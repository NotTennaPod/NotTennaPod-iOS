import UIKit
import NotTennaPodCore

/// Source `ItemPagerFragment`: the ids and index of one episode-details stack entry and its resident pages.
@MainActor final class EpisodePagerState {
    var model: EpisodePagerModel
    let view = EpisodePagerView()
    var pages: [Int: LibraryViewController.EpisodePage] = [:]
    /// Where the neighbours released while the pager was hidden were read (their header and notes reopen there).
    var releasedReading: [Int: (episodeID: Int64, header: CGFloat, notes: CGFloat)] = [:]
    /// Header positions of rebuilt neighbours, applied after their first layout.
    var restoredHeaderOffsets: [Int: CGFloat] = [:]
    init(model: EpisodePagerModel) { self.model = model }
}

// Episode details pager.
extension LibraryViewController {
    /// Every episode tap in a list (`EpisodeItemListAdapter`, `HorizontalItemListAdapter`): the pager receives the rows
    /// the list displays at that moment, in their order, and opens directly on the tapped row.
    func openEpisode(feedID: Int64, episodeID: Int64, list: [EpisodePagerItem]) {
        let state = EpisodePagerState(model: EpisodePagerModel(items: list, tapped: .init(feedID: feedID, episodeID: episodeID)))
        episodePagers[path.count] = state
        push(.episode(state.model.visible.feedID, state.model.visible.episodeID))
    }

    /// The pager of the current episode screen.
    var visibleEpisodePager: EpisodePagerState? {
        guard case .episode(let feedID, let episodeID) = path.last, let pager = episodePagers[path.count - 1],
              pager.model.visible == EpisodePagerItem(feedID: feedID, episodeID: episodeID) else { return nil }
        return pager
    }

    /// The toolbar menu belongs to the pager and acts on the visible page only: not while a swipe is under way and
    /// never on a page that is no longer the one shown (Android's stale-menu window is not copied).
    func episodePagerSettled(on episodeID: Int64) -> Bool {
        guard case .episode(_, let visible) = path.last, visible == episodeID else { return false }
        return visibleEpisodePager?.view.isMoving != true
    }

    /// Source `ItemFragment.load` closes the screen when its episode no longer exists. Only the visible page does
    /// that here: a missing neighbour stays a blank page (Android's neighbour pop is not copied).
    func closeMissingEpisodePager() {
        guard libraryLoaded, path.count > 1, case .episode(let feedID, let episodeID) = path.last,
              libraryEpisode(episodeID)?.feed.id != feedID else { return }
        popup?.removeFromSuperview(); popup = nil
        popToParent()
    }

    /// Called by `render()` for the visible page of the current episode screen.
    func renderEpisodePager(_ feed: LibraryFeed, _ episode: LibraryEpisode) {
        let index = path.count - 1, item = EpisodePagerItem(feedID: feed.id, episodeID: episode.id)
        let state: EpisodePagerState
        if let existing = episodePagers[index], existing.model.visible == item { state = existing }
        else { state = EpisodePagerState(model: .init(single: item)); episodePagers[index] = state }
        connect(state)
        if state.view.superview !== content { content.addSubview(state.view) }
        if state.view.frame != content.bounds { state.view.frame = content.bounds }
        updateResidentPages(state, around: state.model.index)
        if let page = state.pages[state.model.index] {
            episodeHeader = page.header; episodeHeaderScroll = page.headerScroll
            episodeNotes = page.notes; episodeDetailsID = page.episodeID
        }
        updateEpisodeHeader()
    }

    private func connect(_ state: EpisodePagerState) {
        state.view.onCenteredPageChanged = { [weak self, weak state] centered in
            guard let self, let state, visibleEpisodePager === state else { return }
            // Preload around the page being swiped to, so a burst of swipes never reveals an empty page.
            updateResidentPages(state, around: centered)
            layoutEpisodeDetails()
        }
        state.view.onScrollingChanged = { [weak self, weak state] moving in
            guard let self, let state, visibleEpisodePager === state else { return }
            if moving { popup?.removeFromSuperview(); popup = nil }
            for id in ["episodeWebsite", "episodeMore"] {
                (toolbar.subviews.first { $0.accessibilityIdentifier == id } as? UIControl)?.isEnabled = !moving
            }
        }
        state.view.onSettled = { [weak self, weak state] target in
            guard let self, let state, visibleEpisodePager === state, state.model.select(target) else { return }
            // One history entry for the whole pager: the visible page replaces the entry, swiping adds no Back step.
            path[path.count - 1] = .episode(state.model.visible.feedID, state.model.visible.episodeID)
            render()
        }
        state.view.accessibilityAnnouncement = { [weak self, weak state] page in
            guard let self, let item = state?.model.items[safe: page] else { return nil }
            return libraryEpisode(item.episodeID).flatMap { $0.feed.id == item.feedID ? $0.episode.details.title : nil }
        }
    }

    /// The visible page and its neighbours (`setOffscreenPageLimit(1)`) are built; pages outside that window are
    /// released and rebuilt when they come back, as ViewPager2 destroys and recreates them. While nobody can swipe
    /// (the expanded player covers the pager, or its scene is in the background) only the settled page is built.
    func updateResidentPages(_ state: EpisodePagerState, around center: Int) {
        let window: ClosedRange<Int>
        if !episodeContentCovered && !episodeSceneBackgrounded {
            window = max(0, center - 1)...min(state.model.count - 1, center + 1)
            for (index, page) in state.pages where !window.contains(index) && index != state.model.index {
                page.container.removeFromSuperview(); state.pages[index] = nil; state.restoredHeaderOffsets[index] = nil
            }
            state.releasedReading = state.releasedReading.filter { window.contains($0.key) }
        } else {
            releaseNeighbourPages(state)
            window = state.model.index...state.model.index
        }
        for index in window where state.pages[index] == nil {
            let item = state.model.items[index]
            guard let (feed, episode) = libraryEpisode(item.episodeID), feed.id == item.feedID else { continue }
            // The page shows the stored show notes and chapters (the screens' library holds list projections).
            let page = makeEpisodePage(feed, detailedEpisode(episode))
            if let reading = state.releasedReading.removeValue(forKey: index), reading.episodeID == episode.id {
                // Both regions reopen where they were read: the notes at their rendered readiness, the header
                // after the page's first layout, within what fits then (`layoutEpisodeDetails`).
                page.notes.restoreReadingOffset(reading.notes)
                state.restoredHeaderOffsets[index] = reading.header
            }
            state.pages[index] = page
        }
        state.view.update(count: state.model.count, settled: state.model.index,
            rightToLeft: view.effectiveUserInterfaceLayoutDirection == .rightToLeft,
            pages: state.pages.mapValues(\.container))
    }

    /// A pager nobody sees (another screen or the expanded player above it, or its scene in the background) keeps only
    /// its settled page, which Back or a return shows at once. Its neighbours' WebKit processes are released for iOS;
    /// they are built again, where their header and notes were read, when the pager can be seen again.
    func releaseEpisodeNeighbours(_ state: EpisodePagerState) {
        guard releaseNeighbourPages(state) else { return }
        state.view.update(count: state.model.count, settled: state.model.index, rightToLeft: state.view.rightToLeft,
            pages: state.pages.mapValues(\.container))
    }

    @discardableResult
    private func releaseNeighbourPages(_ state: EpisodePagerState) -> Bool {
        guard !state.view.isMoving else { return false }
        let neighbours = state.pages.filter { $0.key != state.model.index }
        guard !neighbours.isEmpty else { return false }
        for (index, page) in neighbours {
            state.releasedReading[index] = (page.episodeID, page.headerScroll.contentOffset.y, page.notes.readingOffset)
            state.restoredHeaderOffsets[index] = nil
            page.container.removeFromSuperview(); state.pages[index] = nil
        }
        return true
    }

    /// Pagers another screen covers release their neighbours at every screen change (`render`).
    func releaseHiddenEpisodeNeighbours() {
        let visible = episodeContentCovered ? nil : visibleEpisodePager
        for state in episodePagers.values where state !== visible { releaseEpisodeNeighbours(state) }
    }

    /// Whether the expanded player covers the content column, from the player's own state. Settings hides the player
    /// but keeps its expansion, so Back returns to episode details that are still covered. Only the sheet's settled
    /// positions count, so a drag that turns back changes nothing (nil keeps the current state).
    private var episodeContentCoverTarget: Bool? {
        guard let playerView, playback?.episode != nil else { return false }
        guard playerView.expansion == 0 || playerView.expansion == 1 else { return nil }
        return playerView.expansion == 1
    }

    /// Brings the owner's cover state, and every resident page's notes, up to date without changing which pages are
    /// built. `render` calls this before it attaches a pager, so nothing is shown, rebuilt or built behind the player.
    @discardableResult
    func syncEpisodeContentCover() -> Bool {
        guard let covered = episodeContentCoverTarget, covered != episodeContentCovered else { return false }
        episodeContentCovered = covered
        for state in episodePagers.values { state.pages.values.forEach { $0.notes.isCovered = covered } }
        return true
    }

    /// The expanded player covers episode details: their notes are not shown (uncovering them is a new visit) and
    /// the pager keeps only its settled page until the player collapses.
    func updateEpisodeDetailsCover() {
        guard syncEpisodeContentCover(), let state = visibleEpisodePager else { return }
        if episodeContentCovered { releaseEpisodeNeighbours(state) }
        else { updateResidentPages(state, around: state.model.index); layoutEpisodeDetails() }
    }

    @objc func episodeSceneDidEnterBackground(_ notification: Notification) {
        guard let scene = view.window?.windowScene, notification.object as? UIScene === scene else { return }
        episodeSceneBackgrounded = true
        episodePagers.values.forEach(releaseEpisodeNeighbours)
    }

    @objc func episodeSceneWillEnterForeground(_ notification: Notification) {
        guard let scene = view.window?.windowScene, notification.object as? UIScene === scene else { return }
        episodeSceneBackgrounded = false
        guard let state = visibleEpisodePager else { return }
        updateResidentPages(state, around: state.model.index)
        layoutEpisodeDetails()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
