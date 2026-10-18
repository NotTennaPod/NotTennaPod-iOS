import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Years and Downloads statistics against the independent SQL/Java oracle
/// (`TestSupport/Data/statistics-tabs/expected/statistics-tabs.json`), written from
/// the pinned source without reading this code. Libraries come from the Android-schema fixtures through
/// the database import. The import brings Android downloads in as not downloaded, so each fixture's
/// `download_inputs` are re-marked as downloaded on iOS, with the stored size, before reading.
@Suite(.serialized) struct StatisticsTabsTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../TestSupport/Data/statistics-tabs").standardized
    nonisolated(unsafe) static let expected: [String: Any] = {
        let data = try! Data(contentsOf: fixtures.appendingPathComponent("expected/statistics-tabs.json"))
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()
    static func database(_ name: String) -> [String: Any] { (expected["databases"] as! [String: Any])[name] as! [String: Any] }
    private let formatter = StatisticsTextFormatter(locale: Locale(identifier: "en-US"), timeZone: TimeZone(identifier: "UTC")!)

    private func int64(_ value: Any?) -> Int64 { (value as? NSNumber)?.int64Value ?? -1 }
    private func float(_ value: Any?) -> Float { (value as? NSNumber)?.floatValue ?? .nan }

    /// Restores an Android fixture and re-marks the oracle's download inputs as iOS downloads.
    private func library(_ file: String, downloads: [[String: Any]], reset: Bool = false) async throws -> [LibraryFeed] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StatisticsTabs-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let restored = try AndroidDatabaseRestore.read(Self.fixtures.appendingPathComponent(file), staging: directory.appendingPathComponent("s"))
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try await store.installRestoredLibrary(restored, carrying: try await store.restoreCarryOver())
        for input in downloads {
            let id = int64(input["item_id"]), size = int64(input["filesize"])
            try await store.updateEpisode(id: id) {
                $0.userState.isDownloaded = true; $0.userState.localFileURL = "/fixture/\(id).mp3"
                $0.userState.downloadDate = Date(timeIntervalSince1970: 1_700_000_000)
                $0.details.media?.size = size
            }
        }
        if reset { try await store.resetPlayedDurationStatistics() }
        let feeds = try await store.feeds()
        try await store.close()
        return feeds
    }

    private func months(_ value: Any?) -> [MonthlyListening] {
        (value as? [[String: Any]] ?? []).map {
            MonthlyListening(year: Int(int64($0["year"])), month: Int(int64($0["month"])), playedMilliseconds: int64($0["time_played_ms"]))
        }
    }

    private func expectYears(_ snapshot: YearsStatisticsSnapshot, _ oracle: [String: Any], rows: Any?, _ label: String) {
        #expect(snapshot.monthly == months(oracle["monthly"]), "\(label) monthly")
        #expect(snapshot.chartMonths == months(oracle["chart_months"]), "\(label) chart months")
        let expectedRows = rows as? [[String: Any]] ?? []
        #expect(snapshot.years.map(\.year) == expectedRows.map { Int(int64($0["year"])) }, "\(label) year order")
        for (row, expected) in zip(snapshot.years, expectedRows) {
            #expect(row.playedMilliseconds == int64(expected["time_played_ms"]), "\(label) \(row.year)")
            #expect(formatter.duration(seconds: row.playedMilliseconds / 1000, hoursLabel: "hours") == expected["hours_text"] as? String,
                    "\(label) \(row.year) text")
        }
    }

    /// Bars, colours, year labels, separators and grid at the oracle's 1000×200 canvas, at the precision a
    /// person sees: every edge within one point and every bar height within 1 % of the chart.
    private func expectChart(_ months: [MonthlyListening], _ chart: [String: Any], _ label: String) {
        let layout = YearsBarChartLayout(months: months, width: 1000, height: 200)
        func near(_ a: Float, _ b: Float) -> Bool { abs(a - b) <= 1 }
        let bars = chart["bars"] as? [[String: Any]] ?? []
        #expect(layout.bars.count == bars.count, "\(label) bar count")
        for (bar, expected) in zip(layout.bars, bars) {
            #expect(bar.purple == (expected["color"] as? String == "purple"), "\(label) bar \(bar.index) colour")
            #expect(abs(bar.heightFraction - float(expected["height_fraction"])) <= 0.01, "\(label) bar \(bar.index) height")
            #expect(near(bar.left, float(expected["left"])) && near(bar.right, float(expected["right"])) && near(bar.top, float(expected["top"])),
                    "\(label) bar \(bar.index) frame")
        }
        let labels = chart["year_labels"] as? [[String: Any]] ?? []
        #expect(layout.yearLabels.map(\.text) == labels.map { $0["text"] as? String ?? "" }, "\(label) year labels")
        for (value, expected) in zip(layout.yearLabels, labels) {
            #expect(value.index == Int(int64(expected["index"])) && near(value.x, float(expected["x"])) && near(value.baseline, float(expected["y"])),
                    "\(label) label \(value.text)")
        }
        let separators = chart["january_separators"] as? [[String: Any]] ?? []
        #expect(layout.separators.map(\.index) == separators.map { Int(int64($0["index"])) }, "\(label) separators")
        for (value, expected) in zip(layout.separators, separators) { #expect(near(value.x, float(expected["x"])), "\(label) separator x") }
        let grid = chart["grid_lines"] as? [[String: Any]] ?? []
        #expect(layout.gridLines.map(\.label) == grid.map { $0["label"] as? String ?? "" }, "\(label) grid labels")
        for (value, expected) in zip(layout.gridLines, grid) {
            #expect(value.valueMilliseconds == int64(expected["value_ms"]) && near(value.y, float(expected["y"])), "\(label) grid \(value.label)")
        }
        #expect(layout.maxValue == int64(chart["max_value_ms"]), "\(label) max")
    }

    private func expectDownloads(_ snapshot: DownloadStatisticsSnapshot, _ oracle: [String: Any], _ label: String) {
        let rows = oracle["rows"] as? [[String: Any]] ?? []
        #expect(snapshot.rows.map(\.feedID) == rows.map { int64($0["feed_id"]) }, "\(label) order")
        let shares = StatisticsPieShares(values: snapshot.rows.map { Float($0.bytes) })
        for (index, (row, expected)) in zip(snapshot.rows, rows).enumerated() {
            #expect(row.title == expected["title"] as? String, "\(label) \(row.feedID) title")
            #expect(row.bytes == int64(expected["total_download_size"]), "\(label) \(row.feedID) size")
            #expect(row.downloadedEpisodes == int64(expected["episodes_download_count"]), "\(label) \(row.feedID) count")
            let text = expected["value_text"] as? String ?? ""
            #expect(text.hasPrefix(formatter.fileSize(bytes: row.bytes) + " • "), "\(label) \(row.feedID) size text \(text)")
            #expect(String(format: "#FF%06X", shares.color(index)) == expected["chip_color"] as? String, "\(label) \(row.feedID) chip")
        }
        #expect(snapshot.totalBytes == int64(oracle["exact_total_bytes"]), "\(label) total")
        #expect(snapshot.totalEpisodes == int64(oracle["downloaded_episodes"]), "\(label) episodes")
        #expect(formatter.fileSize(bytes: snapshot.totalBytes) == oracle["header_value_text"] as? String, "\(label) header")
    }

    @Test func mainDatabaseMatchesOracleInEveryTimeZone() async throws {
        let oracle = Self.database("main")
        let years = oracle["years"] as! [String: Any], downloads = oracle["downloads"] as! [String: Any]
        let feeds = try await library("statistics.db", downloads: downloads["download_inputs"] as! [[String: Any]])
        // UTC months: the device zone never matters. Change it inside the test and restore it.
        let original = NSTimeZone.default, originalTZ = ProcessInfo.processInfo.environment["TZ"]
        defer {
            NSTimeZone.default = original
            if let originalTZ { setenv("TZ", originalTZ, 1) } else { unsetenv("TZ") }
            tzset()
        }
        for zone in ["UTC", "America/Los_Angeles", "Asia/Tokyo", "Pacific/Kiritimati"] {
            NSTimeZone.default = TimeZone(identifier: zone)!; setenv("TZ", zone, 1); tzset()
            let snapshot = YearsStatisticsSnapshot(feeds: feeds)
            expectYears(snapshot, years, rows: years["year_rows"], "main \(zone)")
            expectChart(snapshot.chartMonths, years["chart"] as! [String: Any], "main \(zone)")
            #expect(snapshot.years.reduce(0) { $0 + $1.playedMilliseconds } == int64(years["total_all_years_ms"]))
            expectDownloads(DownloadStatisticsSnapshot(feeds: feeds), downloads, "main \(zone)")
        }
    }

    @Test func resetEmptiesYearsAndLeavesDownloads() async throws {
        let oracle = Self.database("after_reset")
        let years = oracle["years"] as! [String: Any], downloads = oracle["downloads"] as! [String: Any]
        let feeds = try await library("statistics.db", downloads: downloads["download_inputs"] as! [[String: Any]], reset: true)
        let snapshot = YearsStatisticsSnapshot(feeds: feeds)
        // Android adds a "0" / "0.0 hours" row here; the recommended outcome has none.
        expectYears(snapshot, years, rows: (years["recommended"] as! [String: Any])["year_rows"], "after reset")
        #expect(snapshot.years.isEmpty && snapshot.chartMonths.isEmpty)
        expectChart(snapshot.chartMonths, years["chart"] as! [String: Any], "after reset")
        expectDownloads(DownloadStatisticsSnapshot(feeds: feeds), downloads, "after reset")
    }

    @Test func emptyAndMalformedDatabases() async throws {
        let empty = Self.database("empty")
        let emptyYears = empty["years"] as! [String: Any], emptyDownloads = empty["downloads"] as! [String: Any]
        let emptyFeeds = try await library("statistics-empty.db", downloads: emptyDownloads["download_inputs"] as! [[String: Any]])
        let emptySnapshot = YearsStatisticsSnapshot(feeds: emptyFeeds)
        expectYears(emptySnapshot, emptyYears, rows: (emptyYears["recommended"] as! [String: Any])["year_rows"], "empty")
        expectChart(emptySnapshot.chartMonths, emptyYears["chart"] as! [String: Any], "empty")
        expectDownloads(DownloadStatisticsSnapshot(feeds: emptyFeeds), emptyDownloads, "empty")

        // A last-played time after year 9999: Android's page spins forever; iOS leaves that row out.
        let malformed = Self.database("malformed")
        let years = malformed["years"] as! [String: Any], downloads = malformed["downloads"] as! [String: Any]
        let recommended = years["recommended"] as! [String: Any]
        let feeds = try await library("statistics-malformed.db", downloads: downloads["download_inputs"] as! [[String: Any]])
        let snapshot = YearsStatisticsSnapshot(feeds: feeds)
        expectYears(snapshot, recommended, rows: recommended["year_rows"], "malformed")
        expectChart(snapshot.chartMonths, recommended["chart"] as! [String: Any], "malformed")
        expectDownloads(DownloadStatisticsSnapshot(feeds: feeds), downloads, "malformed")
    }

    @Test func chartScenariosMatchOracle() {
        for scenario in Self.expected["chart_scenarios"] as! [[String: Any]] {
            let name = scenario["name"] as? String ?? ""
            let snapshot = YearsStatisticsSnapshot(monthly: months(scenario["monthly"]))
            // Empty input: no bogus year-0 row; every other scenario equals Android.
            expectYears(snapshot, scenario, rows: name == "empty" ? [] : scenario["year_rows"], name)
            expectChart(snapshot.chartMonths, scenario["chart"] as! [String: Any], name)
        }
    }

    @Test func pieScenariosMatchOracle() {
        for scenario in Self.expected["pie_scenarios"] as! [[String: Any]] {
            let values = (scenario["values"] as? [Any] ?? []).map { float($0) }
            let shares = StatisticsPieShares(values: values)
            #expect(values.indices.map { String(format: "#FF%06X", shares.color($0)) } == scenario["colors"] as? [String],
                    "\(scenario["name"] ?? "")")
        }
    }

    /// Month edges in UTC: the last and first millisecond of a month and year, a leap day, and the
    /// last second SQLite can place (9999-12-31T23:59:59Z).
    @Test func utcMonthBoundaries() {
        func key(_ iso: String) -> Int? {
            let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return YearsStatisticsSnapshot.utcMonthKey(milliseconds: Int64((parser.date(from: iso)!.timeIntervalSince1970 * 1000).rounded()))
        }
        #expect(key("2025-01-31T23:59:59.999Z") == 2025 * 12 + 0)
        #expect(key("2025-02-01T00:00:00.000Z") == 2025 * 12 + 1)
        #expect(key("2024-12-31T23:59:59.999Z") == 2024 * 12 + 11)
        #expect(key("2024-02-29T12:00:00.000Z") == 2024 * 12 + 1)
        #expect(key("2024-03-01T00:00:00.000Z") == 2024 * 12 + 2)
        #expect(key("1970-01-01T00:00:00.001Z") == 1970 * 12)
        #expect(YearsStatisticsSnapshot.utcMonthKey(milliseconds: 253_402_300_799_999) == 9999 * 12 + 11)
        #expect(YearsStatisticsSnapshot.utcMonthKey(milliseconds: 253_402_300_800_000) == nil)
        #expect(YearsStatisticsSnapshot.utcMonthKey(milliseconds: .max) == nil)
    }

    /// Whole played duration lands in the month of the last play; not-subscribed feeds count for Years
    /// and are left out of Downloads; zero-duration and zero-timestamp rows do not count.
    @Test func countingRules() {
        func episode(_ id: Int64, played: Int64, last: Int64, downloaded: Bool = false, size: Int64 = 0, media: Bool = true) -> LibraryEpisode {
            var state = EpisodeUserState()
            state.playedDurationMilliseconds = played; state.lastPlayedTimeMilliseconds = last
            if downloaded { state.isDownloaded = true; state.downloadDate = Date(timeIntervalSince1970: 1_000) }
            return .init(id: id, details: .init(media: media ? .init(url: "fixture://\(id)", size: size, durationMilliseconds: 1) : nil), userState: state)
        }
        let june = Int64(1_750_000_000_000) // 2025-06-15T15:06:40Z
        var preview = LibraryFeed(id: 3, source: "fixture://3", metadata: .init(format: .rss, title: "Preview"),
                                  episodes: [episode(31, played: 60_000, last: june, downloaded: true, size: 500)])
        preview.subscriptionState = .notSubscribed
        var archived = LibraryFeed(id: 2, source: "fixture://2", metadata: .init(format: .rss, title: "Archived"),
                                   episodes: [episode(21, played: 0, last: june, downloaded: true, size: 10)])
        archived.subscriptionState = .archived
        let subscribed = LibraryFeed(id: 1, source: "fixture://1", metadata: .init(format: .rss, title: "Subscribed"), episodes: [
            episode(11, played: 120_000, last: june), episode(12, played: 30_000, last: 0),
            episode(13, played: 45_000, last: june, media: false), episode(14, played: 0, last: 0)])
        let empty = LibraryFeed(id: 4, source: "fixture://4", metadata: .init(format: .rss, title: "Empty"), episodes: [])
        let feeds = [preview, archived, subscribed, empty]
        let years = YearsStatisticsSnapshot(feeds: feeds)
        #expect(years.monthly == [.init(year: 2025, month: 6, playedMilliseconds: 180_000)])
        #expect(years.years == [.init(year: 2025, playedMilliseconds: 180_000)])
        let downloads = DownloadStatisticsSnapshot(feeds: feeds)
        #expect(downloads.rows.map(\.feedID) == [2, 1])
        #expect(downloads.rows.map(\.bytes) == [10, 0])
        #expect(downloads.totalBytes == 10 && downloads.totalEpisodes == 1)
    }

    @Test func tabsAndMenusFollowSource() {
        #expect(StatisticsTab.allCases.map(\.titleKey) == ["subscriptions_label", "years_statistics_label", "downloads_label"])
        #expect(StatisticsTab.allCases.map(\.showsFilter) == [true, false, false])
        #expect(StatisticsTab.allCases.map(\.showsReset) == [true, true, false])
    }

    @MainActor @Test func pageLoaderPublishesLatestReadOnly() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let calls = Mutex(0)
        let loader = StatisticsPageLoader<YearsStatisticsSnapshot>(read: {
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 1 { for await _ in gate.stream { break } }
            var state = EpisodeUserState(); state.playedDurationMilliseconds = Int64(call) * 3_600_000
            state.lastPlayedTimeMilliseconds = 1_750_000_000_000
            return [LibraryFeed(id: 1, source: "fixture://1", metadata: .init(format: .rss), episodes: [
                .init(id: 1, details: .init(media: .init(url: "fixture://e", size: 0, durationMilliseconds: 1)), userState: state)])]
        }, make: YearsStatisticsSnapshot.init(feeds:))
        let first = loader.load()
        #expect(loader.state == .loading)
        // The first read is blocked at the gate before the second load starts.
        while calls.withLock({ $0 }) == 0 { await Task.yield() }
        let second = loader.load()
        await second.value
        gate.continuation.yield(); gate.continuation.finish()
        await first.value
        #expect(loader.state == .loaded(YearsStatisticsSnapshot(monthly: [.init(year: 2025, month: 6, playedMilliseconds: 7_200_000)])))
        loader.cancel()
        #expect(loader.state == .idle)
    }
}
