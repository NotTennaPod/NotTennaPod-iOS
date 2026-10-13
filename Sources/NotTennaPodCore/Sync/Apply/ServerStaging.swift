import Foundation

/// Bounded cutover of new podcasts and episodes: a shadow that creates many episodes (a podcast
/// another device subscribed, its catalog arriving) inserts their rows in bounded transactions ahead of its unit while
/// they are hidden (`ntp_hidden_feeds` state `staging` for a new podcast, `ntp_hidden_episodes` for each new episode)
/// from every list, count, search and statistic; the unit then writes the rest and reveals them in one small
/// transaction. What staging inserted into the base and the mappings is listed in `ntp_staging`, so a staging that
/// never reached its unit (a crash, a stale shadow, a cancelled exchange) is taken out again, in bounded
/// transactions, before anything is applied. The staged rows are hidden, so no local action can change them; a local
/// change to a shown episode of the same podcast is the unit's switch to keep (`touchedRebase`). Only a feed staging
/// writes into going away (a local removal) stops it: the shadow is then built again.
/// The content records a commit changes are staged too, and the shown rows only they change are shown ahead, each whole
/// with the unit's image (stall fix (c), `ServerShadow.aheadRows`). Taking a staging out does not take such a row back:
/// it shows content the same commit publishes when it applies (its rebuilt shadow finds the row already right).
struct ServerStagingCursor: Sendable, Equatable {
    var feeds = false
    var episode: Int64 = 0
    var mapping: Int64 = 0
    var record: Int64 = 0
    var update: Int64 = 0
    var ahead: Int64 = 0
    /// Showing rows ahead stopped (a local change since the build defers the unit): the rest are the switch's.
    var aheadStopped = false
}

extension FeedLibraryStore {
    /// Episode rows a staging transaction inserts at most; mappings and base records are small rows and go five times
    /// as many at a time. Measured up to 140 ms for 250 episodes or 1,000 rows on a loaded Mac; these keep a margin
    /// under the 100 ms budget.
    static let stagingEpisodes = 100
    static let stagingRows = 500
    /// Shadow records a staging transaction examines at most for new records or content updates.
    static let stagingWindow = 2_000

    /// One bounded staging transaction of `shadow`, from `cursor`: the hidden podcasts first, then their episodes,
    /// then the mappings and base records new to the library, then the content records the commit changes, then the
    /// shown rows only that content changes (stall fix (c)). Returns the rows it went through (0: all staged) and those it
    /// showed. A feed it writes into gone (a local removal) makes the shadow stale (`ServerApplyError.stale`). Its own
    /// rows are not local changes (`quietServerTouches`).
    func stageServerShadowBatch(_ shadow: ServerShadowBuild, seq: Int64, cursor: ServerStagingCursor) throws -> (rows: Int, shown: Int, cursor: ServerStagingCursor) {
        guard serverContext != nil, let staging = shadow.staging else { return (0, 0, cursor) }
        try ensureServerExchangeTables()
        try database.execute("ATTACH DATABASE ? AS shadow", [.text(shadow.url.path)])
        defer { try? database.execute("DETACH DATABASE shadow") }
        var next = cursor
        var shown = 0
        let created = Set(staging.created.map(\.feedID))
        let rows = try syncTransactions(ServerTransactionKind.staging) { try database.transaction(durable: false) { () throws -> Int in
            let present = Set(staging.feeds).subtracting(cursor.feeds ? [] : created)
            guard try present.allSatisfy({ try database.scalar("SELECT count(*) FROM feeds WHERE id = ?", [.integer($0)]) == 1 }) else {
                throw ServerApplyError.stale
            }
            return try quietServerTouches { () throws -> Int in
            if !next.feeds, !staging.created.isEmpty {
                next.feeds = true
                for (feed, podcast) in staging.created {
                    // Hidden first, in the same transaction: no read ever sees the podcast before its unit.
                    try database.execute("INSERT INTO ntp_hidden_feeds(feed_id, podcast_id, state, seq) VALUES (?, ?, 'staging', ?)",
                                         [.integer(feed), .text(podcast), .integer(seq)])
                    try database.execute("INSERT INTO feeds(id, title, record) SELECT id, title, record FROM shadow.feeds WHERE id = ? AND stage = 1", [.integer(feed)])
                }
                return staging.created.count
            }
            let episodes = try database.rows("SELECT id FROM shadow.episodes WHERE stage = 1 AND id > ? ORDER BY id LIMIT ?",
                                             [.integer(next.episode), .integer(Int64(Self.stagingEpisodes))]).compactMap { $0[0].integer }
            if let last = episodes.last {
                let list = ContractJSON.array(episodes.map(ContractJSON.integer)).canonicalText
                // Hidden in the same transaction: no read sees a new episode before its unit (a new podcast's are hidden
                // with the podcast).
                try database.execute("INSERT INTO ntp_hidden_episodes(episode_id, feed_id, seq) SELECT id, feed_id, ? FROM shadow.episodes WHERE id IN (SELECT value FROM json_each(?)) AND feed_id NOT IN (SELECT value FROM json_each(?))",
                                     [.integer(seq), .text(list), .text(ContractJSON.array(staging.created.map { .integer($0.feedID) }).canonicalText)])
                try database.execute("INSERT INTO episodes(id, feed_id, pubdate, record) SELECT id, feed_id, pubdate, record FROM shadow.episodes WHERE id IN (SELECT value FROM json_each(?))",
                                     [.text(list)])
                next.episode = last
                return episodes.count
            }
            let mappings = try database.rows("SELECT rowid, episode_id FROM shadow.mappings WHERE stage = 1 AND rowid > ? ORDER BY rowid LIMIT ?",
                                             [.integer(next.mapping), .integer(Int64(Self.stagingRows))])
            if let last = mappings.last?[0].integer {
                let keys = ContractJSON.array(mappings.compactMap { $0[1].text.map(ContractJSON.string) }).canonicalText
                try database.execute("INSERT INTO ntp_staging(seq, kind, keys) VALUES (?, 'episodes', ?)", [.integer(seq), .blob(Data(keys.utf8))])
                try database.execute("INSERT INTO ntp_episodes(episode_id, local_id, podcast_id, kind, value, occurrence, merged_into) SELECT episode_id, local_id, podcast_id, kind, value, occurrence, merged_into FROM shadow.mappings WHERE rowid IN (SELECT value FROM json_each(?))",
                                     [.text(ContractJSON.array(mappings.compactMap { $0[0].integer.map(ContractJSON.integer) }).canonicalText)])
                next.mapping = last
                return mappings.count
            }
            // New records (no base row yet), then the content updates of records the base holds (`update`): each
            // update keeps the previous value and provenance in `ntp_staging`, so taking the staging out restores them
            // exactly. Each transaction examines a window of the shadow's records (by rowid), never all of them: a
            // window without what it looks for moves the cursor on.
            let lastRecord = try database.scalar("SELECT coalesce(max(rowid), 0) FROM shadow.records")
            if next.update == 0 {
                let window = next.record + Int64(Self.stagingWindow)
                let records = try database.rows("SELECT s.rowid, s.entity, s.id, s.field_group FROM shadow.records s WHERE s.rowid > ? AND s.rowid <= ? AND +s.stage = 1 AND NOT EXISTS (SELECT 1 FROM ntp_records r WHERE r.entity = s.entity AND r.id = s.id AND r.field_group = s.field_group) ORDER BY s.rowid LIMIT ?",
                                                [.integer(next.record), .integer(window), .integer(Int64(Self.stagingRows))])
                if let last = records.last?[0].integer {
                    let keys = ContractJSON.array(records.map { row in .array([1, 2, 3].map { row[$0].text.map(ContractJSON.string) ?? .null }) }).canonicalText
                    try database.execute("INSERT INTO ntp_staging(seq, kind, keys) VALUES (?, 'records', ?)", [.integer(seq), .blob(Data(keys.utf8))])
                    try database.execute("INSERT INTO ntp_records(entity, id, field_group, value, provenance) SELECT entity, id, field_group, value, provenance FROM shadow.records WHERE rowid IN (SELECT value FROM json_each(?)) ON CONFLICT(entity, id, field_group) DO UPDATE SET value = excluded.value, provenance = excluded.provenance",
                                         [.text(ContractJSON.array(records.compactMap { $0[0].integer.map(ContractJSON.integer) }).canonicalText)])
                    next.record = last
                    return records.count
                }
                if window < lastRecord {
                    next.record = window
                    return 1
                }
                next.update = -1
            }
            if next.update != -2 {
                let from = max(0, next.update), window = from + Int64(Self.stagingWindow)
                let updates = try database.rows("SELECT s.rowid FROM shadow.records s JOIN ntp_records r ON r.entity = s.entity AND r.id = s.id AND r.field_group = s.field_group WHERE s.rowid > ? AND s.rowid <= ? AND +s.stage = 1 AND (r.value IS NOT s.value OR r.provenance IS NOT s.provenance) ORDER BY s.rowid LIMIT ?",
                                                [.integer(from), .integer(window), .integer(Int64(Self.stagingRows))]).compactMap { $0[0].integer }
                if let last = updates.last {
                    let list = ContractJSON.array(updates.map(ContractJSON.integer)).canonicalText
                    // The previous values first, then the new ones.
                    // A `records` entry whose keys carry the previous value and provenance (five elements, not three).
                    try database.execute("INSERT INTO ntp_staging(seq, kind, keys) SELECT ?, 'records', CAST(json_group_array(json_array(r.entity, r.id, r.field_group, CAST(r.value AS TEXT), r.provenance)) AS BLOB) FROM shadow.records s JOIN ntp_records r ON r.entity = s.entity AND r.id = s.id AND r.field_group = s.field_group WHERE s.rowid IN (SELECT value FROM json_each(?))",
                                         [.integer(seq), .text(list)])
                    try database.execute("INSERT INTO ntp_records(entity, id, field_group, value, provenance) SELECT entity, id, field_group, value, provenance FROM shadow.records WHERE rowid IN (SELECT value FROM json_each(?)) ON CONFLICT(entity, id, field_group) DO UPDATE SET value = excluded.value, provenance = excluded.provenance",
                                         [.text(list)])
                    next.update = last
                    return updates.count
                }
                if window < lastRecord {
                    next.update = window
                    return 1
                }
                next.update = -2
            }
            // The shown rows only the commit's content changes (stall fix (c)), each whole, its image the unit's: the base
            // holds that content now. A row a local change touched since the build is left to the switch, which
            // re-projects it (`rebase`); a local change that defers the unit stops them (the switch then defers too, and
            // at the pause the unit is published as a whole over them).
            guard !next.aheadStopped, staging.ahead > 0 else { return 0 }
            // Measured as rows shown ahead (the label is read when the transaction commits).
            database.transactionKind = ServerTransactionKind.shownAhead
            let ahead = try database.rows("SELECT id FROM shadow.episodes WHERE stage = 2 AND id > ? ORDER BY id LIMIT ?",
                                          [.integer(next.ahead), .integer(Int64(Self.stagingEpisodes))]).compactMap { $0[0].integer }
            guard let last = ahead.last else { return 0 }
            let touched: Set<Int64>
            do {
                touched = try rebase(shadow.revisions, stagedWork: 0, workLimit: nil).rows
            } catch ServerApplyError.deferred {
                next.aheadStopped = true
                return 0
            }
            let shows = ContractJSON.array(ahead.filter { !touched.contains($0) }.map(ContractJSON.integer)).canonicalText
            try database.execute("UPDATE episodes SET pubdate = s.pubdate, record = s.record FROM shadow.episodes s WHERE s.id IN (SELECT value FROM json_each(?)) AND episodes.id = s.id AND episodes.feed_id = s.feed_id AND (episodes.pubdate IS NOT s.pubdate OR episodes.record IS NOT s.record)",
                                 [.text(shows)])
            shown = Int(try database.scalar("SELECT changes()"))
            try database.execute("UPDATE shadow.episodes SET stage = 3 WHERE id IN (SELECT value FROM json_each(?))", [.text(shows)])
            next.ahead = last
            return ahead.count
            }
        } }
        return (rows, shown, next)
    }

    /// Whether a staging that never reached its unit is left to take out.
    func hasServerStaging() throws -> Bool {
        guard serverContext != nil else { return false }
        try ensureServerExchangeTables()
        return try database.scalar("SELECT (SELECT count(*) FROM ntp_staging) + (SELECT count(*) FROM ntp_hidden_episodes) + (SELECT count(*) FROM ntp_hidden_feeds WHERE state = 'staging')") > 0
    }

    /// One `ntp_staging` entry taken out: the new base records and mappings it inserted go; the content records it
    /// updated (keys of five elements: the previous value and provenance) get their previous values back.
    static func takeOut(kind: String, list: String, _ database: LibrarySQLite) throws {
        switch kind {
        case "records":
            try database.execute("DELETE FROM ntp_records WHERE (entity, id, field_group) IN (SELECT json_extract(value, '$[0]'), json_extract(value, '$[1]'), json_extract(value, '$[2]') FROM json_each(?) WHERE json_array_length(value) = 3)", [.text(list)])
            try database.execute("INSERT INTO ntp_records(entity, id, field_group, value, provenance) SELECT json_extract(value, '$[0]'), json_extract(value, '$[1]'), json_extract(value, '$[2]'), CAST(json_extract(value, '$[3]') AS BLOB), json_extract(value, '$[4]') FROM json_each(?) WHERE json_array_length(value) = 5 ON CONFLICT(entity, id, field_group) DO UPDATE SET value = excluded.value, provenance = excluded.provenance",
                                 [.text(list)])
        default:
            try database.execute("DELETE FROM ntp_episodes WHERE episode_id IN (SELECT value FROM json_each(?))", [.text(list)])
        }
    }

    /// Takes out every staging that never reached its unit inside the caller's transaction (a retained shadow published
    /// as a whole at the pause, where the budget is relaxed). Its hidden rows were never visible; rows shown ahead are the
    /// unit's own images, which the whole publication then projects again.
    func discardAllServerStaging() throws {
        try quietServerTouches {
            for row in try database.rows("SELECT kind, keys FROM ntp_staging ORDER BY id") {
                guard let kind = row[0].text, let keys = row[1].data else { continue }
                try Self.takeOut(kind: kind, list: String(decoding: keys, as: UTF8.self), database)
            }
            try database.execute("DELETE FROM ntp_staging")
            try database.execute("DELETE FROM episodes WHERE id IN (SELECT episode_id FROM ntp_hidden_episodes)")
            try database.execute("DELETE FROM ntp_hidden_episodes")
            try database.execute("DELETE FROM episodes WHERE feed_id IN (SELECT feed_id FROM ntp_hidden_feeds WHERE state = 'staging')")
            try database.execute("DELETE FROM feeds WHERE id IN (SELECT feed_id FROM ntp_hidden_feeds WHERE state = 'staging')")
            try database.execute("DELETE FROM ntp_hidden_feeds WHERE state = 'staging'")
        }
    }

    /// One bounded transaction taking out a staging that never reached its unit: the base records and mappings it
    /// inserted (new keys go, updated content records get their previous values back), then the hidden podcasts'
    /// episodes and the podcasts, which were never visible and hold nothing of the person's. Returns whether anything
    /// was left.
    func discardServerStagingBatch() throws -> Bool {
        try syncTransactions(ServerTransactionKind.stagingTakeOut) { try discardServerStagingBatchLabelled() }
    }

    private func discardServerStagingBatchLabelled() throws -> Bool {
        guard serverContext != nil else { return false }
        try ensureServerExchangeTables()
        return try database.transaction(durable: false) { () throws -> Bool in
            // Rows nobody ever saw: taking them out is not a local change.
            try quietServerTouches { () throws -> Bool in
            if let row = try database.rows("SELECT id, kind, keys FROM ntp_staging ORDER BY id LIMIT 1").first,
               let id = row[0].integer, let kind = row[1].text, let keys = row[2].data {
                let list = String(decoding: keys, as: UTF8.self)
                try Self.takeOut(kind: kind, list: list, database)
                try database.execute("DELETE FROM ntp_staging WHERE id = ?", [.integer(id)])
                return true
            }
            let hidden = try database.rows("SELECT episode_id FROM ntp_hidden_episodes ORDER BY episode_id LIMIT ?", [.integer(Int64(Self.stagingEpisodes))])
                .compactMap { $0[0].integer }
            if !hidden.isEmpty {
                let list = ContractJSON.array(hidden.map(ContractJSON.integer)).canonicalText
                try database.execute("DELETE FROM episodes WHERE id IN (SELECT value FROM json_each(?))", [.text(list)])
                try database.execute("DELETE FROM ntp_hidden_episodes WHERE episode_id IN (SELECT value FROM json_each(?))", [.text(list)])
                return true
            }
            guard let feed = try database.rows("SELECT feed_id FROM ntp_hidden_feeds WHERE state = 'staging' ORDER BY feed_id LIMIT 1").first?.first?.integer else { return false }
            let episodes = try database.rows("SELECT id FROM episodes WHERE feed_id = ? ORDER BY id LIMIT ?", [.integer(feed), .integer(Int64(Self.stagingEpisodes))])
                .compactMap { $0[0].integer }
            if episodes.isEmpty {
                try database.execute("DELETE FROM feeds WHERE id = ?", [.integer(feed)])
                try database.execute("DELETE FROM ntp_hidden_feeds WHERE feed_id = ?", [.integer(feed)])
            } else {
                try database.execute("DELETE FROM episodes WHERE feed_id = ? AND id IN (SELECT value FROM json_each(?))",
                                     [.integer(feed), .text(ContractJSON.array(episodes.map(ContractJSON.integer)).canonicalText)])
            }
            return true
            }
        }
    }
}

extension ServerSyncEngine {
    /// Stages a shadow's new podcasts in bounded transactions, paced like units while audio plays.
    func stage(_ shadow: ServerShadowBuild, seq: Int64, report: inout ServerExchangeReport) async throws -> ServerShadowBuild {
        guard let staging = shadow.staging else { return shadow }
        var cursor = ServerStagingCursor()
        var batches = 0, shown = 0
        var longest = 0.0
        // Rows shown ahead are told as they show, at most about once a second (a long catch-up shows its progress, PROTOCOL §6.8).
        let clock = ContinuousClock()
        var told = clock.now, untold = false
        while true {
            try Task.checkCancellation()
            try await pace()
            try await beforeStagingBatch?()
            let started = clock.now
            let step = try await store.stageServerShadowBatch(shadow, seq: seq, cursor: cursor)
            let held = FeedLibraryStore.milliseconds(started.duration(to: clock.now))
            report.longestLockMilliseconds = max(report.longestLockMilliseconds, held)
            longest = max(longest, held)
            if step.shown > 0 {
                shown += step.shown
                report.shownAhead += step.shown
                report.libraryChanged = true
                untold = true
                if told.duration(to: clock.now) >= .seconds(1) { publish(.libraryChanged); told = clock.now; untold = false }
            }
            if step.cursor.aheadStopped, !cursor.aheadStopped {
                log("apply", "commit \(seq): a local change since its build defers it; its remaining content is shown by its unit")
            }
            if step.rows == 0 { break }
            batches += 1
            report.stagingBatches += 1
            cursor = step.cursor
        }
        if untold { publish(.libraryChanged) }
        try crash("staging.staged")
        log("apply", "commit \(seq): \(staging.work) rows of \(staging.created.count) new podcast(s), \(staging.episodes) new episodes, "
            + "\(staging.updates) content records and \(shown) of \(staging.ahead) rows only that content changes staged in \(batches) transactions, "
            + "the longest \(String(format: "%.1f", longest)) ms")
        return shadow
    }

    /// Takes out a staging that never reached its unit, before anything is applied.
    func discardStaging() async throws {
        guard try await store.hasServerStaging() else { return }
        log("apply", "a podcast staged for a unit that did not run is taken out; it is staged again")
        while try await store.discardServerStagingBatch() {
            try Task.checkCancellation()
            try await pace()
        }
    }
}
