import Foundation

/// Episode-list coordinates, excluding the independently collapsing feed header.
/// The pinned LinearLayoutManager retains the adapter index and top offset on
/// notifyDataSetChanged, even with stable IDs.
public struct EpisodeListScrollPosition: Equatable, Sendable {
    public var firstVisibleIndex: Int
    public var topOffset: CGFloat

    public init(firstVisibleIndex: Int, topOffset: CGFloat) {
        self.firstVisibleIndex = firstVisibleIndex
        self.topOffset = topOffset
    }

    public func contentOffset(rowHeights: [CGFloat], viewportHeight: CGFloat) -> CGFloat {
        guard rowHeights.indices.contains(firstVisibleIndex) else { return 0 }
        let requested = rowHeights.prefix(firstVisibleIndex).reduce(0, +) - topOffset
        let maximum = max(0, rowHeights.reduce(0, +) - viewportHeight)
        return min(maximum, max(0, requested))
    }
}
