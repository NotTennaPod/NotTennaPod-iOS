// From a pattern's fields to an instant: the date is year, month and day of month on the Julian calendar before
// 15 October 1582 and the Gregorian one from then; the zone offset is the one read, or the named zone's at that local
// time. A strict pattern also needs every field in range and every field to come back unchanged from the instant (so
// a wrong weekday, 31 April or a time in a daylight-saving gap fails). All instant arithmetic wraps.

/// What a pattern has read.
struct DateFields {
    enum Field: Int, CaseIterable {
        case year, month /* 0 = January */, day /* of the month */, weekday /* 1 = Sunday */, hour /* of the day */
        case minute, second, millis, zoneOffset /* ms */, dstOffset /* ms */
    }

    /// The ranges a strict pattern accepts.
    static let strictRanges: [ClosedRange<Int64>] = [
        1...292_278_994, 0...11, 1...31, 1...7, 0...23, 0...59, 0...59, 0...999,
        (-13 * 3_600_000)...(14 * 3_600_000), 0...(2 * 3_600_000)
    ]

    private var values = [Int64](repeating: 0, count: Field.allCases.count)
    private var isSet = [Bool](repeating: false, count: Field.allCases.count)
    /// The zone of a zone name; nil is GMT.
    var zone: ParityDates.Zone?
    /// A two-digit year equal to the window's start year.
    var ambiguousYear = false

    /// A field's value; 0 when unset.
    subscript(_ field: Field) -> Int64 {
        get { values[field.rawValue] }
        set { values[field.rawValue] = newValue }
    }

    func has(_ field: Field) -> Bool { isSet[field.rawValue] }

    mutating func record(_ field: Field, _ value: Int64) {
        values[field.rawValue] = value
        isSet[field.rawValue] = true
    }

    mutating func forget(_ field: Field) {
        values[field.rawValue] = 0
        isSet[field.rawValue] = false
    }

    /// Whether every field read comes back from the instant t.
    func roundTrips(_ t: Int64) -> Bool {
        var (raw, dst) = ParityDates.Zone.offsets(zone, at: t)
        if has(.zoneOffset) { raw = self[.zoneOffset] }
        if has(.dstOffset) { dst = self[.dstOffset] }
        let local = t &+ raw &+ dst
        let day = DateCalendar.floorDiv(local, DateCalendar.dayMs) + DateCalendar.epochDay
        let ms = DateCalendar.floorMod(local, DateCalendar.dayMs)
        var (y, m, d) = day >= DateCalendar.cutover ? DateCalendar.gregorianDate(day) : DateCalendar.julianDate(day)
        if y < 1 { y = 1 - y }  // the year of the era BC
        let got: [Int64] = [y, m - 1, d, DateCalendar.floorMod(day, 7) + 1, ms / 3_600_000, ms / 60_000 % 60,
                            ms / 1000 % 60, ms % 1000]
        for (k, v) in got.enumerated() where isSet[k] && values[k] != v { return false }
        return true
    }
}

/// Day numbers: day 1 is 0001-01-01 on the proleptic Gregorian calendar.
enum DateCalendar {
    static let dayMs: Int64 = 86_400_000
    /// 1970-01-01.
    static let epochDay: Int64 = 719_163
    /// 1582-10-15, the first Gregorian day.
    static let cutover: Int64 = 577_736
    /// 0001-01-01 on the Julian calendar.
    static let julianDay: Int64 = -1

    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return a % b != 0 && (a < 0) != (b < 0) ? q - 1 : q
    }

    static func floorMod(_ a: Int64, _ b: Int64) -> Int64 { a &- floorDiv(a, b) &* b }

    static func gregorianLeap(_ y: Int64) -> Bool { y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) }

    static func julianLeap(_ y: Int64) -> Bool { y % 4 == 0 }

    /// The day of the year before month m starts (with February counted as 30 days), corrected for February.
    static func monthStart(_ m: Int64, leap: Bool) -> Int64 {
        let d = floorDiv(367 &* m &- 362, 12)
        return m > 2 ? d - (leap ? 1 : 2) : d
    }

    /// The day number of a proleptic Gregorian date (astronomical years: 0 is 1 BC).
    static func gregorianDay(_ y: Int64, _ m: Int64, _ d: Int64) -> Int64 {
        let y1 = y &- 1
        return 365 &* y1 &+ floorDiv(y1, 4) &- floorDiv(y1, 100) &+ floorDiv(y1, 400)
            &+ monthStart(m, leap: gregorianLeap(y)) &+ d
    }

    /// The day number of a proleptic Julian date (astronomical years).
    static func julianDayOf(_ y: Int64, _ m: Int64, _ d: Int64) -> Int64 {
        let y1 = y &- 1
        return julianDay - 1 &+ 365 &* y1 &+ floorDiv(y1, 4) &+ monthStart(m, leap: julianLeap(y)) &+ d
    }

    /// The proleptic Gregorian date of a day number.
    static func gregorianDate(_ day: Int64) -> (Int64, Int64, Int64) {
        let d0 = day &- 1
        let n400 = floorDiv(d0, 146_097), d1 = floorMod(d0, 146_097)
        let n100 = d1 / 36_524, d2 = d1 % 36_524
        let n4 = d2 / 1461, d3 = d2 % 1461
        let n1 = d3 / 365
        var y = 400 &* n400 &+ 100 * n100 &+ 4 * n4 &+ n1
        if n100 != 4 && n1 != 4 { y = y &+ 1 }
        let (m, d) = monthOf(day, y, gregorianDay)
        return (y, m, d)
    }

    /// The proleptic Julian date of a day number.
    static func julianDate(_ day: Int64) -> (Int64, Int64, Int64) {
        let y = floorDiv(4 &* (day &- julianDay) &+ 1464, 1461)
        let (m, d) = monthOf(day, y, julianDayOf)
        return (y, m, d)
    }

    /// The month and day of a day number in year y.
    private static func monthOf(_ day: Int64, _ y: Int64, _ dayOf: (Int64, Int64, Int64) -> Int64) -> (Int64, Int64) {
        let prior = day &- dayOf(y, 1, 1)
        var correction: Int64 = 0
        if day >= dayOf(y, 3, 1) {
            correction = dayOf(y, 3, 1) &- dayOf(y, 2, 1) == 29 ? 1 : 2
        }
        let m = floorDiv(12 &* (prior &+ correction) &+ 373, 367)
        return (m, day &- dayOf(y, m, 1) &+ 1)
    }
}

/// Where two-digit years fall: the 100 years from 80 years before now (UTC, proleptic Gregorian).
struct DateYearWindow {
    /// The window's first instant.
    let start: Int64
    /// Its start year's century.
    let base: Int64
    /// Its start year within the century (negative for a negative year).
    let ambiguous: Int64

    init(now: Int64) {
        let day = DateCalendar.floorDiv(now, DateCalendar.dayMs)
        var (y, m, d) = DateCalendar.gregorianDate(day + DateCalendar.epochDay)
        y -= 80
        if m == 2 && d == 29 && !DateCalendar.gregorianLeap(y) {
            d = 28  // the only day that can be missing 80 years earlier
        }
        start = (DateCalendar.gregorianDay(y, m, d) &- DateCalendar.epochDay) &* DateCalendar.dayMs
            &+ DateCalendar.floorMod(now, DateCalendar.dayMs)
        base = y / 100 * 100
        ambiguous = y % 100
    }
}

extension DateParser {
    /// The fields as an instant, or nil when a strict pattern's fields are out of range or do not come back.
    func resolve(_ f: DateFields, lenient: Bool) -> Int64? {
        if !lenient {
            for field in DateFields.Field.allCases where f.has(field) {
                if !DateFields.strictRanges[field.rawValue].contains(f[field]) { return nil }
            }
        }
        var year: Int64 = f.has(.year) ? f[.year] : 1970
        let tod = ((f[.hour] &* 60 &+ f[.minute]) &* 60 &+ f[.second]) &* 1000 &+ f[.millis]
        var month = f[.month]
        year = year &+ DateCalendar.floorDiv(month, 12)
        month = DateCalendar.floorMod(month, 12) + 1
        var add = DateCalendar.floorDiv(tod, DateCalendar.dayMs)
        if f.has(.day) { add = add &+ (f[.day] &- 1) }
        let gregorian = DateCalendar.gregorianDay(year, month, 1) &+ add
        let julian = DateCalendar.julianDayOf(year, month, 1) &+ add
        let day: Int64
        if year < 1582 {
            day = julian
        } else if gregorian >= DateCalendar.cutover {
            day = gregorian
        } else if julian < DateCalendar.cutover || lenient {
            // Strictly, the ten days the reform dropped are no date.
            day = julian
        } else {
            return nil
        }
        let local = (day &- DateCalendar.epochDay) &* DateCalendar.dayMs &+ DateCalendar.floorMod(tod, DateCalendar.dayMs)

        let instant: Int64
        let zone = f.zone
        let zoneRaw = Int64(zone?.raw ?? 0)
        if f.has(.zoneOffset) {
            // A numeric offset or GMT, always read with a DST offset.
            instant = local &- f[.zoneOffset] &- f[.dstOffset]
        } else if f.has(.dstOffset) {
            let (raw, _) = ParityDates.Zone.offsets(zone, at: local &- zoneRaw)
            instant = local &- raw &- f[.dstOffset]
        } else {
            let u = local &- zoneRaw
            var (raw, dst) = ParityDates.Zone.offsets(zone, at: u)
            if dst != 0 && !ParityDates.Zone.isDaylight(zone, at: u &- dst) { dst = 0 }
            instant = local &- raw &- dst
        }
        if !lenient && !f.roundTrips(instant) { return nil }
        return instant
    }
}
