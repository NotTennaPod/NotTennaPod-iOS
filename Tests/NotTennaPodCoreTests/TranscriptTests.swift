import Foundation
import Testing
@testable import NotTennaPodCore

private final class TranscriptTestBundleMarker {}

@Suite struct TranscriptTests {
    private func oracleURL() throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: "transcript-oracle", withExtension: "json", subdirectory: "Fixtures"))
#else
        try #require(Bundle(for: TranscriptTestBundleMarker.self).url(forResource: "transcript-oracle", withExtension: "json"))
#endif
    }
    private struct Oracle: Decodable {
        let name: String, format: String, text: String, outcome: String
        let segments: [TranscriptSegment]?
        let speakers: Set<String>?
        let correction: String?
    }
    @Test func unchangedReleaseOracle() throws {
        let url = try oracleURL()
        let cases = try JSONDecoder().decode([Oracle].self, from: Data(contentsOf: url))
        #expect(cases.count >= 80)
        for value in cases where value.correction == nil {
            let format = try #require(FeedTranscript.Format(rawValue: value.format))
            if value.outcome == "parsed" {
                let transcript = try TranscriptParser.parse(value.text, format: format)
                #expect(transcript.segments == value.segments, Comment(rawValue: value.name))
                #expect(transcript.speakers == value.speakers, Comment(rawValue: value.name))
            } else { #expect(throws: (any Error).self) { try TranscriptParser.parse(value.text, format: format) } }
        }
    }
    @Test func confirmedMalformedSourceCrashesAndTextLossArePrevented() throws {
        let url = try oracleURL()
        let cases = try JSONDecoder().decode([Oracle].self, from: Data(contentsOf: url))
        for value in cases where value.correction != nil {
            let format = try #require(FeedTranscript.Format(rawValue: value.format))
            switch value.correction {
            case "preserve-body-colons":
                #expect(value.outcome == "parsed" && value.segments?.first?.words == "A ratio")
                #expect(try TranscriptParser.parse(value.text, format: format).segments.first?.words == "A ratio: two to one.")
            case "empty-lookahead-no-crash":
                #expect(value.outcome == "exception")
                #expect(try TranscriptParser.parse(value.text, format: format).segments.first?.words == "Hello")
            case "empty-cue-no-crash", "invalid-order-error":
                #expect(value.outcome == "exception")
                #expect(throws: (any Error).self) { try TranscriptParser.parse(value.text, format: format) }
            default: Issue.record("Unverified correction: \(value.name)")
            }
        }
    }
    @Test func precedingHighlightSpeakerHeadersAndOrderedSelection() throws {
        let transcript = try EpisodeTranscript(segments: [
            .init(startMilliseconds: 800, endMilliseconds: 1900, words: "First", speaker: "Ada"),
            .init(startMilliseconds: 2500, endMilliseconds: 4000, words: "Second", speaker: "Ada"),
            .init(startMilliseconds: 4500, endMilliseconds: 5000, words: "Third", speaker: "Bob"),
            .init(startMilliseconds: 5500, endMilliseconds: 6000, words: "Fourth"),
            .init(startMilliseconds: 6500, endMilliseconds: 8000, words: "Fifth", speaker: "Bob")
        ], speakers: ["Ada", "Bob"])
        for (time, index) in [(Int64.min,0),(0,0),(800,0),(2499,0),(2500,1),(5001,2),(Int64.max,4)] {
            #expect(transcript.segmentIndex(at: time) == index)
        }
        #expect(transcript.timecodeHeading(at: 0) == "00:00:00 • Ada")
        #expect(transcript.timecodeHeading(at: 1) == nil)
        #expect(transcript.timecodeHeading(at: 2) == "00:00:04 • Bob")
        #expect(transcript.timecodeHeading(at: 3) == nil)
        #expect(transcript.selectedText(indices: [4,0,1]) == "Ada : First Second\n[...]\n\nBob : Fifth")
        #expect(transcript.selectedText(indices: [0,1,2,3,4]) == "Ada : First Second\nBob : Third Fourth\nBob : Fifth")
        #expect(transcript.selectedText(indices: []) == "")
        let anonymous = try EpisodeTranscript(segments: (0..<7).map { .init(startMilliseconds: Int64($0)*1000, endMilliseconds: Int64($0+1)*1000, words: "Text") }, speakers: [])
        #expect(anonymous.timecodeHeading(at: 0) == "00:00:00")
        #expect(anonymous.timecodeHeading(at: 4) == nil)
        #expect(anonymous.timecodeHeading(at: 5) == "00:00:05")
    }
}
