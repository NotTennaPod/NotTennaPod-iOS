import Foundation

/// A fact target (PROTOCOL §6.1): `{entity, id, generation?}`.
struct ServerFactTarget: Hashable, Sendable {
    var entity: String
    var id: String
    var generation: String?

    var json: ContractJSON {
        var object: ContractObject = ["entity": .string(entity), "id": .string(id)]
        if let generation { object["generation"] = .string(generation) }
        return .object(object)
    }

    /// Sorted by `(entity, id, generation-or-empty)`, bytewise on UTF-8, without duplicates.
    static func sorted(_ targets: [ServerFactTarget]) -> [ServerFactTarget] {
        var seen = Set<ServerFactTarget>()
        return targets.filter { seen.insert($0).inserted }.sorted {
            let a = [$0.entity, $0.id, $0.generation ?? ""], b = [$1.entity, $1.id, $1.generation ?? ""]
            for (x, y) in zip(a, b) where !x.utf8.elementsEqual(y.utf8) {
                return x.utf8.lexicographicallyPrecedes(y.utf8)
            }
            return false
        }
    }
}

/// What one unretired local fact shows over the base (PROTOCOL §6.8), keyed by its op ID.
struct ServerOverlay: Sendable {
    enum Kind: String, Sendable {
        case register, dismiss, activity, historyMark = "history_mark", historyCut = "history_cut"
        case statCut = "stat_cut", contribution, completion, historyRestore = "history_restore"
        /// A session start or claiming checkpoint (PROTOCOL §8): the position under its own claim. A session export's position
        /// shows only while the claim it stands under is the displayed one.
        case claim, sessionPosition = "session_position"
    }
    var entity: String
    var id: String
    var property: String
    var kind: Kind
    var value: ContractJSON?
}

/// The recorder's writes (PROTOCOL §15.2). Every write the recorder makes inside its savepoint goes through `execute`,
/// which counts it, so tests can inject a failure after each one.
final class ServerOutboxWriter {
    let database: LibrarySQLite
    let context: ServerLibraryContext
    private let failAfter: Int?
    private(set) var writes = 0
#if DEBUG
    /// The outbox entries this writer added, for the hub bridge once their transaction commits.
    private(set) var exported: [ServerDebugHooks.Export] = []
#endif

    init(database: LibrarySQLite, context: ServerLibraryContext, failAfter: Int?) {
        self.database = database; self.context = context; self.failAfter = failAfter
    }

    func execute(_ sql: String, _ values: [LibrarySQLValue] = []) throws {
        try database.execute(sql, values)
        writes += 1
        if let failAfter, writes >= failAfter { throw ServerRecordingError.injectedFailure }
    }

    /// The next knowledge-clock value, written with the counters (PROTOCOL §6.8 coverage).
    private func nextClock() throws -> Int64 {
        try database.scalar("SELECT knowledge_clock FROM ntp_library WHERE id = 1") + 1
    }

    private struct AuthorPosition { let seq: Int64; let previous: String? }

    private func authorPosition(_ authorID: String) throws -> AuthorPosition {
        guard let row = try database.rows("SELECT next_seq, last_op_id FROM ntp_authors WHERE author_id = ?", [.text(authorID)]).first,
              let seq = row[0].integer else { throw ServerRecordingError.corruptState("no author \(authorID)") }
        if case .text(let previous) = row[1] { return .init(seq: seq, previous: previous) }
        return .init(seq: seq, previous: nil)
    }

    static func sortedUnique(_ ids: some Sequence<String>) -> [String] {
        var seen = Set<[UInt8]>()
        return ids.filter { seen.insert(Array($0.utf8)).inserted }.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// Builds a contract-v1 fact (PROTOCOL §15.2).
    static func fact(opID: String, authorID: String, authorSeq: Int64, previousOpID: String?, dependencies: [String],
                     type: String, clientTime: Int64, targets: [ServerFactTarget], payload: ContractObject) -> ContractJSON {
        var fact: ContractObject = [
            "op_id": .string(opID), "author_id": .string(authorID), "author_seq": .integer(authorSeq),
            "dependencies": .array(sortedUnique(dependencies + (previousOpID.map { [$0] } ?? [])).map(ContractJSON.string)),
            "type": .string(type), "type_version": 1, "client_time": .integer(clientTime),
            "targets": .array(ServerFactTarget.sorted(targets).map(\.json)), "payload": .object(Self.sanitized(payload)),
        ]
        if let previousOpID { fact["previous_op_id"] = .string(previousOpID) }
        return .object(fact)
    }

    /// No credentials in strings (PROTOCOL §15.2, §7.2): URL userinfo is removed from every string before hashing.
    static func sanitized(_ object: ContractObject) -> ContractObject {
        var copy = object
        for member in object.members { copy[member.name] = sanitized(member.value) }
        return copy
    }

    static func sanitized(_ value: ContractJSON) -> ContractJSON {
        switch value {
        case .string(let text): .string(ContractURL.stripUserinfo(text))
        case .array(let items): .array(items.map(sanitized))
        case .object(let object): .object(sanitized(object))
        default: value
        }
    }

    /// Appends a fact of the main author to the outbox: op ID, author position and transport slot in this
    /// transaction (PROTOCOL §15.2), its node in the frontier, and its overlays. A playback session keeps its author for life
    /// (PROTOCOL §15.2), so its facts may name a registration author (`authorID`); a fact whose identity was fixed when it was
    /// decided (an owed playback fact, PROTOCOL §8.2) passes its `opID`.
    @discardableResult
    func appendFact(type: String, targets: [ServerFactTarget], payload: ContractObject, dependencies: [String] = [],
                    overlays: [ServerOverlay] = [], clientTime: Int64, secretIDs: [String] = [], now: Int64,
                    authorID: String? = nil, opID fixedOpID: String? = nil) throws -> String {
        let opID = fixedOpID ?? ContractIdentity.randomUUID()
        let authorID = authorID ?? context.mainAuthor
        let author = try authorPosition(authorID)
        let fact = Self.fact(opID: opID, authorID: authorID, authorSeq: author.seq, previousOpID: author.previous,
                             dependencies: dependencies, type: type, clientTime: clientTime, targets: targets, payload: payload)
        try insertOutboxEntry(opID: opID, authorID: authorID, authorSeq: author.seq, type: type, fact: fact,
                              secretIDs: secretIDs, now: now)
        try execute("UPDATE ntp_authors SET next_seq = next_seq + 1, last_op_id = ? WHERE author_id = ?",
                    [.text(opID), .text(authorID)])
        let clock = try nextClock()
        try execute("UPDATE ntp_library SET knowledge_clock = ? WHERE id = 1", [.integer(clock)])
        try addNode(opID, clock: clock, dependencies: fact["dependencies"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        try writeOverlays(overlays, opID: opID, clock: clock)
        return opID
    }

    /// The outbox entry for a fact, with the next transport slot (contiguous, PROTOCOL §15.2).
    func insertOutboxEntry(opID: String, authorID: String, authorSeq: Int64, type: String, fact: ContractJSON,
                           secretIDs: [String], now: Int64) throws {
        let bytes = try fact.canonicalBytes()
        let slot = try database.scalar("SELECT next_install_seq FROM ntp_library WHERE id = 1")
        try execute("UPDATE ntp_library SET next_install_seq = next_install_seq + 1 WHERE id = 1")
        try execute("INSERT INTO ntp_outbox(install_seq, op_id, author_id, author_seq, type, fact, content_hash, secret_ids, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    [.integer(slot), .text(opID), .text(authorID), .integer(authorSeq), .text(type), .blob(Data(bytes)),
                     .text(ContractIdentity.sha256Hex(bytes)),
                     secretIDs.isEmpty ? .null : .text(String(decoding: try JSONEncoder().encode(secretIDs), as: UTF8.self)),
                     .integer(now)])
#if DEBUG
        exported.append(.init(opID: opID, type: type, installSeq: slot, authorID: authorID))
#endif
    }

    /// A known local node: its dependencies leave the frontier, it joins it.
    func addNode(_ nodeID: String, clock: Int64, dependencies: [String]) throws {
        if !dependencies.isEmpty {
            let marks = Array(repeating: "?", count: dependencies.count).joined(separator: ", ")
            try execute("UPDATE ntp_nodes SET frontier = 0 WHERE frontier != 0 AND node_id IN (\(marks))", dependencies.map(LibrarySQLValue.text))
        }
        try execute("INSERT INTO ntp_nodes(node_id, knowledge_clock, frontier, kind) VALUES (?, ?, 1, 'local') ON CONFLICT(node_id) DO UPDATE SET knowledge_clock = excluded.knowledge_clock, frontier = 1, kind = 'local'",
                    [.text(nodeID), .integer(clock)])
    }

    func writeOverlays(_ overlays: [ServerOverlay], opID: String, clock: Int64) throws {
        for overlay in overlays {
            try execute("INSERT OR REPLACE INTO ntp_overlays(op_id, entity, id, property, kind, value, clock) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        [.text(opID), .text(overlay.entity), .text(overlay.id), .text(overlay.property), .text(overlay.kind.rawValue),
                         try overlay.value.map { .blob(Data(try $0.canonicalBytes())) } ?? .null, .integer(clock)])
        }
    }

    /// A draft on a registration chain (PROTOCOL §15.2): its op ID, author position and client time are fixed now; its
    /// template names local IDs until the registration resolves.
    @discardableResult
    func appendDraft(registrationOp: String, authorID: String, type: String, template: ContractJSON,
                     dependencies: [String] = [], overlays: [ServerOverlay] = [], clientTime: Int64, now: Int64,
                     opID fixedOpID: String? = nil) throws -> String {
        let opID = fixedOpID ?? ContractIdentity.randomUUID()
        let author = try authorPosition(authorID)
        try execute("INSERT INTO ntp_drafts(op_id, author_id, author_seq, previous_op_id, client_time, registration_op, kind, template, dependencies, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    [.text(opID), .text(authorID), .integer(author.seq), author.previous.map(LibrarySQLValue.text) ?? .null,
                     .integer(clientTime), .text(registrationOp), .text(type), .blob(Data(try template.canonicalBytes())),
                     .text(String(decoding: try JSONEncoder().encode(Self.sortedUnique(dependencies)), as: UTF8.self)), .integer(now)])
        try execute("UPDATE ntp_authors SET next_seq = next_seq + 1, last_op_id = ? WHERE author_id = ?", [.text(opID), .text(authorID)])
        let clock = try nextClock()
        try execute("UPDATE ntp_library SET knowledge_clock = ? WHERE id = 1", [.integer(clock)])
        // Drafts are known nodes, never in the main author's frontier (a main-author fact never depends on one).
        try execute("INSERT INTO ntp_nodes(node_id, knowledge_clock, frontier, kind) VALUES (?, ?, 0, 'draft')", [.text(opID), .integer(clock)])
        try writeOverlays(overlays, opID: opID, clock: clock)
        return opID
    }

    /// The registration's own author, created with it (PROTOCOL §15.4).
    func createRegistration(opID: String, kind: String, feedID: Int64, feedURL: String, now: Int64) throws -> String {
        let author = ContractIdentity.randomUUID()
        try execute("INSERT INTO ntp_authors(author_id, role, next_seq, registration_op, created_at) VALUES (?, 'registration', 1, ?, ?)",
                    [.text(author), .text(opID), .integer(now)])
        try execute("INSERT INTO ntp_registrations(op_id, feed_id, kind, author_id, feed_url, state, created_at) VALUES (?, ?, ?, ?, ?, 'pending', ?)",
                    [.text(opID), .integer(feedID), .text(kind), .text(author), .text(feedURL), .integer(now)])
        return author
    }

    /// The known frontier (non-draft nodes nothing known depends on), for cuts (PROTOCOL §15.2).
    func frontier() throws -> [String] {
        try database.rows("SELECT node_id FROM ntp_nodes WHERE frontier = 1 AND kind != 'draft' ORDER BY node_id").compactMap {
            if case .text(let id) = $0[0] { id } else { nil }
        }
    }
}
