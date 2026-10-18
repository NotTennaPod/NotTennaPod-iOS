import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Mounted: tag chips on Subscriptions and Archive, the chip menu (Rename/Delete tag), multi-select
/// (action mode, circles, floating actions per state), bulk dialogs and their stored effect, the drawer's
/// folder and feed menus, and RTL. The library is the oracle's Android fixture `tags-library.db` through the
/// database import; expectations come from `TestSupport/Data/subscription-tags-bulk/expected`.
@MainActor @Suite(.serialized)
struct SubscriptionTagsViewTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../TestSupport/Data/subscription-tags-bulk").standardized
    static let oracle: [String: Any] = {
        let data = try! Data(contentsOf: fixtures.appendingPathComponent("expected/subscription-tags.json"))
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    private func find<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let match = view as? T, view.accessibilityIdentifier == id { return match }
        return view.subviews.lazy.compactMap { find(id, in: $0, as: T.self) }.first
    }
    private func all(_ prefix: String, in view: UIView) -> [UIView] {
        ((view.accessibilityIdentifier ?? "").hasPrefix(prefix) ? [view] : []) + view.subviews.flatMap { all(prefix, in: $0) }
    }
    private func visible(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let item = current { if item.isHidden || item.alpha < 0.01 { return false }; current = item.superview }
        return true
    }
    /// Displayed feed ids in reading order.
    private func displayed(_ controller: LibraryViewController, rtl: Bool = false) -> [Int64] {
        all("subscriptionFeed-", in: controller.view).sorted {
            let a = $0.convert($0.bounds, to: nil), b = $1.convert($1.bounds, to: nil)
            return abs(a.minY - b.minY) > 0.5 ? a.minY < b.minY : (rtl ? a.minX > b.minX : a.minX < b.minX)
        }.compactMap { Int64(($0.accessibilityIdentifier ?? "").dropFirst("subscriptionFeed-".count)) }
    }
    /// Chip tags in reading order.
    private func chips(_ controller: LibraryViewController, rtl: Bool = false) -> [String] {
        all("subscriptionTag-", in: controller.view).sorted { rtl ? $0.frame.minX > $1.frame.minX : $0.frame.minX < $1.frame.minX }
            .map { String(($0.accessibilityIdentifier ?? "").dropFirst("subscriptionTag-".count)) }
    }
    private func tap(_ id: String, in view: UIView) throws {
        let control: UIControl = try #require(find(id, in: view), "\(id)")
        control.sendActions(for: .touchUpInside)
    }
    private func wait(_ stage: String, _ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while try await !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await predicate(), Comment(rawValue: stage))
    }
    private func presented<T: UIViewController>(_ controller: LibraryViewController, _ type: T.Type) async throws -> T {
        try await wait("\(T.self) presented") { controller.presentedViewController is T && controller.presentedViewController?.isBeingPresented == false }
        let result = try #require(controller.presentedViewController as? T); result.view.layoutIfNeeded(); return result
    }
    private func dismissed(_ controller: LibraryViewController) async throws {
        try await wait("dismissed") { controller.presentedViewController == nil }
    }
    /// A popup menu row: its button dismisses the menu, then runs the action.
    private func choose(_ id: String, _ controller: LibraryViewController) async throws {
        let menu = try await presented(controller, PopupMenuController.self)
        try tap(id, in: menu.view)
        try await wait("menu closed") { controller.presentedViewController !== menu }
    }
    private func texts(_ view: UIView) -> [String] { all("", in: view).compactMap { ($0 as? UILabel)?.text } }
    private func menuItems(_ menu: UIViewController) -> [String] {
        all("", in: menu.view).compactMap { ($0 as? UIButton)?.title(for: .normal) }
    }
    private func tags(_ store: FeedLibraryStore, _ id: Int64) async throws -> [String] {
        FeedTagOrder.preferences(try await store.feed(id: id)?.tags ?? []).values
    }

    struct Fixture {
        let folder: URL, store: FeedLibraryStore, prefs: SubscriptionDisplayPreferenceStore
        let speeds: PlaybackSpeedPreferenceStore, navigation: NavigationPreferenceStore
    }
    private func fixture(bottomNavigation: Bool = true) async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SubscriptionTags-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let restored = try AndroidDatabaseRestore.read(Self.fixtures.appendingPathComponent("tags-library.db"), staging: folder.appendingPathComponent("s"))
        let store = try FeedLibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        try await store.installRestoredLibrary(restored, carrying: try await store.restoreCarryOver())
        let navigation = try NavigationPreferenceStore(file: folder.appendingPathComponent("navigation.json"))
        var value = navigation.value
        value.defaultPage = "remember"; value.lastPage = NavigationDestination.subscriptions.rawValue; value.bottomNavigation = bottomNavigation
        try navigation.update(value)
        let prefs = try SubscriptionDisplayPreferenceStore(file: folder.appendingPathComponent("subscriptions.json"))
        var display = SubscriptionDisplayPreferences(); display.feedOrder = "1"; display.columns = 3
        try prefs.update(display)
        let speeds = try PlaybackSpeedPreferenceStore(file: folder.appendingPathComponent("speed.json"))
        try speeds.restore(feeds: restored.feedSpeeds, silence: restored.feedSilence)
        return Fixture(folder: folder, store: store, prefs: prefs, speeds: speeds, navigation: navigation)
    }
    private func mounted(_ fixture: Fixture, rtl: Bool = false, size: CGSize? = nil,
                         _ body: @MainActor (LibraryViewController) async throws -> Void) async throws {
        let controller = LibraryViewController(library: fixture.store, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: fixture.navigation, speedPreferences: fixture.speeds,
            mobileNetworkPreferences: nil, usage: nil)
        controller.subscriptionPreferences = fixture.prefs
        try await withViewTestWindow { host, _ in
            if rtl { host.traitOverrides.layoutDirection = .rightToLeft; controller.view.semanticContentAttribute = .forceRightToLeft }
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer {
                controller.presentedViewController?.dismiss(animated: false)
                controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent()
                host.traitOverrides.remove(UITraitLayoutDirection.self)
            }
            controller.view.frame = size.map { CGRect(origin: .zero, size: $0) } ?? host.view.bounds
            controller.view.layoutIfNeeded()
            await controller.reloadLibrary()?.value
            controller.view.layoutIfNeeded()
            try await wait("subscriptions shown") { !all("subscriptionFeed-", in: controller.view).isEmpty }
            try await body(controller)
        }
    }
    private func close(_ fixture: Fixture) async {
        try? await fixture.store.close(); try? FileManager.default.removeItem(at: fixture.folder)
    }
    private static var subscribedChips: [String] {
        (((oracle["views"] as! [String: Any])["subscribed"] as! [String: Any])["chips"] as! [[String: Any]]).map { $0["tag"] as! String }
    }

    // MARK: Chips

    @Test(arguments: [false, true]) func chipsRowListsTagsAndFiltersTheGrid(rightToLeft: Bool) async throws {
        let fixture = try await fixture(); defer { Task { await close(fixture) } }
        try await mounted(fixture, rtl: rightToLeft) { controller in
            #expect(chips(controller, rtl: rightToLeft) == Self.subscribedChips)
            let row: UIScrollView = try #require(find("subscriptionTags", in: controller.view))
            let labels = all("subscriptionTag-", in: row).compactMap(\.accessibilityLabel)
            #expect(labels.contains("All") && labels.contains("Untagged") && labels.contains("A very long tag nam…") && labels.contains("123456789012345678…"))
            // The row sits above the grid, chips never overlap, and All is selected.
            let firstCell = try #require(all("subscriptionFeed-", in: controller.view).map { $0.frame.minY }.min())
            #expect(row.frame.maxY <= firstCell + 0.5)
            let frames = all("subscriptionTag-", in: row).map(\.frame).sorted { $0.minX < $1.minX }
            for (a, b) in zip(frames, frames.dropFirst()) { #expect(a.maxX <= b.minX) }
            #expect((find("subscriptionTag-#root", in: row) as UIControl?)?.accessibilityTraits.contains(.selected) == true)
            #expect(displayed(controller, rtl: rightToLeft) == [1, 2, 4, 5, 3, 9, 10, 11, 12, 6])

            try tap("subscriptionTag-Tech", in: controller.view); controller.view.layoutIfNeeded()
            #expect(displayed(controller, rtl: rightToLeft) == [4, 5, 3, 6], "Tech members in the Subscriptions order")
            #expect(fixture.prefs.value.lastTag == "Tech")
            #expect((find("subscriptionTag-Tech", in: controller.view) as UIControl?)?.accessibilityTraits.contains(.selected) == true)
            try tap("subscriptionTag-#untagged", in: controller.view)
            #expect(displayed(controller, rtl: rightToLeft) == [1])
            try tap("subscriptionTag-Tech", in: controller.view)
        }
        // The selected chip is remembered on the next visit.
        try await mounted(fixture, rtl: rightToLeft) { controller in
            #expect(displayed(controller, rtl: rightToLeft) == [4, 5, 3, 6])
            // A filter that hides every member falls back to All ("news" under Kept updated).
            try tap("subscriptionTag-news", in: controller.view)
            #expect(displayed(controller) == [5])
            controller.updateSubscriptionDisplay { $0.subscriptionsFilter = "enabled_updates" }
            #expect(displayed(controller, rtl: rightToLeft) == [1, 2, 4, 3, 9, 10, 11, 12, 6])
            #expect(fixture.prefs.value.lastTag == FeedTags.root)
        }
    }

    @Test func archiveChipsComeFromArchivedFeedsAndStartAtAll() async throws {
        let fixture = try await fixture(); defer { Task { await close(fixture) } }
        try await mounted(fixture) { controller in
            controller.archiveTag = FeedTags.root; controller.push(.archive); controller.view.layoutIfNeeded()
            #expect(chips(controller) == [FeedTags.root, "News", "Old"])
            try tap("subscriptionTag-Old", in: controller.view)
            #expect(displayed(controller) == [7])
            #expect(fixture.prefs.value.lastTag == FeedTags.root, "the Archive does not store its chip")
            try tap("toolbarBack", in: controller.view); controller.view.layoutIfNeeded()
            try tap("subscriptionsMore", in: controller.view); try tap("subscriptionsArchive", in: controller.view)
            controller.view.layoutIfNeeded()
            #expect((find("subscriptionTag-#root", in: controller.view) as UIControl?)?.accessibilityTraits.contains(.selected) == true)
        }
    }

    // MARK: Chip menu: rename and delete

    @Test func chipMenuRenamesAndDeletesTheTagOnSubscribedFeedsOnly() async throws {
        let fixture = try await fixture(); defer { Task { await close(fixture) } }
        try await mounted(fixture) { controller in
            let news: UIControl = try #require(find("subscriptionTag-News", in: controller.view))
            let allChip: UIControl = try #require(find("subscriptionTag-#root", in: controller.view))
            #expect(allChip.accessibilityCustomActions?.isEmpty ?? true, "All has no menu")
            _ = news.accessibilityCustomActions?.first?.actionHandler?(news.accessibilityCustomActions!.first!)
            let menu = try await presented(controller, PopupMenuController.self)
            #expect(menuItems(menu) == ["Rename tag", "Delete tag"])
            #expect(all("", in: menu.view).compactMap { $0 as? UILabel }.contains { $0.text == "News" }, "header is the tag title")
            try await choose("renameTag", controller)
            let rename = try await presented(controller, SourceMessageController.self)
            let input: UITextView = try #require(find("tagRenameInput", in: rename.view))
            #expect(input.text == "News")
            input.text = "Headlines"; try tap("tagRenameReset", in: rename.view)
            #expect(input.text == "News", "Reset restores the original title without closing")
            input.text = "Headlines"; try tap("tagRenameConfirm", in: rename.view)
            try await wait("renamed") { try await tags(fixture.store, 2) == ["Headlines"] }
            #expect(Set(try await tags(fixture.store, 3)) == ["Tech", "Headlines"])
            let archived = try await tags(fixture.store, 7), preview = try await tags(fixture.store, 8)
            #expect(archived.contains("News") && preview == ["News"], "archived and preview feeds keep the tag")
            try await dismissed(controller); await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
            #expect(chips(controller).contains("Headlines") && !chips(controller).contains("News"))

            // Delete the last tag of a feed: the feed returns to the main list and Untagged; nothing is deleted.
            try tap("subscriptionTag-Solo", in: controller.view)
            let solo: UIControl = try #require(find("subscriptionTag-Solo", in: controller.view))
            _ = solo.accessibilityCustomActions?.first?.actionHandler?(solo.accessibilityCustomActions!.first!)
            try await choose("deleteTag", controller)
            let confirm = try await presented(controller, SourceMessageController.self)
            #expect(texts(confirm.view).contains("Please confirm that you want to delete the tag \"Solo\"."))
            try tap("tagDeleteConfirm", in: confirm.view)
            try await wait("deleted") { try await tags(fixture.store, 11) == [FeedTags.root] }
            try await dismissed(controller); await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
            #expect(fixture.prefs.value.lastTag == FeedTags.root, "delete resets the chip to All")
            #expect(!chips(controller).contains("Solo"))
            #expect(displayed(controller).contains(11))
            #expect(try await fixture.store.snapshot().feeds.count == 12)
        }
    }

    /// A blank name is not written (Android would create a blank chip).
    @Test func renameToBlankChangesNothing() async throws {
        let fixture = try await fixture(); defer { Task { await close(fixture) } }
        try await mounted(fixture) { controller in
            let before = try await fixture.store.snapshot().feeds
            controller.showTagMenu("Tech", state: .subscribed, anchor: controller.view)
            try await choose("renameTag", controller)
            let rename = try await presented(controller, SourceMessageController.self)
            let input: UITextView = try #require(find("tagRenameInput", in: rename.view))
            input.text = "   "; try tap("tagRenameConfirm", in: rename.view)
            try await dismissed(controller)
            try await Task.sleep(for: .milliseconds(200))
            #expect(try await fixture.store.snapshot().feeds == before)
        }
    }

    // MARK: Multi-select

    private func startSelection(_ controller: LibraryViewController, _ id: Int64) throws {
        let cell: UIControl = try #require(find("subscriptionFeed-\(id)", in: controller.view))
        let action = try #require(cell.accessibilityCustomActions?.first { $0.name == "Multi select" })
        #expect(action.actionHandler?(action) == true)
        controller.view.layoutIfNeeded()
    }
    private func title(_ controller: LibraryViewController) -> String? {
        (find("subscriptionSelectionCount", in: controller.view) as UILabel?)?.text
    }
    private func barActions(_ controller: LibraryViewController) -> [String] {
        all("feedBulk-", in: controller.subscriptionSelectionBar).sorted { $0.frame.minX < $1.frame.minX }
            .map { String(($0.accessibilityIdentifier ?? "").dropFirst("feedBulk-".count)) }
    }

    @Test(arguments: [false, true]) func selectionModeShowsCirclesActionsAndCount(rightToLeft: Bool) async throws {
        let fixture = try await fixture(); defer { Task { await close(fixture) } }
        try await mounted(fixture, rtl: rightToLeft) { controller in
            #expect(find("subscriptionsAdd", in: controller.view) as UIButton? != nil)
            try startSelection(controller, 1)
            #expect(title(controller) == "1/10 selected")
            #expect(find("subscriptionsAdd", in: controller.view) as UIButton? == nil, "FAB hidden")
            let row: UIScrollView = try #require(find("subscriptionTags", in: controller.view))
            #expect(!visible(row), "chips row invisible (keeps its space)")
            #expect(visible(controller.subscriptionSelectionBar))
            let expectedOne: [FeedBulkAction] = [.editTags, .share, .removeInbox, .removeArchive, .keepUpdated, .notifications, .autoDownload, .autoDelete, .playbackSpeed]
            #expect(Set(barActions(controller)) == Set(expectedOne.map(\.rawValue)))
            // Circles: every cell, checked on the selected one, at the top start.
            let cell: UIControl = try #require(find("subscriptionFeed-1", in: controller.view))
            let circle: SelectionCircleView = try #require(find("subscriptionSelectionCircle-1", in: cell))
            #expect(visible(circle) && circle.checked)
            #expect(rightToLeft ? circle.frame.midX > cell.bounds.midX : circle.frame.midX < cell.bounds.midX)
            #expect(cell.accessibilityTraits.contains(.selected))
            #expect((find("subscriptionSelectionCircle-3", in: controller.view) as SelectionCircleView?)?.checked == false)

            try tap("subscriptionFeed-3", in: controller.view)
            #expect(title(controller) == "2/10 selected")
            #expect(!barActions(controller).contains(FeedBulkAction.share.rawValue), "Share only for one feed")
            try tap("subscriptionFeed-6", in: controller.view)
            #expect(barActions(controller).contains(FeedBulkAction.removeInbox.rawValue))
            try tap("subscriptionFeed-1", in: controller.view)
            #expect(title(controller) == "2/10 selected")

            // Order 1, 2, 4, 5, 3, 9, 10, 11, 12, 6 with Gamma (3) and Zeta (6) selected: Select all above adds
            // everything before Gamma; Select all below adds nothing after Zeta, the last row.
            try tap("subscriptionSelectionMore", in: controller.view)
            let menu = try await presented(controller, PopupMenuController.self)
            #expect(menuItems(menu) == ["Select all", "Select all above", "Select all below"])
            try await choose("select_all_below", controller)
            #expect(title(controller) == "2/10 selected")
            try tap("subscriptionSelectionMore", in: controller.view)
            try await choose("select_all_above", controller)
            #expect(title(controller) == "6/10 selected")
            #expect((find("subscriptionSelectionCircle-9", in: controller.view) as SelectionCircleView?)?.checked == false)
            #expect((find("subscriptionSelectionCircle-2", in: controller.view) as SelectionCircleView?)?.checked == true)
            try tap("subscriptionSelectionMore", in: controller.view)
            try await choose("select_toggle", controller)
            #expect(title(controller) == "10/10 selected")
            try tap("subscriptionSelectionMore", in: controller.view)
            let again = try await presented(controller, PopupMenuController.self)
            #expect(menuItems(again).first == "Deselect all")
            try await choose("select_toggle", controller)
            #expect(title(controller) == "0/10 selected", "Deselect all keeps selection mode")
            try tap("feedBulk-editTags", in: controller.subscriptionSelectionBar)
            #expect(title(controller) == nil, "an action with nothing selected just ends selection")
            #expect(controller.presentedViewController == nil)
            #expect(find("subscriptionsAdd", in: controller.view) as UIButton? != nil)
        }
    }

    @Test func archiveSelectionOffersTagsShareAndRestore() async throws {
        let fixture = try await fixture(); defer { Task { await close(fixture) } }
        try await mounted(fixture) { controller in
            controller.push(.archive); controller.view.layoutIfNeeded()
            try startSelection(controller, 7)
            #expect(barActions(controller) == [FeedBulkAction.editTags, .share, .removeRestore].map(\.rawValue))
            try tap("endSubscriptionSelection", in: controller.view)
            #expect(title(controller) == nil)
        }
    }

    // MARK: Bulk dialogs and their stored effect

    @Test func bulkSwitchAndListDialogsChangeOnlyTheSelectedFeeds() async throws {
        let fixture = try await fixture(); defer { Task { await close(fixture) } }
        try await mounted(fixture) { controller in
            let before = try await fixture.store.snapshot().feeds
            try startSelection(controller, 1)
            try tap("subscriptionFeed-4", in: controller.view); try tap("subscriptionFeed-3", in: controller.view)
            try tap("feedBulk-keepUpdated", in: controller.subscriptionSelectionBar)
            let dialog = try await presented(controller, SourceMessageController.self)
            #expect(texts(dialog.view).contains("Kept updated"))
            let toggle: UIControl = try #require(find("bulkSwitch", in: dialog.view))
            #expect(toggle.accessibilityLabel == "Include this podcast when (auto-)refreshing all podcasts")
            #expect(toggle.accessibilityValue == "Off", "the switch starts off whatever the feeds hold")
            try tap("bulkKeepUpdatedConfirm", in: dialog.view)
            try await wait("keep updated saved") { try await fixture.store.feed(id: 3)?.keepUpdated == false }
            let after = try await fixture.store.snapshot().feeds
            for feed in after {
                let old = try #require(before.first { $0.id == feed.id })
                #expect(feed.keepUpdated == ([1, 3, 4].contains(feed.id) ? false : old.keepUpdated), "feed \(feed.id)")
            }
            try await wait("snackbar") { controller.visibleSnackbar?.accessibilityIdentifier == "subscriptionsUpdatedSnackbar" }
            #expect(all("", in: try #require(controller.visibleSnackbar)).contains { ($0 as? UILabel)?.text == "3 subscriptions updated." })
            try await dismissed(controller)
            #expect(title(controller) == "3/10 selected", "selection stays with several feeds")

            try tap("feedBulk-autoDownload", in: controller.subscriptionSelectionBar)
            let list = try await presented(controller, SourceMessageController.self)
            let rows = all("bulkAutoDownload-", in: list.view).sorted { $0.frame.minY < $1.frame.minY }
            #expect(rows.map(\.accessibilityLabel) == ["Global default", "Enabled", "Disabled"])
            #expect(rows.first?.accessibilityTraits.contains(.selected) == true)
            try tap("bulkAutoDownload-2", in: list.view); try tap("bulkAutoDownloadConfirm", in: list.view)
            try await wait("auto download saved") { try await fixture.store.feed(id: 4)?.autoDownload == .disabled }
            for feed in try await fixture.store.snapshot().feeds {
                let old = try #require(before.first { $0.id == feed.id })
                #expect(feed.autoDownload == ([1, 3, 4].contains(feed.id) ? .disabled : old.autoDownload), "feed \(feed.id)")
            }
            try await dismissed(controller)

            try tap("feedBulk-autoDelete", in: controller.subscriptionSelectionBar)
            let delete = try await presented(controller, SourceMessageController.self)
            #expect(all("bulkAutoDelete-", in: delete.view).sorted { $0.frame.minY < $1.frame.minY }.map(\.accessibilityLabel) == ["Global default", "Always", "Never"])
            try tap("bulkAutoDelete-1", in: delete.view); try tap("bulkAutoDeleteCancel", in: delete.view)
            try await dismissed(controller)
            #expect(try await fixture.store.snapshot().feeds.map(\.autoDelete) == before.map(\.autoDelete), "Cancel writes nothing")
        }
    }

    /// The bulk speed dialog saves speed and Skip silence for every selected feed.
    @Test func bulkSpeedSavesSpeedAndSkipSilence() async throws {
        let fixture = try await fixture(); defer { Task { await close(fixture) } }
        try await mounted(fixture) { controller in
            let before = fixture.speeds.value
            try startSelection(controller, 1)
            try tap("subscriptionFeed-4", in: controller.view)
            try tap("feedBulk-playbackSpeed", in: controller.subscriptionSelectionBar)
            let dialog = try await presented(controller, SourceMessageController.self)
            let value: UILabel = try #require(find("feedSpeedValue", in: dialog.view))
            #expect((value.text ?? "").isEmpty, "the value label stays blank until changed")
            for _ in 0..<7 { try tap("feedSpeedIncrease", in: dialog.view) }
            #expect(value.text == String(format: "%.2fx", 1.35))
            try tap("feedSpeedSkipSilence", in: dialog.view)
            try tap("bulkSpeedSave", in: dialog.view)
            try await wait("speed saved") { fixture.speeds.value.feeds[1] != nil }
            for id: Int64 in [1, 4] {
                #expect(abs((fixture.speeds.value.feeds[id] ?? 0) - 1.35) < 0.001)
                #expect(fixture.speeds.value.silence.feeds[id] == .aggressive)
            }
            for id: Int64 in [2, 3, 5] {
                #expect(fixture.speeds.value.feeds[id] == before.feeds[id])
                #expect(fixture.speeds.value.silence.feeds[id] == before.silence.feeds[id])
            }
        }
    }

    @Test func bulkTagsDialogShowsCommonTagsAndKeepsPartialOnes() async throws {
        let fixture = try await fixture(); defer { Task { await close(fixture) } }
        try await mounted(fixture) { controller in
            try startSelection(controller, 2); try tap("subscriptionFeed-3", in: controller.view)
            try tap("feedBulk-editTags", in: controller.subscriptionSelectionBar)
            let dialog = try await presented(controller, SourceMessageController.self)
            let body: FeedTagsBody = try #require(find("feedTagsBody", in: dialog.view))
            #expect(body.draft.displayed == ["News"], "only the common tag")
            let info: UILabel = try #require(find("feedTagsCommonInfo", in: dialog.view))
            #expect(visible(info) && info.text == "Only common tags from all selected subscriptions are shown. Other tags stay unaffected.")
            try tap("feedTagRemove-0", in: dialog.view)
            body.field.text = "Favourites"
            try tap("feedTagsSave", in: dialog.view)
            try await wait("tags saved") { try await tags(fixture.store, 2) == ["Favourites"] }
            #expect(Set(try await tags(fixture.store, 3)) == ["Tech", "Favourites"], "Tech was not common and stays")
        }
    }

    @Test func bulkRemoveFromInboxAndArchive() async throws {
        let fixture = try await fixture(); defer { Task { await close(fixture) } }
        try await mounted(fixture) { controller in
            try startSelection(controller, 1); try tap("subscriptionFeed-3", in: controller.view)
            try tap("feedBulk-removeInbox", in: controller.subscriptionSelectionBar)
            let confirm = try await presented(controller, SourceMessageController.self)
            try tap("removeFeedInboxConfirm", in: confirm.view)
            try await wait("inbox cleared") {
                let feeds = try await fixture.store.snapshot().feeds
                return feeds.filter { [1, 3].contains($0.id) }.flatMap(\.episodes).allSatisfy { $0.userState.playState != .new }
            }
            #expect(try await fixture.store.feed(id: 2)?.episodes.contains { $0.userState.playState == .new } == true, "other feeds untouched")
            try await dismissed(controller)

            try tap("feedBulk-removeArchive", in: controller.subscriptionSelectionBar)
            let sheet = try await presented(controller, RemoveFeedController.self)
            #expect(texts(sheet.view).contains("2 subscriptions"))
            try tap("archiveFeed", in: sheet.view)
            try await wait("archived") {
                let first = try await fixture.store.feed(id: 1)?.subscriptionState, second = try await fixture.store.feed(id: 3)?.subscriptionState
                return first == .archived && second == .archived
            }
            #expect(try await fixture.store.feed(id: 2)?.subscriptionState == .subscribed)
            try await dismissed(controller); controller.view.layoutIfNeeded()
            #expect(title(controller) == nil, "fewer feeds shown after the archive ends selection")
            #expect(!displayed(controller).contains(1))
        }
    }

    /// Tablet width: the chips row, the grid and the floating bar stay inside the window without overlap.
    @Test func wideWindowKeepsChipsGridAndBarVisible() async throws {
        let fixture = try await fixture(); defer { Task { await close(fixture) } }
        try await mounted(fixture, size: CGSize(width: 1032, height: 1376)) { controller in
            let row: UIScrollView = try #require(find("subscriptionTags", in: controller.view))
            #expect(row.contentSize.width <= row.bounds.width + 0.5, "every chip fits on a tablet")
            for chip in all("subscriptionTag-", in: row) { #expect(row.bounds.contains(chip.frame)) }
            try startSelection(controller, 1)
            let bar = controller.subscriptionSelectionBar
            #expect(controller.view.bounds.contains(bar.convert(bar.bounds, to: controller.view)))
            for button in all("feedBulk-", in: bar) { #expect(!button.frame.isEmpty) }
            let lastCell = try #require(all("subscriptionFeed-", in: controller.view).max { $0.frame.maxY < $1.frame.maxY })
            let content = try #require(lastCell.superview as? UIScrollView)
            #expect(content.contentSize.height - lastCell.frame.maxY >= bar.bounds.height - 16, "the last row can scroll clear of the bar")
        }
    }

    /// Home's "Check your classics" covers and Search results open the same feed menu.
    @Test func homeCoverOpensTheFeedMenu() async throws {
        let fixture = try await fixture(); defer { Task { await close(fixture) } }
        try await mounted(fixture) { controller in
            controller.select(.home); controller.view.layoutIfNeeded()
            controller.showSearchFeedMenu(7, anchor: controller.view, fraction: CGPoint(x: 0.5, y: 0.5))
            let menu = try await presented(controller, PopupMenuController.self)
            #expect(menuItems(menu) == ["Edit tags", "Unsubscribe / restore", "Share"], "archived feed")
            #expect(texts(menu.view).contains("Eta Archive"))
        }
    }

    // MARK: Drawer folders and menus

    @Test(arguments: [false, true]) func drawerFolderAndFeedMenus(rightToLeft: Bool) async throws {
        let fixture = try await fixture(bottomNavigation: false); defer { Task { await close(fixture) } }
        var display = fixture.prefs.value; display.openFolders = ["Tech"]; try fixture.prefs.update(display)
        try await mounted(fixture, rtl: rightToLeft) { controller in
            let drawer: NavigationDrawerView = try #require(find("navigationDrawer", in: controller.view))
            let folder: UIControl = try #require(find("drawer-folder-Tech", in: drawer))
            let member: UIControl = try #require(find("drawer-folder-feed-5", in: drawer))
            let root: UIControl = try #require(find("drawer-feed-1", in: drawer))
            // Folder members are indented on the leading side (half the 40-point thumbnail).
            let rootTitle = try #require(root.subviews.compactMap { $0 as? UILabel }.first { $0.text == "Alpha Daily" })
            let memberTitle = try #require(member.subviews.compactMap { $0 as? UILabel }.first { $0.text == "Epsilon Cast" })
            if rightToLeft { #expect(memberTitle.frame.maxX < rootTitle.frame.maxX - 10) } else { #expect(memberTitle.frame.minX > rootTitle.frame.minX + 10) }

            _ = folder.accessibilityCustomActions?.first?.actionHandler?(folder.accessibilityCustomActions!.first!)
            let menu = try await presented(controller, PopupMenuController.self)
            #expect(menuItems(menu) == ["Rename tag", "Delete tag"])
            try await choose("deleteTag", controller)
            let confirm = try await presented(controller, SourceMessageController.self)
            try tap("tagDeleteConfirm", in: confirm.view)
            // Every subscribed feed loses the tag, whatever the filter.
            try await wait("deleted") { try await tags(fixture.store, 6) == [FeedTags.root] }
            #expect(try await tags(fixture.store, 5) == ["news"])
            try await dismissed(controller)

            let feedRow: UIControl = try #require(find("drawer-feed-1", in: controller.view))
            _ = feedRow.accessibilityCustomActions?.first?.actionHandler?(feedRow.accessibilityCustomActions!.first!)
            let feedMenu = try await presented(controller, PopupMenuController.self)
            #expect(menuItems(feedMenu) == ["Remove all from inbox", "Edit tags", "Unsubscribe / archive", "Share"])
            #expect(all("", in: feedMenu.view).compactMap { $0 as? UILabel }.contains { $0.text == "Alpha Daily" })
        }
    }
}
