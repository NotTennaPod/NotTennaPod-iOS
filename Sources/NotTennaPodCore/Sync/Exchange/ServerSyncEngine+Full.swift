import Foundation

/// Force full synchronization (PROTOCOL §6.14): a same-lineage `upgrade` snapshot of every field group,
/// verified, replaces the base, and every live row is reprojected from it through the overlays and the player's pin,
/// published as one atomic switch with the keyed writes of PROTOCOL §6.8. A wrong live row is repaired even when the base was
/// right; the outbox is never touched.
///
/// 1. Catch up as an exchange does (what was archived applies, this library's facts are pushed).
/// 2. `POST /v1/snapshot {mode: upgrade, cursor, install_id, acked_install_seq}` without `field_groups` (all of
///    them), spooled to `staging/full/` and verified (item count and `snapshot_digest`).
/// 3. Commits up to the snapshot's head are pulled and applied as units, so the live cursor is its head.
/// 4. Secrets the snapshot names are fetched (PROTOCOL §6.8); its entries and decisions are archived (idempotent).
/// 5. The reprojection is staged outside the live lock and published in one transaction: within the publication
///    budget while audio plays or the app is in use; above it once the app leaves the foreground (while audio plays,
///    whole within the background budget), otherwise at the next pause or stop, or in a processing background task.
///    A local action meanwhile is re-projected at its switch, or defers it to a whole publication when it may run.
extension ServerSyncEngine {
    /// Records the person's request; it stays until a repair is published, across relaunches.
    public func requestFullSynchronization() async {
        do { try await store.requestServerFullSynchronization() } catch { log("error", "recording the request: \(ServerLogValue.failure(error))") }
    }

    /// Whether a Force full synchronization is owed.
    public func fullSynchronizationRequested() async -> Bool { (try? await store.serverFullSynchronizationRequested()) ?? false }

    public func forceFullSynchronization() async -> ServerExchangeReport {
        // One exchange at a time: a running one finishes first.
        if let running { _ = await running.value }
        let task = Task(priority: .utility) { await self.performFull() }
        running = task
        let report = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        running = nil
        return report
    }

    /// Stops the running exchange (the library graph stops, or granted background time ended). Everything is
    /// resumable: units are atomic, and the next exchange continues from the live cursor.
    public func cancelExchange() { running?.cancel() }

    private func performFull() async -> ServerExchangeReport {
        // A snapshot the server refused waits for an explicit retry or an update; the request stays owed, and the
        // exchange goes on as usual meanwhile.
        if let state = try? await store.serverExchangeState(), !state.permits(.snapshot) { return await performExchange() }
        var report = ServerExchangeReport()
        do {
            log("full", "started")
            if try await store.releaseServerPins() { report.libraryChanged = true; publish(.libraryChanged) }
            try await applyPending(&report)
            try await push(&report)
            // While audio plays, a library too large to stage then waits before anything is downloaded.
            var playingLarge = false
            if await isPlaying() { playingLarge = try await store.serverRecordCount() > fullStagingWhilePlaying }
            if report.waiting || playingLarge {
                if playingLarge { report.waitingForPause = true }
                log("full", report.waitingForBackground ? "waits until NotTennaPod is in the background" : "waits for playback to pause")
            } else if report.pause.map(\.pullsContinue) ?? true {
                try await reproject(&report)
                if !report.waiting, report.retryAfter == nil {
                    try await applyPending(&report)
                    try await push(&report)
                }
            }
            if report.retryAfter == nil, !report.waitingForDependencies { failures = 0 }
        } catch let error as ServerExchangeError {
            await handle(error, &report)
        } catch let refused as ServerRequestRefused {
            await refuse(refused.request, &report)
        } catch is ServerRequestGated {
            // What the server refused waits for an explicit retry or an update.
        } catch is CancellationError {
            report.cancelled = true
        } catch ServerSnapshotError.verificationFailed {
            log("full", "the snapshot did not verify; again later")
            backoff(&report)
        } catch {
            log("error", ServerLogValue.failure(error))
            report.error = String(describing: error)
            backoff(&report)
        }
        return await finish(report)
    }

    private func reproject(_ report: inout ServerExchangeReport) async throws {
        let state = try await store.serverExchangeState()
        guard let cursor = state.cursor else { return }
        // A repair (or a recovery's base switch) built earlier and kept (its switch could not re-project the local
        // changes since within the budget): published from what it built while the live cursor is still exactly the one
        // it was built on, dropped otherwise.
        if let kept = keptFull {
            if try await keptFullIsLive(kept) {
                try await publishFull(kept, &report)
                return
            }
            try await dropKeptFull()
        }
        // A shadow kept for the next commit was built on the base this repair replaces.
        try await dropKeptShadow()
        try await discardStaging()
        let folder = staging.appendingPathComponent("full", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = transport
        let snapshot = try await ServerSnapshotDownload(folder: folder, fetch: { page in
            var body: ContractObject = ["mode": "upgrade", "cursor": .string(cursor.encoded), "install_id": .string(state.installID),
                                        "acked_install_seq": .integer(state.acked)]
            if let page { body["page"] = .string(page) }
            return try await ServerRequestRefused.mapping(.snapshot) { try await transport.snapshot(.object(body)) }
        }, isViewExpired: { ($0 as? ServerExchangeError)?.code == "view_expired" }).run()
        try crash("full.spooled")
        let head = try SyncCursor(encoded: snapshot.head)
        guard head.logID == cursor.logID, head.epoch == cursor.epoch else {
            throw ServerExchangeError.server(status: 409, code: "lineage_mismatch", retryAfter: nil)
        }
        // The live library at exactly the snapshot's head: later commits wait in the archive.
        if head.seq > cursor.seq {
            try await pull(&report)
            try await applyPending(&report, through: head.seq)
            if report.waiting { log("full", "waits for the commits before the snapshot"); return }
        }
        guard let live = try await store.serverExchangeState().cursor, live == head else {
            log("full", "the library is not at the snapshot's head yet; again later")
            backoff(&report)
            return
        }
        _ = try await publishReprojection(snapshot, head: head, replacing: nil, &report)
    }

    /// Makes a verified snapshot the live base and projects every live row from it, published in one transaction
    /// (PROTOCOL §6.14; a recovery's full snapshot, PROTOCOL §6.11, with `replacing` the live cursor it switches from: the cursor
    /// becomes the snapshot's head in the same transaction). A retained publication (PROTOCOL §6.8): built against the
    /// local-change log's end, taken before anything is read, and published over exactly the cursor it was built on,
    /// re-projecting the local changes since. Returns whether it was published; otherwise it is kept (`keptFull`, for
    /// the next exchange or the pause, never built again while that cursor is live) and the report says what it waits
    /// for.
    func publishReprojection(_ snapshot: ServerAttachSnapshot, head: SyncCursor, replacing: SyncCursor?, recoveryID: String? = nil,
                             _ report: inout ServerExchangeReport) async throws -> Bool {
        // The local-change log's end before anything of the library is read (the registrations below included): what
        // changes after it, the switch re-projects or defers for.
        let touches = try await store.serverTouchWatermark()
        // Secrets first (PROTOCOL §6.8), and the archive completed with the snapshot's entries and decisions.
        var secrets = Set<String>()
        var entries: [ServerAcceptedEntry] = [], decisions: [ServerDecision] = []
        let now = now()
        // This library's pending registrations the snapshot resolves: no commit will bring their resolutions once the
        // cursor is the snapshot's head (a recovery's).
        let pending = try await store.pendingServerRegistrations()
        var resolutions: [ServerDecision] = []
        try snapshot.forEachItem { item in
            if let accepted = item["accepted"] { entries.append(try ServerAcceptedEntry(accepted)) }
            else if let decision = item["decision"] {
                let decoded = try ServerDecision(decision)
                decisions.append(decoded)
                if decoded.type == "podcast.resolution", pending[decoded.subject] != nil { resolutions.append(decoded) }
            }
            else if let record = item["record"], record["entity"]?.stringValue == "podcast", record["field_group"]?.stringValue == "credentials",
                    let secret = record["value"]?["secret_id"]?.stringValue { secrets.insert(secret) }
            if entries.count + decisions.count >= 2_000 {
                try archive.archive(entries: entries, decisions: decisions, now: now)
                entries.removeAll(keepingCapacity: true); decisions.removeAll(keepingCapacity: true)
            }
        }
        try archive.archive(entries: entries, decisions: decisions, now: now)
        try await fetchSecrets(secrets)
        let file = staging.appendingPathComponent("full-\(head.seq).sqlite")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        // Nothing is kept now: a staged snapshot an earlier opening kept (the app stopped meanwhile) goes.
        removeFullStagingFiles()
        var keep = false
        defer { if !keep { Self.removeStagingFile(file) } }
        let staged = try ServerFullReprojection.stageBase(snapshot, into: file)
        // The registrations the snapshot resolves: their podcasts are their own feeds (as a unit's resolution gives
        // them), and their drafts' materialization is the publication's work too.
        var resolvedFeeds: [String: Int64] = [:]
        for decision in resolutions {
            if let podcast = decision.result["podcast_id"]?.stringValue, let feed = pending[decision.subject] ?? nil { resolvedFeeds[podcast] = feed }
        }
        let materializing = try await store.serverDraftCount(registrations: resolutions.map(\.subject))
        try crash("full.staged")
        // Projecting a large library takes seconds of processor time the player shares (PROTOCOL §6.8): while audio plays, only
        // a small one is projected; a larger one waits for a pause or stop, as an over-budget publication does.
        if await isPlaying(), staged.records > fullStagingWhilePlaying {
            report.waitingForPause = true
            log("full", "\(staged.records) records wait for playback to pause")
            return false
        }
        var extra = 0
        for _ in 0..<4 {
            try Task.checkCancellation()
            let reserved = try await store.reserveServerLocalIDs(feeds: 64 + extra, episodes: staged.identities + 64 + extra)
            let clock = ContinuousClock(), started = clock.now
            var build: ServerFullBuild
            do {
                build = try ServerFullReprojection.build(database: databaseURL, file: file, history: history, now: now,
                                                         feedIDs: reserved.feeds, episodeIDs: reserved.episodes, touches: touches,
                                                         target: head, admissionsSeen: replacing == nil, resolvedFeeds: resolvedFeeds)
            } catch ServerApplyError.needsLocalIDs {
                extra = max(1_024, extra * 4)
                continue
            }
            build.work += materializing * FeedLibraryStore.retirementWork
            report.shadowBuildMilliseconds = max(report.shadowBuildMilliseconds, FeedLibraryStore.milliseconds(started.duration(to: clock.now)))
            report.shadowsBuilt += 1
            try crash("full.built")
            // Built on exactly what it replaces (nothing applies during an exchange's build; checked, never assumed).
            guard build.revisions.source == (replacing ?? head) else {
                log("full", "the library moved during the build; again later")
                backoff(&report)
                return false
            }
            keptFull = ServerKeptFull(head: head, build: build, records: staged.records, now: now, replacing: replacing,
                                      resolutions: resolutions, recoveryID: recoveryID)
            keep = true
            if try await publishFull(keptFull!, &report) { return true }
            if keptFull != nil { return false } // kept for a later exchange or the pause
            keep = false
        }
        log("full", "local changes kept arriving; again later")
        backoff(&report)
        return false
    }

    /// Publishes a built repair (PROTOCOL §6.14): over the budget only when nobody uses the app, while audio plays
    /// within the background budget, admitted by the store only if nothing changed since that check, re-projecting the
    /// local changes made since it was built (PROTOCOL §6.8). Returns whether it was published; otherwise it is kept
    /// (still `keptFull`) for a later exchange or the pause, or dropped to be built again (what it was built on moved).
    @discardableResult
    private func publishFull(_ kept: ServerKeptFull, _ report: inout ServerExchangeReport) async throws -> Bool {
        let build = kept.build
        let kind = kept.replacing == nil ? "Force full synchronization" : "The recovery's base switch"
        let what = "\(kind): \(build.work) row writes"
        var deferredOnce = false
        for _ in 0..<2 {
            try await beforePublish?()
            var ticket: ServerPublicationTicket?
            // Over the budget, or deferred within it by the switch's re-projection: admitted as a large publication (whole
            // in the background while audio plays, within the background budget).
            if build.work > publishWorkLimit || deferredOnce {
                guard let allowed = await largePublicationTicket(&report, what, work: build.work) else { return false }
                ticket = allowed
            }
            let busy = await isPlaying() ? true : await isForeground()
            do {
                let result = try await store.publishFullReprojection(build, head: kept.head, now: kept.now, crash: stepCrashPoint, ticket: ticket,
                                                                     workLimit: ticket == nil && busy ? publishWorkLimit : nil, history: history,
                                                                     resolutions: kept.resolutions)
                try await dropKeptFull()
                report.publishedUnits += 1
                report.reprojected = true
                report.rebasedEntities += result.rebased
                record(result, into: &report)
                try crash("full.published")
                if result.background { log("full", "\(result.work) row writes published whole while audio plays in the background") }
                log("full", result.wholeAtPause
                    ? "reprojected as a whole from \(kept.records) records (local changes since staging needed it)"
                    : "reprojected from \(kept.records) records: \(build.recordChanges) records and \(result.work - build.recordChanges) rows changed"
                      + (result.rebased > 0 ? "; \(result.rebased) local changes since staging re-projected at its publication" : ""))
                return true
            } catch ServerApplyError.ineligible {
                // Someone started using the app (or audio started) while it waited for the store: it waits, kept.
                if !(await largePublicationMayRun(&report, what, work: build.work)) { return false }
            } catch ServerApplyError.deferred(let reason) {
                // Kept for the pause, where it is published as a whole if the deferral still holds; in the background while
                // audio plays it is tried once more as a large publication, unless one was deferred there already.
                deferredOnce = true
                if !(await largePublicationMayRun(&report, "\(kind): \(reason)", work: build.work)) { return false }
            }
        }
        return false
    }

    /// Publishes a recovery's kept base switch (PROTOCOL §6.11, PROTOCOL §6.8). Returns whether it was published; otherwise it stays
    /// kept and the report says what it waits for.
    func publishKeptRecovery(_ kept: ServerKeptFull, _ report: inout ServerExchangeReport) async throws -> Bool {
        guard try await publishFull(kept, &report) else { return false }
        log("recovery", "the library's base is the restored server's at \(kept.head.seq), with what this library restored (built at an earlier exchange)")
        return true
    }

    /// Forgets the kept repair: its file goes, and the local-change log before it.
    func dropKeptFull() async throws {
        guard let kept = keptFull else { return }
        keptFull = nil
        Self.removeStagingFile(kept.build.url)
        try await releaseTouches()
    }

    /// Whether a kept repair or recovery publication may still be published: the live cursor is exactly the one it was
    /// built on (epoch and digest included), and its staged snapshot is there.
    func keptFullIsLive(_ kept: ServerKeptFull) async throws -> Bool {
        guard let source = kept.build.revisions.source, try await store.serverExchangeState().cursor == source else { return false }
        return FileManager.default.fileExists(atPath: kept.build.url.path)
    }

    /// Takes out the staged snapshots of full publications nothing keeps (an earlier opening's, the app stopped while one
    /// was kept).
    func removeFullStagingFiles() {
        let kept = keptFull?.build.url.standardizedFileURL.path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        for name in names where name.hasPrefix("full-") && name.hasSuffix(".sqlite") {
            let url = staging.appendingPathComponent(name)
            if url.standardizedFileURL.path != kept { Self.removeStagingFile(url) }
        }
    }
}

/// A Force full synchronization or a recovery's base switch built and not published yet (PROTOCOL §6.14):
/// published later from what it built while the live cursor is still exactly the one it was built on.
struct ServerKeptFull: Sendable {
    var head: SyncCursor
    var build: ServerFullBuild
    var records: Int
    var now: Int64
    /// A recovery's full snapshot (PROTOCOL §6.11): the live cursor it switches from.
    var replacing: SyncCursor? = nil
    /// The snapshot's resolutions of this library's pending registrations, materialized with it.
    var resolutions: [ServerDecision] = []
    /// The recovery whose base switch it is: published only by that recovery (or a repair while its cursor is live).
    var recoveryID: String? = nil
}
