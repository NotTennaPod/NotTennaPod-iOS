import Foundation
import SwiftSoup

final class FeedDateParser {
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private let patterns = [
        "dd MMM yy HH:mm:ss Z", "dd MMM yy HH:mm Z",
        "EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss",
        "EEE, dd MMMM yyyy HH:mm:ss Z", "EEE, dd MMMM yyyy HH:mm:ss",
        "EEEE, dd MMM yyyy HH:mm:ss Z", "EEEE, dd MMM yy HH:mm:ss Z",
        "EEEE, dd MMM yyyy HH:mm:ss", "EEEE, dd MMM yy HH:mm:ss",
        "EEE MMM d HH:mm:ss yyyy", "EEE, dd MMM yyyy HH:mm Z", "EEE, dd MMM yyyy HH:mm",
        "EEE, dd MMMM yyyy HH:mm Z", "EEE, dd MMMM yyyy HH:mm",
        "EEEE, dd MMM yyyy HH:mm Z", "EEEE, dd MMM yy HH:mm Z",
        "EEEE, dd MMM yyyy HH:mm", "EEEE, dd MMM yy HH:mm", "EEE MMM d HH:mm yyyy",
        "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS Z",
        "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", "yyyy-MM-dd'T'HH:mm:ss.SSS",
        "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "yyyy-MM-ddZ", "yyyy-MM-dd", "EEE d MMM yyyy HH:mm:ss 'GMT'Z (z)"
    ]

    func parse(_ input: String, now: Date) -> Date? {
        guard let date = parse(input), date <= now else { return nil }
        return date
    }

    /// `DateUtils.parse`. Its retry without a leading "word, " recursed; a hostile date made of thousands of
    /// such words recursed until the stack overflowed, re-reading the rest each time. The retries
    /// loop here, and text far longer than any date is not tried against every pattern.
    func parse(_ input: String) -> Date? {
        // Most feed dates are canonical RFC 822 or ISO 8601; trying the formatter chain cost 9-12 % of a
        // refresh in a device profile. The fast path only answers for forms whose result is
        // proven identical to the chain (FeedDateFastPathTests) and otherwise leaves the date to it.
        if let date = FeedDateFastPath.parse(input) { return date }
        return parseWithFormatters(input)
    }

    /// The `DateUtils.parse` formatter chain, without the fast path.
    func parseWithFormatters(_ input: String) -> Date? {
        var input = input
        for _ in 0..<64 {
            switch attempt(input) {
            case .date(let date): return date
            case .retry(let rest): input = rest
            case .none: return nil
            }
        }
        return nil
    }

    private enum Attempt { case date(Date), retry(String), none }

    private func attempt(_ input: String) -> Attempt {
        formatter.isLenient = true
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        if let date = formatter.date(from: input) { return .date(date) }
        // DateUtils' first SimpleDateFormat.parse accepts a complete RFC822
        // prefix. Foundation's date(from:) requires consuming the whole string.
        if let prefix = input.range(of: #"^[A-Za-z]+,\s*[0-9]{1,2}\s+[A-Za-z]{3,}\s+[0-9]{2,4}\s+[0-9]{1,2}:[0-9]{1,2}:[0-9]{1,2}\s+(?:[+-][0-9]{4}|[A-Za-z]{1,5})(?=\s|$)"#,
                                    options: .regularExpression),
           let date = formatter.date(from: String(input[prefix])) { return .date(date) }
        guard input.utf16.count <= 1_000 else { return .none }
        var value = JavaString.trim(input).replacingOccurrences(of: "/", with: "-")
        for (pattern, replacement) in [
            (" {2,}", " "), ("([+-][0-9][0-9]):([0-9][0-9])$", "$1$2"),
            ("CEST$", "+0200"), ("CET$", "+0100"), ("\\bSept\\b", "Sep")
        ] {
            value = value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        if let dot = value.firstIndex(of: ".") {
            var end = value.index(after: dot)
            while end < value.endIndex, value[end].isNumber { end = value.index(after: end) }
            let fraction = String(value[value.index(after: dot)..<end])
            if fraction.count != 3 {
                let suffix = end < value.index(before: value.endIndex) ? String(value[end...]) : ""
                value = String(value[...dot]) + String((fraction + "000").prefix(3)) + suffix
            }
        }
        formatter.isLenient = false
        for pattern in patterns {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: value) { return .date(date) }
            if pattern.hasSuffix(" Z") {
                formatter.dateFormat = String(pattern.dropLast()) + "z"
                if let date = formatter.date(from: value) { return .date(date) }
            }
        }
        if value.range(of: "^\\w+, .*$", options: .regularExpression) != nil,
           let comma = value.firstIndex(of: ",") {
            return .retry(String(value[value.index(after: comma)...]))
        }
        return .none
    }
}

/// Exact parsing of the canonical feed date forms, by arithmetic instead of DateFormatter:
/// `[Day, ]d MMM yyyy HH:mm[:ss] zone` (zone: ±hhmm, GMT, UTC, UT or a North American abbreviation) and
/// `yyyy-MM-ddTHH:mm:ss[.fraction][Z|±hh:mm|±hhmm]`. Anything else, including out-of-range fields that the
/// lenient formatter would roll over, returns nil and is left to the formatter chain.
enum FeedDateFastPath {
    private static let months: [UInt32: Int] = {
        var table: [UInt32: Int] = [:]
        for (index, name) in ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"].enumerated() {
            table[key(name)] = index + 1
        }
        return table
    }()
    private static let weekdays: Set<UInt32> = Set(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map(key))
    /// Abbreviations and their fixed offsets in minutes, as the formatter resolves them.
    private static let zones: [String: Int] = [
        "GMT": 0, "UTC": 0, "UT": 0,
        "EST": -300, "EDT": -240, "CST": -360, "CDT": -300, "MST": -420, "MDT": -360, "PST": -480, "PDT": -420
    ]
    private static func key(_ name: String) -> UInt32 { name.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    static func parse(_ input: String) -> Date? {
        var input = input
        return input.withUTF8 { bytes in
            guard bytes.count >= 16, bytes.count <= 40 else { return nil }
            return isDigit(bytes[0]) && isDigit(bytes[1]) && isDigit(bytes[2]) && isDigit(bytes[3]) && bytes[4] == 0x2D
                ? iso(bytes) : rfc822(bytes)
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    private struct Cursor {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0
        var atEnd: Bool { index == bytes.count }
        mutating func digits(_ count: Int) -> Int? {
            guard index + count <= bytes.count else { return nil }
            var value = 0
            for offset in 0..<count {
                let byte = bytes[index + offset]
                guard byte >= 0x30 && byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            index += count
            return value
        }
        mutating func skip(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }
        func peek(_ byte: UInt8) -> Bool { index < bytes.count && bytes[index] == byte }
        mutating func letters(_ count: Int) -> UInt32? {
            guard index + count <= bytes.count else { return nil }
            var value: UInt32 = 0
            for offset in 0..<count {
                let byte = bytes[index + offset]
                guard (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) else { return nil }
                value = value << 8 | UInt32(byte)
            }
            index += count
            return value
        }
        /// `±hhmm`, or `±hh:mm` when `colon` is allowed, as minutes east of UTC.
        mutating func offset(colon: Bool) -> Int? {
            let negative: Bool
            if skip(0x2B) { negative = false } else if skip(0x2D) { negative = true } else { return nil }
            guard let hours = digits(2) else { return nil }
            if colon { _ = skip(0x3A) }
            guard let minutes = digits(2), hours <= 14, minutes <= 59 else { return nil }
            return (negative ? -1 : 1) * (hours * 60 + minutes)
        }
    }

    private static func rfc822(_ bytes: UnsafeBufferPointer<UInt8>) -> Date? {
        var cursor = Cursor(bytes: bytes)
        if !isDigit(bytes[0]) {
            guard let weekday = cursor.letters(3), weekdays.contains(weekday), cursor.skip(0x2C), cursor.skip(0x20) else { return nil }
        }
        let day: Int
        if let two = cursor.digits(2) { day = two } else if let one = cursor.digits(1) { day = one } else { return nil }
        guard cursor.skip(0x20), let name = cursor.letters(3), let month = months[name], cursor.skip(0x20),
              let year = cursor.digits(4), cursor.skip(0x20),
              let hour = cursor.digits(2), cursor.skip(0x3A), let minute = cursor.digits(2) else { return nil }
        var second = 0
        if cursor.skip(0x3A) {
            guard let value = cursor.digits(2) else { return nil }
            second = value
        }
        guard cursor.skip(0x20) else { return nil }
        let offset: Int
        if cursor.peek(0x2B) || cursor.peek(0x2D) {
            guard let value = cursor.offset(colon: false) else { return nil }
            offset = value
        } else {
            let start = cursor.index
            while !cursor.atEnd, cursor.letters(1) != nil {}
            guard let zone = zones[String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<cursor.index]), as: UTF8.self)] else { return nil }
            offset = zone
        }
        guard cursor.atEnd else { return nil }
        return date(year: year, month: month, day: day, hour: hour, minute: minute, second: second,
                    milliseconds: 0, offsetMinutes: offset)
    }

    private static func iso(_ bytes: UnsafeBufferPointer<UInt8>) -> Date? {
        var cursor = Cursor(bytes: bytes)
        guard let year = cursor.digits(4), cursor.skip(0x2D), let month = cursor.digits(2), cursor.skip(0x2D),
              let day = cursor.digits(2), cursor.skip(0x54), let hour = cursor.digits(2), cursor.skip(0x3A),
              let minute = cursor.digits(2), cursor.skip(0x3A), let second = cursor.digits(2) else { return nil }
        var milliseconds = 0
        if cursor.skip(0x2E) {
            // The chain keeps milliseconds: the first three digits, padded with zeros.
            var count = 0
            while !cursor.atEnd, isDigit(bytes[cursor.index]) {
                if count < 3 { milliseconds = milliseconds * 10 + Int(bytes[cursor.index] - 0x30) }
                count += 1; cursor.index += 1
            }
            guard count > 0 else { return nil }
            for _ in count..<max(count, 3) { milliseconds *= 10 }
        }
        var offset = 0
        if cursor.skip(0x5A) {
        } else if !cursor.atEnd {
            guard let value = cursor.offset(colon: true) else { return nil }
            offset = value
        }
        guard cursor.atEnd else { return nil }
        return date(year: year, month: month, day: day, hour: hour, minute: minute, second: second,
                    milliseconds: milliseconds, offsetMinutes: offset)
    }

    private static func date(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int,
                             milliseconds: Int, offsetMinutes: Int) -> Date? {
        // Proleptic arithmetic matches the formatter's Gregorian calendar well after its 1582 cutover.
        guard (1900...2999).contains(year), (1...12).contains(month), day >= 1, hour <= 23, minute <= 59, second <= 59 else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day <= lengths[month - 1] else { return nil }
        // Days from 1970-01-01 (Howard Hinnant's days_from_civil).
        let y = month <= 2 ? year - 1 : year
        let era = y / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let seconds = ((days * 24 + hour) * 60 + minute) * 60 + second - offsetMinutes * 60
        // As CFDateFormatter builds its result from ICU's milliseconds.
        let udate = Double(seconds * 1_000 + milliseconds)
        return Date(timeIntervalSinceReferenceDate: udate / 1_000 - 978_307_200)
    }
}
