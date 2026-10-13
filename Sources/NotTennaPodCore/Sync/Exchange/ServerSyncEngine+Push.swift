import Foundation

/// Pushing (PROTOCOL §6.4, as the web client's pusher): contiguous `install_seq` from the
/// acknowledged prefix, facts over the unframed bound framed one part per request, secrets beside their facts,
/// receipts stored durably with their lineage, `dependency_missing` waited on, gaps repaired from the server's
/// watermark. Nothing is ever dropped.
extension ServerSyncEngine {
    /// Pushes until nothing more can be pushed now.
    func push(_ report: inout ServerExchangeReport) async throws {
        try await parkBeforePush()
        // Slots a park, quarantine or transition left to renumber are contiguous before anything is sent.
        try await ServerBlockingSteps.renumber(store)
        for _ in 0..<10_000 {
            guard try await pushOnce(&report) else { return }
        }
    }

    /// While a recovery waits for another device, what the outbox gained since the last park pass
    /// (a draft this exchange's pull materialized) and is chained behind what waits is parked
    /// before anything is sent, so its slot never holds back the slots after it.
    private func parkBeforePush() async throws {
        guard let recovery = try await store.serverRecovery(), !recovery.finished, recovery.caughtUp, recovery.waiting,
              let epoch = recovery.epoch else { return }
        let waiting = try waitingNodes(recovery, epoch: epoch)
        guard !waiting.isEmpty else { return }
        let parked = try await ServerBlockingSteps.park(store, database: databaseURL, behind: waiting, archived: try archivedNames(waiting),
                                                        onlyNew: true, now: clock(), between: betweenSteps)
        if !parked.isEmpty { log("recovery", "\(parked.count) new changes wait behind changes another device may restore") }
    }

    /// One push request. Returns whether it made progress (another request may follow).
    private func pushOnce(_ report: inout ServerExchangeReport) async throws -> Bool {
        // Owed facts (a play load's queue add whose recording failed) are recorded first, so nothing
        // owed is left behind a push; then the durability barrier: no fact is sent before it is durable (PROTOCOL §15.2).
        try await store.replayOwedFacts()
        // Observations a relaunch left listed (PROTOCOL §9.4), one bounded transaction at a time.
        while try await store.recordDeferredObservations(feedID: nil) {}
        try await store.serverDurabilityBarrier()
        try crash("push.barrier")
        let state = try await store.serverExchangeState()
        // A `version_unsupported` pause that refused something else lets pushes go on.
        if let pause = state.pause, !(pause == .versionUnsupported && state.permits(.push)) { report.pause = pause; return false }
        guard let cursor = state.cursor else { return false }
        let bounds = state.bounds
        let limit = min(operationLimit ?? bounds.maxOperations, bounds.maxOperations)
        let entries = try await store.serverOutbox(after: state.acked, limit: limit)
        guard !entries.isEmpty else { return false }
        var operations: [ContractJSON] = []
        var included: [ServerOutboxEntry] = []
        var bytes = 1_024
        for entry in entries {
            if entry.bytes.count > bounds.maxUnframedFactBytes {
                guard operations.isEmpty else { break }
                // A framed fact goes alone, one part per request; its transaction ID is persisted before the first part.
                let framing = try await store.serverFraming(installSeq: entry.installSeq, opID: entry.opID)
                try crash("push.framed")
                let parts = stride(from: 0, to: entry.bytes.count, by: bounds.maxPartBytes).map {
                    Array(entry.bytes[$0..<min(entry.bytes.count, $0 + bounds.maxPartBytes)])
                }
                guard parts.count <= bounds.maxPartCount else {
                    // Larger than the server accepts in any framing: a phone bug; kept, logged, retried later.
                    log("too_large", "\(ServerLogValue.type(entry.type)) \(entry.bytes.count) bytes")
                    backoff(&report)
                    return false
                }
                let index = (0..<parts.count).first { !framing.present.contains($0) } ?? parts.count - 1
                operations.append(["install_seq": .integer(entry.installSeq),
                                   "part": ["transaction_id": .string(framing.transactionID), "part_index": .integer(Int64(index)),
                                            "part_count": .integer(Int64(parts.count)), "content_hash": .string(entry.contentHash),
                                            "data": .string(ContractBase64URL.encode(parts[index]))]])
                included.append(entry)
                break
            }
            if operations.count >= limit || bytes + entry.bytes.count + 64 > bounds.maxRequestBytes { break }
            operations.append(["install_seq": .integer(entry.installSeq), "fact": try ContractJSON.decode(entry.bytes)])
            included.append(entry)
            bytes += entry.bytes.count + 64
        }
        guard !operations.isEmpty else { return false }
        var secretIDs = Set(included.flatMap(\.secretIDs)).union(extraSecrets)
        var secrets: [ContractJSON] = []
        for id in secretIDs.sorted() {
            guard let secret = try await secret(id) else { secretIDs.remove(id); continue }
            secrets.append(secret)
        }
        var body: ContractObject = ["cursor": .string(cursor.encoded), "install_id": .string(state.installID),
                                    "acked_install_seq": .integer(state.acked), "operations": .array(operations)]
        if !secrets.isEmpty { body["secrets"] = .array(secrets) }
        let answer: ContractJSON
        do {
            answer = try await ServerRequestRefused.mapping(.push) { try await transport.push(.object(body)) }
        } catch let error as ServerExchangeError where error.status == 413 {
            // Lower the request size; a single fact over the bound is framed above (PROTOCOL §6.4).
            operationLimit = max(1, operations.count / 2)
            log("retry", "payload_too_large")
            return operations.count > 1
        }
        try crash("push.response")
        extraSecrets.subtract(secretIDs)
        var record = ServerPushRecord()
        record.watermark = answer["install_watermark"]?.integerValue
        if let head = answer["head"]?.stringValue, let decoded = try? SyncCursor(encoded: head) {
            record.lineage = ["log_id": .string(decoded.logID), "epoch": .integer(decoded.epoch)]
        }
        var progressed = false
        var conflict = false
        /// Nodes a caught-up recovery cannot supply: what waits for them is parked once this answer is recorded (PROTOCOL §6.11).
        var parkBehind = Set<String>()
        for result in answer["results"]?.arrayValue ?? [] {
            guard let seq = result["install_seq"]?.integerValue, let status = result["status"]?.stringValue else { continue }
            let entry = included.first { $0.installSeq == seq }
            switch status {
            case "accepted", "duplicate":
                guard let receipt = result["receipt"] else { continue }
                record.receipts.append((seq, receipt))
                progressed = true
                let outcome = receipt["outcome"]?.stringValue ?? "?"
                log("push", "\(ServerLogValue.type(entry?.type)) \(ServerLogValue.outcome(outcome))" + ServerLogValue.reason(receipt["reason"]?.stringValue))
            case "part_stored":
                record.partsPresent.append((seq, (result["parts_present"]?.arrayValue ?? []).compactMap { $0.integerValue.map(Int.init) }))
                progressed = true
            case "dependency_missing":
                let missing = (result["missing"]?.arrayValue ?? []).compactMap(\.stringValue)
                record.waiting = (seq, missing)
                report.waitingForDependencies = true
                var held = false
                let recovery = try await store.serverRecovery()
                for id in missing {
                    if try await secret(id) != nil, !secretIDs.contains(id) { extraSecrets.insert(id); held = true }
                    else if try await store.serverSecretCredential(id) != nil { continue }
                    else if recovery?.unrestored.contains(id) == true || recovery?.missingNodes.contains(id) == true {
                        // One a recovery could not restore waits (another recovery could not either, PROTOCOL §6.11).
                        continue
                    } else if let recovery, recovery.caughtUp, !recovery.finished, try !archive.contains(node: id),
                              try await store.serverRetainedEntries().contains(where: { $0.opID == id }) == false {
                        // A recovery that caught up cannot supply a node it never held: what names it waits, parked,
                        // until another device restores it, and the slots after it keep moving.
                        parkBehind.insert(id)
                    } else if try await store.serverKnowsNode(id) || archive.contains(node: id) {
                        // The server lost a node this library holds; its lineage check normally reports it first (PROTOCOL §6.4).
                        try await store.setServerPause(.dependencyLost)
                        report.pause = .dependencyLost
                        log("paused", "\(ServerPauseReason.dependencyLost.rawValue) \(ContractIdentity.isUUID(id) ? id : "?")")
                    }
                }
                if !parkBehind.isEmpty { record.waiting = nil }
                if held || !parkBehind.isEmpty { progressed = true; report.waitingForDependencies = false }
                else if report.pause == nil { log("waiting", "\(ServerLogValue.type(entry?.type)) for \(missing.count) dependencies"); backoff(&report) }
            case "version_unsupported":
                try await store.refuseServerRequest(.push, refusedProtocol: nil)
                report.pause = .versionUnsupported
                log("paused", "\(ServerPauseReason.versionUnsupported.rawValue) \(ServerLogValue.type(entry?.type))")
            case "gap":
                // The server consumed less than this library believes: resend from its watermark (PROTOCOL §6.4). Progress
                // only if that lowers the acknowledgement; a slot this library no longer holds cannot be repaired.
                record.gap = true
                if let watermark = record.watermark, watermark < state.acked { progressed = true }
                log("gap", "watermark \(record.watermark ?? -1)")
            case "installation_conflict":
                conflict = true
            case "op_id_conflict":
                // A phone bug: logged; the slot is consumed and the entry retires with its commit.
                record.consumedWithoutReceipt.append(seq)
                progressed = true
                log("op_id_conflict", ServerLogValue.type(entry?.type))
            case "invalid_part":
                record.resetParts.append(seq)
                progressed = true
                log("retry", "invalid_part")
            default:
                log("push", ServerLogValue.status(status))
            }
        }
        try await store.recordServerPush(record)
        try crash("push.recorded")
        if !parkBehind.isEmpty {
            try await store.updateServerRecovery { $0.missingNodes = Array(Set($0.missingNodes).union(parkBehind)).sorted(); $0.waiting = true }
            // Behind everything the recovery still waits for, so no frontier repair brings a waiting node back.
            var behind = parkBehind
            if let recovery = try await store.serverRecovery(), let epoch = recovery.epoch { behind.formUnion(try waitingNodes(recovery, epoch: epoch)) }
            let parked = try await ServerBlockingSteps.park(store, database: databaseURL, behind: behind, archived: try archivedNames(behind), now: clock(),
                                                            between: betweenSteps)
            log("recovery", "\(parked.count) changes wait for \(parkBehind.count) changes another device may restore")
        }
        report.acknowledged += record.receipts.count
        if conflict {
            try await store.setServerPause(.transportConflict)
            report.pause = .transportConflict
            log("paused", "\(ServerPauseReason.transportConflict.rawValue) installation_conflict")
            return false
        }
        return progressed && report.pause == nil
    }

    /// A secret beside its facts (PROTOCOL §15.2): `{secret_id, username, password, approved_origins}` from the library's
    /// credential. Never logged.
    func secret(_ id: String) async throws -> ContractJSON? {
        guard let mapped = try await store.serverSecretCredential(id),
              let value = try? vault.password(id: mapped.credentialID),
              let credentials = try? JSONDecoder().decode(FeedCredentials.self, from: Data(value.utf8)) else { return nil }
        return ["secret_id": .string(id), "username": .string(credentials.username ?? ""), "password": .string(credentials.password ?? ""),
                "approved_origins": .array(mapped.approvedOrigins.map(ContractJSON.string))]
    }
}
