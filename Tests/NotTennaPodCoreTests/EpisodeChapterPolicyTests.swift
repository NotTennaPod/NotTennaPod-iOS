import Foundation
import Testing
@testable import NotTennaPodCore

struct EpisodeChapterPolicyTests {
    private struct Oracle: Decodable {
        struct Merge: Decodable { let first, second, result: [ParsedChapter]? }
        struct Selection: Decodable { let chapters: [ParsedChapter]?; let position: Int64; let index: Int }
        struct Parser: Decodable { let document: String; let result: [ParsedChapter]? }
        struct Control: Decodable {
            let chapters: [ParsedChapter]
            let position: Int64
            let speed: Float
            let displayedIndex: Int
            let previous, next: Int64?
        }
        let referenceCommit: String
        let complete: Bool
        let merges: [Merge]
        let selections: [Selection]
        let controls: [Control]
        let parser: [Parser]
    }
    private func oracle() throws -> Oracle {
        let url = try #require(Bundle.module.url(forResource: "player-chapter-policy-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        #expect(oracle.complete && oracle.referenceCommit == "f8c641887e4677237b01b6e942ff8fe20fc8beec")
        return oracle
    }
    @Test func originalMergePriorityAndEnrichment() throws {
        let cases = try oracle().merges; #expect(cases.count == 512)
        for (index, item) in cases.enumerated() {
            #expect(ChapterMerger.merge(item.first, item.second) == item.result, "merge case \(index)")
        }
    }
    @Test func originalCurrentChapterBoundariesAndSuppliedOrder() throws {
        let cases = try oracle().selections; #expect(cases.count == 44)
        for (index, item) in cases.enumerated() {
            #expect(ChapterPlaybackRules.currentIndex(in: item.chapters, positionMilliseconds: item.position) == item.index, "selection case \(index)")
        }
    }
    @Test func unchangedCoverPreviousNextAndSpeedThreshold() throws {
        let cases = try oracle().controls; #expect(cases.count > 100)
        for (index, item) in cases.enumerated() {
            #expect(ChapterPlaybackRules.previousStart(in: item.chapters, displayedIndex: item.displayedIndex,
                positionMilliseconds: item.position, speed: item.speed) == item.previous, "previous case \(index)")
            #expect(ChapterPlaybackRules.nextStart(in: item.chapters, displayedIndex: item.displayedIndex) == item.next, "next case \(index)")
        }
    }
    @Test func retiredChapterIndexCannotSeek() {
        let chapters = [ParsedChapter(startMilliseconds: 5000)]
        for index in [-1, 1, Int.max] {
            #expect(ChapterPlaybackRules.previousStart(in: chapters, displayedIndex: index, positionMilliseconds: 0, speed: 1) == nil)
            #expect(ChapterPlaybackRules.nextStart(in: chapters, displayedIndex: index) == nil)
        }
    }
    @Test func originalExternalParserCoercionsAndMalformedDocuments() throws {
        let cases = try oracle().parser; #expect(cases.count == 30)
        for (index, item) in cases.enumerated() {
            #expect(PodcastIndexChapterParser.parse(item.document) == item.result, "parser case \(index)")
        }
    }
}
