import Foundation
import SQLite3
import SQLiteBudget

/// Bulk synchronization writes under a byte budget (the `ntp-budget` VFS): a snapshot's archive batches, its staging and
/// build, and the publication through its COMMIT. Each write that would extend the database's files past the budget is
/// refused before it happens, the transaction rolls back, and the work stops with `ServerInsufficientSpace`; the
/// free space the app keeps for its own writes is never used. Unarmed, the VFS only delegates.
enum SQLiteWriteBudget {
    /// The VFS name the library's and the sync engine's connections open with (nil: the default VFS, never expected).
    static let vfs: String? = ntp_budget_register() == SQLITE_OK ? NTP_BUDGET_VFS : nil

    /// Runs `body` with `budget` bytes armed on `handle`'s main database (nil: unarmed). A refused write, or the disk
    /// itself full, becomes `ServerInsufficientSpace`; what committed before a refusal stays committed (a checkpoint
    /// after COMMIT that could not finish leaves the WAL for later).
    static func run<T>(_ handle: OpaquePointer?, budget: Int64?, _ body: () throws -> T) throws -> T {
        guard let handle, let budget, ntp_budget_arm(handle, "main", max(0, budget)) == SQLITE_OK else {
            do { return try body() } catch { throw mapped(error, refused: nil, budget: 0) }
        }
        defer { ntp_budget_disarm(handle, "main") }
        do { return try body() }
        catch {
            var state = ntp_budget_state()
            let read = ntp_budget_read(handle, "main", &state) == SQLITE_OK
            throw mapped(error, refused: read && state.refused != 0 ? state : nil, budget: budget)
        }
    }

    /// What `handle`'s armed budget has charged so far (tests).
    static func state(_ handle: OpaquePointer?) -> ntp_budget_state? {
        guard let handle else { return nil }
        var state = ntp_budget_state()
        return ntp_budget_read(handle, "main", &state) == SQLITE_OK ? state : nil
    }

    private static func mapped(_ error: any Error, refused: ntp_budget_state?, budget: Int64) -> any Error {
        if let refused { return ServerInsufficientSpace(shortfall: max(1, refused.charged + refused.refused_charge - budget)) }
        if case FeedLibraryError.sqlite(let code, _) = error, code & 0xff == SQLITE_FULL {
            return ServerInsufficientSpace(shortfall: 1 << 20)
        }
        return error
    }
}
