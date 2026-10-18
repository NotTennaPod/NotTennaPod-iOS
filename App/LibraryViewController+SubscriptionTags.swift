import UIKit
import NotTennaPodCore

/// Where a feed context menu (`nav_feed_context.xml`) was opened from.
enum FeedContextOrigin: Equatable { case search, home, drawer }

// Tag chips, tag rename/delete and the feed context menu.
extension LibraryViewController {
    // MARK: Tag chips

    /// The screen's selected chip: Subscriptions remembers it (`last_tag`), the Archive starts at All.
    func subscriptionTag(archived: Bool) -> String { archived ? archiveTag : subscriptionDisplay.lastTag }
    func setSubscriptionTag(_ tag: String, archived: Bool, rerender: Bool) {
        if archived {
            guard !FeedTags.equal(archiveTag, tag) else { return }
            archiveTag = tag
            if rerender { render() }
        } else {
            updateSubscriptionDisplay(rerender: rerender) { $0.lastTag = tag }
        }
    }

    /// The horizontal chips row at the top of the list (12-point side padding, 4 points between chips),
    /// scrolled so the selected chip is centred. It keeps its space but is hidden while selecting.
    func renderTagChips(_ chips: [SubscriptionTagChips.Chip], selected: String, archived: Bool, hidden: Bool) -> CGFloat {
        let row = UIScrollView()
        row.accessibilityIdentifier = "subscriptionTags"
        row.showsHorizontalScrollIndicator = false; row.contentInsetAdjustmentBehavior = .never
        row.alwaysBounceHorizontal = false
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        var views: [SubscriptionTagChip] = []
        for chip in chips {
            let title: String
            switch chip.tag {
            case _ where FeedTags.equal(chip.tag, FeedTags.root): title = Appearance.text("tag_all")
            case _ where FeedTags.equal(chip.tag, FeedTags.untagged): title = Appearance.text("tag_untagged")
            default: title = SubscriptionTagChips.label(chip.tag)
            }
            let view = SubscriptionTagChip(tag: chip.tag, title: title, checked: FeedTags.equal(chip.tag, selected))
            view.accessibilityIdentifier = "subscriptionTag-" + chip.tag
            view.addAction(UIAction { [weak self] _ in self?.setSubscriptionTag(chip.tag, archived: archived, rerender: true) }, for: .touchUpInside)
            if chip.isTag {
                view.enableTagMenu { [weak self] anchor in
                    self?.showTagMenu(chip.tag, state: archived ? .archived : .subscribed, anchor: anchor, fromChip: true)
                }
            }
            views.append(view); row.addSubview(view)
        }
        let height = views.map { $0.sizeThatFits(.zero).height }.max() ?? SubscriptionTagChip.rowHeight
        var x: CGFloat = 12
        var frames: [CGRect] = []
        for view in views {
            let width = view.sizeThatFits(.zero).width
            frames.append(CGRect(x: x, y: 0, width: width, height: height)); x += width + 4
        }
        let total = max(content.bounds.width, x - 4 + 12)
        for (view, frame) in zip(views, frames) {
            view.frame = rtl ? CGRect(x: total - frame.maxX, y: 0, width: frame.width, height: height) : frame
        }
        row.frame = CGRect(x: 0, y: 0, width: content.bounds.width, height: height)
        row.contentSize = CGSize(width: total, height: height)
        if let chosen = views.first(where: { FeedTags.equal($0.tagTitle, selected) }) {
            let maximum = max(0, total - row.bounds.width)
            row.contentOffset.x = min(maximum, max(0, chosen.frame.midX - row.bounds.width / 2))
        }
        // INVISIBLE, not GONE, during multi-select (SubscriptionFragment:505).
        row.alpha = hidden ? 0 : 1; row.isUserInteractionEnabled = !hidden; row.accessibilityElementsHidden = hidden
        content.addSubview(row)
        return height
    }

    // MARK: Rename / delete tag

    /// `nav_folder_context.xml` headed by the full tag title. A Subscriptions chip and a drawer folder act
    /// on every subscribed feed with the tag, an Archive chip on the archived ones.
    func showTagMenu(_ tag: String, state: FeedSubscriptionState, anchor: UIView, fromChip: Bool = false) {
        guard presentedViewController == nil else { return }
        let entries = [("renameTag", Appearance.text("rename_tag_label")), ("deleteTag", Appearance.text("delete_tag_label"))]
        present(PopupMenuController(title: tag, identifier: "tagContextMenu", anchor: anchor, anchorFraction: CGPoint(x: 0.5, y: 0.5),
            actions: entries) { [weak self] key in
                if key == "renameTag" { self?.showRenameTag(tag, state: state) }
                else { self?.confirmDeleteTag(tag, state: state, resetChip: fromChip) }
            }, animated: true)
    }

    private func showRenameTag(_ tag: String, state: FeedSubscriptionState) {
        guard let library else { return }
        let input = FeedURLEditInputView(value: tag)
        input.accessibilityIdentifier = "tagRenameBody"
        input.textView.accessibilityIdentifier = "tagRenameInput"
        input.textView.accessibilityLabel = Appearance.text("rename_tag_label")
        let dialog = SourceMessageController(title: Appearance.text("rename_tag_label"), message: "",
            positive: .init(title: Appearance.text("ok"), identifier: "tagRenameConfirm", perform: { [weak self] in
                let value = input.value
                Task { [weak self] in
                    do {
                        let members = FeedTagEdit.members(of: tag, in: try await library.readers().bulk.listFeedHeaders(), state: state)
                        try await library.renameTag(tag, to: value, feedIDs: members)
                        await self?.reloadLibrary(preservingEpisodeDetails: true)?.value
                    } catch { self?.showError(error) }
                }
            }), negative: .init(title: Appearance.text("cancel_label"), identifier: "tagRenameCancel"),
            neutral: .init(title: Appearance.text("reset"), identifier: "tagRenameReset", perform: {
                input.textView.text = tag; input.textViewDidChange(input.textView)
            }, dismisses: false), customBody: input)
        dialog.avoidsKeyboard = true
        input.onSizeChange = { [weak dialog] in dialog?.viewIfLoaded?.setNeedsLayout() }
        present(dialog, animated: true)
    }

    private func confirmDeleteTag(_ tag: String, state: FeedSubscriptionState, resetChip: Bool) {
        guard let library else { return }
        present(SourceMessageController(title: Appearance.text("delete_tag_label"),
            message: String(format: Appearance.text("delete_tag_confirmation"), tag),
            positive: .init(title: Appearance.text("confirm_label"), identifier: "tagDeleteConfirm", perform: { [weak self] in
                // TagMenuHandler selects All at once; the drawer leaves the chips alone.
                if resetChip { self?.setSubscriptionTag(FeedTags.root, archived: state == .archived, rerender: false) }
                Task { [weak self] in
                    do {
                        let members = FeedTagEdit.members(of: tag, in: try await library.readers().bulk.listFeedHeaders(), state: state)
                        try await library.deleteTag(tag, feedIDs: members)
                        await self?.reloadLibrary(preservingEpisodeDetails: true)?.value
                    } catch { self?.showError(error) }
                }
            }), negative: .init(title: Appearance.text("cancel_label"), identifier: "tagDeleteCancel")), animated: true)
    }

    // MARK: Feed context menu

    /// `nav_feed_context.xml` headed by the feed title: Remove all from inbox, Edit tags,
    /// Unsubscribe / archive or restore, Share, by feed state (`FeedMenuHandler.onPrepareMenu`).
    func showFeedContextMenu(_ feedID: Int64, origin: FeedContextOrigin, anchor: UIView, fraction: CGPoint) {
        guard let library else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let feed = try await library.listedFeedHeader(id: feedID), presentedViewController == nil else { return }
                switch (origin, path.last) {
                case (.search, .search?), (.home, .destination(.home)?), (.drawer, _): break
                default: return
                }
                present(PopupMenuController(feed: feed, anchor: anchor, anchorFraction: fraction) { [weak self] action in
                    guard let self else { return }
                    switch action {
                    case .removeInbox: confirmRemoveFeedInbox(feedID)
                    case .removeArchive, .removeRestore: presentFeedRemoval([feed], closesShownFeed: origin == .drawer)
                    case .share: shareFeed(feedID)
                    case .editTags: presentTagsDialog(for: [feed])
                    }
                }, animated: true)
            } catch { showError(error) }
        }
    }

    /// TagSettingsDialog for one feed or a multi-selection (in list order): only common tags are shown and
    /// changed; OK writes every edited feed in one transaction. No snackbar.
    func presentTagsDialog(for feeds: [LibraryFeed]) {
        guard let library, !feeds.isEmpty else { return }
        let ids = feeds.map(\.id)
        present(FeedTagsController.make(draft: FeedTags(selection: feeds.map(\.tags)), suggestions: FeedTags.suggestions(in: self.feeds),
            bottomNavigation: bottomNavigationEnabled) { [weak self] draft in
                Task { [weak self] in
                    do {
                        try await library.saveTags(draft, feedIDs: ids)
                        await self?.reloadLibrary(preservingEpisodeDetails: true)?.value
                    } catch { self?.showError(error) }
                }
            }, animated: true)
    }

    /// `RemoveFeedDialog` for one or several feeds. From the drawer (`RemoveFeedDialogClose`), unsubscribing
    /// the feed that is currently shown first opens the default page.
    func presentFeedRemoval(_ removed: [LibraryFeed], closesShownFeed: Bool = false) {
        guard let library, !removed.isEmpty else { return }
        let deletion = feedDeletion
        let dialog = RemoveFeedController(feeds: removed, remove: { [weak self] feed in
            guard let deletion else { throw FeedLibraryError.invalidMutation }
            if closesShownFeed, let self, rootNavigationTag == String(feed.id) {
                selectTag(navigationPreferences?.value.defaultPage ?? NavigationDestination.home.rawValue)
            }
            try await deletion.delete(feedID: feed.id).value
        }, archive: { feed, state in
            try await library.updatePreferences(feedID: feed.id) { $0.subscriptionState = state }
        }, finished: { [weak self] in
            await self?.reloadLibrary()?.value
        }, failed: { [weak self] in self?.showError($0) })
        present(dialog, animated: true)
    }
}
