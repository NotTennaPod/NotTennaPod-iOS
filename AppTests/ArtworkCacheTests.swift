import UIKit
import CryptoKit
import Synchronization
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Covers are downloaded once per picture, whatever sizes the screens and notifications ask for, and a very large
/// picture waits for Wi-Fi on a restricted network. The network is the app's own (`MobileImageAccess` through the
/// proxy client, a direct connection here) against a local server that counts what it serves.
@MainActor @Suite(.serialized)
struct ArtworkCacheTests {
    /// Serves pictures by path, counting requests and bytes; `hold` keeps the first request for a path unanswered.
    final class Pictures: @unchecked Sendable {
        /// What the server has answered: bytes per path, and the paths whose first request it holds.
        final class Ledger: @unchecked Sendable {
            private let lock = NSLock()
            private var bytes: [String: Int] = [:]
            private var held: Set<String>
            init(held: Set<String>) { self.held = held }
            func take(_ path: String) -> Bool { lock.withLock { held.remove(path) != nil } }
            func add(_ path: String, _ count: Int) { lock.withLock { bytes[path, default: 0] += count } }
            var total: Int { lock.withLock { bytes.values.reduce(0, +) } }
        }
        let server: LoopbackHTTPServer
        private let ledger: Ledger
        init(_ pictures: [String: Data], hold: Set<String> = []) async throws {
            let ledger = Ledger(held: hold)
            self.ledger = ledger
            server = try await LoopbackHTTPServer.start { request in
                let path = request.path
                guard let body = pictures[path] else { return .init(status: 404, body: Data()) }
                if ledger.take(path) { return nil }
                ledger.add(path, body.count)
                return .init(headers: ["Content-Type": "image/jpeg"], body: body)
            }
        }
        func url(_ path: String) -> String { "http://127.0.0.1:\(server.url.port!)\(path)" }
        func requests(_ path: String) -> Int { server.requests.filter { $0.path == path }.count }
        var totalRequests: Int { server.requests.count }
        var totalBytes: Int { ledger.total }
        func release(_ path: String, _ body: Data) throws {
            ledger.add(path, body.count)
            try server.respond(toPath: path, with: .init(headers: ["Content-Type": "image/jpeg"], body: body))
        }
        deinit { server.stop() }
    }

    /// The app's picture network on a controllable connection (Wi-Fi unless changed).
    private func withNetwork(_ body: (DownloadNetworkMonitor) async throws -> Void) async throws {
        try await withNetworkAndPreferences { network, _ in try await body(network) }
    }
    private func withNetworkAndPreferences(_ body: (DownloadNetworkMonitor, MobileNetworkPreferenceStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArtworkCache-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = try MobileNetworkPreferenceStore(file: directory.appendingPathComponent("mobile.json"))
        try preferences.setAllowed(.images, true)
        let network = DownloadNetworkMonitor(startMonitoring: false)
        network.update(.init(connected: true, metered: false, cellular: false, transport: .wifi))
        let environment = ProxyNetworkEnvironment(configuration: .init())
        let access = MobileImageAccess(preferences: preferences, network: network,
            proxyConfiguration: { environment.newClientConfiguration() }, cache: URLCache(memoryCapacity: 0, diskCapacity: 0))
        let previous = (EpisodeArtworkView.remoteLoader, ArtworkImageCache.fetchAllowance, ArtworkImageCache.unrestrictedNetwork)
        EpisodeArtworkView.remoteLoader = { try await access.load($0) }
        ArtworkImageCache.fetchAllowance = { try await access.fetchAllowance() }
        ArtworkImageCache.unrestrictedNetwork = { try await access.waitUntilUnrestricted() }
        defer { (EpisodeArtworkView.remoteLoader, ArtworkImageCache.fetchAllowance, ArtworkImageCache.unrestrictedNetwork) = previous }
        try await body(network, preferences)
    }

    /// Noise in blocks of `block` pixels, so a picture's file size grows with its pixel size as photos do.
    private static func noise(side: Int, block: Int, alpha: Bool, seed: UInt32) -> UIImage {
        var state = seed &* 2_654_435_761 | 1
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for y in stride(from: 0, to: side, by: block) {
            for x in stride(from: 0, to: side, by: block) {
                state ^= state << 13; state ^= state >> 17; state ^= state << 5
                for row in y..<min(side, y + block) {
                    for column in x..<min(side, x + block) {
                        let index = (row * side + column) * 4
                        pixels[index] = UInt8(state & 255); pixels[index + 1] = UInt8((state >> 8) & 255)
                        pixels[index + 2] = UInt8((state >> 16) & 255)
                        if alpha { pixels[index + 3] = UInt8((state >> 24) & 255) }
                    }
                }
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.last : .noneSkipLast).rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return UIImage(cgImage: image)
    }
    /// A photo-like JPEG cover.
    private static func photo(side: Int, seed: UInt32) -> Data {
        noise(side: side, block: 6, alpha: false, seed: seed).jpegData(compressionQuality: 0.9)!
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    private func withStore(_ body: (FeedLibraryStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArtworkCacheStore-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        do { try await body(store); try await store.close() } catch { try? await store.close(); throw error }
    }

    /// A synthetic library's covers shown in a list, in the player and in a new-episode notification: each picture
    /// is downloaded once. The bytes are reported for comparison.
    @Test func libraryCoversAtListPlayerAndNotificationSizesDownloadEachPictureOnce() async throws {
        let run = UUID().uuidString
        var library: [String: Data] = [:]
        for (index, side) in ([600, 600] + Array(repeating: 1400, count: 8) + Array(repeating: 3000, count: 6)).enumerated() {
            library["/\(run)/cover-\(index).jpg"] = Self.photo(side: side, seed: UInt32(index + 1))
        }
        let pictures = try await Pictures(library)
        try await withNetwork { _ in
            try await withStore { store in
                for path in library.keys.sorted() {
                    #expect(await ArtworkImageCache.remoteImage(pictures.url(path), maxPixels: 400) != nil)
                }
                let listBytes = pictures.totalBytes
                for path in library.keys.sorted() {
                    #expect(await ArtworkImageCache.remoteImage(pictures.url(path), maxPixels: 1200) != nil)
                }
                let playerBytes = pictures.totalBytes - listBytes
                for path in library.keys.sorted() {
                    let data = try await NewEpisodeNotificationContent.artwork(.init(feedID: 1, title: "Show", imageURL: pictures.url(path), count: 1), store: store)
                    #expect(data != nil)
                }
                let notificationBytes = pictures.totalBytes - listBytes - playerBytes
                let originals = library.values.reduce(0) { $0 + $1.count }
                print("ArtworkCacheBytes covers=\(library.count) originals=\(originals) list=\(listBytes) player=\(playerBytes) notification=\(notificationBytes) total=\(pictures.totalBytes) requests=\(pictures.totalRequests)")
                #expect(pictures.totalRequests == library.count)
                #expect(pictures.totalBytes == originals)
            }
        }
    }

    /// A list row and the player asking for the same picture at the same time share one download.
    @Test func differentSizesAtTheSameTimeShareOneDownload() async throws {
        let path = "/\(UUID())/shared.jpg", body = Self.photo(side: 1400, seed: 7)
        let pictures = try await Pictures([path: body], hold: [path])
        try await withNetwork { _ in
            let row = Task { await ArtworkImageCache.remoteImage(pictures.url(path), maxPixels: 400) }
            try await waitUntil { pictures.requests(path) == 1 }
            let player = Task { await ArtworkImageCache.remoteImage(pictures.url(path), maxPixels: 1200) }
            for _ in 0..<50 { await Task.yield() }
            try pictures.release(path, body)
            #expect(await row.value != nil)
            #expect(await player.value != nil)
            #expect(pictures.requests(path) == 1)
        }
    }

    /// The player opened right after a row showed the cover finds it on the phone; old per-size files are still read
    /// and no new ones are written.
    @Test func aSecondSizeRightAfterTheFirstNeedsNoDownloadAndOldFilesAreReadNotWritten() async throws {
        let path = "/\(UUID())/sequential.jpg"
        let pictures = try await Pictures([path: Self.photo(side: 1400, seed: 9)])
        let directory = try #require(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
            .appendingPathComponent("Artwork", isDirectory: true)
        func digest(_ source: String) -> String { SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined() }
        try await withNetwork { _ in
            #expect(await ArtworkImageCache.remoteImage(pictures.url(path), maxPixels: 400) != nil)
            #expect(await ArtworkImageCache.remoteImage(pictures.url(path), maxPixels: 1200) != nil)
            #expect(pictures.requests(path) == 1)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(digest(pictures.url(path))) }
            #expect(!names.contains { $0.hasSuffix("-400.jpg") || $0.hasSuffix("-1200.jpg") }, "\(names)")
            // A cover saved by an earlier version, at the size asked for.
            let legacy = "https://example.invalid/\(UUID()).jpg"
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.photo(side: 400, seed: 3).write(to: directory.appendingPathComponent("\(digest(legacy))-400.jpg"))
            let before = pictures.totalRequests
            #expect(await ArtworkImageCache.remoteImage(legacy, maxPixels: 400) != nil)
            #expect(pictures.totalRequests == before)
        }
    }

    /// A list row rebuilt while its cover downloads joins the download instead of starting it again.
    @Test func rowRebuiltDuringADownloadKeepsTheTransfer() async throws {
        let path = "/\(UUID())/rebuilt.jpg", body = Self.photo(side: 1400, seed: 11)
        let pictures = try await Pictures([path: body], hold: [path])
        try await withNetwork { _ in
            var old: EpisodeArtworkView? = EpisodeArtworkView(source: pictures.url(path), fallback: nil, title: "Show")
            try await waitUntil { pictures.requests(path) == 1 }
            old?.cancelLoading(); old = nil
            for _ in 0..<50 { await Task.yield() }
            let rebuilt = EpisodeArtworkView(source: pictures.url(path), fallback: nil, title: "Show")
            for _ in 0..<50 { await Task.yield() }
            try? pictures.release(path, body)
            try await waitUntil { rebuilt.displayedSource != nil }
            #expect(pictures.requests(path) == 1)
        }
    }

    /// On cellular a picture over the limit is not downloaded: the podcast cover shows, rebuilt rows do not ask
    /// again, and on Wi-Fi the episode's picture replaces it.
    @Test func oversizedPictureOnCellularWaitsForWiFiWithoutAskingAgain() async throws {
        let run = UUID().uuidString
        let big = "/\(run)/huge.png", small = "/\(run)/podcast.jpg"
        // Noise does not compress: about 9 MB, like the outlier pictures some podcasts publish.
        let huge = try #require(Self.noise(side: 1500, block: 1, alpha: true, seed: 5).pngData())
        #expect(huge.count > 5 * 1024 * 1024)
        let pictures = try await Pictures([big: huge, small: Self.photo(side: 600, seed: 13)])
        try await withNetwork { network in
            network.update(.init(connected: true, metered: true, cellular: true))
            let row = EpisodeArtworkView(source: pictures.url(big), fallback: pictures.url(small), title: "Show")
            try await waitUntil { row.displayedSource != nil }
            #expect(row.displayedSource == pictures.url(small))
            #expect(pictures.requests(big) == 1)
            for _ in 0..<3 {
                let rebuilt = EpisodeArtworkView(source: pictures.url(big), fallback: pictures.url(small), title: "Show")
                try await waitUntil { rebuilt.displayedSource != nil }
                #expect(rebuilt.displayedSource == pictures.url(small))
            }
            #expect(pictures.requests(big) == 1, "no repeated attempts on cellular")
            network.update(.init(connected: true, metered: false, cellular: false, transport: .wifi))
            try await waitUntil { row.displayedSource == pictures.url(big) }
            #expect(pictures.requests(big) == 2)
        }
    }

    /// New-episode notifications use the covers already on the phone.
    @Test func notificationPicturesUseTheSharedCache() async throws {
        let path = "/\(UUID())/notified.jpg"
        let pictures = try await Pictures([path: Self.photo(side: 1400, seed: 17)])
        try await withNetwork { _ in
            try await withStore { store in
                #expect(await ArtworkImageCache.remoteImage(pictures.url(path), maxPixels: 400) != nil)
                for _ in 0..<2 {
                    let data = try #require(try await NewEpisodeNotificationContent.artwork(.init(feedID: 1, title: "Show",
                        imageURL: pictures.url(path), count: 1), store: store))
                    let image = try #require(UIImage(data: data))
                    #expect(image.size == CGSize(width: 384, height: 384))
                }
                #expect(pictures.requests(path) == 1)
            }
        }
    }

    /// A streamed episode's embedded chapter picture is read from the network once for every size it is shown at;
    /// one over the restricted-network limit is not read on cellular.
    @Test func streamedEmbeddedChapterPictureIsReadOnceForBothSizes() async throws {
        try await withNetwork { network in try await withStore { store in
            var parsed = ParsedEpisode(identifier: "episode", title: "Episode", description: nil,
                media: .init(url: "https://example.invalid/\(UUID()).mp3", size: 50_000_000, durationMilliseconds: 60_000))
            parsed.chapters = [.init(startMilliseconds: 0, title: "One")]
            let source = URL(string: "https://example.invalid/\(UUID())/feed")!
            let feed = try await store.insert(.init(feed: ParsedFeed(format: .rss, title: "Show", episodes: [parsed]), source: source.absoluteString,
                                                    responseURL: source, validator: nil, permanentRedirectURL: nil))
            let episode = try #require(try await store.episode(id: feed.episodes[0].id))
            let picture = try #require(UIGraphicsImageRenderer(size: CGSize(width: 800, height: 800)).image { context in
                UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 800, height: 800))
            }.pngData())
            let reads = Mutex(0)
            let access = EpisodeChapterAccess(store: store, loader: .init(transport: URLSessionFeedTransport(), cache: URLCache(memoryCapacity: 0, diskCapacity: 0), userAgent: "test"),
                remoteRead: { _, _, _, _, request in
                    guard case .image = request else { return .chapters(nil) }
                    reads.withLock { $0 += 1 }
                    return .image(picture)
                })
            let reference = "embedded-image://4000000/\(picture.count)"
            for cover in [false, true] {
                let view = ChapterArtworkView(reference: reference, episode: episode, feed: nil, library: store, access: access, coverFallback: cover)
                defer { view.cancelLoading() }
                try await waitUntil { view.subviews.compactMap { $0 as? UIImageView }.contains { $0.image != nil } }
            }
            #expect(reads.withLock { $0 } == 1)
            network.update(.init(connected: true, metered: true, cellular: true))
            let largeReference = "embedded-image://4000000/\(6 * 1024 * 1024)"
            let large = ChapterArtworkView(reference: largeReference, episode: episode, feed: nil, library: store,
                                           access: access, coverFallback: false)
            defer { large.cancelLoading() }
            let key = "chapter|\(episode.details.media?.url ?? "")|\(episode.details.media?.size ?? 0)|\(largeReference)"
            try await waitUntil { ArtworkImageCache.isDeferred(key) }
            #expect(reads.withLock { $0 } == 1)
            #expect(!large.subviews.compactMap { $0 as? UIImageView }.contains { $0.image != nil })
            // Back on Wi-Fi the deferred picture may be asked for again (and later tests start unrestricted).
            network.update(.init(connected: true, metered: false, cellular: false, transport: .wifi))
            try await waitUntil { !ArtworkImageCache.isDeferred(key) }
        } }
    }

    // MARK: Embedded chapter pictures through the real chapter reader

    /// Streamed media served through a test proxy: honouring Range or not, with replaceable bytes.
    final class ChapterMedia: @unchecked Sendable {
        let server: LoopbackHTTPServer
        private let lock = NSLock()
        private var file: Data
        init(_ file: Data, honorsRange: Bool) async throws {
            self.file = file
            let box = Box()
            server = try await LoopbackHTTPServer.start { request in
                guard let media = box.owner else { return .init(status: 503) }
                let file = media.lock.withLock { media.file }
                let bounds = request.headers["range"].flatMap { range -> (Int, Int)? in
                    guard range.hasPrefix("bytes=") else { return nil }
                    let parts = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
                    return parts.count == 2 ? (parts[0], min(parts[1], file.count - 1)) : nil
                }
                guard honorsRange, let bounds, bounds.0 <= bounds.1 else { return .init(headers: ["Content-Type": "audio/mpeg"], body: file) }
                return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "Content-Range": "bytes \(bounds.0)-\(bounds.1)/\(file.count)"],
                             body: file[bounds.0...bounds.1])
            }
            box.owner = self
        }
        final class Box: @unchecked Sendable { weak var owner: ChapterMedia? }
        func replace(_ file: Data) { lock.withLock { self.file = file } }
        var requests: Int { server.requests.count }
        deinit { server.stop() }
    }

    /// Solid pictures padded to one length, so a replacement keeps the picture's offset and length.
    private static func pictures(_ colors: [UIColor], length: Int = 4096) throws -> [Data] {
        try colors.map { color in
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
            let png = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).pngData { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }
            try #require(png.count <= length)
            return png + Data(count: length - png.count)
        }
    }
    /// The shown picture's centre colour as 0–255 red, green and blue.
    private func shownColor(_ view: ChapterArtworkView) -> [Int]? {
        guard let cg = view.subviews.compactMap({ ($0 as? UIImageView)?.image }).first?.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: -CGFloat(cg.width) / 2, y: -CGFloat(cg.height) / 2, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return pixel[0..<3].map(Int.init)
    }
    private static let red = [255, 0, 0], green = [0, 255, 0], blue = [0, 0, 255]
    /// Whether the view shows `color` (within a few levels; nil: no picture shown).
    private func shows(_ view: ChapterArtworkView, _ color: [Int]?) -> Bool {
        guard let color else { return shownColor(view) == nil }
        guard let shown = shownColor(view) else { return false }
        return zip(shown, color).allSatisfy { abs($0 - $1) <= 8 }
    }

    /// A streamed episode (not downloaded) whose chapter pictures are read from `media` through the real reader.
    private func withStreamedEpisode(_ media: ChapterMedia, size: Int64,
                                     _ body: (FeedLibraryStore, LibraryEpisode, EpisodeChapterAccess) async throws -> Void) async throws {
        try await withStore { store in
            let parsed = ParsedEpisode(identifier: "episode", title: "Episode", description: nil,
                media: .init(url: "http://chapter-media.invalid/\(UUID()).mp3", size: size, durationMilliseconds: 60_000))
            let source = URL(string: "https://example.invalid/\(UUID())/feed")!
            let feed = try await store.insert(.init(feed: ParsedFeed(format: .rss, title: "Show", episodes: [parsed]), source: source.absoluteString,
                                                    responseURL: source, validator: nil, permanentRedirectURL: nil))
            let episode = try #require(try await store.episode(id: feed.episodes[0].id))
            let port = media.server.url.port!
            let access = EpisodeChapterAccess(store: store, loader: .init(transport: URLSessionFeedTransport(),
                cache: URLCache(memoryCapacity: 0, diskCapacity: 0), userAgent: "test"), proxy: { .init(kind: .http, host: "127.0.0.1", port: port) })
            try await body(store, episode, access)
        }
    }
    private func streamedKey(_ episode: LibraryEpisode, _ reference: String) -> String {
        "chapter|\(episode.details.media?.url ?? "")|\(episode.details.media?.size ?? 0)|\(reference)"
    }

    /// With "Cover images" off for mobile updates, a streamed chapter picture not on the phone is not fetched on
    /// cellular or Low Data Wi-Fi; on, it is fetched once, and then shows with the option off.
    @Test func streamedChapterPicturesFollowCoverImagesOnRestrictedNetworks() async throws {
        let picture = try Self.pictures([.red])[0]
        let media = try await ChapterMedia(Data(count: 200_000) + picture, honorsRange: true)
        let reference = "embedded-image://200000/\(picture.count)"
        try await withNetworkAndPreferences { network, preferences in
            try await withStreamedEpisode(media, size: 204_096) { store, episode, access in
                try preferences.setAllowed(.images, false)
                for state in [DownloadNetworkState(connected: true, metered: true, cellular: true),
                              DownloadNetworkState(connected: true, metered: false, cellular: false, transport: .wifi, constrained: true)] {
                    network.update(state)
                    let view = ChapterArtworkView(reference: reference, episode: episode, feed: nil, library: store, access: access, coverFallback: false)
                    await view.request?.value
                    #expect(shows(view, nil))
                    #expect(media.requests == 0)
                }
                try preferences.setAllowed(.images, true)
                network.update(.init(connected: true, metered: true, cellular: true))
                let allowed = ChapterArtworkView(reference: reference, episode: episode, feed: nil, library: store, access: access, coverFallback: false)
                await allowed.request?.value
                #expect(shows(allowed, Self.red))
                #expect(media.requests == 1)
                try preferences.setAllowed(.images, false)
                let player = ChapterArtworkView(reference: reference, episode: episode, feed: nil, library: store, access: access, coverFallback: true)
                await player.request?.value
                #expect(shows(player, Self.red), "a picture already on the phone shows")
                #expect(media.requests == 1)
            }
        }
    }

    /// A server that ignores Range would send 6 MB of audio before a small chapter picture: on cellular nothing past
    /// the 5 MB picture budget is read, rebuilt views do not ask again, and on Wi-Fi it loads.
    @Test func chapterPictureBeyondThePictureBudgetWaitsForWiFiWithoutRepeatedAttempts() async throws {
        let picture = try Self.pictures([.red])[0]
        let prefix = 6 * 1024 * 1024
        let media = try await ChapterMedia(Data(count: prefix) + picture, honorsRange: false)
        let reference = "embedded-image://\(prefix)/\(picture.count)"
        try await withNetwork { network in
            try await withStreamedEpisode(media, size: Int64(prefix + picture.count)) { store, episode, access in
                network.update(.init(connected: true, metered: true, cellular: true))
                for _ in 0..<3 {
                    let view = ChapterArtworkView(reference: reference, episode: episode, feed: nil, library: store, access: access, coverFallback: false)
                    await view.request?.value
                    #expect(shows(view, nil))
                }
                #expect(media.requests == 1)
                #expect(ArtworkImageCache.isDeferred(streamedKey(episode, reference)))
                network.update(.init(connected: true, metered: false, cellular: false, transport: .wifi))
                try await waitUntil { !ArtworkImageCache.isDeferred(streamedKey(episode, reference)) }
                let view = ChapterArtworkView(reference: reference, episode: episode, feed: nil, library: store, access: access, coverFallback: false)
                await view.request?.value
                #expect(shows(view, Self.red))
                #expect(media.requests == 2)
            }
        }
    }

    /// A server that ignores Range for a long episode with a picture early in it: on cellular and on Wi-Fi the
    /// picture shows after one request, however long the episode.
    @Test func chapterPictureEarlyInARangeIgnoringLongEpisodeShowsOnCellularAndWiFi() async throws {
        let picture = try Self.pictures([.red])[0]
        let offset = 1024 * 1024
        var file = Data(count: 20 * 1024 * 1024)
        file.replaceSubrange(offset..<(offset + picture.count), with: picture)
        let media = try await ChapterMedia(file, honorsRange: false)
        let reference = "embedded-image://\(offset)/\(picture.count)"
        try await withNetwork { network in
            for (index, state) in [DownloadNetworkState(connected: true, metered: true, cellular: true),
                                   DownloadNetworkState(connected: true, metered: false, cellular: false, transport: .wifi)].enumerated() {
                network.update(state)
                try await withStreamedEpisode(media, size: Int64(file.count)) { store, episode, access in
                    let view = ChapterArtworkView(reference: reference, episode: episode, feed: nil, library: store, access: access, coverFallback: false)
                    await view.request?.value
                    #expect(shows(view, Self.red), "\(state)")
                    #expect(media.requests == index + 1)
                }
            }
        }
    }

    /// Media replaced at the same address with the same length: the new chapter picture shows after a relaunch, as
    /// nothing of the old one was kept on disk.
    @Test func replacedStreamedMediaShowsItsNewChapterPictureAfterARelaunch() async throws {
        let colors = try Self.pictures([.red, .blue])
        let media = try await ChapterMedia(Data(count: 10_000) + colors[0], honorsRange: true)
        let reference = "embedded-image://10000/\(colors[0].count)"
        try await withNetwork { _ in
            try await withStreamedEpisode(media, size: 14_096) { store, episode, access in
                let first = ChapterArtworkView(reference: reference, episode: episode, feed: nil, library: store, access: access, coverFallback: false)
                await first.request?.value
                #expect(shows(first, Self.red))
                media.replace(Data(count: 10_000) + colors[1])
                ArtworkImageCache.removeAllFromMemory()
                let relaunched = ChapterArtworkView(reference: reference, episode: episode, feed: nil, library: store, access: access, coverFallback: false)
                await relaunched.request?.value
                #expect(shows(relaunched, Self.blue))
                #expect(media.requests == 2)
                let directory = try #require(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
                    .appendingPathComponent("Artwork", isDirectory: true)
                let digest = SHA256.hash(data: Data(streamedKey(episode, reference).utf8)).map { String(format: "%02x", $0) }.joined()
                #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(digest)-src").path))
            }
        }
    }

    /// A downloaded file replaced at the same path (same offset and length, with or without a new download date)
    /// and a folder file replaced in place show their new chapter picture within the same run.
    @Test func replacedLocalFilesShowTheirNewChapterPictureWithinOneRun() async throws {
        let colors = try Self.pictures([.red, .blue, .green])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChapterFiles-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = "embedded-image://1000/\(colors[0].count)"
        try await withStore { store in
            let parsed = ParsedEpisode(identifier: "episode", title: "Episode", description: nil,
                media: .init(url: "https://example.invalid/\(UUID()).mp3", size: 5096, durationMilliseconds: 60_000))
            let source = URL(string: "https://example.invalid/\(UUID())/feed")!
            let feed = try await store.insert(.init(feed: ParsedFeed(format: .rss, title: "Show", episodes: [parsed]), source: source.absoluteString,
                                                    responseURL: source, validator: nil, permanentRedirectURL: nil))
            let path = root.appendingPathComponent("download.media")
            try (Data(count: 1000) + colors[0]).write(to: path)
            let id = feed.episodes[0].id
            try await store.updateEpisode(id: id) {
                $0.userState.isDownloaded = true; $0.userState.localFileURL = path.path; $0.userState.downloadDate = Date(timeIntervalSince1970: 10)
            }
            let access = EpisodeChapterAccess(store: store, loader: .init(transport: URLSessionFeedTransport(),
                cache: URLCache(memoryCapacity: 0, diskCapacity: 0), userAgent: "test"), proxy: { .init() })
            @MainActor func shown(_ episode: LibraryEpisode, _ color: [Int]) async throws {
                let view = ChapterArtworkView(reference: reference, episode: episode, feed: nil, library: store, access: access, coverFallback: false)
                await view.request?.value
                #expect(shows(view, color))
            }
            try await shown(try #require(try await store.episode(id: id)), Self.red)
            try (Data(count: 1000) + colors[1]).write(to: path)
            try await shown(try #require(try await store.episode(id: id)), Self.blue)
            try (Data(count: 1000) + colors[2]).write(to: path)
            try await store.updateEpisode(id: id) { $0.userState.downloadDate = Date(timeIntervalSince1970: 20) }
            try await shown(try #require(try await store.episode(id: id)), Self.green)
        }
        // A file in a local folder, replaced in place.
        try await withStore { store in
            let folder = root.appendingPathComponent("folder")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("one.mp3")
            try (Data(count: 1000) + colors[0]).write(to: file)
            _ = try await store.registerLocalFolder(title: "Local", directoryIdentity: "folder", bookmark: try LocalFolderDocuments.makeBookmark(directory: folder))
            let refresh = LocalFeedRefreshService(store: store, open: { link in
                try await LocalFolderDocuments(bookmark: link.bookmark).scanInput { _, _ in .init(title: "Local") }
            })
            _ = try await refresh.refresh(feedID: 1, description: "Local", author: "Local")
            let episode = try #require(try await store.episode(id: 1))
            let access = EpisodeChapterAccess(store: store, loader: .init(transport: URLSessionFeedTransport(),
                cache: URLCache(memoryCapacity: 0, diskCapacity: 0), userAgent: "test"), proxy: { .init() })
            for (index, color) in [Self.red, Self.blue].enumerated() {
                try (Data(count: 1000) + colors[index]).write(to: file)
                let view = ChapterArtworkView(reference: reference, episode: episode, feed: nil, library: store, access: access, coverFallback: false)
                await view.request?.value
                #expect(shows(view, color))
            }
        }
    }
}

/// Decoded covers are bounded and trimmed: the cache keeps at most its cost limit, and nothing after the app
/// goes to the background or a memory warning, while covers on screen stay drawn (their views hold them).
@MainActor @Suite(.serialized)
struct ArtworkCacheTrimViewTests {
    private func cover(_ index: Int) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 400, height: 400), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .image { context in UIColor(hue: CGFloat(index % 32) / 32, saturation: 1, brightness: 1, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 400)) }
    }

    @Test func coversAreBoundedAndTrimmedInTheBackgroundAndOnAMemoryWarning() async throws {
        ArtworkImageCache.trimMemory()
        // A long grid scroll's worth of 400 px covers (100 podcasts, 64 MB decoded): the cache keeps its bound.
        for index in 0..<100 { ArtworkImageCache.store(cover(index), source: "https://example.test/trim/\(index).jpg", maxPixels: 400) }
        #expect(ArtworkImageCache.memoryCost <= ArtworkImageCache.costLimit, "\(ArtworkImageCache.memoryCost) bytes kept")
        #expect(ArtworkImageCache.costLimit == 48 * 1_024 * 1_024)
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didReceiveMemoryWarningNotification] {
            let shown = cover(1)
            ArtworkImageCache.store(shown, source: "https://example.test/trim/shown.jpg", maxPixels: 400)
            let view = UIImageView(image: ArtworkImageCache.image("https://example.test/trim/shown.jpg", maxPixels: 400))
            #expect(ArtworkImageCache.memoryCount > 0)
            NotificationCenter.default.post(name: name, object: nil)
            #expect(ArtworkImageCache.memoryCount == 0 && ArtworkImageCache.memoryCost == 0, "\(name.rawValue)")
            #expect(FeedAppBarView.blurredCount == 0, "\(name.rawValue): blurred headers")
            #expect(view.image === shown, "\(name.rawValue): a cover on screen stays drawn")
            #expect(ArtworkImageCache.image("https://example.test/trim/shown.jpg", maxPixels: 400) == nil)
        }
    }
}
