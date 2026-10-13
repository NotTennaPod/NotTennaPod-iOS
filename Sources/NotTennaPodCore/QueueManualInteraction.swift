import Foundation
import CoreGraphics

/// Captures stable episode identity without rejecting legitimate progress/favorite updates.
public struct QueueEpisodeIdentity: Equatable, Sendable {
    public let id: Int64
    public let identifier: String?
    public let mediaURL: String?
    public let link: String?
    public init(_ episode: LibraryEpisode) {
        id = episode.id; identifier = episode.details.identifier
        mediaURL = episode.details.media?.url; link = episode.details.link
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && exactlyEqual(lhs.identifier, rhs.identifier) && exactlyEqual(lhs.mediaURL, rhs.mediaURL)
            && exactlyEqual(lhs.link, rhs.link)
    }

}

public enum QueueBoundary: String, Sendable { case top, bottom }
public enum QueueManualMove: Equatable, Sendable {
    case item(Int64, finalIndex: Int)
    case boundary([Int64], QueueBoundary)

    public func applying(to order: [Int64]) -> [Int64]? {
        guard Set(order).count == order.count else { return nil }
        switch self {
        case .item(let id, let target):
            guard let index = order.firstIndex(of: id), order.indices.contains(target) else { return nil }
            var result = order; result.remove(at: index); result.insert(id, at: target); return result
        case .boundary(let ids, let boundary):
            let selected = Set(ids)
            guard !selected.isEmpty, selected.count == ids.count, selected.isSubset(of: Set(order)) else { return nil }
            let moved = order.filter { selected.contains($0) }, remaining = order.filter { !selected.contains($0) }
            return boundary == .top ? moved + remaining : remaining + moved
        }
    }
}

public struct QueueInteractionPolicy: Equatable, Sendable {
    public var locked: Bool
    public var keepSorted: Bool
    public var selecting: Bool
    public init(locked: Bool = false, keepSorted: Bool = false, selecting: Bool = false) {
        self.locked = locked; self.keepSorted = keepSorted; self.selecting = selecting
    }
    public var showsHandle: Bool { !locked && !keepSorted }
    public var allowsDrag: Bool { showsHandle && !selecting }
    public var showsLockEntry: Bool { !keepSorted }
    public var showsInformation: Bool { !selecting }
    // Lock is scoped to manual drag/bulk movement, not ordinary menus or swipes.
    public func canMove(_ ids: [Int64], in order: [Int64], to boundary: QueueBoundary, bulk: Bool) -> Bool {
        guard !keepSorted, bulk ? (!locked && selecting) : !selecting,
              let moved = QueueManualMove.boundary(ids, boundary).applying(to: order) else { return false }
        return moved != order
    }
    public func startsDrag(at point: CGPoint, handle: CGRect, cover: CGRect, rightToLeft: Bool) -> Bool {
        guard allowsDrag else { return false }
        if handle.width > 0 && handle.contains(point) { return true }
        guard cover.contains(point) else { return false }
        return rightToLeft ? point.x > cover.midX : point.x < cover.midX
    }
}

public struct QueueDragSession: Sendable {
    public let snapshot: [QueueEpisodeIdentity]
    public let episodeID: Int64
    public private(set) var order: [Int64]
    public init?(episodes: [LibraryEpisode], episodeID: Int64, policy: QueueInteractionPolicy) {
        guard policy.allowsDrag, episodes.contains(where: { $0.id == episodeID }), Set(episodes.map(\.id)).count == episodes.count else { return nil }
        snapshot = episodes.map(QueueEpisodeIdentity.init); self.episodeID = episodeID; order = episodes.map(\.id)
    }
    public mutating func cross(_ targetID: Int64) {
        guard let target = order.firstIndex(of: targetID), let changed = QueueManualMove.item(episodeID, finalIndex: target).applying(to: order) else { return }
        order = changed
    }
    /// One delivered pointer sample can cross several rows. Choose the furthest crossed center.
    public mutating func cross(centerY: CGFloat, rowCenters: [Int64: CGFloat]) {
        guard let index = order.firstIndex(of: episodeID) else { return }
        let above = order.prefix(index).first { rowCenters[$0].map { centerY < $0 } ?? false }
        let below = order.dropFirst(index + 1).last { rowCenters[$0].map { centerY > $0 } ?? false }
        if let target = above ?? below { cross(target) }
    }
    public var move: QueueManualMove? {
        guard order != snapshot.map(\.id), let target = order.firstIndex(of: episodeID) else { return nil }
        return .item(episodeID, finalIndex: target)
    }
}

public struct QueueManualMoveResult: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case moved, unchanged, stale }
    public let status: Status
    public let change: LibraryQueueChange
    public init(status: Status, change: LibraryQueueChange) { self.status = status; self.change = change }
}
