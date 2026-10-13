import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.timeLimit(.minutes(1)))
struct SynchronizationDeliveryTests {
    private func fixture(_ body: (FeedLibraryStore, UUID, DeliveryPublisher) async throws -> Void) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("SyncDelivery-\(UUID()).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) } }
        let store = try FeedLibraryStore(url: file)
        try await store.selectSynchronizationAccount(UUID())
        do { try await body(store, store.synchronizationState().epoch, DeliveryPublisher()); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    private func recipient(_ store: FeedLibraryStore, _ publisher: DeliveryPublisher,
                           foreground: @escaping @MainActor (String) -> Bool = { _ in false },
                           changed: @escaping @MainActor ([Int64]) async throws -> Void = { _ in }) -> SynchronizationDelivery {
        .init(store: store, publisher: publisher, text: .init(errorTitle: "gpodder.net sync error", errorPrefix: "An error occurred during syncing: "),
              foreground: foreground, episodesChanged: changed)
    }
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }

    @Test func foregroundMessageDoesNotDependOnOSPermissionOrPublishASecondCopy() async throws {
        try await fixture { store, epoch, publisher in
            publisher.authorized = false
            var messages: [String] = []
            let delivery = recipient(store, publisher, foreground: { messages.append($0); return true })
            try await delivery.handle(.reportError(message: "fixture failure"), epoch: epoch)
            #expect(messages == ["An error occurred during syncing: fixture failure"])
            #expect(publisher.authorizationCalls == 0 && publisher.published.isEmpty)
        }
    }
    @Test func backgroundHonorsPermissionAndUsesSourceTitlePrefix() async throws {
        try await fixture { store, epoch, publisher in
            let delivery = recipient(store, publisher)
            publisher.authorized = false
            try await delivery.handle(.reportError(message: "first"), epoch: epoch)
            #expect(publisher.published.isEmpty)
            publisher.authorized = true
            try await delivery.handle(.reportError(message: "second"), epoch: epoch)
            #expect(publisher.published == ["gpodder.net sync error|An error occurred during syncing: second"])
            #expect(publisher.authorizationCalls == 2)
        }
    }
    @Test func permissionRevocationDuringPublicationDoesNotFailSynchronization() async throws {
        try await fixture { store, epoch, publisher in
            let delivery = recipient(store, publisher)
            publisher.publicationFailure = true; publisher.revokeOnFailure = true
            try await delivery.handle(.reportError(message: "denied during add"), epoch: epoch)
            #expect(!publisher.authorized && publisher.published.isEmpty)
            publisher.authorized = true; publisher.revokeOnFailure = false
            await #expect(throws: URLError.self) { try await delivery.handle(.reportError(message: "actual delivery failure"), epoch: epoch) }
        }
    }
    @Test func statusReplaysAndAccountChangeInvalidatesIt() async throws {
        try await fixture { store, epoch, publisher in
            let delivery = recipient(store, publisher)
            try await delivery.handle(.status(.subscriptions), epoch: epoch)
            var updates = delivery.updates().makeAsyncIterator()
            let initial = await updates.next()
            #expect(initial??.status == .subscriptions && initial??.epoch == epoch)
            try await store.selectSynchronizationAccount(nil)
            let cleared = await updates.next()
            #expect(cleared != nil && cleared! == nil)
            #expect(delivery.status == nil)
        }
    }

    @Test func schedulingStatusRequiresCurrentRequestAndAccountAndRejectsRetryReplay() async throws {
        try await fixture { store, epoch, publisher in
            let delivery = recipient(store, publisher)
            let first = try #require(try await store.requestSynchronization(immediately: true))
            try await delivery.requestAccepted(first, epoch: epoch)
            #expect(delivery.status == .init(epoch: epoch, status: .started))
            try await delivery.handle(.status(.subscriptions), epoch: epoch)
            let replacement = try #require(try await store.requestSynchronization(immediately: true))
            await #expect(throws: CancellationError.self) { try await delivery.requestAccepted(first, epoch: epoch) }
            #expect(delivery.status?.status == .subscriptions)
            try await delivery.requestAccepted(replacement, epoch: epoch)
            #expect(delivery.status?.status == .started)
            _ = try await store.beginSynchronization(replacement)
            try await store.finishSynchronization(replacement, epoch: epoch, successful: false, retry: true)
            try await delivery.handle(.status(.error), epoch: epoch)
            let retry = try #require(try await store.synchronizationState().request)
            try await delivery.requestAccepted(retry, epoch: epoch)
            #expect(delivery.status?.status == .error)
            try await store.selectSynchronizationAccount(UUID())
            await #expect(throws: CancellationError.self) { try await delivery.requestAccepted(retry, epoch: epoch) }
            try await until { delivery.status == nil }
        }
    }

    @Test func delayedSchedulingStatusCannotOverwriteReplacementWhileDeliveryIsOccupied() async throws {
        try await fixture { store, epoch, publisher in
            publisher.holdAuthorization = true
            let delivery = recipient(store, publisher)
            let blocking = Task { try await delivery.handle(.reportError(message: "previous"), epoch: epoch) }
            try await until { publisher.authorizationGate != nil }
            let oldRequest = try #require(try await store.requestSynchronization(immediately: true))
            let old = Task { try await delivery.requestAccepted(oldRequest, epoch: epoch) }
            try await store.selectSynchronizationAccount(UUID())
            let replacementEpoch = try await store.synchronizationState().epoch
            let replacement = try #require(try await store.requestSynchronization(immediately: true))
            let latest = Task { try await delivery.requestAccepted(replacement, epoch: replacementEpoch) }
            publisher.holdAuthorization = false
            publisher.authorizationGate?.resume(); publisher.authorizationGate = nil
            await #expect(throws: CancellationError.self) { try await blocking.value }
            await #expect(throws: CancellationError.self) { try await old.value }
            try await latest.value
            #expect(delivery.status == .init(epoch: replacementEpoch, status: .started))
            #expect(publisher.published.isEmpty)
        }
    }
    @Test func successClearsErrorsAndChangedEpisodesReachActualRecipient() async throws {
        try await fixture { store, epoch, publisher in
            var changed: [Int64] = []
            let delivery = recipient(store, publisher, changed: { changed += $0 })
            try await delivery.handle(.episodesChanged([2, 4]), epoch: epoch)
            try await delivery.handle(.clearErrorNotifications, epoch: epoch)
            try await delivery.handle(.status(.success), epoch: epoch)
            #expect(changed == [2, 4] && publisher.clearCalls == 1 && delivery.status?.status == .success)
            try await store.selectSynchronizationAccount(UUID())
            await #expect(throws: CancellationError.self) { try await delivery.handle(.episodesChanged([7]), epoch: epoch) }
            #expect(changed == [2, 4])
        }
    }
    @Test func accountChangeDuringAuthorizationPreventsPublication() async throws {
        try await fixture { store, epoch, publisher in
            publisher.holdAuthorization = true
            let delivery = recipient(store, publisher)
            let task = Task { try await delivery.handle(.reportError(message: "stale"), epoch: epoch) }
            try await until { publisher.authorizationGate != nil }
            try await store.selectSynchronizationAccount(UUID())
            publisher.authorizationGate?.resume(); publisher.authorizationGate = nil
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(publisher.published.isEmpty)
        }
    }
    @Test func accountChangeDuringPublicationCleansStaleErrorBeforeNewOne() async throws {
        try await fixture { store, epoch, publisher in
            publisher.holdPublication = true
            let delivery = recipient(store, publisher)
            let old = Task { try await delivery.handle(.reportError(message: "old"), epoch: epoch) }
            try await until { publisher.publicationGate != nil }
            try await store.selectSynchronizationAccount(UUID())
            let nextEpoch = try await store.synchronizationState().epoch
            let next = Task { try await delivery.handle(.reportError(message: "new"), epoch: nextEpoch) }
            publisher.holdPublication = false
            publisher.publicationGate?.resume(); publisher.publicationGate = nil
            await #expect(throws: CancellationError.self) { try await old.value }
            try await next.value
            // Only the new account's error remains visible.
            #expect(publisher.visible == "new")
        }
    }
    @Test func cancellingAcceptedPublicationCleansItAndLaterDeliveryStillWorks() async throws {
        try await fixture { store, epoch, publisher in
            publisher.holdPublication = true
            let delivery = recipient(store, publisher)
            let task = Task { try await delivery.handle(.reportError(message: "cancelled"), epoch: epoch) }
            try await until { publisher.publicationGate != nil }
            task.cancel(); publisher.holdPublication = false
            publisher.publicationGate?.resume(); publisher.publicationGate = nil
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(publisher.visible == nil && publisher.clearCalls == 1)
            try await delivery.handle(.status(.error), epoch: epoch)
            #expect(delivery.status?.status == .error)
        }
    }
}

@MainActor private final class DeliveryPublisher: SynchronizationNotificationPublishing {
    var authorized = true, holdAuthorization = false, holdPublication = false
    var publicationFailure = false, revokeOnFailure = false
    var authorizationGate: CheckedContinuation<Void, Never>?, publicationGate: CheckedContinuation<Void, Never>?
    var authorizationCalls = 0, clearCalls = 0
    var published: [String] = [], events: [String] = []
    var visible: String?
    func isAuthorized() async -> Bool {
        authorizationCalls += 1
        if holdAuthorization { await withCheckedContinuation { authorizationGate = $0 } }
        return authorized
    }
    func publishError(title: String, body: String) async throws {
        if holdPublication { await withCheckedContinuation { publicationGate = $0 } }
        if publicationFailure { if revokeOnFailure { authorized = false }; throw URLError(.notConnectedToInternet) }
        published.append(title + "|" + body)
        visible = String(body.split(separator: " ").last!)
        events.append("publish:" + visible!)
    }
    func clearErrors() async { clearCalls += 1; visible = nil; events.append("clear") }
}
