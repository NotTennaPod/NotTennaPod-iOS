import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

struct LocalEpisodeArtworkTests {
    @Test func originalSelectionCasesAndStalePresenceDefectAreRetained() throws {
        struct Oracle: Decodable {
            struct Case: Decodable {
                let episodeImage, localMedia, feedImage, expected: String?
                let mediaPresent, embedded, feedPresent: Bool
            }
            let cases: [Case]
            let stalePresence: [String]
        }
        let url = try #require(Bundle.module.url(forResource: "episode-artwork-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        #expect(oracle.cases.count == 216)
        for row in oracle.cases {
            #expect(EpisodeArtworkSelection.source(episodeImage: row.episodeImage,
                hasEmbeddedPicture: row.mediaPresent && row.embedded, localMedia: row.localMedia,
                feedImage: row.feedPresent ? row.feedImage : nil) == row.expected)
        }
        #expect(oracle.stalePresence == ["DEFECT:false:true:false:2", "DEFECT:true:false:true:2"])
        for old in [false, true] {
            var episode = LibraryEpisode(id: 1, details: ParsedEpisode(media: ParsedMedia(size: 1, hasEmbeddedPicture: old)))
            episode.update(from: ParsedEpisode(media: ParsedMedia(size: 2, hasEmbeddedPicture: !old)))
            #expect(episode.details.media?.hasEmbeddedPicture == !old)
            // Remote feed refreshes and uninspected metadata must not clear it.
            episode.update(from: ParsedEpisode(media: ParsedMedia(size: 2)))
            #expect(episode.details.media?.hasEmbeddedPicture == !old)
        }
    }

    /// Episodes saved before artwork inspection read as uninspected, so their artwork is looked up again.
    /// Persistence of a known flag is covered by EpisodeArtworkReaderTests (reopen).
    @Test func legacyMediaJSONDecodesAsUninspected() throws {
        let legacy = Data(#"{"url":"https://example/episode.mp3","size":123,"durationMilliseconds":2000}"#.utf8)
        #expect(try JSONDecoder().decode(ParsedMedia.self, from: legacy).hasEmbeddedPicture == nil)
    }

    @Test func cachedAndRescannedArtworkRetainIdentityAndListeningState() async throws {
        for flag in [false, true] {
            let media = ParsedMedia(url: "document:one", size: 10, hasEmbeddedPicture: flag)
            var old = LibraryEpisode(id: 7, details: ParsedEpisode(identifier: "original", link: "one.mp3", media: media))
            old.userState.isFavorite = true; old.userState.positionMilliseconds = 1234
            let saved = LibraryFeed(id: 1, source: "antennapod_local:folder", metadata: ParsedFeed(format: .rss), episodes: [old])
            func scan(name: String, size: Int64, metadata: @escaping @Sendable (LocalFeedFile) async throws -> LocalFileMetadata) async throws -> ParsedFeed {
                try await LocalFeedScanner.scan(files: [LocalFeedFile(name: name, identity: "document:one",
                    providerMIMEType: "audio/mpeg", mediaMIMEType: "audio/mpeg", size: size, modified: Date())],
                    saved: saved, folderIdentity: "folder", description: "Local", author: "Local", readMetadata: metadata)
            }
            let cached = try await scan(name: "one.mp3", size: 10) { _ in Issue.record("Cached file was reread"); return .init() }
            #expect(cached.episodes.first?.media?.hasEmbeddedPicture == flag)
            let renamed = try await scan(name: "renamed.mp3", size: 10) { _ in Issue.record("Cached rename was reread"); return .init() }
            #expect(renamed.episodes.first?.media?.hasEmbeddedPicture == flag)
            let changed = try await scan(name: "one.mp3", size: 20) { _ in .init(embeddedArtwork: flag ? nil : Data([1])) }
            var options = FeedRefreshOptions(); options.isLocalFeed = true
            let merged = FeedRefreshMerger.merge(changed, into: saved, options: options, allocateEpisodeID: { 20 })
            #expect(merged.feed.episodes.first?.details.media?.hasEmbeddedPicture == !flag)
            #expect(merged.feed.episodes.first?.userState == old.userState)
        }
    }

    @Test(arguments: ["reconnect", "cancel", "replace"])
    func obsoleteOrCancelledReadsCannotDeliverArtwork(change: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtworkRace-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2]).write(to: folder.appendingPathComponent("one.mp3"))
        let bookmark = try LocalFolderDocuments.makeBookmark(directory: folder)
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        _ = try await store.registerLocalFolder(title: "Local", directoryIdentity: "folder", bookmark: bookmark)
        let service = LocalFeedRefreshService(store: store, open: { link in
            try await LocalFolderDocuments(bookmark: link.bookmark).scanInput { _, _ in .init(embeddedArtwork: Data([3])) }
        })
        _ = try await service.refresh(feedID: 1, description: "Local", author: "Local")
        let episode = try #require(try await store.feed(id: 1)?.episodes.first)
        let started = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let reader = LocalEpisodeArtworkReader(store: store, readImage: { _, check in
            started.withLock { $0 = true }
            guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileReadUnknown) }
            try check()
            return Data([3])
        })
        let pending = Task { try await reader.read(episode: episode) }
        for _ in 0..<1000 {
            if started.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(started.withLock { $0 })
        if change == "reconnect" {
            _ = try await store.reconnectLocalFolder(feedID: 1, directoryIdentity: "folder", bookmark: bookmark)
        } else if change == "replace" {
            try await store.updateEpisode(id: episode.id) { $0.details.media?.size = 99 }
        } else { pending.cancel() }
        release.signal()
        if change == "cancel" {
            await #expect(throws: CancellationError.self) { try await pending.value }
        } else { #expect(try await pending.value == nil) }
        // A stale view snapshot cannot start a read for replacement media.
        if change == "replace" { #expect(try await reader.read(episode: episode) == nil) }
        try await store.close()
    }
}
