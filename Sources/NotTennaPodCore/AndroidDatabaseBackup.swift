import Foundation
import SQLite3

/// Android AntennaPod 3.12.1 `Antennapod.db` backup (source `DatabaseExporter` copies this file at
/// `PodDBAdapter.VERSION`). The iOS library stores different internals, so a backup is generated with
/// the source's verbatim fresh-install schema and an explicit column mapping.
public enum AndroidDatabaseBackup {
    public static let version: Int64 = 3_110_000

    public struct Source: Sendable {
        public var feeds: [LibraryFeed]
        /// Queue order; each entry is (episode id, feed id).
        public var queue: [QueueEntry]
        /// Newest-first entries as shown in the Download log (feed refresh and media attempts).
        public var downloadLog: [DownloadLogEntry]
        public var credentials: [Int64: FeedCredentials]
        public var speeds: PlaybackSpeedPreferences
        /// The library's statistics units by local episode ID (schema 20; PROTOCOL §11.5): each is written
        /// back as the stock Android row it came from.
        public var statisticsUnits: [Int64: [LibraryStatisticsUnit]]
        /// A server library promises that no unit was played later than its episode: the writer checks
        /// it and refuses a file that breaks it. A standalone library makes no such promise and is never refused.
        public var checksUnitLastPlayed: Bool
        public struct QueueEntry: Sendable, Equatable {
            public var episodeID: Int64, feedID: Int64
            public init(episodeID: Int64, feedID: Int64) { self.episodeID = episodeID; self.feedID = feedID }
        }
        public init(feeds: [LibraryFeed], queue: [QueueEntry], downloadLog: [DownloadLogEntry] = [],
                    credentials: [Int64: FeedCredentials] = [:], speeds: PlaybackSpeedPreferences = .init(),
                    statisticsUnits: [Int64: [LibraryStatisticsUnit]] = [:], checksUnitLastPlayed: Bool = false) {
            self.feeds = feeds; self.queue = queue; self.downloadLog = downloadLog
            self.credentials = credentials; self.speeds = speeds
            self.statisticsUnits = statisticsUnits; self.checksUnitLastPlayed = checksUnitLastPlayed
        }
    }

    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        case sqlite(code: Int32, message: String)
        case destinationExists
        case verification(String)
        /// A server library's statistics unit was played later than its episode: never a fabricated time.
        /// The existing export error with no detail of its own (no new wording); the cause and the episode go to the
        /// server library's sync log (`LibraryExportSource.databaseData`).
        case unitAfterEpisode(episodeID: Int64)

        /// Source exporter messages are shown verbatim ("Export error" / automatic backup error).
        public var errorDescription: String? {
            switch self {
            case .sqlite(_, let message): message
            case .destinationExists: "Unable to create export file"
            case .verification(let message): message
            case .unitAfterEpisode: ""
            }
        }
    }

    /// The item IDs of the file (PROTOCOL §11.5): unit rows take item and media IDs above every local episode ID,
    /// and an episode with units has its own item row above its units', so it stays the state row on reimport (the
    /// server's import takes the most recently played row, on a tie the higher item ID). Its media row keeps the local episode ID,
    /// which the download log names. Every reference to the episode's item uses `item[episode]`.
    struct ItemIDs {
        var item: [Int64: Int64] = [:]
        /// Per episode, its units with their item (and media) IDs, in unit order.
        var units: [Int64: [(id: Int64, unit: LibraryStatisticsUnit)]] = [:]

        init(feeds: [LibraryFeed], units: [Int64: [LibraryStatisticsUnit]]) {
            var next = feeds.flatMap(\.episodes).map(\.id).max().map { $0 + 1 } ?? 1
            for feed in feeds {
                for episode in feed.episodes {
                    guard let list = units[episode.id], !list.isEmpty else { item[episode.id] = episode.id; continue }
                    self.units[episode.id] = list.sorted { $0.unitID < $1.unitID }.map { unit in
                        defer { next += 1 }
                        return (next, unit)
                    }
                    item[episode.id] = next
                    next += 1
                }
            }
        }
    }

    /// `PodDBAdapter.java:146–252` fresh-install DDL, in `onCreate` order, plus the framework's
    /// `android_metadata` table present in real files.
    static let schema = [
        "CREATE TABLE android_metadata (locale TEXT)",
        "CREATE TABLE Feeds (id INTEGER PRIMARY KEY AUTOINCREMENT ,title TEXT,custom_title TEXT,file_url TEXT,download_url TEXT,downloaded INTEGER,link TEXT,description TEXT,payment_link TEXT,last_update TEXT,language TEXT,author TEXT,image_url TEXT,type TEXT,feed_identifier TEXT,auto_download INTEGER DEFAULT 1,username TEXT,password TEXT,include_filter TEXT DEFAULT '',exclude_filter TEXT DEFAULT '',minimal_duration_filter INTEGER DEFAULT -1,keep_updated INTEGER DEFAULT 1,is_paged INTEGER DEFAULT 0,next_page_link TEXT,hide TEXT,sort_order TEXT,last_update_failed INTEGER DEFAULT 0,auto_delete_action INTEGER DEFAULT 0,feed_playback_speed REAL DEFAULT -1.0,feed_skip_silence INTEGER DEFAULT 1,feed_volume_adaption INTEGER DEFAULT 0,tags TEXT,feed_skip_intro INTEGER DEFAULT 0,feed_skip_ending INTEGER DEFAULT 0,episode_notification INTEGER DEFAULT 0,state INTEGER DEFAULT 0,new_episodes_action INTEGER DEFAULT 0)",
        "CREATE TABLE FeedItems (id INTEGER PRIMARY KEY AUTOINCREMENT ,title TEXT,pubDate INTEGER,read INTEGER,link TEXT,description TEXT,payment_link TEXT,media INTEGER,feed INTEGER,has_simple_chapters INTEGER,item_identifier TEXT,image_url TEXT,auto_download INTEGER,podcastindex_chapter_url TEXT,podcastindex_transcript_type TEXT,podcastindex_transcript_url TEXT,social_interact_url TEXT)",
        "CREATE TABLE FeedMedia (id INTEGER PRIMARY KEY AUTOINCREMENT ,duration INTEGER,file_url TEXT,download_url TEXT,downloaded INTEGER,position INTEGER,filesize INTEGER,mime_type TEXT,playback_completion_date INTEGER,feeditem INTEGER,played_duration INTEGER,has_embedded_picture INTEGER,last_played_time INTEGER)",
        "CREATE TABLE DownloadLog (id INTEGER PRIMARY KEY AUTOINCREMENT ,feedfile INTEGER,feedfile_type INTEGER,reason INTEGER,successful INTEGER,completion_date INTEGER,reason_detailed TEXT,title TEXT)",
        "CREATE TABLE Queue(id INTEGER PRIMARY KEY,feeditem INTEGER,feed INTEGER)",
        "CREATE TABLE SimpleChapters (id INTEGER PRIMARY KEY AUTOINCREMENT ,title TEXT,start INTEGER,feeditem INTEGER,link TEXT,image_url TEXT)",
        "CREATE TABLE Favorites(id INTEGER PRIMARY KEY,feeditem INTEGER,feed INTEGER)",
        "CREATE INDEX FeedItems_feed ON FeedItems (feed)",
        "CREATE INDEX FeedItems_pubDate ON FeedItems (pubDate)",
        "CREATE INDEX FeedItems_read ON FeedItems (read)",
        "CREATE INDEX FeedMedia_feeditem ON FeedMedia (feeditem)",
        "CREATE INDEX Queue_feeditem ON Queue (feeditem)",
        "CREATE INDEX SimpleChapters_feeditem ON SimpleChapters (feeditem)",
    ]

    /// Writes a new self-contained backup file at `url` (which must not exist), then verifies it like
    /// `DatabaseExporter.exportToStream` (integrity and exact `user_version`).
    public static func write(_ source: Source, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.destinationExists }
        let db = try BackupSQLite(url: url, create: true)
        do {
            try db.execute("PRAGMA page_size = 4096")
            try db.execute("PRAGMA encoding = 'UTF-8'")
            try db.execute("PRAGMA journal_mode = DELETE")
            try db.execute("BEGIN")
            for statement in schema { try db.execute(statement) }
            try db.execute("INSERT INTO android_metadata VALUES (?)", [.text("en_US")])
            try insertRows(source, into: db)
            try db.execute("PRAGMA user_version = \(version)")
            try db.execute("COMMIT")
            guard try db.text("PRAGMA integrity_check") == "ok" else { throw Failure.verification("integrity_check failed") }
            let written = try db.integer("PRAGMA user_version")
            guard written == version else {
                throw Failure.verification("Database version mismatch. Expected: \(version), found: \(written)")
            }
            try db.close()
        } catch {
            try? db.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func insertRows(_ source: Source, into db: BackupSQLite) throws {
        let ids = ItemIDs(feeds: source.feeds, units: source.statisticsUnits)
        func itemID(_ episode: Int64) -> Int64 { ids.item[episode] ?? episode }
        for feed in source.feeds {
            let credentials = source.credentials[feed.id]
            let speed = source.speeds.feeds[feed.id].map { Double($0) } ?? -1.0
            let silence = (source.speeds.silence.feeds[feed.id] ?? .global).rawValue
            let tags = feed.tags.isEmpty ? "#root" : feed.tags.joined(separator: "\u{1E}")
            let metadata = feed.metadata
            var row: [BackupSQLite.Value] = [.integer(feed.id), .text(metadata.title), .text(feed.customTitle), .null, .text(feed.source)]
            row += [.integer(feed.lastRefreshAttempt.map(milliseconds) ?? 0), .text(metadata.link), .text(metadata.description)]
            row += [.text(paymentLinks(metadata.funding)), .text(feed.validator), .text(metadata.language), .text(metadata.author)]
            row += [.text(metadata.imageURL), .text(feed.sourceFeedType), .text(metadata.identifier)]
            row += [.integer(Int64(feed.autoDownload.rawValue)), .text(credentials?.username), .text(credentials?.password)]
            row += [.text(feed.automaticDownloadFilter.include), .text(feed.automaticDownloadFilter.exclude)]
            row += [.integer(Int64(feed.automaticDownloadFilter.minimumDurationSeconds)), .integer(feed.keepUpdated ? 1 : 0)]
            row += [.integer(metadata.isPaged ? 1 : 0), .text(metadata.nextPageURL)]
            row += [.text((feed.episodeFilterValues ?? []).joined(separator: ",")), .text(feed.episodeSortOrderCode.map { String($0) })]
            row += [.integer(feed.lastUpdateFailed ? 1 : 0), .integer(Int64(feed.autoDelete.rawValue)), .real(speed)]
            row += [.integer(Int64(silence)), .integer(Int64(feed.volumeAdaptation.rawValue)), .text(tags)]
            row += [.integer(Int64(feed.skipPreferences.introSeconds)), .integer(Int64(feed.skipPreferences.endingSeconds))]
            row += [.integer(feed.showEpisodeNotification ? 1 : 0), .integer(Int64(feed.subscriptionState.rawValue))]
            row += [.integer(Int64(feed.newEpisodesAction.rawValue))]
            try db.execute("INSERT INTO Feeds (id,title,custom_title,file_url,download_url,downloaded,link,description,payment_link,last_update,language,author,image_url,type,feed_identifier,auto_download,username,password,include_filter,exclude_filter,minimal_duration_filter,keep_updated,is_paged,next_page_link,hide,sort_order,last_update_failed,auto_delete_action,feed_playback_speed,feed_skip_silence,feed_volume_adaption,tags,feed_skip_intro,feed_skip_ending,episode_notification,state,new_episodes_action) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", row)
            for episode in feed.episodes {
                let details = episode.details, state = episode.userState
                // The episode's statistics units first, as the rows they were: in this feed, with the
                // episode's title, publication date, link and GUID, their own played flag (never new), duration,
                // position, played time, last played and history; not downloaded, in no queue or favorites, no chapters.
                for (unitID, unit) in ids.units[episode.id] ?? [] {
                    if source.checksUnitLastPlayed, unit.lastPlayedMilliseconds > state.lastPlayedTimeMilliseconds {
                        throw Failure.unitAfterEpisode(episodeID: episode.id)
                    }
                    try db.execute("INSERT INTO FeedItems (id,title,pubDate,read,link,description,payment_link,media,feed,has_simple_chapters,item_identifier,image_url,auto_download,podcastindex_chapter_url,podcastindex_transcript_type,podcastindex_transcript_url,social_interact_url) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
                        .integer(unitID), .text(details.title), .integer(details.publicationDate.map(milliseconds) ?? 0),
                        .integer(unit.played ? 1 : 0), .text(details.link), .null, .null, .null, .integer(feed.id), .integer(0),
                        .text(details.identifier), .null, .integer(0), .null, .null, .null, .null,
                    ])
                    try db.execute("INSERT INTO FeedMedia (id,duration,file_url,download_url,downloaded,position,filesize,mime_type,playback_completion_date,feeditem,played_duration,has_embedded_picture,last_played_time) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", [
                        .integer(unitID), .integer(clampedInt32(unit.durationMilliseconds)), .null, .text(details.media?.url), .integer(0),
                        .integer(clampedInt32(unit.positionMilliseconds)), .integer(0), .text(details.media?.mimeType),
                        .integer(unit.historyMilliseconds ?? 0), .integer(unitID), .integer(clampedInt32(unit.playedMilliseconds)),
                        .integer(0), .integer(unit.lastPlayedMilliseconds),
                    ])
                }
                let item: [BackupSQLite.Value] = [
                    .integer(itemID(episode.id)), .text(details.title), .integer(details.publicationDate.map(milliseconds) ?? 0),
                    .integer(Int64(state.playState.rawValue)), .text(details.link), .text(details.description),
                    .text(details.paymentLink), .null, .integer(feed.id), .integer(details.chapters != nil ? 1 : 0),
                    .text(details.identifier), .text(details.imageURL), .integer(state.autoDownloadEnabled ? 1 : 0),
                    .text(details.chapterURL), .text(details.transcript.map { $0.format.rawValue }),
                    .text(details.transcript?.url), .text(details.socialInteractionURL),
                ]
                try db.execute("INSERT INTO FeedItems (id,title,pubDate,read,link,description,payment_link,media,feed,has_simple_chapters,item_identifier,image_url,auto_download,podcastindex_chapter_url,podcastindex_transcript_type,podcastindex_transcript_url,social_interact_url) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", item)
                if let media = details.media {
                    // iOS files never exist on Android; export the repaired "not downloaded" state.
                    let row: [BackupSQLite.Value] = [
                        .integer(episode.id), .integer(Int64(media.durationMilliseconds)), .null, .text(media.url), .integer(0),
                        .integer(Int64(state.positionMilliseconds)), .integer(media.size), .text(media.mimeType),
                        .integer(state.lastPlayedHistoryMilliseconds ?? 0), .integer(itemID(episode.id)),
                        .integer(clampedInt32(state.playedDurationMilliseconds)), .integer(0),
                        .integer(state.lastPlayedTimeMilliseconds),
                    ]
                    try db.execute("INSERT INTO FeedMedia (id,duration,file_url,download_url,downloaded,position,filesize,mime_type,playback_completion_date,feeditem,played_duration,has_embedded_picture,last_played_time) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", row)
                }
                for chapter in details.chapters ?? [] {
                    try db.execute("INSERT INTO SimpleChapters (title,start,feeditem,link,image_url) VALUES (?,?,?,?,?)",
                                   [.text(chapter.title), .integer(chapter.startMilliseconds), .integer(itemID(episode.id)),
                                    .text(chapter.link), .text(chapter.imageURL)])
                }
            }
            for episode in feed.episodes.sorted(by: { $0.id < $1.id }) where episode.userState.isFavorite {
                try db.execute("INSERT INTO Favorites (feeditem,feed) VALUES (?,?)", [.integer(itemID(episode.id)), .integer(feed.id)])
            }
        }
        for (position, entry) in source.queue.enumerated() {
            try db.execute("INSERT INTO Queue (id,feeditem,feed) VALUES (?,?,?)",
                           [.integer(Int64(position)), .integer(itemID(entry.episodeID)), .integer(entry.feedID)])
        }
        // Source reads newest first by completion date; insert oldest first so ids ascend with time.
        for entry in source.downloadLog.reversed() {
            var (feedfile, type): (Int64, Int64) = entry.episodeID.map { ($0, 2) } ?? (entry.feedID, 0)
            var completion: BackupSQLite.Value = .integer(milliseconds(entry.date))
            if case .imported(let log) = entry.result {
                (feedfile, type) = (log.feedfile, Int64(log.type))
                if log.completionMissing == true { completion = .null }
            }
            try db.execute("INSERT INTO DownloadLog (feedfile,feedfile_type,reason,successful,completion_date,reason_detailed,title) VALUES (?,?,?,?,?,?,?)", [
                .integer(feedfile), .integer(type), .integer(reasonCode(entry.result)), .integer(entry.isSuccessful ? 1 : 0),
                completion, .text(detail(entry.result)), .text(entry.title),
            ])
        }
    }

    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    static func clampedInt32(_ value: Int64) -> Int64 { min(max(value, Int64(Int32.min)), Int64(Int32.max)) }

    /// `FeedFunding.getPaymentLinksAsString`: url U+001F content, joined by U+001E; NULL when absent.
    static func paymentLinks(_ funding: [FeedFunding]) -> String? {
        funding.isEmpty ? nil : funding.map { ($0.url ?? "null") + "\u{1F}" + $0.content }.joined(separator: "\u{1E}")
    }

    private static func detail(_ result: DownloadLogEntry.Result) -> String? {
        switch result { case .feed(let log): log.detail; case .media(let log): log.detail; case .imported(let log): log.detail }
    }

    /// `DownloadError` codes (source `DownloadError.java`); only defined codes are written, since an
    /// unknown code throws on Android read.
    static func reasonCode(_ result: DownloadLogEntry.Result) -> Int64 {
        switch result {
        case .imported(let log): return Int64(log.reason)
        case .feed(let log):
            switch log.kind {
            case .success: return 0
            case .duplicate: return 22
            case .failure(let failure):
                switch failure {
                case .malformedURL: return 4
                case .unauthorized: return 14
                case .forbidden: return 16
                case .notFound: return 20
                case .httpStatus: return 9
                case .tooManyRedirects, .io: return 5
                case .connection: return 3
                case .unknownHost: return 11
                case .certificate: return 21
                case .blocked: return 18
                case .wrongSize: return 17
                case .unsupportedFeed: return 2
                case .websiteInsteadOfFeed: return 19
                case .parsing, .missingFeedTitle, .missingEpisodeTitle: return 1
                }
            }
        case .media(let log):
            guard let failure = log.failure else { return 0 }
            switch failure {
            case .http(401): return 14
            case .http(403): return 16
            case .http(404), .http(410): return 20
            case .http: return 9
            case .malformedURL: return 4
            case .fileType: return 15
            case .invalidRange, .tooManyFollowUps, .io: return 5
            case .connection: return 3
            case .unknownHost: return 11
            case .certificate: return 21
            case .blocked: return 18
            case .database: return 13
            case .wrongSize: return 17
            case .notEnoughSpace: return 10
            }
        }
    }
}

/// Minimal SQLite access for Android backup files (never the iOS library schema).
final class BackupSQLite {
    enum Value { case integer(Int64), real(Double), text(String?), null }
    private var handle: OpaquePointer?

    init(url: URL, create: Bool, writable: Bool = false) throws {
        var connection: OpaquePointer?
        let flags = create ? (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) : writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY
        let status = sqlite3_open_v2(url.path, &connection, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let connection { sqlite3_close_v2(connection) }
            throw AndroidDatabaseBackup.Failure.sqlite(code: status, message: message)
        }
        handle = connection
    }
    deinit { if let handle { sqlite3_close_v2(handle) } }

    func close() throws {
        guard let handle else { return }
        let status = sqlite3_close_v2(handle); self.handle = nil
        guard status == SQLITE_OK else { throw AndroidDatabaseBackup.Failure.sqlite(code: status, message: "close failed") }
    }

    func execute(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW { status = sqlite3_step(statement) }
        guard status == SQLITE_DONE else { throw error(status) }
    }

    func rows(_ sql: String, _ values: [Value] = []) throws -> [[Value]] {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        var result: [[Value]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw error(status) }
            result.append((0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: .real(sqlite3_column_double(statement, column))
                case SQLITE_NULL: .null
                default: .text(sqlite3_column_text(statement, column).map { String(cString: $0) })
                }
            })
        }
    }

    func columnNames(_ sql: String) throws -> [String] {
        let statement = try prepare(sql, []); defer { sqlite3_finalize(statement) }
        return (0..<sqlite3_column_count(statement)).map { String(cString: sqlite3_column_name(statement, $0)) }
    }

    func integer(_ sql: String) throws -> Int64 {
        guard case .integer(let value) = try rows(sql).first?.first else { throw AndroidDatabaseBackup.Failure.verification(sql) }
        return value
    }
    func text(_ sql: String) throws -> String? {
        guard case .text(let value) = try rows(sql).first?.first else { return nil }
        return value
    }

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer? {
        guard let handle else { throw AndroidDatabaseBackup.Failure.sqlite(code: SQLITE_MISUSE, message: "closed") }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK else { throw error(status) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1), bound: Int32
            switch value {
            case .integer(let number): bound = sqlite3_bind_int64(statement, index, number)
            case .real(let number): bound = sqlite3_bind_double(statement, index, number)
            case .text(let string?): bound = sqlite3_bind_text(statement, index, string, -1, transient)
            case .text(nil), .null: bound = sqlite3_bind_null(statement, index)
            }
            guard bound == SQLITE_OK else { sqlite3_finalize(statement); throw error(bound) }
        }
        return statement
    }
    private func error(_ status: Int32) -> AndroidDatabaseBackup.Failure {
        .sqlite(code: status, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error")
    }
}
