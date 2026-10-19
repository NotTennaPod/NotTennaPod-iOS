import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Mounted checks: every Settings → Swipe actions row opens
/// its screen's dialog with the source title and defaults, Cancel stores nothing and Confirm stores the pair and the
/// switch; Queue and History swipes remove with their source message and Undo, locked or not; selection rules; RTL.
@MainActor @Suite(.serialized)
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwipeSettingsView-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let downloads = DownloadCoordinator(store: store, directory: root.appendingPathComponent("media"), network: .init(startMonitoring: false), preferences: { .init() })
        let playback = PlaybackCoordinator(store: store, engine: Engine())
        do {
            let base = Date(timeIntervalSince1970: 1_780_000_000)
            let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Swipe podcast", episodes: (1...5).map {
                .init(identifier: "swipe-\($0)", title: "Swipe episode \($0)", publicationDate: base.addingTimeInterval(Double($0) * 3600),
                      media: .init(url: "https://example.invalid/swipe/\($0).mp3", size: 42, durationMilliseconds: 1_800_000))
            }), source: "https://example.invalid/swipe", responseURL: URL(string: "https://example.invalid/swipe")!, validator: nil, permanentRedirectURL: nil))
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

    // MARK: Swipe gesture

    /// A pan whose state, translation and velocity the test sets: it drives `EpisodeRowSwipe` through its gesture
    /// callback, with UIKit's real animations.
    private final class ScriptedPan: UIPanGestureRecognizer {
        var scripted: UIGestureRecognizer.State = .possible, x: CGFloat = 0, velocityX: CGFloat = 0
        override var state: UIGestureRecognizer.State { get { scripted } set { scripted = newValue } }
        override func translation(in view: UIView?) -> CGPoint { CGPoint(x: x, y: 0) }
        override func velocity(in view: UIView?) -> CGPoint { CGPoint(x: velocityX, y: 0) }
    }
    private func drive(_ swipe: EpisodeRowSwipe, _ steps: [(UIGestureRecognizer.State, CGFloat)]) {
        let pan = ScriptedPan()
        for (state, x) in steps {
            pan.scripted = state; pan.x = x; pan.velocityX = -900
            _ = swipe.perform(Selector(("dragged:")), with: pan)
        }
    }
    /// Swipe backgrounds drawn over a row that is at rest: visible, and above the row they overlap.
    private func strandedSwipeBackgrounds(in list: UIView) -> [CGRect] {
        list.subviews.enumerated().filter { _, view in
            type(of: view) == UIView.self && view.subviews.count == 1 && view.subviews[0] is UIImageView
                && !view.isHidden && view.alpha > 0 && view.bounds.width > 0
        }.filter { above, background in
            list.subviews.enumerated().contains { index, row in
                index < above && row is EpisodeRowView && row.transform == .identity && row.frame.intersects(background.frame)
            }
        }.map(\.element.frame)
    }

    enum SecondSwipe: CaseIterable { case none, heldWhenRemoved, releasedWhenRemoved }

    /// The owner's picture: a grey swipe background with the remove icon left over a row that is not being swiped.
    /// A completed "Remove from queue" swipe slides the row out, and it stays out until its removal lands, as Android's
    /// swiped-out item does. A second swipe on it meanwhile (the finger still down, or released past half the width)
    /// neither brings it back nor cancels the first swipe's removal, and the removal leaves no background behind.
    @Test(arguments: SecondSwipe.allCases)
    func removeSwipeLeavesNoBackgroundOverTheRowThatMovesUp(second: SecondSwipe) async throws {
        try await withScreen(.queue) { controller, fixture in
            let ids = fixture.ids
            try fixture.swipe.confirm(.init(screen: .queue, configuration: .init(left: .removeQueue, right: .favorite)))
            let button = try #require(find("episode-\(ids[1])", in: controller.view, as: UIButton.self))
            var parent: UIView? = button
            while parent != nil && !(parent is EpisodeRowView) { parent = parent?.superview }
            let row = try #require(parent as? EpisodeRowView), list = try #require(row.superview), swipe = try #require(row.swipe)
            let slot = row.frame, width = row.bounds.width
            drive(swipe, [(.began, -12), (.changed, -0.6 * width), (.ended, -0.6 * width)])
            switch second {
            case .none: break
            case .heldWhenRemoved: drive(swipe, [(.began, -12), (.changed, -0.75 * width)])
            case .releasedWhenRemoved: drive(swipe, [(.began, -12), (.changed, -0.75 * width), (.ended, -0.75 * width)])
            }
            let removed = try await outUntilRemoved(row)
            #expect(removed.left, "the removal landed")
            #expect(!removed.cameBack, "the row stays out until its removal lands")
            // UIKit cancels the gesture of a view that left the screen under the finger.
            if second == .heldWhenRemoved { drive(swipe, [(.cancelled, -0.75 * width)]) }
            try await wait { rows(ids, in: controller) == [ids[0], ids[2], ids[3]] }
            #expect(try await fixture.store.queue().map(\.id) == [ids[0], ids[2], ids[3]])
            let next = try #require(find("episode-\(ids[2])", in: controller.view, as: UIButton.self))
            #expect(abs(next.convert(next.bounds, to: list).minY - slot.minY) < 1, "the next row moved up into the slot")
            // Each swipe animation takes a quarter second: wait for the screen to come to rest.
            let rest = ContinuousClock.now + .seconds(2)
            while !strandedSwipeBackgrounds(in: list).isEmpty, ContinuousClock.now < rest { try await Task.sleep(for: .milliseconds(10)) }
            let stranded = strandedSwipeBackgrounds(in: list)
            #expect(stranded.isEmpty, "swipe background \(stranded) left over the row now in slot \(slot)")
        }
    }

    /// Samples `row` on every turn until it leaves its list: whether it left, and whether it was back in its place before.
    private func outUntilRemoved(_ row: UIView) async throws -> (left: Bool, cameBack: Bool) {
        var cameBack = false
        let deadline = ContinuousClock.now + .seconds(8)
        while row.superview != nil, ContinuousClock.now < deadline {
            if row.transform == .identity { cameBack = true }
            try await Task.sleep(for: .milliseconds(1))
        }
        return (row.superview == nil, cameBack)
    }

    /// The owner's case: one completed "Remove from queue" swipe, and nothing but the list keeps the row and its swipe.
    /// The row leaves when its removal lands, and its background leaves with it.
    @Test func aSingleRemoveSwipeLeavesNoBackgroundWhenOnlyTheListKeepsItsRow() async throws {
        try await withScreen(.queue) { controller, fixture in
            let ids = fixture.ids
            try fixture.swipe.confirm(.init(screen: .queue, configuration: .init(left: .removeQueue, right: .favorite)))
            weak var removedRow: EpisodeRowView?
            weak var removedSwipe: EpisodeRowSwipe?
            let list: UIView, slot: CGRect
            do {
                let button = try #require(find("episode-\(ids[1])", in: controller.view, as: UIButton.self))
                var parent: UIView? = button
                while parent != nil && !(parent is EpisodeRowView) { parent = parent?.superview }
                let row = try #require(parent as? EpisodeRowView), swipe = try #require(row.swipe)
                list = try #require(row.superview); slot = row.frame
                removedRow = row; removedSwipe = swipe
                drive(swipe, [(.began, -12), (.changed, -0.6 * row.bounds.width), (.ended, -0.6 * row.bounds.width)])
            }
            try await wait { rows(ids, in: controller) == [ids[0], ids[2], ids[3]] }
            #expect(try await fixture.store.queue().map(\.id) == [ids[0], ids[2], ids[3]])
            try await wait { removedRow == nil && removedSwipe == nil }
            let rest = ContinuousClock.now + .seconds(2)
            while !strandedSwipeBackgrounds(in: list).isEmpty, ContinuousClock.now < rest { try await Task.sleep(for: .milliseconds(10)) }
            let stranded = strandedSwipeBackgrounds(in: list)
            #expect(stranded.isEmpty, "swipe background \(stranded) left over the row now in slot \(slot)")
        }
    }

    /// With Reduce Motion the row moves without animation: out at once, and it stays out until its removal lands (no jump
    /// out and back). Reduce Motion is the swipe's own reading of the setting here; the setting itself is never changed.
    @Test(arguments: [false, true])
    func aRemoveSwipeKeepsItsRowOutUntilItsRemovalLands(reduceMotion: Bool) async throws {
        try await withScreen(.queue) { controller, fixture in
            let ids = fixture.ids
            try fixture.swipe.confirm(.init(screen: .queue, configuration: .init(left: .removeQueue, right: .favorite)))
            let button = try #require(find("episode-\(ids[1])", in: controller.view, as: UIButton.self))
            var parent: UIView? = button
            while parent != nil && !(parent is EpisodeRowView) { parent = parent?.superview }
            let row = try #require(parent as? EpisodeRowView), swipe = try #require(row.swipe)
            swipe.reduceMotion = { reduceMotion }
            let width = row.bounds.width
            drive(swipe, [(.began, -12), (.changed, -0.6 * width), (.ended, -0.6 * width)])
            let removed = try await outUntilRemoved(row)
            #expect(removed.left && !removed.cameBack, "out until the removal lands")
            try await wait { rows(ids, in: controller) == [ids[0], ids[2], ids[3]] }
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

    // MARK: Swipe gesture on the screen (the row's own gesture, with UIKit's real animations)

    /// `fling`: the finger moves at 900 points a second in the swipe's direction; otherwise it stops before letting go.
    private func swipeGesture(_ row: EpisodeRowView, _ steps: [(UIGestureRecognizer.State, CGFloat)], fling: Bool = true) throws {
        let swipe = try #require(row.swipe, "the row has a swipe")
        let pan = ScriptedPan()
        for (state, x) in steps {
            pan.scripted = state; pan.x = x; pan.velocityX = fling ? (x < 0 ? -900 : 900) : 0
            _ = swipe.perform(Selector(("dragged:")), with: pan)
        }
    }
    /// Every built row of episode `id` (Home can show one episode in two sections), top to bottom.
    private func episodeRows(_ id: Int64, in controller: LibraryViewController) -> [EpisodeRowView] {
        all(EpisodeRowView.self, in: controller.content).filter { row in
            all(UIButton.self, in: row).contains { $0.accessibilityIdentifier == "episode-\(id)" }
        }.sorted { $0.convert($0.bounds, to: controller.content).minY < $1.convert($1.bounds, to: controller.content).minY }
    }

    /// The player's position is whatever the test says it reached (the coordinator saves it every five seconds).
    private final class ScriptedEngine: PlaybackEngine {
        var reading: PlaybackEngineReading?
        var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
        private var generation: UUID?, commandID: UUID?
        private(set) var position: Int32 = 0
        private var playing = false
        func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
            self.generation = generation; commandID = generation; position = Int32(positionMilliseconds); reading = nil
        }
        func play(commandID: UUID) { self.commandID = commandID; playing = true; reading?.commandID = commandID; reading?.sample.status = .playing }
        func pause(commandID: UUID) { self.commandID = commandID; playing = false; reading?.commandID = commandID; reading?.sample.status = .paused }
        func seek(to positionMilliseconds: Int64, commandID: UUID) { self.commandID = commandID; position = Int32(positionMilliseconds) }
        func setSpeed(_ speed: Float, commandID: UUID) throws { self.commandID = commandID }
        func unload() { reading = nil; generation = nil; commandID = nil }
        private func value(_ position: Int32) -> PlaybackEngineReading? {
            guard let generation, let commandID else { return nil }
            return PlaybackEngineReading(generation: generation, commandID: commandID,
                sample: .init(positionMilliseconds: position, durationMilliseconds: 1_800_000, status: playing ? .playing : .paused))
        }
        func ready() { guard let value = value(position) else { return }; reading = value; onEvent?(.ready(value)) }
        func moved(to position: Int32) {
            self.position = position
            guard let value = value(position) else { return }
            reading = value; onEvent?(.position(value))
        }
    }

    /// `withScreen` with a playback engine of the test's choice and a change to the library before the screen opens.
    private func withPlayableScreen(_ destination: NavigationDestination, engine: (any PlaybackEngine)? = nil, local: Bool = false,
                                 prepare: @MainActor (FeedLibraryStore, [Int64], DownloadPreferenceStore) async throws -> Void = { _, _, _ in },
                                 _ body: @MainActor (LibraryViewController, Fixture, PlaybackCoordinator) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwipeGestureView-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let downloads = DownloadCoordinator(store: store, directory: root.appendingPathComponent("media"), network: .init(startMonitoring: false), preferences: { .init() })
        let playback = PlaybackCoordinator(store: store, engine: engine ?? Engine())
        do {
            let base = Date(timeIntervalSince1970: 1_780_000_000)
            let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Swipe podcast", episodes: (1...5).map {
                .init(identifier: "swipe-\($0)", title: "Swipe episode \($0)", publicationDate: base.addingTimeInterval(Double($0) * 3600),
                      media: .init(url: "https://example.invalid/swipe/\($0).mp3", size: 42, durationMilliseconds: 1_800_000))
            }), source: local ? "antennapod_local:unregistered" : "https://example.invalid/swipe", responseURL: URL(string: "https://example.invalid/swipe")!, validator: nil, permanentRedirectURL: nil))
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
            try await prepare(store, ids, downloadPreferences)
            let fixture = Fixture(root: root, store: store, swipe: swipe, downloadPreferences: downloadPreferences, queue: queue, ids: ids)
            var controller: LibraryViewController? = LibraryViewController(library: store, startupError: nil, downloads: downloads, playback: playback,
                timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil,
                downloadPreferences: downloadPreferences, inboxSwipePreferences: swipe, queueInteractionPreferences: queue)
            try await withViewTestWindow { host, _ in
                let mounted = try #require(controller)
                host.addChild(mounted); host.view.addSubview(mounted.view); mounted.didMove(toParent: host)
                mounted.view.frame = host.view.bounds
                defer { mounted.dismiss(animated: false); mounted.willMove(toParent: nil); mounted.view.removeFromSuperview(); mounted.removeFromParent() }
                await mounted.reloadLibrary()?.value; mounted.view.layoutIfNeeded()
                try await body(mounted, fixture, playback)
            }
            controller = nil
            try await playback.stop(); await downloads.stop(); try await store.close()
        } catch { try? await playback.stop(); await downloads.stop(); try? await store.close(); throw error }
    }

    /// Home shows a new episode that is also downloaded (an automatic download) in both "New" and "Downloads", as
    /// Android's InboxSection and DownloadsSection each list it. Each row swipes with its own section's settings
    /// (`SwipeActions(this, InboxFragment.TAG)` and `SwipeActions(this, CompletedDownloadsFragment.TAG)`): a swipe on
    /// either row must do something.
    @Test func homeRowsOfOneEpisodeInNewAndDownloadsEachSwipe() async throws {
        try await withPlayableScreen(.home, prepare: { store, ids, downloads in
            // The newest episode is new and downloaded; one older episode is downloaded too.
            try await store.updateEpisode(id: ids[4]) { $0.userState.playState = .new; $0.userState.isDownloaded = true }
            try await store.updateEpisode(id: ids[3]) { $0.userState.isDownloaded = true }
            var value = downloads.value; var swipe = DownloadsSwipePreferences(); swipe.left = .favorite; swipe.right = .favorite
            value.swipe = swipe; try downloads.update(value)
        }) { controller, fixture, _ in
            let ids = fixture.ids, episode = ids[4]
            try fixture.swipe.confirm(.init(screen: .inbox, configuration: .init(left: .removeInbox, right: .queue)))
            controller.view.layoutIfNeeded()
            let both = episodeRows(episode, in: controller)
            try #require(both.count == 2, "the episode has a row in New and one in Downloads")
            let download = both[1], width = download.bounds.width
            // The Downloads row: its own settings (Add to favorites, which keeps the row).
            try swipeGesture(download, [(.began, -12), (.changed, -0.6 * width)])
            #expect(download.transform != .identity, "the Downloads row follows the finger")
            try swipeGesture(download, [(.ended, -0.6 * width)])
            try await wait { try await fixture.store.episode(id: episode)?.userState.isFavorite == true }
            try await wait { controller.presentedViewController == nil && self.episodeRows(episode, in: controller).count == 2 }
            // The favorite's patch has drawn both sections again before the next swipe starts.
            await controller.settleLibraryChanges(); controller.view.layoutIfNeeded()
            // The New row: the Inbox's settings (Remove from inbox, which slides it out).
            let newRow = try #require(episodeRows(episode, in: controller).first)
            try swipeGesture(newRow, [(.began, -12), (.changed, -0.6 * width)])
            #expect(newRow.transform != .identity, "the New row follows the finger")
            try swipeGesture(newRow, [(.ended, -0.6 * width)])
            let deadline = ContinuousClock.now + .seconds(3)
            while try await fixture.store.episode(id: episode)?.userState.playState == .new, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(try await fixture.store.episode(id: episode)?.userState.playState == .unplayed,
                    "a left swipe on the New row removes the episode from the inbox")
        }
    }

    /// Home's twin rows of one episode: a Favorite swiped on its Downloads row redraws both sections, and its patch lands
    /// while the New row's Remove from inbox swipe slides out. The section drawn again detaches the New row; its accepted
    /// removal is still performed.
    @Test func aHomeRowDrawnAgainAsItsRemoveSlidesOutKeepsItsAcceptedRemoval() async throws {
        try await withPlayableScreen(.home, prepare: { store, ids, downloads in
            try await store.updateEpisode(id: ids[4]) { $0.userState.playState = .new; $0.userState.isDownloaded = true }
            try await store.updateEpisode(id: ids[3]) { $0.userState.isDownloaded = true }
            var value = downloads.value; var swipe = DownloadsSwipePreferences(); swipe.left = .favorite; swipe.right = .favorite
            value.swipe = swipe; try downloads.update(value)
        }) { controller, fixture, _ in
            let episode = fixture.ids[4]
            try fixture.swipe.confirm(.init(screen: .inbox, configuration: .init(left: .removeInbox, right: .queue)))
            controller.view.layoutIfNeeded()
            let both = episodeRows(episode, in: controller)
            try #require(both.count == 2, "the episode has a row in New and one in Downloads")
            let newRow = both[0], download = both[1], width = download.bounds.width
            // The Favorite's patch waits until the New row's swipe is sliding out.
            let updater = try #require(controller.screenUpdater)
            updater.beginOpen()
            try swipeGesture(download, [(.began, -12), (.changed, -0.6 * width), (.ended, -0.6 * width)])
            try await wait { try await fixture.store.episode(id: episode)?.userState.isFavorite == true }
            try swipeGesture(newRow, [(.began, -12), (.changed, -0.6 * width), (.ended, -0.6 * width)])
            let released = ContinuousClock.now
            updater.opened(at: nil)
            await controller.settleLibraryChanges()
            try #require(newRow.superview == nil && ContinuousClock.now - released < .milliseconds(250),
                         "the New row was drawn again while it slid out")
            try await wait { try await fixture.store.episode(id: episode)?.userState.playState == .unplayed }
            #expect(try await fixture.store.episode(id: episode)?.userState.isFavorite == true)
        }
    }

    enum KeptRowInterruption: CaseIterable { case drawnAgain, offScreen, secondSwipe }

    /// A swipe whose action keeps the row (Add to favorites) performs it when the row has slid back, as Android's
    /// `clearView` performs it: once, on the episode swiped, whatever happens to the row in that quarter second (the screen
    /// drawn again, the screen leaving the window, or a second swipe on the row that the person lets go of).
    @Test(arguments: KeptRowInterruption.allCases)
    func aKeptRowSwipeIsPerformedWhenItsRowIsPaintedAgainAsItSlidesBack(interruption: KeptRowInterruption) async throws {
        try await withPlayableScreen(.queue) { controller, fixture, _ in
            let ids = fixture.ids, id = ids[1]
            try fixture.swipe.confirm(.init(screen: .queue, configuration: .init(left: .removeQueue, right: .favorite)))
            let row = try #require(episodeRows(id, in: controller).first), width = row.bounds.width
            let host = try #require(controller.view.superview)
            try swipeGesture(row, [(.began, 12), (.changed, 0.6 * width)])
            #expect(row.transform != .identity)
            let released = ContinuousClock.now
            try swipeGesture(row, [(.ended, 0.6 * width)])
            switch interruption {
            case .drawnAgain: controller.render()
            case .offScreen: controller.view.removeFromSuperview()
            case .secondSwipe: try swipeGesture(row, [(.began, 12), (.changed, 0.3 * width), (.cancelled, 0.3 * width)])
            }
            try #require(ContinuousClock.now - released < .milliseconds(250), "the row was interrupted while it slid back")
            if interruption == .drawnAgain { #expect(row.superview == nil) }
            if interruption == .offScreen { #expect(row.window == nil) }
            try await wait { try await fixture.store.episode(id: id)?.userState.isFavorite == true }
            await controller.lastInboxSwipe?.value
            #expect(try await fixture.store.episode(id: id)?.userState.isFavorite == true, "performed once")
            #expect(try await fixture.store.episode(id: ids[0])?.userState.isFavorite == false, "on the episode swiped")
            if interruption == .offScreen { host.addSubview(controller.view); controller.view.frame = host.bounds }
        }
    }

    /// A removing swipe's removal is performed when its row is drawn again, or its screen leaves the window, while it slides
    /// out.
    @Test(arguments: [KeptRowInterruption.drawnAgain, .offScreen])
    func anAcceptedRemoveIsPerformedWhenItsRowIsInterruptedAsItSlidesOut(interruption: KeptRowInterruption) async throws {
        try await withPlayableScreen(.queue) { controller, fixture, _ in
            let ids = fixture.ids
            try fixture.swipe.confirm(.init(screen: .queue, configuration: .init(left: .removeQueue, right: .favorite)))
            let row = try #require(episodeRows(ids[1], in: controller).first), width = row.bounds.width
            let host = try #require(controller.view.superview)
            try swipeGesture(row, [(.began, -12), (.changed, -0.6 * width), (.ended, -0.6 * width)])
            if interruption == .drawnAgain { controller.render(); #expect(row.superview == nil) }
            else { controller.view.removeFromSuperview() }
            try await wait { try await fixture.store.queue().map(\.id) == [ids[0], ids[2], ids[3]] }
            if interruption == .offScreen { host.addSubview(controller.view); controller.view.frame = host.bounds }
            try await wait { self.episodeRows(ids[1], in: controller).isEmpty }
            #expect(all(EpisodeRowView.self, in: controller.content).allSatisfy { $0.transform == .identity })
        }
    }

    /// The playing episode's row while playback runs: the player saves its position every five seconds. A swipe held on
    /// that row (a person removing the episode they are listening to from the queue) must not be cut off by a save.
    @Test func aPositionSaveDoesNotInterruptASwipeOnThePlayingRow() async throws {
        let engine = ScriptedEngine()
        try await withPlayableScreen(.queue, engine: engine) { controller, fixture, playback in
            let ids = fixture.ids, id = ids[0]
            try fixture.swipe.confirm(.init(screen: .queue, configuration: .init(left: .removeQueue, right: .favorite)))
            try await playback.select(episodeID: id, play: true)
            engine.ready()
            try await wait { playback.phase == .playing }
            var position: Int32 = 60_000
            engine.moved(to: position)
            try await wait { playback.sample?.positionMilliseconds == position }
            await controller.settleLibraryChanges(); controller.view.layoutIfNeeded()
            let stored = try await fixture.store.episode(id: id)?.userState.positionMilliseconds
            let row = try #require(episodeRows(id, in: controller).first), width = row.bounds.width
            try swipeGesture(row, [(.began, -12), (.changed, -0.3 * width)])
            #expect(row.transform != .identity)
            // Playback runs on (a sample every 100 ms) until the player has saved a newer position.
            let deadline = ContinuousClock.now + .seconds(9)
            var leftBeforeTheSave = false
            while ContinuousClock.now < deadline {
                let gone = row.superview == nil
                guard try await fixture.store.episode(id: id)?.userState.positionMilliseconds == stored else { break }
                if gone { leftBeforeTheSave = true }
                position += 100; engine.moved(to: position)
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(try await fixture.store.episode(id: id)?.userState.positionMilliseconds != stored, "the player saved its position")
            try #require(!leftBeforeTheSave, "the live samples alone keep the row")
            await controller.settleLibraryChanges(); controller.view.layoutIfNeeded()
            #expect(row.superview != nil, "the save does not build the row under the finger again")
            #expect(row.transform != .identity, "the swipe under the finger goes on")
            try swipeGesture(row, [(.cancelled, -0.3 * width)])
            try await playback.pause()
        }
    }

    /// The swipe backgrounds shown in `list` (the grey background with the action's icon beside a swiped row).
    private func visibleSwipeBackgrounds(in list: UIView) -> [UIView] {
        list.subviews.filter { view in
            type(of: view) == UIView.self && view.subviews.count == 1 && view.subviews[0] is UIImageView
                && !view.isHidden && view.alpha > 0 && view.bounds.width > 0
        }
    }
    /// Rows back at rest and no background left: what a person sees once every swipe is over.
    private func atRest(_ controller: LibraryViewController) -> Bool {
        all(EpisodeRowView.self, in: controller.content).allSatisfy { $0.transform == .identity }
            && visibleSwipeBackgrounds(in: controller.content).isEmpty
    }

    // MARK: A removing swipe whose removal does not land

    /// "Add to queue" on the Inbox, on a new episode already queued, removes it from the queue (`AddToQueueSwipeAction`)
    /// and slides it out (it "will remove" on the Inbox), but the episode stays new: its row comes back, and shows that it
    /// is no longer queued.
    @Test func aRemovingSwipeWhoseEpisodeStaysBringsItsRowBack() async throws {
        try await withPlayableScreen(.inbox, prepare: { store, ids, _ in
            try await store.updateEpisode(id: ids[1]) { $0.userState.playState = .new }
        }) { controller, fixture, _ in
            let ids = fixture.ids, id = ids[1]
            try fixture.swipe.confirm(.init(screen: .inbox, configuration: .init(left: .queue, right: .removeInbox)))
            let row = try #require(episodeRows(id, in: controller).first), width = row.bounds.width
            #expect(controller.inboxSwipeConfiguration(.left, episodeID: id)?.removes == true)
            try swipeGesture(row, [(.began, -12), (.changed, -0.6 * width), (.ended, -0.6 * width)])
            try await wait { try await fixture.store.queue().map(\.id) == [ids[0], ids[2], ids[3]] }
            #expect(try await fixture.store.episode(id: id)?.userState.playState == .new)
            try await wait { self.atRest(controller) && self.episodeRows(id, in: controller).count == 1 }
            let shown = try #require(episodeRows(id, in: controller).first)
            #expect(shown.window != nil && shown.frame.minX == 0, "the row is back in its place")
            #expect(shown !== row, "drawn again once its swipe ended: it is no longer queued")
        }
    }

    /// Delete on Downloads, on a local folder's episode: the row stays out while the warning asks, and comes back when the
    /// person cancels; nothing is deleted.
    @Test func aCancelledLocalDeleteWarningOnDownloadsBringsTheRowBack() async throws {
        try await withPlayableScreen(.downloads, local: true, prepare: { store, ids, downloads in
            try await store.updateEpisode(id: ids[1]) { $0.userState.isDownloaded = true }
            var value = downloads.value; var swipe = DownloadsSwipePreferences(); swipe.left = .delete; swipe.right = .delete
            value.swipe = swipe; try downloads.update(value)
        }) { controller, fixture, _ in
            let id = fixture.ids[1]
            let row = try #require(episodeRows(id, in: controller).first), width = row.bounds.width
            try swipeGesture(row, [(.began, -12), (.changed, -0.6 * width), (.ended, -0.6 * width)])
            try await wait { controller.presentedViewController?.isBeingPresented == false }
            let warning = try #require(controller.presentedViewController)
            #expect(row.superview != nil && row.transform != .identity, "out while the warning asks")
            try #require(find("cancelLocalEpisodeDelete", in: warning.view, as: UIButton.self)).sendActions(for: .touchUpInside)
            try await wait { controller.presentedViewController == nil }
            try await wait { self.atRest(controller) }
            #expect(row.superview != nil, "the row is back")
            #expect(try await fixture.store.episode(id: id)?.userState.isDownloaded == true)
        }
    }

    // MARK: Undo of a removing swipe

    enum UndoMoment: CaseIterable { case afterTheQueueChanged, beforeTheRowLeft }

    /// Undo of a swiped "Remove from queue" puts the episode back at the place it had, in the queue as it is then
    /// (`RemoveFromQueueSwipeAction`: `addQueueItemAt(position)`): after another change to the queue, or before the screen
    /// showed the removal at all (the removal and its Undo reach the screen together). Every row is back at rest.
    @Test(arguments: UndoMoment.allCases)
    func removeSwipeUndoRestoresTheEpisodeInItsPlace(moment: UndoMoment) async throws {
        try await withPlayableScreen(.queue) { controller, fixture, _ in
            let ids = fixture.ids
            try fixture.swipe.confirm(.init(screen: .queue, configuration: .init(left: .removeQueue, right: .favorite)))
            let updater = try #require(controller.screenUpdater), active = updater.isActive
            if moment == .beforeTheRowLeft { updater.isActive = { false } }
            let row = try #require(episodeRows(ids[1], in: controller).first), width = row.bounds.width
            try swipeGesture(row, [(.began, -12), (.changed, -0.6 * width), (.ended, -0.6 * width)])
            try await wait { try await fixture.store.queue().map(\.id) == [ids[0], ids[2], ids[3]] }
            let expected: [Int64]
            switch moment {
            case .afterTheQueueChanged:
                try await wait { self.rows(ids, in: controller) == [ids[0], ids[2], ids[3]] }
                _ = try await fixture.store.removeFromQueue([ids[0]])
                try await wait { self.rows(ids, in: controller) == [ids[2], ids[3]] }
                expected = [ids[2], ids[1], ids[3]]
            case .beforeTheRowLeft:
                expected = Array(ids.prefix(4))
            }
            let undo = try #require(find("inboxSwipeUndo", in: controller.view, as: UIButton.self))
            undo.sendActions(for: .touchUpInside)
            try await wait { try await fixture.store.queue().map(\.id) == expected }
            if moment == .beforeTheRowLeft { updater.isActive = active; updater.activate() }
            await controller.settleLibraryChanges()
            try await wait { self.rows(ids, in: controller) == expected && self.atRest(controller) }
            #expect(episodeRows(ids[1], in: controller).count == 1)
        }
    }

    // MARK: A patch during a swipe

    /// A change to the swiped episode that a patch brings (a sync, a download) neither builds the row under the finger
    /// again nor ends its swipe; the row shows the change when the swipe ends.
    @Test func aChangeToASwipedRowShowsWhenItsSwipeEnds() async throws {
        try await withPlayableScreen(.queue) { controller, fixture, _ in
            let ids = fixture.ids, id = ids[1]
            try fixture.swipe.confirm(.init(screen: .queue, configuration: .init(left: .removeQueue, right: .favorite)))
            let row = try #require(episodeRows(id, in: controller).first), width = row.bounds.width
            try swipeGesture(row, [(.began, -12), (.changed, -0.3 * width)])
            try await fixture.store.updateEpisode(id: id) { $0.userState.isFavorite = true }
            await controller.settleLibraryChanges(); controller.view.layoutIfNeeded()
            #expect(row.superview != nil, "the row under the finger is kept")
            #expect(controller.inboxSwipeConfiguration(.left, episodeID: id) != nil, "its swipe can go on")
            try swipeGesture(row, [(.changed, -0.4 * width)])
            #expect(row.transform != .identity, "the swipe follows the finger")
            try swipeGesture(row, [(.cancelled, -0.4 * width)])
            try await wait { row.superview == nil && self.atRest(controller) }
            let shown = try #require(episodeRows(id, in: controller).first)
            #expect(shown.actionModel?.snapshot().episode.userState.isFavorite == true, "drawn again with the change")
            #expect(controller.inboxSwipeConfiguration(.left, episodeID: id) != nil)
        }
    }

    /// A patch that moves a row during its swipe (a row above it removed, or Home's section above it growing) moves the
    /// swipe's background with it.
    @Test func aSwipesBackgroundFollowsItsRowWhenAPatchMovesIt() async throws {
        try await withPlayableScreen(.queue) { controller, fixture, _ in
            let ids = fixture.ids
            try fixture.swipe.confirm(.init(screen: .queue, configuration: .init(left: .removeQueue, right: .favorite)))
            let row = try #require(episodeRows(ids[2], in: controller).first), width = row.bounds.width
            try swipeGesture(row, [(.began, -12), (.changed, -0.4 * width)])
            let before = row.center.y
            _ = try await fixture.store.removeFromQueue([ids[0]])
            await controller.settleLibraryChanges(); controller.view.layoutIfNeeded()
            try #require(row.center.y < before - 1, "the row moved up")
            let background = try #require(visibleSwipeBackgrounds(in: controller.content).first)
            #expect(abs(background.frame.midY - row.center.y) < 0.5 && abs(background.frame.height - row.bounds.height) < 0.5,
                    "background \(background.frame) beside its row at \(row.center.y)")
            // The swiped episode itself leaves: its row and background go.
            _ = try await fixture.store.removeFromQueue([ids[2]])
            await controller.settleLibraryChanges()
            try await wait { row.superview == nil && self.atRest(controller) }
        }
        try await withPlayableScreen(.home, prepare: { store, ids, downloads in
            try await store.updateEpisode(id: ids[4]) { $0.userState.isDownloaded = true }
            var value = downloads.value; var swipe = DownloadsSwipePreferences(); swipe.left = .favorite; swipe.right = .favorite
            value.swipe = swipe; try downloads.update(value)
        }) { controller, fixture, _ in
            let ids = fixture.ids
            let row = try #require(episodeRows(ids[4], in: controller).first), width = row.bounds.width
            try swipeGesture(row, [(.began, -12), (.changed, -0.6 * width)])
            let before = row.center.y
            // A new episode joins "New", above "Downloads".
            try await fixture.store.updateEpisode(id: ids[3]) { $0.userState.playState = .new }
            await controller.settleLibraryChanges(); controller.view.layoutIfNeeded()
            try #require(abs(row.center.y - before) > 1 && row.superview != nil, "Downloads moved")
            let background = try #require(visibleSwipeBackgrounds(in: controller.content).first)
            #expect(abs(background.frame.midY - row.center.y) < 0.5, "background \(background.frame) beside its row at \(row.center.y)")
            try swipeGesture(row, [(.cancelled, -0.6 * width)])
            try await wait { self.atRest(controller) }
        }
    }

    // MARK: Downloads Toggle played

    /// Toggle played on Downloads is the lists' swipe mark (`TogglePlaybackStateSwipeAction` → `markReadWithUndo`): it
    /// keeps the position, queues no played or new action for a synchronization account (Android's `markItemsPlayed`
    /// queues none), and offers no Undo on Downloads.
    @Test func downloadsTogglePlayedKeepsThePositionAndSendsNoSyncAction() async throws {
        try await withPlayableScreen(.downloads, prepare: { store, ids, downloads in
            try await store.updateEpisode(id: ids[1]) {
                $0.userState.isDownloaded = true; $0.userState.playState = .unplayed; $0.userState.positionMilliseconds = 42_000
            }
            var state = try await store.synchronizationState(); state.accountID = UUID()
            try await store.saveSynchronizationState(state)
            var value = downloads.value; var swipe = DownloadsSwipePreferences(); swipe.left = .played; swipe.right = .played
            value.swipe = swipe; try downloads.update(value)
        }) { controller, fixture, _ in
            let id = fixture.ids[1]
            let before = try await fixture.store.synchronizationQueue().count
            for expected in [EpisodePlayState.played, .unplayed] {
                let row = try #require(episodeRows(id, in: controller).first), width = row.bounds.width
                try swipeGesture(row, [(.began, -12), (.changed, -0.6 * width), (.ended, -0.6 * width)])
                try await wait { try await fixture.store.episode(id: id)?.userState.playState == expected }
                await controller.settleLibraryChanges()
                #expect(try await fixture.store.episode(id: id)?.userState.positionMilliseconds == 42_000)
                #expect(try await fixture.store.synchronizationQueue().count == before, "no manual sync action")
                #expect(find("inboxSwipeSnackbar", in: controller.view, as: UIView.self) == nil)
                try await wait { self.atRest(controller) }
            }
        }
    }

    // MARK: An accepted swipe keeps what it was accepted for

    /// Delete on Downloads deletes the file it was accepted for, or nothing: a new download of the episode that lands
    /// before the deletion runs (replaced media) survives, and stays downloaded (`DeleteSwipeAction` keeps its item's media).
    @Test func aDownloadsDeleteAcceptedForAFileNeverDeletesItsReplacement() async throws {
        let files = FileManager.default.temporaryDirectory.appendingPathComponent("SwipeDeleteFiles-\(UUID())")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: files) }
        let original = files.appendingPathComponent("original.mp3"), replacement = files.appendingPathComponent("replacement.mp3")
        try Data([1, 2, 3]).write(to: original); try Data([4, 5]).write(to: replacement)
        try await withPlayableScreen(.downloads, prepare: { store, ids, downloads in
            try await store.updateEpisode(id: ids[1]) { $0.userState.isDownloaded = true; $0.userState.localFileURL = original.path }
            var value = downloads.value; var swipe = DownloadsSwipePreferences(); swipe.left = .delete; swipe.right = .delete
            value.swipe = swipe; try downloads.update(value)
        }) { controller, fixture, _ in
            let id = fixture.ids[1]
            let accepted = try #require(controller.acceptDownloadsSwipe(.left, episodeID: id))
            // The episode's media is replaced before the accepted deletion runs.
            try await fixture.store.updateEpisode(id: id) {
                $0.details.media?.url = "https://example.invalid/swipe/replaced.mp3"; $0.userState.localFileURL = replacement.path
            }
            await controller.settleLibraryChanges()
            await accepted()?.value
            await controller.settleLibraryChanges()
            #expect(FileManager.default.fileExists(atPath: replacement.path), "the replacement survives")
            #expect(try await fixture.store.episode(id: id)?.userState.isDownloaded == true, "and stays downloaded")
        }
    }

    /// The same through a local folder's delete warning: the file replaced while the warning asks survives its Delete,
    /// and the row comes back.
    @Test func aLocalDeleteConfirmedAfterItsFileWasReplacedDeletesNothing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SwipeLocalFolder-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("original.mp3"), replacement = folder.appendingPathComponent("replacement.mp3")
        try Data([1, 2, 3]).write(to: original); try Data([4, 5]).write(to: replacement)
        var localID: Int64 = 0
        try await withPlayableScreen(.downloads, prepare: { store, _, downloads in
            let context = try await store.registerLocalFolder(title: "Local", directoryIdentity: folder.absoluteString,
                bookmark: LocalFolderDocuments.makeBookmark(directory: folder))
            let scan = try await store.applyLocalFolderScan(.init(format: .rss, episodes: [
                .init(identifier: "0", title: "original.mp3", link: "original.mp3", media: .init(url: original.absoluteString, size: 3, mimeType: "audio/mpeg"))
            ]), context: context)
            localID = scan.feed.episodes[0].id
            try await store.updateEpisode(id: localID) { $0.userState.isDownloaded = true }
            var value = downloads.value; var swipe = DownloadsSwipePreferences(); swipe.left = .delete; swipe.right = .delete
            value.swipe = swipe; try downloads.update(value)
        }) { controller, fixture, _ in
            let row = try #require(episodeRows(localID, in: controller).first), width = row.bounds.width
            try swipeGesture(row, [(.began, -12), (.changed, -0.6 * width), (.ended, -0.6 * width)])
            try await wait { controller.presentedViewController?.isBeingPresented == false }
            let warning = try #require(controller.presentedViewController)
            // While the warning asks, the episode's file is replaced.
            try await fixture.store.updateEpisode(id: localID) {
                $0.details.media?.url = replacement.absoluteString; $0.details.media?.size = 2; $0.details.link = "replacement.mp3"
            }
            await controller.settleLibraryChanges()
            try #require(find("confirmLocalEpisodeDelete", in: warning.view, as: UIButton.self)).sendActions(for: .touchUpInside)
            try await wait { controller.presentedViewController == nil }
            try await wait { self.atRest(controller) }
            #expect(FileManager.default.fileExists(atPath: replacement.path), "the replacement survives")
            #expect(try await fixture.store.episode(id: localID) != nil)
            #expect(episodeRows(localID, in: controller).count == 1, "the row is back")
        }
    }

    enum SettledAction: CaseIterable { case queuePlayed, downloadsPlayed, downloadsFavorite }

    /// An accepted swipe sets the state it was accepted for (Android derives it from its retained item,
    /// `TogglePlaybackStateSwipeAction`): a sync that sets that same state while the row slides back does not turn the
    /// swipe into the opposite action.
    @Test(arguments: SettledAction.allCases)
    func anAcceptedSwipeKeepsTheStateItWasAcceptedFor(_ action: SettledAction) async throws {
        let destination: NavigationDestination = action == .queuePlayed ? .queue : .downloads
        try await withPlayableScreen(destination, prepare: { store, ids, downloads in
            try await store.updateEpisode(id: ids[1]) {
                $0.userState.isDownloaded = true
                if action != .queuePlayed { $0.userState.playState = .unplayed }
            }
            var value = downloads.value; var swipe = DownloadsSwipePreferences()
            swipe.left = action == .downloadsFavorite ? .favorite : .played; swipe.right = swipe.left
            value.swipe = swipe; try downloads.update(value)
        }) { controller, fixture, _ in
            let id = fixture.ids[1]
            let accepted: EpisodeRowSwipe.Accepted
            if action == .queuePlayed {
                try fixture.swipe.confirm(.init(screen: .queue, configuration: .init(left: .played, right: .favorite)))
                accepted = try #require(controller.acceptInboxSwipe(.left, episodeID: id))
            } else {
                accepted = try #require(controller.acceptDownloadsSwipe(.left, episodeID: id))
            }
            // A sync sets the accepted state first: played to unplayed on the Queue, unplayed to played and not favorite
            // to favorite on Downloads.
            try await fixture.store.updateEpisode(id: id) {
                switch action {
                case .queuePlayed: $0.userState.playState = .unplayed
                case .downloadsPlayed: $0.userState.playState = .played
                case .downloadsFavorite: $0.userState.isFavorite = true
                }
            }
            await controller.settleLibraryChanges()
            await accepted()?.value
            await controller.settleLibraryChanges()
            let state = try #require(try await fixture.store.episode(id: id)?.userState)
            switch action {
            case .queuePlayed: #expect(state.playState == .unplayed)
            case .downloadsPlayed: #expect(state.playState == .played)
            case .downloadsFavorite: #expect(state.isFavorite)
            }
        }
    }

    /// Add to queue on Downloads settled after the episode left the queue during the drag (a sync) is performed: the
    /// queue membership at the finger's lift decides it, not the row's older one.
    @Test func aDownloadsAddToQueueSettledAfterAQueueChangeIsPerformed() async throws {
        try await withPlayableScreen(.downloads, prepare: { store, ids, downloads in
            try await store.updateEpisode(id: ids[1]) { $0.userState.isDownloaded = true }
            var value = downloads.value; var swipe = DownloadsSwipePreferences(); swipe.left = .queue; swipe.right = .queue
            value.swipe = swipe; try downloads.update(value)
        }) { controller, fixture, _ in
            let id = fixture.ids[1]
            let row = try #require(episodeRows(id, in: controller).first), width = row.bounds.width
            try swipeGesture(row, [(.began, -12), (.changed, -0.3 * width)])
            _ = try await fixture.store.removeFromQueue([id])
            await controller.settleLibraryChanges()
            let model = try #require(row.actionModel)
            try #require(row.superview != nil && !controller.contextItem(model).queued, "the swiped row is kept; the episode left the queue")
            try swipeGesture(row, [(.changed, -0.6 * width), (.ended, -0.6 * width)])
            try await wait { try await fixture.store.queue().contains { $0.id == id } }
            try await wait { self.atRest(controller) }
        }
    }
}
