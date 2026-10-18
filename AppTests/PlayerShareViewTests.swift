import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

private final class ShareViewTestBundleMarker {}

@MainActor private final class SharePositionEngine: PlaybackEngine {
    var reading: PlaybackEngineReading?
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    private var generation: UUID?
    private var command: UUID?
    func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) { self.generation = generation; command = generation }
    func play(commandID: UUID) { command = commandID }
    func pause(commandID: UUID) { command = commandID }
    func seek(to positionMilliseconds: Int64, commandID: UUID) { command = commandID }
    func setSpeed(_ speed: Float, commandID: UUID) throws { command = commandID }
    func unload() { reading = nil }
    func ready() {
        guard let generation, let command else { return }
        let value = PlaybackEngineReading(generation: generation, commandID: command,
            sample: .init(positionMilliseconds: 0, durationMilliseconds: 60_000, status: .playing))
        reading = value; onEvent?(.ready(value))
    }
    func position(_ milliseconds: Int32) {
        guard var value = reading else { return }
        value.sample.positionMilliseconds = milliseconds
        reading = value; onEvent?(.position(value))
    }
}

@MainActor @Suite(.serialized)
struct PlayerShareViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(id, in: $0) as T? }.first
    }
    private func player(in view: UIView) -> PlayerView? { (view as? PlayerView) ?? view.subviews.lazy.compactMap { player(in: $0) }.first }
    private func wait(seconds: Int = 5, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
    private func fixture(_ body: (FeedLibraryStore, LibraryFeed, PlaybackCoordinator, SharePositionEngine, TimeDisplayPreferenceStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PlayerShare-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        do {
            let source = URL(string: "https://example.invalid/feed")!
            let feed = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Podcast", episodes: [
                .init(identifier: "episode", title: "Episode", description: "Notes", link: "https://example.invalid/episode",
                    media: .init(url: "https://example.invalid/audio.mp3", size: 0, durationMilliseconds: 60_000))
            ]), source: source.absoluteString, responseURL: source, validator: nil, permanentRedirectURL: nil))
            let engine = SharePositionEngine()
            let playback = PlaybackCoordinator(store: store, engine: engine, clock: { Date(timeIntervalSince1970: 1_700_000_000) })
            try await playback.select(episodeID: feed.episodes[0].id)
            engine.ready(); try await wait { playback.phase == .playing }
            engine.position(12_345); try await wait { playback.sample?.positionMilliseconds == 12_345 }
            try await body(store, feed, playback, engine, TimeDisplayPreferenceStore(file: directory.appendingPathComponent("time.json")))
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

    @Test(arguments: [false, true])
    func shareCapturesLivePositionAndRemovesLocalFeedSlot(rtl: Bool) async throws {
        try await fixture { store, feed, playback, _, time in
            let player = PlayerView(playback: playback, timeDisplayPreferences: time, library: store)
            player.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            player.frame = CGRect(x: 0, y: 0, width: 402, height: 800); player.expandedSize = player.bounds.size
            player.update(feed: feed, stored: feed.episodes.first { $0.id == playback.episode?.id }); player.setExpanded(true, animated: false); player.layoutIfNeeded()
            let share: UIButton = try #require(find("playerShare", in: player))
            let favorite: UIButton = try #require(find("playerFavorite", in: player))
            #expect(!share.isHidden && share.accessibilityLabel == "Share")
            #expect(abs((rtl ? share.frame.minX : player.bounds.width - share.frame.maxX) - 40) <= 1)
            #expect(share.currentImage === UIImage(named: "ic_share"))
            var shared: LibraryEpisode?
            player.showShare = { sentFeed, episode, anchor in
                #expect(sentFeed.id == feed.id && anchor === share)
                shared = episode
            }
            let savedBefore = try await store.episode(id: feed.episodes[0].id)
            #expect(savedBefore?.userState.positionMilliseconds == 0)
            share.sendActions(for: .touchUpInside)
            #expect(shared?.id == feed.episodes[0].id && shared?.userState.positionMilliseconds == 12_345)
            #expect(try await store.episode(id: feed.episodes[0].id) == savedBefore)
            #expect(playback.wantsPlayback && playback.sample?.positionMilliseconds == 12_345)
            let before = favorite.frame
            var local = feed; local.source = "antennapod_local:fixture"
            player.update(feed: local, stored: local.episodes.first { $0.id == playback.episode?.id }); player.layoutIfNeeded()
            #expect(share.isHidden)
            // Favorite moves into the freed Share slot.
            #expect(abs(favorite.frame.minX - (before.minX + (rtl ? -48 : 48))) <= 1)
            shared = nil; share.sendActions(for: .touchUpInside); #expect(shared == nil)
            try await playback.resetPlaybackPosition(episodeID: feed.episodes[0].id)
            player.update(feed: feed, stored: feed.episodes.first { $0.id == playback.episode?.id }); #expect(share.isHidden)
        }
    }

    @Test(arguments: [false, true])
    func controllerPreservesPlayerThroughCancelAndAnchorsNativeShare(clearSelection: Bool) async throws {
        try await fixture { store, _, playback, engine, time in
            let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: playback,
                timeDisplayPreferences: time, navigationPreferences: nil, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                controller.view.frame = host.view.bounds
                await controller.reloadLibrary()?.value
                let player = try #require(player(in: controller.view))
                let share: UIButton = try #require(find("playerShare", in: player))
                try await wait { !share.isHidden }
                player.setExpanded(true, animated: false); controller.view.layoutIfNeeded()
                let selected = playback.episode?.id
                share.sendActions(for: .touchUpInside)
                try await wait { controller.presentedViewController is EpisodeShareController && controller.presentedViewController?.isBeingPresented == false }
                let sheet = try #require(controller.presentedViewController)
                let social: UIButton = try #require(find("episodeShareSocial", in: sheet.view))
                #expect(social.accessibilityValue?.contains("Podcast: Episode") == true)
                let checkbox: UIButton = try #require(find("episodeSharePosition", in: sheet.view))
                let oldPreference = UserDefaults.standard.object(forKey: "shareEpisodeStartAt")
                defer { UserDefaults.standard.set(oldPreference, forKey: "shareEpisodeStartAt") }
                if checkbox.accessibilityValue == "Not checked" { checkbox.sendActions(for: .touchUpInside) }
                engine.position(23_456); try await wait { playback.sample?.positionMilliseconds == 23_456 }
                #expect(social.accessibilityValue?.contains("Starting from: 00:00:12") == true)
                controller.additionalSafeAreaInsets = .init(top: 0, left: 31, bottom: 0, right: 7)
                controller.view.layoutIfNeeded()
                #expect(sheet.accessibilityPerformEscape())
                try await wait { controller.presentedViewController == nil }
                #expect(player.expansion == 1 && playback.episode?.id == selected && playback.sample?.positionMilliseconds == 23_456 && playback.wantsPlayback)
                share.sendActions(for: .touchUpInside)
                try await wait { controller.presentedViewController is EpisodeShareController && controller.presentedViewController?.isBeingPresented == false }
                let address: UIButton = try #require(find("episodeShareMediaAddress", in: controller.presentedViewController!.view))
                if clearSelection {
                    try await playback.resetPlaybackPosition(episodeID: selected!)
                    try await wait { player.isHidden }
                }
                address.sendActions(for: .touchUpInside)
                // The first native share sheet in a process loads its share extensions first (seconds when run alone).
                try await wait(seconds: 20) { controller.presentedViewController is UIActivityViewController && controller.presentedViewController?.isBeingPresented == false }
                let activity = try #require(controller.presentedViewController as? UIActivityViewController)
                let source = try #require(activity.popoverPresentationController?.sourceView)
                #expect(!source.isHidden && source.window != nil)
                if clearSelection {
                    #expect(source !== share && playback.episode == nil)
                } else {
                    #expect(source === share)
                    #expect(activity.popoverPresentationController?.sourceRect == share.bounds)
                    #expect(player.expansion == 1 && playback.episode?.id == selected && playback.wantsPlayback)
                }
                activity.dismiss(animated: false)
                try await wait { controller.presentedViewController == nil }
            }
        }
    }

    @Test(arguments: ["episodeShareSocial", "episodeShareMediaAddress", "episodeShareFile"])
    func dialogSharesCapturedContentAndPersistsPositionOption(action: String) async throws {
        try await fixture { _, feed, _, _, _ in
            let suite = "PlayerShare-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let media = try #require(Bundle(for: ShareViewTestBundleMarker.self).url(forResource: "playback-30sec", withExtension: "mp3"))
            var episode = feed.episodes[0]
            episode.userState.positionMilliseconds = 12_345
            episode.userState.isDownloaded = true; episode.userState.localFileURL = media.path
            var value: Any?
            let sheet = EpisodeShareController(feed: feed, episode: episode, defaults: defaults) { value = $0 }
            try await withViewTestWindow { host, _ in
                host.present(sheet, animated: false)
                try await wait { sheet.viewIfLoaded?.window != nil && !sheet.isBeingPresented }
                let checkbox: UIButton = try #require(find("episodeSharePosition", in: sheet.view))
                #expect(checkbox.accessibilityValue == "Not checked")
                checkbox.sendActions(for: .touchUpInside)
                #expect(defaults.bool(forKey: "shareEpisodeStartAt"))
                let social: UIButton = try #require(find("episodeShareSocial", in: sheet.view))
                #expect(social.accessibilityValue?.contains("Starting from: 00:00:12") == true)
                let button: UIButton = try #require(find(action, in: sheet.view))
                button.sendActions(for: .touchUpInside)
                try await wait { value != nil && host.presentedViewController == nil }
                switch action {
                case "episodeShareSocial": #expect((value as? String) == "Podcast: Episode\nStarting from: 00:00:12\n\nEpisode webpage: https://example.invalid/episode\n\nMedia file: https://example.invalid/audio.mp3#t=12")
                case "episodeShareMediaAddress": #expect((value as? String) == "https://example.invalid/audio.mp3")
                default: #expect((value as? URL) == media)
                }
                let reopened = EpisodeShareController(feed: feed, episode: episode, defaults: defaults) { _ in }
                reopened.loadViewIfNeeded()
                let retained: UIButton = try #require(find("episodeSharePosition", in: reopened.view))
                #expect(retained.accessibilityValue == "Checked")
            }
        }
    }
}
