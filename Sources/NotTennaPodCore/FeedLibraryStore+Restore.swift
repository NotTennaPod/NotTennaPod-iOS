import Foundation

/// Android database restore.
extension FeedLibraryStore {
    /// State the source keeps outside its database (SharedPreferences), which an import therefore
    /// keeps: the synchronization account, timestamps and outbox, and the periodic refresh schedule.
    /// Also the replaced library's credential references, retired only after the new library commits.
    public struct RestoreCarryOver: Sendable {
        var tables: [(name: String, rows: [[LibrarySQLValue]])]
        public let credentialIDs: [UUID]
    }

    public func restoreCarryOver() throws -> RestoreCarryOver {
        try database.transaction(write: false) {
            let tables = try ["synchronization_state", "synchronization_outbox", "periodic_feed_schedule"].map {
                (name: $0, rows: try database.rows("SELECT * FROM \($0) ORDER BY rowid"))
            }
            let ids = try database.rows("SELECT credential_id FROM feed_credentials UNION SELECT credential_id FROM feed_credential_cleanup")
                .map { row -> UUID in
                    guard case .text(let text) = row[0], let id = UUID(uuidString: text) else { throw FeedLibraryError.corruptRecord }
                    return id
                }
            return RestoreCarryOver(tables: tables, credentialIDs: ids)
        }
    }

    /// Fills this new, empty library with a validated Android backup in one transaction. Android ids
    /// are kept; the id counters continue after them. No queue work, sync action or effect is
    /// created, as the source import creates none.
    public func installRestoredLibrary(_ library: AndroidDatabaseRestore.Library, carrying carry: RestoreCarryOver) throws {
        try Task.checkCancellation()
        // A database import would bring a library into the account from the phone (PROTOCOL §11.5).
        guard serverContext == nil else { throw ServerRecordingError.refusedInServerLibrary("database import") }
        try database.transaction {
            guard try database.scalar("SELECT count(*) FROM feeds") == 0 else { throw FeedLibraryError.invalidMutation }
            for feed in library.feeds { try save(feed) }
            for (position, id) in library.queue.enumerated() {
                try database.execute("INSERT INTO queue(position, episode_id) VALUES (?, ?)", [.integer(Int64(position)), .integer(id)])
            }
            for entry in library.downloadLog {
                try database.execute("INSERT INTO imported_download_log(completed_at, record) VALUES (?, ?)",
                                     [.integer(entry.completion), .blob(try JSONEncoder().encode(entry))])
            }
            let feedID = library.feeds.map(\.id).max() ?? 0
            let episodeID = library.feeds.flatMap { $0.episodes.map(\.id) }.max() ?? 0
            try database.execute("UPDATE library_ids SET value = max(value, ?) WHERE kind = 'feed'", [.integer(feedID)])
            try database.execute("UPDATE library_ids SET value = max(value, ?) WHERE kind = 'episode'", [.integer(episodeID)])
            let journal = RestoreJournal(feedSpeeds: library.feedSpeeds, feedSilence: library.feedSilence)
            try database.execute("INSERT INTO restore_journal(id, record) VALUES (1, ?)", [.blob(try JSONEncoder().encode(journal))])
            for table in carry.tables where !table.rows.isEmpty {
                try database.execute("DELETE FROM \(table.name)")
                for row in table.rows {
                    let marks = Array(repeating: "?", count: row.count).joined(separator: ",")
                    try database.execute("INSERT INTO \(table.name) VALUES (\(marks))", row)
                }
            }
            try Task.checkCancellation()
        }
    }

    /// Preferences stored outside the library that the restored backup defines (per-feed speed and
    /// silence), kept in the restored library until the next graph start applies them.
    public struct RestoreJournal: Codable, Equatable, Sendable {
        public var feedSpeeds: [Int64: Float]
        public var feedSilence: [Int64: PlaybackSilencePreference]
    }

    public func pendingRestoreJournal() throws -> RestoreJournal? {
        guard let row = try database.rows("SELECT record FROM restore_journal WHERE id = 1").first else { return nil }
        return try decode(row[0])
    }

    public func clearRestoreJournal() throws { try database.execute("DELETE FROM restore_journal") }

    func idCounters() throws -> (feed: Int64, episode: Int64) {
        (try database.scalar("SELECT value FROM library_ids WHERE kind = 'feed'"),
         try database.scalar("SELECT value FROM library_ids WHERE kind = 'episode'"))
    }
}
