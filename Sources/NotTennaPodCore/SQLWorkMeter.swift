import Foundation
import SQLite3
import Synchronization

/// The routine-work meter of the budgets (tests only; off in the app): SQL and host work summed over every connection
/// of the process (a store's writer, planning and read-only connections, shadow and staging libraries, the sync
/// database and archive readers), whichever opened during the measured interval. Each statement adds its VM steps, the
/// pages its connection fetched while it ran (page-cache hits and misses: the B-tree work one VM step can hide), the rows
/// it wrote (triggers included) and the rows and bytes it handed to the host; record decodes (episodes, feeds, protocol
/// JSON, journal sessions) and the change-set keys built are counted where they happen.
///
/// While `recording`, every distinct statement is explained on the connection that runs it, from its bytecode: each
/// b-tree it reads whole (a cursor rewound over a table or index, whatever alias or scope names it), by schema and table,
/// labelled with the operation the test names (`operation`). A statement is explained again for each operation, each
/// connection (by its number, never its file's name) and each schema that connection has (its databases and their
/// schema versions). A statement that cannot be explained there is a failure, not a skip.
public final class SQLWorkMeter: Sendable {
    public static let shared = SQLWorkMeter()

    public struct Totals: Sendable, Equatable, CustomStringConvertible {
        public var steps: Int64 = 0
        public var pages: Int64 = 0
        public var statements: Int64 = 0
        public var rowsRead: Int64 = 0
        public var bytesRead: Int64 = 0
        public var rowsWritten: Int64 = 0
        public var sessionsDecoded: Int64 = 0
        public var recordsDecoded: Int64 = 0
        public var bytesDecoded: Int64 = 0
        public var keys: Int64 = 0

        public static func - (a: Totals, b: Totals) -> Totals {
            Totals(steps: a.steps - b.steps, pages: a.pages - b.pages, statements: a.statements - b.statements,
                   rowsRead: a.rowsRead - b.rowsRead, bytesRead: a.bytesRead - b.bytesRead, rowsWritten: a.rowsWritten - b.rowsWritten,
                   sessionsDecoded: a.sessionsDecoded - b.sessionsDecoded, recordsDecoded: a.recordsDecoded - b.recordsDecoded,
                   bytesDecoded: a.bytesDecoded - b.bytesDecoded, keys: a.keys - b.keys)
        }

        public var description: String {
            "\(steps) VM steps, \(pages) pages, \(statements) statements, \(rowsRead) rows and \(bytesRead) bytes read, \(rowsWritten) rows written, "
                + "\(recordsDecoded) records (\(bytesDecoded) bytes) and \(sessionsDecoded) sessions decoded, \(keys) keys"
        }
    }

    /// A b-tree read whole: the database it is in on its connection (`main`, `temp` or an attached name) and its table.
    public struct Scan: Sendable, Hashable, CustomStringConvertible {
        public var schema: String
        public var table: String
        public var description: String { schema == "main" ? table : "\(schema).\(table)" }
    }

    /// A statement as explained on the connection that ran it.
    public struct Plan: Sendable, Hashable {
        public var operation: String
        public var connection: String
        /// The connection's databases and their schema versions when it was explained.
        public var schema: String
        public var sql: String
        /// The tables (an index read whole counted as its table's) the statement reads whole.
        public var scans: [Scan]
        /// Why it could not be explained there (nil: explained).
        public var failure: String?
    }

    private struct State {
        var totals = Totals()
        var recording = false
        var operation = ""
        var statements: Set<String> = []
        var steps: [String: Int64] = [:]
        var explained: Set<String> = []
        var plans: [Plan] = []
    }

    private let enabledFlag = Atomic<Bool>(false)
    private let connections = Atomic<Int>(0)
    private let state = Mutex(State())

    /// Whether statements are measured (each costs a page-status read only then).
    public var enabled: Bool { enabledFlag.load(ordering: .relaxed) }

    public func setEnabled(_ on: Bool) { enabledFlag.store(on, ordering: .relaxed) }

    /// A number for a newly opened connection, unique in the process: its plans' identity (two connections to files of
    /// the same name stay apart).
    public func connectionNumber() -> Int { connections.wrappingAdd(1, ordering: .relaxed).newValue }

    public var totals: Totals { state.withLock { $0.totals } }

    /// Starts keeping and explaining every distinct statement run (cleared).
    public func startRecordingStatements() {
        state.withLock { $0.recording = true; $0.statements = []; $0.steps = [:]; $0.explained = []; $0.plans = [] }
    }

    /// The operation the next statements belong to (their plans are labelled with it).
    public func setOperation(_ name: String) { state.withLock { $0.operation = name } }

    /// The VM steps of each statement run since recording started (for a budget's diagnosis).
    public var stepsByStatement: [String: Int64] { state.withLock { $0.steps } }

    /// The statements run since recording started; recording stops.
    public func takeStatements() -> Set<String> {
        state.withLock { state in
            defer { state.recording = false; state.statements = [] }
            return state.statements
        }
    }

    /// The statements explained since recording started, with their operations and connections; recording stops.
    public func takePlans() -> [Plan] {
        state.withLock { state in
            defer { state.recording = false; state.statements = []; state.plans = []; state.explained = [] }
            return state.plans
        }
    }

    var recording: Bool { state.withLock { $0.recording } }

    func add(sql: String, steps: Int64, pages: Int64, rows: Int64, bytes: Int64, written: Int64 = 0) {
        state.withLock { state in
            state.totals.statements += 1
            state.totals.steps += steps
            state.totals.pages += pages
            state.totals.rowsRead += rows
            state.totals.bytesRead += bytes
            state.totals.rowsWritten += written
            if state.recording { state.statements.insert(sql); state.steps[sql, default: 0] += steps }
        }
    }

    func noteSessionsDecoded(_ count: Int) {
        guard enabled, count > 0 else { return }
        state.withLock { $0.totals.sessionsDecoded += Int64(count) }
    }

    /// A record decoded on the host (an episode, a feed, protocol JSON) of `bytes` bytes.
    func noteDecoded(bytes: Int) {
        guard enabled else { return }
        state.withLock { $0.totals.recordsDecoded += 1; $0.totals.bytesDecoded += Int64(bytes) }
    }

    /// A change set built with `keys` keys.
    func noteKeys(_ keys: Int) {
        guard enabled, keys > 0 else { return }
        state.withLock { $0.totals.keys += Int64(keys) }
    }

    /// Explains `sql` on `handle` (the connection that runs it, `connection` its label with its number), from its
    /// bytecode, while recording: once per operation, connection and schema.
    func explain(_ sql: String, handle: OpaquePointer, connection: String) {
        guard let operation = state.withLock({ $0.recording ? $0.operation : nil }) else { return }
        let schema: (key: String, label: String)
        do { schema = try Self.schema(handle) } catch { schema = ("?", "unknown (\(error))") }
        let key = [operation, connection, schema.key, sql].joined(separator: "\u{1}")
        guard !state.withLock({ $0.explained.contains(key) }) else { return }
        let plan: Plan
        do { plan = Plan(operation: operation, connection: connection, schema: schema.label, sql: sql, scans: try Self.scans(sql, handle: handle), failure: nil) }
        catch { plan = Plan(operation: operation, connection: connection, schema: schema.label, sql: sql, scans: [], failure: "\(error)") }
        state.withLock { if $0.explained.insert(key).inserted { $0.plans.append(plan) } }
    }

    struct ExplainFailure: Error, CustomStringConvertible { var description: String }

    private static func rows(_ handle: OpaquePointer, _ text: String) throws -> [[String?]] {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, text, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw ExplainFailure(description: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        var result: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) }
            })
        }
        return result
    }

    /// The connection's schema: each database's name, file and schema version (the key), and names and versions (the label).
    static func schema(_ handle: OpaquePointer) throws -> (key: String, label: String) {
        var key: [String] = [], label: [String] = []
        for row in try rows(handle, "PRAGMA database_list") {
            guard let name = row[1] else { continue }
            let version = try rows(handle, "PRAGMA \"\(name.replacingOccurrences(of: "\"", with: "\"\""))\".schema_version").first?.first.flatMap { $0 } ?? "?"
            key.append("\(name)=\(row[2] ?? "")@\(version)")
            label.append("\(name)@\(version)")
        }
        return (key.joined(separator: "\u{2}"), label.joined(separator: " "))
    }

    /// The tables `sql` reads whole on this connection: each cursor its bytecode opens on a table or index b-tree and
    /// rewinds to read from the start, resolved through the schema of the database it is in (by root page).
    static func scans(_ sql: String, handle: OpaquePointer) throws -> [Scan] {
        let head = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        for word in ["PRAGMA", "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE", "EXPLAIN", "CREATE", "DROP", "ATTACH", "DETACH", "VACUUM", "ANALYZE"]
        where head.hasPrefix(word) { return [] }
        // Databases on this connection, and each one's b-trees by root page.
        var names: [Int: String] = [:]
        for row in try rows(handle, "PRAGMA database_list") { if let seq = row[0].flatMap(Int.init), let name = row[1] { names[seq] = name } }
        var trees: [Int: [Int: String]] = [:]
        for (seq, name) in names {
            let master = name == "temp" ? "sqlite_temp_master" : "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\".sqlite_master"
            for row in try rows(handle, "SELECT rootpage, tbl_name FROM \(master) WHERE rootpage IS NOT NULL AND rootpage > 0") {
                if let page = row[0].flatMap(Int.init), let table = row[1] { trees[seq, default: [:]][page] = table }
            }
        }
        // The bytecode: addr, opcode, p1, p2, p3, p4, p5, comment. Trigger programs follow the main program, each from
        // address 0 with cursors of its own.
        var result = Set<Scan>()
        var cursors: [Int: Scan] = [:], rewound: Set<Int> = []
        func close() {
            result.formUnion(rewound.compactMap { cursors[$0] })
            cursors = [:]; rewound = []
        }
        for row in try rows(handle, "EXPLAIN " + sql) {
            if row[0] == "0" { close() }
            guard let opcode = row[1], let p1 = row[2].flatMap(Int.init) else { continue }
            switch opcode {
            case "OpenRead", "OpenWrite":
                if let page = row[3].flatMap(Int.init), let database = row[4].flatMap(Int.init), let table = trees[database]?[page] {
                    cursors[p1] = Scan(schema: names[database] ?? "?", table: table)
                }
            case "Rewind", "Last", "Count":
                rewound.insert(p1)
            default:
                break
            }
        }
        close()
        return result.sorted { ($0.schema, $0.table) < ($1.schema, $1.table) }
    }
}

extension JSONDecoder {
    /// A library row's record (an episode, a feed) decoded, counted by the work meter.
    static func libraryRecord<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        SQLWorkMeter.shared.noteDecoded(bytes: data.count)
        return try JSONDecoder().decode(type, from: data)
    }
}
