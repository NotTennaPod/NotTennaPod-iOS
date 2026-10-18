import Foundation

extension ServerProjectionPlan: @unchecked Sendable {}

/// A built shadow (PROTOCOL §6.8): the full post-commit images of every affected feed and episode in
/// `staging/shadow-<seq>.sqlite`, the rest of the plan in memory, and the revisions it was built against.
struct ServerShadowBuild: Sendable {
    var url: URL
    var plan: ServerProjectionPlan
    /// Row writes of the whole unit, staged parts included.
    var work: Int
    /// Row writes its switch makes: `work` without what staging writes ahead of it, counted from what is actually left
    /// unstaged (each staged row and record once). What its admission, retries and the store's final check bound.
    var switchWork: Int
    /// What it was built against: its retained-publication basis (PROTOCOL §6.8).
    var revisions: ServerRetainedBasis
    /// The new podcasts the shadow stages before its unit, nil when it stages nothing.
    var staging: ServerShadowStaging? = nil
}

/// What a shadow stages: the podcasts and episodes it creates, the episodes' mappings new to the
/// library and the records of all of them new to the base, inserted in bounded transactions while the podcasts and
/// episodes are hidden; the unit then reveals them in one small transaction. Rows marked `stage = 1` in the shadow.
struct ServerShadowStaging: Sendable {
    /// New podcasts, hidden as a whole until the unit.
    var created: [(feedID: Int64, podcast: String)]
    /// New episodes of podcasts the library shows, each hidden until the unit (a new podcast's are hidden with it).
    var episodes: Int
    /// The feeds whose rows staging writes: their change generations are checked between transactions.
    var feeds: [Int64]
    /// Row writes staged ahead of the unit.
    var work: Int
    /// Content records the commit changes (metadata, a measured duration, a refresh status), written ahead of the unit;
    /// those the base held keep their previous values so that taking the staging out restores them.
    var updates = 0
    /// Shown rows only the commit's content changes (stall fix (c)): shown ahead of the unit in bounded transactions.
    var ahead = 0
}

enum ServerShadow {
    /// What a switch's reveal of one episode staged into a shown podcast costs, in counted row writes: it deletes the
    /// episode's hidden marker and updates its list keys and its podcast's counts (schema 21), three SQLite rows measured
    /// at about 12 µs together, a counted row write's cost (about 10 µs a row written, up to two rows each).
    static let revealWork = 1

    static let schema = [
        // `stage`: 1 for a row staged ahead of the unit, 0 for one the unit itself writes. Episodes
        // also: 2 for a shown row only the commit's content changes, shown ahead of the unit (stall fix (c)), 3 once
        // shown (the unit leaves it).
        "CREATE TABLE IF NOT EXISTS feeds (id INTEGER PRIMARY KEY, title TEXT, record BLOB NOT NULL, stage INTEGER NOT NULL DEFAULT 0)",
        "CREATE TABLE IF NOT EXISTS episodes (id INTEGER PRIMARY KEY, feed_id INTEGER NOT NULL, pubdate INTEGER NOT NULL, record BLOB NOT NULL, play_state_changed INTEGER NOT NULL, stage INTEGER NOT NULL DEFAULT 0)",
        // Read by stage inside the live lock: never a scan of the images.
        "CREATE INDEX IF NOT EXISTS episodes_stage ON episodes(stage, id)",
        "CREATE INDEX IF NOT EXISTS episodes_play_state ON episodes(play_state_changed)",
        // The commit's records (the post-commit base) and episode identities, copied in bulk at publication.
        "CREATE TABLE IF NOT EXISTS records (entity TEXT NOT NULL, id TEXT NOT NULL, field_group TEXT NOT NULL, value BLOB, provenance TEXT NOT NULL, tombstone INTEGER NOT NULL, stage INTEGER NOT NULL DEFAULT 0)",
        // (A Force full synchronization's staged base has its own `records` and `identities`: statements on these name
        // " records " and " identities ".)
        "CREATE INDEX IF NOT EXISTS records_stage ON records (stage, tombstone)",
        "CREATE INDEX IF NOT EXISTS records_tombstone ON records (tombstone)",
        "CREATE TABLE IF NOT EXISTS identities (episode_id TEXT PRIMARY KEY, podcast_id TEXT NOT NULL, kind TEXT NOT NULL, value TEXT NOT NULL, occurrence BLOB, merged_into TEXT, stage INTEGER NOT NULL DEFAULT 0)",
        "CREATE INDEX IF NOT EXISTS identities_stage ON identities (stage)",
        // The plan's episode mappings (wire episode → local row).
        "CREATE TABLE IF NOT EXISTS mappings (episode_id TEXT PRIMARY KEY, local_id INTEGER, podcast_id TEXT NOT NULL, kind TEXT NOT NULL, value TEXT NOT NULL, occurrence BLOB, merged_into TEXT, stage INTEGER NOT NULL DEFAULT 0)",
        // The switch reads what it writes itself by stage, never scanning what staging wrote ahead.
        "CREATE INDEX IF NOT EXISTS mappings_stage ON mappings(stage)",
    ]

    /// Builds a commit's shadow outside the live write lock: a read-only connection to the live library (one WAL
    /// snapshot), the commit's records as the post-commit base, its retirements excluded, local IDs from a reserved
    /// range.
    /// `touches`: the store's local-change log end, taken before the build reads anything.
    static func build(_ input: ServerUnitInput, database: URL, shadow url: URL, history: ServerHistoryOracle?,
                      feedIDs: ClosedRange<Int64>, episodeIDs: ClosedRange<Int64>, touches: ServerTouchWatermark) throws -> ServerShadowBuild {
        try? FileManager.default.removeItem(at: url)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix)) }
        let connection = try LibrarySQLite(readingOnly: database)
        defer { try? connection.close() }
        var projectorRetiring = 0
        var stage = StageSets()
        let (plan, revisions, changedStates) = try connection.transaction(write: false) { () throws -> (ServerProjectionPlan, ServerRetainedBasis, Set<Int64>) in
            guard let row = try connection.rows("SELECT namespace, account_id, install_id FROM ntp_library WHERE id = 1").first,
                  let namespace = row[0].text, let account = row[1].text, let install = row[2].text else {
                throw ServerRecordingError.corruptState("ntp_library")
            }
            var nextFeed = feedIDs.lowerBound, nextEpisode = episodeIDs.lowerBound
            let projector = ServerProjector(db: connection, namespace: namespace, accountID: account, now: input.now) { kind in
                if kind == "feed" {
                    guard nextFeed <= feedIDs.upperBound else { throw ServerApplyError.needsLocalIDs }
                    defer { nextFeed += 1 }
                    return nextFeed
                }
                guard nextEpisode <= episodeIDs.upperBound else { throw ServerApplyError.needsLocalIDs }
                defer { nextEpisode += 1 }
                return nextEpisode
            }
            projector.history = history
            // The commit's statistics resets cut this library's sessions; the publication stores the cuts (PROTOCOL §8.8).
            projector.commitResets = input.commit.accepted.filter { $0.type == "statistics.reset" && $0.isCausalNode }.map(\.opID)
            var scope = ServerProjectionScope()
            for record in input.commit.records {
                if record.entity == "episode", record.fieldGroup == "played_time" {
                    try projector.notePlayedTimeChange(episode: record.id, previous: try projector.record("episode", record.id, "played_time")?["played_ms"]?.integerValue ?? 0)
                }
            }
            for record in input.commit.records {
                projector.delta[record.key] = record
                scope.add(record: record.entity, id: record.id, group: record.fieldGroup)
            }
            for slot in input.commit.slots where slot.installID == install {
                guard try connection.rows("SELECT op_id FROM ntp_outbox WHERE install_seq = ?", [.integer(slot.installSeq)]).first?.first?.text == slot.opID else { continue }
                projector.excludedOps.insert(slot.opID)
                projectorRetiring += 1
                if let row = try connection.rows("SELECT type, receipt FROM ntp_outbox WHERE install_seq = ?", [.integer(slot.installSeq)]).first,
                   let type = row[0].text {
                    var receipt = input.commit.accepted.first { $0.opID == slot.opID }?.receipt
                    if receipt == nil, let data = row[1].data { receipt = try? ContractJSON.decode(data) }
                    let outcome = slot.result == "op_id_conflict" ? "op_id_conflict" : receipt?["outcome"]?.stringValue
                    try scope.withdraw(connection, opID: slot.opID, type: type, outcome: outcome)
                }
                for overlay in try connection.rows("SELECT entity, id, property FROM ntp_overlays WHERE op_id = ?", [.text(slot.opID)]) {
                    guard let entity = overlay[0].text, let id = overlay[1].text, let property = overlay[2].text else { continue }
                    scope.add(overlay: entity, id: id, property: property)
                }
            }
            for decision in input.commit.decisions where decision.type == "podcast.resolution" {
                guard let podcast = decision.result["podcast_id"]?.stringValue,
                      let feed = try connection.rows("SELECT feed_id FROM ntp_registrations WHERE op_id = ?", [.text(decision.subject)]).first?.first?.integer else { continue }
                projector.resolvedFeeds[podcast] = feed
            }
            try projector.addHistoryScope(input.commit, scope: &scope)
            try projector.project(scope)
            let projected = try ServerShadowScope(projector, player: try ServerFullReprojection.player(connection), live: connection)
            // Its projection context, for its switch and every retry: the commit's resets, the retirement's withdrawn
            // queue members and the queue memberships the commit removed.
            let removed = input.commit.records.filter { $0.entity == "episode" && $0.fieldGroup == "queue_membership" && $0.value == nil }.map(\.id)
            let context = ServerProjectionContext(commitResets: projector.commitResets, withdrawnQueue: scope.withdrawnQueue,
                                                  removedMemberships: Set(removed))
            let source = try connection.rows("SELECT cursor FROM ntp_library WHERE id = 1").first?.first?.text.map { try SyncCursor(encoded: $0) }
            var changed = Set<Int64>()
            for (id, entry) in projector.plan.episodes where !projector.plan.createdEpisodes.contains(id) {
                guard let row = try connection.rows("SELECT record FROM episodes WHERE id = ?", [.integer(id)]).first, let data = row[0].data else { continue }
                if try JSONDecoder.libraryRecord(LibraryEpisode.self, from: data).userState.playState != entry.episode.userState.playState { changed.insert(id) }
            }
            stage = try stageSets(projector.plan, records: input.commit.records, live: connection)
            stage.ahead = try aheadRows(input, plan: projector.plan, content: stage.content, playStateChanged: changed, scope: projected,
                                        live: connection, namespace: namespace, account: account, history: history)
            // A row shown ahead shows content the base must already hold: all of the commit's content changes are staged.
            if !stage.ahead.isEmpty { stage.updates = stage.content }
            return (projector.plan, ServerRetainedBasis(touches: touches, scope: projected, context: context, source: source, target: input.cursor), changed)
        }
        var small = plan
        // Only real changes count: records the base already holds identically are not written (stall fix (b)).
        let work = plan.work + stage.changedRecords + FeedLibraryStore.retirementWork * projectorRetiring
        // What its switch writes: the unit's work less what staging writes ahead, each staged row and record counted once
        // and only if the unit's work counts it (a staged record is one the commit changes; a staged row one the plan
        // writes).
        let stagedRecords = stage.records.union(stage.updates).intersection(stage.changedKeys)
        let stagedRows = stage.feeds.intersection(plan.feeds.keys).count + stage.episodes.intersection(plan.episodes.keys).count
            + stage.mappings.intersection(plan.episodeMappings.keys).count + stage.ahead.intersection(plan.episodes.keys).count
        // Revealing an episode staged into a shown podcast deletes its hidden marker and updates its list keys and its
        // podcast's counts (schema 21) in the switch (`revealWork` each). A new podcast is revealed as a whole, at no cost
        // per episode.
        let revealed = plan.episodes.filter { stage.episodes.contains($0.key) && !stage.feeds.contains($0.value.feedID) }.count
        let switchWork = work - stagedRecords.count - stagedRows + Self.revealWork * revealed
        // The images go to the shadow file; publication copies them with keyed statements.
        let file = try SyncSQLite(url: url, durable: false)
        defer { try? file.close() }
        try file.transaction {
            for statement in schema { try file.execute(statement) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            for (id, feed) in plan.feeds {
                var header = feed
                header.episodes = []
                try file.execute("INSERT INTO feeds(id, title, record, stage) VALUES (?, ?, ?, ?)",
                                 [.integer(id), feed.metadata.title.map(LibrarySQLValue.text) ?? .null, .blob(try encoder.encode(header)),
                                  .integer(stage.feeds.contains(id) ? 1 : 0)])
            }
            for (id, entry) in plan.episodes {
                guard let date = entry.episode.details.publicationDate else { throw FeedLibraryError.invalidMutation }
                let changed = changedStates.contains(id)
                try file.execute("INSERT INTO episodes(id, feed_id, pubdate, record, play_state_changed, stage) VALUES (?, ?, ?, ?, ?, ?)",
                                 [.integer(id), .integer(entry.feedID), .integer(Int64(date.timeIntervalSince1970 * 1_000)),
                                  .blob(try encoder.encode(entry.episode)), .integer(changed ? 1 : 0),
                                  .integer(stage.episodes.contains(id) ? 1 : stage.ahead.contains(id) ? 2 : 0)])
            }
            for record in input.commit.records {
                try file.execute("INSERT INTO records(entity, id, field_group, value, provenance, tombstone, stage) VALUES (?, ?, ?, ?, ?, ?, ?)",
                                 [.text(record.entity), .text(record.id), .text(record.fieldGroup),
                                  try record.value.map { .blob(try $0.canonicalData()) } ?? .null,
                                  .text(ContractJSON.array(record.provenance.map(ContractJSON.string)).canonicalText), .integer(record.value == nil ? 1 : 0),
                                  .integer(stage.records.contains(record.key) || stage.updates.contains(record.key) ? 1 : 0)])
                if record.entity == "episode", record.fieldGroup == "identity", let value = record.value, let podcast = value["podcast_id"]?.stringValue {
                    let occurrence = value["occurrence"]
                    try file.execute("INSERT OR REPLACE INTO identities(episode_id, podcast_id, kind, value, occurrence, merged_into, stage) VALUES (?, ?, ?, ?, ?, ?, ?)",
                                     [.text(record.id), .text(podcast), .text(occurrence?["k"]?.stringValue ?? "none"), .text(occurrence?["v"]?.stringValue ?? ""),
                                      try occurrence.map { .blob(try $0.canonicalData()) } ?? .null, value["merged_into"]?.stringValue.map(LibrarySQLValue.text) ?? .null,
                                      .integer(stage.mappings.contains(record.id) ? 1 : 0)])
                }
            }
            for (episode, mapping) in plan.episodeMappings {
                try file.execute("INSERT INTO mappings(episode_id, local_id, podcast_id, kind, value, occurrence, merged_into, stage) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                                 [.text(episode), mapping.localID.map(LibrarySQLValue.integer) ?? .null, .text(mapping.podcast), .text(mapping.kind),
                                  .text(mapping.value), try mapping.occurrence.map { .blob(try $0.canonicalData()) } ?? .null,
                                  mapping.mergedInto.map(LibrarySQLValue.text) ?? .null, .integer(stage.mappings.contains(episode) ? 1 : 0)])
            }
        }
        small.feeds = [:]
        small.episodes = [:]
        small.episodeMappings = [:]
        let touched = Set(stage.created.map(\.feedID)).union(plan.episodes.compactMap { stage.episodes.contains($0.key) ? $0.value.feedID : nil })
        return ServerShadowBuild(url: url, plan: small, work: work, switchWork: switchWork, revisions: revisions,
                                 staging: stage.work > 0 ? ServerShadowStaging(created: stage.created,
                                                                               episodes: plan.episodes.filter { stage.episodes.contains($0.key) && !stage.feeds.contains($0.value.feedID) }.count,
                                                                               feeds: touched.sorted(), work: stage.work, updates: stage.updates.count,
                                                                               ahead: stage.ahead.count) : nil)
    }

    /// Rows a shadow stages ahead of its unit, and the commit's real record changes.
    struct StageSets {
        var created: [(feedID: Int64, podcast: String)] = []
        var feeds: Set<Int64> = []
        var episodes: Set<Int64> = []
        var mappings: Set<String> = []
        var records: Set<ServerRecordKey> = []
        /// Content records staged ahead (stall fix (c)): those the base holds keep their previous values.
        var updates: Set<ServerRecordKey> = []
        /// Every content record the commit changes (values, not tombstones): what `updates` takes when rows are shown ahead.
        var content: Set<ServerRecordKey> = []
        /// Shown rows only the commit's content changes, shown ahead of the unit (stall fix (c)).
        var ahead: Set<Int64> = []
        /// Records whose value or provenance differs from the base's (or that it lacks, or a tombstone of one it has).
        var changedKeys: Set<ServerRecordKey> = []
        var changedRecords: Int { changedKeys.count }
        /// Rows and records staged ahead, each once (a new episode's metadata is both new to the base and content).
        var work: Int { feeds.count + episodes.count + mappings.count + records.union(updates).count + ahead.count }
    }

    /// The field groups whose changes are staged ahead of their unit: content no local action records a fact about or
    /// reads causally (a fact's dependencies never cite them; no claim, position or queue decision reads them). The base
    /// takes them a moment before the unit's switch, and a shown row that only they change shows them then too, each row
    /// whole (`aheadRows`): nothing anyone records depends on when that happens. Everything a person's actions depend on
    /// (listening, play state, favorites, history, the queue, subscriptions, identities) stays in the switch.
    static let stagedUpdateGroups: Set<String> = ["metadata", "measured_duration", "refresh_status"]

    /// The commit's content records that change the base: values only (a tombstone stays the unit's to write).
    static func stagedContent(_ records: [ServerRecord], changed: Set<ServerRecordKey>) -> Set<ServerRecordKey> {
        Set(records.lazy.filter { $0.value != nil && stagedUpdateGroups.contains($0.fieldGroup) && changed.contains($0.key) }.map(\.key))
    }

    /// No row is shown ahead by a projection that would create one.
    private struct AheadCreates: Error {}

    /// The shown rows only the commit's content changes (stall fix (c)), read on the build's snapshot: each changed
    /// episode row of the plan (not created, its play state unchanged, no structural change of the plan, not the player's)
    /// whose full post-commit image equals, exactly, its image projected with the commit's content records alone. Showing
    /// such a row before the unit shows only content the staging has put in the base; its row is otherwise the one the
    /// unit writes. Empty when there are too few to be worth staging.
    static func aheadRows(_ input: ServerUnitInput, plan: ServerProjectionPlan, content: Set<ServerRecordKey>, playStateChanged: Set<Int64>,
                          scope: ServerShadowScope, live: LibrarySQLite, namespace: String, account: String,
                          history: ServerHistoryOracle?) throws -> Set<Int64> {
        guard !content.isEmpty else { return [] }
        let player = Set(scope.player.compactMap { $0 })
        let candidates = plan.episodes.keys.filter {
            !plan.createdEpisodes.contains($0) && !playStateChanged.contains($0) && !scope.structural.contains($0) && !player.contains($0)
        }
        guard candidates.count >= FeedLibraryStore.removalBatch else { return [] }
        let projector = ServerProjector(db: live, namespace: namespace, accountID: account, now: input.now) { _ in throw AheadCreates() }
        projector.history = history
        var contentScope = ServerProjectionScope()
        for record in input.commit.records where content.contains(record.key) {
            projector.delta[record.key] = record
            contentScope.add(record: record.entity, id: record.id, group: record.fieldGroup)
        }
        // Nothing is shown ahead when the content alone cannot be projected on its own (it would create a row): the unit
        // shows it.
        do { try projector.project(contentScope) } catch { return [] }
        var ahead = Set<Int64>()
        for id in candidates {
            guard let full = plan.episodes[id], let alone = projector.plan.episodes[id], alone.feedID == full.feedID, alone.episode == full.episode else { continue }
            ahead.insert(id)
        }
        return ahead.count >= FeedLibraryStore.removalBatch ? ahead : []
    }

    /// The commit's records that change the base, compared exactly (canonical value bytes and provenance), read on
    /// `live` in chunks.
    static func changedRecordKeys(_ records: [ServerRecord], live: LibrarySQLite) throws -> (changed: Set<ServerRecordKey>, existing: Set<ServerRecordKey>) {
        var changed = Set<ServerRecordKey>(), existing = Set<ServerRecordKey>()
        var stored: [ServerRecordKey: (value: Data?, provenance: String?)] = [:]
        let byEntity = Dictionary(grouping: records, by: \.entity)
        for (entity, group) in byEntity {
            let ids = Array(Set(group.map(\.id))).sorted()
            for start in stride(from: 0, to: ids.count, by: 500) {
                let chunk = ContractJSON.array(ids[start..<min(ids.count, start + 500)].map(ContractJSON.string)).canonicalText
                for row in try live.rows("SELECT id, field_group, value, provenance FROM ntp_records WHERE entity = ? AND id IN (SELECT value FROM json_each(?))",
                                         [.text(entity), .text(chunk)]) {
                    guard let id = row[0].text, let fieldGroup = row[1].text else { continue }
                    stored[ServerRecordKey(entity: entity, id: id, fieldGroup: fieldGroup)] = (row[2].data, row[3].text)
                }
            }
        }
        for record in records {
            let current = stored[record.key]
            if current != nil { existing.insert(record.key) }
            if let value = record.value {
                let provenance = ContractJSON.array(record.provenance.map(ContractJSON.string)).canonicalText
                if try current?.value != value.canonicalData() || current?.provenance != provenance { changed.insert(record.key) }
            } else if current != nil {
                changed.insert(record.key)
            }
        }
        return (changed, existing)
    }

    /// The podcasts and episodes a commit creates (a podcast another device subscribed, its catalog arriving), with
    /// enough rows to be worth staging: their feed and episode rows, the mappings of those episodes the library does
    /// not have, and the records of the podcasts and those episodes the base does not have (a key the base holds is the
    /// unit's to change). Read on the build's snapshot.
    static func stageSets(_ plan: ServerProjectionPlan, records: [ServerRecord], live: LibrarySQLite) throws -> StageSets {
        var sets = StageSets()
        let changes = try changedRecordKeys(records, live: live)
        sets.changedKeys = changes.changed
        // Content records the commit changes (another device's observation of a catalog, a refresh's new metadata): staged
        // ahead, only when there are enough of them to be worth it (or when rows they alone change are shown ahead).
        sets.content = stagedContent(records, changed: changes.changed)
        let updates = sets.content.count >= FeedLibraryStore.removalBatch ? sets.content : []
        guard !plan.createdFeeds.isEmpty || !plan.createdEpisodes.isEmpty else {
            sets.updates = updates
            return sets
        }
        for (podcast, mapping) in plan.podcastMappings {
            if let feed = mapping.feedID, plan.createdFeeds.contains(feed) { sets.created.append((feed, podcast)) }
        }
        sets.created.sort { $0.feedID < $1.feedID }
        sets.feeds = Set(sets.created.map(\.feedID))
        sets.episodes = plan.createdEpisodes.filter { plan.episodes[$0] != nil }
        var wire = Set<String>()
        for (episode, mapping) in plan.episodeMappings {
            guard let local = mapping.localID, sets.episodes.contains(local) else { continue }
            wire.insert(episode)
        }
        let podcasts = Set(sets.created.map(\.podcast))
        // What the library already has of them, read in chunks: a known mapping or base record is the unit's.
        var knownEpisodes = Set<String>(), knownRecords = Set<ServerRecordKey>()
        let ids = wire.sorted()
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = ContractJSON.array(ids[start..<min(ids.count, start + 500)].map(ContractJSON.string)).canonicalText
            for row in try live.rows("SELECT episode_id FROM ntp_episodes WHERE episode_id IN (SELECT value FROM json_each(?))", [.text(chunk)]) {
                if let id = row[0].text { knownEpisodes.insert(id) }
            }
            for row in try live.rows("SELECT id, field_group FROM ntp_records WHERE entity = 'episode' AND id IN (SELECT value FROM json_each(?))", [.text(chunk)]) {
                if let id = row[0].text, let group = row[1].text { knownRecords.insert(ServerRecordKey(entity: "episode", id: id, fieldGroup: group)) }
            }
        }
        for podcast in podcasts {
            for row in try live.rows("SELECT field_group FROM ntp_records WHERE entity = 'podcast' AND id = ?", [.text(podcast)]) {
                if let group = row[0].text { knownRecords.insert(ServerRecordKey(entity: "podcast", id: podcast, fieldGroup: group)) }
            }
        }
        sets.mappings = wire.subtracting(knownEpisodes)
        for record in records where record.value != nil && !knownRecords.contains(record.key)
            && ((record.entity == "podcast" && podcasts.contains(record.id)) || (record.entity == "episode" && wire.contains(record.id))) {
            sets.records.insert(record.key)
        }
        sets.updates = updates
        // A small podcast is not worth the extra transactions: the unit writes it.
        if sets.episodes.count + sets.records.count < FeedLibraryStore.removalBatch {
            var updatesOnly = StageSets()
            updatesOnly.changedKeys = sets.changedKeys
            updatesOnly.content = sets.content
            updatesOnly.updates = sets.updates
            return updatesOnly
        }
        return sets
    }
}

extension FeedLibraryStore {
    /// Reserves local feed and episode IDs for a shadow (`library_ids`; IDs are never reused, so an unused one is a
    /// harmless gap).
    func reserveServerLocalIDs(feeds: Int, episodes: Int) throws -> (feeds: ClosedRange<Int64>, episodes: ClosedRange<Int64>) {
        try syncTransactions(ServerTransactionKind.bookkeeping) { try database.transaction {
            func reserve(_ kind: String, _ count: Int) throws -> ClosedRange<Int64> {
                let first = try database.scalar("SELECT value FROM library_ids WHERE kind = ?", [.text(kind)]) + 1
                try database.execute("UPDATE library_ids SET value = value + ? WHERE kind = ?", [.integer(Int64(max(count, 1))), .text(kind)])
                return first...(first + Int64(max(count, 1)) - 1)
            }
            return (try reserve("feed", feeds), try reserve("episode", episodes))
        } }
    }

    /// Publishes a shadow in one live transaction on the attached shadow file (PROTOCOL §6.8), a bounded atomic switch
    /// that keeps concurrent local operations: the local changes in its scope since it was built that are simple row
    /// images (a favorite, a checkpoint, a play-state change, a queue edit) are not written from its images but
    /// re-projected here from the base and the current overlays with its original projection context (`rebase`), so they
    /// stay. One that meets a structural dependency of its plan (a removal, merge or transfer, ownership, an identity
    /// match, a download job), or a switch whose work is over its limit (`workLimit`, else the `ticket`'s background
    /// budget), throws `ServerApplyError.deferred`, nothing written, and the engine keeps it for the pause; there (no
    /// limit) it is published as a whole instead, correctly: its staging taken out and the unit applied from the intact
    /// local rows. Rows are written with keyed statements only.
    func publishServerShadow(_ shadow: ServerShadowBuild, input: ServerUnitInput, history: ServerHistoryOracle?,
                             ticket: ServerPublicationTicket? = nil, workLimit: Int? = nil) throws -> ServerUnitResult {
        guard let context = serverContext else { throw ServerRecordingError.notAServerLibrary }
        try ensureServerExchangeTables()
        try database.execute("ATTACH DATABASE ? AS shadow", [.text(shadow.url.path)])
        defer { try? database.execute("DETACH DATABASE shadow") }
        let clock = ContinuousClock(), started = clock.now
        let changes = database.totalChanges, steps = database.statementSteps
        let kind = workLimit == nil && ticket?.budget != nil ? ServerTransactionKind.backgroundPublication : ServerTransactionKind.publication
        var published = try syncTransactions(kind) { try write(.remote, durable: true) {
            var result = ServerUnitResult(seq: input.commit.seq)
            let live = try serverExchangeState().cursor
            if let live, live.logID == input.cursor.logID, input.commit.seq <= live.seq { result.alreadyApplied = true; return result }
            guard let live, live.logID == input.cursor.logID, input.commit.seq == live.seq + 1 else {
                throw ServerApplyError.outOfOrder(live: live?.seq, commit: input.commit.seq)
            }
            // Admitted only while nobody started using the app since it was allowed.
            if let ticket, !ticket.isCurrent { throw ServerApplyError.ineligible }
            // What local changes touched in its scope since it was built, re-projected below, or what defers it.
            let rebase: ServerTouchedRebase
            // The podcasts staged ahead of the unit are revealed by it: exactly this shadow's.
            let staged = try database.scalar("SELECT count(*) FROM ntp_hidden_feeds WHERE state = 'staging'")
            let hidden = try database.scalar("SELECT count(*) FROM ntp_hidden_episodes")
            // The 1,000-row budget while audio plays or the app is in use, the ticket's background budget while audio plays
            // with no scene in the foreground, or none.
            let limit = Self.publicationLimit(workLimit: workLimit, ticket: ticket)
            do {
                guard staged == Int64(shadow.staging?.created.count ?? 0), hidden == Int64(shadow.staging?.episodes ?? 0) else {
                    throw ServerApplyError.deferred("its staged rows changed")
                }
                // Rows to show ahead that staging did not show (a local change touched them, or it stopped) are the switch's.
                let unshown = (shadow.staging?.ahead ?? 0) > 0 ? Int(try database.scalar("SELECT count(*) FROM shadow.episodes WHERE stage = 2")) : 0
                rebase = try self.rebase(shadow.revisions, stagedWork: shadow.switchWork + unshown, workLimit: limit, plan: shadow.plan)
            } catch ServerApplyError.deferred(let reason) {
                // With the budget relaxed (no limit: the pause), it is published as a whole instead, correctly: its staging
                // taken out and the unit applied from the intact local rows with its full context, in this transaction.
                guard limit == nil else { throw Self.deferred(reason, workLimit: workLimit, ticket: ticket) }
                try quietServerTouches { try discardAllServerStaging() }
                try applyUnitInTransaction(input, context: context, history: history, maxWork: nil, result: &result)
                result.wholeAtPause = true
                return result
            }
            return try quietServerTouches { () throws -> ServerUnitResult in
            // Its staged content updates are the unit's own from here on.
            if shadow.staging != nil { try database.execute("DELETE FROM ntp_staging") }
            if staged > 0 || hidden > 0 {
                // Revealed: every read sees them from this transaction on (their feeds' cached images are reloaded).
                try database.execute("UPDATE feed_changes SET generation = generation + 1, episode_generation = episode_generation + 1 WHERE feed_id IN (SELECT DISTINCT feed_id FROM ntp_hidden_episodes)")
                try database.execute("DELETE FROM ntp_hidden_episodes")
                try database.execute("DELETE FROM ntp_hidden_feeds WHERE state = 'staging'")
                try database.execute("DELETE FROM ntp_staging")
            }
            let projector = try unitProjector(context: context, now: input.now)
            projector.history = history
            // A record the commit writes ends a recovery's hold on it (the shadow read the commit's record over it).
            try projector.dropHolds(input.commit.records.map(\.key))
            // The bases a pending statistics reset keeps were read before the commit's records, at staging.
            projector.plan.overlayAdditions = shadow.plan.overlayAdditions
            var scope = ServerProjectionScope()
            for record in input.commit.records { scope.add(record: record.entity, id: record.id, group: record.fieldGroup) }
            // The base, in bulk from the shadow (each record once per commit): records, tombstones, episode identities.
            try database.execute("INSERT INTO ntp_records(entity, id, field_group, value, provenance) SELECT entity, id, field_group, value, provenance FROM shadow.records WHERE tombstone = 0 AND stage = 0 ON CONFLICT(entity, id, field_group) DO UPDATE SET value = excluded.value, provenance = excluded.provenance WHERE ntp_records.value IS NOT excluded.value OR ntp_records.provenance IS NOT excluded.provenance")
            try database.execute("DELETE FROM ntp_records WHERE (entity, id, field_group) IN (SELECT entity, id, field_group FROM shadow.records WHERE tombstone = 1)")
            try database.execute("INSERT INTO ntp_episodes(episode_id, local_id, podcast_id, kind, value, occurrence, merged_into) SELECT episode_id, NULL, podcast_id, kind, value, occurrence, merged_into FROM shadow.identities WHERE stage = 0 ON CONFLICT(episode_id) DO UPDATE SET podcast_id = excluded.podcast_id, occurrence = excluded.occurrence, merged_into = excluded.merged_into WHERE ntp_episodes.podcast_id IS NOT excluded.podcast_id OR ntp_episodes.occurrence IS NOT excluded.occurrence OR ntp_episodes.merged_into IS NOT excluded.merged_into")
            try addNodes(input.commit)
            try applyDecisions(input.commit, context: context, projector: projector, inTransaction: true)
            try retire(input.commit, context: context, scope: &scope, result: &result)
            try noteRetiredPlayback(input.commit, retired: result.retired, history: history)
            try input.crash?("publish.base")
            // The rows: the staged images, except those local changes touched since (re-projected below) and those shown
            // ahead.
            let rows = ContractJSON.array(rebase.rows.sorted().map(ContractJSON.integer)).canonicalText
            try database.execute("DELETE FROM episode_swipe_undo WHERE episode_id IN (SELECT id FROM shadow.episodes WHERE play_state_changed = 1 AND id NOT IN (SELECT value FROM json_each(?)))", [.text(rows)])
            try database.execute("INSERT INTO feeds(id, title, record) SELECT id, title, record FROM shadow.feeds WHERE stage = 0 ON CONFLICT(id) DO UPDATE SET title = excluded.title, record = excluded.record WHERE feeds.title IS NOT excluded.title OR feeds.record IS NOT excluded.record")
            try database.execute("INSERT INTO episodes(id, feed_id, pubdate, record) SELECT id, feed_id, pubdate, record FROM shadow.episodes WHERE stage IN (0, 2) AND id NOT IN (SELECT value FROM json_each(?)) ON CONFLICT(id) DO UPDATE SET pubdate = excluded.pubdate, record = excluded.record WHERE episodes.feed_id = excluded.feed_id AND (episodes.pubdate IS NOT excluded.pubdate OR episodes.record IS NOT excluded.record)", [.text(rows)])
            // Episode mappings: another holder of a local row lets go first (local_id is unique).
            try database.execute("UPDATE ntp_episodes SET local_id = NULL WHERE local_id IN (SELECT local_id FROM shadow.mappings WHERE local_id IS NOT NULL AND stage = 0)")
            try database.execute("INSERT INTO ntp_episodes(episode_id, local_id, podcast_id, kind, value, occurrence, merged_into) SELECT episode_id, local_id, podcast_id, kind, value, occurrence, merged_into FROM shadow.mappings WHERE stage = 0 ON CONFLICT(episode_id) DO UPDATE SET local_id = coalesce(excluded.local_id, local_id), podcast_id = excluded.podcast_id, occurrence = coalesce(excluded.occurrence, occurrence), merged_into = excluded.merged_into")
            result.work = shadow.work
            result.background = workLimit == nil && ticket?.budget != nil
            try writePlan(Self.plan(shadow.plan, without: rebase), now: input.now, result: &result)
            try writeRebase(rebase, basis: shadow.revisions, context: context, now: input.now, history: history, result: &result)
            try setCursor(input.cursor, watermark: input.watermark)
            try input.crash?("publish.written")
            return result
            }
        } }
        published.lockMilliseconds = Self.milliseconds(started.duration(to: clock.now))
        published.lockSteps = database.statementSteps - steps
        published.rowsWritten = Int(database.totalChanges - changes)
        published.published = true
        return published
    }
}

/// A shadow built for a commit and not published yet (PROTOCOL §6.8): kept for that commit and retried at the next exchange or
/// pause, never built again unless the base it was built on moved (another lineage, an earlier commit applied: its
/// basis's source cursor is no longer the live one).
struct ServerKeptShadow: Sendable {
    var build: ServerShadowBuild
    /// Row writes of its unit beyond what is staged, and whether that is over the publication budget.
    var unitWork: Int
    var large: Bool
    /// Its new rows are staged (a unit over the budget is staged only when it may run).
    var staged: Bool
}

extension ServerSyncEngine {
    /// Builds a shadow, stages its new rows and publishes it (PROTOCOL §6.8): a bounded atomic switch that keeps the local
    /// changes made meanwhile that are simple row images (`FeedLibraryStore.rebase`). While audio plays or the app is in
    /// use, a publication over its budget, or one a local change since its staging defers (it meets a structural
    /// dependency of its plan, or the switch would be over the budget), waits (nil), kept: at the pause it is published
    /// without building it again, as a whole if a deferral still holds.
    func publishShadow(_ input: ServerUnitInput, report: inout ServerExchangeReport) async throws -> ServerUnitResult? {
        var extra = 0
        var deferredOnce = false
        for _ in 0..<8 {
            do {
                var kept: ServerKeptShadow
                if let current = keptShadow, current.build.revisions.target == input.cursor,
                   FileManager.default.fileExists(atPath: current.build.url.path) {
                    kept = current
                } else {
                    // A staging an earlier attempt left (a crash, another commit's) is taken out: the new shadow stages afresh.
                    try await dropKeptShadow()
                    try await discardStaging()
                    let identities = input.commit.records.filter { $0.entity == "episode" && $0.fieldGroup == "identity" }.count
                    let podcasts = input.commit.records.filter { $0.entity == "podcast" && $0.fieldGroup == "subscription" }.count
                    let reserved = try await store.reserveServerLocalIDs(feeds: podcasts + 1, episodes: identities + 64 + extra)
                    let url = staging.appendingPathComponent("shadow-\(input.commit.seq).sqlite")
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                    // The local-change log's end before anything is read: what changes after it, its switch re-projects.
                    let touches = try await store.serverTouchWatermark()
                    let shadow: ServerShadowBuild
                    let clock = ContinuousClock(), started = clock.now
                    do {
                        shadow = try ServerShadow.build(input, database: databaseURL, shadow: url, history: history,
                                                        feedIDs: reserved.feeds, episodeIDs: reserved.episodes, touches: touches)
                        report.shadowBuildMilliseconds = max(report.shadowBuildMilliseconds, FeedLibraryStore.milliseconds(started.duration(to: clock.now)))
                    } catch ServerApplyError.needsLocalIDs {
                        extra = max(1_024, extra * 4)
                        continue
                    }
                    report.shadowsBuilt += 1
                    try crash("shadow.built")
                    // A new podcast's rows are staged in bounded transactions; only what its unit writes counts here. A
                    // larger unit runs only when nobody uses the app and no audio plays; built, it is
                    // kept for then, not built again.
                    let unitWork = shadow.switchWork
                    kept = ServerKeptShadow(build: shadow, unitWork: unitWork, large: unitWork > publishWorkLimit, staged: false)
                    keptShadow = kept
                }
                let what = "commit \(input.commit.seq): \(kept.unitWork) row writes"
                // A unit over the budget is staged only when it may run (and admitted again just before its switch).
                if kept.large, !(await largePublicationMayRun(&report, what, work: kept.unitWork)) {
                    deferredUnit = (input.cursor.logID, input.commit.seq, kept.unitWork)
                    return nil
                }
                if !kept.staged {
                    do {
                        kept.build = try await stage(kept.build, seq: input.commit.seq, report: &report)
                    } catch ServerApplyError.stale {
                        // A feed it stages into went away: what is staged is taken out with the whole publication.
                        log("apply", "commit \(input.commit.seq): a podcast it stages into went away during its staging")
                    } catch {
                        // Stopped mid-staging (a crash, a cancellation): the next exchange takes the staging out and
                        // builds it again, as after a relaunch.
                        keptShadow = nil
                        Self.removeStagingFile(kept.build.url)
                        throw error
                    }
                    kept.staged = true
                    keptShadow = kept
                }
                try await beforePublish?()
                var ticket: ServerPublicationTicket?
                // Over the budget, or deferred within it by the switch's re-projection: admitted as a large publication (whole
                // in the background while audio plays, within the background budget).
                if kept.large || deferredOnce {
                    guard let allowed = await largePublicationTicket(&report, what, work: kept.unitWork) else {
                        deferredUnit = (input.cursor.logID, input.commit.seq, kept.unitWork)
                        return nil
                    }
                    ticket = allowed
                }
                // Within the publication budget while audio plays or the app is in use (the switch's re-projection
                // included); when nobody uses it and nothing plays (or under the ticket), whatever it takes, as a whole if
                // a local change since its staging needs it.
                let busy = await isPlaying() ? true : await isForeground()
                let result = try await store.publishServerShadow(kept.build, input: input, history: history, ticket: ticket,
                                                                 workLimit: ticket == nil && busy ? publishWorkLimit : nil)
                try await dropKeptShadow()
                report.publishedUnits += 1
                report.rebasedEntities += result.rebased
                if result.background {
                    log("apply", "commit \(input.commit.seq): \(result.work) row writes published whole while audio plays in the background")
                }
                if result.wholeAtPause {
                    log("apply", "commit \(input.commit.seq): published as a whole (local changes since its staging needed its whole projection)")
                } else if result.rebased > 0 {
                    log("apply", "commit \(input.commit.seq): \(result.rebased) local changes since staging re-projected at its publication")
                }
                try crash("shadow.published")
                return result
            } catch ServerApplyError.ineligible {
                // Someone started using the app (or audio started) while it waited for the store: it waits, kept.
                let unitWork = keptShadow?.unitWork ?? 0
                if !(await largePublicationMayRun(&report, "commit \(input.commit.seq): \(unitWork) row writes", work: unitWork)) {
                    deferredUnit = (input.cursor.logID, input.commit.seq, unitWork)
                    return nil
                }
            } catch ServerApplyError.deferred(let reason) {
                // Kept for the pause, where it is published as a whole if the deferral still holds; in the background while
                // audio plays it is tried once more as a large publication, unless one was deferred there already.
                deferredOnce = true
                if !(await largePublicationMayRun(&report, "commit \(input.commit.seq): \(reason)", work: keptShadow?.unitWork)) { return nil }
            }
        }
        throw ServerApplyError.needsLocalIDs
    }

    /// Forgets the kept shadow (published, or built again): its file goes, and the local-change log before it.
    func dropKeptShadow() async throws {
        guard let kept = keptShadow else { return }
        keptShadow = nil
        Self.removeStagingFile(kept.build.url)
        try await releaseTouches()
    }

    /// Before the next commit applies: a kept shadow of another commit (the base moved: another lineage, or its commit
    /// applied by other means) is dropped with its staging; a kept shadow of exactly the next commit keeps its staging.
    func reconcileKeptShadow() async throws {
        let live = try await store.serverExchangeState().cursor
        if let kept = keptShadow, let live, kept.build.revisions.source == live { return }
        try await dropKeptShadow()
        try await discardStaging()
        // Nothing kept needs the local-change log before now.
        try await releaseTouches()
    }

    /// Releases the local-change log up to what no kept staged result needs.
    func releaseTouches() async throws {
        let needed = [keptShadow?.build.revisions.touches, keptFull?.build.revisions.touches].compactMap { $0 }
        if needed.isEmpty { try await store.releaseServerTouches(through: nil) }
        else if let oldest = needed.map(\.id).min() { try await store.releaseServerTouches(through: oldest) }
    }

    static func removeStagingFile(_ url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix)) }
    }
}
