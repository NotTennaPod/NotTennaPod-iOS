import UIKit
import NotTennaPodCore
import OSLog

// Feed screen, feed information, feed menus, pull refresh and episode details.
extension LibraryViewController {
    private func refreshStalePreview(_ feed: LibraryFeed) {
        guard feed.needsPreviewRefresh(at: Date()), let manualRefresh else { return }
        let attempt = feed.lastRefreshAttempt ?? Date(timeIntervalSince1970: 0)
        // Rendering/resizing the same snapshot must not replace its accepted job.
        guard requestedPreviewAttempts[feed.id] != attempt else { return }
        requestedPreviewAttempts[feed.id] = attempt
        // Source runOnce(feed, true): the Boolean means nextPage, not admission.
        // The owner retains this work if the preview closes or the network drops.
        let accepted = manualRefresh.runOnce(feedID: feed.id,
            isLocalFeed: feed.source.isLocalFeedSource, nextPage: true)
        Task { [weak self] in
            do { _ = try await accepted.value }
            catch {
                self?.requestedPreviewAttempts[feed.id] = nil
                self?.showError(error)
            }
        }
    }

    func feedScreen(_ feed: LibraryFeed) {
        refreshStalePreview(feed)
        let displayed = feed.filteredDisplayEpisodes(queuedIDs: Set(queuedEpisodes.map(\.id)),
            globalSort: navigationPreferences?.value.defaultFeedSortOrder ?? .dateNewest)
        feedSelectionIDs = displayed.map(\.id)
        feedPageFooter.onLoad = { [weak self] in self?.requestFeedPage(feed.id, reset: false) }
        if library != nil && feed.subscriptionState != .notSubscribed {
            let search = Appearance.icon("ic_search", label: Appearance.text("search_label")) { [weak self] in self?.openSearch(feed) }
            search.accessibilityIdentifier = "feedSearch"
            search.frame = toolbarLayout(hasOverflow: true, hasPrimaryAction: true).primaryAction
            toolbar.addSubview(search)
        }
        if library != nil {
            let menu = Appearance.icon("dots_vertical", label: Appearance.text("overflow_more")) { [weak self] in self?.showFeedRemovalMenu(feed) }
            menu.accessibilityIdentifier = "feedListMore"; menu.frame = toolbarLayout(hasOverflow: true).overflow
            toolbar.addSubview(menu)
        }

        let header = SubscribedFeedHeaderView(feed: feed, library: library,
            hasFilter: feed.episodeFilter.isActive, keepUpdated: feed.keepUpdated,
            hasInteracted: feed.episodes.contains { episode in episode.userState.isFavorite || episode.userState.isDownloaded || episode.userState.playState == .played || queuedEpisodes.contains(where: { $0.id == episode.id }) })
        header.accessibilityIdentifier = "subscribedFeedHeader"
        header.onAction = { [weak self] action in self?.feedHeaderAction(action, feedID: feed.id) }
        let appBar = FeedAppBarView(header: header, information: false)
        appBar.toolbarHeight = toolbar.bounds.height
        appBar.fullHeaderHeight = header.sizeThatFits(content.bounds.size).height
        episodes(displayed.map { (feed, $0) }, top: appBar.fullHeaderHeight, paged: true)
        content.addSubview(appBar); feedAppBar = appBar
    }

    private func feedHeaderAction(_ action: SubscribedFeedHeaderView.Action, feedID: Int64) {
        guard let feed = feeds.first(where: { $0.id == feedID }) else { return }
        switch action {
        case .subscribe:
            guard !subscriptionPending, let subscribe = onPreviewSubscribe else { return }
            subscriptionPending = true
            Task { [weak self] in
                defer { self?.subscriptionPending = false }
                do { try await subscribe(feedID) } catch { self?.showError(error) }
            }
        case .restore:
            guard feed.subscriptionState == .archived, let library else { return }
            Task { [weak self] in
                do {
                    try await library.updatePreferences(feedID: feedID) { $0.subscriptionState = .subscribed }
                    await self?.reloadLibrary()?.value
                } catch { self?.showError(error) }
            }
        case .information: push(.feedInformation(feedID))
        case .settings: push(.feedSettings(feedID))
        case .copyTitle(let text), .copyAuthor(let text): UIPasteboard.general.string = text
        case .filter:
            guard let library else { return }
            let editor = FeedFilterEditor(feed: feed, store: library)
            present(FeedFilterController(editor: editor, onSaved: { [weak self] _ in
                self?.reloadLibrary(preservingEpisodeDetails: true)
            }, onFailure: { [weak self] in self?.showError($0) }), animated: true)
        case .failure:
            guard let library else { return }
            Task { [weak self] in
                do {
                    let log = try await library.logs(feedID: feedID).first
                    let current = try await library.feed(id: feedID)
                    guard let self, case .feed(let visibleID) = path.last, visibleID == feedID else { return }
                    if let log, !log.kind.isSuccessful {
                        messages.present(FeedLogDetailsDialog.make(FeedLogDetails(log: log, feed: current, text: Appearance.text)))
                    } else { showDownloadLog() }
                } catch { self?.showError(error) }
            }
        }
    }

    func informationScreen(_ feed: LibraryFeed) {
        do {
            if feedInformation?.feedID != feed.id {
                feedInformation = try FeedInformationScreenView(feed: feed, library: library, readStatistics: statisticsRead())
            } else { try feedInformation?.update(feed) }
            guard let information = feedInformation else { return }
            information.onSubscribe = { [weak self] in self?.feedHeaderAction(.subscribe, feedID: feed.id) }
            information.onAction = { [weak self] action in
                guard let self else { return }
                switch action {
                case .allPodcasts: push(.destination(.statistics))
                case .detailedStatistics: showFeedStatistics(feedID: feed.id)
                case .fundingURL(let url): openWebsite(url)
                }
            }
            information.onSizeChange = { [weak self] in self?.layoutInformation() }
            content.addSubview(information)
            feedAppBar = information.appBar
            information.appBar.toolbarHeight = toolbar.bounds.height
            layoutInformation()
            let state = try FeedInformationScreenView.information(feed)
            let overflow = state.showsReconnect || (state.showsEditURL && manualRefresh != nil)
            let layout = toolbarLayout(hasOverflow: overflow, hasPrimaryAction: state.showsShare || state.showsWebsite)
            var actions: [(String, String, String, () -> Void)] = []
            if state.showsShare {
                actions.append(("ic_share", "share_label", "feedShare", { [weak self] in self?.shareFeed(feed.id) }))
            }
            if state.showsWebsite, let url = feed.metadata.link {
                actions.append(("ic_web", "visit_website_label", "feedWebsite", { [weak self] in self?.openWebsite(url) }))
            }
            for (index, action) in actions.enumerated() {
                let button = Appearance.icon(action.0, label: Appearance.text(action.1), action: action.3)
                button.accessibilityIdentifier = action.2
                let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
                button.frame = layout.primaryAction.offsetBy(dx: (rtl ? 1 : -1) * CGFloat(index) * 48, dy: 0)
                toolbar.addSubview(button)
            }
            if overflow {
                let more = Appearance.icon("dots_vertical", label: Appearance.text("overflow_more")) { [weak self] in
                    self?.showInformationMenu(feed)
                }
                more.accessibilityIdentifier = "feedInformationMore"; more.frame = layout.overflow; toolbar.addSubview(more)
            }
        } catch { showError(error) }
    }

    private func layoutInformation() {
        guard case .feedInformation(let id) = path.last, let information = feedInformation, information.feedID == id else { return }
        information.frame = CGRect(origin: .zero, size: information.sizeThatFits(content.bounds.size))
        information.layoutIfNeeded()
        content.contentSize = CGSize(width: content.bounds.width, height: max(content.bounds.height + information.appBar.fullHeaderHeight, information.frame.height))
        updateFeedAppBar(animated: false)
    }

    private func showFeedStatistics(feedID: Int64) {
        guard let feed = feeds.first(where: { $0.id == feedID }) else { return }
        let dialog = FeedStatisticsDialog.make(feedID: feed.id, title: feed.title, read: statisticsRead()) { [weak self] in
            self?.drawerAction(.feed(feedID))
        }
        present(dialog, animated: true)
    }

    func shareFeed(_ feedID: Int64, anchorID: String = "feedShare") {
        guard let feed = feeds.first(where: { $0.id == feedID }), !feed.source.isLocalFeedSource else { return }
        let sheet = UIActivityViewController(activityItems: [FeedShareText.make(title: feed.title ?? "", source: feed.source)], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            let anchor = toolbar.subviews.first { $0.accessibilityIdentifier == anchorID } ?? toolbar
            popover.sourceView = anchor; popover.sourceRect = anchor.bounds
        }
        present(sheet, animated: true)
    }

    /// Search results and Home's "Check your classics" covers open the feed context menu.
    func showSearchFeedMenu(_ feedID: Int64, anchor: UIView, fraction: CGPoint) {
        let origin: FeedContextOrigin
        switch path.last {
        case .search: origin = .search
        case .destination(.home): origin = .home
        default: return
        }
        showFeedContextMenu(feedID, origin: origin, anchor: anchor, fraction: fraction)
    }

    private func showFeedRemovalMenu(_ feed: LibraryFeed) {
        var entries: [(String, String, () -> Void)] = []
        if feed.subscriptionState == .subscribed {
            entries.append((Appearance.text("sort"), "sortFeed", { [weak self] in self?.showFeedSort(feed) }))
        }
        if manualRefresh != nil, feed.subscriptionState != .notSubscribed {
            entries.append((Appearance.text("refresh_label"), "refreshFeed", { [weak self] in self?.requestFeedRefresh(feed) }))
        }
        if manualRefresh != nil, feed.metadata.isPaged {
            entries.append((Appearance.text("load_complete_feed"), "refreshCompleteFeed", { [weak self] in self?.requestFeedPage(feed.id, reset: true) }))
        }
        if let link = feed.metadata.link, !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entries.append((Appearance.text("visit_website_label"), "feedListWebsite", { [weak self] in self?.openWebsite(link) }))
        }
        if !feed.source.isLocalFeedSource {
            entries.append((Appearance.text("share_label"), "feedListShare", { [weak self] in self?.shareFeed(feed.id, anchorID: "feedListMore") }))
        }
        if feed.subscriptionState == .subscribed {
            entries.append((Appearance.text("remove_all_inbox_label"), "removeFeedInbox", { [weak self] in self?.confirmRemoveFeedInbox(feed.id) }))
        }
        if feedDeletion != nil, feed.subscriptionState != .notSubscribed {
            entries.append((Appearance.text(feed.subscriptionState == .archived ? "remove_restore_feed_label" : "remove_archive_feed_label"), "removeArchiveFeed", { [weak self] in self?.showFeedRemoval(feed) }))
        }
        showFeedMenu(entries, identifier: "feedListMenu")
    }

    private func showFeedSort(_ feed: LibraryFeed) {
        guard let library else { return }
        presentFeedSort(FeedSortEditor(feed: feed, store: library))
    }
    func showGlobalFeedSort() {
        guard let preferences = navigationPreferences else { return }
        presentFeedSort(FeedSortEditor(selection: preferences.value.defaultFeedSortOrder, local: false, includesGlobal: false, save: { order in
            var value = preferences.value; value.defaultFeedSortOrder = order
            try preferences.update(value)
        }))
    }
    func presentFeedSort(_ editor: FeedSortEditor) {
        editor.onSaved = { [weak self] in self?.reloadLibrary(preservingEpisodeDetails: true) }
        editor.onFailure = { [weak self] in self?.showError($0) }
        present(FeedSortController(editor: editor), animated: true)
    }
    func confirmRemoveFeedInbox(_ feedID: Int64) {
        guard let library else { return }
        present(SourceMessageController(title: Appearance.text("remove_all_inbox_label"), message: Appearance.text("remove_all_inbox_confirmation_msg"),
            positive: .init(title: Appearance.text("confirm_label"), identifier: "removeFeedInboxConfirm", perform: { [weak self] in
                Task {
                    do { try await library.removeFeedFromInbox(feedID: feedID); await self?.reloadLibrary(preservingEpisodeDetails: true)?.value }
                    catch { self?.showError(error) }
                }
            }), negative: .init(title: Appearance.text("cancel_label"), identifier: "removeFeedInboxCancel")), animated: true)
    }

    private func showFeedRemoval(_ feed: LibraryFeed) {
        guard let feedDeletion, let library else { return }
        let dialog = RemoveFeedController(feed: feed, remove: { [weak self] in
            self?.selectAfterFeedRemoval()
            try await feedDeletion.delete(feedID: feed.id).value
            await self?.reloadLibrary()?.value
        }, archive: { [weak self] state in
            try await library.updatePreferences(feedID: feed.id) { $0.subscriptionState = state }
            await self?.reloadLibrary()?.value
        }, failed: { [weak self] in self?.showError($0) })
        present(dialog, animated: true)
    }

    /// `accessories` draw the AppCompat trailing widgets (checkbox, radio button, submenu arrow);
    /// `header` is a submenu's title row.
    func showFeedMenu(_ entries: [(String, String, () -> Void)], identifier: String, checked: Set<String> = [],
                              accessories: [String: PopupMenuAccessory.Kind] = [:], header: String? = nil) {
        popup?.removeFromSuperview()
        let widths = (header.map { [($0 as NSString).size(withAttributes: [.font: Appearance.font(16, medium: true)]).width] } ?? [])
            + entries.map { ($0.0 as NSString).size(withAttributes: [.font: Appearance.font(16)]).width + (accessories[$0.1] == nil ? 0 : 48) }
        let overlay = UIControl(frame: surface.bounds)
        overlay.accessibilityIdentifier = identifier
        overlay.addAction(UIAction { [weak self] _ in self?.popup?.removeFromSuperview(); self?.popup = nil }, for: .touchUpInside)
        let panel = UIScrollView(); panel.backgroundColor = Appearance.navigation; panel.layer.cornerRadius = 4
        let buttons = entries.map { title, identifier, action in
            let button = textButton(title) { [weak self] in
                self?.popup?.removeFromSuperview(); self?.popup = nil; action()
            }
            button.accessibilityIdentifier = identifier; button.contentHorizontalAlignment = .leading
            if let kind = accessories[identifier] {
                let accessory = PopupMenuAccessory(kind: kind); accessory.tag = 702
                if kind.isOn { button.accessibilityTraits.insert(.selected) }
                button.addSubview(accessory)
            } else if checked.contains(identifier) {
                button.accessibilityTraits.insert(.selected)
                let mark = UIImageView(image: UIImage(named: "ic_check")); mark.tag = 701
                mark.contentMode = .scaleAspectFit; mark.tintColor = Appearance.foreground; mark.isUserInteractionEnabled = false
                button.addSubview(mark)
            }
            panel.addSubview(button)
            return button
        }
        let headerLabel = header.map { text -> UILabel in
            let label = Appearance.label(text, size: 16); label.font = Appearance.font(16, medium: true)
            label.textColor = Appearance.secondary; label.numberOfLines = 1; label.accessibilityTraits = .header
            label.accessibilityIdentifier = identifier + "Header"; panel.addSubview(label); return label
        }
        overlay.addSubview(panel); surface.addSubview(overlay); popup = overlay
        layoutPopup = { [weak self, weak overlay, weak panel] in
            guard let self, let overlay, let panel else { return }
            overlay.frame = surface.bounds
            let layout = EpisodeMenuLayout(viewport: CGSize(width: surface.bounds.width, height: surface.bounds.height - view.safeAreaInsets.bottom),
                anchorY: toolbar.frame.minY + toolbarLayout(hasOverflow: true).overflow.minY,
                titleWidths: widths, density: traitCollection.displayScale,
                rightToLeft: view.effectiveUserInterfaceLayoutDirection == .rightToLeft)
            panel.frame = layout.panel; panel.contentSize = layout.contentSize
            let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            if let headerLabel, let frame = layout.rows.first {
                headerLabel.frame = frame.insetBy(dx: 16, dy: 0); headerLabel.textAlignment = rtl ? .right : .left
            }
            for (button, frame) in zip(buttons, layout.rows.dropFirst(headerLabel == nil ? 0 : 1)) {
                button.frame = frame
                button.viewWithTag(701)?.frame = CGRect(x: rtl ? 8 : max(0, frame.width-32), y: (frame.height-24)/2, width: 24, height: 24)
                if let accessory = button.viewWithTag(702) as? PopupMenuAccessory {
                    let inset: CGFloat = accessory.kind == .submenu ? 16 : 24
                    accessory.frame = CGRect(x: rtl ? inset : max(0, frame.width - inset - 24), y: (frame.height-24)/2, width: 24, height: 24)
                    accessory.mirrored = rtl
                }
            }
        }
        layoutPopup?()
    }

    private func showInformationMenu(_ feed: LibraryFeed) {
        if feed.source.isLocalFeedSource { showReconnectMenu(feedID: feed.id); return }
        showFeedMenu([(Appearance.text("edit_url_menu"), "editFeedURL", { [weak self] in self?.editFeedURL(feed) })], identifier: "feedInformationMenu")
    }

    private func editFeedURL(_ feed: LibraryFeed) {
        guard let library, let manualRefresh else { return }
        let flow = FeedURLEditFlow(feed: feed, store: library, enqueueForcedRefresh: { [weak self] feedID in
            let accepted = manualRefresh.runOnce(feedID: feedID)
            Task { do { _ = try await accepted.value } catch { self?.showError(error) } }
        }, didUpdateURL: { [weak self] _ in self?.reloadLibrary(preservingEpisodeDetails: true) },
            failed: { [weak self] in self?.showError($0) })
        feedURLEdit = flow; flow.show(from: self)
    }

    private func requestFeedPage(_ feedID: Int64, reset: Bool) {
        guard let manualRefresh, !pageRequestPending else { return }
        pageRequestPending = true
        updateFeedPageFooter()
        let accepted = manualRefresh.runOnce(feedID: feedID, nextPage: !reset, resetPagination: reset)
        Task { [weak self] in
            defer { self?.pageRequestPending = false; self?.updateFeedPageFooter() }
            do { _ = try await accepted.value }
            catch { self?.showError(error) }
        }
    }

    func updateFeedPageFooter() {
        guard !renderingContent else { return }
        guard currentSelectionScope != nil, !content.accessibilityElementsHidden else {
            feedPageFooter.isHidden = true; feedSelectionBar.isHidden = true; return
        }
        var visible = false
        let height = feedPageFooter.sizeThatFits(content.bounds.size).height
        if case .feed(let id) = path.last, let feed = feeds.first(where: { $0.id == id }) {
            // Original recycler exposes its page control within the final three rows.
            let count = episodeList?.ids.count ?? 0
            let visibleRows = episodeList?.indices(from: content.bounds.minY, to: content.bounds.maxY) ?? 0..<0
            // Rows of this library not yet shown come first (EpisodesListFragment loads its next page).
            let nearBottom = remainingEpisodeRows == nil && (count == 0 || (!visibleRows.isEmpty && count - visibleRows.upperBound <= 3))
            visible = nearBottom && feed.metadata.isPaged && feed.metadata.nextPageURL != nil && manualRefresh != nil
            feedPageFooter.frame = CGRect(x: content.frame.minX, y: content.frame.maxY - height,
                width: content.bounds.width, height: height)
            let running: Bool = if case .active = manualRefresh?.state { true } else { false }
            feedPageFooter.setLoading(running || pageRequestPending)
        }
        feedPageFooter.isHidden = !visible
        let selecting = selectionScope == currentSelectionScope && feedSelection.active
        let selectionHeight = min(feedSelectionBar.preferredHeight, max(0, content.bounds.height - 48))
        feedSelectionBar.isHidden = !selecting
        feedSelectionBar.frame = CGRect(x: content.frame.minX, y: content.frame.maxY - selectionHeight,
            width: content.bounds.width, height: selectionHeight)
        let padding = selecting ? max(112, selectionHeight) : (visible ? height : 0)
        let contentHeight = feedContentHeight + padding
        if content.contentSize.height != contentHeight { content.contentSize.height = contentHeight }
        if visible { surface.bringSubviewToFront(feedPageFooter) }
        if selecting { surface.bringSubviewToFront(feedSelectionBar) }
    }

    @objc func feedPullChanged(_ gesture: UIPanGestureRecognizer) {
        handleFeedPull(state: gesture.state, translation: gesture.translation(in: content), location: gesture.location(in: surface))
    }

    /// Uses the existing scroll recognizer so row taps, scrolling and the pull
    /// share one touch sequence. Coordinates belong to the current content area.
    func handleFeedPull(state: UIGestureRecognizer.State, translation: CGPoint, location: CGPoint) {
        guard manualRefresh != nil, let scope = currentRefreshScope,
              !content.accessibilityElementsHidden, presentedViewController == nil else { stopFeedPull(); return }
        if case .active = manualRefresh?.state { stopFeedPull(); return }
        switch state {
        case .began:
            guard !pullWaiting else { return }
            let header = max(0, (feedAppBar?.fullHeaderHeight ?? 0) - max(0, content.contentOffset.y))
            guard location.y - translation.y >= content.frame.minY + header else { return }
            pullAnimation?.stopAnimation(true); pullAnimation = nil
            pullReturning = false; pullSettling = false
            pullScope = scope
            // Necessary short-window adaptation: leave enough travel to cross
            // the threshold without dragging outside the episode viewport.
            feedPull = FeedPullRefresh(triggerDistance: min(FeedPullRefresh.referenceTrigger,
                max(1, (content.bounds.height - header) * 0.5)))
            feedPull.begin(translation: translation.y, scrollOffset: content.contentOffset.y)
        case .changed:
            guard pullScope == scope, !pullWaiting else { return }
            feedPull.move(translation: translation.y)
            if feedPull.distance > 0 { content.contentOffset.y = 0 }
            refreshProgressChanged()
        case .ended:
            guard pullScope == scope, !pullWaiting else { return }
            feedPull.move(translation: translation.y)
            if feedPull.shouldRefresh {
                pullWaiting = true; pullSettling = true
                let animator = UIViewPropertyAnimator(duration: 0.2, curve: .easeOut) { [weak self] in self?.refreshProgressChanged() }
                pullAnimation = animator
                animator.addCompletion { [weak self] position in
                    guard let self, position == .end, pullScope == scope, pullWaiting,
                          currentRefreshScope == scope else { return }
                    pullAnimation = nil
                    pullSettling = false; refreshProgressChanged()
                    switch scope {
                    case .downloads, .home, .subscriptions, .archive, .list: requestFeedRefresh(nil)
                    case .feed(let id):
                        guard let feed = feeds.first(where: { $0.id == id }) else { stopFeedPull(); return }
                        requestFeedRefresh(feed)
                    }
                }
                animator.startAnimation()
            } else { returnFeedPull() }
        case .cancelled, .failed: returnFeedPull()
        default: break
        }
    }

    private func stopFeedPull() {
        pullAnimation?.stopAnimation(true); pullAnimation = nil
        pullScope = nil; pullWaiting = false; pullSettling = false; pullReturning = false
        feedPull = FeedPullRefresh()
        refreshProgressChanged()
    }

    private func returnFeedPull() {
        guard let id = pullScope, feedPull.distance > 0 else { stopFeedPull(); return }
        pullWaiting = false; pullSettling = false; pullReturning = true
        feedPull = FeedPullRefresh()
        let animator = UIViewPropertyAnimator(duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2, curve: .easeOut) { [weak self] in
            self?.refreshProgressChanged()
        }
        pullAnimation = animator
        animator.addCompletion { [weak self] position in
            guard let self, position == .end, pullScope == id, pullReturning else { return }
            pullAnimation = nil; stopFeedPull()
        }
        animator.startAnimation()
    }

    func requestFeedRefresh(_ feed: LibraryFeed?) {
        guard let manualRefresh else { return }
        Task { [weak self] in
            do {
                guard let self else { return }
                let network = try await refreshNetwork()
                let local = feed?.source.isLocalFeedSource == true
                let admission = manualRefresh.admission(feedID: feed?.id, isLocalFeed: local, network: network,
                    refreshAllowed: !network.restricted || mobileNetworkPreferences?.allows(.feedRefresh) == true)
                let run = { [weak self] in
                    let accepted = manualRefresh.runOnce(feedID: feed?.id, isLocalFeed: local)
                    // In server mode the server refreshes too (PROTOCOL §9); nothing waits for it.
                    if !local { (UIApplication.shared.delegate as? AppDelegate)?.serverSync?.requestServerRefresh(feedID: feed?.id) }
                    Task {
                        defer { self?.stopFeedPull() }
                        do { _ = try await accepted.value } catch { self?.showError(error) }
                    }
                }
                switch admission {
                case .run: run()
                case .cooldown: stopFeedPull(); showNotice(Appearance.text("please_wait_before_refreshing"))
                case .offline: stopFeedPull(); showNotice(Appearance.text("download_error_no_connection"))
                case .askMobile(let vpn):
                    let dialog = SourceMessageController(title: Appearance.text("feed_refresh_title"),
                        message: Appearance.text(vpn ? "confirm_mobile_feed_refresh_dialog_message_vpn" : "confirm_mobile_feed_refresh_dialog_message"),
                        positive: .init(title: Appearance.text("confirm_mobile_streaming_button_once"), identifier: "refreshOnce", perform: run),
                        negative: .init(title: Appearance.text("no"), identifier: "refreshNo", perform: { [weak self] in self?.stopFeedPull() }),
                        neutral: .init(title: Appearance.text("confirm_mobile_streaming_button_always"), identifier: "refreshAlways", perform: { [weak self] in
                            do { try self?.mobileNetworkPreferences?.setAllowed(.feedRefresh, true); run() }
                            catch { self?.stopFeedPull(); self?.showError(error) }
                        }))
                    dialog.onCancel = { [weak self] in self?.stopFeedPull() }
                    present(dialog, animated: true)
                }
            } catch { self?.stopFeedPull(); self?.showError(error) }
        }
    }

    func refreshProgressChanged() {
        if let preview = presentedViewController as? FeedPreviewController,
           let child = preview.contentController as? LibraryViewController { child.refreshProgressChanged() }
        guard isViewLoaded else { return }
        updateFeedPageFooter()
        let visible: Bool
        // MainActivity includes both RUNNING and ENQUEUED WorkInfo in the
        // sticky event. Offline saved work still shows the source indicator.
        if currentRefreshScope != nil, case .active = manualRefresh?.state,
           !content.accessibilityElementsHidden { visible = true } else { visible = false }
        let header = max(0, (feedAppBar?.fullHeaderHeight ?? 0) - max(0, content.contentOffset.y))
        let pulling = currentRefreshScope != nil && currentRefreshScope == pullScope && !content.accessibilityElementsHidden
        if !pulling, pullScope != nil {
            pullAnimation?.stopAnimation(true); pullAnimation = nil
            pullScope = nil; pullWaiting = false; pullSettling = false; pullReturning = false; feedPull = FeedPullRefresh()
        }
        let dragging = pulling && ((!pullWaiting && feedPull.distance > 0) || pullSettling || pullReturning) && !visible
        let offset = dragging && !pullSettling ? feedPull.geometry.offset : 24
        refreshIndicator.frame = CGRect(x: content.frame.midX - 20, y: toolbar.frame.maxY + header + offset, width: 40, height: 40)
        if dragging { refreshIndicator.setPull(feedPull.geometry) }
        else { refreshIndicator.setRunning(visible || (pulling && pullWaiting)) }
        if visible || pulling { surface.bringSubviewToFront(refreshIndicator) }
    }

    func refreshStateChanged(_ state: ManualFeedRefreshCoordinator.State) {
        refreshProgressChanged()
        if case .failed(_, let message) = state { showNotice(message) }
    }

    private func selectAfterFeedRemoval() {
        let tag = navigationPreferences?.value.defaultPage ?? NavigationDestination.home.rawValue
        selectTag(tag)
    }

    private func showReconnectMenu(feedID: Int64) {
        popup?.removeFromSuperview()
        let title = Appearance.text("reconnect_local_folder")
        let width = (title as NSString).size(withAttributes: [.font: Appearance.font(16)]).width
        let overlay = UIControl(frame: surface.bounds)
        overlay.accessibilityIdentifier = "feedInformationMenu"
        overlay.addAction(UIAction { [weak self] _ in self?.popup?.removeFromSuperview(); self?.popup = nil }, for: .touchUpInside)
        let panel = UIScrollView(); panel.backgroundColor = Appearance.navigation; panel.layer.cornerRadius = 4
        let button = textButton(title) { [weak self] in
            self?.popup?.removeFromSuperview(); self?.popup = nil
            self?.confirmReconnect(feedID: feedID)
        }
        button.accessibilityIdentifier = "reconnectLocalFolder"
        button.contentHorizontalAlignment = .leading
        panel.addSubview(button); overlay.addSubview(panel); surface.addSubview(overlay); popup = overlay
        layoutPopup = { [weak self, weak panel, weak overlay] in
            guard let self, let panel, let overlay else { return }
            overlay.frame = surface.bounds
            let layout = EpisodeMenuLayout(viewport: CGSize(width: surface.bounds.width, height: surface.bounds.height - view.safeAreaInsets.bottom),
                anchorY: toolbar.frame.minY, titleWidths: [width], density: traitCollection.displayScale,
                rightToLeft: view.effectiveUserInterfaceLayoutDirection == .rightToLeft)
            panel.frame = layout.panel; panel.contentSize = layout.contentSize; button.frame = layout.rows[0]
        }
        layoutPopup?()
    }

    private func confirmReconnect(feedID: Int64) {
        // The menu entry opens the source warning; picking a directory is a
        // separate step and cancellation at either stage leaves storage intact.
        let warning = SourceMessageController(message: Appearance.text("reconnect_local_folder_warning"),
            positive: .init(title: Appearance.text("ok"), identifier: "reconnectFolderConfirm", perform: { [weak self] in
                guard let self else { return }
                let picker = localFolderPicker.makeController { [weak self] directory in
                    Task { [weak self] in
                        guard let self, let localFolders else { return }
                        do {
                            let selection = try await LocalFolderSelection.prepare(directory: directory)
                            try await localFolders.reconnect(selection, feedID: feedID)
                            showNotice(Appearance.text("ok"))
                        } catch is CancellationError { }
                        catch { showError(error) }
                    }
                }
                present(picker, animated: true)
            }, performAfterDismiss: true),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "reconnectFolderCancel"))
        present(warning, animated: true)
    }

    func updateFeedAppBar(animated: Bool) {
        guard let appBar = feedAppBar else { return }
        let offset = content.contentOffset.y
        let collapse = min(appBar.fullHeaderHeight, max(0, offset))
        let toolbarHeight = toolbar.bounds.height
        appBar.toolbarHeight = toolbarHeight
        appBar.collapse = collapse
        appBar.frame = CGRect(x: 0, y: offset - toolbarHeight, width: content.bounds.width,
            height: toolbarHeight + appBar.fullHeaderHeight - collapse)
        appBar.setNeedsLayout(); appBar.layoutIfNeeded()
        // Extend drawing through the pinned toolbar while still clipping at
        // the navigation/player boundary. Touches there belong to the toolbar.
        content.clipsToBounds = false; content.bounces = false
        feedScrollMask.path = UIBezierPath(rect: CGRect(x: 0, y: offset - toolbarHeight,
            width: content.bounds.width, height: content.bounds.height + toolbarHeight)).cgPath
        content.layer.mask = feedScrollMask
        let collapsed = toolbarHeight + appBar.fullHeaderHeight - collapse < min(2 * toolbarHeight, toolbarHeight + appBar.fullHeaderHeight)
        if !animated || collapsed != feedToolbarCollapsed {
            feedToolbarCollapsed = collapsed
            feedScrimAnimator?.stopAnimation(true)
            let color: UIColor = collapsed ? Appearance.background : .clear
            if animated {
                let animator = UIViewPropertyAnimator(duration: 0.2,
                    controlPoint1: collapsed ? CGPoint(x: 0.4, y: 0) : CGPoint(x: 0, y: 0),
                    controlPoint2: collapsed ? CGPoint(x: 1, y: 1) : CGPoint(x: 0.2, y: 1)) {
                    self.toolbar.backgroundColor = color
                }
                feedScrimAnimator = animator; animator.startAnimation()
            } else { toolbar.backgroundColor = color }
        }
        for button in toolbar.subviews.compactMap({ $0 as? UIButton }) {
            button.tintColor = collapsed ? Appearance.foreground : .white
        }
        if let heading = toolbar.subviews.compactMap({ $0 as? UILabel }).first {
            if case .feed(let id) = path.last, collapsed { heading.text = feeds.first { $0.id == id }?.title }
            else { heading.text = "" }
        }
    }

    func episodeScreen(_ feed: LibraryFeed, _ episode: LibraryEpisode) {
        let website = EpisodeWebsite.toolbarDestination(episode: episode, feed: feed)
        // AppCompat toolbar padding is 0dp by default and 8dp at sw600dp.
        // Resolve from the current window content size, not device identity;
        // the toolbar already lies inside the surface's system safe area.
        let padding: CGFloat = min(view.bounds.width, view.bounds.height) >= 600 ? 8 : 0
        let horizontalInset = min(padding, toolbar.bounds.width / 2)
        let layout = ToolbarLayout(size: CGSize(width: max(0, toolbar.bounds.width - horizontalInset * 2),
                                                height: toolbar.bounds.height),
            // Open podcast and the favorite action also exist for text-only episodes, so there is always an overflow.
            hasNavigation: true, hasOverflow: true, density: traitCollection.displayScale,
            rightToLeft: view.effectiveUserInterfaceLayoutDirection == .rightToLeft,
            hasPrimaryAction: website != nil)
        if let back = toolbar.subviews.first(where: { $0.accessibilityIdentifier == "toolbarBack" }) {
            back.frame = layout.navigation.offsetBy(dx: horizontalInset, dy: 0)
        }
        if let website {
            let visit = Appearance.icon("ic_web", label: Appearance.text("visit_website_label")) { [weak self] in
                // The toolbar acts only on the settled, visible page.
                guard self?.episodePagerSettled(on: episode.id) == true else { return }
                self?.openWebsite(website)
            }
            visit.accessibilityIdentifier = "episodeWebsite"
            visit.frame = layout.primaryAction.offsetBy(dx: horizontalInset, dy: 0)
            toolbar.addSubview(visit)
        }
        let more = Appearance.icon("dots_vertical", label: Appearance.text("overflow_more")) { [weak self] in
            guard self?.episodePagerSettled(on: episode.id) == true else { return }
            self?.requestEpisodeMenu(feedID: feed.id, episodeID: episode.id)
        }
        more.accessibilityIdentifier = "episodeMore"
        more.frame = layout.overflow.offsetBy(dx: horizontalInset, dy: 0)
        toolbar.addSubview(more)
        renderEpisodePager(feed, episode)
    }

    /// One pager page (source ItemFragment): its own header, buttons and shownotes for its own episode.
    func makeEpisodePage(_ feed: LibraryFeed, _ episode: LibraryEpisode) -> EpisodePage {
        episodePagesBuilt += 1
        let container = UIView()
        container.clipsToBounds = true
        container.accessibilityIdentifier = "episodePage-\(episode.id)"
        let header = EpisodeHeaderView(feed: feed, episode: episode, library: library)
        header.openPodcast = { [weak self] in
            guard let self, let currentFeed = feeds.first(where: { $0.id == feed.id }) else { return }
            if currentFeed.subscriptionState == .notSubscribed { fetch(currentFeed.source) }
            else { push(.feed(currentFeed.id)) }
        }
        header.performAction = { [weak self] action in self?.performEpisodeDetailAction(episodeID: episode.id, action: action) }
        let headerScroll = UIScrollView()
        headerScroll.contentInsetAdjustmentBehavior = .never
        headerScroll.accessibilityIdentifier = "episodeHeaderScroll"
        headerScroll.addSubview(header)
        headerScroll.setContentOffset(.zero, animated: false)
        container.addSubview(headerScroll)
        let web = ShownotesWebView()
        web.accessibilityIdentifier = "episodeShownotes"
        web.isCovered = episodeContentCovered
        web.showLinkMenu = { [weak self] link, source in self?.presentShownotesLinkMenu(link, source: source) }
        web.shareSelection = { [weak self] text, source in self?.presentShownotesSelectionShare(text, source: source) }
        web.openLink = { [weak self] link in self?.openWebsite(link) }
        web.failure = { [weak self] error in self?.showError(error) }
        web.selectTimecode = { [weak self] time in
            guard let self else { return }
            guard let playback, [.preparing, .playing, .buffering, .paused].contains(playback.phase) else {
                showNotice(Appearance.text("play_this_to_seek_position_message")); return
            }
            Task { do { try await playback.seek(to: Int64(time)) } catch { self.showError(error) } }
        }
        container.addSubview(web)
        web.show(episode)
        return EpisodePage(feedID: feed.id, episodeID: episode.id, container: container,
            header: header, headerScroll: headerScroll, notes: web)
    }

    func layoutEpisodeDetails() {
        guard let pager = visibleEpisodePager else { return }
        for (index, page) in pager.pages {
            layoutEpisodePage(page, size: pager.view.bounds.size)
            // A neighbour rebuilt after its release reopens its header where it was read, within what fits now.
            guard pager.view.bounds.height > 0, let offset = pager.restoredHeaderOffsets.removeValue(forKey: index) else { continue }
            let maximum = max(0, page.headerScroll.contentSize.height - page.headerScroll.bounds.height)
            page.headerScroll.setContentOffset(CGPoint(x: 0, y: min(max(0, offset), maximum)), animated: false)
        }
    }

    func layoutEpisodePage(_ page: EpisodePage, size available: CGSize) {
        let episodeHeader = page.header, episodeNotes = page.notes, episodeHeaderScroll = page.headerScroll
        let size = episodeHeader.sizeThatFits(CGSize(width: available.width, height: .greatestFiniteMagnitude))
        let available = max(0, available.height)
        // Preserve the fixed header whenever a default notes line also fits.
        // Below that boundary only its viewport shrinks, never its contents.
        let headerMinimum = episodeHeader.minimumScrollViewportHeight(width: size.width)
        let line = episodeNotes.defaultLineHeight
        let notesAllowance: CGFloat
        if available >= headerMinimum + line {
            notesAllowance = min(episodeNotes.readableViewportHeight(width: size.width), available - headerMinimum)
        } else {
            // Transient/tiny windows cannot fit both minimums. Keep both regions
            // represented without negative frames; this is only partial visibility.
            notesAllowance = available * line / (headerMinimum + line)
        }
        let headerHeight = min(size.height, max(0, available - notesAllowance))
        let offset = episodeHeaderScroll.contentOffset.y
        let previousMaximum = max(0, episodeHeaderScroll.contentSize.height - episodeHeaderScroll.bounds.height)
        episodeHeaderScroll.frame = CGRect(x: 0, y: 0, width: size.width, height: headerHeight)
        episodeHeader.frame = CGRect(origin: .zero, size: size)
        episodeHeaderScroll.contentSize = size
        episodeHeaderScroll.isScrollEnabled = size.height > headerHeight
        let maximum = max(0, size.height - headerHeight)
        let clamped = CGPoint(x: 0, y: min(max(0, offset), maximum))
        if previousMaximum != maximum, episodeHeaderScroll.contentOffset != clamped {
            episodeHeaderScroll.setContentOffset(clamped, animated: false)
        }
        episodeNotes.frame = CGRect(x: 0, y: headerHeight, width: size.width, height: available - headerHeight)
        // A page turn, Back or a resize can reveal notes whose WebKit process ended while they were not shown.
        episodeNotes.visibilityMayHaveChanged()
        content.isScrollEnabled = false
    }

    func detailActions(_ episode: LibraryEpisode, feed: LibraryFeed) -> EpisodeDetailActions {
        let job = downloads?.activeJob(source: episode.details.media?.url)
        let progress = job.flatMap { downloads?.progress[$0.id] }
        let percent: Int
        if let progress, let expected = progress.expected, expected > 0 {
            percent = Int(min(100, max(0, Double(progress.received) / Double(expected) * 100)))
        } else { percent = 0 }
        return EpisodeDetailActions(episode: episode, localFeed: feed.source.isLocalFeedSource,
            currentlyPlaying: playback?.episode?.id == episode.id && playback?.wantsPlayback == true,
            downloading: job != nil, queuedDownload: job?.state == .waiting, downloadPercent: percent)
    }

    func updateEpisodeHeader() {
        guard case .episode(_, let id) = path.last, id == episodeDetailsID, let pager = visibleEpisodePager else { return }
        // Every resident page shows its own episode's current state, so a neighbour revealed by a swipe is current too.
        for page in pager.pages.values {
            guard let feed = feeds.first(where: { $0.id == page.feedID }),
                  let episode = feed.episodes.first(where: { $0.id == page.episodeID }) else { continue }
            page.header.update(feed: feed, episode: episode)
            page.header.update(actions: detailActions(episode, feed: feed))
        }
        layoutEpisodeDetails()
    }

    private func performEpisodeDetailAction(episodeID: Int64, action: EpisodeDetailActions.Action) {
        Task { [weak self] in
            guard let self, let library else { return }
            do {
                guard case .episode(let feedID, let currentID) = path.last, currentID == episodeID,
                      let feed = try await library.feed(id: feedID), let episode = feed.episodes.first(where: { $0.id == episodeID }) else { return }
                try await downloads?.refresh()
                guard case .episode(_, let visibleID) = path.last, visibleID == episodeID else { return }
                let current = detailActions(episode, feed: feed)
                guard [current.primary, current.secondary].contains(where: { $0.visible && $0.action == action }) else {
                    reloadLibrary(preservingEpisodeDetails: true); return
                }
                if let preferences = navigationPreferences?.value,
                   let suggestion = usage?.value.suggestion(for: action, preferences: preferences) {
                    showUsageSuggestion(suggestion, episodeID: episodeID)
                    return
                }
                switch action {
                case .stream:
                    logUsage(.stream)
                    preferVideoInThisScene()
                    try await playback?.select(episodeID: episodeID)
                case .playLocal:
                    preferVideoInThisScene()
                    try await playback?.select(episodeID: episodeID)
                case .play:
                    if try await library.repairMissingDownloadedMedia(episodeID: episodeID) {
                        showNotice(Appearance.text("error_file_not_found")); reloadLibrary(preservingEpisodeDetails: true)
                    }
                    else {
                        preferVideoInThisScene()
                        try await playback?.select(episodeID: episodeID)
                    }
                case .pause: try await playback?.pause()
                case .download:
                    guard episode.details.media != nil, !episode.userState.isDownloaded,
                          downloads?.activeJob(source: episode.details.media?.url) == nil else { return }
                    logUsage(.download)
                    if let decision = try await downloads?.request(episodeID: episodeID) { handleDownloadDecision(decision, episodeID: episodeID) }
                case .cancelDownload: try await downloads?.cancel(episodeID: episodeID)
                case .delete:
                    if let playback { try await downloads?.deleteDownloadedMedia(episodeID: episodeID, playback: playback) }
                case .markRead: try await library.markEpisodePlayed(episodeID: episodeID, played: true)
                case .visitWebsite: if let link = episode.details.link { openWebsite(link) }
                }
                // Playback publishes its own change (load, play/pause status), which reloads once; another
                // reload here only repeated it.
                switch action {
                case .stream, .play, .playLocal, .pause: break
                default: reloadLibrary(preservingEpisodeDetails: true)
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { showError(error) } }
        }
    }

    func logUsage(_ action: StreamDownloadUsage.Action) {
        do { try usage?.log(action) }
        catch { Logger(subsystem: "org.nottennapod.app", category: "Usage").error("Unable to persist local action usage") }
    }

    private func showUsageSuggestion(_ offer: StreamDownloadUsage.Action, episodeID: Int64) {
        guard let episodeHeader, let navigationPreferences else { return }
        popup?.removeFromSuperview()
        let prompt = UsageSuggestionView(frame: surface.bounds,
            anchorBottom: episodeHeader.primaryActionFrame(in: surface).maxY, offerStreaming: offer == .stream)
        prompt.dismiss = { [weak self, weak prompt] in
            prompt?.removeFromSuperview()
            if self?.popup === prompt { self?.popup = nil }
        }
        prompt.respond = { [weak self, weak prompt] accept in
            guard let self, case .episode(_, let currentID) = path.last, currentID == episodeID else {
                prompt?.dismiss?(); return
            }
            var preferences = navigationPreferences.value
            preferences.respondToStreamingSuggestion(offerStreaming: offer == .stream, accept: accept)
            do {
                try navigationPreferences.update(preferences)
                prompt?.dismiss?()
                if accept { showNotice(Appearance.text("on_demand_config_setting_changed")) }
            } catch { prompt?.dismiss?(); showError(error) }
        }
        surface.addSubview(prompt); popup = prompt
        layoutPopup = { [weak self, weak prompt] in
            guard let self, let prompt, let episodeHeader = self.episodeHeader else { return }
            episodeHeader.layoutIfNeeded()
            prompt.frame = surface.bounds
            prompt.updateAnchorBottom(episodeHeader.primaryActionFrame(in: surface).maxY)
        }
        prompt.animatePresentation()
    }
}
