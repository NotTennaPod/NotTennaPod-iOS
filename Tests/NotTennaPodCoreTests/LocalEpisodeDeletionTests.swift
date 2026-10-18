import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite struct LocalEpisodeDeletionTests {
    private final class Engine: PlaybackEngine {
        var reading: PlaybackEngineReading?
        var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
        var unloads = 0
        func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {}
        func play(commandID: UUID) {}
        func pause(commandID: UUID) {}
        func seek(to positionMilliseconds: Int64, commandID: UUID) {}
        func setSpeed(_ speed: Float, commandID: UUID) throws {}
        func unload() { unloads += 1 }
    }
    @Test func confirmedLocalDeletionRemovesOnlyDocumentRefreshesAndRetiresPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), folder = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = folder.appendingPathComponent("episode.mp3"), second = folder.appendingPathComponent("keep.mp3")
        try Data([1, 2, 3]).write(to: first); try Data([4, 5]).write(to: second)
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let bookmark = try LocalFolderDocuments.makeBookmark(directory: folder)
        let context = try await store.registerLocalFolder(title: "Local", directoryIdentity: folder.absoluteString, bookmark: bookmark)
        let result = try await store.applyLocalFolderScan(.init(format: .rss, episodes: [first, second].enumerated().map { index, url in
            .init(identifier: String(index), title: url.lastPathComponent, link: url.lastPathComponent,
                  media: .init(url: url.absoluteString, size: index == 0 ? 3 : 2, mimeType: "audio/mpeg"))
        }), context: context)
        let id = result.feed.episodes[0].id, keep = result.feed.episodes[1].id
        _ = try await store.enqueue([id, keep])
        let engine = Engine()
        let active = PlaybackCoordinator(store: store, engine: engine)
        try await active.select(episodeID: id, play: false)
        let before = try await store.pendingEffects()
        let local = LocalFolderCoordinator(store: store, description: "Local", author: "AntennaPod")
        try await local.deleteMedia(episodeID: id, playback: active, removeFromQueue: false)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(try Data(contentsOf: second) == Data([4, 5]))
        #expect(try await store.episode(id: id) == nil)
        #expect(try await store.feed(id: context.feed.id)?.episodes.map(\.id) == [keep])
        #expect(active.episode == nil && active.phase == .idle && engine.unloads > 0)
        #expect(try await store.playbackSession() == nil)
        #expect(try await store.pendingEffects().filter { effect in
            if case .episodeStateChanged = effect.effect.kind { return true }; return false
        } == before.filter { if case .episodeStateChanged = $0.effect.kind { return true }; return false })
        try await store.close()
    }
    @Test func oldFolderRegistrationCannotRetireReconnectedEpisodeState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let context = try await store.registerLocalFolder(title: "Local", directoryIdentity: "old", bookmark: Data([1]))
        let result = try await store.applyLocalFolderScan(.init(format: .rss, episodes: [.init(identifier: "one", link: "one.mp3", media: .init(url: "file:///old/one.mp3", size: 1))]), context: context)
        let id = result.feed.episodes[0].id, reference = try #require(try await store.localDocument(episodeID: result.feed.episodes[0].id))
        _ = try await store.reconnectLocalFolder(feedID: context.feed.id, directoryIdentity: "new", bookmark: Data([2]))
        let before = try await store.episode(id: id)
        await #expect(throws: FeedLibraryError.invalidMutation) { try await store.recordLocalMediaDeletion(episodeID: id, reference: reference, removeFromQueue: true) }
        #expect(try await store.episode(id: id) == before)
        try await store.close()
    }
}
