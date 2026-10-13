import Foundation
import Testing
@testable import NotTennaPodCore

/// The five-second save's work through a long offline session. The accepted accounting
/// is kept at retirement, so a save asks about one pending export however many a session holds, and a save reads only
/// the overlay its played time needs. The measurement (`NTP_SAVE_LATENCY=1`): eight hours of listening with no
/// exchange, a checkpoint export due every minute and none accepted, every save timed as the coordinator awaits it
/// (the store call, its transaction and its recording).
@Suite(.serialized, .timeLimit(.minutes(20))) struct ServerPlaybackSaveLatencyTests {
    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    /// C_acc asks about the export after the retired prefix only, not about every export still pending.
    @Test func theAcceptedContributionAsksAboutOnePendingExport() throws {
        var session = ServerSyncSession(localSession: UUID(), episodeID: 1, incarnation: "opening", start: 0)
        session.state = .open
        for ordinal in 1...480 {
            session.exports.append(.init(op: "op-\(ordinal)", ordinal: Int64(ordinal), contribution: Int64(ordinal) * 60_000))
        }
        let pending = Set((241...480).map { "op-\($0)" })
        var asked = 0
        try session.noteRetiredExports { asked += 1; return pending.contains($0) }
        #expect(session.acceptedCount == 240 && asked == 241, "retirement walks the newly retired exports once")
        asked = 0
        #expect(try session.acceptedContribution { asked += 1; return pending.contains($0) } == 240 * 60_000)
        #expect(asked == 1, "a save asks about one pending export")
        session.exports[239].void = true
        #expect(try session.acceptedContribution { pending.contains($0) } == 239 * 60_000, "a refused export adds nothing")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NTP_SAVE_LATENCY"] != nil))
    func saveLatencyThroughAnEightHourOfflineSession() async throws {
        let (fixture, ids, _, _) = try await ServerPlaybackRecorderTests.library()
        defer { Task { await fixture.close() } }
        let player = StorePlayer(fixture.store)
        player.duration = 30_000_000
        try await player.load(ids[1])
        try await player.play()
        let clock = ContinuousClock()
        var hours: [[Double]] = []
        for _ in 0..<8 {
            var samples: [Double] = []
            for _ in 0..<(3_600 / 5) {
                let started = clock.now
                try await player.listen(5)
                samples.append(Self.milliseconds(clock.now - started))
            }
            hours.append(samples)
        }
        let checkpoints = try fixture.outbox().filter { $0.type == "session.checkpoint" }.count
        let all = hours.flatMap { $0 }
        func line(_ name: String, _ values: [Double]) -> String {
            "\(name) median \(String(format: "%.2f", Self.median(values))) ms, worst \(String(format: "%.2f", values.max() ?? 0)) ms"
        }
        print("SAVE LATENCY over 8 h offline (\(all.count) saves, \(checkpoints) checkpoint exports unaccepted): "
              + ([line("all", all)] + hours.indices.map { line("hour \($0 + 1)", hours[$0]) }).joined(separator: "; "))
        #expect(checkpoints >= 470, "a checkpoint export every minute")
    }
}
