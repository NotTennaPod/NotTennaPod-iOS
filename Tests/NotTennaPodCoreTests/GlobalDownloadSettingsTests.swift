import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite
struct GlobalDownloadSettingsTests {
    @Test func settingsCacheInitializationDistinguishesUnsetAndExplicitValues() throws {
        var value = AutomaticDownloadPreferences()
        #expect(value.cacheSize == 20)
        let unset = try JSONEncoder().encode(value)
        #expect(!String(decoding: unset, as: UTF8.self).contains("cacheSize"))
        value = try JSONDecoder().decode(AutomaticDownloadPreferences.self, from: unset)
        value.initializeSettingsDefaults(); #expect(value.cacheSize == 25)
        value.cacheSize = -1; value.initializeSettingsDefaults(); #expect(value.cacheSize == -1)
        let legacy = Data(#"{"global":true,"queue":true,"onBattery":false,"cacheSize":20,"cleanup":12}"#.utf8)
        var restored = try JSONDecoder().decode(AutomaticDownloadPreferences.self, from: legacy)
        restored.initializeSettingsDefaults()
        #expect(restored.cacheSize == 20 && restored.global && restored.queue && !restored.onBattery && restored.cleanup == 12)
    }
    @Test func oldDownloadPreferencesRetainDefaultsAndNewFieldsPersistTogether() throws {
        let old = Data(#"{"allowMobile":false,"enqueue":true,"deleteRemovesFromQueue":false,"enqueueLocation":"BACK"}"#.utf8)
        var value = try JSONDecoder().decode(DownloadPreferences.self, from: old)
        #expect(value.playbackEnd == PlaybackEndPreferences())
        #expect(value.buttonActionPlay == nil && value.swipe == nil && value.newEpisodesAction == nil)
        value.newEpisodesAction = .queue
        value.buttonActionPlay = true; value.autoDelete = true; value.autoDeleteLocal = true
        value.favoriteKeepsEpisode = false; value.smartMarkAsPlayedSeconds = 120; value.deleteRemovesFromQueue = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GlobalDownloads-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("preferences.json"), store = try DownloadPreferenceStore(file: root.appendingPathComponent("preferences.json"))
        try store.update(value)
        let saved = try DownloadPreferenceStore(file: file).value
        #expect(saved == value && saved.playbackEnd.autoDelete && saved.playbackEnd.autoDeleteLocal)
        #expect(!saved.playbackEnd.favoriteKeepsEpisode && saved.playbackEnd.smartMarkAsPlayedSeconds == 120)
    }
    @Test func markDeletionUsesGlobalLocalAndPositionRulesIncludingFavoritesAndWideArithmetic() {
        var value = DownloadPreferences(), episode = LibraryEpisode(id: 1, details: .init(media: .init(url: "https://example.test/media", size: 120017, durationMilliseconds: 120_000)))
        episode.userState.positionMilliseconds = 90_000; episode.userState.isFavorite = true
        func item(_ local: Bool = false) -> EpisodeListItem { .init(episode: episode, local: local) }
        #expect(!value.deletesAfterMark(item()))
        value.autoDelete = true
        #expect(value.deletesAfterMark(item())) // Source mark handler does not apply favorite protection.
        #expect(!value.deletesAfterMark(item(true)))
        value.autoDeleteLocal = true; #expect(value.deletesAfterMark(item(true)))
        episode.userState.positionMilliseconds = 89_999; #expect(!value.deletesAfterMark(item()))
        value.smartMarkAsPlayedSeconds = .max; #expect(value.deletesAfterMark(item()))
        episode.details.media?.durationMilliseconds = 0; #expect(!value.deletesAfterMark(item()))
    }
    private actor Gate {
        var entered = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0; entered = true } }
        func release() { continuation?.resume(); continuation = nil }
    }
    @Test func delayedDeletionReadsSettingsAtExecutionAndUsesRealFileOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MarkedDeletion-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        var preferences = DownloadPreferences()
        let downloads = DownloadCoordinator(store: store, directory: root.appendingPathComponent("media"), network: DownloadNetworkMonitor(startMonitoring: false), preferences: { preferences })
        let playback = PlaybackCoordinator(store: store, engine: AVPlayerPlaybackEngine(muted: true))
        do {
            let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Feed", episodes: [.init(identifier: "episode", media: .init(url: "https://example.test/media", size: 120017, durationMilliseconds: 120_000))]), source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
            let id = try #require(feed.episodes.first?.id), file = root.appendingPathComponent("episode.mp3")
            let fixture = try #require(Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures"))
            try FileManager.default.copyItem(at: fixture, to: file)
            try await store.updateEpisode(id: id) { $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path; $0.userState.positionMilliseconds = 100_000; $0.userState.isFavorite = true }
            _ = try await store.enqueue([id])
            let item = EpisodeListItem(episode: try #require(try await store.episode(id: id)), local: false)
            let gate = Gate()
            let job = downloads.deleteAfterMark(item, wait: { await gate.wait() }) { id, local in
                #expect(!local); try await downloads.deleteDownloadedMedia(episodeID: id, playback: playback)
            }
            while await !gate.entered { await Task.yield() }
            #expect(FileManager.default.fileExists(atPath: file.path))
            preferences.autoDelete = true // Source reads this at delayed execution, not scheduling.
            await gate.release(); await job.value
            #expect(!FileManager.default.fileExists(atPath: file.path))
            let result = try #require(try await store.episode(id: id))
            #expect(!result.userState.isDownloaded && result.userState.localFileURL == nil && result.userState.isFavorite)
            #expect(try await store.queue().map(\.id) == [id])
            let cancelledGate = Gate()
            let cancelled = downloads.deleteAfterMark(item, wait: { await cancelledGate.wait() }) { _, _ in Issue.record("Cancelled timer must not delete") }
            while await !cancelledGate.entered { await Task.yield() }
            cancelled.cancel(); await cancelledGate.release(); await cancelled.value
            await downloads.stop(); try await store.close()
        } catch { await downloads.stop(); try? await store.close(); throw error }
    }
}
