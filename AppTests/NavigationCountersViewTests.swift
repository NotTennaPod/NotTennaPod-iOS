import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Episode actions need a playback owner; nothing plays in these tests.
@MainActor private final class SilentEngine: PlaybackEngine {
    var reading: PlaybackEngineReading?
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {}
    func play(commandID: UUID) {}
    func pause(commandID: UUID) {}
    func seek(to positionMilliseconds: Int64, commandID: UUID) {}
    func setSpeed(_ speed: Float, commandID: UUID) throws {}
    func unload() {}
}

/// Mounted: the bottom-navigation Inbox badge, the drawer's
/// Queue/Inbox/Subscriptions counters and the Subscriptions grid counters show Android's numbers and
/// change at once when a person marks an episode played, removes one from the Inbox, archives
/// (unsubscribes), restores, subscribes to a preview and removes all from the Inbox — each through its
/// control. The library is `gap-data/counter-states.db` (a real Android 3.12.1 library with NEW
/// episodes in subscribed, archived and preview feeds) through the database import; the expected numbers
/// are `gap-data/counter-expected.json`, Android's own SQL run by `navigation_counters.py`
/// (`NavigationCountersOracleTests.recordedCountersAreCurrent` keeps it current).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)))
struct NavigationCountersViewTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../TestSupport/Data/database-restore/gap-data").standardized
    struct Counters { let inbox: Int, queue: Int, subscriptions: Int, feeds: [Int64: Int] }
    static let states: [Counters] = {
        let data = try! Data(contentsOf: fixtures.appendingPathComponent("counter-expected.json"))
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return (object["states"] as! [[String: Any]]).map { state in
            let entry = state["subscriptions_entry"] as! [String: Int]
            let perFeed = (state["feed_counters"] as! [String: [String: Int]])["SHOW_NEW"] ?? [:]
            return Counters(inbox: state["inbox"] as! Int, queue: state["queue"] as! Int, subscriptions: entry["SHOW_NEW"]!,
                            feeds: Dictionary(uniqueKeysWithValues: perFeed.map { (Int64($0.key)!, $0.value) }))
        }
    }()

    private func find<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let match = view as? T, view.accessibilityIdentifier == id { return match }
        return view.subviews.lazy.compactMap { find(id, in: $0, as: T.self) }.first
    }
    private func tap(_ id: String, in view: UIView) throws {
        let control: UIControl = try #require(find(id, in: view), "\(id)")
        control.sendActions(for: .touchUpInside)
    }
    private func wait(_ stage: String, sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while try await !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await predicate(), Comment(rawValue: stage), sourceLocation: sourceLocation)
    }
    private func presented<T: UIViewController>(_ controller: UIViewController, _ type: T.Type) async throws -> T {
        try await wait("\(T.self) presented") {
            controller.presentedViewController is T && controller.presentedViewController?.isBeingPresented == false
        }
        let result = try #require(controller.presentedViewController as? T); result.view.layoutIfNeeded(); return result
    }

    private func inboxButton(_ controller: LibraryViewController) throws -> NavigationButton {
        try #require(find(NavigationDestination.inbox.rawValue, in: controller.view, as: NavigationButton.self))
    }
    private func badge(_ controller: LibraryViewController) throws -> UILabel {
        try #require(find("navigationBadge", in: try inboxButton(controller), as: UILabel.self))
    }
    private func drawerValue(_ destination: NavigationDestination, _ controller: LibraryViewController) -> String? {
        find("drawer-" + destination.rawValue, in: controller.view, as: UIControl.self)?.accessibilityValue
    }
    /// What a person sees and hears for the counters of `state`: the Inbox badge with bottom navigation,
    /// the drawer's counters otherwise (with bottom navigation there is no drawer, as in Android).
    private func shows(_ state: Counters, _ controller: LibraryViewController) -> Bool {
        controller.view.layoutIfNeeded()
        guard controller.bottomNavigationEnabled else {
            return drawerValue(.inbox, controller) == (state.inbox > 0 ? "\(state.inbox)" : nil)
                && drawerValue(.subscriptions, controller) == (state.subscriptions > 0 ? "\(state.subscriptions)" : nil)
                && drawerValue(.queue, controller) == (state.queue > 0 ? "\(state.queue)" : nil)
        }
        guard let button = try? inboxButton(controller), let badge = try? badge(controller) else { return false }
        let badgeShown = state.inbox > 0 ? !badge.isHidden && badge.text == "\(state.inbox)" : badge.isHidden
        let spoken = state.inbox == 0 ? nil : "\(state.inbox) new notification" + (state.inbox == 1 ? "" : "s")
        return badgeShown && button.accessibilityValue == spoken
    }
    private func expectCounters(_ index: Int, _ controller: LibraryViewController, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let state = Self.states[index]
        try await wait("state \(index): Inbox \(state.inbox), Subscriptions \(state.subscriptions), Queue \(state.queue)",
                       sourceLocation: sourceLocation) { shows(state, controller) }
    }

    struct Fixture {
        let folder: URL, store: FeedLibraryStore, navigation: NavigationPreferenceStore, prefs: SubscriptionDisplayPreferenceStore
        let downloads: DownloadCoordinator, playback: PlaybackCoordinator
    }
    private func fixture(start: NavigationDestination = .inbox, bottomNavigation: Bool = true) async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GAP-DATA-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let restored = try AndroidDatabaseRestore.read(Self.fixtures.appendingPathComponent("counter-states.db"), staging: folder.appendingPathComponent("s"))
        let store = try FeedLibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        try await store.installRestoredLibrary(restored, carrying: try await store.restoreCarryOver())
        let navigation = try NavigationPreferenceStore(file: folder.appendingPathComponent("navigation.json"))
        var value = navigation.value
        value.defaultPage = "remember"; value.lastPage = start.rawValue; value.bottomNavigation = bottomNavigation
        try navigation.update(value)
        let prefs = try SubscriptionDisplayPreferenceStore(file: folder.appendingPathComponent("subscriptions.json"))
        var display = SubscriptionDisplayPreferences(); display.columns = 3
        try prefs.update(display)
        let network = DownloadNetworkMonitor(startMonitoring: false)
        network.update(.init(connected: false, metered: false, cellular: false))
        let downloads = DownloadCoordinator(store: store, directory: folder.appendingPathComponent("media"), network: network,
                                            preferences: { DownloadPreferences() })
        return Fixture(folder: folder, store: store, navigation: navigation, prefs: prefs, downloads: downloads,
                       playback: PlaybackCoordinator(store: store, engine: SilentEngine()))
    }
    private func mounted(_ fixture: Fixture, rtl: Bool = false, _ body: @MainActor (LibraryViewController) async throws -> Void) async throws {
        let controller = LibraryViewController(library: fixture.store, startupError: nil, downloads: fixture.downloads, playback: fixture.playback,
            timeDisplayPreferences: nil, navigationPreferences: fixture.navigation, speedPreferences: nil,
            mobileNetworkPreferences: nil, usage: nil,
            feedDeletion: FeedDeletionCoordinator(store: fixture.store, retirePlayback: { _ in }, retireDownloads: { _ in }))
        controller.subscriptionPreferences = fixture.prefs
        try await withViewTestWindow { host, _ in
            if rtl { host.traitOverrides.layoutDirection = .rightToLeft; controller.view.semanticContentAttribute = .forceRightToLeft }
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer {
                controller.presentedViewController?.dismiss(animated: false)
                controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent()
                host.traitOverrides.remove(UITraitLayoutDirection.self)
            }
            controller.view.frame = host.view.bounds
            controller.view.layoutIfNeeded()
            await controller.reloadLibrary()?.value
            controller.view.layoutIfNeeded()
            try await body(controller)
        }
    }
    private func close(_ fixture: Fixture) async {
        try? await fixture.playback.stop(); await fixture.downloads.stop()
        try? await fixture.store.close(); try? FileManager.default.removeItem(at: fixture.folder)
    }
    /// The episode row's context menu (long press), as ListInboxActionViewTests opens it.
    private func rowMenu(_ id: Int64, _ controller: LibraryViewController) async throws -> UIView {
        controller.view.layoutIfNeeded()
        var ancestor: UIView? = find("episode-\(id)", in: controller.view, as: UIButton.self)
        while ancestor != nil && !(ancestor is EpisodeRowView) { ancestor = ancestor?.superview }
        let row = try #require(ancestor as? EpisodeRowView, "row \(id)")
        row.contextMenu?(row, CGPoint(x: 0.4, y: 0.5))
        try await wait("menu of \(id)") { controller.presentedViewController != nil && controller.presentedViewController?.isBeingPresented == false }
        return try #require(controller.presentedViewController?.view)
    }

    /// Every counting rule and every action, in one person's session (counter-actions.json order).
    @Test func countersFollowAndroidRulesAndEveryAction() async throws {
        let fixture = try await fixture(); defer { Task { await close(fixture) } }
        try await mounted(fixture) { controller in
            // Restored: NEW episodes of archived feed 2 and preview feed 8 count nowhere.
            try await expectCounters(0, controller)
            for id: Int64 in [2, 19, 28, 29, 30] { #expect(find("episode-\(id)", in: controller.view, as: UIButton.self) != nil, "Inbox lists \(id)") }
            for id: Int64 in [3, 4, 5, 61, 62] { #expect(find("episode-\(id)", in: controller.view, as: UIButton.self) == nil, "Inbox omits \(id)") }

            // 1. Inbox row menu: Mark as played.
            try tap("markPlayed", in: try await rowMenu(28, controller))
            try await expectCounters(1, controller)
            // 2. Inbox row menu: Remove from inbox.
            try tap("removeInbox", in: try await rowMenu(29, controller))
            try await expectCounters(2, controller)
            // 3. Episode screen of the text-only episode 19: its "Mark as read" button. The screen keeps
            //    its content (it reloads preserving the episode), and the bottom bar stays visible.
            try tap("episode-19", in: controller.view); controller.view.layoutIfNeeded()
            let markRead = try #require(["episodePrimaryAction", "episodeSecondaryAction"]
                .compactMap { find($0, in: controller.view, as: UIButton.self) }.first { $0.title(for: .normal) == "Mark as read" && !$0.isHidden })
            markRead.sendActions(for: .touchUpInside)
            try await expectCounters(3, controller)
            #expect(find("episodeNoMedia", in: controller.view, as: UIView.self) != nil, "still on the episode screen")
            // 4. Unsubscribe: Subscriptions -> feed 5 -> menu -> Remove podcast -> Archive.
            try tap(NavigationDestination.subscriptions.rawValue, in: controller.view); controller.view.layoutIfNeeded()
            try tap("subscriptionFeed-5", in: controller.view); controller.view.layoutIfNeeded()
            try tap("feedListMore", in: controller.view); try tap("removeArchiveFeed", in: controller.view)
            let removal = try await presented(controller, RemoveFeedController.self)
            try tap("archiveFeed", in: removal.view)
            try await wait("archived") { try await fixture.store.feed(id: 5)?.subscriptionState == .archived }
            try await expectCounters(4, controller)
            try await wait("dialog closed") { controller.presentedViewController == nil }
            // 5. Subscriptions -> Archive -> feed 2 -> Restore.
            try tap(NavigationDestination.subscriptions.rawValue, in: controller.view); controller.view.layoutIfNeeded()
            try tap("subscriptionsMore", in: controller.view); try tap("subscriptionsArchive", in: controller.view)
            controller.view.layoutIfNeeded()
            try await wait("archive lists feed 2") { find("subscriptionFeed-2", in: controller.view, as: UIControl.self) != nil }
            try tap("subscriptionFeed-2", in: controller.view); controller.view.layoutIfNeeded()
            try await wait("archived feed 2 shown: \(controller.path)") { find("restoreFeed", in: controller.view, as: UIButton.self)?.isHidden == false }
            try tap("restoreFeed", in: controller.view)
            try await expectCounters(5, controller)
            // 6. The preview of feed 8 (reached from search or a link): Subscribe.
            controller.showPreview(8, recoveredBySearch: false)
            let preview = try await presented(controller, FeedPreviewController.self)
            let child = try #require(preview.contentController as? LibraryViewController)
            await child.reloadLibrary()?.value; preview.view.layoutIfNeeded()
            try await wait("preview header") { find("subscribeFeed", in: preview.view, as: UIButton.self)?.isHidden == false }
            try tap("subscribeFeed", in: preview.view)
            try await wait("preview closed") { controller.presentedViewController == nil }
            try await expectCounters(6, controller)
            // The Subscriptions grid shows each subscribed feed's Inbox count (SHOW_NEW), none for 0.
            try tap(NavigationDestination.subscriptions.rawValue, in: controller.view); controller.view.layoutIfNeeded()
            for (id, count) in Self.states[6].feeds {
                let pill = try #require(find("subscriptionCounter-\(id)", in: controller.view, as: UILabel.self))
                #expect(!pill.isHidden && pill.text == "\(count)", "grid counter of feed \(id)")
            }
            for id: Int64 in [3, 4, 10, 19] {
                #expect(find("subscriptionCounter-\(id)", in: controller.view, as: UILabel.self)?.isHidden != false, "no counter for feed \(id)")
            }
            #expect(find("subscriptionFeed-5", in: controller.view, as: UIControl.self) == nil, "archived feed 5 left the grid")
            // 7. Inbox menu: Remove all from inbox -> Confirm; the badge disappears.
            try tap(NavigationDestination.inbox.rawValue, in: controller.view); controller.view.layoutIfNeeded()
            try tap("inboxMore", in: controller.view); try tap("inboxRemoveAll", in: controller.view)
            let confirm = try await presented(controller, SourceMessageController.self)
            try tap("inboxRemoveAllConfirm", in: confirm.view)
            try await expectCounters(7, controller)
        }
    }

    /// With the drawer instead of bottom navigation, the drawer's Inbox, Queue and Subscriptions counters
    /// show Android's numbers and follow row actions at once.
    @Test func drawerCountersFollowAndroidRules() async throws {
        let fixture = try await fixture(bottomNavigation: false); defer { Task { await close(fixture) } }
        try await mounted(fixture) { controller in
            try await expectCounters(0, controller)
            try tap("markPlayed", in: try await rowMenu(28, controller))
            try await expectCounters(1, controller)
            try tap("removeInbox", in: try await rowMenu(29, controller))
            try await expectCounters(2, controller)
        }
    }

    /// The badge sits on the Inbox icon as in the Android capture (pill starting at the icon's centre,
    /// top about 2 points above it, mirrored in RTL), stays inside the bar above the label, and also
    /// follows a change made elsewhere while an episode screen keeps its content (playback, refresh,
    /// sync and download events reload that way).
    @Test(arguments: [false, true]) func badgeSitsOnTheIconAndFollowsChangesOnEpisodeScreens(rightToLeft: Bool) async throws {
        let fixture = try await fixture(); defer { Task { await close(fixture) } }
        try await mounted(fixture, rtl: rightToLeft) { controller in
            try await expectCounters(0, controller)
            let button = try inboxButton(controller), badge = try badge(controller)
            let iconMidX = button.bounds.midX, iconTop: CGFloat = 10
            if rightToLeft { #expect(abs(badge.frame.maxX - iconMidX) <= 1, "RTL: the pill ends at the icon centre") }
            else { #expect(abs(badge.frame.minX - iconMidX) <= 1, "the pill starts at the icon centre") }
            #expect(abs(badge.frame.minY - (iconTop - 2)) <= 1 && badge.frame.height >= 16 && badge.frame.width >= badge.frame.height)
            #expect(button.bounds.contains(badge.frame), "not clipped by its item")
            let label = try #require(button.subviews.compactMap { $0 as? UILabel }.first { $0.text == "Inbox" })
            #expect(badge.frame.maxY <= label.frame.minY, "above the Inbox label")
            #expect(button.accessibilityLabel == "Inbox")

            try tap("episode-19", in: controller.view); controller.view.layoutIfNeeded()
            try await fixture.store.removeEpisodeFromInbox(episodeID: 19)
            await controller.reloadLibrary(preservingEpisodeDetails: true)?.value
            let state = Self.states[0]
            try await wait("one fewer NEW episode") {
                shows(Counters(inbox: state.inbox - 1, queue: state.queue, subscriptions: state.subscriptions - 1, feeds: [:]), controller)
            }
            #expect(find("episodeMore", in: controller.view, as: UIControl.self) != nil, "still on the episode screen")
        }
    }

    /// Remove from inbox on a library search result keeps the results on screen (the search applies
    /// the change in place) and still updates the badge and drawer at once.
    @Test func searchResultChangeUpdatesTheBadge() async throws {
        let fixture = try await fixture(); defer { Task { await close(fixture) } }
        try await mounted(fixture) { controller in
            try await expectCounters(0, controller)
            try tap("inboxSearch", in: controller.view); controller.view.layoutIfNeeded()
            let field = try #require(find("librarySearchQuery", in: controller.view, as: UITextField.self))
            field.text = "Pull delivered"; field.sendActions(for: .editingChanged); _ = field.delegate?.textFieldShouldReturn?(field)
            try await wait("search result") { find("episode-19", in: controller.view, as: UIButton.self) != nil }
            try tap("removeInbox", in: try await rowMenu(19, controller))
            let state = Self.states[0]
            try await wait("one fewer NEW episode") {
                shows(Counters(inbox: state.inbox - 1, queue: state.queue, subscriptions: state.subscriptions - 1, feeds: [:]), controller)
            }
            #expect(find("searchEpisodeResults", in: controller.view, as: UIScrollView.self) != nil, "still on the search results")
            controller.view.endEditing(true)
        }
    }
}
