import Foundation
import SQLite3
import Testing
@testable import NotTennaPodCore

/// The change sets' budgets, counters first (time is secondary): routine changes cost what they change, never what the library
/// holds. End-to-end work is metered over every connection of the process during the operation (`SQLWorkMeter`: VM
/// steps, pages fetched, rows and bytes handed to the host, journal sessions decoded); the capture's own work (rows it
/// writes, rows its drain reads, digest inputs) apart. One dimension varies at a time with the logical change held
/// constant. Every capture statement and every statement a routine operation runs passes a query-plan guard: no scan of a
/// library table but the queue. `NTP_SCALE=1` adds the power-user size (120 podcasts × 450 episodes, 54,000).
@Suite(.serialized) struct ServerChangeSetBudgetTests {
    struct Work: CustomStringConvertible {
        var steps: Int64 = 0, pages: Int64 = 0, captureRows: Int64 = 0, drainRows: Int64 = 0, digests: Int64 = 0, keys = 0
        var rowsRead: Int64 = 0, bytesRead: Int64 = 0, sessions: Int64 = 0, statements: Int64 = 0
        var rowsWritten: Int64 = 0, decoded: Int64 = 0, decodedBytes: Int64 = 0
        var description: String {
            "\(steps) VM steps, \(pages) pages, \(rowsRead) rows and \(bytesRead) bytes read, \(rowsWritten) rows written, "
                + "\(decoded) records (\(decodedBytes) bytes) and \(sessions) sessions decoded, \(keys) keys, "
                + "capture \(captureRows) rows written, \(drainRows) read, \(digests) digest inputs"
        }
        static func - (a: Work, b: Work) -> Work {
            Work(steps: a.steps - b.steps, pages: a.pages - b.pages, captureRows: a.captureRows - b.captureRows,
                 drainRows: a.drainRows - b.drainRows, digests: a.digests - b.digests, keys: a.keys - b.keys,
                 rowsRead: a.rowsRead - b.rowsRead, bytesRead: a.bytesRead - b.bytesRead, sessions: a.sessions - b.sessions,
                 statements: a.statements - b.statements, rowsWritten: a.rowsWritten - b.rowsWritten, decoded: a.decoded - b.decoded,
                 decodedBytes: a.decodedBytes - b.decodedBytes)
        }
        static func + (a: Work, b: Work) -> Work {
            Work(steps: a.steps + b.steps, pages: a.pages + b.pages, captureRows: a.captureRows + b.captureRows,
                 drainRows: a.drainRows + b.drainRows, digests: a.digests + b.digests, keys: a.keys + b.keys,
                 rowsRead: a.rowsRead + b.rowsRead, bytesRead: a.bytesRead + b.bytesRead, sessions: a.sessions + b.sessions,
                 statements: a.statements + b.statements, rowsWritten: a.rowsWritten + b.rowsWritten, decoded: a.decoded + b.decoded,
                 decodedBytes: a.decodedBytes + b.decodedBytes)
        }
    }

    static let scale = ProcessInfo.processInfo.environment["NTP_SCALE"] != nil

    /// Flat: the large library's work is within 10 % of the small one's plus a constant.
    static func expectFlat(_ label: String, _ small: Work, _ large: Work, constant: Int64 = 2_000, sourceLocation: SourceLocation = #_sourceLocation) {
        print("BUDGET \(label): small \(small) | large \(large)")
        #expect(large.steps <= small.steps + small.steps / 10 + constant, "\(label) VM steps: \(small.steps) → \(large.steps)", sourceLocation: sourceLocation)
        #expect(large.pages <= small.pages + small.pages / 10 + constant / 20, "\(label) pages: \(small.pages) → \(large.pages)", sourceLocation: sourceLocation)
        #expect(large.captureRows <= small.captureRows + 4 && large.drainRows <= small.drainRows + 4 && large.digests <= small.digests + 4,
                "\(label) capture work: \(small) → \(large)", sourceLocation: sourceLocation)
        #expect(large.rowsRead <= small.rowsRead + small.rowsRead / 10 + constant / 20 && large.bytesRead <= small.bytesRead + small.bytesRead / 10 + constant * 20
                    && large.sessions <= small.sessions + 2 && large.decoded <= small.decoded + small.decoded / 10 + 4
                    && large.decodedBytes <= small.decodedBytes + small.decodedBytes / 10 + constant * 20
                    && large.rowsWritten <= small.rowsWritten + small.rowsWritten / 10 + 8 && large.keys <= small.keys + 4,
                "\(label) host work: \(small) → \(large)", sourceLocation: sourceLocation)
    }

    /// Whether `large` is flat against `small` (the same rule, as a value, for mutation checks).
    static func isFlat(_ small: Work, _ large: Work, constant: Int64 = 2_000) -> Bool {
        large.steps <= small.steps + small.steps / 10 + constant && large.pages <= small.pages + small.pages / 10 + constant / 20
            && large.rowsRead <= small.rowsRead + small.rowsRead / 10 + constant / 20 && large.bytesRead <= small.bytesRead + small.bytesRead / 10 + constant * 20
            && large.digests <= small.digests + 4 && large.sessions <= small.sessions + 2
            && large.decoded <= small.decoded + small.decoded / 10 + 4 && large.decodedBytes <= small.decodedBytes + small.decodedBytes / 10 + constant * 20
            && large.rowsWritten <= small.rowsWritten + small.rowsWritten / 10 + 8 && large.keys <= small.keys + 4
    }

    // MARK: - Server libraries of a given size

    static let generation = "g1:" + String(repeating: "5", count: 64)
    static func podcast(_ number: Int) -> String { "p1:" + ContractIdentity.sha256Hex(Array("budget-podcast-\(number)".utf8)) }
    static func wire(_ podcast: Int, _ episode: Int) -> String { "e1:" + ContractIdentity.sha256Hex(Array("budget-\(podcast)-\(episode)".utf8)) }

    static func podcastRecords(_ number: Int, episodes: Int, queued: Int = 0) throws -> [ServerRecord] {
        let id = podcast(number), url = "https://example.test/budget-\(number).xml"
        var records = [
            ServerRecord(entity: "podcast", id: id, fieldGroup: "identity", value: ["refresh_url": .string(url), "aliases": [["url": .string(url), "normalized": .string(url)]]]),
            ServerRecord(entity: "podcast", id: id, fieldGroup: "subscription", value: ["state": "subscribed", "generation_id": .string(generation)]),
        ]
        var key: QueueKey?
        for episode in 1...episodes {
            let wire = wire(number, episode), guid = "budget-\(number)-\(episode)"
            records.append(ServerRecord(entity: "episode", id: wire, fieldGroup: "identity", value: ["podcast_id": .string(id),
                "occurrence": ["k": "rss-guid", "v": .string(guid), "guid": .string(guid)]]))
            records.append(ServerRecord(entity: "episode", id: wire, fieldGroup: "metadata", value: [
                "title": .string("Episode \(episode)"), "description": .null, "link": .null, "pub_date": .integer(1_700_000_000_000 + Int64(episode) * 60_000),
                "image_url": .null, "payment_link": .null,
                "media": ["url": .string("https://example.test/\(guid).mp3"), "size": "1000", "mime_type": "audio/mpeg", "duration": 600_000],
                "chapters": .null, "chapter_url": .null, "transcript_url": .null, "transcript_type": .null, "social_interact_url": .null,
                "revision": .string("r-\(guid)"), "fetch_time": 1_700_000_000_000]))
            if episode <= queued {
                key = try QueueKey.between(key, nil, positionWriteID: UUID())
                records += [ServerProjectionUnitTests.membership(wire, generation, true), ServerProjectionUnitTests.position(wire, generation, key!)]
            }
        }
        return records
    }

    /// A server library of `podcasts` × `episodes`, the first podcast's first ten episodes queued, everything applied.
    static func library(podcasts: Int, episodes: Int) async throws -> (ServerLibraryFixture, ServerProjectionUnitTests.Applier) {
        let fixture = try await ServerLibraryFixture()
        let applier = try await ServerProjectionUnitTests.Applier(fixture)
        for number in 0..<podcasts { try await applier.apply(try podcastRecords(number, episodes: episodes, queued: number == 0 ? 10 : 0)) }
        return (fixture, applier)
    }

    /// The work of `body`: the meter over every connection, and the store's capture counters.
    static func measure(_ store: FeedLibraryStore, _ body: () async throws -> Void) async throws -> Work {
        SQLWorkMeter.shared.setEnabled(true)
        defer { SQLWorkMeter.shared.setEnabled(false) }
        let before = await store.workForTesting()
        try await body()
        return await store.workForTesting() - before
    }

    /// The routine sync units of PROTOCOL §6.8 on a small and a large library: each costs the same.
    @Test func routineUnitsAreFlatInTheLibrarySize() async throws {
        let sizes = Self.scale ? [(2, 450), (120, 450)] : [(2, 450), (12, 450)]
        var results: [String: [Work]] = [:]
        for (podcasts, episodes) in sizes {
            let (fixture, applier) = try await Self.library(podcasts: podcasts, episodes: episodes)
            let store = fixture.store
            let one = Self.wire(0, 5), two = Self.wire(0, 6)
            func unit(_ label: String, _ records: [ServerRecord]) async throws {
                results[label, default: []].append(try await Self.measure(store) { try await applier.apply(records) })
            }
            try await unit("another device's played mark", [ServerRecord(entity: "episode", id: one, fieldGroup: "play_state",
                value: ["generation_id": .string(Self.generation), "play_state": "played"])])
            try await unit("another device's checkpoint", [
                ServerRecord(entity: "episode", id: two, fieldGroup: "position", value: ["generation_id": .string(Self.generation), "position": 90_000,
                                                                                       "claim_id": .string(ContractIdentity.randomUUID())]),
                ServerRecord(entity: "episode", id: two, fieldGroup: "last_played", value: ["generation_id": .string(Self.generation), "time": 1_760_000_000_000]),
                ServerRecord(entity: "episode", id: two, fieldGroup: "played_time", value: ["generation_id": .string(Self.generation), "played_ms": 90_000])])
            // The same move in both libraries: episode 1 to the same new key.
            try await unit("a queue move", [ServerProjectionUnitTests.position(Self.wire(0, 1), Self.generation,
                try QueueKey.between(nil, nil, positionWriteID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!))])
            let fresh = try Self.podcastRecords(0, episodes: episodes + 1).suffix(2)
            try await unit("one new episode", Array(fresh))
            try await unit("a favorite", [ServerRecord(entity: "episode", id: one, fieldGroup: "favorite",
                                                       value: ["generation_id": .string(Self.generation), "on": true])])
            // What the units left is what a full reprojection of the same records shows, at this size too.
            let rebuilt = ContinuousClock.now
            let differences = try await ServerChangeSetCaptureTests.rebuildDifferences(store, ownedRoot: fixture.directory, archive: nil)
            #expect(differences.isEmpty, "\(podcasts) × \(episodes): \(differences.prefix(8).joined(separator: "\n"))")
            print("BUDGET rebuild of \(podcasts) × \(episodes) episodes compared in \(ContinuousClock.now - rebuilt)")
            // The adoption check on the player's episode.
            let local = try #require(try await store.localEpisodeForTesting(wire: two))
            _ = try await store.beginPlayback(episodeID: local)
            results["an adoption check", default: []].append(try await Self.measure(store) { _ = try await store.serverAdoptionCheck(episodeID: local) })
            await fixture.close()
        }
        for (label, works) in results.sorted(by: { $0.key < $1.key }) { Self.expectFlat(label, works[0], works[1]) }
    }

    /// The local writes the screens follow, on a small and a large standalone library: each costs the same.
    @Test func routineLocalWritesAreFlatInTheLibrarySize() async throws {
        let sizes = Self.scale ? [60, 120] : [6, 24]
        var results: [String: [Work]] = [:]
        for podcasts in sizes {
            let fixture = try await ServerLibraryFixture(server: false)
            let store = fixture.store
            var first: LibraryFeed?
            for number in 0..<podcasts {
                let feed = try await store.insert(ServerLibraryFixture.fetched("https://example.test/local-\(number).xml", title: "Local \(number)", count: 450,
                                                                               guidPrefix: "local-\(number)-"))
                if first == nil { first = feed }
            }
            let ids = try #require(first).episodes.map(\.id).sorted()
            _ = try await store.enqueue(Array(ids[0..<10]))
            func write(_ label: String, _ body: () async throws -> Void) async throws {
                results[label, default: []].append(try await Self.measure(store, body))
            }
            try await write("a played mark") { try await store.markEpisodePlayed(episodeID: ids[20], played: true) }
            try await write("a favorite") { try await store.setFavorite(episodeID: ids[21], favorite: true) }
            try await write("a queue move") {
                _ = try await store.performQueueMove(.item(ids[0], finalIndex: 5), expected: try await store.queue().map(QueueEpisodeIdentity.init))
            }
            try await write("a swipe") { _ = try await store.applySwipeMark(episodeID: ids[22], action: .togglePlayed) }
            try await write("a download request") { _ = try await store.requestDownload(episodeID: ids[23], directory: fixture.directory, enqueue: false) }
            let session = try await store.beginPlayback(episodeID: ids[24])
            try await write("a playback save") {
                _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 5_000, durationMilliseconds: 600_000, status: .playing))
            }
            await fixture.close()
        }
        for (label, works) in results.sorted(by: { $0.key < $1.key }) { Self.expectFlat(label, works[0], works[1]) }
    }

    /// Proportional changes cost what they change: a podcast's hide costs the capture its own keys and the queue, never its
    /// episodes; a podcast's deletion and a statistics replacement cost their rows (the digest once per key, not per row).
    /// The derived keys (schema 21) recompute the hidden podcast's eligibility row by row, feed-proportional by construction
    /// (`LibrarySchema21`): that maintenance is measured alone, the same hide on a connection without the capture, and the
    /// capture's own work (the difference) stays flat.
    @Test func proportionalChangesCostTheirRows() async throws {
        var hides: [Work] = [], maintenance: [Work] = [], deletions: [Work] = [], units: [Work] = []
        for size in [100, 1_000, 3_000] {
            let fixture = try await ServerLibraryFixture(server: false)
            let store = fixture.store
            let feed = try await store.insert(ServerLibraryFixture.fetched("https://example.test/size.xml", title: "Size", count: size))
            let id = try #require(feed.episodes.first).id
            try await store.databaseForTesting { db in
                try db.transaction { try db.replaceStatisticsUnits(episode: id, with: (0..<size).map { LibraryStatisticsUnit(episodeID: id, unitID: "u\($0)", playedMilliseconds: 1) }) }
            }
            units.append(try await Self.measure(store) {
                try await store.databaseForTesting { db in try db.transaction { try db.execute("DELETE FROM statistics_units WHERE episode_id = ?", [.integer(id)]) } }
            })
            hides.append(try await Self.measure(store) {
                try await store.databaseForTesting { db in try db.transaction { try db.execute("INSERT INTO pinned_feed_removals(feed_id) VALUES (?)", [.integer(feed.id)]) } }
            })
            try await store.databaseForTesting { db in try db.transaction { try db.execute("DELETE FROM pinned_feed_removals WHERE feed_id = ?", [.integer(feed.id)]) } }
            let plain = try LibrarySQLite(url: fixture.url)
            maintenance.append(try await Self.measure(store) {
                try plain.transaction { try plain.execute("INSERT INTO pinned_feed_removals(feed_id) VALUES (?)", [.integer(feed.id)]) }
            })
            try plain.close()
            deletions.append(try await Self.measure(store) {
                try await store.databaseForTesting { db in try db.transaction { try db.execute("DELETE FROM feeds WHERE id = ?", [.integer(feed.id)]) } }
            })
            await fixture.close()
        }
        print("BUDGET a podcast's hide, the derived keys' maintenance alone: \(zip([100, 1_000, 3_000], maintenance).map { "\($0): \($1)" }.joined(separator: " | "))")
        #expect(maintenance[2].rowsWritten - maintenance[0].rowsWritten == 2_900, "the derived maintenance writes the podcast's key rows: \(maintenance)")
        Self.expectFlat("a podcast's hide (100 → 3,000 episodes), the capture's own work", hides[0] - maintenance[0], hides[2] - maintenance[2], constant: 200)
        for (label, works) in [("a podcast's deletion", deletions), ("1 episode's statistics units deleted", units)] {
            print("BUDGET \(label): \(zip([100, 1_000, 3_000], works).map { "\($0): \($1)" }.joined(separator: " | "))")
            // Linear: 30× the rows at most ~32× the capture work.
            #expect(works[2].digests <= works[0].digests * 32 + 8 && works[2].captureRows <= works[0].captureRows * 32 + 8, "\(label): \(works)")
        }
        #expect(units[1].digests - units[0].digests == 900 && units[2].digests - units[0].digests == 2_900, "the units hashed once each: \(units.map(\.digests))")
    }

    /// The queue's work is linear in the queue (settled: queue capture and projection stay whole-queue): a move's VM steps
    /// and pages per member stay the same from 1,000 to 5,000 members. An order-preserving quadratic capture (a rank
    /// count per member, a mutation) fails.
    @Test(arguments: [false, true]) func queueWorkIsLinearInTheQueue(mutated: Bool) async throws {
        var moves: [Work] = []
        let lengths = [10, 1_000, 5_000]
        for length in lengths {
            let fixture = try await ServerLibraryFixture(server: false)
            let store = fixture.store
            if mutated { try await store.setChangeCaptureFaultsForTesting([.quadraticQueueOrder]) }
            let feed = try await store.insert(ServerLibraryFixture.fetched("https://example.test/queue.xml", title: "Queue", count: 5_050))
            let ids = feed.episodes.map(\.id).sorted()
            _ = try await store.enqueue(Array(ids[0..<length]))
            moves.append(try await Self.measure(store) {
                _ = try await store.performQueueMove(.item(ids[0], finalIndex: 1), expected: try await store.queue().map(QueueEpisodeIdentity.init))
            })
            await fixture.close()
        }
        print("BUDGET a queue move (queue 10 → 1,000 → 5,000)\(mutated ? " (quadratic order)" : ""): \(moves.map(\.description).joined(separator: " | "))")
        func perMember(_ a: Int, _ b: Int, _ value: (Work) -> Int64) -> Double {
            Double(value(moves[b]) - value(moves[a])) / Double(lengths[b] - lengths[a])
        }
        let steps = (perMember(0, 1, \.steps), perMember(1, 2, \.steps)), pages = (perMember(0, 1, \.pages), perMember(1, 2, \.pages))
        let linear = steps.1 <= steps.0 * 1.5 + 2 && pages.1 <= pages.0 * 1.5 + 1 && moves[2].drainRows <= moves[0].drainRows * 501 + 50
        print("BUDGET queue per member: steps \(steps), pages \(pages)")
        if mutated { #expect(!linear, "the quadratic capture is caught: \(steps)") } else { #expect(linear, "\(steps) \(pages)") }
    }

    /// Hidden whole-library work inside a unit is metered on any connection: a scan on a second connection, and every
    /// podcast decoded in memory (mutations), each break the flat budget of a one-record unit; without them it is flat.
    @Test(arguments: [nil, FeedLibraryStore.AdoptionFault.unitScansOnSecondConnection, .unitLoadsFeeds])
    func hiddenLibraryWorkInAUnitIsCaught(fault: FeedLibraryStore.AdoptionFault?) async throws {
        var works: [Work] = []
        for (podcasts, episodes) in [(2, 450), (12, 450)] {
            let (fixture, applier) = try await Self.library(podcasts: podcasts, episodes: episodes)
            if let fault { await fixture.store.setAdoptionFaultsForTesting([fault]) }
            works.append(try await Self.measure(fixture.store) {
                try await applier.apply([ServerRecord(entity: "episode", id: Self.wire(0, 5), fieldGroup: "favorite",
                                                      value: ["generation_id": .string(Self.generation), "on": true])])
            })
            await fixture.close()
        }
        let flat = Self.isFlat(works[0], works[1])
        print("BUDGET a favorite unit\(fault.map { " (\($0))" } ?? ""): \(works[0]) | \(works[1])")
        if fault == nil { #expect(flat, "\(works)") } else { #expect(!flat, "\(String(describing: fault)) is caught: \(works)") }
    }

    /// Routine work does not grow with one episode's accumulated statistics units (imports and merges add many): a
    /// favorite, a playback save, another device's checkpoint and a metadata change cost the same with 0, 1,000 and
    /// 10,000 units. An episode image that hashes its units (a mutation) breaks it.
    @Test(arguments: [false, true]) func routineWorkIsFlatInAnEpisodesStatisticsUnits(mutated: Bool) async throws {
        var results: [String: [Work]] = [:]
        for units in [0, 1_000, 10_000] {
            let (fixture, applier) = try await Self.library(podcasts: 1, episodes: 50)
            let store = fixture.store
            if mutated { try await store.setChangeCaptureFaultsForTesting([.unitsInEpisodeDigest]) }
            let local = try #require(try await store.localEpisodeForTesting(wire: Self.wire(0, 5)))
            try await store.databaseForTesting { db in
                try db.transaction { try db.replaceStatisticsUnits(episode: local, with: (0..<units).map { LibraryStatisticsUnit(episodeID: local, unitID: "u\($0)", playedMilliseconds: 1) }) }
            }
            func measure(_ label: String, _ body: () async throws -> Void) async throws {
                results[label, default: []].append(try await Self.measure(store, body))
            }
            try await measure("a favorite") { try await store.setFavorite(episodeID: local, favorite: true) }
            let session = try await store.beginPlayback(episodeID: local)
            _ = try await store.recordPlaybackIntent(sessionID: session.id, positionMilliseconds: 0, durationMilliseconds: 600_000, baseline: UUID(),
                                                     intentional: true, now: Date(timeIntervalSince1970: 1_760_000_000))
            try await measure("a playback save") {
                _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 5_000, durationMilliseconds: 600_000, status: .playing),
                                                   now: Date(timeIntervalSince1970: 1_760_000_005))
            }
            try await measure("another device's checkpoint") {
                try await applier.apply([
                    ServerRecord(entity: "episode", id: Self.wire(0, 6), fieldGroup: "position", value: ["generation_id": .string(Self.generation), "position": 90_000,
                                                                                                    "claim_id": .string(ContractIdentity.randomUUID())]),
                    ServerRecord(entity: "episode", id: Self.wire(0, 5), fieldGroup: "last_played", value: ["generation_id": .string(Self.generation), "time": 1_760_000_100_000])])
            }
            let metadata = try #require(try Self.podcastRecords(0, episodes: 5).last { $0.fieldGroup == "metadata" })
            var changed = metadata
            if case .object(var object)? = metadata.value { object["title"] = "Renamed"; changed.value = .object(object) }
            try await measure("a metadata change") { try await applier.apply([changed]) }
            await fixture.close()
        }
        var flat = true
        for (label, works) in results.sorted(by: { $0.key < $1.key }) {
            print("BUDGET \(label) with 0 → 1,000 → 10,000 statistics units\(mutated ? " (units in the episode image)" : ""): \(works.map(\.description).joined(separator: " | "))")
            let ok = Self.isFlat(works[0], works[2])
            flat = flat && ok
            if !mutated { #expect(ok, "\(label): \(works)") }
        }
        if mutated { #expect(!flat, "the units' hashing is caught") }
    }

    /// An adoption check decodes the same sessions whatever the selected episode's acknowledged listening history (1,
    /// 10, 100 earlier sessions): acknowledged sessions are pruned. Keeping them all (a mutation) grows it.
    @Test(arguments: [false, true]) func anAdoptionCheckIsFlatInTheSessionHistory(mutated: Bool) async throws {
        var works: [Work] = []
        for history in [1, 10, 100] {
            let (fixture, store, one, _) = try await ServerAdoptionBaselineTests.library()
            if mutated { await store.setAdoptionFaultsForTesting([.keepAcknowledgedSessions]) }
            let player = StorePlayer(store)
            for _ in 0..<history {
                try await player.load(one)
                try await player.play(); try await player.listen(5)
                _ = try await player.end(.switched)
                _ = try await store.retireOutboxForTesting()
            }
            try await player.load(one)
            works.append(try await Self.measure(store) { _ = try await store.serverAdoptionCheck(episodeID: one) })
            await fixture.close()
        }
        print("BUDGET an adoption check with 1 → 10 → 100 acknowledged sessions\(mutated ? " (never pruned)" : ""): \(works.map(\.description).joined(separator: " | "))")
        let flat = works[2].sessions <= works[0].sessions + 2 && Self.isFlat(works[0], works[2])
        if mutated { #expect(!flat, "the unpruned history is caught") } else { #expect(flat, "\(works)") }
    }

    /// The query-plan guard: every capture statement (each trigger body's statements with their row values bound, and
    /// each drain statement) searches library tables by key; only the queue (proportional to itself) may be scanned.
    @Test(arguments: [false, true]) func everyCaptureStatementSearchesByKey(mutated: Bool) async throws {
        let fixture = try await ServerLibraryFixture()
        try await fixture.store.ensureServerExchangeTablesForTesting()
        if mutated { try await fixture.store.setChangeCaptureFaultsForTesting([.unkeyedDownloadDigest]) }
        let violations = try await fixture.store.captureQueryPlanViolationsForTesting()
        if mutated {
            #expect(violations.contains { $0.contains("download_jobs") }, "the aliased scan is caught: \(violations)")
        } else {
            #expect(violations.isEmpty, "\(violations.prefix(5).joined(separator: "\n"))")
        }
        await fixture.close()
    }

    // MARK: - More dimensions and operations

    /// The pending-outbox dimension (0, 100, 1,000 unsent facts): a favorite, a played mark, a remote unit and an
    /// adoption check cost the same.
    @Test func routineWorkIsFlatInThePendingOutbox() async throws {
        var results: [String: [Work]] = [:]
        for pending in [0, 100, 1_000] {
            let (fixture, applier) = try await Self.library(podcasts: 3, episodes: 450)
            let store = fixture.store
            var locals: [Int64] = []
            for podcast in 0..<3 { for episode in 1...450 { if let id = try await store.localEpisodeForTesting(wire: Self.wire(podcast, episode)) { locals.append(id) } } }
            for id in locals.prefix(pending) { try await store.setFavorite(episodeID: id, favorite: true) }
            let outbox = try await store.databaseForTesting { try $0.scalar("SELECT count(*) FROM ntp_outbox") }
            #expect(outbox >= Int64(pending), "\(outbox) pending facts")
            let target = locals[locals.count - 1], other = locals[locals.count - 2]
            func measure(_ label: String, _ body: () async throws -> Void) async throws { results[label, default: []].append(try await Self.measure(store, body)) }
            try await measure("a favorite") { try await store.setFavorite(episodeID: target, favorite: true) }
            try await measure("a played mark") { try await store.markEpisodePlayed(episodeID: other, played: true) }
            try await measure("a remote unit") {
                try await applier.apply([ServerRecord(entity: "episode", id: Self.wire(2, 300), fieldGroup: "play_state",
                                                      value: ["generation_id": .string(Self.generation), "play_state": "played"])])
            }
            _ = try await store.beginPlayback(episodeID: target)
            try await measure("an adoption check") { _ = try await store.serverAdoptionCheck(episodeID: target) }
            await fixture.close()
        }
        for (label, works) in results.sorted(by: { $0.key < $1.key }) { Self.expectFlat("\(label) with 0 → 100 → 1,000 pending facts", works[0], works[2]) }
    }

    /// The archive dimension (none, and 20,000 archived history entries and facts of other episodes): another device's
    /// history for an episode with a pending local cut reads the archive for that episode only.
    @Test func historyWorkIsFlatInTheArchive() async throws {
        var works: [Work] = []
        for archived in [0, 20_000] {
            let (fixture, _, one, _) = try await ServerLocalPlaybackTests.library()
            let store = fixture.store
            let url = fixture.directory.appendingPathComponent("sync.sqlite")
            let archive = try ServerArchive(url: url)
            try archive.close()
            if archived > 0 {
                let sync = try SyncSQLite(url: url)
                try sync.execute("BEGIN")
                for index in 0..<archived {
                    let node = "n\(index)", episode = "e1:other-\(index % 500)"
                    try sync.execute("INSERT INTO archive_history(episode_id, node_id, kind, time) VALUES (?, ?, 'activity', ?)", [.text(episode), .text(node), .integer(Int64(index))])
                    try sync.execute("INSERT INTO archive_entries(op_id, content_hash, epoch, seq, idx, outcome, type, normalized_time, fact, receipt) VALUES (?, '', 1, ?, 0, 'applied', 'session.checkpoint', ?, x'00', x'00')",
                                     [.text(node), .integer(Int64(index + 1)), .integer(Int64(index))])
                }
                try sync.execute("COMMIT")
                try sync.close()
            }
            let reader = try ServerArchiveReader(url: url)
            _ = try await store.removeFromPlaybackHistoryWithUndo(one)
            works.append(try await Self.measure(store) {
                _ = try await store.applyRecordsForTesting([ServerRecord(entity: "episode", id: ServerLocalPlaybackTests.one, fieldGroup: "history",
                    value: ["generation_id": .string(ServerLocalPlaybackTests.generation), "time": 3_000_000])], history: reader)
            })
            await fixture.close()
        }
        Self.expectFlat("a history unit with a pending cut, archive empty → 20,000 entries", works[0], works[1])
    }

    /// Pin release, a one-entry history removal and a knowledge event cost the same in a library twelve times larger. The
    /// release does its work: the old episode is no longer selected and both deferred fields reach its row.
    @Test func pinReleaseHistoryRemovalAndKnowledgeAreFlat() async throws {
        var results: [String: [Work]] = [:]
        for (podcasts, episodes) in [(2, 450), (12, 450)] {
            let (fixture, applier) = try await Self.library(podcasts: podcasts, episodes: episodes)
            let store = fixture.store
            let two = try #require(try await store.localEpisodeForTesting(wire: Self.wire(0, 6)))
            func measure(_ label: String, _ body: () async throws -> Void) async throws { results[label, default: []].append(try await Self.measure(store, body)) }
            let pin = try await Self.pinRelease(store, applier, leave: true)
            #expect(pin.released, "\(podcasts) × \(episodes): the release applied the deferred position and duration")
            #expect(pin.release.rowsWritten > 0 && pin.release.keys > 0, "\(podcasts) × \(episodes): the release wrote its row: \(pin.release)")
            results["a knowledge event for the player's episode", default: []].append(pin.knowledge)
            results["a pin release", default: []].append(pin.release)
            try await applier.apply([ServerRecord(entity: "episode", id: Self.wire(0, 6), fieldGroup: "history",
                                                  value: ["generation_id": .string(Self.generation), "time": 1_760_000_000_000])])
            try await measure("a one-entry history removal") { _ = try await store.removeFromPlaybackHistoryWithUndo(two) }
            await fixture.close()
        }
        for (label, works) in results.sorted(by: { $0.key < $1.key }) { Self.expectFlat(label, works[0], works[1]) }
        // The control: the earlier measurement ended the episode with the queue's next one still to load, so it stayed
        // selected and the release did nothing. The check above rejects it.
        let (fixture, applier) = try await Self.library(podcasts: 2, episodes: 450)
        let control = try await Self.pinRelease(fixture.store, applier, leave: false)
        print("BUDGET a pin release while the episode stays selected (control): \(control.release)")
        #expect(!control.released && control.release.rowsWritten == 0, "a release with the episode still selected is a no-op: \(control.release)")
        await fixture.close()
    }

    /// The player's episode (the first podcast's fifth) holds another device's position and measured duration (a pin, told
    /// as knowledge); then the player leaves it for another episode (`leave`), or ends it with the queue's next episode
    /// still to load, so that it stays selected. The knowledge event's work, the release's, and whether the release applied
    /// both deferred fields to the row.
    static func pinRelease(_ store: FeedLibraryStore, _ applier: ServerProjectionUnitTests.Applier, leave: Bool) async throws
        -> (knowledge: Work, release: Work, released: Bool) {
        let wire = Self.wire(0, 5)
        let one = try #require(try await store.localEpisodeForTesting(wire: wire))
        let next = try #require(try await store.localEpisodeForTesting(wire: Self.wire(0, 7)))
        func pins() async throws -> Int64 {
            try await store.databaseForTesting { try $0.scalar("SELECT count(*) FROM ntp_deferred_pins WHERE episode_id = ?", [.text(wire)]) }
        }
        let session = try await store.beginPlayback(episodeID: one)
        let knowledge = try await Self.measure(store) {
            try await applier.apply([
                ServerRecord(entity: "episode", id: wire, fieldGroup: "position",
                             value: ["generation_id": .string(Self.generation), "position": 77_000, "claim_id": .string(ContractIdentity.randomUUID())]),
                ServerRecord(entity: "episode", id: wire, fieldGroup: "measured_duration",
                             value: ["generation_id": .string(Self.generation), "duration_ms": 612_000, "installation_id": .string(ContractIdentity.randomUUID())])])
        }
        let held = try #require(try await store.episode(id: one))
        #expect(held.userState.positionMilliseconds == 0 && held.details.media?.durationMilliseconds == 600_000, "the player keeps its own while it holds the episode")
        #expect(try await pins() == 1, "both wait for the player")
        if leave {
            _ = try await store.endPlayback(sessionID: session.id, reason: .switched)
            _ = try await store.beginPlayback(episodeID: next)
            #expect(try await store.playbackSelectionEpisodeID() == next, "the player left the episode")
        } else {
            _ = try await store.endPlayback(sessionID: session.id, reason: .skipped)
            #expect(try await store.playbackSelectionEpisodeID() == one, "the next episode is still to load: this one stays selected")
        }
        let release = try await Self.measure(store) { _ = try await store.releaseServerPins() }
        let row = try #require(try await store.episode(id: one))
        let released = try await pins() == 0 && row.userState.positionMilliseconds == 77_000 && row.details.media?.durationMilliseconds == 612_000
        return (knowledge, release, released)
    }

    struct State: Equatable { var played = 0, favorites = 0, queued = 0 }

    /// The first podcast's episodes as the library shows them now: how many are played, favorites and queued.
    static func firstPodcastState(_ store: FeedLibraryStore, episodes: Int) async throws -> State {
        let queue = Set(try await store.queue().map(\.id))
        var state = State()
        for number in 1...episodes {
            let local = try #require(try await store.localEpisodeForTesting(wire: Self.wire(0, number)))
            let episode = try #require(try await store.episode(id: local))
            state.played += episode.userState.playState == .played ? 1 : 0
            state.favorites += episode.userState.isFavorite ? 1 : 0
            state.queued += queue.contains(local) ? 1 : 0
        }
        return state
    }

    /// Proportional: a podcast's generation change, every episode holding state, costs at most what its episodes are,
    /// linearly (50 → 500 episodes: at most about ten times the work). The unit is what the server publishes for a
    /// removal and a new subscription (PROTOCOL §4: closing a generation tombstones every episode record of it; the new
    /// one starts without state): every played mark and favorite goes, which is checked. The subscription record alone
    /// (the earlier measurement, a control) changes no episode, and the check rejects it.
    @Test func aGenerationChangeIsProportional() async throws {
        var works: [Work] = []
        let next = "g1:" + String(repeating: "6", count: 64)
        let subscription = ServerRecord(entity: "podcast", id: Self.podcast(0), fieldGroup: "subscription",
                                        value: ["state": "subscribed", "generation_id": .string(next)])
        for (episodes, control) in [(50, true), (50, false), (500, false)] {
            let (fixture, applier) = try await Self.library(podcasts: 2, episodes: episodes)
            let store = fixture.store
            // Every episode of the podcast holds state under the current generation, which the new one starts without.
            try await applier.apply((1...episodes).flatMap { number in
                [ServerRecord(entity: "episode", id: Self.wire(0, number), fieldGroup: "play_state", value: ["generation_id": .string(Self.generation), "play_state": "played"]),
                 ServerRecord(entity: "episode", id: Self.wire(0, number), fieldGroup: "favorite", value: ["generation_id": .string(Self.generation), "on": true])]
            })
            let before = try await Self.firstPodcastState(store, episodes: episodes)
            #expect(before == State(played: episodes, favorites: episodes, queued: 10), "\(episodes): every episode holds state first: \(before)")
            var records = [subscription]
            if !control {
                for number in 1...episodes {
                    for group in ["play_state", "favorite"] + (number <= 10 ? ["queue_membership", "queue_position"] : []) {
                        records.append(ServerRecord(entity: "episode", id: Self.wire(0, number), fieldGroup: group, value: nil))
                    }
                }
            }
            let work = try await Self.measure(store) { try await applier.apply(records) }
            let after = try await Self.firstPodcastState(store, episodes: episodes)
            let applied = after.played == 0 && after.favorites == 0
            if control {
                print("BUDGET a generation change, the subscription record alone (control): \(work)")
                #expect(!applied, "the subscription alone changes no episode, and the check rejects it: \(after)")
            } else {
                #expect(applied, "\(episodes): every episode's state of the closed generation is gone: \(after)")
                // Its queue entries go with it, incrementally as a full projection drops them (their membership records
                // tombstoned), and a full reprojection of the same records agrees.
                #expect(after.queued == 0, "\(episodes): the closed generation's episodes left the queue: \(after)")
                let rebuilt = try await ServerChangeSetCaptureTests.rebuildDifferences(store, ownedRoot: fixture.directory, archive: nil)
                #expect(rebuilt.isEmpty, "\(episodes): incremental equals a full reprojection: \(rebuilt.prefix(2))")
                #expect(work.rowsWritten >= Int64(episodes) && work.keys >= Int64(episodes), "\(episodes): each episode's row was written: \(work)")
                works.append(work)
            }
            await fixture.close()
        }
        print("BUDGET a generation change (50 → 500 episodes): \(works[0]) | \(works[1])")
        #expect(works[1].steps <= works[0].steps * 12 + 2_000 && works[1].pages <= works[0].pages * 12 + 200
                    && works[1].rowsWritten <= works[0].rowsWritten * 12 + 50 && works[1].keys <= works[0].keys * 12 + 4, "proportional: \(works)")
    }

    /// Proportional: a podcast merged into another (PROTOCOL §7.7, §9.7: its episodes become the survivor's) costs at
    /// most what it moves, linearly (50 → 500 episodes merged: at most about ten times the work). The complete merge is
    /// metered: the unit the server publishes (the subscription merged, each episode's identity merged into the
    /// survivor's, its state refolded there), the removal transactions after it and the deferred file cleanup. The unit
    /// itself merges every episode and deletes or moves every row of the merged podcast (at 500 episodes about 13,000 rows
    /// and 1.9 million VM steps): it is not bounded, it grows with the podcast; the removal transactions after it only
    /// take out the emptied feed. It is checked done: the merged podcast and its rows are gone, the survivor shows the
    /// merged state and keeps its queue. The unit alone (the earlier measurement, a control) leaves the merged feed of a
    /// large merge in place, and the check rejects it.
    @Test func aPodcastMergeIsProportional() async throws {
        var works: [Work] = []
        for episodes in [50, 500] {
            let (fixture, applier) = try await Self.library(podcasts: 2, episodes: episodes)
            let store = fixture.store
            // The merged podcast's episodes were played; the server refolds that onto the survivor's.
            try await applier.apply((1...episodes).map { ServerMergeTests.playState(Self.wire(1, $0), Self.generation, "played") })
            func feed(_ wire: String) async throws -> Int64 {
                let local = try #require(try await store.localEpisodeForTesting(wire: wire))
                return try await store.databaseForTesting { try $0.scalar("SELECT feed_id FROM episodes WHERE id = ?", [.integer(local)]) }
            }
            let source = try await feed(Self.wire(1, 1)), survivor = try await feed(Self.wire(0, 1))
            let queue = try await store.queue().map(\.id)
            #expect(queue.count == 10)
            var records = [ServerRecord(entity: "podcast", id: Self.podcast(1), fieldGroup: "subscription",
                                        value: ["state": "merged", "merged_into": .string(Self.podcast(0)), "generation_id": .string(Self.generation)])]
            for number in 1...episodes {
                records.append(ServerMergeTests.identity(Self.wire(1, number), podcast: Self.podcast(1), guid: "budget-1-\(number)", mergedInto: Self.wire(0, number)))
                records.append(ServerRecord(entity: "episode", id: Self.wire(1, number), fieldGroup: "play_state", value: nil))
                records.append(ServerMergeTests.playState(Self.wire(0, number), Self.generation, "played"))
            }
            func done() async throws -> Bool {
                let sourceRows = try await store.databaseForTesting { try $0.scalar("SELECT count(*) FROM episodes WHERE feed_id = ?", [.integer(source)]) }
                let state = try await Self.firstPodcastState(store, episodes: episodes)
                let sourceFeed = try await store.feed(id: source), hidden = try await store.hasHiddenRemovals()
                let survivorEpisodes = try await store.feed(id: survivor)?.episodes.count, queued = try await store.queue().map(\.id)
                return sourceFeed == nil && sourceRows == 0 && !hidden && state.played == episodes && survivorEpisodes == episodes && queued == queue
            }
            var work = try await Self.measure(store) { try await applier.apply(records) }
            let unitAlone = try await done()
            print("BUDGET a podcast merge of \(episodes) episodes, its unit alone: \(work)")
            if episodes == 500 { #expect(!unitAlone, "a large merge is not done in its unit: the check rejects the unit alone") }
            var batches = 0
            work = work + (try await Self.measure(store) {
                while try await store.deleteHiddenRemovalBatch().progressed { batches += 1 }
                try await ServerMergeTests.cleanUp(store)
            })
            #expect(try await done(), "\(episodes): the merge is complete after \(batches) removal transactions")
            #expect(work.rowsWritten >= Int64(episodes) && work.keys >= Int64(episodes), "\(episodes): every merged row went: \(work)")
            works.append(work)
            await fixture.close()
        }
        print("BUDGET a complete podcast merge (50 → 500 episodes): \(works[0]) | \(works[1])")
        #expect(works[1].steps <= works[0].steps * 12 + 2_000 && works[1].pages <= works[0].pages * 12 + 200
                    && works[1].rowsWritten <= works[0].rowsWritten * 12 + 50 && works[1].keys <= works[0].keys * 12 + 4, "proportional: \(works)")
    }

    /// Hiding one podcast costs its own keys, never the other podcasts': flat from 5 to 50 other podcasts. A capture
    /// that expands a hide over every podcast (a mutation) grows with them.
    @Test(arguments: [false, true]) func aHideIsFlatInTheOtherPodcasts(mutated: Bool) async throws {
        var works: [Work] = []
        for others in [5, 50] {
            let fixture = try await ServerLibraryFixture(server: false)
            let store = fixture.store
            if mutated { try await store.setChangeCaptureFaultsForTesting([.hideScansAllFeeds]) }
            let target = try await store.insert(ServerLibraryFixture.fetched("https://example.test/target.xml", title: "Target", count: 20))
            for number in 0..<others {
                _ = try await store.insert(ServerLibraryFixture.fetched("https://example.test/other-\(number).xml", title: "Other \(number)", count: 20,
                                                                        guidPrefix: "other-\(number)-"))
            }
            works.append(try await Self.measure(store) {
                try await store.databaseForTesting { db in try db.transaction { try db.execute("INSERT INTO pinned_feed_removals(feed_id) VALUES (?)", [.integer(target.id)]) } }
            })
            await fixture.close()
        }
        let flat = Self.isFlat(works[0], works[1], constant: 200) && works[1].captureRows <= works[0].captureRows + 4
        print("BUDGET a podcast's hide with 5 → 50 other podcasts\(mutated ? " (expanded over every podcast)" : ""): \(works[0]) | \(works[1])")
        if mutated { #expect(!flat, "the expansion is caught: \(works)") } else { #expect(flat, "\(works)") }
    }

    /// Each routine operation's whole-table reads, with the bound that justifies each (anything else, or a statement that
    /// cannot be explained on its own connection, fails).
    static let routineAllowances: [String: [String: String]] = {
        let queue = "the queue's own length (settled: whole-queue capture and projection; a played mark takes the episode out of it)"
        let sessions = "this phone's sessions not yet acknowledged (acknowledged ones are pruned at each load)"
        // Every server-library write's recording seam (PROTOCOL §15.2) compares the queue before and after its action, and
        // the episode rows' upsert carries the capture's queue trigger for a move of a queued episode between podcasts.
        let seam = "the queue's own length (settled: the recording seam's before and after order, and the whole-queue capture)"
        let hidden: [String: String] = [
            "ntp_hidden_feeds": "podcasts this phone is staging or removing",
            "ntp_hidden_episodes": "episodes staged and not yet revealed",
            "pinned_feed_removals": "podcasts removed elsewhere while their episode is selected",
            "ntp_podcasts": "one row per podcast (the server's pinned-removal filter), flat in episodes",
        ]
        return [
            "a played mark": ["queue": queue, "ntp_sessions": sessions].merging(hidden) { a, _ in a },
            "a favorite": ["queue": seam].merging(hidden) { a, _ in a },
            "a queue move": ["queue": queue].merging(hidden) { a, _ in a },
            "a download request": ["download_jobs": "the person's active downloads", "queue": seam].merging(hidden) { a, _ in a },
            "a playback load": ["ntp_sessions": sessions, "ntp_recovery_holds": "an existence probe, stopped at its first row", "queue": seam],
            "a playback save": ["ntp_sessions": sessions, "ntp_local_playback": "this phone's unexported playback marks",
                                "ntp_recovery_holds": "an existence probe, stopped at its first row", "queue": seam].merging(hidden) { a, _ in a },
            "an adoption check": ["ntp_recovery_holds": "an existence probe, stopped at its first row"],
            "a remote unit": ["queue": queue, "ntp_sessions": sessions, "ntp_local_playback": "this phone's unexported playback marks",
                              "ntp_recovery_holds": "an existence probe, stopped at its first row",
                              "ntp_outbox": "this phone's unacknowledged facts (acknowledged ones are pruned)"].merging(hidden) { a, _ in a },
        ]
    }()

    /// Every statement the routine operations run, on every connection, explained there from its bytecode: no
    /// library-scale table read whole beyond the operation's own allowances.
    @Test func everyRoutineStatementSearchesByKey() async throws {
        let (fixture, applier) = try await Self.library(podcasts: 2, episodes: 200)
        let store = fixture.store
        let one = try #require(try await store.localEpisodeForTesting(wire: Self.wire(0, 5)))
        let two = try #require(try await store.localEpisodeForTesting(wire: Self.wire(0, 6)))
        SQLWorkMeter.shared.setEnabled(true)
        SQLWorkMeter.shared.startRecordingStatements()
        let meter = SQLWorkMeter.shared
        meter.setOperation("a played mark"); try await store.markEpisodePlayed(episodeID: one, played: true)
        meter.setOperation("a favorite"); try await store.setFavorite(episodeID: two, favorite: true)
        let queue = try await store.queue()
        meter.setOperation("a queue move")
        _ = try await store.performQueueMove(.item(try #require(queue.first).id, finalIndex: 1), expected: queue.map(QueueEpisodeIdentity.init))
        meter.setOperation("a download request"); _ = try await store.requestDownload(episodeID: two, directory: fixture.directory, enqueue: false)
        meter.setOperation("a playback load"); let session = try await store.beginPlayback(episodeID: one)
        meter.setOperation("a playback save")
        _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 5_000, durationMilliseconds: 600_000, status: .paused))
        meter.setOperation("an adoption check"); _ = try await store.serverAdoptionCheck(episodeID: one)
        meter.setOperation("a remote unit")
        try await applier.apply([ServerRecord(entity: "episode", id: Self.wire(1, 7), fieldGroup: "play_state",
                                              value: ["generation_id": .string(Self.generation), "play_state": "played"])])
        let plans = meter.takePlans()
        meter.setEnabled(false)
        let violations = Self.violations(plans)
        print("BUDGET routine statements explained: \(plans.count) on \(Set(plans.map(\.connection)).sorted())")
        #expect(violations.isEmpty, "\(violations.prefix(8).joined(separator: "\n"))")
        await fixture.close()
    }

    /// The plans' failures: a statement not explained on its connection, or a library-scale table read whole that its
    /// operation's allowances do not justify. Schema and table are classified apart: a library table is library-scale in
    /// whichever schema it is (an attached `shadow.episodes` as the library's own); an allowance names a table of the
    /// connection's own database (`main`), or of its `temp` schema as `temp.<table>`.
    static func violations(_ plans: [SQLWorkMeter.Plan], allowances: [String: [String: String]] = routineAllowances) -> [String] {
        var found: [String] = []
        for plan in plans {
            if let failure = plan.failure { found.append("[\(plan.operation)] not explained on \(plan.connection) (\(plan.schema)): \(failure): \(plan.sql.prefix(160))"); continue }
            for scan in plan.scans where FeedLibraryStore.libraryTables.contains(scan.table) && allowances[plan.operation]?[scan.description] == nil {
                found.append("[\(plan.operation)] reads \(scan) whole on \(plan.connection) (\(plan.schema)): \(plan.sql.prefix(200))")
            }
        }
        return found
    }

    /// Scopes cannot hide a scan: an outer `episodes AS ev` read whole while an inner query names its own `ev` is
    /// reported from the bytecode, as the plain statement is.
    @Test func aNestedAliasCannotHideAScan() async throws {
        let fixture = try await ServerLibraryFixture()
        try await fixture.store.ensureServerExchangeTablesForTesting()
        let plain = try await fixture.store.scansForTesting("SELECT sum(ev.pubdate) FROM episodes AS ev")
        let nested = try await fixture.store.scansForTesting("SELECT sum(ev.pubdate) FROM episodes AS ev WHERE EXISTS (SELECT 1 FROM temp.ntp_vis_before AS ev)")
        let episodes = SQLWorkMeter.Scan(schema: "main", table: "episodes")
        #expect(plain.contains(episodes) && nested.contains(episodes), "plain \(plain), nested \(nested)")
        await fixture.close()
    }

    /// Plans stay scoped by connection, schema and operation. Each of these is a violation: the same statement under an
    /// allowed operation and then a disallowed one; the same keyed statement on two connections whose files share a name,
    /// one of them without the index; the same statement on one connection after its schema lost that index; a scan of an
    /// attached schema's library table (`shadow.episodes`).
    @Test func plansRemainOperationAndSchemaScoped() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("plan-scopes-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        let a = try LibrarySQLite(url: root.appendingPathComponent("a/library.sqlite"))
        let b = try LibrarySQLite(url: root.appendingPathComponent("b/library.sqlite"))
        defer { try? a.close(); try? b.close() }
        try b.execute("DROP INDEX episodes_by_feed")
        let meter = SQLWorkMeter.shared
        meter.setEnabled(true)
        defer { meter.setEnabled(false) }
        meter.startRecordingStatements()
        let keyed = "SELECT count(*) FROM episodes WHERE feed_id = ?", queue = "SELECT count(*) FROM queue"
        meter.setOperation("a favorite")
        _ = try a.rows(keyed, [.integer(1)])
        _ = try b.rows(keyed, [.integer(1)])
        meter.setOperation("a played mark"); _ = try a.rows(queue)
        meter.setOperation("an adoption check"); _ = try a.rows(queue)
        meter.setOperation("a favorite")
        try a.execute("DROP INDEX episodes_by_feed")
        _ = try a.rows(keyed, [.integer(1)])
        try a.execute("ATTACH DATABASE ? AS shadow", [.text(root.appendingPathComponent("a/shadow.sqlite").path)])
        try a.execute("CREATE TABLE shadow.episodes (id INTEGER PRIMARY KEY, pubdate INTEGER NOT NULL)")
        meter.setOperation("a played mark"); _ = try a.rows("SELECT sum(pubdate) FROM shadow.episodes")
        let violations = Self.violations(meter.takePlans())
        print("BUDGET scoped plan violations:\n\(violations.joined(separator: "\n"))")
        #expect(violations.filter { $0.hasPrefix("[a favorite] reads episodes whole") && $0.hasSuffix(keyed) }.count == 2,
                "the unindexed connection of the same name, and the same connection after its index went: \(violations)")
        #expect(violations.filter { $0.hasPrefix("[an adoption check] reads queue whole") }.count == 1, "the same statement under a disallowed operation: \(violations)")
        #expect(violations.filter { $0.hasPrefix("[a played mark]") && $0.contains("shadow") && $0.hasSuffix("FROM shadow.episodes") }.count == 1,
                "the attached schema's episodes: \(violations)")
        #expect(violations.count == 4, "\(violations)")
    }

    /// The performance mutation: putting back `SELECT count(*) FROM statistics_units` in the projection makes a unit's work
    /// grow with the library's statistics units; with the probe it stays flat.
    @Test(arguments: [false, true]) func aStatisticsProbeNotACount(mutated: Bool) async throws {
        var works: [Work] = []
        for units in [0, 100_000] {
            let (fixture, applier) = try await Self.library(podcasts: 1, episodes: 50)
            if mutated { await fixture.store.setAdoptionFaultsForTesting([.countStatisticsUnits]) }
            if units > 0 {
                let local = try #require(try await fixture.store.localEpisodeForTesting(wire: Self.wire(0, 50)))
                try await fixture.store.databaseForTesting { db in
                    try db.transaction { try db.replaceStatisticsUnits(episode: local, with: (0..<units).map { LibraryStatisticsUnit(episodeID: local, unitID: "u\($0)") }) }
                }
            }
            works.append(try await Self.measure(fixture.store) {
                try await applier.apply([ServerRecord(entity: "episode", id: Self.wire(0, 3), fieldGroup: "played_time",
                                                      value: ["generation_id": .string(Self.generation), "played_ms": 5_000])])
            })
            await fixture.close()
        }
        print("BUDGET a played-time unit with 0 → 100,000 statistics units\(mutated ? " (count(*) put back)" : ""): \(works[0]) | \(works[1])")
        // Pages, not VM steps: a whole-table count is one VM step over every page.
        let flat = works[1].steps <= works[0].steps + works[0].steps / 10 + 2_000 && works[1].pages <= works[0].pages + works[0].pages / 10 + 100
        if mutated { #expect(!flat, "the count is caught: \(works)") } else { #expect(flat, "\(works)") }
    }
}

extension FeedLibraryStore {
    func workForTesting() -> ServerChangeSetBudgetTests.Work {
        var work = ServerChangeSetBudgetTests.Work()
        let meter = SQLWorkMeter.shared.totals
        work.steps = meter.steps
        work.pages = meter.pages
        work.rowsRead = meter.rowsRead
        work.bytesRead = meter.bytesRead
        work.sessions = meter.sessionsDecoded
        work.statements = meter.statements
        work.rowsWritten = meter.rowsWritten
        work.decoded = meter.recordsDecoded
        work.decodedBytes = meter.bytesDecoded
        work.keys = Int(meter.keys)
        work.captureRows = database.capture?.changesWritten ?? 0
        work.drainRows = database.capture?.drainRows ?? 0
        work.digests = database.capture?.counter.inputs ?? 0
        return work
    }

    func ensureServerExchangeTablesForTesting() throws { try ensureServerExchangeTables() }

    /// EXPLAIN QUERY PLAN of every capture statement: the ones that scan a library table other than the queue.
    func captureQueryPlanViolationsForTesting() throws -> [String] {
        guard let capture = database.capture else { return ["no capture"] }
        let sql = LibraryChangeCapture.SQL(tables: capture.tables, columns: [:], faults: capture.faults)
        var statements: [String] = []
        for trigger in sql.triggers() {
            guard let begin = trigger.statement.range(of: " BEGIN "), let end = trigger.statement.range(of: " END", options: .backwards) else { continue }
            if let when = trigger.statement.range(of: " WHEN ") , when.upperBound < begin.lowerBound {
                statements.append("SELECT " + String(trigger.statement[when.upperBound..<begin.lowerBound])
                    .replacingOccurrences(of: #"(NEW|OLD)\.[a-z_]+"#, with: "?", options: .regularExpression))
            }
            let body = String(trigger.statement[begin.upperBound..<end.lowerBound])
                .replacingOccurrences(of: #"(NEW|OLD)\.[a-z_]+"#, with: "?", options: .regularExpression)
            statements += body.split(separator: ";").map { String($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        let drain = sql.drainStatements()
        statements += Array(drain.changed.values) + [drain.queueAfter, drain.unitsChanged, drain.unitEpisode]
        var plans: [SQLWorkMeter.Plan] = []
        for statement in statements {
            do { plans.append(.init(operation: "capture", connection: "writer", schema: "", sql: statement, scans: try scansForTesting(statement), failure: nil)) }
            catch { plans.append(.init(operation: "capture", connection: "writer", schema: "", sql: statement, scans: [], failure: "\(error)")) }
        }
        return ServerChangeSetBudgetTests.violations(plans, allowances: ["capture": ["queue": "the queue's own length"]])
    }

    /// The tables `sql` reads whole on the store's writer, from its bytecode, with their schemas.
    func scansForTesting(_ sql: String) throws -> [SQLWorkMeter.Scan] {
        var result: [SQLWorkMeter.Scan] = []
        var failure: Error?
        try database.withHandle { handle in
            do { result = try SQLWorkMeter.scans(sql, handle: handle) } catch { failure = error }
            return SQLITE_OK
        }
        if let failure { throw failure }
        return result
    }

    /// Library-scale tables: a routine statement must search them by key.
    static let libraryTables: Set<String> = ["feeds", "episodes", "statistics_units", "download_jobs", "episode_swipe_undo", "local_folder_links",
                                             "pinned_feed_removals", "ntp_hidden_feeds", "ntp_hidden_episodes", "ntp_podcasts", "ntp_episodes",
                                             "ntp_records", "ntp_overlays", "ntp_sessions", "ntp_nodes", "ntp_outbox", "ntp_local_playback",
                                             "ntp_deferred_pins", "ntp_recovery_holds", "queue", "archive_entries", "archive_history", "archive_edges",
                                             "archive_decisions", "ntp_statistics_units"]
}
