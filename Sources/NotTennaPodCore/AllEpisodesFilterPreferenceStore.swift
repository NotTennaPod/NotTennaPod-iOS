import Foundation

/// AllEpisodesFragment adds every subscription state when favorites are selected.
/// The stored tokens remain unchanged; per-feed filtering has a different scope.
public struct AllEpisodesFilter: Equatable, Sendable {
    public let stored: FeedEpisodeFilter
    public init(_ stored: FeedEpisodeFilter = .init()) { self.stored = stored }
    public var effective: FeedEpisodeFilter {
        guard stored.values.contains("is_favorite") else { return stored }
        return .init(values: stored.values + ["include_subscribed", "include_archived", "include_not_subscribed"])
    }
    public func includes(_ episode: LibraryEpisode, subscription: FeedSubscriptionState, queued: Bool) -> Bool {
        let filter = effective, tokens = Set(filter.values)
        let states: [(FeedSubscriptionState, String)] = [(.subscribed, "include_subscribed"),
            (.archived, "include_archived"), (.notSubscribed, "include_not_subscribed")]
        let explicit = states.filter { tokens.contains($0.1) }.map(\.0)
        guard (explicit.isEmpty ? [.subscribed] : explicit).contains(subscription) else { return false }
        return filter.includes(episode, queued: queued)
    }
}

@MainActor public final class AllEpisodesFilterPreferenceStore {
    public private(set) var value: AllEpisodesFilter
    private let file: URL
    public init(file: URL) throws {
        self.file = file
        let raw = try SavedState.contents(of: file).map { try JSONDecoder().decode(String.self, from: $0) } ?? ""
        value = .init(.init(values: [raw]))
    }
    /// Publish only after atomic replacement succeeds, like other preference owners.
    public func update(_ filter: FeedEpisodeFilter) throws {
        try JSONEncoder().encode(filter.values.joined(separator: ",")).write(to: file, options: .atomic)
        value = .init(filter)
    }
}

/// The source sheet writes on every toggle. Confirm/outside dismissal do not
/// commit or revert a draft. Opening it restores the same visible six groups.
@MainActor public final class AllEpisodesFilterEditor {
    public enum Event { case changed, saved, failed(any Error) }
    public private(set) var selection: FeedFilterSelection
    public var onEvent: ((Event) -> Void)?
    private let store: AllEpisodesFilterPreferenceStore
    private let initial: FeedEpisodeFilter
    private var restorationPending = true
    public init(store: AllEpisodesFilterPreferenceStore) {
        self.store = store; initial = store.value.effective
        selection = .init(initial)
    }
    public func restoreVisibleOptions() {
        guard restorationPending else { return }
        restorationPending = false
        if selection.filter.isActive && Set(initial.values) != Set(selection.filter.values) { persist() }
    }
    public func toggle(group: FeedFilterGroup, index: Int) {
        restorationPending = false; selection.toggle(group: group, index: index); persist()
    }
    public func reset() { restorationPending = false; selection.reset(); persist() }
    private func persist() {
        do { try store.update(selection.filter); onEvent?(.changed); onEvent?(.saved) }
        catch { selection = .init(store.value.effective); onEvent?(.changed); onEvent?(.failed(error)) }
    }
}
