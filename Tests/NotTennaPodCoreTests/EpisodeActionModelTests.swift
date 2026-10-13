import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct EpisodeActionModelTests {
    private actor Gate {
        var entered = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0; entered = true } }
        func release() { continuation?.resume(); continuation = nil }
    }
    private func model(_ position: Int32, local: Bool = false) -> EpisodeActionModel {
        var episode = LibraryEpisode(id: 41, details: .init(title: "Captured", media: .init(url: "https://example.test/media", size: 120017, durationMilliseconds: 120_000)))
        episode.userState.positionMilliseconds = position
        episode.userState.playState = .new
        episode.userState.isFavorite = true
        episode.userState.localFileURL = "/owned/original.media"
        episode.userState.isDownloaded = true
        return .init(item: .init(episode: episode, local: local, subscription: .archived, queued: true, downloading: false))
    }
    private func waitForGate(_ gate: Gate) async throws {
        let limit = ContinuousClock.now + .seconds(3)
        while await !gate.entered, ContinuousClock.now < limit { await Task.yield() }
        try #require(await gate.entered)
    }

    // Literal original-app observations: six cases, including both directions of
    // same-object updates and same-ID replacement. Never derive expectation from policy.
    @Test(arguments: [0, 1, 2, 3, 4, 5])
    func sourceCapturedLifetimeCases(_ scenario: Int) async throws {
        let initial: [Int32] = [90_000, 89_999, 0, 90_000, 90_000, 0]
        let final: [Int32] = [90_000, 89_999, 90_000, 0, 0, 90_000]
        let expected = [true, false, true, false, true, false]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CapturedModel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        var preferences = DownloadPreferences(); preferences.autoDelete = true
        let downloads = DownloadCoordinator(store: store, directory: root.appendingPathComponent("media"), network: DownloadNetworkMonitor(startMonitoring: false), preferences: { preferences })
        let captured = model(initial[scenario]), gate = Gate()
        var bound = captured
        var deleted: [Int64] = []
        let timer = downloads.deleteAfterMark(model: captured, wait: { await gate.wait() }) { id, local in
            #expect(!local); deleted.append(id)
        }
        try await waitForGate(gate)
        if scenario >= 4 { bound = model(final[scenario]); #expect(bound.identity != captured.identity) }
        else { bound.receivePlaybackPosition(positionMilliseconds: final[scenario], durationMilliseconds: 120_000) }
        captured.applyCommittedState(.init(playState: .unplayed))
        #expect(bound.episodeID == captured.episodeID)
        #expect(bound.snapshot().episode.userState.positionMilliseconds == final[scenario])
        await gate.release(); await timer.value
        #expect(deleted == (expected[scenario] ? [41] : []))
        #expect(captured.snapshot().episode.userState.positionMilliseconds == (scenario >= 4 ? initial[scenario] : final[scenario]))
        await downloads.stop(); try await store.close()
    }

    @Test func committedDeltaPreservesProgressAndAllUnrelatedStateUntilExplicitReset() {
        let value = model(71_234, local: true), identity = value.identity
        let original = value.snapshot()
        value.applyCommittedState(.init(playState: .unplayed))
        var expectedEpisode = original.episode; expectedEpisode.userState.playState = .unplayed
        #expect(value.snapshot() == .init(episode: expectedEpisode, local: true, subscription: .archived, queued: true))
        value.receivePlaybackPosition(positionMilliseconds: 90_111, durationMilliseconds: 121_234)
        expectedEpisode.userState.positionMilliseconds = 90_111; expectedEpisode.details.media?.durationMilliseconds = 121_234
        #expect(value.snapshot().episode == expectedEpisode)
        value.applyCommittedState(.init(playState: .new))
        #expect(value.snapshot().episode.userState.positionMilliseconds == 90_111)
        value.applyCommittedState(.init(playState: .played, resetPosition: true))
        #expect(value.snapshot().episode.userState.positionMilliseconds == 0)
        #expect(value.identity == identity && value.snapshot().episode.userState.isFavorite)
        let withoutMedia = EpisodeActionModel(item: .init(episode: .init(id: 90, details: .init()), local: false))
        withoutMedia.receivePlaybackPosition(positionMilliseconds: 10, durationMilliseconds: 100)
        #expect(withoutMedia.snapshot().episode.details.media == nil)
        #expect(withoutMedia.snapshot().episode.userState.positionMilliseconds == 0)
    }

    @Test func liveSettingsLocalGateAndIndependentCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CapturedSettings-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        var preferences = DownloadPreferences()
        let downloads = DownloadCoordinator(store: store, directory: root.appendingPathComponent("media"), network: DownloadNetworkMonitor(startMonitoring: false), preferences: { preferences })
        var calls = 0
        let captured = model(0, local: true)
        let first = Gate(), second = Gate()
        let cancelled = downloads.deleteAfterMark(model: captured, wait: { await first.wait() }) { _, _ in calls += 100 }
        let survivor = downloads.deleteAfterMark(model: captured, wait: { await second.wait() }) { id, local in
            #expect(id == 41 && local); calls += 1
        }
        try await waitForGate(first); try await waitForGate(second)
        captured.receivePlaybackPosition(positionMilliseconds: 90_000, durationMilliseconds: 120_000)
        preferences.autoDelete = true; preferences.autoDeleteLocal = true
        cancelled.cancel(); await first.release(); await cancelled.value
        await second.release(); await survivor.value
        #expect(calls == 1)
        let third = Gate()
        let blocked = downloads.deleteAfterMark(model: captured, wait: { await third.wait() }) { _, _ in calls += 100 }
        try await waitForGate(third); preferences.autoDeleteLocal = false
        await third.release(); await blocked.value
        #expect(calls == 1)
        let fourth = Gate()
        let threshold = downloads.deleteAfterMark(model: captured, wait: { await fourth.wait() }) { _, _ in calls += 100 }
        try await waitForGate(fourth); preferences.autoDeleteLocal = true; preferences.smartMarkAsPlayedSeconds = 29
        await fourth.release(); await threshold.value
        #expect(calls == 1)
        await downloads.stop(); try await store.close()
    }
    @Test func eligibleCleanupWithoutCapturedGrantReportsStorageFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MissingCapture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let downloads = DownloadCoordinator(store: store, directory: root.appendingPathComponent("media"),
            network: .init(startMonitoring: false), preferences: {
                var p = DownloadPreferences(); p.autoDelete = true; p.autoDeleteLocal = true; return p
            })
        var failures = 0, successes = 0
        let events = downloads.events()
        let listener = Task {
            for await event in events {
                switch event {
                case .storageError: failures += 1
                case .libraryChanged: successes += 1
                default: break
                }
            }
        }
        defer { listener.cancel() }
        let timer = downloads.deleteAfterMark(model: model(90_000, local: true), target: nil, wait: {}) { _ in
            Issue.record("Unavailable capture must never retarget by ID"); return .deleted
        }
        await timer.value
        let deadline = ContinuousClock.now + .seconds(3)
        while failures == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(failures == 1 && successes == 0)
        await downloads.stop(); try await store.close()
    }

}
