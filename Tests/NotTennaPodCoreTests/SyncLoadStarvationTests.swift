import AVFoundation
import Foundation
import Testing
@testable import NotTennaPodCore

/// Sync never starves audio (PROTOCOL §6.8; scenario 29 PROTOCOL §16). A long MP3 plays through the production
/// processed-PCM path and Apple's renderer, on a server library's own player, while the exchange does its heaviest work
/// against the pinned server, with the app in the background (listening with the screen locked): a large podcast's
/// catalog arrives and is staged, a first attachment of that library is built beside it, the worst-case commits of
/// PROTOCOL §6.8 arrive while the person uses the app (the large podcast's removal, listening and a history clear over
/// thousands of episodes, a sorted add rewriting a 1,000-item queue: what is over the publication budget waits for the
/// app to leave the foreground, PROTOCOL §6.8), then the person leaves the app, still listening, and they are published
/// whole within the background budget; the player's own saves are pushed with the durable minute's exports, and the
/// queue is edited. It fails only on what a person would notice: any moment the renderer runs dry, heard speed off by
/// more than 3 %, and any synchronization transaction (a unit or any other) that held the live write lock for more than
/// a second while playing. The longest of each kind is logged against its PROTOCOL §6.8 budget
/// (`ServerTransactionKind.budgets`) as information only. After the pause what still waited applies. It takes minutes,
/// so it runs when `NTP_SYNC_STARVATION` is set (`NTP_SYNC_STARVATION=20000` sets the large podcast's size, the
/// default); run it on a quiet machine with `PCMRealTimeStarvationTests`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NTP_SYNC_STARVATION"] != nil))
@MainActor struct SyncLoadStarvationTests {
    typealias Agreement = ServerExchangeAgreementTests
    typealias Concurrency = ServerExchangeConcurrencyTests

    @MainActor final class Driver: AudioSessionActivationDriver {
        func setActive(_ active: Bool) async throws -> Bool { true }
    }

    static var size: Int { Int(ProcessInfo.processInfo.environment["NTP_SYNC_STARVATION"] ?? "") ?? 20_000 }

    /// The episodes of A's own podcast: the one it plays and the queue it edits while playing. The queue edit must not
    /// depend on the large catalog: over the publication budget, it waits on A for the pause (PROTOCOL §6.8) at 20,000 episodes.
    static let otherEpisodes = 25

    /// The longest a synchronization transaction may hold the live write lock while playing before a person would
    /// notice (a save or a screen's write waiting); the PROTOCOL §6.8 budgets are logged, not asserted.
    static let noticeableLock = 1_000.0

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    @Test(arguments: [Float(1), 1.75])
    func playingThroughTheHeaviestSyncNeverStarves(speed: Float) async throws {
        let size = Self.size
        let history = min(5_000, max(500, size / 4))
        let world = try await ExchangeWorld.start(feeds: ["/large.xml": ("Large", "large", size), "/hist.xml": ("History", "hist", history),
                                                          "/queue.xml": ("Queue", "queue", 1_000), "/other.xml": ("Other", "other", Self.otherEpisodes)])
        do { try await run(world, speed: speed, size: size, history: history) } catch { await world.stop(); throw error }
        await world.stop()
    }

    private func run(_ world: ExchangeWorld, speed: Float, size: Int, history: Int) async throws {
        // Each progress line says how long the run has taken so far (where a slow step spends its time).
        let begun = ContinuousClock.now
        func log(_ line: String) { print("SYNC LOAD [+\(Int(Self.seconds(begun.duration(to: .now)))) s] \(line)") }
        do {
            let a = try await world.attach("A")
            let other = try await a.store.insert(Agreement.fetched(world.url("other.xml"), title: "Other", prefix: "other", count: Self.otherEpisodes))
            try await Agreement.waitForCatalog(a, feedID: other.id)
            let c = try await world.attach("C")
            // A's player: the production PCM path on the server library's store, playing a half-hour MP3.
            let fixture = try #require(Bundle.module.url(forResource: "half-hour.mp3", withExtension: nil, subdirectory: "Fixtures/LongMP3"))
            let cache = world.root.appendingPathComponent("pcm-cache")
            let factories = PCMPlaybackFactory(cacheDirectory: cache, minimumQueuedSeconds: PCMRecoveryFactory.productionQueuedSeconds,
                                               makeTransport: { NativeSampleBufferTransport(muted: true) })
            let engine = PCMPlaybackEngine(driver: Driver(), resolveFactory: { _, url in
                try #require(try await factories.processedIfSupported(url: url, proxy: PodcastProxy(), credentials: nil, userAgent: "t"))
            }, source: { _ in fixture })
            let player = PlaybackCoordinator(store: a.store, engine: engine, preferences: { _ in
                var preferences = PlaybackPreferences(); preferences.speed = speed; return preferences
            }, clock: { Date() })
            let episode = try #require(other.episodes.first?.id)
            try await player.select(episodeID: episode)
            let ready = ContinuousClock.now + .seconds(10)
            while player.phase != .playing, ContinuousClock.now < ready { try await Task.sleep(for: .milliseconds(10)) }
            try #require(player.phase == .playing)
            a.playing.value = true
            a.foreground.value = false
            defer { engine.unload() }
            try await Task.sleep(for: .milliseconds(500))
            PCMStarvationDiagnostics.reset()
            let startMedia = Double(engine.reading?.sample.positionMilliseconds ?? 0) / 1_000
            let started = ContinuousClock.now
            var units: [(label: String, unit: ServerUnitTiming)] = []
            // Every synchronization transaction that held the live write lock while playing, the longest of each kind per
            // step (PROTOCOL §6.8): logged against its kind's budget, failing only over a second.
            var transactions: [(label: String, kind: String, time: LibraryTransactionTime)] = []
            func describe(_ times: [String: LibraryTransactionTime]) -> String {
                times.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.1f", $0.value.milliseconds)) ms (commit \(String(format: "%.1f", $0.value.commitMilliseconds))) ×\($0.value.count)" }
                    .joined(separator: ", ")
            }
            func exchange(_ label: String) async {
                let report = await a.engine.exchange()
                units += report.units.map { (label, $0) }
                transactions += report.transactionTimes.map { (label, $0.key, $0.value) }
                log("\(label): \(report.appliedUnits) units (\(report.units.filter(\.background).count) whole in the background, the longest "
                      + "\(String(format: "%.1f", report.units.filter(\.background).map(\.lockMilliseconds).max() ?? 0)) ms), \(report.shownAhead) rows shown ahead, "
                      + "longest lock \(String(format: "%.1f", report.longestLockMilliseconds)) ms, "
                      + "waiting for a pause \(report.waitingForPause), for the background \(report.waitingForBackground); "
                      + "transactions: \(describe(report.transactionTimes))")
            }

            // 1. A large podcast's catalog arrives on A as staged units while A plays.
            let large = try await c.store.insert(Agreement.fetched(world.url("large.xml"), title: "Large", prefix: "large", count: size))
            await c.exchange()
            let podcast = try #require(try await c.store.podcastOfFeedForTesting(large.id))
            _ = try await c.transport.server.send("POST", "v1/refresh", body: ["podcast_id": .string(podcast)])
            try await Agreement.waitForCatalog(c, feedID: large.id)
            await exchange("catalog of a \(size)-episode podcast")
            // 2. A first attachment of that library is built beside the playing one.
            let attachment = ContinuousClock.now
            let d = try await world.attach("D")
            log("first attachment of a \(size)-episode library: \(attachment.duration(to: .now))")
            await d.close()
            // 3. The queue is edited while playing, and A's own saves (with the durable minute's export) are pushed. A's own
            // podcast's episodes: whether the large catalog is on A yet depends on its size (it waits for the pause when
            // its publication is over the budget).
            let ids = Array(other.episodes.map(\.id).sorted().prefix(20))
            try #require(ids.count == 20)
            _ = try await a.store.enqueue(ids)
            _ = try await a.store.performQueueMove(.item(ids[3], finalIndex: 0), expected: try await a.store.queue().map(QueueEpisodeIdentity.init))
            await exchange("queue edits and playback exports")
            // 4. The worst-case publications (PROTOCOL §6.8), while the person uses the app, still listening: the large podcast's
            // removal, listening and a history clear over many episodes, a sorted add rewriting a 1,000-item queue. What is
            // over the publication budget waits for the app to leave the foreground.
            a.foreground.value = true
            log("another phone removes the \(size)-episode podcast")
            #expect(try await c.store.requestFeedDeletion(feedID: large.id))
            await c.exchange()
            await exchange("removal of a \(size)-episode podcast")
            let hist = try await c.store.insert(Agreement.fetched(world.url("hist.xml"), title: "History", prefix: "hist", count: history))
            try await Agreement.waitForCatalog(c, feedID: hist.id)
            log("another phone records listening of \(history) episodes")
            for id in hist.episodes.map(\.id) {
                var session = RemoteSession(store: c.store, episode: id)
                try await session.start(at: 0)
                try await session.end(position: 1_000, contribution: 1_000, completed: false)
            }
            await c.exchange()
            await exchange("listening of \(history) episodes")
            _ = try await c.store.clearPlaybackHistory()
            await c.exchange()
            await exchange("history clear covering \(history) episodes")
            let queue = try await c.store.insert(Agreement.fetched(world.url("queue.xml"), title: "Queue", prefix: "queue", count: 1_000))
            try await Agreement.waitForCatalog(c, feedID: queue.id)
            let queued = queue.episodes.map(\.id)
            _ = try await c.store.enqueue(Array(queued.dropLast()))
            await c.exchange()
            await exchange("a 999-item queue")
            c.store.setQueueInsertionSettings(.init(keepSortedOrder: .episodeTitleZA))
            try await c.store.setServerAccountPolicy(.sorting(keepSorted: true, order: .episodeTitleZA))
            _ = try await c.store.enqueue([queued.last!])
            await c.exchange()
            await exchange("a 1,000-item queue rewritten by a sorted add")
            // 5. The person leaves the app, still listening (the screen locked): what waited is published whole, each within
            // the background budget, while audio plays.
            a.foreground.value = false
            let left = units.count
            await exchange("the worst-case publications, in the background while playing")
            #expect(units.dropFirst(left).contains { $0.unit.background }, "whole publications ran in the background while playing")
            // Play on past a minute's export, then push it.
            while started.duration(to: .now) < .seconds(75) { try await Task.sleep(for: .milliseconds(250)) }
            await exchange("the durable minute's export")

            let elapsed = Self.seconds(started.duration(to: .now))
            let advanced = Double(engine.reading?.sample.positionMilliseconds ?? 0) / 1_000 - startMedia
            let starvation = PCMStarvationDiagnostics.current
            let exported = try a.rows("SELECT CAST(record AS TEXT) FROM ntp_sessions").compactMap { $0[0] }
                .map { (try? ContractJSON.decode(Data($0.utf8)))?["ordinal"]?.integerValue ?? 0 }
            try await player.pause()
            a.playing.value = false
            let paused = await a.engine.exchange()
            // A unit here is a commit that arrived after the last exchange while playing (its pull came before the server
            // committed what that exchange's last push sent), not one that waited: its waiting flags were false.
            log("after the pause: \(paused.appliedUnits) units (retiring \(paused.units.map(\.retired)) of this phone's facts), \(paused.publishedUnits) published, longest lock "
                  + "\(String(format: "%.1f", paused.longestLockMilliseconds)) ms, waiting \(paused.waitingForPause) \(paused.waitingForBackground)")
            log("\(speed)×: \(String(format: "%.1f", elapsed)) s, heard \(String(format: "%.3f", advanced / elapsed))×, "
                  + "starvation \(starvation.events)× for \(starvation.overrunSeconds) s; units \(units.count) (\(units.filter(\.unit.background).count) whole in the background), longest "
                  + "\(String(format: "%.1f", units.map(\.unit.lockMilliseconds).max() ?? 0)) ms; checkpoints exported while playing \(exported); "
                  + "load \(ProcessInfo.processInfo.loadAverageDescription)")
            #expect(starvation.events == 0, "the renderer ran dry \(starvation.events)× for \(starvation.overrunSeconds) s at \(speed)×")
            #expect(abs(advanced / elapsed - Double(speed)) / Double(speed) < 0.03, "heard \(advanced / elapsed)× at \(speed)×")
            #expect(exported.contains { $0 >= 1 }, "the minute's export was made while playing")
            for (label, unit) in units {
                let kind = unit.background ? "whole publication in the background" : unit.published ? "publication" : "direct unit"
                #expect(unit.lockMilliseconds <= Self.noticeableLock, "\(label): a \(kind) held the lock \(unit.lockMilliseconds) ms")
            }
            var longest: [String: LibraryTransactionTime] = [:]
            for (label, kind, time) in transactions {
                longest[kind, default: LibraryTransactionTime()].merge(time)
                #expect(time.milliseconds <= Self.noticeableLock, "\(label): a \(kind) transaction held the lock \(time.milliseconds) ms (its commit \(time.commitMilliseconds) ms)")
            }
            // Information only: each kind's longest against its PROTOCOL §6.8 budget.
            let againstBudgets = longest.sorted { $0.key < $1.key }.map { kind, time in
                let budget = ServerTransactionKind.budgets[kind].map { String(format: "%.0f", $0) } ?? "?"
                return "\(kind) \(String(format: "%.1f", time.milliseconds)) of \(budget) ms\(time.milliseconds > (ServerTransactionKind.budgets[kind] ?? .infinity) ? " (over)" : "")"
            }.joined(separator: ", ")
            log("\(speed)× longest transactions while playing: \(describe(longest))")
            log("\(speed)× against the budgets (not asserted): \(againstBudgets)")
        }
    }
}
