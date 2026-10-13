import Foundation
import Testing
@testable import NotTennaPodCore

struct LocalMetadataDateParserTests {
    private struct Oracle: Decodable {
        struct Case: Decodable {
            let input: String?
            let timeZone, locale: String
            let expectedEpochMilliseconds: Int64?
        }
        let cases: [Case]
    }
    private func cases() throws -> [Oracle.Case] {
        let url = try #require(Bundle.module.url(forResource: "local-metadata-dates-oracle", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url)).cases
    }
    private func milliseconds(_ date: Date?) -> Int64? {
        date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
    }

    @Test func sourceDateCasesRetainBehaviorExceptDocumentedInstantCorruption() throws {
        let cases = try cases()
        #expect(cases.count == 222)
        // Expected corrections come from the source's own correctly parsed
        // dashed equivalents, not from the new Swift implementation.
        let canonical = [
            "20260914T010203.999Z": "2026-09-14T01:02:03.999Z",
            "20260914T010203Z": "2026-09-14T01:02:03Z",
            "20260914T010203+0200": "2026-09-14T01:02:03+02:00"
        ]
        for item in cases {
            let zone = try #require(TimeZone(identifier: item.timeZone))
            let expected: Int64?
            if let raw = item.input, let equivalent = canonical[raw] {
                expected = try #require(cases.first { $0.input == equivalent && $0.locale == "en-US" && $0.timeZone == "UTC" }).expectedEpochMilliseconds
            } else {
                // Metadata calendar years are not Buddhist-era user-interface
                // years; retain source en-US epochs across UI locale choices.
                expected = try #require(cases.first { $0.input == item.input && $0.locale == "en-US" && $0.timeZone == item.timeZone }).expectedEpochMilliseconds
            }
            #expect(milliseconds(LocalMetadataDateParser.parse(item.input, timeZone: zone)) == expected,
                    "input=\(String(describing: item.input)); zone=\(item.timeZone); original locale=\(item.locale)")
        }
    }
}
