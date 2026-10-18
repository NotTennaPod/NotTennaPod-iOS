import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor private final class PreviewPlaybackEngine: PlaybackEngine {
    var reading: PlaybackEngineReading?
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    private(set) var loads = 0
    func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
        loads += 1
        reading = .init(generation: generation, sample: .init(positionMilliseconds: Int32(positionMilliseconds),
            durationMilliseconds: 60_000, status: .paused))
    }
    func play(commandID: UUID) { reading?.commandID = commandID; reading?.sample.status = .playing }
    func pause(commandID: UUID) { reading?.commandID = commandID; reading?.sample.status = .paused }
    func seek(to positionMilliseconds: Int64, commandID: UUID) {
        reading?.commandID = commandID; reading?.sample.positionMilliseconds = Int32(positionMilliseconds)
    }
    func setSpeed(_ speed: Float, commandID: UUID) throws { reading?.commandID = commandID; reading?.speed = speed }
    func unload() { reading = nil }
    func ready() { if let reading { onEvent?(.ready(reading)) } }
    func position(_ milliseconds: Int32) {
        reading?.sample.positionMilliseconds = milliseconds
        if let reading { onEvent?(.position(reading)) }
    }
}

@MainActor @Suite(.serialized)
struct FeedPreviewLifecycleTests {
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let value = view as? T { return value }
        for child in view.subviews { if let value: T = find(id, in: child) { return value } }
        return nil
    }
    private func wait(_ predicate: () async throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while try await !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(try await predicate(), sourceLocation: sourceLocation)
    }
    private func fixture(now: Date = Date(), _ body: (FeedLibraryStore, URL, LibraryFeed) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewLifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        do {
            var parsed = ParsedFeed(format: .rss, title: "Preview lifecycle", episodes: [
                .init(identifier: "episode", title: "Preview episode", media: .init(url: "https://example.invalid/audio", size: 100, durationMilliseconds: 60_000))
            ])
            parsed.isPaged = true; parsed.nextPageURL = "https://example.invalid/page2"
            let url = URL(string: "https://example.invalid/feed")!
            let feed = try await store.preparePreview(.init(feed: parsed, source: url.absoluteString,
                responseURL: url, validator: nil, permanentRedirectURL: nil), now: now)
            try await body(store, root, feed); try await store.close()
        } catch { try? await store.close(); throw error }
    }

    @Test(arguments: ["stale", "fresh", "archived", "subscribed"])
    func stalePreviewRequestsNextPageWithoutAdmissionAndRetainsWorkAfterClosing(scenario: String) async throws {
        try await fixture(now: scenario == "fresh" ? Date().addingTimeInterval(60) : Date(timeIntervalSince1970: 1)) { store, _, original in
            try await store.updatePreferences(feedID: original.id) { feed in
                if scenario == "archived" { feed.subscriptionState = .archived }
                if scenario == "subscribed" { feed.subscriptionState = .subscribed }
            }
            let before = try #require(try await store.feed(id: original.id))
            // Hold the accepted owner until teardown; UI reloads must not replace it.
            let owner = ManualFeedRefreshCoordinator(store: store, execute: { _ in try await Task.sleep(for: .seconds(50)) })
            var accepted: [FeedRefreshRequest] = []
            owner.onChange = { if case .active(let request) = $0 { accepted.append(request) } }
            defer { owner.suspend() }
            let child = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
                timeDisplayPreferences: nil, navigationPreferences: nil, speedPreferences: nil,
                mobileNetworkPreferences: nil, usage: nil, manualRefresh: owner, previewFeedID: original.id,
                refreshNetwork: { Issue.record("Stale preview must bypass the admission/network prompt path"); return .init(connected: false, metered: true, cellular: true) })
            let card = FeedPreviewController(content: child)
            try await withViewTestWindow { host, _ in
                host.present(card, animated: false)
                try await wait { card.viewIfLoaded?.window != nil && !card.isBeingPresented }
                await child.reloadLibrary()?.value
                if scenario == "stale" { try await wait { accepted.count == 1 } }
                for width in [402.0, 720, 320] {
                    card.view.frame.size.width = width; card.view.setNeedsLayout(); card.view.layoutIfNeeded()
                    await child.reloadLibrary()?.value
                }
                #expect(accepted.count == (scenario == "stale" ? 1 : 0))
                #expect(card.presentedViewController == nil && child.presentedViewController == nil)
                if let request = accepted.first {
                    #expect(request.feedID == original.id && request.nextPage && request.force && request.requiresNetwork)
                    #expect(try await store.manualRefreshRequest() == request)
                }
                #expect(try await store.feed(id: original.id) == before)
                await withCheckedContinuation { done in card.dismiss(animated: false) { done.resume() } }
                if let request = accepted.first { #expect(try await store.manualRefreshRequest() == request) }
            }
            owner.suspend()
        }
    }

    @Test(arguments: ["streamingOnce", "streamingAlways", "streamingCancel"])
    func sharedPlayerPromptsUpdatesAndErrorsStayConnectedInsidePreview(choice: String) async throws {
        try await fixture { store, directory, feed in
            let episode = try #require(feed.episodes.first)
            try await store.updateEpisode(id: episode.id) { $0.userState.positionMilliseconds = 5_000 }
            let time = try TimeDisplayPreferenceStore(file: directory.appendingPathComponent("time.json"))
            let mobile = try MobileNetworkPreferenceStore(file: directory.appendingPathComponent("mobile.json"))
            let engine = PreviewPlaybackEngine()
            let playback = PlaybackCoordinator(store: store, engine: engine,
                streamingAccess: { _ in .init(needsStreaming: true, streamingAllowed: mobile.allows(.streaming)) })
            let root = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: playback,
                timeDisplayPreferences: time, navigationPreferences: nil, speedPreferences: nil,
                mobileNetworkPreferences: mobile, usage: nil)
            let child = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: playback,
                timeDisplayPreferences: time, navigationPreferences: nil, speedPreferences: nil,
                mobileNetworkPreferences: mobile, usage: nil, previewFeedID: feed.id)
            let card = FeedPreviewController(content: child)
            do {
                try await withViewTestWindow { host, _ in
                    host.addChild(root); host.view.addSubview(root.view); root.didMove(toParent: host)
                    root.view.frame = host.view.bounds; root.view.layoutIfNeeded()
                    await root.reloadLibrary()?.value
                    root.present(card, animated: false)
                    try await wait { card.viewIfLoaded?.window != nil && !card.isBeingPresented }
                    await child.reloadLibrary()?.value
                    let row: UIButton = try #require(find("episode-\(episode.id)", in: child.view))
                    row.sendActions(for: .touchUpInside)
                    let stream: UIButton = try #require(find("episodePrimaryAction", in: child.view))
                    #expect(stream.title(for: .normal) == "Stream")
                    stream.sendActions(for: .touchUpInside)
                    try await wait { card.presentedViewController is SourceMessageController && card.presentedViewController?.isBeingPresented == false }
                    let prompt = try #require(card.presentedViewController)
                    #expect(playback.phase == .awaitingStreamingConfirmation && engine.loads == 0)
                    let button: UIButton = try #require(find(choice, in: prompt.view))
                    button.sendActions(for: .touchUpInside)
                    try await wait { card.presentedViewController == nil }
                    #expect(root.presentedViewController === card)
                    if choice == "streamingCancel" {
                        #expect(engine.loads == 0 && !playback.wantsPlayback)
                    } else {
                        try await wait { engine.loads == 1 }
                        #expect(mobile.allows(.streaming) == (choice == "streamingAlways"))
                        engine.ready()
                        try await wait { playback.phase == .playing && stream.title(for: .normal) == "Pause" }
                        let back: UIButton = try #require(find("toolbarBack", in: child.view))
                        back.sendActions(for: .touchUpInside); child.view.layoutIfNeeded()
                        try await wait { (find("episode-\(episode.id)", in: child.view) as UIButton?) != nil }
                        // Playback reports its position repeatedly; the list rebuilt by Back shows it within a tick.
                        var tick: Int32 = 12_000
                        try await wait {
                            tick += 1; engine.position(tick)
                            return (find("episode-\(episode.id)", in: child.view) as UIButton?)?.accessibilityValue?.contains("00:00:12") == true
                        }
                        #expect(engine.loads == 1)
                        let generation = try #require(engine.reading?.generation)
                        engine.onEvent?(.failed(generation: generation, message: "Controlled preview failure"))
                        try await wait { card.presentedViewController is SourceMessageController && card.presentedViewController?.isBeingPresented == false }
                        let error = try #require(card.presentedViewController)
                        let message: UILabel = try #require(find("sourceMessage", in: error.view))
                        #expect(message.text?.contains("Controlled preview failure") == true)
                        let ok: UIButton = try #require(find("sourceMessageOK", in: error.view))
                        ok.sendActions(for: .touchUpInside)
                        try await wait { card.presentedViewController == nil }
                        #expect(root.presentedViewController === card && playback.phase == .failed)
                    }
                    #expect(try await store.feed(id: feed.id)?.subscriptionState == .notSubscribed)
                    await withCheckedContinuation { done in card.dismiss(animated: false) { done.resume() } }
                }
                try await playback.stop()
            } catch { try? await playback.stop(); throw error }
        }
    }

    /// A preview's video player offers Transcript with the app's admitted loader, not an unrestricted one: with Cover
    /// images off on cellular the preview's transcript makes no request, and it loads once Cover images is allowed.
    @Test func previewTranscriptFollowsTheMobileUpdatesOptions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewTranscript-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        do {
            let parsed = ParsedFeed(format: .rss, title: "Preview video", episodes: [
                .init(identifier: "video", title: "Preview video episode",
                      media: .init(url: "https://example.invalid/video.mp4", size: 100, durationMilliseconds: 60_000),
                      transcript: .init(format: .json, url: "https://example.invalid/video.json"))
            ])
            let url = URL(string: "https://example.invalid/feed")!
            let feed = try await store.preparePreview(.init(feed: parsed, source: url.absoluteString,
                responseURL: url, validator: nil, permanentRedirectURL: nil), now: Date())
            let episode = try #require(feed.episodes.first)
            let time = try TimeDisplayPreferenceStore(file: root.appendingPathComponent("time.json"))
            let mobile = try MobileNetworkPreferenceStore(file: root.appendingPathComponent("mobile.json"))
            try mobile.updateAllowed(["streaming"])
            let network = DownloadNetworkMonitor(startMonitoring: false)
            let admission = AuxiliaryNetworkAdmission(network: network, preferences: mobile)
            let transport = PreviewTranscriptTransport()
            let loader = TranscriptLoader(transport: transport, cache: URLCache(memoryCapacity: 1_000_000, diskCapacity: 0),
                                          userAgent: "test", admission: admission)
            let engine = PreviewPlaybackEngine()
            let playback = PlaybackCoordinator(store: store, engine: engine)
            let library = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: playback,
                timeDisplayPreferences: time, navigationPreferences: nil, speedPreferences: nil,
                mobileNetworkPreferences: mobile, usage: nil, transcriptLoader: loader)
            do {
                try await withViewTestWindow { host, _ in
                    host.addChild(library); host.view.addSubview(library.view); library.didMove(toParent: host)
                    library.view.frame = host.view.bounds; library.view.layoutIfNeeded()
                    await library.reloadLibrary()?.value
                    library.showPreview(feed.id, recoveredBySearch: false)
                    try await wait { library.presentedViewController is FeedPreviewController && library.presentedViewController?.isBeingPresented == false }
                    let card = try #require(library.presentedViewController as? FeedPreviewController)
                    let child = try #require(card.contentController as? LibraryViewController)
                    #expect(child.transcriptLoader === loader)
                    try await playback.select(episodeID: episode.id, play: false); engine.ready()
                    try await wait { playback.phase == .paused }
                    // What the preview's video menu presents for Transcript.
                    let sheet = TranscriptController(playback: playback, library: store, loader: child.transcriptLoader,
                        notice: { _ in }, failure: { Issue.record($0) })
                    card.present(sheet, animated: false)
                    // The admission is asked: the fetch waits for the first network observation, then is denied.
                    try await wait { network.pendingObservationCount == 1 }
                    network.update(.init(connected: true, metered: true, cellular: true))
                    #expect(await transport.calls == 0)
                    try mobile.updateAllowed(["streaming", "images"]); admission.preferencesChanged()
                    try await wait { (find("transcriptSegment-0", in: sheet.view) as UIButton?)?.currentTitle == "Preview text." }
                    #expect(await transport.calls == 1)
                    await withCheckedContinuation { done in sheet.dismiss(animated: false) { done.resume() } }
                    await withCheckedContinuation { done in card.dismiss(animated: false) { done.resume() } }
                }
                try await playback.stop()
            } catch { try? await playback.stop(); throw error }
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
}

private actor PreviewTranscriptTransport: FeedHTTPTransport {
    var calls = 0
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
        calls += 1
        return .init(url: request.url!, status: 200,
                     body: Data("{\"segments\":[{\"startTime\":0,\"endTime\":5,\"body\":\"Preview text.\"}]}".utf8))
    }
}
