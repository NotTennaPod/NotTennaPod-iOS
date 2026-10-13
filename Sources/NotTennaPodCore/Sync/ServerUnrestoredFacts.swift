import Foundation

/// What a recovery cannot restore yet, or ever (PROTOCOL §1.3, §6: unsent changes never expire, and a restored
/// server never rolls a phone back). Every fact names its author's previous fact and its dependencies, and transport
/// slots are consumed in order, so a fact the server cannot admit would hold back every fact after it. Two cases:
///
/// - **Waiting** (`dependency_missing` that another device may still restore): the facts of this library's outbox
///   chained behind a waiting node are *parked*: moved out of the slot order into `ntp_retained`, marked parked, with
///   their op IDs, authors, facts and overlays unchanged (the phone keeps showing them, as during an outage); the rest
///   of the outbox is renumbered. Once what they wait for joins they go back to the end of the outbox and are sent.
/// - **Refused for good** (`conflict`, `invalid_receipt`, `invalid`): the closure is *quarantined*: kept in
///   `ntp_retained` marked unrestored for the library's life, never sent; the engine withdraws its overlays and
///   projects what it touched from the base, as a retired rejected fact does.
///
/// Either way each blocked author that would write again (the main author, a registration's current author) continues
/// on a fresh author with no `installation.fork` (its tip was never placed: PROTOCOL §6.10's "never written as A"), and
/// the blocked nodes leave the known frontier, so no new fact depends on them: synchronization never stops.
/// The work is bounded (PROTOCOL §6.8): what to do is planned on a connection of its own, without the store,
/// and then done in steps of `blockedBatch` entries, each one short live transaction (`ServerBlockingSteps` drives
/// them). Every step is idempotent and a plan is made again from the live state, so an interruption leaves nothing a
/// later pass does not finish; slots are renumbered before anything is pushed.
extension FeedLibraryStore {
    /// The marks of `ntp_retained.lineage` (a JSON object), with why.
    static let unrestoredMark = "unrestored"
    static let parkedMark = "parked"
    /// Entries one live transaction moves, marks or renumbers.
    static let blockedBatch = 100
    /// Parked facts one live transaction puts back into the outbox (each is inserted on its own), and slots one
    /// renumbering step moves (each moves its row).
    static let releaseBatch = 50

    struct BlockedCandidate: Sendable {
        enum Kind: Sendable { case outbox, retained, draft }
        var opID: String
        var author: String?
        var names: Set<String>
        var kind: Kind
    }

    /// What parking or a quarantine does, planned from the live state.
    struct ServerBlockingPlan: Sendable {
        /// What moves out of the outbox, is marked in `ntp_retained` or leaves the drafts, in order.
        var chosen: [BlockedCandidate] = []
        /// Blocked known nodes in the frontier: they leave it in the same transaction as `giveBack` joins it, so every
        /// committed state keeps the known past covered.
        var tips: [String] = []
        /// Blocked known nodes below the frontier: marked out (2) afterwards, in steps, so they come back once they join.
        var interior: [String] = []
        /// Known nodes the frontier gets back (the repair).
        var giveBack: [String] = []
        /// Authors that continue on a fresh one: whether the main author does, and the registrations whose do.
        var rotateMain = false
        var rotateRegistrations: [String] = []
        /// The library's knowledge clock when planned: what was recorded since is taken into account when the first
        /// step runs (`prepareServerBlocking`), with what is blocked and what never joins the frontier.
        var clock: Int64 = 0
        var blocked: Set<String> = []
        var excluded: Set<String> = []

        /// Whether the frontier or the writers change.
        var repairs: Bool { !tips.isEmpty || !giveBack.isEmpty || rotateMain || !rotateRegistrations.isEmpty }
        var isEmpty: Bool { chosen.isEmpty && interior.isEmpty && !repairs }
    }

    // MARK: - Planning (any connection; read only)

    private static func unreceiptedOutbox(_ db: LibrarySQLite) throws -> [BlockedCandidate] {
        try db.rows("SELECT op_id, author_id, fact FROM ntp_outbox WHERE receipt IS NULL ORDER BY install_seq").compactMap { row in
            guard let op = row[0].text, let data = row[2].data else { return nil }
            return BlockedCandidate(opID: op, author: row[1].text, names: named(try ContractJSON.decode(data)), kind: .outbox)
        }
    }

    /// Retained entries with what they name, and whether each is parked or quarantined.
    private static func retainedNames(_ db: LibrarySQLite) throws -> [(op: String, author: String?, names: Set<String>, parked: Bool, unrestored: Bool, slot: Int64)] {
        try db.rows("SELECT op_id, fact, lineage, slot FROM ntp_retained ORDER BY transport, slot").compactMap { row in
            guard let op = row[0].text, let data = row[1].data else { return nil }
            let fact = try ContractJSON.decode(data)
            return (op, fact["author_id"]?.stringValue, named(fact), isMarked(row[2].data, parkedMark), isMarked(row[2].data, unrestoredMark), row[3].integer ?? 0)
        }
    }

    private static func drafts(_ db: LibrarySQLite) throws -> [BlockedCandidate] {
        try db.rows("SELECT op_id, author_id, previous_op_id, dependencies FROM ntp_drafts ORDER BY created_at, author_seq").compactMap { row in
            guard let op = row[0].text else { return nil }
            var names = Set<String>()
            if let previous = row[2].text { names.insert(previous) }
            if let text = row[3].text { names.formUnion((try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []) }
            return BlockedCandidate(opID: op, author: row[1].text, names: names, kind: .draft)
        }
    }

    /// The candidates that are, or name, a blocked node, transitively (each table in its own order, so a few passes
    /// reach the fixed point); `blocked` gains them.
    private static func closure(_ candidates: [BlockedCandidate], _ blocked: inout Set<String>) -> [BlockedCandidate] {
        var chosen: [BlockedCandidate] = [], taken = Set<String>()
        var changed = true
        while changed {
            changed = false
            for candidate in candidates where !taken.contains(candidate.opID) {
                guard blocked.contains(candidate.opID) || !candidate.names.isDisjoint(with: blocked) else { continue }
                blocked.insert(candidate.opID); taken.insert(candidate.opID); chosen.append(candidate); changed = true
            }
        }
        return chosen
    }

    /// Parking (`parkingPlan`): every unsent outbox fact chained behind `waiting` (nodes the server lacks and another
    /// device may still restore) or behind a fact parked earlier, transitively.
    static func parkingPlan(_ db: LibrarySQLite, behind waiting: Set<String>, archived: [String: Set<String>]) throws -> ServerBlockingPlan {
        let retained = try retainedNames(db)
        var blocked = waiting.union(retained.filter(\.parked).map(\.op))
        let candidates = try unreceiptedOutbox(db)
        var plan = ServerBlockingPlan()
        plan.chosen = closure(candidates, &blocked)
        try finishPlan(&plan, db, blocked: blocked, waiting: waiting, candidates: candidates, retained: retained, archived: archived)
        return plan
    }

    /// The quarantine (`quarantinePlan`): every fact this library holds that is, or names, one of `unrestored` (op and
    /// decision IDs the recovery can never restore) or a fact quarantined before, transitively, parked ones included.
    /// What is quarantined already stays a causal bridge: a quarantine an interruption left after
    /// some of its steps is planned again whole, and its rest is quarantined too.
    static func quarantinePlan(_ db: LibrarySQLite, unrestored: Set<String>, waiting: Set<String>,
                               archived: [String: Set<String>]) throws -> ServerBlockingPlan {
        let retained = try retainedNames(db)
        var blocked = unrestored.union(retained.filter(\.unrestored).map(\.op))
        var candidates = try unreceiptedOutbox(db)
        candidates += retained.filter { !$0.unrestored }.map { BlockedCandidate(opID: $0.op, author: $0.author, names: $0.names, kind: .retained) }
        candidates += try drafts(db)
        var plan = ServerBlockingPlan()
        plan.chosen = closure(candidates, &blocked)
        try finishPlan(&plan, db, blocked: blocked, waiting: waiting, candidates: candidates, retained: retained, archived: archived)
        return plan
    }

    /// The frontier and the authors (`leave`, in the plan): the blocked nodes leave the frontier (marked 2, "out while
    /// blocked": `rejoinServerFrontier` brings back those that join), which is repaired from the surviving causal graph
    ///: walking back from each blocked node through what it names, past other blocked, waiting,
    /// parked or quarantined nodes, every known node reached joins the frontier again. A later cut (Clear history, Reset
    /// statistics) depends on the frontier, so it still observes everything the blocked nodes covered, and never names a
    /// node the server may lack. (A node reached may also be covered by another frontier node: a redundant dependency,
    /// harmless.) Each blocked author that would write again continues on a fresh one.
    private static func finishPlan(_ plan: inout ServerBlockingPlan, _ db: LibrarySQLite, blocked: Set<String>, waiting: Set<String>,
                                   candidates: [BlockedCandidate], retained: [(op: String, author: String?, names: Set<String>, parked: Bool, unrestored: Bool, slot: Int64)],
                                   archived: [String: Set<String>]) throws {
        var names = archived
        for entry in retained { names[entry.op] = entry.names }
        for candidate in candidates { names[candidate.opID] = candidate.names }
        var excluded = blocked.union(waiting)
        for entry in retained where entry.parked || entry.unrestored { excluded.insert(entry.op) }
        // Known nodes only, and only what changes.
        var flags: [String: Int64] = [:]
        func readFlags(_ nodes: Set<String>) throws {
            for chunk in chunks(Array(nodes)) {
                for row in try db.rows("SELECT node_id, frontier FROM ntp_nodes WHERE kind != 'draft' AND node_id IN (SELECT value FROM json_each(?))",
                                       [.text(ContractJSON.array(chunk.map(ContractJSON.string)).canonicalText)]) {
                    if let node = row[0].text, let flag = row[1].integer { flags[node] = flag }
                }
            }
        }
        try readFlags(blocked)
        plan.blocked = blocked
        plan.excluded = excluded
        // From the nodes not out yet: those already out were walked when they left (a later cut may cover what they
        // gave back; it stays covered).
        var reached = Set<String>(), visited = Set<String>(), stack = Array(blocked.filter { flags[$0] != 2 })
        while let node = stack.popLast() {
            guard visited.insert(node).inserted else { continue }
            for name in names[node] ?? [] {
                if excluded.contains(name) { stack.append(name) } else { reached.insert(name) }
            }
        }
        try readFlags(reached)
        plan.tips = blocked.filter { flags[$0] == 1 }.sorted()
        plan.interior = blocked.filter { flags[$0] == 0 }.sorted()
        plan.giveBack = reached.filter { flags[$0].map { $0 != 1 } ?? false }.sorted()
        // An author blocked by its moved facts, or whose writing tip (a fact the server lacks) is blocked.
        var authors = Set(plan.chosen.compactMap(\.author))
        for row in try db.rows("SELECT author_id, last_op_id FROM ntp_authors WHERE last_op_id IS NOT NULL") {
            if let author = row[0].text, let tip = row[1].text, blocked.contains(tip) { authors.insert(author) }
        }
        if let main = try db.rows("SELECT main_author FROM ntp_library WHERE id = 1").first?.first?.text { plan.rotateMain = authors.contains(main) }
        plan.clock = try db.scalar("SELECT knowledge_clock FROM ntp_library WHERE id = 1")
        for row in try db.rows("SELECT op_id, author_id FROM ntp_registrations ORDER BY created_at, rowid") {
            if let op = row[0].text, let author = row[1].text, authors.contains(author) { plan.rotateRegistrations.append(op) }
        }
    }

    /// Parked facts whose waiting is over (nothing they name is still waiting or parked), in the order they go back.
    static func releasePlan(_ db: LibrarySQLite, stillWaiting waiting: Set<String>) throws -> [String] {
        let parked = try retainedNames(db).filter(\.parked).sorted { $0.slot < $1.slot }
        var kept = Set(parked.map(\.op))
        var released: [String] = []
        var changed = true
        while changed {
            changed = false
            for entry in parked where kept.contains(entry.op) {
                guard entry.names.isDisjoint(with: waiting), entry.names.isDisjoint(with: kept) else { continue }
                kept.remove(entry.op); released.append(entry.op); changed = true
            }
        }
        return released
    }

    // MARK: - Steps (each one live transaction)

    /// Parks these outbox facts (out of the slot order, unchanged, still shown). Returns how many were parked now.
    @discardableResult
    func parkServerFacts(_ batch: [BlockedCandidate], now: Date = Date()) throws -> Int {
        guard serverContext != nil else { throw ServerRecordingError.notAServerLibrary }
        let mark = ContractJSON.object([Self.parkedMark: "dependency_missing", "at": .integer(try milliseconds(now))])
        let list = ContractJSON.array(batch.filter { $0.kind == .outbox }.map { .string($0.opID) }).canonicalText
        return try database.transaction {
            try database.execute("INSERT INTO ntp_retained(op_id, transport, slot, fact, receipt, lineage, secret_ids) SELECT op_id, (SELECT install_id FROM ntp_library WHERE id = 1), install_seq, fact, receipt, ?, secret_ids FROM ntp_outbox WHERE receipt IS NULL AND op_id IN (SELECT value FROM json_each(?)) ORDER BY install_seq ON CONFLICT(op_id) DO UPDATE SET lineage = excluded.lineage",
                                 [.blob(try mark.canonicalData()), .text(list)])
            try database.execute("DELETE FROM ntp_outbox WHERE receipt IS NULL AND op_id IN (SELECT value FROM json_each(?))", [.text(list)])
            return Int(try database.scalar("SELECT changes()"))
        }
    }

    /// Quarantines these facts, kept as evidence and never sent; the open recovery counts them in the same transaction
    /// (an interruption right after never loses it). Returns how many were quarantined now.
    @discardableResult
    func quarantineServerFacts(_ batch: [BlockedCandidate], reason: String, now: Date = Date()) throws -> Int {
        guard serverContext != nil else { throw ServerRecordingError.notAServerLibrary }
        let mark = try ContractJSON.object([Self.unrestoredMark: .string(reason), "at": .integer(try milliseconds(now))]).canonicalData()
        func list(_ kind: BlockedCandidate.Kind) -> String {
            ContractJSON.array(batch.filter { $0.kind == kind }.map { .string($0.opID) }).canonicalText
        }
        return try database.transaction { () throws -> Int in
            var count = 0
            try database.execute("INSERT INTO ntp_retained(op_id, transport, slot, fact, receipt, lineage, secret_ids) SELECT op_id, (SELECT install_id FROM ntp_library WHERE id = 1), install_seq, fact, receipt, ?, secret_ids FROM ntp_outbox WHERE receipt IS NULL AND op_id IN (SELECT value FROM json_each(?)) ORDER BY install_seq ON CONFLICT(op_id) DO UPDATE SET lineage = excluded.lineage",
                                 [.blob(mark), .text(list(.outbox))])
            try database.execute("DELETE FROM ntp_outbox WHERE receipt IS NULL AND op_id IN (SELECT value FROM json_each(?))", [.text(list(.outbox))])
            count += Int(try database.scalar("SELECT changes()"))
            for row in try database.rows("SELECT op_id, lineage FROM ntp_retained WHERE op_id IN (SELECT value FROM json_each(?))", [.text(list(.retained))]) {
                guard let op = row[0].text, !Self.isUnrestored(row[1].data) else { continue }
                try database.execute("UPDATE ntp_retained SET lineage = ? WHERE op_id = ?", [.blob(mark), .text(op)])
                count += 1
            }
            // A draft is kept as the template it is (its local references never became wire IDs).
            try database.execute("INSERT INTO ntp_retained(op_id, transport, slot, fact, receipt, lineage, secret_ids) SELECT op_id, 'draft:' || registration_op, author_seq, template, NULL, ?, NULL FROM ntp_drafts WHERE op_id IN (SELECT value FROM json_each(?)) ON CONFLICT(op_id) DO UPDATE SET lineage = excluded.lineage",
                                 [.blob(mark), .text(list(.draft))])
            try database.execute("DELETE FROM ntp_drafts WHERE op_id IN (SELECT value FROM json_each(?))", [.text(list(.draft))])
            count += Int(try database.scalar("SELECT changes()"))
            if count > 0, var recovery = try Self.recovery(database), !recovery.finished {
                recovery.quarantined += count
                recovery.complete = false
                try Self.storeRecovery(recovery, database)
            }
            return count
        }
    }

    /// The plan's first step, before anything moves, in one transaction: the blocked tips leave the frontier as the
    /// known nodes they covered join it (so a cut recorded after any committed step still observes the known past), and
    /// the blocked authors continue on fresh ones (so a change the person makes after it is never chained behind what
    /// is blocked). A plan is never applied stale: facts recorded since it was made (a later knowledge clock), in their
    /// order, are blocked too when they name a blocked node, and leave the frontier with the tips, what they name joins
    /// it and their authors continue on fresh ones, in this same transaction. Returns how many such facts were found: a
    /// further pass moves them.
    @discardableResult
    func prepareServerBlocking(_ plan: ServerBlockingPlan, now: Date = Date()) throws -> Int {
        guard serverContext != nil else { throw ServerRecordingError.notAServerLibrary }
        let time = try milliseconds(now)
        let (extended, rotated) = try database.transaction { () throws -> (Int, Bool) in
            var tips = plan.tips, giveBack = Set(plan.giveBack), rotateMain = plan.rotateMain
            var rotateRegistrations = plan.rotateRegistrations
            var extended = 0
            if try database.scalar("SELECT knowledge_clock FROM ntp_library WHERE id = 1") != plan.clock {
                var blocked = plan.blocked
                let main = try database.rows("SELECT main_author FROM ntp_library WHERE id = 1").first?.first?.text
                for row in try database.rows("SELECT node_id FROM ntp_nodes WHERE knowledge_clock > ? ORDER BY knowledge_clock, node_id", [.integer(plan.clock)]) {
                    guard let node = row[0].text, !blocked.contains(node) else { continue }
                    let names = try Self.knownNames(database, of: [node])[node] ?? []
                    guard !names.isDisjoint(with: blocked) else { continue }
                    blocked.insert(node)
                    extended += 1
                    tips.append(node)
                    giveBack.formUnion(names.filter { !blocked.contains($0) && !plan.excluded.contains($0) })
                    let author = try database.rows("SELECT author_id FROM ntp_outbox WHERE op_id = ? UNION ALL SELECT author_id FROM ntp_drafts WHERE op_id = ?",
                                                   [.text(node), .text(node)]).first?.first?.text
                    if let author, author == main { rotateMain = true }
                    if let author, let registration = try database.rows("SELECT op_id FROM ntp_registrations WHERE author_id = ?", [.text(author)]).first?.first?.text,
                       !rotateRegistrations.contains(registration) { rotateRegistrations.append(registration) }
                }
                giveBack.subtract(blocked)
            }
            for chunk in Self.chunks(tips) {
                try database.execute("UPDATE ntp_nodes SET frontier = 2 WHERE frontier = 1 AND node_id IN (SELECT value FROM json_each(?))",
                                     [.text(ContractJSON.array(chunk.map(ContractJSON.string)).canonicalText)])
            }
            for chunk in Self.chunks(Array(giveBack)) {
                try database.execute("UPDATE ntp_nodes SET frontier = 1 WHERE kind != 'draft' AND frontier != 2 AND node_id IN (SELECT value FROM json_each(?))",
                                     [.text(ContractJSON.array(chunk.map(ContractJSON.string)).canonicalText)])
            }
            if rotateMain, let main = try database.rows("SELECT main_author FROM ntp_library WHERE id = 1").first?.first?.text {
                let fresh = ContractIdentity.randomUUID()
                try database.execute("INSERT INTO ntp_authors(author_id, role, next_seq, forked_from, created_at) VALUES (?, 'main', 1, ?, ?)",
                                     [.text(fresh), .text(main), .integer(time)])
                try database.execute("UPDATE ntp_library SET main_author = ? WHERE id = 1", [.text(fresh)])
            }
            for op in rotateRegistrations {
                guard let author = try database.rows("SELECT author_id FROM ntp_registrations WHERE op_id = ?", [.text(op)]).first?.first?.text else { continue }
                let fresh = ContractIdentity.randomUUID()
                try database.execute("INSERT INTO ntp_authors(author_id, role, next_seq, registration_op, forked_from, created_at) VALUES (?, 'registration', 1, ?, ?, ?)",
                                     [.text(fresh), .text(op), .text(author), .integer(time)])
                try database.execute("UPDATE ntp_registrations SET author_id = ? WHERE op_id = ?", [.text(fresh), .text(op)])
            }
            return (extended, rotateMain || !rotateRegistrations.isEmpty)
        }
        if rotated { serverContext = try Self.loadServerContext(database) }
        return extended
    }

    /// Marks these blocked nodes below the frontier out (2), so they come back once they join; nodes in the frontier
    /// are never touched here (`prepareServerBlocking` moves those).
    func takeOutOfServerFrontier(_ batch: [String]) throws {
        guard serverContext != nil, !batch.isEmpty else { return }
        try database.transaction {
            try database.execute("UPDATE ntp_nodes SET frontier = 2 WHERE frontier = 0 AND node_id IN (SELECT value FROM json_each(?))",
                                 [.text(ContractJSON.array(batch.map(ContractJSON.string)).canonicalText)])
        }
    }

    /// These parked facts go back to the end of the outbox, in this order, unchanged, and are sent as usual; each
    /// covers what it names again. Returns the op IDs released now.
    @discardableResult
    func unparkServerFacts(_ batch: [String]) throws -> [String] {
        guard serverContext != nil else { throw ServerRecordingError.notAServerLibrary }
        let list = ContractJSON.array(batch.map(ContractJSON.string)).canonicalText
        return try database.transaction { () throws -> [String] in
            var rows: [String: (fact: ContractJSON, secrets: String?)] = [:]
            for row in try database.rows("SELECT op_id, fact, secret_ids, lineage FROM ntp_retained WHERE op_id IN (SELECT value FROM json_each(?))", [.text(list)]) {
                guard let op = row[0].text, let data = row[1].data, Self.isMarked(row[3].data, Self.parkedMark) else { continue }
                rows[op] = (try ContractJSON.decode(data), row[2].text)
            }
            var released: [String] = []
            var slot = try database.scalar("SELECT next_install_seq FROM ntp_library WHERE id = 1")
            let created = Int64(Date().timeIntervalSince1970 * 1_000)
            for op in batch {
                guard let entry = rows[op] else { continue }
                let bytes = try entry.fact.canonicalBytes()
                try database.execute("INSERT INTO ntp_outbox(install_seq, op_id, author_id, author_seq, type, fact, content_hash, secret_ids, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                                     [.integer(slot), .text(op), .text(entry.fact["author_id"]?.stringValue ?? ""),
                                      .integer(entry.fact["author_seq"]?.integerValue ?? 0), .text(entry.fact["type"]?.stringValue ?? ""),
                                      .blob(Data(bytes)), .text(ContractIdentity.sha256Hex(bytes)), entry.secrets.map(LibrarySQLValue.text) ?? .null,
                                      .integer(created)])
                slot += 1
                // Known again, it covers what it names (the frontier the repair gave back included those).
                let named = ContractJSON.array(Self.named(entry.fact).map(ContractJSON.string)).canonicalText
                try database.execute("UPDATE ntp_nodes SET frontier = 0 WHERE frontier != 0 AND node_id IN (SELECT value FROM json_each(?))", [.text(named)])
                try database.execute("UPDATE ntp_nodes SET frontier = 1 WHERE node_id = ?", [.text(op)])
                released.append(op)
            }
            try database.execute("UPDATE ntp_library SET next_install_seq = ? WHERE id = 1", [.integer(slot)])
            try database.execute("DELETE FROM ntp_retained WHERE op_id IN (SELECT value FROM json_each(?))",
                                 [.text(ContractJSON.array(released.map(ContractJSON.string)).canonicalText)])
            return released
        }
    }

    /// One step of renumbering: unacknowledged slots stay contiguous after entries left the outbox (none of them was
    /// consumed: the server consumes slots in order), so what follows the acknowledged prefix is numbered again from
    /// it, in order, at most `limit` entries a transaction. Returns whether more is left to renumber. The push renumbers
    /// first, so nothing is sent with a gap.
    @discardableResult
    func renumberServerOutbox(limit: Int = releaseBatch) throws -> Bool {
        guard serverContext != nil else { return false }
        return try database.transaction { try Self.renumberStep(database, limit: limit) }
    }

    /// `renumberServerOutbox` inside the caller's transaction.
    static func renumberStep(_ database: LibrarySQLite, limit: Int) throws -> Bool {
        let acked = try database.scalar("SELECT acked_install_seq FROM ntp_library WHERE id = 1")
        // Each entry's place is the acknowledged prefix plus its rank; an entry above its place moves down (its place
        // is free: ranks before it are in place, and every entry after it is higher still).
        let misplaced = try database.rows("SELECT install_seq, framing, place FROM (SELECT install_seq, framing, ? + ROW_NUMBER() OVER (ORDER BY install_seq) AS place FROM ntp_outbox WHERE install_seq > ?) WHERE install_seq != place ORDER BY install_seq LIMIT ?",
                                          [.integer(acked), .integer(acked), .integer(Int64(limit) + 1)])
        for row in misplaced.prefix(limit) {
            guard let old = row[0].integer, let place = row[2].integer else { continue }
            var framing: LibrarySQLValue = row[1].data.map(LibrarySQLValue.blob) ?? .null
            if let data = row[1].data, var stored = try? JSONDecoder().decode(ServerFraming.self, from: data) {
                stored.present = []
                framing = .blob(try JSONEncoder().encode(stored))
            }
            try database.execute("UPDATE ntp_outbox SET install_seq = ?, framing = ?, waiting = NULL WHERE install_seq = ?",
                                 [.integer(place), framing, .integer(old)])
        }
        guard misplaced.count <= limit else { return true }
        let next = max(acked, try database.scalar("SELECT coalesce(max(install_seq), 0) FROM ntp_outbox")) + 1
        if try database.scalar("SELECT next_install_seq FROM ntp_library WHERE id = 1") != next {
            try database.execute("UPDATE ntp_library SET next_install_seq = ? WHERE id = 1", [.integer(next)])
        }
        return false
    }

    // MARK: - In one call (a small library, tests): the steps above, one after another on the store

    /// Parks every unsent outbox fact chained behind `waiting` (`parkingPlan`), renumbering after. Returns the op IDs
    /// parked now. Idempotent. `onlyNew`: a pass before a push, after a full one ran for these nodes: nothing more is
    /// done when nothing new is chained behind them.
    @discardableResult
    func parkWaitingFacts(behind waiting: Set<String>, archived: [String: Set<String>] = [:], onlyNew: Bool = false,
                          now: Date = Date()) throws -> [String] {
        guard serverContext != nil else { throw ServerRecordingError.notAServerLibrary }
        let plan = try database.transaction(write: false) { try Self.parkingPlan(database, behind: waiting, archived: archived) }
        if onlyNew, plan.chosen.isEmpty { return [] }
        try prepareServerBlocking(plan, now: now)
        for batch in Self.chunks(plan.chosen, size: Self.blockedBatch) { try parkServerFacts(batch, now: now) }
        for batch in Self.chunks(plan.interior, size: Self.blockedBatch) { try takeOutOfServerFrontier(batch) }
        while try renumberServerOutbox() {}
        return plan.chosen.map(\.opID)
    }

    /// Quarantines (`quarantinePlan`), renumbering after. Returns the op IDs quarantined now. Idempotent.
    @discardableResult
    func quarantineUnrestoredFacts(_ unrestored: Set<String>, reason: String, archived: [String: Set<String>] = [:],
                                   waiting: Set<String> = [], now: Date = Date()) throws -> [String] {
        guard serverContext != nil else { throw ServerRecordingError.notAServerLibrary }
        let plan = try database.transaction(write: false) {
            try Self.quarantinePlan(database, unrestored: unrestored, waiting: waiting, archived: archived)
        }
        try prepareServerBlocking(plan, now: now)
        for batch in Self.chunks(plan.chosen, size: Self.blockedBatch) { try quarantineServerFacts(batch, reason: reason, now: now) }
        for batch in Self.chunks(plan.interior, size: Self.blockedBatch) { try takeOutOfServerFrontier(batch) }
        while try renumberServerOutbox() {}
        return plan.chosen.map(\.opID)
    }

    /// Releases the parked facts whose waiting is over (`releasePlan`). Returns the op IDs released.
    @discardableResult
    func unparkFacts(stillWaiting waiting: Set<String>) throws -> [String] {
        guard serverContext != nil else { throw ServerRecordingError.notAServerLibrary }
        let order = try database.transaction(write: false) { try Self.releasePlan(database, stillWaiting: waiting) }
        var released: [String] = []
        for batch in Self.chunks(order, size: Self.releaseBatch) { released += try unparkServerFacts(batch) }
        return released
    }

    /// The parked facts, in their order.
    func parkedFacts() throws -> [ServerRetainedEntry] {
        try serverRetainedEntries().filter(\.parked).sorted { $0.slot < $1.slot }
    }

    /// Whether this library quarantined anything (a quarantine to resume may be left).
    func hasUnrestoredServerFacts() throws -> Bool {
        guard serverContext != nil else { return false }
        return try database.scalar("SELECT EXISTS(SELECT 1 FROM ntp_retained WHERE json_extract(CAST(lineage AS TEXT), '$.unrestored') IS NOT NULL)") == 1
    }

    /// Nodes taken out of the frontier while they were blocked that are not parked or quarantined (those stay out).
    func blockedOutServerNodes() throws -> [String] {
        guard serverContext != nil else { return [] }
        return try Self.blockedOutNodes(database)
    }

    static func blockedOutNodes(_ db: LibrarySQLite) throws -> [String] {
        try db.rows("SELECT n.node_id FROM ntp_nodes n WHERE n.frontier = 2 AND NOT EXISTS (SELECT 1 FROM ntp_retained r WHERE r.op_id = n.node_id AND (json_extract(CAST(r.lineage AS TEXT), '$.parked') IS NOT NULL OR json_extract(CAST(r.lineage AS TEXT), '$.unrestored') IS NOT NULL)) ORDER BY n.node_id")
            .compactMap { $0[0].text }
    }

    /// Of `nodes` (taken out while blocked), those nothing excludes any more (they joined: not in `waiting`, parked or
    /// quarantined) come back: the ones none of them names join the frontier again (`tips`), the others are covered
    /// (a later cut observes them). `archived` gives what the archive's among them name.
    static func rejoinPlan(_ db: LibrarySQLite, _ nodes: [String], stillWaiting waiting: Set<String>,
                           archived: [String: Set<String>]) throws -> (tips: [String], covered: [String]) {
        var back = Set(nodes).subtracting(waiting)
        for chunk in chunks(Array(back)) {
            for row in try db.rows("SELECT op_id, lineage FROM ntp_retained WHERE op_id IN (SELECT value FROM json_each(?))",
                                   [.text(ContractJSON.array(chunk.map(ContractJSON.string)).canonicalText)]) {
                if let op = row[0].text, isMarked(row[1].data, unrestoredMark) || isMarked(row[1].data, parkedMark) { back.remove(op) }
            }
        }
        guard !back.isEmpty else { return ([], []) }
        var names = try knownNames(db, of: back)
        names.merge(archived) { known, _ in known }
        let covered = back.intersection(Set(back.flatMap { names[$0] ?? [] }))
        return (back.subtracting(covered).sorted(), covered.sorted())
    }

    /// Sets these nodes, out while blocked, back: in the frontier (1) or covered (0). Each step only adds to the
    /// frontier, so any committed state keeps the known past covered.
    func setServerFrontier(_ batch: [String], to flag: Int64) throws {
        guard serverContext != nil, !batch.isEmpty else { return }
        try database.transaction {
            try database.execute("UPDATE ntp_nodes SET frontier = ? WHERE frontier = 2 AND node_id IN (SELECT value FROM json_each(?))",
                                 [.integer(flag), .text(ContractJSON.array(batch.map(ContractJSON.string)).canonicalText)])
        }
    }

    /// `rejoinPlan` and its steps in one call (a small library, tests). Returns how many joined the frontier.
    @discardableResult
    func rejoinServerFrontier(_ nodes: [String], stillWaiting waiting: Set<String>, archived: [String: Set<String>]) throws -> Int {
        guard serverContext != nil else { return 0 }
        let plan = try database.transaction(write: false) { try Self.rejoinPlan(database, nodes, stillWaiting: waiting, archived: archived) }
        for batch in Self.chunks(plan.covered, size: Self.blockedBatch) { try setServerFrontier(batch, to: 0) }
        for batch in Self.chunks(plan.tips, size: Self.blockedBatch) { try setServerFrontier(batch, to: 1) }
        return plan.tips.count
    }

    /// What the facts and drafts this library holds among `ops` name (the archive's are the engine's to give).
    private static func knownNames(_ database: LibrarySQLite, of ops: Set<String>) throws -> [String: Set<String>] {
        var names: [String: Set<String>] = [:]
        for chunk in chunks(Array(ops)) {
            let list = ContractJSON.array(chunk.map(ContractJSON.string)).canonicalText
            for table in ["ntp_retained", "ntp_outbox"] {
                for row in try database.rows("SELECT op_id, fact FROM \(table) WHERE op_id IN (SELECT value FROM json_each(?))", [.text(list)]) {
                    guard let op = row[0].text, let data = row[1].data else { continue }
                    names[op, default: []].formUnion(named(try ContractJSON.decode(data)))
                }
            }
            for row in try database.rows("SELECT op_id, previous_op_id, dependencies FROM ntp_drafts WHERE op_id IN (SELECT value FROM json_each(?))", [.text(list)]) {
                guard let op = row[0].text else { continue }
                if let previous = row[1].text { names[op, default: []].insert(previous) }
                if let text = row[2].text { names[op, default: []].formUnion((try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []) }
            }
        }
        return names
    }

    /// The facts and nodes a fact names: its author's previous fact and its dependencies.
    static func named(_ fact: ContractJSON) -> Set<String> {
        var names = Set(fact["dependencies"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        if let previous = fact["previous_op_id"]?.stringValue { names.insert(previous) }
        return names
    }

    static func isMarked(_ lineage: Data?, _ mark: String) -> Bool {
        guard let lineage, let json = try? ContractJSON.decode(lineage) else { return false }
        return json[mark] != nil
    }

    static func isUnrestored(_ lineage: Data?) -> Bool { isMarked(lineage, unrestoredMark) }

    /// Unrestored retained entries whose overlays have not been withdrawn yet (a crash between the quarantine and its
    /// unit leaves some): the engine withdraws them. Parked facts keep theirs.
    func unrestoredWithOverlays() throws -> [String] {
        guard serverContext != nil else { return [] }
        return try database.rows("SELECT r.op_id, r.lineage FROM ntp_retained r WHERE EXISTS (SELECT 1 FROM ntp_overlays o WHERE o.op_id = r.op_id)").compactMap {
            Self.isUnrestored($0[1].data) ? $0[0].text : nil
        }
    }
}

/// Drives parking, quarantine, release and renumbering in bounded steps (PROTOCOL §6.8): the plan is made on a
/// read-only connection of its own, then each step is one short store transaction, so a playback save or a local action
/// waits for one step at most, never for the whole operation.
enum ServerBlockingSteps {
    static func read<T>(_ url: URL, _ body: (LibrarySQLite) throws -> T) throws -> T {
        let connection = try LibrarySQLite(readingOnly: url)
        defer { try? connection.close() }
        return try connection.transaction(write: false) { try body(connection) }
    }

    /// `FeedLibraryStore.parkWaitingFacts`, in steps.
    @discardableResult
    static func park(_ store: FeedLibraryStore, database url: URL, behind waiting: Set<String>, archived: [String: Set<String>],
                     onlyNew: Bool = false, now: Date, between: (@Sendable (String) async throws -> Void)? = nil) async throws -> [String] {
        let replan = { try read(url) { try FeedLibraryStore.parkingPlan($0, behind: waiting, archived: archived) } }
        let plan = try replan()
        if onlyNew, plan.chosen.isEmpty { return [] }
        try await between?("park.planned")
        let found = try await store.prepareServerBlocking(plan, now: now)
        try await between?("park.frontier")
        for batch in FeedLibraryStore.chunks(plan.chosen, size: FeedLibraryStore.blockedBatch) {
            try await store.parkServerFacts(batch, now: now)
            try await between?("park.batch")
        }
        try await finish(store, plan, "park", between)
        // What was recorded meanwhile and is blocked too: moved by another pass (its writers already continue apart).
        let more = found > 0 ? try await park(store, database: url, behind: waiting, archived: archived, onlyNew: true, now: now, between: between) : []
        return plan.chosen.map(\.opID) + more
    }

    /// `FeedLibraryStore.quarantineUnrestoredFacts`, in steps. `onlyNeeded`: nothing is done when the plan finds nothing
    /// left (a pass resuming an interrupted quarantine).
    @discardableResult
    static func quarantine(_ store: FeedLibraryStore, database url: URL, _ unrestored: Set<String>, reason: String,
                           archived: [String: Set<String>], waiting: Set<String>, now: Date, onlyNeeded: Bool = false,
                           between: (@Sendable (String) async throws -> Void)? = nil) async throws -> [String] {
        let replan = { try read(url) { try FeedLibraryStore.quarantinePlan($0, unrestored: unrestored, waiting: waiting, archived: archived) } }
        let plan = try replan()
        if onlyNeeded, plan.isEmpty { return [] }
        try await between?("quarantine.planned")
        let found = try await store.prepareServerBlocking(plan, now: now)
        try await between?("quarantine.frontier")
        for batch in FeedLibraryStore.chunks(plan.chosen, size: FeedLibraryStore.blockedBatch) {
            try await store.quarantineServerFacts(batch, reason: reason, now: now)
            try await between?("quarantine.batch")
        }
        try await finish(store, plan, "quarantine", between)
        let more = found > 0 ? try await quarantine(store, database: url, unrestored, reason: reason, archived: archived, waiting: waiting, now: now,
                                                     onlyNeeded: true, between: between) : []
        return plan.chosen.map(\.opID) + more
    }

    /// `FeedLibraryStore.unparkFacts`, in steps.
    @discardableResult
    static func unpark(_ store: FeedLibraryStore, database url: URL, stillWaiting waiting: Set<String>) async throws -> [String] {
        let order = try read(url) { try FeedLibraryStore.releasePlan($0, stillWaiting: waiting) }
        var released: [String] = []
        for batch in FeedLibraryStore.chunks(order, size: FeedLibraryStore.releaseBatch) { released += try await store.unparkServerFacts(batch) }
        return released
    }

    /// Renumbers until the unacknowledged slots are contiguous.
    static func renumber(_ store: FeedLibraryStore) async throws {
        while try await store.renumberServerOutbox() {}
    }

    private static func finish(_ store: FeedLibraryStore, _ plan: FeedLibraryStore.ServerBlockingPlan, _ kind: String,
                               _ between: (@Sendable (String) async throws -> Void)?) async throws {
        for batch in FeedLibraryStore.chunks(plan.interior, size: FeedLibraryStore.blockedBatch) { try await store.takeOutOfServerFrontier(batch) }
        try await between?("\(kind).marked")
        try await renumber(store)
    }
}
