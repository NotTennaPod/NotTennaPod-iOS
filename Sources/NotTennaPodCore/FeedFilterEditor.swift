import Foundation

/// Changes apply immediately, in tap order, and survive dismissal. Confirm is
/// only a close action. A rejected latest write restores the stored selection.
@MainActor
public final class FeedFilterEditor {
    public enum Event { case changed, saved(LibraryFeed), failed(any Error) }
    public private(set) var selection: FeedFilterSelection
    public var onEvent: ((Event) -> Void)?
    private let store: FeedLibraryStore
    private let feedID: Int64
    private let initialFilter: FeedEpisodeFilter
    private var restorationPending = true
    private var revision = UUID()
    private var pending: Task<Void, Never>?

    public init(feed: LibraryFeed, store: FeedLibraryStore) {
        initialFilter = feed.episodeFilter
        selection = FeedFilterSelection(initialFilter); feedID = feed.id; self.store = store
    }
    /// Checking restored buttons invokes the source listeners. If legacy values
    /// conflict or include hidden options, opening the sheet saves the visible
    /// normalized selection. Unknown-only values cause no checked-button event.
    public func restoreVisibleOptions() {
        guard restorationPending else { return }
        restorationPending = false
        if selection.filter.isActive && Set(initialFilter.values) != Set(selection.filter.values) { persist() }
    }
    public func toggle(group: FeedFilterGroup, index: Int) {
        restorationPending = false
        selection.toggle(group: group, index: index); persist()
    }
    public func reset() { restorationPending = false; selection.reset(); persist() }
    public func waitForPendingChanges() async { await pending?.value }
    private func persist() {
        let request = UUID(), previous = pending, filter = selection.filter
        revision = request
        // Deliberately retains its owner until the accepted write finishes;
        // leaving the sheet must not cancel a change already made by the user.
        pending = Task { [self] in
            await previous?.value
            do {
                try await store.setEpisodeFilter(feedID: feedID, filter: filter)
                if let feed = try await store.feed(id: feedID) { onEvent?(.saved(feed)) }
            } catch {
                if let feed = try? await store.feed(id: feedID), revision == request {
                    selection = FeedFilterSelection(feed.episodeFilter); onEvent?(.changed)
                }
                onEvent?(.failed(error))
            }
        }
        onEvent?(.changed)
    }
}
