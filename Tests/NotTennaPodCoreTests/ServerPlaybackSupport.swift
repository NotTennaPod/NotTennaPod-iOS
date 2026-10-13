import Foundation
import Synchronization
@testable import NotTennaPodCore

/// Drives a library's playback store calls in the order `PlaybackCoordinator` makes them (PROTOCOL §8):
/// load, the intentional-play hook, five-second saves while playing, a pause's synchronized save, the seek hook, and a
/// switch, skip or end (its final save, then `endPlayback`). Its clock is simulated (each save five seconds later), or
/// for tests against the server the real one: the server orders concurrent actions by their times, normalized between
/// their causal past and their receipt (PROTOCOL §6), so each action of a scenario is stamped when the test makes it.
final class StorePlayer: @unchecked Sendable {
    let store: FeedLibraryStore
    private(set) var session: LibraryPlaybackSession?
    private(set) var generation = UUID()
    private(set) var position: Int32 = 0
    private(set) var playing = false
    /// An engine holds the episode (a load in this process); a restored player has none and makes no final save.
    private(set) var engineLoaded = false
    var duration: Int32 = 600_000
    private var simulated: Date
    private let realTime: Bool
    var time: Date {
        get { realTime ? Self.realClock() : simulated }
        set { simulated = newValue }
    }

    /// The real clock, strictly increasing across every player of the process (by at least a millisecond), so no two
    /// actions of a scenario share a time and tie.
    private static let lastRealTime = Mutex<Int64>(0)
    static func realClock() -> Date {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let value = lastRealTime.withLock { last in
            last = max(now, last + 1)
            return last
        }
        return Date(timeIntervalSince1970: Double(value) / 1_000)
    }
    var smartSeconds: Int32 = 30
    var skipKeepsEpisode = true

    init(_ store: FeedLibraryStore, time: Date = Date(timeIntervalSince1970: 1_760_000_000)) {
        self.store = store
        simulated = time
        realTime = false
    }

    /// A player on the real clock.
    init(_ store: FeedLibraryStore, realTime: Void) {
        self.store = store
        simulated = Date()
        self.realTime = true
    }

    var episodeID: Int64? { session?.episodeID }

    /// Loads an episode paused or about to play (`beginPlayback` with a new baseline), at `position` or its saved one.
    func load(_ episodeID: Int64, at position: Int32? = nil) async throws {
        if let session, session.episodeID != episodeID { _ = try await end(.switched) }
        var start = position ?? 0
        if position == nil { start = try await store.episode(id: episodeID)?.userState.positionMilliseconds ?? 0 }
        generation = UUID()
        session = try await store.beginPlayback(episodeID: episodeID, positionMilliseconds: start)
        self.position = start
        playing = false
        engineLoaded = true
    }

    /// The person presses play: the intentional-play hook, after the engine started.
    func play() async throws {
        guard let session, !playing else { return }
        playing = true
        _ = try await store.recordPlaybackIntent(sessionID: session.id, positionMilliseconds: position, durationMilliseconds: duration,
                                                 baseline: generation, intentional: true, now: time)
    }

    /// Plays on for `seconds`, saving every `every` seconds (five, as the coordinator does; a test may save less often to
    /// cover long listening quickly: the contribution follows the positions, not the number of saves).
    func listen(_ seconds: Int, every: Int = 5) async throws {
        guard let session, playing else { return }
        var left = seconds
        while left > 0 {
            let step = min(every, left)
            left -= step
            time = time.addingTimeInterval(Double(step))
            position += Int32(step) * 1_000
            _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: position, durationMilliseconds: duration,
                                                                                    status: .playing), now: time)
        }
    }

    func pause() async throws {
        guard let session else { return }
        playing = false
        time = time.addingTimeInterval(1)
        _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: position, durationMilliseconds: duration,
                                                                                status: .paused), now: time, synchronize: true)
    }

    /// An intentional seek: the engine moves, then the seek hook (a takeover when a superseding claim waits).
    func seek(to target: Int32) async throws {
        guard let session else { return }
        let before = position
        position = target
        if let rebased = try await store.recordSeekIntent(sessionID: session.id, from: before, to: target, wantsPlayback: playing, now: time) {
            self.session = rebased
        }
    }

    /// The player's position moves to an adopted remote one (the coordinator's paused seek).
    func adopt() async throws -> Int32? {
        guard let episodeID = session?.episodeID, !playing else { return nil }
        guard let adopted = try await store.adoptRemotePosition(episodeID: episodeID, now: time) else { return nil }
        position = adopted
        session = try await store.playbackSession()
        return adopted
    }

    /// A switch, skip or natural end: the final save, then `endPlayback` with the device's settings.
    @discardableResult
    func end(_ reason: PlaybackEndReason, at final: Int32? = nil) async throws -> PlaybackEndResult? {
        guard let session else { return nil }
        if let final { position = final }
        playing = false
        time = time.addingTimeInterval(1)
        if engineLoaded {
            _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: position, durationMilliseconds: duration,
                                                                                    status: .paused), now: time)
        }
        var preferences = PlaybackEndPreferences()
        preferences.smartMarkAsPlayedSeconds = smartSeconds
        preferences.skipKeepsEpisode = skipKeepsEpisode
        let result = try await store.endPlayback(sessionID: session.id, reason: reason, preferences: preferences, now: time,
                                                 continueQueue: false)
        self.session = nil
        return result
    }

    /// The player of a store reopened after a relaunch (the coordinator's passive `restore()`: no fact, no engine).
    static func restored(_ store: FeedLibraryStore, time: Date? = nil, duration: Int32 = 600_000) async throws -> StorePlayer {
        let player = time.map { StorePlayer(store, time: $0) } ?? StorePlayer(store, realTime: ())
        player.duration = duration
        player.session = try await store.playbackSession()
        if let episode = player.session?.episodeID {
            player.position = try await store.episode(id: episode)?.userState.positionMilliseconds ?? 0
        }
        return player
    }

    /// The app is closed and opened again: a new store on the same file, the player restored paused (no fact).
    func relaunch(_ url: URL) async throws -> StorePlayer {
        try await store.close()
        let reopened = StorePlayer(try FeedLibraryStore(url: url), time: time.addingTimeInterval(60))
        reopened.session = try await reopened.store.playbackSession()
        if let episode = reopened.session?.episodeID {
            reopened.position = try await reopened.store.episode(id: episode)?.userState.positionMilliseconds ?? 0
        }
        reopened.duration = duration
        return reopened
    }
}

extension FeedLibraryStore {
    func liveSyncSessionStateForTesting(_ local: UUID) throws -> String? { try liveSyncSession(local: local)?.state.rawValue }

    func syncSessionsForTesting() throws -> [ServerSyncSession] { try syncSessions() }

    /// The podcast takes another live generation (as a resubscription elsewhere gives it).
    func setLiveGenerationForTesting(podcast: String, generation: String) throws {
        try database.execute("UPDATE ntp_podcasts SET live_generation = ? WHERE podcast_id = ?", [.text(generation), .text(podcast)])
    }

    /// Whether earlier playback writes owe recording (`ntp_library.export_owed`).
    func serverExportOwedForTesting() throws -> Bool { try database.scalar("SELECT export_owed FROM ntp_library WHERE id = 1") == 1 }

    func transitionStateForTesting() throws -> ServerTransitionState { try transitionState() }

    /// Retires every outbox entry as the server's commit consuming its slot would, with these records (a stand-in
    /// for a pull, for unit tests without a server).
    func retireOutboxForTesting(records: [ServerRecord] = [], outcomes: [String: String] = [:], accepted: [ServerAcceptedEntry] = [],
                                history: ServerHistoryOracle? = nil) throws -> ServerUnitResult {
        guard let context = serverContext else { throw ServerRecordingError.notAServerLibrary }
        let live = try serverExchangeState().cursor
        let log = live?.logID ?? ContractIdentity.randomUUID()
        let seq = (live?.seq ?? 0) + 1
        if live == nil { try setCursorForTesting(try SyncCursor(logID: log, epoch: 1, seq: 0, digest: String(repeating: "0", count: 64))) }
        let slots = try database.rows("SELECT install_seq, op_id FROM ntp_outbox ORDER BY install_seq").map { row in
            try ServerSlot(["install_id": .string(context.installID), "install_seq": .integer(row[0].integer ?? 0), "op_id": .string(row[1].text ?? ""),
                            "result": .string(outcomes[row[1].text ?? ""] ?? "accepted")])
        }
        let cursor = try SyncCursor(logID: log, epoch: 1, seq: seq, digest: ContractIdentity.sha256Hex(Array("\(log)\(seq)".utf8)))
        return try applyServerUnit(ServerUnitInput(commit: ServerCommit(epoch: 1, seq: seq, accepted: accepted, slots: slots, records: records),
                                                   cursor: cursor, watermark: nil, now: 1_760_000_000_000), history: history, maxWork: nil)
    }
}
