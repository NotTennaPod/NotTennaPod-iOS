import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct MatroskaSeekPointTests {
    @Test func defaultSeekPointsMatchOriginalJava() throws {
        struct Point: Decodable { let timeMicroseconds, clusterOffset: Int64 }
        struct Cue: Decodable { let timeMicroseconds, clusterOffset, relativeOffset: Int64 }
        struct Case: Decodable {
            let durationMicroseconds, targetMicroseconds: Int64
            let primaryPresent: Bool
            let cues: [Cue]
            let first, second: Point
        }
        struct Oracle: Decodable { let cases: [Case] }
        let url = try #require(Bundle.module.url(forResource: "matroska-seek-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        try #require(oracle.cases.count == 11760)
        for (index, item) in oracle.cases.enumerated() {
            let cues = item.cues.map { MatroskaTimeline.Cue(timeMicroseconds: $0.timeMicroseconds,
                clusterOffset: $0.clusterOffset, relativeOffset: $0.relativeOffset) }
            let timeline = MatroskaTimeline(durationMicroseconds: item.durationMicroseconds, primaryTrack: 1,
                cues: [item.primaryPresent ? 1 : 2: cues], declaredCueOffset: nil)
            let actual = timeline.defaultSeekPoints(at: item.targetMicroseconds)
            #expect(actual.first == .init(timeMicroseconds: item.first.timeMicroseconds, clusterOffset: item.first.clusterOffset)
                && actual.second == .init(timeMicroseconds: item.second.timeMicroseconds, clusterOffset: item.second.clusterOffset),
                Comment(rawValue: "Original default seek-point case \(index)"))
        }
    }

    @Test func missingDurationCannotMakeASeekMapEvenWithCues() {
        let timeline = MatroskaTimeline(durationMicroseconds: nil, primaryTrack: 1,
            cues: [1: [.init(timeMicroseconds: 0, clusterOffset: 438, relativeOffset: 3)]], declaredCueOffset: 86250)
        let points = timeline.defaultSeekPoints(at: 4_000_000)
        #expect(!timeline.isSeekable && points.first == .start && points.second == .start)
    }
}
