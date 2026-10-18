import Foundation
import Testing
import Synchronization
@testable import NotTennaPodCore

@MainActor
@Suite
struct DownloadCoordinatorTests {
    private func withCoordinator(source: String, network: DownloadNetworkMonitor,
                                 sharedMedia: Bool = false,
                                 preferences: @escaping @MainActor () -> DownloadPreferences = { .init() },
                                 _ operation: (DownloadCoordinator, FeedLibraryStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Coordinator-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let episodes = (1...2).map { index in
            ParsedEpisode(identifier: "\(index)", title: "Episode \(index)",
                          media: ParsedMedia(url: sharedMedia ? source : source + "?episode=\(index)", size: 100_000, durationMilliseconds: 30_000))
        }
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Coordinator", episodes: episodes),
                                              source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
                                              validator: nil, permanentRedirectURL: nil))
        let coordinator = DownloadCoordinator(store: store, directory: directory.appendingPathComponent("media"),
                                               network: network, preferences: preferences)
        do { try await operation(coordinator, store, directory); await coordinator.stop(); try await store.close() }
        catch { await coordinator.stop(); try? await store.close(); throw error }
    }

    private func network(metered: Bool = false) -> DownloadNetworkMonitor {
        let monitor = DownloadNetworkMonitor(startMonitoring: false)
        monitor.update(.init(connected: true, metered: metered, cellular: metered))
        return monitor
    }

    private func waitUntil(_ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try await !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(try await condition())
    }

    @Test func batchRequestsUseServiceConstraintsDisplayOrderAndSourceDeduplication() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(body: Data("audio".utf8)) }
        defer { server.stop() }
        try await withCoordinator(source: server.url.absoluteString, network: network(metered: true)) { coordinator, store, _ in
            try await coordinator.requestBatch(episodeID: 2)
            try await coordinator.requestBatch(episodeID: 1)
            try await coordinator.requestBatch(episodeID: 2)
            #expect(try await store.queue().map(\.id) == [2, 1])
            #expect(try await store.downloadJobs().count == 2)
            #expect(try await store.downloadJobs().allSatisfy { $0.networkConstraint == .unmetered && $0.attempts == 0 })
            #expect(server.requests.isEmpty)
            try await coordinator.cancel(episodeID: 2)
            #expect(try await store.queue().map(\.id) == [1])
            #expect(try await store.episode(id: 2)?.userState.autoDownloadEnabled == false)
        }
    }

    @Test func oneCoordinatorStartsUniqueWorkAndPublishesCompletedLibraryState() async throws {
        let body = Data("downloaded".utf8)
        let server = try await LoopbackHTTPServer.start { _ in .init(body: body) }
        defer { server.stop() }
        try await withCoordinator(source: server.url.absoluteString, network: network()) { coordinator, store, _ in
            #expect(try await coordinator.request(episodeID: 1) == .request(ignoreConstraints: false, showMobileNotice: false))
            _ = try await coordinator.request(episodeID: 1)
            try await waitUntil { try await store.episode(id: 1)?.userState.isDownloaded == true }
            try await waitUntil { coordinator.jobs.first?.state == .completed }
            #expect(server.requests.count == 1)
            #expect(try await store.queue().map(\.id) == [1])
            let path = try #require(try await store.episode(id: 1)?.userState.localFileURL)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == body)
            #expect(coordinator.activeJob(source: server.url.absoluteString + "?episode=1") == nil)
            #expect(try await coordinator.request(episodeID: 1) == .ignored)
        }
    }

    @Test func laterConfirmationQueuesWithoutNetworkTrafficAndBypassesSecondPrompt() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(body: Data("audio".utf8)) }
        defer { server.stop() }
        try await withCoordinator(source: server.url.absoluteString, network: network(metered: true)) { coordinator, store, _ in
            #expect(try await coordinator.request(episodeID: 1) == .confirmation(showVPNAdvice: false))
            #expect(try await store.downloadJobs().isEmpty)
            #expect(try await coordinator.confirm(episodeID: 1, choice: .later) == .request(ignoreConstraints: false, showMobileNotice: false))
            #expect(try await coordinator.request(episodeID: 2) == .request(ignoreConstraints: false, showMobileNotice: false))
            #expect(try await store.queue().map(\.id) == [1, 2])
            #expect(try await store.downloadJobs().allSatisfy { $0.state == .waiting && $0.networkConstraint == .unmetered && $0.attempts == 0 })
            #expect(server.requests.isEmpty)
            try await coordinator.cancel(episodeID: 1)
            #expect(try await store.queue().map(\.id) == [2])
            #expect(try await store.episode(id: 1)?.userState.autoDownloadEnabled == false)
        }
    }

    @Test func anywayConfirmationStartsMeteredWorkAndSecondTapRequestsNotice() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(body: Data("audio".utf8)) }
        defer { server.stop() }
        try await withCoordinator(source: server.url.absoluteString, network: network(metered: true)) { coordinator, store, _ in
            #expect(try await coordinator.request(episodeID: 1) == .confirmation(showVPNAdvice: false))
            #expect(try await coordinator.confirm(episodeID: 1, choice: .now) == .request(ignoreConstraints: true, showMobileNotice: false))
            #expect(try await coordinator.request(episodeID: 2) == .request(ignoreConstraints: true, showMobileNotice: true))
            try await waitUntil { try await store.downloadJobs(activeOnly: false).filter { $0.state == .completed }.count == 2 }
            #expect(try await store.downloadJobs(activeOnly: false).allSatisfy { $0.networkConstraint == .connected })
            #expect(server.requests.count == 2)
        }
    }

    /// A job created within "Allow this time" keeps the constraint it was stored with after the window ends; a download
    /// asked for later on Wi-Fi is Wi-Fi-only again.
    @Test func allowThisTimeCoversOnlyJobsCreatedWithinIt() async throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1_700_000_000))
        let network = network(metered: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Coordinator-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let episodes = (1...2).map { index in
            ParsedEpisode(identifier: "\(index)", title: "Episode \(index)",
                          media: ParsedMedia(url: "https://example.test/media?episode=\(index)", size: 100_000, durationMilliseconds: 30_000))
        }
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Coordinator", episodes: episodes),
                                              source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
                                              validator: nil, permanentRedirectURL: nil))
        // A transfer that never finishes: only the stored constraints matter here.
        let coordinator = DownloadCoordinator(store: store, directory: directory.appendingPathComponent("media"), transfer: NeverFinishingTransfer(),
                                              network: network, clock: { clock.withLock { $0 } })
        do {
            #expect(try await coordinator.request(episodeID: 1) == .confirmation(showVPNAdvice: false))
            #expect(try await coordinator.confirm(episodeID: 1, choice: .now) == .request(ignoreConstraints: true, showMobileNotice: false))
            clock.withLock { $0 = $0.addingTimeInterval(600) }
            network.update(.init(connected: true, metered: false, cellular: false, transport: .wifi))
            #expect(try await coordinator.request(episodeID: 2) == .request(ignoreConstraints: false, showMobileNotice: false))
            let jobs = try await store.downloadJobs(activeOnly: false)
            let constraints = Dictionary(uniqueKeysWithValues: jobs.map { ($0.episodeID, $0.networkConstraint) })
            #expect(constraints == [1: .connected, 2: .unmetered])
            await coordinator.stop(); try await store.close()
        } catch { await coordinator.stop(); try? await store.close(); throw error }
    }

    private struct NeverFinishingTransfer: MediaTransferring {
        func download(_ input: MediaDownloadRequest,
                      progress: @escaping @Sendable (MediaDownloadProgress) -> Void) async throws -> MediaDownloadResult {
            try await Task.sleep(for: .seconds(3_600))
            throw CancellationError()
        }
    }

    @Test func stalledTransferProgressUpdatesWithoutAnotherDataCallbackAndCancelCleansUp() async throws {
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": "100000"], body: Data(repeating: 5, count: 8192), keepConnectionOpen: true)
        }
        defer { server.stop() }
        try await withCoordinator(source: server.url.absoluteString, network: network()) { coordinator, store, _ in
            _ = try await coordinator.request(episodeID: 1)
            let job = try #require(coordinator.jobs.first)
            try await waitUntil { coordinator.progress[job.id]?.received == 8192 }
            #expect(coordinator.progress[job.id]?.expected == 100_000)
            #expect(coordinator.jobs.first?.state == .transferring)
            try await coordinator.cancel(episodeID: 1)
            #expect(!FileManager.default.fileExists(atPath: job.destination.path))
            #expect(try await store.queue().isEmpty)
            #expect(coordinator.progress[job.id] == nil)
        }
    }

    @Test(arguments: [false, true])
    func eitherEpisodeCanCancelSharedMediaWithoutChangingTheOtherEpisodesQueueOrAutoDownload(transferring: Bool) async throws {
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": "100000"], body: Data(repeating: 5, count: 8192), keepConnectionOpen: true)
        }
        defer { server.stop() }
        try await withCoordinator(source: server.url.absoluteString, network: network(metered: !transferring), sharedMedia: true) { coordinator, store, _ in
            _ = try await store.enqueue([2])
            _ = try await coordinator.confirm(episodeID: 1, choice: .later)
            let job = try #require(coordinator.activeJob(source: server.url.absoluteString))
            #expect(try await coordinator.request(episodeID: 2) == .ignored)
            #expect(try await store.queue().map(\.id) == [2, 1])
            if transferring { try await waitUntil { coordinator.progress[job.id]?.received == 8192 } }
            else { #expect(server.requests.isEmpty) }
            try await coordinator.cancel(episodeID: 2)
            #expect(coordinator.activeJob(source: server.url.absoluteString) == nil)
            #expect(try await store.downloadJob(id: job.id)?.state == .cancelled)
            #expect(try await store.queue().map(\.id) == [1])
            #expect(try await store.episode(id: 1)?.userState.autoDownloadEnabled == true)
            #expect(try await store.episode(id: 2)?.userState.autoDownloadEnabled == false)
            #expect(FileManager.default.fileExists(atPath: job.destination.path) == transferring)
            #expect(try await store.episode(id: 1)?.userState.localFileURL == (transferring ? job.destination.path : nil))
            #expect(try await store.pendingEffects().allSatisfy {
                if case .downloadFileDeleted = $0.effect.kind { return false }
                return true
            })
            #expect(server.requests.count == (transferring ? 1 : 0))
            try await coordinator.cancel(episodeID: 2)
            #expect(try await store.queue().map(\.id) == [1])
        }
    }

    @Test func sharedCancellationRetainsVerifiedBytesAndTheOriginalEpisodeResumesAfterReopen() async throws {
        let prefix = Data(repeating: 5, count: 8192), suffix = Data(repeating: 6, count: 100_000 - 8192)
        let server = try await LoopbackHTTPServer.start { request in
            if request.headers["range"] != nil {
                return .init(status: 206, headers: ["Content-Range": "bytes 8192-99999/100000", "ETag": "\"same-media\""], body: suffix)
            }
            return .init(headers: ["Content-Length": "100000", "ETag": "\"same-media\""], body: prefix, keepConnectionOpen: true)
        }
        defer { server.stop() }
        try await withCoordinator(source: server.url.absoluteString, network: network(), sharedMedia: true) { coordinator, store, root in
            _ = try await coordinator.request(episodeID: 1)
            let original = try #require(coordinator.jobs.first)
            try await waitUntil { coordinator.progress[original.id]?.received == 8192 }
            let before = try await store.episode(id: 1)
            try await coordinator.cancel(episodeID: 2)
            #expect(try await store.episode(id: 1) == before)
            #expect(try Data(contentsOf: original.destination) == prefix)
            await coordinator.stop()
            let reopened = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
            let restarted = DownloadCoordinator(store: reopened, directory: root.appendingPathComponent("media"), network: network())
            do {
                let retained = try #require(try await reopened.downloadJob(id: original.id))
                #expect(retained.representation == .init(resource: server.url, entityTag: "\"same-media\"", total: 100_000))
                _ = try await restarted.request(episodeID: 1)
                try await waitUntil { try await reopened.episode(id: 1)?.userState.isDownloaded == true }
                let completed = try #require(try await reopened.downloadJobs(activeOnly: false).last)
                #expect(completed.id != original.id)
                #expect(completed.state == .completed)
                #expect(try Data(contentsOf: completed.destination) == prefix + suffix)
                #expect(server.requests.map { $0.headers["range"] } == [nil, "bytes=8192-"])
                #expect(server.requests.map { $0.headers["if-range"] } == [nil, "\"same-media\""])
                #expect(try await reopened.episode(id: 2)?.userState.isDownloaded == false)
                #expect(try await reopened.episode(id: 2)?.userState.autoDownloadEnabled == false)
                await restarted.stop(); try await reopened.close()
            } catch { await restarted.stop(); try? await reopened.close(); throw error }
        }
    }

    /// A download waiting for Wi-Fi changes nothing on screen until it transfers: the 1 Hz poll
    /// (a database read each second) sleeps meanwhile, and the transfer's progress wakes it.
    @Test func progressPollSleepsWhileWorkOnlyWaitsAndWakesWhenBytesFlow() async throws {
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": "100000"], body: Data(repeating: 5, count: 8192), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let network = network(metered: true)
        try await withCoordinator(source: server.url.absoluteString, network: network) { coordinator, store, _ in
            _ = try await coordinator.confirm(episodeID: 1, choice: .later)
            let job = try #require(coordinator.jobs.first)
            #expect(coordinator.isPolling && job.state == .waiting)
            try await waitUntil { !coordinator.isPolling }
            #expect(coordinator.activeJob(source: job.source)?.state == .waiting && server.requests.isEmpty)
            network.update(.init(connected: true, metered: false, cellular: false))
            try await waitUntil { coordinator.progress[job.id]?.received == 8192 }
            #expect(coordinator.jobs.first?.state == .transferring && coordinator.isPolling)
            try await coordinator.cancel(episodeID: 1)
            #expect(try await store.downloadJob(id: job.id)?.state == .cancelled)
        }
    }

    @Test func stopPreservesWaitingWorkAndStartResumesIt() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(body: Data("audio".utf8)) }
        defer { server.stop() }
        let network = network(metered: true)
        try await withCoordinator(source: server.url.absoluteString, network: network) { coordinator, store, _ in
            _ = try await coordinator.confirm(episodeID: 1, choice: .later)
            await coordinator.stop()
            #expect(try await store.downloadJobs().first?.state == .waiting)
            #expect(try await store.queue().map(\.id) == [1])
            #expect(try await store.episode(id: 1)?.userState.autoDownloadEnabled == true)
            network.update(.init(connected: true, metered: false, cellular: false))
            try await coordinator.start()
            try await waitUntil { try await store.episode(id: 1)?.userState.isDownloaded == true }
            #expect(server.requests.count == 1)
        }
    }

    @Test func suppliedPreferencesControlQueueAndMobileAdmission() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(body: Data("audio".utf8)) }
        defer { server.stop() }
        var preferences = DownloadPreferences()
        preferences.enqueue = false
        preferences.allowMobile = true
        try await withCoordinator(source: server.url.absoluteString, network: network(metered: true), preferences: { preferences }) { coordinator, store, _ in
            #expect(try await coordinator.request(episodeID: 1) == .request(ignoreConstraints: false, showMobileNotice: false))
            try await waitUntil { try await store.episode(id: 1)?.userState.isDownloaded == true }
            #expect(try await store.queue().isEmpty)
        }
    }

    @Test func stopWaitsForStartupAndPreventsLateLaunchUntilExplicitRestart() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(body: Data("audio".utf8)) }
        defer { server.stop() }
        try await withCoordinator(source: server.url.absoluteString, network: network()) { coordinator, store, directory in
            _ = try await store.requestDownload(episodeID: 1, directory: directory.appendingPathComponent("media"))
            let gate = CoordinatorStartupGate()
            defer { gate.release.signal() }
            let blockedStore = Task.detached { await store.holdForCoordinatorTest(gate) }
            try await waitUntil { gate.entered.withLock { $0 } }
            var startEntered = false
            let starting = Task { startEntered = true; try await coordinator.start() }
            try await waitUntil { startEntered }
            var stopEntered = false
            let stopping = Task { stopEntered = true; await coordinator.stop() }
            try await waitUntil { stopEntered }
            gate.release.signal()
            await blockedStore.value
            await stopping.value
            switch await starting.result {
            case .success: Issue.record("Startup must be interrupted by the stop request")
            case .failure(let error): #expect(error is CancellationError)
            }
            #expect(try await store.downloadJobs().first?.attempts == 0)
            #expect(server.requests.isEmpty)
            try await coordinator.start()
            try await waitUntil { try await store.episode(id: 1)?.userState.isDownloaded == true }
            #expect(server.requests.count == 1)
        }
    }
}

private final class CoordinatorStartupGate: Sendable {
    let entered = Mutex(false)
    let release = DispatchSemaphore(value: 0)
}

private extension FeedLibraryStore {
    func holdForCoordinatorTest(_ gate: CoordinatorStartupGate) {
        gate.entered.withLock { $0 = true }
        gate.release.wait()
    }
}
