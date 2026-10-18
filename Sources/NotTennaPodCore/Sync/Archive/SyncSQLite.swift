import Foundation
import SQLite3

/// A plain SQLite connection for the sync engine's own files (PROTOCOL §15.2): `sync.sqlite` and the
/// shadow projections in `staging/`. Unlike `LibrarySQLite` it creates no library schema; each owner creates its own
/// tables. WAL, `synchronous = FULL`, foreign keys off (these files have none).
final class SyncSQLite {
    private var handle: OpaquePointer?
    /// This connection's number for the work meter (its plans' identity).
    private let meterNumber = SQLWorkMeter.shared.connectionNumber()

    init(url: URL, durable: Bool = true) throws {
        guard url.isFileURL, !url.path.contains("\0") else { throw FeedLibraryError.invalidLocation }
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, SQLiteWriteBudget.vfs)
        guard status == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open the sync database"
            if let connection { sqlite3_close_v2(connection) }
            throw FeedLibraryError.sqlite(code: status, message: message)
        }
        handle = connection
        sqlite3_extended_result_codes(connection, 1)
        sqlite3_busy_timeout(connection, 5_000)
        do {
            try execute("PRAGMA journal_mode = WAL")
            try execute(durable ? "PRAGMA synchronous = FULL" : "PRAGMA synchronous = OFF")
        } catch {
            sqlite3_close_v2(connection)
            handle = nil
            throw error
        }
    }

    deinit { if let handle { sqlite3_close_v2(handle) } }

    /// Runs `body` with bulk writes limited to `budget` bytes (`SQLiteWriteBudget`); nil: no limit.
    func withWriteBudget<T>(_ budget: Int64?, _ body: () throws -> T) throws -> T { try SQLiteWriteBudget.run(handle, budget: budget, body) }

    /// The armed budget's state (tests).
    var writeBudget: (charged: Int64, refused: Bool)? { SQLiteWriteBudget.state(handle).map { ($0.charged, $0.refused != 0) } }

    /// The connection (tests drive the VFS through it).
    var connectionForTesting: OpaquePointer? { handle }

    func close() throws {
        guard let handle else { return }
        let status = sqlite3_close(handle)
        guard status == SQLITE_OK else { throw failure(status) }
        self.handle = nil
    }

    func transaction<T>(write: Bool = true, _ operation: () throws -> T) throws -> T {
        try execute(write ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
            let result = try operation()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func scalar(_ sql: String, _ values: [LibrarySQLValue] = []) throws -> Int64 {
        guard let result = try rows(sql, values).first?.first?.integer else { throw FeedLibraryError.corruptRecord }
        return result
    }

    func execute(_ sql: String, _ values: [LibrarySQLValue] = []) throws { _ = try rows(sql, values) }

    /// Pages the connection fetched since it opened (page-cache hits and misses), for the work meter.
    private func pagesFetched(_ handle: OpaquePointer) -> Int64 {
        var current: Int32 = 0, highest: Int32 = 0, total: Int64 = 0
        for status in [SQLITE_DBSTATUS_CACHE_HIT, SQLITE_DBSTATUS_CACHE_MISS] {
            sqlite3_db_status(handle, status, &current, &highest, 0)
            total += Int64(current)
        }
        return total
    }

    func rows(_ sql: String, _ values: [LibrarySQLValue] = []) throws -> [[LibrarySQLValue]] {
        var results: [[LibrarySQLValue]] = []
        try forEachRow(sql, values) { results.append($0) }
        return results
    }

    /// Steps through the rows without collecting them, for large reads.
    func forEachRow(_ sql: String, _ values: [LibrarySQLValue] = [], _ body: ([LibrarySQLValue]) throws -> Void) throws {
        guard let handle else { throw FeedLibraryError.closed }
        var statement: OpaquePointer?
        let preparation = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard preparation == SQLITE_OK, let statement else { throw failure(preparation) }
        let metering = SQLWorkMeter.shared.enabled
        // Explained before it is measured: the explanation's own reads are not the statement's.
        if metering, SQLWorkMeter.shared.recording {
            let name = sqlite3_db_filename(handle, "main").map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "memory"
            SQLWorkMeter.shared.explain(sql, handle: handle, connection: "sync #\(meterNumber) \(name)")
        }
        let pagesBefore = metering ? pagesFetched(handle) : 0
        let changesBefore = metering ? sqlite3_total_changes64(handle) : 0
        var rowsRead: Int64 = 0, bytesRead: Int64 = 0
        defer {
            if metering {
                SQLWorkMeter.shared.add(sql: sql, steps: Int64(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0)),
                                        pages: pagesFetched(handle) - pagesBefore, rows: rowsRead, bytes: bytesRead,
                                        written: sqlite3_total_changes64(handle) - changesBefore)
            }
            sqlite3_finalize(statement)
        }
        guard sqlite3_bind_parameter_count(statement) == values.count else { throw FeedLibraryError.invalidMutation }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .integer(let integer): status = sqlite3_bind_int64(statement, index, integer)
            case .real(let real): status = sqlite3_bind_double(statement, index, real)
            case .text(let text):
                status = text.withCString {
                    sqlite3_bind_text64(statement, index, $0, UInt64(text.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self), UInt8(SQLITE_UTF8))
                }
            case .blob(let data):
                if data.isEmpty { status = sqlite3_bind_zeroblob(statement, index, 0) }
                else {
                    status = data.withUnsafeBytes {
                        sqlite3_bind_blob64(statement, index, $0.baseAddress, UInt64(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                }
            case .null: status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw failure(status) }
        }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw failure(status) }
            rowsRead += 1
            var row: [LibrarySQLValue] = []
            for index in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, index)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    bytesRead += Int64(count)
                    if count == 0 { row.append(.blob(Data())) }
                    else if let bytes = sqlite3_column_blob(statement, index) { row.append(.blob(Data(bytes: bytes, count: count))) }
                    else { throw FeedLibraryError.corruptRecord }
                case SQLITE_TEXT:
                    guard let bytes = sqlite3_column_text(statement, index) else { throw FeedLibraryError.corruptRecord }
                    let count = Int(sqlite3_column_bytes(statement, index))
                    bytesRead += Int64(count)
                    row.append(.text(String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)))
                case SQLITE_NULL: row.append(.null)
                default: throw FeedLibraryError.corruptRecord
                }
            }
            try body(row)
        }
    }

    private func failure(_ code: Int32) -> FeedLibraryError {
        .sqlite(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "The sync database is closed")
    }
}

extension LibrarySQLValue {
    var text: String? { if case .text(let value) = self { value } else { nil } }
}
