import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite struct EpisodeChapterAccessTests {
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

    // MARK: Streamed chapter lists and the admission

    private final class OnceBox: Sendable { let value = Mutex<Int64?>(nil) }
    private final class Network: @unchecked Sendable {
        let preferences: MobileNetworkPreferenceStore
        let monitor = DownloadNetworkMonitor(startMonitoring: false)
        let admission: AuxiliaryNetworkAdmission
        private let file: URL
        private let once = OnceBox()
        init(allowed: Set<String>, state: DownloadNetworkState?) async throws {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("ChapterMobile-\(UUID()).json")
            self.file = file
            preferences = try await MainActor.run {
                let preferences = try MobileNetworkPreferenceStore(file: file)
                try preferences.updateAllowed(allowed)
                return preferences
            }
            let once = once
            admission = AuxiliaryNetworkAdmission(network: monitor, preferences: preferences, onceAdmittedEpisodeID: { once.value.withLock { $0 } })
            if let state { monitor.update(state) }
        }
        func allow(_ values: Set<String>) async throws {
            let preferences = preferences
            try await MainActor.run { try preferences.updateAllowed(values) }
        }
        func consent(_ id: Int64?) { once.value.withLock { $0 = id } }
        deinit { try? FileManager.default.removeItem(at: file) }
        static let wifi = DownloadNetworkState(connected: true, metered: false, cellular: false, transport: .wifi)
        static let cellular = DownloadNetworkState(connected: true, metered: true, cellular: true)
    }

    private func admittedLoader(_ network: Network) -> EpisodeChapterLoader {
        .init(transport: NoHTTP(), cache: URLCache(memoryCapacity: 1024, diskCapacity: 0), userAgent: "chapter-test", admission: network.admission)
    }

    /// Streaming off on cellular: the streamed list is not read, waits for its permission and is not cached; with
    /// Streaming on it is read.
    @Test func deniedStreamedReadIsNotCachedAndReadsOncePermitted() async throws {
        try await withStore { store, _, episode in
            let network = try await Network(allowed: ["images"], state: Network.cellular), calls = Mutex(0)
            let access = EpisodeChapterAccess(store: store, loader: admittedLoader(network), remoteRead: { _, _, _, _, request in
                guard case .streamedChapters = request else { Issue.record("not admitted: \(request)"); return .chapters(nil) }
                calls.withLock { $0 += 1 }; return .chapters([.init(startMilliseconds: 0, title: "Streamed")])
            })
            let denied = try await access.loadDeferring(episode: episode)
            #expect(denied == EpisodeChapterLoad(chapters: [], deferred: [.permitted(.streamedMedia, episodeID: episode.id)]))
            #expect(try await access.loadDeferring(episode: episode).deferred == [.permitted(.streamedMedia, episodeID: episode.id)])
            #expect(calls.withLock { $0 } == 0)
            try await network.allow(["images", "streaming"])
            #expect(try await access.loadDeferring(episode: episode) == EpisodeChapterLoad(chapters: [.init(startMilliseconds: 0, title: "Streamed")]))
            #expect(calls.withLock { $0 } == 1)
        }
    }

    /// "Once" consent is for its own episode: consent for another episode reads nothing; for this one it reads.
    @Test func onceConsentAdmitsOnlyItsEpisodesChapterList() async throws {
        try await withStore { store, _, episode in
            let network = try await Network(allowed: [], state: Network.cellular), calls = Mutex(0)
            let access = EpisodeChapterAccess(store: store, loader: admittedLoader(network), remoteRead: { _, _, _, _, _ in
                calls.withLock { $0 += 1 }; return .chapters([.init(startMilliseconds: 0, title: "Streamed")])
            })
            network.consent(episode.id + 1)
            #expect(try await access.loadDeferring(episode: episode).deferred == [.permitted(.streamedMedia, episodeID: episode.id)])
            #expect(calls.withLock { $0 } == 0)
            network.consent(episode.id)
            #expect(try await access.load(episode: episode) == [.init(startMilliseconds: 0, title: "Streamed")])
            #expect(calls.withLock { $0 } == 1)
        }
    }

    /// Downloaded and folder files never ask: their chapters load while the network is not even known yet.
    @Test(arguments: ["downloaded", "folder"]) func localFilesNeverAsk(kind: String) async throws {
        try await withStore(local: kind == "folder") { store, root, episode in
            let network = try await Network(allowed: [], state: nil)
            if kind == "downloaded" {
                let path = root.appendingPathComponent("download.media")
                try FileManager.default.copyItem(at: fixture(), to: path)
                try await store.updateEpisode(id: episode.id) {
                    $0.userState.isDownloaded = true; $0.userState.localFileURL = path.path; $0.userState.downloadDate = Date(timeIntervalSince1970: 10)
                }
            }
            let current = try #require(try await store.episode(id: episode.id))
            let access = EpisodeChapterAccess(store: store, loader: admittedLoader(network), proxy: { .init() })
            #expect(try await access.load(episode: current) == (try EmbeddedChapterReader.read(url: fixture())))
            #expect(network.monitor.pendingObservationCount == 0)
        }
    }

    /// Over the budget: on a restricted network the list waits for an unrestricted one, per media, and is not cached:
    /// routine reloads (play, pause, buffering, a Refresh) make no request while it waits, and it is read once the
    /// network is unrestricted. On an unrestricted network there are no embedded chapters within limits, kept for the
    /// session (no second read).
    @Test(arguments: [true, false]) func streamedListOverItsBudget(restricted: Bool) async throws {
        try await withStore { store, _, episode in
            let network = try await Network(allowed: ["streaming"], state: restricted ? Network.cellular : Network.wifi), calls = Mutex(0)
            let access = EpisodeChapterAccess(store: store, loader: admittedLoader(network), remoteRead: { _, _, _, _, request in
                calls.withLock { $0 += 1 }
                guard case .streamedChapters(let allowance) = request else { return .chapters(nil) }
                if allowance.restricted { throw ChapterMediaBudgetExceeded(restricted: true) }
                return .chapters(restricted ? [.init(startMilliseconds: 0, title: "On Wi-Fi")] : nil)
            })
            let first = try await access.loadDeferring(episode: episode)
            #expect(first == EpisodeChapterLoad(chapters: [], deferred: restricted ? [.unrestricted] : []))
            #expect(try await access.loadDeferring(episode: episode).deferred == (restricted ? [.unrestricted] : []))
            #expect(calls.withLock { $0 } == 1, restricted ? "no read while it waits" : "the session's result is kept")
            guard restricted else { return }
            #expect(try await access.loadDeferring(episode: episode, forceRefresh: true).deferred == [.unrestricted])
            #expect(calls.withLock { $0 } == 1, "a Refresh on the restricted network does not read it either")
            network.monitor.update(Network.wifi)
            #expect(try await access.load(episode: episode) == [.init(startMilliseconds: 0, title: "On Wi-Fi")])
            #expect(calls.withLock { $0 } == 2)
        }
    }

    /// The last consumer of a streamed read leaves (its surface stops): the read is cancelled and its request
    /// disconnects promptly, and the caller finishes at once, without the held response ever being released.
    @Test func cancellingTheLastConsumerStopsTheRead() async throws {
        let disconnected = Mutex(false)
        let server = try await LoopbackHTTPServer.start(onClientDisconnect: { disconnected.withLock { $0 = true } }) { _ in nil }
        defer { server.stop() }
        try await withStore { store, _, original in
            try await store.updateEpisode(id: original.id) { $0.details.media?.url = server.url.absoluteString }
            let episode = try #require(try await store.episode(id: original.id))
            let access = EpisodeChapterAccess(store: store, loader: loader(), proxy: { .init() })
            let finished = Mutex(false)
            let load = Task {
                defer { finished.withLock { $0 = true } }
                return try await access.loadDeferring(episode: episode)
            }
            let deadline = ContinuousClock.now + .seconds(10)
            while server.requests.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
            try #require(server.requests.count == 1)
            load.cancel()
            while !(finished.withLock { $0 } && disconnected.withLock { $0 }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(finished.withLock { $0 }, "the caller finished")
            #expect(disconnected.withLock { $0 }, "the request disconnected")
            await #expect(throws: CancellationError.self) { _ = try await load.value }
        }
    }

    /// Two surfaces share one read; one of them leaving does not cancel it for the other, which gets the chapters.
    @Test func aSharedReadOutlivesOneConsumersCancellation() async throws {
        let file = SparseM4A.file(mdat: 20_000)
        let server = try await LoopbackHTTPServer.start { _ in nil }
        defer { server.stop() }
        try await withStore { store, _, original in
            try await store.updateEpisode(id: original.id) { $0.details.media?.url = server.url.absoluteString }
            let episode = try #require(try await store.episode(id: original.id))
            let loader = loader()
            await loader.setRetireDelay(.zero)
            let access = EpisodeChapterAccess(store: store, loader: loader, proxy: { .init() })
            let leaving = Task { try await access.loadDeferring(episode: episode) }
            let deadline = ContinuousClock.now + .seconds(10)
            while server.requests.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
            let staying = Task { try await access.loadDeferring(episode: episode) }
            while await loader.mediaConsumerCount < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
            try #require(await loader.mediaConsumerCount == 2)
            leaving.cancel()
            await #expect(throws: CancellationError.self) { _ = try await leaving.value }
            try server.respond(toPath: server.requests[0].path, with: .init(headers: ["Content-Type": "audio/mp4"], body: file))
            #expect(try await staying.value.chapters.map(\.title) == SparseM4A.expected)
            #expect(server.requests.count == 1, "one read, shared")
        }
    }

    /// A read whose completing chunk takes it past its 5 MiB restricted budget (two redirect pages leave 1,000 bytes;
    /// the file's first chunk is larger) is the budget limit, not "no chapters": it waits for an unrestricted network
    /// and is not cached, so the next load reuses nothing and makes no request on the restricted network.
    @Test func restrictedFiveMiBOverrunMustNotBeCached() async throws {
        let page = (5 * 1024 * 1024 - 1000) / 2
        let media = Data("NOTMEDIA".utf8) + Data(repeating: 7, count: 1_000_000)
        let server = try await LoopbackHTTPServer.start { request in
            switch URL(string: request.path)?.path ?? request.path {
            case "/episode.mp3": return .init(status: 302, headers: ["Location": "/second.mp3"], body: Data(count: page))
            case "/second.mp3": return .init(status: 302, headers: ["Location": "/media.mp3"], body: Data(count: page))
            default: return .init(headers: ["Content-Type": "audio/mpeg"], body: media)
            }
        }
        defer { server.stop() }
        try await withStore { store, _, original in
            let url = server.url.deletingLastPathComponent().appendingPathComponent("episode.mp3")
            try await store.updateEpisode(id: original.id) { $0.details.media?.url = url.absoluteString }
            let episode = try #require(try await store.episode(id: original.id))
            let network = try await Network(allowed: ["streaming"], state: Network.cellular)
            let access = EpisodeChapterAccess(store: store, loader: admittedLoader(network), proxy: { .init() })
            #expect(try await access.loadDeferring(episode: episode) == EpisodeChapterLoad(chapters: [], deferred: [.unrestricted]))
            let requests = server.requests.count
            #expect(try await access.loadDeferring(episode: episode) == EpisodeChapterLoad(chapters: [], deferred: [.unrestricted]))
            #expect(server.requests.count == requests, "nothing reused, nothing requested")
        }
    }


    /// The file changed between the requests of one read (the publisher replaced it after the first request): not
    /// cached as "no chapters"; the next load reads it again and finds its chapters. Real requests at a loopback server.
    @Test func changedMediaIsNotCachedAndTheNextLoadReadsAgain() async throws {
        let server = try await SparseM4A.Server(SparseM4A.file(mdat: 1_000_000), ranges: true, changeAfterFirst: true)
        try await withStore { store, _, original in
            try await store.updateEpisode(id: original.id) { $0.details.media?.url = server.url.absoluteString }
            let episode = try #require(try await store.episode(id: original.id))
            let network = try await Network(allowed: ["streaming"], state: Network.cellular)
            let access = EpisodeChapterAccess(store: store, loader: admittedLoader(network), proxy: { .init() })
            #expect(try await access.loadDeferring(episode: episode) == EpisodeChapterLoad(chapters: []))
            #expect(server.requests.count == 2 && server.requests[1].headers["if-range"] == "\"v1\"")
            #expect(try await access.load(episode: episode).map(\.title) == SparseM4A.expected)
            #expect(server.requests.count == 4, "read again: the change was not kept as a result")
            #expect(try await access.load(episode: episode).map(\.title) == SparseM4A.expected)
            #expect(server.requests.count == 4, "a completed read is kept")
        }
    }

    /// A list admitted only because the network was unrestricted stops when a metered network appears, even one gone
    /// again: the request is cancelled (the server sees the client leave), the list waits for its permission and is
    /// not cached, and the next load reads it.
    @Test func transientMeteredRevisionStopsAPathLockedChapterRead() async throws {
        let disconnected = Mutex(false)
        let file = SparseM4A.file(mdat: 20_000)
        let hold = Mutex(true)
        let server = try await LoopbackHTTPServer.start(onClientDisconnect: { disconnected.withLock { $0 = true } }) { _ in
            hold.withLock { $0 } ? nil : .init(headers: ["Content-Type": "audio/mp4"], body: file)
        }
        defer { server.stop() }
        try await withStore { store, _, original in
            try await store.updateEpisode(id: original.id) { $0.details.media?.url = server.url.absoluteString }
            let episode = try #require(try await store.episode(id: original.id))
            let network = try await Network(allowed: [], state: Network.wifi)
            let access = EpisodeChapterAccess(store: store, loader: admittedLoader(network), proxy: { .init() })
            let load = Task { try await access.loadDeferring(episode: episode) }
            let deadline = ContinuousClock.now + .seconds(10)
            while server.requests.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
            try #require(server.requests.count == 1)
            network.monitor.update(Network.cellular); network.monitor.update(Network.wifi)
            #expect(try await load.value == EpisodeChapterLoad(chapters: [], deferred: [.permitted(.streamedMedia, episodeID: episode.id)]))
            while !disconnected.withLock({ $0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
            #expect(disconnected.withLock { $0 })
            hold.withLock { $0 = false }
            #expect(try await access.load(episode: episode).map(\.title) == SparseM4A.expected)
            #expect(server.requests.count == 2)
        }
    }
}
