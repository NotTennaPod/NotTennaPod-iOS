import Foundation

/// What the archive gives a recovery after a server restore (PROTOCOL §6.11–6, PROTOCOL §6.11): every
/// archived fact and decision with its receipt position, in receipt order, for the inventory; the entries themselves
/// for the upload; and each entry's progress, kept in `recovery_progress` under the recovery and the server epoch it
/// was answered in, so a crash resumes where it stopped and a second restore starts the inventory again.
extension ServerArchive {
    /// One inventory entry: a fact `{kind: fact, op_id, content_hash, position}` or a decision `{kind: decision,
    /// decision_id, rank}`.
    struct RecoveryItem: Sendable, Equatable {
        enum Kind: String, Sendable { case fact, decision }
        var kind: Kind
        var id: String
        var contentHash: String?
        var epoch: Int64
        var seq: Int64
        var index: Int64

        /// Receipt order `(epoch, seq, index, id)`, which is causal order for accepted facts (PROTOCOL §6.11); a decision's
        /// index follows the fact whose acceptance made it (PROTOCOL §6.10.8).
        static func receiptOrder(_ a: RecoveryItem, _ b: RecoveryItem) -> Bool {
            if a.epoch != b.epoch { return a.epoch < b.epoch }
            if a.seq != b.seq { return a.seq < b.seq }
            if a.index != b.index { return a.index < b.index }
            return a.id.utf8.lexicographicallyPrecedes(b.id.utf8)
        }

        var inventory: ContractJSON {
            switch kind {
            case .fact:
                ["kind": "fact", "op_id": .string(id), "content_hash": .string(contentHash ?? ""),
                 "position": [.integer(epoch), .integer(seq), .integer(index)]]
            case .decision:
                ["kind": "decision", "decision_id": .string(id), "rank": [.integer(epoch), .integer(seq)]]
            }
        }
    }

    /// The archived facts and decisions, received after `after` (`(epoch, seq)`, exclusive) when given.
    func recoveryItems(after: (epoch: Int64, seq: Int64)?) throws -> [RecoveryItem] {
        let bound = after.map { [LibrarySQLValue.integer($0.epoch), .integer($0.epoch), .integer($0.seq)] } ?? []
        let condition = after == nil ? "" : " WHERE epoch > ? OR (epoch = ? AND seq > ?)"
        var items = try database.rows("SELECT op_id, content_hash, epoch, seq, idx FROM archive_entries" + condition, bound).compactMap { row -> RecoveryItem? in
            guard let id = row[0].text, let hash = row[1].text, let epoch = row[2].integer, let seq = row[3].integer else { return nil }
            return RecoveryItem(kind: .fact, id: id, contentHash: hash, epoch: epoch, seq: seq, index: row[4].integer ?? 0)
        }
        items += try database.rows("SELECT decision_id, epoch, seq, idx FROM archive_decisions" + condition, bound).compactMap { row -> RecoveryItem? in
            guard let id = row[0].text, let epoch = row[1].integer, let seq = row[2].integer else { return nil }
            return RecoveryItem(kind: .decision, id: id, epoch: epoch, seq: seq, index: row[3].integer ?? 0)
        }
        return items
    }

    /// An archived fact and its receipt, the content hash checked (PROTOCOL §15.2).
    func factEntry(_ opID: String) throws -> (fact: ContractJSON, receipt: ContractJSON)? {
        guard let fact = try fact(opID: opID), let receipt = try receipt(opID: opID) else { return nil }
        return (fact, receipt)
    }

    /// What an archived fact or decision names: its dependency edges, and a fact's `previous_op_id` and dependencies
    /// (a rejected fact has no edges).
    func dependencies(of id: String) throws -> Set<String> {
        var names = Set(try database.rows("SELECT dependency_id FROM archive_edges WHERE node_id = ?", [.text(id)]).compactMap { $0[0].text })
        if let fact = try fact(opID: id) { names.formUnion(FeedLibraryStore.named(fact)) }
        return names
    }

    /// An archived decision as recorded, with its `key_id` and `mac`.
    func decision(_ id: String) throws -> ContractJSON? {
        guard let data = try database.rows("SELECT decision FROM archive_decisions WHERE decision_id = ?", [.text(id)]).first?.first?.data else { return nil }
        return try ContractJSON.decode(try Self.decompress(data))
    }

    // MARK: - Progress (`recovery_progress`)

    /// What a recovery knows of one entry: its inventory answer or upload result (`have`, `need`, `conflict`,
    /// `joined`, `known`, `replaced`, `part_stored`, `dependency_missing`, `invalid_receipt`, `invalid`), what it was
    /// missing, and a framed fact's upload framing.
    struct RecoveryProgress: Codable, Equatable, Sendable {
        var status: String
        var missing: [String]?
        var framing: ServerFraming?

        static let recovered: Set<String> = ["have", "joined", "known", "replaced"]
        /// Quarantined because it depends on an entry that can never be restored.
        static let blocked = "blocked"
        static let problems: Set<String> = ["conflict", "invalid_receipt", "invalid", "too_large", blocked]
        var isRecovered: Bool { Self.recovered.contains(status) }
        var isProblem: Bool { Self.problems.contains(status) }
    }

    static func progressKey(recovery: String, epoch: Int64, _ kind: RecoveryItem.Kind, _ id: String) -> String {
        "\(recovery)/\(epoch)/\(kind.rawValue)/\(id)"
    }

    /// Every entry's progress in one recovery and epoch, by `kind/id`.
    func recoveryProgress(recovery: String, epoch: Int64) throws -> [String: RecoveryProgress] {
        let prefix = "\(recovery)/\(epoch)/"
        var result: [String: RecoveryProgress] = [:]
        for row in try database.rows("SELECT key, value FROM recovery_progress WHERE key >= ? AND key < ?", [.text(prefix), .text(prefix + "\u{FFFF}")]) {
            guard let key = row[0].text, let data = row[1].data,
                  let value = try? JSONDecoder().decode(RecoveryProgress.self, from: data) else { continue }
            result[String(key.dropFirst(prefix.count))] = value
        }
        return result
    }

    /// Records progress durably, in one transaction.
    func setRecoveryProgress(recovery: String, epoch: Int64, _ values: [(kind: RecoveryItem.Kind, id: String, progress: RecoveryProgress)]) throws {
        guard !values.isEmpty else { return }
        try database.transaction {
            for value in values {
                try database.execute("INSERT OR REPLACE INTO recovery_progress(key, value) VALUES (?, ?)",
                                     [.text(Self.progressKey(recovery: recovery, epoch: epoch, value.kind, value.id)),
                                      .blob(try JSONEncoder().encode(value.progress))])
            }
        }
    }

    /// Forgets a finished recovery's progress (its entries' outcomes stay with the retained entries they concern).
    func clearRecoveryProgress(except recovery: String?) throws {
        try database.transaction {
            if let recovery {
                try database.execute("DELETE FROM recovery_progress WHERE key NOT LIKE ?", [.text(recovery + "/%")])
            } else {
                try database.execute("DELETE FROM recovery_progress")
            }
        }
    }
}
