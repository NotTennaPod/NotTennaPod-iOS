import Foundation

/// A server library's `sync.sqlite` (PROTOCOL §15.2): the fact archive (every accepted entry and
/// decision, deflate-compressed, with its dependency edges), the history entries the overlays need (PROTOCOL §6.8), the
/// verified commits not yet applied to the live library, the sync log, the queue safeguards and the recovery seam.
/// It has its own connection, outside the live library's write lock, and may run ahead of the live library: the
/// live cursor is authoritative for what has been applied.
final class ServerArchive {
    let database: SyncSQLite
    let url: URL

    static let schema: [String] = [
        """
        CREATE TABLE IF NOT EXISTS archive_entries (
            op_id TEXT PRIMARY KEY, content_hash TEXT NOT NULL, epoch INTEGER NOT NULL, seq INTEGER NOT NULL,
            idx INTEGER NOT NULL, outcome TEXT NOT NULL, reason TEXT, type TEXT NOT NULL, author_id TEXT,
            normalized_time INTEGER NOT NULL, fact BLOB NOT NULL, receipt BLOB NOT NULL)
        """,
        "CREATE INDEX IF NOT EXISTS archive_entries_by_position ON archive_entries(epoch, seq, idx, op_id)",
        """
        CREATE TABLE IF NOT EXISTS archive_decisions (
            decision_id TEXT PRIMARY KEY, decision_type TEXT NOT NULL, subject TEXT NOT NULL, epoch INTEGER NOT NULL,
            seq INTEGER NOT NULL, idx INTEGER NOT NULL, normalized_time INTEGER NOT NULL, decision BLOB NOT NULL)
        """,
        "CREATE INDEX IF NOT EXISTS archive_decisions_by_subject ON archive_decisions(decision_type, subject)",
        "CREATE TABLE IF NOT EXISTS archive_edges (node_id TEXT NOT NULL, dependency_id TEXT NOT NULL, PRIMARY KEY(node_id, dependency_id)) WITHOUT ROWID",
        "CREATE INDEX IF NOT EXISTS archive_edges_by_dependency ON archive_edges(dependency_id)",
        // History entries and cuts per episode (PROTOCOL §6.8 per-entry history): `kind` is `activity`, `mark`, `remove`,
        // `restore` (with the removal it cancels) or `clear` (episode `*`).
        """
        CREATE TABLE IF NOT EXISTS archive_history (
            episode_id TEXT NOT NULL, node_id TEXT NOT NULL, kind TEXT NOT NULL, time INTEGER, removal TEXT,
            PRIMARY KEY(episode_id, node_id, kind)) WITHOUT ROWID
        """,
        "CREATE TABLE IF NOT EXISTS superseded_receipts (op_id TEXT NOT NULL, receipt BLOB NOT NULL, replaced_at INTEGER NOT NULL)",
        // Verified commits, kept until the live cursor has passed them (PROTOCOL §6.6: applied from the archive after a crash).
        """
        CREATE TABLE IF NOT EXISTS pending_commits (
            seq INTEGER PRIMARY KEY, epoch INTEGER NOT NULL, log_id TEXT NOT NULL, digest TEXT NOT NULL, body BLOB NOT NULL,
            parts INTEGER NOT NULL DEFAULT 0)
        """,
        // A large commit's compressed body in parts, each written in its own transaction (`parts` above counts them).
        "CREATE TABLE IF NOT EXISTS pending_commit_parts (seq INTEGER NOT NULL, idx INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY(seq, idx)) WITHOUT ROWID",
        "CREATE TABLE IF NOT EXISTS sync_log (id INTEGER PRIMARY KEY AUTOINCREMENT, time INTEGER NOT NULL, kind TEXT NOT NULL, detail TEXT)",
        "CREATE TABLE IF NOT EXISTS queue_safeguards (id INTEGER PRIMARY KEY AUTOINCREMENT, time INTEGER NOT NULL, record BLOB NOT NULL)",
        "CREATE TABLE IF NOT EXISTS recovery_progress (key TEXT PRIMARY KEY, value BLOB)",
    ]

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        database = try SyncSQLite(url: url)
        try database.transaction {
            for statement in Self.schema { try database.execute(statement) }
            // An archive made before commit bodies came in parts.
            if try !database.rows("PRAGMA table_info(pending_commits)").contains(where: { $0[1].text == "parts" }) {
                try database.execute("ALTER TABLE pending_commits ADD COLUMN parts INTEGER NOT NULL DEFAULT 0")
            }
        }
    }

    func close() throws { try database.close() }

    // MARK: - Compression (PROTOCOL §15.2: deflate, the content hash checked on read)

    static func compress(_ bytes: [UInt8]) throws -> Data {
        try (Data(bytes) as NSData).compressed(using: .zlib) as Data
    }

    static func decompress(_ data: Data) throws -> [UInt8] {
        [UInt8](try (data as NSData).decompressed(using: .zlib) as Data)
    }

    // MARK: - Archiving

    /// Archives verified commits in one transaction (PROTOCOL §6.6): their accepted entries and decisions (idempotent by
    /// ID; a different receipt for a known op ID replaces it and the old one is kept, PROTOCOL §6.11), the edges, the
    /// history index, and the commits themselves until they are applied.
    func archive(commits: [(commit: ServerCommit, body: ContractJSON, cursor: SyncCursor)], now: Int64) throws {
        try database.transaction {
            for item in commits { try insertCommit(item.commit, body: item.body, cursor: item.cursor, now: now) }
        }
    }

    /// One verified commit, inside the caller's archive transaction.
    func insertCommit(_ commit: ServerCommit, body: ContractJSON, cursor: SyncCursor, now: Int64) throws {
        try insert(entries: commit.accepted, now: now)
        try insert(decisions: commit.decisions)
        try database.execute("DELETE FROM pending_commit_parts WHERE seq = ?", [.integer(commit.seq)])
        try database.execute("INSERT OR REPLACE INTO pending_commits(seq, epoch, log_id, digest, body, parts) VALUES (?, ?, ?, ?, ?, 0)",
                             [.integer(commit.seq), .integer(commit.epoch), .text(cursor.logID),
                              .text(cursor.digest), .blob(try Self.compress(try body.canonicalBytes()))])
    }

    /// What one archive transaction of a pull writes at most: a playback save, and a tap queued behind it, never
    /// waits behind a long archive write. Compressed bytes of a commit body, and accepted entries or decisions.
    static let transactionBytes = 256 * 1024
    static let transactionEntries = 250

    /// Archives verified commits in bounded transactions (a pull, PROTOCOL §6.6): each commit's entries and decisions in
    /// batches, a large body in parts, and last the small transaction that makes the commit pending. Every step is
    /// idempotent, so a pull stopped in between archives again what it had not finished; commits are made pending in
    /// order, so the pending ones are always a run from the live cursor.
    func archiveBounded(_ commit: ServerCommit, body: ContractJSON, cursor: SyncCursor, now: Int64) throws {
        for start in stride(from: 0, to: commit.accepted.count, by: Self.transactionEntries) {
            let batch = Array(commit.accepted[start..<min(commit.accepted.count, start + Self.transactionEntries)])
            try database.transaction { try insert(entries: batch, now: now) }
        }
        for start in stride(from: 0, to: commit.decisions.count, by: Self.transactionEntries) {
            let batch = Array(commit.decisions[start..<min(commit.decisions.count, start + Self.transactionEntries)])
            try database.transaction { try insert(decisions: batch) }
        }
        let compressed = try Self.compress(try body.canonicalBytes())
        var parts = 0
        if compressed.count > Self.transactionBytes {
            try database.transaction { try database.execute("DELETE FROM pending_commit_parts WHERE seq = ?", [.integer(commit.seq)]) }
            for start in stride(from: 0, to: compressed.count, by: Self.transactionBytes) {
                let part = compressed.subdata(in: start..<min(compressed.count, start + Self.transactionBytes))
                try database.transaction {
                    try database.execute("INSERT OR REPLACE INTO pending_commit_parts(seq, idx, data) VALUES (?, ?, ?)",
                                         [.integer(commit.seq), .integer(Int64(parts)), .blob(part)])
                }
                parts += 1
            }
        }
        try database.transaction {
            if parts == 0 { try database.execute("DELETE FROM pending_commit_parts WHERE seq = ?", [.integer(commit.seq)]) }
            try database.execute("INSERT OR REPLACE INTO pending_commits(seq, epoch, log_id, digest, body, parts) VALUES (?, ?, ?, ?, ?, ?)",
                                 [.integer(commit.seq), .integer(commit.epoch), .text(cursor.logID), .text(cursor.digest),
                                  .blob(parts == 0 ? compressed : Data()), .integer(Int64(parts))])
        }
    }

    /// A pending commit's compressed body: in the row, or its parts in order (all of them, or the archive is damaged).
    private func pendingBody(seq: Int64, row: Data?, parts: Int64) throws -> Data {
        guard parts > 0 else {
            guard let row else { throw FeedLibraryError.corruptRecord }
            return row
        }
        var body = Data()
        let stored = try database.rows("SELECT idx, data FROM pending_commit_parts WHERE seq = ? ORDER BY idx", [.integer(seq)])
        guard stored.count == Int(parts) else { throw FeedLibraryError.corruptRecord }
        for (index, part) in stored.enumerated() {
            guard part[0].integer == Int64(index), let data = part[1].data else { throw FeedLibraryError.corruptRecord }
            body.append(data)
        }
        return body
    }

    /// The first verified commit after `seq`, if the archive holds it.
    func nextPendingCommit(after seq: Int64) throws -> (commit: ServerCommit, cursor: SyncCursor)? {
        guard let row = try database.rows("SELECT seq, epoch, log_id, digest, body, parts FROM pending_commits WHERE seq > ? ORDER BY seq LIMIT 1", [.integer(seq)]).first,
              let seq = row[0].integer, let epoch = row[1].integer, let log = row[2].text, let digest = row[3].text else { return nil }
        let body = try pendingBody(seq: seq, row: row[4].data, parts: row[5].integer ?? 0)
        let json = try ContractJSON.decode(try Self.decompress(body))
        return (try ServerCommit(json), try SyncCursor(logID: log, epoch: epoch, seq: seq, digest: digest))
    }

    /// The archived entries and decisions (a snapshot's items besides its records, for a download's estimate).
    func entryAndDecisionCount() throws -> Int {
        Int(try database.scalar("SELECT (SELECT count(*) FROM archive_entries) + (SELECT count(*) FROM archive_decisions)"))
    }

    /// Archives a snapshot's entries and decisions (first attachment, PROTOCOL §15.4), in batches of one transaction.
    /// `budget`: the bytes the batch may add (`SQLiteWriteBudget`; nil: no limit).
    func archive(entries: [ServerAcceptedEntry], decisions: [ServerDecision], now: Int64, budget: Int64? = nil) throws {
        try database.withWriteBudget(budget) {
            try database.transaction {
                try insert(entries: entries, now: now)
                try insert(decisions: decisions)
            }
        }
    }

    private func insert(entries: [ServerAcceptedEntry], now: Int64) throws {
        for entry in entries {
            let receipt = try entry.receipt.canonicalBytes()
            if let existing = try database.rows("SELECT receipt, content_hash FROM archive_entries WHERE op_id = ?", [.text(entry.opID)]).first {
                guard let stored = existing[0].data, try Self.decompress(stored) != receipt else { continue }
                // A recovered original replaces a provisional receipt (PROTOCOL §6.11); the replaced one is kept.
                try database.execute("INSERT INTO superseded_receipts(op_id, receipt, replaced_at) VALUES (?, ?, ?)",
                                     [.text(entry.opID), .blob(stored), .integer(now)])
                try database.execute("UPDATE archive_entries SET epoch = ?, seq = ?, idx = ?, outcome = ?, reason = ?, normalized_time = ?, receipt = ? WHERE op_id = ?",
                                     [.integer(entry.epoch), .integer(entry.seq), .integer(entry.index), .text(entry.outcome),
                                      entry.reason.map(LibrarySQLValue.text) ?? .null, .integer(entry.normalizedTime),
                                      .blob(try Self.compress(receipt)), .text(entry.opID)])
                continue
            }
            let fact = try entry.fact.canonicalBytes()
            guard ContractIdentity.sha256Hex(fact) == entry.contentHash else {
                throw ServerWireError.invalid("an accepted fact whose content hash does not match its receipt")
            }
            try database.execute("INSERT INTO archive_entries(op_id, content_hash, epoch, seq, idx, outcome, reason, type, author_id, normalized_time, fact, receipt) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                                 [.text(entry.opID), .text(entry.contentHash), .integer(entry.epoch), .integer(entry.seq),
                                  .integer(entry.index), .text(entry.outcome), entry.reason.map(LibrarySQLValue.text) ?? .null,
                                  .text(entry.type), entry.authorID.map(LibrarySQLValue.text) ?? .null, .integer(entry.normalizedTime),
                                  .blob(try Self.compress(fact)), .blob(try Self.compress(receipt))])
            if entry.isCausalNode {
                for dependency in entry.dependencies {
                    try database.execute("INSERT OR IGNORE INTO archive_edges(node_id, dependency_id) VALUES (?, ?)",
                                         [.text(entry.opID), .text(dependency)])
                }
            }
            try indexHistory(entry)
        }
    }

    private func insert(decisions: [ServerDecision]) throws {
        for decision in decisions {
            guard try database.scalar("SELECT count(*) FROM archive_decisions WHERE decision_id = ?", [.text(decision.decisionID)]) == 0 else { continue }
            try database.execute("INSERT INTO archive_decisions(decision_id, decision_type, subject, epoch, seq, idx, normalized_time, decision) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                                 [.text(decision.decisionID), .text(decision.type), .text(decision.subject), .integer(decision.epoch),
                                  .integer(decision.seq), .integer(decision.index), .integer(decision.normalizedTime),
                                  .blob(try Self.compress(try decision.json.canonicalBytes()))])
            for dependency in decision.dependencies {
                try database.execute("INSERT OR IGNORE INTO archive_edges(node_id, dependency_id) VALUES (?, ?)",
                                     [.text(decision.decisionID), .text(dependency)])
            }
            // An imported episode's history time is a history entry of its import decision (PROTOCOL §11.5).
            if decision.type == "import.episode", let episode = decision.result["episode_id"]?.stringValue,
               let time = decision.result["imported"]?["history"]?.integerValue {
                try addHistory(episode, decision.decisionID, "mark", time: time)
            }
        }
    }

    /// The history entries and cuts an accepted fact makes (PROTOCOL §8): activity of starts,
    /// checkpoints and ends; history marks of ends, finalizations and leaves; removals, restores and clears.
    private func indexHistory(_ entry: ServerAcceptedEntry) throws {
        guard entry.outcome == "applied" || entry.outcome == "superseded" else { return }
        let payload = entry.payload
        let episode = payload["episode"]?["episode_id"]?.stringValue
        let time = entry.normalizedTime
        switch entry.type {
        case "session.start", "session.checkpoint":
            if let episode, payload["activity"]?.boolValue == true { try addHistory(episode, entry.opID, "activity", time: time) }
        case "session.end":
            guard let episode else { return }
            if payload["activity"]?.boolValue == true { try addHistory(episode, entry.opID, "activity", time: time) }
            if payload["history"]?.boolValue == true { try addHistory(episode, entry.opID, "mark", time: time) }
        case "session.finalize", "episode.leave":
            if let episode, payload["history"]?.boolValue == true { try addHistory(episode, entry.opID, "mark", time: time) }
        case "history.remove":
            if let episode { try addHistory(episode, entry.opID, "remove", time: time) }
        case "history.restore":
            if let episode { try addHistory(episode, entry.opID, "restore", time: time, removal: payload["removal"]?.stringValue) }
        case "history.clear":
            try addHistory("*", entry.opID, "clear", time: time)
        default:
            break
        }
    }

    private func addHistory(_ episode: String, _ node: String, _ kind: String, time: Int64, removal: String? = nil) throws {
        try database.execute("INSERT OR IGNORE INTO archive_history(episode_id, node_id, kind, time, removal) VALUES (?, ?, ?, ?, ?)",
                             [.text(episode), .text(node), .text(kind), .integer(time), removal.map(LibrarySQLValue.text) ?? .null])
    }

    // MARK: - Pending commits

    /// Verified commits after `seq`, in order: archived but not yet applied (PROTOCOL §6.6, after a crash).
    func pendingCommits(after seq: Int64) throws -> [(commit: ServerCommit, cursor: SyncCursor)] {
        try database.rows("SELECT seq, epoch, log_id, digest, body, parts FROM pending_commits WHERE seq > ? ORDER BY seq", [.integer(seq)]).map { row in
            guard let seq = row[0].integer, let epoch = row[1].integer, let log = row[2].text, let digest = row[3].text else { throw FeedLibraryError.corruptRecord }
            let body = try pendingBody(seq: seq, row: row[4].data, parts: row[5].integer ?? 0)
            let json = try ContractJSON.decode(try Self.decompress(body))
            return (try ServerCommit(json), try SyncCursor(logID: log, epoch: epoch, seq: seq, digest: digest))
        }
    }

    func pendingCommitCount(after seq: Int64) throws -> Int {
        Int(try database.scalar("SELECT count(*) FROM pending_commits WHERE seq > ?", [.integer(seq)]))
    }

    /// Forgets applied commits (the live cursor names `seq`), and any commit of another lineage.
    func dropPendingCommits(through seq: Int64, logID: String) throws {
        try database.transaction {
            try database.execute("DELETE FROM pending_commit_parts WHERE seq <= ? OR seq IN (SELECT seq FROM pending_commits WHERE log_id != ?)",
                                 [.integer(seq), .text(logID)])
            try database.execute("DELETE FROM pending_commits WHERE seq <= ? OR log_id != ?", [.integer(seq), .text(logID)])
        }
    }

    // MARK: - Reading the archive

    func contains(node: String) throws -> Bool {
        try database.scalar("SELECT (SELECT count(*) FROM archive_entries WHERE op_id = ?) + (SELECT count(*) FROM archive_decisions WHERE decision_id = ?)",
                            [.text(node), .text(node)]) > 0
    }

    /// The archived receipt of a fact.
    func receipt(opID: String) throws -> ContractJSON? {
        guard let row = try database.rows("SELECT receipt FROM archive_entries WHERE op_id = ?", [.text(opID)]).first,
              let data = row[0].data else { return nil }
        return try ContractJSON.decode(try Self.decompress(data))
    }

    /// The archived fact, its content hash checked (PROTOCOL §15.2).
    func fact(opID: String) throws -> ContractJSON? {
        guard let row = try database.rows("SELECT fact, content_hash FROM archive_entries WHERE op_id = ?", [.text(opID)]).first,
              let data = row[0].data, let hash = row[1].text else { return nil }
        let bytes = try Self.decompress(data)
        guard ContractIdentity.sha256Hex(bytes) == hash else { throw ServerWireError.invalid("an archived fact whose content hash does not match") }
        return try ContractJSON.decode(bytes)
    }

    func entryCount() throws -> Int { Int(try database.scalar("SELECT count(*) FROM archive_entries")) }
    func decisionCount() throws -> Int { Int(try database.scalar("SELECT count(*) FROM archive_decisions")) }

    /// An archived history entry or cut of one episode.
    struct HistoryItem: Equatable, Sendable {
        var node: String
        var kind: String
        var time: Int64
        var removal: String?
    }

    /// The history entries and cuts of the episodes, with the account's clears and the restores of them.
    func historyItems(episodes: [String]) throws -> [String: [HistoryItem]] {
        var result: [String: [HistoryItem]] = [:]
        for episode in Set(episodes + ["*"]) {
            result[episode] = try database.rows("SELECT node_id, kind, time, removal FROM archive_history WHERE episode_id = ?", [.text(episode)]).map {
                HistoryItem(node: $0[0].text ?? "", kind: $0[1].text ?? "", time: $0[2].integer ?? 0, removal: $0[3].text)
            }
        }
        return result
    }

    /// Whether `node` is in the causal past of `cut` (the coverage walk, PROTOCOL §8): a walk from `cut` along its
    /// dependencies, through nodes not older than `node` (an older node can have no later node in its past).
    func isInPast(_ node: String, of cut: String, notBefore bound: (Int64, Int64)) throws -> Bool {
        var frontier = [cut], seen: Set<String> = [cut]
        while let current = frontier.popLast() {
            for row in try database.rows("SELECT dependency_id FROM archive_edges WHERE node_id = ?", [.text(current)]) {
                guard let dependency = row[0].text, seen.insert(dependency).inserted else { continue }
                if dependency == node { return true }
                if let at = try position(of: dependency), at < bound { continue }
                frontier.append(dependency)
            }
        }
        return false
    }

    /// A node's commit `(epoch, seq)`.
    func position(of node: String) throws -> (Int64, Int64)? {
        if let row = try database.rows("SELECT epoch, seq FROM archive_entries WHERE op_id = ?", [.text(node)]).first,
           let epoch = row[0].integer, let seq = row[1].integer { return (epoch, seq) }
        if let row = try database.rows("SELECT epoch, seq FROM archive_decisions WHERE decision_id = ?", [.text(node)]).first,
           let epoch = row[0].integer, let seq = row[1].integer { return (epoch, seq) }
        return nil
    }

    // MARK: - Sync log (PROTOCOL §15.5: the last 30 days or 5,000 entries; never payloads)

    static let logLimit = 5_000
    static let logAge: Int64 = 30 * 86_400_000

    /// The one place the sync log is written: every line is redacted here (`ServerSyncLog.redacted`), whoever wrote it.
    func log(_ kind: String, _ detail: String, now: Int64) throws {
        try database.execute("INSERT INTO sync_log(time, kind, detail) VALUES (?, ?, ?)",
                             [.integer(now), .text(ServerSyncLog.redacted(kind)), .text(ServerSyncLog.redacted(detail))])
        try database.execute("DELETE FROM sync_log WHERE time < ? OR id <= (SELECT max(id) FROM sync_log) - ?",
                             [.integer(now - Self.logAge), .integer(Int64(Self.logLimit))])
    }

    /// One entry from outside the sync engine (a refused export, PROTOCOL §11.5) into a server library's existing
    /// `sync.sqlite`; best effort, and never creates the file of a library that has none.
    static func append(to url: URL, kind: String, now: Date, detail: String) {
        guard FileManager.default.fileExists(atPath: url.path), let archive = try? ServerArchive(url: url) else { return }
        try? archive.log(kind, detail, now: Int64((now.timeIntervalSince1970 * 1_000).rounded(.down)))
        try? archive.database.close()
    }

    struct LogEntry: Equatable, Sendable {
        var time: Int64
        var kind: String
        var detail: String
    }

    /// Newest first.
    func logEntries() throws -> [LogEntry] {
        try database.rows("SELECT time, kind, detail FROM sync_log ORDER BY id DESC").map {
            LogEntry(time: $0[0].integer ?? 0, kind: $0[1].text ?? "", detail: $0[2].text ?? "")
        }
    }

    // MARK: - Queue safeguards (PROTOCOL §15: copies kept before a commit removes more than 75% of the queue)

    func saveQueueSafeguard(_ record: ContractJSON, now: Int64) throws { try saveQueueSafeguards([record], now: now) }

    /// Saves safeguard copies in one durable transaction; one the archive already holds is skipped.
    func saveQueueSafeguards(_ records: [ContractJSON], now: Int64) throws {
        try database.transaction {
            for record in records {
                let data = try record.canonicalData()
                guard try database.scalar("SELECT count(*) FROM queue_safeguards WHERE record = ?", [.blob(data)]) == 0 else { continue }
                try database.execute("INSERT INTO queue_safeguards(time, record) VALUES (?, ?)", [.integer(now), .blob(data)])
            }
        }
    }

    func queueSafeguards() throws -> [ContractJSON] {
        try database.rows("SELECT record FROM queue_safeguards ORDER BY id").compactMap { try $0[0].data.map { try ContractJSON.decode($0) } }
    }
}
