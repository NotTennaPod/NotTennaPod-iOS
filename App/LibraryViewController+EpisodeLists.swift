import UIKit
import NotTennaPodCore

// Inbox, Episodes, Favorites and History lists.
extension LibraryViewController {
    private func allEpisodesRows() -> [(LibraryFeed, LibraryEpisode)] {
        let queued = Set(queuedEpisodes.map(\.id)), filter = allEpisodesFilter
        let rows = feeds.flatMap { feed in
            feed.episodes.filter { filter.includes($0, subscription: feed.subscriptionState, queued: queued.contains($0.id)) }.map { (feed: feed, episode: $0) }
        }
        return EpisodeListQueries.episodes(rows, filter: filter.effective, sort: episodeLists.episodes).map { ($0.feed, $0.episode) }
    }
    // MARK: Episode lists

    func renderInbox(heading: UILabel) {
        let rows = EpisodeListQueries.inbox(feeds, sort: episodeLists.inbox).map { ($0.feed, $0.episode) }
        feedSelectionIDs = rows.map { $0.1.id }
        if rows.isEmpty { listEmpty(icon: "ic_inbox", title: "no_inbox_head_label", message: "no_inbox_label", identifier: "inbox") }
        else { episodes(rows, paged: true) }
        let layout = toolbarLayout(hasOverflow: true, hasSecondaryAction: true)
        heading.frame = layout.title
        let search = Appearance.icon("ic_search", label: Appearance.text("search_label")) { [weak self] in self?.openSearch() }
        search.accessibilityIdentifier = "inboxSearch"; search.frame = layout.secondaryAction
        let more = Appearance.icon("dots_vertical", label: Appearance.text("overflow_more")) { [weak self] in
            self?.showFeedMenu([(Appearance.text("sort"), "inboxSort", { [weak self] in self?.showEpisodeListSort(inbox: true) }),
                                (Appearance.text("refresh_label"), "inboxRefresh", { [weak self] in self?.requestFeedRefresh(nil) }),
                                (Appearance.text("remove_all_inbox_label"), "inboxRemoveAll", { [weak self] in self?.removeAllFromInbox() })],
                               identifier: "inboxMenu")
        }
        more.accessibilityIdentifier = "inboxMore"; more.frame = layout.overflow
        [search, more].forEach(toolbar.addSubview)
    }

    func renderFavorites(heading: UILabel) {
        let rows = EpisodeListQueries.favorites(feeds, sort: episodeLists.episodes).map { ($0.feed, $0.episode) }
        feedSelectionIDs = rows.map { $0.1.id }
        if rows.isEmpty { listEmpty(icon: "ic_star", title: "no_fav_episodes_head_label", message: "no_fav_episodes_label", identifier: "favorites") }
        else { episodes(rows, paged: true) }
        let layout = toolbarLayout(hasOverflow: true, hasSecondaryAction: true)
        heading.frame = layout.title
        let search = Appearance.icon("ic_search", label: Appearance.text("search_label")) { [weak self] in self?.openSearch() }
        search.accessibilityIdentifier = "favoritesSearch"; search.frame = layout.secondaryAction
        let more = Appearance.icon("dots_vertical", label: Appearance.text("overflow_more")) { [weak self] in
            self?.showFeedMenu([(Appearance.text("refresh_label"), "favoritesRefresh", { [weak self] in self?.requestFeedRefresh(nil) })],
                               identifier: "favoritesMenu")
        }
        more.accessibilityIdentifier = "favoritesMore"; more.frame = layout.overflow
        [search, more].forEach(toolbar.addSubview)
    }

    func renderHistory(heading: UILabel) {
        let rows = EpisodeListQueries.history(feeds).map { ($0.feed, $0.episode) }
        feedSelectionIDs = rows.map { $0.1.id }
        if rows.isEmpty { listEmpty(icon: "ic_history", title: "no_history_head_label", message: "no_history_label", identifier: "history") }
        else { episodes(rows, paged: true) }
        // Clear history is shown only while the history has episodes (`PlaybackHistoryFragment:91–95`).
        let layout = toolbarLayout(hasOverflow: false, hasPrimaryAction: !rows.isEmpty)
        heading.frame = layout.title
        guard !rows.isEmpty else { return }
        let clear = Appearance.icon("ic_delete", label: Appearance.text("clear_history_label")) { [weak self] in self?.confirmClearHistory() }
        clear.accessibilityIdentifier = "historyClear"; clear.frame = layout.primaryAction
        toolbar.addSubview(clear)
    }

    private func listEmpty(icon name: String, title: String, message: String, identifier: String) {
        let icon = UIImageView(image: UIImage(named: name)); icon.tintColor = Appearance.foreground
        let heading = Appearance.label(Appearance.text(title), size: 16)
        let detail = Appearance.label(Appearance.text(message), size: 14)
        heading.accessibilityIdentifier = identifier + "EmptyTitle"; detail.accessibilityIdentifier = identifier + "EmptyMessage"
        detail.textColor = Appearance.secondary
        heading.textAlignment = .center; detail.textAlignment = .center
        let width = max(0, content.bounds.width - 80)
        let headingHeight = heading.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height + 3
        let detailHeight = detail.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height + 3
        let y = max(0, (content.bounds.height - 32 - headingHeight - detailHeight) / 2)
        icon.frame = CGRect(x: (content.bounds.width - 32) / 2, y: y, width: 32, height: 32)
        heading.frame = CGRect(x: 40, y: icon.frame.maxY, width: width, height: headingHeight)
        detail.frame = CGRect(x: 40, y: heading.frame.maxY, width: width, height: detailHeight)
        [icon, heading, detail].forEach(content.addSubview)
    }

    private func updateEpisodeLists(_ change: (inout EpisodeListPreferences) -> Void) {
        if let episodeListPreferences {
            do { try episodeListPreferences.update(change) } catch { showError(error); return }
        } else { change(&episodeListFallback) }
    }

    /// Inbox or Episodes sort sheet; each tap saves and re-sorts the open lists (Favorites follows Episodes).
    private func showEpisodeListSort(inbox: Bool) {
        guard presentedViewController == nil else { return }
        present(EpisodeListSortController(current: { [weak self] in
            guard let self else { return .standard }
            return inbox ? episodeLists.inbox : episodeLists.episodes
        }, save: { [weak self] sort in
            self?.updateEpisodeLists { if inbox { $0.inboxSort = sort.rawValue } else { $0.episodesSort = sort.rawValue } }
            self?.render()
        }), animated: true)
    }

    /// `InboxFragment.removeAllNewFlagsConfirm`: prompt unless "Do not show again" was chosen.
    private func removeAllFromInbox() {
        guard presentedViewController == nil else { return }
        let run = { [weak self] in
            guard let self, let library else { return }
            Task { [weak self] in
                do { try await library.removeAllFromInbox() } catch { self?.showError(error); return }
                await self?.reloadLibrary()?.value
                self?.showNotice(Appearance.text("removed_all_inbox_msg"))
            }
        }
        if episodeLists.doNotPromptRemoveAllFromInbox { run(); return }
        let body = QueueLockWarningBody(messageKey: "remove_all_inbox_confirmation_msg", identifier: "inboxRemoveAllMessage",
                                        checkboxIdentifier: "inboxRemoveAllDoNotShow")
        present(SourceMessageController(title: Appearance.text("remove_all_inbox_label"), message: "",
            positive: .init(title: Appearance.text("confirm_label"), identifier: "inboxRemoveAllConfirm", perform: { [weak self] in
                run()
                let checked = body.suppression.checked
                self?.updateEpisodeLists { $0.doNotPromptRemoveAllFromInbox = checked }
            }, performAfterDismiss: true),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "inboxRemoveAllCancel"), customBody: body), animated: true)
    }

    /// `PlaybackHistoryFragment` Clear history confirmation.
    private func confirmClearHistory() {
        guard presentedViewController == nil else { return }
        present(SourceMessageController(title: Appearance.text("clear_history_label"), message: Appearance.text("clear_playback_history_msg"),
            positive: .init(title: Appearance.text("confirm_label"), identifier: "historyClearConfirm", perform: { [weak self] in
                guard let self, let library else { return }
                Task { [weak self] in
                    do { try await library.clearPlaybackHistory() } catch { self?.showError(error); return }
                    await self?.reloadLibrary()?.value
                }
            }, performAfterDismiss: true),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "historyClearCancel")), animated: true)
    }

    func renderAllEpisodes(heading: UILabel) {
        let rows = allEpisodesRows()
        // The source adapter's total count and selection denominator use the same query.
        feedSelectionIDs = rows.map { $0.1.id }
        if rows.isEmpty { allEpisodesEmpty() }
        else { episodes(rows, paged: true) }
        let layout = toolbarLayout(hasOverflow: true, hasPrimaryAction: true, hasSecondaryAction: true)
        heading.frame = layout.title
        let search = Appearance.icon("ic_search", label: Appearance.text("search_label")) { [weak self] in self?.openSearch() }
        search.accessibilityIdentifier = "allEpisodesSearch"; search.frame = layout.secondaryAction
        let filter = Appearance.icon("ic_filter_white", label: Appearance.text("filter")) { [weak self] in self?.showAllEpisodesFilter() }
        filter.accessibilityIdentifier = "allEpisodesFilter"; filter.frame = layout.primaryAction
        let more = Appearance.icon("dots_vertical", label: Appearance.text("overflow_more")) { [weak self] in
            self?.showFeedMenu([(Appearance.text("sort"), "allEpisodesSort", { [weak self] in self?.showEpisodeListSort(inbox: false) }),
                                (Appearance.text("refresh_label"), "allEpisodesRefresh", { [weak self] in self?.requestFeedRefresh(nil) })],
                               identifier: "allEpisodesMenu")
        }
        more.accessibilityIdentifier = "allEpisodesMore"; more.frame = layout.overflow
        [search, filter, more].forEach(toolbar.addSubview)
    }
    private func allEpisodesEmpty() {
        let icon = UIImageView(image: UIImage(named: "ic_feed")); icon.tintColor = Appearance.foreground
        let title = Appearance.label(Appearance.text("no_all_episodes_head_label"), size: 16)
        let message = Appearance.label(Appearance.text(allEpisodesFilter.effective.isActive ? "no_all_episodes_filtered_label" : "no_all_episodes_label"), size: 14)
        title.accessibilityIdentifier = "allEpisodesEmptyTitle"; message.accessibilityIdentifier = "allEpisodesEmptyMessage"
        message.textColor = Appearance.secondary
        title.textAlignment = .center; message.textAlignment = .center
        let width = max(0, content.bounds.width - 80)
        let titleHeight = title.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height + 3
        let messageHeight = message.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height + 3
        let y = max(0, (content.bounds.height - 32 - titleHeight - messageHeight) / 2)
        icon.frame = CGRect(x: (content.bounds.width - 32) / 2, y: y, width: 32, height: 32)
        title.frame = CGRect(x: 40, y: icon.frame.maxY, width: width, height: titleHeight)
        message.frame = CGRect(x: 40, y: title.frame.maxY, width: width, height: messageHeight)
        [icon, title, message].forEach(content.addSubview)
    }
    @objc func showAllEpisodesFilter() {
        guard allEpisodesVisible, let allEpisodesFilterPreferences, presentedViewController == nil else { return }
        present(FeedFilterController(allEpisodes: AllEpisodesFilterEditor(store: allEpisodesFilterPreferences), onSaved: { [weak self] in
            self?.content.setContentOffset(.zero, animated: false)
            self?.render(); self?.view.setNeedsLayout()
        }, onFailure: { [weak self] in self?.showError($0) }), animated: true)
    }
}
