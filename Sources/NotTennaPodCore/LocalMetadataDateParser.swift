import Foundation

/// Local metadata date rules, preserving the source's modified-file fallback.
/// Compact encoded timestamps use a Gregorian calendar and honor an explicit
/// offset. The original default-locale/prefix formatter corrupts those instants;
/// this parser prevents that.
enum LocalMetadataDateParser {
    static func parse(_ raw: String?, timeZone: TimeZone = .current) -> Date? {
        guard let raw, !raw.isEmpty, raw != "19040101T000000.000Z" else { return nil }
        // Android's MP4 extractor emits compact UTC timestamps. Keep explicit
        // fraction/zone information rather than discarding it in a prefix parse.
        if raw.range(of: #"^[0-9]{8}T[0-9]{6}(\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})$"#,
                     options: .regularExpression) != nil {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
            if raw.contains(".") { formatter.formatOptions.insert(.withFractionalSeconds) }
            if raw.contains(":") { formatter.formatOptions.insert(.withColonSeparatorInTimeZone) }
            return formatter.date(from: raw)
        }
        // Retain lenient compact-prefix handling for the source's zone-less
        // legacy inputs. Fix only locale/calendar reinterpretation here.
        if let range = raw.range(of: #"^[0-9]{8}T[0-9]{4}[0-9]+"#, options: .regularExpression) {
            let bytes = Array(raw[range].utf8)
            func number(_ range: Range<Int>) -> Int? { Int(String(decoding: bytes[range], as: UTF8.self)) }
            guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8),
                  let hour = number(9..<11), let minute = number(11..<13), let second = number(13..<bytes.count) else { return nil }
            // Java fixes the preceding abutting fields and lets the final seconds
            // field vary in width. Normalize overflow with the system calendar,
            // avoiding ICU's different redistribution of short abutting input.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            guard let normalized = calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                                      hour: hour, minute: minute, second: second)) else { return nil }
            let fields = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: normalized)
            guard let y = fields.year, let m = fields.month, let d = fields.day, let h = fields.hour,
                  let min = fields.minute, let sec = fields.second else { return nil }
            let prefix = "\(y)-\(m)-\(d) \(h):\(min):\(sec)"
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.isLenient = true
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            if let value = formatter.date(from: prefix) { return value }
        }
        return FeedDateParser().parse(raw)
    }
}
