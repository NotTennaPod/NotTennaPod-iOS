import Foundation
import Testing
@testable import NotTennaPodCore

struct StatisticsPeriodTests {
    private func milliseconds(_ iso: String) -> Int64 {
        Int64(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 * 1000)
    }

    private func calendar(_ zone: String = "UTC") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }

    private func options(oldest: String = "2024-11-05T12:00:00Z",
                         now: String = "2026-09-23T12:00:00Z", zone: String = "UTC") throws -> StatisticsPeriodOptions {
        try StatisticsPeriodOptions(oldestMilliseconds: milliseconds(oldest), nowMilliseconds: milliseconds(now),
            calendar: calendar(zone), locale: Locale(identifier: "en_US"))
    }

    @Test func matchesExtractedGregorianMonthBoundariesWithoutClaimingAndroidLabels() throws {
        struct Case: Decodable {
            let id, zone, locale, hostCalendar: String
            let oldest, now: Int64
            let fromDates, toDates: [Int64]
        }
        struct Fixture: Decodable { let kind, sourceSHA256: String; let cases: [Case] }
        let file = try #require(Bundle.module.url(forResource: "calendar-oracle", withExtension: "json",
            subdirectory: "Fixtures/StatisticsPeriodFixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
        #expect(fixture.kind == "transformed-host-Java-extraction-not-Android-UI")
        #expect(fixture.sourceSHA256 == "c496c8abc5753ab8560f00b671a9825cee7316c1b2aad20143471310d988d663")
        #expect(fixture.cases.count == 160)
        let cases = fixture.cases.filter { $0.hostCalendar == "java.util.GregorianCalendar" }
        #expect(cases.count == 128)
        // Retain and explicitly verify the raw source
        // defect; the intended recovery is a separately approved exception.
        let recoveredIDs = Set(["en-US", "de-DE", "ar-EG", "ja-JP"].map {
            "empty-exact-UTC-month/UTC/" + $0
        })
        #expect(cases.filter { recoveredIDs.contains($0.id) }.count == 4)
        for item in cases {
            let result = try StatisticsPeriodOptions(oldestMilliseconds: item.oldest, nowMilliseconds: item.now,
                calendar: calendar(item.zone), locale: Locale(identifier: item.locale))
            if recoveredIDs.contains(item.id) {
                #expect(item.oldest == 1_788_220_800_000 && item.now == 1_788_220_800_000)
                #expect(item.fromDates.isEmpty && item.toDates == [Int64.max])
                #expect(result.from.map(\.timestamp) == [1_788_220_800_000], "\(item.id)")
                #expect(result.to.map(\.timestamp) == [1_790_812_800_000, Int64.max], "\(item.id)")
            } else {
                #expect(result.from.map(\.timestamp) == item.fromDates, "\(item.id)")
                #expect(result.to.map(\.timestamp) == item.toDates, "\(item.id)")
            }
            #expect(result.to.last?.label == .today)
            #expect(result.to.last?.timestamp == .max)
        }
    }

    @Test func defaultsRestoreAndUnchangedOKNormalizesFromToOldestMonth() throws {
        let saved = StatisticsPeriodPreferences()
        #expect(saved == .init(includeMarkedAsPlayed: false, timeFrom: 0, timeTo: .max))
        let values = try options()
        let draft = StatisticsPeriodDraft(preferences: saved, options: values)
        #expect(values.from.count == 23 && values.to.count == 24)
        #expect(values.from.first?.label == .month("Nov 2024"))
        #expect(values.to[22].label == .month("Sep 2026"))
        #expect(draft.fromIndex == 0 && draft.toIndex == 23 && draft.datesEnabled)
        #expect(draft.confirmedPreferences() == .init(timeFrom: milliseconds("2024-11-01T00:00:00Z")))
    }

    @Test func pastYearIsTwelveNamedMonthsAndAllTimeHasTodaySentinel() throws {
        var draft = StatisticsPeriodDraft(preferences: .init(), options: try options())
        draft.selectPastYear()
        #expect(draft.confirmedPreferences() == .init(timeFrom: milliseconds("2025-10-01T00:00:00Z"),
            timeTo: milliseconds("2026-10-01T00:00:00Z")))
        draft.selectAllTime()
        #expect(draft.confirmedPreferences() == .init(timeFrom: milliseconds("2024-11-01T00:00:00Z")))
    }

    @Test func shortHistoryPresetsClampToAvailableMonth() throws {
        var draft = StatisticsPeriodDraft(preferences: .init(), options: try options(oldest: "2026-09-23T11:00:00Z"))
        draft.selectPastYear()
        #expect(draft.confirmedPreferences() == .init(timeFrom: milliseconds("2026-09-01T00:00:00Z"),
            timeTo: milliseconds("2026-10-01T00:00:00Z")))
        draft.selectAllTime()
        #expect(draft.confirmedPreferences()?.timeTo == .max)
    }

    @Test func markedToggleDisablesEditingRetainsDraftAndConfirmationDiscardsSavedRange() throws {
        let saved = StatisticsPeriodPreferences(timeFrom: milliseconds("2026-02-01T00:00:00Z"),
            timeTo: milliseconds("2026-04-01T00:00:00Z"))
        var draft = StatisticsPeriodDraft(preferences: saved, options: try options())
        let indices = [draft.fromIndex, draft.toIndex]
        draft.includeMarkedAsPlayed = true
        #expect(!draft.datesEnabled)
        #expect(!draft.selectFrom(0) && !draft.selectTo(0))
        draft.selectAllTime(); draft.selectPastYear()
        #expect([draft.fromIndex, draft.toIndex] == indices)
        #expect(draft.confirmedPreferences() == .init(includeMarkedAsPlayed: true))
        draft.includeMarkedAsPlayed = false
        #expect(draft.confirmedPreferences() == saved)
        draft.includeMarkedAsPlayed = true
        var reopened = StatisticsPeriodDraft(preferences: try #require(draft.confirmedPreferences()), options: try options())
        reopened.includeMarkedAsPlayed = false
        #expect(reopened.confirmedPreferences() == .init(timeFrom: milliseconds("2024-11-01T00:00:00Z")))
    }

    @Test func selectionRoundsUpAndPreservesReversedOrEqualBounds() throws {
        let values = try options()
        var draft = StatisticsPeriodDraft(preferences: .init(timeFrom: milliseconds("2026-02-15T00:00:00Z"),
            timeTo: milliseconds("2026-02-01T00:00:00Z")), options: values)
        #expect(draft.confirmedPreferences() == .init(timeFrom: milliseconds("2026-03-01T00:00:00Z"),
            timeTo: milliseconds("2026-02-01T00:00:00Z")))
        let selectedFrom = draft.selectFrom(3) // Feb2025 starts at the same instant Jan2025 To ends.
        let selectedTo = draft.selectTo(2)
        #expect(selectedFrom && selectedTo)
        #expect(draft.confirmedPreferences()?.timeFrom == draft.confirmedPreferences()?.timeTo)
        let before = draft
        #expect(!draft.selectFrom(-1) && !draft.selectTo(999))
        #expect(draft == before)
        let beyond = StatisticsPeriodDraft(preferences: .init(timeFrom: .max), options: values)
        #expect(beyond.fromIndex == 0) // Source spinner default when no candidate reaches saved From.
    }

    @Test func timezoneReentryUsesSavedAbsoluteBoundsUntilUserConfirms() throws {
        let saved = StatisticsPeriodPreferences(timeFrom: milliseconds("2026-03-01T00:00:00Z"),
            timeTo: milliseconds("2026-04-01T00:00:00Z"))
        let la = StatisticsPeriodDraft(preferences: saved, options: try options(zone: "America/Los_Angeles"))
        #expect(la.confirmedPreferences() == .init(timeFrom: milliseconds("2026-03-01T08:00:00Z"),
            timeTo: milliseconds("2026-04-01T07:00:00Z")))
        let tokyo = StatisticsPeriodDraft(preferences: saved, options: try options(zone: "Asia/Tokyo"))
        #expect(tokyo.confirmedPreferences() == .init(timeFrom: milliseconds("2026-03-31T15:00:00Z"),
            timeTo: milliseconds("2026-04-30T15:00:00Z")))
    }

    @Test func futureOldestRemainsOutsideApprovedRecoveryDomain() throws {
        let values = try options(oldest: "2026-10-01T00:00:00Z", now: "2026-09-01T00:00:00Z")
        #expect(values.from.isEmpty)
        #expect(values.to.count == 1 && values.to[0].timestamp == .max)
        var draft = StatisticsPeriodDraft(preferences: .init(), options: values)
        #expect(draft.fromIndex == nil && draft.confirmedPreferences() == nil)
        draft.selectPastYear()
        #expect(draft.toIndex == nil && draft.confirmedPreferences() == nil)
        draft.selectAllTime()
        #expect(draft.toIndex == 0 && draft.confirmedPreferences() == nil)
        draft.includeMarkedAsPlayed = true
        #expect(draft.confirmedPreferences() == .init(includeMarkedAsPlayed: true))
    }


    @Test @MainActor func approvedExactMidnightRecoveryMatchesTenIndependentProposalCases() throws {
        // Literal proposal cases of the exact-midnight month recovery.
        // Neither the raw Java oracle nor its expectations are regenerated here.
        struct Case {
            let name: String
            var oldest: Int64 = 1_788_220_800_000
            var now: Int64 = 1_788_220_800_000
            var zone = "UTC"
            var saved = StatisticsPeriodPreferences()
            var preset: String? = nil
            var marked: Bool? = nil
            var from: [Int64] = [1_788_220_800_000]
            var to: [Int64] = [1_790_812_800_000, Int64.max]
            var confirmed: StatisticsPeriodPreferences? = .init(timeFrom: 1_788_220_800_000)
        }
        let cases: [Case] = [
            .init(name: "exact-current-month-default"),
            .init(name: "exact-current-month-past-year", preset: "past-year",
                  confirmed: .init(timeFrom: 1_788_220_800_000, timeTo: 1_790_812_800_000)),
            .init(name: "exact-current-month-all-time", preset: "all-time"),
            .init(name: "exact-previous-confirmed-range",
                  saved: .init(timeFrom: 1_785_542_400_000, timeTo: 1_788_220_800_000),
                  confirmed: .init(timeFrom: 1_788_220_800_000, timeTo: 1_790_812_800_000)),
            .init(name: "exact-marked-on", marked: true, confirmed: .init(includeMarkedAsPlayed: true)),
            .init(name: "exact-marked-off", saved: .init(includeMarkedAsPlayed: true), marked: false),
            .init(name: "ordinary-one-ms-after-unchanged", now: 1_788_220_800_001),
            .init(name: "prior-snapshot-before-midnight-unchanged", oldest: 1_788_220_799_999,
                  from: [1_785_542_400_000], to: [1_788_220_800_000, Int64.max],
                  confirmed: .init(timeFrom: 1_785_542_400_000)),
            .init(name: "future-oldest-not-in-repair-domain", oldest: 1_790_812_800_000,
                  from: [], to: [Int64.max], confirmed: nil),
            .init(name: "LA-local-midnight", oldest: 1_788_246_000_000, now: 1_788_246_000_000,
                  zone: "America/Los_Angeles", from: [1_788_246_000_000],
                  to: [1_790_838_000_000, Int64.max], confirmed: .init(timeFrom: 1_788_246_000_000))
        ]
        #expect(cases.count == 10)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("M13Midnight-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for item in cases {
            let file = root.appendingPathComponent(item.name + ".json")
            let store = try StatisticsPreferenceStore(file: file)
            if item.saved != .init() { try store.update(item.saved) }
            let before = try? Data(contentsOf: file)
            let values = try StatisticsPeriodOptions(oldestMilliseconds: item.oldest, nowMilliseconds: item.now,
                calendar: calendar(item.zone), locale: Locale(identifier: "en-US"))
            #expect(values.from.map(\.timestamp) == item.from, "\(item.name)")
            #expect(values.to.map(\.timestamp) == item.to, "\(item.name)")
            var draft = StatisticsPeriodDraft(preferences: store.value, options: values)
            if item.preset == "past-year" { draft.selectPastYear() }
            if item.preset == "all-time" { draft.selectAllTime() }
            if let marked = item.marked { draft.includeMarkedAsPlayed = marked }
            #expect(draft.confirmedPreferences() == item.confirmed, "\(item.name)")
            // Opening, editing and discarding a draft preserve absent files and exact saved bytes.
            #expect(store.value == item.saved)
            #expect((try? Data(contentsOf: file)) == before)
            #expect(try StatisticsPreferenceStore(file: file).value == item.saved)
            if let confirmed = draft.confirmedPreferences() {
                try store.update(confirmed)
                #expect(try StatisticsPreferenceStore(file: file).value == item.confirmed)
                let aggregate = try LibraryStatistics(feeds: [], includeMarkedAsPlayed: confirmed.includeMarkedAsPlayed,
                    timeFrom: confirmed.timeFrom, timeTo: confirmed.timeTo,
                    now: Date(timeIntervalSince1970: Double(item.now) / 1000))
                #expect(aggregate.feeds.isEmpty)
                #expect(aggregate.oldestPlaybackMilliseconds == item.now)
                #expect(aggregate.feeds.reduce(Int64(0)) { $0 + $1.playedSeconds } == 0)
            }
        }
    }

    @Test func midnightRecoveryDoesNotAppendCurrentMonthToOlderHistoryOrFutureWithinMonth() throws {
        let older = try options(oldest: "2026-07-01T00:00:00Z", now: "2026-09-01T00:00:00Z")
        #expect(older.from.map(\.timestamp) == [1_782_864_000_000, 1_785_542_400_000])
        #expect(older.to.map(\.timestamp) == [1_785_542_400_000, 1_788_220_800_000, Int64.max])
        let future = try StatisticsPeriodOptions(oldestMilliseconds: 1_788_220_800_001,
            nowMilliseconds: 1_788_220_800_000, calendar: calendar(), locale: Locale(identifier: "en-US"))
        #expect(future.from.isEmpty && future.to.map(\.timestamp) == [Int64.max])
    }

    @Test func savedChoicesDriveExistingAggregateUsingLiteralIndependentTotals() throws {
        func episode(_ id: Int64, _ last: Int64, _ played: Int64, _ duration: Int32 = 60000,
                     marked: Bool = false) -> LibraryEpisode {
            var state = EpisodeUserState()
            state.lastPlayedTimeMilliseconds = last
            state.playedDurationMilliseconds = played
            state.playState = marked ? .played : .unplayed
            return LibraryEpisode(id: id, details: ParsedEpisode(media: ParsedMedia(url: "fixture://\(id)",
                size: 100, durationMilliseconds: duration)), userState: state)
        }
        let start = milliseconds("2026-09-01T00:00:00Z"), end = milliseconds("2026-10-01T00:00:00Z")
        let feeds = [
            LibraryFeed(id: 1, source: "fixture://alpha", metadata: .init(format: .rss), episodes: [
                episode(1, start - 1, 10500), episode(2, start, 20750), episode(3, 0, 0, 50000, marked: true)]),
            LibraryFeed(id: 2, source: "fixture://beta", metadata: .init(format: .rss), episodes: [
                episode(4, end - 1, 30750), episode(5, end, 40000),
                episode(6, milliseconds("2026-09-15T12:00:00Z"), 10000, 90000, marked: true)])]
        let cases: [(StatisticsPeriodPreferences, [Int64])] = [
            (.init(timeFrom: start, timeTo: end), [20, 40]), (.init(), [31, 80]),
            (.init(includeMarkedAsPlayed: true), [81, 80]), (.init(timeFrom: start), [20, 80]),
            (.init(timeFrom: end, timeTo: start), [0, 0]), (.init(timeFrom: start, timeTo: start), [0, 0])]
        for (saved, expected) in cases {
            let actual = try LibraryStatistics(feeds: feeds, includeMarkedAsPlayed: saved.includeMarkedAsPlayed,
                timeFrom: saved.timeFrom, timeTo: saved.timeTo,
                now: ISO8601DateFormatter().date(from: "2026-09-23T12:00:00Z")!)
            #expect(actual.feeds.map(\.playedSeconds) == expected)
            #expect(actual.feeds.map(\.totalSeconds) == [170, 210])
            #expect(actual.feeds.map(\.episodes) == [3, 3])
            #expect(actual.oldestPlaybackMilliseconds == start - 1)
        }
    }

    @Test @MainActor func cancelWritesNothingAndSuccessfulCommitReopensExactTuple() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StatisticsPeriod-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("choices.json")
        let store = try StatisticsPreferenceStore(file: file)
        var draft = StatisticsPeriodDraft(preferences: store.value, options: try options())
        draft.selectPastYear()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.value == .init())
        let saved = try #require(draft.confirmedPreferences())
        try store.update(saved)
        let bytes = try Data(contentsOf: file)
        var canceled = StatisticsPeriodDraft(preferences: store.value, options: try options())
        canceled.includeMarkedAsPlayed = true
        #expect(store.value == saved)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try StatisticsPreferenceStore(file: file).value == saved)
        try store.update(.init(includeMarkedAsPlayed: true))
        #expect(try StatisticsPreferenceStore(file: file).value == .init(includeMarkedAsPlayed: true))
        #expect(try String(contentsOf: file, encoding: .utf8).contains("9223372036854775807"))
    }

    @Test @MainActor func failedAtomicWritePreservesValueDiskAndAllowsRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StatisticsPeriodFailure-\(UUID())")
        let parent = root.appendingPathComponent("current"), moved = root.appendingPathComponent("preserved")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = parent.appendingPathComponent("choices.json")
        let store = try StatisticsPreferenceStore(file: file)
        let first = StatisticsPeriodPreferences(timeFrom: 123, timeTo: 456)
        try store.update(first)
        let bytes = try Data(contentsOf: file)
        try FileManager.default.moveItem(at: parent, to: moved)
        #expect(throws: (any Error).self) { try store.update(.init(includeMarkedAsPlayed: true)) }
        #expect(store.value == first)
        #expect(try Data(contentsOf: moved.appendingPathComponent("choices.json")) == bytes)
        try FileManager.default.moveItem(at: moved, to: parent)
        try store.update(.init(includeMarkedAsPlayed: true))
        #expect(try StatisticsPreferenceStore(file: file).value == .init(includeMarkedAsPlayed: true))
    }

    @Test(arguments: ["{}", "{\"countAll\":true}", "{\"filterFrom\":9223372036854775806,\"filterTo\":9223372036854775807}"])
    func partialPreferencesUsePerKeySourceDefaultsAndInt64Precision(json: String) throws {
        let value = try JSONDecoder().decode(StatisticsPeriodPreferences.self, from: Data(json.utf8))
        #expect(value.timeTo == .max)
        if json.contains("5806") { #expect(value.timeFrom == Int64.max - 1) }
        else { #expect(value.timeFrom == 0) }
        #expect(value.includeMarkedAsPlayed == json.contains("true"))
        #expect(try JSONDecoder().decode(StatisticsPeriodPreferences.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test(arguments: ["{", "{\"countAll\":\"yes\"}", "{\"filterTo\":9223372036854775808}", "{\"filterFrom\":1.5}"])
    @MainActor func corruptPreferenceReadDoesNotOverwriteFile(json: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("StatisticsInvalid-\(UUID()).json")
        let bytes = Data(json.utf8)
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: (any Error).self) { try StatisticsPreferenceStore(file: file) }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test @MainActor func observerReceivesOnlyPersistedCompleteTuple() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("StatisticsEvents-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = try StatisticsPreferenceStore(file: file)
        var events = store.events().makeAsyncIterator()
        #expect(await events.next() == .init())
        let saved = StatisticsPeriodPreferences(timeFrom: 987, timeTo: 123) // Reversed remains representable.
        try store.update(saved)
        #expect(await events.next() == saved)
        #expect(try StatisticsPreferenceStore(file: file).value == saved)
    }
}
