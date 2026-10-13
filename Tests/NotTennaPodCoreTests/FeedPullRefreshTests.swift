import Testing
@testable import NotTennaPodCore

struct FeedPullRefreshTests {
    @Test func consumesStoredScrollBeforePullAndReversalCancelsThreshold() {
        var pull = FeedPullRefresh(triggerDistance: 100)
        pull.begin(translation: 8, scrollOffset: 200)
        pull.move(translation: 108)
        #expect(pull.distance == 0)
        pull.move(translation: 308)
        #expect(pull.distance == 100 && !pull.shouldRefresh)
        pull.move(translation: 309)
        #expect(pull.shouldRefresh)
        pull.move(translation: 230)
        #expect(pull.distance == 22 && !pull.shouldRefresh)
        pull.move(translation: -100)
        #expect(pull.distance == 0)
        pull.begin(translation: 0, scrollOffset: -12)
        pull.move(translation: 101)
        #expect(pull.shouldRefresh)
    }
    /// The indicator slides down with the finger, draws its arc, becomes opaque with its arrow at
    /// the trigger distance and stops at a maximum offset, like Android's (within 1 pt / 2 %).
    @Test func sourceSlingshotGeometryAtIndependentCheckpoints() {
        func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= tolerance }
        var pull = FeedPullRefresh(triggerDistance: 100)
        pull.begin(translation: 0, scrollOffset: 0)
        #expect(near(pull.geometry.offset, -40, 1) && near(pull.geometry.endTrim, 0, 0.02))
        pull.move(translation: 50)
        #expect(near(pull.geometry.offset, -8, 1) && near(pull.geometry.endTrim, 2.0 / 15, 0.02))
        #expect(near(pull.geometry.opacity, 76.0 / 255, 0.02))
        pull.move(translation: 100)
        #expect(near(pull.geometry.offset, 24, 1) && near(pull.geometry.endTrim, 0.8, 0.02))
        #expect(near(pull.geometry.rotation, 0.075, 0.02))
        #expect(pull.geometry.arrowScale == 1 && near(pull.geometry.opacity, 1, 0.02))
        pull.move(translation: 164)
        #expect(near(pull.geometry.offset, 72, 1))
        pull.move(translation: 228)
        #expect(near(pull.geometry.offset, 88, 1))
        pull.move(translation: 10000)
        #expect(near(pull.geometry.offset, 88, 1))
    }
}

/// The refresh spinner's arc grows and shrinks each lap and never jumps at a lap boundary
/// (within 2 % of a turn).
struct FeedRefreshSpinnerTests {
    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 0.02 }
    @Test func normalLapsGrowShrinkAndContinueAcrossBoundary() {
        let spinner = FeedRefreshSpinner()
        let first = spinner.frame(at: 0)
        #expect(near(first.end - first.start, 0.01))
        #expect(first.arrowScale == 0)
        let grown = spinner.frame(at: 0.665999)
        #expect(near(grown.end - grown.start, 0.8))
        let shrunk = spinner.frame(at: 1.331999)
        #expect(near(shrunk.end - shrunk.start, 0.01))
        let next = spinner.frame(at: 1.332)
        #expect(near(next.start, shrunk.start) && near(next.end, shrunk.end))
        #expect(near(next.start, 1.59))
    }
    @Test func releaseFinishesPulledArcBeforeOrdinaryLaps() {
        var pull = FeedPullRefresh(triggerDistance: 100)
        pull.begin(translation: 0, scrollOffset: 0); pull.move(translation: 100)
        let spinner = FeedRefreshSpinner(finishing: pull.geometry)
        let first = spinner.frame(at: 0), halfway = spinner.frame(at: 0.333)
        #expect(near(first.start, 0.075) && near(first.end, 0.875))
        #expect(first.arrowScale == 1 && halfway.arrowScale == 1)
        #expect(near(halfway.end - halfway.start, 0.405))
        let finished = spinner.frame(at: 0.666)
        #expect(finished.arrowScale == 0)
        #expect(near(finished.end - finished.start, 0.01))
        #expect(near(finished.start, 1.79))
    }
}
