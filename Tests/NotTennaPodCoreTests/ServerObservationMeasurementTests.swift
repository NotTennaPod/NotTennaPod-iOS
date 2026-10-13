import Foundation
import Testing
@testable import NotTennaPodCore

/// What another device's observation of a catalog writes on this library: against the pinned
/// server, C subscribes to a 1,000-episode feed and observes it; A applies each commit alone and every record, row and
/// mapping is compared before and after. Prints the breakdown; run with `NTP_MEASURE_OBSERVATION=1`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NTP_MEASURE_OBSERVATION"] != nil))
struct ServerObservationMeasurementTests {
    typealias Agreement = ServerExchangeAgreementTests
    typealias Dump = (records: [String: String], episodes: [String: String], mappings: [String: String], queue: [String], other: [String: Int])

    static func dump(_ phone: ExchangePhone) throws -> Dump {
        var records: [String: String] = [:]
        for row in try phone.rows("SELECT entity || '|' || id || '|' || field_group, CAST(value AS TEXT) || '#' || coalesce(provenance, '') FROM ntp_records") {
            records[row[0] ?? ""] = row[1] ?? ""
        }
        var episodes: [String: String] = [:]
        for row in try phone.rows("SELECT id, CAST(record AS TEXT) FROM episodes") { episodes[row[0] ?? ""] = row[1] ?? "" }
        var mappings: [String: String] = [:]
        for row in try phone.rows("SELECT episode_id, coalesce(local_id, '') || '|' || podcast_id || '|' || kind || '|' || value || '|' || coalesce(CAST(occurrence AS TEXT), '') || '|' || coalesce(merged_into, '') FROM ntp_episodes") {
            mappings[row[0] ?? ""] = row[1] ?? ""
        }
        let queue = try phone.rows("SELECT episode_id FROM queue ORDER BY position").map { $0[0] ?? "" }
        var other: [String: Int] = [:]
        for table in ["ntp_nodes", "ntp_overlays", "ntp_outbox", "ntp_ledger", "ntp_statistics_units", "statistics_units", "ntp_queue_keys", "feeds", "ntp_local_items", "ntp_observation_work"] {
            other[table] = Int(try phone.rows("SELECT count(*) FROM \(table)").first?.first.flatMap { $0 }.flatMap { Int($0) } ?? -1)
        }
        return (records, episodes, mappings, queue, other)
    }

    static func compare(_ before: Dump, _ after: Dump, _ report: ServerExchangeReport, _ estimate: (seq: Int64, total: Int, unit: Int, records: Int, groups: [String: Int])?) {
        if let estimate { print("OBSERVATION commit \(estimate.seq): estimate \(estimate.total) (unit \(estimate.unit)), records in commit \(estimate.records) by group \(estimate.groups)") }
        var recIns = 0, recChanged = 0, recSame = 0, provenanceOnly = 0
        var groups: [String: [Int]] = [:]
        for (key, value) in after.records {
            let group = key.split(separator: "|").last.map(String.init) ?? ""
            if let old = before.records[key] {
                if old == value { recSame += 1 } else {
                    recChanged += 1; groups[group, default: [0, 0]][1] += 1
                    if old.split(separator: "#").first == value.split(separator: "#").first { provenanceOnly += 1 }
                }
            } else { recIns += 1; groups[group, default: [0, 0]][0] += 1 }
        }
        var epChanged = 0, epNew = 0
        for (id, record) in after.episodes { if let old = before.episodes[id] { if old != record { epChanged += 1 } } else { epNew += 1 } }
        var mapChanged = 0
        for (id, m) in after.mappings where before.mappings[id] != m { mapChanged += 1 }
        let otherDelta = after.other.filter { before.other[$0.key] != $0.value }.map { "\($0.key) \(before.other[$0.key] ?? 0)->\($0.value)" }
        for unit in report.units {
            print("OBSERVATION  unit seq \(unit.seq): work \(unit.work), rowsWritten \(unit.rowsWritten), lock \(String(format: "%.1f", unit.lockMilliseconds)) ms, published \(unit.published)")
        }
        print("OBSERVATION  records: inserted \(recIns), changed \(recChanged) (provenance only \(provenanceOnly)), unchanged \(recSame); by group [inserted, changed] \(groups)")
        print("OBSERVATION  episode rows changed \(epChanged), new \(epNew); mappings changed \(mapChanged); queue changed \(before.queue != after.queue); counts \(otherDelta)")
        if let key = after.records.keys.sorted().first(where: { $0.hasPrefix("episode|") && $0.hasSuffix("|metadata") && before.records[$0] != nil && before.records[$0] != after.records[$0] }) {
            func fields(_ text: String) -> [String: String] {
                let json = String(text.split(separator: "#").first ?? "")
                guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return [:] }
                return object.mapValues { "\($0)" }
            }
            let old = fields(before.records[key]!), new = fields(after.records[key]!)
            let diff = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }.sorted()
            print("OBSERVATION  record \(key) fields that differ: \(diff.map { "\($0): \(old[$0]?.prefix(60) ?? "nil") -> \(new[$0]?.prefix(60) ?? "nil")" })")
        }
        if let id = after.episodes.keys.sorted().first(where: { before.episodes[$0] != nil && before.episodes[$0] != after.episodes[$0] }) {
            func flat(_ text: String) -> [String: String] {
                guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [:] }
                var out: [String: String] = [:]
                func walk(_ value: Any, _ path: String) {
                    if let d = value as? [String: Any] { for (k, v) in d { walk(v, path.isEmpty ? k : path + "." + k) } } else { out[path] = "\(value)" }
                }
                walk(object, "")
                return out
            }
            let old = flat(before.episodes[id]!), new = flat(after.episodes[id]!)
            let diff = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }.sorted()
            print("OBSERVATION  episode row \(id) fields that differ: \(diff.map { "\($0): \(old[$0]?.prefix(60) ?? "nil") -> \(new[$0]?.prefix(60) ?? "nil")" })")
        }
    }

    @Test func observationCommitBreakdown() async throws {
        try await ExchangeWorld.run(feeds: ["/large.xml": ("Large", "large", 1_000), "/other.xml": ("Other", "other", 3)]) { world in
            let a = try await world.attach("A")
            let other = try await a.store.insert(Agreement.fetched(world.url("other.xml"), title: "Other", prefix: "other", count: 3))
            try await Agreement.waitForCatalog(a, feedID: other.id)
            let c = try await world.attach("C")
            let large = try await c.store.insert(Agreement.fetched(world.url("large.xml"), title: "Large", prefix: "large", count: 1_000))
            await c.exchange()
            let podcast = try #require(try await c.store.podcastOfFeedForTesting(large.id))
            _ = try await c.transport.server.send("POST", "v1/refresh", body: ["podcast_id": .string(podcast)])
            try await Agreement.waitForCatalog(c, feedID: large.id)
            for _ in 0..<3 { await c.exchange() }
            _ = await a.run([.pull])
            await a.engine.setBudgets(direct: 1_000_000, publish: 1_000_000)
            for _ in 0..<12 {
                let before = try Self.dump(a)
                let estimate = try await a.engine.nextEstimateForTesting()
                let report = await a.run([.applyOne])
                if report.appliedUnits == 0 { break }
                Self.compare(before, try Self.dump(a), report, estimate)
            }
        }
    }
}

extension ServerSyncEngine {
    func nextEstimateForTesting() throws -> (seq: Int64, total: Int, unit: Int, records: Int, groups: [String: Int])? {
        guard let live = try ServerLibraryFixture.read(databaseURL, "SELECT seq FROM ntp_library").first?.first.flatMap({ $0 }).flatMap({ Int64($0) }),
              let next = try archive.nextPendingCommit(after: live) else { return nil }
        let estimate = try estimateWork(next.commit)
        var groups: [String: Int] = [:]
        for record in next.commit.records { groups["\(record.entity)/\(record.fieldGroup)", default: 0] += 1 }
        return (next.commit.seq, estimate.total, estimate.unit, next.commit.records.count, groups)
    }
}
