import UIKit
import NotTennaPodCore

// Subscriptions and Archive (SubscriptionFragment).
extension LibraryViewController {
    // MARK: Subscriptions and Archive (SubscriptionFragment)

    var subscriptionDisplay: SubscriptionDisplayPreferences { subscriptionPreferences?.value ?? subscriptionFallback }
    func updateSubscriptionDisplay(rerender: Bool = true, _ change: (inout SubscriptionDisplayPreferences) -> Void) {
        var next = subscriptionDisplay; change(&next)
        guard next != subscriptionDisplay else { return }
        if let subscriptionPreferences {
            do { try subscriptionPreferences.update(next) } catch { showError(error); return }
        } else { subscriptionFallback = next }
        if rerender { render() }
    }
    /// `subscriptions_default_num_of_columns`: 5 when the window's smallest width is at least 600 points.
    private var subscriptionsDefaultColumns: Int {
        SubscriptionDisplayPreferences.defaultColumns(smallestWidth: Double(min(view.bounds.width, view.bounds.height)))
    }
    var globalAutoDownload: Bool { automaticDownloadPreferences?.value.global ?? false }

    /// Subscriptions, Archive or the drawer (`SubscriptionListQueries.load`) over the screens' library, ordered and
    /// filtered by the kept counts and newest dates: proportional to the podcasts, never to their episodes.
    func subscriptionList(_ preferences: SubscriptionDisplayPreferences, state: FeedSubscriptionState) -> SubscriptionListQueries.Result {
        mirror.subscriptionList(preferences: preferences, state: state, globalAutoDownload: globalAutoDownload,
                                latest: preferences.order == .mostRecentEpisode ? latestDates : FeedLatestDates())
    }

    func renderSubscriptions(heading: UILabel, archived: Bool) {
        let preferences = subscriptionDisplay
        // setColumnNumber writes the value on every creation, persisting the device-class default.
        let columns = preferences.columns.flatMap { (1...5).contains($0) ? $0 : nil } ?? subscriptionsDefaultColumns
        if preferences.columns == nil { updateSubscriptionDisplay(rerender: false) { $0.columns = columns } }
        let layout = toolbarLayout(hasOverflow: true, hasPrimaryAction: true)
        heading.frame = layout.title
        let search = Appearance.icon("ic_search", label: Appearance.text("search_label")) { [weak self] in
            if archived { self?.openArchiveSearch() } else { self?.openSearch() }
        }
        search.accessibilityIdentifier = "subscriptionsSearch"; search.frame = layout.primaryAction
        let more = Appearance.icon("dots_vertical", label: Appearance.text("overflow_more")) { [weak self] in
            self?.showSubscriptionsMenu(archived: archived, columns: columns)
        }
        more.accessibilityIdentifier = "subscriptionsMore"; more.frame = layout.overflow
        [search, more].forEach(toolbar.addSubview)

        let result = subscriptionList(preferences, state: archived ? .archived : .subscribed)
        // Tag chips; the selected chip shows its members, or falls back to All.
        let chips = SubscriptionTagChips.chips(feeds, state: archived ? .archived : .subscribed)
        subscriptionChips = chips
        let shown = SubscriptionTagChips.shown(selected: subscriptionTag(archived: archived), in: result)
        // Remember the fallback only once the library has loaded (an empty first render must not forget the chip).
        if !feeds.isEmpty, !FeedTags.equal(shown.tag, subscriptionTag(archived: archived)) {
            setSubscriptionTag(shown.tag, archived: archived, rerender: false)
        }
        // Selection is kept by feed id; a reload that shows fewer feeds ends it.
        if subscriptionSelection.active, subscriptionSelectionArchive == archived, shown.feeds.count < subscriptionSelectionIDs.count {
            subscriptionSelection.end()
        }
        subscriptionSelectionIDs = shown.feeds.map(\.id)
        let selecting = subscriptionSelection.active && subscriptionSelectionArchive == archived
        var y: CGFloat = 0
        if SubscriptionTagChips.rowVisible(chips) {
            y = renderTagChips(chips, selected: shown.tag, archived: archived, hidden: selecting)
        }
        // The Filtered bar reads the user's filter in both states; it opens the filter sheet.
        if preferences.filter.isEnabled {
            let bar = UIButton(type: .custom)
            bar.setTitle(Appearance.text("filtered_label"), for: .normal)
            bar.setTitleColor(Appearance.secondary, for: .normal); bar.titleLabel?.font = Appearance.font(14)
            bar.contentHorizontalAlignment = .leading
            let padding: CGFloat = path.count > 1 || !bottomNavigationEnabled ? 60 : 16
            bar.contentEdgeInsets = UIEdgeInsets(top: 4, left: padding, bottom: 4, right: padding)
            bar.accessibilityIdentifier = "subscriptionsFiltered"
            bar.addAction(UIAction { [weak self] _ in self?.showSubscriptionsFilter() }, for: .touchUpInside)
            let height = ceil(Appearance.font(14).lineHeight) + 8
            bar.frame = CGRect(x: 0, y: y, width: content.bounds.width, height: height)
            // INVISIBLE while selecting (SubscriptionFragment.updateFilterVisibility).
            bar.alpha = selecting ? 0 : 1; bar.isUserInteractionEnabled = !selecting; bar.accessibilityElementsHidden = selecting
            content.addSubview(bar); y += height
        }
        if shown.feeds.isEmpty {
            subscriptionsEmpty(archived: archived, top: y)
        } else {
            let gridLayout = SubscriptionsGridLayout(width: content.bounds.width, columns: columns, wideList: subscriptionsDefaultColumns == 5)
            let pixel = 1 / max(1, traitCollection.displayScale)
            let rowHeight = gridLayout.isList ? SubscriptionsGridLayout.listRowHeight : gridLayout.gridRowHeight(showTitle: preferences.showTitle, pixel: pixel)
            let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            // Tiles are built only near the visible area, like the episode lists, from the tiles as they are now (a patch
            // changes them, `patchSubscriptions`).
            let library = library, showTitle = preferences.showTitle, counters = result.counters
            subscriptionTiles = Dictionary(shown.feeds.map { ($0.id, ($0, counters[$0.id, default: 0])) }, uniquingKeysWith: { first, _ in first })
            subscriptionGridGeometry = SubscriptionGridGeometry(layout: gridLayout, rowHeight: rowHeight, top: y, rightToLeft: rtl,
                                                                selecting: selecting, archived: archived, filtered: preferences.filter.isEnabled,
                                                                tag: shown.tag)
            let grid = LazyContentList(top: y) { [weak self] id in
                guard let self, let (feed, counter) = subscriptionTiles[id] else { return UIView() }
                let chosen = selecting && subscriptionSelection.ids.contains(feed.id)
                let cell: UIControl
                if gridLayout.isList {
                    let row = SubscriptionListRow(feed: feed, counter: counter, library: library)
                    row.setSelection(mode: selecting, selected: chosen); cell = row
                } else {
                    let tile = SubscriptionGridCell(feed: feed, counter: counter, columns: columns, showTitle: showTitle, library: library)
                    tile.setSelection(mode: selecting, selected: chosen); cell = tile
                }
                cell.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                cell.addAction(UIAction { [weak self] _ in
                    guard let self else { return }
                    if subscriptionSelectionVisible { toggleSubscriptionSelection(feed.id) } else { push(.feed(feed.id)) }
                }, for: .touchUpInside)
                // A long press starts multi-select (no context menu on this grid).
                cell.addGestureRecognizer(ClosureLongPress { [weak self] in
                    guard let self, !subscriptionSelectionVisible else { return }
                    startSubscriptionSelection(feed.id, archived: archived)
                })
                if !selecting {
                    cell.accessibilityCustomActions = [UIAccessibilityCustomAction(name: Appearance.text("multi_select")) { [weak self] _ in
                        self?.startSubscriptionSelection(feed.id, archived: archived); return true
                    }]
                }
                return cell
            }
            grid.append(shown.feeds.map(\.id), frames: shown.feeds.indices.map {
                gridLayout.slot($0, rowHeight: rowHeight, top: y, rightToLeft: rtl)
            })
            subscriptionGrid = grid
            // fragment_subscriptions.xml: paddingBottom 88dp, clipToPadding false (last row clears the FAB).
            // While selecting, the last row clears the floating action bar instead.
            // Pixel-aligned so the end offset survives UIKit's pixel rounding across resizes.
            let scale = max(1, traitCollection.displayScale)
            let bottom = selecting ? max(88, subscriptionSelectionBar.preferredHeight) : 88
            content.contentSize.height = max(content.bounds.height, ceil((y + gridLayout.height(count: shown.feeds.count, rowHeight: rowHeight) + bottom) * scale) / scale)
        }
        // The FAB is hidden while selecting.
        guard !archived, !selecting else { return }
        let add = Appearance.icon("ic_add", label: Appearance.text("add_feed_label")) { [weak self] in self?.select(.addPodcast) }
        add.accessibilityIdentifier = "subscriptionsAdd"
        add.translatesAutoresizingMaskIntoConstraints = false
        add.backgroundColor = Appearance.selected
        add.layer.cornerRadius = 16
        content.addSubview(add)
        subscriptionGrid?.ceiling = { [weak add] in add }
        let end = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? add.leftAnchor.constraint(equalTo: content.frameLayoutGuide.leftAnchor, constant: 16)
            : add.rightAnchor.constraint(equalTo: content.frameLayoutGuide.rightAnchor, constant: -16)
        NSLayoutConstraint.activate([
            end,
            add.bottomAnchor.constraint(equalTo: content.frameLayoutGuide.bottomAnchor, constant: -16),
            add.widthAnchor.constraint(equalToConstant: 56),
            add.heightAnchor.constraint(equalToConstant: 56)
        ])
    }

    /// EmptyViewHandler: `ic_subscriptions` 32 points, title 16, message 14, centred with 40-point sides.
    private func subscriptionsEmpty(archived: Bool, top: CGFloat) {
        let icon = UIImageView(image: UIImage(named: "ic_subscriptions")); icon.tintColor = Appearance.foreground
        let title = Appearance.label(Appearance.text(archived ? "no_archive_head_label" : "no_subscriptions_head_label"), size: 16)
        let message = Appearance.label(Appearance.text(archived ? "no_archive_label" : "no_subscriptions_label"), size: 14)
        message.textColor = Appearance.secondary
        title.textAlignment = .center; message.textAlignment = .center
        title.accessibilityIdentifier = "subscriptionsEmptyTitle"
        let width = max(0, content.bounds.width - 80)
        let titleHeight = title.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height + 3
        let messageHeight = message.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height + 3
        let y = max(top, (content.bounds.height - 32 - titleHeight - messageHeight) / 2)
        icon.frame = CGRect(x: (content.bounds.width - 32) / 2, y: y, width: 32, height: 32)
        title.frame = CGRect(x: 40, y: icon.frame.maxY, width: width, height: titleHeight)
        message.frame = CGRect(x: 40, y: title.frame.maxY, width: width, height: messageHeight)
        [icon, title, message].forEach(content.addSubview)
    }

    /// `subscriptions.xml` overflow; the archive keeps Sort, Number of columns and Show titles.
    private func showSubscriptionsMenu(archived: Bool, columns: Int) {
        // Runtime order (Android 3.12.1 capture): Refresh has menuCategory="container" and is listed last.
        var entries: [(String, String, () -> Void)] = []
        if !archived {
            entries.append((Appearance.text("filter"), "subscriptionsFilter", { [weak self] in self?.showSubscriptionsFilter() }))
        }
        entries.append((Appearance.text("sort"), "subscriptionsSort", { [weak self] in self?.showSubscriptionsSort() }))
        if !archived {
            entries.append((Appearance.text("pref_nav_drawer_feed_counter_title"), "subscriptionsCounter", { [weak self] in self?.showSubscriptionsCounter() }))
        }
        entries.append((Appearance.text("subscription_num_columns"), "subscriptionsColumns", { [weak self] in self?.showSubscriptionColumns(columns) }))
        // Show titles: checkable, visible only in grid mode.
        if columns > 1 {
            entries.append((Appearance.text("pref_show_subscription_title"), "subscriptionsShowTitles", { [weak self] in
                self?.updateSubscriptionDisplay { $0.showTitle.toggle() }
            }))
        }
        if !archived {
            entries.append((Appearance.text("archive_feed_label_noun"), "subscriptionsArchive", { [weak self] in
                self?.archiveTag = FeedTags.root; self?.push(.archive)
            }))
            entries.append((Appearance.text("refresh_label"), "subscriptionsRefresh", { [weak self] in self?.requestFeedRefresh(nil) }))
        }
        showFeedMenu(entries, identifier: "subscriptionsMenu",
                     accessories: ["subscriptionsColumns": .submenu, "subscriptionsShowTitles": .checkbox(subscriptionDisplay.showTitle)])
    }
    /// Number of columns submenu: List, 2–5 (locale digits), single choice.
    private func showSubscriptionColumns(_ columns: Int) {
        let formatter = NumberFormatter()
        let entries: [(String, String, () -> Void)] = (1...5).map { value in
            (value == 1 ? Appearance.text("subscription_display_list") : formatter.string(from: NSNumber(value: value)) ?? "\(value)",
             "subscriptionsColumns-\(value)", { [weak self] in self?.updateSubscriptionDisplay { $0.columns = value } })
        }
        showFeedMenu(entries, identifier: "subscriptionsColumnsMenu",
                     accessories: Dictionary(uniqueKeysWithValues: (1...5).map { ("subscriptionsColumns-\($0)", PopupMenuAccessory.Kind.radio($0 == columns)) }),
                     header: Appearance.text("subscription_num_columns"))
    }
    private func showSubscriptionsSort() {
        let choices = FeedOrder.dialogOrder
        present(SourceSingleChoiceController(title: Appearance.text("sort"), identifier: "subscriptionsSortDialog",
            choices: choices.map { ($0.stored, Appearance.text($0.titleKey)) },
            selectedIndex: choices.firstIndex(of: subscriptionDisplay.order)) { [weak self] index in
                self?.updateSubscriptionDisplay { $0.feedOrder = choices[index].stored }
            }, animated: true)
    }
    private func showSubscriptionsCounter() {
        let choices = FeedCounter.dialogOrder
        present(SourceSingleChoiceController(title: Appearance.text("pref_nav_drawer_feed_counter_title"), identifier: "subscriptionsCounterDialog",
            choices: choices.map { ($0.stored, Appearance.text($0.titleKey)) },
            selectedIndex: choices.firstIndex(of: subscriptionDisplay.counter)) { [weak self] index in
                self?.updateSubscriptionDisplay { $0.feedCounter = choices[index].stored }
            }, animated: true)
    }
    func showSubscriptionsFilter() {
        guard presentedViewController == nil else { return }
        let editor = SubscriptionsFilterEditor(stored: subscriptionDisplay.subscriptionsFilter) { [weak self] value in
            self?.updateSubscriptionDisplay { $0.subscriptionsFilter = value }
        }
        present(FeedFilterController(subscriptions: editor), animated: true)
    }
    private func openArchiveSearch() {
        guard let library else { return }
        let session = LibrarySearchSession(archivedTitle: Appearance.text("archive_feed_label_noun")) { [weak self] query, id, archived in
            try await Self.searchLibrary(self, store: library, query: query, feedID: id, archived: archived)
        }
        openSearch(session: session)
    }
    /// Toolbar long-press: SubscriptionFragment scrolls to the top.
    @objc func toolbarHeld(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, !(toolbar.hitTest(gesture.location(in: toolbar), with: nil) is UIControl) else { return }
        switch path.last {
        case .destination(.subscriptions), .destination(.subscriptionList), .archive:
            content.setContentOffset(CGPoint(x: 0, y: -content.adjustedContentInset.top), animated: true)
        default: break
        }
    }
}
