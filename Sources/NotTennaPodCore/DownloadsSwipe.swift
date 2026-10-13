import Foundation

/// CompletedDownloadsFragment's picker and physical (not leading/trailing) directions.
public enum DownloadsSwipeAction: String, Codable, CaseIterable, Sendable {
    case queue = "ADD_TO_QUEUE", delete = "DELETE", favorite = "MARK_FAV", played = "MARK_PLAYED"
    public var titleKey: String {
        switch self { case .queue: "add_to_queue_label"; case .delete: "delete_label"
        case .favorite: "add_to_favorite_label"; case .played: "toggle_played_label" }
    }
    public var icon: String {
        switch self { case .queue: "ic_playlist_play"; case .delete: "ic_delete"
        case .favorite: "ic_star"; case .played: "ic_mark_played" }
    }
    public func action(for item: EpisodeListItem) -> EpisodeListAction? {
        switch self {
        case .queue: item.queued ? .removeQueue : item.episode.details.media == nil ? nil : .addQueue
        case .favorite: item.episode.userState.isFavorite ? .removeFavorite : .addFavorite
        // Source maps New to Unplayed too; it is not a Boolean inversion of Played.
        case .played: item.episode.userState.playState == .unplayed ? .markPlayed : .markUnplayed
        // Unlike context Delete, swiping an active remote download does not cancel it.
        case .delete: item.local || item.episode.userState.isDownloaded ? .delete : nil
        }
    }
    public func removesFromDownloads(_ item: EpisodeListItem) -> Bool {
        self == .delete && (item.local || item.episode.userState.isDownloaded)
    }
}

public enum EpisodeSwipeDirection: String, Sendable { case left, right }
public struct DownloadsSwipePreferences: Codable, Equatable, Sendable {
    public var enabled = true
    public var left: DownloadsSwipeAction = .delete
    public var right: DownloadsSwipeAction = .delete
    public init() {}
    public func action(_ direction: EpisodeSwipeDirection) -> DownloadsSwipeAction { direction == .left ? left : right }
}

/// SwipeActions.onChildDraw and ItemTouchHelper's distance/velocity release rules.
public struct EpisodeSwipeMotion: Equatable, Sendable {
    public let displacement: Double
    public let reached: Bool
    public let direction: EpisodeSwipeDirection
    public init(translation: Double, width: Double, removes: Bool) {
        direction = translation > 0 ? .right : .left
        guard width > 0, width.isFinite, translation.isFinite else { displacement = 0; reached = false; return }
        if removes { displacement = translation; reached = abs(translation) >= width * 0.5 }
        else {
            let limit = max(1, floor(width * 2 / 5))
            let fraction = min(1, abs(translation) / limit)
            displacement = (translation > 0 ? 1 : -1) * limit * 0.7 * sin(.pi / 2 * fraction)
            reached = fraction >= 0.85
        }
    }
    public func commits(velocityX: Double, velocityY: Double, removes: Bool, cancelled: Bool = false) -> Bool {
        guard !cancelled else { return false }
        if reached { return true }
        guard removes, displacement != 0, velocityX.isFinite, velocityY.isFinite else { return false }
        // RecyclerView1.4.0:120dp/s escape,800dp/s cap; source multiplies1.5 and0.6.
        let x = min(abs(velocityX), 480), y = min(abs(velocityY), 480)
        return x >= 180 && x > y && (velocityX > 0) == (direction == .right)
    }
}
