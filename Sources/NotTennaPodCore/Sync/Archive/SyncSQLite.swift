import Foundation
import SQLite3

/// A plain SQLite connection for the sync engine's own files (PROTOCOL §15.2): `sync.sqlite` and the
/// shadow projections in `staging/`. Unlike `LibrarySQLite` it creates no library schema; each owner creates its own
/// tables. WAL, `synchronous = FULL`, foreign keys off (these files have none).
final class SyncSQLite {
    private var handle: OpaquePointer?

    init(url: URL, durable: Bool = true) throws {
        guard url.isFileURL, !url.path.contains("\0") else { throw FeedLibraryError.invalidLocation }
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
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
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_parameter_count(statement) == values.count else { throw FeedLibraryError.invalidMutation }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .integer(let integer): status = sqlite3_bind_int64(statement, index, integer)
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
            var row: [LibrarySQLValue] = []
            for index in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, index)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    if count == 0 { row.append(.blob(Data())) }
                    else if let bytes = sqlite3_column_blob(statement, index) { row.append(.blob(Data(bytes: bytes, count: count))) }
                    else { throw FeedLibraryError.corruptRecord }
                case SQLITE_TEXT:
                    guard let bytes = sqlite3_column_text(statement, index) else { throw FeedLibraryError.corruptRecord }
                    let count = Int(sqlite3_column_bytes(statement, index))
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
