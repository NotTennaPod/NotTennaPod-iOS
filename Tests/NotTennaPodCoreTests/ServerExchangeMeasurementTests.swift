import Foundation
import Testing
@testable import NotTennaPodCore

/// Worst-case measurements (PROTOCOL §6.8): the apply time of large commits, how long each held the live write lock,
/// and the latency of playback saves made while they applied. They take minutes, so they run when
/// `NTP_EXCHANGE_MEASURE` is set (`NTP_EXCHANGE_MEASURE=20000` sets the large podcast's size).
@Suite(.serialized, .timeLimit(.minutes(60)), .enabled(if: ProcessInfo.processInfo.environment["NTP_EXCHANGE_MEASURE"] != nil))
struct ServerExchangeMeasurementTests {
    typealias Agreement = ServerExchangeAgreementTests
    typealias Concurrency = ServerExchangeConcurrencyTests

    static var size: Int { Int(ProcessInfo.processInfo.environment["NTP_EXCHANGE_MEASURE"] ?? "") ?? 20_000 }

    /// Playback saves every 5 ms on `episode` while `body` runs: the longest a save waited (the live lock's hold, as a
    /// playback save feels it).
    /// Saves that waited longer than 50 ms are listed with when they started (seconds after `body` began, the slowest
    /// five), so a wait can be put beside the exchange's log.
    static func savesDuring(_ phone: ExchangePhone, episode: Int64, _ body: () async throws -> Void) async throws -> (longest: Double, saves: Int) {
        let session = try await phone.store.beginPlayback(episodeID: episode)
        let stop = PlayingFlag()
        let store = phone.store
        let began = ContinuousClock.now, wall = Date()
        let saver = Task { () -> (Double, Int, [(Double, Double)]) in
            var longest = 0.0, count = 0, position: Int32 = 0, slow: [(Double, Double)] = []
            let clock = ContinuousClock()
            while !stop.value {
                position += 5_000
                let started = clock.now
                _ = try? await store.recordPlayback(sessionID: session.id, sample: PlaybackSample(positionMilliseconds: position,
                    durationMilliseconds: 3_600_000, status: .playing))
                let wait = FeedLibraryStore.milliseconds(started.duration(to: clock.now))
                longest = max(longest, wait)
                if wait > 50 { slow.append((FeedLibraryStore.milliseconds(began.duration(to: started)) / 1_000, wait)) }
                count += 1
                try? await Task.sleep(for: .milliseconds(5))
            }
            return (longest, count, slow)
        }
        try await body()
        stop.value = true
        let result = await saver.value
        if !result.2.isEmpty {
            let slowest = result.2.sorted { $0.1 > $1.1 }.prefix(5).sorted { $0.0 < $1.0 }
            print("  slow saves: " + slowest.map { String(format: "+%.1f s %.0f ms", $0.0, $0.1) }.joined(separator: ", "))
            let since = Int64(wall.timeIntervalSince1970 * 1_000)
            let steps = try await phone.engine.logEntries().filter { $0.time >= since }.sorted { $0.time < $1.time }.prefix(12)
            print("  log: " + steps.map { String(format: "+%.1f s ", Double($0.time - since) / 1_000) + "\($0.kind) \($0.detail.prefix(60))" }.joined(separator: " | "))
        }
        return (result.0, result.1)
    }

    static func line(_ label: String, _ exchange: ServerExchangeReport, seconds: Double, saves: (longest: Double, saves: Int)) -> String {
        let units = exchange.units.map { "\($0.published ? "published" : "direct") \($0.work) work, \($0.rowsWritten) rows written, \(String(format: "%.1f", $0.lockMilliseconds)) ms" }
        return "MEASURE \(label): \(exchange.appliedUnits) units in \(String(format: "%.1f", seconds)) s, longest live lock \(String(format: "%.1f", exchange.longestLockMilliseconds)) ms, "
            + "shadow build \(String(format: "%.1f", exchange.shadowBuildMilliseconds)) ms, waiting for a pause: \(exchange.waitingForPause), "
            + "waiting for the background: \(exchange.waitingForBackground); staging transactions \(exchange.stagingBatches), removal transactions \(exchange.removalBatches); "
            + "playback saves \(saves.saves), longest wait \(String(format: "%.1f", saves.longest)) ms; units [\(units.joined(separator: "; "))]; "
            + "load \(ProcessInfo.processInfo.loadAverageDescription)"
    }

    /// How the person uses the phone while what is pending applies: in the app, listening with
    /// the app in the background, or neither (a background or processing task).
    enum Use: String, CaseIterable { case inUse = "in use", playing = "while playing", background = "in the background" }

    static func set(_ a: ExchangePhone, _ use: Use) {
        a.foreground.value = use == .inUse
        a.playing.value = use == .playing
    }

    /// Applies what is pending on A three times: while someone uses the app (an over-budget publication waits for
    /// the background), while A plays in the background (units paced, an over-budget publication waits for a pause),
    /// then in the background, paused; playback saves run throughout. Prints each.
    static func measure(_ label: String, _ a: ExchangePhone, playing episode: Int64) async throws {
        let clock = ContinuousClock()
        for use in Use.allCases {
            set(a, use)
            let started = clock.now
            var report = ServerExchangeReport()
            let saves = try await savesDuring(a, episode: episode) { report = await a.engine.exchange() }
            let seconds = FeedLibraryStore.milliseconds(started.duration(to: clock.now)) / 1_000
            print(line("\(label) (\(use.rawValue))", report, seconds: seconds, saves: saves))
        }
        set(a, .background)
    }

    /// Force full synchronization of what A holds, the same three ways.
    static func measureFull(_ label: String, _ a: ExchangePhone, playing episode: Int64) async throws {
        let clock = ContinuousClock()
        for use in Use.allCases {
            set(a, use)
            let started = clock.now
            var report = ServerExchangeReport()
            let saves = try await savesDuring(a, episode: episode) { report = await a.engine.forceFullSynchronization() }
            let seconds = FeedLibraryStore.milliseconds(started.duration(to: clock.now)) / 1_000
            print(line("\(label) (\(use.rawValue), reprojected \(report.reprojected))", report, seconds: seconds, saves: saves))
        }
        set(a, .background)
    }

    @Test func largeCommits() async throws {
        let size = Self.size
        let long = "Large"
        try await ExchangeWorld.run(feeds: ["/large.xml": (long, "large", size), "/hist.xml": ("History", "hist", 5_000),
                                            "/queue.xml": ("Queue", "queue", 1_000), "/other.xml": ("Other", "other", 3)]) { world in
            let a = try await world.attach("A")
            let other = try await a.store.insert(Agreement.fetched(world.url("other.xml"), title: "Other", prefix: "other", count: 3))
            try await Agreement.waitForCatalog(a, feedID: other.id)
            let playing = try #require(other.episodes.first?.id)
            let clock = ContinuousClock()

            // 1. A podcast of `size` episodes arrives: subscribed here, its catalog fetched by the server.
            let large = try await a.store.insert(Agreement.fetched(world.url("large.xml"), title: long, prefix: "large", count: size))
            await a.exchange()
            let podcast = try #require(try await a.store.podcastOfFeedForTesting(large.id))
            let c = try await world.attach("C")
            _ = try await c.transport.server.send("POST", "v1/refresh", body: ["podcast_id": .string(podcast)])
            try await Agreement.waitForCatalog(c, feedID: try await Concurrency.feed(of: podcast, on: c))
            try await Self.measure("catalog of a \(size)-episode podcast", a, playing: playing)
            if ProcessInfo.processInfo.environment["NTP_EXCHANGE_MEASURE_ONLY"] == "catalog" { return }

            // 2. First attachment of that library.
            let started = clock.now
            let d = try await world.attach("D")
            print("MEASURE first attachment of a \(size)-episode library: \(started.duration(to: clock.now))")
            await d.close()

            // 2b. Force full synchronization of that library: nothing to repair, then 2,000 wrong favorites.
            try await Self.measureFull("Force full synchronization of a \(size)-episode library, nothing to repair", a, playing: playing)
            let largeIDs = try await a.store.feed(id: large.id)?.episodes.map(\.id) ?? []
            for id in largeIDs.prefix(2_000) { try await a.store.projectForTesting(id) { $0.userState.isFavorite = true } }
            try await Self.measureFull("Force full synchronization repairing 2,000 rows of a \(size)-episode library", a, playing: playing)

            // 3. The podcast is removed elsewhere: it leaves A's lists in one small unit, its rows in bounded transactions.
            #expect(try await c.store.requestFeedDeletion(feedID: try await Concurrency.feed(of: podcast, on: c)))
            await c.exchange()
            try await Self.measure("removal of a \(size)-episode podcast", a, playing: playing)
            #expect(try await a.store.feed(id: large.id) == nil)

            // 4. A history clear covering 5,000 episodes.
            let hist = try await c.store.insert(Agreement.fetched(world.url("hist.xml"), title: "History", prefix: "hist", count: 5_000))
            try await Agreement.waitForCatalog(c, feedID: hist.id)
            try await Self.measure("a 5,000-episode podcast arriving", a, playing: playing)
            for id in hist.episodes.map(\.id) {
                var session = RemoteSession(store: c.store, episode: id)
                try await session.start(at: 0)
                try await session.end(position: 1_000, contribution: 1_000, completed: false)
            }
            await c.exchange()
            try await Self.measure("listening of 5,000 episodes arriving", a, playing: playing)
            _ = try await c.store.clearPlaybackHistory()
            await c.exchange()
            try await Self.measure("history clear covering 5,000 episodes", a, playing: playing)

            // 5. A 1,000-item queue asserted by a Keep sorted add.
            let queue = try await c.store.insert(Agreement.fetched(world.url("queue.xml"), title: "Queue", prefix: "queue", count: 1_000))
            try await Agreement.waitForCatalog(c, feedID: queue.id)
            let ids = queue.episodes.map(\.id)
            _ = try await c.store.enqueue(Array(ids.dropLast()))
            await c.exchange()
            try await Self.measure("a 999-item queue arriving", a, playing: playing)
            c.store.setQueueInsertionSettings(.init(keepSortedOrder: .episodeTitleZA))
            try await c.store.setServerAccountPolicy(.sorting(keepSorted: true, order: .episodeTitleZA))
            _ = try await c.store.enqueue([ids.last!])
            await c.exchange()
            try await Self.measure("a 1,000-item queue rewritten by a sorted add", a, playing: playing)
            #expect(try await a.view().queue == (try await c.view().queue))

            // 6. Retirement after a week offline: 1,000 of A's own facts come back.
            for id in ids { try await a.store.setFavorite(episodeID: try await Concurrency.same(id, from: c, on: a), favorite: true) }
            try await Self.measure("1,000 local facts pushed and retired", a, playing: playing)
        }
    }
}

extension ProcessInfo {
    var loadAverageDescription: String {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return "?" }
        return loads.map { String(format: "%.1f", $0) }.joined(separator: " ")
    }
}
