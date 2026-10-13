import Foundation

/// Statistics-specific source formatting. Locale, zone and clock are explicit
/// so asynchronous statistics loads do not mix formatting configurations.
public struct StatisticsTextFormatter: Equatable, Sendable {
    public let locale: Locale
    public let timeZone: TimeZone
    public let now: Date

    public init(locale: Locale = .current, timeZone: TimeZone = .current, now: Date = Date()) {
        self.locale = locale; self.timeZone = timeZone; self.now = now
    }

    public func duration(seconds: Int64, hoursLabel: String) -> String {
        let value = Float(seconds) / 3600
        let formatter = number(fractionDigits: 1)
        // Java String.format uses a literal minus; ICU can add bidi controls.
        formatter.negativePrefix = "-"
        return formatter.string(from: NSNumber(value: Double(value)))! + " " + hoursLabel
    }

    public func fileSize(bytes: Int64) -> String {
        // Convert the unsigned magnitude before negation. Unlike the original
        // integer negation, this also handles Int64.min without corrupting sign.
        var value = Float(bytes.magnitude), unit = 0
        while value > 900 && unit < 5 { value /= 1000; unit += 1 }
        let digits = unit == 0 || value >= 10 ? 0 : value < 1 ? 2 : 1
        if bytes < 0 { value = -value }
        let formatter = number(fractionDigits: digits)
        if unit == 0 {
            let resources = byteResources
            return resources.pattern
                .replacingOccurrences(of: "%1$s", with: formatter.string(from: NSNumber(value: Double(value)))!)
                .replacingOccurrences(of: "%2$s", with: resources.unit)
        }
        let units: [UnitInformationStorage] = [.bytes, .kilobytes, .megabytes, .gigabytes, .terabytes, .petabytes]
        let measurement = MeasurementFormatter()
        measurement.locale = locale
        measurement.unitOptions = .providedUnit
        // Foundation's medium style corresponds to ICU MeasureFormat SHORT.
        measurement.unitStyle = .medium
        measurement.numberFormatter = formatter
        let text = measurement.string(from: Measurement(value: Double(value), unit: units[unit]))
        // Android's Japanese ICU data uses KB; Apple's currently uses kB.
        if unit == 1 && locale.language.languageCode?.identifier == "ja" {
            return text.replacingOccurrences(of: "kB", with: "KB")
        }
        return text
    }

    public func abbreviatedDate(_ date: Date?) -> String {
        guard let date else { return "" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.calendar = calendar; formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        // Android DateUtils' captured Arabic abbreviated dates omit the comma
        // before the year; Apple's current localized template inserts one.
        if locale.language.languageCode?.identifier == "ar" {
            formatter.dateFormat = formatter.dateFormat.replacingOccurrences(of: "،", with: "")
        }
        return formatter.string(from: date)
    }

    private func number(fractionDigits: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale; formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        formatter.maximumIntegerDigits = 42
        formatter.roundingMode = .halfUp
        return formatter
    }

    private var byteResources: (unit: String, pattern: String) {
        let language = locale.language.languageCode?.identifier ?? ""
        let script = locale.language.script?.identifier
        let region = locale.region?.identifier
        let candidates = [[language, script, region], [language, script], [language, region], [language], [""]]
        for components in candidates {
            let key = components.compactMap { $0 }.joined(separator: "_")
            if let value = StatisticsByteResources.values[key] { return value }
        }
        return ("B", "%1$s %2$s")
    }
}
