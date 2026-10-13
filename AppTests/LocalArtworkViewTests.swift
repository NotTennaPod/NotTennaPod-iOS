import UIKit
import CryptoKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

private final class LocalArtworkTestBundle: NSObject {}

@MainActor
struct LocalArtworkViewTests {
    private func image(in view: UIView) -> UIImage? {
        // Ignore action/status icons elsewhere in the row/header while loading.
        if view is EpisodeArtworkView { return view.subviews.compactMap { ($0 as? UIImageView)?.image }.first }
        return view.subviews.lazy.compactMap { image(in: $0) }.first
    }

    private func waitForImage(in view: UIView) async throws -> UIImage {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let result = image(in: view) { return result }
            try await Task.sleep(for: .milliseconds(5))
        }
        return try #require(image(in: view))
    }

    @Test(arguments: [false, true])
    func actualFolderPNGReopensAndAppearsInDrawerRowAndHeader(moved: Bool) async throws {
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 3, height: 2)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
            UIColor.blue.setFill(); context.fill(CGRect(x: 1, y: 0, width: 1, height: 2))
        }
        let bytes = try #require(picture.pngData())
        let expected = try #require(UIImage(data: bytes)?.pngData())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderArtworkView-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Folder ü #1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bytes.write(to: folder.appendingPathComponent("Folder.png"))
        let url = root.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        _ = try await store.registerLocalFolder(title: "Folder", directoryIdentity: "folder",
            bookmark: LocalFolderDocuments.makeBookmark(directory: folder))
        _ = try await LocalFeedRefreshService(store: store).refresh(feedID: 1, description: "Local", author: "Local")
        let originalGrant = try #require(try await store.localFolder(feedID: 1))
        try await store.close()
        if moved { try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("Moved folder")) }
        let reopened = try FeedLibraryStore(url: url)
        let feed = try #require(try await reopened.feed(id: 1))
        let episode = LibraryEpisode(id: 7, details: ParsedEpisode(title: "No media"))
        let header = EpisodeHeaderView(feed: feed, episode: episode, library: reopened)
        let row = EpisodeRowView(feed: feed, episode: episode, queued: false, queueScreen: false,
            showRemainingTime: false, activelyPlaying: false, library: reopened, downloadAction: {}, open: {})
        let drawer = NavigationDrawerView(frame: .zero)
        drawer.update(items: [], subscriptionItems: [.init(action: .feed(feed.id), title: "Folder", image: nil,
            artwork: feed.metadata.imageURL, identifier: "folder")], showSeparator: false, library: reopened)
        for view in [header, row, drawer] as [UIView] {
            #expect(try await waitForImage(in: view).pngData() == expected)
        }
        let currentGrant = try #require(try await reopened.localFolder(feedID: 1))
        #expect(currentGrant.generation == originalGrant.generation)
        if moved { #expect(currentGrant.bookmark != originalGrant.bookmark) }
        try await reopened.close()
    }

    @Test(arguments: [false, true])
    func actualVorbisArtworkReopensAndReachesRowAndHeaderOnIOS(moved: Bool) async throws {
        let bundle = Bundle(for: LocalArtworkTestBundle.self)
        let source = try #require(bundle.url(forResource: "auphonic", withExtension: "ogg"))
        let bytes = try Data(contentsOf: source)
        #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            == "33409b2885d4f75c13cd5ad504d8c6f518cd447418041733eadff4ff61c10856")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtworkView-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bytes.write(to: folder.appendingPathComponent("auphonic.ogg"))
        let url = root.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let bookmark = try LocalFolderDocuments.makeBookmark(directory: folder)
        _ = try await store.registerLocalFolder(title: "Local", directoryIdentity: "folder", bookmark: bookmark)
        _ = try await LocalFeedRefreshService(store: store).refresh(feedID: 1, description: "Local", author: "Local")
        let originalGrant = try #require(try await store.localFolder(feedID: 1))
        try await store.close()
        if moved { try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("Moved media")) }
        let reopened = try FeedLibraryStore(url: url)
        let episodeID = try #require(try await reopened.feed(id: 1)?.episodes.first?.id)
        try await reopened.updateEpisode(id: episodeID) { $0.details.media?.hasEmbeddedPicture = nil }
        let feed = try #require(try await reopened.feed(id: 1))
        let episode = try #require(feed.episodes.first)
        #expect(episode.details.media?.hasEmbeddedPicture == nil)
        let picture = try #require(try await EpisodeArtworkReader.readOwnedFile(source))
        #expect(SHA256.hash(data: picture).map { String(format: "%02x", $0) }.joined()
            == "efece7e0b38d8f9eadaeb3482b71a581e099ddf9febe614aed0fe5d5043e8634")
        let expected = try #require(UIImage(data: picture)?.pngData())
        let header = EpisodeHeaderView(feed: feed, episode: episode, library: reopened)
        let row = EpisodeRowView(feed: feed, episode: episode, queued: false, queueScreen: false,
            showRemainingTime: false, activelyPlaying: false, library: reopened, downloadAction: {}, open: {})
        #expect(try await waitForImage(in: header).pngData() == expected)
        #expect(try await waitForImage(in: row).pngData() == expected)
        #expect(try await reopened.episode(id: episodeID)?.details.media?.hasEmbeddedPicture == true)
        let currentGrant = try #require(try await reopened.localFolder(feedID: 1))
        #expect(currentGrant.generation == originalGrant.generation)
        if moved { #expect(currentGrant.bookmark != originalGrant.bookmark) }
        try await reopened.close()
    }

    @Test func embeddedPresenceAndFileSizeRefreshCoverWithoutMovingItsControl() throws {
        let media = ParsedMedia(url: "file:///one.ogg", size: 1, hasEmbeddedPicture: false)
        var episode = LibraryEpisode(id: 1, details: ParsedEpisode(media: media))
        let feed = LibraryFeed(id: 1, source: "antennapod_local:folder", metadata: ParsedFeed(format: .rss), episodes: [episode])
        let header = EpisodeHeaderView(feed: feed, episode: episode)
        let button = try #require(header.subviews.first { $0.accessibilityIdentifier == "episodeCover" })
        var cover = try #require(header.subviews.first { $0 is EpisodeArtworkView })
        for size in [1, 2] as [Int64] {
            episode.details.media?.hasEmbeddedPicture = true
            episode.details.media?.size = size
            header.update(feed: feed, episode: episode)
            let replacement = try #require(header.subviews.first { $0 is EpisodeArtworkView })
            #expect(replacement !== cover)
            #expect(header.subviews.first { $0.accessibilityIdentifier == "episodeCover" } === button)
            cover = replacement
        }
    }

    /// The cover disk cache keeps at most the limit, dropping least recently used covers first.
    @Test func viewsShowingTheSameWebCoverShareOneLoadAndAMissingCoverIsNotAskedAgain() async throws {
        let source = "https://example.invalid/shared-\(UUID()).png", missing = "https://example.invalid/missing-\(UUID()).png"
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.pngData())
        var requests: [String] = []
        var released = false
        let previous = EpisodeArtworkView.remoteLoader
        defer { EpisodeArtworkView.remoteLoader = previous }
        EpisodeArtworkView.remoteLoader = { url in
            requests.append(url.absoluteString)
            if url.absoluteString == missing { return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!) }
            while !released { try await Task.sleep(for: .milliseconds(5)) }
            return (png, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        // A podcast page of one show: every row shows the same cover.
        let views = (0..<12).map { _ in EpisodeArtworkView(source: source, fallback: nil, title: "Show") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while requests.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        for _ in 0..<20 { await Task.yield() }
        #expect(requests == [source])
        released = true
        for view in views { _ = try await waitForImage(in: view) }
        #expect(requests == [source])
        // A cover that is missing on the server falls back at once next time, without asking again.
        for _ in 0..<2 {
            let view = EpisodeArtworkView(source: missing, fallback: source, title: "Show")
            _ = try await waitForImage(in: view)
        }
        #expect(requests.filter { $0 == missing }.count == 1)
        #expect(ArtworkImageCache.loadsInFlight == 0)
    }

    @Test func coverViewsHaveNoBitmapOfTheirOwnAndGeneratedCoversStillShow() async throws {
        let view = EpisodeArtworkView(source: "antennapod_generative_cover:https://example.org/\(UUID())", fallback: nil, title: "Generated")
        view.frame = CGRect(x: 0, y: 0, width: 56, height: 56)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while image(in: view) == nil, ContinuousClock.now < deadline {
            view.setNeedsLayout(); view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(5))
        }
        let shown = try #require(image(in: view))
        #expect(shown.size == CGSize(width: 56, height: 56))
        // The same picture the header blur and lock screen use.
        let rendered = try #require(view.artwork(size: CGSize(width: 56, height: 56), scale: shown.scale))
        #expect(shown.pngData() == rendered.pngData())
        view.frame.size = CGSize(width: 100, height: 100); view.layoutIfNeeded()
        #expect(image(in: view)?.size == CGSize(width: 100, height: 100))
        #expect(view.layer.contents == nil)
    }

    @Test func coverDiskCacheTrimsLeastRecentlyUsedToTheLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArtworkTrim-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        for index in 0..<10 {
            let file = directory.appendingPathComponent("cover-\(index).jpg")
            try Data(repeating: UInt8(index), count: 1_000).write(to: file)
            // cover-0 is the most recently used, cover-9 the least.
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(Double(-index * 60))], ofItemAtPath: file.path)
        }
        ArtworkImageCache.trimDisk(directory: directory, limit: 10_000)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 10)
        ArtworkImageCache.trimDisk(directory: directory, limit: 6_500)
        let kept = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(kept == (0..<6).map { "cover-\($0).jpg" })
        #expect(ArtworkImageCache.diskLimit == 250 * 1024 * 1024)
    }
}
