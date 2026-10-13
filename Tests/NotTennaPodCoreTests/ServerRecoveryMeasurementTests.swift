import Foundation
import Testing
@testable import NotTennaPodCore

/// The live-transaction work of recovery (PROTOCOL §6.8): parking, the pre-push pass,
/// release and the frontier's return, quarantine, renumbering and the frontier repair, and the recovery holds, with
/// `NTP_EXCHANGE_MEASURE` pending entries (10,000 by default), while playback saves run every 5 ms. Each line gives the
/// longest single store call (one live transaction, or the longest of a chunked operation's) and the longest a
/// concurrent playback save waited. The work runs as the engine runs it (`ServerBlockingSteps`: planned on a connection
/// of its own, then bounded store transactions). They take minutes, so they run when `NTP_EXCHANGE_MEASURE` is set.
@Suite(.serialized, .timeLimit(.minutes(60)), .enabled(if: ProcessInfo.processInfo.environment["NTP_EXCHANGE_MEASURE"] != nil))
struct ServerRecoveryMeasurementTests {
    static var size: Int { Int(ProcessInfo.processInfo.environment["NTP_EXCHANGE_MEASURE"] ?? "") ?? 10_000 }

    /// Playback saves every 5 ms on `episode` while `body` runs; `body` returns its longest store call (ms).
    static func measure(_ label: String, _ store: FeedLibraryStore, session: UUID, _ body: () async throws -> Double) async throws {
        let stop = PlayingFlag()
        let saver = Task { () -> (Double, Int) in
            var longest = 0.0, count = 0, position: Int32 = 0
            let clock = ContinuousClock()
            while !stop.value {
                position += 5_000
                let started = clock.now
                _ = try? await store.recordPlayback(sessionID: session, sample: PlaybackSample(positionMilliseconds: position % 3_000_000,
                    durationMilliseconds: 3_600_000, status: .playing))
                longest = max(longest, FeedLibraryStore.milliseconds(started.duration(to: clock.now)))
                count += 1
                try? await Task.sleep(for: .milliseconds(5))
            }
            return (longest, count)
        }
        try await Task.sleep(for: .milliseconds(50))
        let hold = try await body()
        stop.value = true
        let saves = await saver.value
        print(String(format: "MEASURE %@: longest store call %.1f ms; playback saves %d, longest wait %.1f ms; ", label, hold, saves.1, saves.0) + "load \(ProcessInfo.processInfo.loadAverageDescription)")
    }

    static func timed(_ body: () async throws -> Void) async throws -> Double {
        let clock = ContinuousClock(), started = clock.now
        try await body()
        return FeedLibraryStore.milliseconds(started.duration(to: clock.now))
    }

    /// The longest of the store calls made through it.
    final class Longest: @unchecked Sendable {
        var value = 0.0
        var slow: [String] = []
        func step<T>(line: Int = #line, _ body: () async throws -> T) async throws -> T {
            let clock = ContinuousClock(), started = clock.now
            let result = try await body()
            let took = FeedLibraryStore.milliseconds(started.duration(to: clock.now))
            value = max(value, took)
            if took > 40 { slow.append(String(format: "line %d %.0f ms", line, took)); print("  slow step at line \(line): \(String(format: "%.1f", took)) ms") }
            return result
        }
    }

    /// `ServerBlockingSteps`, each store call timed.
    static func park(_ store: FeedLibraryStore, _ url: URL, behind waiting: Set<String>, onlyNew: Bool = false, _ longest: Longest) async throws -> Int {
        let plan = try ServerBlockingSteps.read(url) { try FeedLibraryStore.parkingPlan($0, behind: waiting, archived: [:]) }
        if onlyNew, plan.chosen.isEmpty { return 0 }
        _ = try await longest.step { try await store.prepareServerBlocking(plan) }
        for batch in FeedLibraryStore.chunks(plan.chosen, size: FeedLibraryStore.blockedBatch) { _ = try await longest.step { try await store.parkServerFacts(batch) } }
        try await finish(store, plan, longest)
        return plan.chosen.count
    }

    static func finish(_ store: FeedLibraryStore, _ plan: FeedLibraryStore.ServerBlockingPlan, _ longest: Longest) async throws {
        for batch in FeedLibraryStore.chunks(plan.interior, size: FeedLibraryStore.blockedBatch) { try await longest.step { try await store.takeOutOfServerFrontier(batch) } }
        while try await (longest.step { try await store.renumberServerOutbox() }) {}
    }

    @Test func parkingReleaseQuarantineRenumberingAndHolds() async throws {
        let size = Self.size
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let store = fixture.store, url = fixture.url
        // A podcast of `size` episodes, each with a base record a waiting node set (for the holds), and one playing.
        let registered = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(count: size))
        // The subscription was accepted and pulled: its facts retired.
        try await store.executeForTesting("DELETE FROM ntp_overlays")
        let x = ContractIdentity.randomUUID()
        try await store.executeForTesting("INSERT INTO ntp_nodes(node_id, knowledge_clock, frontier, kind) VALUES (?, 1, 1, 'pulled')", [.text(x)])
        try await store.executeForTesting("INSERT OR IGNORE INTO ntp_episodes(episode_id, local_id, podcast_id, kind, value) SELECT 'e1:measure-' || id, id, ?, 'guid', 'measure-' || id FROM episodes WHERE feed_id = ?",
                                          [.text(registered.podcast), .integer(registered.feed.id)])
        try await store.executeForTesting("INSERT OR REPLACE INTO ntp_records(entity, id, field_group, value, provenance) SELECT 'episode', episode_id, 'favorite', CAST('{\"favorite\":true}' AS BLOB), ? FROM ntp_episodes WHERE podcast_id = ?",
                                          [.text(ContractJSON.array([.string(x)]).canonicalText), .text(registered.podcast)])
        let playing = try #require(registered.feed.episodes.map(\.id).min())
        let session = try await store.beginPlayback(episodeID: playing).id
        // `size` unsent facts chained behind X (the first names it).
        for index in 0..<size {
            try await store.appendFactForTesting(type: "favorite.set", targets: [], payload: [:], dependencies: index == 0 ? [x] : [])
        }
        try await Self.measure("park \(size) chained facts (closure, moves, frontier repair, author rotation)", store, session: session) {
            let longest = Longest()
            let parked = try await Self.park(store, url, behind: [x], longest)
            #expect(parked == size)
            return longest.value
        }
        // Later changes flow on the fresh author.
        for _ in 0..<size { try await store.appendFactForTesting(type: "favorite.set", targets: [], payload: [:]) }
        try await Self.measure("pre-push pass over \(size) unsent and \(size) parked facts, nothing new (planned off the store) and the slot check", store, session: session) {
            let longest = Longest()
            let parked = try await Self.park(store, url, behind: [x], onlyNew: true, longest)
            #expect(parked == 0)
            while try await (longest.step { try await store.renumberServerOutbox() }) {}
            return longest.value
        }
        try await Self.measure("frontier return and release of \(size) parked facts (batches of 50)", store, session: session) {
            let longest = Longest()
            let out = try ServerBlockingSteps.read(url) { try FeedLibraryStore.blockedOutNodes($0) }
            let rejoin = try ServerBlockingSteps.read(url) { try FeedLibraryStore.rejoinPlan($0, out, stillWaiting: [x], archived: [:]) }
            for batch in FeedLibraryStore.chunks(rejoin.covered + rejoin.tips, size: FeedLibraryStore.blockedBatch) {
                try await longest.step { try await store.setServerFrontier(batch, to: rejoin.tips.contains(batch[0]) ? 1 : 0) }
            }
            let order = try ServerBlockingSteps.read(url) { try FeedLibraryStore.releasePlan($0, stillWaiting: []) }
            #expect(order.count == size)
            for batch in FeedLibraryStore.chunks(order, size: FeedLibraryStore.releaseBatch) { _ = try await longest.step { try await store.unparkServerFacts(batch) } }
            return longest.value
        }
        // A transition onto a new installation after the first unsent fact was acknowledged: \(2 * size - 1) renumbered.
        try await store.executeForTesting("UPDATE ntp_outbox SET receipt = CAST('{}' AS BLOB) WHERE install_seq = (SELECT min(install_seq) FROM ntp_outbox)")
        try await store.planServerTransition(.conflict, nonce: ContractIdentity.randomUUID())
        try await store.updateServerTransition { $0.state = .issued }
        try await Self.measure("transition commit and renumbering \(2 * size - 1) unsent facts (50 a step)", store, session: session) {
            let longest = Longest()
            _ = try await longest.step { try await store.commitServerTransition() }
            while try await (longest.step { try await store.renumberServerOutbox() }) {}
            return longest.value
        }
        try await Self.measure("quarantine \(size) chained facts (closure, marks, frontier repair)", store, session: session) {
            let longest = Longest()
            let plan = try ServerBlockingSteps.read(url) { try FeedLibraryStore.quarantinePlan($0, unrestored: [x], waiting: [], archived: [:]) }
            #expect(plan.chosen.count == size)
            _ = try await longest.step { try await store.prepareServerBlocking(plan) }
            for batch in FeedLibraryStore.chunks(plan.chosen, size: FeedLibraryStore.blockedBatch) {
                _ = try await longest.step { try await store.quarantineServerFacts(batch, reason: "refused") }
            }
            try await Self.finish(store, plan, longest)
            return longest.value
        }
        // Holds: the scan runs on a connection of its own; the store holds them 500 to a transaction and releases them
        // 50 to a unit.
        let records = try FeedLibraryStore.serverRecords(naming: [x], database: url)
        #expect(records.count == size)
        try await Self.measure("hold \(size) records (500 a transaction)", store, session: session) {
            let longest = Longest()
            for chunk in FeedLibraryStore.chunks(records) { _ = try await longest.step { try await store.holdServerRecords(chunk) } }
            return longest.value
        }
        try await Self.measure("release \(size) holds (10 a unit, each projected)", store, session: session) {
            let longest = Longest()
            var lock = 0.0
            while let unit = try await (longest.step { try await store.releaseServerHolds(stillWaiting: [], history: nil, now: Int64(Date().timeIntervalSince1970 * 1_000)) }) {
                lock = max(lock, unit.lockMilliseconds)
            }
            print(String(format: "  the longest release unit's live transaction: %.1f ms", lock))
            return longest.value
        }
        #expect(try await store.serverHeldRecordCount() == 0)
        // A held podcast of `size` episodes whose creation is refused for good: the base lacks its records once the
        // holds end, and the release removes it (its rows in bounded batches, the playing episode kept for the player).
        let y = ContractIdentity.randomUUID()
        let provenance = ContractJSON.array([.string(y)]).canonicalText
        try await store.executeForTesting("INSERT OR REPLACE INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('podcast', ?, 'subscription', CAST('{\"state\":\"subscribed\"}' AS BLOB), ?)",
                                          [.text(registered.podcast), .text(provenance)])
        try await store.executeForTesting("INSERT OR REPLACE INTO ntp_records(entity, id, field_group, value, provenance) SELECT 'episode', episode_id, 'identity', CAST(json_object('podcast_id', podcast_id) AS BLOB), ? FROM ntp_episodes WHERE podcast_id = ?",
                                          [.text(provenance), .text(registered.podcast)])
        let held = try FeedLibraryStore.serverRecords(naming: [y], database: url)
        for chunk in FeedLibraryStore.chunks(held) { try await store.holdServerRecords(chunk) }
        try await store.executeForTesting("DELETE FROM ntp_records WHERE provenance = ?", [.text(provenance)])
        try await Self.measure("release the holds of a refused \(size)-episode podcast and remove it (bounded batches)", store, session: session) {
            let longest = Longest()
            var units = 0
            while let unit = try await (longest.step { try await store.releaseServerHolds(stillWaiting: [], history: nil, now: Int64(Date().timeIntervalSince1970 * 1_000)) }) {
                units += 1
                if units <= 3 || units % 100 == 0 { print(String(format: "  release unit %d: live transaction %.1f ms, work %d", units, unit.lockMilliseconds, unit.work)) }
            }
            while try await (longest.step { try await store.deleteHiddenRemovalBatch() }).progressed {}
            return longest.value
        }
        #expect(try fixture.rows("SELECT count(*) FROM episodes WHERE feed_id = \(registered.feed.id)") == [["1"]], "only the playing episode stays, for the player")
        // Holds newer local work keeps (a pending fact about their podcast): a release pass finds nothing to end.
        let other = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/other.xml", title: "Other", count: size))
        try await store.executeForTesting("INSERT OR IGNORE INTO ntp_episodes(episode_id, local_id, podcast_id, kind, value) SELECT 'e1:kept-' || id, id, ?, 'guid', 'kept-' || id FROM episodes WHERE feed_id = ?",
                                          [.text(other.podcast), .integer(other.feed.id)])
        let z = ContractIdentity.randomUUID(), kept = ContractJSON.array([.string(z)]).canonicalText
        try await store.executeForTesting("INSERT OR REPLACE INTO ntp_records(entity, id, field_group, value, provenance) SELECT 'episode', episode_id, 'identity', CAST(json_object('podcast_id', podcast_id) AS BLOB), ? FROM ntp_episodes WHERE podcast_id = ?",
                                          [.text(kept), .text(other.podcast)])
        for chunk in FeedLibraryStore.chunks(try FeedLibraryStore.serverRecords(naming: [z], database: url)) { try await store.holdServerRecords(chunk) }
        try await store.executeForTesting("DELETE FROM ntp_records WHERE provenance = ?", [.text(kept)])
        try await store.executeForTesting("INSERT INTO ntp_overlays(op_id, entity, id, property, kind, value, clock) VALUES ('pending-work', 'podcast', ?, 'keep_updated', 'register', CAST('false' AS BLOB), 1)",
                                          [.text(other.podcast)])
        try await Self.measure("a release pass over \(size) holds newer local work keeps", store, session: session) {
            let longest = Longest()
            let unit = try await longest.step { try await store.releaseServerHolds(stillWaiting: [], history: nil, now: Int64(Date().timeIntervalSince1970 * 1_000)) }
            #expect(unit == nil)
            return longest.value
        }
        #expect(try await store.serverHeldRecordCount() == size)
    }

    /// Deferred podcast merges completing in steps: 100 small merged podcasts and one of `size`
    /// episodes, all waiting, then all free. Each step reads off the store, then completes one merge in one unit.
    @Test func deferredMergeSteps() async throws {
        let size = Self.size
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let store = fixture.store, url = fixture.url
        let p = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/p.xml", title: "P", count: 3))
        let session = try await store.beginPlayback(episodeID: try #require(p.feed.episodes.first?.id)).id
        var records: [ServerRecord] = []
        for index in 0...100 {
            let q = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/q\(index).xml", title: "Q\(index)",
                                                                                         count: index == 0 ? size : 5, guidPrefix: "q\(index)-"))
            records.append(ServerRecord(entity: "podcast", id: q.podcast, fieldGroup: "subscription",
                                        value: ["state": "merged", "merged_into": .string(p.podcast), "generation_id": .string(q.generation)]))
        }
        // Waiting for their first populations' observations.
        try await ServerProjectionUnitTests.Applier(fixture).apply(records)
        #expect(try ServerDeferredMerges.candidates(url).count == 101)
        try await Self.measure("a pass over 101 deferred merges, all waiting (one of \(size) episodes)", store, session: session) {
            let longest = Longest()
            for candidate in try ServerDeferredMerges.candidates(url) {
                let result = try await longest.step { try await ServerDeferredMerges.step(store, database: url, candidate: candidate, history: nil, now: 1_760_000_000_000) }
                #expect(result == nil)
            }
            return longest.value
        }
        try await store.executeForTesting("DELETE FROM ntp_observation_work")
        try await store.retireEverythingForTesting()
        try await Self.measure("101 deferred merges completing, one a step (one of \(size) episodes, removed in bounded batches)", store, session: session) {
            let longest = Longest()
            while let candidate = try ServerDeferredMerges.candidates(url).first {
                _ = try await longest.step { try await ServerDeferredMerges.step(store, database: url, candidate: candidate, history: nil, now: 1_760_000_000_000) }
                while try await (longest.step { try await store.deleteHiddenRemovalBatch() }).progressed {}
            }
            return longest.value
        }
    }
}
