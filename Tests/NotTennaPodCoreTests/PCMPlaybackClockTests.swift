import Foundation
import Testing
@testable import NotTennaPodCore

struct PCMPlaybackClockTests {
    private struct Operation: Decodable {
        let kind: String
        let speedBits: UInt32
        let sampleRate, channels: Int?
        let mediaUs, frame, presented, written, input, pending, output, skipped, expected: Int64?
        let active: Bool?
    }
    private struct Oracle: Decodable {
        let referenceCommit, media3Version: String
        let operations: [Operation]
    }

    /// The position shown while playing at changing speeds (with skip-silence) matches
    /// Media3's playback clock within 1 ms across 7,672 recorded readings, including
    /// after renderer recovery.
    @Test func shownPositionMatchesMedia3AcrossSpeedChanges() throws {
        let url = try #require(Bundle.module.url(forResource: "pcm-clock-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        #expect(oracle.referenceCommit == "f8c641887e4677237b01b6e942ff8fe20fc8beec")
        #expect(oracle.media3Version == "1.10.0" && oracle.operations.count == 10_232)
        var clock: PCMPlaybackClock?
        var comparisons = 0
        for (index, operation) in oracle.operations.enumerated() {
            let speed = Float(bitPattern: operation.speedBits)
            switch operation.kind {
            case "reset":
                clock = try PCMPlaybackClock(sampleRate: #require(operation.sampleRate),
                                             mediaMicroseconds: #require(operation.mediaUs), speed: speed)
            case "checkpoint":
                var current = try #require(clock)
                try current.enqueueCheckpoint(outputFrame: #require(operation.frame),
                                              mediaMicroseconds: #require(operation.mediaUs), speed: speed)
                clock = current
            case "read":
                var current = try #require(clock)
                let progress = try PCMProcessingProgress(speed: speed, channels: #require(operation.channels),
                    inputFrames: #require(operation.input), pendingInputFrames: #require(operation.pending),
                    outputFrames: #require(operation.output), skippedFrames: #require(operation.skipped),
                    speedProcessingActive: #require(operation.active as Bool?))
                let position = try current.position(presentedFrames: #require(operation.presented),
                                                    writtenFrames: #require(operation.written), progress: progress)
                let expected = try #require(operation.expected)
                #expect(abs(position - expected) <= 1_000, Comment(rawValue: "Original Java reading at operation \(index)"))
                // Retire every checkpoint already admitted by this independent Java scenario,
                // then recover its earlier reading using the same coherent processor snapshot.
                var advanced = current
                _ = try advanced.position(presentedFrames: #require(operation.written),
                                          writtenFrames: #require(operation.written), progress: progress)
                let recovered = try advanced.recoveryPosition(presentedFrames: #require(operation.presented),
                    writtenFrames: #require(operation.written), progress: progress)
                #expect(abs(recovered - expected) <= 1_000, Comment(rawValue: "Recovered original Java reading at operation \(index)"))
                clock = current
                comparisons += 1
            default: Issue.record("Unknown oracle operation: \(operation.kind)")
            }
        }
        #expect(comparisons == 7672)
    }
}
