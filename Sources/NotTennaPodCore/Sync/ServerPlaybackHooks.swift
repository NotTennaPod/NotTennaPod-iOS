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
        guard serverContext != nil, wantsPlayback, let local = try playbackSession(), local.id == sessionID,
              let live = try liveSyncSession(local: sessionID), live.state == .open, live.incarnation == playbackIncarnation,
              try waitingRemotePosition(episodeID: local.episodeID) != nil else { return nil }
        let time = try milliseconds(now)
        return try write(.playbackSave, durable: true, now: now) { () throws -> LibraryPlaybackSession? in
            guard var old = try liveSyncSession(local: sessionID), old.state == .open,
                  let waiting = try waitingRemotePosition(episodeID: local.episodeID) else { return nil }
            var transitions = try transitionState()
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
            transitions.current = .init(id: transitions.current?.episodeID == local.episodeID ? transitions.current!.id : ContractIdentity.randomUUID(),
                                        kind: .finalize, episodeID: local.episodeID, session: new.id, claim: new.startOp)
            try storeTransitionState(transitions, journal)
            activeCapture?.playbackDue = true
            return rebased
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

    /// The episode's position record, when its claim is not one of this library's own facts (PROTOCOL §6.10: a position whose claim
    /// is one of the library's own facts is its own), differs from the claim the player stands under (the pending
    /// transition's) or moved under it, and the view includes this library's latest claim on the episode: none of its
    /// claims on it is still pending or owed (until then its own overlay wins).
    func waitingRemotePosition(episodeID: Int64) throws -> WaitingPosition? {
        guard serverContext != nil, let wire = try wireEpisode(local: episodeID),
              let row = try database.rows("SELECT value, provenance FROM ntp_records WHERE entity = 'episode' AND id = ? AND field_group = 'position'", [.text(wire)]).first,
              let data = row[0].data else { return nil }
        let record = try ContractJSON.decode(data)
        guard let claim = record["claim_id"]?.stringValue, let position = record["position"]?.integerValue else { return nil }
        if try database.scalar("SELECT count(*) FROM ntp_nodes WHERE node_id = ? AND kind IN ('local', 'draft')", [.text(claim)]) > 0 { return nil }
        let sessions = try ServerSyncSession.load(database, episode: episodeID)
        if sessions.contains(where: { $0.claims.contains(claim) }) { return nil }
        // The claim the player stands under, at the position it took under it: nothing new. A later checkpoint of that
        // claim moving the position is new; a seek the person made while paused does not change the record.
        if let transition = try transitionState().current, transition.episodeID == episodeID, transition.claim == claim,
           transition.claimPosition.map({ $0 == position }) ?? true { return nil }
        if try database.scalar("SELECT count(*) FROM ntp_overlays WHERE entity = 'episode' AND id IN (?, ?) AND property = 'position' AND kind IN ('claim', 'register')",
                               [.text(wire), .text("local-episode:\(episodeID)")]) > 0 { return nil }
        if sessions.contains(where: { !$0.startRecorded || $0.unexported.contains { $0.claim != nil } }) { return nil }
        let provenance = (row[1].text.flatMap { try? ContractJSON.decode(Data($0.utf8)).arrayValue } ?? []).compactMap(\.stringValue)
            .filter(ContractIdentity.isUUID)
        return WaitingPosition(position: max(0, position), claim: claim, provenance: provenance)
    }

    /// Whether the episode has a remote position to adopt (PROTOCOL §8.6): the sync layer asks before it sends the coordinator's
    /// adoption command.
    public func serverAdoptionWaiting(episodeID: Int64) throws -> Bool { try waitingRemotePosition(episodeID: episodeID) != nil }

    /// The adoption transaction (PROTOCOL §8.6): the open sync session is sealed at its pre-adoption save (`session.end {reason:
    /// superseded, completed: false, history: false}`, listening only if a save was unexported); the adopted position
    /// is projected onto the row; the local session's start moves to it, so the jump is not counted; a new pending
    /// session observes the adopted claim (the next intentional play starts it there); the pending transition stands
    /// under the adopted claim. Returns the adopted position, nil when nothing waits. Only the coordinator's command
    /// queue calls it (`PlaybackCoordinator.adoptRemotePosition`), while the player is not playing; `stillPaused` is
    /// checked last, inside the transaction: when playback began meanwhile, nothing is written and nil is returned.
    public func adoptRemotePosition(episodeID: Int64, now: Date = Date(), stillPaused: @Sendable () -> Bool = { true }) throws -> Int32? {
        guard serverContext != nil, try waitingRemotePosition(episodeID: episodeID) != nil else { return nil }
        let time = try milliseconds(now)
        do {
            return try adoptRemotePosition(episodeID: episodeID, time: time, now: now, stillPaused: stillPaused)
        } catch is AdoptionOvertaken { return nil }
    }

    private struct AdoptionOvertaken: Error {}

    private func adoptRemotePosition(episodeID: Int64, time: Int64, now: Date, stillPaused: @Sendable () -> Bool) throws -> Int32? {
        try write(.playbackSave, durable: true, now: now) { () throws -> Int32? in
            guard let waiting = try waitingRemotePosition(episodeID: episodeID), var episode = try loadEpisode(episodeID) else { return nil }
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
