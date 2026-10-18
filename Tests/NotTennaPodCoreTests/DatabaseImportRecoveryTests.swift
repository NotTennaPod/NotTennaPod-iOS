import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// An interrupted database import: killed at every point from before staging to after publication, the next
/// launch completes or rolls it back; the old or new library stays coherent and its feed credentials work; only the
/// secrets the import created and its staging folder go, never a credential the live library reaches; cleanup that
/// cannot run now keeps its journal and is safe to repeat; the outcome is told once.
@Suite(.serialized)
struct DatabaseImportRecoveryTests {
    static let backup = AndroidDatabaseRestoreTests.fixtures.appendingPathComponent("archived-credentials-library.db")
    static let liveLogin = FeedCredentials(username: "live-user", password: "live-password")

    /// The live library: one podcast with a saved login, as the person has it before importing.
    struct Live {
        let root: URL, database: URL, vault: ImportVault, feedID: Int64, identity: String
        var journals: URL { DatabaseImportJournal.folder(root: root) }
        var notices: PendingNotices { PendingNotices(root: root) }
        var liveSecrets: Set<UUID> = []
    }

    private func live() async throws -> Live {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DatabaseImportRecovery-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("media"), withIntermediateDirectories: true)
        let database = root.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: database), vault = ImportVault()
        let source = "https://import.example/private"
        let feed = try await store.insert(.init(feed: ParsedFeed(format: .rss, title: "Live private podcast"), source: source,
            responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil))
        try await FeedAuthentication(store: store, vault: vault).save(Self.liveLogin, feedID: feed.id)
        let identity = try #require(store.identityAtOpen?.identity)
        try await store.close()
        // A downloaded file of the live library, which a completed import removes and a rolled-back one keeps.
        try Data("episode".utf8).write(to: root.appendingPathComponent("media/live-episode.mp3"))
        var value = Live(root: root, database: database, vault: vault, feedID: feed.id, identity: identity)
        value.liveSecrets = vault.ids
        return value
    }

    private func attempt(_ live: Live) throws -> DatabaseImportAttempt {
        try DatabaseImportAttempt(root: live.root, folder: live.root, live: live.database, liveIdentity: live.identity, vault: live.vault,
                                  notices: live.notices)
    }

    /// Stages with the live store open, as the app does, then "kills" the process at `point` (nothing is cleaned up).
    private func stage(_ attempt: DatabaseImportAttempt, _ live: Live, killedAt point: DatabaseImportAttempt.KillPoint? = nil) async throws {
        let store = try FeedLibraryStore(url: live.database)
        do { try await attempt.stage(backup: Self.backup, live: store, killedAt: point) }
        catch is DatabaseImportAttempt.SimulatedKill {}
        try await store.close()
    }

    /// The live library is the old one: same identity, its podcast and its login.
    private func expectOldLibrary(_ live: Live) async throws {
        let store = try FeedLibraryStore(url: live.database)
        #expect(store.identityAtOpen?.identity == live.identity)
        #expect(try await store.feeds().map(\.title) == ["Live private podcast"])
        #expect(try await FeedAuthentication(store: store, vault: live.vault).credentials(feedID: live.feedID) == Self.liveLogin,
                "The live library's login still works")
        try await store.close()
        #expect(live.liveSecrets.isSubset(of: live.vault.ids), "No credential the live library reaches was removed")
        #expect(FileManager.default.fileExists(atPath: live.root.appendingPathComponent("media/live-episode.mp3").path))
    }

    /// The live library is the imported one: its logins work, and the old library's are retired by its own cleanup.
    private func expectNewLibrary(_ live: Live, stagedIdentity: String?) async throws {
        let store = try FeedLibraryStore(url: live.database)
        #expect(store.identityAtOpen?.identity == stagedIdentity && stagedIdentity != live.identity)
        let auth = FeedAuthentication(store: store, vault: live.vault)
        #expect(try await auth.credentials(feedID: 1) == .init(username: "retained-user", password: "retained-password"))
        try await auth.recoverCredentialCleanup()
        #expect(live.liveSecrets.isDisjoint(with: live.vault.ids), "The replaced library's logins retire after publication")
        #expect(try await auth.credentials(feedID: 1) == .init(username: "retained-user", password: "retained-password"))
        try await store.close()
    }

    private func expectNoLeftovers(_ live: Live, created: [UUID]) throws {
        #expect(Set(created).isDisjoint(with: live.vault.ids), "The import's own secrets are gone")
        let names = try FileManager.default.contentsOfDirectory(atPath: live.root.path)
        #expect(!names.contains { $0.hasPrefix("restore-staging-") }, "\(names)")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: live.journals.path)) ?? []).isEmpty)
    }

    // MARK: - Kill points before publication: rolled back

    @Test(arguments: [DatabaseImportAttempt.KillPoint?.none, .afterBackupRead, .afterCarryOver, .afterCredentials, .afterRetiringOldCredentials])
    func killBeforePublicationRollsBackAndKeepsTheLiveLibraryAndItsLogins(_ point: DatabaseImportAttempt.KillPoint?) async throws {
        let live = try await live(); defer { try? FileManager.default.removeItem(at: live.root) }
        let attempt = try attempt(live)
        if let point { try await stage(attempt, live, killedAt: point) }
        let journal = await attempt.record
        if point == .afterCredentials || point == .afterRetiringOldCredentials {
            #expect(journal.created.count == 4 && Set(journal.created).isSubset(of: live.vault.ids))
            #expect(Set(journal.retired) == live.liveSecrets, "The live library's logins are journaled as its own")
        }
        // Next launch.
        #expect(try relaunch(live) == [.importRolledBack])
        try await expectOldLibrary(live)
        try expectNoLeftovers(live, created: journal.created)
        #expect(try relaunch(live).isEmpty, "Told once; repeating is harmless")
        try await expectOldLibrary(live)
    }

    @Test func killWhileTheOldLibraryWasMovedAsideRollsBack() async throws {
        let live = try await live(); defer { try? FileManager.default.removeItem(at: live.root) }
        let attempt = try attempt(live)
        try await stage(attempt, live)
        try await attempt.markCommitting(target: live.database, replacedFolders: [live.root.appendingPathComponent("media")])
        // The first rename of `LibraryReplacement.replace`, then the kill.
        try FileManager.default.moveItem(at: live.database, to: URL(fileURLWithPath: live.database.path + ".pre-restore"))
        let created = await attempt.record.created
        #expect(try relaunch(live) == [.importRolledBack])
        try await expectOldLibrary(live)
        try expectNoLeftovers(live, created: created)
    }

    // MARK: - Kill points after the new library arrived: completed

    @Test func killAfterTheNewLibraryArrivedCompletesTheImport() async throws {
        let live = try await live(); defer { try? FileManager.default.removeItem(at: live.root) }
        let attempt = try attempt(live)
        try await stage(attempt, live)
        let staged = await attempt.record.stagedIdentity
        try await attempt.markCommitting(target: live.database, replacedFolders: [live.root.appendingPathComponent("media")])
        // Both renames of the main file, then the kill: the old copy is still beside it.
        try FileManager.default.moveItem(at: live.database, to: URL(fileURLWithPath: live.database.path + ".pre-restore"))
        try FileManager.default.moveItem(at: attempt.stagedDatabase, to: live.database)
        #expect(try relaunch(live) == [.importCompleted])
        #expect(!FileManager.default.fileExists(atPath: live.database.path + ".pre-restore"))
        #expect(!FileManager.default.fileExists(atPath: live.root.appendingPathComponent("media/live-episode.mp3").path),
                "The replaced library's downloads go, as the import does after publishing")
        try expectNoLeftovers(live, created: [])
        try await expectNewLibrary(live, stagedIdentity: staged)
        #expect(try relaunch(live).isEmpty)
    }

    @Test func killAfterPublicationFinishesTheImportOnce() async throws {
        let live = try await live(); defer { try? FileManager.default.removeItem(at: live.root) }
        let attempt = try attempt(live)
        try await stage(attempt, live)
        let staged = await attempt.record.stagedIdentity
        try await attempt.commit(target: live.database, replacedFolders: [live.root.appendingPathComponent("media")])
        #expect(await attempt.record.phase == .published)
        // Killed before `finish`.
        #expect(try relaunch(live) == [.importCompleted])
        #expect(!FileManager.default.fileExists(atPath: live.root.appendingPathComponent("media/live-episode.mp3").path))
        try expectNoLeftovers(live, created: [])
        try await expectNewLibrary(live, stagedIdentity: staged)
    }

    @Test func theReplacedFilesLeaveBeforeTheNewLibraryOpensAndNothingItAddsIsEverRemoved() async throws {
        let live = try await live(); defer { try? FileManager.default.removeItem(at: live.root) }
        let attempt = try attempt(live)
        try await stage(attempt, live)
        let media = live.root.appendingPathComponent("media")
        try await attempt.commit(target: live.database, replacedFolders: [media])
        // Killed after publication. At the next start the old downloads cannot be moved aside yet: the start waits, and
        // nothing is removed.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: live.root.path)
        #expect(throws: (any Error).self) { _ = try relaunch(live) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: live.root.path)
        #expect(FileManager.default.fileExists(atPath: media.appendingPathComponent("live-episode.mp3").path))
        // Then they are moved aside, but the staging folder cannot be removed yet: the journal stays.
        let locked = attempt.staging.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        #expect(try relaunch(live) == [.importCompleted])
        #expect(!FileManager.default.fileExists(atPath: media.appendingPathComponent("live-episode.mp3").path))
        // The imported library opens and downloads an episode; a Keep later puts a kept server library's download there.
        try Data("new".utf8).write(to: media.appendingPathComponent("new-episode.mp3"))
        try Data("kept".utf8).write(to: media.appendingPathComponent("server-1.media"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        #expect(try relaunch(live).isEmpty, "Recorded once")
        #expect(FileManager.default.fileExists(atPath: media.appendingPathComponent("new-episode.mp3").path)
                && FileManager.default.fileExists(atPath: media.appendingPathComponent("server-1.media").path),
                "Only what was moved aside is removed, never what the paths hold later")
        try expectNoLeftovers(live, created: [])
    }

    /// An import ended after the staged library reached the live path but before its journal
    /// advanced; at the next start its journal cannot be read. The start waits, so nothing can move the library before
    /// the import is decided; and once a Keep has moved the imported library into `Previous Libraries/` anyway, it is
    /// still found by identity: completed, its passwords keep working, and nothing it owns is removed.
    @Test func anImportedLibraryMovedByAKeepIsStillCompletedAndKeepsItsPasswords() async throws {
        let live = try await live(); defer { try? FileManager.default.removeItem(at: live.root) }
        let attempt = try attempt(live)
        try await stage(attempt, live)
        let staged = await attempt.record.stagedIdentity, created = await attempt.record.created
        try await attempt.markCommitting(target: live.database, replacedFolders: [live.root.appendingPathComponent("media")])
        try FileManager.default.moveItem(at: live.database, to: URL(fileURLWithPath: live.database.path + ".pre-restore"))
        try FileManager.default.moveItem(at: attempt.stagedDatabase, to: live.database)
        let journal = live.journals.appendingPathComponent(attempt.attempt.uuidString + ".json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: journal.path)
        #expect(throws: (any Error).self) { _ = try relaunch(live) }
        #expect(try live.notices.all().isEmpty && Set(created).isSubset(of: live.vault.ids))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        // As a Keep at logout would have done: the imported library archived, another library at the root.
        try LibraryReplacement.recoverInterrupted(live: live.database)
        let previous = PreviousLibraryLocation(root: live.root, id: UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: previous.folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: live.database, to: previous.database)
        try await FeedLibraryStore(url: live.database).close()
        try Data("kept".utf8).write(to: live.root.appendingPathComponent("media/server-1.media"))
        #expect(try relaunch(live) == [.importCompleted], "The import committed: not \"Your library was not changed\"")
        let archived = try FeedLibraryStore(url: previous.database)
        #expect(archived.identityAtOpen?.identity == staged)
        #expect(try await FeedAuthentication(store: archived, vault: live.vault).credentials(feedID: 1)
                == .init(username: "retained-user", password: "retained-password"), "Its passwords still work")
        try await archived.close()
        #expect(Set(created).isSubset(of: live.vault.ids))
        #expect(FileManager.default.fileExists(atPath: live.root.appendingPathComponent("media/server-1.media").path),
                "The root's media belongs to the library there now")
        try expectNoLeftovers(live, created: [])
    }

    /// The outcome survives a background launch that recovers it with no screen, a failed
    /// graph start, and later launches, until a person sees it; recording it again adds nothing.
    @Test func theOutcomeStaysUntilItIsPresented() async throws {
        let live = try await live(); defer { try? FileManager.default.removeItem(at: live.root) }
        let attempt = try attempt(live)
        try await stage(attempt, live, killedAt: .afterCredentials)
        #expect(try relaunch(live) == [.importRolledBack]) // a background launch: no screen takes it, and the process ends
        #expect(try relaunch(live).isEmpty)               // a graph start that fails later, then the visible launch
        let pending = try live.notices.all()
        #expect(pending.map(\.kind) == [.importRolledBack] && pending.first?.id == attempt.attempt)
        try live.notices.add(PendingNotice(id: attempt.attempt, kind: .importRolledBack))
        #expect(try live.notices.all().count == 1, "Recorded once per attempt")
        try live.notices.acknowledge(attempt.attempt)
        #expect(try live.notices.all().isEmpty)
    }

    // MARK: - In the process

    @Test func aReplacementThatRolledBackKeepsTheLiveLibrarysLogins() async throws {
        let live = try await live(); defer { try? FileManager.default.removeItem(at: live.root) }
        let attempt = try attempt(live)
        try await stage(attempt, live)
        let created = await attempt.record.created
        // The staged library cannot be moved in: `LibraryReplacement` rolls back.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: live.root.path)
        await #expect(throws: (any Error).self) {
            try await attempt.commit(target: live.database, replacedFolders: [live.root.appendingPathComponent("media")])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: live.root.path)
        await attempt.rollBack()
        try await expectOldLibrary(live)
        try expectNoLeftovers(live, created: created)
        #expect(try relaunch(live).isEmpty, "The import's dialog told it")
    }

    @Test func expirationWhileWaitingForTheLibraryGateRollsBackWithoutHoldingIt() async throws {
        let live = try await live(); defer { try? FileManager.default.removeItem(at: live.root) }
        let attempt = try attempt(live), gate = LibraryGate()
        await gate.acquireShared() // an export collecting its source
        let store = try FeedLibraryStore(url: live.database)
        let work = Task { try await attempt.prepareCommit(backup: Self.backup, live: store, gate: gate) }
        try await until { gate.hasWaiters }
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(!gate.hasWaiters)
        gate.releaseShared()
        #expect(!gate.isHeld, "A cancelled wait holds nothing")
        try await store.close()
        let created = await attempt.record.created
        #expect(created.count == 4)
        await attempt.rollBack()
        try await expectOldLibrary(live)
        try expectNoLeftovers(live, created: created)
    }

    @Test func cleanupThatCannotReachTheKeychainNowKeepsItsJournalAndFinishesLater() async throws {
        let live = try await live(); defer { try? FileManager.default.removeItem(at: live.root) }
        let attempt = try attempt(live)
        try await stage(attempt, live, killedAt: .afterRetiringOldCredentials)
        let created = await attempt.record.created
        live.vault.locked.withLock { $0 = true }
        #expect(try relaunch(live) == [.importRolledBack], "Told at the first launch")
        #expect(Set(created).isSubset(of: live.vault.ids))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: live.journals.path)) ?? []).count == 1, "Kept for retry")
        #expect(try relaunch(live).isEmpty)
        live.vault.locked.withLock { $0 = false }
        #expect(try relaunch(live).isEmpty, "Not told again")
        try await expectOldLibrary(live)
        try expectNoLeftovers(live, created: created)
    }

    @Test func aGraphStartWhileTheImportRunsLeavesItAlone() async throws {
        let live = try await live(); defer { try? FileManager.default.removeItem(at: live.root) }
        let attempt = try attempt(live)
        try await stage(attempt, live)
        // A library switch or restart in the same process, while the import waits for its commit.
        try DatabaseImportRecovery.recover(root: live.root, vault: live.vault, notices: live.notices)
        #expect(try live.notices.all().isEmpty)
        #expect(FileManager.default.fileExists(atPath: attempt.stagedDatabase.path))
        #expect(Set(await attempt.record.created).isSubset(of: live.vault.ids))
        await attempt.rollBack()
        try expectNoLeftovers(live, created: await attempt.record.created)
    }

    /// The pending-notice store cannot be read or written now (or again).
    private func notices(_ live: Live, available: Bool) throws {
        let file = live.notices.file
        if !FileManager.default.fileExists(atPath: file.path) { try Data("{}".utf8).write(to: file) }
        try FileManager.default.setAttributes([.posixPermissions: available ? 0o600 : 0o000], ofItemAtPath: file.path)
    }

    /// As a Keep at logout would have done: the library at the root archived into `Previous Libraries/`, another at root.
    private func keep(_ live: Live) async throws -> PreviousLibraryLocation {
        let previous = PreviousLibraryLocation(root: live.root, id: UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: previous.folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: live.database, to: previous.database)
        try await FeedLibraryStore(url: live.database).close()
        return previous
    }

    private func expectImportedLibraryWorks(at database: URL, _ live: Live) async throws {
        let store = try FeedLibraryStore(url: database)
        #expect(try await FeedAuthentication(store: store, vault: live.vault).credentials(feedID: 1)
                == .init(username: "retained-user", password: "retained-password"), "Its passwords still work")
        try await store.close()
    }

    /// The outcome is decided once and recorded before anything can move a library. A
    /// published import whose message cannot be saved makes the start wait with its decision kept; even when its
    /// library was later archived by a Keep and that archive cannot be read, the import is still the completed one.
    @Test func aDecidedImportStaysCompletedWhenItsArchiveCannotBeReadLater() async throws {
        let live = try await live(); defer { try? FileManager.default.removeItem(at: live.root) }
        let attempt = try attempt(live)
        try await stage(attempt, live)
        try await attempt.commit(target: live.database, replacedFolders: [live.root.appendingPathComponent("media")])
        try notices(live, available: false)
        #expect(throws: (any Error).self) { try startWaits(live) }
        #expect(await attempt.record.phase == .published)
        let previous = try await keep(live)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: previous.database.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previous.database.path) }
        try notices(live, available: true)
        #expect(try relaunch(live) == [.importCompleted], "Never \"Your library was not changed\"")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previous.database.path)
        try await expectImportedLibraryWorks(at: previous.database, live)
        try expectNoLeftovers(live, created: [])
    }

    /// An undecided import whose library a later layout moved is never called rolled back
    /// while a library it may be cannot be read: the start waits until it can.
    @Test func anUnreadableLibraryNeverDecidesARollback() async throws {
        let live = try await live(); defer { try? FileManager.default.removeItem(at: live.root) }
        let attempt = try attempt(live)
        try await stage(attempt, live)
        try await attempt.markCommitting(target: live.database, replacedFolders: [live.root.appendingPathComponent("media")])
        try FileManager.default.moveItem(at: live.database, to: URL(fileURLWithPath: live.database.path + ".pre-restore"))
        try FileManager.default.moveItem(at: attempt.stagedDatabase, to: live.database)
        try LibraryReplacement.recoverInterrupted(live: live.database)
        let previous = try await keep(live)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: previous.database.path)
        #expect(throws: (any Error).self) { _ = try relaunch(live) }
        #expect(try live.notices.all().isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previous.database.path)
        #expect(try relaunch(live) == [.importCompleted])
        try await expectImportedLibraryWorks(at: previous.database, live)
    }

    /// In the process, an outcome that cannot be recorded keeps the journal (nothing is cleaned
    /// up); the app ends before the result dialog; the next start records the outcome.
    @Test(arguments: [true, false])
    func anOutcomeThatCannotBeRecordedKeepsItsJournalForTheNextStart(completed: Bool) async throws {
        let live = try await live(); defer { try? FileManager.default.removeItem(at: live.root) }
        let attempt = try attempt(live)
        try await stage(attempt, live)
        let created = await attempt.record.created
        try notices(live, available: false)
        if completed {
            try await attempt.commit(target: live.database, replacedFolders: [live.root.appendingPathComponent("media")])
            await attempt.finish()
        } else {
            await attempt.rollBack()
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: live.journals.path)) ?? []).count == 1, "The journal stays")
        try notices(live, available: true)
        #expect(try relaunch(live) == [completed ? .importCompleted : .importRolledBack])
        try expectNoLeftovers(live, created: completed ? [] : created)
    }

    /// An outcome seen once never returns, although its journal cannot say it was recorded
    /// (its folder cannot be written) and its cleanup must wait.
    @Test func anAcknowledgedOutcomeNeverReturnsWhileItsJournalCannotBeUpdated() async throws {
        let live = try await live(); defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: live.journals.path)
            try? FileManager.default.removeItem(at: live.root)
        }
        let attempt = try attempt(live)
        try await stage(attempt, live, killedAt: .afterCredentials)
        let created = await attempt.record.created
        try notices(live, available: false)
        #expect(throws: (any Error).self) { try startWaits(live) } // its outcome decided and kept
        try notices(live, available: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: live.journals.path)
        live.vault.locked.withLock { $0 = true }

        #expect(try relaunch(live) == [.importRolledBack])
        try live.notices.acknowledge(attempt.attempt) // seen
        #expect(try relaunch(live).isEmpty && (try live.notices.all()).isEmpty, "Seen once: never again")
        #expect(try relaunch(live).isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: live.journals.path)
        live.vault.locked.withLock { $0 = false }
        #expect(try relaunch(live).isEmpty)
        try expectNoLeftovers(live, created: created)
        #expect(!FileManager.default.fileExists(atPath: live.notices.file.path), "Its acknowledgement goes with the journal")
    }

    /// The next launch's recovery alone (the store may be unreadable): throws when the start must wait.
    private func startWaits(_ live: Live) throws {
        DatabaseImportAttempt.simulateProcessEnd()
        try DatabaseImportRecovery.recover(root: live.root, vault: live.vault, notices: live.notices)
    }

    /// The next launch: what this process was running is now interrupted. Returns the outcomes it recorded for the person.
    private func relaunch(_ live: Live) throws -> [PendingNotice.Kind] {
        DatabaseImportAttempt.simulateProcessEnd()
        let before = Set(try live.notices.all().map(\.id))
        try DatabaseImportRecovery.recover(root: live.root, vault: live.vault, notices: live.notices)
        return try live.notices.all().filter { !before.contains($0.id) }.map(\.kind)
    }

    private func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate() && ContinuousClock.now < deadline { await Task.yield() }
        try #require(predicate())
    }
}

/// Background time may end any wait for the library gate: a cancelled wait holds nothing and lets whoever waited
/// behind it in.
@Suite
struct LibraryGateCancellationTests {
    private func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate() && ContinuousClock.now < deadline { await Task.yield() }
        try #require(predicate())
    }

    @Test func aCancelledSharedWaitBehindAWriterHoldsNothing() async throws {
        let gate = LibraryGate()
        await gate.acquireExclusive()
        let waiting = Task { try await gate.acquireSharedUnlessCancelled() }
        try await until { gate.hasWaiters }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(!gate.hasWaiters)
        gate.releaseExclusive()
        #expect(!gate.isHeld)
        #expect(gate.tryAcquireExclusive(), "Nothing was left holding or waiting")
        gate.releaseExclusive()
    }

    @Test func aCancelledWriterLetsTheReadersQueuedBehindItIn() async throws {
        let gate = LibraryGate()
        await gate.acquireShared()
        let writer = Task { try await gate.acquireExclusiveUnlessCancelled() }
        try await until { gate.hasWaiters }
        let reader = Task { await gate.acquireShared(); return true }
        writer.cancel()
        await #expect(throws: CancellationError.self) { try await writer.value }
        #expect(await reader.value, "The reader behind the cancelled writer gets in")
        gate.releaseShared(); gate.releaseShared()
        #expect(!gate.isHeld && !gate.hasWaiters)
    }

    @Test func aWaitCancelledBeforeItStartsAndAGrantedOneBehaveAsAsked() async throws {
        let gate = LibraryGate()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await gate.acquireExclusiveUnlessCancelled()
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!gate.isHeld && !gate.hasWaiters)
        try await gate.acquireExclusiveUnlessCancelled()
        #expect(gate.isHeld)
        gate.releaseExclusive()
        try await gate.acquireSharedUnlessCancelled()
        gate.releaseShared()
        #expect(!gate.isHeld)
    }
}

/// The Keychain: a locked one refuses every change, as before the first unlock.
final class ImportVault: SynchronizationCredentialStore, Sendable {
    private let values = Mutex<[UUID: String]>([:])
    let locked = Mutex(false)
    var ids: Set<UUID> { values.withLock { Set($0.keys) } }
    func insert(_ password: String, id: UUID) throws {
        if locked.withLock({ $0 }) { throw SynchronizationCredentialError.keychain(-25308) }
        values.withLock { $0[id] = password }
    }
    func password(id: UUID) throws -> String {
        if locked.withLock({ $0 }) { throw SynchronizationCredentialError.keychain(-25308) }
        guard let value = values.withLock({ $0[id] }) else { throw SynchronizationCredentialError.keychain(-25300) }
        return value
    }
    func remove(id: UUID) throws {
        if locked.withLock({ $0 }) { throw SynchronizationCredentialError.keychain(-25308) }
        _ = values.withLock { $0.removeValue(forKey: id) }
    }
}
