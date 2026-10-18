import Foundation
import SQLite3
import Testing
@testable import NotTennaPodCore

/// The write gate of bulk synchronization work (`SQLiteWriteBudget`, the `ntp-budget` VFS), with real SQLite: an armed
/// budget refuses the write that would pass it before it happens, so the files never grow past the budget by more than
/// one write; the transaction rolls back and nothing of it is visible. A WAL frame's later checkpoint copy is reserved
/// when the frame is written and paid from that reserve, never charged twice: a publication that fits commits, and a
/// checkpoint after its COMMIT never turns it into a refusal. Unarmed, the VFS only delegates.
@Suite(.serialized) struct SQLiteWriteBudgetTests {
    static let row = 1 << 20

    static func database() throws -> (SyncSQLite, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WriteBudget-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("bulk.sqlite")
        let database = try SyncSQLite(url: url)
        try database.execute("PRAGMA wal_autocheckpoint = 0")
        try database.execute("CREATE TABLE rows (id INTEGER PRIMARY KEY, value BLOB NOT NULL)")
        return (database, url)
    }

    static func size(_ url: URL) -> Int64 {
        ["", "-wal", "-journal"].reduce(0) { total, suffix in
            total + ((try? FileManager.default.attributesOfItem(atPath: url.path + suffix)[.size] as? Int64) ?? 0)
        }
    }

    static func insert(_ database: SyncSQLite, rows: Int, from first: Int = 0) throws {
        try database.transaction {
            for index in first..<(first + rows) {
                try database.execute("INSERT INTO rows(id, value) VALUES (?, randomblob(?))", [.integer(Int64(index)), .integer(Int64(row))])
            }
        }
    }

    /// A large bulk write: 128 rows of 1 MiB in WAL mode against a 40 MB budget.
    @Test func aWriteThatWouldPassTheBudgetIsRefusedBeforeItHappens() throws {
        let (database, url) = try Self.database()
        defer { try? database.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = Self.size(url)
        let budget: Int64 = 40_000_000
        #expect(throws: ServerInsufficientSpace.self) {
            try database.withWriteBudget(budget) { try Self.insert(database, rows: 128) }
        }
        let grown = Self.size(url) - before
        // Each WAL byte is charged twice (its later checkpoint copy): its growth stays within half the budget plus a frame.
        #expect(grown <= budget / 2 + 4_096 + 24, "grew \(grown) bytes")
        #expect(try database.scalar("SELECT count(*) FROM rows") == 0, "rolled back: nothing of it is visible")
        // The same work fits once it may: the gate only refuses, it never changes what is written.
        try database.withWriteBudget(400_000_000) { try Self.insert(database, rows: 16) }
        #expect(try database.scalar("SELECT count(*) FROM rows") == 16)
    }

    /// A publication that fits commits; the checkpoint copy after its COMMIT is paid from the frames' reserve and
    /// never charged again, so it is not refused; and a checkpoint that cannot finish never reports the committed
    /// publication as rolled back.
    @Test func aCheckpointAfterCommitIsPaidFromTheReserveAndNeverUndoesTheCommit() throws {
        let (database, url) = try Self.database()
        defer { try? database.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let budget: Int64 = 10 << 20
        try database.withWriteBudget(budget) {
            try Self.insert(database, rows: 4)
            #expect(try database.scalar("SELECT count(*) FROM rows") == 4, "committed")
            let committed = try #require(database.writeBudget)
            #expect(!committed.refused && committed.charged <= budget)
            try database.execute("PRAGMA wal_checkpoint(PASSIVE)")
            let checkpointed = try #require(database.writeBudget)
            #expect(!checkpointed.refused, "the copy was reserved with its frames")
            #expect(checkpointed.charged == committed.charged, "and is never charged twice")
            try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
        #expect(Self.size(url) < budget, "the files are within the budget")
        // A budget too small for the checkpoint's copy alone (frames written before it was armed): the checkpoint is
        // refused, the WAL kept for later, and the committed rows stay.
        try Self.insert(database, rows: 2, from: 4)
        try database.withWriteBudget(1 << 20) {
            _ = try? database.execute("PRAGMA wal_checkpoint(PASSIVE)")
            #expect(database.writeBudget?.refused == true, "the copy did not fit")
        }
        #expect(try database.scalar("SELECT count(*) FROM rows") == 6, "every committed row stays")
        try database.close()
        let reopened = try SyncSQLite(url: url)
        #expect(try reopened.scalar("SELECT count(*) FROM rows") == 6)
        try reopened.close()
    }

    @Test func unarmedItOnlyDelegates() throws {
        let (database, url) = try Self.database()
        defer { try? database.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Self.insert(database, rows: 8)
        #expect(try database.scalar("SELECT count(*) FROM rows") == 8)
        #expect(database.writeBudget?.charged == 0)
        // The library's own connections open through it too, and their suites run unchanged on it.
        #expect(SQLiteWriteBudget.vfs == "ntp-budget")
    }

    /// Another writer takes free space between two arms: each arm reads free space anew, so the second step's budget is
    /// smaller and it stops before the reserve.
    @Test func eachArmReadsFreeSpaceAgain() throws {
        let (database, url) = try Self.database()
        defer { try? database.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let free = ServerSnapshotSpoolTests.FreeSpace((1 << 30) + (64 << 20) + (20 << 20))
        let policy = ServerBulkDiskPolicy(available: { _ in free.value })
        try database.withWriteBudget(policy.budget(at: url)) { try Self.insert(database, rows: 4) }
        free.value = (1 << 30) + (64 << 20) + (2 << 20)
        #expect(throws: ServerInsufficientSpace.self) {
            try database.withWriteBudget(policy.budget(at: url)) { try Self.insert(database, rows: 8, from: 4) }
        }
        #expect(try database.scalar("SELECT count(*) FROM rows") == 4)
    }

    /// Checkpoint copies still owed outlive the step that reserved them: a reader holds the copies back while bulk
    /// batches commit one after another (each armed with what is left of the allowance, the writer reopened between
    /// them); once the reader ends, an ordinary write's checkpoint makes the copies. Everything bulk work caused,
    /// copies included, stays within the allowance, so the reserve is intact.
    @Test func reservationsOutliveTheirArmUntilTheCheckpointPaysThem() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WriteBudget-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("bulk.sqlite")
        var writer = try SyncSQLite(url: url)
        try writer.execute("CREATE TABLE rows (id INTEGER PRIMARY KEY, value BLOB NOT NULL)")
        let reader = try SyncSQLite(url: url)
        defer { try? reader.close() }
        try reader.execute("BEGIN")
        _ = try reader.scalar("SELECT count(*) FROM rows")
        let start = Self.size(url)
        let allowance: Int64 = 128 << 20
        var committed = 0, refused = 0
        for batch in 0..<5 {
            let budget = allowance - (Self.size(url) - start)
            do {
                try writer.withWriteBudget(budget) { try Self.insert(writer, rows: 20, from: batch * 20) }
                committed += 1
            } catch is ServerInsufficientSpace { refused += 1 }
            try writer.close()
            writer = try SyncSQLite(url: url)
        }
        try reader.execute("COMMIT")
        try writer.execute("INSERT INTO rows(id, value) VALUES (1000, x'00')")
        try writer.execute("PRAGMA wal_checkpoint(PASSIVE)")
        let grown = Self.size(url) - start
        #expect(refused > 0 && committed > 0, "\(committed) committed, \(refused) refused")
        #expect(grown <= allowance + (1 << 20), "bulk work and its checkpoint copies grew \(grown) bytes of an allowance of \(allowance)")
        #expect(try writer.scalar("SELECT count(*) FROM rows") == Int64(committed * 20 + 1))
        try writer.close()
    }

    /// Growth SQLite or the system asks for directly (an extending truncation, a size hint with a chunk size) is charged
    /// before it happens and refused when it does not fit.
    @Test func extendingTruncationsAndSizeHintsAreChargedFirst() throws {
        let (database, url) = try Self.database()
        defer { try? database.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let handle = try #require(database.connectionForTesting)
        var pointer: UnsafeMutableRawPointer?
        #expect(sqlite3_file_control(handle, "main", SQLITE_FCNTL_FILE_POINTER, &pointer) == SQLITE_OK)
        let file = try #require(pointer?.assumingMemoryBound(to: sqlite3_file.self))
        func size() -> Int64 { var value: sqlite3_int64 = 0; _ = file.pointee.pMethods.pointee.xFileSize(file, &value); return value }
        let before = size()
        try database.withWriteBudget(0) {
            #expect(file.pointee.pMethods.pointee.xTruncate(file, 8 << 20) == SQLITE_FULL)
            #expect(size() == before, "not extended")
            var chunk: Int32 = 16 << 20
            _ = sqlite3_file_control(handle, "main", SQLITE_FCNTL_CHUNK_SIZE, &chunk)
            var hint: sqlite3_int64 = 32 << 20
            #expect(sqlite3_file_control(handle, "main", SQLITE_FCNTL_SIZE_HINT, &hint) == SQLITE_FULL)
            #expect(size() == before, "no preallocation")
            #expect(database.writeBudget?.refused == true)
        }
        // Within a budget it is charged, and later writes inside it cost nothing more.
        try database.withWriteBudget(64 << 20) {
            #expect(file.pointee.pMethods.pointee.xTruncate(file, before + (4 << 20)) == SQLITE_OK)
            let charged = try #require(database.writeBudget?.charged)
            #expect(charged >= 4 << 20 && charged <= 33 << 20, "\(charged)")
        }
        var chunk: Int32 = 0
        _ = sqlite3_file_control(handle, "main", SQLITE_FCNTL_CHUNK_SIZE, &chunk)
    }

    /// Frames written over WAL space the file already had (after the WAL started again) still reserve their copy: a
    /// second batch whose copy would not fit is refused before it commits, so bulk work never grows past its allowance.
    @Test func framesWrittenOverOldWALSpaceStillReserveTheirCopy() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WriteBudget-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("bulk.sqlite")
        let writer = try SyncSQLite(url: url)
        defer { try? writer.close() }
        try writer.execute("CREATE TABLE rows (id INTEGER PRIMARY KEY, value BLOB NOT NULL)")
        _ = try writer.rows("PRAGMA journal_size_limit = -1")
        // An ordinary 40 MiB write, checkpointed: the WAL file keeps its size, the next frames go over that space.
        try Self.insert(writer, rows: 40, from: 0)
        try writer.execute("PRAGMA wal_checkpoint(PASSIVE)")
        let start = Self.size(url)
        let allowance: Int64 = 30 << 20
        var committed = 0
        for batch in 0..<2 {
            let budget = allowance - (Self.size(url) - start)
            do {
                try writer.withWriteBudget(budget) { try Self.insert(writer, rows: 20, from: 100 + batch * 20) }
                committed += 1
            } catch is ServerInsufficientSpace {}
        }
        try writer.execute("PRAGMA wal_checkpoint(PASSIVE)")
        let grown = Self.size(url) - start
        #expect(committed == 1, "the second batch's copy did not fit: \(committed) committed")
        #expect(grown <= allowance + (1 << 20), "grew \(grown) bytes of an allowance of \(allowance)")
    }

    /// The app is killed with committed bulk frames still in the WAL (its files as they were, copied while the writer and
    /// a reader holding the copies back were open): when the database is opened again, the surviving WAL's checkpoint
    /// copies are still owed, so new bulk work and the copies together stay within the allowance.
    @Test func aWALThatSurvivedTheProcessIsReservedWhenOpenedAgain() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WriteBudget-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("bulk.sqlite"), killed = folder.appendingPathComponent("killed.sqlite")
        let writer = try SyncSQLite(url: url)
        try writer.execute("CREATE TABLE rows (id INTEGER PRIMARY KEY, value BLOB NOT NULL)")
        let reader = try SyncSQLite(url: url)
        try reader.execute("BEGIN")
        _ = try reader.scalar("SELECT count(*) FROM rows")
        let start = Self.size(url)
        let allowance: Int64 = 128 << 20
        try writer.withWriteBudget(allowance) { try Self.insert(writer, rows: 40, from: 0) }
        // The files a killed process leaves: the database and its WAL, nothing checkpointed, no shared memory.
        for suffix in ["", "-wal"] {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: url.path + suffix), to: URL(fileURLWithPath: killed.path + suffix))
        }
        try reader.execute("COMMIT")
        try reader.close()
        try writer.close()
        let reopened = try SyncSQLite(url: killed)
        defer { try? reopened.close() }
        #expect(try reopened.scalar("SELECT count(*) FROM rows") == 40, "the committed rows survived")
        do {
            try reopened.withWriteBudget(allowance - (Self.size(killed) - start)) { try Self.insert(reopened, rows: 40, from: 40) }
        } catch is ServerInsufficientSpace {}
        try reopened.execute("INSERT INTO rows(id, value) VALUES (1000, x'00')")
        try reopened.execute("PRAGMA wal_checkpoint(PASSIVE)")
        let grown = Self.size(killed) - start
        #expect(grown <= allowance + (1 << 20), "bulk work and its copies grew \(grown) bytes of an allowance of \(allowance)")
    }

    /// With a chunk size, the system allocates whole chunks: a truncation or size hint whose request fits but whose
    /// chunk does not is refused before anything is allocated.
    @Test func chunkRoundingIsChargedBeforeItAllocates() throws {
        let (database, url) = try Self.database()
        defer { try? database.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let handle = try #require(database.connectionForTesting)
        var pointer: UnsafeMutableRawPointer?
        #expect(sqlite3_file_control(handle, "main", SQLITE_FCNTL_FILE_POINTER, &pointer) == SQLITE_OK)
        let file = try #require(pointer?.assumingMemoryBound(to: sqlite3_file.self))
        func size() -> Int64 { var value: sqlite3_int64 = 0; _ = file.pointee.pMethods.pointee.xFileSize(file, &value); return value }
        var chunk: Int32 = 16 << 20
        #expect(sqlite3_file_control(handle, "main", SQLITE_FCNTL_CHUNK_SIZE, &chunk) == SQLITE_OK)
        defer { var none: Int32 = 0; _ = sqlite3_file_control(handle, "main", SQLITE_FCNTL_CHUNK_SIZE, &none) }
        let before = size()
        try database.withWriteBudget(1 << 20) {
            let fits = before + (1 << 20) - 4_096
            #expect(file.pointee.pMethods.pointee.xTruncate(file, fits) == SQLITE_FULL)
            #expect(size() == before, "no chunk allocated")
            var hint: sqlite3_int64 = fits
            #expect(sqlite3_file_control(handle, "main", SQLITE_FCNTL_SIZE_HINT, &hint) == SQLITE_FULL)
            #expect(size() == before, "no chunk allocated")
        }
    }

    struct NoServer: ServerExchangeTransport {
        func send(_ method: String, _ path: String, body: ContractJSON?) async throws -> ContractJSON { throw ServerExchangeError.unreachable }
    }

    /// An attachment tried again first deletes the earlier attempt's base: that write is under the budget too, and a
    /// refusal leaves the old base as it was (rolled back).
    @Test func anAttachRetrysResetIsUnderTheBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WriteBudget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let location = LibraryLocation(root: root, reference: .server(ContractIdentity.randomUUID()))
        try location.prepare()
        let store = try FeedLibraryStore(url: location.database)
        try await store.initializeServerLibrary(ServerLibraryIdentity(libraryID: ContractIdentity.randomUUID(), serverURL: "http://127.0.0.1:1",
            serverID: nil, accountID: ContractIdentity.randomUUID(), namespace: ContractIdentity.randomUUID(), username: "alice",
            installID: ContractIdentity.randomUUID(), deviceMarker: nil))
        try await store.close()
        let seed = try LibrarySQLite(url: location.database)
        try seed.transaction {
            for index in 0..<20_000 {
                try seed.execute("INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('episode', ?, 'state', randomblob(2048), '[]')",
                                 [.text("e1:\(index)")])
            }
        }
        try seed.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try seed.close()
        var builder = ServerAttachBuilder(location: location, transport: NoServer(), vault: MemoryCredentialVault())
        var disk = ServerBulkDiskPolicy(available: { _ in ServerBulkDiskPolicy().reserve + (1 << 20) })
        disk.unknownAdmission = 0
        builder.disk = disk
        let head = try SyncCursor(logID: ContractIdentity.randomUUID(), epoch: 1, seq: 1, digest: String(repeating: "a", count: 64)).encoded
        await #expect(throws: ServerInsufficientSpace.self) {
            try await builder.build(head: head, watermark: 0, items: { _ in })
        }
        let reader = try LibrarySQLite(readingOnly: location.database)
        defer { try? reader.close() }
        #expect(try reader.scalar("SELECT count(*) FROM ntp_records") == 20_000, "the reset was refused and rolled back")
    }
}
