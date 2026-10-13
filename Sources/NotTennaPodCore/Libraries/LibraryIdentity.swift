import Foundation

/// A library's own identity and the library data that is not sync state (PROTOCOL §15.2, schema 20): who
/// the library is, its Cast tag, the Keep at logout that last archived or converted it, and the folder its owned
/// paths were written under. Every library has it, server or standalone, and it moves with the library's database.
public struct LibraryIdentity: Equatable, Sendable {
    /// What a Keep at logout did to this library (PROTOCOL §15.4): `archived` (phase 4, the old standalone library, never opened
    /// as the active library again) or `converted` (phase 5, the server library that became standalone).
    public enum KeepRole: String, Sendable { case archived, converted }

    /// A server library's ID, kept by a library kept from it; a fresh UUID for any other library.
    public var identity: String
    /// The tag a library's Cast loads carry (PROTOCOL §15.4 "Cast"): a server library's ID, kept by a library kept from it;
    /// nil for any other standalone library.
    public var castTag: String?
    /// The Keep operation that last archived or converted this library, and how.
    public var keepOperation: String?
    public var keepRole: KeepRole?
    /// For an archived library: the previous library it became (`Previous Libraries/<archive>/`).
    public var archiveID: String?
    /// The folder the library's owned paths (downloads, transcripts, download destinations, pending file effects) were
    /// written under: the folder holding its `media/` (PROTOCOL §15.4 "Owned paths").
    public var pathsRoot: String

    public init(identity: String, castTag: String? = nil, keepOperation: String? = nil, keepRole: KeepRole? = nil,
                archiveID: String? = nil, pathsRoot: String) {
        self.identity = identity; self.castTag = castTag; self.keepOperation = keepOperation; self.keepRole = keepRole
        self.archiveID = archiveID; self.pathsRoot = pathsRoot
    }

    /// The library as its Cast loads name it (PROTOCOL §15.4 "Cast"): its tag as a server library reference, or the standalone
    /// library's (no tag) when it has none. The graph tags its loads with it and adopts receiver media by it.
    public var castLibrary: LibraryReference { castTag.map { .server($0) } ?? .standalone }
}

extension LibraryReference {
    /// The library's tag on Cast loads (`CastMediaItemCodec.libraryIDKey`): none for the standalone library. Receiver
    /// media is this library's own only when its tag equals this one (`CastReceiverSessionController`,
    /// `CastPlaybackEngine`): another library's media, and untagged media for a tagged library, are foreign.
    public var castLibraryID: String? { if case .server(let id) = self { id } else { nil } }
}

/// Schema 20: three library tables every library reads, and the
/// idempotent migration that fills them.
enum LibrarySchema20 {
    static let statements = [
        """
        CREATE TABLE IF NOT EXISTS library_identity (
            id INTEGER PRIMARY KEY CHECK(id = 1), identity TEXT NOT NULL, cast_tag TEXT,
            keep_operation TEXT, keep_role TEXT CHECK(keep_role IN ('archived', 'converted')), archive_id TEXT,
            paths_root TEXT NOT NULL)
        """,
        // An imported Android row that counts separately in statistics (PROTOCOL §11.5), owned by its local episode.
        """
        CREATE TABLE IF NOT EXISTS statistics_units (
            episode_id INTEGER NOT NULL REFERENCES episodes(id) ON DELETE CASCADE, unit_id TEXT NOT NULL,
            played_ms INTEGER NOT NULL DEFAULT 0, last_played INTEGER NOT NULL DEFAULT 0, history INTEGER,
            duration_ms INTEGER NOT NULL DEFAULT 0, played INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(episode_id, unit_id))
        """,
        // A podcast removed elsewhere while its episode is selected, carried into a library kept at logout (PROTOCOL §15.4).
        "CREATE TABLE IF NOT EXISTS pinned_feed_removals (feed_id INTEGER PRIMARY KEY REFERENCES feeds(id) ON DELETE CASCADE)",
    ]

    /// The migration of one library database, inside the schema transaction: the tables, then the identity (a server
    /// library's ID as identity and Cast tag; a fresh identity for any other library), the folder as `paths_root`,
    /// and a server library's statistics units backfilled from `ntp_statistics_units` without those a pending local
    /// reset covers. Idempotent: an existing identity and existing units are kept.
    static func migrate(_ database: LibrarySQLite, folder: URL) throws {
        for statement in statements { try database.execute(statement) }
        guard try database.scalar("SELECT count(*) FROM library_identity") == 0 else { return }
        let server = try database.rows("SELECT library_id FROM ntp_library WHERE id = 1").first?.first?.text
        let identity = server ?? ContractIdentity.randomUUID()
        try database.execute("INSERT INTO library_identity(id, identity, cast_tag, paths_root) VALUES (1, ?, ?, ?)",
                             [.text(identity), server.map(LibrarySQLValue.text) ?? .null, .text(LibraryOwnedPaths.root(of: folder))])
        if server != nil { try ServerStatisticsUnits.backfill(database) }
    }
}

extension LibrarySQLite {
    /// The library's identity row (schema 20); nil before schema 20.
    func libraryIdentity() throws -> LibraryIdentity? {
        guard try scalar("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'library_identity'") == 1,
              let row = try rows("SELECT identity, cast_tag, keep_operation, keep_role, archive_id, paths_root FROM library_identity WHERE id = 1").first,
              let identity = row[0].text, let root = row[5].text else { return nil }
        return LibraryIdentity(identity: identity, castTag: row[1].text, keepOperation: row[2].text,
                               keepRole: row[3].text.flatMap(LibraryIdentity.KeepRole.init(rawValue:)), archiveID: row[4].text,
                               pathsRoot: root)
    }
}

extension FeedLibraryStore {
    /// This library's identity (schema 20).
    public func libraryIdentity() throws -> LibraryIdentity {
        guard let identity = try database.libraryIdentity() else { throw FeedLibraryError.corruptRecord }
        return identity
    }

    /// The library's Cast tag (PROTOCOL §15.4 "Cast"): the server library's ID it is or was kept from; nil otherwise.
    public func castTag() throws -> String? { try libraryIdentity().castTag }

    /// Makes this new server library's identity its library ID, and its Cast tag (first attachment, PROTOCOL §15.4).
    func adoptServerIdentity(_ libraryID: String) throws {
        try database.execute("UPDATE library_identity SET identity = ?, cast_tag = ? WHERE id = 1", [.text(libraryID), .text(libraryID)])
    }
}

/// A library's statistics unit (PROTOCOL §15.2, §11.5): an imported Android row that the server merged into one episode but
/// that counts separately, as Android counts each row. Owned by its local episode: deleting the episode deletes it.
public struct LibraryStatisticsUnit: Equatable, Hashable, Sendable {
    public var episodeID: Int64
    public var unitID: String
    public var playedMilliseconds: Int64
    /// 0 when the row was never played (Android's `last_played_time` default).
    public var lastPlayedMilliseconds: Int64
    /// The row's history time (`playback_completion_date`); nil when it has none.
    public var historyMilliseconds: Int64?
    public var durationMilliseconds: Int64
    /// The row was PLAYED (`read = 1`); otherwise unplayed (a unit is never new).
    public var played: Bool
    public var positionMilliseconds: Int64

    public init(episodeID: Int64, unitID: String, playedMilliseconds: Int64 = 0, lastPlayedMilliseconds: Int64 = 0,
                historyMilliseconds: Int64? = nil, durationMilliseconds: Int64 = 0, played: Bool = false, positionMilliseconds: Int64 = 0) {
        self.episodeID = episodeID; self.unitID = unitID; self.playedMilliseconds = playedMilliseconds
        self.lastPlayedMilliseconds = lastPlayedMilliseconds; self.historyMilliseconds = historyMilliseconds
        self.durationMilliseconds = durationMilliseconds; self.played = played; self.positionMilliseconds = positionMilliseconds
    }

    /// The unit as the statistics row it was on Android: its episode's feed, metadata and publication date with the
    /// unit's own state and duration, not downloaded. Only statistics read it; no list shows it.
    public func statisticsRow(of episode: LibraryEpisode) -> LibraryEpisode {
        var row = episode
        var media = row.details.media ?? ParsedMedia(url: nil, size: 0, mimeType: nil, durationMilliseconds: 0)
        media.durationMilliseconds = Int32(clamping: durationMilliseconds)
        media.size = 0
        row.details.media = media
        var state = EpisodeUserState()
        state.playState = played ? .played : .unplayed
        state.positionMilliseconds = Int32(clamping: positionMilliseconds)
        state.playedDurationMilliseconds = playedMilliseconds
        state.lastPlayedTimeMilliseconds = lastPlayedMilliseconds
        state.lastPlayedHistoryMilliseconds = historyMilliseconds
        state.isFavorite = false
        state.isDownloaded = false
        state.downloadDate = nil
        state.localFileURL = nil
        row.userState = state
        return row
    }
}

extension LibrarySQLite {
    /// Every statistics unit, by local episode ID (schema 20).
    func statisticsUnits(episodes: [Int64]? = nil) throws -> [Int64: [LibraryStatisticsUnit]] {
        var units: [Int64: [LibraryStatisticsUnit]] = [:]
        let filter = episodes.map { ids in " WHERE episode_id IN (SELECT value FROM json_each('\(ContractJSON.array(ids.map(ContractJSON.integer)).canonicalText)'))" } ?? ""
        for row in try rows("SELECT episode_id, unit_id, played_ms, last_played, history, duration_ms, played, position FROM statistics_units\(filter) ORDER BY episode_id, unit_id") {
            guard let episode = row[0].integer, let unit = row[1].text else { throw FeedLibraryError.corruptRecord }
            units[episode, default: []].append(LibraryStatisticsUnit(episodeID: episode, unitID: unit, playedMilliseconds: row[2].integer ?? 0,
                lastPlayedMilliseconds: row[3].integer ?? 0, historyMilliseconds: row[4].integer, durationMilliseconds: row[5].integer ?? 0,
                played: row[6].integer == 1, positionMilliseconds: row[7].integer ?? 0))
        }
        return units
    }

    /// Replaces one episode's units.
    func replaceStatisticsUnits(episode: Int64, with units: [LibraryStatisticsUnit]) throws {
        try execute("DELETE FROM statistics_units WHERE episode_id = ?", [.integer(episode)])
        for unit in units { try insertStatisticsUnit(unit) }
    }

    func insertStatisticsUnit(_ unit: LibraryStatisticsUnit) throws {
        try execute("INSERT OR REPLACE INTO statistics_units(episode_id, unit_id, played_ms, last_played, history, duration_ms, played, position) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    [.integer(unit.episodeID), .text(unit.unitID), .integer(unit.playedMilliseconds), .integer(unit.lastPlayedMilliseconds),
                     unit.historyMilliseconds.map(LibrarySQLValue.integer) ?? .null, .integer(unit.durationMilliseconds),
                     .integer(unit.played ? 1 : 0), .integer(unit.positionMilliseconds)])
    }
}

/// A server library's statistics units (PROTOCOL §15.2): `ntp_statistics_units` (the base, keyed by wire episode
/// IDs) projected onto the library table `statistics_units` by local episode ID. A unit a pending local statistics
/// reset covers is not projected, as the server drops it: the reset covers what the library knew when it was made,
/// so the units of a record whose provenance was learned before the latest pending reset (PROTOCOL §6.8 "Coverage").
enum ServerStatisticsUnits {
    /// The units of one wire episode as library rows, nil when the episode has no local row.
    static func projected(_ database: LibrarySQLite, episode: String, localID: Int64, record: ContractJSON?,
                          provenance: [String], resetClock: Int64?) throws -> [LibraryStatisticsUnit] {
        if let resetClock, try covered(database, provenance: provenance, resetClock: resetClock) { return [] }
        return (record?["units"]?.arrayValue ?? []).compactMap { unit($0, localID: localID) }
    }

    static func unit(_ value: ContractJSON, localID: Int64) -> LibraryStatisticsUnit? {
        guard let id = value["id"]?.stringValue else { return nil }
        return LibraryStatisticsUnit(episodeID: localID, unitID: id, playedMilliseconds: value["played_ms"]?.integerValue ?? 0,
            lastPlayedMilliseconds: value["last_played"]?.integerValue ?? 0, historyMilliseconds: value["history"]?.integerValue,
            durationMilliseconds: value["duration_ms"]?.integerValue ?? 0, played: value["played"]?.boolValue ?? false,
            positionMilliseconds: value["position"]?.integerValue ?? 0)
    }

    /// The knowledge clock of the latest pending local statistics reset, ordinary or deferred (a deferred cut's draft
    /// writes the same overlay, PROTOCOL §15.2); nil without one.
    static func pendingResetClock(_ database: LibrarySQLite, excluding: Set<String> = []) throws -> Int64? {
        var latest: Int64?
        for row in try database.rows("SELECT op_id, clock FROM ntp_overlays WHERE entity = 'account' AND kind = 'stat_cut' AND property = 'played_time'") {
            guard let op = row[0].text, !excluding.contains(op), let clock = row[1].integer else { continue }
            latest = max(latest ?? clock, clock)
        }
        return latest
    }

    /// Whether every node of a record's provenance was known before the reset (an empty provenance: known since the
    /// attachment).
    static func covered(_ database: LibrarySQLite, provenance: [String], resetClock: Int64) throws -> Bool {
        for node in provenance {
            guard let clock = try database.rows("SELECT knowledge_clock FROM ntp_nodes WHERE node_id = ?", [.text(node)]).first?.first?.integer,
                  clock < resetClock else { return false }
        }
        return true
    }

    static func provenance(_ database: LibrarySQLite, episode: String) throws -> [String] {
        guard let text = try database.rows("SELECT provenance FROM ntp_records WHERE entity = 'episode' AND id = ? AND field_group = 'statistics_units'",
                                           [.text(episode)]).first?.first?.text,
              let list = try? ContractJSON.decode(Data(text.utf8)).arrayValue else { return [] }
        return list.compactMap(\.stringValue)
    }

    /// Schema 20's backfill: every mapped episode's units from `ntp_statistics_units`, by local ID.
    static func backfill(_ database: LibrarySQLite) throws {
        let reset = try pendingResetClock(database)
        var records: [String: [ContractJSON]] = [:]
        for row in try database.rows("SELECT episode_id, record FROM ntp_statistics_units ORDER BY episode_id, unit_id") {
            guard let episode = row[0].text, let data = row[1].data, let unit = try? ContractJSON.decode(data) else { continue }
            records[episode, default: []].append(unit)
        }
        for (episode, units) in records.sorted(by: { $0.key < $1.key }) {
            guard let local = try database.rows("SELECT local_id FROM ntp_episodes WHERE episode_id = ? AND local_id IS NOT NULL", [.text(episode)]).first?.first?.integer,
                  try database.scalar("SELECT count(*) FROM episodes WHERE id = ?", [.integer(local)]) == 1 else { continue }
            let rows = try projected(database, episode: episode, localID: local, record: ["units": .array(units)],
                                     provenance: provenance(database, episode: episode), resetClock: reset)
            try database.replaceStatisticsUnits(episode: local, with: rows)
        }
    }
}

/// A library's owned paths (PROTOCOL §15.4 "Owned paths and downloads"): the absolute paths it stores under its own `media/`
/// (downloads, transcripts, download destinations, the file lists of pending effects). `paths_root` is the folder they
/// were written under; when the library is found elsewhere (a Keep moved it, or a device backup was restored under
/// another application root), they are rewritten onto the current folder before it opens writable.
/// Paths elsewhere (local-folder grants) are not owned and never rewritten.
public enum LibraryOwnedPaths {
    /// The form `paths_root` stores: the standardized path, without a trailing slash.
    public static func root(of folder: URL) -> String {
        var path = folder.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// One owned path mapped from the folder it was written under onto `current` (read-only readers resolve without
    /// writing). A path outside the old root's `media/` is returned unchanged.
    public static func resolve(_ path: String, writtenUnder old: String, current: String) -> String {
        guard old != current else { return path }
        for owned in ["media/"] {
            let prefix = old + "/" + owned
            if path.hasPrefix(prefix) { return current + "/" + owned + path.dropFirst(prefix.count) }
        }
        return path
    }

    public static func resolve(_ url: URL, writtenUnder old: String, current: String) -> URL {
        guard url.isFileURL else { return url }
        let resolved = resolve(url.standardizedFileURL.path, writtenUnder: old, current: current)
        return resolved == url.standardizedFileURL.path ? url : URL(fileURLWithPath: resolved)
    }

    /// The text forms an owned prefix takes inside a stored JSON record: a path and a file URL, each with and without
    /// `JSONEncoder`'s escaped slashes, each starting a JSON string.
    static func recordForms(_ root: String) -> [String] {
        let path = root + "/media/"
        let url = URL(fileURLWithPath: root + "/media", isDirectory: true).absoluteString
        var forms: [String] = []
        for text in [path, url] {
            forms.append("\"" + text)
            forms.append("\"" + text.replacingOccurrences(of: "/", with: "\\/"))
        }
        return forms
    }

    /// Rewrites one record's owned paths from `old` onto `current`; nil when nothing changes.
    static func rewrite(_ data: Data, from old: String, to current: String) -> Data? {
        var text = String(decoding: data, as: UTF8.self)
        var changed = false
        for (from, to) in zip(recordForms(old), recordForms(current)) where text.contains(from) {
            text = text.replacingOccurrences(of: from, with: to)
            changed = true
        }
        return changed ? Data(text.utf8) : nil
    }

    /// Normalization before a writable open: when `paths_root` is not `folder`, one transaction rewrites
    /// the owned paths of every episode, download job and pending effect onto `folder` and updates `paths_root`.
    /// Repeating it changes nothing. Returns the number of rewritten rows.
    @discardableResult
    static func normalize(_ database: LibrarySQLite, folder: URL) throws -> Int {
        guard let identity = try database.libraryIdentity() else { return 0 }
        let current = root(of: folder)
        guard identity.pathsRoot != current else { return 0 }
        return try database.transaction {
            var rewritten = 0
            for table in ["episodes", "download_jobs", "pending_effects"] {
                for row in try database.rows("SELECT rowid, record FROM \(table) WHERE instr(CAST(record AS TEXT), 'media') > 0") {
                    guard let id = row[0].integer, let data = row[1].data,
                          let next = rewrite(data, from: identity.pathsRoot, to: current) else { continue }
                    try database.execute("UPDATE \(table) SET record = ? WHERE rowid = ?", [.blob(next), .integer(id)])
                    rewritten += 1
                }
            }
            try database.execute("UPDATE library_identity SET paths_root = ? WHERE id = 1", [.text(current)])
            return rewritten
        }
    }
}

extension FeedLibraryStore {
    /// A library kept at logout with a podcast removed elsewhere while its episode was selected (PROTOCOL §15.4): when the
    /// selection is no longer one of its episodes, the podcast is deleted by the ordinary local feed deletion (files
    /// through the two-phase cleanup). It is never subscribed again silently, and the current episode is not cleared.
    /// Returns the deleted feeds.
    @discardableResult
    public func finishPinnedFeedRemovals(now: Date = Date()) throws -> [Int64] {
        guard serverContext == nil, try database.scalar("SELECT count(*) FROM pinned_feed_removals") > 0 else { return [] }
        return try write(.local) {
            let held = Set([try playbackSelectionEpisodeID(), try playbackSession()?.episodeID].compactMap { $0 })
            var deleted: [Int64] = []
            var queue = try loadQueue()
            for row in try database.rows("SELECT feed_id FROM pinned_feed_removals ORDER BY feed_id") {
                guard let id = row[0].integer, let feed = try loadFeed(id) else { continue }
                guard !feed.episodes.contains(where: { held.contains($0.id) }) else { continue }
                try deleteFeedInTransaction(feed, queue: &queue, now: now)
                deleted.append(id)
            }
            return deleted
        }
    }

    /// Whether a pinned removal waits for the player to leave its episode (a library kept at logout).
    public func hasPinnedFeedRemovals() throws -> Bool {
        try database.scalar("SELECT count(*) FROM pinned_feed_removals") > 0
    }
}
