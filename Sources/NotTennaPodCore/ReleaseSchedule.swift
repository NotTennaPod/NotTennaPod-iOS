import Foundation

public struct ReleaseScheduleGuess: Equatable, Sendable {
    public enum Schedule: String, Codable, Sendable {
        case daily = "DAILY", weekdays = "WEEKDAYS", specificDays = "SPECIFIC_DAYS"
        case weekly = "WEEKLY", biweekly = "BIWEEKLY", fourweekly = "FOURWEEKLY"
        case monthly = "MONTHLY", unknown = "UNKNOWN"
    }
    public let schedule: Schedule
    /// Java Calendar weekday numbering: Sunday=1 through Saturday=7.
    public let days: [Int]?
    public let nextExpectedDate: Date?
    public let multipleReleasesPerDay: Bool
}

/// Source ReleaseScheduleGuesser. Calendar fields use the supplied local zone,
/// while prediction steps add elapsed milliseconds, including across DST.
public enum ReleaseSchedule {
    public enum PredictionError: Error, Equatable { case invalidDate, arithmeticOverflow, invalidCalendar }
    private static let hour: Int64 = 3_600_000, day: Int64 = 86_400_000, week: Int64 = 604_800_000

    public static func guess(_ releaseDates: [Date], timeZone: TimeZone = .current) throws -> ReleaseScheduleGuess {
        var dates = try releaseDates.map(milliseconds).sorted()
        guard dates.count > 1 else { return .init(schedule: .unknown, days: nil, nextExpectedDate: nil, multipleReleasesPerDay: false) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func date(_ timestamp: Int64) -> Date { Date(timeIntervalSince1970: Double(timestamp) / 1000) }
        func normalized(_ timestamp: Int64) -> Date { calendar.startOfDay(for: date(timestamp)) }
        func field(_ component: Calendar.Component, _ timestamp: Int64) -> Int { calendar.component(component, from: date(timestamp)) }
        var uniqueDays = Set<Date>(), lower = dates.count
        while lower > 0 && uniqueDays.count < 20 {
            lower -= 1; uniqueDays.insert(normalized(dates[lower]))
        }
        if dates.count > 20 { dates = Array(dates[lower...]) }
        var hours: [Float] = [], distances: [Int64] = []
        var weekDays = [Int](repeating: 0, count: 8), monthDays = [Int](repeating: 0, count: 32)
        for index in dates.indices {
            let timestamp = dates[index]
            hours.append(Float(field(.hour, timestamp)) + Float(field(.minute, timestamp)) / 60)
            if index > 0 {
                let (distance, overflow) = timestamp.subtractingReportingOverflow(dates[index - 1])
                guard !overflow else { throw PredictionError.arithmeticOverflow }
                distances.append(distance)
            }
            weekDays[field(.weekday, timestamp)] += 1
            monthDays[field(.day, timestamp)] += 1
        }
        func mostFrequent(_ values: [Int], indices: Range<Int>) -> Int {
            var day = 1, count = 0
            for index in indices where values[index] > count { day = index; count = values[index] }
            return day
        }
        let mostWeekDay = mostFrequent(weekDays, indices: 1..<8)
        // The pinned implementation's monthly candidate scan excludes day31.
        let mostMonthDay = mostFrequent(monthDays, indices: 1..<31)
        hours.sort(); distances.sort()
        let medianHour = hours[hours.count / 2], medianDistance = Float(distances[distances.count / 2])
        var averageDelta: Float = 0
        for distance in distances { averageDelta += abs(Float(distance) - medianDistance) }
        averageDelta /= Float(distances.count)
        let wrongDays = max(1, dates.count / 5), singleDayOff = dates.count / 10
        let lastDate = date(dates.last!)
        let minute = Int((Double(medianHour) - floor(Double(medianHour))) * 60)
        // Setting an already-matching hour can retain the earlier occurrence of
        // a repeated time. Re-resolve from midnight, as GregorianCalendar.set
        // does, so half-hour DST folds also select the later occurrence.
        let beginning = calendar.startOfDay(for: lastDate).addingTimeInterval(-1)
        guard var normalizedTime = calendar.nextDate(after: beginning,
            matching: DateComponents(hour: Int(medianHour), minute: minute, second: 0),
            matchingPolicy: .nextTimePreservingSmallerComponents, repeatedTimePolicy: .last) else {
            throw PredictionError.invalidCalendar
        }
        // Foundation currently returns the earlier instant for both policies at
        // Lord Howe's half-hour fold. Validate the later instant using actual
        // zone transitions and complete wall-clock fields, without zone-specific
        // offsets or changing ordinary/nonrepeated dates.
        let fields: Set<Calendar.Component> = [.era, .year, .month, .day, .hour, .minute, .second]
        var wallTime = calendar.dateComponents(fields, from: lastDate)
        wallTime.hour = Int(medianHour); wallTime.minute = minute; wallTime.second = 0
        var utc = Calendar(identifier: .gregorian); utc.timeZone = .gmt
        guard let nominal = utc.date(from: wallTime) else { throw PredictionError.invalidCalendar }
        guard let end = calendar.dateInterval(of: .day, for: lastDate)?.end else { throw PredictionError.invalidCalendar }
        var transition = timeZone.nextDaylightSavingTimeTransition(after: beginning)
        while let change = transition, change < end {
            let before = timeZone.secondsFromGMT(for: change.addingTimeInterval(-1))
            let after = timeZone.secondsFromGMT(for: change)
            let offsetDecrease = before - after
            if offsetDecrease > 0 {
                let later = normalizedTime.addingTimeInterval(Double(offsetDecrease))
                if calendar.dateComponents(fields, from: later) == wallTime { normalizedTime = later }
            } else if offsetDecrease < 0,
                      nominal >= change.addingTimeInterval(Double(before)),
                      nominal < change.addingTimeInterval(Double(after)) {
                // GregorianCalendar resolves a nonexistent local time with the
                // preceding offset, shifting it forward by the actual gap.
                // Foundation can skip the entire day for a partial-hour gap.
                normalizedTime = nominal.addingTimeInterval(-Double(before))
            }
            transition = timeZone.nextDaylightSavingTimeTransition(after: change.addingTimeInterval(1))
        }
        var last = try milliseconds(normalizedTime)
        func advance(_ amount: Int64) throws {
            let (value, overflow) = last.addingReportingOverflow(amount)
            guard !overflow else { throw PredictionError.arithmeticOverflow }
            last = value
        }
        func largeDays(_ threshold: Int) -> [Int] { (1...7).filter { weekDays[$0] > threshold } }
        func advanceToDay(_ amount: Int64, allowed: [Int]) throws {
            repeat { try advance(amount) } while !allowed.contains(field(.weekday, last))
        }
        func result(_ schedule: ReleaseScheduleGuess.Schedule, _ days: [Int]?, multiple: Bool = false) -> ReleaseScheduleGuess {
            .init(schedule: schedule, days: days, nextExpectedDate: date(last), multipleReleasesPerDay: multiple)
        }
        func isWeekdays(_ days: [Int]) -> Bool { days == [2, 3, 4, 5, 6] }
        if dates.count - uniqueDays.count >= 2 {
            let averagePerDay = Float(dates.count) / Float(uniqueDays.count)
            let currentDay = normalized(last)
            let releasesToday = dates.filter { normalized($0) == currentDay }.count
            let distance = Float(releasesToday) <= averagePerDay ? try integer(medianDistance) : day
            let days = largeDays(0)
            try advanceToDay(distance, allowed: days)
            return result(days.count == 7 ? .daily : isWeekdays(days) ? .weekdays : .specificDays, days, multiple: true)
        }
        if abs(medianDistance - Float(day)) < Float(2 * hour) && averageDelta < Float(2 * hour) {
            try advance(day); return result(.daily, [2, 3, 4, 5, 6, 7, 1])
        }
        if abs(medianDistance - Float(week)) < Float(day) && averageDelta < Float(2 * day) {
            try advance(3 * day); try advanceToDay(day, allowed: [mostWeekDay])
            return result(.weekly, [mostWeekDay])
        }
        if abs(medianDistance - Float(2 * week)) < Float(day) && averageDelta < Float(2 * day) {
            try advance(10 * day); try advanceToDay(day, allowed: [mostWeekDay])
            return result(.biweekly, [mostWeekDay])
        }
        if abs(medianDistance - Float(30 * day)) < Float(5 * day) && averageDelta < Float(5 * day) {
            if monthDays[mostMonthDay] >= dates.count - wrongDays {
                try advance(2 * week)
                repeat { try advance(day) } while field(.day, last) != mostMonthDay
                return result(.monthly, nil)
            }
            try advance(3 * week + 3 * day); try advanceToDay(day, allowed: [mostWeekDay])
            return result(.fourweekly, [mostWeekDay])
        }
        let days = largeDays(singleDayOff)
        guard !days.isEmpty else { throw PredictionError.invalidCalendar }
        let averageDays = dates.count / days.count
        let balanced = days.allSatisfy { weekDays[$0] >= averageDays - singleDayOff }
        if balanced && medianDistance < Float(week) {
            try advanceToDay(day, allowed: days)
            return result(isWeekdays(days) ? .weekdays : .specificDays, days)
        }
        if days.count == 1 {
            try advanceToDay(day, allowed: days); return result(.weekly, days)
        }
        try advance(integer(0.6 * medianDistance))
        return result(.unknown, nil)
    }

    private static func milliseconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970 * 1000
        guard value.isFinite, value >= Double(Int64.min), value < Double(Int64.max) else { throw PredictionError.invalidDate }
        return Int64(value)
    }
    private static func integer(_ value: Float) throws -> Int64 {
        guard value.isFinite, Double(value) >= Double(Int64.min), Double(value) < Double(Int64.max) else {
            throw PredictionError.arithmeticOverflow
        }
        return Int64(value)
    }
}
