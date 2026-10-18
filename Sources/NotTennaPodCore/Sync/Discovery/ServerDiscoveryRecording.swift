import Foundation

/// The facts of refresh and discovery in a server library (PROTOCOL §9.4), recorded by the recorder in
/// the transaction that stores the refresh or files its releases: `catalog.observe` for what changed, then one
/// `discovery.propose` per release; `queue` proposals with the transaction that consumes the `queueEpisodes` effect.
extension FeedLibraryStore {
    /// Items at most per observation fact: the server's own refresh parts' size (PROTOCOL §9.4).
    static let observationItems = 200
    /// An observation fact's size in canonical bytes at most, under the default unframed bound (PROTOCOL §6.4 256 KiB);
    /// a single larger item goes alone and is framed by the pusher. Each item counts with its whole entry: its fields
    /// and its occurrence (which repeats the title) exactly, the rest as `observationEntryOverhead`; the fact's envelope
    /// and the feed record count with the chunk.
    static let observationBytes = 240 << 10
    /// An entry's bytes besides its fields and occurrence, at most: the episode, podcast and generation IDs, `base`, its
    /// target, a dependency, and the keys (about 480 bytes).
    static let observationEntryOverhead = 600
    /// A fact's envelope besides its items, at most (op and author IDs, sequence, type, times, the podcast target).
    static let observationFactOverhead = 2 << 10
    /// An item larger than this, with its occurrence and entry, is never observed (nor one over half the fact bound the
    /// server advertises, PROTOCOL §6.13): the server's own fetch covers it, and the outbox is never blocked by it.
    static let observationItemLimit = 4 << 20
    /// How long a newly registered podcast's observations wait for its first canonical metadata (PROTOCOL §9.4).
    static let firstPopulationWait: Int64 = 10 * 60_000

    /// A refresh's facts (`.refresh`, and an identity match merged by `.subscribe` or `.preview`): its observations, its
    /// `inbox` and `nothing` proposals with their local filing's overlays, and every release's ledger entry. A
    /// subscription's first population, a preview the account does not know and a local folder record nothing.
    func mapDiscovery(_ s: RecordingSession) throws {
        defer { accountDiscovery(s) }
        guard let batch = s.capture.discovery, !batch.firstPopulation else { return }
        let binding = try binding(batch.feedID, s)
        switch binding {
        case .registered, .pending: break
        case .localFolder, .unregistered: return
        }
        let observations = try observe(batch, binding: binding, s)
        for release in batch.releases where release.action != "queue" {
            let op = try propose(release, binding: binding, bundle: nil, dependencies: observations, s)
            try noteLedger(release, binding: binding, proposal: op, s)
        }
        // A queue release is proposed when its filing is consumed (PROTOCOL §9.5); its entry is the refresh's.
        for release in batch.releases where release.action == "queue" {
            try noteLedger(release, binding: binding, proposal: nil, s)
        }
    }

    /// What a refresh may change: insert episodes, file releases (NEW), follow a permanent redirect (no fact, PROTOCOL §9.7),
    /// and remove episodes a local folder no longer lists.
    private func accountDiscovery(_ s: RecordingSession) {
        for change in s.pending {
            switch change {
            case .episodeInserted, .episodeDeleted, .episode(_, .playState), .feed(_, .source), .queueOut, .queueOrder:
                s.account(change)
            default: break
            }
        }
    }

    // MARK: - Observations (PROTOCOL §9.4)

    /// `catalog.observe` for the records new to this phone's replica or whose own parse changed since it last observed
    /// them and that differ from the canonical record it holds (whole records, `base` the canonical revision). A
    /// newly registered podcast's observations wait for its first canonical metadata (10 minutes at most), except its
    /// releases'. A large batch's records other than its releases' are listed in `ntp_observation_work` and recorded
    /// after this transaction, 200 to a bounded transaction (PROTOCOL §6.8, `recordDeferredObservations`). Returns the op IDs
    /// recorded here (proposals follow them).
    private func observe(_ batch: ServerDiscoveryBatch, binding: PodcastBinding, _ s: RecordingSession) throws -> [String] {
        var podcast: String?
        if case .registered(let id, _) = binding { podcast = id }
        let canonicalFeed = try podcast.flatMap { try serverRecord("podcast", $0, "metadata") }
        var waiting = false
        if let podcast, canonicalFeed == nil,
           let registered = try database.rows("SELECT max(created_at) FROM ntp_registrations WHERE feed_id = ? OR podcast_id = ?",
                                               [.integer(batch.feedID), .text(podcast)]).first?.first?.integer {
            waiting = s.now - registered < Self.firstPopulationWait
        }
        var feedRecord: ContractJSON?
        let feedKey = "local-feed:\(batch.feedID)"
        let feedHash = batch.feedHash
        if try observedHash("podcast", feedKey) != feedHash {
            if waiting {
                // Recorded once the wait ends, with this parse.
                try listObservations(feedID: batch.feedID, batchID: batch.batchID, fetchTime: batch.fetchTime,
                                     entries: [.init(localID: nil, key: nil, evidence: nil, hash: feedHash, canonical: batch.feedCanonical)], writer: s.writer)
            } else {
                if ServerCatalogRecords.fields(ofCanonical: canonicalFeed) != batch.feedFields {
                    var record: ContractObject = ["fields": batch.feedFields]
                    if let revision = canonicalFeed?["revision"]?.stringValue { record["base"] = .string(revision) }
                    feedRecord = .object(record)
                }
                try noteObservedFeed(batch.feedID, hash: feedHash, s)
            }
        }
        // The batch's last observed hashes: as the merge read them in this transaction, else in one read.
        var hashes: [String: String] = [:]
        if let observed = batch.observedHashes {
            for item in batch.items { if let hash = observed[item.localID] { hashes[Self.ledgerKey(localEpisode: item.localID)] = hash } }
        } else {
            for chunk in Self.chunks(batch.items.map { ContractJSON.string(Self.ledgerKey(localEpisode: $0.localID)) }) {
                for row in try database.rows("SELECT id, parse_hash FROM ntp_observed WHERE entity = 'episode' AND id IN (SELECT value FROM json_each(?))",
                                             [.text(ContractJSON.array(chunk).canonicalText)]) {
                    if let id = row[0].text, let hash = row[1].text { hashes[id] = hash }
                }
            }
        }
        var changed = batch.items.filter { hashes[Self.ledgerKey(localEpisode: $0.localID)] != $0.hash }
        let others = changed.filter { !$0.isRelease }
        // While the podcast waits for its first canonical metadata, or for a large batch, the records besides the
        // releases are listed and recorded later (PROTOCOL §6.8).
        if waiting || others.count > Self.observationItems {
            try listObservations(feedID: batch.feedID, batchID: batch.batchID, fetchTime: batch.fetchTime,
                                 entries: others.map { .init(localID: $0.localID, key: $0.key, evidence: $0.evidence, hash: $0.hash, canonical: $0.canonical) },
                                 writer: s.writer)
            changed = changed.filter(\.isRelease)
        }
        return try emitObservations(changed, feedRecord: feedRecord, batchID: batch.batchID, fetchTime: batch.fetchTime, binding: binding, s)
    }

    /// The observation facts of changed records: each compared with the canonical record it would replace (an equal
    /// one is noted as observed and not sent), chunked within the fact bounds (PROTOCOL §15.2, §9.4), the feed record with the
    /// first. Returns their op IDs.
    private func emitObservations(_ changed: [ServerDiscoveryBatch.Item], feedRecord: ContractJSON?, batchID: String, fetchTime: Int64,
                                  binding: PodcastBinding, _ s: RecordingSession) throws -> [String] {
        // Within the bound the server advertises (PROTOCOL §6.13): an item, or the podcast's own record, too large for a fact
        // of its own is not observed (the server's own fetch covers it); the log says so, and everything else is observed. The
        // bound is read only when something is to be observed (an unchanged refresh observes nothing).
        var feedRecord = feedRecord
        if let record = feedRecord, try record.canonicalBytes().count + Self.observationFactOverhead > min(Self.observationBytes, s.writer.factBound / 2) {
            let bytes = try record.canonicalBytes().count
            s.capture.afterCommit.append { $0.noteServerDiagnostic("too_large", "catalog.observe podcast record \(bytes) bytes: not observed") }
            feedRecord = nil
        }
        var skipped = 0
        defer {
            if skipped > 0 {
                let count = skipped
                s.capture.afterCommit.append { $0.noteServerDiagnostic("too_large", "catalog.observe \(count) items: not observed") }
            }
        }
        var podcast: String?
        if case .registered(let id, _) = binding { podcast = id }
        var items: [(item: ServerDiscoveryBatch.Item, record: ContractJSON, size: Int, wire: String?)] = []
        var notes: [ObservedNote] = []
        // The records' wire IDs and canonical records in a read per 500; an episode not mapped yet derives its own.
        var wires: [Int64: String] = [:], canonicals: [String: ContractJSON] = [:]
        if podcast != nil {
            for chunk in Self.chunks(changed.map { ContractJSON.integer($0.localID) }) {
                for row in try database.rows("SELECT local_id, episode_id FROM ntp_episodes WHERE local_id IN (SELECT value FROM json_each(?))",
                                             [.text(ContractJSON.array(chunk).canonicalText)]) {
                    if let local = row[0].integer, let wire = row[1].text { wires[local] = wire }
                }
            }
            for chunk in Self.chunks(wires.values.sorted().map(ContractJSON.string)) {
                for row in try database.rows("SELECT id, value FROM ntp_records WHERE entity = 'episode' AND field_group = 'metadata' AND id IN (SELECT value FROM json_each(?))",
                                             [.text(ContractJSON.array(chunk).canonicalText)]) {
                    if let id = row[0].text, let data = row[1].data { canonicals[id] = try ContractJSON.decode(data) }
                }
            }
        }
        for item in changed {
            let wire: String?, canonical: ContractJSON?
            if let mapped = wires[item.localID] {
                wire = mapped; canonical = canonicals[mapped]
            } else {
                wire = try podcast.map { try wireEpisodeID(item.localID, podcast: $0, occurrence: (item.key.kind, item.key.value), s) }
                canonical = try wire.flatMap { try serverRecord("episode", $0, "metadata") }
            }
            observationTally.note(item.fields, canonical: ServerCatalogRecords.fields(ofCanonical: canonical))
            if ServerCatalogRecords.fields(ofCanonical: canonical) == item.fields {
                notes.append(.init(local: item.localID, hash: item.hash, op: nil, catalogOnly: false))
                continue
            }
            let occurrence = try ContractJSON.object(item.evidence.occurrence(item.key)).canonicalBytes().count
            let size = item.size + occurrence + Self.observationEntryOverhead
            guard size <= min(Self.observationItemLimit, s.writer.factBound / 2) else { skipped += 1; continue }
            var record: ContractObject = ["fields": item.fields]
            if let revision = canonical?["revision"]?.stringValue { record["base"] = .string(revision) }
            items.append((item, .object(record), size, wire))
        }
        guard feedRecord != nil || !items.isEmpty else { try noteObserved(notes, s); return [] }
        // Chunks within the fact bounds (PROTOCOL §15.2, §9.4), the feed record with the first.
        var chunks: [[(item: ServerDiscoveryBatch.Item, record: ContractJSON, size: Int, wire: String?)]] = [[]]
        var bytes = try Self.observationFactOverhead + (feedRecord?.canonicalBytes().count ?? 0)
        // One episode at most once a fact: a provisional release names its earlier release's
        // identity.
        var named = Set<String>()
        for entry in items {
            let name = entry.wire ?? "\(entry.item.key.kind)\u{0}\(entry.item.key.value)"
            if !chunks[chunks.count - 1].isEmpty,
               chunks[chunks.count - 1].count >= Self.observationItems || bytes + entry.size > Self.observationBytes || named.contains(name) {
                chunks.append([]); bytes = Self.observationFactOverhead; named = []
            }
            chunks[chunks.count - 1].append(entry); bytes += entry.size; named.insert(name)
        }
        var ops: [String] = []
        for (index, chunk) in chunks.enumerated() {
            var payload: ContractObject = ["batch_id": .string(batchID), "parser_version": .string(ServerCatalogParse.parserVersion),
                                           "fetch_time": .integer(fetchTime)]
            if index == 0, let feedRecord { payload["feed"] = feedRecord }
            var targets: [ContractJSON]
            var entries: [ContractJSON] = []
            switch binding {
            case .registered(let podcast, let generation):
                payload["podcast_id"] = .string(podcast)
                targets = [ServerFactTarget(entity: "podcast", id: podcast).json]
                for entry in chunk {
                    guard let wire = entry.wire, case .object(var record) = entry.record else { continue }
                    record["episode"] = ["episode_id": .string(wire), "podcast_id": .string(podcast), "generation_id": .string(generation),
                                         "occurrence": .object(entry.item.evidence.occurrence(entry.item.key))]
                    entries.append(.object(record))
                    targets.append(ServerFactTarget(entity: "episode", id: wire).json)
                }
            case .pending:
                payload["podcast_id"] = ["ntp_podcast_id": true]
                targets = [["entity": "podcast", "ntp_registration": true, "ntp_no_generation": true]]
                for entry in chunk {
                    guard case .object(var record) = entry.record else { continue }
                    record["episode"] = ["ntp_local_episode": .integer(entry.item.localID), "occurrence": .object(entry.item.evidence.occurrence(entry.item.key))]
                    entries.append(.object(record))
                    targets.append(["entity": "episode", "ntp_local_episode": .integer(entry.item.localID), "ntp_no_generation": true])
                }
            case .localFolder, .unregistered:
                try noteObserved(notes, s)
                return ops
            }
            payload["items"] = .array(entries)
            let op = try emit(s, binding: binding, type: "catalog.observe", targets: targets, payload: payload, overlays: []).opID
            ops.append(op)
            notes += chunk.map { .init(local: $0.item.localID, hash: $0.item.hash, op: op, catalogOnly: $0.item.fields["media"]?.isNull ?? true) }
        }
        try noteObserved(notes, s)
        return ops
    }

    // MARK: - Deferred observations (PROTOCOL §9.4)

    /// One bounded transaction of deferred observations (`.observe`): up to 200 listed records of one of a feed's
    /// batches (with the podcast record, when listed, first), each as its row keeps the parse (or the refresh's parse of
    /// it, still in this process, `observationInputs`). A record observed since, or equal to the canonical record, is
    /// noted and not sent; every other is sent. Their rows go in the same transaction, never
    /// before.
    func mapDeferredObservations(_ s: RecordingSession) throws {
        guard let feed = s.capture.observationFeed else { return }
        var rows = try nextListedObservations(feedID: feed)
        guard let first = rows.first else { return }
        let binding = try binding(feed, s)
        guard case .registered(let podcast, _) = binding else { return }
        var feedRecord: ContractJSON?
        if first.localID == nil {
            rows.removeFirst()
            try s.writer.execute("DELETE FROM ntp_observation_work WHERE feed_id = ? AND local_id IS NULL", [.integer(feed)])
            if try observedHash("podcast", "local-feed:\(feed)") != first.hash {
                let fields = try ContractJSON.decode(Data(first.canonical))
                let canonical = try serverRecord("podcast", podcast, "metadata")
                if ServerCatalogRecords.fields(ofCanonical: canonical) != fields {
                    var record: ContractObject = ["fields": fields]
                    if let revision = canonical?["revision"]?.stringValue { record["base"] = .string(revision) }
                    feedRecord = .object(record)
                }
                try noteObservedFeed(feed, hash: first.hash, s)
            }
        }
        try s.writer.execute("DELETE FROM ntp_observation_work WHERE local_id IN (SELECT value FROM json_each(?))",
                             [.text(ContractJSON.array(rows.compactMap { $0.localID.map(ContractJSON.integer) }).canonicalText)])
        var observed: [Int64: String] = [:]
        for row in try database.rows("SELECT CAST(substr(id, 15) AS INTEGER), parse_hash FROM ntp_observed WHERE entity = 'episode' AND id IN (SELECT value FROM json_each(?))",
                                     [.text(ContractJSON.array(rows.compactMap { $0.localID.map { .string(Self.ledgerKey(localEpisode: $0)) } }).canonicalText)]) {
            if let local = row[0].integer, let hash = row[1].text { observed[local] = hash }
        }
        var items: [ServerDiscoveryBatch.Item] = []
        for row in rows {
            guard let local = row.localID, let key = row.key, !key.isNone, let evidence = row.evidence, observed[local] != row.hash else { continue }
            let fields: ContractJSON
            if let input = s.capture.observationInputs[local], input.hash == row.hash { fields = input.fields }
            else { fields = try ContractJSON.decode(Data(row.canonical)) }
            items.append(.init(localID: local, key: key, evidence: evidence, fields: fields, hash: row.hash, canonical: row.canonical, isNew: false))
        }
        _ = try emitObservations(items, feedRecord: feedRecord, batchID: first.batchID, fetchTime: first.fetchTime, binding: binding, s)
    }

    private func observedHash(_ entity: String, _ id: String) throws -> String? {
        try database.rows("SELECT parse_hash FROM ntp_observed WHERE entity = ? AND id = ?", [.text(entity), .text(id)]).first?.first?.text
    }

    /// `ntp_observed` (PROTOCOL §15.2), keyed by local IDs: the hash of the phone's last parse, its observation op, and the
    /// observation that saw the item without an enclosure (gained-media evidence, PROTOCOL §9.4).
    private func noteObserved(_ entity: String, _ id: String, hash: String, op: String?, catalogOnly: Bool, _ s: RecordingSession) throws {
        try s.writer.execute("INSERT INTO ntp_observed(entity, id, parse_hash, observation_op, catalog_node) VALUES (?, ?, ?, ?, ?) ON CONFLICT(entity, id) DO UPDATE SET parse_hash = excluded.parse_hash, observation_op = coalesce(excluded.observation_op, observation_op), catalog_node = coalesce(excluded.catalog_node, catalog_node)",
                             [.text(entity), .text(id), .text(hash), op.map(LibrarySQLValue.text) ?? .null,
                              catalogOnly ? op.map(LibrarySQLValue.text) ?? .null : .null])
    }

    /// The podcast record observed (or equal to the canonical one) with this parse: a listed one is done.
    private func noteObservedFeed(_ feedID: Int64, hash: String, _ s: RecordingSession) throws {
        try noteObserved("podcast", "local-feed:\(feedID)", hash: hash, op: nil, catalogOnly: false, s)
        try s.writer.execute("DELETE FROM ntp_observation_work WHERE feed_id = ? AND local_id IS NULL", [.integer(feedID)])
    }

    struct ObservedNote { let local: Int64, hash: String, op: String?, catalogOnly: Bool }

    /// Episodes' `ntp_observed` rows, as `noteObserved` writes one, in a statement per 500.
    private func noteObserved(_ notes: [ObservedNote], _ s: RecordingSession) throws {
        for chunk in Self.chunks(notes) {
            // A listed observation of what is observed now is done.
            try s.writer.execute("DELETE FROM ntp_observation_work WHERE local_id IN (SELECT value FROM json_each(?))",
                                 [.text(ContractJSON.array(chunk.map { .integer($0.local) }).canonicalText)])
            let rows = ContractJSON.array(chunk.map { note in
                let op = note.op.map(ContractJSON.string) ?? .null
                return [.string(Self.ledgerKey(localEpisode: note.local)), .string(note.hash), op, note.catalogOnly ? op : .null]
            })
            try s.writer.execute("INSERT INTO ntp_observed(entity, id, parse_hash, observation_op, catalog_node) SELECT 'episode', json_extract(value, '$[0]'), json_extract(value, '$[1]'), json_extract(value, '$[2]'), json_extract(value, '$[3]') FROM json_each(?) WHERE true ON CONFLICT(entity, id) DO UPDATE SET parse_hash = excluded.parse_hash, observation_op = coalesce(excluded.observation_op, observation_op), catalog_node = coalesce(excluded.catalog_node, catalog_node)",
                                 [.text(rows.canonicalText)])
        }
    }

    // MARK: - Proposals (PROTOCOL §9.5)

    /// `discovery.propose {podcast_id, generation_id, episode, batch_id, pub_date, newest_before_batch, gained_media?,
    /// action, policy_node, queue_bundle?}` for one release, its local filing shown as its overlay.
    private func propose(_ release: ServerRelease, binding: PodcastBinding, bundle: QueueBundle?, dependencies: [String],
                         _ s: RecordingSession) throws -> String? {
        guard let reference = try episodeReference(release.localID, binding: binding, s) else { return nil }
        var payload: ContractObject = [
            "episode": reference.ref, "batch_id": .string(release.batchID),
            "pub_date": release.pubDate.map(ContractJSON.integer) ?? .null,
            "newest_before_batch": release.newestBeforeBatch.map(ContractJSON.integer) ?? .null,
            "action": .string(release.action), "policy_node": release.policyNode.map(ContractJSON.string) ?? .null,
        ]
        switch binding {
        case .registered(let podcast, let generation):
            payload["podcast_id"] = .string(podcast); payload["generation_id"] = .string(generation)
        case .pending:
            payload["podcast_id"] = ["ntp_podcast_id": true]; payload["generation_id"] = ["ntp_generation_id": true]
        case .localFolder, .unregistered:
            return nil
        }
        if let gained = release.gainedMedia { payload["gained_media"] = ["catalog_only_observation": .string(gained)] }
        var overlays: [ServerOverlay] = []
        switch release.action {
        case "inbox":
            overlays.append(ServerOverlay(entity: "episode", id: reference.entityID, property: "play_state", kind: .register, value: "new"))
        case "queue":
            if let bundle {
                payload["queue_bundle"] = ["key": .string(bundle.key.key.wire), "position_id": .string(bundle.key.positionID), "place": bundle.place.json]
                overlays += [ServerOverlay(entity: "episode", id: reference.entityID, property: "queue_membership", kind: .register, value: true),
                             ServerOverlay(entity: "episode", id: reference.entityID, property: "queue_position", kind: .register,
                                           value: ["key": .string(bundle.key.key.wire), "position_id": .string(bundle.key.positionID)])]
            }
        default: break
        }
        overlays += bundle?.extra ?? []
        return try emit(s, binding: binding, type: "discovery.propose", targets: [reference.target], payload: payload, overlays: overlays,
                        dependencies: dependencies + (bundle?.dependencies ?? []), members: [release.localID]).opID
    }

    /// A queue filing's resolved add (PROTOCOL §9.4, §7.6): the member's key and position ID and its place.
    struct QueueBundle {
        var key: StoredQueueKey
        var place: QueuePlace
        var dependencies: [String] = []
        /// Overlays of members the filing re-keyed (Keep sorted), on the first proposal.
        var extra: [ServerOverlay] = []
    }

    private func noteLedger(_ release: ServerRelease, binding: PodcastBinding, proposal: String?, _ s: RecordingSession) throws {
        guard let feedID = try feedOf(release.localID, s) else { return }
        switch binding {
        case .registered(let podcast, let generation):
            guard let episode = try episodeValue(release.localID, s), let feed = try header(feedID, s) else { return }
            let occurrence = occurrence(of: episode, atom: feed.metadata.format == .atom)
            let wire = try wireEpisodeID(release.localID, podcast: podcast, occurrence: (occurrence.kind, occurrence.value), s)
            // A provisional release's entry is keyed by its local episode until the server's
            // mapping names it; the mapping rekeys it.
            let key = try mappedElsewhere(wire, localID: release.localID) ? Self.ledgerKey(localEpisode: release.localID) : wire
            try noteServerRelease(generation: generation, occurrence: key, localID: release.localID, feedID: feedID, action: release.action,
                                  proposal: proposal, writer: s.writer)
        case .pending(let op, _):
            try noteServerRelease(generation: Self.ledgerKey(registration: op), occurrence: Self.ledgerKey(localEpisode: release.localID),
                                  localID: release.localID, feedID: feedID, action: release.action, proposal: proposal, writer: s.writer)
        case .localFolder, .unregistered:
            break
        }
    }

    // MARK: - Queue filings (PROTOCOL §9.5)

    /// The transaction consuming `queueEpisodes` (`.discoveryQueue`): one `discovery.propose {action: queue,
    /// queue_bundle}` per release it placed, with the bundle that transaction resolved (`{key, position_id, place}`,
    /// the place as an add at the account's location resolves); a release it could not place (already queued, gone)
    /// is proposed without a bundle, and the server resolves it. Each release's ledger entry takes its proposal.
    func mapDiscoveryQueue(_ s: RecordingSession) throws {
        let before = Set(s.capture.queueBefore)
        let added = s.queueAfter.filter { !before.contains($0) }
        let addedSet = Set(added)
        var extra = try rekeyedOverlays(s, excluding: addedSet)
        var mainFacts: [String] = []
        let insertions = s.capture.queueInsertions
        for release in s.capture.queueReleases {
            guard let feedID = try feedOf(release.localID, s) else { continue }
            let binding = try binding(feedID, s)
            switch binding {
            case .registered, .pending: break
            case .localFolder, .unregistered: continue
            }
            let insertion = addedSet.contains(release.localID) ? insertions.first { $0.members.contains(release.localID) } : nil
            if let op = try proposeQueued(release, binding, insertion, &extra, s), case .registered = binding { mainFacts.append(op) }
        }
        let deps = try queueProvenance(s)
        try replacePendingMembers(s, after: mainFacts, placed: addedSet, dependencies: deps)
        for id in added {
            s.account(.queueIn(id))
            if s.capture.episodes[id]?.before?.userState.playState == .new && s.capture.episodes[id]?.after?.userState.playState == .unplayed {
                s.account(.episode(id, .playState))
            }
        }
        s.account(.queueOrder)
    }

    @discardableResult
    private func proposeQueued(_ release: ServerRelease, _ binding: PodcastBinding, _ insertion: QueueInsertion?, _ extra: inout [ServerOverlay],
                               _ s: RecordingSession) throws -> String? {
        var bundle: QueueBundle?
        if let insertion, let key = s.queueKeys[release.localID] {
            let place = try insertionPlace(insertion, first: release.localID, author: binding, s)
            bundle = QueueBundle(key: key, place: place, dependencies: try queueProvenance(s), extra: extra)
            extra = []
        }
        guard let op = try propose(release, binding: binding, bundle: bundle, dependencies: [], s) else { return nil }
        switch binding {
        case .registered(let podcast, let generation):
            if let episode = try episodeValue(release.localID, s), let feedID = try feedOf(release.localID, s), let feed = try header(feedID, s) {
                let occurrence = occurrence(of: episode, atom: feed.metadata.format == .atom)
                let wire = try wireEpisodeID(release.localID, podcast: podcast, occurrence: (occurrence.kind, occurrence.value), s)
                try noteServerReleaseProposal(generation: generation, occurrence: wire, proposal: op, writer: s.writer)
            }
        case .pending(let registration, _):
            try noteServerReleaseProposal(generation: Self.ledgerKey(registration: registration), occurrence: Self.ledgerKey(localEpisode: release.localID),
                                          proposal: op, writer: s.writer)
        case .localFolder, .unregistered:
            break
        }
        return op
    }
}
