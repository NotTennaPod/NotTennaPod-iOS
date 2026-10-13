import UIKit
import NotTennaPodCore

// Library search and online search.
extension LibraryViewController {
    func openSearch(_ feed: LibraryFeed? = nil) {
        guard let library else { return }
        openSearch(session: LibrarySearchSession(feedID: feed?.id, feedTitle: feed?.title ?? "", read: { [weak self] query, id in
            try await Self.searchLibrary(self, store: library, query: query, feedID: id, archived: false)
        }))
    }
    /// Searches the library this screen has loaded, away from the main thread: the store's
    /// search parsed every episode record per query. Same results and order (host-tested against the store).
    nonisolated static func searchLibrary(_ controller: LibraryViewController?, store: FeedLibraryStore, query: String,
                                          feedID: Int64?, archived: Bool) async throws -> LibrarySearchResult {
        let loaded = await MainActor.run { () -> (feeds: [LibraryFeed], targets: [Int64: EpisodeMediaDeletionTarget])? in
            guard let controller, controller.libraryLoaded else { return nil }
            return (controller.feeds, controller.deletionTargets)
        }
        guard let loaded else { return try await store.search(query: query, feedID: feedID, archived: archived) }
        let worker = Task.detached(priority: .userInitiated) {
            try LibrarySearchResult.search(query: query, feeds: loaded.feeds, deletionTargets: loaded.targets,
                                           feedID: feedID, archived: archived)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    func openSearch(session: LibrarySearchSession) {
        guard let search = makeLibrarySearch(session: session) else { return }
        push(.search(search))
    }

    /// The library search page over `session`, wired to this screen (opened, or restored with its scene).
    func makeLibrarySearch(session: LibrarySearchSession) -> LibrarySearchView? {
        guard let library else { return nil }
        let search = LibrarySearchView(session: session)
        search.willReplaceRows = { [weak self, weak search] revision in
            guard let self, case .search(let active) = path.last, active === search else { return }
            if searchResultRevision != revision {
                retireActionPresentation(); searchResultRevision = revision
            }
            episodeRows.removeAll()
        }
        search.makeRow = { [weak self, weak search] feedID, episode in
            guard let self, case .search(let active) = path.last, active === search, let feed = feeds.first(where: { $0.id == feedID }) else { return nil }
            let target = search?.session.result.episodes.first { $0.episode.id == episode.id }?.deletionTarget
            let model = actionModel(feed: feed, episode: episode, deletionTarget: target)
            let episode = model.snapshot().episode
            let row = EpisodeRowView(feed: feed, episode: episode, queued: queuedEpisodes.contains { $0.id == episode.id },
                queueScreen: false, showRemainingTime: timeDisplayPreferences?.value.showRemainingTime == true,
                activelyPlaying: playback?.episode?.id == episode.id && playback?.wantsPlayback == true, library: library,
                episodeCover: usesEpisodeCover,
                downloadAction: { [weak self, weak search] in
                    if search?.toggleSelection(episode.id) != true { self?.downloadAction(episode.id) }
                },
                open: { [weak self, weak search] in
                    guard let self, let search, !search.toggleSelection(episode.id) else { return }
                    // The pager gets the episode results shown now (rows exist only for loaded feeds).
                    let list = search.session.result.episodes.filter { result in feeds.contains { $0.id == result.feedID } }
                        .map { EpisodePagerItem(feedID: $0.feedID, episodeID: $0.episode.id) }
                    openEpisode(feedID: feed.id, episodeID: episode.id, list: list)
                })
            row.actionModel = model
            episodeRows[episode.id] = (episode, row)
            let job = downloads?.activeJob(source: episode.details.media?.url)
            row.updateDownload(job: job, progress: job.flatMap { downloads?.progress[$0.id] },
                playing: playback?.episode?.id == episode.id && playback?.wantsPlayback == true,
                streamOverDownload: navigationPreferences?.value.streamOverDownload == true)
            return row
        }
        search.rowHeight = { [weak self] feedID, episode, width in
            guard let self, let feed = feeds.first(where: { $0.id == feedID }) else { return nil }
            return width > 0 ? searchRowHeight(feed: feed, episode: episode, width: width) : 0
        }
        search.selectedItems = { [weak self] ids in self?.episodeListItems(ids) ?? [] }
        search.selectionChanged = { [weak self, weak search] in
            guard let self, let search, case .search(let active) = path.last, active === search else { return }
            renderSearchSelectionToolbar(search)
        }
        search.episodeContext = { [weak self, weak search] id, anchor, fraction in
            guard let self, let search else { return }
            showSearchEpisodeMenu(id, search: search, anchor: anchor, fraction: fraction)
        }
        search.performSelection = { [weak self] action, ids in self?.performEpisodeListAction(action, ids: ids, selection: true) }
        search.openFeed = { [weak self] in self?.push(.feed($0)) }
        search.feedContext = { [weak self, weak search] feedID, anchor, fraction in
            guard let self, case .search(let active) = path.last, active === search else { return }
            showSearchFeedMenu(feedID, anchor: anchor, fraction: fraction)
        }
        search.searchOnline = { [weak self] in self?.openOnlineSearch($0) }
        search.onFailure = { [weak self] in self?.showError($0) }
        return search
    }

    /// The library search as a restored scene had it: the whole library, a podcast or the archive, with its text in
    /// the field at once and searched again by `start` (without the keyboard, as `openSearchSubmitting`) once the
    /// library has been read; an empty search waits for typing.
    func makeRestoredLibrarySearch(query: String, feedID: Int64?, feedTitle: String, archived: Bool) -> (view: LibrarySearchView, start: () -> Void)? {
        guard let library else { return nil }
        let session = archived
            ? LibrarySearchSession(archivedTitle: Appearance.text("archive_feed_label_noun")) { [weak self] query, id, archived in
                try await Self.searchLibrary(self, store: library, query: query, feedID: id, archived: archived)
            }
            : LibrarySearchSession(feedID: feedID, feedTitle: feedTitle, read: { [weak self] query, id in
                try await Self.searchLibrary(self, store: library, query: query, feedID: id, archived: false)
            })
        guard let search = makeLibrarySearch(session: session) else { return nil }
        if !query.isEmpty { search.focusOnAttach = false; search.session.restoreQuery(query); search.field.text = query }
        return (search, { [weak search] in
            guard let search, !query.isEmpty else { return }
            search.session.submit()
        })
    }

    /// A search result row's height before it is built, as the other lists measure theirs.
    private func searchRowHeight(feed: LibraryFeed, episode stored: LibraryEpisode, width: CGFloat) -> CGFloat {
        let episode = actionBindings[stored.id]?.model.snapshot().episode ?? stored
        let scale = view.window?.screen.scale ?? traitCollection.displayScale
        let playing = playback?.wantsPlayback == true && playback?.episode?.id == episode.id
        let key = EpisodeRowHeightKey(title: episode.details.title ?? "",
            progressLine: EpisodeRowView.showsProgressLine(episode, activelyPlaying: playing),
            draggable: false, action: true, queue: false, width: width, scale: scale, category: traitCollection.preferredContentSizeCategory)
        if let height = episodeRowHeights[key] { return height }
        let height = EpisodeRowMetrics(queueTraits: nil, scale: scale).height(title: key.title, progressLine: key.progressLine,
                                                                           width: width, draggable: false, showAction: true)
        if episodeRowHeights.count >= 20_000 { episodeRowHeights.removeAll() }
        episodeRowHeights[key] = height
        return height
    }

    func renderSearch(_ search: LibrarySearchView) {
        content.isScrollEnabled = false
        search.emptyAreaTop = -content.frame.minY
        search.frame = content.bounds; search.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.addSubview(search)
        let layout = toolbarLayout(hasOverflow: false)
        search.field.frame = layout.title
        let needsFocus = search.field.superview !== toolbar
        toolbar.addSubview(search.field)
        search.toolbarAttached(focus: needsFocus && !search.selection.active); renderSearchSelectionToolbar(search)
        search.rebuildRows()
        if searchNeedsReload { searchNeedsReload = false; search.reload() }
    }

    private func renderSearchSelectionToolbar(_ search: LibrarySearchView) {
        toolbar.subviews.filter { $0.accessibilityIdentifier == "searchSelectionToolbar" }.forEach { $0.removeFromSuperview() }
        search.field.isHidden = search.selection.active
        toolbar.accessibilityElements = nil
        guard search.selection.active else { return }
        let bar = UIView(frame: toolbar.bounds); bar.backgroundColor = Appearance.navigation
        bar.accessibilityIdentifier = "searchSelectionToolbar"
        let layout = toolbarLayout(hasOverflow: true)
        let close = Appearance.icon("abc_ic_ab_back_material", label: Appearance.text("close_label")) { [weak search] in
            guard let search else { return }; search.endSelection()
            UIAccessibility.post(notification: .layoutChanged, argument: search.field)
        }
        close.configuration?.image = UIImage(named: "abc_ic_ab_back_material")?.imageFlippedForRightToLeftLayoutDirection()
        close.accessibilityIdentifier = "endEpisodeSelection"; close.frame = layout.navigation
        let count = search.selection.ids.count
        let title = Appearance.label(String(format: Appearance.text("num_selected_label"), count, search.displayedIDs.count), size: 20)
        title.numberOfLines = 1; title.frame = layout.title; title.accessibilityIdentifier = "episodeSelectionCount"
        let more = Appearance.icon("dots_vertical", label: Appearance.text("overflow_more")) { [weak self, weak search, weak bar] in
            guard let self, let search, let bar else { return }
            let keys = ["select_toggle", "select_all_above", "select_all_below"]
            let titleKeys = [search.selection.ids.count == search.displayedIDs.count ? "deselect_all_label" : "select_all_label", "select_all_above", "select_all_below"]
            let menu = PopupMenuController(title: "", identifier: "episodeSelectionOptions", anchor: bar,
                anchorFraction: CGPoint(x: bar.effectiveUserInterfaceLayoutDirection == .rightToLeft ? 0 : 1, y: 1),
                actions: zip(keys, titleKeys).map { ($0.0, Appearance.text($0.1)) }) { search.changeSelection($0) }
            present(menu, animated: true)
        }
        more.accessibilityIdentifier = "episodeSelectionMore"; more.frame = layout.overflow
        [close, title, more].forEach(bar.addSubview); toolbar.addSubview(bar); toolbar.accessibilityElements = [bar]
    }

    private func showSearchEpisodeMenu(_ id: Int64, search: LibrarySearchView, anchor: UIView, fraction: CGPoint) {
        guard case .search(let active) = path.last, active === search, !search.selection.active,
              let captured = captureAction(id) else { return }
        let item = contextItem(captured.model), episode = item.episode
        let menu = PopupMenuController(title: episode.details.title ?? "", identifier: "searchEpisodeContextMenu",
            anchor: anchor, anchorFraction: fraction, actions: EpisodeListMenu.actions([item], selection: false).map {
                ($0.rawValue, Appearance.text($0.titleKey(hasMedia: episode.details.media != nil)))
            }) { [weak self, weak search] key in
                guard let action = EpisodeListAction(rawValue: key) else { return }
                if action == .multiSelect { search?.startSelection(id) }
                else { self?.performEpisodeListAction(action, ids: [id], captured: action == .removeInbox ? captured : nil) }
            }
        present(menu, animated: true)
    }

    private func openOnlineSearch(_ query: String) {
        if query.range(of: "^https?://[^\\r\\n]*$", options: .regularExpression) != nil { fetch(query); return }
        push(.onlineSearch(makeOnlineSearch(provider: .combined, query: query)))
    }

    /// OnlineSearchFragment for one provider, submitting `query` at once when there is one (opened, or restored with
    /// its scene).
    func makeOnlineSearch(provider: PodcastSearchProvider, query: String?) -> OnlineSearchView {
        let client = podcastSearch
        let session = OnlineSearchSession(provider: provider, read: { query, provider in try await client.search(query, provider: provider) })
        let search = OnlineSearchView(session: session, query: query)
        search.openFeed = { [weak self] in self?.fetch($0) }
        return search
    }

    func renderOnlineSearch(_ search: OnlineSearchView) {
        content.isScrollEnabled = false
        search.emptyAreaTop = -content.frame.minY
        search.frame = content.bounds; search.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.addSubview(search)
        search.field.frame = toolbarLayout(hasOverflow: false).title
        toolbar.addSubview(search.field); search.toolbarAttached()
    }
}
