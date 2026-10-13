import Foundation

/// The installation transition (PROTOCOL §6.11, §6.10): a library moves to a new transport
/// installation `T'` when the server was restored (recovery: the installation's transport nonce is kept, so the
/// successor supersedes its predecessor), when it found itself a copy, or when another library used its transport
/// (both with a fresh nonce, so the other library's installation is left alone). `ntp_library.transition` holds the
/// plan until the transition commits; the current `install_id` changes only in that commit, which renumbers the
/// unreceipted outbox onto `T'` from slot 1 and keeps the receipted, unretired entries in `ntp_retained`.
struct ServerInstallationTransition: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable { case recovery, copy, conflict }
    /// `planned`: `T'` and its nonce are chosen. `issued`: `T'` holds a token (the successor request answered, or the
    /// person signed in with `T'`), so the transition may commit.
    enum State: String, Codable, Sendable { case planned, issued }

    /// `T'`.
    var installID: String
    var transportNonce: String
    var reason: Reason
    var state: State
    /// The installation the plan succeeds.
    var predecessor: String
    /// The predecessor can no longer authorize a successor (`409 installation_superseded`, or `401` once another
    /// library used a successor of it, PROTOCOL §6.10): the person signs in again with `T'` and its nonce instead.
    var signInWithSuccessor: Bool

    init(installID: String, transportNonce: String, reason: Reason, state: State = .planned, predecessor: String,
         signInWithSuccessor: Bool = false) {
        self.installID = installID; self.transportNonce = transportNonce; self.reason = reason; self.state = state
        self.predecessor = predecessor; self.signInWithSuccessor = signInWithSuccessor
    }

    private enum CodingKeys: String, CodingKey {
        case reason, state, predecessor
        case installID = "install_id", transportNonce = "transport_nonce", signInWithSuccessor = "sign_in_with_successor"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        installID = try values.decode(String.self, forKey: .installID)
        transportNonce = try values.decode(String.self, forKey: .transportNonce)
        reason = try values.decode(Reason.self, forKey: .reason)
        state = try values.decode(State.self, forKey: .state)
        predecessor = try values.decode(String.self, forKey: .predecessor)
        signInWithSuccessor = try values.decodeIfPresent(Bool.self, forKey: .signInWithSuccessor) ?? false
    }
}

/// A recovery after a server restore (PROTOCOL §6.11), in `ntp_library.recovery` from its start until it is
/// finished. The live database is authoritative for it: with the transition plan, the cursor, the outbox and the
/// retained entries it says where a recovery that a crash or a second restore interrupted goes on. Per-entry
/// inventory and upload results are in `sync.sqlite` (`recovery_progress`), under the server epoch they belong to.
struct ServerRecoveryRecord: Codable, Equatable, Sendable {
    /// What started it: `lineage_mismatch` (the server was restored) or `dependency_lost` (the server lost a node this
    /// library holds; the whole archive is inventoried then, whatever the cursor).
    enum Cause: String, Codable, Sendable { case lineageMismatch = "lineage_mismatch", dependencyLost = "dependency_lost" }

    var recoveryID: String
    var cause: Cause
    /// The live cursor when the recovery started: the archive beyond it is what a prefix recovery inventories.
    var from: String?
    /// The server epoch the inventory and upload results belong to (a later restore makes them stale), and whether
    /// the server still held the cursor (`prefix`, PROTOCOL §6.11). Known after the recovery snapshot's first answer.
    var epoch: Int64?
    var prefix: Bool?
    /// The library has caught up with the server after the uploads (PROTOCOL §6.11): its outbox may be pushed.
    var caughtUp: Bool
    /// Caught up, some entries still wait for a dependency another device may restore: the upload is tried again at
    /// later exchanges, with the backoff, indefinitely (unsent changes never expire, PROTOCOL §6, §1.3); the facts chained
    /// behind them are parked meanwhile.
    var waiting: Bool
    /// Nodes the server lacks that this library cannot supply (it never held them): what waits for them waits until
    /// they reach the server from another device and this library pulls them.
    var missingNodes: [String]
    /// The server was told the recovery's outcome so far (`finish {complete: false}` while entries wait).
    var finishSent: Bool
    /// Facts of this library quarantined because they could never be restored.
    var quarantined: Int
    /// `POST /v1/sync/recovery/finish` was answered: the recovery is over.
    var finished: Bool
    /// Whether nothing ended `invalid_receipt`, `invalid`, `conflict` or with a dependency nobody restored.
    var complete: Bool?
    /// Entries that could not be restored (the page and the log say so).
    var problems: Int
    /// The facts and decisions that could not be restored (at most `unrestoredLimit`): a later `dependency_missing`
    /// naming one waits instead of starting another recovery that could not restore it either.
    var unrestored: [String]
    var startedAt: Int64

    static let unrestoredLimit = 1_000

    /// The recovery continues on another installation (a copy's, or after the server bound its ID to another one):
    /// a new ID, and every phase bound to the old installation's server session starts again as one checkpoint
    ///: no epoch yet (the snapshot answers again), not caught up (it inventories and
    /// uploads what is still needed and catches up again), nothing told the server. What it learned stays: where it
    /// started, whether it was a full recovery (its inventory stays the whole archive), the nodes nobody here can
    /// supply, and its quarantine; parked facts and holds are the library's and stay too.
    mutating func restartPhases() {
        recoveryID = ContractIdentity.randomUUID()
        epoch = nil
        caughtUp = false
        waiting = false
        finishSent = false
    }

    init(recoveryID: String = ContractIdentity.randomUUID(), cause: Cause, from: String?, startedAt: Int64) {
        self.recoveryID = recoveryID; self.cause = cause; self.from = from; epoch = nil; prefix = nil
        caughtUp = false; finished = false; complete = nil; problems = 0; unrestored = []; self.startedAt = startedAt
        waiting = false; missingNodes = []; finishSent = false; quarantined = 0
    }

    private enum CodingKeys: String, CodingKey {
        case cause, from, epoch, prefix, finished, complete, problems, unrestored, waiting, quarantined
        case recoveryID = "recovery_id", caughtUp = "caught_up", startedAt = "started_at", missingNodes = "missing_nodes"
        case finishSent = "finish_sent"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        recoveryID = try values.decode(String.self, forKey: .recoveryID)
        cause = try values.decode(Cause.self, forKey: .cause)
        from = try values.decodeIfPresent(String.self, forKey: .from)
        epoch = try values.decodeIfPresent(Int64.self, forKey: .epoch)
        prefix = try values.decodeIfPresent(Bool.self, forKey: .prefix)
        caughtUp = try values.decode(Bool.self, forKey: .caughtUp)
        finished = try values.decode(Bool.self, forKey: .finished)
        complete = try values.decodeIfPresent(Bool.self, forKey: .complete)
        problems = try values.decode(Int.self, forKey: .problems)
        unrestored = try values.decodeIfPresent([String].self, forKey: .unrestored) ?? []
        startedAt = try values.decode(Int64.self, forKey: .startedAt)
        waiting = try values.decodeIfPresent(Bool.self, forKey: .waiting) ?? false
        missingNodes = try values.decodeIfPresent([String].self, forKey: .missingNodes) ?? []
        finishSent = try values.decodeIfPresent(Bool.self, forKey: .finishSent) ?? false
        quarantined = try values.decodeIfPresent(Int.self, forKey: .quarantined) ?? 0
    }
}

/// What committing a transition did.
struct ServerTransitionCommit: Equatable, Sendable {
    var predecessor: String
    var successor: String
    var reason: ServerInstallationTransition.Reason
    /// Unreceipted entries now on `T'`, from slot 1.
    var renumbered: Int
    /// Receipted, unretired entries now in `ntp_retained`.
    var retained: Int
}

extension FeedLibraryStore {
    // MARK: - Reading

    func serverTransition() throws -> ServerInstallationTransition? {
        guard serverContext != nil else { return nil }
        return try Self.transition(database)
    }

    func serverRecovery() throws -> ServerRecoveryRecord? {
        guard serverContext != nil else { return nil }
        return try Self.recovery(database)
    }

    static func transition(_ database: LibrarySQLite) throws -> ServerInstallationTransition? {
        guard let data = try database.rows("SELECT transition FROM ntp_library WHERE id = 1").first?.first?.data else { return nil }
        do { return try JSONDecoder().decode(ServerInstallationTransition.self, from: data) }
        catch { throw ServerRecordingError.corruptState("ntp_library.transition") }
    }

    static func recovery(_ database: LibrarySQLite) throws -> ServerRecoveryRecord? {
        guard let data = try database.rows("SELECT recovery FROM ntp_library WHERE id = 1").first?.first?.data else { return nil }
        do { return try JSONDecoder().decode(ServerRecoveryRecord.self, from: data) }
        catch { throw ServerRecordingError.corruptState("ntp_library.recovery") }
    }

    static func storeTransition(_ transition: ServerInstallationTransition?, _ database: LibrarySQLite) throws {
        try database.execute("UPDATE ntp_library SET transition = ? WHERE id = 1",
                             [try transition.map { .blob(try JSONEncoder().encode($0)) } ?? .null])
    }

    static func storeRecovery(_ recovery: ServerRecoveryRecord?, _ database: LibrarySQLite) throws {
        try database.execute("UPDATE ntp_library SET recovery = ? WHERE id = 1",
                             [try recovery.map { .blob(try JSONEncoder().encode($0)) } ?? .null])
    }

    // MARK: - Planning (PROTOCOL §6.11, PROTOCOL §6.10)

    /// Plans a transition onto a new installation with `nonce` (the predecessor's for a recovery, a fresh one for a copy
    /// or conflict), unless one is planned already: that one is kept (a crash repeats the same handoff). A recovery
    /// is recorded with its plan in the same transaction (PROTOCOL §6.11: "start, once"), and the pause that stood for it
    /// is cleared: the recovery explains itself.
    @discardableResult
    func planServerTransition(_ reason: ServerInstallationTransition.Reason, nonce: String,
                              recovery cause: ServerRecoveryRecord.Cause? = nil, now: Date = Date()) throws -> ServerInstallationTransition {
        guard serverContext != nil else { throw ServerRecordingError.notAServerLibrary }
        let time = try milliseconds(now)
        return try database.transaction {
            let state = try serverExchangeState()
            let planned = try Self.transition(database)
            if let cause {
                // A recovery that caught up (its outbox may have been pushed under `T'`) and meets another restore
                // starts again: the receipts `T'` got move aside too (PROTOCOL §6.11: a second restore resumes from the live state).
                let record = try Self.recovery(database)
                if record == nil || record?.finished == true || (planned == nil && record?.caughtUp == true) {
                    try Self.storeRecovery(ServerRecoveryRecord(cause: cause, from: state.cursor?.encoded, startedAt: time), database)
                }
            }
            // The pause it stood for goes with what a version pause refused.
            let resume = "UPDATE ntp_library SET pause_reason = NULL, protocol_version = NULL, version_refusals = NULL WHERE id = 1"
            if let planned {
                try database.execute(resume)
                return planned
            }
            let plan = ServerInstallationTransition(installID: ContractIdentity.randomUUID(), transportNonce: nonce, reason: reason,
                                                    predecessor: state.installID)
            try Self.storeTransition(plan, database)
            try database.execute(resume)
            return plan
        }
    }

    /// Changes the plan (its state, or that the person must sign in with `T'`); nothing without a plan.
    func updateServerTransition(_ change: (inout ServerInstallationTransition) -> Void) throws {
        try database.transaction {
            guard var plan = try Self.transition(database) else { return }
            change(&plan)
            try Self.storeTransition(plan, database)
        }
    }

    func updateServerRecovery(_ change: (inout ServerRecoveryRecord) -> Void) throws {
        try database.transaction {
            guard var record = try Self.recovery(database) else { return }
            change(&record)
            try Self.storeRecovery(record, database)
        }
    }

    // MARK: - The transition's commit (PROTOCOL §6.11)

    /// Commits the planned transition in one live transaction: unreceipted outbox entries move to `T'` from slot 1,
    /// unchanged (op IDs, authors, order, dependencies and framing transaction IDs; the parts the predecessor's slot
    /// stored do not count for the new slot); receipted, unretired entries move to `ntp_retained` with their receipts
    /// and lineage; `install_id = T'`, `acked_install_seq = 0`. Overlays are keyed by op ID and do not move. Only
    /// after this commit does any request use `T'`'s token. Nil without a plan.
    @discardableResult
    func commitServerTransition() throws -> ServerTransitionCommit? {
        guard serverContext != nil else { throw ServerRecordingError.notAServerLibrary }
        let result = try database.transaction { () throws -> ServerTransitionCommit? in
            guard let plan = try Self.transition(database) else { return nil }
            let moved = try Self.moveOutbox(database, onto: plan.installID)
            try Self.storeTransition(nil, database)
            return ServerTransitionCommit(predecessor: plan.predecessor, successor: plan.installID, reason: plan.reason,
                                          renumbered: moved.renumbered, retained: moved.retained)
        }
        serverContext = try Self.loadServerContext(database)
        return result
    }

    /// The renumbering inside the caller's transaction (the commit, or copy detection without a token, PROTOCOL §6.10): receipted
    /// entries move aside, the rest go on `T'` in their order. Their framing transactions stay; the parts the
    /// predecessor's slots stored do not count for the new ones. The first `releaseBatch` are renumbered from slot 1 here;
    /// a longer outbox goes on in bounded steps before anything is pushed (PROTOCOL §6.8).
    static func moveOutbox(_ database: LibrarySQLite, onto installID: String) throws -> (renumbered: Int, retained: Int) {
        guard let transport = try database.rows("SELECT install_id FROM ntp_library WHERE id = 1").first?.first?.text else {
            throw ServerRecordingError.corruptState("ntp_library")
        }
        let retained = Int(try database.scalar("SELECT count(*) FROM ntp_outbox WHERE receipt IS NOT NULL"))
        try database.execute("INSERT INTO ntp_retained(op_id, transport, slot, fact, receipt, lineage, secret_ids) SELECT op_id, ?, install_seq, fact, receipt, receipt_lineage, secret_ids FROM ntp_outbox WHERE receipt IS NOT NULL ON CONFLICT(op_id) DO NOTHING",
                             [.text(transport)])
        try database.execute("DELETE FROM ntp_outbox WHERE receipt IS NOT NULL")
        for row in try database.rows("SELECT install_seq, framing FROM ntp_outbox WHERE framing IS NOT NULL") {
            guard let seq = row[0].integer, let data = row[1].data, var stored = try? JSONDecoder().decode(ServerFraming.self, from: data) else { continue }
            stored.present = []
            try database.execute("UPDATE ntp_outbox SET framing = ? WHERE install_seq = ?", [.blob(try JSONEncoder().encode(stored)), .integer(seq)])
        }
        try database.execute("UPDATE ntp_outbox SET waiting = NULL WHERE waiting IS NOT NULL")
        try database.execute("UPDATE ntp_library SET install_id = ?, acked_install_seq = 0 WHERE id = 1", [.text(installID)])
        _ = try renumberStep(database, limit: releaseBatch)
        return (Int(try database.scalar("SELECT count(*) FROM ntp_outbox")), retained)
    }

    // MARK: - Retained entries (PROTOCOL §6.11)

    /// A receipted entry of an earlier transport, kept for recovery upload until the server holds it.
    struct ServerRetainedEntry: Sendable {
        var opID: String
        var transport: String
        var slot: Int64
        var fact: ContractJSON
        var receipt: ContractJSON?
        var secretIDs: [String]
        /// Quarantined (`quarantineUnrestoredFacts`): never sent or uploaded again.
        var unrestored = false
        /// Parked (`parkWaitingFacts`): an unsent fact waiting for what it names to be restored, sent once it is.
        var parked = false
        var type: String { fact["type"]?.stringValue ?? "" }
        /// The receipt's position `(epoch, seq, index)`, when it is a receipt (an `op_id_conflict` stand-in is not).
        var position: (epoch: Int64, seq: Int64, index: Int64)? {
            guard let receipt, let epoch = receipt["epoch"]?.integerValue, let seq = receipt["seq"]?.integerValue else { return nil }
            return (epoch, seq, receipt["index"]?.integerValue ?? 0)
        }
    }

    func serverRetainedEntries() throws -> [ServerRetainedEntry] {
        guard serverContext != nil else { return [] }
        return try database.rows("SELECT op_id, transport, slot, fact, receipt, secret_ids, lineage FROM ntp_retained ORDER BY transport, slot").compactMap { row in
            guard let op = row[0].text, let transport = row[1].text, let slot = row[2].integer, let fact = row[3].data else { return nil }
            var secrets: [String] = []
            if let text = row[5].text { secrets = (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? [] }
            return ServerRetainedEntry(opID: op, transport: transport, slot: slot, fact: try ContractJSON.decode(fact),
                                       receipt: try row[4].data.map { try ContractJSON.decode($0) }, secretIDs: secrets,
                                       unrestored: Self.isUnrestored(row[6].data), parked: Self.isMarked(row[6].data, Self.parkedMark))
        }
    }

    /// Retires retained entries once the live base holds what they did (their commit was applied, or the recovery
    /// caught up after the server took them), or once they never can: their overlays go and what they showed is
    /// projected again from the base, in one unit. Rows in `deleting` leave `ntp_retained`; the others stay as
    /// evidence (an entry the server refused in recovery, PROTOCOL §6.11: kept permanently).
    func retireServerRetained(_ opIDs: [String], deleting: Set<String>, history: ServerHistoryOracle?, now: Int64) throws -> ServerUnitResult {
        guard let context = serverContext else { throw ServerRecordingError.notAServerLibrary }
        try ensureServerExchangeTables()
        let clock = ContinuousClock(), started = clock.now
        var result = try write(.remote, durable: true) {
            var result = ServerUnitResult(seq: try serverExchangeState().cursor?.seq ?? 0)
            let projector = try unitProjector(context: context, now: now)
            projector.history = history
            var scope = ServerProjectionScope()
            for chunk in Self.chunks(opIDs) {
                let ops = ContractJSON.array(chunk.map(ContractJSON.string)).canonicalText
                for row in try database.rows("SELECT op_id, fact, receipt, lineage FROM ntp_retained WHERE op_id IN (SELECT value FROM json_each(?))", [.text(ops)]) {
                    guard let op = row[0].text, let fact = row[1].data else { continue }
                    let type = try ContractJSON.decode(fact)["type"]?.stringValue ?? ""
                    let outcome = try row[2].data.map { try ContractJSON.decode($0) }?["outcome"]?.stringValue
                    // A quarantined fact never reaches the server, whatever its old receipt said: what its overlays
                    // showed as queued is withdrawn like a refused add's (the receipt stays as it is).
                    try scope.withdraw(database, opID: op, type: type, outcome: Self.isUnrestored(row[3].data) ? "rejected" : outcome)
                    result.retired.append(.init(opID: op, type: type, outcome: outcome, reason: nil))
                }
                for overlay in try database.rows("SELECT entity, id, property FROM ntp_overlays WHERE op_id IN (SELECT value FROM json_each(?))", [.text(ops)]) {
                    guard case .text(let entity) = overlay[0], case .text(let id) = overlay[1], case .text(let property) = overlay[2] else { continue }
                    scope.add(overlay: entity, id: id, property: property)
                }
                try database.execute("DELETE FROM ntp_overlays WHERE op_id IN (SELECT value FROM json_each(?))", [.text(ops)])
            }
            for chunk in Self.chunks(Array(deleting)) {
                try database.execute("DELETE FROM ntp_retained WHERE op_id IN (SELECT value FROM json_each(?))",
                                     [.text(ContractJSON.array(chunk.map(ContractJSON.string)).canonicalText)])
            }
            try projector.project(scope)
            let plan = projector.plan
            if !plan.missingSecrets.isEmpty { throw ServerApplyError.missingSecrets(plan.missingSecrets) }
            result.work = plan.work + Self.retirementWork * result.retired.count
            try writePlan(plan, now: now, result: &result)
            return result
        }
        result.lockMilliseconds = Self.milliseconds(started.duration(to: clock.now))
        return result
    }
}
