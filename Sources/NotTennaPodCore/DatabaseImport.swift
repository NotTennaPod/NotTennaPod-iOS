import Foundation
import Synchronization
import os

/// An interrupted database import's durable record, one file per attempt in `Database Imports/` of the root
/// folder (Application Support), written before anything is staged. It names the staging folder and the library the
/// import replaces, and journals the feed credentials as two kinds: those the import created in the Keychain (each one
/// before it is written), and the live library's own, which the new library retires only after a successful
/// publication and which nothing here ever removes. Paths are relative to the root folder.
public struct DatabaseImportJournal: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// The staged library is being built; the live library is unchanged.
        case staging
        /// The files are being swapped (`LibraryReplacement`); the outcome is read from the target's identity.
        case committing
        /// The new library is live.
        case published
    }

    public var attempt: UUID
    public var phase: Phase
    public var staging: String
    /// The live library's database: the one the import replaces.
    public var target: String
    public var liveIdentity: String
    public var stagedIdentity: String?
    /// Keychain items the import created for the staged library.
    public var created: [UUID] = []
    /// The live library's credentials, queued in the staged library for retirement after publication.
    public var retired: [UUID] = []
    /// The replaced library's downloads and stream cache: moved aside into the staging folder once the new library is
    /// live, before anything opens it, and removed with that folder.
    public var replacedFolders: [String] = []
    /// They were moved aside: what the paths hold from then on is the new library's, never removed here.
    public var replacedSetAside = false
    /// The decided outcome, saved once: a later library layout (a Keep moving the library) never recomputes it.
    public var outcome: PendingNotice.Kind?
    /// The outcome was recorded durably for the person (`PendingNotices`), until it is actually presented.
    public var reported = false

    public static let folderName = "Database Imports"
    public static func folder(root: URL) -> URL { root.appendingPathComponent(folderName, isDirectory: true) }

    static func relative(_ url: URL, root: URL) throws -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(base + "/") else { throw FeedLibraryError.invalidLocation }
        return String(path.dropFirst(base.count + 1))
    }
    static func absolute(_ path: String, root: URL) -> URL { root.appendingPathComponent(path) }

    func write(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
}

/// The import stopped before its commit because its background time ended (or it could not continue): nothing was
/// changed.
public struct DatabaseImportInterrupted: Error, Equatable, Sendable { public init() {} }

/// One database import's staging, commit and cleanup, journaled so that an interruption at any point is either
/// completed or rolled back. Cleanup removes only what the import created (secrets not reachable from the library it
/// leaves live, its staging folder); a step that cannot be done now (a locked Keychain, files that cannot be read)
/// keeps the journal for a later graph start. The caller holds the library gate and stops the graph for the commit.
public actor DatabaseImportAttempt {
    public nonisolated let root: URL
    public nonisolated let staging: URL
    public nonisolated var stagedDatabase: URL { staging.appendingPathComponent(LibraryLocation.databaseName) }
    private let file: URL
    private let vault: any SynchronizationCredentialStore
    private let notices: PendingNotices
    private var journal: DatabaseImportJournal
    /// This attempt: its outcome's pending notice is acknowledged by it when the import's dialog appears.
    public nonisolated let attempt: UUID
    /// Imports this process is running: a graph start meanwhile (a switch, a restart) never takes them for interrupted.
    static let inProgress = Mutex<Set<UUID>>([])
    /// Tests: the process ended (what it was running is now an interrupted import).
    static func simulateProcessEnd() { inProgress.withLock { $0 = [] } }

    /// Journals the attempt before anything is staged. `folder` holds the staging folder; `live` is the library's
    /// database the import replaces.
    public init(root: URL, folder: URL, live: URL, liveIdentity: String, vault: any SynchronizationCredentialStore,
                notices: PendingNotices) throws {
        let attempt = UUID()
        self.attempt = attempt
        self.root = root; self.vault = vault; self.notices = notices
        staging = folder.appendingPathComponent("restore-staging-\(attempt.uuidString)", isDirectory: true)
        file = DatabaseImportJournal.folder(root: root).appendingPathComponent(attempt.uuidString + ".json")
        journal = DatabaseImportJournal(attempt: attempt, phase: .staging,
            staging: try DatabaseImportJournal.relative(staging, root: root),
            target: try DatabaseImportJournal.relative(live, root: root), liveIdentity: liveIdentity)
        Self.inProgress.withLock { _ = $0.insert(attempt) }
        try journal.write(to: file)
    }

    /// The journal as written (tests).
    public var record: DatabaseImportJournal { journal }

    /// Where a test ends the process during staging (nothing is cleaned up after it).
    enum KillPoint: Sendable { case afterBackupRead, afterCarryOver, afterCredentials, afterRetiringOldCredentials }
    struct SimulatedKill: Error {}

    /// Staging, then the exclusive library gate for the commit: what background time may end. Cancelled, it throws
    /// with nothing held; the caller rolls back.
    public func prepareCommit(backup: URL, live: FeedLibraryStore, gate: LibraryGate) async throws {
        try await stage(backup: backup, live: live)
        try await gate.acquireExclusiveUnlessCancelled()
    }

    /// Validates and converts the backup into a complete staged library carrying `live`'s kept state, with the
    /// backup's feed credentials in the Keychain under the staged library's own IDs and the live library's queued for
    /// retirement after publication. Cancellation stops it between steps.
    public func stage(backup: URL, live: FeedLibraryStore) async throws {
        try await stage(backup: backup, live: live, killedAt: nil)
    }

    func stage(backup: URL, live: FeedLibraryStore, killedAt kill: KillPoint?) async throws {
        try Task.checkCancellation()
        let source = staging.appendingPathComponent("source", isDirectory: true)
        let restored = try await Task.detached(priority: .userInitiated) {
            try AndroidDatabaseRestore.read(backup, staging: source)
        }.value
        if kill == .afterBackupRead { throw SimulatedKill() }
        try Task.checkCancellation()
        let carry = try await live.restoreCarryOver()
        // Journaled before the staged library queues them: they are the live library's, never the import's to remove.
        journal.retired = carry.credentialIDs
        try save()
        let staged = try FeedLibraryStore(url: stagedDatabase)
        do {
            journal.stagedIdentity = staged.identityAtOpen?.identity
            try save()
            try await staged.installRestoredLibrary(restored, carrying: carry)
            if kill == .afterCarryOver { throw SimulatedKill() }
            let credentials = FeedAuthentication(store: staged, vault: vault, created: { [weak self] id in
                guard let self else { throw CancellationError() }
                try await self.recordCreated(id)
            })
            for (feedID, value) in restored.credentials.sorted(by: { $0.key < $1.key }) {
                try Task.checkCancellation()
                try await credentials.save(value, feedID: feedID)
            }
            if kill == .afterCredentials { throw SimulatedKill() }
            try Task.checkCancellation()
            try await staged.retireReplacedCredentials(carry.credentialIDs)
            if kill == .afterRetiringOldCredentials { throw SimulatedKill() }
            try await staged.close()
        } catch {
            try? await staged.close()
            throw error
        }
    }

    /// Journaled before the Keychain item is written, so no secret the import created is ever unknown.
    private func recordCreated(_ id: UUID) throws {
        journal.created.append(id)
        try save()
    }

    /// The commit, with the gate held and the graph stopped: journaled, then the staged library replaces `target`
    /// (the live database, or where a pending Keep publishes it). Throws after a rollback: the live library is unchanged.
    public func commit(target: URL, replacedFolders: [URL]) async throws {
        try markCommitting(target: target, replacedFolders: replacedFolders)
        try await LibraryReplacement.replace(live: target, with: stagedDatabase)
        journal.phase = .published
        // Should this fail, the next graph start finds the staged library live and completes the import.
        try? save()
    }

    func markCommitting(target: URL, replacedFolders: [URL]) throws {
        journal.phase = .committing
        journal.target = try DatabaseImportJournal.relative(target, root: root)
        journal.replacedFolders = try replacedFolders.map { try DatabaseImportJournal.relative($0, root: root) }
        try save()
    }

    /// After publication, before the graph starts again: the outcome is kept for the person until the import's dialog
    /// (or, if the app ends first, a later launch) shows it; the replaced library's downloads and stream cache are moved
    /// aside and go with the staging folder, then the journal.
    /// When the outcome cannot be recorded now, nothing is cleaned up and the journal stays, with its outcome: the next
    /// graph start records it before anything opens.
    public func finish() {
        settle(.importCompleted) { journal in
            try DatabaseImportRecovery.complete(&journal, root: root, file: file, notices: notices)
        }
    }

    private func settle(_ outcome: PendingNotice.Kind, cleanup: (inout DatabaseImportJournal) throws -> Void) {
        let log = Logger(subsystem: "org.nottennapod.app", category: "Restore")
        defer { _ = Self.inProgress.withLock { $0.remove(journal.attempt) } }
        journal.outcome = outcome
        try? save() // Without it the next start decides the same from the phase and the libraries.
        do { try DatabaseImportRecovery.record(outcome, for: &journal, notices: notices, file: file) }
        catch { log.error("Import outcome kept in its journal for the next start"); return }
        do { try cleanup(&journal) } catch { log.error("Import cleanup retained for the next start") }
    }

    /// Before publication, or after a replacement that rolled back: the outcome is kept for the person as for `finish`;
    /// only the secrets the import created that no library on the device reaches go, and the staging folder. When the
    /// Keychain or the files cannot be reached now, the journal stays and the next graph start finishes it.
    public func rollBack() {
        settle(.importRolledBack) { journal in
            try DatabaseImportRecovery.rollBack(journal, root: root, vault: vault, file: file, notices: notices)
        }
    }

    private func save() throws { try journal.write(to: file) }
}

/// At every graph start, before any library is opened, moved or migrated: each interrupted import is completed (its
/// staged library, found by identity, became a library on this device) or rolled back (it did not), as
/// `DatabaseImportAttempt` would have. Its outcome is recorded in `PendingNotices` before anything is resolved. The
/// decision needs its evidence: a journal or a library identity that cannot be read now is thrown, so the start waits
/// and nothing can move the imported library before its import is decided. No library is changed here, no
/// credential any library on the device reaches is removed, and nothing that a library may use after its graph opens is
/// ever swept.
public enum DatabaseImportRecovery {
    public static func recover(root: URL, vault: any SynchronizationCredentialStore, notices: PendingNotices) throws {
        let folder = DatabaseImportJournal.folder(root: root)
        let log = Logger(subsystem: "org.nottennapod.app", category: "Restore")
        guard try SavedState.isPresent(folder) else { return }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let running = DatabaseImportAttempt.inProgress.withLock { $0 }
        for name in names.sorted() where name.hasSuffix(".json") {
            if let attempt = UUID(uuidString: String(name.dropLast(5))), running.contains(attempt) { continue }
            let file = folder.appendingPathComponent(name)
            // Cannot be read now (before the first unlock): the start waits for it.
            guard let data = try SavedState.contents(of: file) else { continue }
            guard var journal = try? JSONDecoder().decode(DatabaseImportJournal.self, from: data) else {
                // Written atomically, so never partial; a damaged one names nothing that could be removed safely.
                log.error("Unreadable import journal set aside")
                try? FileManager.default.removeItem(at: file)
                continue
            }
            let target = DatabaseImportJournal.absolute(journal.target, root: root)
            let outcome: PendingNotice.Kind
            if let decided = journal.outcome {
                outcome = decided
            } else {
                switch journal.phase {
                case .staging: outcome = .importRolledBack
                case .published: outcome = .importCompleted
                case .committing:
                    try LibraryReplacement.recoverInterrupted(live: target)
                    outcome = try importedLibraryExists(journal, target: target, root: root) ? .importCompleted : .importRolledBack
                }
                // Decided once, durably, before anything can move a library (or the start waits).
                journal.outcome = outcome
                try journal.write(to: file)
            }
            // Before anything opens the imported library, the replaced one's files leave its paths (or the start waits).
            if outcome == .importCompleted { try setAside(&journal, root: root, file: file) }
            // Recorded for the person before anything can move a library: when it cannot be saved now, the start waits.
            try record(outcome, for: &journal, notices: notices, file: file)
            do {
                if outcome == .importCompleted {
                    log.notice("An interrupted database import was completed")
                    try complete(&journal, root: root, file: file, notices: notices)
                } else {
                    log.notice("An interrupted database import was rolled back")
                    try rollBack(journal, root: root, vault: vault, file: file, notices: notices)
                }
            } catch {
                log.error("Import cleanup retained for retry")
            }
        }
    }

    /// The outcome is recorded for the person once, before the journal says so. Throws when it cannot be saved now.
    static func record(_ outcome: PendingNotice.Kind, for journal: inout DatabaseImportJournal, notices: PendingNotices,
                       file: URL) throws {
        guard !journal.reported else { return }
        try notices.add(PendingNotice(id: journal.attempt, kind: outcome))
        journal.reported = true
        // Should this fail, recording again adds nothing: the store keeps an acknowledged attempt until it is resolved.
        try? journal.write(to: file)
    }

    /// The staged library became a library on this device: at the target, or wherever it moved since (a Keep archives
    /// the library it replaces into `Previous Libraries/`). Every library's identity is read: one that cannot be read now
    /// is thrown (an unread candidate is no proof of absence); only a database confirmed damaged is passed over.
    static func importedLibraryExists(_ journal: DatabaseImportJournal, target: URL, root: URL) throws -> Bool {
        guard let staged = journal.stagedIdentity else { return false }
        let candidates = [target] + (try LibraryLocation.all(root: root).map(\.database))
            + (try PreviousLibraryLocation.all(root: root).map(\.database))
        for database in candidates {
            guard try SavedState.isPresent(database) else { continue }
            do { if try LibraryDatabaseInspection.identity(of: database)?.identity == staged { return true } }
            catch where SavedState.isCorrupt(error) { continue }
        }
        return false
    }

    /// After publication: the replaced library's downloads and stream cache are moved aside into the staging folder (only
    /// while the imported library is still the one at their paths, and before it opens), then the staging folder and the
    /// journal go. The removal only ever reaches what was moved aside.
    static func complete(_ journal: inout DatabaseImportJournal, root: URL, file: URL, notices: PendingNotices) throws {
        try setAside(&journal, root: root, file: file)
        let staging = DatabaseImportJournal.absolute(journal.staging, root: root)
        if try SavedState.isPresent(staging) { try FileManager.default.removeItem(at: staging) }
        try FileManager.default.removeItem(at: file)
        try? notices.resolved(journal.attempt)
    }

    /// The replaced library's downloads and stream cache leave their paths into the staging folder, once.
    static func setAside(_ journal: inout DatabaseImportJournal, root: URL, file: URL) throws {
        let staging = DatabaseImportJournal.absolute(journal.staging, root: root)
        if !journal.replacedSetAside {
            let target = DatabaseImportJournal.absolute(journal.target, root: root)
            let ownsPaths = try SavedState.isPresent(target)
                && (try LibraryDatabaseInspection.identity(of: target)?.identity) == journal.stagedIdentity
            if ownsPaths {
                for (index, path) in journal.replacedFolders.enumerated() {
                    let live = DatabaseImportJournal.absolute(path, root: root)
                    let retired = staging.appendingPathComponent("retired-\(index)", isDirectory: true)
                    // Already moved (an earlier attempt ended between the move and the record): the path holds the new one.
                    if try !SavedState.isPresent(retired), try SavedState.isPresent(live) {
                        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                        try FileManager.default.moveItem(at: live, to: retired)
                    }
                    if try !SavedState.isPresent(live) { try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true) }
                }
            }
            // Moved aside, or the paths belong to another library now: nothing at them is this import's to remove.
            journal.replacedSetAside = true
            try journal.write(to: file)
        }
    }

    /// Only the secrets the import created that no library on the device reaches (its own database, every server and
    /// previous library, and the live library's credentials journaled before staging), then the staging folder and the
    /// journal. Throws, keeping the journal, when any library or the Keychain cannot be read now.
    static func rollBack(_ journal: DatabaseImportJournal, root: URL, vault: any SynchronizationCredentialStore, file: URL,
                         notices: PendingNotices) throws {
        var databases = [DatabaseImportJournal.absolute(journal.target, root: root)]
        databases += try LibraryLocation.all(root: root).map(\.database)
        databases += try PreviousLibraryLocation.all(root: root).map(\.database)
        var retained = Set(journal.retired)
        for database in databases { retained.formUnion(try reachableCredentials(database)) }
        for id in journal.created where !retained.contains(id) { try vault.remove(id: id) }
        let staging = DatabaseImportJournal.absolute(journal.staging, root: root)
        if try SavedState.isPresent(staging) { try FileManager.default.removeItem(at: staging) }
        try FileManager.default.removeItem(at: file)
        try? notices.resolved(journal.attempt)
    }

    /// Every credential the library's database names: its feeds', its pending cleanup's and a server library's
    /// secrets. Throws when the database cannot be read now; an absent one names none.
    static func reachableCredentials(_ database: URL) throws -> Set<UUID> {
        guard try SavedState.isPresent(database) else { return [] }
        let connection = try LibrarySQLite(readingOnly: database)
        defer { try? connection.close() }
        return try connection.transaction(write: false) {
            var tables = ["feed_credentials", "feed_credential_cleanup"]
            if try connection.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'ntp_secrets'") == 1 {
                tables.append("ntp_secrets")
            }
            let rows = try connection.rows(tables.map { "SELECT credential_id FROM \($0)" }.joined(separator: " UNION "))
            return Set(rows.compactMap { row in row.first?.text.flatMap(UUID.init(uuidString:)) })
        }
    }
}
