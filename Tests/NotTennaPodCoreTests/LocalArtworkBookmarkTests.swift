import CryptoKit
import Foundation
import Testing
@testable import NotTennaPodCore

struct LocalArtworkBookmarkTests {
    private let image = "document:cover.png"

    private func fixture(_ body: (FeedLibraryStore, URL, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtworkBookmark-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: database)
        do { try await body(store, database, root); try await store.close() }
        catch { try? await store.close(); throw error }
    }

    /// Synthetic bytes test database ordering only; real native grants are tested below.
    private func seed(_ store: FeedLibraryStore) async throws {
        let initial = try await store.registerLocalFolder(title: "Local", directoryIdentity: "folder", bookmark: Data([1]))
        let snapshot = ParsedFeed(format: .rss, title: "Local", imageURL: image, episodes: [
            ParsedEpisode(identifier: "one", link: "one.ogg", media: ParsedMedia(url: "document:one.ogg", size: 42))
        ])
        _ = try await store.applyLocalFolderScan(snapshot, context: initial, artworkFilename: "cover.png")
        try await store.updateEpisode(id: 1) { $0.userState.isFavorite = true; $0.userState.positionMilliseconds = 4321 }
    }

    @Test(arguments: [false, true])
    func artworkRenewalDoesNotSupersedeScanAndScanCannotRestoreOldBytes(fails: Bool) async throws {
        try await fixture { store, database, _ in
            try await seed(store)
            let context = try await store.beginLocalFolderScan(feedID: 1)
            let reference = try #require(try await store.localDocument(episodeID: 1))
            #expect(try await store.recordLocalArtwork(episodeID: 1, reference: reference, present: true,
                                                       refreshedBookmark: Data([2])))
            #expect(try await store.isCurrentLocalFolderScan(context))
            #expect(try await store.localFolder(feedID: 1)?.generation == context.link.generation)
            if fails {
                #expect(try await store.recordLocalFolderFailure(.init(message: "Provider error"), context: context, date: Date()))
            } else {
                var snapshot = context.feed.metadata
                snapshot.episodes = context.feed.episodes.map(\.details)
                _ = try await store.applyLocalFolderScan(snapshot, context: context,
                    refreshedBookmark: Data([1]), artworkFilename: "cover.png")
            }
            let current = try #require(try await store.localFolder(feedID: 1))
            #expect(current.bookmark == Data([2]))
            #expect(current.artwork?.filename == "cover.png")
            #expect(current.generation != context.link.generation)
            #expect(try await store.feed(id: 1)?.episodes.first?.userState.positionMilliseconds == 4321)
            #expect(try await store.feed(id: 1)?.episodes.first?.userState.isFavorite == true)
            let reopened = try FeedLibraryStore(url: database)
            #expect(try await reopened.localFolder(feedID: 1) == current)
            try await reopened.close()
        }
    }

    @Test func simultaneousReadersKeepFirstRenewalAndRejectSupersededRegistrations() async throws {
        try await fixture { store, _, _ in
            try await seed(store)
            let observed = try #require(try await store.localFolder(feedID: 1))
            #expect(try await store.recordFolderArtworkRead(feedID: 1, identity: image, observed: observed, refreshedBookmark: Data([2])))
            let episodeReference = try #require(try await store.localDocument(episodeID: 1))
            #expect(try await store.recordFolderArtworkRead(feedID: 1, identity: image, observed: observed, refreshedBookmark: Data([3])))
            #expect(try await store.recordFolderArtworkRead(feedID: 1, identity: image, observed: observed, refreshedBookmark: Data([1])))
            #expect(try await store.localFolder(feedID: 1)?.bookmark == Data([2]))
            // A reader which observed the new grant may renew it again.
            #expect(try await store.recordLocalArtwork(episodeID: 1, reference: episodeReference, present: true,
                                                       refreshedBookmark: Data([4])))
            #expect(try await store.localFolder(feedID: 1)?.bookmark == Data([4]))
            let next = try await store.beginLocalFolderScan(feedID: 1)
            #expect(try await store.recordFolderArtworkRead(feedID: 1, identity: image, observed: observed, refreshedBookmark: Data([9])) == false)
            #expect(try await store.recordLocalArtwork(episodeID: 1, reference: episodeReference, present: false,
                                                       refreshedBookmark: Data([9])) == false)
            let reconnected = try await store.reconnectLocalFolder(feedID: 1, directoryIdentity: "folder", bookmark: Data([5]))
            #expect(reconnected.link.artwork == nil)
            #expect(try await store.recordFolderArtworkRead(feedID: 1, identity: image, observed: next.link, refreshedBookmark: Data([9])) == false)
            #expect(try await store.localFolder(feedID: 1) == reconnected.link)
            #expect(try await store.feed(id: 1)?.episodes.first?.details.media?.hasEmbeddedPicture == true)
        }
    }

    @Test func rejectedOrFailedRenewalRollsBackPresenceAndPreservesGrant() async throws {
        try await fixture { store, database, _ in
            try await seed(store)
            let reference = try #require(try await store.localDocument(episodeID: 1))
            let before = try await store.feed(id: 1)
            await #expect(throws: FeedLibraryError.invalidMutation) {
                try await store.recordLocalArtwork(episodeID: 1, reference: reference, present: true, refreshedBookmark: Data())
            }
            #expect(try await store.feed(id: 1) == before)
            let db = try LibrarySQLite(url: database)
            defer { try? db.close() }
            try db.execute("CREATE TRIGGER fail_renewal BEFORE UPDATE ON local_folder_links BEGIN SELECT RAISE(ABORT, 'renewal failure'); END")
            await #expect(throws: FeedLibraryError.self) {
                try await store.recordLocalArtwork(episodeID: 1, reference: reference, present: true, refreshedBookmark: Data([2]))
            }
            #expect(try await store.feed(id: 1) == before)
            #expect(try await store.localFolder(feedID: 1) == reference.folder)
            try db.execute("DROP TRIGGER fail_renewal")
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await store.recordLocalArtwork(episodeID: 1, reference: reference, present: true, refreshedBookmark: Data([2]))
            }
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            #expect(try await store.feed(id: 1) == before)
            #expect(try await store.localFolder(feedID: 1) == reference.folder)
        }
    }

    @Test func invalidRelativeLocatorCannotChangeScanAndLegacyLinksStillDecode() async throws {
        let legacy = Data(#"{"feedID":1,"directoryIdentity":"folder","bookmark":"AQ==","generation":"11111111-1111-1111-1111-111111111111"}"#.utf8)
        #expect(try JSONDecoder().decode(LocalFolderLink.self, from: legacy).artwork == nil)
        try await fixture { store, _, _ in
            try await seed(store)
            let context = try await store.beginLocalFolderScan(feedID: 1)
            for name in ["", ".", "..", "../cover.png", "a/b.png", "cover\0.png"] {
                await #expect(throws: FeedLibraryError.invalidMutation) {
                    try await store.applyLocalFolderScan(context.feed.metadata, context: context, artworkFilename: name)
                }
            }
            #expect(try await store.isCurrentLocalFolderScan(context))
            #expect(try await store.localFolder(feedID: 1) == context.link)
        }
    }

    @Test(arguments: [false, true])
    func realMovedFolderRetainsSelectedCoverAndEmbeddedImageWithoutRescan(coverFirst: Bool) async throws {
        try await fixture { store, database, root in
            let original = root.appendingPathComponent("Original ü #100%")
            let moved = root.appendingPathComponent("Moved ü #100%")
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
            let media = try #require(Bundle.module.url(forResource: "auphonic.ogg", withExtension: nil, subdirectory: "Fixtures/VorbisDescriptions"))
            try FileManager.default.copyItem(at: media, to: original.appendingPathComponent("episode ü.ogg"))
            let cover = try #require(try LocalMediaMetadataReader.artwork(url: media))
            #expect(SHA256.hash(data: cover).map { String(format: "%02x", $0) }.joined()
                == "efece7e0b38d8f9eadaeb3482b71a581e099ddf9febe614aed0fe5d5043e8634")
            try cover.write(to: original.appendingPathComponent("cover ü #100%.png"))
            let bookmark = try LocalFolderDocuments.makeBookmark(directory: original)
            _ = try await store.registerLocalFolder(title: "Local", directoryIdentity: original.absoluteString, bookmark: bookmark)
            _ = try await LocalFeedRefreshService(store: store).refresh(feedID: 1, description: "Local", author: "Local")
            let before = try #require(try await store.feed(id: 1))
            let image = try #require(before.metadata.imageURL)
            let episode = try #require(before.episodes.first)
            let grant = try #require(try await store.localFolder(feedID: 1))
            #expect(grant.artwork?.filename == "cover ü #100%.png")
            try FileManager.default.moveItem(at: original, to: moved)
            let folderReader = LocalFolderArtworkReader(store: store)
            let episodeReader = LocalEpisodeArtworkReader(store: store)
            if coverFirst {
                #expect(try await folderReader.read(feedID: 1, identity: image) == cover)
            } else { #expect(try await episodeReader.read(episode: episode) == cover) }
            let renewed = try #require(try await store.localFolder(feedID: 1))
            #expect(renewed.bookmark != grant.bookmark)
            #expect(renewed.generation == grant.generation && renewed.artwork == grant.artwork)
            #expect(try await store.feed(id: 1) == before)
            #expect(try await folderReader.read(feedID: 1, identity: image) == cover)
            #expect(try await episodeReader.read(episode: episode) == cover)
            let reopened = try FeedLibraryStore(url: database)
            #expect(try await reopened.localFolder(feedID: 1)?.bookmark == renewed.bookmark)
            #expect(try await LocalFolderArtworkReader(store: reopened).read(feedID: 1, identity: image) == cover)
            #expect(try await LocalEpisodeArtworkReader(store: reopened).read(episode: episode) == cover)
            try await reopened.close()
        }
    }
}
