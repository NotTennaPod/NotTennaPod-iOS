import Foundation
import Testing
@testable import NotTennaPodCore

/// Host checks of the player widget against Android 3.12.1: what the widget shows, which buttons it has, how its
/// time advances, and what its buttons do on the app's playback coordinator.
@Suite
struct PlayerWidgetTests {
    private let english = Locale(identifier: "en_US")
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(position: Int32 = 13_000, duration: Int32 = 30_000, rate: Float = 0, speed: Float = 1,
                          playing: Bool = false, remaining: Bool = false, respects: Bool = false) -> PlayerWidgetSnapshot {
        PlayerWidgetSnapshot(episodeID: 7, title: "Deletion episode 0", isPlaying: playing, positionRate: rate,
            positionMilliseconds: position, durationMilliseconds: duration, speed: speed, showRemainingTime: remaining,
            timeRespectsSpeed: respects, savedAt: start)
    }

    /// A snapshot as the app writes it now, with its lease; four hours long, playing at `rate` unless `playing` is false.
    private func leased(at date: Date, position: Int32, duration: Int32 = 14_400_000, rate: Float = 1,
                        playing: Bool = true) -> PlayerWidgetSnapshot {
        PlayerWidgetSnapshot(episodeID: 7, title: "Deletion episode 0", isPlaying: playing, positionRate: playing ? rate : 0,
            positionMilliseconds: position, durationMilliseconds: duration, savedAt: date, leaseSeconds: PlayerWidgetLease.duration)
    }

    /// `WidgetUpdater.getProgressString`; "00:00:13 / 00:00:30" is the Android reference capture.
    @Test func progressTextIsAndroidsPositionAndDuration() {
        func text(_ position: Int32, _ duration: Int32, speed: Float = 1, remaining: Bool = false, respects: Bool = false) -> String? {
            PlayerWidgetPresentation.progress(position: position, duration: duration, speed: speed,
                showRemainingTime: remaining, timeRespectsSpeed: respects, locale: english)
        }
        #expect(text(13_000, 30_000) == "00:00:13 / 00:00:30")
        #expect(text(13_000, 30_000, remaining: true) == "00:00:13 / -00:00:17")
        #expect(text(3_723_999, 7_200_000) == "01:02:03 / 02:00:00")
        #expect(text(0, 30_000) == "00:00:00 / 00:00:30")
        // Past the end the remaining time is "-00:00:00", never negative.
        #expect(text(31_000, 30_000, remaining: true) == "00:00:31 / -00:00:00")
        // Unknown duration or position: no progress line.
        #expect(text(13_000, 0) == nil)
        #expect(text(-1, 30_000) == nil)
        // "Time respects speed" divides by the speed; without it the speed does not matter.
        #expect(text(30_000, 90_000, speed: 1.5, respects: true) == "00:00:20 / 00:01:00")
        #expect(text(30_000, 90_000, speed: 1.5, remaining: true, respects: true) == "00:00:20 / -00:00:40")
        #expect(text(30_000, 90_000, speed: 2) == "00:00:30 / 00:01:30")
    }

    /// The widget formats time like the app's player and lists (`Converter.getDurationStringLong` in both),
    /// including locale digits.
    @Test func durationTextMatchesTheAppsPlayerFormat() throws {
        for identifier in ["en_US", "ar", "de_DE", "hi_IN"] {
            let locale = Locale(identifier: identifier)
            for value: Int32 in [-5, 0, 999, 1_000, 59_999, 61_000, 3_599_000, 3_600_000, 36_061_000, .max] {
                #expect(PlayerWidgetPresentation.durationLong(value, locale: locale) == EpisodeRowPresentation.time(value, locale: locale),
                        "\(identifier) \(value)")
            }
        }
        // The same position/duration and speed conversion as the expanded player shows.
        for (position, duration, speed) in [(Int32(30_000), Int32(90_000), Float(1.5)), (4_000, 9_000, 0.75), (59_000, 3_700_000, 3)] {
            for remaining in [false, true] {
                let text = PlayerWidgetPresentation.progress(position: position, duration: duration, speed: speed,
                    showRemainingTime: remaining, timeRespectsSpeed: true, locale: english)
                let player = try #require(PlayerTimePresentation(position: position, duration: duration, showRemainingTime: remaining,
                    speed: speed, timeRespectsSpeed: true, locale: english))
                #expect(text == "\(player.position) / \(player.length)")
            }
        }
    }

    /// While playing the position advances at the playback rate (the progress ticks every second on Android).
    @Test func positionAdvancesAtThePlaybackRateUntilTheEnd() {
        var value = snapshot(position: 10_000, duration: 30_000, rate: 1.5, playing: true)
        #expect(value.position(at: start.addingTimeInterval(2)) == 13_000)
        #expect(value.position(at: start.addingTimeInterval(60)) == 30_000)
        #expect(value.position(at: start.addingTimeInterval(-5)) == 10_000)
        value.positionRate = 0
        #expect(value.position(at: start.addingTimeInterval(60)) == 10_000)
        value = snapshot(position: 10_000, duration: 0, rate: 1, playing: true)
        #expect(value.position(at: start.addingTimeInterval(5)) == 15_000)
        let shown = PlayerWidgetPresentation(snapshot: snapshot(position: 10_000, rate: 1.5, playing: true),
            configuration: .init(), date: start.addingTimeInterval(2), narrow: false, hasCover: false, locale: english)
        #expect(shown.progress == "00:00:13 / 00:00:30")
    }

    /// One entry per second ahead while the position advances, so the widget ticks without the app, until the
    /// lease ends; then a paused entry at the position the snapshot was written with (not the predicted one),
    /// where WidgetKit asks for a new timeline. A single entry when paused or without media.
    @Test func timelineTicksEverySecondUntilAPausedEntryAtTheLeaseEnd() throws {
        let written = leased(at: start, position: 10_000)
        let now = start.addingTimeInterval(10)
        let expiry = start.addingTimeInterval(PlayerWidgetLease.duration)
        let schedule = PlayerWidgetTimeline.schedule(for: written, now: now)
        let ticks = schedule.entries.dropLast()
        #expect(ticks.count == 170 && ticks.first?.date == now && ticks.allSatisfy { $0.snapshot == written && $0.date < expiry })
        #expect(zip(ticks, ticks.dropFirst()).allSatisfy { $1.date.timeIntervalSince($0.date) == 1 })
        let last = try #require(schedule.entries.last)
        #expect(last.date == expiry && schedule.refresh == expiry)
        let paused = try #require(last.snapshot)
        #expect(!paused.isPlaying && paused.positionRate == 0 && paused.positionMilliseconds == 10_000 && paused.title == written.title)
        let face = PlayerWidgetPresentation(snapshot: paused, configuration: .init(), date: expiry.addingTimeInterval(600),
                                            narrow: false, hasCover: false, locale: english)
        #expect(!face.isPlaying && face.progress == "00:00:10 / 04:00:00" && face.action(for: .playPause) == .command(.play))
        // The entry before it still runs: 10 s + 179 s.
        let running = PlayerWidgetPresentation(snapshot: written, configuration: .init(), date: try #require(ticks.last).date,
                                               narrow: false, hasCover: false, locale: english)
        #expect(running.isPlaying && running.progress == "00:03:09 / 04:00:00")
        for value in [snapshot(playing: false), leased(at: start, position: 10_000, playing: false), nil] {
            let schedule = PlayerWidgetTimeline.schedule(for: value, now: start)
            #expect(schedule.entries == [.init(date: start, snapshot: value)] && schedule.refresh == nil)
        }
    }

    /// The episode's end: the entries stop at the one that reaches it (the app reports what comes next), and the
    /// paused entry still ends the timeline in case the app has ended.
    @Test func timelineStopsTickingAtTheEpisodesEnd() {
        let ending = leased(at: start, position: 25_500, duration: 30_000)
        let schedule = PlayerWidgetTimeline.schedule(for: ending, now: start)
        #expect(schedule.entries.map(\.date) == (0...5).map { start.addingTimeInterval(TimeInterval($0)) } + [start.addingTimeInterval(180)])
        #expect(ending.position(at: schedule.entries[5].date) == 30_000 && ending.position(at: schedule.entries[4].date) < 30_000)
        #expect(schedule.entries.last?.snapshot?.isPlaying == false && schedule.refresh == start.addingTimeInterval(180))
    }

    /// Buffering (wants to play, position still) and an unknown duration show no running time: the first entry as
    /// written and the paused entry at the lease's end.
    @Test func bufferingAndUnknownDurationShowNoRunningTime() {
        let buffering = leased(at: start, position: 10_000, rate: 0)
        var schedule = PlayerWidgetTimeline.schedule(for: buffering, now: start.addingTimeInterval(5))
        #expect(schedule.entries.map(\.date) == [start.addingTimeInterval(5), start.addingTimeInterval(180)])
        #expect(schedule.entries.first?.snapshot == buffering && schedule.entries.last?.snapshot?.isPlaying == false)
        let shown = PlayerWidgetPresentation(snapshot: buffering, configuration: .init(), date: start.addingTimeInterval(100),
                                             narrow: false, hasCover: false, locale: english)
        #expect(shown.isPlaying && shown.progress == "00:00:10 / 04:00:00")
        let unknown = leased(at: start, position: 10_000, duration: 0)
        schedule = PlayerWidgetTimeline.schedule(for: unknown, now: start)
        #expect(schedule.entries.map(\.date) == [start, start.addingTimeInterval(180)] && schedule.refresh == start.addingTimeInterval(180))
        #expect(PlayerWidgetPresentation(snapshot: unknown, configuration: .init(), date: start.addingTimeInterval(60),
                                         narrow: false, hasCover: false).progress == nil)
    }

    /// The lease holds from when the snapshot was written for `PlayerWidgetLease.duration`; outside it the snapshot
    /// shows paused at its own position. A date that does not fit the reader's clock (from its future: the clock
    /// was set back; long past: set forward) is not trusted; a small correction is.
    @Test func onlyAHoldingLeaseShowsPlaying() {
        let written = leased(at: start, position: 10_000)
        #expect(written.isFresh(at: start) && written.isFresh(at: start.addingTimeInterval(179.9)))
        #expect(!written.isFresh(at: start.addingTimeInterval(180)) && !written.isFresh(at: start.addingTimeInterval(3_600)))
        #expect(written.isFresh(at: start.addingTimeInterval(-4)))
        #expect(!written.isFresh(at: start.addingTimeInterval(-60)) && !written.isFresh(at: start.addingTimeInterval(-3_600)))
        #expect(written.shown(at: start.addingTimeInterval(60)) == written)
        for date in [start.addingTimeInterval(-3_600), start.addingTimeInterval(180), start.addingTimeInterval(3_600)] {
            let shown = written.shown(at: date)
            #expect(!shown.isPlaying && shown.positionRate == 0 && shown.positionMilliseconds == 10_000)
            let schedule = PlayerWidgetTimeline.schedule(for: written, now: date)
            #expect(schedule.entries == [.init(date: date, snapshot: shown)] && schedule.refresh == nil)
        }
        // Paused snapshots are shown as written, with or without a lease.
        #expect(snapshot(playing: false).shown(at: start.addingTimeInterval(3_600)) == snapshot(playing: false))
        // Invalid leases are no lease.
        for lease in [0, -1, .infinity, .nan] as [TimeInterval] {
            var value = written; value.leaseSeconds = lease
            #expect(!value.isFresh(at: start) && !value.shown(at: start).isPlaying)
        }
    }

    /// A snapshot written before leases existed (an earlier version, or one that ended while playing) is read, but
    /// never shown as playing, by the widget or the control. The current format keeps its lease, and the control
    /// reads the file and checks the lease each time it is asked.
    @Test func oldSnapshotFormatsAreNotFresh() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PlayerWidget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = PlayerWidgetStore(directory: directory)
        let old = """
            {"episodeID":7,"title":"Deletion episode 0","isVideo":false,"isPlaying":true,"positionRate":1,\
            "positionMilliseconds":13000,"durationMilliseconds":30000,"speed":1,"showRemainingTime":false,\
            "timeRespectsSpeed":false,"savedAt":\(start.timeIntervalSinceReferenceDate)}
            """
        try Data(old.utf8).write(to: directory.appendingPathComponent("snapshot.json"))
        let read = try #require(store.read())
        #expect(read.title == "Deletion episode 0" && read.isPlaying && read.leaseSeconds == nil && read.savedAt == start)
        #expect(!read.isFresh(at: start) && !read.shown(at: start).isPlaying && read.shown(at: start).positionMilliseconds == 13_000)
        #expect(!store.controlValue(at: start))
        let schedule = PlayerWidgetTimeline.schedule(for: read, now: start)
        #expect(schedule.entries.count == 1 && schedule.entries[0].snapshot?.isPlaying == false && schedule.refresh == nil)

        let written = leased(at: start, position: 13_000, duration: 30_000)
        try store.write(written)
        #expect(store.read() == written)
        #expect(store.controlValue(at: start.addingTimeInterval(10)) && !store.controlValue(at: start.addingTimeInterval(180)))
        try store.write(leased(at: start, position: 13_000, playing: false))
        #expect(!store.controlValue(at: start.addingTimeInterval(10)))
        try store.write(nil)
        #expect(!store.controlValue(at: start))
    }

    /// What the app writes: on visible changes; while playing, a renewal once the last write is a minute old by
    /// its monotonic clock (or at once when that is unknown, after the clock was set); never between, nor for a
    /// paused snapshot.
    @Test func theAppRenewsAPlayingLeaseAboutOnceAMinute() {
        let first = leased(at: start, position: 10_000)
        let along = leased(at: start.addingTimeInterval(30), position: 40_000)
        #expect(PlayerWidgetLease.needsWrite(first, after: nil, elapsed: nil))
        #expect(PlayerWidgetLease.needsWrite(nil, after: .some(first), elapsed: .seconds(1)))
        #expect(!PlayerWidgetLease.needsWrite(nil, after: .some(nil), elapsed: .seconds(600)))
        #expect(!PlayerWidgetLease.needsWrite(along, after: .some(first), elapsed: .seconds(59)))
        #expect(PlayerWidgetLease.needsWrite(along, after: .some(first), elapsed: .seconds(60)))
        #expect(PlayerWidgetLease.needsWrite(along, after: .some(first), elapsed: nil))
        // A live stream whose position runs ahead of its rate (Skip silence) is only renewed once a minute.
        let live = leased(at: start, position: 10_000, duration: 0)
        let liveAhead = leased(at: start.addingTimeInterval(30), position: 100_000, duration: 0)
        #expect(!PlayerWidgetLease.needsWrite(liveAhead, after: .some(live), elapsed: .seconds(30)))
        #expect(PlayerWidgetLease.needsWrite(liveAhead, after: .some(live), elapsed: .seconds(60)))
        // A seek is written at once.
        #expect(PlayerWidgetLease.needsWrite(leased(at: start.addingTimeInterval(30), position: 90_000), after: .some(first), elapsed: .seconds(30)))
        // Buffering is renewed (the app still plays); a paused snapshot never is.
        let buffering = leased(at: start, position: 10_000, rate: 0)
        #expect(PlayerWidgetLease.needsWrite(buffering, after: .some(buffering), elapsed: .seconds(60)))
        let paused = leased(at: start, position: 10_000, playing: false)
        #expect(!PlayerWidgetLease.needsWrite(paused, after: .some(paused), elapsed: .seconds(3_600)))
        #expect(!PlayerWidgetLease.needsWrite(paused, after: .some(paused), elapsed: nil))
        // An old-format snapshot in memory is replaced by one with a lease.
        #expect(PlayerWidgetLease.needsWrite(first, after: .some(snapshot(position: 10_000, rate: 1, playing: true)), elapsed: .seconds(1)))
    }

    // MARK: - The lease over time: the app and WidgetKit second by second

    /// What WidgetKit shows from a delivered timeline at a moment: its latest entry not after that moment.
    private struct Delivered {
        let entries: [PlayerWidgetTimeline.Entry]
        let refresh: Date?
        init(_ schedule: (entries: [PlayerWidgetTimeline.Entry], refresh: Date?)) { entries = schedule.entries; refresh = schedule.refresh }
        func entry(at date: Date) -> PlayerWidgetTimeline.Entry? { entries.last { $0.date <= date } }
    }

    private struct Run {
        /// Per second: what the widget shows (nil: no entry yet in the new wall clock) and the true position.
        var shown: [(entry: PlayerWidgetTimeline.Entry?, position: Int32)] = []
        /// Seconds at which the app asked for a reload, and at which a new timeline was built.
        var requests: [Int] = [], deliveries: [Int] = []
        func playing(_ second: Int) -> Bool { shown[second].entry?.snapshot?.isPlaying == true }
        /// Seconds at which the widget does not show the episode playing.
        var notPlaying: [Int] { shown.indices.filter { !playing($0) } }
    }

    /// Plays for `seconds` at `rate` (0: buffering throughout). Each second the app (alive until `alive`) writes
    /// what `PlayerWidgetLease.needsWrite` asks for, timed by its monotonic second, and asks for a reload with each
    /// write. Each requested timeline arrives `delivery` seconds later (nil: never), built from the file at that
    /// moment; with `followsPolicy` WidgetKit also builds one at the delivered timeline's refresh date. `wall` gives
    /// the wall clock at each second; `clockSet` the seconds at which the app hears `NSSystemClockDidChange`. The
    /// widget starts with a timeline built at second 0, which answers the first request.
    private func run(seconds: Int, delivery: Int?, followsPolicy: Bool = false, rate: Float = 1, alive: Int = .max,
                     duration: Int32 = 14_400_000, advance: Int? = nil,
                     clockSet: Set<Int> = [], wall: (Int) -> Date) -> Run {
        var result = Run()
        var file: PlayerWidgetSnapshot?
        var written: PlayerWidgetSnapshot??
        var writtenAt: Int?
        var arrivals: [Int] = []
        var timeline: Delivered?
        for second in 0...seconds {
            let now = wall(second)
            let position = Int32(10_000 + (advance ?? Int(1_000 * rate)) * min(second, alive))
            if second <= alive {
                if clockSet.contains(second) { writtenAt = nil }
                let next = leased(at: now, position: position, duration: duration, rate: rate)
                if PlayerWidgetLease.needsWrite(next, after: written, elapsed: writtenAt.map { .seconds(second - $0) }) {
                    file = next; written = .some(next); writtenAt = second
                    result.requests.append(second)
                    if let delivery { arrivals.append(second + delivery) }
                }
            }
            if timeline == nil { arrivals.removeAll() }
            if timeline == nil || arrivals.contains(second) || (followsPolicy && timeline?.refresh.map { $0 <= now } == true) {
                timeline = Delivered(PlayerWidgetTimeline.schedule(for: file, now: now))
                result.deliveries.append(second)
                arrivals.removeAll { $0 <= second }
            }
            result.shown.append((timeline?.entry(at: now), position))
        }
        return result
    }

    private func clock(_ second: Int) -> Date { start.addingTimeInterval(TimeInterval(second)) }

    /// Twenty minutes, several leases: while replacement timelines arrive within `duration − renewal` of a request
    /// the widget shows playing all along, its time within a second of the player's; the app asks for a reload
    /// once a minute, not on every position update.
    @Test(arguments: [0, 30, 110])
    func longPlaybackKeepsShowingPlayingWhenReloadsArrive(delivery: Int) throws {
        let result = run(seconds: 1_200, delivery: delivery, wall: clock)
        #expect(result.notPlaying.isEmpty, "\(result.notPlaying)")
        #expect(result.requests == Array(stride(from: 0, through: 1_200, by: 60)))
        for (second, shown) in result.shown.enumerated() {
            let entry = try #require(shown.entry), snapshot = try #require(entry.snapshot)
            let predicted = snapshot.position(at: entry.date)
            #expect(abs(Int(predicted) - Int(shown.position)) <= 1_000, "\(second): \(predicted) for \(shown.position)")
        }
    }

    /// A live stream (unknown duration) whose position runs three times its rate (Skip silence) for twelve minutes:
    /// no time shows, so the drift is no change; the lease is renewed and a reload asked for once a minute, and the
    /// widget shows playing all along.
    @Test func aLiveStreamRunningAheadIsRenewedOnceAMinute() {
        let result = run(seconds: 720, delivery: 0, duration: 0, advance: 3_000, wall: clock)
        #expect(result.notPlaying.isEmpty, "\(result.notPlaying)")
        #expect(result.requests == Array(stride(from: 0, through: 720, by: 60)), "\(result.requests)")
    }

    /// A delivered timeline, then renewals written to the file but no new provider call: it reaches its paused
    /// entry, at the position it was built with, although the app still plays (the documented false-paused
    /// interval). When WidgetKit builds a timeline at that entry, as asked, it shows playing again.
    @Test func renewalsWithoutANewProviderCallReachThePausedEntry() {
        let unanswered = run(seconds: 400, delivery: nil, wall: clock)
        #expect(unanswered.requests == [0, 60, 120, 180, 240, 300, 360] && unanswered.deliveries == [0])
        #expect(unanswered.notPlaying == Array(180...400))
        #expect(unanswered.shown[400].entry?.snapshot?.positionMilliseconds == 10_000)
        let policy = run(seconds: 400, delivery: nil, followsPolicy: true, wall: clock)
        #expect(policy.notPlaying.isEmpty && policy.deliveries == [0, 180, 360])
    }

    /// A replacement that arrives after the delivered timeline's paused entry: paused from that entry until it
    /// arrives, then playing again; one that arrives before it replaces it unseen.
    @Test func aLateReplacementShowsPausedOnlyUntilItArrives() {
        let late = run(seconds: 600, delivery: 150, wall: clock)
        // The first timeline (second 0) ends at 180; the reload asked for at 60 arrives at 210.
        #expect(late.notPlaying == Array(180..<210))
        let replaced = run(seconds: 600, delivery: 100, wall: clock)
        #expect(replaced.notPlaying.isEmpty)
    }

    /// The app ends at second 200 without `willTerminate`: the widget shows playing until the timeline delivered at
    /// its last renewal (180) reaches its paused entry (360), at that renewal's position (190 s, not 210 s);
    /// WidgetKit's next timeline then shows it paused with no further refresh.
    @Test func afterTheAppEndsTheWidgetShowsPlayingUntilThePausedEntry() throws {
        let ended = run(seconds: 900, delivery: 0, followsPolicy: true, alive: 200, wall: clock)
        #expect(ended.requests.last == 180)
        #expect(ended.notPlaying == Array(360...900))
        let paused = try #require(ended.shown[900].entry?.snapshot)
        #expect(paused.positionMilliseconds == 190_000 && paused.positionRate == 0)
        #expect(ended.deliveries == [0, 60, 120, 180, 360])
    }

    /// The wall clock set back or forward an hour at second 100. While the time runs, the next position no longer
    /// fits the prediction in the new clock, so it is written at once, told of the change or not. While buffering
    /// there is nothing to predict: told, the app renews at once; not told, within a minute anyway, because it times
    /// renewals by its monotonic clock (going by the wall clock, it would wait an hour after the clock was set back).
    @Test(arguments: [-3_600.0, 3_600.0])
    func clockChangesDoNotBreakTheLease(offset: TimeInterval) {
        let wall = { (second: Int) in self.start.addingTimeInterval(TimeInterval(second) + (second >= 100 ? offset : 0)) }
        let renewedAt100 = [0, 60] + Array(stride(from: 100, through: 600, by: 60))
        for clockSet: Set<Int> in [[100], []] {
            let playing = run(seconds: 600, delivery: 0, clockSet: clockSet, wall: wall)
            #expect(playing.notPlaying.isEmpty && playing.requests == renewedAt100, "\(clockSet)")
        }
        let told = run(seconds: 600, delivery: 0, rate: 0, clockSet: [100], wall: wall)
        #expect(told.notPlaying.isEmpty && told.requests == renewedAt100)
        let untold = run(seconds: 600, delivery: 0, rate: 0, wall: wall)
        #expect(untold.requests == Array(stride(from: 0, through: 600, by: 60)))
        // Set back: the delivered timeline has no entry yet in the new clock. Forward: it is past its paused entry.
        #expect(untold.notPlaying == Array(100..<120))
        #expect(Set(untold.notPlaying.map { untold.shown[$0].entry == nil }) == [offset < 0])
    }

    /// Android's extended row order and which controls show for every choice of the four buttons.
    @Test func buttonsFollowTheWidgetSettings() {
        let media = snapshot()
        for mask in 0..<16 {
            let configuration = PlayerWidgetConfiguration(playbackSpeed: mask & 1 != 0, rewind: mask & 2 != 0,
                                                          fastForward: mask & 4 != 0, skip: mask & 8 != 0)
            let wide = PlayerWidgetPresentation(snapshot: media, configuration: configuration, date: start, narrow: false, hasCover: true)
            var expected: [PlayerWidgetPresentation.Control] = []
            if mask & 1 != 0 { expected.append(.playbackSpeed) }
            if mask & 2 != 0 { expected.append(.rewind) }
            if mask != 0 { expected.append(.playPause) }
            if mask & 4 != 0 { expected.append(.fastForward) }
            if mask & 8 != 0 { expected.append(.skip) }
            #expect(wide.extendedControls == expected, "mask \(mask)")
            #expect(wide.showsStandalonePlay == (mask == 0))
            #expect(wide.showsText && wide.title == "Deletion episode 0")
            // The small widget is Android's narrow layout: no text or row, and it keeps play/pause (no copy of
            // Android's control-less narrow widget).
            let small = PlayerWidgetPresentation(snapshot: media, configuration: configuration, date: start, narrow: true, hasCover: true)
            #expect(!small.showsText && small.extendedControls.isEmpty && small.showsStandalonePlay)
        }
    }

    /// Each button's action, label and icon; with no media every control opens the app. Play/Pause sends what it
    /// shows: Play plays and Pause pauses, so a Pause left on screen can never start playback.
    @Test func buttonActionsLabelsAndNoMediaState() {
        let all = PlayerWidgetConfiguration(playbackSpeed: true, rewind: true, fastForward: true, skip: true)
        let paused = PlayerWidgetPresentation(snapshot: snapshot(playing: false), configuration: all, date: start, narrow: false, hasCover: true)
        #expect(paused.extendedControls.map(paused.action(for:)) == [.open(PlayerWidgetLink.speed), .command(.rewind),
            .command(.play), .command(.fastForward), .command(.skip)])
        #expect(paused.extendedControls.map(paused.labelKey(for:)) == ["playback_speed", "rewind_label", "play_label",
            "fast_forward_label", "skip_episode_label"])
        #expect(paused.iconName(for: .playPause) == "ic_widget_play")
        let playing = PlayerWidgetPresentation(snapshot: snapshot(playing: true), configuration: all, date: start, narrow: false, hasCover: true)
        #expect(playing.labelKey(for: .playPause) == "pause_label" && playing.iconName(for: .playPause) == "ic_widget_pause")
        #expect(playing.action(for: .playPause) == .command(.pause))
        for narrow in [false, true] {
            for media in [snapshot(playing: false), snapshot(playing: true)] {
                let shown = PlayerWidgetPresentation(snapshot: media, configuration: .init(), date: start, narrow: narrow, hasCover: true)
                #expect(shown.action(for: .playPause) == .command(media.isPlaying ? .pause : .play))
            }
        }
        let none = PlayerWidgetPresentation(snapshot: nil, configuration: all, date: start, narrow: false, hasCover: true)
        #expect(none.title == nil && none.progress == nil && !none.hasMedia && !none.isPlaying)
        #expect(none.extendedControls.allSatisfy { none.action(for: $0) == .open(PlayerWidgetLink.player) })
        #expect(none.labelKey(for: .playPause) == "play_label")
    }

    /// Opacity is the background colour's alpha, the chosen percentage to within one 8-bit step (Android rounds
    /// `255 × percent / 100`); Cover as background forces 100 % and shows the cover behind (only when there is one).
    @Test func backgroundFollowsOpacityAndCoverAsBackground() {
        #expect(PlayerWidgetConfiguration().backgroundAlpha == 1)
        #expect(PlayerWidgetConfiguration(opacity: 0).backgroundAlpha == 0)
        #expect(abs(PlayerWidgetConfiguration(opacity: 39).backgroundAlpha - 0.39) <= 1.0 / 255)
        #expect(abs(PlayerWidgetConfiguration(opacity: 50).backgroundAlpha - 0.5) <= 1.0 / 255)
        #expect(PlayerWidgetConfiguration(opacity: 39, coverAsBackground: true).backgroundAlpha == 1)
        let configured = PlayerWidgetConfiguration(opacity: 39, coverAsBackground: true)
        let withCover = PlayerWidgetPresentation(snapshot: snapshot(), configuration: configured, date: start, narrow: false, hasCover: true)
        #expect(withCover.showsCoverBackground && !withCover.showsCover)
        let without = PlayerWidgetPresentation(snapshot: snapshot(), configuration: configured, date: start, narrow: false, hasCover: false)
        #expect(!without.showsCoverBackground && !without.showsCover)
        let plain = PlayerWidgetPresentation(snapshot: snapshot(), configuration: .init(), date: start, narrow: false, hasCover: true)
        #expect(plain.showsCover && !plain.showsCoverBackground)
    }

    /// The app rewrites the snapshot only when the widget would show something else.
    @Test func snapshotDifferenceIgnoresPredictedProgress() {
        let playing = snapshot(position: 10_000, rate: 1, playing: true)
        var later = playing
        later.savedAt = start.addingTimeInterval(5); later.positionMilliseconds = 15_200
        #expect(!playing.differs(from: later))
        later.positionMilliseconds = 25_000
        #expect(playing.differs(from: later))
        var paused = playing; paused.isPlaying = false; paused.positionRate = 0
        #expect(playing.differs(from: paused))
        var faster = playing; faster.speed = 1.5
        #expect(playing.differs(from: faster))
        var other = playing; other.episodeID = 8
        #expect(playing.differs(from: other))
        // Unknown duration (a live stream): no time shows, so a position off the prediction (Skip silence runs
        // ahead) is no change; the play state or a duration becoming known is.
        let live = snapshot(position: 10_000, duration: 0, rate: 1, playing: true)
        var ahead = live
        ahead.savedAt = start.addingTimeInterval(5); ahead.positionMilliseconds = 40_000
        #expect(!live.differs(from: ahead))
        var stopped = ahead; stopped.isPlaying = false; stopped.positionRate = 0
        #expect(live.differs(from: stopped))
        var known = ahead; known.durationMilliseconds = 3_600_000
        #expect(live.differs(from: known))
    }

    @Test func storeKeepsTheSnapshotAndItsCover() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PlayerWidget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlayerWidgetStore(directory: directory)
        #expect(store.read() == nil)
        var value = snapshot()
        value.cover = try store.writeCover(Data([1, 2, 3]), episodeID: 7)
        try store.write(value)
        #expect(store.read() == value)
        #expect(store.cover(named: try #require(value.cover)) == Data([1, 2, 3]))
        let next = try store.writeCover(Data([4]), episodeID: 8)
        value.episodeID = 8; value.cover = next
        try store.write(value)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("cover-") } == [next])
        try store.write(nil)
        #expect(store.read() == nil)
        #expect(store.cover(named: next) == nil)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("snapshot.json"))
        #expect(store.read() == nil)
    }

    @Test func widgetLinksRouteToThePlayerAndTheSpeedDialog() {
        #expect(ExternalEntry.route(for: PlayerWidgetLink.player) == .openPlayer)
        #expect(ExternalEntry.route(for: PlayerWidgetLink.speed) == .playbackSpeed)
        #expect(ExternalEntry.route(for: URL(string: "https://example.com/speed")!) == nil)
    }
}

/// The widget's buttons and the control on the app's playback coordinator, with the fake engine
/// of the playback-preference tests.
@Suite(.serialized) @MainActor
struct PlayerWidgetPlaybackTests {
    private func intervals(rewind: Int32 = 10, forward: Int32 = 30) -> PlaybackIntervalPreferences {
        var value = PlaybackIntervalPreferences(); value.rewindSeconds = rewind; value.forwardSeconds = forward
        return value
    }

    /// Play and Pause set a state: Play while playing and Pause while paused change nothing. Without a direction
    /// (a button drawn before buttons said which) it only pauses.
    @Test func playAndPauseSetTheCurrentEpisodesState() async throws {
        try await PCPlaybackFixture.withFixture { f in
            try await f.player.select(episodeID: 1); f.engine.ready(); try await f.player.awaitPendingOperations()
            #expect(f.player.wantsPlayback && f.engine.playing)
            #expect(try await PlayerWidgetPlayback.perform(.playPause, playback: f.player, intervals: intervals()))
            #expect(!f.player.wantsPlayback && !f.engine.playing)
            #expect(try await !PlayerWidgetPlayback.perform(.playPause, playback: f.player, intervals: intervals()))
            #expect(!f.player.wantsPlayback && !f.engine.playing && f.player.episode?.id == 1)
            try await PlayerWidgetPlayback.perform(.play, playback: f.player, intervals: intervals())
            #expect(f.player.wantsPlayback && f.engine.playing)
            try await PlayerWidgetPlayback.perform(.play, playback: f.player, intervals: intervals())
            #expect(f.player.wantsPlayback && f.engine.playing)
            try await PlayerWidgetPlayback.perform(.pause, playback: f.player, intervals: intervals())
            #expect(!f.player.wantsPlayback)
            try await PlayerWidgetPlayback.perform(.pause, playback: f.player, intervals: intervals())
            #expect(!f.player.wantsPlayback)
            try await PlayerWidgetPlayback.perform(.play, playback: f.player, intervals: intervals())
            #expect(f.player.wantsPlayback && f.engine.playing)
        }
    }

    /// Rewind and fast-forward use "Rewind skip time"/"Fast-forward skip time"; fast-forward past the end ends
    /// the episode, and Skip episode moves to the next queued one (`Media3PlaybackService.java:159–183`).
    @Test func rewindFastForwardAndSkipUseThePreferredIntervals() async throws {
        try await PCPlaybackFixture.withFixture { f in
            _ = try await f.store.enqueue([1, 2, 3])
            try await f.player.select(episodeID: 1); f.engine.ready(); try await f.player.awaitPendingOperations()
            f.engine.position(50_000); try await f.player.awaitPendingOperations()
            let preferred = intervals(rewind: 20, forward: 45)
            try await PlayerWidgetPlayback.perform(.rewind, playback: f.player, intervals: preferred)
            #expect(f.engine.seeks.last == 30_000)
            try await PlayerWidgetPlayback.perform(.rewind, playback: f.player, intervals: intervals(rewind: 60))
            #expect(f.engine.seeks.last == 0)
            f.engine.position(40_000); try await f.player.awaitPendingOperations()
            try await PlayerWidgetPlayback.perform(.fastForward, playback: f.player, intervals: preferred)
            #expect(f.engine.seeks.last == 85_000 && f.player.episode?.id == 1)
            // 85 s + 45 s is beyond the 100 s episode: it ends and the queue continues with episode 2.
            try await PlayerWidgetPlayback.perform(.fastForward, playback: f.player, intervals: preferred)
            try await f.player.awaitPendingOperations()
            #expect(f.player.episode?.id == 2)
            f.engine.ready(); try await f.player.awaitPendingOperations()
            try await PlayerWidgetPlayback.perform(.skip, playback: f.player, intervals: preferred)
            try await f.player.awaitPendingOperations()
            #expect(f.player.episode?.id == 3)
        }
    }

    /// The app may be launched just for a widget button: Play first restores the saved episode and plays it from
    /// its saved position; rewind and skip need a loaded player (Android's service without media does nothing).
    @Test func playRestoresTheSavedEpisodeAfterALaunch() async throws {
        try await PCPlaybackFixture.withFixture { f in
            _ = try await f.store.enqueue([1, 2])
            try await f.player.select(episodeID: 2); f.engine.ready(); try await f.player.awaitPendingOperations()
            f.engine.position(42_000); try await f.player.awaitPendingOperations()
            try await f.player.pause()
            try await f.player.stop()
            let saved = try #require(try await f.store.episode(id: 2)?.userState.positionMilliseconds)
            #expect(saved > 0)
            let engine = PCPlaybackEngine()
            let clock = f.clock
            let launched = PlaybackCoordinator(store: f.store, engine: RoutedPlaybackEngine(local: engine),
                clock: { Date(timeIntervalSince1970: Double(clock.milliseconds) / 1_000) })
            #expect(launched.episode == nil)
            #expect(try await !PlayerWidgetPlayback.perform(.skip, playback: launched, intervals: intervals()))
            #expect(launched.episode?.id == 2 && engine.seeks.isEmpty)
            #expect(try await PlayerWidgetPlayback.perform(.play, playback: launched, intervals: intervals()))
            engine.ready(); try await launched.awaitPendingOperations()
            #expect(launched.wantsPlayback && launched.episode?.id == 2)
            #expect(launched.systemSnapshot?.positionMilliseconds == Int64(saved) && engine.position == saved)
            try await launched.stop()
        }
    }

    /// The app ended while playing and the widget still shows Pause: a tap launches the app for Pause, which
    /// restores the saved episode and leaves it paused. Only the widget's Play starts it.
    @Test func aStalePauseNeverStartsTheRestoredPlayer() async throws {
        try await PCPlaybackFixture.withFixture { f in
            try await f.player.select(episodeID: 2); f.engine.ready(); try await f.player.awaitPendingOperations()
            f.engine.position(42_000); try await f.player.awaitPendingOperations()
            try await f.player.pause()
            try await f.player.stop()
            let saved = try #require(try await f.store.episode(id: 2)?.userState.positionMilliseconds)
            let engine = PCPlaybackEngine()
            let clock = f.clock
            let launched = PlaybackCoordinator(store: f.store, engine: RoutedPlaybackEngine(local: engine),
                clock: { Date(timeIntervalSince1970: Double(clock.milliseconds) / 1_000) })
            let pause = PlayerWidgetPresentation(snapshot: PlayerWidgetSnapshot(episodeID: 2, title: "Episode 2",
                isPlaying: true, positionRate: 1, positionMilliseconds: 42_000, durationMilliseconds: 100_000, savedAt: Date()),
                configuration: .init(), date: Date(), narrow: false, hasCover: false).action(for: .playPause)
            guard case .command(let command) = pause else { Issue.record("\(pause)"); return }
            #expect(command == .pause)
            #expect(try await PlayerWidgetPlayback.perform(command, playback: launched, intervals: intervals()))
            try await launched.awaitPendingOperations()
            #expect(launched.episode?.id == 2 && !launched.wantsPlayback && !engine.playing && engine.reading == nil)
            try await PlayerWidgetPlayback.perform(.play, playback: launched, intervals: intervals())
            engine.ready(); try await launched.awaitPendingOperations()
            #expect(launched.wantsPlayback && engine.playing && engine.position == saved)
            try await launched.stop()
        }
    }

    /// A button drawn before buttons said Play or Pause (no direction, `.playPause`) may still show Pause over a
    /// silent player: one restored for the tap after the app ended, one paused by an interruption or headphone
    /// removal, one being prepared paused. It is refused there and nothing plays; it only ever pauses.
    @Test func aLegacyFlipNeverStartsPlayback() async throws {
        try await PCPlaybackFixture.withFixture { f in
            try await f.player.select(episodeID: 2); f.engine.ready(); try await f.player.awaitPendingOperations()
            f.engine.position(42_000); try await f.player.awaitPendingOperations()
            try await f.player.pause()
            try await f.player.stop()
            let engine = PCPlaybackEngine()
            let clock = f.clock
            let launched = PlaybackCoordinator(store: f.store, engine: RoutedPlaybackEngine(local: engine),
                clock: { Date(timeIntervalSince1970: Double(clock.milliseconds) / 1_000) })
            #expect(try await !PlayerWidgetPlayback.perform(.playPause, playback: launched, intervals: intervals()))
            try await launched.awaitPendingOperations()
            #expect(launched.episode?.id == 2 && launched.phase == .stopped && !launched.wantsPlayback)
            #expect(!engine.playing && engine.reading == nil)
            // Restored before the tap (the app restored its selection at launch): still refused.
            #expect(try await !PlayerWidgetPlayback.perform(.playPause, playback: launched, intervals: intervals()))
            #expect(!launched.wantsPlayback && engine.reading == nil)
            // Playing: it pauses; then, paused and loaded, it is refused.
            try await PlayerWidgetPlayback.perform(.play, playback: launched, intervals: intervals())
            engine.ready(); try await launched.awaitPendingOperations()
            #expect(launched.wantsPlayback && engine.playing)
            #expect(try await PlayerWidgetPlayback.perform(.playPause, playback: launched, intervals: intervals()))
            #expect(!launched.wantsPlayback && !engine.playing && launched.phase == .paused)
            #expect(try await !PlayerWidgetPlayback.perform(.playPause, playback: launched, intervals: intervals()))
            #expect(!launched.wantsPlayback && !engine.playing)
            // Paused from outside (an interruption, headphones removed): refused.
            try await PlayerWidgetPlayback.perform(.play, playback: launched, intervals: intervals())
            #expect(launched.wantsPlayback && engine.playing)
            engine.state(.paused); try await launched.awaitPendingOperations()
            #expect(!launched.wantsPlayback && launched.phase == .paused && engine.reading != nil)
            #expect(try await !PlayerWidgetPlayback.perform(.playPause, playback: launched, intervals: intervals()))
            try await launched.awaitPendingOperations()
            #expect(!launched.wantsPlayback && !engine.playing && launched.phase == .paused)
            // Prepared paused (selected without playing, still loading): refused, and it stays paused when ready.
            try await launched.select(episodeID: 1, play: false)
            #expect(launched.phase == .preparing && !launched.wantsPlayback)
            #expect(try await !PlayerWidgetPlayback.perform(.playPause, playback: launched, intervals: intervals()))
            engine.ready(); try await launched.awaitPendingOperations()
            #expect(launched.episode?.id == 1 && !launched.wantsPlayback && !engine.playing)
            try await launched.stop()
            // Stopped in this process: unloaded, so refused like a restored one.
            #expect(try await !PlayerWidgetPlayback.perform(.playPause, playback: launched, intervals: intervals()))
            #expect(!launched.wantsPlayback && !engine.playing)
        }
    }

    /// Playback of unknown duration (a live stream) publishes no position events, so the widget would never renew
    /// its lease; each of its ticks reaches `onUnknownDurationTick` instead, while playing and buffering, not while
    /// paused. A known duration keeps its position events and does not call it.
    @Test func unknownDurationTicksReachTheWidget() async throws {
        for duration: Int32 in [0, 100_000] {
            try await PCPlaybackFixture.withFixture { f in
                var ticks = 0, positions = 0
                f.player.onUnknownDurationTick = { ticks += 1 }
                let events = f.player.events()
                let counting = Task { @MainActor in
                    for await event in events { if case .positionChanged = event { positions += 1 } }
                }
                defer { counting.cancel() }
                try await f.player.select(episodeID: 1)
                f.engine.duration = duration; f.engine.ready(); try await f.player.awaitPendingOperations()
                #expect(f.player.wantsPlayback && f.player.phase == .playing)
                for second in 1...5 { f.engine.position(Int32(second * 1_000)); try await f.player.awaitPendingOperations() }
                f.engine.state(.playing, buffering: true); try await f.player.awaitPendingOperations()
                #expect(f.player.wantsPlayback && f.player.systemSnapshot?.rate == 0)
                for _ in 1...3 { f.engine.position(5_000); try await f.player.awaitPendingOperations() }
                try await f.player.pause()
                f.engine.position(5_000); try await f.player.awaitPendingOperations()
                if duration == 0 {
                    #expect(ticks == 8 && positions == 0, "\(ticks) \(positions)")
                } else {
                    let deadline = ContinuousClock.now + .seconds(5)
                    while positions < 8, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                    #expect(ticks == 0 && positions == 8, "\(ticks) \(positions)")
                }
            }
        }
    }

    /// The snapshot the widget reads follows the coordinator: episode, play state, rate and time settings.
    @Test func snapshotFollowsTheCoordinator() async throws {
        try await PCPlaybackFixture.withFixture { f in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            #expect(PlayerWidgetPlayback.snapshot(playback: f.player, timeDisplay: .init(), cover: nil, now: now) == nil)
            try await f.player.select(episodeID: 1); f.engine.ready(); try await f.player.awaitPendingOperations()
            f.engine.position(12_000); try await f.player.awaitPendingOperations()
            try await f.player.setSpeed(1.5)
            var playing = try #require(PlayerWidgetPlayback.snapshot(playback: f.player,
                timeDisplay: .init(showRemainingTime: true, timeRespectsSpeed: false), cover: "c.png", now: now))
            #expect(playing.episodeID == 1 && playing.title == "Episode 1" && playing.isPlaying)
            #expect(playing.positionMilliseconds == 12_000 && playing.durationMilliseconds == 100_000)
            #expect(playing.positionRate == 1.5 && playing.speed == 1.5 && playing.showRemainingTime && playing.cover == "c.png")
            #expect(playing.savedAt == now && playing.leaseSeconds == PlayerWidgetLease.duration && playing.isFresh(at: now))
            try await f.player.pause()
            playing = try #require(PlayerWidgetPlayback.snapshot(playback: f.player, timeDisplay: .init(), cover: nil, now: now))
            #expect(!playing.isPlaying && playing.positionRate == 0 && playing.speed == 1.5)
        }
    }
}
