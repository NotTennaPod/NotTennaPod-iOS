import Foundation
import Testing
@testable import NotTennaPodCore

/// "No other surfaces" (PROTOCOL §15: no nags during normal use): what server mode's exchange goes
/// through (an unreachable server, a refused login, a server failure, a lost history) reaches the Synchronization page
/// through the scheduler's report and nowhere else: the "Synchronization failed" notification and its in-app message
/// stay gpodder.net/Nextcloud-only, even with their delivery listening to the same library.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct ServerSyncSurfacesTests {
    @MainActor final class Publisher: SynchronizationNotificationPublishing {
        var published: [String] = []
        func isAuthorized() async -> Bool { true }
        func publishError(title: String, body: String) async throws { published.append(title + "|" + body) }
        func clearErrors() async {}
    }

    struct Permitted: ServerSyncNetworkGate {
        func permitted() async -> Bool { true }
        func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
    }

    @Test func serverFailuresReachOnlyTheSynchronizationPage() async throws {
        let fixture = try await ServerLibraryFixture()
        let publisher = Publisher()
        var messages: [String] = []
        let delivery = SynchronizationDelivery(store: fixture.store, publisher: publisher,
            text: .init(errorTitle: "gpodder.net sync error", errorPrefix: "An error occurred during syncing: "),
            foreground: { messages.append($0); return true }, episodesChanged: { _ in })
        let failure = TokenBox("unreachable")
        let transport = ServerSyncEngineUnitTests.Transport { _, _ in
            switch failure.value {
            case "unreachable": throw ServerExchangeError.unreachable
            case "sign_in": throw ServerExchangeError.server(status: 401, code: "unauthorized", retryAfter: nil)
            case "lineage": throw ServerExchangeError.server(status: 409, code: "lineage_unknown", retryAfter: nil)
            default: throw ServerExchangeError.server(status: 500, code: "internal", retryAfter: nil)
            }
        }
        let engine = try await ServerSyncEngineUnitTests.engine(fixture, transport)
        let scheduler = ServerSyncScheduler(engine: engine, hints: nil, outbox: nil, network: Permitted())
        var reports: [ServerExchangeReport] = []
        scheduler.callbacks.reported = { reports.append($0) }
        scheduler.start()
        try await fixture.store.appendFactForTesting(type: "favorite.set", targets: [], payload: [:])
        for kind in ["unreachable", "internal", "sign_in", "lineage"] {
            failure.value = kind
            _ = await scheduler.synchronizeNow()
            try await engine.resume()
        }
        // Whatever the library's changes made the delivery do has been done: it reads the library once per change.
        _ = try await fixture.store.synchronizationState()
        await Task.yield()
        #expect(reports.contains { $0.unreachable } && reports.contains { $0.pause == .signIn } && reports.contains { $0.pause == .lineageUnknown })
        #expect(reports.contains { $0.retryAfter != nil && !$0.unreachable }, "a server failure")
        #expect(publisher.published.isEmpty && messages.isEmpty, "no notification and no message outside the page")
        #expect(delivery.status == nil)
        await scheduler.close()
        await fixture.close()
    }
}
