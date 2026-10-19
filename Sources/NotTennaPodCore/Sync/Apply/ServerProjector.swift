import Foundation

/// The archive's history entries and coverage walk, for per-entry history (PROTOCOL §6.8). The live unit
/// reads it through its own connection to `sync.sqlite`, read only.
protocol ServerHistoryOracle: AnyObject {
    /// The episode's history entries, cuts and restores (`activity`, `mark`, `remove`, `restore`).
    func items(_ episode: String) throws -> [ServerArchive.HistoryItem]
    /// The account's history clears.
    func clears() throws -> [ServerArchive.HistoryItem]
    /// Whether `node` is in the causal past of `cut`.
    func isInPast(_ node: String, of cut: String) throws -> Bool
}

/// A read-only connection to a library's archive for the live unit's history derivation. Its own connection, used
/// by one caller at a time (a lock), so the store's unit and the engine's shadow build may both read it.
final class ServerArchiveReader: ServerHistoryOracle, @unchecked Sendable {
    private let archive: ServerArchive
    private let lock = NSLock()

    init(url: URL) throws { archive = try ServerArchive(url: url) }

    func items(_ episode: String) throws -> [ServerArchive.HistoryItem] {
        try lock.withLock { try archive.historyItems(episodes: [episode])[episode] ?? [] }
    }
    func clears() throws -> [ServerArchive.HistoryItem] { try lock.withLock { try archive.historyItems(episodes: [])["*"] ?? [] } }
    func isInPast(_ node: String, of cut: String) throws -> Bool {
        try lock.withLock {
            guard let position = try archive.position(of: node) else { return false }
            return try archive.isInPast(node, of: cut, notBefore: position)
        }
    }
    func close() { lock.withLock { try? archive.close() } }
}

/// A play load's owed queue facts: added and re-placed members, and whether its keys are unsettled.
struct ServerOwedQueue: Sendable {
    var adds: Set<Int64> = []
    var placements: Set<Int64> = []
    var unsettled = false
}

/// One overlay row (`ntp_overlays`, PROTOCOL §6.8).
struct ServerOverlayRow: Sendable {
    var opID: String
    var entity: String
    var id: String
    var property: String
    var kind: String
    var value: ContractJSON?
    var clock: Int64
}

/// Projects the server's records onto a library's rows, through the overlays of its unretired local facts and the
/// player's pin (PROTOCOL §6.8). It reads one connection (the live one inside a unit, or a read-only one
/// for a shadow) and produces a `ServerProjectionPlan`; it never writes. For a shadow, `delta` holds the commit's
/// records (not yet in `ntp_records`) and `excludedOps` the facts the commit retires.
final class ServerProjector {
    let db: LibrarySQLite
    let namespace: String
    let accountID: String
    /// Commit records not yet in `ntp_records` (a shadow's post-commit base).
    var delta: [ServerRecordKey: ServerRecord] = [:]
    /// The records a unit's commit removed from the base (its tombstones; a shadow's are in `delta`).
    var removedRecords: Set<ServerRecordKey> = []
    /// Ops whose overlays no longer apply (retired by the commit, in a shadow).
    var excludedOps: Set<String> = []
    /// Registrations resolved by the commit: podcast → the registration's local feed.
    var resolvedFeeds: [String: Int64] = [:]
    /// Merged feeds' rows classified off the store with the state still the same (`ServerDeferredMerges`).
    var precomputedMerges: [Int64: ServerMergeRows] = [:]
    /// Episodes a refused queue add of this library had shown as queued (`ServerProjectionScope.withdrawnQueue`).
    var withdrawnQueue: Set<String> = []
    var history: ServerHistoryOracle?
    /// The statistics resets the commit accepts (PROTOCOL §8.8): a shadow built before its publication counts their cuts of this
    /// library's sessions (`ServerSyncSession.noteAcceptedCut`), which the publication then stores.
    var commitResets: [String] = []
    /// Allocates a local feed or episode ID (`library_ids`).
    var allocate: (String) throws -> Int64
    /// The commit's time, for placeholders without a publication date (PROTOCOL §6.8).
    var now: Int64
    /// Whether admissions are new releases (pulls) or seen (an attach snapshot, PROTOCOL §15.4).
    var admissionsSeen = false
    /// Where the base is read: `ntp_records`, or a staged snapshot's records (Force full synchronization, PROTOCOL §6.14).
    var baseTable = "ntp_records"
    /// Force full synchronization (PROTOCOL §6.14): the attached staging file's schema (`records`, `identities`). The snapshot
    /// is the whole base: the episodes of a podcast are its identities, and a server-known episode without a queue
    /// record is not queued.
    var fullBase: String?

    var plan = ServerProjectionPlan()
    /// What this projector projected (a staged publication's scope, `ServerShadowScope`).
    var visited = ServerShadowScope()
    private var feedOfPodcast: [String: Int64?] = [:]
    private var derivations: [Int64: [String: Int64]] = [:]
    /// Rows a podcast's new identity rules gave another episode: row → its episode now.
    private var reassigned: [Int64: String] = [:]
    /// The episodes such rows left, with the row whose pending overlays they hold.
    private var leftBy: [String: Int64] = [:]
    private var removedPodcasts: Set<String> = []
    private lazy var selection: Int64? = try? db.rows("SELECT episode_id FROM playback_selection WHERE id = 1").first?.first?.integer
    private lazy var sessionEpisode: Int64? = try? db.rows("SELECT episode_id FROM playback_session WHERE id = 1").first?.first?.integer
    private var owedCache: ServerOwedQueue?
    /// Episodes with listening no exported fact represents yet: their marked fields stay as this
    /// device has them, in every projection.
    private lazy var localPlayback: [Int64: (fields: ServerEpisodeFields, queue: Bool)] = {
        var marks: [Int64: (fields: ServerEpisodeFields, queue: Bool)] = [:]
        for row in (try? db.rows("SELECT episode_id, fields, queue FROM ntp_local_playback")) ?? [] {
            guard let id = row[0].integer, let fields = row[1].integer else { continue }
            marks[id] = (ServerEpisodeFields(rawValue: Int(fields)), row[2].integer == 1)
        }
        return marks
    }()

    /// Base records a recovery holds as this library had them (`ntp_recovery_holds`):
    /// read in place of the base, below a commit's own records (`delta`), so what a change waiting for another device
    /// showed stays shown in every projection; a held podcast or episode identity is never removed as absent. Looked
    /// up by key as needed (a unit never loads them all), once each.
    private lazy var anyHolds: Bool = ((try? db.scalar("SELECT EXISTS(SELECT 1 FROM ntp_recovery_holds)")) ?? 0) == 1
    private var heldCache: [ServerRecordKey: (value: Data?, provenance: String?)?] = [:]

    fileprivate func held(_ key: ServerRecordKey) throws -> (value: Data?, provenance: String?)? {
        guard anyHolds else { return nil }
        if let cached = heldCache[key] { return cached }
        let row = try db.rows("SELECT value, provenance FROM ntp_recovery_holds WHERE entity = ? AND id = ? AND field_group = ?",
                              [.text(key.entity), .text(key.id), .text(key.fieldGroup)]).first
        let found = row.map { (value: $0[0].data, provenance: $0[1].text) }
        heldCache[key] = .some(found)
        return found
    }

    /// The held records of one entity kind and field group (their IDs).
    private func heldIDs(entity: String, group: String) throws -> [String] {
        guard anyHolds else { return [] }
        return try db.rows("SELECT id FROM ntp_recovery_holds WHERE entity = ? AND field_group = ?", [.text(entity), .text(group)])
            .compactMap { $0[0].text }.filter { (try? held(ServerRecordKey(entity: entity, id: $0, fieldGroup: group))) != nil }
    }

    /// Whether a recovery holds any record of this entity.
    private func holdsAny(entity: String, id: String) throws -> Bool {
        guard anyHolds else { return false }
        for row in try db.rows("SELECT field_group FROM ntp_recovery_holds WHERE entity = ? AND id = ?", [.text(entity), .text(id)]) {
            if let group = row[0].text, try held(ServerRecordKey(entity: entity, id: id, fieldGroup: group)) != nil { return true }
        }
        return false
    }

    /// A commit writes these records: the server's newer answer ends a recovery's hold on each (in the unit's
    /// transaction, before anything is projected).
    func dropHolds(_ keys: [ServerRecordKey]) throws {
        guard anyHolds, !keys.isEmpty else { return }
        for key in keys { heldCache[key] = .some(nil) }
        for chunk in FeedLibraryStore.chunks(keys) {
            let list = ContractJSON.array(chunk.map { .array([.string($0.entity), .string($0.id), .string($0.fieldGroup)]) }).canonicalText
            // Keyed (a row-value IN would scan every hold).
            try db.execute("DELETE FROM ntp_recovery_holds WHERE rowid IN (SELECT h.rowid FROM json_each(?) k JOIN ntp_recovery_holds h ON h.entity = json_extract(k.value, '$[0]') AND h.id = json_extract(k.value, '$[1]') AND h.field_group = json_extract(k.value, '$[2]'))",
                           [.text(list)])
        }
    }

    init(db: LibrarySQLite, namespace: String, accountID: String, now: Int64, allocate: @escaping (String) throws -> Int64) {
        self.db = db; self.namespace = namespace; self.accountID = accountID; self.now = now; self.allocate = allocate
    }

    // MARK: - Base and overlays

    /// A record's provenance (the nodes that set it), as `record` reads its value.
    func recordProvenance(_ entity: String, _ id: String, _ group: String) throws -> [String] {
        let key = ServerRecordKey(entity: entity, id: id, fieldGroup: group)
        if let pending = delta[key] { return pending.provenance }
        if let held = try held(key) {
            return (held.provenance.flatMap { try? ContractJSON.decode(Data($0.utf8)).arrayValue } ?? []).compactMap(\.stringValue)
        }
        guard let text = try db.rows("SELECT provenance FROM \(baseTable) WHERE entity = ? AND id = ? AND field_group = ?",
                                     [.text(entity), .text(id), .text(group)]).first?.first?.text,
              let list = try? ContractJSON.decode(Data(text.utf8)).arrayValue else { return [] }
        return list.compactMap(\.stringValue)
    }

    /// The latest pending statistics reset's knowledge clock, without the facts the commit retires (PROTOCOL §6.8).
    private lazy var statisticsResetClock: Int64? = try? ServerStatisticsUnits.pendingResetClock(db, excluding: excludedOps)
    /// Whether the library table holds any unit (most libraries have none: nothing to compare then). A probe, not a count:
    /// routine work must not grow with the library.
    private lazy var libraryHasStatisticsUnits = countsStatisticsUnits
        ? ((try? db.scalar("SELECT count(*) FROM statistics_units")) ?? 0) > 0
        : ((try? db.scalar("SELECT EXISTS (SELECT 1 FROM statistics_units)")) ?? 0) == 1
    /// Only for the budget's performance mutation: the count the probe replaced.
    var countsStatisticsUnits = false
    /// Off only for its mutation check: last played and history include this device's unexported listening
    /// instead of being frozen by its marks.
    var journalAwareListening = true
    /// Test-only (a mutation check): this device's unexported listening taken from what the row showed, as the first
    /// revision did, instead of from the journal.
    var listeningFromDisplayedRow = false

    /// Test-only: a full projection that drops the device's own resume points (a mutation check).
    nonisolated(unsafe) static var dropsDevicePositionsForTesting = false

    /// In a full projection (Force full synchronization, a recovery's switch), whether the episode's displayed position is
    /// the device's own: nothing pending sets its position (no claim, register or completion overlay), and the base's
    /// position record is exactly the one the live library had, so the live position was never the record's to replace.
    /// An incremental projection reaches the same rule by not projecting the position until its record changes.
    private func keepsDevicePosition(_ episode: String, overlays: [ServerOverlayRow]) throws -> Bool {
        guard let full = fullBase, !Self.dropsDevicePositionsForTesting,
              !overlays.contains(where: { $0.property == "position" || $0.kind == "completion" }) else { return false }
        let live = try db.scalar("SELECT count(*) FROM ntp_records WHERE entity = 'episode' AND id = ? AND field_group = 'position'", [.text(episode)])
        let base = try db.scalar("SELECT count(*) FROM \(full).records WHERE entity = 'episode' AND id = ? AND field_group = 'position'", [.text(episode)])
        guard live == base else { return false }
        guard live > 0 else { return true }
        return try db.scalar("""
            SELECT count(*) FROM ntp_records AS r JOIN \(full).records AS f ON f.entity = r.entity AND f.id = r.id AND f.field_group = r.field_group
            WHERE r.entity = 'episode' AND r.id = ? AND r.field_group = 'position' AND f.value IS r.value AND f.provenance IS r.provenance
            """, [.text(episode)]) > 0
    }

    /// The journal's owed transition facts (an end's or leave's history entry), read once.
    private lazy var dueTransitions: [ServerTransitionFact] = {
        guard let data = try? db.rows("SELECT pending_transition FROM ntp_library WHERE id = 1").first?.first?.data,
              let state = try? JSONDecoder().decode(ServerTransitionState.self, from: data) else { return [] }
        return state.due
    }()

    /// This device's unexported listening of an episode (PROTOCOL §8.7, the pending entries): the activity of starts not
    /// recorded yet, of saves not exported and of ends covering such a save; for history also the entries of ends and
    /// transitions (leave, finalize) not recorded yet. They become overlays when recorded and accepted entries when applied.
    func pendingListening(_ localID: Int64) throws -> (lastPlayed: Int64?, history: Int64?) {
        var activity: Int64?, history: Int64?
        // A session kept on this device: its history entries up to a local history cut are covered (PROTOCOL §8.8).
        var historyCut: Int64?
        func note(_ time: Int64, listening: Bool) {
            if listening { activity = max(activity ?? time, time) }
            if historyCut.map({ time > $0 }) ?? true { history = max(history ?? time, time) }
        }
        for session in try ServerSyncSession.load(db, episode: localID) {
            historyCut = session.exportRefused == .keptLocal ? session.localHistoryCut : nil
            if !session.startRecorded { note(session.startTime, listening: true) }
            for save in session.unexported { note(save.time, listening: true) }
            if let end = session.end, !end.recorded {
                let fresh = (session.last?.index ?? 0) > session.exportedIndex
                if fresh { note(end.time, listening: true) } else if end.history { note(end.time, listening: false) }
            }
        }
        historyCut = nil
        for fact in dueTransitions where fact.transition.episodeID == localID && fact.showsHistory { note(fact.time, listening: false) }
        return (activity, history)
    }

    func record(_ entity: String, _ id: String, _ group: String) throws -> ContractJSON? {
        let key = ServerRecordKey(entity: entity, id: id, fieldGroup: group)
        if let pending = delta[key] { return pending.value }
        if let held = try held(key) { return try held.value.map { try ContractJSON.decode($0) } }
        if projecting, let stored = storedRecords[key] { return stored }
        var value: ContractJSON?
        if let row = try db.rows("SELECT value FROM \(baseTable) WHERE entity = ? AND id = ? AND field_group = ?",
                                 [.text(entity), .text(id), .text(group)]).first, let data = row[0].data {
            value = try ContractJSON.decode(data)
        }
        if projecting { storedRecords[key] = .some(value) }
        return value
    }

    /// An episode's stored mapping row (`ntp_episodes`: local_id, podcast_id, kind, value, occurrence, merged_into).
    func storedMapping(_ episode: String) throws -> [LibrarySQLValue]? {
        if projecting, let stored = storedMappings[episode] { return stored }
        let row = try db.rows("SELECT local_id, podcast_id, kind, value, occurrence, merged_into FROM ntp_episodes WHERE episode_id = ?", [.text(episode)]).first
        if projecting { storedMappings[episode] = .some(row) }
        return row
    }

    /// Reads the identity records and mappings of `episodes` in a few statements before they are projected one by one.
    private func primeEpisodeReads(_ episodes: [String]) throws {
        let wanted = episodes.filter { storedMappings[$0] == nil }
        for start in stride(from: 0, to: wanted.count, by: 500) {
            let chunk = Array(wanted[start..<min(wanted.count, start + 500)])
            let list = ContractJSON.array(chunk.map(ContractJSON.string)).canonicalText
            var mappings: [String: [LibrarySQLValue]] = [:]
            for row in try db.rows("SELECT n.episode_id, n.local_id, n.podcast_id, n.kind, n.value, n.occurrence, n.merged_into FROM json_each(?) AS j CROSS JOIN ntp_episodes AS n ON n.episode_id = j.value", [.text(list)]) {
                if let episode = row[0].text { mappings[episode] = Array(row.dropFirst()) }
            }
            var identities: [String: ContractJSON] = [:]
            for row in try db.rows("SELECT r.id, r.value FROM json_each(?) AS j CROSS JOIN \(baseTable) AS r ON r.entity = 'episode' AND r.id = j.value AND r.field_group = 'identity'", [.text(list)]) {
                if let episode = row[0].text, let data = row[1].data { identities[episode] = try ContractJSON.decode(data) }
            }
            for episode in chunk {
                storedMappings[episode] = .some(mappings[episode])
                storedRecords[ServerRecordKey(entity: "episode", id: episode, fieldGroup: "identity")] = .some(identities[episode])
            }
        }
    }

    func overlays(entity: String, ids: [String], property: String? = nil) throws -> [ServerOverlayRow] {
        guard !ids.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let only = property == nil ? "" : " AND property = ?"
        // Within one fact its completion comes last: an end is a checkpoint, then its completion (PROTOCOL §8.3), so a
        // pending end that completes shows position 0, not the position it ended at.
        return try db.rows("SELECT op_id, entity, id, property, kind, value, clock FROM ntp_overlays WHERE entity = ? AND id IN (\(marks))\(only) ORDER BY clock, op_id, property = 'completion', property",
                           [.text(entity)] + ids.map(LibrarySQLValue.text) + (property.map { [.text($0)] } ?? [])).compactMap { row in
            guard case .text(let op) = row[0], !excludedOps.contains(op), case .text(let entity) = row[1], case .text(let id) = row[2],
                  case .text(let property) = row[3], case .text(let kind) = row[4], let clock = row[6].integer else { return nil }
            return ServerOverlayRow(opID: op, entity: entity, id: id, property: property, kind: kind,
                                    value: try row[5].data.map { try ContractJSON.decode($0) }, clock: clock)
        }
    }

    /// What a play load whose recording failed still owes the queue (`ntp_owed`). Until the replay
    /// records it, it is a local change like a pending overlay and wins over the base: an owed add keeps
    /// its episode queued and out of the Inbox, owed adds and placements keep their members' local keys, and a queue
    /// whose keys the load could not settle keeps its order and keys until the replay settles them.
    func owedQueue() throws -> ServerOwedQueue {
        if let owedCache { return owedCache }
        var owed = ServerOwedQueue()
        // An add refused as too large (`queue.add.refused`) or kept on this device (`queue.add.kept`) stays this device's, as owed.
        for row in try db.rows("SELECT intent, subject FROM ntp_owed WHERE intent IN ('queue.add', 'queue.place', 'queue.settle', 'queue.add.refused', 'queue.add.kept')") {
            guard let intent = row[0].text, let subject = row[1].text else { continue }
            if intent == "queue.settle" { owed.unsettled = true; continue }
            guard subject.hasPrefix("episode:"), let id = Int64(subject.dropFirst("episode:".count)) else { continue }
            if intent == "queue.place" { owed.placements.insert(id) } else { owed.adds.insert(id) }
        }
        owedCache = owed
        return owed
    }

    /// The latest pending value of one register property (PROTOCOL §6.8 `register`).
    private func register(_ overlays: [ServerOverlayRow], _ property: String) -> ContractJSON?? {
        guard let last = overlays.last(where: { $0.kind == "register" && $0.property == property }) else { return nil }
        return .some(last.value)
    }

    // MARK: - Rows

    /// Hidden feeds: a removal's whose rows are going, or a new podcast staged for a unit that has
    /// not revealed it, and the detached feed of an episode the player kept after its podcast's removal (PROTOCOL §6.8).
    /// Gone for every projection: nothing is projected onto them or matched to them.
    private lazy var removingFeeds: Set<Int64> = Set((((try? db.rows("SELECT feed_id FROM ntp_hidden_feeds")) ?? [])
        + ((try? db.rows("SELECT feed_id FROM pinned_feed_removals")) ?? [])).compactMap { $0[0].integer })

    /// Rows decoded from the store while `project` runs (nothing writes them meanwhile): each read and decoded once
    /// (a unit reads the same feed and member rows many times inside the live lock).
    private var projecting = false
    private var storedFeeds: [Int64: LibraryFeed?] = [:]
    private var storedEpisodes: [Int64: (feedID: Int64, episode: LibraryEpisode)?] = [:]
    private var storedRecords: [ServerRecordKey: ContractJSON?] = [:]
    private var storedMappings: [String: [LibrarySQLValue]?] = [:]
    /// Rows decoded from the store (what the caches above save inside a unit).
    private(set) var rowDecodes = 0

    func feedHeader(_ id: Int64) throws -> LibraryFeed? {
        if let image = plan.feeds[id] { return image }
        if plan.removedFeeds.contains(id) || plan.hiddenRemovedFeeds.contains(id) || removingFeeds.contains(id) || detaching(id) { return nil }
        if projecting, let stored = storedFeeds[id] { return stored }
        var feed: LibraryFeed?
        if let row = try db.rows("SELECT record FROM feeds WHERE id = ?", [.integer(id)]).first, let data = row[0].data {
            feed = try JSONDecoder.libraryRecord(LibraryFeed.self, from: data)
            rowDecodes += 1
        }
        if projecting { storedFeeds[id] = .some(feed) }
        return feed
    }

    func episodeRow(_ id: Int64) throws -> (feedID: Int64, episode: LibraryEpisode)? {
        if let image = plan.episodes[id] { return image }
        guard !plan.removedEpisodeIDs.contains(id) else { return nil }
        let row: (feedID: Int64, episode: LibraryEpisode)?
        if projecting, let stored = storedEpisodes[id] { row = stored } else {
            if let read = try db.rows("SELECT feed_id, record FROM episodes WHERE id = ?", [.integer(id)]).first,
               let feed = read[0].integer, let data = read[1].data {
                row = (feed, try JSONDecoder.libraryRecord(LibraryEpisode.self, from: data))
                rowDecodes += 1
            } else { row = nil }
            if projecting { storedEpisodes[id] = .some(row) }
        }
        guard let row else { return nil }
        guard !plan.removedFeeds.contains(row.feedID), !plan.hiddenRemovedFeeds.contains(row.feedID), !removingFeeds.contains(row.feedID),
              !detaching(row.feedID) else { return nil }
        return row
    }

    /// A feed this plan detaches (a removal of the player's episode's podcast, PROTOCOL §6.8): gone for the rest of the
    /// projection, as for every later one.
    private func detaching(_ feedID: Int64) -> Bool {
        !plan.mergeRemovals.contains(feedID) && plan.pinnedRemovals.contains { $0.feedID == feedID }
    }

    private func isLocalFolder(_ feedID: Int64) throws -> Bool { try feedHeader(feedID)?.source.isLocalFeedSource == true }

    /// The local feed of a podcast: its mapping, a registration this commit resolved, or nil.
    func feed(ofPodcast podcast: String) throws -> Int64? {
        if let known = feedOfPodcast[podcast] { return known }
        var result: Int64?
        if let mapped = plan.podcastMappings[podcast]?.feedID { result = mapped }
        else if let resolved = resolvedFeeds[podcast] { result = resolved }
        else if let row = try db.rows("SELECT feed_id FROM ntp_podcasts WHERE podcast_id = ?", [.text(podcast)]).first, let id = row[0].integer {
            result = id
        }
        if let id = result, try feedHeader(id) == nil { result = nil }
        feedOfPodcast[podcast] = result
        return result
    }

    /// Forgets a podcast's feed this projection looked up (a merge re-maps it).
    func forgetFeed(ofPodcast podcast: String) { feedOfPodcast[podcast] = nil }

    private func mappedPodcast(ofFeed feedID: Int64) throws -> String? {
        if let entry = plan.podcastMappings.first(where: { $0.value.feedID == feedID }) { return entry.key }
        guard let row = try db.rows("SELECT podcast_id FROM ntp_podcasts WHERE feed_id = ?", [.integer(feedID)]).first,
              case .text(let id) = row[0] else { return nil }
        return id
    }

    /// The local episode of a wire episode: its mapping when the row exists.
    func localEpisode(_ episode: String) throws -> Int64? {
        if let mapped = plan.episodeMappings[episode]?.localID { return mapped }
        guard let row = try storedMapping(episode), let id = row[0].integer, try episodeRow(id) != nil else { return nil }
        if let now = reassigned[id], now != episode { return nil }
        return id
    }

    /// A podcast's identity rules changed (a dispute of a GUID, PROTOCOL §9.7): each row this phone mapped from its own
    /// observed evidence is resolved again, and a row whose occurrence now resolves to another episode becomes that
    /// episode's, with its file, download, discovery ledger entries and the player's hold; the
    /// episode it held gets a row of its own. Returns the episodes to project again.
    func reresolveOccurrences(_ podcast: String) throws -> [String] {
        guard let feedID = try feed(ofPodcast: podcast), let header = try feedHeader(feedID),
              try db.scalar("SELECT count(*) FROM sqlite_master WHERE name = 'ntp_local_items'") == 1 else { return [] }
        let rules = ServerIdentityRules(try record("podcast", podcast, "identity_rules"))
        guard !rules.disputedGUIDs.isEmpty else { return [] }
        // Every move first: the server's releases can permute the phone's own provisional
        // assignment (rotating enclosures), so a row may take an episode another row of
        // the same GUID leaves.
        var moves: [Int64: (current: String, derived: (episodeID: String, key: ServerEpisodeKey))] = [:]
        for row in try db.rows("SELECT n.episode_id, i.local_id, i.guid, i.enclosure, i.publication_time FROM ntp_local_items i JOIN ntp_episodes n ON n.local_id = i.local_id WHERE i.feed_id = ? AND i.guid IS NOT NULL AND n.podcast_id = ? AND n.merged_into IS NULL ORDER BY i.local_id",
                               [.integer(feedID), .text(podcast)]) {
            guard let current = row[0].text, let local = row[1].integer, let guid = row[2].text, rules.disputedGUIDs[guid] != nil,
                  reassigned[local] == nil else { continue }
            let evidence = ServerItemEvidence(guid: guid, enclosureURL: row[3].text, publicationTime: row[4].integer, title: nil,
                                              atom: header.metadata.format == .atom)
            guard let derived = try ServerEpisodeIdentity.derive(evidence, rules: rules, namespace: namespace, podcast: podcast),
                  derived.episodeID != current else { continue }
            moves[local] = (current, derived)
        }
        var episodes: [String] = []
        for (local, move) in moves.sorted(by: { $0.key < $1.key }) {
            // Another row shows that release and keeps it: both stay as they are.
            if let holder = try localEpisode(move.derived.episodeID), holder != local, moves[holder] == nil { continue }
            reassigned[local] = move.derived.episodeID
            plan.episodeMappings[move.derived.episodeID] = (local, podcast, move.derived.key.kind, move.derived.key.value, nil, nil)
            plan.ledgerMoves.append((move.current, move.derived.episodeID))
            // Its pending overlays (facts naming the episode it left, with its occurrence) stay its own.
            leftBy[move.current] = local
            plan.overlayMoves.append((move.current, local))
            episodes += [move.derived.episodeID, move.current]
        }
        return episodes
    }

    private func wireEpisode(ofLocal id: Int64) throws -> String? {
        if let entry = plan.episodeMappings.first(where: { $0.value.localID == id }) { return entry.key }
        guard let row = try db.rows("SELECT episode_id FROM ntp_episodes WHERE local_id = ?", [.integer(id)]).first,
              case .text(let wire) = row[0] else { return nil }
        return wire
    }

    /// A local episode of the feed whose derivation (PROTOCOL §9.7: its identity, through the podcast's identity rules) is
    /// `episode` and that no other wire episode holds. Each is taken once.
    func derivedLocal(_ episode: String, podcast: String, feedID: Int64) throws -> Int64? {
        guard let id = try derivationMap(podcast: podcast, feedID: feedID)[episode] else { return nil }
        derivations[feedID]?[episode] = nil
        return id
    }

    /// The derivations of a feed's local rows no wire episode maps yet: wire episode → local row.
    func derivationMap(podcast: String, feedID: Int64) throws -> [String: Int64] {
        if derivations[feedID] == nil {
            var map: [String: Int64] = [:]
            guard let header = try feedHeader(feedID) else { return [:] }
            let rules = ServerIdentityRules(try record("podcast", podcast, "identity_rules"))
            let hasItems = try db.scalar("SELECT count(*) FROM sqlite_master WHERE name = 'ntp_local_items'") == 1
            for row in try db.rows("SELECT e.id, e.record\(hasItems ? ", i.kind, i.value, i.guid, i.enclosure, i.publication_time" : "") FROM episodes e LEFT JOIN ntp_episodes n ON n.local_id = e.id\(hasItems ? " LEFT JOIN ntp_local_items i ON i.local_id = e.id" : "") WHERE e.feed_id = ? AND n.local_id IS NULL ORDER BY e.id",
                                   [.integer(feedID)]) {
                guard let id = row[0].integer, let data = row[1].data else { continue }
                let local = try JSONDecoder.libraryRecord(LibraryEpisode.self, from: data)
                let atom = header.metadata.format == .atom
                var evidence = ServerItemEvidence(guid: local.details.identifier, enclosureURL: local.details.media?.url,
                                                  publicationTime: nil, title: nil, atom: atom)
                var key = evidence.plainKey
                if hasItems, let kind = row[2].text, let value = row[3].text {
                    key = ServerEpisodeKey(kind: kind, value: value)
                    evidence = ServerItemEvidence(guid: row[4].text, enclosureURL: row[5].text, publicationTime: row[6].integer, title: nil, atom: atom)
                }
                guard let key, !key.isNone else { continue }
                // `rss-guid+enclosure` as it is, unless its GUID is disputed (its release by date decides) or it is a
                // provisional release of rotating enclosures, which only the server's mapping names.
                let derived: String?
                if key.kind == ContractIdentity.EpisodeKind.rssGUIDEnclosure.rawValue, evidence.guid.map({ rules.disputedGUIDs[$0] == nil }) ?? true {
                    if hasItems, let time = evidence.publicationTime,
                       try db.scalar("SELECT count(*) FROM ntp_local_items WHERE feed_id = ? AND kind = ? AND value = ? AND local_id != ? AND publication_time < ?",
                                     [.integer(feedID), .text(key.kind), .text(key.value), .integer(id), .integer(time - ServerEpisodeIdentity.releaseWindow)]) > 0 {
                        continue
                    }
                    derived = try ServerEpisodeIdentity.id(key, namespace: namespace, podcast: podcast)
                } else {
                    derived = try ServerEpisodeIdentity.derive(evidence, rules: rules, namespace: namespace, podcast: podcast)?.episodeID
                }
                guard let derived, map[derived] == nil else { continue }
                map[derived] = id
            }
            derivations[feedID] = map
        }
        return derivations[feedID] ?? [:]
    }

    /// The player's current episode: the selection or the session (PROTOCOL §6.8). Its position and measured duration are
    /// pinned: remote values wait in `ntp_records` until it leaves the episode.
    func isPinned(_ localID: Int64) -> Bool { localID == selection || localID == sessionEpisode }

    // MARK: - Podcasts

    func projectPodcast(_ podcast: String, fields requested: ServerPodcastFields) throws {
        guard ContractIdentity.isPodcastID(podcast) else { return }
        visited.podcasts.insert(podcast)
        guard !removedPodcasts.contains(podcast) else { return }
        var fields = requested
        var feedID = try feed(ofPodcast: podcast)
        let overlayIDs = [podcast] + (feedID.map { ["local-feed:\($0)"] } ?? [])
        let overlays = try self.overlays(entity: "podcast", ids: overlayIDs)
        let subscription = try record("podcast", podcast, "subscription")
        var state = subscription?["state"]?.stringValue
        if case .some(let pending) = register(overlays, "subscription"), let value = pending?.stringValue { state = value }
        // Without a subscription record or a pending one, a podcast this library registered keeps its local state; its
        // other records still apply. One nobody here knows waits for its subscription record.
        if state == nil, feedID != nil { fields.remove(.subscription) }
        guard let state = state ?? (feedID != nil ? "local" : nil) else { return }
        switch state {
        case "merged":
            // A podcast merge (PROTOCOL §9.7): this feed becomes the survivor's, or its episodes merge into the survivor's.
            if let survivor = subscription?["merged_into"]?.stringValue, survivor != podcast, let feedID {
                try projectMergedPodcast(podcast, into: survivor, feedID: feedID)
            }
            return
        case "removed":
            plan.podcastMappings[podcast] = (feedID, nil)
            removedPodcasts.insert(podcast)
            // Its generation closes whether or not this phone still shows the feed (a removal made here deleted it before
            // the server's commit came back): its obsolete work ends either way (PROTOCOL §6.8).
            plan.closedPodcasts.insert(podcast)
            if let feedID { try remove(feedID: feedID, podcast: podcast) }
            return
        default:
            break
        }
        let generation = subscription?["generation_id"]?.stringValue
        var created = false
        if feedID == nil {
            feedID = try matchingFeed(podcast)
            if feedID == nil {
                feedID = try createFeed(podcast)
                created = true
            }
            feedOfPodcast[podcast] = feedID
            fields = .all
        }
        guard let feedID, var header = try feedHeader(feedID), !header.source.isLocalFeedSource else { return }
        let existingGeneration = try db.rows("SELECT live_generation FROM ntp_podcasts WHERE podcast_id = ?", [.text(podcast)]).first?.first?.text
        plan.podcastMappings[podcast] = (feedID, generation ?? existingGeneration)
        if fields.contains(.subscription), state != "local" {
            switch state {
            case "archived": header.subscriptionState = .archived
            case "not_subscribed": header.subscriptionState = .notSubscribed
            default: header.subscriptionState = .subscribed
            }
        }
        if fields.contains(.policy) || fields.contains(.subscription) {
            let policy = try record("podcast", podcast, "policy")
            var keep = policy?["keep_updated"]?.boolValue
            var action = policy?["new_episodes_action"]?.stringValue
            if case .some(let pending) = register(overlays, "keep_updated"), let value = pending?.boolValue { keep = value }
            if case .some(let pending) = register(overlays, "new_episodes_action"), let value = pending?.stringValue { action = value }
            if let keep { header.keepUpdated = keep }
            if let action { header.newEpisodesAction = Self.action(action) }
        }
        if fields.contains(.identity) {
            var url = try record("podcast", podcast, "identity")?["refresh_url"]?.stringValue
            if case .some(let pending) = register(overlays, "refresh_url"), let value = pending?.stringValue { url = value }
            if let url, !url.isEmpty, !Self.sameURL(url, header.source) { header.source = url }
        }
        if fields.contains(.metadata), let metadata = try record("podcast", podcast, "metadata") {
            header.applyCanonicalMetadata(title: metadata["title"]?.stringValue, description: metadata["description"]?.stringValue,
                                          author: metadata["author"]?.stringValue, language: metadata["language"]?.stringValue,
                                          link: metadata["link"]?.stringValue, imageURL: metadata["image_url"]?.stringValue,
                                          funding: (metadata["funding"]?.arrayValue ?? []).compactMap { entry in
                                              entry["content"]?.stringValue.map { FeedFunding(url: entry["url"]?.stringValue, content: $0) }
                                          },
                                          format: metadata["type"]?.stringValue == "atom" ? .atom : (created ? .rss : nil))
        }
        if fields.contains(.credentials) {
            var secret = try record("podcast", podcast, "credentials")?["secret_id"]?.stringValue
            if case .some(let pending) = register(overlays, "credentials") { secret = pending?.stringValue }
            try projectCredentials(feedID: feedID, secret: secret)
        }
        if fields.contains(.identityRules) {
            plan.identityRules[podcast] = .some(try record("podcast", podcast, "identity_rules"))
        }
        // The server's own refresh status, beside this device's (never in place of it).
        if fields.contains(.refreshStatus) {
            header.serverRefresh = ServerRefreshStatus(record: try record("podcast", podcast, "refresh_status"))
        }
        let storedHeader = try feedHeader(feedID)
        if header != storedHeader || created { plan.feeds[feedID] = header }
        if created {
            plan.createdFeeds.insert(feedID)
            for episode in try episodes(ofPodcast: podcast) { try projectEpisode(episode, fields: .all) }
            plan.queueStale = true
        }
    }

    /// A local feed whose address is one of the podcast's aliases and that no other podcast holds (a registration
    /// this library made that has not resolved yet, PROTOCOL §15.2): it becomes the podcast's feed.
    private func matchingFeed(_ podcast: String) throws -> Int64? {
        guard let identity = try record("podcast", podcast, "identity") else { return nil }
        var aliases = Set((identity["aliases"]?.arrayValue ?? []).compactMap { $0["normalized"]?.stringValue })
        if let url = identity["refresh_url"]?.stringValue { aliases.insert(ContractURL.normalize(ContractURL.stripUserinfo(url))) }
        for row in try db.rows("SELECT id, record FROM feeds ORDER BY id") {
            guard let id = row[0].integer, let data = row[1].data, !plan.removedFeeds.contains(id), !plan.hiddenRemovedFeeds.contains(id),
                  !removingFeeds.contains(id), !detaching(id) else { continue }
            let feed = try JSONDecoder.libraryRecord(LibraryFeed.self, from: data)
            guard !feed.source.isLocalFeedSource,
                  aliases.contains(ContractURL.normalize(ContractURL.stripUserinfo(feed.source))) else { continue }
            if let other = try mappedPodcast(ofFeed: id), other != podcast,
               try db.rows("SELECT live_generation FROM ntp_podcasts WHERE podcast_id = ?", [.text(other)]).first?.first?.text != nil { continue }
            return id
        }
        return nil
    }

    private func createFeed(_ podcast: String) throws -> Int64 {
        let identity = try record("podcast", podcast, "identity")
        let source = identity?["refresh_url"]?.stringValue ?? identity?["aliases"]?.arrayValue?.first?["url"]?.stringValue ?? ""
        let id = try allocate("feed")
        var feed = LibraryFeed(id: id, source: source, metadata: ParsedFeed(format: .rss), episodes: [])
        // A podcast created here is new to this device: a not-subscribed one (a preview another device registered) is
        // kept as a local preview would be, from now (PROTOCOL §7.2: preview clean-up stays local).
        feed.lastRefreshAttempt = Date(timeIntervalSince1970: Double(now) / 1_000)
        plan.feeds[id] = feed
        return id
    }

    /// The wire episodes of a podcast this library knows: mapped ones (every episode identity record is mapped when
    /// it arrives) and, in a shadow, the commit's identity records.
    private func episodes(ofPodcast podcast: String) throws -> [String] {
        if let full = fullBase {
            var result = Set(try db.rows("SELECT episode_id FROM \(full).identities WHERE podcast_id = ? AND merged_into IS NULL", [.text(podcast)])
                .compactMap { $0[0].text })
            for id in try heldIDs(entity: "episode", group: "identity") {
                if let identity = try record("episode", id, "identity"), identity["podcast_id"]?.stringValue == podcast,
                   identity["merged_into"]?.stringValue == nil { result.insert(id) }
            }
            return result.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        }
        var result = Set(try db.rows("SELECT episode_id FROM ntp_episodes WHERE podcast_id = ? AND merged_into IS NULL", [.text(podcast)]).compactMap { $0[0].text })
        for (key, record) in delta where key.entity == "episode" && key.fieldGroup == "identity" && record.value?["podcast_id"]?.stringValue == podcast {
            result.insert(key.id)
        }
        return result.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// A remote removal (PROTOCOL §6.8): the existing feed deletion, unless the player's current episode belongs to the
    /// podcast; then its other episodes go, the playing one keeps only what the player needs, and the podcast leaves
    /// every library-wide read until the selection leaves it.
    /// `merged`: the podcast merged into a live one (PROTOCOL §9.7): no generation closes, and the player's episode keeps
    /// its sync identity.
    func remove(feedID: Int64, podcast: String, merged: Bool = false) throws {
        guard let header = try feedHeader(feedID), !header.source.isLocalFeedSource else { return }
        if merged {
            plan.mergeRemovals.insert(feedID)
        } else {
            plan.closedPodcasts.insert(podcast)
            if let live = try db.rows("SELECT live_generation FROM ntp_podcasts WHERE podcast_id = ?", [.text(podcast)]).first?.first?.text {
                plan.closedGenerations[feedID] = live
            }
        }
        // Whether it is large is read from at most one more than the bound of the feed's index entries: a large podcast's
        // episodes are never listed inside the unit (they go afterwards).
        let large = try db.scalar("SELECT count(*) FROM (SELECT 1 FROM episodes WHERE feed_id = ? LIMIT ?)",
                                  [.integer(feedID), .integer(Int64(FeedLibraryStore.removalBatch + 1))]) > Int64(FeedLibraryStore.removalBatch)
        if large {
            // Large: hidden from every list in this unit, its rows deleted in bounded transactions afterwards
            //; an episode the player holds stays until it leaves it.
            let pinned = try [selection, sessionEpisode].compactMap { $0 }.first {
                try db.rows("SELECT feed_id FROM episodes WHERE id = ?", [.integer($0)]).first?.first?.integer == feedID
            }
            plan.hiddenRemovals.append((feedID, podcast, pinned))
            plan.hiddenRemovedFeeds.insert(feedID)
            plan.removedEpisodeCount += 1
            // Images this projection made of its episodes are not written (the feed's rows are hidden, then deleted).
            for (id, entry) in plan.episodes where entry.feedID == feedID { plan.episodes[id] = nil }
            plan.feeds[feedID] = nil
            plan.queueStale = true
            return
        }
        let episodes = try db.rows("SELECT id FROM episodes WHERE feed_id = ?", [.integer(feedID)]).compactMap { $0[0].integer }
        if let pinned = episodes.first(where: isPinned) {
            plan.pinnedRemovals.append((feedID, podcast, pinned))
            // Their statistics units go with the rows (an episode can hold thousands).
            plan.removedEpisodeCount += episodes.count - 1 + (try cascadedStatisticsRows(feedID: feedID))
        } else {
            plan.removedFeeds.append(feedID)
            plan.removedEpisodeCount += episodes.count + (try cascadedStatisticsRows(feedID: feedID))
        }
        for id in episodes { plan.episodes[id] = nil }
        plan.feeds[feedID] = nil
        plan.queueStale = true
    }

    private func projectCredentials(feedID: Int64, secret: String?) throws {
        let current: UUID? = try db.rows("SELECT credential_id FROM feed_credentials WHERE feed_id = ?", [.integer(feedID)]).first?.first?.text
            .flatMap(UUID.init(uuidString:))
        guard let secret else {
            // No credentials on the server: a credential that was one of its secrets goes; a local one the server never
            // held (cleared credentials are kept empty, as Android keeps them) stays.
            if let current, try db.scalar("SELECT count(*) FROM ntp_secrets WHERE credential_id = ?", [.text(current.uuidString)]) > 0 {
                plan.credentials[feedID] = .some(nil)
            }
            return
        }
        guard let row = try db.rows("SELECT credential_id FROM ntp_secrets WHERE secret_id = ?", [.text(secret)]).first,
              let credential = row[0].text.flatMap(UUID.init(uuidString:)) else {
            plan.missingSecrets.insert(secret)
            return
        }
        if credential != current { plan.credentials[feedID] = .some(credential) }
    }

    // MARK: - Episodes

    func projectEpisode(_ episode: String, fields requested: ServerEpisodeFields) throws {
        visited.episodes.insert(episode)
        let identity = try record("episode", episode, "identity")
        var podcast = identity?["podcast_id"]?.stringValue
        if podcast == nil {
            podcast = try storedMapping(episode)?[1].text
        }
        guard let podcast, !removedPodcasts.contains(podcast), let feedID = try feed(ofPodcast: podcast),
              try !isLocalFolder(feedID), !plan.pinnedRemovals.contains(where: { $0.feedID == feedID }) else { return }
        var fields = requested
        var localID = try localEpisode(episode)
        // Nothing of its row to project (named by a queue record or overlay, which the queue's projection reads): an
        // episode mapped here to a row of its podcast, merged into nothing, is left as it is.
        if requested.isEmpty, let localID, identity?["merged_into"] == nil, try episodeRow(localID)?.feedID == feedID,
           try storedMapping(episode)?[0].integer == localID {
            return
        }
        var derivedRow = false
        if localID == nil, let derived = try derivedLocal(episode, podcast: podcast, feedID: feedID) { localID = derived; fields = .all; derivedRow = true }
        // An episode merge (PROTOCOL §9.7): its row and download move to the survivor. A row only derived to it whose own occurrence
        // is another release's (a provisional release of rotating enclosures) is not this episode's.
        if let survivor = identity?["merged_into"]?.stringValue, survivor != episode {
            let occurrence = identity?["occurrence"]
            let local = try derivedRow && localID.map({ try !isOwnOccurrence($0, identity ?? .null) }) == true ? nil : localID
            try projectMergedEpisode(episode, into: survivor, podcast: podcast, kind: occurrence?["k"]?.stringValue ?? "none",
                                     value: occurrence?["v"]?.stringValue ?? "", occurrence: occurrence, local: local)
            return
        }
        let occurrence = identity?["occurrence"]
        var image: LibraryEpisode
        var created = false
        if let localID, let row = try episodeRow(localID) {
            guard row.feedID == feedID else { return }
            image = row.episode
        } else {
            // A new episode gets a local row: placeholder metadata from the occurrence until its metadata arrives (PROTOCOL §4).
            let hasMetadata = try record("episode", episode, "metadata") != nil
            guard identity != nil || hasMetadata else { return }
            let id = try allocate("episode")
            localID = id
            image = LibraryEpisode(id: id, details: Self.placeholder(occurrence, now: now))
            created = true
            fields = .all
        }
        guard let localID else { return }
        let kind = occurrence?["k"]?.stringValue ?? (episode.hasPrefix("e0:") ? "none" : "")
        let value = occurrence?["v"]?.stringValue ?? ""
        let stored = try storedMapping(episode)
        let mapped = stored?[0].integer
        if created || fields.contains(.identity) || mapped != localID {
            let mergedInto = identity?["merged_into"]?.stringValue
            // A repair writes only mappings that change (a no-op for most of a correct library).
            let unchanged = try !created && mapped == localID && stored.map { row in
                try row[1].text == podcast && row[2].text == kind && row[3].text == value && row[5].text == mergedInto
                    && row[4].data == occurrence.map { try $0.canonicalData() }
            } == true
            if !unchanged { plan.episodeMappings[episode] = (localID, podcast, kind, value, occurrence, mergedInto) }
        }
        let before = image
        // Listening this device did that no exported fact carries yet keeps its fields; everything else is projected.
        // Last played and history are projected too (PROTOCOL §8.7), from the accepted entries, the pending overlays and
        // this device's unexported listening read from its journal (`pendingListening`), never from what the row showed:
        // so other devices' newer listening, normalized times and remote cuts show at once, and this device's own
        // receipt never rolls its unexported listening back.
        let marked = created ? [] : localPlayback[localID]?.fields ?? []
        if !created, let mark = localPlayback[localID] {
            fields.subtract(journalAwareListening ? mark.fields.subtracting([.lastPlayed, .history]) : mark.fields)
        }
        try apply(fields, to: &image, episode: episode, localID: localID, occurrence: occurrence)
        if listeningFromDisplayedRow {
            if fields.contains(.lastPlayed), marked.contains(.lastPlayed) {
                image.userState.lastPlayedTimeMilliseconds = max(image.userState.lastPlayedTimeMilliseconds, before.userState.lastPlayedTimeMilliseconds)
            }
            if fields.contains(.history), marked.contains(.history), let own = before.userState.lastPlayedHistoryMilliseconds {
                image.userState.lastPlayedHistoryMilliseconds = max(image.userState.lastPlayedHistoryMilliseconds ?? own, own)
            }
        }
        if created || image != before {
            plan.episodes[localID] = (feedID, image)
            if created { plan.createdEpisodes.insert(localID) }
        }
    }

    private func apply(_ requested: ServerEpisodeFields, to image: inout LibraryEpisode, episode: String, localID: Int64,
                       occurrence: ContractJSON?) throws {
        var fields = requested
        // A row's pending overlays: its own (by its local ID), its episode's unless another row that left it holds them,
        // and those of the episode it left.
        var ids = ["local-episode:\(localID)"]
        if leftBy[episode].map({ $0 == localID }) ?? true { ids.append(episode) }
        ids += leftBy.filter { $0.value == localID && $0.key != episode }.map(\.key)
        let overlays = try self.overlays(entity: "episode", ids: ids)
        // A pending completion holds only while its claim owns the position (PROTOCOL §6.8): a change of the position's claim
        // shows or withdraws its PLAYED and its queue removal too.
        if fields.contains(.position), overlays.contains(where: { $0.kind == "completion" }) {
            fields.insert(.playState)
            plan.queueStale = true
        }
        let pinned = isPinned(localID)
        // The position under the displayed claim and the completions that hold (PROTOCOL §6.8).
        let playback = try positionState(episode: episode, overlays: overlays)
        if fields.contains(.metadata) { try applyMetadata(&image, episode: episode, occurrence: occurrence, pinned: pinned) }
        if fields.contains(.playState) {
            var state = try record("episode", episode, "play_state")?["play_state"]?.stringValue ?? "unplayed"
            for overlay in overlays where overlay.property == "play_state" || playback.completions[overlay.opID] != nil {
                switch overlay.kind {
                case "register": if let value = overlay.value?.stringValue { state = value }
                case "dismiss": if state == "new" { state = "unplayed" }
                case "completion": state = "played"
                default: break
                }
            }
            // An owed add has the queue add's fixed effect, as its pending overlay would.
            if state == "new", try owedQueue().adds.contains(localID) { state = "unplayed" }
            image.userState.playState = state == "played" ? .played : state == "new" ? .new : .unplayed
        }
        if fields.contains(.position) {
            let value = Int32(clamping: max(0, playback.position))
            if try keepsDevicePosition(episode, overlays: overlays) {
                // The device's own resume point (a paused seek or load's save, PROTOCOL §8): no fact carries it, and the base's
                // position record is the one it was chosen against, so a full projection keeps it as the live library does.
            } else if !pinned { image.userState.positionMilliseconds = value }
            else if value != image.userState.positionMilliseconds { plan.deferredPins[episode, default: []].insert(.position) }
        }
        if fields.contains(.favorite) {
            var on = try record("episode", episode, "favorite")?["on"]?.boolValue ?? false
            if case .some(let pending) = register(overlays, "favorite"), let value = pending?.boolValue { on = value }
            image.userState.isFavorite = on
        }
        if fields.contains(.lastPlayed) {
            var time = try record("episode", episode, "last_played")?["time"]?.integerValue ?? 0
            for overlay in overlays where overlay.kind == "activity" { time = max(time, overlay.value?.integerValue ?? 0) }
            if journalAwareListening, !listeningFromDisplayedRow, let pending = try pendingListening(localID).lastPlayed { time = max(time, pending) }
            image.userState.lastPlayedTimeMilliseconds = time
        }
        if fields.contains(.history) {
            var history = try displayedHistory(episode: episode, overlays: overlays)
            // This device's unexported entries are never in a cut's causal past (local cuts flush them first; a remote cut
            // cannot depend on them): they are never suppressed.
            if journalAwareListening, !listeningFromDisplayedRow, let pending = try pendingListening(localID).history { history = max(history ?? pending, pending) }
            image.userState.lastPlayedHistoryMilliseconds = history
        }
        if fields.contains(.playedTime) {
            image.userState.playedDurationMilliseconds = try displayedPlayedTime(episode: episode, localID: localID, overlays: overlays)
        }
        if fields.contains(.duration), let duration = try record("episode", episode, "measured_duration")?["duration_ms"]?.integerValue,
           image.details.media != nil {
            if !pinned { image.details.media?.durationMilliseconds = Int32(clamping: duration) }
            else if Int32(clamping: duration) != image.details.media?.durationMilliseconds { plan.deferredPins[episode, default: []].insert(.duration) }
        }
        if fields.contains(.statisticsUnits) {
            let units = try record("episode", episode, "statistics_units")
            // Only what differs from what is stored: a new episode without units writes nothing (a
            // catalog's thousands of new episodes would otherwise each cost a statement in the unit).
            let rows = try statisticsUnitsRows(episode, units)
            if rows.differ {
                plan.statisticsUnits[episode] = .some(units)
                plan.statisticsRows[episode] = rows.stored + rows.wanted
            }
        }
        if fields.contains(.statisticsUnits) || fields.contains(.playedTime) {
            // The library table (schema 20): the record's units by local ID, unless a pending reset covers them.
            let units = try record("episode", episode, "statistics_units")
            let desired = try ServerStatisticsUnits.projected(db, episode: episode, localID: localID, record: units,
                provenance: recordProvenance("episode", episode, "statistics_units"), resetClock: statisticsResetClock)
            if !desired.isEmpty || libraryHasStatisticsUnits {
                let stored = try db.statisticsUnits(episodes: [localID])[localID] ?? []
                if Set(desired) != Set(stored) {
                    plan.libraryStatisticsUnits[localID] = desired
                    plan.libraryStatisticsRows[localID] = stored.count + desired.count
                }
            }
        }
        // A full projection plans only admissions the ledger will lack once its entries have moved
        // (a re-resolved row's entry leaves this episode's key for its own release's); the
        // publication inserts after those moves, so an entry still there is kept as it is.
        if fields.contains(.admission), let admission = try record("episode", episode, "admission"),
           let generation = admission["generation_id"]?.stringValue,
           try fullBase == nil || plan.ledgerMoves.contains(where: { $0.from == episode && $0.to != episode })
            || db.scalar("SELECT count(*) FROM ntp_ledger WHERE generation_id = ? AND occurrence = ?", [.text(generation), .text(episode)]) == 0 {
            plan.admissions.append((generation, episode, admission["admission_id"]?.stringValue))
            plan.admissionsSeen = admissionsSeen
        }
    }

    /// Canonical episode metadata (PROTOCOL §6.8): the record's fields replace the stored ones; the media URL only when no
    /// working download or playback depends on it (PROTOCOL §9), and stored chapters stay.
    private func applyMetadata(_ image: inout LibraryEpisode, episode: String, occurrence: ContractJSON?, pinned: Bool) throws {
        guard let metadata = try record("episode", episode, "metadata") else {
            if image.details.title == nil, let title = occurrence?["title"]?.stringValue { image.details.title = title }
            if image.details.identifier == nil, let guid = occurrence?["guid"]?.stringValue { image.details.identifier = guid }
            return
        }
        var details = image.details
        if details.identifier == nil, let guid = occurrence?["guid"]?.stringValue { details.identifier = guid }
        details.title = metadata["title"]?.stringValue
        details.description = metadata["description"]?.stringValue
        details.link = metadata["link"]?.stringValue
        if let date = metadata["pub_date"]?.integerValue { details.publicationDate = Date(timeIntervalSince1970: Double(date) / 1_000) }
        details.imageURL = metadata["image_url"]?.stringValue
        details.paymentLink = metadata["payment_link"]?.stringValue
        details.chapterURL = metadata["chapter_url"]?.stringValue
        details.socialInteractionURL = metadata["social_interact_url"]?.stringValue
        if let url = metadata["transcript_url"]?.stringValue, let type = metadata["transcript_type"]?.stringValue,
           let format = FeedTranscript.Format(rawValue: type) ?? Self.transcriptFormat(type) {
            details.transcript = FeedTranscript(format: format, url: url)
        } else { details.transcript = nil }
        if !image.hasStoredChapters {
            details.chapters = metadata["chapters"]?.arrayValue.map { list in
                list.map { chapter in
                    ParsedChapter(startMilliseconds: chapter["start"]?.stringValue.flatMap { Int64($0) } ?? chapter["start"]?.integerValue ?? 0,
                                  title: chapter["title"]?.stringValue, link: chapter["link"]?.stringValue, imageURL: chapter["image_url"]?.stringValue)
                }
            }
        }
        if let media = metadata["media"], media.objectValue != nil {
            let url = media["url"]?.stringValue
            let size = media["size"]?.stringValue.flatMap { Int64($0) } ?? media["size"]?.integerValue ?? 0
            let duration = media["duration"]?.integerValue ?? 0
            if var local = details.media {
                if try Self.mayReplaceMediaURL(image, pinned: pinned, db: db), let url, !Self.sameURL(url, local.url ?? "") { local.url = url }
                if size > 0 { local.size = size }
                if let mime = media["mime_type"]?.stringValue { local.mimeType = mime }
                if local.durationMilliseconds <= 0, duration > 0 { local.durationMilliseconds = Int32(clamping: duration) }
                details.media = local
            } else {
                details.media = ParsedMedia(url: url, size: size, mimeType: media["mime_type"]?.stringValue,
                                            durationMilliseconds: Int32(clamping: duration))
            }
        }
        image.details = details
    }

    /// The statistics units a removal deletes with its episodes' rows (`statistics_units` cascades).
    func cascadedStatisticsRows(feedID: Int64? = nil, episode: Int64? = nil) throws -> Int {
        if let episode { return Int(try db.scalar("SELECT count(*) FROM statistics_units WHERE episode_id = ?", [.integer(episode)])) }
        guard let feedID else { return 0 }
        return Int(try db.scalar("SELECT count(*) FROM statistics_units WHERE episode_id IN (SELECT id FROM episodes WHERE feed_id = ?)", [.integer(feedID)]))
    }

    /// Whether the stored statistics units of an episode are not the record's (a repair writes only those that are), and
    /// how many rows are stored and wanted (replacing them deletes the one and inserts the other).
    private func statisticsUnitsRows(_ episode: String, _ record: ContractJSON?) throws -> (differ: Bool, stored: Int, wanted: Int) {
        var stored: [String: Data] = [:]
        for row in try db.rows("SELECT unit_id, record FROM ntp_statistics_units WHERE episode_id = ?", [.text(episode)]) {
            if let id = row[0].text { stored[id] = row[1].data ?? Data() }
        }
        var wanted: [String: Data] = [:]
        for unit in record?["units"]?.arrayValue ?? [] {
            if let id = unit["id"]?.stringValue { wanted[id] = try unit.canonicalData() }
        }
        return (stored != wanted, stored.count, wanted.count)
    }

    /// A working media URL is never replaced (PROTOCOL §9): not while the episode is downloaded, downloading or loaded in
    /// the player.
    private static func mayReplaceMediaURL(_ episode: LibraryEpisode, pinned: Bool, db: LibrarySQLite) throws -> Bool {
        guard !pinned, !episode.userState.isDownloaded else { return false }
        return try db.scalar("SELECT count(*) FROM download_jobs WHERE episode_id = ? AND active = 1", [.integer(episode.id)]) == 0
    }

    static func sameURL(_ a: String, _ b: String) -> Bool {
        ContractURL.normalize(ContractURL.stripUserinfo(a)).utf8.elementsEqual(ContractURL.normalize(ContractURL.stripUserinfo(b)).utf8)
    }

    private static func transcriptFormat(_ type: String) -> FeedTranscript.Format? {
        switch type {
        case "application/srr", "application/x-subrip": .srt
        default: nil
        }
    }

    static func placeholder(_ occurrence: ContractJSON?, now: Int64) -> ParsedEpisode {
        var details = ParsedEpisode()
        details.identifier = occurrence?["guid"]?.stringValue
        details.title = occurrence?["title"]?.stringValue
        let time = occurrence?["publication_time"]?.integerValue ?? now
        details.publicationDate = Date(timeIntervalSince1970: Double(time) / 1_000)
        if let url = occurrence?["enclosure_url"]?.stringValue { details.media = ParsedMedia(url: url, size: 0) }
        return details
    }

    static func action(_ value: String) -> NewEpisodesAction {
        switch value {
        case "inbox": .inbox
        case "queue": .queue
        case "nothing": .nothing
        default: .global
        }
    }

    // MARK: - History and played time (PROTOCOL §6.8)

    /// Displayed history: the base, unless a pending local cut, restore or mark applies; then derived per entry.
    func displayedHistory(episode: String, overlays: [ServerOverlayRow]) throws -> Int64? {
        let base = try record("episode", episode, "history")?["time"]?.integerValue
        let accountCuts = try self.overlays(entity: "account", ids: [accountID]).filter { $0.kind == "history_cut" && $0.property == "history" }
        let local = overlays.filter { ["history_cut", "history_restore", "history_mark", "activity"].contains($0.kind) }
        guard !(local.isEmpty && accountCuts.isEmpty) else { return base }
        guard let history else {
            // Without the archive (a pin's release): pending listening and marks show over the base; cuts wait for a unit.
            let pending = local.filter { $0.kind == "history_mark" || $0.kind == "activity" }.compactMap { $0.value?.integerValue }
            return pending.max().map { max(base ?? $0, $0) } ?? base
        }
        // Pending cuts, minus those a pending restore cancels.
        let pendingRestores = Set(local.filter { $0.kind == "history_restore" }.compactMap { $0.value?.stringValue })
        let pendingCuts = (local.filter { $0.kind == "history_cut" } + accountCuts).filter { !pendingRestores.contains($0.opID) }
        // Accepted cuts that apply to this episode, minus those an accepted or pending restore cancels.
        let items = try history.items(episode)
        let acceptedRestores = Set(items.filter { $0.kind == "restore" }.compactMap(\.removal))
        let acceptedCuts = (items.filter { $0.kind == "remove" } + (try history.clears())).filter {
            !acceptedRestores.contains($0.node) && !pendingRestores.contains($0.node)
        }
        guard !pendingCuts.isEmpty || !pendingRestores.isEmpty || local.contains(where: { $0.kind == "history_mark" || $0.kind == "activity" }) else {
            return base
        }
        var entries: [(node: String, time: Int64, clock: Int64?)] = []
        for item in items where item.kind == "activity" || item.kind == "mark" {
            guard let clock = try clock(of: item.node) else { continue }
            entries.append((item.node, item.time, clock))
        }
        for overlay in local where overlay.kind == "history_mark" || overlay.kind == "activity" {
            if let time = overlay.value?.integerValue { entries.append((overlay.opID, time, overlay.clock)) }
        }
        entries.sort { $0.time != $1.time ? $0.time > $1.time : $0.node.utf8.lexicographicallyPrecedes($1.node.utf8) }
        for entry in entries {
            // A pending cut covers what was known before it (PROTOCOL §6.8 coverage).
            if let clock = entry.clock, pendingCuts.contains(where: { clock < $0.clock }) { continue }
            var suppressed = false
            for cut in acceptedCuts {
                guard let cutClock = try self.clock(of: cut.node), let clock = entry.clock, cutClock >= clock else { continue }
                if try history.isInPast(entry.node, of: cut.node) { suppressed = true; break }
            }
            if !suppressed { return entry.time }
        }
        return nil
    }

    /// The knowledge clock at which this library learned a node; nil for one it has not applied yet.
    private func clock(of node: String) throws -> Int64? {
        try db.rows("SELECT knowledge_clock FROM ntp_nodes WHERE node_id = ?", [.text(node)]).first?.first?.integer
    }

    /// Before a commit changes an episode's played time while a reset is pending, what the reset covered of other
    /// sessions (`others`, PROTOCOL §8.8, from the record before the commit) is kept with the reset (an overlay row of its op),
    /// so the displayed time counts only their later growth.
    func notePlayedTimeChange(episode: String, previous: Int64) throws {
        let cuts = try overlays(entity: "account", ids: [accountID]).filter { $0.kind == "stat_cut" && $0.property == "played_time" }
        guard let latest = cuts.last else { return }
        let existing = try db.scalar("SELECT count(*) FROM ntp_overlays WHERE op_id = ? AND entity = 'episode' AND id = ? AND property = 'played_time_base'",
                                     [.text(latest.opID), .text(episode)])
        guard existing == 0, !plan.overlayAdditions.contains(where: { $0.op == latest.opID && $0.id == episode }) else { return }
        plan.overlayAdditions.append((latest.opID, "episode", episode, "played_time_base", "stat_cut_base",
                                      .integer(try othersPlayedTime(episode: episode, record: previous))))
    }

    // MARK: - Queue (PROTOCOL §7.6)

    /// The queue: members by the displayed membership (pending overlays, else the record, else the current local
    /// state for an entry the server has no record of), synced members in key order, device-only runs placed by their
    /// anchors (PROTOCOL §7.6).
    func projectQueue() throws {
        visited.queue = true
        plan.queueStale = false
        let owed = try owedQueue()
        if owed.unsettled {
            // The whole local order is owed: the queue and its keys stay as they are until the replay settles and
            // records them; the base it skipped is projected with the next queue commit, the replay's own.
            plan.queue = nil; plan.queueKeys = [:]
            return
        }
        let current = try db.rows("SELECT episode_id FROM queue ORDER BY position").compactMap { $0[0].integer }
        var stored: [Int64: ServerQueueKeyRow] = [:]
        for row in try db.rows("SELECT episode_id, key, position_id, device_only, next_anchor, previous_anchor FROM ntp_queue_keys") {
            guard let id = row[0].integer, let wire = row[1].text, let position = row[2].text else { continue }
            stored[id] = ServerQueueKeyRow(key: try QueueKey(wire: wire), positionID: position, deviceOnly: row[3].integer == 1,
                                           nextAnchor: row[4].integer, previousAnchor: row[5].integer)
        }
        // Only an entry that is queued now, queued by a record, or queued by a pending overlay can show in the queue.
        var candidates = Set(current)
        // The live base's queue membership records through their own index (a unit reads them inside the lock; the base's
        // primary key would visit every episode record).
        let indexed = try baseTable == "ntp_records"
            && db.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'ntp_records_in_queue'") == 1
        for row in try db.rows("SELECT n.local_id FROM \(baseTable) r \(indexed ? "INDEXED BY ntp_records_in_queue " : "")JOIN ntp_episodes n ON n.episode_id = r.id WHERE r.entity = 'episode' AND r.field_group = 'queue_membership' AND n.local_id IS NOT NULL AND CAST(r.value AS TEXT) LIKE '%\"in_queue\":true%'") {
            if let id = row[0].integer { candidates.insert(id) }
        }
        for (key, record) in delta where key.entity == "episode" && key.fieldGroup == "queue_membership" && record.value?["in_queue"]?.boolValue == true {
            if let id = try localEpisode(key.id) { candidates.insert(id) }
        }
        for held in try heldIDs(entity: "episode", group: "queue_membership") {
            if try record("episode", held, "queue_membership")?["in_queue"]?.boolValue == true, let id = try localEpisode(held) { candidates.insert(id) }
        }
        for row in try db.rows("SELECT DISTINCT id FROM ntp_overlays WHERE entity = 'episode' AND property = 'queue_membership' AND kind = 'register' AND CAST(value AS TEXT) = 'true'") {
            guard let id = row[0].text else { continue }
            if let local = id.hasPrefix("local-episode:") ? Int64(id.dropFirst("local-episode:".count)) : try localEpisode(id) { candidates.insert(local) }
        }
        for id in plan.createdEpisodes { candidates.insert(id) }
        var synced: [(id: Int64, key: ServerQueueKeyRow)] = []
        var deviceOnly: [Int64] = []
        let currentSet = Set(current)
        // The candidates' wire IDs, queue records and overlays, each read once for all of them (a unit projects the
        // queue inside the live lock): the same values `wireEpisode`, `record` and `overlays` give one at a time.
        let members = try QueueMemberReads(self, candidates: candidates)
        for id in candidates {
            // An episode without media shows when the queue holds it (Android's queue joins its media optionally): this
            // device never queues one itself, but another client's add or a feed that dropped an enclosure can. As on Android,
            // playback refuses it, automatic download skips it, and playback that reaches it in the queue stops there.
            guard let row = try episodeRow(id) else { continue }
            if plan.pinnedRemovals.contains(where: { $0.feedID == row.feedID }) { continue }
            if try isLocalFolder(row.feedID) {
                if currentSet.contains(id) { deviceOnly.append(id) }
                continue
            }
            let wire = members.wire[id]
            let overlays = members.overlays(wire: wire, local: id)
            let membershipRecord = wire.flatMap { members.record($0, "queue_membership") }
            // A queue change this device's playback made (a completion's removal) stays as this device has it.
            let localQueue = localPlayback[id]?.queue == true
            var member = localQueue ? currentSet.contains(id) : membershipRecord?["in_queue"]?.boolValue ?? currentSet.contains(id)
            // A full snapshot is the whole truth about the episodes the server knows: one it never queued is not
            // queued, unless this device owes its queue add. So is a commit that removes a membership record (a closed
            // generation's): the entry leaves the queue in a unit as it does in a full projection.
            if !localQueue, membershipRecord == nil, member, let wire, !owed.adds.contains(id), !owed.placements.contains(id) {
                let key = ServerRecordKey(entity: "episode", id: wire, fieldGroup: "queue_membership")
                if removedRecords.contains(key) || delta[key].map({ $0.value == nil }) == true {
                    member = false
                } else if fullBase != nil, try record("episode", wire, "identity") != nil {
                    member = false
                }
            }
            // A pending membership: the latest register, or a completion of this library's playback that holds (PROTOCOL §6.8).
            let completions = overlays.contains { $0.kind == "completion" } ? try positionState(episode: wire, overlays: overlays).completions : [:]
            if !localQueue, let pending = pendingQueueMembership(overlays, completions: completions) { member = pending }
            // An owed add of an episode still queued here is a pending membership.
            if owed.adds.contains(id), currentSet.contains(id) { member = true }
            // A refused add's prediction leaves the queue unless an accepted membership, another pending add, an owed
            // add or the player holds it.
            if member, withdrawnQueue.contains("local-episode:\(id)") || wire.map(withdrawnQueue.contains) == true,
               membershipRecord == nil, register(overlays, "queue_membership") == nil, !owed.adds.contains(id), !localQueue, !isPinned(id) {
                member = false
            }
            guard member else { continue }
            var key: ServerQueueKeyRow?
            if let position = wire.flatMap({ members.record($0, "queue_position") }), membershipRecord?["in_queue"]?.boolValue == true,
               let wireKey = position["key"]?.stringValue, let positionID = position["position_id"]?.stringValue {
                key = ServerQueueKeyRow(key: try QueueKey(wire: wireKey), positionID: positionID, deviceOnly: false)
            }
            if case .some(let pending) = register(overlays, "queue_position"), let wireKey = pending?["key"]?.stringValue,
               let positionID = pending?["position_id"]?.stringValue {
                key = ServerQueueKeyRow(key: try QueueKey(wire: wireKey), positionID: positionID, deviceOnly: false)
            }
            // An owed add or placement keeps the local key the replay will record: projection never overwrites it.
            if owed.adds.contains(id) || owed.placements.contains(id), currentSet.contains(id), let old = stored[id], !old.deviceOnly {
                key = ServerQueueKeyRow(key: old.key, positionID: old.positionID, deviceOnly: false)
            }
            if key == nil, let old = stored[id], !old.deviceOnly { key = ServerQueueKeyRow(key: old.key, positionID: old.positionID, deviceOnly: false) }
            if let key { synced.append((id, key)) } else { deviceOnly.append(id) }
        }
        synced.sort { $0.key.key != $1.key.key ? $0.key.key < $1.key.key : $0.key.positionID.utf8.lexicographicallyPrecedes($1.key.positionID.utf8) }
        var order = synced.map(\.id)
        // Device-only runs: before their surviving next anchor, else after their previous one, else at the tail, in the
        // current order.
        let deviceOrder = deviceOnly.sorted { (current.firstIndex(of: $0) ?? Int.max, $0) < (current.firstIndex(of: $1) ?? Int.max, $1) }
        var tail: [Int64] = []
        var placements: [(anchor: Int64, before: Bool, id: Int64)] = []
        for id in deviceOrder {
            let anchors = stored[id]
            if let next = anchors?.nextAnchor, order.contains(next) { placements.append((next, true, id)) }
            else if let previous = anchors?.previousAnchor, order.contains(previous) { placements.append((previous, false, id)) }
            else { tail.append(id) }
        }
        for anchor in Set(placements.map(\.anchor)) {
            let before = placements.filter { $0.anchor == anchor && $0.before }.map(\.id)
            let after = placements.filter { $0.anchor == anchor && !$0.before }.map(\.id)
            guard let index = order.firstIndex(of: anchor) else { continue }
            order.insert(contentsOf: after, at: index + 1)
            order.insert(contentsOf: before, at: index)
        }
        order += tail
        // Keys: synced members take their displayed keys; device-only entries keep theirs where they still fit, else
        // get fresh keys between their neighbours, with their anchors recomputed.
        let syncedKeys = Dictionary(uniqueKeysWithValues: synced.map { ($0.id, $0.key) })
        var keys: [Int64: ServerQueueKeyRow] = [:]
        for (index, id) in order.enumerated() {
            if let key = syncedKeys[id] { keys[id] = key; continue }
            let low = index > 0 ? keys[order[index - 1]]?.key : nil
            let high = order[(index + 1)...].lazy.compactMap { syncedKeys[$0]?.key }.first
            let next = order[(index + 1)...].first { syncedKeys[$0] != nil }
            let previous = order[..<index].last { syncedKeys[$0] != nil }
            var row: ServerQueueKeyRow
            if let old = stored[id] { row = old } else {
                let write = UUID()
                row = ServerQueueKeyRow(key: try QueueKey.between(low, high, positionWriteID: write), positionID: write.uuidString.lowercased(), deviceOnly: true)
            }
            let fits = (low.map { $0 < row.key } ?? true) && (high.map { row.key < $0 } ?? true)
            if !fits {
                let write = UUID()
                row = ServerQueueKeyRow(key: try QueueKey.between(low, high, positionWriteID: write), positionID: write.uuidString.lowercased(), deviceOnly: true)
            }
            row.deviceOnly = true; row.nextAnchor = next; row.previousAnchor = previous
            keys[id] = row
        }
        let changedKeys = keys.filter { stored[$0.key] != $0.value }
        if order != current || !changedKeys.isEmpty || stored.keys.contains(where: { keys[$0] == nil }) {
            plan.queue = order
            plan.queueKeys = keys
        } else {
            plan.queue = nil; plan.queueKeys = [:]
        }
    }
}

extension ServerProjector {
    // MARK: - Scope

    /// New history entries of episodes this library is cutting or restoring re-derive their history (PROTOCOL §6.8): a remote
    /// entry the pending cut never observed shows, even when the base does not change.
    func addHistoryScope(_ commit: ServerCommit, scope: inout ServerProjectionScope) throws {
        let accountCut = try db.scalar("SELECT count(*) FROM ntp_overlays WHERE entity = 'account' AND kind = 'history_cut'") > 0
        for entry in commit.accepted where ["session.start", "session.checkpoint", "session.end", "session.finalize", "episode.leave"].contains(entry.type) {
            guard let episode = entry.payload["episode"]?["episode_id"]?.stringValue else { continue }
            let local = try db.scalar("SELECT count(*) FROM ntp_overlays WHERE entity = 'episode' AND id = ? AND kind IN ('history_cut', 'history_restore', 'history_mark', 'activity')",
                                      [.text(episode)]) > 0
            if accountCut || local { scope.episodes[episode, default: []].insert(.history) }
        }
    }

    /// Force full synchronization (PROTOCOL §6.14): what the base held and the snapshot no longer holds leaves the live rows.
    /// A podcast with records in the base and none in the snapshot is removed (as a remote removal, PROTOCOL §6.8); an episode
    /// whose identity was in the base and is not in the snapshot is removed from its podcast, unless the player holds
    /// it or a pending local fact names it. Local folders, unregistered previews and drafts were never projected and
    /// stay, as does what a recovery holds (a podcast with a held record, an episode with a held identity).
    func projectAbsent() throws {
        guard let full = fullBase else { return }
        visited.everything = true
        // A podcast this library maps whose records neither the base nor the snapshot has (one a
        // recovery held and whose creation was refused) is absent too.
        for row in try db.rows("SELECT DISTINCT r.id FROM ntp_records r WHERE r.entity = 'podcast' AND NOT EXISTS (SELECT 1 FROM \(full).records f WHERE f.entity = 'podcast' AND f.id = r.id) UNION SELECT p.podcast_id FROM ntp_podcasts p WHERE p.feed_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM \(full).records f WHERE f.entity = 'podcast' AND f.id = p.podcast_id) AND NOT EXISTS (SELECT 1 FROM ntp_records r WHERE r.entity = 'podcast' AND r.id = p.podcast_id) AND NOT EXISTS (SELECT 1 FROM ntp_registrations g WHERE g.feed_id = p.feed_id AND g.state = 'pending') ORDER BY 1") {
            guard let podcast = row[0].text else { continue }
            try removeAbsentPodcast(podcast)
        }
        for row in try db.rows("SELECT n.episode_id, n.local_id FROM ntp_episodes n JOIN ntp_records r ON r.entity = 'episode' AND r.id = n.episode_id AND r.field_group = 'identity' WHERE n.local_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM \(full).identities f WHERE f.episode_id = n.episode_id) ORDER BY n.local_id") {
            guard let episode = row[0].text, try held(ServerRecordKey(entity: "episode", id: episode, fieldGroup: "identity")) == nil,
                  let local = row[1].integer else { continue }
            _ = try removeAbsentEpisode(episode, local: local)
        }
    }

    /// A podcast the server does not have: removed as a remote removal is (PROTOCOL §6.8), the player's episode kept for the
    /// player, never left as a local preview. Not while a recovery holds any of its records.
    private func removeAbsentPodcast(_ podcast: String) throws {
        visited.podcasts.insert(podcast)
        guard try !holdsAny(entity: "podcast", id: podcast), !removedPodcasts.contains(podcast) else { return }
        // Newer local work on its feed (the person subscribed meanwhile) decides; the absence waits for it.
        if let feedID = try feed(ofPodcast: podcast), try feedHasNewerWork(feedID, podcast: podcast) { return }
        removedPodcasts.insert(podcast)
        guard let feedID = try feed(ofPodcast: podcast) else { return }
        plan.podcastMappings[podcast] = (feedID, nil)
        try remove(feedID: feedID, podcast: podcast)
    }

    /// An episode whose identity the server does not have leaves its podcast; held by the player, a pending fact or a
    /// fact this device still owes (a play load's queue add or placement) it is removed once that hold
    /// retires (the base forgets its identity now). Returns whether it was removed or deferred.
    private func removeAbsentEpisode(_ episode: String, local: Int64) throws -> Bool {
        visited.episodes.insert(episode)
        guard let current = try episodeRow(local), !plan.removedFeeds.contains(current.feedID), !plan.hiddenRemovedFeeds.contains(current.feedID),
              !plan.pinnedRemovals.contains(where: { $0.feedID == current.feedID }), try !isLocalFolder(current.feedID) else { return false }
        // Its feed now belongs to another podcast (a newer subscription won), or newer local work on the feed is pending:
        // the row is that work's, not the absent podcast's.
        let owner = try db.rows("SELECT podcast_id FROM ntp_episodes WHERE episode_id = ?", [.text(episode)]).first?.first?.text
        if let owner, let mapped = try mappedPodcast(ofFeed: current.feedID), mapped != owner { return false }
        if try feedHasNewerWork(current.feedID, podcast: owner) { return false }
        let owed = try owedQueue()
        let held = try isPinned(local) || !overlays(entity: "episode", ids: [episode, "local-episode:\(local)"]).isEmpty
            || owed.adds.contains(local) || owed.placements.contains(local)
        if held {
            plan.deferredAbsences.append((local, episode, current.feedID))
            return true
        }
        plan.removedEpisodes[current.feedID, default: []].append(local)
        plan.removedEpisodeIDs.insert(local)
        plan.episodes[local] = nil
        plan.removedEpisodeCount += 1 + (try cascadedStatisticsRows(episode: local))
        plan.queueStale = true
        return true
    }

    /// Newer local work on a feed: a pending registration of it, or a pending local fact about its podcast or the feed
    /// itself (its `local-feed:` alias). What the server lacks of an older podcast on that feed waits for that work.
    func feedHasNewerWork(_ feedID: Int64, podcast: String?) throws -> Bool {
        if try db.scalar("SELECT count(*) FROM ntp_registrations WHERE feed_id = ? AND state = 'pending'", [.integer(feedID)]) > 0 { return true }
        var ids = ["local-feed:\(feedID)"]
        if let podcast { ids.append(podcast) }
        if let mapped = try mappedPodcast(ofFeed: feedID), mapped != podcast { ids.append(mapped) }
        return try !overlays(entity: "podcast", ids: ids).isEmpty
    }

    /// What a recovery held and the server does not have once the holds ended (refused for good):
    /// a podcast none of whose records the base has, an episode whose identity it lacks, removed through the normal
    /// removal with its safeguards, before anything else of the unit is projected. Returns the episodes removed.
    func projectReleasedAbsence(podcasts: Set<String>, episodes: Set<String>, identities: Set<String>) throws -> Set<String> {
        for podcast in podcasts.sorted() where try db.scalar("SELECT count(*) FROM \(baseTable) WHERE entity = 'podcast' AND id = ?", [.text(podcast)]) == 0 {
            try removeAbsentPodcast(podcast)
        }
        var removed = Set<String>()
        // An episode whose identity hold ended now, or earlier while other fields were still held
        // (its absence remembered then), is judged again whenever one of its holds ends.
        for episode in episodes.sorted() where try record("episode", episode, "identity") == nil {
            guard try identities.contains(episode)
                    || db.scalar("SELECT count(*) FROM ntp_deferred_absence WHERE episode_id = ?", [.text(episode)]) > 0 else { continue }
            guard let local = try localEpisode(episode), let row = try episodeRow(local) else { continue }
            // Its podcast goes (in this unit, or its rows are already being removed in bounded batches): nothing more.
            if try removingFeeds.contains(row.feedID) || mappedPodcast(ofFeed: row.feedID).map(removedPodcasts.contains) ?? true {
                removed.insert(episode)
                continue
            }
            if try holdsAny(entity: "episode", id: episode) {
                // Other fields are still held: the absence is remembered (`ntp_deferred_absence`), so the last hold's end,
                // the next exchange or a repair removes it.
                plan.deferredAbsences.append((local, episode, row.feedID))
                continue
            }
            if try removeAbsentEpisode(episode, local: local) { removed.insert(episode) }
        }
        return removed
    }

    /// Force full synchronization while a statistics reset is pending: the base each changed played time replaces
    /// is kept with the reset first, as for a commit (PROTOCOL §6.8 `stat_cut`).
    func noteFullPlayedTimeChanges() throws {
        guard let full = fullBase,
              try db.scalar("SELECT count(*) FROM ntp_overlays WHERE entity = 'account' AND kind = 'stat_cut'") > 0 else { return }
        for row in try db.rows("SELECT f.id, r.value FROM \(full).records f LEFT JOIN ntp_records r ON r.entity = f.entity AND r.id = f.id AND r.field_group = f.field_group WHERE f.entity = 'episode' AND f.field_group = 'played_time' AND (r.value IS NULL OR r.value IS NOT f.value)") {
            guard let episode = row[0].text else { continue }
            let previous = try row[1].data.flatMap { try ContractJSON.decode($0)["played_ms"]?.integerValue } ?? 0
            try notePlayedTimeChange(episode: episode, previous: previous)
        }
    }

    /// Projects a scope: podcasts first (a created feed brings its episodes), then episodes, every mapped episode for
    /// an account-level field, then the queue.
    func project(_ scope: ServerProjectionScope) throws {
        projecting = true
        defer { projecting = false; storedFeeds = [:]; storedEpisodes = [:]; storedRecords = [:]; storedMappings = [:] }
        // A merged podcast before its survivor, so a survivor without a feed here takes the merged feed (PROTOCOL §9.7).
        var podcasts = scope.podcasts.sorted(by: { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) })
        let mergedPodcasts = try Set(podcasts.filter { $0.value.contains(.subscription) }.map(\.key).filter {
            try record("podcast", $0, "subscription")?["state"]?.stringValue == "merged"
        })
        if !mergedPodcasts.isEmpty {
            podcasts = podcasts.filter { mergedPodcasts.contains($0.key) } + podcasts.filter { !mergedPodcasts.contains($0.key) }
        }
        for (podcast, fields) in podcasts {
            try projectPodcast(podcast, fields: fields)
        }
        // An overlay kept by a local episode (a provisional release's, a re-resolved row's) re-projects its row's episode.
        var episodes = scope.episodes
        for (key, fields) in scope.episodes where key.hasPrefix("local-episode:") {
            episodes[key] = nil
            if let local = Int64(key.dropFirst("local-episode:".count)), let wire = try wireEpisode(ofLocal: local) {
                episodes[wire, default: []].formUnion(fields)
            }
        }
        // New identity rules re-resolve the rows mapped from this phone's own evidence first.
        for (podcast, fields) in podcasts where fields.contains(.identityRules) {
            for episode in try reresolveOccurrences(podcast) { episodes[episode] = .all }
        }
        // Merged episodes first, so a survivor without a row here takes the merged row rather than a new one (PROTOCOL §9.7).
        var ordered = episodes.sorted(by: { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) })
        let merged = try Set(ordered.filter { $0.value.contains(.identity) }.map(\.key).filter {
            try record("episode", $0, "identity")?["merged_into"]?.stringValue != nil
        })
        if !merged.isEmpty { ordered = ordered.filter { merged.contains($0.key) } + ordered.filter { !merged.contains($0.key) } }
        try primeEpisodeReads(ordered.map(\.key))
        for (episode, fields) in ordered {
            try projectEpisode(episode, fields: fields)
        }
        if !scope.allEpisodes.isEmpty {
            visited.everything = true
            for row in try db.rows("SELECT episode_id FROM ntp_episodes WHERE local_id IS NOT NULL ORDER BY episode_id") {
                if let episode = row[0].text { try projectEpisode(episode, fields: scope.allEpisodes) }
            }
        }
        if scope.queue || plan.queueStale || !plan.createdEpisodes.isEmpty {
            withdrawnQueue.formUnion(scope.withdrawnQueue)
            try projectQueue()
        }
        if scope.accountPolicies { plan.accountPoliciesChanged = true }
    }
}

/// What the queue's projection reads of its candidates, read in a few chunked statements instead of several each.
private struct QueueMemberReads {
    /// Wire IDs by local row: the plan's mappings first, then the store's (as `wireEpisode(ofLocal:)`).
    var wire: [Int64: String] = [:]
    /// Queue membership and position records by wire ID: the commit's (the delta) first, then what a recovery holds, then the base's.
    private var records: [ServerRecordKey: ContractJSON?] = [:]
    /// Overlays by target ID, in the order `overlays(entity:ids:)` gives them.
    private var overlayRows: [ServerOverlayRow] = []
    private var overlaysByID: [String: [Int]] = [:]

    init(_ projector: ServerProjector, candidates: Set<Int64>) throws {
        let locals = candidates.sorted()
        for (episode, mapping) in projector.plan.episodeMappings {
            if let local = mapping.localID, candidates.contains(local), wire[local] == nil { wire[local] = episode }
        }
        for chunk in Self.chunks(locals) {
            for row in try projector.db.rows("SELECT n.local_id, n.episode_id FROM json_each(?) AS j CROSS JOIN ntp_episodes AS n ON n.local_id = j.value",
                                             [.text(ContractJSON.array(chunk.map(ContractJSON.integer)).canonicalText)]) {
                if let local = row[0].integer, let episode = row[1].text, wire[local] == nil { wire[local] = episode }
            }
        }
        let wires = Array(Set(wire.values)).sorted()
        for chunk in Self.chunks(wires) {
            for row in try projector.db.rows("SELECT r.id, r.field_group, r.value FROM json_each(?) AS j CROSS JOIN \(projector.baseTable) AS r ON r.entity = 'episode' AND r.id = j.value AND r.field_group IN ('queue_membership', 'queue_position')",
                                             [.text(ContractJSON.array(chunk.map(ContractJSON.string)).canonicalText)]) {
                guard let id = row[0].text, let group = row[1].text else { continue }
                records[ServerRecordKey(entity: "episode", id: id, fieldGroup: group)] = .some(try row[2].data.map { try ContractJSON.decode($0) })
            }
        }
        // A record a recovery holds is read as held, as `record` reads it.
        for id in wires {
            for group in ["queue_membership", "queue_position"] {
                let key = ServerRecordKey(entity: "episode", id: id, fieldGroup: group)
                if let held = try projector.held(key) { records[key] = .some(try held.value.map { try ContractJSON.decode($0) }) }
            }
        }
        for (key, record) in projector.delta where key.entity == "episode" && (key.fieldGroup == "queue_membership" || key.fieldGroup == "queue_position") {
            records[key] = .some(record.value)
        }
        let targets = wires + locals.map { "local-episode:\($0)" }
        for chunk in Self.chunks(targets) {
            let rows = try projector.db.rows("SELECT o.op_id, o.entity, o.id, o.property, o.kind, o.value, o.clock FROM json_each(?) AS j CROSS JOIN ntp_overlays AS o ON o.entity = 'episode' AND o.id = j.value ORDER BY o.clock, o.op_id, o.property",
                                             [.text(ContractJSON.array(chunk.map(ContractJSON.string)).canonicalText)])
            for row in rows {
                guard case .text(let op) = row[0], !projector.excludedOps.contains(op), case .text(let entity) = row[1], case .text(let id) = row[2],
                      case .text(let property) = row[3], case .text(let kind) = row[4], let clock = row[6].integer else { continue }
                overlaysByID[id, default: []].append(overlayRows.count)
                overlayRows.append(ServerOverlayRow(opID: op, entity: entity, id: id, property: property, kind: kind,
                                                    value: try row[5].data.map { try ContractJSON.decode($0) }, clock: clock))
            }
        }
    }

    func record(_ episode: String, _ group: String) -> ContractJSON? {
        records[ServerRecordKey(entity: "episode", id: episode, fieldGroup: group)] ?? nil
    }

    /// A member's overlays (its wire episode's and its local row's), ordered as one query for both would order them.
    func overlays(wire: String?, local: Int64) -> [ServerOverlayRow] {
        let indices = ((wire.flatMap { overlaysByID[$0] } ?? []) + (overlaysByID["local-episode:\(local)"] ?? []))
        return indices.sorted {
            let a = overlayRows[$0], b = overlayRows[$1]
            return (a.clock, a.opID, a.property, $0) < (b.clock, b.opID, b.property, $1)
        }.map { overlayRows[$0] }
    }

    static func chunks<T>(_ list: [T]) -> [ArraySlice<T>] {
        stride(from: 0, to: list.count, by: 500).map { list[$0..<min(list.count, $0 + 500)] }
    }
}
