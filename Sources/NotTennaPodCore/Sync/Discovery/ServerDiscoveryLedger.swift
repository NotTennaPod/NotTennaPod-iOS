import Foundation

/// The discovery ledger (PROTOCOL §9 "Device follow-ups"): one entry per release, from this phone's
/// own proposals and from admissions arriving by pull, keyed by generation and episode (`ntp_ledger(generation_id,
/// occurrence)`), so a release discovered twice, or proposed here and admitted from another device, is one entry. A
/// pending registration's entries are keyed by the registration and the local episode until it resolves, then rekeyed.
/// `state` is the automatic download's (`pending` until the download is requested or no longer wanted, `done`);
/// `notified` the new-episode notification's. An attach snapshot's admissions are seen (`done`, notified).
extension FeedLibraryStore {
    static func ledgerKey(registration op: String) -> String { "registration:\(op)" }
    static func ledgerKey(localEpisode id: Int64) -> String { "local-episode:\(id)" }

    /// Records a release of this phone's refresh (inside the recorder's savepoint): an existing entry for the same
    /// generation and episode (an admission already pulled) is the same release and stays as it is.
    func noteServerRelease(generation: String, occurrence: String, localID: Int64, feedID: Int64, action: String, proposal: String?,
                           writer: ServerOutboxWriter) throws {
        var record: ContractObject = ["local_id": .integer(localID), "feed_id": .integer(feedID), "action": .string(action)]
        if let proposal { record["proposal_id"] = .string(proposal) }
        try writer.execute("INSERT INTO ntp_ledger(generation_id, occurrence, entry_id, state, notified, record) VALUES (?, ?, ?, 'pending', 0, ?) ON CONFLICT(generation_id, occurrence) DO NOTHING",
                           [.text(generation), .text(occurrence), proposal.map(LibrarySQLValue.text) ?? .null,
                            .blob(try ContractJSON.object(record).canonicalData())])
    }

    /// A queue filing's proposal joins its release's entry (it was recorded when the refresh found the release).
    func noteServerReleaseProposal(generation: String, occurrence: String, proposal: String, writer: ServerOutboxWriter) throws {
        try writer.execute("UPDATE ntp_ledger SET entry_id = coalesce(entry_id, ?) WHERE generation_id = ? AND occurrence = ?",
                           [.text(proposal), .text(generation), .text(occurrence)])
    }

    /// At a registration's resolution (inside the materializer's transaction): its entries take the resolved generation
    /// and their episodes' wire IDs (an episode not mapped keeps its local key). An entry that meets one already there (an admission of the same release) merges
    /// with it: the release is done or notified if either was.
    func rekeyServerLedger(registration op: String, generation: String, writer: ServerOutboxWriter) throws {
        let key = Self.ledgerKey(registration: op)
        for row in try database.rows("SELECT occurrence, entry_id, state, notified, record FROM ntp_ledger WHERE generation_id = ?", [.text(key)]) {
            guard let occurrence = row[0].text, occurrence.hasPrefix("local-episode:"),
                  let local = Int64(occurrence.dropFirst("local-episode:".count)) else { continue }
            try writer.execute("DELETE FROM ntp_ledger WHERE generation_id = ? AND occurrence = ?", [.text(key), .text(occurrence)])
            // An episode without a mapping of its own (a provisional release of rotating enclosures) keeps its local
            // episode until the server's mapping names it.
            let wire = try database.rows("SELECT episode_id FROM ntp_episodes WHERE local_id = ?", [.integer(local)]).first?.first?.text ?? occurrence
            try writer.execute("INSERT INTO ntp_ledger(generation_id, occurrence, entry_id, state, notified, record) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(generation_id, occurrence) DO UPDATE SET state = CASE WHEN ntp_ledger.state = 'done' OR excluded.state = 'done' THEN 'done' ELSE ntp_ledger.state END, notified = max(ntp_ledger.notified, excluded.notified)",
                               [.text(generation), .text(wire), row[1], row[2], row[3], row[4]])
        }
    }

    /// One pending or unnotified release: its entry and local episode.
    struct ServerLedgerEntry: Sendable, Equatable {
        var generation: String
        var occurrence: String
        var localID: Int64
        var feedID: Int64
        var pending: Bool
        var notified: Bool
    }

    /// Which ledger entries a read takes: those still to download, or those still to notify.
    enum ServerLedgerSelection { case pending, unnotified }

    /// The releases still to download (`pending`) or to notify (`unnotified`), with their local episodes (an entry whose
    /// episode is not here yet, or no longer, is left out), in the order they were recorded. Each predicate alone is a
    /// partial index of the ledger (`ntp_ledger_pending_occurrence`, `ntp_ledger_unnotified`), so a read is
    /// proportional to the entries it takes, never to the settled releases.
    func serverLedgerEntries(_ selection: ServerLedgerSelection) throws -> [ServerLedgerEntry] {
        guard serverContext != nil else { return [] }
        let condition = switch selection {
        case .pending: "l.state = 'pending'"
        case .unnotified: "l.notified = 0"
        }
        var result: [(rowid: Int64, entry: ServerLedgerEntry)] = []
        // Ordered here, not by SQLite: an ORDER BY the table's order would make it scan the whole ledger instead.
        for row in try database.rows("SELECT l.generation_id, l.occurrence, l.state, l.notified, e.id, e.feed_id, l.rowid FROM ntp_ledger l LEFT JOIN ntp_episodes n ON n.episode_id = l.occurrence JOIN episodes e ON e.id = coalesce(n.local_id, CASE WHEN l.occurrence LIKE 'local-episode:%' THEN CAST(substr(l.occurrence, 15) AS INTEGER) END) WHERE \(condition)") {
            guard let generation = row[0].text, let occurrence = row[1].text, let local = row[4].integer, let feed = row[5].integer,
                  let rowid = row[6].integer else { continue }
            result.append((rowid, .init(generation: generation, occurrence: occurrence, localID: local, feedID: feed,
                                        pending: row[2].text == "pending", notified: row[3].integer == 1)))
        }
        return result.sorted { $0.rowid < $1.rowid }.map(\.entry)
    }

    /// The local episodes of releases the automatic download takes in place of NEW episodes (PROTOCOL §9.9, §9.10): pending
    /// entries of episodes that are here, not played. Nil in a standalone library.
    public func serverReleaseCandidates() throws -> Set<Int64>? {
        guard serverContext != nil else { return nil }
        return try database.transaction(write: false) {
            Set(try serverLedgerEntries(.pending).map(\.localID))
        }
    }

    /// The automatic download is done with these releases: requested, or no longer wanted (played, gone, without
    /// media, downloaded already). A blocked attempt never calls this; its entry stays pending.
    public func finishServerReleases(_ localIDs: Set<Int64>) throws {
        guard serverContext != nil, !localIDs.isEmpty else { return }
        try write(.local) {
            for entry in try serverLedgerEntries(.pending) where localIDs.contains(entry.localID) {
                try database.execute("UPDATE ntp_ledger SET state = 'done' WHERE generation_id = ? AND occurrence = ?",
                                     [.text(entry.generation), .text(entry.occurrence)])
            }
        }
    }

    /// Releases to notify about (PROTOCOL §9.9): unnotified entries of podcasts whose notifications are on, with the
    /// podcast's title, artwork and count. The count is AntennaPod's, the podcast's NEW episodes, or the number of
    /// releases when more (a release the Inbox does not show: `queue`, `nothing`).
    public func serverReleaseNotifications() throws -> [ServerReleaseNotification] {
        guard serverContext != nil else { return [] }
        return try database.transaction(write: false) {
            var byFeed: [Int64: [ServerLedgerEntry]] = [:]
            for entry in try serverLedgerEntries(.unnotified) { byFeed[entry.feedID, default: []].append(entry) }
            var result: [ServerReleaseNotification] = []
            for (feedID, entries) in byFeed.sorted(by: { $0.key < $1.key }) {
                guard let feed = try loadFeedHeader(feedID), try !isHiddenFeed(feedID) else { continue }
                let keys = entries.map { ServerReleaseNotification.Key(generation: $0.generation, occurrence: $0.occurrence) }
                guard feed.keepUpdated, feed.showEpisodeNotification else {
                    result.append(.init(feedID: feedID, title: nil, imageURL: nil, count: 0, keys: keys))
                    continue
                }
                // NEW is −1 (`EpisodePlayState.new`); staged episodes no list shows are left out: the visible counts
                // (schema 21) once complete, else the records.
                let newCount = keyedReads
                    ? Int(try database.rows("SELECT new_count FROM feed_list_counts WHERE feed_id = ?", [.integer(feedID)]).first?.first?.integer ?? 0)
                    : Int(try database.scalar("SELECT count(*) FROM episodes WHERE feed_id = ? AND json_extract(CAST(record AS TEXT), '$.userState.playState') = -1 AND id NOT IN (SELECT episode_id FROM ntp_hidden_episodes)",
                                              [.integer(feedID)]))
                result.append(.init(feedID: feedID, title: feed.title, imageURL: feed.metadata.imageURL, count: max(newCount, entries.count), keys: keys))
            }
            return result
        }
    }

    /// The releases were notified (or need no notification: notifications off).
    public func markServerReleasesNotified(_ keys: [ServerReleaseNotification.Key]) throws {
        guard serverContext != nil, !keys.isEmpty else { return }
        try write(.local) {
            for key in keys {
                try database.execute("UPDATE ntp_ledger SET notified = 1 WHERE generation_id = ? AND occurrence = ?", [.text(key.generation), .text(key.occurrence)])
            }
        }
    }
}

/// A podcast's releases to notify about (PROTOCOL §9.9): `count` 0 means its notifications are off, and its releases
/// are only marked notified.
public struct ServerReleaseNotification: Sendable, Equatable {
    public struct Key: Sendable, Equatable, Hashable {
        public var generation: String
        public var occurrence: String
    }
    public var feedID: Int64
    public var title: String?
    public var imageURL: String?
    public var count: Int
    public var keys: [Key]
}
