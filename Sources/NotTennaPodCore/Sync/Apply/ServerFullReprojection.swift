import Foundation

/// A staged Force full synchronization (PROTOCOL §6.14): the verified snapshot's records as the new base,
/// the record differences from the live base, and the post-reprojection images of every row that changes, in
/// `staging/full-<seq>.sqlite`; the rest of the plan in memory; and the revisions the build read.
struct ServerFullBuild: Sendable {
    var url: URL
    var plan: ServerProjectionPlan
    /// Row writes of the publication: changed records plus the plan's rows (PROTOCOL §6.8 work).
    var work: Int
    /// Records that differ between the live base and the snapshot.
    var recordChanges: Int
    /// What it was built against: its retained-publication basis (PROTOCOL §6.8).
    var revisions: ServerRetainedBasis
}

enum ServerFullReprojection {
    /// The staging file's tables: the snapshot's base, its episode identities, the record differences and the images.
    static let schema = [
        "CREATE TABLE IF NOT EXISTS records (entity TEXT NOT NULL, id TEXT NOT NULL, field_group TEXT NOT NULL, value BLOB, provenance TEXT, PRIMARY KEY(entity, id, field_group)) WITHOUT ROWID",
        "CREATE TABLE IF NOT EXISTS identities (episode_id TEXT PRIMARY KEY, podcast_id TEXT NOT NULL, kind TEXT NOT NULL, value TEXT NOT NULL, occurrence BLOB, merged_into TEXT)",
        "CREATE INDEX IF NOT EXISTS identities_by_podcast ON identities(podcast_id)",
        "CREATE TABLE IF NOT EXISTS record_changes (entity TEXT NOT NULL, id TEXT NOT NULL, field_group TEXT NOT NULL, deleted INTEGER NOT NULL, PRIMARY KEY(entity, id, field_group)) WITHOUT ROWID",
    ]

    /// A staging file a read-only connection can attach: no WAL (a read-only connection cannot create its index).
    private static func open(_ url: URL) throws -> SyncSQLite {
        let file = try SyncSQLite(url: url, durable: false)
        try file.execute("PRAGMA journal_mode = DELETE")
        return file
    }

    /// Writes the snapshot's records and episode identities as the staged base. Returns their counts.
    @discardableResult
    /// `budget`: the bytes its writes may add (`SQLiteWriteBudget`; nil: no limit).
    static func stageBase(_ snapshot: ServerAttachSnapshot, into url: URL, budget: Int64? = nil) throws -> (records: Int, identities: Int) {
        for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix)) }
        let file = try open(url)
        defer { try? file.close() }
        var count = 0, identities = 0
        try file.withWriteBudget(budget) { try file.transaction {
            for statement in schema + ServerShadow.schema.filter({ !$0.contains(" records ") && !$0.contains(" identities ") }) {
                try file.execute(statement)
            }
            try snapshot.forEachItem { item in
                guard let json = item["record"] else { return }
                let record = try ServerRecord(json)
                guard let value = record.value else { return }
                try file.execute("INSERT OR REPLACE INTO records(entity, id, field_group, value, provenance) VALUES (?, ?, ?, ?, ?)",
                                 [.text(record.entity), .text(record.id), .text(record.fieldGroup), .blob(try value.canonicalData()),
                                  .text(ContractJSON.array(record.provenance.map(ContractJSON.string)).canonicalText)])
                count += 1
                if record.entity == "episode", record.fieldGroup == "identity", let podcast = value["podcast_id"]?.stringValue {
                    identities += 1
                    let occurrence = value["occurrence"]
                    try file.execute("INSERT OR REPLACE INTO identities(episode_id, podcast_id, kind, value, occurrence, merged_into) VALUES (?, ?, ?, ?, ?, ?)",
                                     [.text(record.id), .text(podcast), .text(occurrence?["k"]?.stringValue ?? "none"), .text(occurrence?["v"]?.stringValue ?? ""),
                                      try occurrence.map { .blob(try $0.canonicalData()) } ?? .null, value["merged_into"]?.stringValue.map(LibrarySQLValue.text) ?? .null])
                }
            }
        } }
        return (count, identities)
    }

    /// The player's selection and session episodes.
    static func player(_ database: LibrarySQLite) throws -> [Int64?] {
        [try database.rows("SELECT episode_id FROM playback_selection WHERE id = 1").first?.first?.integer,
         try database.rows("SELECT episode_id FROM playback_session WHERE id = 1").first?.first?.integer]
    }

    /// A Force full synchronization's projection: the plan with every changed row's image, what it was built against,
    /// the rows whose play state changes, and the record differences from the live base.
    struct Projection {
        var plan: ServerProjectionPlan
        var revisions: ServerRetainedBasis
        var changedStates: Set<Int64>
        var changes: [(entity: String, id: String, group: String, deleted: Bool)]
    }

    /// Projects every live row from the staged base attached as `full` on `connection`, inside the caller's
    /// transaction: on a read-only connection for a build (no write lock), or on the store's own inside its publication
    /// (a repair published as a whole at the pause). `allocate` gives new local IDs. `context`: a repair's, or a
    /// recovery's (its admissions are releases, its resolved registrations' feeds).
    static func project(_ connection: LibrarySQLite, history: ServerHistoryOracle?, now: Int64,
                        context: ServerProjectionContext = ServerProjectionContext(full: true),
                        allocate: @escaping (String) throws -> Int64) throws -> Projection {
        guard let row = try connection.rows("SELECT namespace, account_id FROM ntp_library WHERE id = 1").first,
              let namespace = row[0].text, let account = row[1].text else {
            throw ServerRecordingError.corruptState("ntp_library")
        }
        let projector = ServerProjector(db: connection, namespace: namespace, accountID: account, now: now, allocate: allocate)
        projector.history = history
        projector.baseTable = "full.records"
        projector.fullBase = "full"
        // Admissions the base already had were applied by their units; one the ledger lacks is seen in a repair, never
        // released again (no notification or download from a repair), and a release in a recovery's snapshot (one this
        // phone never saw: the ledger keeps every one it saw, its row keys included).
        projector.admissionsSeen = context.admissionsSeen
        projector.resolvedFeeds = context.resolvedFeeds
        // The record differences (a publication writes only these).
        var changes: [(entity: String, id: String, group: String, deleted: Bool)] = []
        for row in try connection.rows("SELECT f.entity, f.id, f.field_group FROM full.records f LEFT JOIN ntp_records r ON r.entity = f.entity AND r.id = f.id AND r.field_group = f.field_group WHERE r.value IS NULL OR r.value IS NOT f.value OR r.provenance IS NOT f.provenance") {
            if let entity = row[0].text, let id = row[1].text, let group = row[2].text { changes.append((entity, id, group, false)) }
        }
        for row in try connection.rows("SELECT r.entity, r.id, r.field_group FROM ntp_records r WHERE NOT EXISTS (SELECT 1 FROM full.records f WHERE f.entity = r.entity AND f.id = r.id AND f.field_group = r.field_group)") {
            if let entity = row[0].text, let id = row[1].text, let group = row[2].text { changes.append((entity, id, group, true)) }
        }
        try projector.noteFullPlayedTimeChanges()
        var scope = ServerProjectionScope()
        for row in try connection.rows("SELECT DISTINCT id FROM full.records WHERE entity = 'podcast'") {
            if let id = row[0].text { scope.podcasts[id] = .all }
        }
        for row in try connection.rows("SELECT DISTINCT id FROM full.records WHERE entity = 'episode'") {
            if let id = row[0].text { scope.episodes[id] = .all }
        }
        scope.queue = true
        scope.accountPolicies = changes.contains { $0.entity == "account" }
        try projector.projectAbsent()
        try projector.project(scope)
        let plan = projector.plan
        if !plan.missingSecrets.isEmpty { throw ServerApplyError.missingSecrets(plan.missingSecrets) }
        var changed = Set<Int64>()
        for (id, entry) in plan.episodes where !plan.createdEpisodes.contains(id) {
            guard let row = try connection.rows("SELECT record FROM episodes WHERE id = ?", [.integer(id)]).first, let data = row[0].data else { continue }
            if try JSONDecoder.libraryRecord(LibraryEpisode.self, from: data).userState.playState != entry.episode.userState.playState { changed.insert(id) }
        }
        // Every podcast, episode and the queue are its scope; its context is the snapshot's.
        var projected = try ServerShadowScope(projector, player: try player(connection), live: connection)
        projected.everything = true
        projected.queue = true
        let revisions = ServerRetainedBasis(touches: ServerTouchWatermark(epoch: UUID(), id: 0), scope: projected, context: context)
        return Projection(plan: plan, revisions: revisions, changedStates: changed, changes: changes)
    }

    /// Projects every live row from the staged base on a read-only connection to the live library (one WAL snapshot,
    /// no write lock): every podcast and episode the snapshot holds, through the overlays and the player's pin, and
    /// what the base held and the snapshot does not (removed). Writes the images and the record differences into the
    /// staging file.
    /// `touches`: the store's local-change log end, taken before the build reads anything; what local writes touch
    /// after it, the publication re-projects at its switch.
    /// `target`: the cursor it publishes, a recovery's snapshot head (nil: the live cursor it is built on, a repair's).
    /// Its basis records the live cursor it read as `source`: it publishes only over exactly that one.
    /// `admissionsSeen`: a repair's admissions the ledger lacks are seen (no download or notification from a repair); a
    /// recovery's are releases this phone never saw, driven once (scenario 38 PROTOCOL §16).
    /// `resolvedFeeds`: the local feed of each podcast whose registration the snapshot resolves (podcast → the
    /// registration's feed), as a commit's unit gives its projector: the snapshot's podcast is
    /// projected onto that feed, never matched by URL (a pending URL edit) or created anew.
    static func build(database: URL, file url: URL, history: ServerHistoryOracle?, now: Int64,
                      feedIDs: ClosedRange<Int64>, episodeIDs: ClosedRange<Int64>, touches: ServerTouchWatermark, target: SyncCursor? = nil,
                      admissionsSeen: Bool = true, resolvedFeeds: [String: Int64] = [:], budget: Int64? = nil) throws -> ServerFullBuild {
        let connection = try LibrarySQLite(readingOnly: database)
        defer { try? connection.close() }
        try connection.execute("ATTACH DATABASE ? AS full", [.text(url.path)])
        var stage: Projection
        do {
            stage = try connection.transaction(write: false) {
                var nextFeed = feedIDs.lowerBound, nextEpisode = episodeIDs.lowerBound
                let context = ServerProjectionContext(full: true, admissionsSeen: admissionsSeen, resolvedFeeds: resolvedFeeds)
                var projection = try project(connection, history: history, now: now, context: context) { kind in
                    if kind == "feed" {
                        guard nextFeed <= feedIDs.upperBound else { throw ServerApplyError.needsLocalIDs }
                        defer { nextFeed += 1 }
                        return nextFeed
                    }
                    guard nextEpisode <= episodeIDs.upperBound else { throw ServerApplyError.needsLocalIDs }
                    defer { nextEpisode += 1 }
                    return nextEpisode
                }
                projection.revisions.touches = touches
                projection.revisions.source = try connection.rows("SELECT cursor FROM ntp_library WHERE id = 1").first?.first?.text.map { try SyncCursor(encoded: $0) }
                projection.revisions.target = target ?? projection.revisions.source
                return projection
            }
        } catch {
            try? connection.execute("DETACH DATABASE full")
            throw error
        }
        try connection.execute("DETACH DATABASE full")
        try connection.close()
        let plan = stage.plan
        // The images and the record differences go to the staging file; the publication copies them.
        let file = try open(url)
        defer { try? file.close() }
        try file.withWriteBudget(budget) { try file.transaction {
            for table in ["feeds", "episodes", "mappings", "record_changes"] { try file.execute("DELETE FROM \(table)") }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            for (id, feed) in plan.feeds {
                var header = feed
                header.episodes = []
                try file.execute("INSERT INTO feeds(id, title, record) VALUES (?, ?, ?)",
                                 [.integer(id), feed.metadata.title.map(LibrarySQLValue.text) ?? .null, .blob(try encoder.encode(header))])
            }
            for (id, entry) in plan.episodes {
                guard let date = entry.episode.details.publicationDate else { throw FeedLibraryError.invalidMutation }
                try file.execute("INSERT INTO episodes(id, feed_id, pubdate, record, play_state_changed) VALUES (?, ?, ?, ?, ?)",
                                 [.integer(id), .integer(entry.feedID), .integer(Int64(date.timeIntervalSince1970 * 1_000)),
                                  .blob(try encoder.encode(entry.episode)), .integer(stage.changedStates.contains(id) ? 1 : 0)])
            }
            for (episode, mapping) in plan.episodeMappings {
                try file.execute("INSERT INTO mappings(episode_id, local_id, podcast_id, kind, value, occurrence, merged_into) VALUES (?, ?, ?, ?, ?, ?, ?)",
                                 [.text(episode), mapping.localID.map(LibrarySQLValue.integer) ?? .null, .text(mapping.podcast), .text(mapping.kind),
                                  .text(mapping.value), try mapping.occurrence.map { .blob(try $0.canonicalData()) } ?? .null,
                                  mapping.mergedInto.map(LibrarySQLValue.text) ?? .null])
            }
            for change in stage.changes {
                try file.execute("INSERT OR REPLACE INTO record_changes(entity, id, field_group, deleted) VALUES (?, ?, ?, ?)",
                                 [.text(change.entity), .text(change.id), .text(change.group), .integer(change.deleted ? 1 : 0)])
            }
        } }
        var small = plan
        small.feeds = [:]; small.episodes = [:]; small.episodeMappings = [:]
        return ServerFullBuild(url: url, plan: small, work: plan.work + stage.changes.count, recordChanges: stage.changes.count,
                               revisions: stage.revisions)
    }
}

extension FeedLibraryStore {
    /// This library's registrations still waiting for their resolution, with their local feeds.
    func pendingServerRegistrations() throws -> [String: Int64?] {
        guard serverContext != nil else { return [:] }
        var result: [String: Int64?] = [:]
        for row in try database.rows("SELECT op_id, feed_id FROM ntp_registrations WHERE state = 'pending'") {
            if let op = row[0].text { result[op] = row[1].integer }
        }
        return result
    }

    /// The drafts these registrations' materialization turns into facts (the publication's work, PROTOCOL §6.8).
    func serverDraftCount(registrations: [String]) throws -> Int {
        guard serverContext != nil, !registrations.isEmpty else { return 0 }
        return Int(try database.scalar("SELECT count(*) FROM ntp_drafts WHERE registration_op IN (SELECT value FROM json_each(?))",
                                       [.text(ContractJSON.array(registrations.map(ContractJSON.string)).canonicalText)]))
    }

    /// Publishes a Force full synchronization in one live transaction (PROTOCOL §6.14): the record differences make the live
    /// base the snapshot's, the staged images replace the rows that change (keyed statements only, PROTOCOL §6.8), and
    /// obsolete projected rows go. The cursor already names the snapshot's head. A bounded atomic switch that keeps
    /// concurrent local operations, as a shadow's (PROTOCOL §6.8): what local writes touched since it was built is re-projected
    /// here from the new base and the current overlays. Its whole switch is bounded by its limit (`workLimit`, else the
    /// ticket's background budget; nil: none): over it, or meeting a structural dependency, it throws
    /// `ServerApplyError.deferred`, nothing written, the build kept for later; with no limit it is projected again as a
    /// whole in this transaction.
    /// It publishes only over exactly the live cursor it was built on (its basis's `source`, epoch and digest included)
    /// and moves the cursor to its `target` (`head`) in the same transaction: a recovery's full snapshot (PROTOCOL §6.11)
    /// switches from the live cursor to the snapshot's head; a repair's are the same.
    /// `resolutions`: the snapshot's `podcast.resolution` decisions of this library's pending registrations, which no
    /// commit will bring now that the cursor moves past them (a recovery's full snapshot): their
    /// drafts materialize in this transaction, as a commit's unit materializes them.
    func publishFullReprojection(_ build: ServerFullBuild, head: SyncCursor, now: Int64,
                                 crash: (@Sendable (String) throws -> Void)?, ticket: ServerPublicationTicket? = nil,
                                 workLimit: Int? = nil, history: ServerHistoryOracle? = nil,
                                 resolutions: [ServerDecision] = [], budget: Int64? = nil) throws -> ServerUnitResult {
        guard let context = serverContext else { throw ServerRecordingError.notAServerLibrary }
        try ensureServerExchangeTables()
        try database.execute("ATTACH DATABASE ? AS full", [.text(build.url.path)])
        defer { try? database.execute("DETACH DATABASE full") }
        let clock = ContinuousClock(), started = clock.now
        let changes = database.totalChanges
        let kind = workLimit == nil && ticket?.budget != nil ? ServerTransactionKind.backgroundPublication : ServerTransactionKind.publication
        // Its writes, through COMMIT, never use the space the app keeps (`budget`): a refusal rolls it back whole.
        var result = try database.withWriteBudget(budget) { try syncTransactions(kind) { try write(.remote, durable: true) {
            var result = ServerUnitResult(seq: head.seq)
            guard let source = build.revisions.source, build.revisions.target == head,
                  let live = try serverExchangeState().cursor, live == source else {
                throw ServerApplyError.outOfOrder(live: try serverExchangeState().cursor?.seq, commit: head.seq)
            }
            // Admitted only while nobody started using the app since it was allowed.
            if let ticket, !ticket.isCurrent { throw ServerApplyError.ineligible }
            let rebase: ServerTouchedRebase
            // The 1,000-row budget while audio plays or the app is in use, the ticket's background budget while audio plays
            // with no scene in the foreground, or none.
            let limit = Self.publicationLimit(workLimit: workLimit, ticket: ticket)
            do {
                rebase = try self.rebase(build.revisions, stagedWork: build.work, workLimit: limit, plan: build.plan)
            } catch ServerApplyError.deferred(let reason) {
                // With the budget relaxed (no limit: the pause), projected again here as a whole, correctly: from the intact
                // local rows and the snapshot's semantics, in this transaction.
                guard limit == nil else { throw Self.deferred(reason, workLimit: workLimit, ticket: ticket) }
                return try quietServerTouches { () throws -> ServerUnitResult in
                    try publishFullInTransaction(now: now, history: history, basis: build.revisions, crash: crash, result: &result)
                    try materializeResolutions(resolutions, context: context)
                    if head != source { try setCursor(head, watermark: nil) }
                    // The request is fulfilled with this publication, durably and atomically.
                    try database.execute("DELETE FROM ntp_requests WHERE name = ?", [.text(Self.fullSynchronizationRequest)])
                    try crash?("full.written")
                    return result
                }
            }
            return try quietServerTouches { () throws -> ServerUnitResult in
            // The base: exactly the snapshot's records.
            try database.execute("DELETE FROM ntp_records WHERE (entity, id, field_group) IN (SELECT entity, id, field_group FROM full.record_changes WHERE deleted = 1)")
            try database.execute("INSERT INTO ntp_records(entity, id, field_group, value, provenance) SELECT r.entity, r.id, r.field_group, r.value, r.provenance FROM full.records r JOIN full.record_changes c ON c.entity = r.entity AND c.id = r.id AND c.field_group = r.field_group WHERE c.deleted = 0 ON CONFLICT(entity, id, field_group) DO UPDATE SET value = excluded.value, provenance = excluded.provenance")
            try database.execute("INSERT INTO ntp_episodes(episode_id, local_id, podcast_id, kind, value, occurrence, merged_into) SELECT i.episode_id, NULL, i.podcast_id, i.kind, i.value, i.occurrence, i.merged_into FROM full.identities i JOIN full.record_changes c ON c.entity = 'episode' AND c.id = i.episode_id AND c.field_group = 'identity' WHERE c.deleted = 0 ON CONFLICT(episode_id) DO UPDATE SET podcast_id = excluded.podcast_id, occurrence = excluded.occurrence, merged_into = excluded.merged_into")
            try crash?("full.base")
            // The rows, keyed: the staged images, except those local changes touched since (re-projected below).
            let rows = ContractJSON.array(rebase.rows.sorted().map(ContractJSON.integer)).canonicalText
            try database.execute("DELETE FROM episode_swipe_undo WHERE episode_id IN (SELECT id FROM full.episodes WHERE play_state_changed = 1 AND id NOT IN (SELECT value FROM json_each(?)))", [.text(rows)])
            try database.execute("INSERT INTO feeds(id, title, record) SELECT id, title, record FROM full.feeds WHERE true ON CONFLICT(id) DO UPDATE SET title = excluded.title, record = excluded.record WHERE feeds.title IS NOT excluded.title OR feeds.record IS NOT excluded.record")
            try database.execute("INSERT INTO episodes(id, feed_id, pubdate, record) SELECT id, feed_id, pubdate, record FROM full.episodes WHERE id NOT IN (SELECT value FROM json_each(?)) ON CONFLICT(id) DO UPDATE SET pubdate = excluded.pubdate, record = excluded.record WHERE episodes.feed_id = excluded.feed_id AND (episodes.pubdate IS NOT excluded.pubdate OR episodes.record IS NOT excluded.record)", [.text(rows)])
            // Every row the mappings give another episode is let go first, whether its current holder leaves the mappings or
            // moves to another row in them (a release's identity reassigned); unchanged bindings stay.
            // Then each binding is installed: no order of the staged rows can meet a row still held.
            try database.execute("UPDATE ntp_episodes SET local_id = NULL WHERE local_id IN (SELECT local_id FROM full.mappings WHERE local_id IS NOT NULL) AND NOT EXISTS (SELECT 1 FROM full.mappings m WHERE m.episode_id = ntp_episodes.episode_id AND m.local_id = ntp_episodes.local_id)")
            // A ledger entry keyed by a row (a provisional release of rotating enclosures, PROTOCOL §9.9) takes the episode the
            // snapshot maps that row to, before any admission joins the ledger: one entry per release, its work kept.
            var plan = Self.plan(build.plan, without: rebase)
            for row in try database.rows("SELECT l.occurrence, m.episode_id FROM ntp_ledger l JOIN full.mappings m ON m.local_id IS NOT NULL AND l.occurrence = 'local-episode:' || m.local_id WHERE l.generation_id NOT LIKE 'registration:%'") {
                if let from = row[0].text, let to = row[1].text, !plan.ledgerMoves.contains(where: { $0.from == from }) { plan.ledgerMoves.append((from, to)) }
            }
            try database.execute("INSERT INTO ntp_episodes(episode_id, local_id, podcast_id, kind, value, occurrence, merged_into) SELECT episode_id, local_id, podcast_id, kind, value, occurrence, merged_into FROM full.mappings WHERE true ON CONFLICT(episode_id) DO UPDATE SET local_id = coalesce(excluded.local_id, local_id), podcast_id = excluded.podcast_id, occurrence = coalesce(excluded.occurrence, occurrence), merged_into = excluded.merged_into")
            try writePlan(plan, now: now, result: &result)
            try materializeResolutions(resolutions, context: context)
            // A repair releases nothing (its admissions are seen), its re-projections neither (the basis's context).
            try writeRebase(rebase, basis: build.revisions, context: context, now: now, history: history, result: &result)
            result.work = build.work
            result.background = workLimit == nil && ticket?.budget != nil
            if head != source { try setCursor(head, watermark: nil) }
            // The request is fulfilled with this publication, durably and atomically.
            try database.execute("DELETE FROM ntp_requests WHERE name = ?", [.text(Self.fullSynchronizationRequest)])
            try crash?("full.written")
            return result
            }
        } } }
        result.lockMilliseconds = Self.milliseconds(started.duration(to: clock.now))
        result.rowsWritten = Int(database.totalChanges - changes)
        result.published = true
        return result
    }

    /// A Force full synchronization published as a whole inside the caller's write transaction, its staged snapshot
    /// attached as `full`: every row projected again from the intact local rows with the snapshot's semantics (its
    /// basis's context), the base made the snapshot's, the plan written (the caller fulfils the request). What a deferred
    /// repair does at the pause.
    private func publishFullInTransaction(now: Int64, history: ServerHistoryOracle?, basis: ServerRetainedBasis,
                                          crash: (@Sendable (String) throws -> Void)?, result: inout ServerUnitResult) throws {
        let projection = try ServerFullReprojection.project(database, history: history, now: now, context: basis.context) { [database] kind in
            try database.allocateID(kind)
        }
        for change in projection.changes {
            if change.deleted {
                try database.execute("DELETE FROM ntp_records WHERE entity = ? AND id = ? AND field_group = ?",
                                     [.text(change.entity), .text(change.id), .text(change.group)])
                continue
            }
            try database.execute("INSERT INTO ntp_records(entity, id, field_group, value, provenance) SELECT entity, id, field_group, value, provenance FROM full.records WHERE entity = ? AND id = ? AND field_group = ? ON CONFLICT(entity, id, field_group) DO UPDATE SET value = excluded.value, provenance = excluded.provenance",
                                 [.text(change.entity), .text(change.id), .text(change.group)])
            if change.entity == "episode", change.group == "identity" {
                try database.execute("INSERT INTO ntp_episodes(episode_id, local_id, podcast_id, kind, value, occurrence, merged_into) SELECT episode_id, NULL, podcast_id, kind, value, occurrence, merged_into FROM full.identities WHERE episode_id = ? ON CONFLICT(episode_id) DO UPDATE SET podcast_id = excluded.podcast_id, occurrence = excluded.occurrence, merged_into = excluded.merged_into",
                                     [.text(change.id)])
            }
        }
        try crash?("full.base")
        for id in projection.changedStates { try database.execute("DELETE FROM episode_swipe_undo WHERE episode_id = ?", [.integer(id)]) }
        try writePlan(projection.plan, now: now, result: &result)
        result.work = projection.plan.work + projection.changes.count
        result.wholeAtPause = true
    }

    /// Registrations the snapshot resolved materialize their drafts (idempotent: a resolved one is left as it is).
    private func materializeResolutions(_ resolutions: [ServerDecision], context: ServerLibraryContext) throws {
        for decision in resolutions {
            guard let podcast = decision.result["podcast_id"]?.stringValue, let mode = decision.result["mode"]?.stringValue,
                  try database.rows("SELECT state FROM ntp_registrations WHERE op_id = ?", [.text(decision.subject)]).first?.first?.text == "pending" else { continue }
            try materializeRegistration(opID: decision.subject, .init(podcastID: podcast, generationID: decision.result["generation_id"]?.stringValue,
                                                                      mode: mode, decisionID: decision.decisionID), context: context)
        }
    }
}
