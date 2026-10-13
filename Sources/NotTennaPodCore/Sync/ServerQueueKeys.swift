import Foundation

/// Queue keys of a server library (PROTOCOL §7.6): every queue entry has a contract-v1 key in `ntp_queue_keys`, and the
/// local `queue.position` order equals key order.
extension FeedLibraryStore {
    func storedQueueKeys() throws -> [Int64: StoredQueueKey] {
        try queueKeys(from: database.rows("SELECT episode_id, key, position_id, device_only FROM ntp_queue_keys"))
    }

    /// The stored keys of the given members only (a bounded read).
    func storedQueueKeys(_ members: [Int64]) throws -> [Int64: StoredQueueKey] {
        guard !members.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: members.count).joined(separator: ", ")
        return try queueKeys(from: database.rows("SELECT episode_id, key, position_id, device_only FROM ntp_queue_keys WHERE episode_id IN (\(marks))",
                                                 members.map(LibrarySQLValue.integer)))
    }

    private func queueKeys(from rows: [[LibrarySQLValue]]) throws -> [Int64: StoredQueueKey] {
        var result: [Int64: StoredQueueKey] = [:]
        for row in rows {
            guard let id = row[0].integer, case .text(let wire) = row[1], case .text(let positionID) = row[2],
                  let deviceOnly = row[3].integer else { throw ServerRecordingError.corruptState("ntp_queue_keys") }
            result[id] = StoredQueueKey(key: try QueueKey(wire: wire), positionID: positionID, deviceOnly: deviceOnly != 0)
        }
        return result
    }

    /// Gives the queue after the transaction its keys (`planQueueKeys`) and writes the ones that changed.
    func syncQueueKeys(_ s: RecordingSession) throws {
        // An unchanged queue keeps its keys (most writes, every playback save).
        guard s.capture.queueBefore != s.queueAfter || !s.capture.movedQueueEpisodes.isEmpty || s.capture.queueRestore != nil else { return }
        let order = s.queueAfter
        let members = Set(order)
        let stored = try storedQueueKeys()
        for (id, key) in stored where !members.contains(id) {
            s.removedKeys[id] = key
            try s.writer.execute("DELETE FROM ntp_queue_keys WHERE episode_id = ?", [.integer(id)])
        }
        var restore: (episodeID: Int64, key: StoredQueueKey)?
        if let undo = s.capture.queueRestore, let old = queueRemovalKeys[undo.operationID] { restore = (undo.episodeID, old) }
        var deviceOnly = Set<Int64>()
        for id in order where try isDeviceOnly(id, s) { deviceOnly.insert(id) }
        let planned = try Self.planQueueKeys(order: order, stored: stored, forced: Set(s.capture.movedQueueEpisodes),
                                             restore: restore, deviceOnly: deviceOnly)
        for (position, id) in order.enumerated() {
            let entry = planned[position]
            s.queueKeys[id] = entry.key
            let old = stored[id]
            if old?.key != entry.key.key || old?.positionID != entry.key.positionID { s.freshKeys.insert(id) }
            if old != entry.key || entry.key.deviceOnly {
                try s.writer.execute("INSERT INTO ntp_queue_keys(episode_id, key, position_id, device_only, next_anchor, previous_anchor) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(episode_id) DO UPDATE SET key = excluded.key, position_id = excluded.position_id, device_only = excluded.device_only, next_anchor = excluded.next_anchor, previous_anchor = excluded.previous_anchor",
                                     [.integer(id), .text(entry.key.key.wire), .text(entry.key.positionID), .integer(entry.key.deviceOnly ? 1 : 0),
                                      entry.next.map(LibrarySQLValue.integer) ?? .null, entry.previous.map(LibrarySQLValue.integer) ?? .null])
            }
        }
        // Keying the whole queue settles one a failed play load left unsettled.
        if try owedSettlement() { try settleOwedQueue(byKeySync: order, fresh: s.freshKeys, deviceOnly: deviceOnly, writer: s.writer) }
    }

    /// One member's planned key, and for a device-only entry its anchors (the synced episodes around it).
    struct PlannedQueueKey: Sendable {
        var key: StoredQueueKey
        var next: Int64?
        var previous: Int64?
    }

    /// The keys of a queue in `order` (PROTOCOL §7.6): members along the first longest increasing run of their current keys keep
    /// them (PROTOCOL §7.6, as the web client's `rekey`); the others, and the `forced` members a manual move
    /// placed, get fresh keys between their neighbours, left to right. Undo of a removal asserts the removed key when
    /// it still lies between the restored neighbours. Device-only entries (PROTOCOL §7.6) take keys in the same key space, with
    /// anchors. Pure, so a settlement can plan off the store.
    static func planQueueKeys(order: [Int64], stored: [Int64: StoredQueueKey], forced: Set<Int64>,
                              restore: (episodeID: Int64, key: StoredQueueKey)?, deviceOnly: Set<Int64>) throws -> [PlannedQueueKey] {
        var candidates: [StoredQueueKey?] = order.map { forced.contains($0) ? nil : stored[$0] }
        if let restore, let index = order.firstIndex(of: restore.episodeID) {
            let old = restore.key
            let low = index > 0 ? candidates[index - 1]?.key : nil
            let high = index + 1 < order.count ? candidates[index + 1]?.key : nil
            if (index == 0 || low.map { $0 < old.key } == true) && (index + 1 == order.count || high.map { old.key < $0 } == true) {
                candidates[index] = old
            }
        }
        let keep = firstLongestIncreasingRun(candidates.map { $0?.key })
        var assigned: [StoredQueueKey] = []
        var index = 0
        while index < order.count {
            if keep[index], let kept = candidates[index] { assigned.append(kept); index += 1; continue }
            var end = index
            while end < order.count && !keep[end] { end += 1 }
            let high = end < order.count ? candidates[end]?.key : nil
            for position in index..<end {
                let low = position > 0 ? assigned[position - 1].key : nil
                let id = UUID()
                assigned.append(StoredQueueKey(key: try QueueKey.between(low, high, positionWriteID: id),
                                               positionID: id.uuidString.lowercased(), deviceOnly: false))
            }
            index = end
        }
        let local = order.map(deviceOnly.contains)
        return order.indices.map { position in
            var key = assigned[position]
            key.deviceOnly = local[position]
            let previous = local[position] ? order[..<position].indices.reversed().first { !local[$0] }.map { order[$0] } : nil
            let next = local[position] ? order[(position + 1)...].indices.first { !local[$0] }.map { order[$0] } : nil
            return PlannedQueueKey(key: key, next: next, previous: previous)
        }
    }

    /// The lexicographically first (by position) longest strictly increasing run of the given keys; nil entries
    /// are never kept. Keys are ranked first, so the quadratic search compares integers.
    static func firstLongestIncreasingRun(_ keys: [QueueKey?]) -> [Bool] {
        let distinct = Array(Set(keys.compactMap { $0 })).sorted()
        var rank: [QueueKey: Int] = [:]
        for (index, key) in distinct.enumerated() { rank[key] = index }
        let ranks = keys.map { $0.flatMap { rank[$0] } }
        let n = ranks.count
        var from = [Int](repeating: 0, count: n)
        var longest = 0
        for i in stride(from: n - 1, through: 0, by: -1) {
            guard let value = ranks[i] else { continue }
            from[i] = 1
            for j in (i + 1)..<max(i + 1, n) {
                if let other = ranks[j], value < other, from[j] + 1 > from[i] { from[i] = from[j] + 1 }
            }
            longest = max(longest, from[i])
        }
        var keep = [Bool](repeating: false, count: n)
        var need = longest
        var last: Int?
        for i in 0..<n where need > 0 {
            guard let value = ranks[i], from[i] == need else { continue }
            if let last, let previous = ranks[last], previous >= value { continue }
            keep[i] = true; last = i; need -= 1
        }
        return keep
    }

    /// The duration the canonical comparator sorts by in a server library (PROTOCOL §7.6): the server's own value, so
    /// this phone's sort and the server's replay of it agree and nothing moves when the server's keys arrive. For a
    /// synced episode that is the `measured_duration` register, else the feed's duration in the server's catalog, else
    /// none, as the server's occurrence evidence has none; never this phone's stored value, which may be its own
    /// measurement, unexported, or a feed duration the server's catalog does not have. A local-folder episode never
    /// reaches the server and keeps its media duration.
    ///
    /// This phone's own observation of the episode that the server has not answered yet (still in the outbox)
    /// comes before any later fact of this phone, so the server's catalog has it when it replays the sort: its record
    /// counts where the server's catalog fold would take it (no record yet, its base the current revision, or a later
    /// fetch time; `S/internal/projection/catalog.go` `FoldCatalog`). `observations` caches decoded facts by op.
    func canonicalSortDuration(_ episode: LibraryEpisode, localFolder: Bool, observations: inout [String: ContractJSON]) throws -> Int64? {
        if localFolder { return episode.details.media.map { Int64($0.durationMilliseconds) } }
        func record(_ wire: String, _ group: String) throws -> ContractJSON? {
            guard let data = try database.rows("SELECT value FROM ntp_records WHERE entity = 'episode' AND id = ? AND field_group = ?",
                                               [.text(wire), .text(group)]).first?.first?.data else { return nil }
            return try ContractJSON.decode(data)
        }
        guard let wire = try database.rows("SELECT episode_id FROM ntp_episodes WHERE local_id = ? ORDER BY merged_into IS NOT NULL, episode_id LIMIT 1",
                                           [.integer(episode.id)]).first?.first?.text else { return nil }
        if let measured = try record(wire, "measured_duration")?["duration_ms"]?.integerValue { return measured }
        let canonical = try record(wire, "metadata")
        if let row = try database.rows("SELECT b.op_id, b.fact FROM ntp_observed o JOIN ntp_outbox b ON b.op_id = o.observation_op WHERE o.entity = 'episode' AND o.id = ?",
                                       [.text(Self.ledgerKey(localEpisode: episode.id))]).first,
           let op = row[0].text, let data = row[1].data {
            if observations[op] == nil { observations[op] = try ContractJSON.decode(data) }
            let fact = observations[op]
            if let item = fact?["payload"]?["items"]?.arrayValue?.first(where: { $0["episode"]?["episode_id"]?.stringValue == wire }) {
                let fetchTime = fact?["payload"]?["fetch_time"]?.integerValue ?? .min
                if canonical == nil || item["base"]?.stringValue == canonical?["revision"]?.stringValue
                    || fetchTime > (canonical?["fetch_time"]?.integerValue ?? .min) {
                    return item["fields"]?["media"]?["duration"]?.integerValue
                }
            }
        }
        return canonical?["media"]?["duration"]?.integerValue
    }

    /// A placement `{episode, key, position_id}` (PROTOCOL §7.6).
    func placement(_ ref: ContractJSON, key: StoredQueueKey) -> ContractJSON {
        ["episode": ref, "key": .string(key.key.wire), "position_id": .string(key.positionID)]
    }

    /// The provenance of the queue records the action observed (PROTOCOL §15.2): every synced member before and after it, so
    /// a removal, a clear and an Undo depend on what they remove or restore whatever the queue becomes.
    func queueProvenance(_ s: RecordingSession) throws -> [String] {
        try queueProvenance(members: s.capture.queueBefore + s.queueAfter, s)
    }

    /// The provenance of the given members' queue records: what an owed replay step's facts depend on, so a step
    /// stays bounded however long the queue is.
    func queueProvenance(members: [Int64], _ s: RecordingSession) throws -> [String] {
        var result: [String] = []
        var seen = Set<Int64>()
        for id in members where seen.insert(id).inserted {
            guard try !isDeviceOnly(id, s) else { continue }
            if let row = try database.rows("SELECT episode_id FROM ntp_episodes WHERE local_id = ?", [.integer(id)]).first,
               case .text(let wire) = row[0] {
                result += try provenance(entity: "episode", id: wire, groups: ["queue_membership", "queue_position"])
            }
        }
        return result
    }
}
