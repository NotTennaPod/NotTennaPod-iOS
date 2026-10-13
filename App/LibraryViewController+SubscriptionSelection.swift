import UIKit
import NotTennaPodCore

// Multi-select on Subscriptions/Archive and the bulk actions of its floating bar.
extension LibraryViewController {
    /// nil off the Subscriptions/Archive screens, else whether it is the Archive.
    var subscriptionScreenArchived: Bool? {
        switch path.last {
        case .destination(.subscriptions)?, .destination(.subscriptionList)?: false
        case .archive?: true
        default: nil
        }
    }
    var subscriptionSelectionVisible: Bool {
        subscriptionSelection.active && subscriptionScreenArchived == subscriptionSelectionArchive
    }

    func setUpSubscriptionSelection() {
        subscriptionSelectionBar.accessibilityIdentifier = "subscriptionSelectionActions"
        surface.addSubview(subscriptionSelectionBar); subscriptionSelectionBar.isHidden = true
        subscriptionSelectionBar.performFeedAction = { [weak self] action in self?.performSubscriptionAction(action) }
    }

    /// A long press on a cell starts selection with that feed (`SubscriptionsRecyclerAdapter`).
    func startSubscriptionSelection(_ feedID: Int64, archived: Bool) {
        guard !subscriptionSelectionVisible else { return }
        subscriptionSelectionArchive = archived
        subscriptionSelection.start(feedID)
        subscriptionSelectionBar.resetScroll()
        render()
        UIAccessibility.post(notification: .announcement, argument: Appearance.text("multi_select_started_talkback"))
    }
    /// While selecting, a tap toggles; deselecting the last feed ends selection.
    func toggleSubscriptionSelection(_ feedID: Int64) {
        subscriptionSelection.toggle(feedID); render()
    }
    func endSubscriptionSelection() {
        guard subscriptionSelection.active else { return }
        subscriptionSelection.end(); render()
    }

    /// After every render: selection ends when its screen is left; otherwise the action-mode toolbar and
    /// the floating bar are shown for the current selection.
    func updateSubscriptionSelection() {
        if subscriptionSelection.active, subscriptionScreenArchived != subscriptionSelectionArchive { subscriptionSelection.end() }
        toolbar.subviews.filter { $0.accessibilityIdentifier == "subscriptionSelectionToolbar" }.forEach { $0.removeFromSuperview() }
        guard subscriptionSelectionVisible else { subscriptionSelectionBar.isHidden = true; return }
        let selected = subscriptionSelection.selected(displayed: subscriptionSelectionIDs)
        // FeedMenuHandler.onPrepareMenu returns early for an empty selection: the items stay as they were.
        if !selected.isEmpty {
            subscriptionSelectionActions = FeedBulkAction.visible(selected.compactMap { id in feeds.first { $0.id == id } },
                                                                  archiveScreen: subscriptionSelectionArchive)
        }
        subscriptionSelectionBar.update(feedActions: subscriptionSelectionActions)

        let bar = UIView(frame: toolbar.bounds); bar.backgroundColor = Appearance.navigation
        bar.accessibilityIdentifier = "subscriptionSelectionToolbar"
        let layout = toolbarLayout(hasOverflow: true, forceNavigation: true)
        let close = Appearance.icon("abc_ic_ab_back_material", label: Appearance.text("close_label")) { [weak self] in self?.endSubscriptionSelection() }
        close.configuration?.image = UIImage(named: "abc_ic_ab_back_material")?.imageFlippedForRightToLeftLayoutDirection()
        close.accessibilityIdentifier = "endSubscriptionSelection"; close.frame = layout.navigation
        let title = Appearance.label(String(format: Appearance.text("num_selected_label"), subscriptionSelection.ids.count,
                                            subscriptionSelectionIDs.count), size: 20)
        title.numberOfLines = 1; title.frame = layout.title; title.accessibilityIdentifier = "subscriptionSelectionCount"
        let more = Appearance.icon("dots_vertical", label: Appearance.text("overflow_more")) { [weak self, weak bar] in
            guard let self, let bar else { return }
            // The label always reflects the current state (Android can show a stale "Select all").
            let all = subscriptionSelection.ids.count == subscriptionSelectionIDs.count
            let entries = [("select_toggle", Appearance.text(all ? "deselect_all_label" : "select_all_label")),
                           ("select_all_above", Appearance.text("select_all_above")),
                           ("select_all_below", Appearance.text("select_all_below"))]
            present(PopupMenuController(title: "", identifier: "subscriptionSelectionOptions", anchor: bar,
                anchorFraction: CGPoint(x: bar.effectiveUserInterfaceLayoutDirection == .rightToLeft ? 0 : 1, y: 1),
                actions: entries) { [weak self] key in self?.changeSubscriptionSelection(key) }, animated: true)
        }
        more.accessibilityIdentifier = "subscriptionSelectionMore"; more.frame = layout.overflow
        [close, title, more].forEach(bar.addSubview); toolbar.addSubview(bar); toolbar.accessibilityElements = [bar]

        let height = min(subscriptionSelectionBar.preferredHeight, max(0, content.bounds.height - 48))
        subscriptionSelectionBar.frame = CGRect(x: content.frame.minX, y: content.frame.maxY - height, width: content.bounds.width, height: height)
        subscriptionSelectionBar.isHidden = false
        surface.bringSubviewToFront(subscriptionSelectionBar)
    }

    private func changeSubscriptionSelection(_ key: String) {
        switch key {
        case "select_toggle": subscriptionSelection.toggleAll(displayed: subscriptionSelectionIDs)
        case "select_all_above": subscriptionSelection.above(displayed: subscriptionSelectionIDs)
        case "select_all_below": subscriptionSelection.below(displayed: subscriptionSelectionIDs)
        default: return
        }
        render()
    }

    // MARK: Bulk actions

    /// The handler opens its dialog (or shares); with one or no feed selected, selection ends at once,
    /// before the dialog is answered. With two or more it stays.
    func performSubscriptionAction(_ action: FeedBulkAction) {
        let selected = subscriptionSelection.selected(displayed: subscriptionSelectionIDs).compactMap { id in feeds.first { $0.id == id } }
        if selected.count <= 1 { endSubscriptionSelection() }
        guard !selected.isEmpty, presentedViewController == nil else { return }
        let ids = selected.map(\.id)
        switch action {
        case .editTags: presentTagsDialog(for: selected)
        case .share: if !selected[0].source.isLocalFeedSource { shareFeed(selected[0].id) }
        case .removeInbox: confirmRemoveFeedsFromInbox(ids)
        case .removeArchive, .removeRestore: presentFeedRemoval(selected)
        case .keepUpdated:
            presentBulkSwitch(title: "kept_updated", text: "keep_updated_summary", identifier: "bulkKeepUpdated") { [weak self] on in
                self?.saveBulk(.keepUpdated(on), ids: ids)
            }
        case .notifications:
            presentBulkSwitch(title: "episode_notification", text: "episode_notification_summary", identifier: "bulkNotifications") { [weak self] on in
                // Enabling asks for notification permission, like the per-feed setting; Android saves without asking.
                guard on else { self?.saveBulk(.notifications(false), ids: ids); return }
                Task { [weak self] in
                    let authorization = NativeNotificationAuthorization()
                    if await !authorization.isAuthorized() { _ = try? await authorization.request() }
                    self?.saveBulk(.notifications(true), ids: ids)
                }
            }
        case .autoDownload:
            let choices = FeedBulkPreference.autoDownloadChoices
            presentBulkChoice(title: "auto_download_label", rows: choices.map(\.titleKey), identifier: "bulkAutoDownload") { [weak self] index in
                self?.saveBulk(.autoDownload(choices[index]), ids: ids)
            }
        case .autoDelete:
            let choices = FeedBulkPreference.autoDeleteChoices
            presentBulkChoice(title: "pref_auto_delete_playback_title", rows: choices.map(\.titleKey), identifier: "bulkAutoDelete") { [weak self] index in
                self?.saveBulk(.autoDelete(choices[index]), ids: ids)
            }
        case .playbackSpeed: presentBulkSpeed(ids)
        }
    }

    private func confirmRemoveFeedsFromInbox(_ ids: [Int64]) {
        guard let library else { return }
        present(SourceMessageController(title: Appearance.text("remove_all_inbox_label"), message: Appearance.text("remove_all_inbox_confirmation_msg"),
            positive: .init(title: Appearance.text("confirm_label"), identifier: "removeFeedInboxConfirm", perform: { [weak self] in
                Task { [weak self] in
                    do { try await library.removeFeedsFromInbox(feedIDs: ids); await self?.reloadLibrary(preservingEpisodeDetails: true)?.value }
                    catch { self?.showError(error) }
                }
            }), negative: .init(title: Appearance.text("cancel_label"), identifier: "removeFeedInboxCancel")), animated: true)
    }

    /// `PreferenceSwitchDialog`: title, a switch that starts off whatever the feeds hold, Cancel/Confirm.
    private func presentBulkSwitch(title: String, text: String, identifier: String, save: @escaping (Bool) -> Void) {
        let body = BulkSwitchBody(text: Appearance.text(text))
        present(SourceMessageController(title: Appearance.text(title), message: "",
            positive: .init(title: Appearance.text("confirm_label"), identifier: identifier + "Confirm", perform: { save(body.isOn) }),
            negative: .init(title: Appearance.text("cancel_label"), identifier: identifier + "Cancel"), customBody: body), animated: true)
    }

    /// `PreferenceListDialog`: single choice starting at Global default, Cancel/Confirm.
    private func presentBulkChoice(title: String, rows: [String], identifier: String, save: @escaping (Int) -> Void) {
        let body = BulkChoiceBody(titles: rows.map(Appearance.text), identifier: identifier)
        present(SourceMessageController(title: Appearance.text(title), message: "",
            positive: .init(title: Appearance.text("confirm_label"), identifier: identifier + "Confirm", perform: { save(body.selected) }),
            negative: .init(title: Appearance.text("cancel_label"), identifier: identifier + "Cancel"), customBody: body), animated: true)
    }

    /// The feed speed dialog starting at 1.00 with Global and Skip silence unchecked. "Skip silence in audio"
    /// is saved for every selected feed exactly like the per-feed dialog saves it (Global → global,
    /// checked → aggressive, unchecked → off); Android ignores it.
    private func presentBulkSpeed(_ ids: [Int64]) {
        guard let speedPreferences else { return }
        let body = FeedPlaybackSpeedBody(draft: .init(speed: 1, skipSilence: .off))
        present(SourceMessageController(title: Appearance.text("playback_speed"), message: "",
            positive: .init(title: Appearance.text("ok"), identifier: "bulkSpeedSave", perform: { [weak self] in
                do {
                    try speedPreferences.setFeeds(ids, speed: body.draft.savedSpeed, skipSilence: body.draft.savedSilence)
                    self?.showSubscriptionsUpdated(ids.count)
                } catch { self?.showError(error) }
            }), negative: .init(title: Appearance.text("cancel_label"), identifier: "bulkSpeedCancel"), customBody: body), animated: true)
    }

    private func saveBulk(_ preference: FeedBulkPreference, ids: [Int64]) {
        guard let library else { return }
        Task { [weak self] in
            do {
                try await library.applyBulk(preference, feedIDs: ids)
                await self?.reloadLibrary(preservingEpisodeDetails: true)?.value
                self?.showSubscriptionsUpdated(ids.count)
            } catch { self?.showError(error) }
        }
    }

    /// "%d subscription(s) updated." (MessageEvent snackbar).
    private func showSubscriptionsUpdated(_ count: Int) {
        let text = Appearance.plural("updated_feeds_batch_label", count)
        if showSnackbar(text) { visibleSnackbar?.accessibilityIdentifier = "subscriptionsUpdatedSnackbar" }
    }
}
