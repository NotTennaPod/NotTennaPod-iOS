import CryptoKit
import Foundation

/// An unchanged refresh decodes no stored episodes.
///
/// A feed's memo (`feed_refresh_memo`) records that a full merge of a parse, with given inputs, into the feed's stored
/// episodes (as `feed_changes.details_generation` names them) was a fixed point: it wrote no episode, inserted and removed
/// none, logged no duplicate, filed and proposed nothing, and in a server library wrote nothing to the server tables its
/// episodes are matched and observed by. Any write to those tables, in that transaction or later, retires the memo
/// (`ServerExchangeTables.refreshMemoTriggers`). A later refresh with the same parse and inputs, the same stored details
/// and none of those writes since meets the same fixed point, so it writes only what that merge would have written: the
/// header by the merge's own rule, the recovery log entry and a followed redirect. Episode user state (playback, marks)
/// never enters a fixed point's merge, so it does not retire the memo; a details change, an insert, a removal or a move
/// of an episode moves the details generation and does.
///
/// Always merged, never memoized: a page other than the first, a local folder, a parse that cannot be digested (an
/// unserializable record), a server library without the memo's triggers, and an ambiguous pool: stored or incoming
/// episodes sharing an identifying value or a media address, a repeated or unidentifiable item, or derived episodes
/// that collide.
extension FeedLibraryStore {
    enum RefreshMemoDecision {
        /// Identical to the feed's last applied refresh: its stored header, to be updated.
        case unchanged(LibraryFeed)
        /// A full merge, with the digests of a memo it may prove (nil when the refresh is never memoized).
        case merge(RefreshMemoCandidate?)
    }

    struct RefreshMemoCandidate {
        let parse: Data
        let inputs: Data
    }

    /// A full merge's armed memo: the stored feed it merges into and its details generation then.
    struct ArmedRefreshMemo {
        let before: LibraryFeed
        let detailsGeneration: Int64
    }

    static let refreshMemoVersion = "refresh-memo-1"

    /// SHA-256 of the parse: its sorted-keys encoding and, when the fetch made one, its record-level parse (the feed
    /// record's hash, and each item's hash and identity evidence). Nil when an item record cannot be serialized.
    static func refreshParseDigest(_ fetched: FetchedFeed) -> Data? {
        var digest = RefreshDigest()
        digest.add(refreshMemoVersion)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let feed = try? encoder.encode(fetched.feed) else { return nil }
        digest.add(feed)
        if let catalog = fetched.catalog {
            guard !catalog.feedHash.isEmpty, catalog.items.allSatisfy({ !$0.hash.isEmpty }) else { return nil }
            digest.add("catalog")
            digest.add(catalog.feedHash)
            digest.add(String(catalog.items.count))
            for item in catalog.items {
                let evidence = item.evidence
                digest.add(item.hash)
                digest.add(evidence.guid)
                digest.add(evidence.enclosureURL)
                digest.add(evidence.publicationTime.map { String($0) })
                digest.add(evidence.title)
                digest.add(evidence.atom ? "atom" : "rss")
            }
        } else {
            digest.add("no catalog")
        }
        return digest.finish()
    }

    /// SHA-256 of what the merge reads besides the parse and the stored episodes: the refresh options, the header's
    /// subscription and new-episode settings and format, and in a server library the podcast's binding, mapping, identity
    /// rules and hidden state. Keyed reads only.
    func refreshInputsDigest(header: LibraryFeed, options: FeedRefreshOptions) throws -> Data {
        var digest = RefreshDigest()
        digest.add(Self.refreshMemoVersion)
        digest.add(options.removeUnlistedItems ? "remove unlisted" : "keep unlisted")
        digest.add(String(options.globalNewEpisodesAction.rawValue))
        digest.add(options.globalAutoDownload ? "auto-download" : "no auto-download")
        digest.add(options.timeZone.identifier)
        digest.add(String(header.subscriptionState.rawValue))
        digest.add(String(header.newEpisodesAction.rawValue))
        digest.add(String(header.autoDownload.rawValue))
        digest.add(header.metadata.format.rawValue)
        guard let context = serverContext else {
            digest.add("standalone")
            return digest.finish()
        }
        digest.add("server")
        digest.add(context.namespace)
        digest.add(String(describing: try storedBinding(header.id, isLocalFolder: false)))
        if let row = try database.rows("SELECT podcast_id, live_generation, pinned_removal FROM ntp_podcasts WHERE feed_id = ?", [.integer(header.id)]).first {
            digest.add(row[0].text)
            digest.add(row[1].text)
            digest.add(row[2].integer.map { String($0) })
            if let podcast = row[0].text {
                digest.add(try database.rows("SELECT value FROM ntp_records WHERE entity = 'podcast' AND id = ? AND field_group = 'identity_rules'",
                                             [.text(podcast)]).first?.first?.data)
            }
        } else {
            digest.add("no podcast")
        }
        digest.add(try database.rows("SELECT state FROM ntp_hidden_feeds WHERE feed_id = ?", [.integer(header.id)]).first?.first?.text)
        return digest.finish()
    }

    /// Inside the refresh's transaction: whether it is identical to the feed's last applied one. Reads the memo, the
    /// details generation, the header and the inputs (keyed); never an episode.
    func refreshMemo(_ fetched: FetchedFeed, feedID: Int64, options: FeedRefreshOptions) throws -> RefreshMemoDecision {
        guard refreshMemoEnabled else { return .merge(nil) }
        guard options.pageNumber == 0, !options.isLocalFeed, !fetched.source.isLocalFeedSource,
              let header = try loadFeedHeader(feedID), header.pageNumber == 0, !header.source.isLocalFeedSource,
              try refreshMemoTriggersInstalled(),
              let parse = fetched.parseDigest ?? Self.refreshParseDigest(fetched) else {
            try retireRefreshMemo(feedID: feedID)
            return .merge(nil)
        }
        let inputs = try refreshInputsDigest(header: header, options: options)
        if let row = try database.rows("SELECT parse_digest, inputs_digest, details_generation FROM feed_refresh_memo WHERE feed_id = ?",
                                       [.integer(feedID)]).first,
           let storedParse = row[0].data, let storedInputs = row[1].data, let generation = row[2].integer,
           storedParse == parse, storedInputs == inputs, generation == (try detailsGeneration(feedID: feedID)) {
            return .unchanged(header)
        }
        return .merge(RefreshMemoCandidate(parse: parse, inputs: inputs))
    }

    /// The memo of a refresh identical to the last applied one: the header as the merge writes it, the recovery log entry
    /// and a followed redirect; no episode is read or written, nothing is filed or observed. A server library's listed
    /// observations are recorded afterwards as after a 304 (`FeedRefreshService`).
    func applyUnchangedRefresh(_ fetched: FetchedFeed, header: LibraryFeed, options: FeedRefreshOptions) throws -> FeedRefreshResult {
        var settings = options
        settings.validator = fetched.validator
        var feed = header
        if serverContext != nil {
            let catalog = fetched.catalog ?? ServerCatalogRecords.interim(fetched.feed)
            feed = try serverRefreshedHeader(fetched.feed, catalog: catalog, saved: header,
                                             registered: try serverPodcast(ofFeed: header.id)?.podcast, options: settings)
        } else {
            feed.updateMetadata(fetched.feed, options: settings)
        }
        try saveHeader(feed)
        var result = FeedRefreshResult(feed: feed, queueEpisodeIDs: [], removedEpisodes: [], duplicates: [], completedEpisodeSync: [])
        result.itemsUnchanged = true
        try recordRefreshRecovery(fetched, feedID: header.id, options: options, feed: &result.feed)
        unchangedRefreshes += 1
        return result
    }

    /// Before a full merge that may prove the feed unchanged: an empty memo row, which the server tables' triggers delete
    /// when the merge writes to them, and the stored feed (the merge starts from it).
    func armRefreshMemo(feedID: Int64) throws -> ArmedRefreshMemo? {
        try database.execute("INSERT INTO feed_refresh_memo(feed_id) VALUES (?) ON CONFLICT(feed_id) DO UPDATE SET parse_digest = NULL, inputs_digest = NULL, details_generation = NULL, repeated_duplicates = NULL",
                             [.integer(feedID)])
        let generation = try detailsGeneration(feedID: feedID)
        return try loadFeed(feedID).map { ArmedRefreshMemo(before: $0, detailsGeneration: generation) }
    }

    /// After the full merge: the memo when the merge was a fixed point and its armed row is still there, else none.
    /// The recorder runs later in the same transaction; what it writes to the server tables retires the memo again.
    func settleRefreshMemo(_ candidate: RefreshMemoCandidate, before armed: ArmedRefreshMemo?, result: FeedRefreshResult,
                           fetched: FetchedFeed) throws {
        let feedID = result.feed.id
        guard let armed, try detailsGeneration(feedID: feedID) == armed.detailsGeneration,
              try refreshWasFixedPoint(before: armed.before, result: result, fetched: fetched) else {
            try retireRefreshMemo(feedID: feedID)
            return
        }
        try database.execute("UPDATE feed_refresh_memo SET parse_digest = ?, inputs_digest = ?, details_generation = ? WHERE feed_id = ?",
                             [.blob(candidate.parse), .blob(candidate.inputs), .integer(armed.detailsGeneration), .integer(feedID)])
    }

    func retireRefreshMemo(feedID: Int64) throws {
        try database.execute("DELETE FROM feed_refresh_memo WHERE feed_id = ?", [.integer(feedID)])
    }

    /// The merge changed no episode and had nothing to log, file, sync or observe, over an unambiguous pool.
    private func refreshWasFixedPoint(before: LibraryFeed, result: FeedRefreshResult, fetched: FetchedFeed) throws -> Bool {
        guard result.removedEpisodes.isEmpty, result.duplicates.isEmpty, result.completedEpisodeSync.isEmpty, result.queueEpisodeIDs.isEmpty,
              activeCapture?.discovery?.releases.isEmpty ?? true,
              result.feed.episodes == before.episodes,
              !Self.ambiguousPool(stored: before.episodes.map(\.details), incoming: fetched.feed.episodes) else { return false }
        guard serverContext != nil else { return true }
        // A server library matches items by derived episode: every item identifiable, kept and its own.
        let catalog = fetched.catalog ?? ServerCatalogRecords.interim(fetched.feed)
        guard catalog.items.count == fetched.feed.episodes.count, !catalog.feedHash.isEmpty,
              result.serverItems.count == catalog.items.count else { return false }
        var keys = Set<String>(), guids = Set<String>()
        for item in catalog.items {
            guard !item.hash.isEmpty, let key = item.evidence.plainKey, keys.insert(key.kind + "\u{0}" + key.value).inserted else { return false }
            if let guid = item.evidence.guid, !guids.insert(guid).inserted { return false }
        }
        var localKeys = Set<String>(), localGUIDs = Set<String>()
        for local in try serverLocalItems(of: before).values where !local.key.isNone {
            guard localKeys.insert(local.key.kind + "\u{0}" + local.key.value).inserted else { return false }
            if let guid = local.guid, !localGUIDs.insert(guid).inserted { return false }
        }
        return true
    }

    /// Stored or incoming episodes that share an identifying value (AntennaPod's item identity) or a media address: the
    /// duplicate pool's matches depend on their order.
    static func ambiguousPool(stored: [ParsedEpisode], incoming: [ParsedEpisode]) -> Bool {
        func repeats(_ values: [String?]) -> Bool {
            var seen = Set<[UInt16]>()
            for case let value? in values where !value.isEmpty {
                if !seen.insert(Array(value.utf16)).inserted { return true }
            }
            return false
        }
        return [stored, incoming].contains { episodes in
            repeats(episodes.map(EpisodeDuplicateMatcher.identifyingValue)) || repeats(episodes.map { $0.media?.url })
        }
    }

    func detailsGeneration(feedID: Int64) throws -> Int64 {
        try database.scalar("SELECT coalesce((SELECT details_generation FROM feed_changes WHERE feed_id = ?), 0)", [.integer(feedID)])
    }

    /// In a server library, whether its server tables carry the memo's triggers (checked once per opening).
    private func refreshMemoTriggersInstalled() throws -> Bool {
        guard serverContext != nil else { return true }
        if let known = refreshMemoGuarded { return known }
        let names = ContractJSON.array(ServerExchangeTables.refreshMemoTriggers.map { .string($0.name) }).canonicalText
        let installed = try database.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'trigger' AND name IN (SELECT value FROM json_each(?))",
                                            [.text(names)]) == ServerExchangeTables.refreshMemoTriggers.count
        refreshMemoGuarded = installed
        return installed
    }
}

/// SHA-256 over length-prefixed parts, so no two different part lists hash alike.
struct RefreshDigest {
    private var hasher = SHA256()

    mutating func add(_ data: Data) {
        var count = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &count) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
    }

    mutating func add(_ data: Data?) {
        guard let data else { add(Data([0])); return }
        add(Data([1]) + data)
    }

    mutating func add(_ text: String) { add(Data(text.utf8)) }

    mutating func add(_ text: String?) { add(text.map { Data($0.utf8) }) }

    func finish() -> Data { Data(hasher.finalize()) }
}
