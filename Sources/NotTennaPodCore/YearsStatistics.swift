import Foundation

/// Listening time of one UTC calendar month (`DBReader.MonthlyStatisticsItem`).
public struct MonthlyListening: Equatable, Sendable {
    public let year: Int
    public let month: Int
    public let playedMilliseconds: Int64
    public init(year: Int, month: Int, playedMilliseconds: Int64) {
        self.year = year; self.month = month; self.playedMilliseconds = playedMilliseconds
    }
}

/// One row of the Years list: a calendar year that has listening.
public struct YearListening: Equatable, Sendable {
    public let year: Int
    public let playedMilliseconds: Int64
    public init(year: Int, playedMilliseconds: Int64) { self.year = year; self.playedMilliseconds = playedMilliseconds }
}

/// Years tab data (`PodDBAdapter.getMonthlyStatisticsCursor` 1228–1237 and
/// `YearStatisticsListAdapter.update` 66–98).
public struct YearsStatisticsSnapshot: Equatable, Sendable {
    /// The SQL rows: one per UTC month with listening, oldest first.
    public let monthly: [MonthlyListening]
    /// First to last month with listening; months in between without listening are 0.
    public let chartMonths: [MonthlyListening]
    /// Years with listening, newest first. Empty without listening: Android's spurious
    /// "0" / "0.0 hours" row is not copied.
    public let years: [YearListening]

    /// Every media row with `last_played_time > 0` and `played_duration > 0`, in feeds of any
    /// subscription state, grouped by the **UTC** month of its last statistics timestamp. The
    /// period filter and "include marked as played" do not apply. A timestamp SQLite cannot place
    /// in a month (after year 9999) is left out instead of failing the whole page.
    public init(feeds: [LibraryFeed]) { self.init(feeds: feeds, units: [:]) }

    /// `units`: the library's statistics units by episode ID, each a media row of its own (schema 20).
    public init(feeds: [LibraryFeed], units: [Int64: [LibraryStatisticsUnit]]) {
        var sums: [Int: Int64] = [:]
        for feed in feeds {
            for episode in LibraryStatistics.rows(of: feed, units: units) where episode.details.media != nil {
                let state = episode.userState
                guard state.lastPlayedTimeMilliseconds > 0, state.playedDurationMilliseconds > 0,
                      let key = Self.utcMonthKey(milliseconds: state.lastPlayedTimeMilliseconds) else { continue }
                sums[key] = Self.saturatingAdd(sums[key] ?? 0, state.playedDurationMilliseconds)
            }
        }
        self.init(monthly: sums.keys.sorted().map {
            MonthlyListening(year: $0 / 12, month: $0 % 12 + 1, playedMilliseconds: sums[$0]!)
        })
    }

    /// `YearStatisticsListAdapter.update` for the SQL rows (oldest first).
    public init(monthly: [MonthlyListening]) {
        self.monthly = monthly
        var chart: [MonthlyListening] = [], years: [YearListening] = []
        var last: Int?
        for item in monthly {
            let key = item.year * 12 + item.month - 1
            if let previous = last {
                for gap in stride(from: previous + 1, to: key, by: 1) {
                    chart.append(.init(year: gap / 12, month: gap % 12 + 1, playedMilliseconds: 0))
                }
            }
            chart.append(item)
            last = key
            if years.last?.year == item.year {
                let current = years.removeLast()
                years.append(.init(year: item.year, playedMilliseconds: Self.saturatingAdd(current.playedMilliseconds, item.playedMilliseconds)))
            } else {
                years.append(.init(year: item.year, playedMilliseconds: item.playedMilliseconds))
            }
        }
        chartMonths = chart
        self.years = years.reversed()
    }

    /// `strftime('%Y'/'%m', datetime(last_played_time/1000, 'unixepoch'))`: integer seconds,
    /// UTC, valid through 9999-12-31T23:59:59Z. Returns `year * 12 + month - 1`.
    static func utcMonthKey(milliseconds: Int64) -> Int? {
        let seconds = milliseconds / 1000
        guard seconds >= 0, seconds <= 253_402_300_799 else { return nil }
        // Days-to-civil (proleptic Gregorian), H. Hinnant.
        let z = seconds / 86_400 + 719_468
        let era = z / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        return Int(year) * 12 + Int(month) - 1
    }

    static func saturatingAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? (right > 0 ? .max : .min) : value
    }
}

/// `BarChartView.BarChartDrawable.draw` (48–127) as geometry, with Java float arithmetic.
public struct YearsBarChartLayout: Equatable, Sendable {
    public struct Bar: Equatable, Sendable {
        public let index: Int
        public let year: Int, month: Int
        public let playedMilliseconds: Int64
        /// Alternates per year: false = theme accent, true = purple `#9C27B0`.
        public let purple: Bool
        public let heightFraction: Float
        public let left: Float, right: Float, top: Float
    }
    public struct YearLabel: Equatable, Sendable {
        public let index: Int
        public let text: String
        public let x: Float, baseline: Float
    }
    public struct GridLine: Equatable, Sendable {
        public let label: String
        public let valueMilliseconds: Int64
        public let y: Float
        public let textBaseline: Float
    }
    public struct Separator: Equatable, Sendable {
        public let index: Int
        public let x: Float
    }
    public let width: Float, height: Float
    public let barAreaHeight: Float
    public let textSize: Float
    public let maxValue: Int64
    public let bars: [Bar]
    public let yearLabels: [YearLabel]
    /// Thin vertical lines where a new bar colour starts in January.
    public let separators: [Separator]
    /// Full-width dashed lines: `floor(max / 10 h) × 10 h`, then half of that.
    public let gridLines: [GridLine]

    public init(months data: [MonthlyListening], width: Float, height: Float) {
        self.width = width; self.height = height
        let barHeight = height * 0.9, textPadding = width * 0.05
        let stepSize = (width - textPadding) / Float(data.count + 2)
        let textSize = height * 0.06
        barAreaHeight = barHeight; self.textSize = textSize
        var maxValue: Int64 = 1
        for item in data { maxValue = max(maxValue, item.playedMilliseconds) }
        self.maxValue = maxValue
        var colorIndex = 0, previousYear = data.first?.year ?? 0
        var monthsInFirstYear = 0
        while monthsInFirstYear < data.count && data[monthsInFirstYear].year == data[0].year { monthsInFirstYear += 1 }
        var bars: [Bar] = [], labels: [YearLabel] = [], separators: [Separator] = []
        for (i, item) in data.enumerated() {
            let x = textPadding + Float(i + 1) * stepSize
            if previousYear != item.year || (i == 0 && monthsInFirstYear > 4) {
                previousYear = item.year
                colorIndex += 1
                if i < data.count - 4 {
                    labels.append(.init(index: i, text: String(item.year), x: x + stepSize,
                                        baseline: barHeight + (height - barHeight + textSize) / 2))
                }
                if item.month == 1 { separators.append(.init(index: i, x: x)) }
            }
            let fraction = Float(max(0.005, Double(Float(item.playedMilliseconds) / Float(maxValue))))
            let y = (1 - fraction) * barHeight
            bars.append(.init(index: i, year: item.year, month: item.month, playedMilliseconds: item.playedMilliseconds,
                              purple: colorIndex % 2 == 1, heightFraction: fraction,
                              left: x, right: x + stepSize * 0.95, top: y))
        }
        let oneHour: Int64 = 3_600_000
        let maxLine = Float((Double(maxValue) / (10.0 * Double(oneHour))).rounded(.down) * 10 * Double(oneHour))
        let midLine = maxLine / 2
        func line(_ value: Float) -> GridLine {
            let y = (1 - value / Float(maxValue)) * barHeight
            return GridLine(label: String(Int64(value) / oneHour), valueMilliseconds: Int64(value), y: y,
                            textBaseline: y + 1.2 * textSize)
        }
        gridLines = [line(maxLine), line(midLine)]
        self.bars = bars; yearLabels = labels
        self.separators = separators
    }
}
