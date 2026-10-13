import Foundation

/// What a change waiting for another device showed stays shown (PROTOCOL §1.3, §6: a restored
/// server never rolls a phone back). A recovery switches the live base to the server's library; a change this library
/// had applied (its own or another device's, archived and retired) that the restored server lacks and that waits for a
/// dependency another device may restore would vanish with it, though it was never refused.
///
/// Before the switch, every base record whose provenance names a node still waiting is copied to `ntp_recovery_holds`
/// with the nodes it names, and every projection (units, shadows, repairs) reads it in place of the base. A hold ends
/// when a commit writes that record again (the server's newer answer: a change made since, or the waiting one joining)
/// or when none of its nodes waits any more (joined and caught up with, or refused for good); what it held is then
/// projected from the base. New facts still depend on the base's provenance, never on a waiting node, so they are sent
/// at once; the server's rules (PROTOCOL §7) order them after the waiting ones when those join.
extension FeedLibraryStore {
    struct ServerHeldRecord: Sendable, Equatable {
        var key: ServerRecordKey
        /// The waiting nodes its provenance names.
        var nodes: [String]
    }

    /// The base records whose provenance names one of `nodes`, read on a connection of its own (the store is not held
    /// for the scan).
    static func serverRecords(naming nodes: Set<String>, database url: URL) throws -> [ServerHeldRecord] {
        guard !nodes.isEmpty else { return [] }
        let connection = try LibrarySQLite(readingOnly: url)
        defer { try? connection.close() }
        let list = ContractJSON.array(nodes.sorted().map(ContractJSON.string)).canonicalText
        return try connection.transaction(write: false) {
            try connection.rows("SELECT r.entity, r.id, r.field_group, json_group_array(p.value) FROM ntp_records r, json_each(r.provenance) p WHERE p.value IN (SELECT value FROM json_each(?)) GROUP BY r.entity, r.id, r.field_group",
                                [.text(list)]).compactMap { row in
                guard let entity = row[0].text, let id = row[1].text, let group = row[2].text, let named = row[3].text else { return nil }
                return ServerHeldRecord(key: ServerRecordKey(entity: entity, id: id, fieldGroup: group),
                                        nodes: (try ContractJSON.decode(Data(named.utf8)).arrayValue ?? []).compactMap(\.stringValue).sorted())
            }
        }
    }

    /// Holds `records` as the base has them now, 500 to a transaction. A record held already keeps the value it holds
    /// and gains the nodes; one that gains none is not written (a hold write is a local change a retained publication
    /// defers for). Returns how many records are held.
    @discardableResult
    func holdServerRecords(_ records: [ServerHeldRecord]) throws -> Int {
        guard serverContext != nil else { throw ServerRecordingError.notAServerLibrary }
        try ensureServerExchangeTables()
        for chunk in Self.chunks(records) {
            let list = ContractJSON.array(chunk.map { held in
                .array([.string(held.key.entity), .string(held.key.id), .string(held.key.fieldGroup), .array(held.nodes.map(ContractJSON.string))])
            }).canonicalText
            try database.transaction {
                try database.execute("INSERT INTO ntp_recovery_holds(entity, id, field_group, value, provenance, nodes) SELECT r.entity, r.id, r.field_group, r.value, r.provenance, json_extract(k.value, '$[3]') FROM json_each(?) k JOIN ntp_records r ON r.entity = json_extract(k.value, '$[0]') AND r.id = json_extract(k.value, '$[1]') AND r.field_group = json_extract(k.value, '$[2]') WHERE true ON CONFLICT(entity, id, field_group) DO UPDATE SET nodes = (SELECT json_group_array(value) FROM (SELECT value FROM json_each(ntp_recovery_holds.nodes) UNION SELECT value FROM json_each(excluded.nodes))) WHERE EXISTS (SELECT value FROM json_each(excluded.nodes) EXCEPT SELECT value FROM json_each(ntp_recovery_holds.nodes))",
                                     [.text(list)])
            }
        }
        return Int(try database.scalar("SELECT count(*) FROM ntp_recovery_holds"))
    }

    /// Ends the holds none of whose nodes is in `waiting`, at most `limit` in one unit: they go, and what they held is
    /// projected from the base. Nil when none is left to end.
    func releaseServerHolds(stillWaiting waiting: Set<String>, history: ServerHistoryOracle?, now: Int64,
                            limit: Int = 10) throws -> ServerUnitResult? {
        guard let context = serverContext else { return nil }
        try ensureServerExchangeTables()
        var released: [ServerRecordKey] = [], queued: Set<String> = []
        let list = ContractJSON.array(waiting.sorted().map(ContractJSON.string)).canonicalText
        // Newer local work keeps the holds of its feed: a pending registration of the feed, a pending fact
        // about its podcast or the feed; they end once that work is resolved, and what the base lacks then is absent.
        let protected = try newerLocalWork()
        let podcastsList = ContractJSON.array(protected.podcasts.sorted().map(ContractJSON.string)).canonicalText
        let feedsList = ContractJSON.array(protected.feeds.sorted().map(ContractJSON.integer)).canonicalText
        // Podcasts first: one whose creation is refused goes with all its episodes at once (in bounded batches).
        for podcasts in [true, false] where released.count < limit {
            for row in try database.rows("SELECT entity, id, field_group, json_extract(CAST(value AS TEXT), '$.in_queue') FROM ntp_recovery_holds h WHERE (entity = 'podcast') = ? AND NOT EXISTS (SELECT 1 FROM json_each(h.nodes) n WHERE n.value IN (SELECT value FROM json_each(?))) AND NOT (h.entity = 'podcast' AND h.id IN (SELECT value FROM json_each(?))) AND NOT (h.entity = 'episode' AND EXISTS (SELECT 1 FROM ntp_episodes n LEFT JOIN episodes e ON e.id = n.local_id WHERE n.episode_id = h.id AND (n.podcast_id IN (SELECT value FROM json_each(?)) OR e.feed_id IN (SELECT value FROM json_each(?))))) LIMIT ?",
                                         [.integer(podcasts ? 1 : 0), .text(list), .text(podcastsList), .text(podcastsList), .text(feedsList),
                                          .integer(Int64(limit - released.count))]) {
                guard let entity = row[0].text, let id = row[1].text, let group = row[2].text else { continue }
                released.append(ServerRecordKey(entity: entity, id: id, fieldGroup: group))
                if entity == "episode", group == "queue_membership", row[3].integer == 1 { queued.insert(id) }
            }
        }
        guard !released.isEmpty else { return nil }
        let clock = ContinuousClock(), started = clock.now
        var result = try write(.remote, durable: true) {
            var result = ServerUnitResult(seq: try serverExchangeState().cursor?.seq ?? 0)
            let projector = try unitProjector(context: context, now: now)
            projector.history = history
            try projector.dropHolds(released)
            var scope = ServerProjectionScope()
            // What the server does not have goes (its creation or identity refused for good).
            let removed = try projector.projectReleasedAbsence(podcasts: Set(released.filter { $0.entity == "podcast" }.map(\.id)),
                                                               episodes: Set(released.filter { $0.entity == "episode" }.map(\.id)),
                                                               identities: Set(released.filter { $0.entity == "episode" && $0.fieldGroup == "identity" }.map(\.id)))
            for key in released where !(key.entity == "episode" && removed.contains(key.id)) { scope.add(record: key.entity, id: key.id, group: key.fieldGroup) }
            // A membership the hold kept and the base does not have is absent on the server: it leaves the queue
            // unless something else supports it (a later local change, an owed add, the player), never kept by the
            // queue as it stands.
            scope.withdrawnQueue.formUnion(queued)
            if !queued.isEmpty { scope.queue = true }
            try projector.project(scope)
            let plan = projector.plan
            if !plan.missingSecrets.isEmpty { throw ServerApplyError.missingSecrets(plan.missingSecrets) }
            result.work = plan.work + released.count
            try writePlan(plan, now: now, result: &result)
            return result
        }
        result.lockMilliseconds = Self.milliseconds(started.duration(to: clock.now))
        return result
    }

    /// The feeds with newer local work and their podcasts: pending registrations of a feed, pending facts about a
    /// podcast or a feed (`local-feed:`).
    private func newerLocalWork() throws -> (feeds: Set<Int64>, podcasts: Set<String>) {
        var feeds = Set(try database.rows("SELECT feed_id FROM ntp_registrations WHERE state = 'pending' AND feed_id IS NOT NULL").compactMap { $0[0].integer })
        var podcasts = Set<String>()
        for row in try database.rows("SELECT DISTINCT id FROM ntp_overlays WHERE entity = 'podcast'") {
            guard let id = row[0].text else { continue }
            if id.hasPrefix("local-feed:"), let feed = Int64(id.dropFirst("local-feed:".count)) { feeds.insert(feed) } else { podcasts.insert(id) }
        }
        for podcast in podcasts {
            if let feed = try database.rows("SELECT feed_id FROM ntp_podcasts WHERE podcast_id = ?", [.text(podcast)]).first?.first?.integer { feeds.insert(feed) }
        }
        for feed in feeds {
            for row in try database.rows("SELECT podcast_id FROM ntp_podcasts WHERE feed_id = ?", [.integer(feed)]) { if let id = row[0].text { podcasts.insert(id) } }
        }
        return (feeds, podcasts)
    }

    /// How many records a recovery holds (the log, tests).
    func serverHeldRecordCount() throws -> Int {
        guard serverContext != nil else { return 0 }
        try ensureServerExchangeTables()
        return Int(try database.scalar("SELECT count(*) FROM ntp_recovery_holds"))
    }
}
