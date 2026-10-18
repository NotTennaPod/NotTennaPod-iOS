import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// External chapter JSON asks the admission ("Cover images", or an unrestricted network) on a remote miss, is bounded,
/// and a denial is never cached as "no chapters". Every request is a real request at a loopback fixture.
enum ChapterAdmissionFixture {
    static let stored = [ParsedChapter(startMilliseconds: 0, title: "Stored0"), ParsedChapter(startMilliseconds: 60_000, title: "Stored1")]
    static func document(padding: Int = 0, title: String = "Remote") -> Data {
        let rows = (0..<4).map { "{\"startTime\":\($0 * 30),\"title\":\"\(title)\($0)\"}" }.joined(separator: ",")
        return Data("{\"chapters\":[\(rows)],\"pad\":\"\(String(repeating: " ", count: padding))\"}".utf8)
    }
    /// The publisher's four chapters, as the parser reads them.
    static let remote = PodcastIndexChapterParser.parse(String(decoding: document(), as: UTF8.self))!
    final class Server: Sendable {
        private final class Script: Sendable { let body = Mutex(ChapterAdmissionFixture.document()) }
        let server: LoopbackHTTPServer
        private let script: Script
        init() async throws {
            let script = Script()
            self.script = script
            server = try await LoopbackHTTPServer.start { _ in .init(headers: ["Content-Type": "application/json"], body: script.body.withLock { $0 }) }
        }
        var url: URL { server.url.deletingLastPathComponent().appendingPathComponent("chapters.json") }
        var count: Int { server.requests.count }
        func serve(_ body: Data) { script.body.withLock { $0 = body } }
        deinit { server.stop() }
    }
}

extension EpisodeChapterLoaderTests {
    @MainActor private func admitted(_ fixture: AuxiliaryNetworkFixture, cache: URLCache = URLCache(memoryCapacity: 40_000_000, diskCapacity: 0)) -> EpisodeChapterLoader {
        EpisodeChapterLoader(transport: URLSessionFeedTransport(), cache: cache, userAgent: "chapter-test", admission: fixture.admission)
    }

    /// Denied on a restricted network: no request, the stored chapters show, and the miss waits for its permission;
    /// it is not cached, so once permitted it is fetched.
    @Test @MainActor func coldExternalMissDeniedShowsStoredChaptersAndIsNotCached() async throws {
        let server = try await ChapterAdmissionFixture.Server()
        let fixture = try AuxiliaryNetworkFixture(allowed: [], state: AuxiliaryNetworkFixture.cellular)
        let loader = admitted(fixture)
        let denied = try await loader.loadDeferring(stored: ChapterAdmissionFixture.stored, externalURL: server.url.absoluteString) { nil }
        #expect(denied == EpisodeChapterLoad(chapters: ChapterAdmissionFixture.stored, deferred: [.permitted(.smallMetadata)]))
        #expect(server.count == 0)
        try fixture.allow(["images"])
        let loaded = try await loader.loadDeferring(stored: ChapterAdmissionFixture.stored, externalURL: server.url.absoluteString) { nil }
        #expect(loaded == EpisodeChapterLoad(chapters: ChapterAdmissionFixture.remote))
        #expect(server.count == 1)
    }

    /// Cached external chapters show without asking, whatever the network and options.
    @Test @MainActor func cachedExternalChaptersMakeNoRequest() async throws {
        let server = try await ChapterAdmissionFixture.Server()
        let fixture = try AuxiliaryNetworkFixture(allowed: [], state: AuxiliaryNetworkFixture.wifi)
        let loader = admitted(fixture)
        #expect(try await loader.load(stored: nil, externalURL: server.url.absoluteString) { nil } == ChapterAdmissionFixture.remote)
        fixture.network.update(AuxiliaryNetworkFixture.cellular)
        #expect(try await loader.loadDeferring(stored: nil, externalURL: server.url.absoluteString) { nil } == EpisodeChapterLoad(chapters: ChapterAdmissionFixture.remote))
        #expect(server.count == 1)
    }

    /// Over the restricted budget the list waits for an unrestricted network (no request while restricted, even with
    /// both options on); over the unrestricted budget it is refused for the session. Nothing is cached.
    @Test @MainActor func oversizedChapterListsWaitForWiFiOrAreRefused() async throws {
        let server = try await ChapterAdmissionFixture.Server()
        server.serve(ChapterAdmissionFixture.document(padding: 6 * 1024 * 1024))
        let cache = URLCache(memoryCapacity: 40_000_000, diskCapacity: 0)
        let fixture = try AuxiliaryNetworkFixture(allowed: ["images"], state: AuxiliaryNetworkFixture.cellular)
        let loader = admitted(fixture, cache: cache), url = server.url.absoluteString
        #expect(try await loader.loadDeferring(stored: nil, externalURL: url) { nil } == EpisodeChapterLoad(chapters: [], deferred: [.unrestricted]))
        try fixture.allow(["images", "streaming"])
        #expect(try await loader.loadDeferring(stored: nil, externalURL: url) { nil }.deferred == [.unrestricted])
        #expect(server.count == 1 && cache.cachedResponse(for: URLRequest(url: server.url)) == nil)
        fixture.network.update(AuxiliaryNetworkFixture.wifi)
        #expect(try await loader.loadDeferring(stored: nil, externalURL: url) { nil } == EpisodeChapterLoad(chapters: ChapterAdmissionFixture.remote))
        #expect(server.count == 2)
        server.serve(ChapterAdmissionFixture.document(padding: 21 * 1024 * 1024))
        #expect(try await loader.loadDeferring(stored: nil, externalURL: url, forceRefresh: true) { nil } == EpisodeChapterLoad(chapters: []))
        #expect(try await loader.loadDeferring(stored: nil, externalURL: url, forceRefresh: true) { nil } == EpisodeChapterLoad(chapters: []))
        #expect(server.count == 3, "refused for the session")
    }
}

extension EpisodeChapterPresentationTests {
    @MainActor private func withRemoteEpisode(_ server: ChapterAdmissionFixture.Server, stored: Bool = true,
                                              _ body: (FeedLibraryStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChapterAdmission-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let feed = URL(string: "https://example.invalid/feed")!
        var episode = ParsedEpisode(identifier: "one", title: "One",
            media: .init(url: "file:///unregistered-test-media.mp3", size: 12, durationMilliseconds: 180_000))
        // Only the external list is under test here: the media is not a stream, so it asks nothing and reads nothing.
        episode.chapters = stored ? ChapterAdmissionFixture.stored : nil; episode.chapterURL = server.url.absoluteString
        _ = try await store.insert(.init(feed: .init(format: .rss, episodes: [episode]), source: feed.absoluteString,
            responseURL: feed, validator: nil, permanentRedirectURL: nil))
        do { try await body(store); try await store.close() }
        catch { try? await store.close(); throw error }
    }

    @MainActor private func access(_ store: FeedLibraryStore, _ fixture: AuxiliaryNetworkFixture) -> EpisodeChapterAccess {
        EpisodeChapterAccess(store: store, loader: EpisodeChapterLoader(transport: URLSessionFeedTransport(),
            cache: URLCache(memoryCapacity: 1_000_000, diskCapacity: 0), userAgent: "chapter-test", admission: fixture.admission),
            remoteRead: { _, _, _, _, _ in .chapters(nil) })
    }

    /// A denied list publishes the stored chapters, then reloads once when its permission returns, by an option change
    /// or by a network change: exactly one request, and the publisher's chapters show.
    @Test(arguments: ["option", "network"]) @MainActor
    func deferredChaptersReloadWhenPermissionReturns(trigger: String) async throws {
        let server = try await ChapterAdmissionFixture.Server()
        try await withRemoteEpisode(server) { store in
            let fixture = try AuxiliaryNetworkFixture(allowed: [], state: AuxiliaryNetworkFixture.cellular)
            let owner = EpisodeChapterPresentation(surface: .cover, store: store, access: access(store, fixture))
            defer { owner.stop() }
            owner.reload(episodeID: 1); await owner.awaitLoading()
            #expect(owner.chapters == ChapterAdmissionFixture.stored && owner.wake != nil)
            #expect(server.count == 0)
            if trigger == "option" { try fixture.allow(["images"]) } else { fixture.network.update(AuxiliaryNetworkFixture.wifi) }
            try await fixture.until { owner.chapters == ChapterAdmissionFixture.remote }
            await owner.awaitLoading()
            #expect(server.count == 1 && owner.wake == nil)
        }
    }

    /// The permission returns between the denial and the arming of the wake, its change signal already gone: the
    /// wake's first check sees it, and the list reloads with exactly one request.
    @Test @MainActor func permissionReturningBeforeWakeIsArmedIsSeen() async throws {
        let server = try await ChapterAdmissionFixture.Server()
        try await withRemoteEpisode(server) { store in
            let fixture = try AuxiliaryNetworkFixture(allowed: [], state: AuxiliaryNetworkFixture.cellular)
            let access = access(store, fixture), admission = fixture.admission, preferences = fixture.preferences
            let calls = Mutex(0)
            let owner = EpisodeChapterPresentation(surface: .cover, store: store, loadDeferring: { episode, force in
                let result = try await access.loadDeferring(episode: episode, forceRefresh: force)
                if calls.withLock({ $0 += 1; return $0 }) == 1 {
                    // No `preferencesChanged`: nobody is listening yet.
                    try await MainActor.run { try preferences.updateAllowed(["images"]) }
                }
                return result
            }, wait: { try await admission.wait(until: $0) })
            defer { owner.stop() }
            owner.reload(episodeID: 1)
            try await fixture.until { owner.chapters == ChapterAdmissionFixture.remote }
            await owner.awaitLoading()
            #expect(server.count == 1 && calls.withLock { $0 } == 2)
        }
    }

    /// A Refresh that had to wait is still owed after a play/pause reload of the same episode, even though the old
    /// list is cached: once permitted, exactly one request brings the publisher's new list.
    @Test @MainActor func deferredChapterRefreshSurvivesAStatusReload() async throws {
        let server = try await ChapterAdmissionFixture.Server()
        try await withRemoteEpisode(server) { store in
            let fixture = try AuxiliaryNetworkFixture(allowed: ["images"], state: AuxiliaryNetworkFixture.wifi)
            let owner = EpisodeChapterPresentation(surface: .cover, store: store, access: access(store, fixture))
            defer { owner.stop() }
            owner.reload(episodeID: 1); await owner.awaitLoading()
            #expect(owner.chapters == ChapterAdmissionFixture.remote && server.count == 1)
            server.serve(ChapterAdmissionFixture.document(title: "Next"))
            try fixture.allow([]); fixture.network.update(AuxiliaryNetworkFixture.cellular)
            owner.reload(episodeID: 1, forceRefresh: true); await owner.awaitLoading()
            #expect(owner.wake != nil && server.count == 1)
            owner.reload(episodeID: 1); await owner.awaitLoading()
            #expect(owner.wake != nil && owner.pendingRefreshEpisodeID == 1 && server.count == 1, "the status reload keeps the owed refresh")
            try fixture.allow(["images"])
            try await fixture.until { owner.chapters?.first?.title == "Next0" }
            await owner.awaitLoading()
            #expect(server.count == 2 && owner.wake == nil && owner.pendingRefreshEpisodeID == nil)
            // Settled: a later status reload uses the cache again.
            owner.reload(episodeID: 1); await owner.awaitLoading()
            #expect(server.count == 2)
        }
    }

    /// A dialog whose only source must wait is not told "no chapters" (its wake stays and its chapters show once
    /// permitted); a definitive empty result still is.
    @Test @MainActor func deferredOnlyDialogIsNotEmptyAndWakes() async throws {
        let server = try await ChapterAdmissionFixture.Server()
        try await withRemoteEpisode(server, stored: false) { store in
            let fixture = try AuxiliaryNetworkFixture(allowed: [], state: AuxiliaryNetworkFixture.cellular)
            let owner = EpisodeChapterPresentation(surface: .dialog, store: store, access: access(store, fixture))
            var empties = 0
            // As the chapters dialog does: "No chapters" closes it.
            owner.onEmpty = { empties += 1; owner.stop() }
            defer { owner.onEmpty = nil; owner.stop() }
            owner.reload(episodeID: 1); await owner.awaitLoading()
            #expect(empties == 0 && owner.wake != nil && owner.chapters == [] && server.count == 0)
            try fixture.allow(["images"])
            try await fixture.until { owner.chapters == ChapterAdmissionFixture.remote }
            #expect(empties == 0 && server.count == 1)
            server.serve(Data("{}".utf8))
            owner.reload(episodeID: 1, forceRefresh: true); await owner.awaitLoading()
            #expect(empties == 1 && server.count == 2)
        }
    }
}
