import Foundation

/// Observations recorded after the transaction that found them (PROTOCOL §9.4 under PROTOCOL §6.8 bounded work),
/// listed in `ntp_observation_work` with the parse they observe: a subscription's first population,
/// a batch's records found while the podcast waits for its first canonical metadata, and a large
/// batch's records besides its releases. Each later transaction records up to 200 of one feed, complete on its own, so
/// the store is held briefly and a playback save waits for one at most; a row goes only with its recording, or once
/// what it holds proves observed or equal to the canonical record, never because the rows shown changed. A feed's are
/// recorded once its podcast is registered and its first canonical metadata arrived or its wait ended: by the refresh
/// right after it commits (with its parse, hashed and serialized with the fetch, outside the store), by a refresh
/// answered 304, and before every push (also after a relaunch).
extension FeedLibraryStore {
    /// A record to observe later: an episode's (`localID`, its identity and evidence) or the podcast's (`localID` nil).
    struct ObservationEntry {
        var localID: Int64?
        var key: ServerEpisodeKey?
        var evidence: ServerItemEvidence?
        var hash: String
        var canonical: [UInt8]
    }

    /// Lists records to observe later (inside the transaction that found them), with their parse.
    func listObservations(feedID: Int64, batchID: String, fetchTime: Int64, entries: [ObservationEntry], writer: ServerOutboxWriter? = nil) throws {
        func execute(_ sql: String, _ values: [LibrarySQLValue]) throws {
            if let writer { try writer.execute(sql, values) } else { try database.execute(sql, values) }
        }
        let columns = "feed_id, local_id, batch_id, fetch_time, hash, kind, value, guid, enclosure, publication_time, title, atom, fields"
        let update = "feed_id = excluded.feed_id, batch_id = excluded.batch_id, fetch_time = excluded.fetch_time, hash = excluded.hash, kind = excluded.kind, value = excluded.value, guid = excluded.guid, enclosure = excluded.enclosure, publication_time = excluded.publication_time, title = excluded.title, atom = excluded.atom, fields = excluded.fields"
        func values(_ entry: ObservationEntry) -> [LibrarySQLValue] {
            func text(_ value: String?) -> LibrarySQLValue { value.map(LibrarySQLValue.text) ?? .null }
            return [.integer(feedID), entry.localID.map(LibrarySQLValue.integer) ?? .null, .text(batchID), .integer(fetchTime), .text(entry.hash),
                    text(entry.key?.kind), text(entry.key?.value), text(entry.evidence?.guid), text(entry.evidence?.enclosureURL),
                    entry.evidence?.publicationTime.map(LibrarySQLValue.integer) ?? .null, text(entry.evidence?.title),
                    entry.evidence.map { .integer($0.atom ? 1 : 0) } ?? .null, .blob(Data(entry.canonical))]
        }
        let marks = "(" + Array(repeating: "?", count: 13).joined(separator: ", ") + ")"
        // 70 rows a statement: within SQLite's 999 parameters.
        let episodes = entries.filter { $0.localID != nil }
        for start in stride(from: 0, to: episodes.count, by: 70) {
            let chunk = episodes[start..<min(episodes.count, start + 70)]
            try execute("INSERT INTO ntp_observation_work(\(columns)) VALUES \(Array(repeating: marks, count: chunk.count).joined(separator: ", ")) ON CONFLICT(local_id) WHERE local_id IS NOT NULL DO UPDATE SET \(update)",
                        chunk.flatMap(values))
        }
        for entry in entries where entry.localID == nil {
            try execute("INSERT INTO ntp_observation_work(\(columns)) VALUES \(marks) ON CONFLICT(feed_id) WHERE local_id IS NULL DO UPDATE SET \(update)", values(entry))
        }
    }

    /// The next listed observations of a feed's episodes, up to one transaction's worth.
    func pendingObservations(feedID: Int64) throws -> [Int64] {
        try database.rows("SELECT local_id FROM ntp_observation_work WHERE feed_id = ? AND local_id IS NOT NULL ORDER BY id LIMIT ?",
                          [.integer(feedID), .integer(Int64(Self.observationItems))]).compactMap { $0[0].integer }
    }

    /// The feeds whose listed observations may be recorded now (`feedID`, or any a drain of this process does not own):
    /// recorded as a registered podcast's facts (not while an earlier registration of the feed still holds drafts,
    /// whose chain its facts join), and the podcast's first canonical metadata arrived or its wait ended (PROTOCOL
    /// §9.4). A feed that is not ready keeps its rows.
    private func readyObservationFeeds(_ feedID: Int64?, skipping: Set<Int64>, now: Int64) throws -> [Int64] {
        let feeds = try database.rows(feedID == nil ? "SELECT DISTINCT feed_id FROM ntp_observation_work ORDER BY feed_id"
                                                    : "SELECT DISTINCT feed_id FROM ntp_observation_work WHERE feed_id = ?",
                                      feedID.map { [.integer($0)] } ?? []).compactMap { $0[0].integer }
        return try feeds.filter { feed in
            guard !skipping.contains(feed),
                  case .registered(let podcast, _) = try storedBinding(feed, isLocalFolder: try loadFeedHeader(feed)?.source.isLocalFeedSource == true)
            else { return false }
            if try serverRecord("podcast", podcast, "metadata") != nil { return true }
            guard let created = try database.rows("SELECT max(created_at) FROM ntp_registrations WHERE feed_id = ? OR podcast_id = ?",
                                                  [.integer(feed), .text(podcast)]).first?.first?.integer else { return true }
            return now - created >= Self.firstPopulationWait
        }
    }

    private func listedObservationCount(_ feedID: Int64) throws -> Int64 {
        try database.scalar("SELECT count(*) FROM ntp_observation_work WHERE feed_id = ?", [.integer(feedID)])
    }

    /// One bounded transaction: up to 200 listed observations of one ready feed's batch (`feedID`, or any feed a drain of
    /// this process does not own), with the refresh's parse of them when given. Returns whether more are ready.
    @discardableResult
    func recordDeferredObservations(feedID: Int64?, inputs: [Int64: ServerCatalogParse.Item] = [:], now: Date = Date()) throws -> Bool {
        guard serverContext != nil else { return false }
        let skip = feedID == nil ? drainingObservationFeeds : []
        let time = try milliseconds(now)
        guard let feed = try readyObservationFeeds(feedID, skipping: skip, now: time).first else { return false }
        let listed = try listedObservationCount(feed)
        try syncTransactions(ServerTransactionKind.bookkeeping) {
            try write(.observe, now: now) {
                activeCapture?.observationFeed = feed
                activeCapture?.observationInputs = inputs
            }
        }
        // Never "more" for work this transaction could not take: the next push or refresh tries again.
        guard try listedObservationCount(feed) < listed else { return false }
        return try !readyObservationFeeds(feedID, skipping: skip, now: time).isEmpty
    }

    /// A listed row's record as the parse made it.
    struct ListedObservation {
        var localID: Int64?
        var batchID: String
        var fetchTime: Int64
        var hash: String
        var key: ServerEpisodeKey?
        var evidence: ServerItemEvidence?
        var canonical: [UInt8]
    }

    /// The next transaction's rows of a feed: its podcast record (first) with up to 200 episodes of its batch, else up to
    /// 200 episodes of the oldest batch.
    func nextListedObservations(feedID: Int64) throws -> [ListedObservation] {
        let select = "SELECT local_id, batch_id, fetch_time, hash, kind, value, guid, enclosure, publication_time, title, atom, fields FROM ntp_observation_work"
        func listed(_ row: [LibrarySQLValue]) -> ListedObservation? {
            guard let batch = row[1].text, let time = row[2].integer, let hash = row[3].text, let fields = row[11].data else { return nil }
            var key: ServerEpisodeKey?
            if let kind = row[4].text, let value = row[5].text { key = ServerEpisodeKey(kind: kind, value: value) }
            let evidence = row[0].integer == nil ? nil
                : ServerItemEvidence(guid: row[6].text, enclosureURL: row[7].text, publicationTime: row[8].integer, title: row[9].text, atom: row[10].integer == 1)
            return ListedObservation(localID: row[0].integer, batchID: batch, fetchTime: time, hash: hash, key: key, evidence: evidence, canonical: [UInt8](fields))
        }
        let feedRow = try database.rows("\(select) WHERE feed_id = ? AND local_id IS NULL", [.integer(feedID)]).first.flatMap(listed)
        guard let batch = try feedRow?.batchID ?? database.rows("SELECT batch_id FROM ntp_observation_work WHERE feed_id = ? AND local_id IS NOT NULL ORDER BY id LIMIT 1",
                                                                [.integer(feedID)]).first?.first?.text else { return [] }
        let episodes = try database.rows("\(select) WHERE feed_id = ? AND local_id IS NOT NULL AND batch_id = ? ORDER BY id LIMIT ?",
                                         [.integer(feedID), .text(batch), .integer(Int64(Self.observationItems))]).compactMap(listed)
        return (feedRow.map { [$0] } ?? []) + episodes
    }

    func drainingObservations(_ feedID: Int64, _ draining: Bool) {
        if draining { drainingObservationFeeds.insert(feedID) } else { drainingObservationFeeds.remove(feedID) }
    }

    /// Records a feed's listed observations, one bounded transaction at a time (the store is free between them), with
    /// a refresh's parse when given (else as the rows keep it). A cancelled or failed drain leaves the rest listed for
    /// the next push.
    static func drainObservations(_ store: FeedLibraryStore, feedID: Int64, catalog: ServerCatalogParse?, items: [Int64: Int],
                                  transaction: (@Sendable (Duration) -> Void)? = nil) async throws {
        await store.drainingObservations(feedID, true)
        do {
            while true {
                try Task.checkCancellation()
                var inputs: [Int64: ServerCatalogParse.Item] = [:]
                if let catalog {
                    for local in try await store.pendingObservations(feedID: feedID) {
                        if let index = items[local], index < catalog.items.count { inputs[local] = catalog.items[index] }
                    }
                }
                let started = ContinuousClock.now
                let more = try await store.recordDeferredObservations(feedID: feedID, inputs: inputs)
                transaction?(started.duration(to: .now))
                guard more else { break }
            }
        } catch {
            await store.drainingObservations(feedID, false)
            throw error
        }
        await store.drainingObservations(feedID, false)
    }
}
