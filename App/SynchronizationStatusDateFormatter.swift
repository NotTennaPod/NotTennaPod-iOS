import Foundation

/// DateUtils.getRelativeDateTimeString(MINUTE, WEEK, SHOW_TIME), used by the
/// synchronization toolbar. Unit thresholds and calendar-day promotion are
/// source-owned; Foundation supplies localized relative words and date/time.
enum SynchronizationStatusDateFormatter {
    static func string(from date: Date, relativeTo now: Date = Date(),
                       locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale; calendar.timeZone = timeZone
        let duration = abs(now.timeIntervalSince(date))
        let past = date <= now
        let dayDistance = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                                  to: calendar.startOfDay(for: now)).day ?? 0
        let dateClause: String
        if duration >= 7 * 86_400 {
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            dateClause = formatted(date, template: sameYear ? "MMMd" : "yMd", locale: locale,
                                   timeZone: timeZone, calendar: calendar)
        } else {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale; formatter.calendar = calendar
            formatter.unitsStyle = .full
            formatter.formattingContext = .beginningOfSentence
            let count: Int
            var components = DateComponents()
            let sign = past ? -1 : 1
            if dayDistance != 0 || duration >= 86_400 {
                // A different local calendar date means Yesterday/Tomorrow (or
                // whole calendar days), even when only two minutes have passed.
                count = abs(dayDistance)
                components.day = sign * count
                formatter.dateTimeStyle = .named
            } else if duration >= 3_600 {
                count = Int(duration / 3_600)
                components.hour = sign * count
                formatter.dateTimeStyle = .numeric
            } else {
                count = Int(duration / 60)
                components.minute = sign * count
                formatter.dateTimeStyle = .numeric
            }
            if count == 0, components.minute != nil {
                // DateComponents has no negative zero. Preserve the source's
                // numeric zero and direction instead of "now" or rounding up.
                // These source-derived phrases cover the currently translated
                // app language plus the date oracle's locale checks.
                dateClause = zeroMinutes(past: past, locale: locale)
            } else {
                dateClause = formatter.localizedString(from: components)
            }
        }
        let timeClause = formatted(date, template: "jm", locale: locale, timeZone: timeZone, calendar: calendar)
        return dateClause + ", " + timeClause
    }

    private static func formatted(_ date: Date, template: String, locale: Locale,
                                  timeZone: TimeZone, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.calendar = calendar; formatter.timeZone = timeZone
        formatter.formattingContext = .beginningOfSentence
        formatter.setLocalizedDateFormatFromTemplate(template)
        if template == "MMMd", locale.language.languageCode?.identifier == "en", locale.region?.identifier == "GB" {
            // Android16 ICU's en-GB abbreviated September is "Sept"; Apple's
            // current locale data uses "Sep". Keep the source wording through
            // DateFormatter's supported symbol customization, without changing
            // the locale's ordering, punctuation, other months or clock style.
            // Covered by pastWeek/pastWeekPlus1ms/futureWeek in the source oracle.
            var symbols = formatter.shortMonthSymbols!
            symbols[8] = "Sept"
            formatter.shortMonthSymbols = symbols
        }
        return formatter.string(from: date)
    }

    private static func zeroMinutes(past: Bool, locale: Locale) -> String {
        switch locale.language.languageCode?.identifier {
        case "de": return past ? "Vor 0 Minuten" : "In 0 Minuten"
        case "fr": return past ? "Il y a 0 minute" : "Dans 0 minute"
        default: return past ? "0 minutes ago" : "In 0 minutes"
        }
    }
}
