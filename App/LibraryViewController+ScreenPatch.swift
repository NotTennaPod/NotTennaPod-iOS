import UIKit
import NotTennaPodCore

/// The open list's membership: an incrementally kept index (Inbox, Episodes, Favorites, History, a podcast's list), or one
/// of the person's own collections, recomputed from them (Queue, Downloads).
/// What a row was painted from: the episode its model showed, its queue membership and what it shows of its podcast.
struct RowPaint: Equatable {
    struct Header: Equatable {
        let title: String?, image: String?, source: String, subscription: FeedSubscriptionState
        init(_ feed: LibraryFeed) {
            title = feed.title; image = feed.metadata.imageURL; source = feed.source; subscription = feed.subscriptionState
        }
    }
    let episode: LibraryEpisode
    let queued: Bool
    let header: Header
}

struct EpisodeListScreen {
    enum Source {
        case index(EpisodeListIndex)
        case queue([Int64])
        case downloads([Int64])
    }
    var source: Source
    /// The screen it belongs to (`LibraryViewController.currentListKey`).
    let key: String

    var count: Int {
        switch source {
        case .index(let index): index.count
        case .queue(let ids), .downloads(let ids): ids.count
        }
    }
    var allIDs: [Int64] {
        switch source {
        case .index(let index): index.allIDs
        case .queue(let ids), .downloads(let ids): ids
        }
    }
    var spec: EpisodeListSpec? { if case .index(let index) = source { index.spec } else { nil } }
}

#if DEBUG
/// Test-only mutations of the list patch (`IncrementalScreenViewTests`): the reading position is not kept, every built
/// row is built again, every patch draws the whole screen, a queue change does not repaint rows, and a row is repainted
/// only when its model was replaced (not from what it was painted from).
enum ScreenPatchFault: Hashable { case readingPositionNotKept, everyRowRebuilt, renderEveryPatch, queueRepaintSkipped, paintedStateIgnored }
nonisolated(unsafe) var screenPatchFaults: Set<ScreenPatchFault> = []
#endif

// Incremental list screens: committed changes reach the open screen as patches of the rows they change.
extension LibraryViewController {
    enum CollectionList { case queue, downloads }

    /// The open screen's identity for its list and paging (a podcast page, a root list).
    var currentListKey: String { "\(String(describing: currentSelectionScope))#\(path.count)" }

    // MARK: - Opening

    /// Opens an indexed list over the screens' library; returns its member count.
    @discardableResult
    func openIndexedList(_ spec: EpisodeListSpec) -> Int {
        let candidates: [(feed: LibraryFeed, episode: LibraryEpisode)]
        switch spec {
        case .feed(let id, _, _): candidates = mirror.feed(id).map { feed in feed.episodes.map { (feed: feed, episode: $0) } } ?? []
        default: candidates = mirror.feeds.flatMap { feed in feed.episodes.map { (feed: feed, episode: $0) } }
        }
        let index = EpisodeListIndex(spec: spec, candidates: candidates, queued: mirror.queuedIDs)
        listScreen = EpisodeListScreen(source: .index(index), key: currentListKey)
        return index.count
    }

    /// Opens the Queue or Downloads; returns its rows.
    func openCollectionList(_ kind: CollectionList) -> [(LibraryFeed, LibraryEpisode)] {
        let ids = collectionIDs(kind)
        listScreen = EpisodeListScreen(source: kind == .queue ? .queue(ids) : .downloads(ids), key: currentListKey)
        return ids.compactMap { id in libraryEpisode(id).map { ($0.feed, $0.episode) } }
    }

    private func collectionIDs(_ kind: CollectionList) -> [Int64] {
        switch kind {
        case .queue: queuedEpisodes.compactMap { libraryEpisode($0.id) != nil ? $0.id : nil }
        case .downloads: mirror.downloads(jobs: downloads?.jobs ?? [], order: downloadPreferences?.value.listSortOrder)
        }
    }

    /// Shows the open indexed list, page by page from its membership.
    func indexedEpisodes(top: CGFloat = 0, paged: Bool) {
        guard case .index = listScreen?.source else { return }
        episodes(total: listScreen?.count ?? 0, top: top, paged: paged) { [weak self] range in
            guard let self, case .index(var index) = listScreen?.source else { return [] }
            let ids = index.ids(range)
            listScreen?.source = .index(index)
            return ids.compactMap { id in libraryEpisode(id).map { ($0.feed, $0.episode) } }
        }
    }

    /// The pager over the open list's members at the time of the tap (the list may have changed since the row was built).
    func currentPagerList() -> [EpisodePagerItem] {
        guard let listScreen else { return displayedEpisodeIDs.compactMap { id in libraryEpisode(id).map { EpisodePagerItem(feedID: $0.feed.id, episodeID: id) } } }
        return listScreen.allIDs.compactMap { id in libraryEpisode(id).map { EpisodePagerItem(feedID: $0.feed.id, episodeID: id) } }
    }

    /// A podcast page header's "interacted" state (`FeedItemlistFragment`): any favorite, download, played or queued
    /// episode, from the kept counts and the queue.
    func feedHasInteracted(_ feedID: Int64) -> Bool {
        if let counts = mirror.counts[feedID], counts.favorite > 0 || counts.downloaded > 0 || counts.played > 0 { return true }
        return queuedEpisodes.contains { libraryEpisode($0.id)?.feed.id == feedID }
    }

    // MARK: - The updater

    func configureScreenUpdater() {
        guard let screenUpdater, let library else { return }
        screenUpdater.request = { [weak self] sets in self?.mirrorRequest(for: sets) }
        screenUpdater.read = { request in try await library.readers().quick.mirrorRead(request) }
        screenUpdater.apply = { [weak self] read in self?.applyMirrorRead(read) }
        screenUpdater.reopen = { [weak self] in self?.reloadLibrary(preservingEpisodeDetails: true, reopen: true) }
        screenUpdater.failed = { [weak self] error in
            // A library closing (switch, restore, Keep) ends its readers; the screen is replaced, nothing to show.
            if case FeedLibraryError.closed = error { return }
            self?.showError(error)
        }
        screenUpdater.isActive = { [weak self] in self.map { !$0.applicationInBackground() } ?? false }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidEnterBackgroundForScreens),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        // A full read consumed the episodes refreshes asked to queue; with patches they are queued when they appear.
        guard !isPreview else { return }
        let queueEffects = queueEffects
        queueEffectEvents = Task { [weak self] in
            let requests = await library.queueEffectRequests()
            for await _ in requests {
                guard self != nil, !Task.isCancelled else { return }
                do {
                    if let queueEffects { try await queueEffects() } else { _ = try await library.consumeFeedRefreshQueueEffects() }
                } catch { self?.showError(error) }
            }
        }
    }

    @objc func applicationDidEnterBackgroundForScreens() { screenUpdater?.deactivate(); returningFromBackground = true }

    /// Tests: a screen that reads the whole library at every reload, as a fresh open (the reference the patched screen is
    /// compared with). Before the view loads.
    func useFullReadsForTesting() {
        screenUpdater?.stop()
        screenUpdater = nil
    }

    /// The keyed read for `sets`, or nil when more changed than a patch is worth (catch-up): the screen opens again.
    func mirrorRequest(for sets: [LibraryChangeSet]) -> LibraryMirrorRequest? {
        let request = mirror.request(for: sets)
        // A search never opens again on a catch-up: it re-matches only the changed episodes (only a new query scans).
        if case .search = path.last { return request }
        let resetEpisodes = request.resetFeeds.reduce(0) { $0 + (mirror.feed($1)?.episodes.count ?? 0) }
        let cap = max(2_000, (listScreen?.count ?? 0) / 4)
        return request.episodeCount + resetEpisodes > cap ? nil : request
    }

    /// Waits until the screen covers every change committed now (a write's receipt); returns at once in the background.
    func settleLibraryChanges() async {
        guard let screenUpdater, let library else { await reloadLibrary()?.value; return }
        _ = await screenUpdater.settle(receipt: library.changes.emitted)
    }

    // MARK: - Patches

    func applyMirrorRead(_ read: LibraryMirrorRead) {
        let delta = mirror.apply(read)
        // Every episode a shown commit named (changed or, coalesced, back to what it was) fences older action results.
        for id in read.episodes.keys { coveredEpisodeChanges[id] = read.sequence }
        for episodes in read.feedEpisodes.values { for row in episodes { coveredEpisodeChanges[row.episode.id] = read.sequence } }
        if !delta.isEmpty { libraryRevision &+= 1 }
        // Downloads also follow the jobs, which a commit may change without changing an episode.
        if delta.isEmpty, case .downloads? = listScreen?.source.kind {} else if delta.isEmpty { return }
        screenPatched(delta)
    }

    /// Shows a mirror patch on whatever screen is open, as a patch of what it changed (`LibraryViewController+OtherScreens`):
    /// a list's rows, Home's sections, the Subscriptions tiles, the search results, an episode's pages, a podcast's
    /// information header, the counters and the drawer. Statistics and Classics follow their own events, not changes.
    func screenPatched(_ delta: LibraryMirrorDelta) {
        screenPatchCount += 1
        latestDatesStorage?.apply(delta, mirror: mirror)
        // A row whose stored episode now differs from what its action model shows is built again from storage with a new
        // model; every other row keeps its model (an action in flight already shows its own commit).
        for (id, change) in delta.episodes {
            guard let binding = actionBindings[id] else { continue }
            if change.new.map({ binding.model.snapshot().episode == $0.episode && binding.feedID == $0.feed.id }) != true {
                actionBindings[id] = nil
            }
        }
        if (delta.feedOrder || !delta.feedStates.isEmpty), checkLibraryNavigation() { render(); updatePlayer(); return }
        // The open podcast is gone: the page is drawn again as a full read would draw it.
        switch path.last {
        case .feed(let id), .feedInformation(let id), .feedSettings(let id):
            if !mirror.contains(feed: id) { retireActionPresentation(); render(); updatePlayer(); return }
        default: break
        }
        switch path.last {
        case .episode:
            patchEpisodePages(delta)
            refreshNavigationCounters(delta)
        case .search(let search):
            patchSearch(search, delta)
            refreshNavigationCounters(delta)
        case .destination(.home):
            patchHome(delta)
            refreshNavigationCounters(delta)
        case .destination(.subscriptions), .destination(.subscriptionList), .archive:
            patchSubscriptions(delta)
        case .destination(.statistics):
            // Android's statistics pages load on open, on their return and on StatisticsEvent only.
            refreshNavigationCounters(delta)
        case .feedInformation(let id):
            // The header, the information and the toolbar actions show the podcast's stored fields: drawn again (the
            // screen's view is kept) when one of them changed, never for a refresh's bookkeeping; the statistics follow
            // their own events.
            if delta.headers.contains(id), let feed = mirror.feed(id), let shown = feedInformation?.feed, !Self.sameInformation(shown, feed) {
                render()
            } else { refreshNavigationCounters(delta) }
        case .feedSettings(let id):
            // The settings show the podcast's stored preferences: drawn again when its header changed.
            if delta.headers.contains(id) { render() } else { refreshNavigationCounters(delta) }
        case .settings, .settingsSearch, .discover, .onlineSearch, .destination(.addPodcast):
            // Screens that show no episode data: drawn again only when the podcasts came, went or changed state (a
            // subscribed mark, a podcast list); otherwise only the counters follow.
            if delta.feedOrder || !delta.feedStates.isEmpty { render() } else { refreshNavigationCounters(delta) }
        default:
            if listScreen?.key == currentListKey, episodeList != nil || listScreen?.count == 0 {
                patchEpisodeList(delta)
            } else {
                retireActionPresentation(); render()
            }
        }
        updatePlayer()
    }

    /// Paints a built row again when what it shows differs from what it was painted from (`RowPaint`), or when its model
    /// was retired: its model may be kept (an action in flight already shows its own commit). The row under a queue drag
    /// stays as it is until the drag lets it go, which calls this again.
    func repaintRow(_ id: Int64, value: LibraryMirrorDelta.Value, in list: LazyContentList) {
        guard list.views[id] != nil, queueDragController?.holds(id) != true, rowIsStale(id, value: value) else { return }
        episodeRows[id] = nil; list.rebuild(id, in: content)
    }

    /// The one rule for every built episode row (lists, a drag's end, search results, Home's rows): it is stale, and is
    /// painted again and bound to a current model, when what it shows (the episode its model shows, its queue membership,
    /// its podcast header) differs from what it was painted from (`RowPaint`), or when its model was retired.
    func rowIsStale(_ id: Int64, value: LibraryMirrorDelta.Value? = nil) -> Bool {
        guard let value = value ?? libraryEpisode(id) else { return false }
        let desired = RowPaint(episode: actionBindings[id]?.model.snapshot().episode ?? value.episode,
                               queued: isQueued(id), header: .init(value.feed))
        var stale = desired != rowPaints[id] || actionBindings[id] == nil
#if DEBUG
        if screenPatchFaults.contains(.paintedStateIgnored) { stale = actionBindings[id] == nil }
        if screenPatchFaults.contains(.everyRowRebuilt) { stale = true }
#endif
        return stale
    }

    /// Whether a patch names what a row of episode `id` shows: the episode itself, its joining or leaving the queue
    /// (`queueMembers`), or its podcast's header. Only such rows are judged by `rowIsStale` (never the whole queue).
    func patchNames(_ id: Int64, in delta: LibraryMirrorDelta) -> Bool {
        delta.episodes[id] != nil || delta.queueMembers.contains(id)
            || (!delta.headers.isEmpty && libraryEpisode(id).map { delta.headers.contains($0.feed.id) } == true)
    }

    /// The Downloads list after its jobs changed.
    func patchDownloadsList() {
        guard case .downloads? = listScreen?.source.kind, listScreen?.key == currentListKey else { return }
        patchEpisodeList(LibraryMirrorDelta())
    }

    /// Patches the open list: members that left or joined, the window of loaded pages, changed rows, counters and the
    /// reading position, item-anchored. A list going to or from empty is drawn again (its empty state and toolbar).
    func patchEpisodeList(_ delta: LibraryMirrorDelta) {
        guard var screen = listScreen else { render(); return }
#if DEBUG
        if screenPatchFaults.contains(.renderEveryPatch) { render(); return }
#endif
        // A podcast page whose filter or sort changed, or a list whose sort or filter preference changed, opens again.
        if let spec = screen.spec, spec != currentListSpec(spec) { retireActionPresentation(); render(); return }
        let before = screen.count
        var change = EpisodeListChange()
        var collection: [Int64]?
        switch screen.source {
        case .index(var index):
            // The index is changed in place: no other reference to its storage may remain (a shared one would be copied
            // whole).
            listScreen = nil
            screen.source = .queue([])
            change = index.apply(delta, mirror: mirror)
            screen.source = .index(index)
        case .queue(let old):
            let new = collectionIDs(.queue)
            change = Self.collectionChange(old, new)
            screen.source = .queue(new)
            collection = new
        case .downloads(let old):
            let new = collectionIDs(.downloads)
            change = Self.collectionChange(old, new)
            screen.source = .downloads(new)
            collection = new
        }
        listScreen = screen
        if (before == 0) != (screen.count == 0) { retireActionPresentation(); render(); return }
        guard let list = episodeList else { refreshNavigationCounters(delta); return }
        // Only the queue's structure (order, membership) ends a drag in progress; it puts back the order it started from
        // and is attached again to the new order. A row's content change (a position saved) keeps the drag.
        let queueChanged = queueVisible && !change.isEmpty
        if queueChanged { queueDragController?.cancel(); queueDragController = nil }
        let anchor = captureItemAnchor(list)
        // Podcasts whose header changes what a row shows, compared with the header the rows were placed with before any
        // row of this patch (a refresh adding a row of the podcast) records the new one.
        let rowFeeds = delta.headers.filter { id in
            guard let shown = displayedFeedHeaders[id], let feed = mirror.feed(id) else { return false }
            return !Self.sameRowHeader(shown, feed)
        }
        for id in rowFeeds { displayedFeedHeaders[id] = mirror.feed(id) }
        // A collection keeps the rows of the members that stay (a move reorders them): only leavers and joiners change.
        if let collection {
            let kept = Set(collection)
            change.removed = change.removed.filter { !kept.contains($0.id) }
            let present = Set(list.ids)
            change.inserted = collection.enumerated().filter { !present.contains($0.element) }.map { .init(id: $0.element, rank: $0.offset) }
        }
        // Removals (highest rank first), then insertions (lowest first), within the loaded window.
        var window = list.count
        for removal in change.removed where (collection != nil || removal.rank < window) && list.contains(removal.id) {
            list.remove(removal.id)
            displayedEpisodeValues[removal.id] = nil
            window -= 1
        }
        var measure = rowMeasure()
        for insertion in change.inserted where insertion.rank <= window || collection != nil {
            guard let value = libraryEpisode(insertion.id) else { continue }
            displayedEpisodeValues[insertion.id] = value
            displayedFeedHeaders[value.feed.id] = value.feed
            list.insert(insertion.id, height: measure.height(feed: value.feed, stored: value.episode), at: min(insertion.rank, window))
            window += 1
        }
        if let collection, list.ids != collection { list.reorder(collection) }
        // The window is the first loaded pages of the list after the change.
        let target = episodeListPaged ? min(screen.count, max(1, episodePaging.pages) * Self.episodesPerPage) : screen.count
        while window > target, let last = list.item(at: window - 1) {
            list.remove(last.id); displayedEpisodeValues[last.id] = nil; window -= 1
        }
        if window < target, let page = episodePageSource {
            for (feed, episode) in page(window..<target) {
                displayedEpisodeValues[episode.id] = (feed, episode)
                displayedFeedHeaders[feed.id] = feed
                list.insert(episode.id, height: measure.height(feed: feed, stored: episode), at: window)
                window += 1
            }
        }
        episodeListTotal = screen.count
        // Rows whose stored episode changed, or whose podcast changed what a row shows (title, cover, address,
        // subscription), and are shown: their content and height. A header change nothing shows (a refresh's attempt time)
        // rebuilds nothing.
        let inserted = Set(change.inserted.map(\.id))
        var changed = Set(delta.episodes.keys.filter { list.contains($0) && !inserted.contains($0) })
        if !rowFeeds.isEmpty {
            for (id, value) in displayedEpisodeValues where rowFeeds.contains(value.feed.id) && !inserted.contains(id) {
                changed.insert(id)
                actionBindings[id] = nil
            }
        }
#if DEBUG
        if screenPatchFaults.contains(.everyRowRebuilt) {
            for id in list.views.keys where !inserted.contains(id) { changed.insert(id); actionBindings[id] = nil }
        }
#endif
        // Rows whose queue membership changed show it (an indicator and its spoken value), on every list: the episodes the
        // patch named as joining or leaving, never the whole queue.
        var queueChanges = delta.queueMembers
#if DEBUG
        if screenPatchFaults.contains(.queueRepaintSkipped) { queueChanges = [] }
#endif
        queueMembershipChecks += queueChanges.count
        for id in queueChanges where list.contains(id) && !inserted.contains(id) { changed.insert(id) }
        for id in changed {
            guard let value = libraryEpisode(id) else { continue }
            displayedEpisodeValues[id] = value
            list.setHeight(measure.height(feed: value.feed, stored: value.episode), of: id, in: nil)
            repaintRow(id, value: value, in: list)
        }
        if queueChanged { attachQueueDrag() }
        list.restoreViewOrder(in: content)
        episodeListResized()
#if DEBUG
        if !screenPatchFaults.contains(.readingPositionNotKept) { restoreItemAnchor(anchor, in: list) }
#else
        restoreItemAnchor(anchor, in: list)
#endif
        updateVisibleContent()
        // A podcast page's header: its stored fields in place (a height change draws the page again), and the
        // "interacted" state of its episodes.
        if case .feed(let id) = path.last, let appBar = feedAppBar, let feed = mirror.feed(id) {
            if delta.headers.contains(id) {
                appBar.header.update(feed: feed, hasFilter: feed.episodeFilter.isActive, keepUpdated: feed.keepUpdated)
                if abs(appBar.header.sizeThatFits(content.bounds.size).height - appBar.fullHeaderHeight) > 0.5 {
                    retireActionPresentation(); render(); return
                }
            }
            appBar.header.updateInteracted(feedHasInteracted(id))
        }
        if feedSelection.active { updateFeedSelection() }
        updateQueueInformation()
        refreshNavigationCounters(delta)
    }

    /// Whether a row of `old`'s podcast shows the same as one of `new`'s (`EpisodeRowView`, the row's action model).
    nonisolated static func sameRowHeader(_ old: LibraryFeed, _ new: LibraryFeed) -> Bool {
        old.title == new.title && old.metadata.imageURL == new.metadata.imageURL && old.source == new.source
            && old.subscriptionState == new.subscriptionState
    }

    /// The spec the open list would have now (its preferences and its podcast's stored filter and sort).
    private func currentListSpec(_ spec: EpisodeListSpec) -> EpisodeListSpec {
        switch spec {
        case .inbox: .inbox(episodeLists.inbox)
        case .favorites: .favorites(episodeLists.episodes)
        case .history: .history
        case .episodes: .episodes(allEpisodesFilter, episodeLists.episodes)
        case .feed(let id, _, _):
            mirror.feed(id).map { .feed($0, globalSort: navigationPreferences?.value.defaultFeedSortOrder ?? .dateNewest) } ?? spec
        }
    }

    /// The change from one collection order to another: members that keep their relative order stay; leavers and the
    /// members that moved leave (highest old rank first), joiners and moved members join at their new rank (lowest first).
    static func collectionChange(_ old: [Int64], _ new: [Int64]) -> EpisodeListChange {
        guard old != new else { return EpisodeListChange() }
        let newSet = Set(new), oldSet = Set(old)
        let order = new.filter { oldSet.contains($0) }
        var stable: Set<Int64> = [], position = 0
        for id in old where newSet.contains(id) {
            if position < order.count, order[position] == id { stable.insert(id); position += 1 }
        }
        var change = EpisodeListChange()
        for (rank, id) in old.enumerated().reversed() where !stable.contains(id) { change.removed.append(.init(id: id, rank: rank)) }
        for (rank, id) in new.enumerated() where !stable.contains(id) { change.inserted.append(.init(id: id, rank: rank)) }
        return change
    }

    // MARK: - Reading position

    /// The first visible row and its offset from the top of the screen, and the rows after and before it (the fallback
    /// when it leaves), as Android's item notifications keep the first visible item in place.
    struct ItemAnchor {
        var id: Int64?
        var top: CGFloat
        var after: [Int64]
        var before: [Int64]
        var offset: CGFloat
    }

    func captureItemAnchor(_ list: LazyContentList) -> ItemAnchor {
        let y = max(0, content.contentOffset.y)
        guard let first = list.item(at: 0), y >= first.frame.minY, let item = list.firstItem(below: y) else {
            return ItemAnchor(id: nil, top: 0, after: [], before: [], offset: content.contentOffset.y)
        }
        let after = (item.index + 1..<min(list.count, item.index + 40)).compactMap { list.item(at: $0)?.id }
        let before = (max(0, item.index - 40)..<item.index).reversed().compactMap { list.item(at: $0)?.id }
        return ItemAnchor(id: item.id, top: item.frame.minY - y, after: after, before: before, offset: content.contentOffset.y)
    }

    func restoreItemAnchor(_ anchor: ItemAnchor, in list: LazyContentList) {
        let maximum = max(0, content.contentSize.height - content.bounds.height)
        guard let id = anchor.id else {
            content.setContentOffset(CGPoint(x: 0, y: min(max(0, anchor.offset), maximum)), animated: false)
            return
        }
        let y: CGFloat
        if let frame = list.frame(of: id) { y = frame.minY - anchor.top }
        else if let next = anchor.after.first(where: list.contains), let frame = list.frame(of: next) { y = frame.minY }
        else if let previous = anchor.before.first(where: list.contains), let frame = list.frame(of: previous) { y = frame.minY }
        else { y = 0 }
        content.setContentOffset(CGPoint(x: 0, y: min(max(0, y), maximum)), animated: false)
    }
}

extension EpisodeListScreen.Source {
    enum Kind { case index, queue, downloads }
    var kind: Kind {
        switch self {
        case .index: .index
        case .queue: .queue
        case .downloads: .downloads
        }
    }
}
