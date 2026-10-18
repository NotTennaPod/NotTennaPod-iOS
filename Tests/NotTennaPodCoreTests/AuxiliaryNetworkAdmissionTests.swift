import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite @MainActor
struct AuxiliaryNetworkAdmissionTests {
    private static let wifi = DownloadNetworkState(connected: true, metered: false, cellular: false, transport: .wifi)
    private static let cellular = DownloadNetworkState(connected: true, metered: true, cellular: true)
    private static let lowData = DownloadNetworkState(connected: true, metered: false, cellular: false, transport: .wifi, constrained: true)
    private static let offline = DownloadNetworkState(connected: false, metered: false, cellular: false)

    private final class Once: @unchecked Sendable { @MainActor var episodeID: Int64? }

    private func withAdmission(_ body: (AuxiliaryNetworkAdmission, MobileNetworkPreferenceStore, DownloadNetworkMonitor, Once) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = try MobileNetworkPreferenceStore(file: directory.appendingPathComponent("mobile.json"))
        let network = DownloadNetworkMonitor(startMonitoring: false)
        let once = Once()
        let admission = AuxiliaryNetworkAdmission(network: network, preferences: preferences, onceAdmittedEpisodeID: { once.episodeID })
        try await body(admission, preferences, network, once)
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }

    /// Transcripts and chapter JSON follow "Cover images", a streamed chapter list "Streaming" or Once consent for that
    /// episode; any unrestricted network admits both, but only for as long as it stays unrestricted. Offline and Low
    /// Data Mode count as restricted. Restricted networks allow 5 MiB, unrestricted ones 20 MiB (16 MiB for media).
    @Test func usesMapToTheirMobileUpdatesOptionsWithTheirBudgets() async throws {
        try await withAdmission { admission, preferences, network, once in
            let mib = 1024 * 1024
            try preferences.updateAllowed([])
            network.update(Self.wifi)
            #expect(try await admission.allowance(.smallMetadata) == .init(bytes: 20 * mib, restricted: false, pathLocked: true))
            #expect(try await admission.allowance(.streamedMedia, episodeID: 1) == .init(bytes: 16 * mib, restricted: false, pathLocked: true))
            #expect(try await admission.streamingRelay(1))
            for state in [Self.cellular, Self.lowData, Self.offline] {
                network.update(state)
                try preferences.updateAllowed([])
                #expect(try await admission.allowance(.smallMetadata) == nil)
                #expect(try await admission.allowance(.streamedMedia, episodeID: 1) == nil)
                #expect(try await !admission.streamingRelay(1))
                try preferences.updateAllowed(["images"])
                #expect(try await admission.allowance(.smallMetadata) == .init(bytes: 5 * mib, restricted: true, pathLocked: false))
                #expect(try await admission.allowance(.streamedMedia, episodeID: 1) == nil, "Cover images doesn't allow media")
                try preferences.updateAllowed(["streaming"])
                #expect(try await admission.allowance(.smallMetadata) == nil, "Streaming doesn't allow transcripts")
                #expect(try await admission.allowance(.streamedMedia, episodeID: 1) == .init(bytes: 5 * mib, restricted: true, pathLocked: false))
                #expect(try await admission.streamingRelay(1))
                try preferences.updateAllowed([])
                once.episodeID = 1
                #expect(try await admission.allowance(.streamedMedia, episodeID: 1) == .init(bytes: 5 * mib, restricted: true, pathLocked: false))
                #expect(try await admission.streamingRelay(1))
                #expect(try await admission.allowance(.streamedMedia, episodeID: 2) == nil, "Once is for its own episode")
                #expect(try await admission.allowance(.streamedMedia) == nil)
                #expect(try await !admission.streamingRelay(2))
                #expect(try await admission.allowance(.smallMetadata) == nil, "Once doesn't allow transcripts")
                once.episodeID = nil
            }
            try preferences.updateAllowed(["images", "streaming"])
            network.update(Self.wifi)
            #expect(try await admission.allowance(.smallMetadata) == .init(bytes: 20 * mib, restricted: false, pathLocked: false))
            #expect(try await admission.allowance(.streamedMedia) == .init(bytes: 16 * mib, restricted: false, pathLocked: false))
        }
    }

    /// Until the first network observation nothing is admitted: the answer waits for it (fail-closed).
    @Test func nothingIsAdmittedBeforeTheFirstObservation() async throws {
        try await withAdmission { admission, preferences, network, _ in
            try preferences.updateAllowed([])
            let answer = Task { try await admission.allowance(.smallMetadata) }
            let relay = Task { try await admission.streamingRelay(1) }
            try await until { network.pendingObservationCount == 2 }
            network.update(Self.cellular)
            #expect(try await answer.value == nil)
            #expect(try await !relay.value)
        }
    }

    /// A network change between the allowance and the fetch's start spends nothing: a path-locked fetch refuses on
    /// entry, before any request. A fetch allowed by its option runs on the restricted network (control).
    @Test func changeBetweenAllowanceAndLaunchSpendsNothing() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(body: Data("WEBVTT\n".utf8)) }
        defer { server.stop() }
        try await withAdmission { admission, preferences, network, _ in
            try preferences.updateAllowed([])
            network.update(Self.wifi)
            let allowance = try #require(try await admission.allowance(.smallMetadata))
            #expect(allowance.pathLocked)
            network.update(Self.cellular)
            let url = server.url
            await #expect(throws: DownloadNetworkInterruption.self) {
                try await admission.perform(allowance) {
                    var request = URLRequest(url: url)
                    allowance.constrain(&request)
                    return try await URLSessionFeedTransport().send(request).status
                }
            }
            #expect(server.requests.isEmpty)
            try preferences.updateAllowed(["images"])
            let allowed = try #require(try await admission.allowance(.smallMetadata))
            #expect(try await admission.perform(allowed) { try await URLSessionFeedTransport().send(URLRequest(url: url)).status } == 200)
            #expect(server.requests.count == 1)
        }
    }

    /// A permission that returns between a denial and the waiter's arming (its change signal already gone) is seen by
    /// the wait's first check; so is a network that became unrestricted.
    @Test func permissionReturningBeforeWakeIsArmedIsSeen() async throws {
        try await withAdmission { admission, preferences, network, _ in
            try preferences.updateAllowed([])
            network.update(Self.cellular)
            #expect(try await admission.allowance(.smallMetadata) == nil)
            try preferences.updateAllowed(["images"])
            admission.preferencesChanged() // Nobody listens yet: this signal is lost.
            try await admission.wait(until: .permitted(.smallMetadata))
            #expect(admission.parkedCheckCount == 0)
            try preferences.updateAllowed([])
            #expect(try await admission.allowance(.streamedMedia, episodeID: 3) == nil)
            network.update(Self.wifi)
            try await admission.wait(until: .permitted(.streamedMedia, episodeID: 3))
            #expect(admission.parkedCheckCount == 0)
        }
    }

    /// A parked wait rechecks on every option and network change and returns when its permission holds.
    @Test func parkedWaitWakesOnOptionAndNetworkChanges() async throws {
        try await withAdmission { admission, preferences, network, _ in
            try preferences.updateAllowed([])
            network.update(Self.cellular)
            let byOption = Task { try await admission.wait(until: .permitted(.smallMetadata)) }
            try await until { admission.parkedCheckCount == 1 }
            try preferences.updateAllowed(["streaming"])
            admission.preferencesChanged()
            try await until { admission.parkedCheckCount == 2 }
            try preferences.updateAllowed(["images"])
            admission.preferencesChanged()
            try await byOption.value
            try preferences.updateAllowed([])
            let byNetwork = Task { try await admission.wait(until: .permitted(.streamedMedia, episodeID: 1)) }
            try await until { admission.parkedCheckCount == 3 }
            network.update(Self.lowData)
            try await until { admission.parkedCheckCount == 4 }
            network.update(Self.wifi)
            try await byNetwork.value
            network.update(Self.cellular)
            let cancelled = Task { try await admission.wait(until: .unrestricted) }
            try await until { admission.parkedCheckCount == 5 }
            cancelled.cancel()
            await #expect(throws: CancellationError.self) { try await cancelled.value }
        }
    }

    /// Over the restricted budget a fetch waits for an unrestricted network: no option change releases it, even
    /// Cover images and Streaming both on; Low Data Wi-Fi doesn't either; ordinary Wi-Fi does.
    @Test func unrestrictedWaitIgnoresPermission() async throws {
        try await withAdmission { admission, preferences, network, _ in
            network.update(Self.cellular)
            let released = Mutex(false)
            let wait = Task {
                try await admission.wait(until: .unrestricted)
                released.withLock { $0 = true }
            }
            try await until { admission.parkedCheckCount == 1 }
            try preferences.updateAllowed(["images", "streaming"])
            admission.preferencesChanged()
            try await until { admission.parkedCheckCount == 2 }
            #expect(!released.withLock { $0 })
            network.update(Self.lowData)
            try await until { admission.parkedCheckCount == 3 }
            #expect(!released.withLock { $0 })
            network.update(Self.wifi)
            try await wait.value
            #expect(released.withLock { $0 })
        }
    }

    /// A fetch admitted only because the network was unrestricted stops when a metered network appears, even one that
    /// is gone again by the next check: the request is cancelled (the server sees the client leave), the result is the
    /// interruption, and the retry's wait is released at once on the restored Wi-Fi.
    @Test func transientProhibitedRevisionCancelsPathLockedRead() async throws {
        let disconnected = Mutex(false)
        let server = try await LoopbackHTTPServer.start(onClientDisconnect: { disconnected.withLock { $0 = true } }) { _ in nil }
        defer { server.stop() }
        try await withAdmission { admission, preferences, network, _ in
            try preferences.updateAllowed([])
            network.update(Self.wifi)
            let allowance = try #require(try await admission.allowance(.smallMetadata))
            let url = server.url
            let read = Task {
                try await admission.perform(allowance) {
                    var request = URLRequest(url: url)
                    allowance.constrain(&request)
                    return try await URLSessionFeedTransport().send(request).status
                }
            }
            try await until { server.requests.count == 1 }
            network.update(Self.cellular)
            network.update(Self.wifi)
            await #expect(throws: DownloadNetworkInterruption.self) { try await read.value }
            try await until { disconnected.withLock { $0 } }
            try await admission.wait(until: .permitted(.smallMetadata))
            #expect(server.requests.count == 1)
        }
    }

    /// Without the app's preferences (tests, standalone screens) everything is admitted on the unrestricted budgets.
    @Test func unrestrictedAdmissionAdmitsEverything() async throws {
        let admission = AuxiliaryNetworkAdmission.unrestricted
        #expect(try await admission.allowance(.smallMetadata) == .init(bytes: 20 * 1024 * 1024, restricted: false, pathLocked: false))
        #expect(try await admission.allowance(.streamedMedia, episodeID: 1) == .init(bytes: 16 * 1024 * 1024, restricted: false, pathLocked: false))
        #expect(try await admission.streamingRelay(1))
        try await admission.wait(until: .unrestricted)
        try await admission.wait(until: .permitted(.streamedMedia, episodeID: 1))
    }
}
