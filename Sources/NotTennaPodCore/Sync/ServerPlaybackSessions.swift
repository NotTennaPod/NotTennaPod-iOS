import Foundation

// MARK: - The playback journal (PROTOCOL §8)

/// One save of a sync session (PROTOCOL §8, §6.10): a random ID, the session's next save index, the baseline in force,
/// the position and Android's contribution (PROTOCOL §8.8), its time and the opening of the library that made it.
struct ServerSessionSave: Codable, Equatable, Sendable {
    /// An intentional resume's claim (PROTOCOL §8.1, §15.4): exported as a claiming checkpoint of this save,
    /// owed with it until it is recorded. Its op ID is fixed when the person pressed play.
    struct Claim: Codable, Equatable, Sendable {
        var op: String
        var observed: String?
        /// When it was decided, in the journal's order (`ServerTransitionState.sequence`).
        var sequence: Int64 = 0
        /// What the person's Play observed (PROTOCOL §8.1): the position and play-state provenance when it was
        /// journaled. The claiming checkpoint depends on exactly these, however late it is recorded.
        var dependencies: [String]?
    }

    var id: String
    var index: Int64
    var baseline: String
    var position: Int32
    var contribution: Int64
    var time: Int64
    var incarnation: String
    var claim: Claim?
}

/// A sync session (PROTOCOL §8): separate from the local `LibraryPlaybackSession`, which may map to several over its life.
/// Kept in `ntp_sessions.record`. The journal (saves, the export watermark's inputs, what is due) is written in the
/// playback write's own transaction; the recorder exports what is due inside its savepoint and moves the watermark
/// there, so a failed recording leaves the journal and its debt (PROTOCOL §15.2).
struct ServerSyncSession: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        /// Loaded, not yet played here: nothing recorded (PROTOCOL §8).
        case pending
        /// Started: its saves are journaled and exported.
        case open
        /// Ended (`end`), by this device or a seal at an adoption or takeover.
        case sealed
        /// Left without an end (a reload, a position reset, a load that found it open): it stands at its last export.
        case closed
    }
    /// Where the contribution restarts (PROTOCOL §8.2): a load's position and contribution.
    struct Base: Codable, Equatable, Sendable {
        var position: Int32
        var contribution: Int64
    }
    /// A checkpoint or end the recorder exported: what played time and cuts are computed from (PROTOCOL §8.8).
    struct Export: Codable, Equatable, Sendable {
        var op: String
        var ordinal: Int64
        var contribution: Int64
        /// Retired without effect (refused): it adds nothing on the server.
        var void: Bool?
    }
    /// A statistics cut of the session: the contribution at the greatest ordinal a reset covered (PROTOCOL §8).
    struct Cut: Codable, Equatable, Sendable {
        var op: String
        var ordinal: Int64
        var contribution: Int64
    }
    /// The session's end (PROTOCOL §8.4), decided when it happened; recorded or owed.
    struct End: Codable, Equatable, Sendable {
        var op: String
        var reason: String
        var completed: Bool
        var thresholdMs: Int64
        var removeFromQueue: Bool
        var history: Bool
        var time: Int64
        var dependencies: [String]
        var incarnation: String
        var recorded: Bool
        var sequence: Int64 = 0
    }

    var id: String
    var localSession: UUID
    var episodeID: Int64
    var incarnation: String
    var state: State
    /// The session's author for life (PROTOCOL §15.2): the main author, or the registration author of a draft session.
    var authorID: String?
    var registrationOp: String?
    /// The podcast and generation of a main-author session's start: every later fact names the same (PROTOCOL §8 rule 2).
    var podcastID: String?
    var generationID: String?
    var startOp: String
    var startRecorded = false
    var startSequence: Int64 = 0
    var startPosition: Int32
    var startTime: Int64 = 0
    var startDependencies: [String] = []
    var observedClaim: String?
    var baseline: String = ""
    var base: Base
    var saves: Int64 = 0
    var last: ServerSessionSave?
    /// Saves after the last export: the first, the last, and each owed claim with the save after it.
    var unexported: [ServerSessionSave] = []
    var exportedIndex: Int64 = 0
    var exportedAt: Int64 = 0
    /// An export of the save `exportDueIndex` is due (a pause, the minute, a flush), decided by that opening of the
    /// library, in the journal's order `exportDueSequence`.
    var exportDue: String?
    var exportDueTime: Int64 = 0
    var exportDueIndex: Int64 = 0
    var exportDueSequence: Int64 = 0
    var ordinal: Int64 = 0
    var lastOp: String?
    /// Its claims (PROTOCOL §8.1: on its writing path): the start, then each resume claim.
    var claims: [String] = []
    /// The latest recorded claim: what an ordinary export stands under.
    var recordedClaim: String?
    var exports: [Export] = []
    /// How many of `exports`, from the first, the server has retired (accepted or refused): exports retire in the order
    /// they were recorded, so C_acc is found from here without asking about every export still pending.
    var acceptedCount: Int?
    var end: End?
    var finalized = false
    var duration: Int32 = 0
    var cutAccepted: Cut?
    var cutPending: Cut?
    /// Why the server does not get this session's listening (PROTOCOL §6.13), nil while it does.
    var exportRefused: ExportRefusal?
    /// Kept on this device only: the contribution a later statistics reset here covered, and the time up to which a later
    /// history clear or removal here covered its history entries (PROTOCOL §8.8: local cuts cover local listening).
    var localCut: Int64?
    var localHistoryCut: Int64?

    /// `tooLarge`: an export is larger than the server accepts; nothing more of the session is recorded until an explicit
    /// retry (Synchronize now, Needs attention's "Try again"), and its listening stays here. `keptLocal`: the person chose
    /// "Keep only on this device": its unexported listening is this device's own, never exported, and local cuts cover it.
    enum ExportRefusal: String, Codable, Sendable {
        case tooLarge = "too_large"
        case keptLocal = "kept_local"
    }

    /// Whether what it journaled is owed to the server (a session kept on this device owes nothing).
    var owesServer: Bool { exportRefused != .keptLocal }

    init(localSession: UUID, episodeID: Int64, incarnation: String, start: Int32) {
        id = ContractIdentity.randomUUID()
        self.localSession = localSession; self.episodeID = episodeID; self.incarnation = incarnation
        state = .pending
        startOp = ContractIdentity.randomUUID()
        startPosition = max(0, start)
        base = Base(position: max(0, start), contribution: 0)
    }

    /// Journals a save (PROTOCOL §6.10) with Android's contribution from the session's accounting base (PROTOCOL §8.2, §8.8: forward
    /// displacement from the base, frozen below it; speed ignored).
    @discardableResult
    mutating func addSave(position: Int32, time: Int64, incarnation: String, claim: ServerSessionSave.Claim? = nil) -> ServerSessionSave {
        let position = max(0, position)
        let previous = last?.contribution ?? base.contribution
        let contribution = position > base.position ? base.contribution + Int64(position - base.position) : previous
        saves += 1
        let save = ServerSessionSave(id: ContractIdentity.randomUUID(), index: saves, baseline: baseline, position: position,
                                     contribution: contribution, time: time, incarnation: incarnation, claim: claim)
        last = save
        unexported.append(save)
        if unexported.count > 3 {
            let all = unexported, due = exportDue != nil ? exportDueIndex : -1
            unexported = all.indices.filter { index in
                index == 0 || index == all.count - 1 || all[index].claim != nil || all[index - 1].claim != nil || all[index].index == due
            }.map { all[$0] }
        }
        return save
    }

    /// A session whose episode can no longer be named (a local folder, a refused registration): nothing more of it is
    /// recorded, and it is closed.
    mutating func abandon() {
        state = .closed
        startRecorded = true
        unexported = []
        exportDue = nil
        end?.recorded = true
    }

    /// Whether the recorder has something to record for it.
    var hasDue: Bool {
        guard state != .pending else { return false }
        return !startRecorded || unexported.contains { $0.claim != nil } || (exportDue != nil && !unexported.isEmpty)
            || end.map { !$0.recorded } == true
    }

    /// C (PROTOCOL §8.8): the latest journaled contribution.
    var contribution: Int64 { state == .pending ? 0 : last?.contribution ?? 0 }

    /// C_acc: the contribution at the latest export the server has applied. Exports retire in the order they were
    /// recorded: from the retired prefix kept at retirement, only the next export is asked about while it is pending, so
    /// a save costs the same however many exports a long offline session holds.
    func acceptedContribution(isPending: (String) throws -> Bool) throws -> Int64 {
        var count = min(acceptedCount ?? 0, exports.count)
        while count < exports.count, try !isPending(exports[count].op) { count += 1 }
        for export in exports[..<count].reversed() where export.void != true { return export.contribution }
        return 0
    }

    /// The retired prefix after a commit retired some of this session's exports (`acceptedCount`).
    mutating func noteRetiredExports(isPending: (String) throws -> Bool) throws {
        var count = min(acceptedCount ?? 0, exports.count)
        while count < exports.count, try !isPending(exports[count].op) { count += 1 }
        if count != acceptedCount ?? 0 { acceptedCount = count }
    }

    /// K: the cut at the greater ordinal, accepted or pending (PROTOCOL §8.8), or a local cut of a session kept on this device.
    var effectiveCut: Int64 {
        let cut: Int64 = switch (cutAccepted, cutPending) {
        case (let a?, let p?): p.ordinal > a.ordinal ? p.contribution : a.contribution
        case (let a?, nil): a.contribution
        case (nil, let p?): p.contribution
        case (nil, nil): 0
        }
        return max(cut, localCut ?? 0)
    }

    /// An accepted statistics reset's cut of this session: the greatest of its exports in the reset's causal past (the
    /// server's coverage walk, PROTOCOL §8). Ordinals are monotone along the author's chain, so the first found from the end is
    /// the greatest. Returns whether the accepted cut moved.
    @discardableResult
    mutating func noteAcceptedCut(by reset: String, _ history: ServerHistoryOracle) throws -> Bool {
        for export in exports.reversed() where export.void != true {
            guard try history.isInPast(export.op, of: reset) else { continue }
            guard export.ordinal > cutAccepted?.ordinal ?? 0 else { return false }
            cutAccepted = Cut(op: reset, ordinal: export.ordinal, contribution: export.contribution)
            return true
        }
        return false
    }

    static func load(_ db: LibrarySQLite, _ condition: String, _ values: [LibrarySQLValue] = []) throws -> [ServerSyncSession] {
        let sessions = try db.rows("SELECT record FROM ntp_sessions WHERE \(condition) ORDER BY rowid", values).map { row in
            guard let data = row[0].data else { throw ServerRecordingError.corruptState("ntp_sessions") }
            return try JSONDecoder().decode(ServerSyncSession.self, from: data)
        }
        SQLWorkMeter.shared.noteSessionsDecoded(sessions.count)
        return sessions
    }

    static func load(_ db: LibrarySQLite, episode: Int64) throws -> [ServerSyncSession] {
        try load(db, "episode_id = ? AND state != 'pending'", [.integer(episode)])
    }
}

/// The pending transition (PROTOCOL §8.4): an exact reference, persisted with the selection, never a search.
struct ServerPendingTransition: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case finalize, leave }
    /// Its `transition_id`, given when the episode was loaded.
    var id: String
    var kind: Kind
    var episodeID: Int64
    /// `leave`: the podcast generation the episode was loaded under (PROTOCOL §8.4 `leave {episode, generation, observed_claim}`),
    /// which its `episode.leave` names whatever the live generation is when it is recorded; nil while the podcast's
    /// registration was pending at load (the leave then joins that registration's chain). A finalization names its
    /// session's start generation instead.
    var generation: String?
    /// `finalize`: the session.
    var session: String?
    /// `finalize`: the claim it completes under; `leave`: the claim observed at load, updated by adoption.
    var claim: String?
    /// The position the player took under a claim of another device (shown at load, or adopted): a later checkpoint of
    /// that claim moving the position is adopted too, while a seek the person makes while paused is not undone.
    var claimPosition: Int64?
    /// The provenance of an adopted claim (what a finalization or leave under it depends on).
    var claimDependencies: [String] = []
    /// The version of the episode's position record the player's position was last decided against: set at load,
    /// adoption, a takeover and a rebaseline; kept as stored across relaunches. Nil in a transition persisted before it.
    var observed: ServerObservedPosition?
    /// The newest listening known for the episode: the last played of every version a decision settled, never lower.
    /// A version of another lineage or generation is adopted only when its listening is newer.
    var listenedHighWater: Int64?
}

/// A version of an episode's position record (PROTOCOL §8.6): its lineage (log and epoch), generation, claim, sorted
/// provenance and the episode's last played. `settled` when a decision about it was taken (it was adopted, it is this
/// device's own claim, a rebaseline accepted it, or the player loaded its position from it); a version seen while this
/// device's own intent was pending is not settled and is reconsidered when that intent retires.
struct ServerObservedPosition: Codable, Equatable, Sendable {
    var logID: String?
    var epoch: Int64?
    var generation: String?
    var claim: String?
    var provenance: [String] = []
    var lastPlayed: Int64?
    var settled = true

    /// The same position record: lineage, claim and provenance. The episode's last played is a separate record: it is
    /// evidence of listening for another lineage's version, never a change of this one (a non-owning session's activity
    /// moves it while the position stands). `lastPlayed`: a mutation check's old rule.
    func sameVersion(as other: ServerObservedPosition, lastPlayed: Bool = false) -> Bool {
        sameLineage(as: other) && claim == other.claim && provenance == other.provenance && (!lastPlayed || self.lastPlayed == other.lastPlayed)
    }

    func sameLineage(as other: ServerObservedPosition) -> Bool {
        logID == other.logID && epoch == other.epoch && generation == other.generation
    }
}

/// A finalization or leave decided at a switch, skip or end (PROTOCOL §8.4), recorded or owed.
struct ServerTransitionFact: Codable, Equatable, Sendable {
    var sequence: Int64 = 0
    var op: String
    var transition: ServerPendingTransition
    var reason: String
    var position: Int32
    var completed: Bool
    var thresholdMs: Int64
    var removeFromQueue: Bool
    var time: Int64
    /// A leave's dependencies, fixed when it was decided (what the device had seen then): one recorded late (owed) is
    /// not ordered after what arrived meanwhile.
    var dependencies: [String]?
    /// Larger than the server accepts (PROTOCOL §6.13): kept due, never recorded until an explicit retry (`tooLarge`), or
    /// kept on this device for good (`keptLocal`). Its history entry stays this device's either way.
    var refused: ServerSyncSession.ExportRefusal?
    /// Kept on this device: the time up to which a later history clear or removal here covered its entry.
    var localHistoryCut: Int64?

    /// Whether its history entry shows (a kept one up to a local history cut does not).
    var showsHistory: Bool { refused != .keptLocal || localHistoryCut.map { time > $0 } ?? true }
}

/// `ntp_library.pending_transition`: the current transition, the transition facts owed, and the journal's order: every
/// fact the playback journal makes due takes the next `sequence`, and the recorder records them in that order, so a
/// pause's export comes before the resume that follows it whatever the clocks say.
struct ServerTransitionState: Codable, Equatable, Sendable {
    var current: ServerPendingTransition?
    var due: [ServerTransitionFact] = []
    var sequence: Int64 = 0

    mutating func next() -> Int64 {
        sequence += 1
        return sequence
    }
}

extension FeedLibraryStore {
    /// At most one checkpoint export a minute while playing (PROTOCOL §8).
    static let checkpointInterval: Int64 = 60_000

    // MARK: - Reading and writing the journal

    func syncSessions(_ condition: String = "1", _ values: [LibrarySQLValue] = []) throws -> [ServerSyncSession] {
        try ServerSyncSession.load(database, condition, values)
    }

    func syncSession(_ id: String) throws -> ServerSyncSession? { try syncSessions("session_id = ?", [.text(id)]).first }

    /// The live sync session of a local playback session: its pending or open one.
    func liveSyncSession(local: UUID) throws -> ServerSyncSession? {
        try syncSessions("local_session = ? AND state IN ('pending', 'open')", [.text(local.uuidString)]).last
    }

    func storeSyncSession(_ session: ServerSyncSession, _ execute: (String, [LibrarySQLValue]) throws -> Void) throws {
        try execute("INSERT INTO ntp_sessions(session_id, local_session, episode_id, author_id, incarnation, state, record) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(session_id) DO UPDATE SET local_session = excluded.local_session, episode_id = excluded.episode_id, author_id = excluded.author_id, incarnation = excluded.incarnation, state = excluded.state, record = excluded.record",
                    [.text(session.id), .text(session.localSession.uuidString), .integer(session.episodeID),
                     session.authorID.map(LibrarySQLValue.text) ?? .null, .text(session.incarnation), .text(session.state.rawValue),
                     .blob(try JSONEncoder().encode(session))])
    }

    func transitionState() throws -> ServerTransitionState {
        guard let data = try database.rows("SELECT pending_transition FROM ntp_library WHERE id = 1").first?.first?.data else { return .init() }
        return try JSONDecoder().decode(ServerTransitionState.self, from: data)
    }

    func storeTransitionState(_ state: ServerTransitionState, _ execute: (String, [LibrarySQLValue]) throws -> Void) throws {
        try execute("UPDATE ntp_library SET pending_transition = ? WHERE id = 1", [.blob(try JSONEncoder().encode(state))])
    }

    /// An export of the session's latest save is due, decided now by this opening, in the journal's order.
    func markExportDue(_ session: inout ServerSyncSession, now: Int64, _ transitions: inout ServerTransitionState) {
        guard let last = session.last, last.index > session.exportedIndex else { return }
        session.exportDue = playbackIncarnation
        session.exportDueTime = now
        session.exportDueIndex = last.index
        session.exportDueSequence = transitions.next()
        activeCapture?.playbackDue = true
    }

    /// The journal's own writes: in the playback write's transaction, outside the recorder's savepoint (PROTOCOL §15.2).
    var journal: (String, [LibrarySQLValue]) throws -> Void { { [database] sql, values in try database.execute(sql, values) } }

    /// An episode the server never sees: a local folder's (PROTOCOL §7.6), or a detached one (PROTOCOL §6.8).
    private func isLocalFolderEpisode(_ episodeID: Int64) throws -> Bool {
        guard let feed = try database.rows("SELECT feed_id FROM episodes WHERE id = ?", [.integer(episodeID)]).first?.first?.integer else { return false }
        return try storedHeader(feed)?.source.isLocalFeedSource == true || isDetachedFeed(feed)
    }

    func wireEpisode(local: Int64) throws -> String? {
        try database.rows("SELECT episode_id FROM ntp_episodes WHERE local_id = ?", [.integer(local)]).first?.first?.text
    }

    private func episodeOverlays(_ episodeID: Int64, projector: ServerProjector, property: String? = nil) throws -> (wire: String?, overlays: [ServerOverlayRow]) {
        let wire = try wireEpisode(local: episodeID)
        return (wire, try projector.overlays(entity: "episode", ids: (wire.map { [$0] } ?? []) + ["local-episode:\(episodeID)"], property: property))
    }

    /// The claim the episode's position is displayed under (PROTOCOL §6.8): a claim this library journaled and has not
    /// recorded yet (an owed start or resume), else the base record with the pending overlays.
    func displayedPositionClaim(_ episodeID: Int64) throws -> String? { try displayedPosition(episodeID).claim }

    /// The displayed claim and, when it is not one of this library's journaled claims, the position shown under it.
    func displayedPosition(_ episodeID: Int64) throws -> (claim: String?, position: Int64?) {
        guard let context = serverContext else { return (nil, nil) }
        var owed: (time: Int64, op: String)?
        for session in try ServerSyncSession.load(database, episode: episodeID) where session.owesServer {
            if !session.startRecorded, owed.map({ session.startTime >= $0.time }) ?? true { owed = (session.startTime, session.startOp) }
            for save in session.unexported { if let claim = save.claim, owed.map({ save.time >= $0.time }) ?? true { owed = (save.time, claim.op) } }
        }
        if let owed { return (owed.op, nil) }
        let projector = try unitProjector(context: context, now: 0)
        let (wire, overlays) = try episodeOverlays(episodeID, projector: projector)
        let state = try projector.positionState(episode: wire, overlays: overlays)
        return (state.claim, state.position)
    }

    /// The played time a save writes in a server library (PROTOCOL §8.8), nil for an episode the server never sees (a local
    /// folder, PROTOCOL §7.6), which keeps Android's arithmetic.
    /// `live`: the session a save just journaled, as it stands (not read back).
    func serverPlayedTime(_ episodeID: Int64, live: ServerSyncSession? = nil) throws -> Int64? {
        guard let context = serverContext, try !isLocalFolderEpisode(episodeID) else { return nil }
        let projector = try unitProjector(context: context, now: 0)
        // Only the base a pending statistics reset keeps: every save asks, and the episode's pending overlays grow with
        // each export of a long offline session.
        let (wire, overlays) = try episodeOverlays(episodeID, projector: projector, property: "played_time_base")
        return try projector.displayedPlayedTime(episode: wire, localID: episodeID, overlays: overlays, live: live)
    }

    // MARK: - Journal steps (inside the playback write's transaction, before the recorder)

    /// `beginPlayback` (PROTOCOL §8): a pending session for the load and the pending transition `leave` with the claim the
    /// episode's position is displayed under. A re-begin (the `.ready` handler's new local session, or the same episode
    /// loaded again before any playback) moves the pending session to the new local session and changes nothing else.
    /// Every open session is closed locally first, its unexported save exported (a reload consumes the transition
    /// without completion, PROTOCOL §8).
    func journalPlaybackLoad(previous: LibraryPlaybackSession?, session: LibraryPlaybackSession, now: Int64) throws {
        guard serverContext != nil else { return }
        var transitions = try transitionState()
        if try isLocalFolderEpisode(session.episodeID) {
            try database.execute("DELETE FROM ntp_sessions WHERE state = 'pending'")
            transitions.current = nil
            try storeTransitionState(transitions, journal)
            return
        }
        if let previous, var pending = try liveSyncSession(local: previous.id), pending.state == .pending, pending.episodeID == session.episodeID {
            pending.localSession = session.id
            pending.startPosition = session.startPositionMilliseconds
            pending.base = .init(position: max(0, session.startPositionMilliseconds), contribution: 0)
            try storeSyncSession(pending, journal)
            if transitions.current?.episodeID != session.episodeID {
                transitions.current = try loadedTransition(session.episodeID)
                try storeTransitionState(transitions, journal)
            }
            return
        }
        try database.execute("DELETE FROM ntp_sessions WHERE state = 'pending'")
        for var open in try syncSessions("state = 'open'") {
            markExportDue(&open, now: now, &transitions)
            open.state = .closed
            try storeSyncSession(open, journal)
        }
        try storeSyncSession(ServerSyncSession(localSession: session.id, episodeID: session.episodeID, incarnation: playbackIncarnation,
                                               start: session.startPositionMilliseconds), journal)
        transitions.current = try loadedTransition(session.episodeID)
        try storeTransitionState(transitions, journal)
        try pruneSyncSessions(keeping: transitions)
    }

    /// The pending `leave` of a newly loaded episode (PROTOCOL §8.4), with the claim its position is displayed under and the
    /// baseline the loaded position was decided against: settled when the position came from the record, not when
    /// this device's own pending intent supplied it.
    private func loadedTransition(_ episodeID: Int64) throws -> ServerPendingTransition {
        let shown = try displayedPosition(episodeID)
        var observed = try positionVersion(episodeID)
        // Settled only when the loaded position is this version's: not under pending own intent (the local position was
        // loaded), and not while a recovery fence shows another image (a held position, a base not installed), unless
        // that image is this version's own claim and position.
        var fromRecord = try !pendingOwnPositionIntent(episodeID)
        if fromRecord, !adoptionFaults.contains(.settleFencedLoad), let wire = try wireEpisode(local: episodeID), try positionFenced(wire: wire) {
            let raw = try database.rows("SELECT value FROM ntp_records WHERE entity = 'episode' AND id = ? AND field_group = 'position'", [.text(wire)])
                .first?.first?.data.map { try ContractJSON.decode($0) }
            fromRecord = raw?["claim_id"]?.stringValue == shown.claim && raw?["position"]?.integerValue == shown.position
        }
        observed?.settled = fromRecord
        // Only a settled version's listening moves the high-water mark; an unsettled one is weighed when it is decided.
        let recordListening = fromRecord || adoptionFaults.contains(.highWaterFromUnsettledLoad) ? observed?.lastPlayed ?? 0 : 0
        let high = max(recordListening, try ownListening(episodeID))
        return .init(id: ContractIdentity.randomUUID(), kind: .leave, episodeID: episodeID, generation: try loadedGeneration(episodeID),
                     claim: shown.claim, claimPosition: shown.position, observed: observed, listenedHighWater: high)
    }

    /// The live generation of the episode's podcast as it is loaded (PROTOCOL §8.4), nil while its registration is pending.
    private func loadedGeneration(_ episodeID: Int64) throws -> String? {
        try database.rows("SELECT p.live_generation FROM ntp_podcasts p JOIN episodes e ON e.feed_id = p.feed_id WHERE e.id = ? AND p.live_generation IS NOT NULL AND p.pinned_removal = 0",
                          [.integer(episodeID)]).first?.first?.text
    }

    /// Sessions nothing needs any more: ended or closed, nothing due, every export retired and no pending cut. The
    /// server's record then holds what they added, so `others` (PROTOCOL §8.8) counts them exactly as before.
    private func pruneSyncSessions(keeping transitions: ServerTransitionState) throws {
        if adoptionFaults.contains(.keepAcknowledgedSessions) { return }
        let kept = Set([transitions.current?.session].compactMap { $0 } + transitions.due.compactMap(\.transition.session))
        for session in try syncSessions("state IN ('sealed', 'closed')") where !kept.contains(session.id) && !session.hasDue {
            guard session.cutPending == nil, session.exportedIndex == session.last?.index ?? 0 else { continue }
            let ops = [session.startOp] + session.exports.suffix(1).map(\.op)
            guard try database.scalar("SELECT (SELECT count(*) FROM ntp_outbox WHERE op_id IN (SELECT value FROM json_each(?))) + (SELECT count(*) FROM ntp_drafts WHERE op_id IN (SELECT value FROM json_each(?)))",
                                      [.text(ContractJSON.array(ops.map(ContractJSON.string)).canonicalText),
                                       .text(ContractJSON.array(ops.map(ContractJSON.string)).canonicalText)]) == 0 else { continue }
            try database.execute("DELETE FROM ntp_sessions WHERE session_id = ?", [.text(session.id)])
        }
    }

    /// The intentional play hook (PROTOCOL §8): a pending session starts at the position playback
    /// starts from, under the load's baseline; an open session of this opening journals the resume's save with its
    /// claim. The pending transition becomes `finalize` under the latest claim.
    func journalPlaybackIntent(local: UUID, position: Int32, duration: Int32, baseline: UUID, intentional: Bool, now: Int64) throws -> Bool {
        // A claim needs the person's Play here (see `recordPlaybackIntent`).
        guard intentional, var session = try liveSyncSession(local: local) else { return false }
        var transitions = try transitionState()
        if duration > 0 { session.duration = duration }
        switch session.state {
        case .pending:
            session.state = .open
            session.incarnation = playbackIncarnation
            session.startPosition = max(0, position)
            session.startTime = now
            session.exportedAt = now
            session.baseline = baseline.uuidString.lowercased()
            if session.observedClaim == nil { session.observedClaim = try displayedPositionClaim(session.episodeID) }
            // What the Play observed, fixed now: an owed start recorded later never depends on what arrived meanwhile.
            for dependency in try observedProvenance(session.episodeID) where !session.startDependencies.contains(dependency) {
                session.startDependencies.append(dependency)
            }
            session.claims = [session.startOp]
            session.startSequence = transitions.next()
            session.addSave(position: position, time: now, incarnation: playbackIncarnation)
        case .open where session.incarnation == playbackIncarnation:
            let claim = ServerSessionSave.Claim(op: ContractIdentity.randomUUID(), observed: try displayedPositionClaim(session.episodeID),
                                                sequence: transitions.next(), dependencies: try observedProvenance(session.episodeID))
            session.addSave(position: position, time: now, incarnation: playbackIncarnation, claim: claim)
            session.claims.append(claim.op)
        default:
            return false
        }
        let same = transitions.current?.episodeID == session.episodeID ? transitions.current : nil
        transitions.current = .init(id: same?.id ?? ContractIdentity.randomUUID(), kind: .finalize, episodeID: session.episodeID,
                                    session: session.id, claim: session.claims.last, observed: same?.observed,
                                    listenedHighWater: same?.listenedHighWater)
        try storeSyncSession(session, journal)
        try storeTransitionState(transitions, journal)
        activeCapture?.playbackDue = true
        return true
    }

    /// What a Play observes (PROTOCOL §8.1): the episode's position and play-state provenance as it stands when the
    /// intent is journaled. A start or resume claim depends on these; the recorder never reads them again, so a claim
    /// recorded late (owed) is not ordered after listening that arrived after the person pressed Play.
    func observedProvenance(_ episodeID: Int64) throws -> [String] {
        guard let wire = try wireEpisode(local: episodeID) else { return [] }
        return try provenance(entity: "episode", id: wire, groups: ["position", "play_state"])
    }

    /// What a playback save is (PROTOCOL §8): one the server never sees (a standalone library, a local folder's episode), a
    /// save of the sync session an intentional play opened in this opening (listening), or a save no Play here started
    /// (a pending session: a paused load, an adopted position, a Cast receiver no Play here started; or an earlier
    /// opening's session). Read once per save, with the live session (debt a: a long session's record is decoded once).
    enum PlaybackSaveKind {
        case unsynced
        case listening(ServerSyncSession)
        case notListening(ServerSyncSession?)

        var listens: Bool { if case .notListening = self { false } else { true } }
    }

    func playbackSaveKind(local: UUID, episodeID: Int64) throws -> PlaybackSaveKind {
        guard serverContext != nil, try !isLocalFolderEpisode(episodeID) else { return .unsynced }
        let session = try liveSyncSession(local: local)
        guard let session, session.state == .open, session.episodeID == episodeID, session.incarnation == playbackIncarnation else {
            return .notListening(session)
        }
        return .listening(session)
    }

    /// A playback save (PROTOCOL §8.2): an open session journals it, with an export due at a pause, a stop, a timeline reset or
    /// once a minute; a timeline reset rebases the accounting to position 0 with the current contribution. Returns the
    /// played time to save (PROTOCOL §8.8), nil where Android's arithmetic stays (standalone, local folders) or where the save is
    /// not listening.
    func journalPlaybackSave(_ kind: PlaybackSaveKind, episodeID: Int64, sample: PlaybackSample, now: Int64, synchronize: Bool,
                             resetsTimeline: Bool) throws -> Int64? {
        switch kind {
        case .unsynced:
            return nil
        case .listening(var session):
            let save = session.addSave(position: sample.positionMilliseconds, time: now, incarnation: playbackIncarnation)
            if sample.seekable, sample.durationMilliseconds > 0 { session.duration = sample.durationMilliseconds }
            if synchronize || resetsTimeline || now - session.exportedAt >= Self.checkpointInterval {
                var transitions = try transitionState()
                markExportDue(&session, now: now, &transitions)
                try storeTransitionState(transitions, journal)
            }
            if resetsTimeline { session.base = .init(position: 0, contribution: save.contribution) }
            try storeSyncSession(session, journal)
            return try serverPlayedTime(episodeID, live: session)
        case .notListening(let live):
            // No listening: a paused load's save, or a session no intentional play started (PROTOCOL §8). The position is the
            // device's own display and resume point; nothing marks it, and the played time stays as it stands.
            activeCapture?.playbackUnmarked.insert(episodeID)
            // Nothing before a Play here is listening here: the accounting of the session a Play here starts restarts
            // where this save leaves the player, so playback this phone did not start (a Cast receiver resumed by another
            // sender, or by itself after a seal) is never counted by it.
            if var pending = live, pending.state == .pending, pending.episodeID == episodeID,
               pending.base.position != max(0, sample.positionMilliseconds) {
                pending.startPosition = max(0, sample.positionMilliseconds)
                pending.base = .init(position: pending.startPosition, contribution: 0)
                try storeSyncSession(pending, journal)
            }
            return nil
        }
    }

    /// Whether a save of this local session at `now` exports (PROTOCOL §8.2): the minute's export is a durable transaction.
    func playbackExportDue(local: UUID, now: Int64) throws -> Bool {
        guard serverContext != nil, let session = try liveSyncSession(local: local), session.state == .open,
              session.incarnation == playbackIncarnation else { return false }
        return now - session.exportedAt >= Self.checkpointInterval
    }

    /// `endPlayback` (PROTOCOL §8.4): the pending transition, an exact reference. An open session of this opening ends; a
    /// session ended by an adoption or opened before a relaunch is finalized; an episode loaded and never played here
    /// is left (`episode.leave`, PROTOCOL §8.4). The recorder reports `endPlayback`'s decisions; it never re-decides them.
    func journalPlaybackEnd(local: UUID, episodeID: Int64, reason: PlaybackEndReason, completed: Bool, removeFromQueue: Bool,
                            thresholdMs: Int64, position: Int32, now: Int64) throws {
        guard serverContext != nil else { return }
        try database.execute("DELETE FROM ntp_sessions WHERE state = 'pending' AND local_session = ?", [.text(local.uuidString)])
        var transitions = try transitionState()
        guard let transition = transitions.current, transition.episodeID == episodeID else { return }
        transitions.current = nil
        let reasonText = switch reason { case .ended: "ended"; case .skipped: "skipped"; case .switched: "switched" }
        switch transition.kind {
        case .finalize:
            guard let id = transition.session, var session = try syncSession(id) else { break }
            if session.state == .open && session.incarnation == playbackIncarnation {
                session.end = .init(op: ContractIdentity.randomUUID(), reason: reasonText, completed: completed, thresholdMs: thresholdMs,
                                    removeFromQueue: removeFromQueue, history: true, time: now, dependencies: [],
                                    incarnation: playbackIncarnation, recorded: false, sequence: transitions.next())
                session.state = .sealed
            } else if !session.finalized {
                // A session of an earlier opening exports what it journaled first (passively), then is finalized.
                if session.end == nil { markExportDue(&session, now: now, &transitions) }
                session.finalized = true
                if session.state == .open { session.state = .closed }
                transitions.due.append(.init(sequence: transitions.next(), op: ContractIdentity.randomUUID(), transition: transition,
                                             reason: reasonText, position: position, completed: completed, thresholdMs: thresholdMs,
                                             removeFromQueue: removeFromQueue, time: now))
            } else { break }
            try storeSyncSession(session, journal)
        case .leave:
            var dependencies = transition.claimDependencies
            for dependency in try observedProvenance(episodeID) where !dependencies.contains(dependency) { dependencies.append(dependency) }
            transitions.due.append(.init(sequence: transitions.next(), op: ContractIdentity.randomUUID(), transition: transition,
                                         reason: reasonText, position: position, completed: completed, thresholdMs: thresholdMs,
                                         removeFromQueue: removeFromQueue, time: now, dependencies: dependencies))
        }
        try storeTransitionState(transitions, journal)
        activeCapture?.playbackDue = true
    }

    /// `resetPlaybackPosition` (PROTOCOL §8): the episode's sessions export their unexported save and close locally; the
    /// pending transition is cleared.
    func journalPositionReset(episodeID: Int64, now: Int64) throws {
        guard serverContext != nil else { return }
        try database.execute("DELETE FROM ntp_sessions WHERE state = 'pending' AND episode_id = ?", [.integer(episodeID)])
        var transitions = try transitionState()
        for var session in try syncSessions("state = 'open' AND episode_id = ?", [.integer(episodeID)]) {
            markExportDue(&session, now: now, &transitions)
            session.state = .closed
            try storeSyncSession(session, journal)
        }
        if transitions.current?.episodeID == episodeID { transitions.current = nil }
        try storeTransitionState(transitions, journal)
    }

    /// Flush before cuts (PROTOCOL §8.2): every open session's unexported save is exported before a history removal, a history
    /// clear or a statistics reset, which then depends on the whole frontier.
    func journalFlushOpenSessions(now: Int64, episodes: Set<Int64>? = nil) throws {
        let sessions = try syncSessions("state = 'open'").filter { !$0.unexported.isEmpty && episodes?.contains($0.episodeID) != false }
        guard !sessions.isEmpty else { return }
        var transitions = try transitionState()
        for var session in sessions {
            markExportDue(&session, now: now, &transitions)
            try storeSyncSession(session, journal)
        }
        try storeTransitionState(transitions, journal)
    }

    /// The restart export (PROTOCOL §8.2, §6.10): an open session of an earlier opening exports its unexported save, passively,
    /// before anything else of this opening is recorded.
    func journalRestartExport(now: Int64) throws {
        let sessions = try syncSessions("state = 'open' AND incarnation != ?", [.text(playbackIncarnation)])
            .filter { !$0.unexported.isEmpty && $0.exportDue == nil }
        guard !sessions.isEmpty else { return }
        var transitions = try transitionState()
        for var session in sessions {
            markExportDue(&session, now: now, &transitions)
            try storeSyncSession(session, journal)
        }
        try storeTransitionState(transitions, journal)
    }
}

// MARK: - Recording what the journal made due (inside the recorder's savepoint)

extension FeedLibraryStore {
    /// Where a session's facts go (PROTOCOL §15.2): the author it started under for its whole life, as a draft while its
    /// registration is pending, else as an outbox fact naming the podcast and generation it started under.
    private func sessionBinding(_ session: inout ServerSyncSession, _ s: RecordingSession) throws -> PodcastBinding? {
        if session.authorID == nil {
            guard let feed = try feedOf(session.episodeID, s) else { return nil }
            let binding = try registeredBinding(feed, s)
            switch binding {
            case .registered(let podcast, let generation):
                session.authorID = s.context.mainAuthor; session.podcastID = podcast; session.generationID = generation
            case .pending(let op, let author):
                session.authorID = author; session.registrationOp = op
            case .localFolder, .unregistered:
                return nil
            }
            return binding
        }
        if let op = session.registrationOp, let author = session.authorID {
            guard let row = try database.rows("SELECT state, podcast_id, generation_id FROM ntp_registrations WHERE op_id = ?", [.text(op)]).first else { return nil }
            if row[0].text == "pending" { return .pending(op: op, author: author) }
            guard let podcast = row[1].text, let generation = row[2].text else { return nil }
            return .registered(podcast: podcast, generation: generation)
        }
        guard let podcast = session.podcastID, let generation = session.generationID else { return nil }
        return .registered(podcast: podcast, generation: generation)
    }

    /// One playback fact: a main-author or session-author outbox fact, or a draft on a pending registration's chain.
    /// Returns the overlay entity it named, nil when the episode can no longer be named (nothing is recorded).
    private func emitPlayback(_ s: RecordingSession, binding: PodcastBinding, authorID: String?, episodeID: Int64, type: String,
                              opID: String, clientTime: Int64, dependencies: [String], provenanceGroups: [String] = [],
                              payload: (ContractJSON) -> ContractObject, overlays: (String) -> [ServerOverlay]) throws -> String? {
        guard let reference = try episodeReference(episodeID, binding: binding, s) else { return nil }
        switch binding {
        case .registered:
            guard let entity = reference.target["entity"]?.stringValue, let id = reference.target["id"]?.stringValue else { return nil }
            let target = ServerFactTarget(entity: entity, id: id, generation: reference.target["generation"]?.stringValue)
            var deps = dependencies + (try provenance(entity: "episode", id: id, groups: provenanceGroups))
            if authorID == nil || authorID == s.context.mainAuthor { deps += try latestRegistrationFacts(on: [target], s) }
            try s.writer.appendFact(type: type, targets: [target], payload: payload(reference.ref), dependencies: deps,
                                    overlays: overlays(reference.entityID), clientTime: clientTime, now: s.now,
                                    authorID: authorID, opID: opID)
        case .pending(let registration, let author):
            let template: ContractJSON = ["type": .string(type), "targets": [reference.target], "payload": .object(payload(reference.ref)),
                                          "secret_ids": []]
            try s.writer.appendDraft(registrationOp: registration, authorID: author, type: type, template: template,
                                     dependencies: dependencies, overlays: overlays(reference.entityID), clientTime: clientTime,
                                     now: s.now, opID: opID)
        case .localFolder, .unregistered:
            return nil
        }
        return reference.entityID
    }

    private static func activityOverlays(_ entity: String, time: Int64) -> [ServerOverlay] {
        [ServerOverlay(entity: "episode", id: entity, property: "play_state", kind: .dismiss, value: nil),
         ServerOverlay(entity: "episode", id: entity, property: "last_played", kind: .activity, value: .integer(time)),
         ServerOverlay(entity: "episode", id: entity, property: "history", kind: .activity, value: .integer(time)),
         ServerOverlay(entity: "episode", id: entity, property: "played_time", kind: .contribution, value: nil)]
    }

    private static func positionOverlay(_ entity: String, position: Int32, claim: String?, claiming: Bool) -> ServerOverlay {
        ServerOverlay(entity: "episode", id: entity, property: "position", kind: claiming ? .claim : .sessionPosition,
                      value: ["position": .integer(Int64(position)), "claim": claim.map(ContractJSON.string) ?? .null])
    }

    /// What an end, finalization or leave shows (PROTOCOL §6.8): the history mark, the completion under its claim, a skip's
    /// queue removal.
    private static func transitionOverlays(_ entity: String, time: Int64, history: Bool, completed: Bool, claim: String?,
                                           removeFromQueue: Bool) -> [ServerOverlay] {
        var list: [ServerOverlay] = []
        if history { list.append(ServerOverlay(entity: "episode", id: entity, property: "history_mark", kind: .historyMark, value: .integer(time))) }
        if completed {
            list.append(ServerOverlay(entity: "episode", id: entity, property: "completion", kind: .completion,
                                      value: ["claim": claim.map(ContractJSON.string) ?? .null]))
        } else if removeFromQueue {
            list.append(ServerOverlay(entity: "episode", id: entity, property: "queue_membership", kind: .register, value: false))
        }
        return list
    }

    /// The `save` of an export (PROTOCOL §6.10): `first` only when it covers a new save; passive for a save of an earlier
    /// opening exported by this one (a restart or finalization's export), never for a decision recorded late.
    private static func saveObject(_ save: ServerSessionSave, first: String?, decidedIn incarnation: String) -> ContractJSON {
        var object: ContractObject = ["id": .string(save.id), "index": .integer(save.index), "baseline": .string(save.baseline),
                                      "passive": .bool(save.incarnation != incarnation)]
        if let first { object["first"] = .string(first) }
        return .object(object)
    }

    /// Records every session start, claim, checkpoint and end, finalization and leave the playback journal made due,
    /// in the order they were decided (PROTOCOL §8): on each author's chain a session's facts follow its start, a seal comes
    /// before the takeover that follows it, a finalization after its session's last export. Called first in every
    /// recording but a remote one, so what an earlier write owes is recorded before anything later (PROTOCOL §8.1).
    /// `episode`: only that episode's sessions and transitions (`exportJournalBeforeDetach`).
    func recordPlaybackDue(_ s: RecordingSession, episode: Int64? = nil) throws {
        let owed = try episode == nil && database.scalar("SELECT export_owed FROM ntp_library WHERE id = 1") == 1
        guard s.capture.playbackDue || owed else { return }
        // Only sessions bound to the author and generation they were played under, for one episode: nothing registers.
        // A session the server refused, or kept on this device, records nothing (PROTOCOL §6.13).
        var sessions = try (episode.map { try syncSessions("state != 'pending' AND episode_id = ? AND author_id IS NOT NULL", [.integer($0)]) }
            ?? syncSessions("state != 'pending'")).filter { $0.hasDue && $0.exportRefused == nil }
        var transitions = try transitionState()
        enum Item { case start(Int), claim(Int, Int64), checkpoint(Int), end(Int), transition(Int) }
        // In the order the journal decided them (`ServerTransitionState.sequence`); within one decision a start before
        // its session's exports, an export before an end, sessions before transitions.
        var items: [(sequence: Int64, phase: Int, item: Item)] = []
        for (index, session) in sessions.enumerated() {
            if !session.startRecorded { items.append((session.startSequence, 0, .start(index))) }
            for save in session.unexported { if let claim = save.claim { items.append((claim.sequence, 1, .claim(index, save.index))) } }
            if session.exportDue != nil, !session.unexported.isEmpty { items.append((session.exportDueSequence, 2, .checkpoint(index))) }
            if let end = session.end, !end.recorded { items.append((end.sequence, 3, .end(index))) }
        }
        for (index, fact) in transitions.due.enumerated() where episode.map({ episode in
            fact.transition.episodeID == episode && (fact.transition.kind != .finalize || sessions.contains { $0.id == fact.transition.session })
        }) ?? true {
            items.append((fact.sequence, 4, .transition(index)))
        }
        items.sort { ($0.sequence, $0.phase) < ($1.sequence, $1.phase) }
        // Listening the recorded facts represent needs no mark any more: an export of a session's
        // latest save represents its listening fields; an end, finalization or leave everything, its queue change too.
        var listening = Set<Int64>(), everything = Set<Int64>()
        // A fact too large for the server (PROTOCOL §6.13) is never numbered: its session records nothing more (its later
        // items are skipped) and keeps its listening here; the other sessions go on. Nothing of the refused fact was written
        // (the bound is checked before its first write).
        var refused = Set<Int>()
        var kept: [ServerTransitionFact] = []
        for entry in items {
            do {
                switch entry.item {
                case .start(let index):
                    guard !refused.contains(index) else { continue }
                    try recordStart(&sessions[index], s)
                case .claim(let index, let saveIndex):
                    guard !refused.contains(index) else { continue }
                    if try recordCheckpoint(&sessions[index], upTo: saveIndex, s) { listening.insert(sessions[index].episodeID) }
                case .checkpoint(let index):
                    guard !refused.contains(index) else { continue }
                    // The save it was due for (a pause's, the minute's), or the latest before it still unexported.
                    let due = sessions[index].exportDueIndex
                    if let save = sessions[index].unexported.last(where: { $0.index <= due }),
                       try recordCheckpoint(&sessions[index], upTo: save.index, s) {
                        listening.insert(sessions[index].episodeID)
                    }
                    sessions[index].exportDue = nil
                case .end(let index):
                    guard !refused.contains(index) else { continue }
                    if try recordEnd(&sessions[index], s) { everything.insert(sessions[index].episodeID) }
                case .transition(let index):
                    let fact = transitions.due[index]
                    // Refused (too large) or kept on this device: it stays due, this device's own, unrecorded.
                    if fact.refused != nil { kept.append(fact); continue }
                    // A finalization follows its session's last export: while that session's listening is refused it waits
                    // with it; a session kept on this device keeps every finalization of its own here, whenever it was made
                    // (before or after Keep, after a relaunch): this device's, never sent, its history kept as the session's.
                    if fact.transition.kind == .finalize, let id = fact.transition.session,
                       let refusal = try sessions.first(where: { $0.id == id })?.exportRefused ?? syncSession(id)?.exportRefused {
                        var waiting = fact
                        if refusal == .keptLocal { waiting.refused = .keptLocal }
                        kept.append(waiting)
                        continue
                    }
                    if try recordTransition(fact, sessions: sessions, s) { everything.insert(fact.transition.episodeID) }
                }
            } catch ServerRecordingError.factTooLarge(let type, let bytes) {
                switch entry.item {
                case .start(let index), .claim(let index, _), .checkpoint(let index), .end(let index):
                    try refuseExport(&sessions[index], type: type, bytes: bytes, s)
                    refused.insert(index)
                case .transition(let index):
                    // A leave or finalization alone too large: kept due as this device's (its history, completion and queue
                    // decision), never recorded until an explicit retry, and listed under Needs attention.
                    var fact = transitions.due[index]
                    fact.refused = .tooLarge
                    kept.append(fact)
                    try noteRefusedListening(id: fact.op, episode: fact.transition.episodeID, type: type, bytes: bytes, s)
                }
            }
        }
        // What was refused (or kept on this device) stays due, this device's own.
        if let episode { transitions.due = transitions.due.filter { $0.transition.episodeID != episode } + kept } else { transitions.due = kept }
        for session in sessions { try storeSyncSession(session, s.writer.execute) }
        try storeTransitionState(transitions, s.writer.execute)
        if owed {
            try s.writer.execute("UPDATE ntp_library SET export_owed = 0 WHERE id = 1")
            // The sync log says so once this write commits (PROTOCOL §15.5); a rolled-back recording recorded nothing.
            if !items.isEmpty { s.capture.afterCommit.append { $0.noteOwedPlaybackRecorded() } }
        }
        for episode in everything {
            try s.writer.execute("DELETE FROM ntp_local_playback WHERE episode_id = ?", [.integer(episode)])
        }
        for episode in listening.subtracting(everything) {
            try s.writer.execute("UPDATE ntp_local_playback SET fields = 0 WHERE episode_id = ? AND fields != 0", [.integer(episode)])
            try s.writer.execute("DELETE FROM ntp_local_playback WHERE episode_id = ? AND queue = 0", [.integer(episode)])
        }
    }

    /// A session export larger than the server accepts (PROTOCOL §6.13): the session records nothing more until an explicit
    /// retry, its listening stays on this device (shown, never lost), and Needs attention names the episode, with "Try
    /// again" and "Keep only on this device". The sync log says so once the write commits.
    private func refuseExport(_ session: inout ServerSyncSession, type: String, bytes: Int, _ s: RecordingSession) throws {
        session.exportRefused = .tooLarge
        try noteRefusedListening(id: session.id, episode: session.episodeID, type: type, bytes: bytes, s)
    }

    /// Needs attention's item for refused listening (a session, or a leave or finalization), by its episode.
    private func noteRefusedListening(id: String, episode: Int64, type: String, bytes: Int, _ s: RecordingSession) throws {
        var record: ContractObject = ["episode": .integer(episode)]
        if let title = try loadEpisode(episode)?.details.title { record["title"] = .string(title) }
        try s.writer.execute("INSERT INTO ntp_attention(id, kind, record, created_at) VALUES (?, 'listening_refused', ?, ?) ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, record = excluded.record",
                             [.text(id), .blob(try ContractJSON.object(record).canonicalData()), .integer(s.now)])
        s.capture.refusedExport = true
        s.capture.afterCommit.append { $0.noteServerDiagnostic("too_large", "\(ServerLogValue.type(type)) \(bytes) bytes: listening kept on this device") }
    }

    /// Before the player's episode is cut loose from the account (PROTOCOL §6.8): what its journal holds that no fact carries
    /// yet, listening saved before the removal, is exported now, each session under the author and generation it was played
    /// under (an unbound session under the generation the episode was loaded under), never a later one. A session that
    /// cannot be named so records nothing. Its facts are recorded as the recorder records any.
    /// Listening the server refused as too large (PROTOCOL §6.13) is tried once more here, under its own generation as the
    /// rest; still too large, it goes with the detached journal (`detachHeldEpisode`). What the person kept on this device
    /// stays unsent.
    /// `closed`: the generation the removal closed, for a session that was never bound.
    func exportJournalBeforeDetach(_ episodeID: Int64, closed: String?, now: Int64) throws {
        guard let context = serverContext else { return }
        var sessions = try syncSessions("state != 'pending' AND episode_id = ?", [.integer(episodeID)])
        var transitions = try transitionState()
        guard !sessions.isEmpty || transitions.due.contains(where: { $0.transition.episodeID == episodeID }) else { return }
        for index in sessions.indices where sessions[index].exportRefused == .tooLarge { sessions[index].exportRefused = nil }
        for index in transitions.due.indices where transitions.due[index].transition.episodeID == episodeID && transitions.due[index].refused == .tooLarge {
            transitions.due[index].refused = nil
        }
        let podcast = try database.rows("SELECT podcast_id FROM ntp_episodes WHERE local_id = ?", [.integer(episodeID)]).first?.first?.text
        let loaded = transitions.current.flatMap { $0.episodeID == episodeID ? $0.generation : nil } ?? closed
        for index in sessions.indices {
            if sessions[index].authorID == nil {
                guard let podcast, let loaded else { continue }
                sessions[index].authorID = context.mainAuthor
                sessions[index].podcastID = podcast
                sessions[index].generationID = loaded
            }
            if sessions[index].exportDue == nil { markExportDue(&sessions[index], now: now, &transitions) }
            try storeSyncSession(sessions[index], journal)
        }
        try storeTransitionState(transitions, journal)
        let capture = ChangeCapture(clientTime: Date(timeIntervalSince1970: Double(now) / 1_000))
        capture.playbackDue = true
        let s = RecordingSession(intent: .remote, capture: capture,
                                 writer: ServerOutboxWriter(database: database, context: context, failAfter: nil, factBound: factBoundOverride),
                                 clientTime: now, now: now)
        try recordPlaybackDue(s, episode: episodeID)
        if s.writer.writes > 0 { activeCapture?.afterCommit.append { $0.noteServerOutboxChanged() } }
    }

    /// `session.start {episode, session_id, start_position, activity: true, observed_claim?, duration?, baseline}` (PROTOCOL §8, §6.10
    /// ), under the author its binding gives it for life. A session whose episode can no longer be named records
    /// nothing more.
    private func recordStart(_ session: inout ServerSyncSession, _ s: RecordingSession) throws {
        guard let binding = try sessionBinding(&session, s) else { session.abandon(); return }
        let start = session
        let entity = try emitPlayback(s, binding: binding, authorID: session.authorID, episodeID: session.episodeID, type: "session.start",
                                      opID: session.startOp, clientTime: session.startTime, dependencies: session.startDependencies,
                                      payload: { ref in
            var payload: ContractObject = ["episode": ref, "session_id": .string(start.id), "start_position": .integer(Int64(start.startPosition)),
                                           "activity": true, "baseline": .string(start.baseline)]
            if let observed = start.observedClaim { payload["observed_claim"] = .string(observed) }
            if start.duration > 0 { payload["duration"] = .integer(Int64(start.duration)) }
            return payload
        }, overlays: { entity in
            Self.activityOverlays(entity, time: start.startTime)
                + [Self.positionOverlay(entity, position: start.startPosition, claim: start.startOp, claiming: true)]
        })
        guard entity != nil else { session.abandon(); return }
        session.startRecorded = true
        session.lastOp = session.startOp
        session.recordedClaim = session.startOp
    }

    /// `session.checkpoint` of the saves up to `index` (PROTOCOL §8, §6.10): a claiming one for a resume's save (PROTOCOL §8.1, §15.4
    /// ). Returns whether it covers the session's latest save.
    private func recordCheckpoint(_ session: inout ServerSyncSession, upTo index: Int64, _ s: RecordingSession) throws -> Bool {
        guard session.startRecorded, session.end?.recorded != true, session.state != .pending,
              let save = session.unexported.first(where: { $0.index == index }), index > session.exportedIndex,
              let first = session.unexported.first, let binding = try sessionBinding(&session, s) else { return false }
        let current = session, claim = save.claim
        let op = claim?.op ?? ContractIdentity.randomUUID()
        let standing = claim?.op ?? session.recordedClaim
        let entity = try emitPlayback(s, binding: binding, authorID: session.authorID, episodeID: session.episodeID, type: "session.checkpoint",
                                      opID: op, clientTime: save.time, dependencies: claim?.dependencies ?? [], payload: { ref in
            var payload: ContractObject = ["episode": ref, "session_id": .string(current.id), "ordinal": .integer(current.ordinal + 1),
                                           "position": .integer(Int64(save.position)), "contribution": .integer(save.contribution),
                                           "activity": true,
                                           "save": Self.saveObject(save, first: first.id, decidedIn: claim != nil ? save.incarnation : current.exportDue ?? save.incarnation)]
            if current.duration > 0 { payload["duration"] = .integer(Int64(current.duration)) }
            if let claim {
                payload["claim"] = true
                if let observed = claim.observed { payload["observed_claim"] = .string(observed) }
            }
            return payload
        }, overlays: { entity in
            Self.activityOverlays(entity, time: save.time)
                + [Self.positionOverlay(entity, position: save.position, claim: standing, claiming: claim != nil)]
        })
        guard entity != nil else { return false }
        session.ordinal += 1
        session.lastOp = op
        session.exports.append(.init(op: op, ordinal: session.ordinal, contribution: save.contribution))
        session.exportedIndex = save.index
        session.exportedAt = save.time
        session.unexported.removeAll { $0.index <= save.index }
        if claim != nil { session.recordedClaim = op }
        return save.index == session.last?.index
    }

    /// `session.end` (PROTOCOL §8): covering the latest save if it is unexported (then it is listening activity), with the
    /// decisions taken when it ended. Returns whether it was recorded.
    private func recordEnd(_ session: inout ServerSyncSession, _ s: RecordingSession) throws -> Bool {
        guard var end = session.end, !end.recorded, session.startRecorded, let last = session.last,
              let binding = try sessionBinding(&session, s) else {
            session.end?.recorded = true
            return false
        }
        // Owed claims are recorded first (their items come earlier); what is left is covered here.
        let fresh = last.index > session.exportedIndex
        let current = session, standing = session.recordedClaim
        let entity = try emitPlayback(s, binding: binding, authorID: session.authorID, episodeID: session.episodeID, type: "session.end",
                                      opID: end.op, clientTime: end.time, dependencies: end.dependencies, payload: { ref in
            var payload: ContractObject = ["episode": ref, "session_id": .string(current.id), "ordinal": .integer(current.ordinal + 1),
                                           "position": .integer(Int64(last.position)), "contribution": .integer(last.contribution),
                                           "activity": .bool(fresh), "reason": .string(end.reason), "completed": .bool(end.completed),
                                           "threshold_ms": .integer(end.thresholdMs), "remove_from_queue": .bool(end.removeFromQueue),
                                           "history": .bool(end.history),
                                           "save": Self.saveObject(last, first: fresh ? current.unexported.first?.id : nil, decidedIn: end.incarnation)]
            if current.duration > 0 { payload["duration"] = .integer(Int64(current.duration)) }
            return payload
        }, overlays: { entity in
            (fresh ? Self.activityOverlays(entity, time: end.time) : [])
                + [Self.positionOverlay(entity, position: last.position, claim: standing, claiming: false)]
                + Self.transitionOverlays(entity, time: end.time, history: end.history, completed: end.completed, claim: standing,
                                          removeFromQueue: end.removeFromQueue)
        })
        end.recorded = true
        session.end = end
        guard entity != nil else { return false }
        session.ordinal += 1
        session.lastOp = end.op
        session.exports.append(.init(op: end.op, ordinal: session.ordinal, contribution: last.contribution))
        session.exportedIndex = last.index
        session.unexported = []
        session.exportDue = nil
        return true
    }

    /// `session.finalize` of exactly the transition's session (PROTOCOL §8), or `episode.leave` of exactly its episode (PROTOCOL §8.4).
    private func recordTransition(_ fact: ServerTransitionFact, sessions: [ServerSyncSession], _ s: RecordingSession) throws -> Bool {
        let transition = fact.transition
        switch transition.kind {
        case .finalize:
            guard let id = transition.session, var session = try sessions.first(where: { $0.id == id }) ?? syncSession(id),
                  session.startRecorded, session.ordinal >= 1, let binding = try sessionBinding(&session, s) else { return false }
            let claim = transition.claim ?? session.recordedClaim ?? session.startOp
            return try emitPlayback(s, binding: binding, authorID: session.authorID, episodeID: session.episodeID, type: "session.finalize",
                                    opID: fact.op, clientTime: fact.time, dependencies: transition.claimDependencies, payload: { ref in
                ["episode": ref, "session_id": .string(session.id), "ordinal": .integer(session.ordinal), "claim_id": .string(claim),
                 "completed": .bool(fact.completed), "threshold_ms": .integer(fact.thresholdMs),
                 "remove_from_queue": .bool(fact.removeFromQueue), "history": true]
            }, overlays: { entity in
                Self.transitionOverlays(entity, time: fact.time, history: true, completed: fact.completed, claim: claim,
                                        removeFromQueue: fact.removeFromQueue)
            }) != nil
        case .leave:
            guard let feed = try feedOf(transition.episodeID, s) else { return false }
            var binding = try self.binding(feed, s)
            // The generation the episode was loaded under (PROTOCOL §8.4), not one the podcast took since.
            if case .registered(let podcast, _) = binding, let generation = transition.generation {
                binding = .registered(podcast: podcast, generation: generation)
            }
            return try emitPlayback(s, binding: binding, authorID: nil, episodeID: transition.episodeID, type: "episode.leave",
                                    opID: fact.op, clientTime: fact.time, dependencies: fact.dependencies ?? transition.claimDependencies,
                                    provenanceGroups: fact.dependencies == nil ? ["position", "play_state"] : [], payload: { ref in
                var payload: ContractObject = ["episode": ref, "transition_id": .string(transition.id), "reason": .string(fact.reason),
                                               "position": .integer(Int64(max(0, fact.position))), "completed": .bool(fact.completed),
                                               "threshold_ms": .integer(fact.thresholdMs), "remove_from_queue": .bool(fact.removeFromQueue),
                                               "history": true]
                if let claim = transition.claim { payload["observed_claim"] = .string(claim) }
                return payload
            }, overlays: { entity in
                Self.transitionOverlays(entity, time: fact.time, history: true, completed: fact.completed, claim: transition.claim,
                                        removeFromQueue: fact.removeFromQueue)
            }) != nil
        }
    }

    /// A statistics reset of this library (PROTOCOL §8.8): every session it covers gets its pending cut, the contribution at
    /// its latest export (the flush exported every open session first). A session whose facts wait on a pending
    /// registration is covered by that chain's deferred reset (PROTOCOL §15.2).
    /// A session kept on this device is cut locally at its whole contribution: the reset covers its listening here as the
    /// server's cut covers what it exported.
    func notePendingStatisticsCut(_ s: RecordingSession, main: String, deferred: [String: String]) throws {
        for var session in try syncSessions("state != 'pending'") {
            var changed = false
            if session.exportRefused == .keptLocal { session.localCut = session.contribution; changed = true }
            if session.startRecorded, let latest = session.exports.last(where: { $0.void != true }) {
                var op: String? = main
                if let registration = session.registrationOp,
                   try database.rows("SELECT state FROM ntp_registrations WHERE op_id = ?", [.text(registration)]).first?.first?.text == "pending" {
                    op = deferred[registration]
                }
                if let op { session.cutPending = .init(op: op, ordinal: latest.ordinal, contribution: latest.contribution); changed = true }
            }
            if changed { try storeSyncSession(session, s.writer.execute) }
        }
    }

    /// A history clear (`episode` nil) or removal here covers the history entries of sessions kept on this device up to
    /// `time`. Returns each covered session's earlier cut, for the removal's Undo.
    func noteLocalHistoryCut(_ s: RecordingSession, episode: Int64?, time: Int64) throws -> [(session: String, previous: Int64?)] {
        var covered: [(session: String, previous: Int64?)] = []
        for var session in try keptSessions(episode: episode) {
            covered.append((session.id, session.localHistoryCut))
            session.localHistoryCut = max(session.localHistoryCut ?? time, time)
            try storeSyncSession(session, s.writer.execute)
        }
        // A leave or finalization kept on this device, the same.
        var transitions = try transitionState()
        var changed = false
        for index in transitions.due.indices where transitions.due[index].refused == .keptLocal
            && (episode == nil || transitions.due[index].transition.episodeID == episode) {
            covered.append((transitions.due[index].op, transitions.due[index].localHistoryCut))
            transitions.due[index].localHistoryCut = max(transitions.due[index].localHistoryCut ?? time, time)
            changed = true
        }
        if changed { try storeTransitionState(transitions, s.writer.execute) }
        return covered
    }

    /// An Undo of a removal gives the kept sessions and transitions it covered their earlier history cut back.
    func restoreLocalHistoryCuts(_ s: RecordingSession, _ covered: [(session: String, previous: Int64?)]) throws {
        var transitions = try transitionState()
        var changed = false
        for (id, previous) in covered {
            if var session = try syncSession(id) {
                guard session.exportRefused == .keptLocal else { continue }
                session.localHistoryCut = previous
                try storeSyncSession(session, s.writer.execute)
            } else if let index = transitions.due.firstIndex(where: { $0.op == id && $0.refused == .keptLocal }) {
                transitions.due[index].localHistoryCut = previous
                changed = true
            }
        }
        if changed { try storeTransitionState(transitions, s.writer.execute) }
    }

    /// Leaves and finalizations the server refused as too large (of `episode`, or all).
    func refusedTransitions(episode: Int64? = nil) throws -> [ServerTransitionFact] {
        try transitionState().due.filter { $0.refused == .tooLarge && (episode == nil || $0.transition.episodeID == episode) }
    }

    /// Sessions kept on this device (of `episode`, or all).
    func keptSessions(episode: Int64? = nil) throws -> [ServerSyncSession] {
        let kept = "CAST(record AS TEXT) LIKE '%\"exportRefused\":\"kept_local\"%'"
        guard let episode else { return try syncSessions(kept) }
        return try syncSessions("episode_id = ? AND \(kept)", [.integer(episode)])
    }

    /// Sessions whose listening the server refused as too large (of `episode`, or all).
    func refusedSessions(episode: Int64? = nil) throws -> [ServerSyncSession] {
        let refused = "CAST(record AS TEXT) LIKE '%\"exportRefused\":\"too_large\"%'"
        guard let episode else { return try syncSessions(refused) }
        return try syncSessions("episode_id = ? AND \(refused)", [.integer(episode)])
    }

    /// In the unit that applies a commit (PROTOCOL §6.8): this library's session facts the commit refused add nothing
    /// (void); each statistics reset it accepts cuts this library's sessions at the greatest export in its causal past
    /// (the archive's coverage walk), and a retiring reset of this library is no longer pending.
    func noteRetiredPlayback(_ commit: ServerCommit, retired: [ServerUnitResult.Retired], history: ServerHistoryOracle?) throws {
        let sessionTypes: Set<String> = ["session.start", "session.checkpoint", "session.end", "session.finalize"]
        let resets = commit.accepted.filter { $0.type == "statistics.reset" && $0.isCausalNode }.map(\.opID)
        let retiredResets = Set(retired.filter { $0.type == "statistics.reset" }.map(\.opID))
        let voided = Set(retired.filter { sessionTypes.contains($0.type) && ["rejected", "not_applied", "op_id_conflict"].contains($0.outcome ?? "") }.map(\.opID))
        let retiredPlayback = Set(retired.filter { sessionTypes.contains($0.type) }.map(\.opID))
        guard !resets.isEmpty || !retiredResets.isEmpty || !retiredPlayback.isEmpty else { return }
        for var session in try syncSessions("state != 'pending'") {
            let before = session
            for index in session.exports.indices where voided.contains(session.exports[index].op) { session.exports[index].void = true }
            if session.exports.contains(where: { retiredPlayback.contains($0.op) }) {
                try session.noteRetiredExports { op in
                    try database.scalar("SELECT (SELECT count(*) FROM ntp_outbox WHERE op_id = ?) + (SELECT count(*) FROM ntp_drafts WHERE op_id = ?)",
                                        [.text(op), .text(op)]) > 0
                }
            }
            if let history {
                for reset in resets { try session.noteAcceptedCut(by: reset, history) }
            } else if let pending = session.cutPending, retiredResets.contains(pending.op), pending.ordinal > session.cutAccepted?.ordinal ?? 0 {
                session.cutAccepted = .init(op: pending.op, ordinal: pending.ordinal, contribution: pending.contribution)
            }
            if let pending = session.cutPending, retiredResets.contains(pending.op) { session.cutPending = nil }
            if session != before { try storeSyncSession(session, journal) }
        }
    }
}
