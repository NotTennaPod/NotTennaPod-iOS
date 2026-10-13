import Foundation

/// Source display bounds, independent of the unchanged database query bounds.
/// Month labels correct the fixed-24-hour subtraction defect only.
public struct StatisticsPeriodCaption: Equatable, Sendable {
    public enum Interval: Equatable, Sendable { case nonempty, empty, reversed }
    public let from: String
    public let to: String
    public let interval: Interval

    public init(preferences: StatisticsPeriodPreferences, oldestMilliseconds: Int64,
                formatter: StatisticsTextFormatter) {
        let now = formatter.now
        let savedFrom = Date(timeIntervalSince1970: Double(preferences.timeFrom) / 1000)
        let oldest = Date(timeIntervalSince1970: Double(oldestMilliseconds) / 1000)
        let start = max(min(savedFrom, now), oldest)
        let end = preferences.timeTo == .max ? now
            : min(Date(timeIntervalSince1970: Double(preferences.timeTo) / 1000), now)
        interval = start == end ? .empty : start < end ? .nonempty : .reversed
        // Android's observed en-US and th-TH primitive uses Gregorian months.
        // Locale still owns localized month names/order; zone owns boundaries.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        let date = DateFormatter()
        date.locale = formatter.locale; date.calendar = calendar; date.timeZone = formatter.timeZone
        date.setLocalizedDateFormatFromTemplate("MMM yyyy")
        from = date.string(from: start)
        var lastMonth = end
        if preferences.timeTo != .max,
           Date(timeIntervalSince1970: Double(preferences.timeTo) / 1000) <= now,
           let month = calendar.dateInterval(of: .month, for: end), month.start == end,
           let preceding = calendar.date(byAdding: .month, value: -1, to: month.start) {
            lastMonth = preceding
        }
        to = date.string(from: lastMonth)
    }
}
