import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite
struct KeepSkippedEpisodesPreferenceTests {
    private func withFile(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeepSkipped-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("playback-queue.json"))
    }

    @Test func newPreferencesKeepSkippedEpisodesAndFollowQueue() throws {
        try withFile { file in
            let store = try PlaybackQueuePreferenceStore(file: file)
            #expect(store.value.skipKeepsEpisode && store.value.followQueue)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test(arguments: [true, false])
    func existingFollowQueueFilesAcquireKeepDefaultWithoutLosingTheirValue(follow: Bool) throws {
        try withFile { file in
            try Data("{\"followQueue\":\(follow)}".utf8).write(to: file)
            let store = try PlaybackQueuePreferenceStore(file: file)
            #expect(store.value.skipKeepsEpisode)
            #expect(store.value.followQueue == follow)
            var value = store.value; value.skipKeepsEpisode = false
            try store.update(value)
            let restored = try PlaybackQueuePreferenceStore(file: file)
            #expect(!restored.value.skipKeepsEpisode && restored.value.followQueue == follow)
            value = restored.value; value.skipKeepsEpisode = true
            try restored.update(value)
            #expect(try PlaybackQueuePreferenceStore(file: file).value == value)
        }
    }

    @Test func missingKeysDefaultIndependentlyAndMalformedValueIsRejected() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(PlaybackQueuePreferences.self, from: Data("{}".utf8)) == .init())
        let keepOnly = try decoder.decode(PlaybackQueuePreferences.self, from: Data("{\"skipKeepsEpisode\":false}".utf8))
        #expect(!keepOnly.skipKeepsEpisode && keepOnly.followQueue)
        #expect(throws: DecodingError.self) {
            try decoder.decode(PlaybackQueuePreferences.self, from: Data("{\"skipKeepsEpisode\":\"false\"}".utf8))
        }
    }

    @Test func failedWriteDoesNotPublishAnUnpersistedPreference() throws {
        try withFile { file in
            let store = try PlaybackQueuePreferenceStore(file: file)
            // A directory at the destination deterministically prevents atomic file replacement.
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            var value = store.value; value.skipKeepsEpisode = false
            #expect(throws: (any Error).self) { try store.update(value) }
            #expect(store.value.skipKeepsEpisode && store.value.followQueue)
        }
    }

    private struct EndScenario: Sendable {
        let name: String
        let keep: Bool
        var reason: PlaybackEndReason = .skipped
        var position: Int32 = 4_000
        var autoDelete = true
        var favorite = false
        var protectFavorite = true
        let completed: Bool
        let removed: Bool
        let deleted: Bool
    }

    // Explicit expected outcomes from Media3PlaybackService's end/skip contract.
    // Existing FeedAutoDeleteTests cover global/local/per-feed policy resolution.
    @Test(arguments: [
        EndScenario(name: "early keep gates deletion", keep: true, completed: false, removed: false, deleted: false),
        EndScenario(name: "early discard preserves unplayed position", keep: false, completed: false, removed: true, deleted: true),
        EndScenario(name: "disabled deletion retains download", keep: false, autoDelete: false, completed: false, removed: true, deleted: false),
        EndScenario(name: "favorite protection retains download", keep: false, favorite: true, completed: false, removed: true, deleted: false),
        EndScenario(name: "unprotected favorite deletes download", keep: false, favorite: true, protectFavorite: false, completed: false, removed: true, deleted: true),
        EndScenario(name: "almost completed overrides keep", keep: true, position: 70_000, completed: true, removed: true, deleted: true),
        EndScenario(name: "almost completed with discard", keep: false, position: 70_000, completed: true, removed: true, deleted: true),
        EndScenario(name: "natural completion overrides keep", keep: true, reason: .ended, completed: true, removed: true, deleted: true)
    ])
    private func persistedKeepPreferencePreservesCompletionDeletionAndSuccessorRules(scenario: EndScenario) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeepSkippedEnd-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferenceFile = root.appendingPathComponent("queue.json")
        let preferences = try PlaybackQueuePreferenceStore(file: preferenceFile)
        var saved = preferences.value; saved.skipKeepsEpisode = scenario.keep; try preferences.update(saved)
        let restored = try PlaybackQueuePreferenceStore(file: preferenceFile)
        let libraryFile = root.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: libraryFile)
        do {
            let source = URL(string: "https://example.test/keep-skipped")!
            _ = try await store.insert(.init(feed: .init(format: .rss, title: "Keep skipped", episodes: (1...3).map {
                .init(identifier: "\($0)", title: "Episode \($0)", media: .init(url: source.appendingPathComponent("\($0).mp3").absoluteString,
                    size: 0, durationMilliseconds: 100_000))
            }), source: source.absoluteString, responseURL: source, validator: nil, permanentRedirectURL: nil))
            let file = root.appendingPathComponent("download.mp3")
            try Data("download".utf8).write(to: file)
            try await store.updateEpisode(id: 1) {
                $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path
                $0.userState.downloadDate = Date(); $0.userState.isFavorite = scenario.favorite
            }
            _ = try await store.enqueue([3, 1, 2])
            try await store.selectSynchronizationAccount(UUID())
            let session = try await store.beginPlayback(episodeID: 1)
            _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: scenario.position,
                durationMilliseconds: 100_000, status: .paused))
            var end = PlaybackEndPreferences()
            end.skipKeepsEpisode = restored.value.skipKeepsEpisode
            end.autoDelete = scenario.autoDelete; end.favoriteKeepsEpisode = scenario.protectFavorite
            end.synchronize = true
            let result = try #require(try await store.endPlayback(sessionID: session.id, reason: scenario.reason, preferences: end))
            #expect(result.nextEpisodeID == 2)
            #expect(result.markedPlayed == scenario.completed && result.removedFromQueue == scenario.removed)
            #expect(result.episode.userState.playState == (scenario.completed ? .played : .unplayed))
            #expect(result.episode.userState.positionMilliseconds == (scenario.completed ? 0 : scenario.position))
            #expect(result.episode.userState.isDownloaded == !scenario.deleted)
            #expect(result.episode.userState.lastPlayedHistoryMilliseconds != nil)
            let played = try await store.synchronizationQueue().compactMap {
                if case .episode(let action) = $0.value, action.action == .play { action } else { nil }
            }
            // A completed episode reports its whole duration; otherwise the position it stopped at.
            #expect(played.map(\.position) == [scenario.completed ? 100 : scenario.position / 1_000])
            try await MediaDownloadWorker(store: store).cleanCancelledFiles()
            #expect(FileManager.default.fileExists(atPath: file.path) == !scenario.deleted)
            try await store.close()
            let reopened = try FeedLibraryStore(url: libraryFile)
            do {
                #expect(try await reopened.queue().map(\.id) == (scenario.removed ? [3, 2] : [3, 1, 2]))
                #expect(try await reopened.episode(id: 1)?.userState == result.episode.userState)
                try await reopened.close()
            } catch { try? await reopened.close(); throw error }
        } catch { try? await store.close(); throw error }
    }
}
