import Foundation

/// What an episode's pending playback facts show over its base (PROTOCOL §6.8): the position under the
/// displayed claim, and which completions hold.
struct ServerPositionState: Equatable, Sendable {
    var position: Int64
    /// The claim the displayed position stands under (nil: none).
    var claim: String?
    /// Pending completions whose precondition holds in the displayed state, by op ID, with their knowledge clock.
    var completions: [String: Int64] = [:]
}

extension ServerProjector {
    /// The displayed position (PROTOCOL §6.8): the base record, then the pending overlays in local creation order. A claim (a
    /// mark or reset, a session start, a claiming checkpoint) moves the position and owns it; a session export moves it
    /// only while the claim it stands under is the displayed one; a completion (an end, finalization or leave) holds
    /// only while its claim is still the displayed one, and then shows position 0, PLAYED and out of the
    /// queue. Otherwise the base shows, as the server will fold it.
    func positionState(episode: String?, overlays: [ServerOverlayRow]) throws -> ServerPositionState {
        let record = try episode.flatMap { try record("episode", $0, "position") }
        return Self.positionState(record: record, overlays: overlays)
    }

    static func positionState(record: ContractJSON?, overlays: [ServerOverlayRow]) -> ServerPositionState {
        var state = ServerPositionState(position: record?["position"]?.integerValue ?? 0, claim: record?["claim_id"]?.stringValue)
        for overlay in overlays {
            switch (overlay.kind, overlay.property) {
            case ("register", "position"):
                // Marks played with reset, resets and Undo are claims (PROTOCOL §8).
                if let value = overlay.value?.integerValue { state.position = value; state.claim = overlay.opID }
            case ("claim", "position"):
                if let value = overlay.value?["position"]?.integerValue { state.position = value }
                state.claim = overlay.value?["claim"]?.stringValue ?? overlay.opID
            case ("session_position", "position"):
                if let value = overlay.value?["position"]?.integerValue, overlay.value?["claim"]?.stringValue == state.claim {
                    state.position = value
                }
            case ("completion", _):
                // Both absent counts as equal (PROTOCOL §8.4: a claimless completion).
                if overlay.value?["claim"]?.stringValue == state.claim {
                    state.position = 0
                    state.completions[overlay.opID] = overlay.clock
                }
            default:
                break
            }
        }
        return state
    }

    /// A pending queue membership (PROTOCOL §6.8): the latest pending `register` of the membership or holding completion, in local
    /// creation order; nil when none is pending.
    func pendingQueueMembership(_ overlays: [ServerOverlayRow], completions: [String: Int64]) -> Bool? {
        var latest: (clock: Int64, member: Bool)?
        for overlay in overlays where overlay.kind == "register" && overlay.property == "queue_membership" {
            if let value = overlay.value?.boolValue, latest.map({ overlay.clock >= $0.clock }) ?? true { latest = (overlay.clock, value) }
        }
        for clock in completions.values where latest.map({ clock >= $0.clock }) ?? true { latest = (clock, false) }
        return latest?.member
    }

    /// Whether an op is a pending local fact (an unretired outbox entry or a draft) that this projection does not retire.
    func isPendingOp(_ op: String) throws -> Bool {
        if excludedOps.contains(op) { return false }
        return try db.scalar("SELECT (SELECT count(*) FROM ntp_outbox WHERE op_id = ?) + (SELECT count(*) FROM ntp_drafts WHERE op_id = ?)",
                             [.text(op), .text(op)]) > 0
    }

    /// Displayed played time (PROTOCOL §8.8): `others + Σ max(0, C − K)` over this library's sessions of the episode, where
    /// `others = record − Σ max(0, C_acc − K_acc)` is exactly what the server's fold added for every other session.
    /// While a statistics reset of this library is pending, only the growth of `others` since the reset counts (the
    /// base kept with the reset is `others` then, PROTOCOL §6.8 `stat_cut`), and each session's cut includes the pending one.
    func displayedPlayedTime(episode: String?, localID: Int64, overlays: [ServerOverlayRow], live: ServerSyncSession? = nil) throws -> Int64 {
        let base = try episode.flatMap { try record("episode", $0, "played_time")?["played_ms"]?.integerValue } ?? 0
        var sessions = try live.map { live in
            try ServerSyncSession.load(db, "episode_id = ? AND state != 'pending' AND session_id != ?", [.integer(localID), .text(live.id)]) + [live]
        } ?? ServerSyncSession.load(db, episode: localID)
        if !commitResets.isEmpty, let history {
            for index in sessions.indices {
                for reset in commitResets { try sessions[index].noteAcceptedCut(by: reset, history) }
            }
        }
        var othersAtReset: Int64??
        let cuts = try self.overlays(entity: "account", ids: [accountID]).filter { $0.kind == "stat_cut" && $0.property == "played_time" }
        if let latest = cuts.last, let episode {
            othersAtReset = .some(overlays.last { $0.opID == latest.opID && $0.property == "played_time_base" }?.value?.integerValue
                ?? plan.overlayAdditions.last { $0.op == latest.opID && $0.id == episode }?.value.integerValue)
        } else if cuts.last != nil {
            othersAtReset = .some(nil)
        }
        return try ServerPlayedTime.displayed(record: base, sessions: sessions, isPending: isPendingOp, othersAtReset: othersAtReset)
    }

    /// `others` (PROTOCOL §8.8) for an episode as the library holds it now, before a unit changes its record: the base a
    /// pending statistics reset keeps (`played_time_base`).
    func othersPlayedTime(episode: String, record: Int64) throws -> Int64 {
        guard let local = try db.rows("SELECT local_id FROM ntp_episodes WHERE episode_id = ?", [.text(episode)]).first?.first?.integer else { return record }
        let sessions = try ServerSyncSession.load(db, episode: local)
        return record - (try ServerPlayedTime.accepted(sessions, isPending: isPendingOp))
    }
}

/// Played time by the server's rule (PROTOCOL §8): raw contributions with ordinal cuts.
enum ServerPlayedTime {
    /// `Σ max(0, C_acc − K_acc)`: what the server's fold has added for this library's sessions.
    static func accepted(_ sessions: [ServerSyncSession], isPending: (String) throws -> Bool) throws -> Int64 {
        var total: Int64 = 0
        for session in sessions where session.state != .pending {
            total += max(0, try session.acceptedContribution(isPending: isPending) - (session.cutAccepted?.contribution ?? 0))
        }
        return total
    }

    /// `others + Σ max(0, C − K)`; with a pending reset (`othersAtReset` non-nil), only the growth of `others` since it.
    static func displayed(record: Int64, sessions: [ServerSyncSession], isPending: (String) throws -> Bool,
                          othersAtReset: Int64??) throws -> Int64 {
        var live: Int64 = 0
        for session in sessions where session.state != .pending { live += max(0, session.contribution - session.effectiveCut) }
        let others = max(0, record - (try accepted(sessions, isPending: isPending)))
        switch othersAtReset {
        case .none: return others + live
        case .some(.none): return live
        case .some(.some(let atReset)): return max(0, others - atReset) + live
        }
    }
}
