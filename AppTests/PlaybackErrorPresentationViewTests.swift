import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Supplies a controlled preparation failure through the app's real coordinator/event route.
@MainActor private final class DeferredFailureEngine: PlaybackEngine {
    var reading: PlaybackEngineReading? { nil }
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    var generation: UUID?
    func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) { self.generation = generation }
    func play(commandID: UUID) { }
    func pause(commandID: UUID) { }
    func seek(to positionMilliseconds: Int64, commandID: UUID) { }
    func setSpeed(_ speed: Float, commandID: UUID) throws { }
    func unload() { generation = nil }
}

@MainActor
@Suite(.serialized)
struct PlaybackErrorPresentationViewTests {
    private func element<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let result = view as? T, result.accessibilityIdentifier == id { return result }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: T.self) }.first
    }
    private func player(in view: UIView) -> PlayerView? {
        if let result = view as? PlayerView { return result }
        return view.subviews.lazy.compactMap { player(in: $0) }.first
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    @Test(arguments: [false, true])
    func engineErrorOverSpeedDialogPreservesTheDialogAndOnlyOKCollapsesPlayer(confirm: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlaybackError-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        do {
            let url = URL(string: "https://example.invalid/feed")!
            let feed = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Podcast", episodes: [
                .init(identifier: "episode", title: "Episode", media: .init(url: "https://example.invalid/audio", size: 0, durationMilliseconds: 60_000))
            ]), source: url.absoluteString, responseURL: url, validator: nil, permanentRedirectURL: nil))
            let episode = try #require(feed.episodes.first)
            let engine = DeferredFailureEngine()
            let speed = try PlaybackSpeedPreferenceStore(file: root.appendingPathComponent("speed.json"))
            let time = try TimeDisplayPreferenceStore(file: root.appendingPathComponent("time.json"))
            let playback = PlaybackCoordinator(store: store, engine: engine, speedPreferences: speed)
            let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: playback,
                timeDisplayPreferences: time, navigationPreferences: nil, speedPreferences: speed,
                mobileNetworkPreferences: nil, usage: nil)
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
            window.rootViewController = controller; window.makeKeyAndVisible()
            defer { closeTestWindow(window, restoringKey: previous) }
            await controller.reloadLibrary()?.value
            try await playback.select(episodeID: episode.id, play: false)
            let player = try #require(player(in: controller.view))
            try await wait { !player.isHidden }
            player.setExpanded(true, animated: false)
            let open: UIButton = try #require(element("playerSpeed", in: player))
            open.sendActions(for: .touchUpInside)
            let speedDialog = try #require(controller.presentedViewController as? PlaybackSpeedController)
            try await wait { !speedDialog.isBeingPresented && speedDialog.viewIfLoaded?.window != nil }
            let slider: UIControl = try #require(element("speedSlider", in: speedDialog.view))
            let originalValue = slider.accessibilityValue
            let generation = try #require(engine.generation)
            engine.onEvent?(.failed(generation: generation, message: "Controlled decoder failure"))
            try await wait { speedDialog.presentedViewController is SourceMessageController }
            let error = try #require(speedDialog.presentedViewController as? SourceMessageController)
            try await wait { !error.isBeingPresented && error.viewIfLoaded?.window != nil }
            let message: UILabel = try #require(element("sourceMessage", in: error.view))
            #expect(message.text == Appearance.text("playback_error_generic") + "\n\nControlled decoder failure")
            #expect(playback.phase == .failed && playback.episode?.id == episode.id)
            #expect(player.expansion == 1)
            if confirm {
                let ok: UIButton = try #require(element("sourceMessageOK", in: error.view))
                let frame = ok.convert(ok.bounds, to: window)
                #expect(window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil) === ok)
                ok.sendActions(for: .touchUpInside)
            } else { #expect(error.accessibilityPerformEscape()) }
            try await wait { speedDialog.presentedViewController == nil }
            #expect(controller.presentedViewController === speedDialog)
            #expect(element("speedSlider", in: speedDialog.view, as: UIControl.self) === slider)
            #expect(slider.accessibilityValue == originalValue)
            #expect(player.expansion == (confirm ? 0 : 1))
            #expect(playback.episode?.id == episode.id && !playback.wantsPlayback)
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
}
