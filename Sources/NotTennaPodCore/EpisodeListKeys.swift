import Foundation

/// The values lists order, filter and count episodes by (schema 21), kept by SQLite in `episode_list_keys` from
/// `episodes.record` on every write path, so a list can read exactly the rows it needs instead of decoding the library.
/// `init(episode:feedID:hidden:feedEligible:)` is the reference mapping the SQL derivation must equal, bit for bit.
public struct EpisodeListKeys: Sendable {
    public var id: Int64
    public var feedID: Int64
    /// Staged for a server unit that has not revealed it (`ntp_hidden_episodes`): no list shows it.
    public var hidden: Bool
    /// The feed is subscribed and not a pinned removal: what Inbox and Home read. A podcast hidden while its rows change
    /// in bounded transactions (`ntp_hidden_feeds`, staging or removing) is left out when read, per feed, so hiding or
    /// revealing it never rewrites its episodes' rows inside a unit.
    public var feedEligible: Bool
    /// `details.publicationDate` as stored: seconds since 2001. Nil without a date.
    public var publicationReference: Double?
    /// The list sort key: `Int64((date.timeIntervalSince1970 * 1000).rounded())`. Nil without a date.
    public var publicationMilliseconds: Int64?
    /// `EpisodePlayState` raw value.
    public var state: Int64
    public var isFavorite: Bool
    public var isDownloaded: Bool
    public var autoDownloadEnabled: Bool
    public var hasMedia: Bool
    public var positionMilliseconds: Int64
    public var playedDurationMilliseconds: Int64
    public var lastPlayedTimeMilliseconds: Int64
    /// Nil when the episode has no history entry (kept apart from zero).
    public var lastPlayedHistoryMilliseconds: Int64?
    /// `userState.downloadDate` as stored: seconds since 2001.
    public var downloadReference: Double?
    /// Nil without media.
    public var durationMilliseconds: Int64?
    public var size: Int64?
    public var title: String?
    /// `details.identifier`.
    public var guid: String?
    public var mediaURL: String?
    /// The text after the last "/" of `userState.localFileURL`.
    public var localFileName: String?

    /// The reference mapping of a decoded episode.
    public init(episode: LibraryEpisode, feedID: Int64, hidden: Bool, feedEligible: Bool) {
        id = episode.id
        self.feedID = feedID
        self.hidden = hidden
        self.feedEligible = feedEligible
        let details = episode.details, state = episode.userState
        publicationReference = details.publicationDate?.timeIntervalSinceReferenceDate
        publicationMilliseconds = details.publicationDate.map { Self.listMilliseconds($0) }
        self.state = Int64(state.playState.rawValue)
        isFavorite = state.isFavorite
        isDownloaded = state.isDownloaded
        autoDownloadEnabled = state.autoDownloadEnabled
        hasMedia = details.media != nil
        positionMilliseconds = Int64(state.positionMilliseconds)
        playedDurationMilliseconds = state.playedDurationMilliseconds
        lastPlayedTimeMilliseconds = state.lastPlayedTimeMilliseconds
        lastPlayedHistoryMilliseconds = state.lastPlayedHistoryMilliseconds
        downloadReference = state.downloadDate?.timeIntervalSinceReferenceDate
        durationMilliseconds = details.media.map { Int64($0.durationMilliseconds) }
        size = details.media?.size
        title = details.title
        guid = details.identifier
        mediaURL = details.media?.url
        localFileName = state.localFileURL.map(Self.lastComponent)
    }

    /// The keys of a record that is not valid JSON: every value its default (a malformed row still commits; decoding it
    /// fails later exactly as before).
    static func malformed(id: Int64, feedID: Int64, hidden: Bool, feedEligible: Bool) -> Self {
        var keys = Self(episode: LibraryEpisode(id: id, details: ParsedEpisode()), feedID: feedID, hidden: hidden, feedEligible: feedEligible)
        keys.state = 0
        return keys
    }

    /// The lists' date key (`EpisodeListQueries`), saturated as SQLite's CAST saturates outside Int64.
    static func listMilliseconds(_ date: Date) -> Int64 {
        let value = (date.timeIntervalSince1970 * 1000).rounded()
        if value >= 9_223_372_036_854_775_807.0 { return .max }
        if value <= -9_223_372_036_854_775_808.0 { return .min }
        return Int64(value)
    }

    /// The text after the last "/" (all of it without one), as the SQL derivation computes it.
    static func lastComponent(_ path: String) -> String {
        guard let slash = path.utf8.lastIndex(of: UInt8(ascii: "/")) else { return path }
        return String(path[path.utf8.index(after: slash)...])
    }

    /// A row of `LibrarySchema21.keyColumns`, in that order.
    init(row: [LibrarySQLValue]) throws {
        guard row.count == LibrarySchema21.keyColumns.count else { throw FeedLibraryError.corruptRecord }
        func integer(_ index: Int) throws -> Int64 {
            guard let value = row[index].integer else { throw FeedLibraryError.corruptRecord }
            return value
        }
        func optionalInteger(_ index: Int) throws -> Int64? {
            if case .null = row[index] { return nil }
            return try integer(index)
        }
        func real(_ index: Int) throws -> Double? {
            switch row[index] {
            case .null: return nil
            case .real(let value): return value
            case .integer(let value): return Double(value)
            default: throw FeedLibraryError.corruptRecord
            }
        }
        func text(_ index: Int) throws -> String? {
            switch row[index] {
            case .null: return nil
            case .text(let value): return value
            default: throw FeedLibraryError.corruptRecord
            }
        }
        id = try integer(0); feedID = try integer(1); hidden = try integer(2) != 0; feedEligible = try integer(3) != 0
        publicationReference = try real(4); publicationMilliseconds = try optionalInteger(5)
        state = try integer(6); isFavorite = try integer(7) != 0; isDownloaded = try integer(8) != 0
        autoDownloadEnabled = try integer(9) != 0; hasMedia = try integer(10) != 0
        positionMilliseconds = try integer(11); playedDurationMilliseconds = try integer(12)
        lastPlayedTimeMilliseconds = try integer(13); lastPlayedHistoryMilliseconds = try optionalInteger(14)
        downloadReference = try real(15); durationMilliseconds = try optionalInteger(16); size = try optionalInteger(17)
        title = try text(18); guid = try text(19); mediaURL = try text(20); localFileName = try text(21)
    }
}

extension EpisodeListKeys: Equatable {
    /// Exact equality: text by its UTF-8 bytes (Swift's `==` treats canonically equivalent strings as equal), doubles by
    /// their bits.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        func same(_ a: String?, _ b: String?) -> Bool {
            switch (a, b) {
            case (nil, nil): true
            case let (a?, b?): a.utf8.elementsEqual(b.utf8)
            default: false
            }
        }
        func same(_ a: Double?, _ b: Double?) -> Bool { a?.bitPattern == b?.bitPattern }
        return lhs.id == rhs.id && lhs.feedID == rhs.feedID && lhs.hidden == rhs.hidden && lhs.feedEligible == rhs.feedEligible
            && same(lhs.publicationReference, rhs.publicationReference) && lhs.publicationMilliseconds == rhs.publicationMilliseconds
            && lhs.state == rhs.state && lhs.isFavorite == rhs.isFavorite && lhs.isDownloaded == rhs.isDownloaded
            && lhs.autoDownloadEnabled == rhs.autoDownloadEnabled && lhs.hasMedia == rhs.hasMedia
            && lhs.positionMilliseconds == rhs.positionMilliseconds && lhs.playedDurationMilliseconds == rhs.playedDurationMilliseconds
            && lhs.lastPlayedTimeMilliseconds == rhs.lastPlayedTimeMilliseconds
            && lhs.lastPlayedHistoryMilliseconds == rhs.lastPlayedHistoryMilliseconds
            && same(lhs.downloadReference, rhs.downloadReference) && lhs.durationMilliseconds == rhs.durationMilliseconds
            && lhs.size == rhs.size && same(lhs.title, rhs.title) && same(lhs.guid, rhs.guid) && same(lhs.mediaURL, rhs.mediaURL)
            && same(lhs.localFileName, rhs.localFileName)
    }
}

/// A feed's visible episode counts (schema 21, `feed_list_counts`): hidden (staged) episodes never count. Whether the
/// feed itself is shown is decided per feed when it is read.
public struct FeedListCounts: Equatable, Sendable {
    public var feedID: Int64
    public var total: Int64 = 0
    public var new: Int64 = 0
    public var played: Int64 = 0
    /// Downloaded with media (`FeedCounter.showDownloaded`).
    public var downloadedMedia: Int64 = 0
    /// Downloaded with media and not played (`FeedCounter.showDownloadedUnplayed`).
    public var downloadedMediaUnplayed: Int64 = 0
    /// Downloaded, media or not.
    public var downloaded: Int64 = 0
    public var favorite: Int64 = 0

    public init(feedID: Int64) { self.feedID = feedID }

    /// The reference: the counts of the feed's visible episodes.
    public init(feedID: Int64, episodes: [LibraryEpisode]) {
        self.feedID = feedID
        for episode in episodes {
            let state = episode.userState, media = episode.details.media != nil
            total += 1
            if state.playState == .new { new += 1 }
            if state.playState == .played { played += 1 }
            if state.isDownloaded && media { downloadedMedia += 1 }
            if state.isDownloaded && media && state.playState != .played { downloadedMediaUnplayed += 1 }
            if state.isDownloaded { downloaded += 1 }
            if state.isFavorite { favorite += 1 }
        }
    }

    init(row: [LibrarySQLValue]) throws {
        let values = try row.map { value -> Int64 in
            guard let integer = value.integer else { throw FeedLibraryError.corruptRecord }
            return integer
        }
        guard values.count == 8 else { throw FeedLibraryError.corruptRecord }
        feedID = values[0]; total = values[1]; new = values[2]; played = values[3]
        downloadedMedia = values[4]; downloadedMediaUnplayed = values[5]; downloaded = values[6]; favorite = values[7]
    }

    /// The Subscriptions and drawer counter (`FeedCounter.counts`) of a subscribed feed.
    public func count(for counter: FeedCounter) -> Int64 {
        switch counter {
        case .showNew: new
        case .showUnplayed: total - played
        case .showDownloaded: downloadedMedia
        case .showDownloadedUnplayed: downloadedMediaUnplayed
        case .showNone: 0
        }
    }
}

/// Schema 21: the derived list keys and counts, the tables their triggers read in every library, and the bookkeeping
/// that keyed reads and the change capture use. Derived data never blocks or changes a write: no derived table has a
/// constraint other than its INTEGER PRIMARY KEY, every insert is guarded, a record that is not valid JSON is keyed
/// with defaults, and no trigger writes a canonical table. The migration step only creates objects (no row work); the
/// rows are filled in background batches (`fillBatch`) while every write already keeps its own rows.
enum LibrarySchema21 {
    // MARK: - Derivation

    /// The episode record as JSON text: `{}` when it is not valid JSON.
    static func recordText(_ column: String) -> String {
        "CASE WHEN json_valid(CAST(\(column) AS TEXT)) THEN CAST(\(column) AS TEXT) ELSE '{}' END"
    }

    /// The milliseconds of the stored publication date, rounded half away from zero as Swift's `rounded()` (SQLite's
    /// `round()` is not used).
    private static let publicationMilliseconds: String = {
        let x = "((json_extract(r, '$.details.publicationDate') + 978307200.0) * 1000.0)"
        return "CASE WHEN \(x) IS NULL THEN NULL WHEN \(x) >= 0 THEN CAST(\(x) AS INTEGER) + (\(x) - CAST(\(x) AS INTEGER) >= 0.5) ELSE CAST(\(x) AS INTEGER) - (CAST(\(x) AS INTEGER) - \(x) >= 0.5) END"
    }()

    /// Every derived column but the identity, hidden and eligibility ones, as one expression over the record text `r`.
    /// The fill and every trigger use these same strings. Optional values stay NULL when absent; the rest are coalesced.
    static let derivedColumns: [(name: String, sql: String)] = {
        let path = "json_extract(r, '$.userState.localFileURL')"
        return [
            ("pub_ref", "json_extract(r, '$.details.publicationDate')"),
            ("pub_ms", publicationMilliseconds),
            ("state", "coalesce(json_extract(r, '$.userState.playState'), 0)"),
            ("favorite", "coalesce(json_extract(r, '$.userState.isFavorite'), 0)"),
            ("downloaded", "coalesce(json_extract(r, '$.userState.isDownloaded'), 0)"),
            ("auto_download", "coalesce(json_extract(r, '$.userState.autoDownloadEnabled'), 1)"),
            ("has_media", "coalesce(json_type(r, '$.details.media') = 'object', 0)"),
            ("position", "coalesce(json_extract(r, '$.userState.positionMilliseconds'), 0)"),
            ("played_ms", "coalesce(json_extract(r, '$.userState.playedDurationMilliseconds'), 0)"),
            ("last_played_ms", "coalesce(json_extract(r, '$.userState.lastPlayedTimeMilliseconds'), 0)"),
            ("history_ms", "json_extract(r, '$.userState.lastPlayedHistoryMilliseconds')"),
            ("download_ref", "json_extract(r, '$.userState.downloadDate')"),
            ("duration", "json_extract(r, '$.details.media.durationMilliseconds')"),
            ("size", "json_extract(r, '$.details.media.size')"),
            ("title", "json_extract(r, '$.details.title')"),
            ("guid", "json_extract(r, '$.details.identifier')"),
            ("media_url", "json_extract(r, '$.details.media.url')"),
            ("local_file_name", "substr(\(path), length(rtrim(\(path), replace(\(path), '/', ''))) + 1)"),
        ]
    }()

    /// Every column of `episode_list_keys`, in table order (`EpisodeListKeys.init(row:)`).
    static let keyColumns = ["id", "feed_id", "hidden", "feed_eligible"] + derivedColumns.map(\.name)

    /// 1 when feed `feed` is subscribed and not a pinned removal (`pinned_feed_removals`, or the server's
    /// `ntp_podcasts.pinned_removal`). A header that is not valid JSON is not eligible. (`ntp_hidden_feeds` is applied
    /// when read: see `EpisodeListKeys.feedEligible`.)
    static func eligibleSQL(_ feed: String) -> String {
        "(coalesce((SELECT CASE WHEN json_valid(CAST(f.record AS TEXT)) THEN json_extract(CAST(f.record AS TEXT), '$.subscriptionState') END FROM feeds f WHERE f.id = \(feed)), -1) = 0"
            + " AND NOT EXISTS (SELECT 1 FROM pinned_feed_removals WHERE feed_id = \(feed))"
            + " AND NOT EXISTS (SELECT 1 FROM ntp_podcasts WHERE feed_id = \(feed) AND pinned_removal = 1))"
    }

    /// 1 when episode `episode` is staged hidden.
    static func hiddenSQL(_ episode: String) -> String {
        "EXISTS (SELECT 1 FROM ntp_hidden_episodes WHERE episode_id = \(episode))"
    }

    /// The column groups a write updates separately, each only when one of its values changed: SQLite maintains an
    /// index only for an UPDATE that sets one of its columns, so a listening save maintains the history and last-played
    /// indexes it changes and never the state, favorite, download, feed or lookup indexes.
    static let columnGroups: [(name: String, columns: [String])] = [
        ("listening", ["position", "played_ms", "auto_download", "download_ref", "size", "title"]),
        ("state", ["state", "favorite", "downloaded"]),
        ("history", ["history_ms", "last_played_ms"]),
        ("metadata", ["feed_id", "pub_ref", "pub_ms", "has_media", "duration"]),
        ("lookup", ["media_url", "guid", "local_file_name"]),
    ]

    // MARK: - Objects

    static let tables = [
        // The same statements as `ServerExchangeTables`: the derived triggers read them, and a trigger naming a missing
        // table fails every write it fires on. Empty in a standalone library.
        "CREATE TABLE IF NOT EXISTS ntp_hidden_feeds (feed_id INTEGER PRIMARY KEY, podcast_id TEXT, state TEXT NOT NULL CHECK(state IN ('staging', 'removing')), seq INTEGER NOT NULL DEFAULT 0)",
        "CREATE TABLE IF NOT EXISTS ntp_hidden_episodes (episode_id INTEGER PRIMARY KEY, feed_id INTEGER NOT NULL, seq INTEGER NOT NULL DEFAULT 0)",
        """
        CREATE TABLE IF NOT EXISTS episode_list_keys (id INTEGER PRIMARY KEY, feed_id INTEGER, hidden INTEGER, feed_eligible INTEGER,
            pub_ref REAL, pub_ms INTEGER, state INTEGER, favorite INTEGER, downloaded INTEGER, auto_download INTEGER, has_media INTEGER,
            position INTEGER, played_ms INTEGER, last_played_ms INTEGER, history_ms INTEGER, download_ref REAL, duration INTEGER,
            size INTEGER, title TEXT, guid TEXT, media_url TEXT, local_file_name TEXT)
        """,
        "CREATE TABLE IF NOT EXISTS feed_list_counts (feed_id INTEGER PRIMARY KEY, total INTEGER, new_count INTEGER, played INTEGER, dl_media INTEGER, dl_media_unplayed INTEGER, dl_any INTEGER, favorite INTEGER)",
        // The persisted commit sequence, advanced for every commit with a visible change (seeded here only).
        "CREATE TABLE IF NOT EXISTS library_change_sequence (id INTEGER PRIMARY KEY, seq INTEGER)",
        "INSERT INTO library_change_sequence(id, seq) SELECT 1, 0 WHERE NOT EXISTS (SELECT 1 FROM library_change_sequence WHERE id = 1)",
        // What a feed's last full refresh merge applied, for the unchanged-refresh check (`FeedRefreshMemo`, which
        // writes it).
        "CREATE TABLE IF NOT EXISTS feed_refresh_memo (feed_id INTEGER PRIMARY KEY, parse_digest BLOB, inputs_digest BLOB, details_generation INTEGER, repeated_duplicates BLOB)",
        // The background fill's progress: present until the keys and counts are complete.
        // `end_id`: the last episode the migration found; every later one is keyed by its trigger.
        "CREATE TABLE IF NOT EXISTS derived_fill (id INTEGER PRIMARY KEY, next_id INTEGER, end_id INTEGER)",
    ]

    static let indexes = [
        "CREATE INDEX IF NOT EXISTS episode_list_keys_by_feed ON episode_list_keys(feed_id, hidden, pub_ms)",
        "CREATE INDEX IF NOT EXISTS episode_list_keys_inbox_date ON episode_list_keys(pub_ms, id) WHERE state = -1 AND hidden = 0 AND feed_eligible = 1",
        "CREATE INDEX IF NOT EXISTS episode_list_keys_inbox_duration ON episode_list_keys(duration, id) WHERE state = -1 AND hidden = 0 AND feed_eligible = 1",
        "CREATE INDEX IF NOT EXISTS episode_list_keys_history ON episode_list_keys(history_ms DESC, id) WHERE history_ms > 0 AND has_media = 1 AND hidden = 0",
        "CREATE INDEX IF NOT EXISTS episode_list_keys_history_any ON episode_list_keys(id) WHERE history_ms IS NOT NULL",
        "CREATE INDEX IF NOT EXISTS episode_list_keys_favorite ON episode_list_keys(id) WHERE favorite = 1",
        "CREATE INDEX IF NOT EXISTS episode_list_keys_downloaded ON episode_list_keys(id) WHERE downloaded = 1",
        "CREATE INDEX IF NOT EXISTS episode_list_keys_surprise ON episode_list_keys(feed_id, pub_ms) WHERE has_media = 1 AND state <> 1 AND hidden = 0",
        "CREATE INDEX IF NOT EXISTS episode_list_keys_classics ON episode_list_keys(last_played_ms) WHERE has_media = 1 AND last_played_ms > 0",
        "CREATE INDEX IF NOT EXISTS episode_list_keys_media_url ON episode_list_keys(media_url)",
        "CREATE INDEX IF NOT EXISTS episode_list_keys_guid ON episode_list_keys(guid, id)",
        "CREATE INDEX IF NOT EXISTS episode_list_keys_file ON episode_list_keys(local_file_name) WHERE local_file_name > ''",
    ]

    /// Schema 22: every stored file name is indexed, the empty name included (`FeedLibraryStore.fileOwners`).
    static let schema22 = [
        "DROP INDEX IF EXISTS episode_list_keys_file",
        "CREATE INDEX IF NOT EXISTS episode_list_keys_file_name ON episode_list_keys(local_file_name) WHERE local_file_name IS NOT NULL",
        // Remove all from Inbox: every NEW episode, whatever its podcast's state.
        "CREATE INDEX IF NOT EXISTS episode_list_keys_new ON episode_list_keys(feed_id) WHERE state = -1",
    ]

    /// The release ledger's pending and unnotified entries, for keyed reads of the ledger. Built by the fill (the
    /// ledger may be large), or at once in a library with no episodes.
    static let ledgerIndexes: [(name: String, sql: String)] = [
        ("ntp_ledger_pending", "CREATE INDEX IF NOT EXISTS ntp_ledger_pending ON ntp_ledger(generation_id, occurrence) WHERE state = 'pending'"),
        ("ntp_ledger_unnotified", "CREATE INDEX IF NOT EXISTS ntp_ledger_unnotified ON ntp_ledger(generation_id, occurrence) WHERE notified = 0"),
        ("ntp_ledger_pending_occurrence", "CREATE INDEX IF NOT EXISTS ntp_ledger_pending_occurrence ON ntp_ledger(occurrence) WHERE state = 'pending'"),
    ]

    // MARK: - Triggers

    /// The derived values of `NEW.record` as one row (`d`).
    private static func derivedRow(_ record: String) -> String {
        "(SELECT " + derivedColumns.map { "\($0.sql) AS \($0.name)" }.joined(separator: ", ")
            + " FROM (SELECT \(recordText(record)) AS r))"
    }

    /// The key row of `NEW`, inserted when there is none (a row the background fill has not reached yet, or a new one).
    private static let insertKeys = "INSERT INTO episode_list_keys(" + keyColumns.joined(separator: ", ") + ") SELECT NEW.id, NEW.feed_id, "
        + hiddenSQL("NEW.id") + ", " + eligibleSQL("NEW.feed_id") + ", " + derivedColumns.map { "d.\($0.name)" }.joined(separator: ", ")
        + " FROM " + derivedRow("NEW.record") + " AS d WHERE NOT EXISTS (SELECT 1 FROM episode_list_keys WHERE id = NEW.id);"

    /// One column group's guarded update: written only when one of its values changed. The metadata group also
    /// recomputes eligibility when the episode's parent changed.
    static func updateGroup(_ columns: [String]) -> String {
        var assignments = columns.map { "\($0) = d.\($0)" }
        let parent = columns.contains("feed_id")
        if parent {
            assignments.append("feed_eligible = CASE WHEN episode_list_keys.feed_id IS d.feed_id THEN episode_list_keys.feed_eligible ELSE "
                               + eligibleSQL("d.feed_id") + " END")
        }
        let values = (parent ? ["NEW.feed_id AS feed_id"] : [])
            + derivedColumns.filter { columns.contains($0.name) }.map { "\($0.sql) AS \($0.name)" }
        let derived = "(SELECT " + values.joined(separator: ", ") + " FROM (SELECT \(recordText("NEW.record")) AS r))"
        let stored = "(" + columns.map { "episode_list_keys.\($0)" }.joined(separator: ", ") + ")"
        let fresh = "(" + columns.map { "d.\($0)" }.joined(separator: ", ") + ")"
        return "UPDATE episode_list_keys SET " + assignments.joined(separator: ", ") + " FROM " + derived
            + " AS d WHERE episode_list_keys.id = NEW.id AND \(stored) IS NOT \(fresh);"
    }

    /// `feed_changes.details_generation` of `feed`, its row made when missing (as the generation triggers make it).
    private static func bumpDetails(_ feed: String) -> String {
        "UPDATE feed_changes SET details_generation = coalesce(details_generation, 0) + 1 WHERE feed_id = \(feed);"
            + " INSERT INTO feed_changes(feed_id, generation, episode_generation, details_generation) SELECT \(feed), 0, 0, 1 WHERE NOT EXISTS (SELECT 1 FROM feed_changes WHERE feed_id = \(feed));"
    }

    private static func detailsOf(_ record: String) -> String {
        "(SELECT CASE WHEN json_valid(t) THEN json_extract(t, '$.details') ELSE t END FROM (SELECT CAST(\(record) AS TEXT) AS t))"
    }

    private static func chaptersOf(_ record: String) -> String {
        "(SELECT CASE WHEN json_valid(t) THEN json_extract(t, '$.hasStoredChapters') END FROM (SELECT CAST(\(record) AS TEXT) AS t))"
    }

    /// Recomputes `feed_eligible` of one feed's key rows (feed-proportional; only rows whose value changes are written).
    static func recomputeEligibility(_ feed: String) -> String {
        "UPDATE episode_list_keys SET feed_eligible = v.value FROM (SELECT \(eligibleSQL(feed)) AS value) AS v WHERE episode_list_keys.feed_id = \(feed) AND episode_list_keys.feed_eligible IS NOT v.value;"
    }

    static let keyTriggers: [(name: String, sql: String)] = [
        // A REPLACE removes the old row without a delete trigger: its key row is dropped and made again.
        ("derived_keys_insert", "CREATE TRIGGER IF NOT EXISTS derived_keys_insert AFTER INSERT ON episodes BEGIN DELETE FROM episode_list_keys WHERE id = NEW.id; "
            + insertKeys + " END"),
        ("derived_keys_update", "CREATE TRIGGER IF NOT EXISTS derived_keys_update AFTER UPDATE OF id, feed_id, record ON episodes BEGIN "
            + "DELETE FROM episode_list_keys WHERE id = OLD.id AND OLD.id IS NOT NEW.id; " + insertKeys + " "
            + columnGroups.map { updateGroup($0.columns) }.joined(separator: " ") + " END"),
        ("derived_keys_delete", "CREATE TRIGGER IF NOT EXISTS derived_keys_delete AFTER DELETE ON episodes BEGIN DELETE FROM episode_list_keys WHERE id = OLD.id; END"),
        // `feed_changes.details_generation`: every write that inserts, deletes or moves an episode or changes its details
        // or stored-chapters flag; a user-state write leaves it (the unchanged-refresh check reads it).
        ("derived_details_insert", "CREATE TRIGGER IF NOT EXISTS derived_details_insert AFTER INSERT ON episodes BEGIN \(bumpDetails("NEW.feed_id")) END"),
        ("derived_details_delete", "CREATE TRIGGER IF NOT EXISTS derived_details_delete AFTER DELETE ON episodes BEGIN \(bumpDetails("OLD.feed_id")) END"),
        ("derived_details_update", "CREATE TRIGGER IF NOT EXISTS derived_details_update AFTER UPDATE OF feed_id, record ON episodes WHEN OLD.feed_id IS NOT NEW.feed_id OR "
            + "\(detailsOf("OLD.record")) IS NOT \(detailsOf("NEW.record")) OR \(chaptersOf("OLD.record")) IS NOT \(chaptersOf("NEW.record")) BEGIN "
            + "UPDATE feed_changes SET details_generation = coalesce(details_generation, 0) + 1 WHERE feed_id = OLD.feed_id AND OLD.feed_id IS NOT NEW.feed_id; "
            + bumpDetails("NEW.feed_id") + " END"),
    ]

    static let visibilityTriggers: [(name: String, sql: String)] = [
        ("derived_hidden_insert", "CREATE TRIGGER IF NOT EXISTS derived_hidden_insert AFTER INSERT ON ntp_hidden_episodes BEGIN UPDATE episode_list_keys SET hidden = 1 WHERE id = NEW.episode_id AND hidden IS NOT 1; END"),
        ("derived_hidden_delete", "CREATE TRIGGER IF NOT EXISTS derived_hidden_delete AFTER DELETE ON ntp_hidden_episodes BEGIN UPDATE episode_list_keys SET hidden = \(hiddenSQL("OLD.episode_id")) WHERE id = OLD.episode_id AND hidden IS NOT \(hiddenSQL("OLD.episode_id")); END"),
        ("derived_hidden_update", "CREATE TRIGGER IF NOT EXISTS derived_hidden_update AFTER UPDATE OF episode_id ON ntp_hidden_episodes WHEN OLD.episode_id IS NOT NEW.episode_id BEGIN UPDATE episode_list_keys SET hidden = \(hiddenSQL("OLD.episode_id")) WHERE id = OLD.episode_id; UPDATE episode_list_keys SET hidden = 1 WHERE id = NEW.episode_id AND hidden IS NOT 1; END"),
        // Eligibility follows the subscription state (a value comparison, so a refresh's header write fires nothing) and
        // the pinned removals.
        ("derived_eligible_feed_insert", "CREATE TRIGGER IF NOT EXISTS derived_eligible_feed_insert AFTER INSERT ON feeds BEGIN \(recomputeEligibility("NEW.id")) END"),
        ("derived_eligible_feed_update", "CREATE TRIGGER IF NOT EXISTS derived_eligible_feed_update AFTER UPDATE OF id, record ON feeds WHEN OLD.id IS NOT NEW.id OR "
            + "(SELECT CASE WHEN json_valid(t) THEN json_extract(t, '$.subscriptionState') END FROM (SELECT CAST(OLD.record AS TEXT) AS t)) IS NOT "
            + "(SELECT CASE WHEN json_valid(t) THEN json_extract(t, '$.subscriptionState') END FROM (SELECT CAST(NEW.record AS TEXT) AS t)) "
            + "BEGIN \(recomputeEligibility("OLD.id")) \(recomputeEligibility("NEW.id")) END"),
        ("derived_feed_delete", "CREATE TRIGGER IF NOT EXISTS derived_feed_delete AFTER DELETE ON feeds BEGIN DELETE FROM feed_list_counts WHERE feed_id = OLD.id; DELETE FROM feed_refresh_memo WHERE feed_id = OLD.id; END"),
        ("derived_eligible_pinned_insert", "CREATE TRIGGER IF NOT EXISTS derived_eligible_pinned_insert AFTER INSERT ON pinned_feed_removals BEGIN \(recomputeEligibility("NEW.feed_id")) END"),
        ("derived_eligible_pinned_delete", "CREATE TRIGGER IF NOT EXISTS derived_eligible_pinned_delete AFTER DELETE ON pinned_feed_removals BEGIN \(recomputeEligibility("OLD.feed_id")) END"),
        ("derived_eligible_pinned_update", "CREATE TRIGGER IF NOT EXISTS derived_eligible_pinned_update AFTER UPDATE OF feed_id ON pinned_feed_removals BEGIN \(recomputeEligibility("OLD.feed_id")) \(recomputeEligibility("NEW.feed_id")) END"),
        // Only a pinned row bears on eligibility: a podcast's mapping made or moved in a unit reads none of its episodes.
        ("derived_eligible_podcast_insert", "CREATE TRIGGER IF NOT EXISTS derived_eligible_podcast_insert AFTER INSERT ON ntp_podcasts WHEN NEW.pinned_removal = 1 BEGIN \(recomputeEligibility("NEW.feed_id")) END"),
        ("derived_eligible_podcast_delete", "CREATE TRIGGER IF NOT EXISTS derived_eligible_podcast_delete AFTER DELETE ON ntp_podcasts WHEN OLD.pinned_removal = 1 BEGIN \(recomputeEligibility("OLD.feed_id")) END"),
        ("derived_eligible_podcast_update", "CREATE TRIGGER IF NOT EXISTS derived_eligible_podcast_update AFTER UPDATE OF feed_id, pinned_removal ON ntp_podcasts WHEN (OLD.pinned_removal = 1 OR NEW.pinned_removal = 1) AND (OLD.feed_id IS NOT NEW.feed_id OR OLD.pinned_removal IS NOT NEW.pinned_removal) BEGIN \(recomputeEligibility("OLD.feed_id")) \(recomputeEligibility("NEW.feed_id")) END"),
    ]

    /// A key row's contributions to its feed's visible counts, in `feed_list_counts` column order.
    static func contributions(_ row: String) -> [String] {
        let visible = "\(row).hidden = 0"
        return [visible, "\(visible) AND \(row).state = -1", "\(visible) AND \(row).state = 1",
                "\(visible) AND \(row).downloaded = 1 AND \(row).has_media = 1",
                "\(visible) AND \(row).downloaded = 1 AND \(row).has_media = 1 AND \(row).state <> 1",
                "\(visible) AND \(row).downloaded = 1", "\(visible) AND \(row).favorite = 1"]
    }

    static let countColumns = ["total", "new_count", "played", "dl_media", "dl_media_unplayed", "dl_any", "favorite"]

    /// A feed's counts row, made when missing (a feed with no key row has none and reads as zero).
    private static func ensureCounts(_ feed: String) -> String {
        "INSERT INTO feed_list_counts(feed_id, " + countColumns.joined(separator: ", ") + ") SELECT \(feed), 0, 0, 0, 0, 0, 0, 0 WHERE NOT EXISTS (SELECT 1 FROM feed_list_counts WHERE feed_id = \(feed));"
    }

    private static func adjustCounts(_ feed: String, _ sign: String, _ row: String, when condition: String = "1") -> String {
        "UPDATE feed_list_counts SET " + zip(countColumns, contributions(row)).map { "\($0) = \($0) \(sign) (\($1))" }.joined(separator: ", ")
            + " WHERE feed_id = \(feed) AND \(condition);"
    }

    /// Installed with the key triggers, so every key row ever made (by a trigger or by the fill) is counted once, when
    /// it is made: the counts always equal the key rows that exist, and are complete when the keys are. A change that
    /// leaves its contributions equal writes nothing.
    static let countTriggers: [(name: String, sql: String)] = {
        let delta = "UPDATE feed_list_counts SET " + zip(countColumns, zip(contributions("NEW"), contributions("OLD"))).map {
            "\($0) = \($0) + (\($1.0)) - (\($1.1))"
        }.joined(separator: ", ") + " WHERE feed_id = NEW.feed_id AND OLD.feed_id IS NEW.feed_id;"
        let tuple = { (row: String) in "(" + (["\(row).feed_id"] + contributions(row)).joined(separator: ", ") + ")" }
        return [
            // A hidden row contributes nothing: staging a backlog writes no counts row.
            // The fill counts the rows it makes in one statement per step (`fillBatch`), marked by `derived_fill` row 2.
            ("derived_counts_insert", "CREATE TRIGGER IF NOT EXISTS derived_counts_insert AFTER INSERT ON episode_list_keys WHEN NEW.hidden = 0 AND NOT EXISTS (SELECT 1 FROM derived_fill WHERE id = 2) BEGIN \(ensureCounts("NEW.feed_id")) \(adjustCounts("NEW.feed_id", "+", "NEW")) END"),
            ("derived_counts_delete", "CREATE TRIGGER IF NOT EXISTS derived_counts_delete AFTER DELETE ON episode_list_keys WHEN OLD.hidden = 0 BEGIN \(adjustCounts("OLD.feed_id", "-", "OLD")) END"),
            ("derived_counts_update", "CREATE TRIGGER IF NOT EXISTS derived_counts_update AFTER UPDATE OF feed_id, state, favorite, downloaded, has_media, hidden ON episode_list_keys WHEN \(tuple("OLD")) IS NOT \(tuple("NEW")) BEGIN "
                + ensureCounts("NEW.feed_id") + " " + delta + " "
                + adjustCounts("OLD.feed_id", "-", "OLD", when: "OLD.feed_id IS NOT NEW.feed_id") + " "
                + adjustCounts("NEW.feed_id", "+", "NEW", when: "OLD.feed_id IS NOT NEW.feed_id") + " END"),
        ]
    }()

    /// Every schema-21 object a migration creates, by name (tests take a library back to schema 20 with it).
    static let createdTables = ["episode_list_keys", "feed_list_counts", "library_change_sequence", "feed_refresh_memo", "derived_fill"]

    // MARK: - Migration and fill

    /// The 20 → 21 step, inside the schema transaction: objects only, no row work. A library with no episodes and an
    /// empty release ledger is complete at once; any other gets the fill marker, and its rows (and ledger indexes) are
    /// made by `fillBatch` after the graph starts. Idempotent.
    static func migrate(_ database: LibrarySQLite) throws {
        // Run again over a library that already has the derived tables (a partial schema reopened): their rows stay, and
        // only a fill that never completed is resumed.
        let existed = try database.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'episode_list_keys'") == 1
        for statement in tables { try database.execute(statement) }
        if try !database.rows("PRAGMA table_info(feed_changes)").contains(where: { $0[1].text == "details_generation" }) {
            try database.execute("ALTER TABLE feed_changes ADD COLUMN details_generation INTEGER DEFAULT 0")
        }
        for statement in indexes { try database.execute(statement) }
        for trigger in keyTriggers + visibilityTriggers + countTriggers { try database.execute(trigger.sql) }
        if existed { return }
        if try database.scalar("SELECT EXISTS (SELECT 1 FROM episodes) OR EXISTS (SELECT 1 FROM ntp_ledger)") == 0 {
            try complete(database)
        } else {
            try database.execute("INSERT INTO derived_fill(id, next_id, end_id) SELECT 1, ?, (SELECT max(id) FROM episodes) WHERE NOT EXISTS (SELECT 1 FROM derived_fill)",
                                 [.integer(.min)])
        }
    }

    /// Whether the keys and counts are complete (no fill marker).
    static func isComplete(_ database: LibrarySQLite) throws -> Bool {
        try database.scalar("SELECT EXISTS (SELECT 1 FROM derived_fill)") == 0
    }

    /// A fill step's work estimate: each episode's fixed cost (its key row, twelve index entries, its counts update) and
    /// its record's bytes (read and parsed once). Calibrated on the development Mac to keep a step near 25 ms of CPU
    /// whatever the show notes' length; a record larger than the whole budget is a step of its own.
    static let fillStepBudgetNanoseconds = 25_000_000
    static let fillRowNanoseconds = 30_000
    static let fillByteNanoseconds = 6

    /// One fill step in its own write transaction: the next episodes by ID that have no key row, as many as the step's
    /// budget allows (at most `batch`), counted as they are keyed; then each ledger index alone; then the marker's
    /// removal. Returns whether the fill is complete.
    static func fillBatch(_ database: LibrarySQLite, batch: Int) throws -> Bool {
        try database.transaction {
            guard let marker = try database.rows("SELECT next_id, coalesce(end_id, ?) FROM derived_fill WHERE id = 1", [.integer(.min)]).first,
                  let cursor = marker[0].integer, let end = marker[1].integer else {
                // No marker (or a marker of an earlier layout): complete.
                if try !isComplete(database) { try database.execute("DELETE FROM derived_fill") }
                return true
            }
            var upper: Int64?, cost = 0, missing: [Int64] = []
            for row in try database.rows("SELECT e.id, length(e.record), EXISTS (SELECT 1 FROM episode_list_keys k WHERE k.id = e.id) FROM episodes e WHERE e.id > ? AND e.id <= ? ORDER BY e.id LIMIT ?",
                                         [.integer(cursor), .integer(end), .integer(Int64(max(1, batch)))]) {
                guard let id = row[0].integer else { continue }
                cost += fillRowNanoseconds + fillByteNanoseconds * Int(row[1].integer ?? 0)
                if upper != nil && cost > fillStepBudgetNanoseconds { break }
                upper = id
                if row[2].integer == 0 { missing.append(id) }
            }
            if let upper {
                // The rows this step makes are counted together after they are made, not one trigger at a time; rows
                // writes made earlier were counted when they were made.
                try database.execute("INSERT INTO derived_fill(id) VALUES (2)")
                try database.execute(fillStatement, [.integer(cursor), .integer(upper)])
                try database.execute("DELETE FROM derived_fill WHERE id = 2")
                if !missing.isEmpty { try database.execute(countRowsStatement, [.text(ContractJSON.array(missing.map(ContractJSON.integer)).canonicalText)]) }
                try database.execute("UPDATE derived_fill SET next_id = ? WHERE id = 1", [.integer(upper)])
                return false
            }
            // An index build is one statement that scans the ledger once: each takes a step of its own (proportional to
            // the ledger, once per library).
            if let index = try ledgerIndexes.first(where: {
                try database.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = ?", [.text($0.name)]) == 0
            }) {
                try database.execute(index.sql)
                return false
            }
            try database.execute("DELETE FROM derived_fill")
            return true
        }
    }

    /// Adds the visible contributions of the key rows `?1` (a JSON array of IDs) to their feeds' counts.
    static let countRowsStatement = "INSERT INTO feed_list_counts(feed_id, " + countColumns.joined(separator: ", ") + ") SELECT k.feed_id, "
        + contributions("k").map { "sum(\($0))" }.joined(separator: ", ")
        + " FROM episode_list_keys k WHERE k.id IN (SELECT value FROM json_each(?1)) AND k.hidden = 0 GROUP BY k.feed_id"
        + " ON CONFLICT(feed_id) DO UPDATE SET " + countColumns.map { "\($0) = \($0) + excluded.\($0)" }.joined(separator: ", ")

    /// The counts rows of feeds `(?1, ?2]` from their key rows (zero for a feed with none).
    static let countStatement = "INSERT INTO feed_list_counts(feed_id, " + countColumns.joined(separator: ", ") + ") SELECT f.id, "
        + contributions("k").map { "coalesce(sum(\($0)), 0)" }.joined(separator: ", ")
        + " FROM feeds f LEFT JOIN episode_list_keys k ON k.feed_id = f.id WHERE f.id > ?1 AND f.id <= ?2"
        + " AND NOT EXISTS (SELECT 1 FROM feed_list_counts c WHERE c.feed_id = f.id) GROUP BY f.id"

    /// The key rows of episodes `(?1, ?2]` that have none, eligibility computed once per feed.
    static let fillStatement = "WITH eligible(feed_id, value) AS MATERIALIZED (SELECT id, " + eligibleSQL("feeds.id") + " FROM feeds) "
        + "INSERT INTO episode_list_keys(" + keyColumns.joined(separator: ", ") + ") SELECT e.id, e.feed_id, " + hiddenSQL("e.id")
        + ", coalesce(eligible.value, 0), " + derivedColumns.map(\.sql).joined(separator: ", ")
        // OFFSET 0 keeps the subquery whole: each record's text is made once, not once per derived column.
        + " FROM (SELECT id, feed_id, \(recordText("record")) AS r FROM episodes WHERE id > ?1 AND id <= ?2 LIMIT -1 OFFSET 0) AS e"
        + " LEFT JOIN eligible ON eligible.feed_id = e.feed_id"
        + " WHERE NOT EXISTS (SELECT 1 FROM episode_list_keys k WHERE k.id = e.id) ORDER BY e.id"

    /// A full rebuild for a write that fills an empty library at once (a database import): inside its transaction, the
    /// per-row key triggers are taken out while it writes, then every key row is made by the fill's statement and the
    /// counts installed (`rebuild`). Equivalent to the triggers (the same expressions); a rollback restores everything.
    static func suspendKeys(_ database: LibrarySQLite) throws {
        guard try database.scalar("SELECT EXISTS (SELECT 1 FROM episodes)") == 0 else { throw FeedLibraryError.invalidMutation }
        for trigger in keyTriggers where trigger.name.hasPrefix("derived_keys_") { try database.execute("DROP TRIGGER IF EXISTS \(trigger.name)") }
        for trigger in countTriggers { try database.execute("DROP TRIGGER IF EXISTS \(trigger.name)") }
        try database.execute("DELETE FROM episode_list_keys")
        try database.execute("DELETE FROM feed_list_counts")
        try database.execute("INSERT INTO derived_fill(id, next_id) SELECT 1, ? WHERE NOT EXISTS (SELECT 1 FROM derived_fill)", [.integer(.min)])
    }

    /// The end of `suspendKeys`: every episode keyed, the key triggers back, the counts complete.
    static func rebuild(_ database: LibrarySQLite) throws {
        try database.execute(fillStatement, [.integer(.min), .integer(.max)])
        for trigger in keyTriggers { try database.execute(trigger.sql) }
        try complete(database)
    }

    /// All at once (a library with no episodes, or a rebuild): counts from the keys, their triggers, the ledger indexes,
    /// and the marker's removal, in the caller's transaction.
    static func complete(_ database: LibrarySQLite) throws {
        for index in ledgerIndexes { try database.execute(index.sql) }
        try database.execute("DELETE FROM feed_list_counts")
        try database.execute(countStatement, [.integer(.min), .integer(.max)])
        for trigger in countTriggers { try database.execute(trigger.sql) }
        try database.execute("DELETE FROM derived_fill")
    }

    // MARK: - Verification (tests and DEBUG)

    /// Rows whose stored keys differ from the derivation of their records, missing or orphan key rows (once complete),
    /// and feeds whose counts differ from their keys (once counts exist): empty when the derived data is exact.
    static func discrepancies(_ database: LibrarySQLite) throws -> [String] {
        var found: [String] = []
        let complete = try isComplete(database)
        let recomputed = "SELECT e.id AS id, e.feed_id AS feed_id, \(hiddenSQL("e.id")) AS hidden, \(eligibleSQL("e.feed_id")) AS feed_eligible, "
            + derivedColumns.map { "\($0.sql) AS \($0.name)" }.joined(separator: ", ")
            + " FROM (SELECT id, feed_id, \(recordText("record")) AS r FROM episodes) AS e"
        let differing = "SELECT k.id FROM episode_list_keys k JOIN (\(recomputed)) d ON d.id = k.id WHERE ("
            + keyColumns.map { "k.\($0)" }.joined(separator: ", ") + ") IS NOT (" + keyColumns.map { "d.\($0)" }.joined(separator: ", ") + ") ORDER BY k.id LIMIT 5"
        found += try database.rows(differing).compactMap { $0[0].integer.map { "keys differ for episode \($0)" } }
        found += try database.rows("SELECT id FROM episode_list_keys WHERE id NOT IN (SELECT id FROM episodes) ORDER BY id LIMIT 5")
            .compactMap { $0[0].integer.map { "orphan key row \($0)" } }
        if complete {
            found += try database.rows("SELECT id FROM episodes WHERE id NOT IN (SELECT id FROM episode_list_keys) ORDER BY id LIMIT 5")
                .compactMap { $0[0].integer.map { "missing key row \($0)" } }
        }
        // The counts always equal the key rows that exist (they are counted as they are made).
        if try database.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'derived_counts_%'") == Int64(countTriggers.count) {
            let grouped = "SELECT feed_id, " + zip(countColumns, contributions("k")).map { "sum(\($1)) AS g_\($0)" }.joined(separator: ", ")
                + " FROM episode_list_keys k GROUP BY feed_id"
            let compare = "SELECT coalesce(c.feed_id, g.feed_id) FROM feed_list_counts c FULL JOIN (\(grouped)) AS g ON g.feed_id = c.feed_id WHERE ("
                + countColumns.map { "coalesce(c.\($0), 0)" }.joined(separator: ", ") + ") IS NOT ("
                + countColumns.map { "coalesce(g.g_\($0), 0)" }.joined(separator: ", ") + ") LIMIT 5"
            found += try database.rows(compare).compactMap { $0[0].integer.map { "counts differ for feed \($0)" } }
        }
        return found
    }
}
