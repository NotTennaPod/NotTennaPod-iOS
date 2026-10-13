import Foundation

/// One refresh's discovery batch in a server library (PROTOCOL §9.4), made by the merge and recorded in the same
/// transaction: what it observed and which of its items are releases.
struct ServerDiscoveryBatch: Sendable {
    struct Item: Sendable {
        var localID: Int64
        var key: ServerEpisodeKey
        var evidence: ServerItemEvidence
        /// The episode `metadata` record fields of this parse, and their hash.
        var fields: ContractJSON
        var hash: String
        /// The fields' canonical bytes, made with the parse.
        var canonical: [UInt8]
        var size: Int { canonical.isEmpty ? .max : canonical.count }
        /// New to this phone's replica.
        var isNew: Bool
        /// A release of this batch: observed even while observations wait for the first canonical metadata (PROTOCOL §9.4).
        var isRelease = false
    }

    var feedID: Int64
    var batchID: String
    var fetchTime: Int64
    var newestBeforeBatch: Int64?
    var feedFields: ContractJSON
    var feedHash: String
    var feedCanonical: [UInt8]
    /// The kept items, in feed order (`e0:` items are not observed).
    var items: [Item]
    /// The batch's releases, in filing order.
    var releases: [ServerRelease]
    /// A subscription's first population (PROTOCOL §15.2): nothing is proposed, and observations wait (PROTOCOL §9.4).
    var firstPopulation: Bool
}

/// A release (PROTOCOL §9.5): a playable discovery that is new to the phone's replica (or proves a gained enclosure),
/// eligible by Android's date rule, in a subscribed podcast and not its first population. Its evidence is fixed when the
/// refresh runs, so a queue filing made later (the `queueEpisodes` effect) proposes with it, also after a relaunch.
struct ServerRelease: Codable, Equatable, Sendable {
    var localID: Int64
    var batchID: String
    var pubDate: Int64?
    var newestBeforeBatch: Int64?
    /// The earlier catalog-only observation (a node) a gained enclosure is proven against.
    var gainedMedia: String?
    /// `inbox`, `queue` or `nothing`: the new-episodes action resolved through the account default.
    var action: String
    /// The policy write the action was read from.
    var policyNode: String?

    private enum CodingKeys: String, CodingKey {
        case localID = "local_id", batchID = "batch_id", pubDate = "pub_date", newestBeforeBatch = "newest_before_batch"
        case gainedMedia = "gained_media", action, policyNode = "policy_node"
    }
}

extension FeedLibraryStore {
    /// The podcast a feed of a server library is registered as, with its identity rules; nil before resolution.
    func serverPodcast(ofFeed feedID: Int64) throws -> (podcast: String, generation: String?, rules: ServerIdentityRules)? {
        guard let row = try database.rows("SELECT podcast_id, live_generation FROM ntp_podcasts WHERE feed_id = ?", [.integer(feedID)]).first,
              let podcast = row[0].text else { return nil }
        return (podcast, row[1].text, ServerIdentityRules(try serverRecord("podcast", podcast, "identity_rules")))
    }

    /// The identity evidence of a feed's local episodes (`ntp_local_items`; an episode projected from the server's
    /// records without one is described by its identity record's occurrence, else by its row).
    func serverLocalItems(of feed: LibraryFeed) throws -> [Int64: ServerEpisodeIdentity.LocalItem] {
        var result: [Int64: ServerEpisodeIdentity.LocalItem] = [:]
        for row in try database.rows("SELECT local_id, kind, value, guid, enclosure, publication_time FROM ntp_local_items WHERE feed_id = ?", [.integer(feed.id)]) {
            guard let id = row[0].integer, let kind = row[1].text, let value = row[2].text else { continue }
            result[id] = .init(localID: id, key: ServerEpisodeKey(kind: kind, value: value), guid: row[3].text, enclosure: row[4].text,
                               publicationTime: row[5].integer)
        }
        let missing = feed.episodes.filter { result[$0.id] == nil }
        guard !missing.isEmpty else { return result }
        var mapped: [Int64: (key: ServerEpisodeKey, occurrence: ContractJSON?)] = [:]
        for row in try database.rows("SELECT n.local_id, n.kind, n.value, n.occurrence FROM ntp_episodes n JOIN episodes e ON e.id = n.local_id WHERE e.feed_id = ?", [.integer(feed.id)]) {
            guard let id = row[0].integer, let kind = row[1].text, let value = row[2].text else { continue }
            mapped[id] = (ServerEpisodeKey(kind: kind, value: value), try row[3].data.map { try ContractJSON.decode($0) })
        }
        let atom = feed.metadata.format == .atom
        for episode in missing {
            let details = episode.details
            if let known = mapped[episode.id] {
                let occurrence = known.occurrence
                let evidence = ServerItemEvidence(guid: occurrence?["guid"]?.stringValue ?? details.identifier,
                                                  enclosureURL: occurrence?["enclosure_url"]?.stringValue ?? details.media?.url,
                                                  publicationTime: occurrence?["publication_time"]?.integerValue, title: nil, atom: atom)
                result[episode.id] = .init(localID: episode.id, key: known.key, guid: evidence.guid, enclosure: evidence.normalizedEnclosure,
                                           publicationTime: evidence.publicationTime)
            } else {
                let evidence = ServerItemEvidence(guid: details.identifier, enclosureURL: details.media?.url,
                                                  publicationTime: details.publicationDate.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded(.down)) },
                                                  title: nil, atom: atom)
                result[episode.id] = .init(localID: episode.id, key: evidence.plainKey ?? .none, guid: evidence.guid,
                                           enclosure: evidence.normalizedEnclosure, publicationTime: evidence.publicationTime)
            }
        }
        return result
    }

    func saveServerLocalItem(_ item: ServerEpisodeIdentity.LocalItem, feedID: Int64) throws {
        try database.execute("INSERT INTO ntp_local_items(local_id, feed_id, kind, value, guid, enclosure, publication_time) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(local_id) DO UPDATE SET guid = excluded.guid, enclosure = excluded.enclosure, publication_time = excluded.publication_time WHERE ntp_local_items.guid IS NOT excluded.guid OR ntp_local_items.enclosure IS NOT excluded.enclosure OR ntp_local_items.publication_time IS NOT excluded.publication_time",
                             [.integer(item.localID), .integer(feedID), .text(item.key.kind), .text(item.key.value),
                              item.guid.map(LibrarySQLValue.text) ?? .null, item.enclosure.map(LibrarySQLValue.text) ?? .null,
                              item.publicationTime.map(LibrarySQLValue.integer) ?? .null])
    }

    /// A subscription's first population in a server library (PROTOCOL §15.2): every item stored, as `insert` does, except
    /// repeated items, where the first per derived episode wins (the server's rule); nothing filed, nothing proposed.
    /// The episodes' identities are kept for later refreshes.
    /// Returns the kept items' identities, index for index (a reused GUID's later release its own).
    func serverFirstPopulation(_ fetched: FetchedFeed) -> (FetchedFeed, [ServerEpisodeKey]) {
        let catalog = fetched.catalog ?? ServerCatalogRecords.interim(fetched.feed)
        let count = min(catalog.items.count, fetched.feed.episodes.count)
        let reused = ServerEpisodeIdentity.batchOccurrences(catalog.items.prefix(count).enumerated().map { ($0.offset, $0.element.evidence) },
                                                            locals: [], disputed: { _ in false })
        var seen = Set<String>()
        var kept: [ParsedEpisode] = []
        var keptItems: [ServerCatalogParse.Item] = []
        var keys: [ServerEpisodeKey] = []
        for (index, item) in catalog.items.prefix(count).enumerated() {
            var key = item.evidence.plainKey
            switch reused[index] {
            case .reused(let other), .provisional(let other, _): key = other
            default: break
            }
            if let key {
                guard seen.insert(reused[index]?.identity(key) ?? "\(key.kind)\u{0}\(key.value)").inserted else { continue }
            }
            kept.append(fetched.feed.episodes[index])
            keptItems.append(item)
            keys.append(key ?? .none)
        }
        var result = fetched
        result.feed.episodes = kept
        result.catalog = ServerCatalogParse(feedFields: catalog.feedFields, items: keptItems)
        return (result, keys)
    }

    /// Records the identities of a first population's episodes (inserted in feed order by `FeedRefreshMerger.insert`).
    func saveServerFirstPopulation(_ feed: LibraryFeed, catalog: ServerCatalogParse, keys: [ServerEpisodeKey]) throws {
        for (index, (episode, item)) in zip(feed.episodes, catalog.items).enumerated() {
            let key = index < keys.count ? keys[index] : item.evidence.plainKey ?? .none
            try saveServerLocalItem(.init(localID: episode.id, key: key, guid: item.evidence.guid, enclosure: item.evidence.normalizedEnclosure,
                                          publicationTime: item.evidence.publicationTime), feedID: feed.id)
        }
    }

    /// Refresh in a server library (PROTOCOL §9). Items are matched to episodes by their derived episode
    /// (PROTOCOL §9.7), never by AntennaPod's duplicate guesses or GUID rewrite; a repeated item is skipped (the first per derived
    /// episode wins, as on the server); auto-download never forces the Inbox (PROTOCOL §9.10); the new-episodes action alone files a
    /// release, and an existing item gaining an enclosure files only if the person never acted on it. Records the
    /// batch in the capture for the recorder (observations and proposals in this transaction).
    ///
    /// Returns the merge and its episodes' identities, which the caller saves once the rows are.
    func serverMerge(_ incoming: ParsedFeed, catalog: ServerCatalogParse, into saved: LibraryFeed,
                     options: FeedRefreshOptions) throws -> (FeedRefreshResult, [ServerEpisodeIdentity.LocalItem]) {
        guard let context = serverContext else { throw ServerRecordingError.notAServerLibrary }
        var feed = saved
        feed.updateMetadata(incoming, options: options)
        let registered = try serverPodcast(ofFeed: saved.id)
        // A parse unchanged since this phone last observed it never replaces canonical metadata
        // shown since: what changed is shown until the server answers its observation; what did not
        // stays canonical.
        if let registered, try serverRecord("podcast", registered.podcast, "metadata") != nil,
           try database.rows("SELECT parse_hash FROM ntp_observed WHERE entity = 'podcast' AND id = ?", [.text("local-feed:\(saved.id)")]).first?.first?.text == catalog.feedHash {
            let shown = saved.metadata
            feed.applyCanonicalMetadata(title: shown.title, description: shown.description, author: shown.author, language: shown.language,
                                        link: shown.link, imageURL: shown.imageURL, funding: shown.funding, format: nil)
        }
        var observedHashes: [Int64: String] = [:], canonicalShown = Set<Int64>()
        if registered != nil {
            for row in try database.rows("SELECT CAST(substr(o.id, 15) AS INTEGER), o.parse_hash FROM ntp_observed o WHERE o.entity = 'episode' AND o.id IN (SELECT 'local-episode:' || id FROM episodes WHERE feed_id = ?)",
                                         [.integer(saved.id)]) {
                if let local = row[0].integer, let hash = row[1].text { observedHashes[local] = hash }
            }
            for row in try database.rows("SELECT n.local_id FROM ntp_episodes n JOIN episodes e ON e.id = n.local_id JOIN ntp_records r ON r.entity = 'episode' AND r.id = n.episode_id AND r.field_group = 'metadata' WHERE e.feed_id = ?",
                                         [.integer(saved.id)]) {
                if let local = row[0].integer { canonicalShown.insert(local) }
            }
        }
        var locals = try serverLocalItems(of: saved)
        let stored = Set(try database.rows("SELECT local_id FROM ntp_local_items WHERE feed_id = ?", [.integer(saved.id)]).compactMap { $0[0].integer })
        let original = locals
        var byWire: [String: Int64] = [:]
        if registered != nil {
            for row in try database.rows("SELECT n.episode_id, n.local_id FROM ntp_episodes n JOIN episodes e ON e.id = n.local_id WHERE e.feed_id = ?", [.integer(saved.id)]) {
                if let wire = row[0].text, let local = row[1].integer { byWire[wire] = local }
            }
        }
        func wire(_ key: ServerEpisodeKey) throws -> String? {
            guard let registered, !key.isNone else { return nil }
            return try ServerEpisodeIdentity.id(key, namespace: context.namespace, podcast: registered.podcast)
        }
        // Mapped episodes first: a plain identity finds the episode the account knows by it.
        let mappedLocals = Set(byWire.values)
        var byKey: [ServerEpisodeKey: Int64] = [:]
        for local in locals.values.sorted(by: { a, b in
            let ma = mappedLocals.contains(a.localID), mb = mappedLocals.contains(b.localID)
            return ma != mb ? ma : a.localID < b.localID
        }) where !local.key.isNone && byKey[local.key] == nil { byKey[local.key] = local.localID }
        // The wire IDs of episodes no mapping names yet, derived once, only when an item's derivation needs them.
        var derivedUnmapped = false
        func unmappedWires() throws {
            guard !derivedUnmapped else { return }
            derivedUnmapped = true
            for local in locals.values where !local.key.isNone && !mappedLocals.contains(local.localID) {
                if let id = try wire(local.key), byWire[id] == nil { byWire[id] = local.localID }
            }
        }
        let existing = Dictionary(saved.episodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // 1. Identity in fetch order, the first item per derived episode kept (`S/internal/ops/catalog.go`).
        struct Resolved { var index: Int; var key: ServerEpisodeKey; var match: Int64?; var provisional = false }
        var resolved: [Resolved] = []
        var taken = Set<String>(), takenLocal = Set<Int64>()
        // Reused GUIDs the server has not disputed, resolved with the whole fetch's evidence first.
        let reusedOccurrences = ServerEpisodeIdentity.batchOccurrences(
            catalog.items.prefix(incoming.episodes.count).enumerated().filter { !$0.element.evidence.isUnidentifiable }.map { ($0.offset, $0.element.evidence) },
            locals: Array(locals.values), disputed: { registered?.rules.disputedGUIDs[$0] != nil })
        for (index, item) in catalog.items.enumerated() where index < incoming.episodes.count {
            let evidence = item.evidence
            if evidence.isUnidentifiable {
                // An `e0:` item keeps its episode by AntennaPod's identifying value (its title, else its link).
                let value = EpisodeDuplicateMatcher.identifyingValue(incoming.episodes[index])
                let match = saved.episodes.first { episode in
                    locals[episode.id]?.key.isNone == true && !takenLocal.contains(episode.id)
                        && value != nil && EpisodeDuplicateMatcher.identifyingValue(episode.details).map { $0.utf16.elementsEqual(value!.utf16) } == true
                }?.id
                if let match { takenLocal.insert(match) }
                resolved.append(Resolved(index: index, key: .none, match: match))
                continue
            }
            var key = evidence.plainKey!
            var match: Int64?
            var derived: String?
            // The podcast's rules decide only an item they name, or a new one; otherwise its plain identity does.
            if let registered, registered.rules.concern(evidence) || byKey[key] == nil,
               let result = try ServerEpisodeIdentity.derive(evidence, rules: registered.rules, namespace: context.namespace,
                                                             podcast: registered.podcast) {
                try unmappedWires()
                key = result.key
                derived = result.episodeID
                match = byWire[result.episodeID]
            } else {
                match = byKey[key]
            }
            // A reused GUID seen first on the phone (PROTOCOL §9.7), unless the server's rules already dispute it.
            var provisional: String?
            if let local = reusedOccurrences[index] {
                switch local {
                case .existing(let id): match = id
                case .reused(let reusedKey):
                    try unmappedWires()
                    key = reusedKey
                    derived = try wire(reusedKey)
                    match = derived.flatMap { byWire[$0] } ?? byKey[reusedKey]
                case .provisional(let provisionalKey, _):
                    // A release of its own until the server's mapping names it.
                    key = provisionalKey
                    derived = nil
                    match = nil
                    provisional = local.identity(provisionalKey)
                }
            }
            let identity = provisional ?? derived ?? "\(key.kind)\u{0}\(key.value)"
            guard taken.insert(identity).inserted, match.map({ takenLocal.insert($0).inserted }) ?? true else { continue }
            resolved.append(Resolved(index: index, key: key, match: match, provisional: provisional != nil))
        }

        // 2. Probable GUID changes: observed, neither proposed nor filed (PROTOCOL §9.5).
        var wireOf: [Int64: String] = [:]
        for (id, local) in byWire where wireOf[local] == nil { wireOf[local] = id }
        let matched = Set(resolved.compactMap(\.match))
        // Only an episode titled as a new item can match one (a large feed lists few of its episodes; most vanished).
        let newTitles = Set(resolved.filter { $0.match == nil }.compactMap { catalog.items[$0.index].fields["title"]?.stringValue })
        let vanished = try saved.episodes.filter {
            !matched.contains($0.id) && locals[$0.id]?.key.isNone == false && $0.details.title.map(newTitles.contains) == true
        }.map { episode -> (title: String?, publicationTime: Int64?) in
            if let wire = wireOf[episode.id], let canonical = try serverRecord("episode", wire, "metadata") {
                return (canonical["title"]?.stringValue, canonical["pub_date"]?.integerValue)
            }
            return (episode.details.title, locals[episode.id]?.publicationTime)
        }
        let guidChanges = ServerEpisodeIdentity.probableGUIDChanges(
            items: resolved.map { (catalog.items[$0.index].evidence.guid, catalog.items[$0.index].fields["title"]?.stringValue,
                                   catalog.items[$0.index].evidence.publicationTime, $0.match == nil) },
            vanished: vanished)
        let changedGUID = Set(guidChanges.map { resolved[$0].index })

        // 3. Rows and filings, in AntennaPod's order (newest first, undated first), so a queue filing keeps it.
        let order = resolved.enumerated().sorted { lhs, rhs in
            let a = incoming.episodes[lhs.element.index].publicationDate, b = incoming.episodes[rhs.element.index].publicationDate
            switch (a, b) {
            case (nil, nil): return lhs.offset < rhs.offset
            case (nil, _): return true
            case (_, nil): return false
            case (let a?, let b?): return a == b ? lhs.offset < rhs.offset : a > b
            }
        }.map(\.element)
        let subscribed = saved.subscriptionState == .subscribed
        let newestBefore = try saved.episodes.compactMap(\.details.publicationDate).filter { $0 > Date(timeIntervalSince1970: 0) }.max()
            .map(milliseconds) ?? milliseconds(options.now)
        var action = saved.newEpisodesAction == .global ? options.globalNewEpisodesAction : saved.newEpisodesAction
        if action == .global { action = .inbox }
        let actionName = Self.wire(action).stringValue ?? "inbox"
        let policyNode = try discoveryPolicyNode(feed: saved)
        let queued = Set(try queueEpisodeIDs())
        var rows = existing
        var orderIDs = saved.episodes.map(\.id)
        var localOf: [Int: Int64] = [:]
        var batchItems: [Int64: ServerDiscoveryBatch.Item] = [:]
        var releases: [ServerRelease] = []
        var queue: [Int64] = []
        let batchID = ContractIdentity.randomUUID()
        for (rank, entry) in order.enumerated() {
            let item = incoming.episodes[entry.index], record = catalog.items[entry.index]
            let localID: Int64
            var release = false
            var gained: String?
            if let match = entry.match, let stored = existing[match] {
                localID = match
                var episode = stored
                if !(canonicalShown.contains(match) && observedHashes[match] == record.hash) { episode.update(from: item) }
                // AntennaPod makes an episode that gains media NEW whatever it was; in server mode only the rule below files.
                episode.userState.playState = stored.userState.playState
                if stored.details.media == nil, episode.details.media != nil, record.isPlayable, subscribed {
                    // Gained media (PROTOCOL §9.5): filed only when the person never acted on it, never played → new. An explicit
                    // state leaves no trace in the row's values, so its durable evidence decides too.
                    let explicit = try hasExplicitFilingState(localID: match, wire: wireOf[match])
                    let untouched = stored.userState.playState == .unplayed && !queued.contains(match) && stored.userState.positionMilliseconds == 0
                        && stored.userState.lastPlayedTimeMilliseconds == 0 && stored.userState.lastPlayedHistoryMilliseconds == nil && !explicit
                    gained = try gainedMediaEvidence(localID: match, wire: wireOf[match])
                    let dated = record.evidence.publicationTime.map { $0 >= newestBefore } ?? true
                    release = untouched && (dated || gained != nil)
                    if release, action == .inbox { episode.userState.playState = .new }
                }
                rows[match] = episode
                locals[match] = .init(localID: match, key: locals[match]?.key ?? entry.key, guid: record.evidence.guid,
                                      enclosure: record.evidence.normalizedEnclosure, publicationTime: record.evidence.publicationTime)
            } else {
                localID = try database.allocateID("episode")
                var episode = LibraryEpisode(id: localID, details: item)
                if subscribed, record.isPlayable, !changedGUID.contains(entry.index),
                   record.evidence.publicationTime.map({ $0 >= newestBefore }) ?? true {
                    release = true
                    if action == .inbox { episode.userState.playState = .new }
                }
                rows[localID] = episode
                orderIDs.insert(localID, at: min(rank, orderIDs.count))
                locals[localID] = .init(localID: localID, key: entry.key, guid: record.evidence.guid,
                                        enclosure: record.evidence.normalizedEnclosure, publicationTime: record.evidence.publicationTime)
                if !entry.provisional, let registered, let id = try wire(entry.key) {
                    try database.execute("INSERT INTO ntp_episodes(episode_id, local_id, podcast_id, kind, value) VALUES (?, ?, ?, ?, ?) ON CONFLICT(episode_id) DO UPDATE SET local_id = coalesce(local_id, excluded.local_id)",
                                         [.text(id), .integer(localID), .text(registered.podcast), .text(entry.key.kind), .text(entry.key.value)])
                }
            }
            localOf[entry.index] = localID
            if !entry.key.isNone {
                batchItems[localID] = .init(localID: localID, key: entry.key, evidence: record.evidence, fields: record.fields,
                                            hash: record.hash, canonical: record.canonical, isNew: entry.match == nil, isRelease: release)
            }
            if release {
                releases.append(ServerRelease(localID: localID, batchID: batchID, pubDate: record.evidence.publicationTime,
                                              newestBeforeBatch: newestBefore, gainedMedia: gained, action: actionName, policyNode: policyNode))
                if action == .queue { queue.append(localID) }
            }
        }
        var episodes: [LibraryEpisode] = []
        episodes.reserveCapacity(orderIDs.count)
        for id in orderIDs {
            guard var episode = rows[id] else { continue }
            if episode.details.publicationDate == nil { episode.details.publicationDate = options.now }
            if episode.details.chapters != nil { episode.hasStoredChapters = true }
            episodes.append(episode)
        }
        feed.episodes = episodes
        activeCapture?.discovery = ServerDiscoveryBatch(
            feedID: saved.id, batchID: batchID, fetchTime: try milliseconds(options.refreshAttempt), newestBeforeBatch: newestBefore,
            feedFields: catalog.feedFields, feedHash: catalog.feedHash, feedCanonical: catalog.feedCanonical, items: resolved.compactMap { localOf[$0.index].flatMap { batchItems[$0] } },
            releases: releases, firstPopulation: false)
        var result = FeedRefreshResult(feed: feed, queueEpisodeIDs: queue, removedEpisodes: [], duplicates: [], completedEpisodeSync: [])
        result.serverItems = Dictionary(localOf.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        // Only identities that are new or whose evidence changed are written.
        return (result, orderIDs.compactMap { id in
            guard let item = locals[id], !stored.contains(id) || original[id] != item else { return nil }
            return item
        })
    }

    /// Durable evidence that someone acted on an episode's filing: its `play_state` or
    /// `queue_membership` record, or a pending fact or draft changing either.
    func hasExplicitFilingState(localID: Int64, wire: String?) throws -> Bool {
        if let wire, try database.scalar("SELECT count(*) FROM ntp_records WHERE entity = 'episode' AND id = ? AND field_group IN ('play_state', 'queue_membership')",
                                         [.text(wire)]) > 0 { return true }
        let ids = ContractJSON.array(([wire, Self.ledgerKey(localEpisode: localID)].compactMap { $0 }).map(ContractJSON.string))
        return try database.scalar("SELECT count(*) FROM ntp_overlays WHERE entity = 'episode' AND id IN (SELECT value FROM json_each(?)) AND property IN ('play_state', 'queue_membership')",
                                   [.text(ids.canonicalText)]) > 0
    }

    /// A record of the base (`ntp_records`).
    func serverRecord(_ entity: String, _ id: String, _ group: String) throws -> ContractJSON? {
        guard let data = try database.rows("SELECT value FROM ntp_records WHERE entity = ? AND id = ? AND field_group = ?",
                                           [.text(entity), .text(id), .text(group)]).first?.first?.data else { return nil }
        return try ContractJSON.decode(data)
    }

    /// The observation that saw an episode without an enclosure (PROTOCOL §9.4): the canonical record's revision when it has no
    /// media, else this phone's own catalog-only observation. Nil without evidence.
    func gainedMediaEvidence(localID: Int64, wire: String?) throws -> String? {
        if let wire, let canonical = try serverRecord("episode", wire, "metadata"), canonical["media"]?.isNull ?? true,
           let revision = canonical["revision"]?.stringValue, ContractIdentity.isUUID(revision) { return revision }
        return try database.rows("SELECT catalog_node FROM ntp_observed WHERE entity = 'episode' AND id = ?", [.text("local-episode:\(localID)")]).first?.first?.text
    }

    /// The policy write a discovery's action was read from (PROTOCOL §9.4 `policy_node`): this library's pending change of it,
    /// else the record's provenance; the account's when the podcast follows the global action. Nil when unknown.
    func discoveryPolicyNode(feed: LibraryFeed) throws -> String? {
        guard let context = serverContext else { return nil }
        let (entity, id, property, group): (String, String, String, String)
        if feed.newEpisodesAction == .global {
            (entity, id, property, group) = ("account", context.accountID, "new_episodes_action", "discovery_policy")
        } else {
            guard let podcast = try serverPodcast(ofFeed: feed.id)?.podcast else { return nil }
            (entity, id, property, group) = ("podcast", podcast, "new_episodes_action", "policy")
        }
        if let pending = try database.rows("SELECT op_id FROM ntp_overlays WHERE entity = ? AND id = ? AND property = ? ORDER BY clock DESC LIMIT 1",
                                           [.text(entity), .text(id), .text(property)]).first?.first?.text { return pending }
        return try provenance(entity: entity, id: id, groups: [group]).last
    }
}

extension ServerSyncEngine {
    /// `POST /v1/refresh` (PROTOCOL §9): `{podcast_id}` for a podcast the account knows, no body for all. The answer
    /// (each podcast's status) is not waited for or used; a failure changes nothing.
    public func requestServerRefresh(feedID: Int64?) async {
        var body: ContractJSON?
        if let feedID {
            guard let podcast = try? await store.serverPodcastID(ofFeed: feedID) else { return }
            body = ["podcast_id": .string(podcast)]
        }
        _ = try? await transport.send("POST", "v1/refresh", body: body)
    }
}

extension FeedLibraryStore {
    /// The podcast a feed is registered as in a server library (nil for a local folder, a preview the account does
    /// not know, or a pending registration).
    func serverPodcastID(ofFeed feedID: Int64) throws -> String? {
        guard serverContext != nil else { return nil }
        return try database.rows("SELECT podcast_id FROM ntp_podcasts WHERE feed_id = ? AND live_generation IS NOT NULL", [.integer(feedID)]).first?.first?.text
    }
}
