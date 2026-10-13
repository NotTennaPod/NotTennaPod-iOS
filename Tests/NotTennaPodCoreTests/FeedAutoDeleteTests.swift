import Foundation
import Testing
@testable import NotTennaPodCore

@Suite struct FeedAutoDeleteTests {
    @Test func sourceCodesDefaultsAndLocalGlobalGate() throws {
        #expect(FeedAutoDelete.allCases.map(\.rawValue) == [0, 1, 2])
        let feed = LibraryFeed(id: 1, source: "fixture", metadata: .init(format: .rss), episodes: [])
        let old = try JSONEncoder().encode(feed)
        #expect(!String(decoding: old, as: UTF8.self).contains("autoDeleteValue"))
        #expect(try JSONDecoder().decode(LibraryFeed.self, from: old).autoDelete == .global)
        for master in [false, true] {
            for local in [false, true] {
                for localFeed in [false, true] {
                    #expect(FeedAutoDelete.global.enabled(global: master, local: local, isLocalFeed: localFeed)
                        == (master && (!localFeed || local)))
                    #expect(FeedAutoDelete.always.enabled(global: master, local: local, isLocalFeed: localFeed))
                    #expect(!FeedAutoDelete.never.enabled(global: master, local: local, isLocalFeed: localFeed))
                }
            }
        }
    }

    @Test func choicesSurviveRefreshAndDatabaseReopenWithoutChangingEpisodes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("db")
        let store = try FeedLibraryStore(url: url)
        let input = FetchedFeed(feed: .init(format: .rss, title: "Feed", episodes: [
            .init(identifier: "one", title: "One", media: .init(url: "https://example.test/one.mp3", size: 0))
        ]), source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil)
        let feed = try await store.insert(input)
        for value in FeedAutoDelete.allCases {
            try await store.updatePreferences(feedID: feed.id) { $0.autoDelete = value; $0.tags = ["retained"] }
            _ = try await store.applyRefresh(input, feedID: feed.id)
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.feed(id: feed.id)?.autoDelete == value)
            #expect(try await reopened.feed(id: feed.id)?.episodes == feed.episodes)
            #expect(try await reopened.feed(id: feed.id)?.tags == ["retained"])
            try await reopened.close()
        }
        try await store.close()
    }

    private func withLocalEpisode(_ body: (FeedLibraryStore, URL, URL, LibraryFeed, LibraryEpisode) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("episodes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = folder.appendingPathComponent("one.mp3")
        let fixture = try #require(Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: fixture, to: file)
        let store = try FeedLibraryStore(url: root.appendingPathComponent("db"))
        let bookmark = try LocalFolderDocuments.makeBookmark(directory: folder)
        let context = try await store.registerLocalFolder(title: "Local", directoryIdentity: folder.absoluteString, bookmark: bookmark)
        let result = try await LocalFeedRefreshService(store: store).refresh(feedID: context.feed.id, description: "Local description", author: "Folder")
        guard case .updated(let updated) = result else { Issue.record("Valid local fixture did not scan"); return }
        let episode = try #require(updated.feed.episodes.first)
        try await body(store, root, file, updated.feed, episode)
        try await store.close()
    }

    @Test func localCompletionDeletesThroughBookmarkAndRefreshesAwayEpisode() async throws {
        try await withLocalEpisode { store, _, file, feed, episode in
            let session = try await store.beginPlayback(episodeID: episode.id)
            var preferences = PlaybackEndPreferences(); preferences.autoDelete = true
            _ = try await store.endPlayback(sessionID: session.id, reason: .ended, preferences: preferences)
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(try await store.pendingEffects().contains { if case .deleteLocalMedia = $0.effect.kind { true } else { false } })
            try await MediaDownloadWorker(store: store).cleanCancelledFiles()
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(try await store.episode(id: episode.id) == nil)
            #expect(try await store.feed(id: feed.id)?.episodes.isEmpty == true)
            #expect(try await store.queue().isEmpty)
            #expect(try await store.pendingEffects().allSatisfy {
                switch $0.effect.kind { case .deleteLocalMedia, .refreshAfterLocalMediaDeletion, .downloadFileDeleted: false; default: true }
            })
        }
    }

    @Test func localDeletionFailureSurvivesReopenAndRetriesWithoutDeletingDirectory() async throws {
        try await withLocalEpisode { store, root, file, _, episode in
            let session = try await store.beginPlayback(episodeID: episode.id)
            var preferences = PlaybackEndPreferences(); preferences.autoDelete = true
            _ = try await store.endPlayback(sessionID: session.id, reason: .ended, preferences: preferences)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            let child = file.appendingPathComponent("keep")
            try Data([1]).write(to: child)
            let pending = try await store.pendingEffects()
            await #expect(throws: (any Error).self) { try await MediaDownloadWorker(store: store).cleanCancelledFiles() }
            #expect(try Data(contentsOf: child) == Data([1]))
            #expect(try await store.pendingEffects() == pending)
            try FileManager.default.removeItem(at: child); try FileManager.default.removeItem(at: file)
            let reopened = try FeedLibraryStore(url: root.appendingPathComponent("db"))
            try await MediaDownloadWorker(store: reopened).cleanCancelledFiles()
            #expect(try await reopened.episode(id: episode.id) == nil)
            try await reopened.close()
        }
    }

    @Test func refreshRetryDoesNotRepeatSuccessfulLocalDeletion() async throws {
        try await withLocalEpisode { store, root, file, feed, episode in
            let session = try await store.beginPlayback(episodeID: episode.id)
            var preferences = PlaybackEndPreferences(); preferences.autoDelete = true
            _ = try await store.endPlayback(sessionID: session.id, reason: .ended, preferences: preferences)
            let pending = try #require(try await store.pendingEffects().first { if case .deleteLocalMedia = $0.effect.kind { true } else { false } })
            let folder = try #require(try await store.localFolder(feedID: feed.id))
            let documents = LocalFolderDocuments(bookmark: folder.bookmark)
            _ = try await documents.delete(fileNamed: file.lastPathComponent)
            try await store.completeLocalMediaDeletion(effectID: pending.id, refreshedBookmark: documents.bookmark)
            // Provider deletion succeeded, but the app stopped before refreshing.
            // A newly added same-named file must survive that refresh retry.
            let fixture = try #require(Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures"))
            try FileManager.default.copyItem(at: fixture, to: file)
            let reopened = try FeedLibraryStore(url: root.appendingPathComponent("db"))
            try await MediaDownloadWorker(store: reopened).cleanCancelledFiles()
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(try await reopened.feed(id: feed.id)?.episodes.count == 1)
            #expect(try await reopened.pendingEffects().allSatisfy { $0.id != pending.id })
            try await reopened.close()
        }
    }

    @Test func reconnectDoesNotRedirectPendingDeletionIntoNewFolder() async throws {
        try await withLocalEpisode { store, root, file, feed, episode in
            let session = try await store.beginPlayback(episodeID: episode.id)
            var preferences = PlaybackEndPreferences(); preferences.autoDelete = true
            _ = try await store.endPlayback(sessionID: session.id, reason: .ended, preferences: preferences)
            let replacement = root.appendingPathComponent("replacement")
            try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
            let replacementFile = replacement.appendingPathComponent(file.lastPathComponent)
            try FileManager.default.copyItem(at: file, to: replacementFile)
            _ = try await store.reconnectLocalFolder(feedID: feed.id, directoryIdentity: replacement.absoluteString,
                bookmark: LocalFolderDocuments.makeBookmark(directory: replacement))
            try await MediaDownloadWorker(store: store).cleanCancelledFiles()
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(FileManager.default.fileExists(atPath: replacementFile.path))
            #expect(try await store.pendingEffects().allSatisfy { if case .deleteLocalMedia = $0.effect.kind { false } else { true } })
        }
    }
}
