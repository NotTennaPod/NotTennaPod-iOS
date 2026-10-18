import Foundation

/// Applying archived commits (PROTOCOL §6.8): one commit, one atomic live change. Secrets are
/// fetched before the unit that needs them; the work is estimated outside the live lock; small units apply
/// directly, large ones are built in a shadow and published; while audio plays units are paced, and an over-budget
/// publication waits for the app to leave the foreground, where it is published whole within the background budget, or
/// for a pause or stop.
extension ServerSyncEngine {
    /// Applies archived commits after the live cursor, in order, up to `through` (all when nil). Returns whether every
    /// archived commit is applied: not when one waits (a pause, a publication waiting, a secret the server refused),
    /// when `through` stopped it, or when pending commits were dropped to be pulled again.
    @discardableResult
    func applyPending(_ report: inout ServerExchangeReport, through: Int64? = nil) async throws -> Bool {
        // Safeguards an earlier run wrote but did not move into the archive (it stopped in between) go first, and a
        // staging that never reached its unit is taken out before anything projects, unless it is
        // the kept shadow of exactly the next commit (PROTOCOL §6.8: published later, not built again).
        try await drainQueueSafeguards()
        try await reconcileKeptShadow()
        // A requested repair whose download named its head holds later commits behind it until it is published.
        var through = through
        if let fence = try await fullSyncFence() {
            through = min(through ?? .max, fence)
            report.fullSynchronizationHolds = true
        }
        while true {
            try Task.checkCancellation()
            let state = try await store.serverExchangeState()
            guard let live = state.cursor else { return false }
            if let pause = state.pause, !pause.pullsContinue { report.pause = pause; return false }
            if let through, live.seq >= through { return false }
            if let deferred = deferredUnit, deferred.logID == live.logID, deferred.seq == live.seq + 1,
               !(await largePublicationMayRun(&report, "commit \(deferred.seq): about \(deferred.unit) row writes", work: deferred.unit)) { return false }
            guard let next = try archive.nextPendingCommit(after: live.seq) else {
                try archive.dropPendingCommits(through: live.seq, logID: live.logID)
                return true
            }
            guard next.cursor.logID == live.logID, next.commit.seq == live.seq + 1 else {
                // A commit of another lineage, or one missing: the archive's pending commits are pulled again.
                try archive.dropPendingCommits(through: Int64.max, logID: live.logID)
                log("apply", "dropped pending commits after \(live.seq)")
                return false
            }
            let input = ServerUnitInput(commit: next.commit, cursor: next.cursor, watermark: pullWatermark, now: now(), crash: stepCrashPoint)
            let applied: ServerUnitResult?
            // A unit whose secrets the server refused to send waits; pushing goes on.
            do { applied = try await applyUnit(input, report: &report) } catch is ServerRequestGated { return false }
            guard let result = applied else { return false }
            report.appliedUnits += 1
            if !result.alreadyApplied { await record(result, into: &report) }
            // Each unit's change is told at once: a long catch-up shows its progress (PROTOCOL §6.8).
            if !deferDelivery { await publishChanges(&report) }
            if result.queueSafeguard != nil { try await drainQueueSafeguards() }
            try archive.dropPendingCommits(through: next.commit.seq, logID: live.logID)
        }
    }

    /// One unit: secrets first, then direct or shadow. Nil when a publication waits for a pause.
    func applyUnit(_ input: ServerUnitInput, report: inout ServerExchangeReport) async throws -> ServerUnitResult? {
        try await fetchSecrets(of: input.commit)
        // A shadow kept for exactly this commit is its path: its staging is already in the base, which an estimate read
        // now would mistake for the commit's records being there already.
        if let kept = keptShadow, kept.build.revisions.target == input.cursor {
            deferredUnit = nil
            try await pace()
            return try await publishShadow(input, report: &report)
        }
        let (estimate, unitEstimate) = try estimateWork(input.commit)
        // A unit that cannot be published now (audio plays, or someone uses the app) is not even built then: building
        // it again at every exchange would spend the processor the player shares (PROTOCOL §6.8). It is built when it may run.
        // A new podcast's rows are staged in bounded transactions, so only the rest counts.
        if unitEstimate > publishWorkLimit, !(await largePublicationMayRun(&report, "commit \(input.commit.seq): about \(unitEstimate) row writes", work: unitEstimate)) {
            deferredUnit = (input.cursor.logID, input.commit.seq, unitEstimate)
            return nil
        }
        deferredUnit = nil
        try await pace()
        try crash("apply.before")
        for _ in 0..<3 {
            do {
                if estimate <= directWorkLimit {
                    do {
                        let result = try await store.applyServerUnit(input, history: history, maxWork: directWorkLimit * 4)
                        try crash("apply.after")
                        return result
                    } catch ServerApplyError.overBudget(let work) {
                        log("apply", "commit \(input.commit.seq): \(work) row writes, built in a shadow")
                    }
                }
                return try await publishShadow(input, report: &report)
            } catch ServerApplyError.missingSecrets(let secrets) {
                try await fetchSecrets(secrets)
            }
        }
        throw ServerApplyError.missingSecrets([])
    }

    /// Notes a committed step in the report and tells what it changed at once (before any later network or long work).
    func record(_ result: ServerUnitResult, into report: inout ServerExchangeReport) async {
        report.longestLockMilliseconds = max(report.longestLockMilliseconds, result.lockMilliseconds)
        report.units.append(ServerUnitTiming(seq: result.seq, work: result.work, lockMilliseconds: result.lockMilliseconds, published: result.published,
                                             rowsWritten: result.rowsWritten, background: result.background, retired: result.retired.count,
                                             lockSteps: result.lockSteps))
        report.deletedFeeds += result.deletedFeeds
        report.accountPoliciesChanged = report.accountPoliciesChanged || result.accountPoliciesChanged
        if !result.deletedFeeds.isEmpty || result.removedEpisodes { publish(.feedsDeleted) }
        if result.releases { publish(.releases) }
        if result.feedsMerged { publish(.feedsMerged) }
        for retired in result.retired where retired.outcome != "applied" {
            log("outcome", "\(ServerLogValue.type(retired.type)) \(retired.outcome.map(ServerLogValue.outcome) ?? "?")" + ServerLogValue.reason(retired.reason))
        }

        if result.transportConflict {
            report.pause = .transportConflict
            log("paused", "\(ServerPauseReason.transportConflict.rawValue) a slot of this installation holds another library's fact")
        }
        if !deferDelivery { await publishChanges(&report) }
    }

    /// Deletes the rows of hidden removals in bounded transactions, paced like units while audio
    /// plays; the podcast left every list in its unit. Resumes after a crash.
    func finishHiddenRemovals(_ report: inout ServerExchangeReport) async throws {
        guard try await store.hasHiddenRemovals() else { return }
        while true {
            try Task.checkCancellation()
            try await pace()
            let clock = ContinuousClock(), started = clock.now
            let step = try await store.deleteHiddenRemovalBatch()
            report.longestLockMilliseconds = max(report.longestLockMilliseconds, FeedLibraryStore.milliseconds(started.duration(to: clock.now)))
            report.removalBatches += step.progressed ? 1 : 0
            await publishChanges(&report)
            if step.progressed { publish(.feedsDeleted) }
            if !step.progressed { return }
        }
    }

    /// Moves the queue safeguards units wrote into the archive durably, then forgets them in the live library
    ///. Idempotent: a copy the archive already holds is not added twice.
    func drainQueueSafeguards() async throws {
        let pending = try await store.pendingQueueSafeguards()
        guard !pending.isEmpty else { return }
        try archive.saveQueueSafeguards(pending.map(\.record), now: now())
        try await store.removePendingQueueSafeguards(pending.map(\.id))
        for _ in pending { log("queue_safeguard", "a copy of the queue was kept before most of it was removed") }
    }

    // MARK: - Work estimate (PROTOCOL §6.8 plan, outside the live lock)

    /// The unit's row writes, counted on a read-only connection: records, cascades of removed and created podcasts,
    /// the queue when it changes, and retirements (account-level ones re-project every episode).
    /// The commit's row writes, and those its unit itself makes (without a new podcast's rows, which are staged).
    func estimateWork(_ commit: ServerCommit) throws -> (total: Int, unit: Int) {
        let connection = try planningConnection()
        return try connection.transaction(write: false) {
            // Only real changes count (stall fix (b)): a record the base already holds identically is not written.
            let changes = try ServerShadow.changedRecordKeys(commit.records, live: connection)
            var work = changes.changed.count
            var arriving = Set<String>()
            var queue = false
            var podcasts = Set<String>()
            for record in commit.records {
                if ServerPodcastFields.queueGroups.contains(record.fieldGroup) { queue = true }
                if record.entity == "podcast", record.fieldGroup == "subscription" { podcasts.insert(record.id) }
            }
            for podcast in podcasts {
                if let feed = try connection.rows("SELECT feed_id FROM ntp_podcasts WHERE podcast_id = ?", [.text(podcast)]).first?.first?.integer,
                   try connection.scalar("SELECT count(*) FROM feeds WHERE id = ?", [.integer(feed)]) == 1 {
                    if commit.records.contains(where: { $0.id == podcast && $0.fieldGroup == "subscription" && $0.value?["state"]?.stringValue == "removed" }) {
                        // A large removal is hidden in the unit and deleted in bounded transactions after it.
                        let episodes = Int(try connection.scalar("SELECT count(*) FROM episodes WHERE feed_id = ?", [.integer(feed)]))
                        work += episodes > FeedLibraryStore.removalBatch ? 1 : episodes
                    }
                } else {
                    work += Int(try connection.scalar("SELECT count(*) FROM ntp_episodes WHERE podcast_id = ?", [.text(podcast)]))
                    if commit.records.contains(where: { $0.id == podcast && $0.fieldGroup == "subscription"
                        && ["subscribed", "not_subscribed"].contains($0.value?["state"]?.stringValue ?? "") }) { arriving.insert(podcast) }
                }
            }
            // A podcast new to this library, and episodes new to it (a catalog arriving): their rows and records can be
            // staged.
            var episodes = Set<String>(), podcastOf: [String: String] = [:]
            for record in commit.records where record.entity == "episode" && record.fieldGroup == "identity" {
                episodes.insert(record.id)
                podcastOf[record.id] = record.value?["podcast_id"]?.stringValue
            }
            let identities = episodes.sorted()
            for start in stride(from: 0, to: identities.count, by: 500) {
                let chunk = ContractJSON.array(identities[start..<min(identities.count, start + 500)].map(ContractJSON.string)).canonicalText
                for row in try connection.rows("SELECT episode_id FROM ntp_episodes WHERE episode_id IN (SELECT value FROM json_each(?))", [.text(chunk)]) {
                    if let id = row[0].text { episodes.remove(id) }
                }
            }
            // A catalog for a podcast whose episodes this library already has (its own subscription) maps onto them:
            // nothing of it is staged.
            var newByPodcast: [String: Int] = [:]
            for episode in episodes { if let podcast = podcastOf[episode] { newByPodcast[podcast, default: 0] += 1 } }
            for (podcast, count) in newByPodcast {
                guard let feed = try connection.rows("SELECT feed_id FROM ntp_podcasts WHERE podcast_id = ?", [.text(podcast)]).first?.first?.integer else { continue }
                if try connection.scalar("SELECT count(*) FROM episodes WHERE feed_id = ?", [.integer(feed)]) * 2 >= Int64(count) {
                    episodes = episodes.filter { podcastOf[$0] != podcast }
                }
            }
            var stageable = commit.records.filter { ($0.entity == "podcast" && arriving.contains($0.id)) || ($0.entity == "episode" && episodes.contains($0.id)) }.count
            if episodes.count + stageable < FeedLibraryStore.removalBatch { stageable = 0 }
            // The content records it changes are staged ahead too (stall fix (c)), with the shown rows only they change
            // (not counted here); those of podcasts and episodes new to the library are counted above.
            let content = ServerShadow.stagedContent(commit.records, changed: changes.changed)
                .filter { !($0.entity == "podcast" && arriving.contains($0.id)) && !($0.entity == "episode" && episodes.contains($0.id)) }.count
            if content >= FeedLibraryStore.removalBatch { stageable += content }
            let install = try connection.rows("SELECT install_id FROM ntp_library WHERE id = 1").first?.first?.text
            for slot in commit.slots where slot.installID == install {
                work += FeedLibraryStore.retirementWork
                for row in try connection.rows("SELECT entity FROM ntp_overlays WHERE op_id = ?", [.text(slot.opID)]) {
                    if row[0].text == "account" { work += Int(try connection.scalar("SELECT count(*) FROM ntp_episodes WHERE local_id IS NOT NULL")) }
                    else { work += 1 }
                }
            }
            if queue { work += Int(try connection.scalar("SELECT count(*) FROM queue")) }
            return (work, max(0, work - stageable))
        }
    }

    // MARK: - Secrets before activation (PROTOCOL §6.8)

    /// Fetches every secret the commit's credential records name that this library does not hold. A failed fetch
    /// blocks the unit and is retried; a private feed is never left without its credentials.
    func fetchSecrets(of commit: ServerCommit) async throws {
        var ids = Set<String>()
        for record in commit.records where record.entity == "podcast" && record.fieldGroup == "credentials" {
            if let id = record.value?["secret_id"]?.stringValue { ids.insert(id) }
        }
        try await fetchSecrets(ids)
    }

    func fetchSecrets(_ ids: Set<String>) async throws {
        for id in ids.sorted() where try await store.serverSecretCredential(id) == nil {
            guard try await store.serverExchangeState().permits(.secret) else { throw ServerRequestGated() }
            let value = try await ServerRequestRefused.mapping(.secret) { try await transport.secret(id) }
            let credentials = FeedCredentials(username: value["username"]?.stringValue, password: value["password"]?.stringValue)
            let origins = (value["approved_origins"]?.arrayValue ?? []).compactMap(\.stringValue)
            let credential = UUID()
            try vault.insert(String(decoding: try JSONEncoder().encode(credentials), as: UTF8.self), id: credential)
            do { try await store.storeFetchedServerSecret(secretID: id, credentialID: credential, approvedOrigins: origins) }
            catch { try? vault.remove(id: credential); throw error }
            log("secret", "fetched")
        }
    }
}

extension FeedLibraryStore {
    /// A fetched secret becomes a library credential with a fresh local ID (PROTOCOL §15.4). The Keychain item was
    /// written first; the credential is kept for the library's life (`retire_feed_credential` skips it).
    func storeFetchedServerSecret(secretID: String, credentialID: UUID, approvedOrigins: [String]) throws {
        try syncTransactions(ServerTransactionKind.bookkeeping) { try storeFetchedServerSecretLabelled(secretID: secretID, credentialID: credentialID, approvedOrigins: approvedOrigins) }
    }

    private func storeFetchedServerSecretLabelled(secretID: String, credentialID: UUID, approvedOrigins: [String]) throws {
        try database.transaction {
            guard try database.scalar("SELECT count(*) FROM ntp_secrets WHERE secret_id = ?", [.text(secretID)]) == 0 else { return }
            try database.execute("INSERT INTO ntp_secrets(secret_id, credential_id, approved_origins, origin, created_at) VALUES (?, ?, ?, 'fetched', ?)",
                                 [.text(secretID), .text(credentialID.uuidString),
                                  .text(String(decoding: try JSONEncoder().encode(approvedOrigins), as: UTF8.self)),
                                  .integer(Int64(Date().timeIntervalSince1970 * 1_000))])
        }
    }
}
