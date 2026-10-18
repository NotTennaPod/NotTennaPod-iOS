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

    /// What a Force full synchronization would download now (the confirmation's estimate): nil when unknown.
    public func fullSynchronizationEstimate() async -> Int64? {
        guard let estimate = await snapshotEstimate() else { return nil }
        let spooled = ServerSnapshotSpool.manifest(in: fullSpool)?.bytes ?? 0
        return max(0, estimate - spooled)
    }

    /// Whether a Force full synchronization is owed.
    public func fullSynchronizationRequested() async -> Bool { (try? await store.serverFullSynchronizationRequested()) ?? false }

    public func forceFullSynchronization() async -> ServerExchangeReport {
        // One exchange at a time: a running one finishes first.
        if let running { _ = await running.value }
        let task = Task(priority: .utility) { await LibraryChangeOrigin.$current.withValue(.sync) { await self.performFull() } }
        running = task
        let report = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        running = nil
        return report
    }

    /// Stops the running exchange (the library graph stops, or granted background time ended). Everything is
    /// resumable: units are atomic, and the next exchange continues from the live cursor.
    public func cancelExchange() { running?.cancel() }

    private func performFull() async -> ServerExchangeReport {
        pushRefusedThisExchange = false
        // A snapshot the server refused waits for an explicit retry or an update; the request stays owed, and the
        // exchange goes on as usual meanwhile.
        if let state = try? await store.serverExchangeState(), !state.permits(.snapshot) { return await performExchange() }
        // A download this network may not carry (mobile data or Low Data Mode while the mobile-data preference does not
        // allow sync) waits: the ordinary exchange runs meanwhile, so other changes keep arriving. A complete download
        // needs no network.
        if let wait = await transport.bulkWaitReason(), ServerSnapshotSpool.manifest(in: fullSpool)?.complete != true {
            try? await store.requestServerFullSynchronization()
            var report = await performExchange()
            report.fullSynchronizationWaitsForNetwork = wait
            return report
        }
        // The same while it waits for free space: ordinary sync goes on, and nothing is staged again until space grew.
        var waiting = ServerExchangeReport()
        if !bulkSpaceReturned(&waiting) {
            try? await store.requestServerFullSynchronization()
            return await ordinaryWhileWaitingForSpace(nil)
        }
        var report = ServerExchangeReport()
        do {
            log("full", "started")
            // Owed until a repair is published, across relaunches: its download is kept, and holds later commits, only
            // while it is owed.
            if try await !store.serverFullSynchronizationRequested() { try await store.requestServerFullSynchronization() }
            _ = try await store.releaseServerPins()
            await publishChanges(&report)
            try await applyPending(&report)
            try await push(&report)
            // While audio plays, a library too large to stage then waits before anything is downloaded.
            var playingLarge = false
            if await isPlaying() {
                // A kept download's size counts when it is larger than this library (what staging would write).
                let incoming = ServerSnapshotSpool.manifest(in: fullSpool)?.records ?? 0
                playingLarge = max(try await store.serverRecordCount(), incoming) > fullStagingWhilePlaying
            }
            if report.waiting || playingLarge {
                if playingLarge { report.waitingForPause = true }
                log("full", report.waitingForBackground ? "waits until NotTennaPod is in the background" : "waits for playback to pause")
            } else if report.pause.map(\.pullsContinue) ?? true {
                try await reproject(&report)
                if !report.waiting, report.retryAfter == nil {
                    try await applyPending(&report)
                    // Published: what waited behind its head is applied, and pulls catch up with what followed.
                    if report.reprojected {
                        try await pull(&report)
                        try await applyPending(&report)
                    }
                    try await push(&report)
                }
            }
            if report.retryAfter == nil, !report.waitingForDependencies { failures = 0 }
            // Published: nothing is held any more.
            if report.reprojected { report.fullSynchronizationHolds = false }
        } catch let error as ServerExchangeError {
            await handle(error, &report)
        } catch let refused as ServerRequestRefused {
            await refuse(refused.request, &report)
        } catch is ServerRequestGated {
            // What the server refused waits for an explicit retry or an update.
        } catch let space as ServerInsufficientSpace {
            noteInsufficientSpace(space, &report)
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
        // Stopped short of the reserved space: the ordinary exchange still brings other devices' changes (behind the
        // repair's head once it is known).
        if report.insufficientSpace { return await ordinaryWhileWaitingForSpace(report) }
        return await finish(report)
    }

    /// An ordinary exchange while a repair waits for free space, reported as unfinished (`insufficientSpace`), with what
    /// the repair's attempt did before it stopped.
    private func ordinaryWhileWaitingForSpace(_ before: ServerExchangeReport?) async -> ServerExchangeReport {
        var report = await performExchange()
        report.insufficientSpace = true
        if let before {
            report.libraryChanged = report.libraryChanged || before.libraryChanged
            report.appliedUnits += before.appliedUnits
            report.acknowledged += before.acknowledged
            report.fullSynchronizationHolds = report.fullSynchronizationHolds || before.fullSynchronizationHolds
        }
        return report
    }

    private func reproject(_ report: inout ServerExchangeReport) async throws {
        let state = try await store.serverExchangeState()
        guard let cursor = state.cursor else { return }
        // A repair (or a recovery's base switch) built earlier and kept (its switch could not re-project the local
        // changes since within the budget): published from what it built while the live cursor is still exactly the one
        // it was built on, dropped otherwise.
        if let kept = keptFull {
            if try await keptFullIsLive(kept) {
                if try await publishFull(kept, &report) { ServerSnapshotSpool.remove(fullSpool) }
                return
            }
            try await dropKeptFull()
        }
        // A shadow kept for the next commit was built on the base this repair replaces.
        try await dropKeptShadow()
        try await discardStaging()
        // The repair's download is kept until it is published: an interruption continues it from its last page, and a
        // complete one is published without the network (verified again first).
        let folder = fullSpool
        _ = try await fullSyncFence()
        let identity = ServerSnapshotIdentity(mode: "upgrade", installID: state.installID, logID: cursor.logID, epoch: cursor.epoch)
        let existing = ServerSnapshotSpool.manifest(in: folder).flatMap { $0.identity == identity ? $0 : nil }
        if existing?.complete != true, !snapshotsAllowed {
            log("full", "the download waits for a processing background task or the app")
            return
        }
        guard bulkSpaceReturned(&report) else { return }
        let transport = transport, disk = disk, limit = snapshotPageLimit
        let estimate = await snapshotEstimate()
        var spool = ServerSnapshotSpool(folder: folder, identity: identity, fetch: { page in
            var body: ContractObject = ["mode": "upgrade", "cursor": .string(cursor.encoded), "install_id": .string(state.installID),
                                        "acked_install_seq": .integer(state.acked)]
            if let page { body["page"] = .string(page) } else if let limit { body["limit"] = .integer(Int64(limit)) }
            return try await ServerRequestRefused.mapping(.snapshot) { try await transport.snapshot(.object(body)) }
        }, restarts: { error, resumed in
            let code = (error as? ServerExchangeError)?.code
            return code == "view_expired" || (resumed && code == "invalid_request")
        })
        spool.clock = clock
        disk.guarding(&spool, estimate: estimate)
        let hook = stepCrashPoint
        spool.beforeRequest = { try hook?("full.page") }
        let snapshot = try await spool.run()
        ServerSnapshotEstimate.record(snapshot, in: staging)
        try crash("full.spooled")
        let head = try SyncCursor(encoded: snapshot.head)
        guard head.logID == cursor.logID, head.epoch == cursor.epoch else {
            ServerSnapshotSpool.remove(folder)
            throw ServerExchangeError.server(status: 409, code: "lineage_mismatch", retryAfter: nil)
        }
        // The live library at exactly the snapshot's head: later commits wait in the archive.
        if head.seq > cursor.seq {
            try await pull(&report)
            try await applyPending(&report, through: head.seq)
            if report.waiting { log("full", "waits for the commits before the snapshot"); return }
        }
        guard let live = try await store.serverExchangeState().cursor, live == head else {
            if let live = try await store.serverExchangeState().cursor, live.logID == head.logID, live.epoch == head.epoch, live.seq > head.seq {
                // Past the snapshot already (an older app applied beyond it): it can never be published; again from the start.
                ServerSnapshotSpool.remove(folder)
            }
            log("full", "the library is not at the snapshot's head yet; again later")
            backoff(&report)
            return
        }
        if try await publishReprojection(snapshot, head: head, replacing: nil, &report) { ServerSnapshotSpool.remove(folder) }
    }

    /// The requested repair's spool (PROTOCOL §6.14): `staging/full/`.
    var fullSpool: URL { staging.appendingPathComponent("full", isDirectory: true) }

    /// The head a requested repair's download holds later commits behind, nil when nothing is held. Once the download's
    /// first page named its head H, commits after H wait until the repair is published at H: pushes go on; the next
    /// pull archives what follows H, and later pulls wait for the publication (a pull applies what is archived first),
    /// which then applies and pulls everything in order. A spool that can no longer be published (another lineage or installation, a
    /// live cursor past H, the request gone with its publication) is deleted. The hold is bounded: a partial download
    /// with no page for 24 hours is abandoned (the request stays and starts again later), and a complete one holds for
    /// 72 hours at most (it is kept, and published if the cursor is still at H).
    func fullSyncFence() async throws -> Int64? {
        let folder = fullSpool
        guard let manifest = ServerSnapshotSpool.manifest(in: folder) else { return nil }
        guard let target = manifest.targetHead.flatMap({ try? SyncCursor(encoded: $0) }) else { return nil }
        let state = try await store.serverExchangeState()
        guard let live = state.cursor, manifest.identity.installID == state.installID, live.logID == target.logID, live.epoch == target.epoch,
              live.seq <= target.seq, try await store.serverFullSynchronizationRequested() else {
            ServerSnapshotSpool.remove(folder)
            log("full", "a kept download no longer applies; it is deleted")
            return nil
        }
        let age = now() - manifest.lastActivity
        if !manifest.complete, age > Self.partialSpoolHold {
            ServerSnapshotSpool.remove(folder)
            log("full", "the download made no progress for a day; it starts again later")
            return nil
        }
        if manifest.complete, age > Self.completeSpoolHold { return nil }
        return target.seq
    }

    static let partialSpoolHold: Int64 = 24 * 3_600_000
    static let completeSpoolHold: Int64 = 72 * 3_600_000

    /// The next snapshot download's estimated size: the last one's, scaled by the items this library holds now (its
    /// archived entries and decisions and its base records). Nil when nothing was downloaded into it yet.
    func snapshotEstimate() async -> Int64? {
        guard let last = ServerSnapshotEstimate.read(staging) else { return nil }
        let records = (try? await store.serverRecordCount()) ?? 0
        let archived = (try? archive.entryAndDecisionCount()) ?? 0
        return last.scaled(to: records + archived)
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
                try archive.archive(entries: entries, decisions: decisions, now: now, budget: disk.budget(at: staging))
                entries.removeAll(keepingCapacity: true); decisions.removeAll(keepingCapacity: true)
            }
        }
        try archive.archive(entries: entries, decisions: decisions, now: now, budget: disk.budget(at: staging))
        try crash("full.archived")
        try await fetchSecrets(secrets)
        let file = staging.appendingPathComponent("full-\(head.seq).sqlite")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        // Nothing is kept now: a staged snapshot an earlier opening kept (the app stopped meanwhile) goes.
        removeFullStagingFiles()
        var keep = false
        defer { if !keep { Self.removeStagingFile(file) } }
        let staged = try ServerFullReprojection.stageBase(snapshot, into: file, budget: disk.budget(at: staging))
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
                                                         target: head, admissionsSeen: replacing == nil, resolvedFeeds: resolvedFeeds,
                                                         budget: disk.budget(at: staging))
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
                                                                     resolutions: kept.resolutions, budget: disk.budget(at: staging))
                try await dropKeptFull()
                report.publishedUnits += 1
                report.reprojected = true
                report.rebasedEntities += result.rebased
                await record(result, into: &report)
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
