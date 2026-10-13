import Foundation

/// Half-open intervals describe bytes actually written, never the length of a sparse file.
struct HTTPMediaByteCoverage: Sendable {
    private(set) var ranges: [Range<Int64>] = []
    var count: Int64 { ranges.reduce(0) { $0 + $1.count64 } }
    var prefixEnd: Int64 { ranges.first?.lowerBound == 0 ? ranges[0].upperBound : 0 }

    func availableEnd(at offset: Int64) -> Int64 {
        ranges.first { $0.contains(offset) }?.upperBound ?? offset
    }

    mutating func insert(_ range: Range<Int64>) {
        precondition(range.lowerBound >= 0)
        guard !range.isEmpty else { return }
        var combined = range
        var result: [Range<Int64>] = []
        for existing in ranges {
            if existing.upperBound < combined.lowerBound { result.append(existing) }
            else if combined.upperBound < existing.lowerBound {
                result.append(combined); combined = existing
            } else {
                combined = min(combined.lowerBound, existing.lowerBound)..<max(combined.upperBound, existing.upperBound)
            }
        }
        result.append(combined)
        ranges = result
    }
}

private extension Range<Int64> { var count64: Int64 { upperBound - lowerBound } }

/// A 416 can identify exact EOF, not a successful body or an arbitrary out-of-
/// range read. Media3 DefaultHttpDataSource uses the same position/size equality.
struct HTTPMediaRangeEnd: Equatable, Sendable {
    let length: Int64

    init(contentRange: String?, requestedOffset: Int64) throws {
        guard requestedOffset >= 0, let contentRange else { throw MediaDownloadError.invalidRange }
        let fields = contentRange.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 2, fields[0].lowercased() == "bytes" else { throw MediaDownloadError.invalidRange }
        let parts = fields[1].split(separator: "/", omittingEmptySubsequences: false)
        func integer(_ text: Substring) -> Int64? {
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int64(text)
        }
        guard parts.count == 2, let total = integer(parts[1]), total == requestedOffset else {
            throw MediaDownloadError.invalidRange
        }
        if parts[0] != "*" {
            let ends = parts[0].split(separator: "-", omittingEmptySubsequences: false)
            guard ends.count == 2, let first = integer(ends[0]), let last = integer(ends[1]),
                  first <= last, last < total else { throw MediaDownloadError.invalidRange }
        }
        length = total
    }
}

/// Validates a single-part 206 before any bytes can be assigned a file offset.
struct HTTPMediaPartialResponse: Equatable, Sendable {
    let bytes: Range<Int64>
    let total: Int64?

    init(contentRange: String?, requestedOffset: Int64, expectedTotal: Int64?, contentLength: Int64) throws {
        guard requestedOffset >= 0, expectedTotal.map({ $0 > requestedOffset }) ?? true, let contentRange else {
            throw MediaDownloadError.invalidRange
        }
        let fields = contentRange.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 2, fields[0].lowercased() == "bytes" else { throw MediaDownloadError.invalidRange }
        let parts = fields[1].split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw MediaDownloadError.invalidRange }
        let ends = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        func integer(_ text: Substring) -> Int64? {
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int64(text)
        }
        let reportedTotal: Int64?
        if parts[1] == "*" { reportedTotal = nil }
        else {
            guard let value = integer(parts[1]) else { throw MediaDownloadError.invalidRange }
            reportedTotal = value
        }
        if let expectedTotal, let reportedTotal, expectedTotal != reportedTotal { throw MediaDownloadError.invalidRange }
        let resolvedTotal = expectedTotal ?? reportedTotal
        guard ends.count == 2, let start = integer(ends[0]), let last = integer(ends[1]),
              start == requestedOffset, last >= start, last < Int64.max,
              resolvedTotal.map({ last < $0 }) ?? true else { throw MediaDownloadError.invalidRange }
        let length = last - start + 1
        guard contentLength < 0 || contentLength == length else { throw MediaDownloadError.invalidRange }
        bytes = start..<(last + 1)
        total = resolvedTotal
    }
}
