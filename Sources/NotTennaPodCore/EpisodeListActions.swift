import Foundation

/// SearchFragment / FeedItemMenuHandler, independently of the episode pager menu.
public enum EpisodeListAction: String, CaseIterable, Sendable {
    case removeInbox, markPlayed, markUnplayed, addQueue, removeQueue, delete
    case addFavorite, removeFavorite, resetPosition, share, multiSelect, download

    public func titleKey(hasMedia: Bool = true) -> String {
        switch self {
        case .removeInbox: "remove_inbox_label"
        case .markPlayed: hasMedia ? "mark_as_played_label" : "mark_read_no_media_label"
        case .markUnplayed: hasMedia ? "mark_as_unplayed_label" : "mark_unread_label_no_media"
        case .addQueue: "add_to_queue_label"
        case .removeQueue: "remove_from_queue_label"
        case .delete: "delete_label"
        case .addFavorite: "add_to_favorite_label"
        case .removeFavorite: "remove_from_favorite_label"
        case .resetPosition: "reset_playback_position_label"
        case .share: "share_label"
        case .multiSelect: "multi_select"
        case .download: "download_label"
        }
    }
    public var icon: String {
        switch self {
        case .removeInbox: "ic_check"
        case .markPlayed: "ic_mark_played"
        case .markUnplayed: "ic_mark_unplayed"
        case .addQueue: "ic_playlist_play"
        case .removeQueue: "ic_playlist_remove"
        case .delete: "ic_delete"
        case .addFavorite: "ic_star"
        case .removeFavorite: "ic_star_border"
        case .resetPosition: "ic_replay"
        case .share: "ic_share"
        case .multiSelect: "ic_check"
        case .download: "ic_download"
        }
    }
    public var messageKey: String? {
        switch self {
        case .removeInbox: "removed_from_inbox_batch_label"
        case .markPlayed: "marked_as_played_message"
        case .markUnplayed: "marked_as_unplayed_message"
        case .addQueue: "added_to_queue_message"
        case .removeQueue: "removed_from_queue_message"
        case .delete: "deleted_episode_message"
        case .addFavorite: "added_to_favorites_message"
        case .removeFavorite: "removed_from_favorites_message"
        case .resetPosition: "reset_position_message"
        case .download: "downloading_episodes_message"
        default: nil
        }
    }
}

public struct EpisodeListItem: Sendable, Equatable {
    public let episode: LibraryEpisode
    public let local: Bool
    public let subscription: FeedSubscriptionState
    public let queued, downloading: Bool
    public init(episode: LibraryEpisode, local: Bool, subscription: FeedSubscriptionState = .subscribed,
                queued: Bool = false, downloading: Bool = false) {
        self.episode = episode; self.local = local; self.subscription = subscription
        self.queued = queued; self.downloading = downloading
    }
}

public enum EpisodeListMenu {
    /// Search and Queue explicitly hide this bulk action; the ordinary list
    /// menus retain it in their common XML position.
    public enum BulkInboxPolicy: Sendable, Equatable { case excluded, allowed }

    public static func actions(_ items: [EpisodeListItem], selection: Bool,
                               bulkInbox: BulkInboxPolicy = .excluded) -> [EpisodeListAction] {
        guard !items.isEmpty else { return [] }
        var available: Set<EpisodeListAction> = []
        for item in items {
            let state = item.episode.userState, media = item.episode.details.media != nil
            if state.playState == .new { available.insert(.removeInbox) }
            available.insert(state.playState == .played ? .markUnplayed : .markPlayed)
            if item.queued { available.insert(.removeQueue) }
            else if media { available.insert(.addQueue) }
            if item.local || media && state.isDownloaded || item.downloading { available.insert(.delete) }
            if media && !state.isDownloaded && !item.local && !item.downloading { available.insert(.download) }
            available.insert(state.isFavorite ? .removeFavorite : .addFavorite)
            if media && state.positionMilliseconds != 0 { available.insert(.resetPosition) }
            if !item.local { available.insert(.share) }
        }
        if items.count > 1 {
            available.remove(.share)
            if available.contains(.addFavorite) { available.remove(.removeFavorite) }
        } else if items[0].subscription == .notSubscribed { available.remove(.markPlayed) }
        let order: [EpisodeListAction]
        if selection {
            // FloatingSelectMenu iterates XML order. Its old speed-dial comment is stale.
            order = [.delete, .download, .markUnplayed, .markPlayed, .removeQueue, .addQueue,
                     .share, .removeInbox, .addFavorite, .removeFavorite, .resetPosition]
            if bulkInbox == .excluded { available.remove(.removeInbox) }
        } else {
            available.insert(.multiSelect)
            order = [.removeInbox, .markPlayed, .markUnplayed, .addQueue, .removeQueue, .delete,
                     .addFavorite, .removeFavorite, .resetPosition, .share, .multiSelect]
        }
        return order.filter(available.contains)
    }
}

/// IDs survive result replacement. Actions always follow the current display order.
public struct EpisodeListSelection: Sendable, Equatable {
    public private(set) var active = false
    public private(set) var ids: Set<Int64> = []
    public init() {}
    public mutating func start(_ id: Int64) { active = true; ids = [id] }
    public mutating func end() { active = false; ids.removeAll() }
    public mutating func toggle(_ id: Int64) {
        guard active else { return }
        if !ids.insert(id).inserted { ids.remove(id) }
        if ids.isEmpty { end() }
    }
    public mutating func toggleAll(displayed: [Int64]) {
        guard active else { return }
        let select = ids.count != displayed.count
        for id in displayed { if select { ids.insert(id) } else { ids.remove(id) } }
    }
    public mutating func above(displayed: [Int64]) {
        guard active else { return }
        ids.formUnion(displayed.prefix(displayed.firstIndex(where: ids.contains) ?? 0))
    }
    public mutating func below(displayed: [Int64]) {
        guard active, !displayed.isEmpty else { return }
        ids.formUnion(displayed.dropFirst((displayed.lastIndex(where: ids.contains) ?? 0) + 1))
    }
    public func selected(displayed: [Int64]) -> [Int64] { displayed.filter(ids.contains) }
}

/// Persistent actions and the selected app's I/O owners share the same dispatch.
/// The caller handles Share, selection, and the source local-file confirmation.
@MainActor public final class EpisodeListActionExecutor {
    private let store: FeedLibraryStore
    private let download, delete, reset: @MainActor (Int64) async throws -> Void
    public init(store: FeedLibraryStore, download: @escaping @MainActor (Int64) async throws -> Void,
                delete: @escaping @MainActor (Int64) async throws -> Void,
                reset: @escaping @MainActor (Int64) async throws -> Void) {
        self.store = store; self.download = download; self.delete = delete; self.reset = reset
    }
    @discardableResult public func perform(_ action: EpisodeListAction, items: [EpisodeListItem], resetPosition: Bool = true,
                                          selection: Bool = false) async throws -> Int {
        switch action {
        case .addQueue:
            let ids = items.filter { $0.episode.details.media != nil && !$0.queued }.map(\.episode.id)
            _ = try await store.enqueueUsingSettings(ids); return ids.count
        case .removeQueue:
            _ = try await store.removeFromQueue(items.map(\.episode.id)); return items.count
        case .markPlayed, .markUnplayed:
            // One transaction for the whole selection (a select-all of a long feed used one commit per row).
            try await store.markEpisodesPlayed(episodeIDs: items.map(\.episode.id), played: action == .markPlayed,
                                               resetPosition: resetPosition)
            return items.count
        case .removeInbox:
            // The single context handler writes UNPLAYED directly. The distinct
            // bulk handler touches only NEW members and counts those changes.
            let eligible = selection ? items.filter { $0.episode.userState.playState == .new } : items
            try await store.removeEpisodesFromInbox(episodeIDs: eligible.map(\.episode.id))
            return eligible.count
        case .addFavorite, .removeFavorite:
            let desired = action == .addFavorite
            try await store.setFavorite(episodeIDs: items.map(\.episode.id), favorite: desired)
            return items.filter { $0.episode.userState.isFavorite != desired }.count
        case .download:
            let eligible = items.filter { $0.episode.details.media != nil && !$0.episode.userState.isDownloaded && !$0.local }
            for item in eligible { try await download(item.episode.id) }
            return eligible.count
        case .delete:
            let eligible = items.filter { $0.episode.details.media != nil && ($0.local || $0.episode.userState.isDownloaded || $0.downloading) }
            for item in eligible { try await delete(item.episode.id) }
            return eligible.count
        case .resetPosition:
            let eligible = items.filter { $0.episode.details.media != nil && $0.episode.userState.positionMilliseconds != 0 }
            for item in eligible { try await reset(item.episode.id) }
            return eligible.count
        case .share, .multiSelect: throw FeedLibraryError.invalidMutation
        }
    }
}
