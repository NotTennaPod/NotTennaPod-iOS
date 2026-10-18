import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized)
struct PlayerFavoriteViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(id, in: $0) as T? }.first
    }
    private func player(in view: UIView) -> PlayerView? {
        (view as? PlayerView) ?? view.subviews.lazy.compactMap { player(in: $0) }.first
    }
    private func wait(details: () -> String = { "" }, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "Expected favorite state: \(details())")
    }
    private func fixture(_ body: (FeedLibraryStore, LibraryFeed, PlaybackCoordinator, TimeDisplayPreferenceStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PlayerFavorite-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: file)
        do {
            let source = URL(string: "https://example.invalid/feed")!
            let feed = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Podcast", episodes: [
                ParsedEpisode(identifier: "episode", title: "Episode", description: "Notes",
                    media: ParsedMedia(url: "https://example.invalid/media", size: 0, durationMilliseconds: 60_000))
            ]), source: source.absoluteString, responseURL: source, validator: nil, permanentRedirectURL: nil))
            _ = try await store.beginPlayback(episodeID: feed.episodes[0].id)
            let playback = PlaybackCoordinator(store: store, engine: AVPlayerPlaybackEngine(muted: true))
            try await playback.restore()
            try await body(store, feed, playback, TimeDisplayPreferenceStore(file: directory.appendingPathComponent("time.json")), file)
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

    @Test(arguments: [false, true])
    func libraryActionPersistsAndSurvivesCollapseResizeAndExternalEdits(rtl: Bool) async throws {
        try await fixture { store, feed, playback, time, file in
            let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: playback,
                timeDisplayPreferences: time, navigationPreferences: nil, speedPreferences: nil,
                mobileNetworkPreferences: nil, usage: nil)
            try await withViewTestWindow { host, window in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                controller.view.frame = host.view.bounds
                controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                controller.additionalSafeAreaInsets = .init(top: 0, left: 31, bottom: 0, right: 7)
                await controller.reloadLibrary()?.value
                let player = try #require(player(in: controller.view))
                player.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                player.setExpanded(true, animated: false)
                let favorite: UIButton = try #require(find("playerFavorite", in: player))
                var error: String?
                player.failure = { error = String(describing: $0) }
                let collapse: UIButton = try #require(find("playerCollapse", in: player))
                try await wait { !favorite.isHidden && favorite.isEnabled }
                #expect(favorite.accessibilityLabel == "Add to favorites")
                #expect(favorite.currentImage === UIImage(named: "ic_star_border"))
                let selected = playback.episode, phase = playback.phase
                favorite.sendActions(for: .touchUpInside)
                try await wait(details: { "initial add: \(favorite.accessibilityLabel ?? "nil"), enabled=\(favorite.isEnabled), error=\(error ?? "none")" }) { favorite.isEnabled && favorite.accessibilityLabel == "Remove from favorites" }
                #expect(favorite.accessibilityTraits.contains(.selected))
                #expect(favorite.currentImage === UIImage(named: "ic_star"))
                #expect(try await store.episode(id: feed.episodes[0].id)?.userState.isFavorite == true)
                #expect(playback.episode == selected && playback.phase == phase)
                player.setExpanded(false, animated: false); player.setExpanded(true, animated: false)
                for width in [host.view.bounds.width, min(host.view.bounds.width, 402), min(host.view.bounds.width, 340)] {
                    controller.view.frame.size.width = width
                    for inset in [UIEdgeInsets(top: 0, left: 31, bottom: 0, right: 7), .init(top: 0, left: 7, bottom: 0, right: 31)] {
                        controller.additionalSafeAreaInsets = inset
                        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded(); player.layoutIfNeeded()
                        let frame = favorite.convert(favorite.bounds, to: window)
                        #expect(window.bounds.contains(frame))
                        #expect(window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil) === favorite)
                        // Compare in window coordinates: the two buttons can live in different toolbars.
                        let collapseFrame = collapse.convert(collapse.bounds, to: window)
                        #expect(rtl ? frame.maxX <= collapseFrame.minX + 0.5 : frame.minX >= collapseFrame.maxX - 0.5,
                                "favorite \(frame) collapse \(collapseFrame) width \(width) inset \(inset)")
                        let toolbar = try #require(favorite.superview)
                        #expect(abs((rtl ? favorite.frame.minX : toolbar.bounds.width - favorite.frame.maxX) - 184) <= 1)
                        #expect(favorite.accessibilityLabel == "Remove from favorites" && player.expansion == 1)
                    }
                }
                let reopened = try FeedLibraryStore(url: file)
                #expect(try await reopened.episode(id: feed.episodes[0].id)?.userState.isFavorite == true)
                try await reopened.close()
                // A row/detail action must update the toolbar despite the unchanged playback snapshot.
                try await store.setFavorite(episodeID: feed.episodes[0].id, favorite: false)
                await controller.reloadLibrary(preservingEpisodeDetails: true)?.value
                #expect(favorite.accessibilityLabel == "Add to favorites")
                favorite.sendActions(for: .touchUpInside)
                try await wait { favorite.isEnabled && favorite.accessibilityLabel == "Remove from favorites" }
                favorite.sendActions(for: .touchUpInside)
                try await wait { favorite.isEnabled && favorite.accessibilityLabel == "Add to favorites" }
                #expect(try await store.episode(id: feed.episodes[0].id)?.userState.isFavorite == false)
                #expect(playback.episode == selected && playback.phase == phase)
            }
        }
    }

    @Test func failedSavePreservesDisplayedStateAndReportsError() async throws {
        try await fixture { store, feed, playback, time, _ in
            let player = PlayerView(playback: playback, timeDisplayPreferences: time, library: store)
            player.update(feed: feed, stored: feed.episodes.first { $0.id == playback.episode?.id })
            let favorite: UIButton = try #require(find("playerFavorite", in: player))
            var failures = 0, changes = 0
            player.failure = { _ in failures += 1 }
            player.favoriteChanged = { changes += 1 }
            try await store.close()
            favorite.sendActions(for: .touchUpInside)
            try await wait { failures == 1 }
            #expect(favorite.isEnabled && favorite.accessibilityLabel == "Add to favorites")
            #expect(!favorite.accessibilityTraits.contains(.selected) && changes == 0)
        }
    }

    @Test func staleDisplayedCommandOnlyMutatesItsCapturedEpisode() async throws {
        try await fixture { store, feed, playback, time, _ in
            let player = PlayerView(playback: playback, timeDisplayPreferences: time, library: store)
            player.update(feed: feed, stored: feed.episodes.first { $0.id == playback.episode?.id })
            let favorite: UIButton = try #require(find("playerFavorite", in: player))
            let source = URL(string: "https://example.invalid/other")!
            let other = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Other", episodes: [
                ParsedEpisode(identifier: "other", title: "Other episode", media: ParsedMedia(url: "https://example.invalid/other.mp3", size: 0))
            ]), source: source.absoluteString, responseURL: source, validator: nil, permanentRedirectURL: nil))
            try await playback.resetPlaybackPosition(episodeID: feed.episodes[0].id)
            _ = try await store.beginPlayback(episodeID: other.episodes[0].id)
            try await playback.restore()
            var refreshed = false
            player.favoriteChanged = { player.update(feed: other, stored: other.episodes.first { $0.id == playback.episode?.id }); refreshed = true }
            // The old displayed control can receive a queued tap before the new episode is rendered.
            favorite.sendActions(for: .touchUpInside)
            try await wait { refreshed && favorite.isEnabled }
            #expect(try await store.episode(id: feed.episodes[0].id)?.userState.isFavorite == true)
            #expect(try await store.episode(id: other.episodes[0].id)?.userState.isFavorite == false)
            #expect(playback.episode?.id == other.episodes[0].id && !playback.wantsPlayback)
            #expect(favorite.accessibilityLabel == "Add to favorites")
            try await playback.resetPlaybackPosition(episodeID: other.episodes[0].id)
            player.update(feed: other, stored: other.episodes.first { $0.id == playback.episode?.id })
            #expect(favorite.isHidden)
        }
    }
}
