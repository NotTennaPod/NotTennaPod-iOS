import UIKit
import NotTennaPodCore

/// What one Home section shows: its episodes (cards or rows) with their podcasts, Classics' podcasts, and the badge.
struct HomeSectionContent: Equatable {
    var rows: [(LibraryFeed, LibraryEpisode)] = []
    var feeds: [LibraryFeed] = []
    var badge: String?

    /// What a person sees of it: each episode and the parts of its podcast a card or row shows, Classics' covers.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.badge == rhs.badge && lhs.rows.count == rhs.rows.count && lhs.feeds.count == rhs.feeds.count
            && zip(lhs.rows, rhs.rows).allSatisfy { $0.1 == $1.1 && RowPaint.Header($0.0) == RowPaint.Header($1.0) }
            && zip(lhs.feeds, rhs.feeds).allSatisfy { $0.id == $1.id && $0.title == $1.title && $0.metadata.imageURL == $1.metadata.imageURL }
    }

    /// Whether `other` shows the same episodes, podcasts and badge in the same places, its episodes differing at most in
    /// their playback (`LibraryEpisode.differsOnlyInPlayback`): a position save, which cards and rows show in place.
    func differsOnlyInPlayback(from other: Self) -> Bool {
        var same = other
        same.rows = zip(rows, other.rows).map { mine, theirs in
            mine.1.id == theirs.1.id && mine.1.differsOnlyInPlayback(from: theirs.1) ? (theirs.0, mine.1) : theirs
        } + other.rows.dropFirst(rows.count)
        return self == same
    }
}

/// One drawn Home section: what it shows, its views and where it is.
struct HomeSectionState {
    let section: HomeSection
    var shown: HomeSectionContent
    var views: [UIView]
    var top: CGFloat
    var height: CGFloat
    /// What its strip's cards show, in order: Classics' podcasts, or the episodes of the other strips.
    var stripIDs: [Int64] { section == .classics ? shown.feeds.map(\.id) : shown.rows.map(\.1.id) }
}

/// The Subscriptions or Archive grid as drawn, which a patch lays out again.
struct SubscriptionGridGeometry {
    let layout: SubscriptionsGridLayout
    let rowHeight: CGFloat
    let top: CGFloat
    let rightToLeft: Bool
    let selecting: Bool
    let archived: Bool
    let filtered: Bool
    let tag: String
}

/// What a Subscriptions tile or list row shows (`SubscriptionGridCell`, `SubscriptionListRow`), refresh failure included.
struct SubscriptionTileFace: Equatable {
    let title: String
    let imageURL: String?
    let local: Bool
    let counter: Int
    let failed: Bool
    init(_ feed: LibraryFeed, counter: Int) {
        title = feed.humanReadableIdentifier; imageURL = feed.metadata.imageURL
        local = feed.source.isLocalFeedSource; self.counter = counter; failed = feed.refreshFailed
    }
}

// The other screens kept from patches: Home's sections, the Subscriptions and Archive tiles, the drawer, the search
// results, an episode's pages; Statistics, Feed Information statistics and Classics follow their own events.
extension LibraryViewController {
    /// The counters and the drawer, when the change touched what they show: counts, headers, the podcasts or their order,
    /// the queue, or (in the most-recent-episode order) episode dates. Proportional to the podcasts, never to episodes.
    func refreshNavigationCounters(_ delta: LibraryMirrorDelta) {
        let dates = subscriptionDisplay.order == .mostRecentEpisode && !delta.episodes.isEmpty
        guard !delta.counts.isEmpty || !delta.headers.isEmpty || delta.feedOrder || !delta.feedStates.isEmpty || delta.queue || dates else { return }
        refreshNavigationCounters()
    }

    /// Whether Feed Information shows the same for two headers of one podcast: they differ at most in a refresh's
    /// bookkeeping (attempt times, the validator), which no part of the screen shows.
    nonisolated static func sameInformation(_ a: LibraryFeed, _ b: LibraryFeed) -> Bool {
        var left = a, right = b
        right.lastRefreshAttempt = left.lastRefreshAttempt
        right.localRefreshAttempt = left.localRefreshAttempt
        right.validator = left.validator
        right.serverRefresh?.lastAttempt = left.serverRefresh?.lastAttempt
        right.serverRefresh?.lastSuccess = left.serverRefresh?.lastSuccess
        left.episodes = []; right.episodes = []
        return left == right
    }

    // MARK: - Home

    /// Home after a patch: each section whose episodes, cards or badge changed is drawn again in place, the sections below
    /// move by its change of height; the others keep their views. Classics changes only with its own inputs.
    func patchHome(_ delta: LibraryMirrorDelta) {
        guard homeModel != nil || homeShowsWelcome else { render(); return }
        // Welcome and sections swap only as a whole screen.
        if HomeScreenModel.showsWelcome(mirror) != homeShowsWelcome { render(); return }
        guard !homeShowsWelcome else { return }
        homeModel?.apply(delta, mirror: mirror, now: Self.homeNow())
        redrawChangedHomeSections(delta)
    }

    /// The shuffle button: new picks at the current time, and Get surprised drawn again.
    func reseedHome(_ seed: Int32) {
        guard homeModel != nil else { render(); return }
        homeModel?.reseed(seed, mirror: mirror, now: Self.homeNow())
        redrawChangedHomeSections()
    }

    /// Home appears again (the scene returns to the foreground), after the changes made meanwhile are shown: its clock
    /// moves on and the picks are checked against it, and Classics loads, as Android's sections load on start.
    func homeAppearsAgain() {
        guard homeModel != nil, !homeShowsWelcome else { return }
        homeModel?.appear(mirror: mirror, now: Self.homeNow())
        redrawChangedHomeSections()
    }

    /// `delta`: the patch whose named rows are judged by the rows' rule (none for the shuffle or a return).
    private func redrawChangedHomeSections(_ delta: LibraryMirrorDelta = LibraryMirrorDelta()) {
        // Home's rows follow the lists' repaint rule as well (a queue indicator, a podcast's title). An episode can have a
        // row in two sections (Inbox and Downloads) sharing one paint record, so every section is judged against the
        // record from before this patch, before any is drawn again.
        let stale = homeSections.map { state in
            [.inbox, .downloads].contains(state.section) && state.shown.rows.contains { patchNames($0.1.id, in: delta) && rowIsStale($0.1.id) }
        }
        var shift: CGFloat = 0
        for index in homeSections.indices {
            let state = homeSections[index]
            let now = homeContent(state.section)
            // A position save keeps the section's views: its cards show their progress in place, and its rows were
            // shown it in place by the patch; a row whose progress line came or went takes its new height, and what
            // follows it moves.
            if !stale[index], now == state.shown || now.differsOnlyInPlayback(from: state.shown) {
                if shift != 0 { state.views.forEach { $0.frame.origin.y += shift } }
                homeSections[index].shown = now
                homeSections[index].top += shift
                if now != state.shown {
                    showHomePlayback(state)
                    let grown = fitHomeRows(state.views)
                    homeSections[index].height += grown
                    shift += grown
                }
                continue
            }
            // A strip keeps the person's place: its first visible card, or the nearest one that stays.
            let anchor = Self.stripAnchor(state)
            forgetHomeViews(state.views)
            state.views.forEach { $0.removeFromSuperview() }
            let rebuilt = buildHomeSection(state.section, top: state.top + shift)
            if let anchor { Self.restoreStripAnchor(anchor, in: rebuilt) }
            shift += rebuilt.height - state.height
            homeSections[index] = rebuilt
        }
        if let last = homeSections.last { content.contentSize.height = max(content.bounds.height, last.top + last.height + 12) }
        updateDownloadRows()
    }

    /// A strip's reading place: its cards' identities in order (episodes, or Classics' podcasts), the first visible card from the reading edge (left, or
    /// right in right-to-left) and its distance from that edge.
    struct StripAnchor { let ids: [Int64]; let index: Int; let distance: CGFloat }

    static func stripAnchor(_ state: HomeSectionState) -> StripAnchor? {
        guard let strip = state.views.lazy.compactMap({ $0 as? HomeStrip }).first else { return nil }
        let ids = state.stripIDs
        let rtl = strip.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let visible = strip.bounds
        let cards = strip.itemViews.enumerated().filter { $0.offset < ids.count && $0.element.frame.intersects(visible) }
        guard let first = rtl ? cards.max(by: { $0.element.frame.maxX < $1.element.frame.maxX }) : cards.min(by: { $0.element.frame.minX < $1.element.frame.minX })
        else { return nil }
        let distance = rtl ? visible.maxX - first.element.frame.maxX : first.element.frame.minX - visible.minX
        return StripAnchor(ids: ids, index: first.offset, distance: distance)
    }

    /// Puts the anchored card (or the nearest one that stays: later, then earlier) back at its distance from the reading
    /// edge, within the strip.
    static func restoreStripAnchor(_ anchor: StripAnchor, in state: HomeSectionState) {
        guard let strip = state.views.lazy.compactMap({ $0 as? HomeStrip }).first else { return }
        strip.layoutIfNeeded()
        let ids = state.stripIDs
        let candidates = [anchor.ids[anchor.index]] + anchor.ids[(anchor.index + 1)...] + anchor.ids[..<anchor.index].reversed()
        guard let index = candidates.lazy.compactMap({ ids.firstIndex(of: $0) }).first, strip.itemViews.indices.contains(index) else { return }
        let frame = strip.itemViews[index].frame
        let rtl = strip.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let x = rtl ? frame.maxX + anchor.distance - strip.bounds.width : frame.minX - anchor.distance
        strip.contentOffset.x = min(max(0, x), max(0, strip.contentSize.width - strip.bounds.width))
    }

    /// Each row of a Home section takes the height it needs (a playback change can add or remove its progress line), the
    /// section's views below it moving with it; returns the section's change of height.
    private func fitHomeRows(_ views: [UIView]) -> CGFloat {
        var grown: CGFloat = 0
        for row in views.compactMap({ $0 as? EpisodeRowView }).sorted(by: { $0.frame.minY < $1.frame.minY }) {
            let delta = row.sizeThatFits(CGSize(width: row.bounds.width, height: .greatestFiniteMagnitude)).height - row.frame.height
            guard abs(delta) >= 0.5 else { continue }
            let bottom = row.frame.maxY
            row.frame.size.height += delta
            for view in views where view !== row && view.frame.minY >= bottom - 0.5 { view.frame.origin.y += delta }
            grown += delta
        }
        return grown
    }

    /// A section's cards show their episodes' playback in place (`HorizontalItemViewHolder.bind` of the same holder),
    /// with the player's live position over the stored one, as the action model holds it.
    private func showHomePlayback(_ state: HomeSectionState) {
        guard let strip = state.views.lazy.compactMap({ $0 as? HomeStrip }).first else { return }
        for case let card as HomeEpisodeCard in strip.itemViews {
            guard let episode = card.actionModel?.snapshot().episode ?? libraryEpisode(card.episodeID)?.episode else { continue }
            card.showPlayback(of: episode)
        }
    }

    /// The rows and cards of views that leave. An episode's row in another section stays, with its own registration.
    private func forgetHomeViews(_ views: [UIView]) {
        let leaving = Set(views.map(ObjectIdentifier.init))
        func inside(_ view: UIView) -> Bool {
            var current: UIView? = view
            while let candidate = current { if leaving.contains(ObjectIdentifier(candidate)) { return true }; current = candidate.superview }
            return false
        }
        homeCards.removeAll { inside($0.1) }
        homeRows.removeAll { inside($0.row) }
        for (id, value) in episodeRows where inside(value.1) {
            episodeRows[id] = homeRows.first { $0.episode.id == id }.map { ($0.episode, $0.row) }
        }
    }

    // MARK: - Subscriptions, Archive

    /// Subscriptions or Archive after a patch, when their inputs changed (counts, headers, the podcasts, their order or
    /// newest dates): the order is computed again over the podcasts, tiles move to their new slots, only tiles whose
    /// title, cover, counter or refresh failure changed are built again. The chips, the filter bar, an empty grid and a
    /// shrinking selection draw the screen again (rare).
    func patchSubscriptions(_ delta: LibraryMirrorDelta) {
        // The navigation counters follow their own inputs (the queue among them), whether or not a tile changed.
        refreshNavigationCounters(delta)
        let preferences = subscriptionDisplay
        let dates = preferences.order == .mostRecentEpisode && !delta.episodes.isEmpty
        guard !delta.counts.isEmpty || !delta.headers.isEmpty || delta.feedOrder || !delta.feedStates.isEmpty || dates else { return }
        let archived: Bool = if case .archive = path.last { true } else { false }
        let state: FeedSubscriptionState = archived ? .archived : .subscribed
        let result = subscriptionList(preferences, state: state)
        let chips = SubscriptionTagChips.chips(feeds, state: state)
        let shown = SubscriptionTagChips.shown(selected: subscriptionTag(archived: archived), in: result)
        guard let grid = subscriptionGrid, let geometry = subscriptionGridGeometry, !shown.feeds.isEmpty,
              chips == subscriptionChips, FeedTags.equal(shown.tag, geometry.tag), geometry.filtered == preferences.filter.isEnabled,
              !(subscriptionSelection.active && subscriptionSelectionArchive == archived && shown.feeds.count < subscriptionSelectionIDs.count)
        else { render(); return }
        let ids = shown.feeds.map(\.id)
        var rebuilt: [Int64] = []
        var tiles: [Int64: (feed: LibraryFeed, counter: Int)] = [:]
        for feed in shown.feeds where tiles[feed.id] == nil {
            let counter = result.counters[feed.id, default: 0]
            tiles[feed.id] = (feed, counter)
            if let old = subscriptionTiles[feed.id], SubscriptionTileFace(old.feed, counter: old.counter) != SubscriptionTileFace(feed, counter: counter) {
                rebuilt.append(feed.id)
            }
        }
        subscriptionTiles = tiles
        subscriptionSelectionIDs = ids
        grid.setGrid(ids, frames: ids.indices.map { geometry.layout.slot($0, rowHeight: geometry.rowHeight, top: geometry.top, rightToLeft: geometry.rightToLeft) },
                     in: content)
        for id in rebuilt { grid.rebuild(id, in: content) }
        let scale = max(1, traitCollection.displayScale)
        let bottom = geometry.selecting ? max(88, subscriptionSelectionBar.preferredHeight) : 88
        content.contentSize.height = max(content.bounds.height,
            ceil((geometry.top + geometry.layout.height(count: ids.count, rowHeight: geometry.rowHeight) + bottom) * scale) / scale)
        grid.update(in: content)
        if subscriptionSelection.active { updateSubscriptionSelection() }
    }

    // MARK: - Search

    /// The search after a patch: its matches follow the changed episodes and podcasts (never a new scan), and the results
    /// patch their rows: rows that leave or join move, and a built row is painted again by the lists' rule
    /// (`rowIsStale`: its episode, queue membership or podcast header differs from what it was painted from).
    func patchSearch(_ search: LibrarySearchView, _ delta: LibraryMirrorDelta) {
        let old = search.session.patch(delta, mirror: mirror).previous
        search.patchResults(from: old) { [weak self] id in
            guard let self else { return false }
            return patchNames(id, in: delta) && rowIsStale(id)
        }
    }

    // MARK: - Episode pages

    /// An episode's pager after a patch: the resident pages whose episode or podcast changed show it. The visible page's
    /// episode gone closes the screen, as a full read would.
    func patchEpisodePages(_ delta: LibraryMirrorDelta) {
        guard case .episode(_, let id) = path.last, episodeDetailsID == id, libraryEpisode(id) != nil, let pager = visibleEpisodePager else {
            retireActionPresentation(); render(); return
        }
        if pager.pages.values.contains(where: { delta.episodes[$0.episodeID] != nil || delta.headers.contains($0.feedID) || delta.targets.contains($0.episodeID) }) {
            updateEpisodeHeader()
        }
        // A resident page whose episode a commit changed shows its stored notes again, read by key (Android's ItemFragment
        // reloads on the episode's FeedItemEvent); notes that did not change keep their document and reading position.
        let changed = delta.textChanged
        for page in pager.pages.values where changed.contains(page.episodeID) {
            guard let (feed, episode) = libraryEpisode(page.episodeID), feed.id == page.feedID else { continue }
            page.notes.show(detailedEpisode(episode))
        }
    }

    // MARK: - Re-appearance

    /// The scene returns to the foreground with a screen shown: Statistics, Feed Information statistics and Classics load
    /// again, as Android's fragments do in onStart.
    /// They load against the library after the catch-up the same return starts (what changed in the background), which
    /// they wait for.
    func screensAppearAgain() {
        let receipt = library?.changes.emitted
        let catchUp = screenUpdater
        Task { [weak self] in
            if let catchUp, let receipt { _ = await catchUp.settle(receipt: receipt) }
            guard let self else { return }
            if statisticsActive, statisticsVisible { refreshSubscriptionStatistics() }
            if case .feedInformation = path.last { feedInformation?.refreshStatistics() }
            if case .destination(.home) = path.last { homeAppearsAgain() }
        }
    }
}
