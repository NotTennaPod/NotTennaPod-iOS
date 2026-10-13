import Foundation

/// Recovery after a server restore (PROTOCOL §6.11–9, PROTOCOL §6.11): after the installation
/// transition committed, the library asks for a recovery snapshot, tells the server what it holds (every archived fact
/// and decision and every retained entry, in receipt order, `bounds.recovery_inventory` at a time), uploads what the
/// server lacks with its original receipt, catches up, pushes its renumbered outbox under `T'` and finishes, saying
/// whether everything was restored. Every step resumes from the live database (`ntp_library.recovery`, the cursor,
/// the outbox, `ntp_retained`) and the per-entry progress in `sync.sqlite`; the library, its outbox, its retained
/// entries and its saved playback are never discarded.
extension ServerSyncEngine {
    /// Where the recovery stands, for the page (PROTOCOL §15.5).
    func recoveryProgress() async -> ServerRecoveryProgress? {
        guard let recovery = try? await store.serverRecovery() else { return nil }
        if !recovery.finished { return recovery.waiting ? .waiting : .running }
        return recovery.complete == false ? .incomplete : nil
    }

    /// The requests a recovery needs next (PROTOCOL §6.11): before it caught up, the successor installation, its own requests, the
    /// catch-up pull and the secrets what it applies names; after, the push of its outbox, the pull that catches up with
    /// what it restores later, those secrets and its finish.
    static func recoveryNeeds(caughtUp: Bool) -> Set<ServerRefusedRequest> {
        caughtUp ? [.push, .pull, .secret, .recovery] : [.installation, .recovery, .pull, .secret]
    }

    /// Whether a request the recovery needs next was refused with `version_unsupported`: it waits for an explicit retry
    /// or an update.
    static func recoveryBlocked(_ state: ServerExchangeState, caughtUp: Bool) -> Bool {
        !recoveryNeeds(caughtUp: caughtUp).allSatisfy(state.permits)
    }

    /// Whether the unfinished recovery waits for an explicit retry or an update, for the report (no processing time).
    func recoveryWaitsForRetry(_ state: ServerExchangeState?) async -> Bool {
        guard let state, let recovery = try? await store.serverRecovery(), !recovery.finished else { return false }
        return Self.recoveryBlocked(state, caughtUp: recovery.caughtUp)
    }

    /// Catches up through every later commit (PROTOCOL §6.11): pulls to the server's head and applies every commit up
    /// to it. True only on positive evidence: the server answered a verified view of its head in this exchange and
    /// every archived commit is applied. A pull or secret the server refused, a gate, a pause, a publication that waits
    /// or a retry is not a catch-up: retiring what was restored, releasing holds, `caughtUp` and the finish wait for
    /// one.
    func catchUp(_ report: inout ServerExchangeReport) async throws -> Bool {
        for _ in 0..<2 {
            let reach = try await pull(&report)
            let applied = try await applyPending(&report)
            guard applied, !report.waiting, report.pause == nil, report.retryAfter == nil else { return false }
            switch reach {
            case .head: return true
            // What an earlier pull archived is applied now; the server is asked next.
            case .pendingFirst: continue
            case .blocked: return false
            }
        }
        return false
    }

    /// Steps 4–7 of the recovery the live library records. Returns whether the exchange may go on (its outbox may be
    /// pushed): false while the recovery has not caught up yet (it waits, the report says for what).
    func recover(_ report: inout ServerExchangeReport, _ keychain: ServerInstallationKeychain) async throws -> Bool {
        guard var recovery = try await store.serverRecovery(), !recovery.finished else { return true }
        report.recovery = recovery.waiting ? .waiting : .running
        // A quarantine an interruption left part-way finishes first, before anything is sent: the rest of its closure
        // (with what the person recorded meanwhile), its frontier and writer repairs, then its overlays.
        try await resumeQuarantine(recovery)
        recovery = try await store.serverRecovery() ?? recovery
        try await withdrawUnrestored(&report)
        if recovery.caughtUp {
            // While entries wait, what the outbox gained since (a draft materialized) and names them is parked before the
            // push, so the slots after it keep moving.
            if recovery.waiting, let epoch = recovery.epoch { try await park(try waitingNodes(recovery, epoch: epoch)) }
            return true
        }
        let state = try await store.serverExchangeState()
        // A request the recovery needs that the server refused (`version_unsupported`) waits for an explicit retry or an
        // update: nothing of the recovery is prepared or sent again meanwhile.
        if Self.recoveryBlocked(state, caughtUp: false) { return false }
        // Step 4: the recovery snapshot's first answer opens (or resumes) the recovery: the prefix shortcut, or a full
        // snapshot, whose epoch keys the inventory. A full one is downloaded only after the uploads (step 7).
        let opened = try await openRecovery(&recovery, state: state, spoolingTo: nil)
        try crash("recovery.opened")
        guard let epoch = recovery.epoch else { return false }
        try archive.clearRecoveryProgress(except: recovery.recoveryID)
        // Steps 5 and 6: inventory, then upload what the server needs.
        let from = recovery.from.flatMap { try? SyncCursor(encoded: $0) }
        let scope = recovery.prefix == true && recovery.cause == .lineageMismatch ? from.map { ($0.epoch, $0.seq) } : nil
        let items = try await recoveryItems(after: scope)
        try await inventory(items, recovery: recovery, epoch: epoch, bounds: state.bounds)
        try crash("recovery.inventoried")
        var outcome = try await upload(items, recovery: recovery, epoch: epoch, bounds: state.bounds)
        try crash("recovery.uploaded")
        // Step 7: a full recovery switches its base to the server's library as it is after the uploads (PROTOCOL §1.3, §6:
        // the union is staged before the switch). The backup's snapshot on its own lacks what the uploads restored, and
        // switching to it would remove those podcasts and episodes from the live library and add them back new, with
        // their downloads lost. Then it catches up through every later commit.
        if case .full = opened, let live = state.cursor {
            // What waits for another device keeps showing through the switch: its records are
            // held as this library has them (unchanged holds are not written again: a kept switch stays publishable).
            try await holdWaiting(recovery, epoch: epoch)
            try crash("recovery.held")
            if let kept = keptFull, kept.recoveryID == recovery.recoveryID, kept.head.epoch == epoch, try await keptFullIsLive(kept) {
                // The switch built at an earlier exchange and kept (over the budget while the app was in use or audio
                // played, or deferred by local changes since): published as it was built, never built again while the
                // cursor it replaces is live.
                guard try await publishKeptRecovery(kept, &report) else { return false }
            } else {
                // Anything kept was built on another cursor or for another recovery: it goes, with a shadow kept for a
                // commit of the base this switch replaces and the staging of its podcasts.
                try await dropKeptFull()
                try await dropKeptShadow()
                try await discardStaging()
                let folder = staging.appendingPathComponent("recovery", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                if case .full(let downloaded) = try await openRecovery(&recovery, state: state, spoolingTo: folder), let snapshot = downloaded {
                    let head = try SyncCursor(encoded: snapshot.head)
                    guard head.epoch == epoch else { return false }
                    guard try await publishReprojection(snapshot, head: head, replacing: live, recoveryID: recovery.recoveryID, &report) else {
                        return false
                    }
                    log("recovery", "the library's base is the restored server's at \(head.seq), with what this library restored")
                }
            }
        }
        // Only a catch-up that reached the server's head and applied everything to it lets what the uploads restored
        // give way to the base.
        guard try await catchUp(&report) else { return false }
        try crash("recovery.caught_up")
        try await retireRecovered(items, recovery: recovery, epoch: epoch, &report)
        // What the server refused for good can never be restored: quarantined at once, with what depends on it.
        if !outcome.refused.isEmpty {
            outcome = try await quarantine(Set(outcome.refused), items, recovery: &recovery, epoch: epoch, reason: "refused", &report)
        }
        // What waits for another device keeps its overlays; the outbox facts chained behind it are parked, and what an
        // earlier recovery parked goes back to the outbox once nothing it names waits.
        _ = try await settle(outcome, &recovery, epoch: epoch, &report)
        recovery.caughtUp = true
        try await store.updateServerRecovery { $0 = recovery }
        log("recovery", "caught up: \(outcome.recovered) changes restored" + (outcome.problems > 0 ? ", \(outcome.problems) could not be restored" : "")
            + (outcome.unresolved > 0 ? ", \(outcome.unresolved) wait for another device to restore what they depend on" : ""))
        caughtUpNow = true
        return true
    }

    /// The outcome so far, in the record: what waits, what could not be restored.
    private func note(_ outcome: RecoveryOutcome, _ recovery: inout ServerRecoveryRecord) {
        recovery.missingNodes = recovery.missingNodes.filter { (try? archive.contains(node: $0)) != true }
        recovery.waiting = outcome.unresolved > 0 || !recovery.missingNodes.isEmpty
        recovery.problems = outcome.problems
        // Whatever was quarantined (counted with the quarantine) was not restored, whether or not an entry of this
        // inventory still stands for it.
        recovery.complete = outcome.problems == 0 && recovery.quarantined == 0 && !recovery.waiting
        recovery.unrestored = Array(outcome.unrestored.prefix(ServerRecoveryRecord.unrestoredLimit))
    }

    /// After the library caught up with what the upload restored: the outcome is noted; the outbox facts chained behind
    /// what still waits are parked; parked facts (this recovery's, or an earlier one's that a second restore replaced)
    /// whose waiting is over go back to the end of the outbox, to be pushed next; a parked fact keeps the recovery
    /// waiting (it is not restored until it reached the server); holds of what no longer waits end. Returns how many
    /// facts went back to the outbox.
    private func settle(_ outcome: RecoveryOutcome, _ recovery: inout ServerRecoveryRecord, epoch: Int64,
                        _ report: inout ServerExchangeReport) async throws -> Int {
        note(outcome, &recovery)
        let waiting = try waitingNodes(recovery, epoch: epoch)
        if !waiting.isEmpty { try await park(waiting) }
        let unparked = try await ServerBlockingSteps.unpark(store, database: databaseURL, stillWaiting: waiting)
        try crash("recovery.unparked")
        if !unparked.isEmpty { log("recovery", "\(unparked.count) waiting changes are sent now") }
        // What joined comes back into the frontier (taken out while it waited), so a later cut observes it.
        let out = Set(try ServerBlockingSteps.read(databaseURL) { try FeedLibraryStore.blockedOutNodes($0) }).subtracting(waiting)
        if !out.isEmpty {
            let archived = try archivedNames(out)
            let plan = try ServerBlockingSteps.read(databaseURL) { try FeedLibraryStore.rejoinPlan($0, Array(out), stillWaiting: waiting, archived: archived) }
            for batch in FeedLibraryStore.chunks(plan.covered, size: FeedLibraryStore.blockedBatch) { try await store.setServerFrontier(batch, to: 0) }
            for batch in FeedLibraryStore.chunks(plan.tips, size: FeedLibraryStore.blockedBatch) { try await store.setServerFrontier(batch, to: 1) }
        }
        if try await !store.parkedFacts().isEmpty { recovery.waiting = true; recovery.complete = false }
        try await releaseHolds(waiting, &report)
        return unparked.count
    }

    /// What the server lacks and another device may still restore: this recovery's entries still waiting, the nodes
    /// they named that this library never held (until a pull brings them here), and the nodes a push found missing.
    func waitingNodes(_ recovery: ServerRecoveryRecord, epoch: Int64) throws -> Set<String> {
        let progress = try archive.recoveryProgress(recovery: recovery.recoveryID, epoch: epoch)
        var waiting = Set<String>(), named = Set(recovery.missingNodes)
        for (key, value) in progress where !value.isRecovered && !value.isProblem {
            waiting.insert(String(key.drop { $0 != "/" }.dropFirst()))
            named.formUnion(value.missing ?? [])
        }
        let entries = Set(progress.keys.map { String($0.drop { $0 != "/" }.dropFirst()) })
        for node in named {
            if entries.contains(node) {
                if progress["fact/\(node)"].map({ !$0.isRecovered && !$0.isProblem }) ?? progress["decision/\(node)"].map({ !$0.isRecovered && !$0.isProblem }) ?? false {
                    waiting.insert(node)
                }
            } else if try !archive.contains(node: node) {
                waiting.insert(node)
            }
        }
        return waiting
    }

    /// Holds the base records the waiting nodes' changes set (`holdServerRecords`), scanned outside the store.
    private func holdWaiting(_ recovery: ServerRecoveryRecord, epoch: Int64) async throws {
        let nodes = try waitingNodes(recovery, epoch: epoch)
        let records = try FeedLibraryStore.serverRecords(naming: nodes, database: databaseURL)
        guard !records.isEmpty else { return }
        // 500 to a store call (each one transaction), so a playback save waits for one at most.
        for chunk in FeedLibraryStore.chunks(records) { try await store.holdServerRecords(chunk) }
        log("recovery", "\(records.count) records keep showing what \(nodes.count) changes waiting for another device did")
    }

    /// Ends the holds of changes that no longer wait (`releaseServerHolds`), in units, once the library caught up with
    /// what joined.
    func releaseHolds(_ waiting: Set<String>, _ report: inout ServerExchangeReport) async throws {
        var released = 0
        while let result = try await store.releaseServerHolds(stillWaiting: waiting, history: history, now: now()) {
            record(result, into: &report)
            released += 1
        }
        if released > 0 { log("recovery", "what changes that no longer wait showed is the server's again") }
    }

    /// Holds a finished recovery left because newer local work kept them end once that work resolved, and
    /// podcast merges this library's pending discovery work deferred complete once that work was
    /// applied.
    func releaseLeftHolds(_ report: inout ServerExchangeReport, caughtUp: Bool) async throws {
        // Bounded: a few completions an exchange, one store unit each, paced while audio plays; the rest at the next.
        for candidate in try ServerDeferredMerges.candidates(databaseURL).prefix(ServerDeferredMerges.perExchange) {
            try Task.checkCancellation()
            try await pace()
            if let result = try await ServerDeferredMerges.step(store, database: databaseURL, candidate: candidate, history: history, now: now()) {
                record(result, into: &report)
            }
        }
        if let recovery = try await store.serverRecovery(), !recovery.finished { return }
        // The base they give way to holds what they kept only once this exchange caught up with the server.
        guard caughtUp, try await store.serverHeldRecordCount() > 0 else { return }
        try await releaseHolds([], &report)
    }

    /// Parks the outbox facts chained behind `waiting` (`parkWaitingFacts`): out of the slot order, unchanged.
    func park(_ waiting: Set<String>) async throws {
        guard !waiting.isEmpty else { return }
        let parked = try await ServerBlockingSteps.park(store, database: databaseURL, behind: waiting, archived: try archivedNames(waiting), now: clock(),
                                                        between: betweenSteps)
        if !parked.isEmpty { log("recovery", "\(parked.count) changes wait behind changes another device may restore; later ones are sent meanwhile") }
        try crash("recovery.parked")
    }

    /// What the nodes among `nodes` that the archive holds name (their previous facts and dependencies): the store
    /// repairs the frontier through them.
    func archivedNames(_ nodes: Set<String>) throws -> [String: Set<String>] {
        var names: [String: Set<String>] = [:]
        for node in nodes where try archive.contains(node: node) { names[node] = try archive.dependencies(of: node) }
        return names
    }

    // MARK: - Step 4

    /// A full snapshot is spooled only when asked for (after the uploads): the first answer just tells which.
    private enum Opened { case prefix, full(ServerAttachSnapshot?) }

    /// `POST /v1/snapshot {mode: recovery, recovery_id, install_id: T', cursor, acked_install_seq}`. With
    /// `prefix: true` the cursor is re-issued in the current epoch and the library catches up by pulls (PROTOCOL §6.11);
    /// otherwise the snapshot is full, spooled to `folder` when one is given (a request without a page builds the
    /// server's library as it is now; without a folder only one item is asked for). The answer's epoch keys the
    /// per-entry progress: a server restored again since makes the earlier answers stale. A recovery the server has
    /// bound to another installation (one copied with the library) starts under a new ID.
    private func openRecovery(_ recovery: inout ServerRecoveryRecord, state: ServerExchangeState, spoolingTo folder: URL?) async throws -> Opened {
        for attempt in 0..<2 {
            var body: ContractObject = ["mode": "recovery", "recovery_id": .string(recovery.recoveryID), "install_id": .string(state.installID),
                                        "acked_install_seq": .integer(state.acked)]
            if let cursor = state.cursor { body["cursor"] = .string(cursor.encoded) }
            if folder == nil { body["limit"] = 1 }
            let first: ContractJSON
            do { first = try await gated(.recovery) { try await transport.snapshot(.object(body)) } }
            catch let error as ServerExchangeError where error.status == 403 && attempt == 0 {
                recovery.restartPhases()
                let replaced = recovery
                try await store.updateServerRecovery { $0 = replaced }
                continue
            }
            if first["prefix"]?.boolValue == true {
                guard let reissued = first["cursor"]?.stringValue.flatMap({ try? SyncCursor(encoded: $0) }),
                      let head = first["head"]?.stringValue.flatMap({ try? SyncCursor(encoded: $0) }) else {
                    throw ServerSnapshotError.invalidSnapshot("a prefix answer without its cursor")
                }
                try await note(&recovery, epoch: head.epoch, prefix: true)
                if state.cursor != reissued {
                    try await store.setServerRecoveryCursor(reissued)
                    try archive.dropPendingCommits(through: Int64.max, logID: "")
                    log("recovery", "the server still holds this library's history up to \(reissued.seq)")
                }
                return .prefix
            }
            guard let folder else {
                guard let head = first["head"]?.stringValue.flatMap({ try? SyncCursor(encoded: $0) }) else {
                    throw ServerSnapshotError.invalidSnapshot("a recovery snapshot without its head")
                }
                try await note(&recovery, epoch: head.epoch, prefix: false)
                return .full(nil)
            }
            // A full snapshot: its first page is the one just answered.
            let firstPage = SendableBox(first)
            let transport = transport, request = body
            let snapshot = try await ServerSnapshotDownload(folder: folder, fetch: { page in
                if page == nil, let answer = firstPage.take() { return answer }
                var body = request
                if let page { body["page"] = .string(page) }
                return try await ServerRequestRefused.mapping(.recovery) { try await transport.snapshot(.object(body)) }
            }, isViewExpired: { ($0 as? ServerExchangeError)?.code == "view_expired" }).run()
            let head = try SyncCursor(encoded: snapshot.head)
            try await note(&recovery, epoch: head.epoch, prefix: false)
            log("recovery", "the server's library is restored from a snapshot at \(head.seq)")
            return .full(snapshot)
        }
        throw ServerExchangeError.server(status: 403, code: "forbidden", retryAfter: nil)
    }

    /// The answer's epoch: a new one (the first answer, or the server restored again since) starts the inventory under
    /// it. A full recovery that already switched its base answers as a prefix afterwards; it stays what it was, and
    /// so does its inventory's scope (the whole archive) when it starts again (a copy's).
    private func note(_ recovery: inout ServerRecoveryRecord, epoch: Int64, prefix: Bool) async throws {
        guard recovery.epoch != epoch else { return }
        if recovery.epoch != nil { log("recovery", "the server was restored again: the inventory starts again") }
        recovery.epoch = epoch
        recovery.prefix = (recovery.prefix ?? true) && prefix
        let noted = recovery
        try await store.updateServerRecovery { $0 = noted }
    }

    // MARK: - Step 5: inventory

    /// A recovery entry: an archived fact or decision, or a retained entry the archive does not hold.
    struct RecoveryEntry: Sendable {
        var item: ServerArchive.RecoveryItem
        var retained: FeedLibraryStore.ServerRetainedEntry?
        var key: String { "\(item.kind.rawValue)/\(item.id)" }
    }

    /// Every entry the recovery tells the server about, in receipt order: the archive's facts and decisions (those
    /// received after `after` only, for a prefix recovery), and the retained entries. A quarantined retained entry is
    /// listed too, never inventoried or uploaded again: its refusal stays in the outcome.
    private func recoveryItems(after: (Int64, Int64)?) async throws -> [RecoveryEntry] {
        var entries: [String: RecoveryEntry] = [:]
        for item in try archive.recoveryItems(after: after.map { (epoch: $0.0, seq: $0.1) }) {
            entries["\(item.kind.rawValue)/\(item.id)"] = RecoveryEntry(item: item)
        }
        for retained in try await store.serverRetainedEntries() where !retained.parked {
            guard let position = retained.position else { continue }
            let key = "fact/\(retained.opID)"
            if var archived = entries[key] { archived.retained = retained; entries[key] = archived; continue }
            if try archive.contains(node: retained.opID), let receipt = try archive.receipt(opID: retained.opID),
               let epoch = receipt["epoch"]?.integerValue, let seq = receipt["seq"]?.integerValue {
                // Archived before the prefix: the archive's receipt (an original may have replaced the provisional one).
                let hash = try receipt["content_hash"]?.stringValue ?? ContractIdentity.sha256Hex(retained.fact.canonicalBytes())
                entries[key] = RecoveryEntry(item: .init(kind: .fact, id: retained.opID, contentHash: hash, epoch: epoch, seq: seq,
                                                         index: receipt["index"]?.integerValue ?? 0), retained: retained)
                continue
            }
            let hash = try retained.receipt?["content_hash"]?.stringValue ?? ContractIdentity.sha256Hex(retained.fact.canonicalBytes())
            entries[key] = RecoveryEntry(item: .init(kind: .fact, id: retained.opID, contentHash: hash, epoch: position.epoch,
                                                     seq: position.seq, index: position.index), retained: retained)
        }
        return entries.values.sorted { ServerArchive.RecoveryItem.receiptOrder($0.item, $1.item) }
    }

    /// `POST /v1/sync/recovery/inventory` for every entry without an answer in this epoch, a page at a time: `have`,
    /// `need` or `conflict`, recorded durably per page.
    private func inventory(_ entries: [RecoveryEntry], recovery: ServerRecoveryRecord, epoch: Int64, bounds: ServerBounds) async throws {
        let progress = try archive.recoveryProgress(recovery: recovery.recoveryID, epoch: epoch)
        let open = entries.filter { progress[$0.key] == nil && $0.retained?.unrestored != true }
        let page = max(1, bounds.recoveryInventory)
        for start in stride(from: 0, to: open.count, by: page) {
            try Task.checkCancellation()
            let batch = Array(open[start..<min(open.count, start + page)])
            let answer = try await gated(.recovery) {
                try await transport.send("POST", "v1/sync/recovery/inventory", body: [
                    "recovery_id": .string(recovery.recoveryID), "entries": .array(batch.map(\.item.inventory))])
            }
            var statuses: [String: String] = [:]
            for result in answer["results"]?.arrayValue ?? [] {
                if let kind = result["kind"]?.stringValue, let id = result["id"]?.stringValue, let status = result["status"]?.stringValue {
                    statuses["\(kind)/\(id)"] = status
                }
            }
            let values = batch.map { entry in
                (entry.item.kind, entry.item.id, ServerArchive.RecoveryProgress(status: statuses[entry.key] ?? "need"))
            }
            try archive.setRecoveryProgress(recovery: recovery.recoveryID, epoch: epoch, values.map { (kind: $0.0, id: $0.1, progress: $0.2) })
            let conflicts = values.filter { $0.2.status == "conflict" }.count
            if conflicts > 0 { log("recovery", "\(conflicts) entries differ from the server's: kept here, never uploaded") }
        }
    }

    // MARK: - Step 6: upload

    struct RecoveryOutcome {
        var recovered = 0, problems = 0, unresolved = 0
        /// What could not be restored, in receipt order.
        var unrestored: [String] = []
        /// What the server refused for good (`conflict`, `invalid_receipt`, `invalid`): quarantined at once.
        var refused: [String] = []
        /// Entries this call restored (progress, for the waiting bound's clock).
        var restoredNow = 0
    }

    /// Uploads every entry the server needs, in receipt order (causal order), with original receipts, the secrets the
    /// facts name beside them, and a fact over the unframed bound in parts, one per request. `dependency_missing`
    /// uploads what it names first (a later entry of this recovery, or a secret) and tries again while passes make
    /// progress; what still waits is unresolved, and the recovery is not complete.
    private func upload(_ entries: [RecoveryEntry], recovery: ServerRecoveryRecord, epoch: Int64, bounds: ServerBounds) async throws -> RecoveryOutcome {
        var progress = try archive.recoveryProgress(recovery: recovery.recoveryID, epoch: epoch)
        let before = Set(entries.filter { progress[$0.key]?.isRecovered == true }.map(\.key))
        let retry: Set<String> = ["need", "dependency_missing", "part_stored", "invalid_part"]
        var secrets: Set<String> = []
        for _ in 0..<8 {
            let pending = entries.filter { $0.retained?.unrestored != true && progress[$0.key].map { retry.contains($0.status) } ?? false }
            guard !pending.isEmpty else { break }
            var changed = false
            var index = 0
            while index < pending.count {
                try Task.checkCancellation()
                let first = pending[index]
                if first.item.kind == .fact, let fact = try entryJSON(first)?.fact, try fact.canonicalBytes().count > bounds.maxUnframedFactBytes {
                    index += 1
                    let result = try await uploadParts(first, progress: progress[first.key], recovery: recovery, epoch: epoch, bounds: bounds,
                                                       secrets: secrets)
                    if try await noteUpload(result, for: first, recovery: recovery, epoch: epoch, progress: &progress, secrets: &secrets) { changed = true }
                    continue
                }
                var batch: [RecoveryEntry] = [], objects: [ContractJSON] = [], bytes = 1_024
                while index < pending.count, batch.count < bounds.maxOperations {
                    let entry = pending[index]
                    let factBytes = try entryJSON(entry)?.fact.canonicalBytes().count ?? 0
                    guard let object = try uploadObject(entry), factBytes <= bounds.maxUnframedFactBytes else { break }
                    let size = try object.canonicalBytes().count + 1
                    if !batch.isEmpty, bytes + size > bounds.maxRequestBytes { break }
                    batch.append(entry); objects.append(object); bytes += size; index += 1
                }
                if batch.isEmpty {
                    // An entry the archive no longer holds is unresolved; nothing to send for it.
                    index += 1
                    continue
                }
                var body: ContractObject = ["recovery_id": .string(recovery.recoveryID), "entries": .array(objects)]
                let named = try await secretPayloads(Set(batch.flatMap { secretIDs($0) }).union(secrets))
                if !named.isEmpty { body["secrets"] = .array(named) }
                let answer = try await gated(.recovery) { try await transport.send("POST", "v1/sync/recovery/upload", body: .object(body)) }
                try crash("recovery.upload.response")
                var results: [String: ContractJSON] = [:]
                for result in answer["results"]?.arrayValue ?? [] {
                    if let kind = result["kind"]?.stringValue, let id = result["id"]?.stringValue { results["\(kind)/\(id)"] = result }
                }
                for entry in batch {
                    if try await noteUpload(results[entry.key], for: entry, recovery: recovery, epoch: epoch, progress: &progress,
                                            secrets: &secrets) { changed = true }
                }
            }
            if !changed { break }
        }
        var outcome = Self.outcome(entries, progress)
        outcome.restoredNow = entries.filter { progress[$0.key]?.isRecovered == true && !before.contains($0.key) }.count
        return outcome
    }

    /// The recovery's entries are those its inventory answered: one archived since (a later pull) is not part of it.
    static func outcome(_ entries: [RecoveryEntry], _ progress: [String: ServerArchive.RecoveryProgress]) -> RecoveryOutcome {
        var outcome = RecoveryOutcome()
        for entry in entries {
            if entry.retained?.unrestored == true, progress[entry.key]?.isProblem != true {
                // Quarantined already, by this recovery or an earlier one: durable evidence it was not restored.
                outcome.problems += 1
                outcome.unrestored.append(entry.item.id)
                continue
            }
            guard let value = progress[entry.key] else { continue }
            if value.isRecovered { outcome.recovered += 1; continue }
            if value.isProblem {
                outcome.problems += 1
                if value.status != ServerArchive.RecoveryProgress.blocked { outcome.refused.append(entry.item.id) }
            } else { outcome.unresolved += 1 }
            outcome.unrestored.append(entry.item.id)
        }
        return outcome
    }

    /// Records one entry's upload result durably. Returns whether a later pass can do more: a final answer (which may
    /// be what another entry waited for), a secret it named that this library holds, or a part to send next.
    private func noteUpload(_ result: ContractJSON?, for entry: RecoveryEntry, recovery: ServerRecoveryRecord, epoch: Int64,
                            progress: inout [String: ServerArchive.RecoveryProgress], secrets: inout Set<String>) async throws -> Bool {
        var value = progress[entry.key] ?? .init(status: "need")
        let status = result?["status"]?.stringValue ?? "invalid"
        value.status = status
        var more = false
        switch status {
        case "dependency_missing":
            value.missing = (result?["missing"]?.arrayValue ?? []).compactMap(\.stringValue)
            for id in value.missing ?? [] where !secrets.contains(id) {
                if try await store.serverSecretCredential(id) != nil { secrets.insert(id); more = true }
            }
        case "part_stored", "invalid_part":
            if status == "invalid_part" { value.framing = nil }
            more = true
        default:
            value.missing = nil
            if value.isRecovered || value.isProblem { value.framing = nil; more = true }
        }
        progress[entry.key] = value
        try archive.setRecoveryProgress(recovery: recovery.recoveryID, epoch: epoch, [(entry.item.kind, entry.item.id, value)])
        if value.isProblem {
            // A retained fact may be another device's, as the server sent it: its type only when it is one (PROTOCOL §15.5).
            let type = entry.retained.map { " " + ServerLogValue.type($0.type) } ?? ""
            log("recovery", "\(entry.item.kind.rawValue)\(type) not restored: \(ServerLogValue.recoveryProblem(status))")
        }
        return more
    }

    /// The entry as an upload carries it: `{fact, receipt}` or `{decision}`.
    private func uploadObject(_ entry: RecoveryEntry) throws -> ContractJSON? {
        switch entry.item.kind {
        case .decision:
            return try archive.decision(entry.item.id).map { ["decision": $0] }
        case .fact:
            return try entryJSON(entry).map { ["fact": $0.fact, "receipt": $0.receipt] }
        }
    }

    private func entryJSON(_ entry: RecoveryEntry) throws -> (fact: ContractJSON, receipt: ContractJSON)? {
        guard entry.item.kind == .fact else { return nil }
        if let archived = try archive.factEntry(entry.item.id) { return archived }
        guard let retained = entry.retained, let receipt = retained.receipt else { return nil }
        return (retained.fact, receipt)
    }

    /// The secrets a fact names (a subscription's credentials, a credentials change, PROTOCOL §15.2), and a retained entry's.
    private func secretIDs(_ entry: RecoveryEntry) -> [String] {
        guard let fact = try? entryJSON(entry)?.fact else { return entry.retained?.secretIDs ?? [] }
        let payload = fact["payload"]
        return (entry.retained?.secretIDs ?? []) + ["secret_id", "credentials_secret"].compactMap { payload?[$0]?.stringValue }
    }

    /// `{secret_id, username, password, approved_origins}` for each secret this library holds (PROTOCOL §15.4).
    private func secretPayloads(_ ids: Set<String>) async throws -> [ContractJSON] {
        var result: [ContractJSON] = []
        for id in ids.sorted() { if let secret = try await secret(id) { result.append(secret) } }
        return result
    }

    /// The next part of a fact over the unframed bound, with its receipt (PROTOCOL §6.11): a framing transaction chosen once
    /// and kept with the entry's progress, parts sized so each request fits.
    private func uploadParts(_ entry: RecoveryEntry, progress: ServerArchive.RecoveryProgress?, recovery: ServerRecoveryRecord, epoch: Int64,
                             bounds: ServerBounds, secrets: Set<String>) async throws -> ContractJSON? {
        guard let json = try entryJSON(entry) else { return nil }
        let bytes = try json.fact.canonicalBytes()
        let hash = ContractIdentity.sha256Hex(bytes)
        let receiptBytes = try json.receipt.canonicalBytes().count
        let room = max(1_024, (bounds.maxRequestBytes - receiptBytes - 16 * 1_024) * 3 / 4)
        let size = min(bounds.maxPartBytes, room)
        let count = (bytes.count + size - 1) / size
        guard count <= bounds.maxPartCount else { return ["status": "too_large"] }
        var framing = progress?.framing ?? ServerFraming(transactionID: ContractIdentity.randomUUID(), present: [])
        if progress?.framing == nil {
            var value = progress ?? .init(status: "need")
            value.framing = framing
            try archive.setRecoveryProgress(recovery: recovery.recoveryID, epoch: epoch, [(entry.item.kind, entry.item.id, value)])
        }
        var answer: ContractJSON?
        for _ in 0..<count {
            let index = (0..<count).first { !framing.present.contains($0) } ?? count - 1
            let part: ContractJSON = ["transaction_id": .string(framing.transactionID), "part_index": .integer(Int64(index)),
                                      "part_count": .integer(Int64(count)), "content_hash": .string(hash),
                                      "data": .string(ContractBase64URL.encode(Array(bytes[(index * size)..<min(bytes.count, (index + 1) * size)])))]
            var body: ContractObject = ["recovery_id": .string(recovery.recoveryID), "entries": [["part": part, "receipt": json.receipt]]]
            let named = try await secretPayloads(Set(secretIDs(entry)).union(secrets))
            if !named.isEmpty { body["secrets"] = .array(named) }
            let response = try await gated(.recovery) { try await transport.send("POST", "v1/sync/recovery/upload", body: .object(body)) }
            let result = (response["results"]?.arrayValue ?? []).first { $0["id"]?.stringValue == entry.item.id } ?? response["results"]?.arrayValue?.first
            answer = result
            guard result?["status"]?.stringValue == "part_stored" else { break }
            framing.present = (result?["parts_present"]?.arrayValue ?? []).compactMap { $0.integerValue.map(Int.init) }.sorted()
            if framing.present.isEmpty { framing.present = [index] }
            var value = progress ?? .init(status: "part_stored")
            value.status = "part_stored"
            value.framing = framing
            try archive.setRecoveryProgress(recovery: recovery.recoveryID, epoch: epoch, [(entry.item.kind, entry.item.id, value)])
            try crash("recovery.part")
        }
        return answer
    }

    // MARK: - Step 7: retained entries after the catch-up

    /// Once the library caught up after the uploads, its base holds what the server took: the retained entries the
    /// server holds retire (their overlays go, what they showed is projected from the base) and leave `ntp_retained`
    /// once archived. Those that can never be restored are quarantined instead (`quarantine`); one still waiting for a
    /// dependency keeps its row and overlays, as does a parked fact.
    private func retireRecovered(_ entries: [RecoveryEntry], recovery: ServerRecoveryRecord, epoch: Int64,
                                 _ report: inout ServerExchangeReport) async throws {
        let progress = try archive.recoveryProgress(recovery: recovery.recoveryID, epoch: epoch)
        var retire: [String] = [], delete: Set<String> = []
        for retained in try await store.serverRetainedEntries() where !retained.unrestored && !retained.parked {
            let value = progress["fact/\(retained.opID)"]
            if retained.position == nil || value?.isRecovered == true {
                retire.append(retained.opID)
                let archived = try archive.contains(node: retained.opID)
                if retained.position == nil || archived { delete.insert(retained.opID) }
            }
        }
        for chunk in FeedLibraryStore.chunks(retire, size: 50) {
            let result = try await store.retireServerRetained(chunk, deleting: delete.intersection(chunk), history: history, now: now())
            record(result, into: &report)
        }
    }

    // MARK: - Quarantine

    /// Quarantines what can never be restored: `roots`, and every entry of this recovery not restored that depends on
    /// one of them (through `previous_op_id` or a causal dependency); then this library's own facts naming any of them
    /// (`quarantineUnrestoredFacts`: kept as evidence, never sent; new facts on fresh authors), whose overlays are
    /// withdrawn in one unit. Returns the outcome with the dependents counted as not restorable.
    private func quarantine(_ roots: Set<String>, _ entries: [RecoveryEntry], recovery: inout ServerRecoveryRecord, epoch: Int64, reason: String,
                            _ report: inout ServerExchangeReport) async throws -> RecoveryOutcome {
        var progress = try archive.recoveryProgress(recovery: recovery.recoveryID, epoch: epoch)
        var blocked = roots
        var marks: [(kind: ServerArchive.RecoveryItem.Kind, id: String, progress: ServerArchive.RecoveryProgress)] = []
        // Receipt order is causal order: a dependent follows what it names, so two passes reach every one.
        for _ in 0..<2 {
            for entry in entries where progress[entry.key]?.isRecovered != true {
                if !blocked.contains(entry.item.id) {
                    let names = try entry.retained.map { FeedLibraryStore.named($0.fact) } ?? archive.dependencies(of: entry.item.id)
                    guard !names.isDisjoint(with: blocked) else { continue }
                    blocked.insert(entry.item.id)
                }
                if progress[entry.key]?.isProblem != true {
                    let value = ServerArchive.RecoveryProgress(status: ServerArchive.RecoveryProgress.blocked)
                    progress[entry.key] = value
                    marks.append((entry.item.kind, entry.item.id, value))
                }
            }
        }
        try archive.setRecoveryProgress(recovery: recovery.recoveryID, epoch: epoch, marks)
        let quarantined = try await ServerBlockingSteps.quarantine(store, database: databaseURL, blocked, reason: reason,
                                                                   archived: try archivedNames(blocked),
                                                                   waiting: try waitingNodes(recovery, epoch: epoch).subtracting(blocked), now: clock(),
                                                                   between: betweenSteps)
        recovery.quarantined = try await store.serverRecovery()?.quarantined ?? recovery.quarantined + quarantined.count
        try crash("recovery.quarantined")
        try await withdrawUnrestored(&report)
        log("recovery", "\(blocked.count) changes can never be restored (\(reason)): \(quarantined.count) of this library's kept on this device only; new changes continue")
        return Self.outcome(entries, progress)
    }

    /// Completes a quarantine an interruption left part-way: planned again from everything
    /// quarantined so far, nothing done when nothing is left.
    private func resumeQuarantine(_ recovery: ServerRecoveryRecord) async throws {
        guard try await store.hasUnrestoredServerFacts() else { return }
        let waiting = try recovery.epoch.map { try waitingNodes(recovery, epoch: $0) } ?? []
        let resumed = try await ServerBlockingSteps.quarantine(store, database: databaseURL, [], reason: "refused", archived: [:], waiting: waiting,
                                                               now: clock(), onlyNeeded: true, between: betweenSteps)
        if !resumed.isEmpty { log("recovery", "an interrupted quarantine goes on: \(resumed.count) more changes kept on this device only") }
    }

    /// Withdraws the overlays of quarantined facts and projects what they touched from the base (in units of 50).
    private func withdrawUnrestored(_ report: inout ServerExchangeReport) async throws {
        let ops = try await store.unrestoredWithOverlays()
        for chunk in FeedLibraryStore.chunks(ops, size: 50) {
            let result = try await store.retireServerRetained(chunk, deleting: [], history: history, now: now())
            record(result, into: &report)
        }
    }

    // MARK: - Waiting entries and step 9

    /// After the library caught up and pushed its outbox under `T'` (PROTOCOL §6.11–9). Entries still missing a
    /// dependency another device may restore are uploaded again at later exchanges, with the backoff, indefinitely
    /// (unsent changes never expire); whatever joins is caught up with, and the facts parked behind it go back to the
    /// outbox. Once nothing waits, `POST /v1/sync/recovery/finish {recovery_id, complete}`, true only if nothing ended
    /// refused: otherwise the page says some changes could not be restored, never that everything was. While entries
    /// wait, the server is told `complete: false` once and the page says changes wait for another device.
    func finishRecovery(_ report: inout ServerExchangeReport) async throws {
        guard installations != nil, var recovery = try await store.serverRecovery(), !recovery.finished, recovery.caughtUp,
              let epoch = recovery.epoch else { return }
        if recovery.waiting, !caughtUpNow {
            let from = recovery.from.flatMap { try? SyncCursor(encoded: $0) }
            let scope = recovery.prefix == true && recovery.cause == .lineageMismatch ? from.map { (epoch: $0.epoch, seq: $0.seq) } : nil
            let items = try await recoveryItems(after: scope.map { ($0.epoch, $0.seq) })
            let state = try await store.serverExchangeState()
            var outcome = try await upload(items, recovery: recovery, epoch: epoch, bounds: state.bounds)
            try crash("recovery.retried")
            if outcome.restoredNow > 0 {
                log("recovery", "\(outcome.restoredNow) more changes restored")
                // What joined is applied before anything is retired, released or finished: only once this exchange
                // caught up with it.
                guard try await catchUp(&report) else { return }
            }
            try await retireRecovered(items, recovery: recovery, epoch: epoch, &report)
            if !outcome.refused.isEmpty {
                outcome = try await quarantine(Set(outcome.refused), items, recovery: &recovery, epoch: epoch, reason: "refused", &report)
            }
            let unparked = try await settle(outcome, &recovery, epoch: epoch, &report)
            let noted = recovery
            try await store.updateServerRecovery { $0 = noted }
            if unparked > 0 {
                // What was released goes out before the outcome is decided; a push that finds it still missing a
                // dependency parks it again (and the record says so).
                try await push(&report)
                recovery = try await store.serverRecovery() ?? recovery
            }
        }
        caughtUpNow = false
        // A parked fact has not reached the server: the recovery waits for it whichever way it was parked.
        if !recovery.waiting, try await !store.parkedFacts().isEmpty {
            recovery.waiting = true
            recovery.complete = false
            let noted = recovery
            try await store.updateServerRecovery { $0 = noted }
        }
        if recovery.waiting {
            if !recovery.finishSent {
                _ = try await gated(.recovery) {
                    try await transport.send("POST", "v1/sync/recovery/finish", body: ["recovery_id": .string(recovery.recoveryID), "complete": false])
                }
                recovery.finishSent = true
                let noted = recovery
                try await store.updateServerRecovery { $0 = noted }
            }
            report.recovery = .waiting
            report.waitingForDependencies = true
            backoff(&report)
            return
        }
        // Nothing waits: whatever a hold kept is the server's now.
        try await releaseHolds([], &report)
        let complete = recovery.complete == true && recovery.problems == 0 && recovery.quarantined == 0
        _ = try await gated(.recovery) {
            try await transport.send("POST", "v1/sync/recovery/finish", body: ["recovery_id": .string(recovery.recoveryID), "complete": .bool(complete)])
        }
        try crash("recovery.finish")
        recovery.finished = true
        recovery.complete = complete
        let finished = recovery
        try await store.finishServerRecovery(finished)
        try archive.clearRecoveryProgress(except: nil)
        log("recovery", complete ? "finished: every change was restored"
            : "finished: \(recovery.problems) changes could not be restored, \(recovery.quarantined) of this library's kept on this device only")
        report.recovery = complete ? nil : .incomplete
    }
}

/// A value handed to one `@Sendable` closure call.
final class SendableBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    init(_ value: Value) { self.value = value }
    func take() -> Value? { lock.withLock { defer { value = nil }; return value } }
}

extension FeedLibraryStore {
    /// A prefix recovery's re-issued cursor (PROTOCOL §6.11): the same commit in the current epoch.
    func setServerRecoveryCursor(_ cursor: SyncCursor) throws {
        try database.transaction { try setCursor(cursor, watermark: nil) }
    }

    /// The recovery's end, with an incomplete one listed under "Needs attention" (PROTOCOL §15.5) in the same transaction.
    func finishServerRecovery(_ recovery: ServerRecoveryRecord) throws {
        try database.transaction {
            try Self.storeRecovery(recovery, database)
            guard recovery.complete == false else { return }
            let record: ContractJSON = ["recovery_id": .string(recovery.recoveryID), "problems": .integer(Int64(recovery.problems))]
            try database.execute("INSERT OR REPLACE INTO ntp_attention(id, kind, record, created_at) VALUES (?, 'recovery_incomplete', ?, ?)",
                                 [.text(recovery.recoveryID), .blob(try record.canonicalData()), .integer(Int64(Date().timeIntervalSince1970 * 1_000))])
        }
    }
}
