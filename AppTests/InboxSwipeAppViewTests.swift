import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized)
struct InboxSwipeAppViewTests {
    private final class Engine: PlaybackEngine {
        var reading: PlaybackEngineReading?
        var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
        func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {}
        func play(commandID: UUID) {}
        func pause(commandID: UUID) {}
        func seek(to positionMilliseconds: Int64, commandID: UUID) {}
        func setSpeed(_ speed: Float, commandID: UUID) throws {}
        func unload() {}
    }
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(id, in: $0) as T? }.first
    }
    private func wait(_ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while try await !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await predicate())
    }
    private func row(_ id: Int64, in controller: LibraryViewController) throws -> EpisodeRowView {
        let button: UIButton = try #require(find("episode-\(id)", in: controller.view))
        var parent: UIView? = button
        while parent != nil && !(parent is EpisodeRowView) { parent = parent?.superview }
        return try #require(parent as? EpisodeRowView)
    }
    private func fixture(screen: SwipeScreen, configured: Bool = true, local: Bool = false, allFilter: [String] = [],
                         _ body: @MainActor (LibraryViewController, FeedLibraryStore, LibraryFeed, SwipePreferenceStore, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InboxSwipeApp-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let downloads = DownloadCoordinator(store: store, directory: root.appendingPathComponent("media"), network: .init(startMonitoring: false), preferences: { .init() })
        let playback = PlaybackCoordinator(store: store, engine: Engine())
        do {
            let source = local ? "antennapod_local:unregistered" : "https://example.invalid/swipe"
            let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Swipe application", episodes: (1...2).map {
                .init(identifier: "\($0)", title: "Swipe episode \($0)", media: .init(url: "https://example.invalid/\($0).mp3", size: 42, durationMilliseconds: 120_000))
            }), source: source, responseURL: URL(string: "https://example.invalid/swipe")!, validator: nil, permanentRedirectURL: nil))
            for episode in feed.episodes {
                try await store.updateEpisode(id: episode.id) {
                    $0.userState.playState = .new; $0.userState.positionMilliseconds = 90_000; $0.userState.isFavorite = true
                    $0.details.media?.hasEmbeddedPicture = false
                }
            }
            if screen == .feed { try await store.setEpisodeFilter(feedID: feed.id, filter: .init(values: ["new"])) }
            let navigation = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
            var nav = navigation.value
            switch screen {
            case .inbox: nav.defaultPage = NavigationDestination.inbox.rawValue
            case .episodes: nav.defaultPage = NavigationDestination.episodes.rawValue
            case .favorites: nav.defaultPage = NavigationDestination.favorites.rawValue
            case .feed: nav.defaultPage = "remember"; nav.lastPage = "\(feed.id)"
            // The Queue and History swipes have their own suite (SwipeSettingsViewTests).
            case .queue: nav.defaultPage = NavigationDestination.queue.rawValue
            case .history: nav.defaultPage = NavigationDestination.history.rawValue
            }
            try navigation.update(nav)
            let preferences = try SwipePreferenceStore(file: root.appendingPathComponent("swipe.json"))
            if configured { try preferences.confirm(.init(screen: screen, configuration: .init(left: .removeInbox, right: .queue))) }
            let allPreferences = try AllEpisodesFilterPreferenceStore(file: root.appendingPathComponent("all-filter.json"))
            try allPreferences.update(.init(values: allFilter))
            var controller: LibraryViewController? = LibraryViewController(library: store, startupError: nil, downloads: downloads, playback: playback,
                timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil,
                inboxSwipePreferences: preferences, allEpisodesFilterPreferences: allPreferences)
            try await withViewTestWindow { host, _ in
                let mounted = try #require(controller)
                host.addChild(mounted); host.view.addSubview(mounted.view); mounted.didMove(toParent: host)
                mounted.view.frame = host.view.bounds
                defer { mounted.dismiss(animated: false); mounted.willMove(toParent: nil); mounted.view.removeFromSuperview(); mounted.removeFromParent() }
                await mounted.reloadLibrary()?.value; mounted.view.layoutIfNeeded()
                try await body(mounted, store, feed, preferences, root)
            }
            controller = nil
            try await playback.stop(); await downloads.stop(); try await store.close()
        } catch { try? await playback.stop(); await downloads.stop(); try? await store.close(); throw error }
    }
    @Test func allEpisodesPersistedNewFilterOwnsRowsSelectionCountAndUndoFeedback() async throws {
        try await fixture(screen: .episodes, allFilter: ["new"]) { controller, store, feed, _, root in
            let target = feed.episodes[0].id, survivor = feed.episodes[1].id
            let info: UILabel = try #require(find("allEpisodesFiltered", in: controller.view))
            #expect(!info.isHidden && info.text == "Filtered")
            controller.startFeedSelection(target)
            let count: UILabel = try #require(find("episodeSelectionCount", in: controller.view))
            #expect(count.text == String(format: Appearance.text("num_selected_label"), 1, 2))
            #expect(info.isHidden)
            let close: UIButton = try #require(find("endEpisodeSelection", in: controller.view)); close.sendActions(for: .touchUpInside)
            #expect(!info.isHidden)
            controller.performInboxSwipe(.left, episodeID: target); await controller.lastInboxSwipe?.value
            #expect((find("episode-\(target)", in: controller.view) as UIButton?) == nil)
            #expect((find("episode-\(survivor)", in: controller.view) as UIButton?) != nil)
            let bar: Snackbar = try #require(find("inboxSwipeSnackbar", in: controller.view))
            #expect(bar.message == "Removed from inbox")
            let undo: UIButton = try #require(find("inboxSwipeUndo", in: controller.view)); undo.sendActions(for: .touchUpInside)
            try await wait { try await store.episode(id: target)?.userState.playState == .new }
            await controller.lastEpisodeActionReconciliation?.value
            try await wait { (find("episode-\(target)", in: controller.view) as UIButton?) != nil }
            let reopened = try AllEpisodesFilterPreferenceStore(file: root.appendingPathComponent("all-filter.json"))
            #expect(reopened.value.stored.values == ["new"])
            controller.startFeedSelection(target)
            let restoredCount: UILabel = try #require(find("episodeSelectionCount", in: controller.view))
            #expect(restoredCount.text == String(format: Appearance.text("num_selected_label"), 1, 2))
        }
    }
    @Test func allEpisodesFilterSheetSavesBeforeConfirmAndOutsideClosePreservesIt() async throws {
        try await fixture(screen: .episodes) { controller, _, feed, _, root in
            let button: UIButton = try #require(find("allEpisodesFilter", in: controller.view)); button.sendActions(for: .touchUpInside)
            try await wait { controller.presentedViewController?.isBeingPresented == false }
            let dialog = try #require(controller.presentedViewController as? FeedFilterController)
            #expect((find("feedFilter_new", in: dialog.view) as UIControl?) == nil)
            let played: UIControl = try #require(find("feedFilter_played", in: dialog.view)); played.sendActions(for: .touchUpInside)
            #expect(try AllEpisodesFilterPreferenceStore(file: root.appendingPathComponent("all-filter.json")).value.stored.values == ["played"])
            #expect((find("episode-\(feed.episodes[0].id)", in: controller.view) as UIButton?) == nil)
            let emptyTitle: UILabel = try #require(find("allEpisodesEmptyTitle", in: controller.view))
            let emptyMessage: UILabel = try #require(find("allEpisodesEmptyMessage", in: controller.view))
            #expect(emptyTitle.text == "No episodes" && emptyMessage.text == "Try clearing the filter to see more episodes.")
            #expect(dialog.accessibilityPerformEscape())
            try await wait { controller.presentedViewController == nil }
            let reopened: UIButton = try #require(find("allEpisodesFilter", in: controller.view)); reopened.sendActions(for: .touchUpInside)
            try await wait { controller.presentedViewController?.isBeingPresented == false }
            let second = try #require(controller.presentedViewController)
            let selected: UIControl = try #require(find("feedFilter_played", in: second.view)); #expect(selected.isSelected)
            let reset: UIButton = try #require(find("feedFilterReset", in: second.view)); reset.sendActions(for: .touchUpInside)
            #expect(try AllEpisodesFilterPreferenceStore(file: root.appendingPathComponent("all-filter.json")).value.stored.values.isEmpty)
            let confirm: UIButton = try #require(find("feedFilterConfirm", in: second.view)); confirm.sendActions(for: .touchUpInside)
            try await wait { controller.presentedViewController == nil }
            let info: UILabel = try #require(find("allEpisodesFiltered", in: controller.view)); #expect(info.isHidden)
        }
    }
    @Test(arguments: SwipeScreen.inboxRoutes)
    func fourActualListRecipientsUseCapturedModelFilterFeedbackAndUndo(screen: SwipeScreen) async throws {
        try await fixture(screen: screen) { controller, store, feed, _, root in
            let id = feed.episodes[0].id, view = try row(id, in: controller), model = try #require(view.actionModel)
            let before = try #require(try await store.episode(id: id)), effects = try await store.pendingEffects()
            #expect(view.swipe != nil)
            #expect(controller.inboxSwipeConfiguration(.left, episodeID: id)?.inboxAction == .removeInbox)
            controller.performInboxSwipe(.left, episodeID: id, expectedModel: model)
            await controller.lastInboxSwipe?.value
            #expect(try await store.episode(id: id)?.userState.playState == .unplayed)
            #expect(model.snapshot().episode.userState.playState == .unplayed)
            #expect(try await store.episode(id: id)?.userState.positionMilliseconds == before.userState.positionMilliseconds)
            #expect(try await store.pendingEffects() == effects)
            #expect(try await store.synchronizationQueue().isEmpty)
            let offers = screen == .inbox || screen == .feed
            let bar: Snackbar? = find("inboxSwipeSnackbar", in: controller.view)
            #expect((bar != nil) == offers)
            if offers {
                #expect(bar?.message == "Removed from inbox")
                let undo: UIButton = try #require(find("inboxSwipeUndo", in: controller.view))
                undo.sendActions(for: .touchUpInside)
                try await wait { try await store.episode(id: id)?.userState.playState == .new }
                #expect(model.snapshot().episode.userState.playState == .new)
            }
            let reopened = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
            #expect(try await reopened.episode(id: id)?.userState.playState == (offers ? .new : .unplayed))
            try await reopened.close()
        }
    }
    @Test(arguments: SwipeScreen.inboxRoutes)
    func firstUseCancelAndDisabledConfigurationDoNotMutate(screen: SwipeScreen) async throws {
        try await fixture(screen: screen, configured: false) { controller, store, feed, preferences, _ in
            let id = feed.episodes[0].id, before = try await store.episode(id: feed.episodes[0].id)
            #expect(controller.inboxSwipeConfiguration(.left, episodeID: id)?.icon == "ic_settings")
            controller.performInboxSwipe(.left, episodeID: id); await controller.lastInboxSwipe?.value
            try await wait { controller.presentedViewController?.isBeingPresented == false }
            let dialog = try #require(controller.presentedViewController)
            let cancel: UIButton = try #require(find("inboxSwipeCancel", in: dialog.view)); cancel.sendActions(for: .touchUpInside)
            try await wait { controller.presentedViewController == nil }
            #expect(preferences.value.configuration(for: screen) == nil)
            #expect(try await store.episode(id: id) == before)
            try preferences.confirm(.init(screen: screen, configuration: .init(enabled: false, left: .removeInbox, right: .queue)))
            #expect(controller.inboxSwipeConfiguration(.left, episodeID: id) == nil)
            controller.performInboxSwipe(.left, episodeID: id); await controller.lastInboxSwipe?.value
            #expect(try await store.episode(id: id) == before && controller.presentedViewController == nil)
        }
    }
    @Test func reboundSameIDRejectsOldGestureAndNavigationDoesNotRetargetUndo() async throws {
        try await fixture(screen: .inbox) { controller, store, feed, _, _ in
            let id = feed.episodes[0].id, oldModel = try #require(try row(id, in: controller).actionModel)
            // A screen opened again binds its rows anew (a patch keeps the models of rows that did not change).
            await controller.reloadLibrary(reopen: true)?.value; controller.view.layoutIfNeeded()
            #expect(try row(id, in: controller).actionModel !== oldModel)
            controller.performInboxSwipe(.left, episodeID: id, expectedModel: oldModel)
            #expect(try await store.episode(id: id)?.userState.playState == .new)
            controller.performInboxSwipe(.left, episodeID: id); await controller.lastInboxSwipe?.value
            await controller.openNotification(.feed(feed.id)); controller.view.layoutIfNeeded()
            let undo: UIButton = try #require(find("inboxSwipeUndo", in: controller.view)); undo.sendActions(for: .touchUpInside)
            try await wait { try await store.episode(id: id)?.userState.playState == .new }
            await controller.lastEpisodeActionReconciliation?.value
            #expect(try row(id, in: controller).actionModel?.snapshot().episode.userState.playState == .new)
        }
    }
    @Test func unavailableLocalMediaCaptureReachesActualErrorWithoutMutationOrOffer() async throws {
        try await fixture(screen: .inbox, local: true) { controller, store, feed, _, _ in
            let id = feed.episodes[0].id, before = try await store.episode(id: feed.episodes[0].id)
            controller.performInboxSwipe(.left, episodeID: id); await controller.lastInboxSwipe?.value
            try await wait { controller.presentedViewController != nil }
            #expect(try await store.episode(id: id) == before)
            #expect((find("inboxSwipeSnackbar", in: controller.view) as UIView?) == nil)
        }
    }
    @Test
    func connectedQueueUndoUsesCurrentQueueAndSourceIndex() async throws {
        try await fixture(screen: .feed) { controller, store, feed, preferences, _ in
            let ids = feed.episodes.map(\.id)
            _ = try await store.enqueue(ids)
            try await store.setEpisodeFilter(feedID: feed.id, filter: .init(values: ["queued"]))
            try preferences.confirm(.init(screen: .feed, configuration: .init(left: .queue, right: .queue)))
            await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
            controller.performInboxSwipe(.left, episodeID: ids[0]); await controller.lastInboxSwipe?.value
            #expect(try await store.queue().map(\.id) == [ids[1]])
            let undo: UIButton = try #require(find("inboxSwipeUndo", in: controller.view)); undo.sendActions(for: .touchUpInside)
            try await wait { try await store.queue().count == 2 }
            #expect(try await store.queue().map(\.id) == ids)
            #expect(try await store.episode(id: ids[0])?.userState.positionMilliseconds == 90_000)
        }
    }
    @Test func ordinaryFavoriteAndNoMediaDownloadUseSelectedAppRecipients() async throws {
        try await fixture(screen: .feed) { controller, store, feed, preferences, _ in
            let id = feed.episodes[0].id
            try preferences.confirm(.init(screen: .feed, configuration: .init(left: .favorite, right: .download)))
            controller.performInboxSwipe(.left, episodeID: id); await controller.lastInboxSwipe?.value
            try await wait { try await store.episode(id: id)?.userState.isFavorite == false }
            #expect(try await store.episode(id: id)?.userState.playState == .new)
            try await store.updateEpisode(id: id) { $0.details.media = nil }
            await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
            controller.performInboxSwipe(.right, episodeID: id); await controller.lastInboxSwipe?.value
            let notice: Snackbar = try #require(find("episodeActionSnackbar", in: controller.view))
            #expect(notice.message == Appearance.text("no_media_label"))
            #expect((find("inboxSwipeUndo", in: controller.view) as UIButton?) == nil)
        }
    }

    @Test(arguments: [SwipeScreen.inbox, .episodes, .feed])
    func selectionKeepsGlobalListSwipesButDetachesIndividualFeed(screen: SwipeScreen) async throws {
        try await fixture(screen: screen) { controller, store, feed, _, _ in
            let id = feed.episodes[0].id
            controller.startFeedSelection(id)
            #expect(controller.feedSelection.active)
            #expect((controller.inboxSwipeConfiguration(.left, episodeID: id) != nil) == (screen != .feed))
            controller.performInboxSwipe(.left, episodeID: id); await controller.lastInboxSwipe?.value
            let actual = try await store.episode(id: id)?.userState.playState
            #expect(actual == (screen == .feed ? .new : .unplayed))
        }
    }

}
