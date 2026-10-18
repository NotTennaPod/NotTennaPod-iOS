import Foundation
import Testing
@testable import NotTennaPodCore

/// Power-user scale (`NTP_SCALE=1`, release): the schema-21 fill of a 26,271-episode and a 100,000-episode library,
/// the work of each of its steps (the primary gate), its time (secondary) and the disk it adds; a position save's cost flat at 10k, 54k and 100k episodes; a
/// restore writing one key row per episode.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NTP_SCALE"] == "1"))
struct DerivedScaleTests {
    static func shape(episodes: Int, feeds: Int) -> LargeAndroidLibrary.Shape {
        var shape = LargeAndroidLibrary.Shape()
        shape.episodes = episodes; shape.feeds = feeds
        shape.heavyFeeds = min(10, feeds / 7); shape.heavyEpisodes = episodes / 4 / shape.heavyFeeds
        shape.mediumFeeds = feeds / 2; shape.mediumEpisodes = episodes / 3 / shape.mediumFeeds
        return shape
    }

    static func restored(in directory: URL, episodes: Int, feeds: Int) async throws -> (URL, Duration) {
        let backup = directory.appendingPathComponent("backup.db")
        try LargeAndroidLibrary.write(to: backup, shape: shape(episodes: episodes, feeds: feeds))
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let library = try AndroidDatabaseRestore.read(backup, staging: directory.appendingPathComponent("staging"))
        let clock = ContinuousClock(), start = clock.now
        try await store.installRestoredLibrary(library, carrying: try await store.restoreCarryOver())
        let restore = start.duration(to: clock.now)
        try await store.close()
        try? FileManager.default.removeItem(at: backup)
        return (url, restore)
    }

    static func bytes(_ url: URL) throws -> Int64 {
        try RawLibrary.execute(url, "PRAGMA wal_checkpoint(TRUNCATE)")
        let rows = try RawLibrary.rows(url, "SELECT (SELECT page_count FROM pragma_page_count) * (SELECT page_size FROM pragma_page_size)")
        return Int64(rows[0][0] ?? "0") ?? 0
    }

    static func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    /// The disk budget per episode: a fixed part (numbers, row and index overhead) and the kept text (`textBytes`: what
    /// the episode's title, GUID, media address and file name take in its row and their indexes).
    static func sizeBudget(textBytes: Double) -> Double { 300 + 1.3 * textBytes }

    static func seconds(_ duration: Duration) -> Double { Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 }

    @Test(arguments: [(26_271, 70), (100_000, 500)])
    func theFillAtPowerUserScale(episodes: Int, feeds: Int) async throws {
        let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let (url, restore) = try await Self.restored(in: directory, episodes: episodes, feeds: feeds)
        let derivedBytes = try Self.bytes(url)
        try DerivedDataOracle.downgradeTo20(url)
        try RawLibrary.execute(url, "VACUUM")
        let before = try Self.bytes(url)
        let clock = ContinuousClock()
        var start = clock.now
        let store = try FeedLibraryStore(url: url)
        let open = start.duration(to: clock.now)
        #expect(try RawLibrary.rows(url, "SELECT count(*) FROM episode_list_keys") == [["0"]], "no fill work at open")
        start = clock.now
        let steps = try await Self.fillSteps(store, url: url)
        let fill = start.duration(to: clock.now)
        try await store.close()
        let after = try Self.bytes(url)
        let perEpisode = Double(after - before) / Double(episodes)
        let fillCPU = steps.map(\.cpu).reduce(0, +), longestCPU = steps.map(\.cpu).max() ?? 0
        print("DERIVED scale step CPU (ms): " + steps.map { String(Int($0.cpu * 1_000)) }.joined(separator: " "))
        print("DERIVED scale \(episodes) episodes / \(feeds) feeds: restore \(restore), open (migration) \(open), fill \(fill) wall / \(fillCPU) s CPU in \(steps.count) steps, longest step \(Int(longestCPU * 1_000)) ms CPU; \(Self.describe(steps)); size +\(after - before) bytes (\(Int(perEpisode)) B/episode; restored with derived data \(derivedBytes) bytes)")
        // The primary gate is the work each step does, whatever the machine's load: its episodes and record bytes within
        // the step budget's model, and its VM steps within the per-episode and per-feed allowance.
        #expect(steps.allSatisfy { Self.withinWork($0, feeds: feeds) }, "\(steps.filter { !Self.withinWork($0, feeds: feeds) }.prefix(3))")
        #expect(steps.map(\.rows).reduce(0, +) == episodes, "every episode keyed once")
        // CPU time is secondary: about 30 µs per episode and under 30 ms per step on the development Mac, bounded here
        // with room for a loaded machine.
        #expect(fillCPU <= 8 * Double(episodes) / 100_000 + 0.5, "fill CPU \(fillCPU) s")
        #expect(longestCPU <= Self.secondaryStepCPU, "longest step CPU \(longestCPU) s")
        // The fixture's text: titles about 40 B, GUIDs about 15 B, media addresses about 45 B.
        #expect(perEpisode <= Self.sizeBudget(textBytes: 40 + 2 * (15 + 45)), "\(perEpisode) B/episode")
        try EpisodeListKeysTests.expectExact(url, "filled at scale")
    }

    /// A position save's derived work stays flat with library size (VM steps and pages on the store's connection).
    @Test func aPositionSaveIsFlatAcrossLibrarySizes() async throws {
        var steps: [Int64] = [], pages: [Int64] = []
        for (episodes, feeds) in [(10_000, 100), (54_000, 300), (100_000, 500)] {
            let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
            let (url, _) = try await Self.restored(in: directory, episodes: episodes, feeds: feeds)
            let store = try FeedLibraryStore(url: url)
            let id = Int64(episodes / 2)
            try await store.updateEpisode(id: id) { $0.userState.positionMilliseconds = 1 }
            let before = try await store.withDatabaseForTesting { ($0.statementSteps, $0.pageLookups) }
            try await store.updateEpisode(id: id) { $0.userState.positionMilliseconds = 2 }
            let after = try await store.withDatabaseForTesting { ($0.statementSteps, $0.pageLookups) }
            steps.append(after.0 - before.0); pages.append(after.1 - before.1)
            try await store.close()
        }
        print("DERIVED scale: a position save at 10k/54k/100k: VM steps \(steps), pages \(pages)")
        #expect(Double(steps.max()!) <= 1.1 * Double(steps[0]) + 16, "\(steps)")
        #expect(Double(pages.max()!) <= 1.1 * Double(pages[0]) + 16, "\(pages)")
    }

    /// A restore at 26k and 54k writes one key row per episode and one counts row per feed.
    @Test(arguments: [(26_271, 70), (54_000, 300)])
    func aRestoreWritesOneDerivedRowPerEpisodeAndFeed(episodes: Int, feeds: Int) async throws {
        let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = try await DerivedWriteBudgetTests.restore(in: directory, episodes: episodes, feeds: feeds)
        print("DERIVED scale restore \(episodes): \(log)")
        #expect(DerivedWriteBudgetTests.writesOnce(log, episodes: episodes, feeds: feeds), "each key row and each feed's counts written once: \(log)")
    }
    /// One fill step's work: the episodes it keyed (those its cursor passed), their record bytes, the VM steps it ran
    /// on the store's connection, and its process CPU (the test runs alone).
    struct FillStep: CustomStringConvertible {
        var rows = 0, bytes = 0, vmSteps: Int64 = 0, cpu = 0.0
        var description: String { "\(rows) episodes, \(bytes) B, \(vmSteps) VM steps, \(Int(cpu * 1_000)) ms" }
    }

    /// Fill steps measured one by one.
    static func fillSteps(_ store: FeedLibraryStore, url: URL, batch: Int = 1_000) async throws -> [FillStep] {
        var steps: [FillStep] = []
        func cursor() throws -> String? { try RawLibrary.rows(url, "SELECT next_id FROM derived_fill WHERE id = 1").first?.first ?? nil }
        while true {
            var step = FillStep()
            let from = try cursor(), vm = try await store.withDatabaseForTesting { $0.statementSteps }
            let start = cpu()
            let complete = try await store.fillDerivedBatch(batch)
            step.cpu = cpu() - start
            step.vmSteps = try await store.withDatabaseForTesting { $0.statementSteps } - vm
            if let from, let to = try cursor(), from != to {
                let work = try RawLibrary.rows(url, "SELECT count(*), coalesce(sum(length(record)), 0) FROM episodes WHERE id > \(from) AND id <= \(to)")[0]
                step.rows = Int(work[0] ?? "0") ?? 0; step.bytes = Int(work[1] ?? "0") ?? 0
            }
            steps.append(step)
            if complete { return steps }
        }
    }

    /// A fill step's work allowance in VM steps: per episode keyed (its record read, its key row and index entries, its
    /// counts contribution), per feed (each step's eligibility of every feed, computed once) and per step. Measured at
    /// most: 243,358 for 606 episodes of a 70-feed library, 270,003 for 607 of a 500-feed one, 245,537 for 607 of 99,000
    /// in one feed, 86,003 for 186 with 17 KB of notes; the allowance leaves room (12 to 30%). A step doing work that
    /// grows with the library or a feed (a scan of the keys or the records) breaks it.
    static let vmStepsPerEpisode: Int64 = 500, vmStepsPerFeed: Int64 = 100, vmStepsPerStep: Int64 = 5_000

    /// The primary gate of a fill step: at most `batch` episodes, whose modeled cost (per episode and per record byte)
    /// fits the step budget unless one episode is a step of its own, in VM steps within the allowance.
    static func withinWork(_ step: FillStep, feeds: Int, batch: Int = 1_000) -> Bool {
        let modeled = step.rows * LibrarySchema21.fillRowNanoseconds + step.bytes * LibrarySchema21.fillByteNanoseconds
        return step.rows <= batch && (step.rows <= 1 || modeled <= LibrarySchema21.fillStepBudgetNanoseconds)
            && step.vmSteps <= vmStepsPerEpisode * Int64(step.rows) + vmStepsPerFeed * Int64(feeds) + vmStepsPerStep
    }

    /// The secondary, CPU bound of one step: ten times the 25 ms model, so only a step doing a different order of work fails it.
    static let secondaryStepCPU = 0.25

    static func describe(_ steps: [FillStep]) -> String {
        let keyed = steps.filter { $0.rows > 0 }
        let perEpisode = keyed.map { Double($0.vmSteps) / Double($0.rows) }.max() ?? 0
        return "steps keying episodes: \(keyed.count), most episodes \(keyed.map(\.rows).max() ?? 0), most bytes \(keyed.map(\.bytes).max() ?? 0), most VM steps \(keyed.map(\.vmSteps).max() ?? 0) (\(Int(perEpisode)) per episode at most), others \(steps.filter { $0.rows == 0 }.map(\.vmSteps))"
    }

    /// Records with 17 KB of show notes: the fill's steps adapt to the bytes they read and stay near 25 ms of CPU.
    @Test func longShowNotesKeepEveryFillStepShort() async throws {
        let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let feed = try await store.insert(EpisodeListKeysTests.fetched("https://example.test/notes.xml", count: 1), options: .init(now: EpisodeListKeysTests.now))
        try await store.close()
        var template = feed.episodes[0]
        template.details.description = "<p>" + String(repeating: "A long paragraph of show notes. ", count: 530) + "</p>"
        var statements: [(String, [LibrarySQLValue])] = [("BEGIN", [])]
        for number in 0..<4_000 {
            template.id = 10_000 + Int64(number); template.details.identifier = "notes-\(number)"
            statements.append(("INSERT INTO episodes(id, feed_id, pubdate, record) VALUES (?, ?, 0, ?)", [.integer(template.id), .integer(feed.id), .blob(try DerivedDataOracle.record(template))]))
        }
        statements.append(("COMMIT", []))
        try DerivedDataOracle.write(url, statements)
        try DerivedDataOracle.downgradeTo20(url)
        let migrated = try FeedLibraryStore(url: url)
        let steps = try await Self.fillSteps(migrated, url: url)
        try await migrated.close()
        print("DERIVED scale 17 KB notes: \(steps.count) steps, longest \(Int(steps.map(\.cpu).max()! * 1_000)) ms CPU, total \(Int(steps.map(\.cpu).reduce(0, +) * 1_000)) ms CPU; \(Self.describe(steps))")
        #expect(steps.allSatisfy { Self.withinWork($0, feeds: 1) }, "\(steps.filter { !Self.withinWork($0, feeds: 1) }.prefix(3))")
        #expect(steps.filter { $0.rows > 0 }.count >= 4_000 * 17_000 * LibrarySchema21.fillByteNanoseconds / LibrarySchema21.fillStepBudgetNanoseconds, "the steps adapt to the bytes")
        #expect(steps.map(\.cpu).max()! <= Self.secondaryStepCPU, "longest step \(steps.map(\.cpu).max()!) s")
        try EpisodeListKeysTests.expectExact(url, "long notes")
    }

    /// 100,000 episodes with 99,000 of them in one feed: no step grows with a feed's size.
    @Test func aConcentratedFeedKeepsEveryFillStepShort() async throws {
        let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let (url, _) = try await Self.restored(in: directory, episodes: 100_000, feeds: 100)
        try DerivedDataOracle.downgradeTo20(url)
        try RawLibrary.execute(url, "UPDATE episodes SET feed_id = (SELECT min(id) FROM feeds) WHERE id <= 99000")
        let store = try FeedLibraryStore(url: url)
        let steps = try await Self.fillSteps(store, url: url)
        try await store.close()
        print("DERIVED scale 99k in one feed: \(steps.count) steps, longest \(Int(steps.map(\.cpu).max()! * 1_000)) ms CPU, total \(String(format: "%.2f", steps.map(\.cpu).reduce(0, +))) s CPU; \(Self.describe(steps))")
        #expect(steps.allSatisfy { Self.withinWork($0, feeds: 100) }, "\(steps.filter { !Self.withinWork($0, feeds: 100) }.prefix(3))")
        #expect(steps.map(\.cpu).max()! <= Self.secondaryStepCPU, "longest step \(steps.map(\.cpu).max()!) s")
        try EpisodeListKeysTests.expectExact(url, "concentrated feed")
    }

    /// A populated release ledger (26,271 and 100,000 entries, half pending, half unnotified): each index is built in a
    /// step of its own, once per library, proportional to the ledger (the documented exception to the step budget).
    @Test(arguments: [26_271, 100_000])
    func aPopulatedLedgersIndexesAreBuiltOneStepEach(entries: Int) async throws {
        let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        try await FeedLibraryStore(url: url).close()
        var statements: [(String, [LibrarySQLValue])] = [("BEGIN", [])]
        for number in 0..<entries {
            let generation = "g1:" + String(format: "%064x", number % 100), occurrence = "e1:" + String(format: "%064x", number)
            statements.append(("INSERT INTO ntp_ledger(generation_id, occurrence, entry_id, state, notified) VALUES (?, ?, ?, ?, ?)",
                               [.text(generation), .text(occurrence), .text(UUID().uuidString), .text(number.isMultiple(of: 2) ? "pending" : "done"), .integer(number % 4 < 2 ? 0 : 1)]))
        }
        statements.append(("COMMIT", []))
        try DerivedDataOracle.write(url, statements)
        try DerivedDataOracle.downgradeTo20(url)
        let store = try FeedLibraryStore(url: url)
        let steps = try await Self.fillSteps(store, url: url)
        try await store.close()
        let index = steps.dropLast()
        print("DERIVED scale ledger of \(entries): index steps \(index.map { "\(Int($0.cpu * 1_000)) ms CPU, \($0.vmSteps) VM steps" })")
        #expect(index.count == 3, "one step per index")
        // The work: VM steps proportional to the ledger (a scan and a sort of its entries, about 7.5 per entry measured).
        // Time is secondary: about 1 µs per entry per index on the development Mac, bounded with room for a loaded machine.
        #expect(index.allSatisfy { $0.vmSteps <= 15 * Int64(entries) + 2_000 }, "\(index)")
        #expect(index.allSatisfy { $0.cpu <= 1.6e-5 * Double(entries) + 0.04 }, "\(index)")
    }

    /// A real listening checkpoint's VM steps and pages at 10k, 54k and 100k episodes.
    @Test func aListeningCheckpointIsFlatAtPowerUserScale() async throws {
        var costs: [(steps: Int64, pages: Int64)] = []
        for episodes in [10_000, 54_000, 100_000] { costs.append(try await DerivedWriteBudgetTests.checkpointCost(episodes: episodes, feeds: 300)) }
        print("DERIVED scale: a listening checkpoint at 10k/54k/100k: VM steps \(costs.map(\.steps)), pages \(costs.map(\.pages))")
        #expect(costs.allSatisfy { DerivedWriteBudgetTests.flat(costs[0], $0) }, "\(costs)")
    }
}
