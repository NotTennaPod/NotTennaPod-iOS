import Foundation

/// The coordinator's three hooks (PROTOCOL §8, owner's answer 2), as store calls: intentional play and
/// resume, intentional seek, and adoption while paused. Each is one store transaction that never fails for sync
/// reasons (a failed recording is owed, PROTOCOL §15.2); in a standalone library each does nothing.
extension FeedLibraryStore {
    /// Intentional play or resume (PROTOCOL §8): the local session's pending sync session starts (`session.start`
    /// at the position playback starts from, under the load's baseline, the generation token); an open one records
    /// the resume's claim. Every claiming start or resume needs the person's Play here (`intentional`). Listening
    /// this phone did not start (a Cast receiver resumed by another sender, or by itself after a seal) is not
    /// recorded until a Play here: a restoration's or an automatic resumption's call records nothing and marks
    /// nothing, its saves keep the position on the device alone, and the next Play here starts a claiming session
    /// at the position playback then stands at. Returns whether anything was recorded.
    @discardableResult
    func recordPlaybackIntent(sessionID: UUID, positionMilliseconds: Int32, durationMilliseconds: Int32, baseline: UUID,
                              intentional: Bool, now: Date = Date()) throws -> Bool {
        guard serverContext != nil, intentional, let live = try liveSyncSession(local: sessionID),
              live.state == .pending || (live.state == .open && live.incarnation == playbackIncarnation) else { return false }
        let time = try milliseconds(now)
        // Durable: a start or claim is never lost (PROTOCOL §8.1).
        return try write(.playbackSave, durable: true, now: now) {
            try journalPlaybackIntent(local: sessionID, position: positionMilliseconds, duration: durationMilliseconds,
                                      baseline: baseline, intentional: intentional, now: time)
        }
    }

    /// Intentional seek (PROTOCOL §8.6): while playback is wanted and a superseding claim is known, the takeover in one
    /// transaction, without network: the playing session is sealed at a save of the pre-seek position (`session.end
    /// {reason: superseded}` depending on the claim), and a new session starts at the target observing it, under the
    /// same baseline; the local session's start moves to the target, so the jump is not counted as listening. Returns
    /// the rebased local session after a takeover, nil otherwise (the seek is then part of the open session).
    func recordSeekIntent(sessionID: UUID, from: Int32, to: Int32, wantsPlayback: Bool, now: Date = Date()) throws -> LibraryPlaybackSession? {
        guard serverContext != nil else { return nil }
        if !wantsPlayback {
            // A paused seek is the person's choice against what this phone knows now: a version already here (an adoption
            // still queued, or one found to be a rebaseline) is decided by it and never adopted over it later.
            try settleChosenVersion(sessionID: sessionID, now: now)
            return nil
        }
        guard let local = try playbackSession(), local.id == sessionID,
              let live = try liveSyncSession(local: sessionID), live.state == .open, live.incarnation == playbackIncarnation,
              case .adopt = try positionCheck(episodeID: local.episodeID) else { return nil }
        let time = try milliseconds(now)
        return try write(.playbackSave, durable: true, now: now) { () throws -> LibraryPlaybackSession? in
            guard var old = try liveSyncSession(local: sessionID), old.state == .open,
                  case .adopt(let waiting, let version) = try positionCheck(episodeID: local.episodeID) else { return nil }
            var transitions = try transitionState()
            let previous = transitions.current?.episodeID == local.episodeID ? transitions.current : nil
            old.addSave(position: from, time: time, incarnation: playbackIncarnation)
            old.end = .init(op: ContractIdentity.randomUUID(), reason: "superseded", completed: false, thresholdMs: 0, removeFromQueue: false,
                            history: false, time: time, dependencies: waiting.provenance, incarnation: playbackIncarnation, recorded: false,
                            sequence: transitions.next())
            old.state = .sealed
            try storeSyncSession(old, journal)
            var new = ServerSyncSession(localSession: sessionID, episodeID: local.episodeID, incarnation: playbackIncarnation, start: to)
            new.state = .open
            new.startTime = time
            new.exportedAt = time
            new.baseline = old.baseline
            new.duration = old.duration
            new.observedClaim = waiting.claim
            new.startDependencies = waiting.provenance
            for dependency in try observedProvenance(local.episodeID) where !new.startDependencies.contains(dependency) {
                new.startDependencies.append(dependency)
            }
            new.claims = [new.startOp]
            new.startSequence = transitions.next()
            new.addSave(position: to, time: time, incarnation: playbackIncarnation)
            try storeSyncSession(new, journal)
            let rebased = try rebasePlaybackSession(local, to: to)
            // The superseded version is settled: this takeover decided against it.
            transitions.current = .init(id: previous?.id ?? ContractIdentity.randomUUID(),
                                        kind: .finalize, episodeID: local.episodeID, session: new.id, claim: new.startOp,
                                        observed: version, listenedHighWater: try settledHighWater(previous, version, episodeID: local.episodeID))
            try storeTransitionState(transitions, journal)
            activeCapture?.playbackDue = true
            return rebased
        }
    }

    /// A paused seek's settlement (PROTOCOL §8.6): the version the paused player could adopt or rebaseline now becomes its
    /// settled baseline, so a later check finds nothing new in it and the person's position stands. Nothing is recorded.
    private func settleChosenVersion(sessionID: UUID, now: Date) throws {
        guard !adoptionFaults.contains(.ignoreChosenSeek), let local = try playbackSession(), local.id == sessionID else { return }
        let episodeID = local.episodeID
        switch try positionCheck(episodeID: episodeID) {
        case .none: return
        case .adopt, .rebaseline: break
        }
        try write(.playbackSave, durable: true, now: now) {
            let version: ServerObservedPosition
            switch try positionCheck(episodeID: episodeID) {
            case .none: return
            case .adopt(_, let seen), .rebaseline(let seen): version = seen
            }
            var transitions = try transitionState()
            guard var transition = transitions.current, transition.episodeID == episodeID else { return }
            transition.listenedHighWater = try settledHighWater(transition, version, episodeID: episodeID)
            transition.observed = version
            transitions.current = transition
            try storeTransitionState(transitions, journal)
        }
    }

    /// The local session's start moves to `position` with the played time as it stands, so a jump the person did not
    /// listen to is not counted (PROTOCOL §8, scenario 37).
    private func rebasePlaybackSession(_ session: LibraryPlaybackSession, to position: Int32) throws -> LibraryPlaybackSession {
        let played = try loadEpisode(session.episodeID)?.userState.playedDurationMilliseconds ?? session.playedDurationWhenStarted
        let rebased = LibraryPlaybackSession(id: session.id, episodeID: session.episodeID, startPositionMilliseconds: max(0, position),
                                             playedDurationWhenStarted: played, itemPlayState: session.itemPlayState, status: session.status)
        try savePlaybackSession(rebased)
        return rebased
    }

    /// A remote position the player's episode may adopt (PROTOCOL §8.6, §8.1).
    struct WaitingPosition: Equatable, Sendable {
        var position: Int64
        var claim: String
        /// The position record's provenance: what a seal or takeover under it depends on.
        var provenance: [String]
    }

    /// What the paused player's episode does with the position record it can see now (PROTOCOL §8.6).
    enum AdoptionCheck: Equatable, Sendable {
        /// Nothing: no claim, nothing new, or not yet applicable (this device's own intent is pending, the recovery base
        /// is not installed, a recovery holds the position). Nothing is written, so it is reconsidered when that changes.
        case none
        /// Take the version as the baseline without moving the player: this device's own claim, an older listening of
        /// another lineage or generation, the same version in a transition from before baselines.
        case rebaseline(ServerObservedPosition)
        /// Adopt the position.
        case adopt(WaitingPosition, ServerObservedPosition)
    }

    /// The decision, in order:
    /// 1. fences: the recovery's base not installed yet, the episode's position held by a recovery;
    /// 2. no claim: nothing;
    /// 3. this device's own claim or register on the episode still pending (an owed start or resume, an unretired overlay):
    ///    nothing, and nothing written (the version seen now is reconsidered when the intent retires);
    /// 4. the record's claim is one of this device's own: rebaseline;
    /// 5. the settled baseline's version again: nothing (idempotent across reads and relaunches);
    /// 6. the baseline's lineage and generation, a different version or an unsettled one: adopt;
    /// 7. another lineage or generation (a restored or replaced server, a new subscription), or no baseline: adopt only
    ///    listening newer than everything known (`listenedHighWater` and this device's own listening), else rebaseline.
    func positionCheck(episodeID: Int64) throws -> AdoptionCheck {
        guard serverContext != nil, let wire = try wireEpisode(local: episodeID),
              let row = try database.rows("SELECT value, provenance FROM ntp_records WHERE entity = 'episode' AND id = ? AND field_group = 'position'", [.text(wire)]).first,
              let data = row[0].data else { return .none }
        let record = try ContractJSON.decode(data)
        guard let claim = record["claim_id"]?.stringValue, let position = record["position"]?.integerValue else { return .none }
        if try positionFenced(wire: wire) { return .none }
        let sessions = try ServerSyncSession.load(database, episode: episodeID)
        guard let version = try positionVersion(episodeID, wire: wire, record: record, provenance: row[1].text) else { return .none }
        if try pendingOwnPositionIntent(episodeID, wire: wire, sessions: sessions) {
            return adoptionFaults.contains(.rebaselineWhilePending) ? .rebaseline(version) : .none
        }
        let transition = try transitionState().current.flatMap { $0.episodeID == episodeID ? $0 : nil }
        if try database.scalar("SELECT count(*) FROM ntp_nodes WHERE node_id = ? AND kind IN ('local', 'draft')", [.text(claim)]) > 0
            || sessions.contains(where: { $0.claims.contains(claim) }) {
            // Already the settled baseline: nothing to write again.
            if let observed = transition?.observed, observed.settled,
               observed.sameVersion(as: version, lastPlayed: adoptionFaults.contains(.lastPlayedIsVersion)) { return .none }
            return .rebaseline(version)
        }
        let provenance = (row[1].text.flatMap { try? ContractJSON.decode(Data($0.utf8)).arrayValue } ?? []).compactMap(\.stringValue)
            .filter(ContractIdentity.isUUID)
        let waiting = WaitingPosition(position: max(0, position), claim: claim, provenance: provenance)
        if let observed = transition?.observed {
            var seen = observed
            if adoptionFaults.contains(.ignoreProvenance) { seen.provenance = version.provenance }
            if seen.settled, seen.sameVersion(as: version, lastPlayed: adoptionFaults.contains(.lastPlayedIsVersion)) { return .none }
            if observed.sameLineage(as: version) { return .adopt(waiting, version) }
        } else if let transition, let standing = transition.claim {
            // A transition persisted before baselines: the claim the player stood under at the position it took under it is
            // nothing new and becomes the baseline; anything else is adopted, as before.
            if standing == claim, transition.claimPosition.map({ $0 == position }) ?? true { return .rebaseline(version) }
            return .adopt(waiting, version)
        }
        let known = max(transition?.listenedHighWater ?? 0, ownListening(sessions))
        if adoptionFaults.contains(.alwaysAdopt) { return .adopt(waiting, version) }
        if adoptionFaults.contains(.neverAdopt) { return .rebaseline(version) }
        return (version.lastPlayed ?? 0) > known ? .adopt(waiting, version) : .rebaseline(version)
    }

    /// Test-only faults in the decision (mutation checks): each must fail a named witness.
    enum AdoptionFault: Hashable, Sendable {
        /// A change of the separate last played record alone makes the position record a new version.
        case lastPlayedIsVersion
        /// An end (a passive seal's time included) counts as this device's listening.
        case endsAreListening
        /// A load under a recovery fence settles the raw base version it did not load.
        case settleFencedLoad
        /// A paused seek leaves the version already known undecided.
        case ignoreChosenSeek
        /// A load under pending own intent takes the record's last played into the high-water mark.
        case highWaterFromUnsettledLoad
        /// Unexported listening taken from what the row showed instead of the journal's entries.
        case displayedRowListening
        /// Performance: a unit reads the whole library on a second connection.
        case unitScansOnSecondConnection
        /// Performance: a unit decodes every podcast and episode in memory.
        case unitLoadsFeeds
        /// Performance: acknowledged sessions are never pruned (an adoption check decodes them all).
        case keepAcknowledgedSessions
        /// A version seen while own intent is pending becomes the baseline.
        case rebaselineWhilePending
        /// The high-water mark moves on a `none` too.
        case highWaterOnNone
        /// A new provenance under the same claim is nothing new.
        case ignoreProvenance
        /// Rule 7 replaced: always adopt, or never adopt.
        case alwaysAdopt, neverAdopt
        /// A rebaseline is decided but not written.
        case skipRebaselineWrite
        /// Last played and history frozen by the marks (records only while marked).
        case recordsOnlyListening
        /// Performance: the projection counts the statistics units instead of probing for one.
        case countStatisticsUnits
    }

    func setAdoptionFaultsForTesting(_ faults: Set<AdoptionFault>) { adoptionFaults = faults }

    /// The version of the episode's position record now, settled; nil without a mapping.
    func positionVersion(_ episodeID: Int64) throws -> ServerObservedPosition? {
        guard serverContext != nil, let wire = try wireEpisode(local: episodeID) else { return nil }
        let row = try database.rows("SELECT value, provenance FROM ntp_records WHERE entity = 'episode' AND id = ? AND field_group = 'position'", [.text(wire)]).first
        let record = try row?[0].data.map { try ContractJSON.decode($0) }
        return try positionVersion(episodeID, wire: wire, record: record, provenance: row?[1].text)
    }

    private func positionVersion(_ episodeID: Int64, wire: String, record: ContractJSON?, provenance: String?) throws -> ServerObservedPosition? {
        let lineage = try database.rows("SELECT log_id, epoch FROM ntp_library WHERE id = 1").first
        let lastPlayed = try database.rows("SELECT value FROM ntp_records WHERE entity = 'episode' AND id = ? AND field_group = 'last_played'", [.text(wire)])
            .first?.first?.data.flatMap { try? ContractJSON.decode($0) }?["time"]?.integerValue
        let generation = try record?["generation_id"]?.stringValue
            ?? database.rows("SELECT p.live_generation FROM ntp_podcasts p JOIN episodes e ON e.feed_id = p.feed_id WHERE e.id = ?", [.integer(episodeID)]).first?.first?.text
        let sources = (provenance.flatMap { try? ContractJSON.decode(Data($0.utf8)).arrayValue } ?? []).compactMap(\.stringValue).sorted()
        return ServerObservedPosition(logID: lineage?[0].text, epoch: lineage?[1].integer, generation: generation,
                                      claim: record?["claim_id"]?.stringValue, provenance: sources, lastPlayed: lastPlayed, settled: true)
    }

    /// Whether a recovery keeps the episode's position from being decided now: its base not installed yet, or a hold on the
    /// position (what the player shows is then not the base record's).
    func positionFenced(wire: String) throws -> Bool {
        if let recovery = try serverRecovery(), !recovery.finished, !recovery.caughtUp { return true }
        return try database.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'ntp_recovery_holds'") == 1
            && database.scalar("SELECT count(*) FROM ntp_recovery_holds WHERE entity = 'episode' AND id = ? AND field_group = 'position'", [.text(wire)]) > 0
    }

    /// This device's own position intent on the episode is still pending (PROTOCOL §8.6: adoption waits for a view that
    /// includes it): an unretired claim or register overlay, an owed start, an owed resume claim.
    func pendingOwnPositionIntent(_ episodeID: Int64) throws -> Bool {
        guard serverContext != nil else { return false }
        return try pendingOwnPositionIntent(episodeID, wire: try wireEpisode(local: episodeID),
                                            sessions: ServerSyncSession.load(database, episode: episodeID))
    }

    private func pendingOwnPositionIntent(_ episodeID: Int64, wire: String?, sessions: [ServerSyncSession]) throws -> Bool {
        if try database.scalar("SELECT count(*) FROM ntp_overlays WHERE entity = 'episode' AND id IN (?, ?) AND property = 'position' AND kind IN ('claim', 'register')",
                               [wire.map(LibrarySQLValue.text) ?? .null, .text("local-episode:\(episodeID)")]) > 0 { return true }
        return sessions.contains { $0.owesServer && (!$0.startRecorded || $0.unexported.contains { $0.claim != nil }) }
    }

    /// The newest listening this device journaled for the episode: its sessions' starts and listening saves. An end is not
    /// listening of its own (a passive seal at an adoption is stamped when it happens, not when anyone listened).
    func ownListening(_ episodeID: Int64) throws -> Int64 {
        guard serverContext != nil else { return 0 }
        return ownListening(try ServerSyncSession.load(database, episode: episodeID))
    }

    private func ownListening(_ sessions: [ServerSyncSession]) -> Int64 {
        if adoptionFaults.contains(.endsAreListening) { return sessions.reduce(0) { max($0, $1.startTime, $1.last?.time ?? 0, $1.end?.time ?? 0) } }
        return sessions.reduce(0) { max($0, $1.startTime, $1.last?.time ?? 0) }
    }

    /// The high-water mark after a settled decision about `version` (adopt, rebaseline, takeover): never lower (only
    /// settled decisions move it).
    func settledHighWater(_ transition: ServerPendingTransition?, _ version: ServerObservedPosition, episodeID: Int64) throws -> Int64 {
        max(transition?.listenedHighWater ?? 0, try ownListening(episodeID), version.lastPlayed ?? 0)
    }

    /// The paused player's episode's decision, for the adoption driver.
    public enum AdoptionDecision: Sendable, Equatable { case none, rebaseline, adopt }

    public func serverAdoptionCheck(episodeID: Int64) throws -> AdoptionDecision {
        switch try positionCheck(episodeID: episodeID) {
        case .none: .none
        case .rebaseline: .rebaseline
        case .adopt: .adopt
        }
    }

    /// Whether the episode has a remote position to adopt (PROTOCOL §8.6).
    public func serverAdoptionWaiting(episodeID: Int64) throws -> Bool { try serverAdoptionCheck(episodeID: episodeID) == .adopt }

    /// A rebaseline: the version is the player's baseline now; nothing moves, nothing is recorded. Checked again
    /// inside its transaction. Returns whether it was written.
    @discardableResult
    public func noteAdoptionBaseline(episodeID: Int64, now: Date = Date()) throws -> Bool {
        guard serverContext != nil, case .rebaseline = try positionCheck(episodeID: episodeID),
              !adoptionFaults.contains(.skipRebaselineWrite) else { return false }
        return try write(.playbackSave, durable: true, now: now) { () throws -> Bool in
            guard case .rebaseline(let version) = try positionCheck(episodeID: episodeID) else { return false }
            var transitions = try transitionState()
            guard var transition = transitions.current, transition.episodeID == episodeID else { return false }
            transition.listenedHighWater = try settledHighWater(transition, version, episodeID: episodeID)
            transition.observed = version
            transitions.current = transition
            try storeTransitionState(transitions, journal)
            return true
        }
    }

    /// The adoption transaction (PROTOCOL §8.6): the open sync session is sealed at its pre-adoption save (`session.end {reason:
    /// superseded, completed: false, history: false}`, listening only if a save was unexported); the adopted position
    /// is projected onto the row; the local session's start moves to it, so the jump is not counted; a new pending
    /// session observes the adopted claim (the next intentional play starts it there); the pending transition stands
    /// under the adopted claim, the adopted version its settled baseline. A rebaseline found instead is written as one. Returns
    /// the adopted position, nil when nothing waits. Only the coordinator's command queue calls it
    /// (`PlaybackCoordinator.adoptRemotePosition`), while the player is not playing; `stillPaused` is checked last, inside
    /// the transaction: when playback began meanwhile, nothing is written and nil is returned.
    public func adoptRemotePosition(episodeID: Int64, now: Date = Date(), stillPaused: @Sendable () -> Bool = { true }) throws -> Int32? {
        guard serverContext != nil else { return nil }
        switch try positionCheck(episodeID: episodeID) {
        case .none:
            if adoptionFaults.contains(.highWaterOnNone), let version = try positionVersion(episodeID) {
                try write(.playbackSave, durable: true, now: now) {
                    var transitions = try transitionState()
                    guard var transition = transitions.current, transition.episodeID == episodeID else { return }
                    transition.listenedHighWater = max(transition.listenedHighWater ?? 0, version.lastPlayed ?? 0)
                    transitions.current = transition
                    try storeTransitionState(transitions, journal)
                }
            }
            return nil
        case .rebaseline:
            try noteAdoptionBaseline(episodeID: episodeID, now: now)
            return nil
        case .adopt: break
        }
        let time = try milliseconds(now)
        do {
            return try adoptRemotePosition(episodeID: episodeID, time: time, now: now, stillPaused: stillPaused)
        } catch is AdoptionOvertaken { return nil }
    }

    private struct AdoptionOvertaken: Error {}

    private func adoptRemotePosition(episodeID: Int64, time: Int64, now: Date, stillPaused: @Sendable () -> Bool) throws -> Int32? {
        try write(.playbackSave, durable: true, now: now) { () throws -> Int32? in
            guard case .adopt(let waiting, let version) = try positionCheck(episodeID: episodeID), var episode = try loadEpisode(episodeID) else { return nil }
            let adopted = Int32(clamping: waiting.position)
            var transitions = try transitionState()
            let local = try playbackSession().flatMap { $0.episodeID == episodeID ? $0 : nil }
            if let local, var live = try liveSyncSession(local: local.id) {
                if live.state == .open {
                    live.end = .init(op: ContractIdentity.randomUUID(), reason: "superseded", completed: false, thresholdMs: 0, removeFromQueue: false,
                                     history: false, time: time, dependencies: waiting.provenance, incarnation: playbackIncarnation, recorded: false,
                                     sequence: transitions.next())
                    live.state = .sealed
                    try storeSyncSession(live, journal)
                    activeCapture?.playbackDue = true
                } else {
                    try database.execute("DELETE FROM ntp_sessions WHERE session_id = ?", [.text(live.id)])
                }
            }
            // An open session of an earlier opening (a restored player) is sealed the same way.
            for var open in try syncSessions("state = 'open' AND episode_id = ?", [.integer(episodeID)]) {
                open.end = .init(op: ContractIdentity.randomUUID(), reason: "superseded", completed: false, thresholdMs: 0, removeFromQueue: false,
                                 history: false, time: time, dependencies: waiting.provenance, incarnation: playbackIncarnation, recorded: false,
                                 sequence: transitions.next())
                open.state = .sealed
                try storeSyncSession(open, journal)
                activeCapture?.playbackDue = true
            }
            // The adopted position is the server's, not listening here: nothing marks it.
            activeCapture?.playbackUnmarked.insert(episodeID)
            episode.userState.positionMilliseconds = adopted
            try saveEpisode(episode, feedID: try feedID(forEpisode: episodeID))
            if let wire = try wireEpisode(local: episodeID) {
                try database.execute("UPDATE ntp_deferred_pins SET fields = fields & ? WHERE episode_id = ?",
                                     [.integer(Int64(~ServerEpisodeFields.position.rawValue)), .text(wire)])
                try database.execute("DELETE FROM ntp_deferred_pins WHERE episode_id = ? AND fields = 0", [.text(wire)])
            }
            if let local {
                let rebased = try rebasePlaybackSession(local, to: adopted)
                var pending = ServerSyncSession(localSession: rebased.id, episodeID: episodeID, incarnation: playbackIncarnation, start: adopted)
                pending.observedClaim = waiting.claim
                pending.startDependencies = waiting.provenance
                try storeSyncSession(pending, journal)
            }
            if var transition = transitions.current, transition.episodeID == episodeID {
                transition.claim = waiting.claim
                transition.claimPosition = waiting.position
                transition.claimDependencies = waiting.provenance
                transition.listenedHighWater = try settledHighWater(transition, version, episodeID: episodeID)
                transition.observed = version
                transitions.current = transition
            }
            try storeTransitionState(transitions, journal)
            // Playback began meanwhile (it never waits for this transaction): roll everything back.
            guard stillPaused() else { throw AdoptionOvertaken() }
            return adopted
        }
    }

    /// The restart export and what earlier playback writes owe (PROTOCOL §8.2, §8.1), in one playback write, when
    /// either is waiting. Called when a server library opens and by the exchange before it pushes.
    public func flushServerPlayback() throws {
        guard serverContext != nil else { return }
        guard try playbackRestartPending || database.scalar("SELECT export_owed FROM ntp_library WHERE id = 1") == 1 else { return }
        try write(.playbackSave) {}
    }
}
