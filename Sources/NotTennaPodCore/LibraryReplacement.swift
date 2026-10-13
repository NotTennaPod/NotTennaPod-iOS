import Foundation

/// Replaces the closed live library file with a closed, fully staged one. The source deletes the live
/// database before moving the backup in (`DatabaseExporter.java:90–99`), so a failed move leaves an
/// empty library; here every step is a same-directory rename with rollback, and the replaced file is
/// removed only after the new one opens as a valid library. Stale `-wal`/`-shm` files never remain
/// beside the new database (the reason the source deletes side files).
public enum LibraryReplacement {
    public typealias Move = @Sendable (URL, URL) throws -> Void

    static let suffixes = ["", "-wal", "-shm", "-journal"]

    public static func replace(live: URL, with staged: URL,
                               move: Move = { try FileManager.default.moveItem(at: $0, to: $1) }) async throws {
        let fileManager = FileManager.default
        func file(_ base: URL, _ suffix: String) -> URL { URL(fileURLWithPath: base.path + suffix) }
        let backup = URL(fileURLWithPath: live.path + ".pre-restore")
        guard fileManager.fileExists(atPath: staged.path) else { throw CocoaError(.fileNoSuchFile) }
        for suffix in suffixes { try? fileManager.removeItem(at: file(backup, suffix)) }
        var movedAside: [String] = [], movedIn: [String] = []
        do {
            for suffix in suffixes where fileManager.fileExists(atPath: file(live, suffix).path) {
                try move(file(live, suffix), file(backup, suffix)); movedAside.append(suffix)
            }
            for suffix in suffixes where fileManager.fileExists(atPath: file(staged, suffix).path) {
                try move(file(staged, suffix), file(live, suffix)); movedIn.append(suffix)
            }
            let check = try FeedLibraryStore(url: live)
            try await check.close()
        } catch {
            // Roll back: nothing of the staged library stays at the live path; the old files return.
            // Only files this attempt moved are touched; a live file that never moved stays in place.
            for suffix in movedIn { try? fileManager.removeItem(at: file(live, suffix)) }
            for suffix in movedAside.reversed() { try? fileManager.moveItem(at: file(backup, suffix), to: file(live, suffix)) }
            throw error
        }
        for suffix in suffixes { try? fileManager.removeItem(at: file(backup, suffix)) }
    }

    /// Launch after an interruption during `replace`: if the live file never arrived the replaced
    /// library returns; otherwise the new library is live and the leftover old files are removed.
    /// Every step is checked: when the replaced library cannot be returned now (a refused rename, files that cannot
    /// be examined) this throws, so the start waits instead of creating an empty database in its place, and the backup
    /// stays. Its side files are returned before its main file, so a live main file means the return completed.
    public static func recoverInterrupted(live: URL) throws {
        let fileManager = FileManager.default
        func file(_ base: URL, _ suffix: String) -> URL { URL(fileURLWithPath: base.path + suffix) }
        let backup = URL(fileURLWithPath: live.path + ".pre-restore")
        guard try SavedState.isPresent(backup) else { return }
        if !(try SavedState.isPresent(live)) {
            for suffix in suffixes.dropFirst() + [""] where try SavedState.isPresent(file(backup, suffix)) {
                if try SavedState.isPresent(file(live, suffix)) { try fileManager.removeItem(at: file(live, suffix)) }
                try fileManager.moveItem(at: file(backup, suffix), to: file(live, suffix))
            }
        } else {
            for suffix in suffixes { try? fileManager.removeItem(at: file(backup, suffix)) }
        }
    }
}
