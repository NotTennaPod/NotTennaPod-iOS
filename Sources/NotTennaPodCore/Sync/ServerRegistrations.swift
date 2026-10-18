import Foundation

/// A registration's resolution (`podcast.resolution`, PROTOCOL §7.2), as the exchange applies it.
struct ServerRegistrationResolution: Sendable {
    var podcastID: String
    /// The generation the registration acts on; for a `stale` resolution the live one, else the latest closed one.
    var generationID: String?
    /// `created`, `joined`, `opened` or `stale`.
    var mode: String
    /// The resolution decision's ID, a dependency of every materialized draft.
    var decisionID: String?
}

extension FeedLibraryStore {
    /// The materializer (PROTOCOL §15.2): when a pull brings a registration's resolution, its drafts become outbox facts in
    /// author order, under the resolved podcast and generation, with wire episode IDs derived under the podcast
    /// and the resolution decision as a dependency; `install_seq` is assigned now. The podcast and the episodes it
    /// names get their `ntp_podcasts` and `ntp_episodes` rows. One live transaction per registration.
    func resolveRegistration(opID: String, _ resolution: ServerRegistrationResolution) throws {
        guard let context = serverContext else { throw ServerRecordingError.notAServerLibrary }
        guard ContractIdentity.isPodcastID(resolution.podcastID),
              resolution.generationID.map(ContractIdentity.isGenerationID) ?? true else {
            throw ServerRecordingError.corruptState("a resolution without a podcast or generation ID")
        }
        try database.transaction { try materializeRegistration(opID: opID, resolution, context: context) }
    }

    /// The materializer's body inside the caller's transaction: `resolveRegistration`'s own, or the apply unit of the
    /// commit that brings the resolution (PROTOCOL §6.8: one commit, one atomic live change).
    func materializeRegistration(opID: String, _ resolution: ServerRegistrationResolution, context: ServerLibraryContext) throws {
        do {
            guard let row = try database.rows("SELECT feed_id, author_id, state FROM ntp_registrations WHERE op_id = ?", [.text(opID)]).first,
                  case .text(let author) = row[1], case .text(let state) = row[2] else {
                throw ServerRecordingError.unknownRegistration(opID)
            }
            guard state == "pending" else { return }
            let writer = ServerOutboxWriter(database: database, context: context, failAfter: recorderFailureInjection, factBound: factBoundOverride)
            let feedID = row[0].integer
            let live = resolution.mode == "stale" ? nil : resolution.generationID
            if let feedID, try storedHeader(feedID) != nil {
                try writer.execute("UPDATE ntp_podcasts SET feed_id = NULL WHERE feed_id = ? AND podcast_id != ?", [.integer(feedID), .text(resolution.podcastID)])
            }
            try writer.execute("INSERT INTO ntp_podcasts(podcast_id, feed_id, live_generation, registration_op) VALUES (?, ?, ?, ?) ON CONFLICT(podcast_id) DO UPDATE SET feed_id = coalesce(excluded.feed_id, feed_id), live_generation = coalesce(excluded.live_generation, live_generation), registration_op = excluded.registration_op",
                               [.text(resolution.podcastID), try feedID.flatMap { try storedHeader($0) != nil ? $0 : nil }.map(LibrarySQLValue.integer) ?? .null,
                                live.map(LibrarySQLValue.text) ?? .null, .text(opID)])
            if let generation = resolution.generationID {
                // A copied library forked the registration's author (PROTOCOL §6.10): the copied author's drafts first, then each
                // fork's, whose first fact names the tip before it. A draft too large to number stops the chain there.
                chains: for chain in try registrationChain(opID, current: author) {
                    let drafts = try database.rows("SELECT op_id, author_seq, previous_op_id, client_time, kind, template, dependencies, created_at FROM ntp_drafts WHERE author_id = ? ORDER BY author_seq", [.text(chain)])
                    for draft in drafts {
                        guard try materialize(draft, authorID: chain, registrationOp: opID, podcast: resolution.podcastID,
                                              generation: generation, decision: resolution.decisionID, writer: writer) else { break chains }
                    }
                }
            }
            // The discovery ledger's entries of the registration take their generation and episodes (PROTOCOL §9.9).
            if let generation = resolution.generationID { try rekeyServerLedger(registration: opID, generation: generation, writer: writer) }
            // The registration fact's own overlay named the podcast by its local feed until now.
            if let feedID {
                try writer.execute("UPDATE OR REPLACE ntp_overlays SET id = ? WHERE op_id = ? AND id = ?",
                                   [.text(resolution.podcastID), .text(opID), .text("local-feed:\(feedID)")])
            }
            try writer.execute("UPDATE ntp_registrations SET state = 'resolved', podcast_id = ?, generation_id = ?, mode = ?, decision_id = ? WHERE op_id = ?",
                               [.text(resolution.podcastID), resolution.generationID.map(LibrarySQLValue.text) ?? .null, .text(resolution.mode),
                                resolution.decisionID.map(LibrarySQLValue.text) ?? .null, .text(opID)])
            recorderWrites = writer.writes
        }
    }

    /// "Try again" (and Synchronize now, Force full synchronization) for registrations whose drafts were too large to number
    /// (PROTOCOL §6.13): each such chain is materialized again from where it stopped, under its registration's stored
    /// resolution, in author order, each draft with the identity fixed when it was made; the facts redirected behind it
    /// follow in order. A draft still too large stops its chain there again and stays listed. Returns whether any draft was
    /// numbered.
    @discardableResult
    func resumeRefusedDrafts() throws -> Bool {
        guard let context = serverContext else { return false }
        let registrations = try database.rows("SELECT DISTINCT registration_op FROM ntp_drafts WHERE state = 'refused_too_large' ORDER BY registration_op")
            .compactMap { $0[0].text }
        guard !registrations.isEmpty else { return false }
        var numbered = false
        try database.transaction {
            let writer = ServerOutboxWriter(database: database, context: context, failAfter: recorderFailureInjection, factBound: factBoundOverride)
            for op in registrations {
                guard let row = try database.rows("SELECT author_id, podcast_id, generation_id, decision_id FROM ntp_registrations WHERE op_id = ? AND state = 'resolved'",
                                                  [.text(op)]).first,
                      let author = row[0].text, let podcast = row[1].text, let generation = row[2].text else { continue }
                chains: for chain in try registrationChain(op, current: author) {
                    let drafts = try database.rows("SELECT op_id, author_seq, previous_op_id, client_time, kind, template, dependencies, created_at FROM ntp_drafts WHERE author_id = ? ORDER BY author_seq", [.text(chain)])
                    for draft in drafts {
                        guard try materialize(draft, authorID: chain, registrationOp: op, podcast: podcast, generation: generation,
                                              decision: row[3].text, writer: writer) else { break chains }
                        numbered = true
                    }
                }
            }
            // An item stays while its chain waits on a refused draft.
            try writer.execute("DELETE FROM ntp_attention WHERE kind = 'draft_refused' AND id NOT IN (SELECT op_id FROM ntp_drafts WHERE state = 'refused_too_large')")
        }
        if numbered { noteServerOutboxChanged() }
        return numbered
    }

    /// A removal closed the podcast of chains stopped at drafts too large to number (PROTOCOL §6.8, §6.13): the removal applies
    /// here as everywhere. A draft too large ends as a refused registration's drafts end (`terminateRegistration`: with its
    /// overlays and node); the drafts after it on its author's chain are renumbered so the chain stays contiguous
    /// (`dropPlacementSnapshot`) and numbered under the closed generation, in author order, as any pending fact of that
    /// generation is sent and decided by the server; one of them too large ends the same way. Nothing goes to a podcast
    /// subscribed again (its registration has an author of its own). Their Needs attention items go, and the log says so.
    /// Runs in the unit that applies the removal.
    func endRefusedDraftChains(podcast: String) throws {
        guard let context = serverContext else { return }
        let registrations = try database.rows("SELECT DISTINCT d.registration_op FROM ntp_drafts d JOIN ntp_registrations r ON r.op_id = d.registration_op WHERE d.state = 'refused_too_large' AND r.state = 'resolved' AND r.podcast_id = ? ORDER BY d.registration_op",
                                              [.text(podcast)]).compactMap { $0[0].text }
        guard !registrations.isEmpty else { return }
        let writer = ServerOutboxWriter(database: database, context: context, failAfter: recorderFailureInjection, factBound: factBoundOverride)
        var ended = 0
        for op in registrations {
            guard let row = try database.rows("SELECT author_id, generation_id, decision_id FROM ntp_registrations WHERE op_id = ?", [.text(op)]).first,
                  let author = row[0].text, let generation = row[1].text else { continue }
            let chains = try registrationChain(op, current: author)
            // Nothing another author depends on is ever deleted or renumbered (a restored copy's `installation.fork` names
            // the chain's writing tip): such a chain stays as it was, listed, with Try again.
            guard try !chains.contains(where: { try draftsNamedByOthers(author: $0) }) else { continue }
            for chain in chains {
                // The removal deletes the overlays of the closed generation's pending facts (the facts stay as recorded):
                // these drafts' too, so a podcast subscribed again never shows them.
                try writer.execute("DELETE FROM ntp_overlays WHERE op_id IN (SELECT op_id FROM ntp_drafts WHERE author_id = ?)", [.text(chain)])
                // Each pass ends the refused drafts and numbers what follows; a draft refused in it is ended by the next.
                for _ in 0...(try database.scalar("SELECT count(*) FROM ntp_drafts WHERE author_id = ?", [.text(chain)])) {
                    let refused = try database.rows("SELECT op_id, author_seq FROM ntp_drafts WHERE author_id = ? AND state = 'refused_too_large' ORDER BY author_seq",
                                                    [.text(chain)])
                    guard let lowest = refused.first?[1].integer else { break }
                    for draft in refused {
                        guard let draftOp = draft[0].text else { continue }
                        try writer.execute("DELETE FROM ntp_overlays WHERE op_id = ?", [.text(draftOp)])
                        try writer.execute("DELETE FROM ntp_nodes WHERE node_id = ? AND kind = 'draft'", [.text(draftOp)])
                        try writer.execute("DELETE FROM ntp_drafts WHERE op_id = ?", [.text(draftOp)])
                        ended += 1
                    }
                    try renumberDrafts(author: chain, from: lowest, writer)
                    let drafts = try database.rows("SELECT op_id, author_seq, previous_op_id, client_time, kind, template, dependencies, created_at FROM ntp_drafts WHERE author_id = ? ORDER BY author_seq", [.text(chain)])
                    for draft in drafts {
                        guard try materialize(draft, authorID: chain, registrationOp: op, podcast: podcast, generation: generation,
                                              decision: row[2].text, writer: writer) else { break }
                    }
                }
            }
        }
        try writer.execute("DELETE FROM ntp_attention WHERE kind = 'draft_refused' AND id NOT IN (SELECT op_id FROM ntp_drafts WHERE state = 'refused_too_large')")
        if ended > 0 {
            noteServerDiagnostic("too_large", "\(ended) changes too large for the server ended with their removed podcast; the changes after them are sent")
            noteServerOutboxChanged()
        }
    }

    /// Whether a fact or draft of another author names a draft of `author` (as its predecessor or a dependency).
    private func draftsNamedByOthers(author: String) throws -> Bool {
        try database.scalar("""
            SELECT count(*) FROM ntp_drafts d WHERE d.author_id = ? AND (
              EXISTS (SELECT 1 FROM ntp_outbox o WHERE o.author_id != d.author_id AND instr(CAST(o.fact AS TEXT), '"' || d.op_id || '"') > 0)
              OR EXISTS (SELECT 1 FROM ntp_drafts x WHERE x.author_id != d.author_id
                         AND (x.previous_op_id = d.op_id OR instr(coalesce(x.dependencies, ''), '"' || d.op_id || '"') > 0
                              OR instr(CAST(x.template AS TEXT), '"' || d.op_id || '"') > 0)))
            """, [.text(author)]) > 0
    }

    /// The drafts of `author` from `seq` on, renumbered contiguously after what precedes them on the chain (a draft, or a
    /// fact already numbered), and the author's position after them.
    private func renumberDrafts(author: String, from seq: Int64, _ writer: ServerOutboxWriter) throws {
        var previous = try database.rows("SELECT op_id FROM ntp_drafts WHERE author_id = ? AND author_seq < ? ORDER BY author_seq DESC LIMIT 1",
                                         [.text(author), .integer(seq)]).first?.first?.text
            ?? database.rows("SELECT op_id FROM ntp_outbox WHERE author_id = ? AND author_seq < ? ORDER BY author_seq DESC LIMIT 1",
                             [.text(author), .integer(seq)]).first?.first?.text
        var next = seq
        for row in try database.rows("SELECT op_id FROM ntp_drafts WHERE author_id = ? AND author_seq >= ? ORDER BY author_seq", [.text(author), .integer(seq)]) {
            guard let op = row[0].text else { continue }
            try writer.execute("UPDATE ntp_drafts SET author_seq = ?, previous_op_id = ? WHERE op_id = ?",
                               [.integer(next), previous.map(LibrarySQLValue.text) ?? .null, .text(op)])
            previous = op
            next += 1
        }
        try writer.execute("UPDATE ntp_authors SET next_seq = ?, last_op_id = ? WHERE author_id = ?",
                           [.integer(next), previous.map(LibrarySQLValue.text) ?? .null, .text(author)])
    }

    /// Returns false for a draft larger than the server accepts once materialized (PROTOCOL §6.13): it is not numbered; it
    /// stays a draft (`refused_too_large`) with its overlays, so the change stays shown here, and the drafts after it wait.
    /// Needs attention says so; the materialization itself goes on, and other chains are unaffected.
    private func materialize(_ row: [LibrarySQLValue], authorID: String, registrationOp: String, podcast: String, generation: String,
                             decision: String?, writer: ServerOutboxWriter) throws -> Bool {
        guard case .text(let opID) = row[0], let seq = row[1].integer, let clientTime = row[3].integer,
              case .text(let type) = row[4], let templateData = row[5].data, let created = row[7].integer else {
            throw ServerRecordingError.corruptState("ntp_drafts")
        }
        let previous: String? = if case .text(let value) = row[2] { value } else { nil }
        var dependencies: [String] = []
        if case .text(let text) = row[6] { dependencies = (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? [] }
        dependencies.append(decision ?? registrationOp)
        let template = try ContractJSON.decode(templateData)
        var localIDs: [String: String] = ["local-feed:\(try feedIDOfRegistration(registrationOp).map(String.init) ?? "")": podcast]
        guard case .object(var payload) = try materializeValue(template["payload"] ?? [:], podcast: podcast, generation: generation,
                                                              localIDs: &localIDs, writer: writer) else {
            throw ServerRecordingError.corruptState("draft payload")
        }
        // Targets after the payload: a target placeholder names an episode the payload's reference derived.
        let targets = try (template["targets"]?.arrayValue ?? []).map {
            try materializeValue($0, podcast: podcast, generation: generation, localIDs: &localIDs, writer: writer)
        }.compactMap { json -> ServerFactTarget? in
            guard let entity = json["entity"]?.stringValue, let id = json["id"]?.stringValue else { return nil }
            return ServerFactTarget(entity: entity, id: id, generation: json["generation"]?.stringValue)
        }
        // Bulk member lists are sorted by episode ID (PROTOCOL §7.2).
        for key in ["episodes", "observed"] {
            if let list = payload[key]?.arrayValue {
                payload[key] = .array(list.sorted {
                    ($0["episode_id"]?.stringValue ?? "").utf8.lexicographicallyPrecedes(($1["episode_id"]?.stringValue ?? "").utf8)
                })
            }
        }
        let secrets = template["secret_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let fact = ServerOutboxWriter.fact(opID: opID, authorID: authorID, authorSeq: seq, previousOpID: previous, dependencies: dependencies,
                                           type: type, clientTime: clientTime, targets: targets, payload: payload)
        let size = try fact.canonicalBytes().count
        if size > writer.factBound {
            try writer.execute("UPDATE ntp_drafts SET state = 'refused_too_large' WHERE op_id = ?", [.text(opID)])
            var record: ContractObject = ["registration": .string(registrationOp)]
            if let feed = try feedIDOfRegistration(registrationOp), let title = try loadFeedHeader(feed)?.title { record["title"] = .string(title) }
            try writer.execute("INSERT INTO ntp_attention(id, kind, record, created_at) VALUES (?, 'draft_refused', ?, ?) ON CONFLICT(id) DO NOTHING",
                               [.text(opID), .blob(try ContractJSON.object(record).canonicalData()), .integer(created)])
            noteServerDiagnostic("too_large", "\(ServerLogValue.type(type)) \(size) bytes: kept on this device; later changes to its podcast wait")
            return false
        }
        try writer.insertOutboxEntry(opID: opID, authorID: authorID, authorSeq: seq, type: type, fact: fact, secretIDs: secrets, now: created)
        try writer.execute("DELETE FROM ntp_drafts WHERE op_id = ?", [.text(opID)])
        try writer.execute("UPDATE ntp_nodes SET kind = 'local' WHERE node_id = ?", [.text(opID)])
        let clock = try database.scalar("SELECT knowledge_clock FROM ntp_nodes WHERE node_id = ?", [.text(opID)])
        try writer.addNode(opID, clock: clock, dependencies: fact["dependencies"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        for (local, wire) in localIDs {
            // An overlay stays its local episode's when the wire ID is not its own (a provisional
            // release names its earlier release's), as a registered podcast's facts key it.
            if let id = Int64(local.dropFirst("local-episode:".count)), try mappedElsewhere(wire, localID: id) { continue }
            try writer.execute("UPDATE OR REPLACE ntp_overlays SET id = ? WHERE op_id = ? AND id = ?", [.text(wire), .text(opID), .text(local)])
        }
        return true
    }

    /// The authors of a registration's chain, oldest first: `current` and the authors it was forked from (copy
    /// detection, PROTOCOL §6.10), within the registration.
    func registrationChain(_ opID: String, current: String) throws -> [String] {
        var chain = [current], seen: Set<String> = [current]
        while let row = try database.rows("SELECT forked_from FROM ntp_authors WHERE author_id = ? AND registration_op = ?", [.text(chain[0]), .text(opID)]).first,
              let parent = row[0].text, seen.insert(parent).inserted,
              try database.scalar("SELECT count(*) FROM ntp_authors WHERE author_id = ? AND registration_op = ?", [.text(parent), .text(opID)]) == 1 {
            chain.insert(parent, at: 0)
        }
        return chain
    }

    private func feedIDOfRegistration(_ op: String) throws -> Int64? {
        try database.rows("SELECT feed_id FROM ntp_registrations WHERE op_id = ?", [.text(op)]).first?.first?.integer
    }

    /// Replaces a draft template's placeholders: a local episode becomes its `EpisodeRef` (or target) under the
    /// resolved podcast and generation, the registration's podcast becomes `{entity: podcast, id, generation}`.
    private func materializeValue(_ value: ContractJSON, podcast: String, generation: String, localIDs: inout [String: String],
                                  writer: ServerOutboxWriter) throws -> ContractJSON {
        switch value {
        case .array(let items):
            return .array(try items.map { try materializeValue($0, podcast: podcast, generation: generation, localIDs: &localIDs, writer: writer) })
        case .object(let object):
            // A target without a generation (a catalog observation's, PROTOCOL §9.4).
            let withGeneration: String? = object["ntp_no_generation"] == nil ? generation : nil
            if let local = object["ntp_local_episode"]?.integerValue {
                let episode = try localIDs["local-episode:\(local)"] ?? materializedEpisode(local, placeholder: object, podcast: podcast, writer: writer)
                localIDs["local-episode:\(local)"] = episode
                if object["entity"] != nil { return ServerFactTarget(entity: "episode", id: episode, generation: withGeneration).json }
                return ["episode_id": .string(episode), "podcast_id": .string(podcast), "generation_id": .string(generation),
                        "occurrence": object["occurrence"] ?? [:]]
            }
            if object["ntp_registration"] != nil { return ServerFactTarget(entity: "podcast", id: podcast, generation: withGeneration).json }
            // The resolved podcast and generation as plain strings (a discovery's `podcast_id`, `generation_id`).
            if object["ntp_podcast_id"] != nil { return .string(podcast) }
            if object["ntp_generation_id"] != nil { return .string(generation) }
            var copy = object
            for member in object.members {
                copy[member.name] = try materializeValue(member.value, podcast: podcast, generation: generation, localIDs: &localIDs, writer: writer)
            }
            return .object(copy)
        default:
            return value
        }
    }

    /// The wire episode of a local episode named by a draft: its recorded ID, else derived under the resolved
    /// podcast from the identity kind and value fixed when the person acted.
    private func materializedEpisode(_ local: Int64, placeholder: ContractObject, podcast: String, writer: ServerOutboxWriter) throws -> String {
        if let row = try database.rows("SELECT episode_id FROM ntp_episodes WHERE local_id = ? AND podcast_id = ?", [.integer(local), .text(podcast)]).first,
           case .text(let id) = row[0] { return id }
        guard let occurrence = placeholder["occurrence"], let kind = occurrence["k"]?.stringValue, let value = occurrence["v"]?.stringValue else {
            throw ServerRecordingError.corruptState("a draft episode without its identity")
        }
        let id: String
        if kind == "none" {
            guard let e0 = placeholder["e0"]?.stringValue else { throw ServerRecordingError.corruptState("a draft e0 episode") }
            id = "e0:" + e0
        } else {
            // With the podcast's identity rules (PROTOCOL §9.7), as a registered podcast's facts derive it.
            id = try derivedEpisodeID(local, podcast: podcast, key: ServerEpisodeKey(kind: kind, value: value), namespace: writer.context.namespace)
        }
        // A provisional release of rotating enclosures is never mapped to its earlier release's identity.
        if try isProvisionalLocal(local) { return id }
        let exists = try database.scalar("SELECT count(*) FROM episodes WHERE id = ?", [.integer(local)]) == 1
        let taken = try database.scalar("SELECT count(*) FROM ntp_episodes WHERE local_id = ?", [.integer(local)]) > 0
        try writer.execute("INSERT INTO ntp_episodes(episode_id, local_id, podcast_id, kind, value) VALUES (?, ?, ?, ?, ?) ON CONFLICT(episode_id) DO NOTHING",
                           [.text(id), exists && !taken ? .integer(local) : .null, .text(podcast), .text(kind), .text(value)])
        return id
    }

    // MARK: - Account policies (PROTOCOL §15.4)

    /// The account-level policies of a server library: its account records with this library's pending changes
    /// (the latest pending value of each property). Nil in a standalone library.
    public func serverAccountPolicies() throws -> ServerAccountPolicyValues? {
        guard let context = serverContext else { return nil }
        return try ServerAccountPolicyValues.read(database, accountID: context.accountID)
    }

    /// Records an account policy change (`account.set_discovery_policy` or `account.set_queue_policy`, PROTOCOL §15.2).
    public func setServerAccountPolicy(_ change: ServerAccountPolicyChange, now: Date = Date()) throws {
        guard serverContext != nil else { throw ServerRecordingError.notAServerLibrary }
        try Task.checkCancellation()
        try write(.accountPolicy(change), now: now) {}
    }
}
