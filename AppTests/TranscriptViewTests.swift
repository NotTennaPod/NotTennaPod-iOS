import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

private actor TranscriptViewTransport: FeedHTTPTransport {
    var calls = 0
    var held = false
    var pending: [CheckedContinuation<Void, Never>] = []
    var words = "Text"
    var count = 6
    var fail = false
    func configure(held: Bool = false, words: String = "Text", count: Int = 6, fail: Bool = false) {
        self.held = held; self.words = words; self.count = count; self.fail = fail
    }
    func release() { held = false; let saved = pending; pending = []; saved.forEach { $0.resume() } }
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
        calls += 1
        let words = words, count = count, fail = fail
        if held { await withCheckedContinuation { pending.append($0) } }
        if fail { throw URLError(.notConnectedToInternet) }
        let rows: [[String: Any]] = (0..<count).map { index in
            ["startTime": index * 5, "endTime": (index + 1) * 5, "body": "\(words) \(index).", "speaker": index < 2 ? "Ada" : index < 4 ? "Bob" : "Ada"]
        }
        return .init(url: request.url!, status: 200, body: try JSONSerialization.data(withJSONObject: ["segments": rows]))
    }
}

@MainActor private final class TranscriptViewEngine: PlaybackEngine {
    var reading: PlaybackEngineReading?
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    var seeks: [Int64] = []
    func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
        reading = .init(generation: generation, sample: .init(positionMilliseconds: Int32(positionMilliseconds), durationMilliseconds: 600_000, status: .paused))
    }
    func play(commandID: UUID) { change(commandID, status: .playing) }
    func pause(commandID: UUID) { change(commandID, status: .paused) }
    func seek(to positionMilliseconds: Int64, commandID: UUID) {
        seeks.append(positionMilliseconds); reading?.commandID = commandID
        position(Int32(positionMilliseconds))
    }
    func setSpeed(_ speed: Float, commandID: UUID) { reading?.commandID = commandID }
    func unload() { reading = nil }
    func ready() { if let reading { onEvent?(.ready(reading)) } }
    func position(_ value: Int32) { reading?.sample.positionMilliseconds = value; if let reading { onEvent?(.position(reading)) } }
    private func change(_ command: UUID, status: LibraryPlaybackSession.Status) {
        reading?.commandID = command; reading?.sample.status = status
        if let reading { onEvent?(.stateChanged(reading)) }
    }
}

@MainActor private final class TranscriptDisplayFrames: NSObject {
    private var link: CADisplayLink?
    private var remaining: Int
    private let completion: () -> Void
    init(_ count: Int, completion: @escaping () -> Void) {
        remaining = count; self.completion = completion; super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        self.link = link; link.add(to: .main, forMode: .common)
    }
    @objc private func tick() {
        remaining -= 1
        if remaining == 0 { link?.invalidate(); link = nil; completion() }
    }
}

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TranscriptViewTests {
    private func find<T: UIView>(_ id: String, _ view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let found = view as? T { return found }
        return view.subviews.lazy.compactMap { find(id, $0) as T? }.first
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await condition())
    }
    private func fixture(_ body: (FeedLibraryStore, LibraryFeed, PlaybackCoordinator, TranscriptViewEngine, TranscriptViewTransport, TranscriptLoader) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TranscriptView-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try FeedLibraryStore(url: dir.appendingPathComponent("library.sqlite"))
        do {
            let url = URL(string: "https://example.invalid/feed")!
            let feed = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Podcast", episodes: (0..<3).map { i in
                .init(identifier: "\(i)", title: "Episode \(i)", link: "https://example.invalid/episode",
                    media: .init(url: "https://example.invalid/\(i).mp3", size: 0, durationMilliseconds: 600_000),
                    transcript: i < 2 ? .init(format: .json, url: "https://example.invalid/\(i).json") : nil,
                    socialInteractionURL: "https://example.invalid/comments")
            }), source: url.absoluteString, responseURL: url, validator: nil, permanentRedirectURL: nil))
            let engine = TranscriptViewEngine(), transport = TranscriptViewTransport()
            let playback = PlaybackCoordinator(store: store, engine: engine)
            try await playback.select(episodeID: feed.episodes[0].id, play: false)
            engine.ready(); try await wait { playback.phase == .paused }
            let loader = TranscriptLoader(transport: transport, cache: URLCache(memoryCapacity: 1_000_000, diskCapacity: 0), userAgent: "test")
            try await body(store, feed, playback, engine, transport, loader)
            await transport.release(); try await playback.pause(); try await store.close()
        } catch { try? await store.close(); throw error }
    }

    private func frames(_ count: Int) async {
        await withCheckedContinuation { continuation in
            _ = TranscriptDisplayFrames(count) { continuation.resume() }
        }
    }

    @Test func deliveredMotionRetargetsAndDragCancelsWithoutFollowFighting() async throws {
        try await fixture { store, _, playback, _, transport, loader in
            await transport.configure(count: 100)
            let sheet = TranscriptController(playback: playback, library: store, loader: loader, notice: { _ in }, failure: { Issue.record($0) })
            try await withViewTestWindow { host, _ in
                host.present(sheet, animated: false)
                try await wait { (find("transcriptList", sheet.view) as UITableView?)?.numberOfRows(inSection: 0) == 100 }
                let table: UITableView = try #require(find("transcriptList", sheet.view))
                let follow: UIControl = try #require(find("transcriptFollow", sheet.view))
                try #require(!UIAccessibility.isReduceMotionEnabled)
                let target = table.rectForRow(at: IndexPath(row: 2, section: 0)).minY
                try await playback.seek(to: 15_000)
                try await wait { table.contentOffset.y > 5 }
                #expect(table.contentOffset.y < target)
                let during = table.contentOffset.y
                follow.sendActions(for: .touchUpInside)
                await frames(4)
                #expect(table.contentOffset.y > during) // Unchecking suppresses future requests, not current motion.
                sheet.scrollViewWillBeginDragging(table)
                let stopped = table.contentOffset.y
                await frames(5)
                #expect(table.contentOffset.y == stopped && follow.accessibilityValue == "Off")
                try await playback.seek(to: 20_000); await frames(5)
                #expect(table.contentOffset.y == stopped)
                follow.sendActions(for: .touchUpInside)
                try await playback.seek(to: 15_001)
                try await wait { table.contentOffset.y > stopped }
                try await playback.seek(to: 5_000)
                try await wait { table.contentOffset.y == 0 }
                // A distant target first lands at the bottom edge, then moves toward its top.
                try await playback.seek(to: 300_000)
                let farTop = table.rectForRow(at: IndexPath(row: 59, section: 0)).minY
                try await wait { table.contentOffset.y > 100 }
                #expect(table.contentOffset.y < farTop)
                #expect(sheet.accessibilityPerformEscape())
                let dismissedOffset = table.contentOffset.y
                await frames(5); #expect(table.contentOffset.y == dismissedOffset)
                try await wait { host.presentedViewController == nil }
            }
        }
    }

    @Test func longPanelUsesSourcePortraitLandscapeAndSmallInsets() async throws {
        try await fixture { store, _, playback, _, transport, loader in
            await transport.configure(words: String(repeating: "Long transcript passage ", count: 40), count: 40)
            let sheet = TranscriptController(playback: playback, library: store, loader: loader,
                notice: { _ in }, failure: { Issue.record($0) })
            try await withViewTestWindow { host, _ in
                host.present(sheet, animated: false)
                try await wait { (find("transcriptList", sheet.view) as UITableView?)?.numberOfRows(inSection: 0) == 40 }
                let panel: UIScrollView = try #require(find("transcriptPanel", sheet.view))
                let table: UITableView = try #require(find("transcriptList", sheet.view))
                // Independent Material1.12 resource expectations: normal portrait80,
                // landscape/small24; square470 is portrait and not small.
                let cases: [(CGSize, CGFloat)] = [(.init(width: 411, height: 914),80),
                    (.init(width: 834, height: 1210),80), (.init(width: 466, height: 678),80),
                    (.init(width: 874, height: 402),24), (.init(width: 300, height: 469),24),
                    (.init(width: 300, height: 470),80), (.init(width: 469, height: 469),24),
                    (.init(width: 470, height: 470),80)]
                for (size, inset) in cases {
                    sheet.view.bounds.size = size
                    sheet.additionalSafeAreaInsets = .init(top: 7, left: 11, bottom: 19, right: 61)
                    sheet.view.setNeedsLayout(); sheet.view.layoutIfNeeded()
                    let safe = sheet.view.bounds.inset(by: sheet.view.safeAreaInsets)
                    // Dialog size class margins (80 vs 24) as on Android, within a point.
                    #expect(abs(panel.frame.height - (safe.height - 2 * inset)) <= 1)
                    #expect(abs(panel.frame.midY - safe.midY) <= 1)
                    #expect(abs(panel.frame.width - (safe.width - 48)) <= 1)
                    #expect(table.contentSize.height > table.bounds.height)
                    let close: UIButton = try #require(find("transcriptClose", sheet.view))
                    #expect(panel.bounds.intersects(close.convert(close.bounds, to: panel)))
                }
                // Match the original capture's actual usable viewport, independent
                // of the host device's system safe-area sizes:411.43×840 points.
                sheet.view.bounds.size.width = 1080 / 2.625
                for _ in 0..<3 {
                    let safeHeight = sheet.view.bounds.height - sheet.view.safeAreaInsets.top - sheet.view.safeAreaInsets.bottom
                    let safeWidth = sheet.view.bounds.width - sheet.view.safeAreaInsets.left - sheet.view.safeAreaInsets.right
                    sheet.view.bounds.size.height += 840 - safeHeight
                    sheet.view.bounds.size.width += 1080 / 2.625 - safeWidth
                    sheet.view.setNeedsLayout(); sheet.view.layoutIfNeeded()
                }
                let equalViewport = sheet.view.bounds.inset(by: sheet.view.safeAreaInsets)
                #expect(abs(equalViewport.height - 840) < 0.01)
                #expect(abs(equalViewport.width - 1080 / 2.625) < 0.01)
                #expect(abs(panel.frame.height - 680) <= 1)
                #expect(abs(panel.frame.width - 954 / 2.625) <= 1)
                #expect(sheet.accessibilityPerformEscape()); try await wait { host.presentedViewController == nil }
            }
        }
    }

    @Test func hundredLineVisualCapKeepsFullCopyAndReachableFollowingRows() async throws {
        try await fixture { store, _, playback, _, transport, loader in
            let words = (1...101).map { "Line \($0)" }.joined(separator: "\n")
            await transport.configure(words: words, count: 2)
            var copied = ""
            let sheet = TranscriptController(playback: playback, library: store, loader: loader,
                notice: { _ in }, failure: { Issue.record($0) }, copyText: { copied = $0 })
            try await withViewTestWindow { host, _ in
                host.present(sheet, animated: false)
                try await wait { (find("transcriptList", sheet.view) as UITableView?)?.numberOfRows(inSection: 0) == 2 }
                let table: UITableView = try #require(find("transcriptList", sheet.view))
                let first: UIButton = try #require(find("transcriptSegment-0", sheet.view))
                let line = Appearance.font(14, compatibleWith: sheet.view.traitCollection).lineHeight
                #expect(first.bounds.height >= line * 99 && first.bounds.height <= line * 100 + 5)
                _ = first.accessibilityCustomActions?.first?.actionHandler?(first.accessibilityCustomActions!.first!)
                let copy: UIButton = try #require(find("transcriptCopy", sheet.view)); copy.sendActions(for: .touchUpInside)
                #expect(copied.contains("Line 101"))
                table.scrollToRow(at: IndexPath(row: 1, section: 0), at: .top, animated: false); table.layoutIfNeeded()
                #expect((find("transcriptSegment-1", sheet.view) as UIButton?) != nil)
                #expect(sheet.accessibilityPerformEscape()); try await wait { host.presentedViewController == nil }
            }
        }
    }

    @Test func shortCompositionSelectionCopyAndPlayback() async throws {
        try await fixture { store, _, playback, engine, _, loader in
            var copied: String?
            let sheet = TranscriptController(playback: playback, library: store, loader: loader,
                notice: { _ in Issue.record("Unexpected notice") }, failure: { Issue.record($0) }, copyText: { copied = $0 })
            try await withViewTestWindow { host, _ in
                host.present(sheet, animated: false)
                try await wait { (find("transcriptList", sheet.view) as UITableView?)?.numberOfRows(inSection: 0) == 6 }
                let panel: UIScrollView = try #require(find("transcriptPanel", sheet.view))
                let table: UITableView = try #require(find("transcriptList", sheet.view))
                let follow: UIControl = try #require(find("transcriptFollow", sheet.view))
                let first: UIButton = try #require(find("transcriptSegment-0", sheet.view))
                #expect(!first.accessibilityTraits.contains(.selected))
                #expect(abs(panel.frame.width - (sheet.view.bounds.width - sheet.view.safeAreaInsets.left - sheet.view.safeAreaInsets.right - 48)) < 1)
                #expect(abs(table.frame.minY - 64) < 1)
                // Six short segments fit without scrolling the panel.
                #expect(table.contentSize.height <= table.bounds.height + 0.5)
                #expect(panel.contentSize.height <= panel.bounds.height + 0.5)
                #expect(follow.accessibilityValue == "On")
                #expect(first.accessibilityCustomActions?.first?.actionHandler?(first.accessibilityCustomActions!.first!) == true)
                #expect(follow.accessibilityValue == "Off")
                try await wait { (find("transcriptSegment-0", sheet.view) as UIButton?)?.accessibilityTraits.contains(.selected) == true }
                let selected: UIButton = try #require(find("transcriptSegment-0", sheet.view))
                #expect(selected.backgroundColor?.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)) == UIColor(red: 205/255, green: 228/255, blue: 244/255, alpha: 1))
                #expect(abs(selected.frame.width - (table.bounds.width - 4)) < 1)
                let third: UIButton = try #require(find("transcriptSegment-2", sheet.view))
                third.sendActions(for: .touchUpInside)
                let copy: UIButton = try #require(find("transcriptCopy", sheet.view)); copy.sendActions(for: .touchUpInside)
                #expect(copied == "Ada : Text 0.\n[...]\n\nBob : Text 2.")
                #expect(follow.accessibilityValue == "On")
                let target: UIButton = try #require(find("transcriptSegment-2", sheet.view)); target.sendActions(for: .touchUpInside)
                try await wait { engine.seeks.last == 10_000 }
                #expect(!playback.wantsPlayback)
                let active: UIButton = try #require(find("transcriptSegment-2", sheet.view)); active.sendActions(for: .touchUpInside)
                try await wait { playback.wantsPlayback }
                let playing: UIButton = try #require(find("transcriptSegment-2", sheet.view)); playing.sendActions(for: .touchUpInside)
                try await wait { !playback.wantsPlayback }
                #expect(sheet.accessibilityPerformEscape()); try await wait { host.presentedViewController == nil }
            }
        }
    }

    @Test func refreshRetainsRowsThenRecoversFromFailureAndCancelsStaleEpisode() async throws {
        try await fixture { store, feed, playback, engine, transport, loader in
            var notices: [String] = []
            let sheet = TranscriptController(playback: playback, library: store, loader: loader, notice: { notices.append($0) }, failure: { Issue.record($0) })
            try await withViewTestWindow { host, _ in
                host.present(sheet, animated: false)
                try await wait { (find("transcriptList", sheet.view) as UITableView?)?.numberOfRows(inSection: 0) == 6 }
                let table: UITableView = try #require(find("transcriptList", sheet.view))
                let refresh: UIButton = try #require(find("transcriptRefresh", sheet.view))
                await transport.configure(held: true, words: "Obsolete")
                refresh.sendActions(for: .touchUpInside)
                try await wait { await transport.calls == 2 }
                #expect(table.numberOfRows(inSection: 0) == 6)
                await transport.configure(words: "Replacement")
                try await playback.select(episodeID: feed.episodes[1].id, play: false); engine.ready()
                try await wait { (find("transcriptSegment-0", sheet.view) as UIButton?)?.currentTitle == "Replacement 0." }
                await transport.release()
                await transport.configure(fail: true)
                refresh.sendActions(for: .touchUpInside)
                try await wait { table.numberOfRows(inSection: 0) == 0 }
                let spinner: UIActivityIndicatorView = try #require(find("transcriptLoading", sheet.view))
                #expect(!spinner.isAnimating)
                await transport.configure(words: "Recovered")
                refresh.sendActions(for: .touchUpInside)
                try await wait { (find("transcriptSegment-0", sheet.view) as UIButton?)?.currentTitle == "Recovered 0." }
                try await playback.select(episodeID: feed.episodes[2].id, play: false); engine.ready()
                try await wait { host.presentedViewController == nil && notices == ["No transcript"] }
            }
        }
    }

    @Test(arguments: [false, true])
    func asymmetricResizeSelectionAndWholeCompositionScrolling(rtl: Bool) async throws {
        try await fixture { store, _, playback, engine, transport, loader in
            await transport.configure(words: String(repeating: "Long transcript passage ", count: 5), count: 40)
            let sheet = TranscriptController(playback: playback, library: store, loader: loader, notice: { _ in }, failure: { Issue.record($0) })
            try await withViewTestWindow { host, _ in
                host.present(sheet, animated: false)
                try await wait { (find("transcriptList", sheet.view) as UITableView?)?.numberOfRows(inSection: 0) == 40 }
                // Source permits one initial follow scroll even when Follow is off.
                // Establish that first position event before testing a later manual scroll.
                try await playback.seek(to: 6_000)
                try await wait { (find("transcriptSegment-1", sheet.view) as UIButton?)?.accessibilityTraits.contains(.selected) == true }
                sheet.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                let table: UITableView = try #require(find("transcriptList", sheet.view))
                let panel: UIScrollView = try #require(find("transcriptPanel", sheet.view))
                let first: UIButton = try #require(find("transcriptSegment-0", sheet.view))
                _ = first.accessibilityCustomActions?.first?.actionHandler?(first.accessibilityCustomActions!.first!)
                table.setContentOffset(CGPoint(x: 0, y: 180), animated: false); table.layoutIfNeeded()
                let reading = table.indexPathsForVisibleRows!.first!.row
                sheet.view.bounds.size = CGSize(width: 240, height: 240)
                sheet.additionalSafeAreaInsets = .init(top: 0, left: 11, bottom: 0, right: 61)
                sheet.view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
                sheet.view.setNeedsLayout(); sheet.view.layoutIfNeeded()
                #expect(panel.isScrollEnabled && panel.contentSize.height > panel.bounds.height)
                #expect(table.indexPathsForVisibleRows?.first?.row == reading)
                let follow: UIControl = try #require(find("transcriptFollow", sheet.view))
                let cancel: UIButton = try #require(find("transcriptCancelSelection", sheet.view))
                let copy: UIButton = try #require(find("transcriptCopy", sheet.view))
                let bar = try #require(copy.superview as? UIScrollView)
                #expect(bar.contentSize.width >= copy.frame.maxX && copy.frame.minX >= 0)
                #expect(bar.contentSize.width >= cancel.frame.maxX && cancel.frame.minX >= 0)
                follow.sendActions(for: .touchUpInside); #expect(follow.accessibilityValue == "On")
                panel.delegate?.scrollViewWillBeginDragging?(panel)
                #expect(follow.accessibilityValue == "Off")
                let offset = table.contentOffset
                try await playback.seek(to: 100_000)
                try await wait { playback.sample?.positionMilliseconds == 100_000 }
                #expect(table.contentOffset == offset)
                panel.setContentOffset(CGPoint(x: 0, y: panel.contentSize.height - panel.bounds.height), animated: false)
                let close: UIButton = try #require(find("transcriptClose", sheet.view))
                #expect(panel.bounds.intersects(close.convert(close.bounds, to: panel)))
                // Finish selection after horizontally scrolling the constrained toolbar.
                bar.setContentOffset(CGPoint(x: bar.contentSize.width - bar.bounds.width, y: 0), animated: false)
                cancel.sendActions(for: .touchUpInside); sheet.view.setNeedsLayout(); sheet.view.layoutIfNeeded()
                let refresh: UIButton = try #require(find("transcriptRefresh", sheet.view))
                #expect(bar.bounds.contains(refresh.frame))
                // Preserve progress within a paragraph when its line count shrinks.
                let anchor = table.indexPathsForVisibleRows!.first!
                let before = table.rectForRow(at: anchor)
                table.setContentOffset(CGPoint(x: 0, y: before.minY + before.height * 0.5), animated: false)
                sheet.view.bounds.size = host.view.bounds.size; sheet.additionalSafeAreaInsets = .zero
                sheet.view.traitOverrides.preferredContentSizeCategory = .large
                sheet.view.setNeedsLayout(); sheet.view.layoutIfNeeded()
                let after = table.rectForRow(at: anchor)
                #expect(table.indexPathsForVisibleRows?.first == anchor)
                #expect(abs((table.contentOffset.y - after.minY) / after.height - 0.5) < 0.06)
                #expect(cancel.isHidden && copy.isHidden && follow.accessibilityValue == "On")
                #expect(bar.bounds.contains(refresh.frame))
                #expect(sheet.accessibilityPerformEscape()); try await wait { host.presentedViewController == nil }
            }
        }
    }
}
