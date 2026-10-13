import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PlayerShellAnimationViewTests {
    private func element<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let result = view as? T, result.accessibilityIdentifier == id { return result }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: T.self) }.first
    }
    private func player(in view: UIView) -> PlayerView? {
        if let player = view as? PlayerView { return player }
        return view.subviews.lazy.compactMap { player(in: $0) }.first
    }
    private func wait(details: () -> String = { "" }, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "Expected displayed state before the deadline: \(details())")
    }
    private func mounted(bottomNavigation: Bool,
                         body: @MainActor (LibraryViewController, PlayerView, PlaybackCoordinator) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PlayerShell-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        do {
            let source = URL(string: "https://example.invalid/feed")!
            let feed = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Podcast", episodes: [
                ParsedEpisode(identifier: "episode", title: "Episode", description: "Notes",
                    media: ParsedMedia(url: "https://example.invalid/media", size: 0, durationMilliseconds: 60_000))
            ]), source: source.absoluteString, responseURL: source, validator: nil, permanentRedirectURL: nil))
            let episode = try #require(feed.episodes.first)
            _ = try await store.beginPlayback(episodeID: episode.id)
            let playback = PlaybackCoordinator(store: store, engine: AVPlayerPlaybackEngine(muted: true))
            try await playback.restore() // Restored selection; no media request or audio output.
            let time = try TimeDisplayPreferenceStore(file: directory.appendingPathComponent("time.json"))
            let navigation = try NavigationPreferenceStore(file: directory.appendingPathComponent("navigation.json"))
            var preferences = navigation.value; preferences.bottomNavigation = bottomNavigation
            try navigation.update(preferences)
            let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: playback,
                timeDisplayPreferences: time, navigationPreferences: navigation, speedPreferences: nil,
                mobileNetworkPreferences: nil, usage: nil)
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.keyWindow, window = UIWindow(windowScene: scene), host = UIViewController()
            window.rootViewController = host; window.makeKeyAndVisible()
            defer {
                controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent()
                window.isHidden = true; previous?.makeKey()
            }
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            controller.view.frame = host.view.bounds
            controller.additionalSafeAreaInsets = .init(top: 0, left: 31, bottom: 0, right: 7)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            await controller.reloadLibrary()?.value
            controller.view.layoutIfNeeded()
            let player = try #require(player(in: controller.view))
            try #require(!player.isHidden && player.window != nil)
            try await body(controller, player, playback)
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

    @Test(arguments: [false, true])
    func expandAndCollapseAnimateTheActualSheetFrame(bottomNavigation: Bool) async throws {
        try await mounted(bottomNavigation: bottomNavigation) { controller, player, playback in
            let selected = playback.episode?.id, position = playback.sample?.positionMilliseconds
            player.setExpanded(true, animated: false); controller.view.layoutIfNeeded()
            let expanded = player.frame
            player.setExpanded(false, animated: false); controller.view.layoutIfNeeded()
            let collapsed = player.frame
            try #require(expanded.minY < collapsed.minY)
            let sampler = PlayerFrameSampler(view: player)
            sampler.start(); defer { sampler.stop() }
            try await wait { sampler.frames.last == collapsed }
            for (id, destination, start) in [("miniPlayerOpen", expanded, collapsed), ("playerCollapse", collapsed, expanded)] {
                sampler.frames.removeAll()
                let control: UIButton = try #require(element(id, in: player))
                control.sendActions(for: .touchUpInside)
                // Do not manually flush the shell here: the action owns its animation transaction.
                try await wait {
                    sampler.frames.last.map { abs($0.minY - destination.minY) < 0.5 } == true
                        && (player.layer.animationKeys()?.isEmpty ?? true)
                }
                #expect(sampler.frames.contains { $0.minY > expanded.minY + 1 && $0.minY < collapsed.minY - 1 },
                        "Expected intermediate displayed positions from \(start.minY) to \(destination.minY); got \(sampler.frames.map(\.minY))")
                #expect(player.frame == destination)
                #expect(playback.episode?.id == selected && playback.sample?.positionMilliseconds == position)
                let settledID = id == "miniPlayerOpen" ? "playerCollapse" : "miniPlayerOpen"
                let settled: UIButton = try #require(element(settledID, in: player))
                let window = try #require(controller.view.window)
                let frame = settled.convert(settled.bounds, to: window)
                #expect(window.bounds.contains(frame))
                #expect(window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil) === settled)
            }
        }
    }

    @Test(arguments: [false, true])
    func reversingAnActiveExpansionReturnsFromItsDisplayedPosition(bottomNavigation: Bool) async throws {
        try await mounted(bottomNavigation: bottomNavigation) { controller, player, playback in
            let selected = playback.episode?.id, position = playback.sample?.positionMilliseconds
            player.setExpanded(true, animated: false); controller.view.layoutIfNeeded()
            let expanded = player.frame
            player.setExpanded(false, animated: false); controller.view.layoutIfNeeded()
            let collapsed = player.frame
            let distance = collapsed.minY - expanded.minY
            try #require(distance > 0)
            let sampler = PlayerFrameSampler(view: player)
            sampler.start(); defer { sampler.stop() }
            try await wait { sampler.frames.last == collapsed }
            let open: UIButton = try #require(element("miniPlayerOpen", in: player))
            open.sendActions(for: .touchUpInside)
            try await wait {
                sampler.frames.last.map {
                    $0.minY > expanded.minY + distance * 0.25 && $0.minY < expanded.minY + distance * 0.75
                } == true
            }
            let reversalY = try #require(sampler.frames.last).minY
            sampler.frames.removeAll()
            let close: UIButton = try #require(element("playerCollapse", in: player))
            close.sendActions(for: .touchUpInside)
            try await wait {
                sampler.frames.last.map { abs($0.minY - collapsed.minY) < 0.5 } == true
                    && (player.layer.animationKeys()?.isEmpty ?? true)
            }
            #expect(sampler.frames.contains { $0.minY > reversalY + 1 && $0.minY < collapsed.minY - 1 })
            #expect(sampler.frames.allSatisfy { $0.minY > expanded.minY + 1 && $0.minY <= collapsed.minY + 0.5 })
            #expect(playback.episode?.id == selected && playback.sample?.positionMilliseconds == position)
            #expect(player.expansion == 0 && player.frame == collapsed)
        }
    }

    @Test func nonanimatedChangesAndInteractiveUpdatesCommitOwnedGeometryImmediately() async throws {
        try await mounted(bottomNavigation: true) { controller, player, _ in
            let collapsed = player.frame
            player.setExpanded(true, animated: false)
            #expect(player.frame.minY < collapsed.minY)
            let expanded = player.frame
            player.setExpanded(false, animated: false)
            #expect(player.frame == collapsed)
            player.setExpanded(false, animated: false)
            #expect(player.frame == collapsed)
            let pan = PlayerControlledPan()
            player.addGestureRecognizer(pan)
            pan.state = .began
            try #require(pan.state == .began)
            player.perform(NSSelectorFromString("drag:"), with: pan)
            pan.displacement.y = -(player.expandedSize.height - 64) * 0.4
            pan.state = .changed
            try #require(pan.state == .changed)
            player.perform(NSSelectorFromString("drag:"), with: pan)
            #expect(abs(player.expansion - 0.4) < 0.001)
            #expect(player.frame.minY < collapsed.minY && player.frame.minY > expanded.minY)
            pan.state = .cancelled
            try #require(pan.state == .cancelled)
            player.perform(NSSelectorFromString("drag:"), with: pan)
            #expect(player.expansion == 0)
            try await wait(details: { "frame=\(player.frame), collapsed=\(collapsed), expansion=\(player.expansion), keys=\(player.layer.animationKeys() ?? [])" }) {
                (player.layer.animationKeys()?.isEmpty ?? true) && player.frame == collapsed
            }
            #expect(player.expansion == 0)
            #expect(element("miniPlayerOpen", in: controller.view, as: UIButton.self) != nil)
        }
    }
}

@MainActor
private final class PlayerFrameSampler: NSObject {
    let view: UIView
    var frames: [CGRect] = []
    private var link: CADisplayLink?
    init(view: UIView) { self.view = view }
    func start() {
        let link = CADisplayLink(target: self, selector: #selector(sample))
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func sample() { frames.append(view.layer.presentation()?.frame ?? view.frame) }
}

@MainActor
private final class PlayerControlledPan: UIPanGestureRecognizer {
    private var phase: UIGestureRecognizer.State = .possible
    var displacement = CGPoint.zero
    override var state: UIGestureRecognizer.State {
        get { phase }
        set { phase = newValue }
    }
    override func translation(in view: UIView?) -> CGPoint { displacement }
    override func velocity(in view: UIView?) -> CGPoint { .zero }
}
