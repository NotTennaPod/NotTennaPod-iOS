import Foundation

/// What automatic download reads: keys, never records.
extension FeedLibraryStore {
    /// What one automatic download pass selects from, and the server library's pending releases (nil in a standalone
    /// library), from one read transaction: the feeds library-wide reads show (headers), and of their visible episodes only
    /// those a pass can act on, from the derived keys: NEW (or the pending releases), queued and downloaded. Proportional
    /// to those collections; no episode record is read. Before the derived keys are complete it reads the whole library,
    /// as every pass did before.
    public func automaticDownloadLibrary() throws -> (library: AutomaticDownloadPolicy.Library, releases: Set<Int64>?) {
        try database.transaction(write: false) {
            let releases: Set<Int64>? = serverContext == nil ? nil : Set(try serverLedgerEntries(.pending).map(\.localID))
            return (try loadAutomaticDownloadLibrary(releases: releases), releases)
        }
    }

    /// `automaticDownloadLibrary()`'s library for the given releases, in the caller's read transaction.
    func loadAutomaticDownloadLibrary(releases: Set<Int64>?) throws -> AutomaticDownloadPolicy.Library {
        guard keyedReads else {
            snapshotReads += 1
            return .init(try loadSnapshot())
        }
        let feeds = try loadFeedHeaders(skippingPinnedRemovals: true)
        let columns = LibrarySchema21.keyColumns.map { "k.\($0)" }.joined(separator: ", ")
        var found: [Int64: EpisodeListKeys] = [:], order: [Int64] = []
        func add(_ rows: [[LibrarySQLValue]]) throws {
            for row in rows {
                let keys = try EpisodeListKeys(row: row)
                if found.updateValue(keys, forKey: keys.id) == nil { order.append(keys.id) }
            }
        }
        if let releases {
            for chunk in LibraryReader.chunks(releases.sorted()) {
                try add(database.rows("SELECT \(columns) FROM episode_list_keys k WHERE k.id IN (SELECT value FROM json_each(?)) AND k.hidden = 0", [.text(chunk)]))
            }
        } else {
            try add(database.rows("SELECT \(columns) FROM episode_list_keys k WHERE k.state = -1 AND k.hidden = 0"))
        }
        try add(database.rows("SELECT \(columns) FROM episode_list_keys k WHERE k.downloaded = 1 AND k.hidden = 0"))
        let shown = hiddenFeedsCondition("k.feed_id").map { " AND " + $0 } ?? ""
        let queue = try database.rows("SELECT \(columns) FROM queue q JOIN episode_list_keys k ON k.id = q.episode_id WHERE k.hidden = 0\(shown) ORDER BY q.position").map { row in
            let keys = try EpisodeListKeys(row: row)
            if found.updateValue(keys, forKey: keys.id) == nil { order.append(keys.id) }
            return keys.id
        }
        let episodes = order.compactMap { found[$0].map(AutomaticDownloadPolicy.Item.init) }
        return .init(feeds: feeds, episodes: episodes, queue: queue)
    }
}

extension FeedLibraryStore {
    /// Tests: `automaticDownloadLibrary()` with any release set, in one read.
    func automaticDownloadLibrary(releases: Set<Int64>?) throws -> AutomaticDownloadPolicy.Library {
        try database.transaction(write: false) { try loadAutomaticDownloadLibrary(releases: releases) }
    }
}
