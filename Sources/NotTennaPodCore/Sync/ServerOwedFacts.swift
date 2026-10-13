import Foundation

/// Facts a write that must not fail could not record: a play load's queue add. They are owed durably
/// in `ntp_owed`, one row per intent and subject:
/// - `queue.add` / `episode:<id>`: the added episode; its record is `OwedQueueAdd` (the action's
/// time, the queue
///   policy it was made under, and the place it resolved, PROTOCOL §7.6);
/// - `queue.place` / `episode:<id>`: a member whose local key the load changed (every member a Keep sorted add
///   re-sorted, or whose key settling changed), recorded `{client_time}`. Keys are predictions since the queue
///   replay (PROTOCOL §7.6): nothing is sent for it; it only keeps the member's local key until the replay;
/// - `queue.settle` / `queue`: the play load could not settle the queue keys either; the replay does it first.
///
/// The failed load settles the keys itself, so the local queue order equals key order after every commit and
/// nothing later rekeys what is owed without recording it. The replay then records the owed adds, a bounded number
/// of members per step: a step is one short transaction, so a playback save that arrives while a
/// large debt replays waits for one step at most. A settlement is planned off the store and applied in one short
/// transaction that first checks nothing changed; the queue's order never changes in it.
extension FeedLibraryStore {
    /// The most queue members one replay step names.
    static let owedReplayStepMembers = 4
    /// The largest queue a write's replay step settles inline; a longer one is settled by `replayOwedFacts()`, planned
    /// off the store.
    static let owedInlineSettlementMembers = 64

    /// A play load whose recording failed (PROTOCOL §15.2): the load commits, and its queue add is owed with the policy it was
    /// made under. Its keys are settled now (local order equals key order again), outside the recorder's failed
    /// savepoint; every other member this changes, and every member under Keep sorted, is owed a placement. If that
    /// fails too, the keys stay as they were and the replay settles them first.
    func oweQueueAdd(_ context: ServerLibraryContext, capture: ChangeCapture) throws {
        let queue = try queueEpisodeIDs()
        let before = Set(capture.queueBefore)
        let added = queue.filter { !before.contains($0) }
        guard !added.isEmpty else { return }
        let owed = OwedQueueAdd(clientTime: try milliseconds(capture.clientTime),
                                keepSortedOrder: capture.keepSortedAdd ? capture.keepSortedOrder : nil)
        let now = try milliseconds(Date())
        let record = LibrarySQLValue.blob(Data(try owed.json.canonicalBytes()))
        for id in added {
            var member = owed
            member.place = try owedPlace(of: id, capture.queueInsertions, context: context)
            try database.execute("INSERT OR IGNORE INTO ntp_owed(intent, subject, record, created_at) VALUES ('queue.add', ?, ?, ?)",
                                 [.text(Self.owedSubject(id)), .blob(Data(try member.json.canonicalBytes())), .integer(now)])
        }
        do {
            try database.savepoint("ntp_owed") {
                let writer = ServerOutboxWriter(database: database, context: context, failAfter: nil)
                let s = RecordingSession(intent: .playLoad, capture: capture, writer: writer, clientTime: owed.clientTime, now: now)
                s.queueAfter = queue
                try syncQueueKeys(s)
                try owePlacements(s, queue: queue, except: Set(added), all: owed.keepSortedOrder != nil, clientTime: owed.clientTime, now: now)
            }
        } catch {
            try database.execute("INSERT OR IGNORE INTO ntp_owed(intent, subject, record, created_at) VALUES ('queue.settle', 'queue', ?, ?)",
                                 [record, .integer(now)])
        }
    }

    /// The gap an owed add was inserted into when the load executed it (PROTOCOL §7.6), kept for its replay:
    /// `end` at the back, `start` with no synced episode before it, else the synced episodes before it, nearest first,
    /// up to the first one of a registered podcast, which any author can name. The replay names the nearest one its
    /// author can name then (a registration may have resolved since), so the place is the gap the load resolved,
    /// never one of the queue at replay time, which a Keep sorted pass has changed.
    private func owedPlace(of id: Int64, _ insertions: [QueueInsertion], context: ServerLibraryContext) throws -> OwedQueueAdd.Place? {
        guard let insertion = insertions.first(where: { $0.members.contains(id) }) else { return nil }
        if insertion.end { return .end }
        let offset = insertion.members.firstIndex(of: id) ?? 0
        let preceding = insertion.before.prefix(min(insertion.index, insertion.before.count)) + insertion.members.prefix(offset)
        let s = RecordingSession(intent: .playLoad, capture: ChangeCapture(clientTime: Date()),
                                 writer: ServerOutboxWriter(database: database, context: context, failAfter: nil), clientTime: 0, now: 0)
        var anchors: [Int64] = []
        for candidate in preceding.reversed() {
            guard try !isDeviceOnly(candidate, s), let feed = try feedOf(candidate, s) else { continue }
            anchors.append(candidate)
            if case .registered = try binding(feed, s) { break }
        }
        return anchors.isEmpty ? .start : .after(anchors)
    }

    /// One bounded step of the replay, in the current transaction and its own savepoint: settles the keys if a play
    /// load could not, else records up to `owedReplayStepMembers` owed members, adds first: each owed add as its
    /// `queue.add {members, place}` with its current key; an owed placement is only a local key, so it is let go.
    /// A failure rolls the step back and keeps what is owed; the write in progress records as usual. Returns whether
    /// more is owed after a step that succeeded.
    func replayOwedStep(_ context: ServerLibraryContext) throws -> Bool {
        owedStepAdds = 0
        guard try owedCount() > 0 else { return false }
        let writer = ServerOutboxWriter(database: database, context: context, failAfter: recorderFailureInjection)
        var deferred = false, replayedAdds = 0
        do {
            try database.savepoint("ntp_owed") {
                // What the person removed from the queue since owes nothing.
                try writer.execute("DELETE FROM ntp_owed WHERE intent IN ('queue.add', 'queue.place') AND NOT EXISTS (SELECT 1 FROM queue WHERE queue.episode_id = CAST(substr(ntp_owed.subject, 9) AS INTEGER))")
                if try owedSettlement() {
                    // Bounded: a short queue is settled here, a long one by `replayOwedFacts()`; until then nothing owed
                    // is recorded with a key that does not hold yet.
                    guard try database.scalar("SELECT count(*) FROM queue") <= Self.owedInlineSettlementMembers else { deferred = true; return }
                    let snapshot = try owedSettlementSnapshot()
                    guard try applyOwedSettlement(Self.planOwedSettlement(snapshot), snapshot: snapshot, writer: writer) else {
                        throw ServerRecordingError.corruptState("owed settlement")
                    }
                    return
                }
                let rows = try database.rows("SELECT o.intent, q.episode_id, o.record FROM ntp_owed o JOIN queue q ON q.episode_id = CAST(substr(o.subject, 9) AS INTEGER) WHERE o.intent IN ('queue.add', 'queue.place') ORDER BY o.intent = 'queue.place', q.position LIMIT ?",
                                             [.integer(Int64(Self.owedReplayStepMembers))])
                var added: [(id: Int64, owed: OwedQueueAdd?)] = [], placed: [(id: Int64, op: String?)] = []
                for row in rows {
                    guard case .text(let intent) = row[0], let id = row[1].integer else { throw ServerRecordingError.corruptState("ntp_owed") }
                    if intent == "queue.add" {
                        added.append((id, try row[2].data.map { try OwedQueueAdd(ContractJSON.decode($0)) }))
                    } else if !added.contains(where: { $0.id == id }) {
                        placed.append((id, try row[2].data.flatMap { try ContractJSON.decode($0)["op"]?.stringValue }))
                    }
                }
                let members = added.map(\.id) + placed.map(\.id)
                guard !members.isEmpty else { return }
                let keys = try storedQueueKeys(members)
                // Settled keys are an invariant of every commit: a queued member without one is corrupt state, and the
                // step fails rather than record a guess.
                guard members.allSatisfy({ keys[$0] != nil }) else { throw ServerRecordingError.corruptState("ntp_queue_keys") }
                let order = try queueEpisodeIDs()
                func session(_ time: Int64) throws -> RecordingSession {
                    let s = RecordingSession(intent: .queueAdd, capture: ChangeCapture(clientTime: Date(timeIntervalSince1970: Double(time) / 1000)),
                                             writer: writer, clientTime: time, now: try milliseconds(Date()))
                    s.queueKeys = keys
                    s.queueAfter = order
                    return s
                }
                var recorded: String?
                for (id, owed) in added {
                    let s = try session(owed?.clientTime ?? 0)
                    recorded = try emitOwedAdd(s, id, place: owed?.place, order: order, dependencies: try queueProvenance(members: [id], s)) ?? recorded
                }
                if let recorded {
                    // The members the load re-keyed keep showing its order with the add, until the server's keys arrive.
                    try writer.execute("UPDATE ntp_owed SET record = CAST(json_set(CAST(record AS TEXT), '$.op', ?) AS BLOB) WHERE intent = 'queue.place'",
                                       [.text(recorded)])
                }
                if !placed.isEmpty {
                    let s = try session(0)
                    for (id, op) in placed {
                        guard let op = op ?? recorded else { continue }
                        try showOwedPlacement(s, id, with: op)
                    }
                }
                for id in members {
                    try writer.execute("DELETE FROM ntp_owed WHERE intent IN ('queue.add', 'queue.place') AND subject = ?", [.text(Self.owedSubject(id))])
                }
                replayedAdds = added.count
            }
        } catch {
            // Kept for a later write or replay (failure injection in tests); nothing spins on it.
            owedTransactionWrites = writer.writes
            return false
        }
        owedTransactionWrites = writer.writes
        owedStepAdds = replayedAdds
        return try !deferred && owedCount() > 0
    }

    /// The sync log's line for owed queue additions recorded late, noted after their transaction committed (PROTOCOL §15.5).
    func noteOwedReplayed(_ adds: Int) {
        noteServerDiagnostic("owed", "\(adds) queue additions made while recording failed are recorded now")
    }

    /// The sync log's line for listening a playback write could not record (`export_owed`, PROTOCOL §8.2), recorded by a later
    /// write; noted after that write committed (PROTOCOL §15.5).
    func noteOwedPlaybackRecorded() {
        noteServerDiagnostic("owed", "listening saved while recording failed is recorded now")
    }

    /// One transaction of `replayOwedFacts()`, counted (and traced for tests).
    private func replayTransaction<T>(settlement: Bool, _ body: () throws -> T) throws -> T {
        let start = ContinuousClock.now
        owedTransactionWrites = 0
        defer {
            owedReplayTransactions.withLock { $0 += 1 }
            owedReplayTrace?.append(OwedReplayTransaction(duration: start.duration(to: .now), writes: owedTransactionWrites, settlement: settlement))
        }
        return try syncTransactions(ServerTransactionKind.bookkeeping) { try database.transaction(durable: false, body) }
    }

    /// Replays owed facts now, a bounded step per transaction, yielding the store between steps so a playback save
    /// never waits for more than one step. Called when a server library opens (launch) and by the
    /// exchange before it pushes; otherwise each eligible write takes one step before its own action.
    public func replayOwedFacts() async throws {
        // The restart export and owed playback facts first (PROTOCOL §8.2), in one short playback write.
        try flushServerPlayback()
        guard let context = serverContext, try owedCount() > 0 else { return }
        if try owedSettlement() {
            guard try await settleOwedQueue(context) else { return }
            await Task.yield()
        }
        // Every step records something, so this ends; the bound only guards against a step that would not.
        var steps = try owedCount() + database.scalar("SELECT count(*) FROM queue") + 8
        // What committed steps recorded is logged (PROTOCOL §15.5), also when a later step fails.
        var replayed = 0
        defer { if replayed > 0 { noteOwedReplayed(replayed) } }
        // A step's facts become durable with the exchange's barrier before they are sent; a lost step loses its
        // owed rows' deletion with it, so it is replayed again.
        while steps > 0 {
            let more = try replayTransaction(settlement: false, { try replayOwedStep(context) })
            replayed += owedStepAdds
            guard more else { break }
            steps -= 1
            await Task.yield()
        }
    }

    /// Settles a queue a play load left unsettled: a short read, the plan made off the store (the queue's
    /// whole key assignment), then one short transaction that applies it only if the queue and its keys are still
    /// what was read. A change in between plans again. Returns whether the queue is settled.
    func settleOwedQueue(_ context: ServerLibraryContext) async throws -> Bool {
        for _ in 0..<3 {
            let snapshot = try database.transaction(write: false) { try owedSettlementSnapshot() }
            let plan = try await Task.detached(priority: .utility) { try Self.planOwedSettlement(snapshot) }.value
            let writer = ServerOutboxWriter(database: database, context: context, failAfter: recorderFailureInjection)
            do {
                let applied = try replayTransaction(settlement: true) {
                    let applied = try database.savepoint("ntp_owed") { try applyOwedSettlement(plan, snapshot: snapshot, writer: writer) }
                    owedTransactionWrites = writer.writes
                    return applied
                }
                if applied { return true }
            } catch {
                return false // Kept for a later replay (failure injection in tests).
            }
            await Task.yield()
        }
        return false
    }

    /// An owed add's `queue.add {members, place}`: the gap the load resolved, projected onto the nearest of its kept
    /// anchors the author can name, else `start`. Only an add owed before places were kept is placed by the gap it is
    /// in now. Returns the fact's op ID.
    private func emitOwedAdd(_ s: RecordingSession, _ id: Int64, place: OwedQueueAdd.Place?, order: [Int64], dependencies: [String]) throws -> String? {
        var recorded: String?
        for group in try queueGroups([id], s, register: true) {
            var resolved: QueuePlace?
            switch place {
            case .end?: resolved = .end
            case .start?: resolved = .start
            case .after(let anchors)?:
                resolved = try insertionPlace(QueueInsertion(members: [id], before: anchors.reversed(), index: anchors.count, end: false),
                                              first: id, author: group.author, s)
            case nil: break
            }
            if resolved == nil {
                let now = QueueInsertion(members: [id], before: order.filter { $0 != id }, index: order.firstIndex(of: id) ?? order.count, end: false)
                resolved = try insertionPlace(now, first: id, author: group.author, s)
            }
            var extra: [ServerOverlay] = []
            recorded = try emitAdd(s, type: "queue.add", author: group.author, members: group.members, place: resolved ?? .start,
                                   dependencies: dependencies, extra: &extra)
        }
        return recorded
    }

    /// An owed placement is a key the load predicted, not a fact (keys are predictions, PROTOCOL §7.6): it becomes
    /// a position overlay of the owed add's fact, so the queue keeps the load's order through pulled commits until
    /// that fact retires. Nothing is shown once the fact has retired.
    private func showOwedPlacement(_ s: RecordingSession, _ id: Int64, with op: String) throws {
        let pending = try database.scalar("SELECT (SELECT count(*) FROM ntp_outbox WHERE op_id = ?) + (SELECT count(*) FROM ntp_drafts WHERE op_id = ?)",
                                          [.text(op), .text(op)])
        guard pending > 0, let key = s.queueKeys[id], let binding = try queueBinding(id, s, register: false),
              let reference = try episodeReference(id, binding: binding, s) else { return }
        let clock = try database.scalar("SELECT knowledge_clock FROM ntp_nodes WHERE node_id = ?", [.text(op)])
        try s.writer.writeOverlays([ServerOverlay(entity: "episode", id: reference.entityID, property: "queue_position", kind: .register,
                                                  value: ["key": .string(key.key.wire), "position_id": .string(key.positionID)])],
                                   opID: op, clock: clock)
    }

    // MARK: - Helpers

    static func owedSubject(_ episodeID: Int64) -> String { "episode:\(episodeID)" }

    private func owedCount() throws -> Int64 {
        try database.scalar("SELECT count(*) FROM ntp_owed WHERE intent IN ('queue.add', 'queue.place', 'queue.settle')")
    }

    /// Owes a placement for every queue member except `except` whose key the session changed, or every member with
    /// `all` (a Keep sorted add's re-sort); device-only entries never reach the server (PROTOCOL §7.6).
    private func owePlacements(_ s: RecordingSession, queue: [Int64], except: Set<Int64>, all: Bool, clientTime: Int64, now: Int64) throws {
        let record = LibrarySQLValue.blob(Data(try (["client_time": .integer(clientTime)] as ContractJSON).canonicalBytes()))
        for id in queue where !except.contains(id) && (all || s.freshKeys.contains(id)) {
            guard try !isDeviceOnly(id, s) else { continue }
            try s.writer.execute("INSERT OR IGNORE INTO ntp_owed(intent, subject, record, created_at) VALUES ('queue.place', ?, ?, ?)",
                                 [.text(Self.owedSubject(id)), record, .integer(now)])
        }
    }

    func owedSettlement() throws -> Bool {
        try database.scalar("SELECT count(*) FROM ntp_owed WHERE intent = 'queue.settle'") > 0
    }

    /// What a settlement reads: the queue, its key rows as stored, the device-only members, and what the owed adds were
    /// made under. Small and quick to read; the plan is made from it off the store.
    struct OwedSettlementSnapshot: Sendable {
        struct KeyRow: Sendable, Equatable {
            var episode: Int64, key: String, positionID: String, deviceOnly: Bool, next: Int64?, previous: Int64?
        }
        var order: [Int64]
        var keys: [KeyRow]
        var deviceOnly: Set<Int64>
        var added: Set<Int64>
        var keepSorted: Bool
        var clientTime: Int64
    }

    /// The settlement's writes: the key rows to write and the placements owed for the members whose keys change (every
    /// member, when an owed add was made under Keep sorted).
    struct OwedSettlementPlan: Sendable {
        var rows: [OwedSettlementSnapshot.KeyRow]
        var placements: [Int64]
    }

    func owedSettlementSnapshot() throws -> OwedSettlementSnapshot {
        let order = try queueEpisodeIDs()
        let keys = try database.rows("SELECT episode_id, key, position_id, device_only, next_anchor, previous_anchor FROM ntp_queue_keys ORDER BY episode_id").map { row in
            guard let id = row[0].integer, let key = row[1].text, let position = row[2].text else { throw ServerRecordingError.corruptState("ntp_queue_keys") }
            return OwedSettlementSnapshot.KeyRow(episode: id, key: key, positionID: position, deviceOnly: row[3].integer == 1,
                                                 next: row[4].integer, previous: row[5].integer)
        }
        // Device-only entries are the members of local folders (PROTOCOL §7.6), by their feeds.
        var feeds: [Int64: [Int64]] = [:]
        for row in try database.rows("SELECT q.episode_id, e.feed_id FROM queue q JOIN episodes e ON e.id = q.episode_id") {
            if let id = row[0].integer, let feed = row[1].integer { feeds[feed, default: []].append(id) }
        }
        var deviceOnly = Set<Int64>()
        for (feed, members) in feeds where try storedHeader(feed)?.source.isLocalFeedSource == true { deviceOnly.formUnion(members) }
        var added = Set<Int64>(), keepSorted = false
        var clientTime: Int64?
        for row in try database.rows("SELECT intent, subject, record FROM ntp_owed WHERE intent IN ('queue.add', 'queue.settle')") {
            guard let intent = row[0].text, let subject = row[1].text else { continue }
            if intent == "queue.add", let id = Int64(subject.dropFirst("episode:".count)) { added.insert(id) }
            guard let data = row[2].data else { continue }
            let owed = try OwedQueueAdd(ContractJSON.decode(data))
            if owed.keepSortedOrder != nil { keepSorted = true }
            clientTime = min(clientTime ?? owed.clientTime, owed.clientTime)
        }
        return OwedSettlementSnapshot(order: order, keys: keys, deviceOnly: deviceOnly, added: added, keepSorted: keepSorted,
                                      clientTime: clientTime ?? 0)
    }

    /// The settlement as any queue write keys a queue (`planQueueKeys`), with nothing taken as before: every member is
    /// checked against its neighbours. Pure: runs off the store.
    static func planOwedSettlement(_ snapshot: OwedSettlementSnapshot) throws -> OwedSettlementPlan {
        var stored: [Int64: StoredQueueKey] = [:]
        for row in snapshot.keys {
            stored[row.episode] = StoredQueueKey(key: try QueueKey(wire: row.key), positionID: row.positionID, deviceOnly: row.deviceOnly)
        }
        let planned = try planQueueKeys(order: snapshot.order, stored: stored, forced: [], restore: nil, deviceOnly: snapshot.deviceOnly)
        let current = Dictionary(uniqueKeysWithValues: snapshot.keys.map { ($0.episode, $0) })
        var rows: [OwedSettlementSnapshot.KeyRow] = [], placements: [Int64] = []
        for (position, id) in snapshot.order.enumerated() {
            let entry = planned[position]
            let row = OwedSettlementSnapshot.KeyRow(episode: id, key: entry.key.key.wire, positionID: entry.key.positionID,
                                                    deviceOnly: entry.key.deviceOnly, next: entry.next, previous: entry.previous)
            if current[id] != row { rows.append(row) }
            let fresh = current[id].map { $0.key != row.key || $0.positionID != row.positionID } ?? true
            if !entry.key.deviceOnly, !snapshot.added.contains(id), snapshot.keepSorted || fresh { placements.append(id) }
        }
        return OwedSettlementPlan(rows: rows, placements: placements)
    }

    /// Applies a settlement in the current transaction if the queue and its keys are still the snapshot's; otherwise
    /// writes nothing and returns false. A few statements whatever the queue's length; the order is unchanged.
    func applyOwedSettlement(_ plan: OwedSettlementPlan, snapshot: OwedSettlementSnapshot, writer: ServerOutboxWriter) throws -> Bool {
        guard try owedSettlement() else { return true }
        let now = try owedSettlementSnapshot()
        guard now.order == snapshot.order, now.keys == snapshot.keys, now.deviceOnly == snapshot.deviceOnly else { return false }
        try writer.execute("DELETE FROM ntp_queue_keys WHERE episode_id NOT IN (SELECT episode_id FROM queue)")
        if !plan.rows.isEmpty {
            let rows = ContractJSON.array(plan.rows.map { row in
                .array([.integer(row.episode), .string(row.key), .string(row.positionID), .integer(row.deviceOnly ? 1 : 0),
                        row.next.map(ContractJSON.integer) ?? .null, row.previous.map(ContractJSON.integer) ?? .null])
            })
            try writer.execute("INSERT INTO ntp_queue_keys(episode_id, key, position_id, device_only, next_anchor, previous_anchor) SELECT json_extract(value, '$[0]'), json_extract(value, '$[1]'), json_extract(value, '$[2]'), json_extract(value, '$[3]'), json_extract(value, '$[4]'), json_extract(value, '$[5]') FROM json_each(?) WHERE true ON CONFLICT(episode_id) DO UPDATE SET key = excluded.key, position_id = excluded.position_id, device_only = excluded.device_only, next_anchor = excluded.next_anchor, previous_anchor = excluded.previous_anchor",
                               [.text(rows.canonicalText)])
        }
        try finishOwedSettlement(placements: plan.placements, clientTime: snapshot.clientTime, writer: writer)
        return true
    }

    /// Owes the settled placements and clears the settlement: a few statements whatever their number.
    private func finishOwedSettlement(placements: [Int64], clientTime: Int64, writer: ServerOutboxWriter) throws {
        if !placements.isEmpty {
            let record = try (["client_time": .integer(clientTime)] as ContractJSON).canonicalString()
            try writer.execute("INSERT OR IGNORE INTO ntp_owed(intent, subject, record, created_at) SELECT 'queue.place', 'episode:' || value, CAST(? AS BLOB), ? FROM json_each(?)",
                               [.text(record), .integer(try milliseconds(Date())), .text(ContractJSON.array(placements.map(ContractJSON.integer)).canonicalText)])
        }
        try writer.execute("DELETE FROM ntp_owed WHERE intent = 'queue.settle'")
        // A shadow staged while the queue was unsettled is projected again at publication (PROTOCOL §6.8).
        try writer.execute("UPDATE ntp_library SET overlay_revision = overlay_revision + 1 WHERE id = 1")
    }

    /// A queue write's key sync keyed the whole unsettled queue (`syncQueueKeys`): that settles it. The members it
    /// re-keyed (every synced member, if an owed add was made under Keep sorted) are owed placements, whatever the
    /// write itself records, so the settlement is never lost to a write that does not name them.
    func settleOwedQueue(byKeySync order: [Int64], fresh: Set<Int64>, deviceOnly: Set<Int64>, writer: ServerOutboxWriter) throws {
        let snapshot = try owedSettlementSnapshot()
        let placements = order.filter { !deviceOnly.contains($0) && !snapshot.added.contains($0) && (snapshot.keepSorted || fresh.contains($0)) }
        try finishOwedSettlement(placements: placements, clientTime: snapshot.clientTime, writer: writer)
    }
}

/// One transaction of the owed-fact replay, for tests: its time on the store and the recorder's writes in it.
struct OwedReplayTransaction: Sendable {
    var duration: Duration
    var writes: Int
    var settlement: Bool
}

/// What an owed play-load queue add keeps for its replay: the action's time, the queue policy it was
/// made under (the Keep sorted order it re-sorted the queue by, or nil when it did not), and the place
/// it resolved (PROTOCOL §7.6; its anchors are local episodes, nearest first, named when the add is recorded).
/// Stored as `ntp_owed.record`: `{client_time, keep_sorted, sort_order?, place?}`, `place` `{kind: start | end}` or
/// `{kind: after, local: [<episode>…]}`; a record without one (owed before places were kept) is placed where it is.
struct OwedQueueAdd: Equatable {
    enum Place: Equatable { case start, end, after([Int64]) }
    var clientTime: Int64
    var keepSortedOrder: QueueSortOrder?
    var place: Place?

    init(clientTime: Int64, keepSortedOrder: QueueSortOrder?, place: Place? = nil) {
        self.clientTime = clientTime
        self.keepSortedOrder = keepSortedOrder == .random ? nil : keepSortedOrder
        self.place = place
    }

    init(_ json: ContractJSON) throws {
        guard let time = json["client_time"]?.integerValue else { throw ServerRecordingError.corruptState("ntp_owed record") }
        let order = json["keep_sorted"]?.boolValue == true ? json["sort_order"]?.stringValue.flatMap(QueueSortOrder.init(rawValue:)) : nil
        var place: Place?
        switch json["place"]?["kind"]?.stringValue {
        case "start": place = .start
        case "end": place = .end
        case "after":
            let local = json["place"]?["local"]
            if let one = local?.integerValue { place = .after([one]) }
            else if let list = local?.arrayValue?.compactMap(\.integerValue), !list.isEmpty { place = .after(list) }
        default: place = nil
        }
        self.init(clientTime: time, keepSortedOrder: order, place: place)
    }

    var json: ContractJSON {
        var object: ContractObject = ["client_time": .integer(clientTime), "keep_sorted": .bool(keepSortedOrder != nil)]
        if let keepSortedOrder { object["sort_order"] = .string(keepSortedOrder.rawValue) }
        switch place {
        case .start?: object["place"] = ["kind": "start"]
        case .end?: object["place"] = ["kind": "end"]
        case .after(let ids)?: object["place"] = ["kind": "after", "local": .array(ids.map(ContractJSON.integer))]
        case nil: break
        }
        return .object(object)
    }
}
