import Testing
@testable import NotTennaPodCore

struct HTTPMediaByteRangesTests {
    @Test func initiallyUnknownTotalsRetainUnknownOrLearnOnlyAnExplicitTotal() throws {
        let known = try HTTPMediaPartialResponse(contentRange: "bytes 20-49/100", requestedOffset: 20,
            expectedTotal: nil, contentLength: 30)
        let unknown = try HTTPMediaPartialResponse(contentRange: "bytes 20-49/*", requestedOffset: 20,
            expectedTotal: nil, contentLength: -1)
        #expect(known.bytes == 20..<50 && known.total == 100)
        #expect(unknown.bytes == 20..<50 && unknown.total == nil)
        for value in ["bytes 20-49/49", "bytes 20-49/0", "bytes 21-49/*", "bytes 20-9223372036854775807/*"] {
            #expect(throws: MediaDownloadError.invalidRange) {
                try HTTPMediaPartialResponse(contentRange: value, requestedOffset: 20, expectedTotal: nil, contentLength: -1)
            }
        }
    }

    @Test func disjointAdjacentOverlappingAndRepeatedWritesMatchIndependentByteMap() {
        var coverage = HTTPMediaByteCoverage()
        var bytes = Set<Int64>()
        // Includes sparse tail-first writes, bridges, contained writes and empty intervals.
        for range: Range<Int64> in [24..<32, 4..<8, 8..<12, 6..<10, 0..<3, 18..<24, 3..<4,
                                   30..<32, 12..<12, 12..<18, 0..<32] {
            coverage.insert(range)
            bytes.formUnion(range)
            #expect(coverage.count == Int64(bytes.count))
            for offset: Int64 in 0...33 {
                var end = offset
                while bytes.contains(end) { end += 1 }
                #expect(coverage.availableEnd(at: offset) == end)
            }
            for pair in zip(coverage.ranges, coverage.ranges.dropFirst()) {
                #expect(pair.0.upperBound < pair.1.lowerBound)
            }
        }
        #expect(coverage.ranges == [0..<32] && coverage.prefixEnd == 32)
    }

    @Test func validPartialResponsesIncludeShortSegmentsAndUnknownReportedTotal() throws {
        for (header, length, end): (String, Int64, Int64) in [
            ("bytes 20-99/100", 80, 100), ("bytes 20-49/100", 30, 50),
            ("bytes 20-49/*", -1, 50), ("BYTES 20-99/100", -1, 100)
        ] {
            let response = try HTTPMediaPartialResponse(contentRange: header, requestedOffset: 20,
                                                       expectedTotal: 100, contentLength: length)
            #expect(response.bytes == 20..<end && response.total == 100)
        }
    }

    @Test func invalidPartialResponsesCannotAssignOffsetsOrChangeRepresentationLength() {
        for header: String? in [nil, "", "items 20-99/100", "bytes */100", "bytes 21-99/100",
                               "bytes 0-99/100", "bytes 20-19/100", "bytes 20-100/100", "bytes 20-99/101",
                               "bytes +20-99/100", "bytes 20-99/+100", "bytes 20-99/100/100",
                               "bytes 20-9223372036854775808/100", "bytes 20-99/100, 0-1/100"] {
            // With and without a Content-Length: a declared length must not be the only thing that
            // catches a reply for the wrong offset (chunked 206 replies have none).
            for length: Int64 in [80, -1] {
                #expect(throws: MediaDownloadError.invalidRange, "\(header ?? "nil"), length \(length)") {
                    try HTTPMediaPartialResponse(contentRange: header, requestedOffset: 20, expectedTotal: 100, contentLength: length)
                }
            }
        }
        #expect(throws: MediaDownloadError.invalidRange) {
            try HTTPMediaPartialResponse(contentRange: "bytes 20-99/100", requestedOffset: 20, expectedTotal: 100, contentLength: 79)
        }
        let limit = Int64.max
        #expect(throws: MediaDownloadError.invalidRange) {
            try HTTPMediaPartialResponse(contentRange: "bytes 20-\(limit)/\(limit)", requestedOffset: 20,
                                         expectedTotal: limit, contentLength: -1)
        }
    }
}
