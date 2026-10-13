import CoreMedia
import Testing
@testable import NotTennaPodCore

struct PlaybackVideoTimelineTests {
    private func range(_ start: Int64, _ duration: Int64) -> CMTimeRange {
        CMTimeRange(start: CMTime(value: start, timescale: 1000), duration: CMTime(value: duration, timescale: 1000))
    }

    @Test func explicitSilenceCutAndSpeedChangePreserveSourceAnchors() throws {
        var map = try PlaybackVideoTimeline()
        try map.append(.init(source: range(0, 1000), presentation: range(0, 500)))
        try map.append(.init(source: range(1000, 2000), presentation: range(500, 0)))
        try map.append(.init(source: range(3000, 1000), presentation: range(500, 2000)))
        #expect(try map.sourceTime(at: CMTime(value: 250, timescale: 1000)) == CMTime(value: 500, timescale: 1000))
        #expect(try map.sourceTime(at: CMTime(value: 500, timescale: 1000)) == CMTime(value: 3000, timescale: 1000))
        #expect(try map.sourceTime(at: CMTime(value: 1500, timescale: 1000)) == CMTime(value: 3500, timescale: 1000))
        #expect(try map.presentationTime(at: CMTime(value: 2000, timescale: 1000)) == CMTime(value: 500, timescale: 1000))
        #expect(try map.presentationRanges(for: range(900, 2200)) == [range(450, 50), range(500, 200)])
        #expect(try map.presentationRanges(for: range(1100, 100)).isEmpty)
        #expect(try map.sourceTime(at: CMTime(value: 2500, timescale: 1000)) == CMTime(value: 4000, timescale: 1000))
    }
}
