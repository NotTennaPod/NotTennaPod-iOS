import Foundation
import Testing
@testable import NotTennaPodCore

/// Rule vectors projected by the record applier: the phone does not fold facts, so each case's `expected.records` (the
/// server's fold) is applied to an empty server library, and the rows and lists must show exactly what the records
/// say. `rules_episode_leave` (PROTOCOL §8.4), pinned to the server the host agreement tests run
/// (`TestSupport/Contract/rules`, `Tools/sync-contract-vectors.sh`).
@Suite struct ServerRuleVectorProjectionTests {
    static let directory = ContractVectorTests.root.appendingPathComponent("TestSupport/Contract/rules")

    static func cases(_ suite: String) throws -> [ContractJSON] {
        let file = try ContractJSON.decode(try Data(contentsOf: directory.appendingPathComponent("\(suite).json")))
        return try #require(file["cases"]?.arrayValue)
    }

    @Test func theCopiesMatchTheirManifest() throws {
        let manifest = try String(contentsOf: Self.directory.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
        for line in manifest.split(separator: "\n") {
            let data = try Data(contentsOf: Self.directory.appendingPathComponent(String(line.dropFirst(66))))
            #expect(ContractIdentity.sha256Hex(Array(data)) == String(line.prefix(64)))
        }
        let pinned = try String(contentsOf: ContractVectorTests.root.appendingPathComponent("TestSupport/Server/server-version.txt"), encoding: .utf8)
            .split(separator: "\n").first { !$0.hasPrefix("#") }.map(String.init)
        #expect(try String(contentsOf: Self.directory.appendingPathComponent("server-commit.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == pinned, "the rule vectors are the agreement tests' server's")
    }

    @Test func episodeLeaveRecordsProjectOntoTheRows() async throws {
        let cases = try Self.cases("rules_episode_leave")
        #expect(cases.count >= 20)
        var failures: [String] = []
        for (index, vector) in cases.enumerated() {
            let records = try #require(vector["expected"]?["records"]?.arrayValue).map { record in
                ServerRecord(entity: record["entity"]?.stringValue ?? "", id: record["id"]?.stringValue ?? "",
                             fieldGroup: record["field_group"]?.stringValue ?? "", value: record["value"])
            }
            let problems = try await Self.project(records, namespace: vector["namespace"]?.stringValue ?? "", account: vector["account_id"]?.stringValue ?? "")
            failures += problems.map { "case \(index): \($0)" }
        }
        print("rule vectors projected: suite=rules_episode_leave cases=\(cases.count) failures=\(failures.count)")
        #expect(failures.isEmpty, "\(failures.prefix(10).joined(separator: "\n"))")
    }

    /// Applies the records in one unit and compares every episode's row, and the queue, with them.
    static func project(_ records: [ServerRecord], namespace: String, account: String) async throws -> [String] {
        let fixture = try await ServerLibraryFixture(accountID: account, namespace: namespace)
        defer { Task { await fixture.close() } }
        let applier = try await ServerProjectionUnitTests.Applier(fixture)
        try await applier.apply(records)
        var problems: [String] = []
        var byEpisode: [String: [String: ContractJSON]] = [:]
        for record in records where record.entity == "episode" { byEpisode[record.id, default: [:]][record.fieldGroup] = record.value ?? .null }
        // A removed podcast's episodes leave the library with it (PROTOCOL §7.2).
        let removed = Set(records.filter { $0.entity == "podcast" && $0.fieldGroup == "subscription" && $0.value?["state"]?.stringValue == "removed" }.map(\.id))
        for (episode, groups) in byEpisode.sorted(by: { $0.key < $1.key }) {
            guard let identity = groups["identity"] else { continue }
            if let podcast = identity["podcast_id"]?.stringValue, removed.contains(podcast) {
                if let local = try await fixture.store.localEpisodeForTesting(wire: episode), try await fixture.store.episode(id: local) != nil {
                    problems.append("\(episode.prefix(12)): a removed podcast's episode is shown")
                }
                continue
            }
            guard let local = try await fixture.store.localEpisodeForTesting(wire: episode),
                  let row = try await fixture.store.episode(id: local)?.userState else {
                problems.append("\(episode.prefix(12)): no row"); continue
            }
            let state = groups["play_state"]?["play_state"]?.stringValue ?? "unplayed"
            let expectedState: EpisodePlayState = state == "played" ? .played : state == "new" ? .new : .unplayed
            if row.playState != expectedState { problems.append("\(episode.prefix(12)) play state \(row.playState) ≠ \(state)") }
            let position = groups["position"]?["position"]?.integerValue ?? 0
            if Int64(row.positionMilliseconds) != position { problems.append("\(episode.prefix(12)) position \(row.positionMilliseconds) ≠ \(position)") }
            let history = groups["history"]?["time"]?.integerValue
            if row.lastPlayedHistoryMilliseconds != history {
                problems.append("\(episode.prefix(12)) history \(String(describing: row.lastPlayedHistoryMilliseconds)) ≠ \(String(describing: history))")
            }
            let lastPlayed = groups["last_played"]?["time"]?.integerValue ?? 0
            if row.lastPlayedTimeMilliseconds != lastPlayed { problems.append("\(episode.prefix(12)) last played \(row.lastPlayedTimeMilliseconds) ≠ \(lastPlayed)") }
            let played = groups["played_time"]?["played_ms"]?.integerValue ?? 0
            if row.playedDurationMilliseconds != played { problems.append("\(episode.prefix(12)) played time \(row.playedDurationMilliseconds) ≠ \(played)") }
        }
        // The queue: the members the records put in it, in key order (an exact numeric comparison of the keys).
        var members: [(wire: String, key: QueueKey)] = []
        for (episode, groups) in byEpisode where groups["queue_membership"]?["in_queue"]?.boolValue == true
            && !removed.contains(groups["identity"]?["podcast_id"]?.stringValue ?? "") {
            if let key = groups["queue_position"]?["key"]?.stringValue { members.append((episode, try QueueKey(wire: key))) }
        }
        let expectedQueue = members.sorted { $0.key < $1.key }.map(\.wire)
        let queue = try await fixture.store.queue().map(\.id)
        var shown: [String] = []
        for id in queue { if let wire = try await fixture.store.wireEpisodeForTesting(id) { shown.append(wire) } }
        if shown != expectedQueue { problems.append("queue \(shown.map { $0.prefix(8) }) ≠ \(expectedQueue.map { $0.prefix(8) })") }
        if try !fixture.queueOrderMatchesKeys() { problems.append("queue order is not key order") }
        // Statistics: every played episode's total is its record's (no session of this library is in them).
        let statistics = try await fixture.store.statisticsLibrary()
        let total = statistics.feeds.flatMap(\.episodes).reduce(Int64(0)) { $0 + $1.userState.playedDurationMilliseconds }
        let expectedTotal = byEpisode.values.filter { !removed.contains($0["identity"]?["podcast_id"]?.stringValue ?? "") }
            .reduce(Int64(0)) { $0 + ($1["played_time"]?["played_ms"]?.integerValue ?? 0) }
        if total != expectedTotal { problems.append("played time total \(total) ≠ \(expectedTotal)") }
        return problems
    }
}

/// `Tools/sync-contract-vectors.sh --check`: a rule vector differing from the pinned server or from
/// its manifest fails the check, even when every ordinary vector matches. Run in an isolated copy whose ordinary
/// vectors the script itself copies from the server checkout, so only the rule vector can differ.
@Suite struct ContractVectorScriptTests {
    static var serverCheckout: URL {
        if let path = ProcessInfo.processInfo.environment["NTP_SERVER_CHECKOUT"], !path.isEmpty { return URL(fileURLWithPath: path) }
        let root = ContractVectorTests.root.path
        let top = root.range(of: "/.work/").map { String(root[..<$0.lowerBound]) } ?? root
        return URL(fileURLWithPath: top).deletingLastPathComponent().appendingPathComponent("NotTennaPod-Server")
    }

    /// Runs the script in `root` with `arguments`; returns its exit status and output.
    static func script(_ root: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [root.appendingPathComponent("Tools/sync-contract-vectors.sh").path] + arguments
        // This disposable copy owns a different lock inode. Its child must acquire the copy's lock;
        // real checkout commands keep the outer descriptor/ancestor authentication unchanged.
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("NTP_VALIDATION_LOCK_") }
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func aCorruptRuleVectorFailsTheCheck() throws {
        let server = Self.serverCheckout
        try #require(FileManager.default.fileExists(atPath: server.appendingPathComponent(".git").path), "the server checkout at \(server.path)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vector-check-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Tools", "TestSupport/Server", "TestSupport/Contract"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: ContractVectorTests.root.appendingPathComponent(path), to: root.appendingPathComponent(path))
        }
        // The ordinary vectors as the server has them now; the rule vectors from the pinned server.
        let copied = try Self.script(root, [server.path])
        try #require(copied.status == 0, "copying: \(copied.output)")
        let clean = try Self.script(root, ["--check", server.path])
        #expect(clean.status == 0, "a matching copy passes: \(clean.output)")
        try Data("{}".utf8).write(to: root.appendingPathComponent("TestSupport/Contract/rules/rules_episode_leave.json"))
        let corrupt = try Self.script(root, ["--check", server.path])
        #expect(corrupt.status != 0, "a corrupt rule vector fails the check: \(corrupt.output)")
        #expect(corrupt.output.contains("rules/rules_episode_leave.json"))
        #expect(!corrupt.output.contains("contract vectors match"))
    }
}
