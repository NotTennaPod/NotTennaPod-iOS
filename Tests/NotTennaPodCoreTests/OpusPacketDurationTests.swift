import Foundation
import Testing
@testable import NotTennaPodCore

struct OpusPacketDurationTests {
    @Test func durationMatchesOriginalJavaForAllTOCValues() throws {
        struct Oracle: Decodable {
            struct Entry: Decodable { let toc: UInt8; let count: UInt8; let duration: Int64 }
            let cases: [Entry]
        }
        let url = try #require(Bundle.module.url(forResource: "opus-packet-duration", withExtension: "json", subdirectory: "Fixtures"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        #expect(oracle.cases.count == 2304)
        for entry in oracle.cases {
            if (1...120_000).contains(entry.duration) {
                #expect(try FFmpegAudioReader.opusPacketDuration(firstByte: entry.toc, secondByte: entry.count) == entry.duration)
            } else {
                // Reject malformed zero-length/over-120ms packet headers before decoder input.
                #expect(throws: FFmpegAudioReader.Failure.invalidFormat) {
                    try FFmpegAudioReader.opusPacketDuration(firstByte: entry.toc, secondByte: entry.count)
                }
            }
        }
    }
    @Test func missingFrameCountIsRejectedOnlyForCodeThree() throws {
        for toc in UInt8.min...UInt8.max {
            if toc & 3 == 3 {
                #expect(throws: FFmpegAudioReader.Failure.invalidFormat) {
                    try FFmpegAudioReader.opusPacketDuration(firstByte: toc, secondByte: nil)
                }
            } else {
                #expect(try FFmpegAudioReader.opusPacketDuration(firstByte: toc, secondByte: nil) > 0)
            }
        }
    }
}
