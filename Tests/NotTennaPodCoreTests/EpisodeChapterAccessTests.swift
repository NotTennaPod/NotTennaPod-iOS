import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.timeLimit(.minutes(1))) struct EpisodeChapterAccessTests {
    private struct NoHTTP: FeedHTTPTransport {
        func send(_ request: URLRequest) async throws -> FeedHTTPResponse { throw URLError(.notConnectedToInternet) }
    }
    private actor Gate {
        var continuation: CheckedContinuation<EpisodeChapterAccess.Result, Never>?
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func read() async -> EpisodeChapterAccess.Result {
            await withCheckedContinuation {
                continuation = $0
                for waiter in waiters { waiter.resume() }; waiters = []
            }
        }
        func started() async { if continuation == nil { await withCheckedContinuation { waiters.append($0) } } }
        func release(_ result: EpisodeChapterAccess.Result) { continuation?.resume(returning: result); continuation = nil }
    }
    private func fixture() throws -> URL {
        try #require(Bundle.module.url(forResource: "original-auphonic.mp3", withExtension: nil, subdirectory: "Fixtures/EmbeddedChapters"))
    }
    private func loader() -> EpisodeChapterLoader {
        .init(transport: NoHTTP(), cache: URLCache(memoryCapacity: 1024, diskCapacity: 0), userAgent: "chapter-test")
    }
    private func withStore(local: Bool = false, _ body: (FeedLibraryStore, URL, LibraryEpisode) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChapterAccess-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        do {
            if local {
                let folder = root.appendingPathComponent("media")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: fixture(), to: folder.appendingPathComponent("one.mp3"))
                let bookmark = try LocalFolderDocuments.makeBookmark(directory: folder)
                _ = try await store.registerLocalFolder(title: "Local", directoryIdentity: "folder", bookmark: bookmark)
                let refresh = LocalFeedRefreshService(store: store, open: { link in
                    try await LocalFolderDocuments(bookmark: link.bookmark).scanInput { _, _ in .init(title: "Local") }
                })
                _ = try await refresh.refresh(feedID: 1, description: "Local", author: "Local")
            } else {
                let feed = URL(string: "https://example.invalid/feed")!
                _ = try await store.insert(.init(feed: .init(format: .rss, episodes: [
                    .init(identifier: "one", title: "Episode", media: .init(url: "https://example.invalid/one.mp3", size: 12))
                ]), source: feed.absoluteString, responseURL: feed, validator: nil, permanentRedirectURL: nil))
            }
            let episode = try #require(try await store.episode(id: 1))
            try await body(store, root, episode)
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
    @Test func registeredDocumentLoadsChaptersAndImageWithoutChangingEpisodeArtworkFacts() async throws {
        try await withStore(local: true) { store, _, episode in
            let before = try await store.episode(id: episode.id)
            let access = EpisodeChapterAccess(store: store, loader: loader(), proxy: { .init() })
            let chapters = try await access.load(episode: episode)
            #expect(chapters == (try EmbeddedChapterReader.read(url: fixture())))
            let image = try #require(chapters.first?.imageURL.flatMap(EmbeddedChapterImage.init(url:)))
            #expect(try await access.artwork(image, episode: episode) == image.read(url: fixture()))
            #expect(try await store.episode(id: episode.id) == before)
        }
    }
    @Test(arguments: ["replace", "reconnect", "cancel"])
    func delayedProviderReadsCannotPublishRetiredDocument(change: String) async throws {
        try await withStore(local: true) { store, _, episode in
            let (started, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let release = DispatchSemaphore(value: 0)
            defer { release.signal(); signal.finish() }
            let access = EpisodeChapterAccess(store: store, loader: loader(), fileRead: { _, check, _ in
                signal.yield(()); signal.finish()
                guard release.wait(timeout: .now() + 10) == .success else { throw CocoaError(.fileReadUnknown) }
                try check(); return .chapters([.init(startMilliseconds: 0, title: "Late")])
            })
            let pending = Task { try await access.load(episode: episode) }
            defer { pending.cancel() }
            for await _ in started { break }
            if change == "replace" { try await store.updateEpisode(id: episode.id) { $0.details.media?.size += 1 } }
            else if change == "reconnect" {
                let folder = try #require(try await store.localFolder(feedID: 1))
                _ = try await store.reconnectLocalFolder(feedID: 1, directoryIdentity: folder.directoryIdentity, bookmark: folder.bookmark)
            } else { pending.cancel() }
            release.signal()
            await #expect(throws: CancellationError.self) { try await pending.value }
        }
    }
    @Test func downloadedFileTakesPrecedenceAndMissingFileDoesNotStartAStream() async throws {
        try await withStore { store, root, episode in
            let path = root.appendingPathComponent("download.media")
            try FileManager.default.copyItem(at: fixture(), to: path)
            try await store.updateEpisode(id: episode.id) {
                $0.userState.isDownloaded = true; $0.userState.localFileURL = path.path; $0.userState.downloadDate = Date(timeIntervalSince1970: 10)
                $0.details.chapters = [.init(startMilliseconds: 0, title: "XML")]
                $0.userState.isFavorite = true; $0.userState.positionMilliseconds = 321
            }
            let current = try #require(try await store.episode(id: episode.id)), calls = Mutex(0)
            let access = EpisodeChapterAccess(store: store, loader: loader(), remoteRead: { _, _, _, _, _ in
                calls.withLock { $0 += 1 }; return .chapters(nil)
            })
            #expect(try await access.load(episode: current).count == 4)
            try FileManager.default.removeItem(at: path)
            #expect(try await access.load(episode: current) == current.details.chapters)
            #expect(calls.withLock { $0 } == 0)
            #expect(try await store.episode(id: episode.id) == current)
        }
    }
    @Test(arguments: ["delete", "replace", "cancel"])
    func delayedDownloadedArtworkCannotPublishAfterSourceChanges(change: String) async throws {
        try await withStore { store, root, episode in
            let file = root.appendingPathComponent("download.media")
            try FileManager.default.copyItem(at: fixture(), to: file)
            try await store.updateEpisode(id: episode.id) {
                $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path; $0.userState.downloadDate = Date(timeIntervalSince1970: 10)
            }
            let current = try #require(try await store.episode(id: episode.id))
            let (started, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let release = DispatchSemaphore(value: 0)
            defer { release.signal(); signal.finish() }
            let access = EpisodeChapterAccess(store: store, loader: loader(), fileRead: { _, check, _ in
                signal.yield(()); signal.finish()
                guard release.wait(timeout: .now() + 10) == .success else { throw CocoaError(.fileReadUnknown) }
                try check(); return .image(Data([1]))
            })
            let image = try #require(EmbeddedChapterImage(url: "embedded-image://0/1"))
            let pending = Task { try await access.artwork(image, episode: current) }
            defer { pending.cancel() }
            for await _ in started { break }
            if change == "delete" { try await store.requestMediaDeletion(episodeID: episode.id) }
            else if change == "replace" { try await store.updateEpisode(id: episode.id) { $0.userState.downloadDate = .distantFuture } }
            else { pending.cancel() }
            release.signal()
            await #expect(throws: CancellationError.self) { try await pending.value }
        }
    }
    @Test(arguments: ["media", "chapters", "image", "cancel", "favorite"])
    func remoteReadCapturesConfigurationAndRejectsChangedChapterSources(change: String) async throws {
        try await withStore { store, _, episode in
            let gate = Gate(), configuration = PodcastProxy(kind: .http, host: "proxy.invalid", port: 3128)
            let login = FeedCredentials(username: "fixture", password: "fixture")
            let access = EpisodeChapterAccess(store: store, loader: loader(), proxy: { configuration }, credentials: { feedID in
                #expect(feedID == 1); return login
            }, userAgent: "ChapterTest/1", remoteRead: { url, proxy, credentials, userAgent, _ in
                #expect(url.absoluteString == "https://example.invalid/one.mp3")
                #expect(proxy == configuration && credentials == login && userAgent == "ChapterTest/1")
                return await gate.read()
            })
            let image = try #require(EmbeddedChapterImage(url: "embedded-image://0/1"))
            let pending = Task<[ParsedChapter]?, any Error> {
                if change == "image" { return try await access.artwork(image, episode: episode).map { _ in [ParsedChapter]() } }
                return try await access.load(episode: episode)
            }
            defer { pending.cancel() }
            await gate.started()
            if change == "media" || change == "image" { try await store.updateEpisode(id: episode.id) { $0.details.media?.url = "https://example.invalid/replacement" } }
            else if change == "chapters" { try await store.updateEpisode(id: episode.id) { $0.details.chapterURL = "https://example.invalid/new.json" } }
            else if change == "favorite" { try await store.setFavorite(episodeID: episode.id, favorite: true) }
            else { pending.cancel() }
            await gate.release(change == "image" ? .image(Data([1])) : .chapters([.init(startMilliseconds: 0, title: "Read")]))
            if change == "favorite" { #expect(try await pending.value == [.init(startMilliseconds: 0, title: "Read")]) }
            else { await #expect(throws: CancellationError.self) { try await pending.value } }
        }
    }
    /// Cover and seek bar reload chapters on every play, pause and buffering change; a stream's chapters are read
    /// from the server once per media, not each time. A refresh or a changed source reads again.
    @Test func streamChaptersAreReadOncePerMediaAndSharedBetweenSurfaces() async throws {
        try await withStore { store, _, episode in
            let calls = Mutex(0)
            let loader = loader()
            let access = EpisodeChapterAccess(store: store, loader: loader, remoteRead: { _, _, _, _, _ in
                calls.withLock { $0 += 1 }
                try await Task.sleep(for: .milliseconds(50))
                return .chapters([.init(startMilliseconds: 0, title: "Read")])
            })
            async let cover = access.load(episode: episode)
            async let seekbar = access.load(episode: episode)
            #expect(try await cover == [.init(startMilliseconds: 0, title: "Read")])
            #expect(try await seekbar == [.init(startMilliseconds: 0, title: "Read")])
            for _ in 0..<5 { #expect(try await access.load(episode: episode).count == 1) }
            #expect(calls.withLock { $0 } == 1)
            // Playback state is not chapter data.
            try await store.updateEpisode(id: episode.id) { $0.userState.positionMilliseconds = 5_000; $0.userState.isFavorite = true }
            _ = try await access.load(episode: try #require(try await store.episode(id: episode.id)))
            #expect(calls.withLock { $0 } == 1)
            _ = try await access.load(episode: try #require(try await store.episode(id: episode.id)), forceRefresh: true)
            #expect(calls.withLock { $0 } == 2)
            try await store.updateEpisode(id: episode.id) { $0.details.media?.url = "https://example.invalid/two.mp3" }
            _ = try await access.load(episode: try #require(try await store.episode(id: episode.id)))
            #expect(calls.withLock { $0 } == 3)
        }
    }
    @Test func feedFileURLCannotBypassRegisteredAccessAndIdentityUsesLiteralPaths() async throws {
        try await withStore { store, _, episode in
            let file = try fixture()
            try await store.updateEpisode(id: episode.id) { $0.details.media?.url = file.absoluteString }
            let current = try #require(try await store.episode(id: episode.id)), calls = Mutex(0)
            let access = EpisodeChapterAccess(store: store, loader: loader(), fileRead: { _, _, _ in
                calls.withLock { $0 += 1 }; return .chapters([])
            })
            #expect(try await access.load(episode: current).isEmpty)
            #expect(calls.withLock { $0 } == 0)
            var composed = current, decomposed = current
            composed.details.media?.url = "https://example/caf\u{e9}"
            decomposed.details.media?.url = "https://example/cafe\u{301}"
            #expect(EpisodeChapterIdentity(composed) != EpisodeChapterIdentity(decomposed))
        }
    }
    @Test func bookmarkRenewalPreservesEpisodeFactsAndCannotOverwriteNewerGrant() async throws {
        try await withStore(local: true) { store, _, episode in
            let reference = try #require(try await store.localDocument(episodeID: episode.id))
            #expect(try await store.recordLocalChapterRead(episodeID: episode.id, reference: reference, refreshedBookmark: Data([2])))
            #expect(try await store.recordLocalChapterRead(episodeID: episode.id, reference: reference, refreshedBookmark: Data([3])))
            #expect(try await store.localFolder(feedID: 1)?.bookmark == Data([2]))
            #expect(try await store.episode(id: episode.id) == episode)
            _ = try await store.reconnectLocalFolder(feedID: 1, directoryIdentity: "replacement", bookmark: Data([4]))
            #expect(try await store.recordLocalChapterRead(episodeID: episode.id, reference: reference, refreshedBookmark: Data([5])) == false)
            #expect(try await store.localFolder(feedID: 1)?.bookmark == Data([4]))
        }
    }
}
