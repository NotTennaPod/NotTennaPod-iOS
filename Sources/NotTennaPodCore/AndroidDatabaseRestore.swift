import Foundation
import SQLite3

/// Reads a real Android AntennaPod `Antennapod.db` backup (source `DatabaseExporter.importBackup`)
/// into native library values.
///
/// Unlike the source, which deletes the live database before installing the file, the backup is
/// validated completely on a private copy first; nothing here touches the live library. Older files
/// are upgraded with a port of the source `DBUpgrader` SQL, then every table is read by column name
/// with Android cursor semantics (NULL integers read as 0).
public enum AndroidDatabaseRestore {
    /// A validated, fully mapped backup.
    public struct Library: Sendable, Equatable {
        public var feeds: [LibraryFeed]
        /// Queue order (episode ids).
        public var queue: [Int64]
        public var credentials: [Int64: FeedCredentials]
        public var feedSpeeds: [Int64: Float]
        public var feedSilence: [Int64: PlaybackSilencePreference]
        /// Oldest first.
        public var downloadLog: [ImportedDownloadLog]
        /// Rows Android would never show (orphans, duplicates) or values it cannot read, by reason.
        public var skipped: [String: Int]
        public var sourceVersion: Int64
    }

    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        /// Source `import_no_downgrade`; the app shows its localized text.
        case newerVersion(Int64)
        /// Anything Android would fail on or silently destroy data with. The message
        /// follows the source style of showing the underlying exception text.
        case invalid(String)

        public var errorDescription: String? {
            switch self {
            case .newerVersion(let version): "Database version \(version) is newer than \(AndroidDatabaseBackup.version)"
            case .invalid(let message): message
            }
        }
    }

    static let requiredColumns: [String: [String]] = [
        "Feeds": ["id", "title", "custom_title", "download_url", "downloaded", "link", "description", "payment_link",
                  "last_update", "language", "author", "image_url", "type", "feed_identifier", "auto_download", "username",
                  "password", "include_filter", "exclude_filter", "minimal_duration_filter", "keep_updated", "is_paged",
                  "next_page_link", "hide", "sort_order", "last_update_failed", "auto_delete_action", "feed_playback_speed",
                  "feed_skip_silence", "feed_volume_adaption", "tags", "feed_skip_intro", "feed_skip_ending",
                  "episode_notification", "state", "new_episodes_action"],
        "FeedItems": ["id", "title", "pubDate", "read", "link", "description", "payment_link", "feed", "has_simple_chapters",
                      "item_identifier", "image_url", "auto_download", "podcastindex_chapter_url",
                      "podcastindex_transcript_type", "podcastindex_transcript_url", "social_interact_url"],
        "FeedMedia": ["id", "duration", "file_url", "download_url", "downloaded", "position", "filesize", "mime_type",
                      "playback_completion_date", "feeditem", "played_duration", "has_embedded_picture", "last_played_time"],
        "DownloadLog": ["id", "feedfile", "feedfile_type", "reason", "successful", "completion_date", "reason_detailed", "title"],
        "Queue": ["id", "feeditem", "feed"],
        "SimpleChapters": ["id", "title", "start", "feeditem", "link", "image_url"],
        "Favorites": ["id", "feeditem", "feed"],
    ]

    /// Copies `url` into `staging` (a private directory the caller owns and removes), validates,
    /// upgrades and maps it. Throws `Failure` for any unusable file; `staging` holds only the copy.
    public static func read(_ url: URL, staging: URL) throws -> Library {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let copy = staging.appendingPathComponent("Antennapod.db")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: url, to: copy)
        let header = (try? FileHandle(forReadingFrom: copy).read(upToCount: 16)) ?? Data()
        // SQLITE_NOTADB text, as Android's SQLiteDatabaseCorruptException reports it.
        guard header == Data("SQLite format 3\0".utf8) else { throw Failure.invalid("file is not a database") }
        let db: BackupSQLite
        do { db = try BackupSQLite(url: copy, create: false, writable: true) }
        catch { throw Failure.invalid(message(error)) }
        defer { try? db.close() }
        do {
            // A WAL-mode export (1.7 era) or stray journal is converted on the private copy only.
            try db.execute("PRAGMA journal_mode = DELETE")
            let integrity = try db.rows("PRAGMA integrity_check").compactMap { row -> String? in
                if case .text(let text) = row.first { return text } else { return nil }
            }
            // SQLITE_CORRUPT text, as Android reports corruption.
            guard integrity == ["ok"] else { throw Failure.invalid("database disk image is malformed") }
            let version = try db.integer("PRAGMA user_version")
            guard version <= AndroidDatabaseBackup.version else { throw Failure.newerVersion(version) }
            guard version >= 1 else { throw Failure.invalid("Unsupported database version: \(version)") }
            if version < AndroidDatabaseBackup.version {
                try db.execute("BEGIN")
                try AndroidDatabaseUpgrader.upgrade(db, from: version)
                try db.execute("COMMIT")
            }
            try validateColumns(db)
            var library = try map(db)
            library.sourceVersion = version
            return library
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.invalid(message(error))
        }
    }

    static func message(_ error: Error) -> String {
        if case .sqlite(_, let message) = error as? AndroidDatabaseBackup.Failure { return message }
        if case .verification(let message) = error as? AndroidDatabaseBackup.Failure { return message }
        return error.localizedDescription
    }

    private static func validateColumns(_ db: BackupSQLite) throws {
        for (table, columns) in requiredColumns.sorted(by: { $0.key < $1.key }) {
            let present = Set(try db.rows("SELECT name FROM pragma_table_info(?)", [.text(table)]).compactMap { row -> String? in
                if case .text(let name) = row.first { return name } else { return nil }
            })
            guard !present.isEmpty else { throw Failure.invalid("no such table: \(table)") }
            if let missing = columns.first(where: { !present.contains($0) }) {
                throw Failure.invalid("no such column: \(table).\(missing)")
            }
        }
    }

    // MARK: - Mapping

    private static func map(_ db: BackupSQLite) throws -> Library {
        var skipped: [String: Int] = [:]
        func skip(_ reason: String) { skipped[reason, default: 0] += 1 }
        var feeds: [LibraryFeed] = [], credentials: [Int64: FeedCredentials] = [:]
        var speeds: [Int64: Float] = [:], silence: [Int64: PlaybackSilencePreference] = [:]
        var feedIndex: [Int64: Int] = [:]

        for row in try db.named("SELECT * FROM Feeds ORDER BY id") {
            let id = row.long("id")
            var metadata = ParsedFeed(format: row.string("type") == "atom" ? .atom : .rss)
            metadata.title = row.string("title"); metadata.link = row.string("link")
            metadata.description = row.string("description"); metadata.language = row.string("language")
            metadata.author = row.string("author"); metadata.identifier = row.string("feed_identifier")
            metadata.imageURL = row.string("image_url"); metadata.funding = funding(row.string("payment_link"))
            metadata.isPaged = row.int("is_paged") > 0; metadata.nextPageURL = row.string("next_page_link")
            var feed = LibraryFeed(id: id, source: row.string("download_url") ?? "", metadata: metadata, episodes: [])
            if !["rss", "atom"].contains(row.string("type") ?? "") { feed.markImportedPlaceholder() }
            feed.customTitle = row.string("custom_title")
            let attempt = row.long("downloaded")
            feed.lastRefreshAttempt = attempt == 0 ? nil : Date(timeIntervalSince1970: Double(attempt) / 1000)
            feed.validator = row.string("last_update")
            feed.autoDownload = FeedAutoDownload(storedValue: Int(row.int("auto_download")))
            feed.keepUpdated = row.int("keep_updated") > 0
            feed.lastUpdateFailed = row.int("last_update_failed") > 0
            feed.showEpisodeNotification = row.int("episode_notification") > 0
            feed.automaticDownloadFilter = .init(include: row.string("include_filter") ?? "",
                exclude: row.string("exclude_filter") ?? "", minimumDurationSeconds: Int(row.int("minimal_duration_filter")))
            if let hide = row.string("hide"), !hide.isEmpty { feed.episodeFilterValues = hide.components(separatedBy: ",") }
            if let code = row.string("sort_order"), !code.isEmpty {
                // Unknown or inter-feed codes throw in SortOrder.fromCodeString (default order).
                if let value = Int(code), FeedEpisodeSortOrder(rawValue: value) != nil { feed.episodeSortOrderCode = value }
                else { skip("Feeds.sort_order unsupported") }
            }
            // FeedPreferences.AutoDeleteAction.fromCode: unknown → NEVER.
            feed.autoDelete = FeedAutoDelete(rawValue: Int(row.int("auto_delete_action"))) ?? .never
            if let volume = FeedVolumeAdaptation(rawValue: Int(row.int("feed_volume_adaption"))) { feed.volumeAdaptation = volume }
            else { skip("Feeds.feed_volume_adaption unsupported") }
            if let tags = row.string("tags"), !tags.isEmpty {
                // FeedPreferencesCursor: String.split drops trailing empty strings.
                var parts = tags.components(separatedBy: "\u{1E}")
                while parts.last?.isEmpty == true { parts.removeLast() }
                feed.tags = parts
            }
            feed.skipPreferences = .init(introSeconds: row.int("feed_skip_intro"), endingSeconds: row.int("feed_skip_ending"))
            if let state = FeedSubscriptionState(rawValue: Int(row.int("state"))) { feed.subscriptionState = state }
            else { skip("Feeds.state unsupported") }
            feed.newEpisodesAction = NewEpisodesAction(storedValue: Int(row.int("new_episodes_action")))
            let speed = row.double("feed_playback_speed")
            if speed > 0, speed.isFinite { speeds[id] = Float(speed) }
            else if speed != -1 { skip("Feeds.feed_playback_speed unsupported") }
            // FeedPreferences.SkipSilence.fromCode: unknown → GLOBAL (absent).
            let skipSilence = PlaybackSilencePreference(rawValue: Int(row.int("feed_skip_silence"))) ?? .global
            if skipSilence != .global { silence[id] = skipSilence }
            if row.string("username") != nil || row.string("password") != nil {
                credentials[id] = .init(username: row.string("username"), password: row.string("password"))
            }
            feedIndex[id] = feeds.count
            feeds.append(feed)
        }

        // Every item joined with its lowest-id media row (PDA:349–350 LEFT JOIN).
        var media: [Int64: NamedRow] = [:], mediaOwner: [Int64: Int64] = [:]
        for row in try db.named("SELECT * FROM FeedMedia ORDER BY id") {
            let item = row.long("feeditem")
            mediaOwner[row.long("id")] = item
            if media[item] == nil { media[item] = row } else { skip("FeedMedia duplicate for item") }
        }
        var chapters: [Int64: [ParsedChapter]] = [:]
        for row in try db.named("SELECT * FROM SimpleChapters ORDER BY id") {
            chapters[row.long("feeditem"), default: []].append(.init(startMilliseconds: row.long("start"),
                title: row.string("title"), link: row.string("link"), imageURL: row.string("image_url")))
        }
        let favorites = Set(try db.named("SELECT feeditem FROM Favorites").map { $0.long("feeditem") })
        var episodeFeed: [Int64: Int64] = [:]
        for row in try db.named("SELECT * FROM FeedItems ORDER BY id") {
            let id = row.long("id"), feedID = row.long("feed")
            guard let index = feedIndex[feedID] else { skip("FeedItems without feed"); continue }
            guard id > 0 else { skip("FeedItems invalid id"); continue }
            var details = ParsedEpisode()
            details.identifier = row.string("item_identifier"); details.title = row.string("title")
            details.description = row.string("description"); details.link = row.string("link")
            details.publicationDate = Date(timeIntervalSince1970: Double(row.long("pubDate")) / 1000)
            details.imageURL = row.string("image_url"); details.paymentLink = row.string("payment_link")
            details.chapterURL = row.string("podcastindex_chapter_url")
            details.socialInteractionURL = row.string("social_interact_url")
            if let url = row.string("podcastindex_transcript_url") {
                if let format = FeedTranscript.Format(mimeType: row.string("podcastindex_transcript_type") ?? "") {
                    details.transcript = FeedTranscript(format: format, url: url)
                } else { skip("FeedItems transcript type unsupported") }
            }
            let hasChapters = row.int("has_simple_chapters") > 0
            if hasChapters { details.chapters = chapters[id] ?? [] }
            var state = EpisodeUserState()
            state.playState = switch row.int("read") { case -1: .new; case 1: .played; default: .unplayed }
            state.autoDownloadEnabled = row.long("auto_download") > 0
            state.isFavorite = favorites.contains(id)
            if let media = media[id] {
                let picture = media.int("has_embedded_picture")
                details.media = ParsedMedia(url: media.string("download_url"), size: media.long("filesize"),
                    mimeType: media.string("mime_type"), durationMilliseconds: media.int("duration"),
                    hasEmbeddedPicture: picture == 1 ? true : picture == 0 ? false : nil)
                state.positionMilliseconds = media.int("position")
                state.playedDurationMilliseconds = Int64(media.int("played_duration"))
                state.lastPlayedTimeMilliseconds = media.long("last_played_time")
                let completion = media.long("playback_completion_date")
                state.lastPlayedHistoryMilliseconds = completion > 0 ? completion : nil
                // Android file paths never exist on iOS → Android's own repaired state.
                if media.long("downloaded") > 0 { skip("FeedMedia downloaded on Android (imported as not downloaded)") }
            }
            episodeFeed[id] = feedID
            feeds[index].episodes.append(LibraryEpisode(id: id, details: details, userState: state, hasStoredChapters: hasChapters))
        }

        var queue: [Int64] = [], queued = Set<Int64>()
        for row in try db.named("SELECT feeditem FROM Queue ORDER BY id") {
            let item = row.long("feeditem")
            guard episodeFeed[item] != nil else { skip("Queue without item"); continue }
            guard queued.insert(item).inserted else { skip("Queue duplicate"); continue }
            queue.append(item)
        }

        var log: [ImportedDownloadLog] = []
        for row in try db.named("SELECT * FROM DownloadLog ORDER BY completion_date, id") {
            let type = row.int("feedfile_type"), reason = row.int("reason"), file = row.long("feedfile")
            // Pre-1.7 type 1 (FeedImage) rows stay: Android lists them without a type label.
            // DownloadError.fromCode throws on unknown codes.
            guard (0...22).contains(reason) else { skip("DownloadLog reason unsupported"); continue }
            let episodeID = type == 2 ? mediaOwner[file].flatMap { episodeFeed[$0] != nil ? $0 : nil } : nil
            let feedID = type == 0 ? (feedIndex[file] != nil ? file : nil) : episodeID.flatMap { episodeFeed[$0] }
            log.append(.init(feedfile: type == 2 ? (episodeID ?? file) : file, type: type, reason: reason,
                             successful: row.int("successful") > 0, completion: row.long("completion_date"),
                             detail: row.string("reason_detailed"), title: row.string("title"),
                             feedID: feedID, episodeID: episodeID,
                             completionMissing: row.isNull("completion_date") ? true : nil))
        }
        return Library(feeds: feeds, queue: queue, credentials: credentials, feedSpeeds: speeds, feedSilence: silence,
                       downloadLog: log, skipped: skipped, sourceVersion: 0)
    }

    /// `FeedFunding.extractPaymentLinks` (model/FeedFunding.java:49–78).
    static func funding(_ value: String?) -> [FeedFunding] {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard value.contains("\u{1E}") || value.contains("\u{1F}") else { return [FeedFunding(url: value, content: "")] }
        var parts = value.components(separatedBy: "\u{1E}")
        while parts.last?.isEmpty == true { parts.removeLast() }  // Java split drops trailing empties.
        return parts.compactMap { part in
            let fields = part.components(separatedBy: "\u{1F}")
            guard let url = fields.first, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let title = fields.count > 1 && !fields[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fields[1] : ""
            return FeedFunding(url: url, content: title)
        }
    }
}

/// A source `DownloadLog` row kept verbatim; feed/episode ids resolved at import.
public struct ImportedDownloadLog: Codable, Equatable, Sendable {
    public var feedfile: Int64
    /// 0 feed, 2 media (`Feed.FEEDFILETYPE_FEED`, `FeedMedia.FEEDFILETYPE_FEEDMEDIA`).
    public var type: Int32
    /// `DownloadError` code.
    public var reason: Int32
    public var successful: Bool
    public var completion: Int64
    public var detail: String?
    public var title: String?
    public var feedID: Int64?
    public var episodeID: Int64?
    /// The source row's `completion_date` was NULL (read as 0 for display and order, as `Cursor.getLong`
    /// does). Android's maintenance `completion_date < cutoff` never deletes such a row, and an
    /// export writes NULL back.
    public var completionMissing: Bool? = nil

    public var date: Date { Date(timeIntervalSince1970: Double(completion) / 1000) }
    /// `DownloadErrorLabel.from` (DownloadErrorLabel.java:14–45).
    public var statusKey: String {
        switch reason {
        case 0: "download_successful"
        case 1, 22: "download_error_parser_exception"
        case 2: "download_error_unsupported_type"
        case 3: "download_error_connection_error"
        case 4, 6: "download_error_error_unknown"
        case 5: "download_error_io_error"
        case 7: "download_canceled_msg"
        case 8: "download_error_device_not_found"
        case 9: "download_error_http_data_error"
        case 10: "download_error_insufficient_space"
        case 11: "download_error_unknown_host"
        case 12: "download_error_request_error"
        case 13: "download_error_db_access"
        case 14: "download_error_unauthorized"
        case 15: "download_error_file_type_type"
        case 16: "download_error_forbidden"
        case 17: "download_error_wrong_size"
        case 18: "download_error_blocked"
        case 19: "download_error_unsupported_type_html"
        case 20: "download_error_not_found"
        case 21: "download_error_certificate"
        default: "download_error_error_unknown"
        }
    }
}

/// Column-name access with Android `Cursor` semantics: NULL reads as 0 / nil, `getInt` truncates.
struct NamedRow {
    let values: [String: BackupSQLite.Value]
    func long(_ name: String) -> Int64 {
        switch values[name] {
        case .integer(let value): value
        case .real(let value): value.isFinite ? Int64(max(min(value, 9.2e18), -9.2e18)) : 0
        case .text(let text?): Int64(text.trimmingCharacters(in: .whitespaces)) ?? 0
        default: 0
        }
    }
    func int(_ name: String) -> Int32 { Int32(truncatingIfNeeded: long(name)) }
    func isNull(_ name: String) -> Bool { if case .null = values[name] { true } else { false } }
    func double(_ name: String) -> Double {
        switch values[name] {
        case .integer(let value): Double(value)
        case .real(let value): value
        case .text(let text?): Double(text) ?? 0
        default: 0
        }
    }
    func string(_ name: String) -> String? {
        switch values[name] {
        case .text(let text): text
        case .integer(let value): String(value)
        case .real(let value): String(value)
        default: nil
        }
    }
}

extension BackupSQLite {
    func named(_ sql: String) throws -> [NamedRow] {
        let names = try columnNames(sql)
        return try rows(sql).map { row in NamedRow(values: Dictionary(zip(names, row), uniquingKeysWith: { first, _ in first })) }
    }
}
