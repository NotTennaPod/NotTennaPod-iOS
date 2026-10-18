import Foundation

/// How a local feed is known to the account when a fact names it (PROTOCOL §15.2).
enum PodcastBinding: Equatable {
    /// A local folder (PROTOCOL §7.6): nothing about it is recorded.
    case localFolder
    /// A preview the account does not know yet: facts about it are not recorded until a synced action registers it.
    case unregistered
    /// A registration waiting for the server's resolution: facts are drafts on its author's chain.
    case pending(op: String, author: String)
    case registered(podcast: String, generation: String)
}

struct StoredQueueKey: Equatable, Sendable {
    var key: QueueKey
    var positionID: String
    var deviceOnly: Bool
}

/// One transaction's recording: the intent, the captured changes and the recorder's writes (PROTOCOL §15.2).
final class RecordingSession {
    let intent: ServerIntent
    let capture: ChangeCapture
    let writer: ServerOutboxWriter
    let clientTime: Int64
    let now: Int64
    /// Synced changes not yet accounted for by a fact or a fixed effect.
    var pending: Set<SyncedChange> = []
    var queueAfter: [Int64] = []
    /// Keys of the queue after the transaction, and the members whose key or position ID is new.
    var queueKeys: [Int64: StoredQueueKey] = [:]
    var freshKeys: Set<Int64> = []
    /// Keys of members that left the queue.
    var removedKeys: [Int64: StoredQueueKey] = [:]
    var bindings: [Int64: PodcastBinding] = [:]
    var feedOfEpisode: [Int64: Int64] = [:]

    var context: ServerLibraryContext { writer.context }

    init(intent: ServerIntent, capture: ChangeCapture, writer: ServerOutboxWriter, clientTime: Int64, now: Int64) {
        self.intent = intent; self.capture = capture; self.writer = writer; self.clientTime = clientTime; self.now = now
    }

    func account(_ change: SyncedChange) { pending.remove(change) }
}

/// A fact or draft the recorder wrote.
struct RecordedFact {
    var opID: String
    /// The registration whose chain holds it (a draft), or nil for a main-author fact.
    var registrationOp: String?
    var authorID: String
    var members: [Int64]
}

extension FeedLibraryStore {
    /// The bulk member bound of one fact (PROTOCOL §15.2).
    static let factMemberLimit = 500

    func record(_ intent: ServerIntent, capture: ChangeCapture, writer: ServerOutboxWriter, replaying: Bool = false) throws {
        let s = RecordingSession(intent: intent, capture: capture, writer: writer,
                                 clientTime: try milliseconds(capture.clientTime), now: try milliseconds(Date()))
        s.queueAfter = try queueEpisodeIDs()
        try collectChanges(s)
        if intent == .remote { return }
        let writesBefore = writer.writes
        try syncQueueKeys(s)
        // What the playback journal made due, or an earlier playback write owes, comes first (PROTOCOL §8).
        try recordPlaybackDue(s)
        // A local cut is recorded only once every unexported save it covers was exported (PROTOCOL §8.2).
        if intent.isCut { try checkCutCoverage(s) }
        try mapIntent(s)
        // Recorded something: after COMMIT the sync scheduler is told, and pushes soon (PROTOCOL §6.4).
        if writer.writes > writesBefore { capture.afterCommit.append { $0.noteServerOutboxChanged() } }
        if replaying { return }
        if let first = s.pending.sorted().first {
            throw ServerRecordingError.unmappedChange(intent: intent.name, change: first.description)
        }
    }

    /// A local cut covering listening the server refused as too large (PROTOCOL §6.13) would leave that listening out of
    /// it: the whole action is refused, nothing changes, and the person is pointed to Needs attention ("Try again" or "Keep
    /// only on this device"). A removal of another episode's history is not blocked.
    private func checkCutCoverage(_ s: RecordingSession) throws {
        var episode: Int64?
        if s.intent == .historyRemove {
            guard let removal = s.capture.historyRemoval else { return }
            episode = removal.episodeID
        }
        // A refused leave or finalization carries a history entry: it holds back history cuts (not a statistics reset).
        let transitionsBlock = try s.intent != .statisticsReset && !refusedTransitions(episode: episode).isEmpty
        guard try refusedSessions(episode: episode).isEmpty, !transitionsBlock else {
            throw ServerRecordingError.cutBlockedByRefusedListening(intent: s.intent.name)
        }
    }

    // MARK: - Changes

    private func collectChanges(_ s: RecordingSession) throws {
        let capture = s.capture
        for id in capture.episodeOrder {
            guard let change = capture.episodes[id] else { continue }
            s.feedOfEpisode[id] = change.feedID
            switch (change.before, change.after) {
            case (nil, .some): s.pending.insert(.episodeInserted(id))
            case (.some, nil): s.pending.insert(.episodeDeleted(id))
            case (.some(let before), .some(let after)):
                let old = SyncedEpisode(before), new = SyncedEpisode(after)
                if old.playState != new.playState { s.pending.insert(.episode(id, .playState)) }
                if old.favorite != new.favorite { s.pending.insert(.episode(id, .favorite)) }
                if old.position != new.position { s.pending.insert(.episode(id, .position)) }
                if old.playedDuration != new.playedDuration { s.pending.insert(.episode(id, .playedDuration)) }
                if old.lastPlayed != new.lastPlayed { s.pending.insert(.episode(id, .lastPlayed)) }
                if old.history != new.history { s.pending.insert(.episode(id, .history)) }
            case (nil, nil): break
            }
        }
        for id in capture.feedOrder {
            guard let change = capture.feeds[id] else { continue }
            switch (change.before, change.after) {
            case (nil, .some): s.pending.insert(.feedInserted(id))
            case (.some, nil): s.pending.insert(.feedDeleted(id))
            case (.some(let before), .some(let after)):
                let old = SyncedFeed(before), new = SyncedFeed(after)
                if old.subscription != new.subscription { s.pending.insert(.feed(id, .subscription)) }
                if old.keepUpdated != new.keepUpdated { s.pending.insert(.feed(id, .keepUpdated)) }
                if old.newEpisodesAction != new.newEpisodesAction { s.pending.insert(.feed(id, .newEpisodesAction)) }
                if !old.source.utf8.elementsEqual(new.source.utf8) { s.pending.insert(.feed(id, .source)) }
            case (nil, nil): break
            }
        }
        for (feedID, change) in capture.credentials where change.before != change.after { s.pending.insert(.credentials(feedID)) }
        let before = Set(capture.queueBefore), after = Set(s.queueAfter)
        for id in s.queueAfter where !before.contains(id) { s.pending.insert(.queueIn(id)) }
        for id in capture.queueBefore where !after.contains(id) { s.pending.insert(.queueOut(id)) }
        let syncedBefore = try capture.queueBefore.filter { try after.contains($0) && !isDeviceOnly($0, s) }
        let syncedAfter = try s.queueAfter.filter { try before.contains($0) && !isDeviceOnly($0, s) }
        if syncedBefore != syncedAfter { s.pending.insert(.queueOrder) }
        // Local folders (PROTOCOL §7.6) and detached feeds (PROTOCOL §6.8): nothing about them is recorded.
        for change in s.pending {
            switch change {
            case .episode(let id, _), .episodeInserted(let id), .episodeDeleted(let id), .queueIn(let id), .queueOut(let id):
                if try isDeviceOnly(id, s) { s.account(change) }
            case .feed(let id, _), .feedInserted(let id), .feedDeleted(let id), .credentials(let id):
                if try header(id, s)?.source.isLocalFeedSource == true || isDetachedFeed(id) { s.account(change) }
            case .queueOrder: break
            }
        }
    }

    // MARK: - Lookups

    func header(_ feedID: Int64, _ s: RecordingSession) throws -> LibraryFeed? {
        try s.capture.feeds[feedID]?.after ?? storedHeader(feedID) ?? s.capture.feeds[feedID]?.before
    }

    func feedOf(_ episodeID: Int64, _ s: RecordingSession) throws -> Int64? {
        if let id = s.feedOfEpisode[episodeID] { return id }
        let id = try database.rows("SELECT feed_id FROM episodes WHERE id = ?", [.integer(episodeID)]).first?.first?.integer
        if let id { s.feedOfEpisode[episodeID] = id }
        return id
    }

    func episodeValue(_ id: Int64, _ s: RecordingSession) throws -> LibraryEpisode? {
        try s.capture.episodes[id]?.after ?? loadEpisode(id) ?? s.capture.episodes[id]?.before
    }

    /// Queue entries of local-folder episodes never reach the server (PROTOCOL §7.6).
    func isDeviceOnly(_ episodeID: Int64, _ s: RecordingSession) throws -> Bool {
        guard let feed = try feedOf(episodeID, s) else { return false }
        return try binding(feed, s) == .localFolder
    }

    func binding(_ feedID: Int64, _ s: RecordingSession) throws -> PodcastBinding {
        if let known = s.bindings[feedID] { return known }
        let result = try storedBinding(feedID, isLocalFolder: try header(feedID, s)?.source.isLocalFeedSource == true)
        s.bindings[feedID] = result
        return result
    }

    /// How a feed's facts are recorded now, from the stored registrations and mappings (`binding` without a session).
    func storedBinding(_ feedID: Int64, isLocalFolder: Bool) throws -> PodcastBinding {
        let result: PodcastBinding
        // A detached feed (PROTOCOL §6.8) is recorded as a local folder is: never.
        if try isLocalFolder || isDetachedFeed(feedID) {
            result = .localFolder
        } else if let row = try database.rows("SELECT r.op_id, r.author_id FROM ntp_registrations r WHERE r.feed_id = ? AND r.state = 'pending' AND EXISTS (SELECT 1 FROM ntp_drafts d WHERE d.author_id = r.author_id) ORDER BY r.created_at DESC, r.rowid DESC LIMIT 1", [.integer(feedID)]).first,
                  case .text(let op) = row[0], case .text(let author) = row[1] {
            // While a registration of the feed still holds drafts, its later facts join that chain, so they follow
            // the person's earlier actions on it whatever the clocks say; a main-author fact never
            // depends on a draft.
            result = .pending(op: op, author: author)
        } else if let row = try database.rows("SELECT podcast_id, live_generation FROM ntp_podcasts WHERE feed_id = ? AND live_generation IS NOT NULL AND pinned_removal = 0", [.integer(feedID)]).first,
                  case .text(let podcast) = row[0], case .text(let generation) = row[1] {
            result = .registered(podcast: podcast, generation: generation)
        } else if let row = try database.rows("SELECT op_id, author_id FROM ntp_registrations WHERE feed_id = ? AND state = 'pending' ORDER BY created_at DESC, rowid DESC LIMIT 1", [.integer(feedID)]).first,
                  case .text(let op) = row[0], case .text(let author) = row[1] {
            result = .pending(op: op, author: author)
        } else {
            result = .unregistered
        }
        return result
    }

    /// The binding a synced action needs: an unregistered preview is registered by it (PROTOCOL §15.2, "the first synced
    /// action on a preview"), and a subscribed feed the account does not know yet is subscribed.
    func registeredBinding(_ feedID: Int64, _ s: RecordingSession) throws -> PodcastBinding {
        let current = try binding(feedID, s)
        guard current == .unregistered, let feed = try header(feedID, s) else { return current }
        let kind = feed.subscriptionState == .notSubscribed ? "register_preview" : "subscribe"
        _ = try register(feedID: feedID, kind: kind, s)
        return try binding(feedID, s)
    }

    /// Base records' provenance (UUID nodes only): what an action on existing state acted on (PROTOCOL §15.2).
    func provenance(entity: String, id: String, groups: [String]) throws -> [String] {
        guard !groups.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: groups.count).joined(separator: ", ")
        var result: [String] = []
        for row in try database.rows("SELECT provenance FROM ntp_records WHERE entity = ? AND id = ? AND field_group IN (\(marks))",
                                     [.text(entity), .text(id)] + groups.map(LibrarySQLValue.text)) {
            guard case .text(let text) = row[0], let list = try? ContractJSON.decode(text).arrayValue else { continue }
            result += list.compactMap(\.stringValue).filter(ContractIdentity.isUUID)
        }
        return result
    }

    // MARK: - Episode references

    /// The identity kind and value an episode's wire ID derives from, and the occurrence evidence of what the
    /// person acted on (PROTOCOL §9.7, §7.2 `EpisodeRef`). URLs carry no userinfo.
    func occurrence(of episode: LibraryEpisode, atom: Bool) -> (kind: String, value: String, object: ContractObject) {
        let details = episode.details
        var object = ContractObject()
        var kind: String, value: String
        if let identity = FetchEpisodeIdentity.plainIdentity(guid: details.identifier, enclosureURL: details.media?.url, atom: atom) {
            kind = identity.kind.rawValue; value = identity.value
        } else {
            kind = "none"; value = ""
        }
        // The identity a refresh gave it (PROTOCOL §9.7: a reused GUID's later occurrence) and its own date or none.
        let local = serverContext == nil ? nil : (try? database.rows("SELECT kind, value, publication_time FROM ntp_local_items WHERE local_id = ?",
                                                                      [.integer(episode.id)]))?.first
        if let local, let storedKind = local[0].text, let storedValue = local[1].text { kind = storedKind; value = storedValue }
        object["k"] = .string(kind); object["v"] = .string(value)
        if let guid = ContractIdentity.trimmedGUID(details.identifier.map(ContractURL.stripUserinfo)) { object["guid"] = .string(guid) }
        if let url = details.media?.url, !url.isEmpty { object["enclosure_url"] = .string(ContractURL.stripUserinfo(url)) }
        if let title = details.title { object["title"] = .string(ContractURL.stripUserinfo(title)) }
        if let local {
            if let ms = local[2].integer { object["publication_time"] = .integer(ms) }
        } else if let date = details.publicationDate, let ms = try? milliseconds(date) { object["publication_time"] = .integer(ms) }
        return (kind, value, object)
    }

    /// The wire episode of a local episode under a registered podcast: the one recorded in `ntp_episodes`, else its
    /// derivation with the podcast's identity rules (PROTOCOL §9.7), recorded now.
    func wireEpisodeID(_ localID: Int64, podcast: String, occurrence: (kind: String, value: String), _ s: RecordingSession) throws -> String {
        if let row = try database.rows("SELECT episode_id FROM ntp_episodes WHERE local_id = ?", [.integer(localID)]).first,
           case .text(let id) = row[0] { return id }
        let id: String
        if occurrence.kind == "none" {
            id = "e0:" + ContractIdentity.randomUUID()
        } else {
            id = try derivedEpisodeID(localID, podcast: podcast, key: ServerEpisodeKey(kind: occurrence.kind, value: occurrence.value),
                                      namespace: s.context.namespace)
        }
        // A provisional release of rotating enclosures is named by the identity the earlier release holds, with its own
        // occurrence, and never mapped to it: the server's mapping gives it its own.
        if try isProvisionalLocal(localID) { return id }
        // Two local items of one derived episode (Android keeps duplicates) name the same wire episode; only the
        // first is recorded as its local row.
        try s.writer.execute("INSERT INTO ntp_episodes(episode_id, local_id, podcast_id, kind, value) VALUES (?, ?, ?, ?, ?) ON CONFLICT(episode_id) DO NOTHING",
                             [.text(id), .integer(localID), .text(podcast), .text(occurrence.kind), .text(occurrence.value)])
        return id
    }

    /// Whether a local episode is a provisional release of rotating enclosures (`ServerEpisodeIdentity.isProvisional`).
    func isProvisionalLocal(_ localID: Int64) throws -> Bool {
        guard let row = try database.rows("SELECT feed_id, kind, value, publication_time FROM ntp_local_items WHERE local_id = ?", [.integer(localID)]).first,
              let feed = row[0].integer, let kind = row[1].text, kind == ContractIdentity.EpisodeKind.rssGUIDEnclosure.rawValue,
              let value = row[2].text, let time = row[3].integer else { return false }
        return try database.scalar("SELECT count(*) FROM ntp_local_items WHERE feed_id = ? AND kind = ? AND value = ? AND local_id != ? AND publication_time < ?",
                                   [.integer(feed), .text(kind), .text(value), .integer(localID), .integer(time - ServerEpisodeIdentity.releaseWindow)]) > 0
    }

    /// Whether a wire episode is mapped to another local episode than this one (a provisional release names its
    /// earlier release's identity): its overlays and ledger entry are then keyed by its local ID.
    func mappedElsewhere(_ wire: String, localID: Int64) throws -> Bool {
        guard let mapped = try database.rows("SELECT local_id FROM ntp_episodes WHERE episode_id = ?", [.text(wire)]).first?.first?.integer else {
            return try isProvisionalLocal(localID)
        }
        return mapped != localID
    }

    /// A local episode's wire ID from its identity (PROTOCOL §9.7): a plain identity through the podcast's rules (a lookup alias,
    /// a disputed GUID's release) with the evidence it was observed with; `rss-guid+enclosure` as it is.
    func derivedEpisodeID(_ localID: Int64, podcast: String, key: ServerEpisodeKey, namespace: String) throws -> String {
        guard let data = try database.rows("SELECT value FROM ntp_records WHERE entity = 'podcast' AND id = ? AND field_group = 'identity_rules'",
                                           [.text(podcast)]).first?.first?.data else {
            return try ServerEpisodeIdentity.id(key, namespace: namespace, podcast: podcast)
        }
        let rules = ServerIdentityRules(try ContractJSON.decode(data))
        let row = try database.rows("SELECT guid, enclosure, publication_time FROM ntp_local_items WHERE local_id = ?", [.integer(localID)]).first
        // `rss-guid+enclosure` as it is, unless its GUID is disputed: then its release by date
        // decides (a provisional release takes the server's own ID).
        if key.kind == ContractIdentity.EpisodeKind.rssGUIDEnclosure.rawValue, row?[0].text.map({ rules.disputedGUIDs[$0] == nil }) ?? true {
            return try ServerEpisodeIdentity.id(key, namespace: namespace, podcast: podcast)
        }
        let isGUID = key.kind != ContractIdentity.EpisodeKind.enclosure.rawValue
        let evidence = ServerItemEvidence(guid: row?[0].text ?? (isGUID ? key.value : nil), enclosureURL: row?[1].text ?? (isGUID ? nil : key.value),
                                          publicationTime: row?[2].integer, title: nil, atom: key.kind == ContractIdentity.EpisodeKind.atomID.rawValue)
        return try ServerEpisodeIdentity.derive(evidence, rules: rules, namespace: namespace, podcast: podcast)?.episodeID
            ?? ServerEpisodeIdentity.id(key, namespace: namespace, podcast: podcast)
    }

    /// An episode named by a fact: an `EpisodeRef` for a registered podcast, or a draft placeholder carrying the
    /// occurrence fixed now (materialized when the registration resolves).
    func episodeReference(_ localID: Int64, binding: PodcastBinding, _ s: RecordingSession) throws -> (ref: ContractJSON, target: ContractJSON, entityID: String)? {
        // A detached episode (PROTOCOL §6.8) is named by nothing, whatever binding a session kept from before.
        guard let episode = try episodeValue(localID, s), let feedID = try feedOf(localID, s),
              let feed = try header(feedID, s), try !isDetachedFeed(feedID) else { return nil }
        let occurrence = occurrence(of: episode, atom: feed.metadata.format == .atom)
        switch binding {
        case .registered(let podcast, let generation):
            let id = try wireEpisodeID(localID, podcast: podcast, occurrence: (occurrence.kind, occurrence.value), s)
            let ref: ContractJSON = ["episode_id": .string(id), "podcast_id": .string(podcast), "generation_id": .string(generation),
                                     "occurrence": .object(occurrence.object)]
            // A provisional release's overlays are its own row's, never its earlier release's.
            let entity = try mappedElsewhere(id, localID: localID) ? Self.ledgerKey(localEpisode: localID) : id
            return (ref, ServerFactTarget(entity: "episode", id: id, generation: generation).json, entity)
        case .pending:
            var placeholder: ContractObject = ["ntp_local_episode": .integer(localID), "occurrence": .object(occurrence.object)]
            if occurrence.kind == "none" { placeholder["e0"] = .string(ContractIdentity.randomUUID()) }
            return (.object(placeholder), ["entity": "episode", "ntp_local_episode": .integer(localID)], "local-episode:\(localID)")
        case .localFolder, .unregistered:
            return nil
        }
    }

    // MARK: - Emitting facts

    /// Records `type` for episodes, grouped by how their podcasts are known: registered members as main-author
    /// facts, each pending registration's members as drafts on its chain, local folders never. A `bulkKey` lists
    /// the members sorted by episode ID, at most 500 per fact; without one every member is its own fact.
    @discardableResult
    func emitEpisodeFacts(_ s: RecordingSession, type: String, members: [Int64], bulkKey: String? = nil,
                          extra: (Int64) throws -> ContractObject = { _ in [:] },
                          overlays: (String, Int64) -> [ServerOverlay] = { _, _ in [] },
                          provenanceGroups: [String] = [], dependencies: [String] = []) throws -> [RecordedFact] {
        var groups: [(binding: PodcastBinding, members: [Int64])] = []
        for member in members {
            guard let feed = try feedOf(member, s) else { continue }
            let binding = try registeredBinding(feed, s)
            guard binding != .localFolder, binding != .unregistered else { continue }
            if let index = groups.firstIndex(where: { $0.binding == binding }) { groups[index].members.append(member) }
            else { groups.append((binding, [member])) }
        }
        var recorded: [RecordedFact] = []
        for group in groups {
            var references: [(member: Int64, ref: ContractJSON, target: ContractJSON, entityID: String)] = []
            for member in group.members {
                guard let reference = try episodeReference(member, binding: group.binding, s) else { continue }
                references.append((member, reference.ref, reference.target, reference.entityID))
            }
            let batches: [[(member: Int64, ref: ContractJSON, target: ContractJSON, entityID: String)]]
            if bulkKey != nil {
                let sorted = references.sorted { $0.entityID.utf8.lexicographicallyPrecedes($1.entityID.utf8) }
                batches = stride(from: 0, to: sorted.count, by: Self.factMemberLimit).map {
                    Array(sorted[$0..<min(sorted.count, $0 + Self.factMemberLimit)])
                }
            } else {
                batches = references.map { [$0] }
            }
            for batch in batches {
                var payload: ContractObject
                if let bulkKey {
                    payload = try extra(batch[0].member)
                    payload[bulkKey] = .array(batch.map(\.ref))
                } else {
                    payload = try extra(batch[0].member)
                    payload["episode"] = batch[0].ref
                }
                let overlayList = batch.flatMap { overlays($0.entityID, $0.member) }
                recorded.append(try emit(s, binding: group.binding, type: type, targets: batch.map(\.target), payload: payload,
                                         overlays: overlayList, provenance: batch.map(\.entityID),
                                         provenanceGroups: provenanceGroups, dependencies: dependencies, members: batch.map(\.member)))
            }
        }
        return recorded
    }

    /// One fact on the main author, or one draft on a pending registration's chain.
    func emit(_ s: RecordingSession, binding: PodcastBinding, type: String, targets: [ContractJSON], payload: ContractObject,
              overlays: [ServerOverlay], provenance entities: [String] = [], provenanceGroups: [String] = [],
              dependencies: [String] = [], secretIDs: [String] = [], members: [Int64] = []) throws -> RecordedFact {
        switch binding {
        case .registered:
            var deps = dependencies
            for entity in entities {
                let kind = entity.hasPrefix("p1:") ? "podcast" : "episode"
                deps += try provenance(entity: kind, id: entity, groups: provenanceGroups)
            }
            let factTargets = targets.compactMap { json -> ServerFactTarget? in
                guard let entity = json["entity"]?.stringValue, let id = json["id"]?.stringValue else { return nil }
                return ServerFactTarget(entity: entity, id: id, generation: json["generation"]?.stringValue)
            }
            deps += try latestRegistrationFacts(on: factTargets, s)
            let op = try s.writer.appendFact(type: type, targets: factTargets, payload: payload, dependencies: deps,
                                             overlays: overlays, clientTime: s.clientTime, secretIDs: secretIDs, now: s.now)
            return RecordedFact(opID: op, registrationOp: nil, authorID: s.context.mainAuthor, members: members)
        case .pending(let registration, let author):
            let template: ContractJSON = ["type": .string(type), "targets": .array(targets), "payload": .object(payload),
                                          "secret_ids": .array(secretIDs.map(ContractJSON.string))]
            let op = try s.writer.appendDraft(registrationOp: registration, authorID: author, type: type, template: template,
                                              dependencies: dependencies, overlays: overlays, clientTime: s.clientTime, now: s.now)
            return RecordedFact(opID: op, registrationOp: registration, authorID: author, members: members)
        case .localFolder, .unregistered:
            throw ServerRecordingError.corruptState("a fact about a podcast the account does not know")
        }
    }

    /// The latest unretired fact of another author (a materialized draft of a registration chain) on each subject a
    /// main-author fact names: the new fact depends on it, so causal order follows what the person did whatever the
    /// clocks say. Once retired, its effect is in the base records, whose provenance covers it.
    func latestRegistrationFacts(on targets: [ServerFactTarget], _ s: RecordingSession) throws -> [String] {
        var result: [String] = []
        for target in targets where target.entity == "episode" || target.entity == "podcast" {
            let row = try database.rows("SELECT o.op_id FROM ntp_overlays o JOIN ntp_outbox b ON b.op_id = o.op_id WHERE o.entity = ? AND o.id = ? AND b.author_id != ? ORDER BY o.clock DESC LIMIT 1",
                                        [.text(target.entity), .text(target.id), .text(s.context.mainAuthor)]).first
            if let row, case .text(let op) = row[0] { result.append(op) }
        }
        return result
    }

    /// A podcast-level fact (`podcast.archive`, `set_policy`, …) for a feed: on the main author for a registered
    /// podcast, as a draft for a pending one; nothing for a preview the account does not know or a local folder.
    @discardableResult
    func emitPodcastFact(_ s: RecordingSession, feedID: Int64, type: String, payload: ContractObject,
                         overlays: (String) -> [ServerOverlay], provenanceGroups: [String], secretIDs: [String] = [],
                         registerIfNeeded: Bool) throws -> RecordedFact? {
        let binding = registerIfNeeded ? try registeredBinding(feedID, s) : try binding(feedID, s)
        switch binding {
        case .registered(let podcast, let generation):
            return try emit(s, binding: binding, type: type, targets: [ServerFactTarget(entity: "podcast", id: podcast, generation: generation).json],
                            payload: payload, overlays: overlays(podcast), provenance: [podcast], provenanceGroups: provenanceGroups,
                            secretIDs: secretIDs)
        case .pending:
            return try emit(s, binding: binding, type: type, targets: [["entity": "podcast", "ntp_registration": true]],
                            payload: payload, overlays: overlays("local-feed:\(feedID)"), secretIDs: secretIDs)
        case .localFolder, .unregistered:
            return nil
        }
    }

    /// A podcast registration (PROTOCOL §15.2): `podcast.subscribe` or `podcast.register_preview` on the main author, with
    /// its own registration author for the drafts that wait for its resolution.
    @discardableResult
    func register(feedID: Int64, kind: String, _ s: RecordingSession) throws -> (op: String, author: String) {
        guard let feed = try header(feedID, s) else { throw FeedLibraryError.missingFeed(feedID) }
        let url = ContractURL.stripUserinfo(feed.source)
        var payload: ContractObject = ["feed_url": .string(url)]
        var targets: [ServerFactTarget] = []
        var entity = "local-feed:\(feedID)"
        var deps: [String] = []
        if let observed = try observedPodcast(feedID: feedID, url: url, before: s.capture.feeds[feedID]?.before) {
            payload["observed"] = ["podcast_id": .string(observed.podcast), "generation_id": .string(observed.generation),
                                   "state": .string(observed.state)]
            targets = [ServerFactTarget(entity: "podcast", id: observed.podcast)]
            entity = observed.podcast
            deps = try provenance(entity: "podcast", id: observed.podcast, groups: ["subscription", "identity"])
        }
        var secrets: [String] = []
        // The URL's userinfo wins over a stored credential, as fetching uses it (FeedFetcher): it becomes the
        // subscription's credentials secret, with the feed's origin approved, and the URL is sent without it.
        if kind == "subscribe", let credential = try s.capture.urlCredential ?? feedCredentialID(feedID: feedID) {
            let secret = try secretID(for: credential, feedURL: url, s)
            if credential == s.capture.urlCredential {
                // Claimed: the staged Keychain item is kept as the secret's, not cleaned up.
                try s.writer.execute("DELETE FROM feed_credential_cleanup WHERE credential_id = ?", [.text(credential.uuidString)])
            }
            payload["credentials_secret"] = .string(secret)
            secrets = [secret]
        }
        let state: ContractJSON = kind == "subscribe" ? "subscribed" : "not_subscribed"
        let op = try s.writer.appendFact(type: "podcast.\(kind)", targets: targets, payload: payload, dependencies: deps,
                                         overlays: [ServerOverlay(entity: "podcast", id: entity, property: "subscription", kind: .register, value: state)],
                                         clientTime: s.clientTime, secretIDs: secrets, now: s.now)
        let author = try s.writer.createRegistration(opID: op, kind: kind, feedID: feedID, feedURL: url, now: s.now)
        s.bindings[feedID] = nil
        return (op, author)
    }

    /// The latest generation the phone knows for a feed or its URL (`observed`, PROTOCOL §15.2): from the podcast's records.
    func observedPodcast(feedID: Int64, url: String, before: LibraryFeed?) throws -> (podcast: String, generation: String, state: String)? {
        var podcast: String?
        if let row = try database.rows("SELECT podcast_id FROM ntp_podcasts WHERE feed_id = ?", [.integer(feedID)]).first,
           case .text(let id) = row[0] { podcast = id }
        if podcast == nil {
            let normalized = ContractURL.normalize(url)
            for row in try database.rows("SELECT id, value FROM ntp_records WHERE entity = 'podcast' AND field_group = 'identity'") {
                guard case .text(let id) = row[0], let data = row[1].data, let value = try? ContractJSON.decode(data),
                      let aliases = value["aliases"]?.arrayValue else { continue }
                if aliases.contains(where: { $0["normalized"]?.stringValue.map { $0.utf8.elementsEqual(normalized.utf8) } ?? false }) {
                    podcast = id; break
                }
            }
        }
        guard let podcast else { return nil }
        if let row = try database.rows("SELECT value FROM ntp_records WHERE entity = 'podcast' AND id = ? AND field_group = 'subscription'", [.text(podcast)]).first,
           let data = row[0].data, let value = try? ContractJSON.decode(data),
           let generation = value["generation_id"]?.stringValue, let state = value["state"]?.stringValue {
            return (podcast, generation, state)
        }
        if let row = try database.rows("SELECT live_generation FROM ntp_podcasts WHERE podcast_id = ?", [.text(podcast)]).first,
           case .text(let generation) = row[0], let feed = try before ?? storedHeader(feedID) {
            let state = switch feed.subscriptionState { case .subscribed: "subscribed"; case .archived: "archived"; case .notSubscribed: "not_subscribed" }
            return (podcast, generation, state)
        }
        return nil
    }

    /// The wire secret of a library credential (PROTOCOL §15.4): the one already mapped, else a fresh `secret_id` whose
    /// approved origins are the current secret's of the feed, or the feed URL's origin.
    func secretID(for credential: UUID, feedURL: String, inheriting previous: UUID? = nil, _ s: RecordingSession) throws -> String {
        if let row = try database.rows("SELECT secret_id FROM ntp_secrets WHERE credential_id = ?", [.text(credential.uuidString)]).first,
           case .text(let id) = row[0] { return id }
        var origins: [String] = []
        if let previous, let row = try database.rows("SELECT approved_origins FROM ntp_secrets WHERE credential_id = ?", [.text(previous.uuidString)]).first,
           case .text(let text) = row[0], let list = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) {
            origins = list
        } else if let origin = Self.origin(of: feedURL) {
            origins = [origin]
        }
        let id = ContractIdentity.randomUUID()
        try s.writer.execute("INSERT INTO ntp_secrets(secret_id, credential_id, approved_origins, origin, created_at) VALUES (?, ?, ?, 'local', ?)",
                             [.text(id), .text(credential.uuidString), .text(String(decoding: try JSONEncoder().encode(origins), as: UTF8.self)), .integer(s.now)])
        return id
    }

    /// `scheme://host:port`, lower case, with the scheme's default port (the server's origin form).
    static func origin(of url: String) -> String? {
        guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    /// The local feed a URL names in a server library (PROTOCOL §15.2): a feed whose source normalizes to it, or the feed of a
    /// podcast whose aliases list it. Local folders never match.
    func serverLibraryFeed(matching url: String) throws -> Int64? {
        let normalized = ContractURL.normalize(ContractURL.stripUserinfo(url))
        // A hidden podcast (being removed, or staged and not yet revealed) is nobody's to subscribe again, nor is a
        // detached feed (PROTOCOL §6.8): subscribing again makes a podcast of its own.
        for row in try database.rows("SELECT id, record FROM feeds WHERE id NOT IN (SELECT feed_id FROM ntp_hidden_feeds) AND id NOT IN (SELECT feed_id FROM pinned_feed_removals) ORDER BY id") {
            let feed: LibraryFeed = try decode(row[1])
            if !feed.source.isLocalFeedSource,
               ContractURL.normalize(ContractURL.stripUserinfo(feed.source)).utf8.elementsEqual(normalized.utf8) { return feed.id }
        }
        for row in try database.rows("SELECT r.value, p.feed_id FROM ntp_records r JOIN ntp_podcasts p ON p.podcast_id = r.id WHERE r.entity = 'podcast' AND r.field_group = 'identity' AND p.feed_id IS NOT NULL") {
            guard let data = row[0].data, let feedID = row[1].integer, let value = try? ContractJSON.decode(data),
                  try storedHeader(feedID) != nil,
                  try database.scalar("SELECT count(*) FROM ntp_hidden_feeds WHERE feed_id = ?", [.integer(feedID)]) == 0 else { continue }
            if value["aliases"]?.arrayValue?.contains(where: { $0["normalized"]?.stringValue.map { $0.utf8.elementsEqual(normalized.utf8) } ?? false }) == true {
                return feedID
            }
        }
        return nil
    }
}
