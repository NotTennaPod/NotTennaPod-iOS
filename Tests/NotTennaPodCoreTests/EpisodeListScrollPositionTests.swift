import Foundation
import Testing
@testable import NotTennaPodCore

struct EpisodeListScrollPositionTests {
    @Test func matchesAllCapturedRecyclerViewRefreshLayouts() throws {
        struct Row: Decodable { let id: Int64, height: Double }
        struct State: Decodable { let height: Double, first: Int, offset: Double, rows: [Row] }
        struct Case: Decodable { let change: String, requestedPosition: Int, requestedOffset: Int, before: State, after: State }
        let url = try #require(Bundle.module.url(forResource: "recycler-scroll-runtime", withExtension: "json", subdirectory: "Fixtures"))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        #expect(cases.count == 96)
        for item in cases {
            let actual = item.after.first < 0 ? 0 : item.after.rows.prefix(item.after.first).reduce(0) { $0 + $1.height } - item.after.offset
            let position = EpisodeListScrollPosition(firstVisibleIndex: item.before.first, topOffset: CGFloat(item.before.offset))
            let heights = item.after.rows.map { CGFloat($0.height) }
            // The same rows stay in view after a refresh (within one point).
            #expect(abs(position.contentOffset(rowHeights: heights, viewportHeight: CGFloat(item.after.height)) - CGFloat(actual)) <= 1,
                    "\(item.change), requested \(item.requestedPosition)/\(item.requestedOffset)")
        }
    }

    @Test func fractionalMeasurementsKeepIndexOffsetAndClampToNewBounds() {
        let anchor = EpisodeListScrollPosition(firstVisibleIndex: 2, topOffset: -2.25)
        #expect(anchor.contentOffset(rowHeights: [30.5, 40.25, 50, 60], viewportHeight: 80) == 73)
        #expect(anchor.contentOffset(rowHeights: [30.5, 40.25, 50, 60], viewportHeight: 130) == 50.75)
        #expect(anchor.contentOffset(rowHeights: [30.5], viewportHeight: 20) == 0)
        #expect(anchor.contentOffset(rowHeights: [], viewportHeight: 80) == 0)
        #expect(EpisodeListScrollPosition(firstVisibleIndex: -1, topOffset: 0)
            .contentOffset(rowHeights: [50], viewportHeight: 20) == 0)
    }
}
