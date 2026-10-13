import Foundation

/// One page of the episode details pager: the episode and the feed it belongs to.
public struct EpisodePagerItem: Hashable, Sendable {
    public let feedID: Int64
    public let episodeID: Int64
    public init(feedID: Int64, episodeID: Int64) { self.feedID = feedID; self.episodeID = episodeID }
}

/// Source `ItemPagerFragment`.
///
/// The pager is seeded with the caller's displayed rows, copied at tap time (`newInstance(List, FeedItem)`), and
/// never changes them afterwards. Navigation follows ViewPager2: one page per step, clamped at both ends, with
/// the neighbouring pages resident (`setOffscreenPageLimit(1)`) and a mirrored layout in right-to-left.
public struct EpisodePagerModel: Equatable, Sendable {
    public enum Step: Equatable, Sendable { case next, previous }
    /// The direction the finger moves across the screen.
    public enum Drag: Equatable, Sendable { case left, right }

    public let items: [EpisodePagerItem]
    public private(set) var index: Int

    /// `newInstance(allItems, currentItem)`: the loop has no `break`, so the last row with the tapped id wins, and an
    /// absent id opens page 0; `Math.max(0, pos)` guards negatives. An empty list keeps the tapped episode as one page.
    public init(items: [EpisodePagerItem], tapped: EpisodePagerItem) {
        guard !items.isEmpty else { self.items = [tapped]; index = 0; return }
        self.items = items
        index = max(0, items.lastIndex { $0.episodeID == tapped.episodeID } ?? 0)
    }

    /// `newInstance(long itemId)`: a single page.
    public init(single item: EpisodePagerItem) { items = [item]; index = 0 }

    public var count: Int { items.count }
    public var visible: EpisodePagerItem { items[index] }
    /// The visible page and its neighbours (offscreen page limit 1), in list order.
    public var residentIndices: ClosedRange<Int> { max(0, index - 1)...min(count - 1, index + 1) }

    /// One page forward or back; at either end nothing moves. Returns whether the page changed.
    @discardableResult
    public mutating func step(_ step: Step) -> Bool {
        select(step == .next ? index + 1 : index - 1)
    }

    /// A settled page; indices outside the list do not move the pager.
    @discardableResult
    public mutating func select(_ target: Int) -> Bool {
        guard items.indices.contains(target), target != index else { return false }
        index = target
        return true
    }

    /// ViewPager2 mirrors its layout in right-to-left, so the next episode lies on the left there.
    public static func step(for drag: Drag, rightToLeft: Bool) -> Step {
        switch drag {
        case .left: rightToLeft ? .previous : .next
        case .right: rightToLeft ? .next : .previous
        }
    }

    @discardableResult
    public mutating func drag(_ drag: Drag, rightToLeft: Bool) -> Bool {
        step(Self.step(for: drag, rightToLeft: rightToLeft))
    }

    /// The page's horizontal slot from the left edge: list order in left-to-right, mirrored in right-to-left.
    public func visualSlot(of page: Int, rightToLeft: Bool) -> Int { rightToLeft ? count - 1 - page : page }
    public func page(atVisualSlot slot: Int, rightToLeft: Bool) -> Int {
        min(max(0, rightToLeft ? count - 1 - slot : slot), count - 1)
    }
}
