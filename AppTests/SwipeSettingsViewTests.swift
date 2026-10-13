import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Mounted checks: every Settings → Swipe actions row opens
/// its screen's dialog with the source title and defaults, Cancel stores nothing and Confirm stores the pair and the
/// switch; Queue and History swipes remove with their source message and Undo, locked or not; selection rules; RTL.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct SwipeSettingsViewTests {
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
    private func find<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if view.accessibilityIdentifier == id, let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(id, in: $0, as: type) }.first
    }
    private func all<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }
    private func wait(_ condition: @MainActor () async throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while try await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await condition(), sourceLocation: sourceLocation)
    }
    private func rows(_ ids: [Int64], in controller: LibraryViewController) -> [Int64] {
        controller.view.layoutIfNeeded()
        return ids.compactMap { id -> (CGFloat, Int64)? in
            guard let row = find("episode-\(id)", in: controller.view, as: UIButton.self) else { return nil }
            return (row.convert(row.bounds, to: controller.view).minY, id)
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }
    private func dialogTitle(_ controller: UIViewController?) -> String? {
        controller.flatMap { all(SourceDialogTitle.self, in: $0.view).first?.accessibilityLabel }
    }

    struct Fixture {
        let root: URL, store: FeedLibraryStore, swipe: SwipePreferenceStore, downloadPreferences: DownloadPreferenceStore
        let queue: QueueInteractionPreferenceStore, ids: [Int64]
    }
    /// One podcast, five episodes: 1–4 queued in that order; all five in History, newest first 1…5.
    private func withScreen(_ destination: NavigationDestination, locked: Bool = false, rtl: Bool = false,
                            _ body: @MainActor (LibraryViewController, Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("M26View-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let downloads = DownloadCoordinator(store: store, directory: root.appendingPathComponent("media"), network: .init(startMonitoring: false), preferences: { .init() })
        let playback = PlaybackCoordinator(store: store, engine: Engine())
        do {
            let base = Date(timeIntervalSince1970: 1_780_000_000)
            let feed = try await store.insert(.init(feed: .init(format: .rss, title: "M26", episodes: (1...5).map {
                .init(identifier: "m26-\($0)", title: "M26 episode \($0)", publicationDate: base.addingTimeInterval(Double($0) * 3600),
                      media: .init(url: "https://example.invalid/m26/\($0).mp3", size: 42, durationMilliseconds: 1_800_000))
            }), source: "https://example.invalid/m26", responseURL: URL(string: "https://example.invalid/m26")!, validator: nil, permanentRedirectURL: nil))
            let ids = feed.episodes.map(\.id).sorted()
            for (index, id) in ids.enumerated() {
                try await store.updateEpisode(id: id) {
                    $0.userState.playState = .played; $0.userState.playedDurationMilliseconds = 600_000
                    $0.userState.lastPlayedHistoryMilliseconds = 1_790_000_000_000 - Int64(index) * 60_000
                    $0.userState.lastPlayedTimeMilliseconds = 1_790_000_000_000 - Int64(index) * 60_000
                    $0.details.media?.hasEmbeddedPicture = false
                }
            }
            _ = try await store.enqueue(Array(ids.prefix(4)))
            let navigation = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
            var nav = navigation.value; nav.defaultPage = destination.rawValue; try navigation.update(nav)
            let swipe = try SwipePreferenceStore(file: root.appendingPathComponent("swipe.json"))
            let downloadPreferences = try DownloadPreferenceStore(file: root.appendingPathComponent("downloads.json"))
            let queue = try QueueInteractionPreferenceStore(file: root.appendingPathComponent("queue.json"))
            if locked { try queue.confirmLock(doNotShowAgain: false) }
            let fixture = Fixture(root: root, store: store, swipe: swipe, downloadPreferences: downloadPreferences, queue: queue, ids: ids)
            var controller: LibraryViewController? = LibraryViewController(library: store, startupError: nil, downloads: downloads, playback: playback,
                timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil,
                downloadPreferences: downloadPreferences, inboxSwipePreferences: swipe, queueInteractionPreferences: queue)
            try await withViewTestWindow { host, window in
                let mounted = try #require(controller)
                if rtl { window.traitOverrides.layoutDirection = .rightToLeft; mounted.view.semanticContentAttribute = .forceRightToLeft }
                host.addChild(mounted); host.view.addSubview(mounted.view); mounted.didMove(toParent: host)
                mounted.view.frame = host.view.bounds
                defer { mounted.dismiss(animated: false); mounted.willMove(toParent: nil); mounted.view.removeFromSuperview(); mounted.removeFromParent() }
                await mounted.reloadLibrary()?.value; mounted.view.layoutIfNeeded()
                try await body(mounted, fixture)
            }
            controller = nil
            try await playback.stop(); await downloads.stop(); try await store.close()
        } catch { try? await playback.stop(); await downloads.stop(); try? await store.close(); throw error }
    }

    // MARK: Settings rows

    @Test(arguments: SwipeActionsSettingsRow.allCases)
    func eachSettingsRowOpensItsDialogCancelStoresNothingConfirmStoresTheDefaults(row: SwipeActionsSettingsRow) async throws {
        try await withScreen(.home) { controller, fixture in
            controller.push(.settings(.swipeActions))
            controller.view.layoutIfNeeded()
            // Seven title-only rows in source order.
            let controls = try SwipeActionsSettingsRow.allCases.map { try #require(find($0.key, in: controller.view, as: UIControl.self), "\($0.key)") }
            let tops = controls.map { $0.convert($0.bounds, to: controller.view).minY }
            #expect(tops == tops.sorted() && Set(tops).count == 7)
            #expect(controls.map(\.accessibilityLabel) == ["Queue", "Inbox", "Episodes", "Downloads", "Playback history", "Favorites", "Individual subscription"])
            let title = "Swipe actions - " + Appearance.text(row.titleKey)
            for confirm in [false, true] {
                try #require(find(row.key, in: controller.view, as: UIControl.self)).sendActions(for: .touchUpInside)
                try await wait { controller.presentedViewController?.isBeingPresented == false }
                let dialog = try #require(controller.presentedViewController)
                #expect(dialogTitle(dialog) == title)
                if let screen = row.screen {
                    let body = try #require(find("inboxSwipeSettings", in: dialog.view, as: SwipeSettingsBody.self))
                    #expect(body.draft.configuration == screen.defaultConfiguration)
                    let left = try #require(find("inboxSwipePreview-left", in: dialog.view, as: UIControl.self))
                    let right = try #require(find("inboxSwipePreview-right", in: dialog.view, as: UIControl.self))
                    #expect(left.accessibilityValue == Appearance.text(screen.defaultConfiguration.left.titleKey))
                    #expect(right.accessibilityValue == Appearance.text(screen.defaultConfiguration.right.titleKey))
                    try #require(find(confirm ? "inboxSwipeConfirm" : "inboxSwipeCancel", in: dialog.view, as: UIButton.self)).sendActions(for: .touchUpInside)
                    try await wait { controller.presentedViewController == nil }
                    let reopened = try SwipePreferenceStore(file: fixture.root.appendingPathComponent("swipe.json"))
                    #expect(reopened.value.configuration(for: screen) == (confirm ? screen.defaultConfiguration : nil), "\(row) confirm=\(confirm)")
                    // Other screens are never written.
                    for other in SwipeScreen.allCases where other != screen { #expect(reopened.value.configuration(for: other) == nil) }
                } else {
                    #expect(find("downloadsSwipeSettings", in: dialog.view, as: UIView.self) != nil)
                    try #require(find(confirm ? "downloadsSwipeConfirm" : "downloadsSwipeCancel", in: dialog.view, as: UIButton.self)).sendActions(for: .touchUpInside)
                    try await wait { controller.presentedViewController == nil }
                    let reopened = try DownloadPreferenceStore(file: fixture.root.appendingPathComponent("downloads.json"))
                    #expect((reopened.value.swipe != nil) == confirm)
                    if confirm { #expect(reopened.value.swipe?.left == .delete && reopened.value.swipe?.right == .delete && reopened.value.swipe?.enabled == true) }
                }
            }
        }
    }

    // MARK: Queue

    @Test(arguments: [false, true])
    func queueRemoveOffersUndoAndRestoresTheOrderLockedOrNot(locked: Bool) async throws {
        try await withScreen(.queue, locked: locked) { controller, fixture in
            let ids = fixture.ids, queued = Array(ids.prefix(4))
            #expect(rows(ids, in: controller) == queued)
            // First use, locked or not: the swipe opens "Swipe actions - Queue" and does not touch the episode.
            #expect(controller.inboxSwipeConfiguration(.left, episodeID: ids[2])?.icon == "ic_settings")
            controller.performInboxSwipe(.left, episodeID: ids[2]); await controller.lastInboxSwipe?.value
            try await wait { controller.presentedViewController?.isBeingPresented == false }
            #expect(dialogTitle(controller.presentedViewController) == "Swipe actions - Queue")
            try #require(find("inboxSwipeConfirm", in: controller.presentedViewController!.view, as: UIButton.self)).sendActions(for: .touchUpInside)
            try await wait { controller.presentedViewController == nil }
            #expect(try await fixture.store.queue().map(\.id) == queued)

            let configuration = try #require(controller.inboxSwipeConfiguration(.left, episodeID: ids[2]))
            #expect(configuration.inboxAction == .removeQueue && configuration.removes && configuration.icon == "ic_playlist_remove")
            controller.performInboxSwipe(.left, episodeID: ids[2]); await controller.lastInboxSwipe?.value
            #expect(try await fixture.store.queue().map(\.id) == [ids[0], ids[1], ids[3]])
            try await wait { rows(ids, in: controller) == [ids[0], ids[1], ids[3]] }
            let bar = try #require(find("inboxSwipeSnackbar", in: controller.view, as: Snackbar.self))
            #expect(bar.message == "1 episode removed from queue.")
            let undo = try #require(find("inboxSwipeUndo", in: controller.view, as: UIButton.self))
            #expect(undo.accessibilityLabel == "Undo" || undo.title(for: .normal) == "Undo")
            undo.sendActions(for: .touchUpInside)
            try await wait { try await fixture.store.queue().map(\.id) == queued }
            try await wait { rows(ids, in: controller) == queued }
            #expect(fixture.queue.value.locked == locked, "the lock is unchanged")
        }
    }

    @Test func queueOtherActionsKeepTheRowAndOfferNoUndoAndSelectionDetachesSwiping() async throws {
        try await withScreen(.queue) { controller, fixture in
            let ids = fixture.ids
            try fixture.swipe.confirm(.init(screen: .queue, configuration: .init(left: .played, right: .favorite)))
            let played = try #require(controller.inboxSwipeConfiguration(.left, episodeID: ids[0]))
            #expect(played.inboxAction == .played && !played.removes)
            controller.performInboxSwipe(.left, episodeID: ids[0]); await controller.lastInboxSwipe?.value
            // Toggle played: PLAYED → UNPLAYED, still queued, no message.
            try await wait { try await fixture.store.episode(id: ids[0])?.userState.playState == .unplayed }
            #expect(try await fixture.store.queue().map(\.id) == Array(ids.prefix(4)))
            #expect(find("inboxSwipeSnackbar", in: controller.view, as: UIView.self) == nil)
            controller.performInboxSwipe(.right, episodeID: ids[1]); await controller.lastInboxSwipe?.value
            try await wait { try await fixture.store.episode(id: ids[1])?.userState.isFavorite == true }
            #expect(find("inboxSwipeSnackbar", in: controller.view, as: UIView.self) == nil)
            // Selection mode detaches Queue swiping (`QueueFragment:560`).
            controller.startFeedSelection(ids[2])
            #expect(controller.feedSelection.active)
            #expect(controller.inboxSwipeConfiguration(.left, episodeID: ids[2]) == nil)
        }
    }

    // MARK: History

    @Test func historyRemoveOffersUndoRestoresThePlaceAndSelectionKeepsSwiping() async throws {
        try await withScreen(.history) { controller, fixture in
            let ids = fixture.ids
            #expect(rows(ids, in: controller) == ids)
            try fixture.swipe.confirm(.init(screen: .history, configuration: SwipeScreen.history.defaultConfiguration))
            let configuration = try #require(controller.inboxSwipeConfiguration(.right, episodeID: ids[2]))
            #expect(configuration.inboxAction == .removeHistory && configuration.removes && configuration.icon == "ic_history_remove")
            let before = try #require(try await fixture.store.episode(id: ids[2]))
            controller.performInboxSwipe(.right, episodeID: ids[2]); await controller.lastInboxSwipe?.value
            try await wait { rows(ids, in: controller) == [ids[0], ids[1], ids[3], ids[4]] }
            let removed = try #require(try await fixture.store.episode(id: ids[2]))
            #expect(removed.userState.lastPlayedHistoryMilliseconds == nil)
            #expect(removed.userState.playedDurationMilliseconds == before.userState.playedDurationMilliseconds)
            #expect(removed.userState.playState == .played)
            #expect(try await fixture.store.queue().map(\.id) == Array(ids.prefix(4)), "the queue is untouched")
            let bar = try #require(find("inboxSwipeSnackbar", in: controller.view, as: Snackbar.self))
            #expect(bar.message == "Removed from history")
            try #require(find("inboxSwipeUndo", in: controller.view, as: UIButton.self)).sendActions(for: .touchUpInside)
            try await wait { rows(ids, in: controller) == ids }
            #expect(try await fixture.store.episode(id: ids[2])?.userState.lastPlayedHistoryMilliseconds == before.userState.lastPlayedHistoryMilliseconds)
            #expect(try await fixture.store.synchronizationQueue().isEmpty)
            // History keeps swiping during selection (`EpisodesListFragment`).
            controller.startFeedSelection(ids[0])
            #expect(controller.feedSelection.active)
            #expect(controller.inboxSwipeConfiguration(.left, episodeID: ids[0])?.inboxAction == .removeHistory)
        }
    }

    @Test func historyAddToQueueOnAQueuedEpisodeRemovesItWithoutAMessage() async throws {
        try await withScreen(.history) { controller, fixture in
            let ids = fixture.ids
            try fixture.swipe.confirm(.init(screen: .history, configuration: .init(left: .queue, right: .removeHistory)))
            #expect(controller.inboxSwipeConfiguration(.left, episodeID: ids[0])?.removes == false)
            controller.performInboxSwipe(.left, episodeID: ids[0]); await controller.lastInboxSwipe?.value
            try await wait { try await fixture.store.queue().map(\.id) == [ids[1], ids[2], ids[3]] }
            #expect(find("inboxSwipeSnackbar", in: controller.view, as: UIView.self) == nil)
            #expect(rows(ids, in: controller) == ids, "the History row stays")
        }
    }

    // MARK: Right-to-left

    @Test func rightToLeftKeepsPhysicalSidesInTheListAndTheDialog() async throws {
        try await withScreen(.queue, rtl: true) { controller, fixture in
            let ids = fixture.ids
            try fixture.swipe.confirm(.init(screen: .queue, configuration: .init(left: .removeQueue, right: .favorite)))
            // A physical leftward drag is "Swipe left" in every layout direction.
            #expect(controller.inboxSwipeConfiguration(.left, episodeID: ids[0])?.inboxAction == .removeQueue)
            #expect(controller.inboxSwipeConfiguration(.right, episodeID: ids[0])?.inboxAction == .favorite)
            #expect(EpisodeSwipeMotion(translation: -300, width: 390, removes: true).direction == .left)
            controller.push(.settings(.swipeActions)); controller.view.layoutIfNeeded()
            try #require(find("prefSwipeQueue", in: controller.view, as: UIControl.self)).sendActions(for: .touchUpInside)
            try await wait { controller.presentedViewController?.isBeingPresented == false }
            let dialog = try #require(controller.presentedViewController)
            dialog.view.layoutIfNeeded()
            #expect(dialog.view.effectiveUserInterfaceLayoutDirection == .rightToLeft)
            for (direction, iconOnRight) in [("left", true), ("right", false)] {
                let preview = try #require(find("inboxSwipePreview-" + direction, in: dialog.view, as: UIControl.self))
                // [mock episode, icon region]: the icon is where the real swipe reveals it (physical, not mirrored).
                let icon = try #require(preview.subviews.last)
                #expect((icon.frame.midX > preview.bounds.midX) == iconOnRight, "\(direction) icon side")
                let change = try #require(find("inboxSwipeChange-" + direction, in: dialog.view, as: UIButton.self))
                // Text rows mirror: Change sits at the start edge (left) in RTL.
                #expect(change.convert(change.bounds, to: dialog.view).midX < dialog.view.bounds.midX)
            }
            try #require(find("inboxSwipeCancel", in: dialog.view, as: UIButton.self)).sendActions(for: .touchUpInside)
            try await wait { controller.presentedViewController == nil }
        }
    }
}
