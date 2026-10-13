import Foundation
import Testing
@testable import NotTennaPodCore

struct PlaybackIntervalTests {
    private struct Oracle: Decodable {
        struct Case: Decodable {
            let position, duration, seconds: Int32
            let completed: Bool
            let target: Int64?
        }
        let referenceCommit: String
        let cases: [Case]
    }

    @Test func originalActiveServiceIntervalActionsAndBoundaries() throws {
        let url = try #require(Bundle.module.url(forResource: "playback-interval-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        #expect(oracle.referenceCommit == "f8c641887e4677237b01b6e942ff8fe20fc8beec" && oracle.cases.count == 550)
        for item in oracle.cases {
            let expected: PlaybackTiming.IntervalDecision = try item.completed ? .complete : .seek(#require(item.target))
            #expect(PlaybackTiming.intervalSkip(positionMilliseconds: item.position, durationMilliseconds: item.duration,
                seconds: item.seconds) == expected,
                "position=\(item.position), duration=\(item.duration), seconds=\(item.seconds)")
        }
    }
}
