import Foundation
import Testing
@testable import NotTennaPodCore

struct FeedArtworkBlurTests {
    /// The header background looks like Android's blur: every channel of every pixel within 3/255.
    @Test func matchesExecutedPinnedBlurWithinImperceptibleDifference() throws {
        struct Oracle: Decodable {
            struct Case: Decodable { let width, height: Int; let input, output: [UInt32] }
            let cases: [Case]
        }
        let url = try #require(Bundle.module.url(forResource: "feed-blur-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        #expect(oracle.cases.count == 6)
        for test in oracle.cases {
            let actual = try #require(FeedArtworkBlur.apply(test.input, width: test.width, height: test.height))
            #expect(actual.count == test.output.count)
            func channels(_ value: UInt32) -> [Int] { [UInt32(0), 8, 16, 24].map { Int((value >> $0) & 0xff) } }
            var largest = 0
            for (a, e) in zip(actual, test.output) {
                for (x, y) in zip(channels(a), channels(e)) { largest = max(largest, abs(x - y)) }
            }
            #expect(largest <= 3, "\(test.width)x\(test.height): channel difference \(largest)")
        }
    }
    @Test func invalidDimensionsAreRejectedAndUniformColorIsPreserved() {
        #expect(FeedArtworkBlur.apply([], width: 0, height: 1) == nil)
        #expect(FeedArtworkBlur.apply([0], width: Int.max, height: 2) == nil)
        #expect(FeedArtworkBlur.apply([0], width: 2, height: 1) == nil)
        #expect(FeedArtworkBlur.apply(Array(repeating: 0x80804020, count: 143), width: 13, height: 11)
            == Array(repeating: 0xff804020, count: 143))
    }
}
