import Foundation

/// Global statistics choices. These bounds select each episode's last statistics
/// timestamp; they do not partition that episode's duration into listening sessions.
public struct StatisticsPeriodPreferences: Codable, Equatable, Sendable {
    public var includeMarkedAsPlayed: Bool
    public var timeFrom: Int64
    public var timeTo: Int64

    public init(includeMarkedAsPlayed: Bool = false, timeFrom: Int64 = 0, timeTo: Int64 = .max) {
        self.includeMarkedAsPlayed = includeMarkedAsPlayed
        self.timeFrom = timeFrom
        self.timeTo = timeTo
    }

    private enum CodingKeys: String, CodingKey {
        case includeMarkedAsPlayed = "countAll", timeFrom = "filterFrom", timeTo = "filterTo"
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        includeMarkedAsPlayed = try fields.decodeIfPresent(Bool.self, forKey: .includeMarkedAsPlayed) ?? false
        timeFrom = try fields.decodeIfPresent(Int64.self, forKey: .timeFrom) ?? 0
        timeTo = try fields.decodeIfPresent(Int64.self, forKey: .timeTo) ?? .max
    }
}

public struct StatisticsPeriodOption: Equatable, Sendable {
    public enum Label: Equatable, Sendable { case month(String), today }
    public let label: Label
    public let timestamp: Int64
}

/// Monthly choices from StatisticsFilterDialog.makeMonthlyList. The caller owns
/// the calendar/zone and locale; this does not infer Android's default calendar
/// for locales whose runtime behavior has not yet been verified.
public struct StatisticsPeriodOptions: Equatable, Sendable {
    public let from: [StatisticsPeriodOption]
    public let to: [StatisticsPeriodOption]

    public enum CalendarError: Error, Equatable { case unavailableMonth, invalidTimestamp }

    public init(oldestMilliseconds: Int64, nowMilliseconds: Int64,
                calendar: Calendar, locale: Locale) throws {
        let oldest = Date(timeIntervalSince1970: Double(oldestMilliseconds) / 1000)
        guard var month = calendar.dateInterval(of: .month, for: oldest)?.start else {
            throw CalendarError.unavailableMonth
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM yyyy")
        var starts: [StatisticsPeriodOption] = [], ends: [StatisticsPeriodOption] = []
        // An empty library captured exactly at month
        // start otherwise has no From choice. Include only that real month,
        // matching the source's usable choices one millisecond later. Older
        // history and future oldest timestamps retain the strict source bound.
        let firstMonthMilliseconds = try Self.milliseconds(month)
        let recoverEmptyCurrentMonth = oldestMilliseconds == nowMilliseconds
            && firstMonthMilliseconds == nowMilliseconds
        while try Self.milliseconds(month) < nowMilliseconds
                || (starts.isEmpty && recoverEmptyCurrentMonth) {
            let label = StatisticsPeriodOption.Label.month(formatter.string(from: month))
            starts.append(.init(label: label, timestamp: try Self.milliseconds(month)))
            guard let next = calendar.date(byAdding: .month, value: 1, to: month), next > month else {
                throw CalendarError.unavailableMonth
            }
            ends.append(.init(label: label, timestamp: try Self.milliseconds(next)))
            month = next
        }
        ends.append(.init(label: .today, timestamp: .max))
        from = starts
        to = ends
    }

    private static func milliseconds(_ date: Date) throws -> Int64 {
        let value = (date.timeIntervalSince1970 * 1000).rounded()
        guard value.isFinite, value >= Double(Int64.min), value < Double(Int64.max) else {
            throw CalendarError.invalidTimestamp
        }
        return Int64(value)
    }
}

/// A value-type editing session: dismissing it has no persistence side effect.
/// Confirmed marked inclusion discards the saved narrower range, as on Android.
public struct StatisticsPeriodDraft: Equatable, Sendable {
    public let options: StatisticsPeriodOptions
    public var includeMarkedAsPlayed: Bool
    public private(set) var fromIndex: Int?
    public private(set) var toIndex: Int?

    public init(preferences: StatisticsPeriodPreferences, options: StatisticsPeriodOptions) {
        self.options = options
        includeMarkedAsPlayed = preferences.includeMarkedAsPlayed
        fromIndex = Self.restoredIndex(options.from, saved: preferences.timeFrom)
        toIndex = Self.restoredIndex(options.to, saved: preferences.timeTo)
    }

    public var datesEnabled: Bool { !includeMarkedAsPlayed }

    @discardableResult public mutating func selectFrom(_ index: Int) -> Bool {
        guard datesEnabled, options.from.indices.contains(index) else { return false }
        fromIndex = index
        return true
    }

    @discardableResult public mutating func selectTo(_ index: Int) -> Bool {
        guard datesEnabled, options.to.indices.contains(index) else { return false }
        toIndex = index
        return true
    }

    public mutating func selectAllTime() {
        guard datesEnabled else { return }
        fromIndex = options.from.isEmpty ? nil : 0
        toIndex = options.to.indices.last
    }

    public mutating func selectPastYear() {
        guard datesEnabled else { return }
        fromIndex = options.from.isEmpty ? nil : max(0, options.from.count - 12)
        let lastMonth = options.to.count - 2
        toIndex = options.to.indices.contains(lastMonth) ? lastMonth : nil
    }

    /// Nil represents an absent monthly selection outside the exact empty-library
    /// recovery domain (for example, a synthetic future oldest timestamp).
    public func confirmedPreferences() -> StatisticsPeriodPreferences? {
        if includeMarkedAsPlayed { return .init(includeMarkedAsPlayed: true) }
        guard let fromIndex, let toIndex else { return nil }
        return .init(timeFrom: options.from[fromIndex].timestamp, timeTo: options.to[toIndex].timestamp)
    }

    private static func restoredIndex(_ values: [StatisticsPeriodOption], saved: Int64) -> Int? {
        values.firstIndex(where: { $0.timestamp >= saved }) ?? (values.isEmpty ? nil : 0)
    }
}
