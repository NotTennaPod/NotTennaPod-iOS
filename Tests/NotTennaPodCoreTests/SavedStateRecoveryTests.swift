import Foundation
import SQLite3
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Saved state that cannot be read now (before the first unlock after a restart, a permission or I/O error) during
/// Keep recovery, in the stores the graph opens and in the token-removal journal is never taken for absent, and a
/// download parked for it is tried again once access may have returned, without holding the process.
@MainActor @Suite(.serialized) struct SavedStateRecoveryTests {
    /// Makes `item` unreadable (a file) or unexaminable (a folder) until the returned closure restores it.
    private func deny(_ item: URL) throws -> () -> Void {
        var directory: ObjCBool = false
        FileManager.default.fileExists(atPath: item.path, isDirectory: &directory)
        let restored = directory.boolValue ? 0o755 : 0o644
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: item.path)
        return { try? FileManager.default.setAttributes([.posixPermissions: restored], ofItemAtPath: item.path) }
    }

    private func unavailable(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return SavedState.isUnavailable(error) }
    }

    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SavedStateRecovery-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Keep recovery

    /// A Keep committed and partly published (S's database already moved into the root folder, the registry not yet
    /// updated). Its manifest, the root database's identity or the root media folder's marker cannot be read: the start's
    /// preamble and selection wait (they throw), nothing is deleted, and never the registry's server folder (whose
    /// database has moved) nor any other library opens. Readable again in the same process, the converted library opens
    /// with its podcasts.
    @Test func unreadableKeepStateMakesTheStartWaitAndTheConvertedLibraryOpensOnceReadable() async throws {
        let fixture = LibraryKeepTests()
        let device = try await fixture.device()
        defer { fixture.remove(device) }
        let failing = device.keep { if $0 == .settingsSpeeds { throw POSIXError(.ENOSPC) } }
        let manifest = try failing.request(source: LibraryKeepTests.source)
        #expect(failing.run(manifest) == .notPublished(.storage))
        let folder = LibraryKeep.conversionsFolder(root: device.root).appendingPathComponent(manifest.operation, isDirectory: true)
        let manifestFile = folder.appendingPathComponent(LibraryKeep.manifestName)
        let rootDatabase = device.root.appendingPathComponent(LibraryLocation.databaseName)
        let rootMarker = device.root.appendingPathComponent("media", isDirectory: true).appendingPathComponent(LibraryKeep.markerName)
        #expect(LibraryLocation.isAbsent(device.source.database), "the Keep moved S's database into the root folder")
        for denied in [manifestFile, rootDatabase, rootMarker] {
            let restore = try deny(denied)
            #expect(unavailable {
                _ = try LibraryGraphStart.finishKeep(device.keep(), gate: LibraryGate())
                _ = try LibraryGraphStart.openingLibrary(root: device.root, keep: device.keep())
            }, "\(denied.lastPathComponent)")
            restore()
            #expect(FileManager.default.fileExists(atPath: manifestFile.path), "nothing deleted (\(denied.lastPathComponent))")
            #expect(LibraryLocation.isAbsent(device.source.database), "no database created in S's folder")
        }
        let opening = try LibraryGraphStart.openingLibrary(root: device.root, keep: device.keep())
        #expect(opening.location.database == rootDatabase && opening.location.converted != nil)
        let store = try FeedLibraryStore(url: opening.location.database, ownedRoot: opening.location.ownedRoot)
        let titles = try await store.feeds().map(\.metadata.title)
        try await store.close()
        #expect(titles.contains("Server"))
    }

    /// An unnamed operation whose manifest cannot be read is never deleted as an abandoned request.
    @Test func unreadableManifestOfAnUnnamedOperationIsNotDeleted() async throws {
        let fixture = LibraryKeepTests()
        let device = try await fixture.device()
        defer { fixture.remove(device) }
        let operation = ContractIdentity.randomUUID()
        let manifest = LibraryKeepManifest(operation: operation, source: LibraryKeepTests.source, archive: ContractIdentity.randomUUID(),
                                           keptAt: 1_780_000_000_000)
        try device.keep().writeManifest(manifest)
        let file = LibraryKeep.conversionsFolder(root: device.root).appendingPathComponent(operation).appendingPathComponent(LibraryKeep.manifestName)
        let restore = try deny(file)
        #expect(unavailable { _ = try device.keep().unfinishedKeeps() })
        restore()
        #expect(FileManager.default.fileExists(atPath: file.path))
        // Readable and never recorded: only now is it deleted, as before.
        #expect(try device.keep().unfinishedKeeps().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// Another connection holding a database's exclusive lock, as SQLite reports it to everyone else (SQLITE_BUSY).
    private final class DatabaseLock {
        private var handle: OpaquePointer?
        init(_ database: URL) throws {
            guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw POSIXError(.EIO) }
            for sql in ["PRAGMA locking_mode = EXCLUSIVE", "BEGIN EXCLUSIVE", "CREATE TABLE IF NOT EXISTS lock_probe(x)"] {
                guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw POSIXError(.EIO) }
            }
        }
        func release() {
            guard let handle else { return }
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            sqlite3_close_v2(handle)
            self.handle = nil
        }
        deinit { release() }
    }

    /// A committed, partly published Keep whose operation the registry no longer names (restored to
    /// before the Keep was recorded), while another connection holds the converted database locked. Its commit cannot
    /// be inspected, which is not "not committed": the manifest is never deleted and recovery and selection wait.
    /// Released in the same process, the Keep is recognised as committed and named again.
    @Test func lockedDatabaseNeverMakesACommittedKeepLookUncommitted() async throws {
        let fixture = LibraryKeepTests()
        let device = try await fixture.device()
        defer { fixture.remove(device) }
        let registry = LibraryRegistryFile(root: device.root)
        let before = try Data(contentsOf: registry.url)
        let failing = device.keep { if $0 == .settingsSpeeds { throw POSIXError(.ENOSPC) } }
        let manifest = try failing.request(source: LibraryKeepTests.source)
        #expect(failing.run(manifest) == .notPublished(.storage))
        try before.write(to: registry.url)
        let manifestFile = LibraryKeep.conversionsFolder(root: device.root).appendingPathComponent(manifest.operation)
            .appendingPathComponent(LibraryKeep.manifestName)
        let lock = try DatabaseLock(device.root.appendingPathComponent(LibraryLocation.databaseName))
        #expect(unavailable { _ = try device.keep().unfinishedKeeps() })
        #expect(unavailable { _ = try LibraryGraphStart.openingLibrary(root: device.root, keep: device.keep()) })
        lock.release()
        #expect(FileManager.default.fileExists(atPath: manifestFile.path), "the committed operation's manifest is kept")
        #expect(try device.keep().committed(manifest))
        #expect(try device.keep().unfinishedKeeps().map(\.operation) == [manifest.operation])
        #expect(device.registry.conversions.map(\.operation) == [manifest.operation])
    }

    /// The registry chooses a server library whose database is confirmed missing (a Keep moved it): its database is
    /// never created; the standalone library opens, as for a missing folder.
    @Test func chosenServerLibraryWithoutItsDatabaseIsNeverCreated() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "0b5a3c1e-7c43-4a5e-9d1f-2b9a0e7f6c11"
        var registry = LibraryRegistry()
        registry.libraries = [.init(id: id, serverURL: "https://sync.example.test", serverID: "server-1",
                                    accountID: "6f1c2d3e-4b5a-4c6d-8e7f-9a0b1c2d3e4f", username: "alice", state: .active, createdAt: 0)]
        registry.active = .server(id)
        try LibraryRegistryFile(root: root).write(registry)
        let location = LibraryLocation(root: root, reference: .server(id))
        try location.prepare()
        let keep = LibraryKeep(.init(root: root, secrets: MemoryServerSecrets()))
        let opening = try LibraryGraphStart.openingLibrary(root: root, keep: keep)
        #expect(opening.location.reference == .standalone && opening.fallback == .databaseMissing)
        // An interrupted import's backup still counts: the library is restored by `LibraryReplacement`.
        try Data().write(to: URL(fileURLWithPath: location.database.path + ".pre-restore"))
        #expect(try LibraryGraphStart.openingLibrary(root: root, keep: keep).location.reference == .server(id))
    }

    /// An import was interrupted after moving a populated server library aside, and its backup cannot
    /// be renamed back yet (here a refused rename: the user-immutable flag). The start's preamble (selection, recovery,
    /// opening) waits instead of opening an empty library, and the backup stays; once the rename works in the same
    /// process the library returns with its podcasts, and another launch keeps it.
    @Test func importBackupThatCannotBeRestoredYetIsNeverReplacedByAnEmptyLibrary() async throws {
        let root = try temp()
        let id = "0b5a3c1e-7c43-4a5e-9d1f-2b9a0e7f6c11"
        var registry = LibraryRegistry()
        registry.libraries = [.init(id: id, serverURL: "https://sync.example.test", serverID: "server-1",
                                    accountID: "6f1c2d3e-4b5a-4c6d-8e7f-9a0b1c2d3e4f", username: "alice", state: .active, createdAt: 0)]
        registry.active = .server(id)
        try LibraryRegistryFile(root: root).write(registry)
        let location = LibraryLocation(root: root, reference: .server(id))
        try location.prepare()
        let populated = try FeedLibraryStore(url: location.database, ownedRoot: location.ownedRoot)
        _ = try await populated.insert(ServerLibraryFixture.fetched("https://kept.example/feed.xml", title: "Kept", count: 2))
        try await populated.close()
        let live = location.database, backup = URL(fileURLWithPath: live.path + ".pre-restore")
        for suffix in ["-wal", "-shm", "-journal", ""] where !LibraryLocation.isAbsent(URL(fileURLWithPath: live.path + suffix)) {
            try FileManager.default.moveItem(at: URL(fileURLWithPath: live.path + suffix), to: URL(fileURLWithPath: backup.path + suffix))
        }
        #expect(Darwin.chflags(backup.path, UInt32(UF_IMMUTABLE)) == 0)
        defer {
            _ = Darwin.chflags(backup.path, 0)
            try? FileManager.default.removeItem(at: root)
        }
        let keep = LibraryKeep(.init(root: root, secrets: MemoryServerSecrets()))
        /// What `startLibraryGraph` does before anything else opens the library.
        func preamble() throws -> FeedLibraryStore {
            let opening = try LibraryGraphStart.openingLibrary(root: root, keep: keep)
            try LibraryReplacement.recoverInterrupted(live: opening.location.database)
            return try FeedLibraryStore(url: opening.location.database, ownedRoot: opening.location.ownedRoot)
        }
        do {
            let store = try preamble()
            try await store.close()
            Issue.record("a library opened while its backup could not be returned")
        } catch { #expect(SavedState.isUnavailable(error), "\(error)") }
        #expect(LibraryLocation.isAbsent(live) && !LibraryLocation.isAbsent(backup), "nothing created in its place, the backup kept")
        _ = Darwin.chflags(backup.path, 0)
        for launch in ["same process", "another launch"] {
            let store = try preamble()
            let titles = try await store.feeds().map(\.metadata.title)
            try await store.close()
            #expect(titles == ["Kept"], "\(launch)")
        }
        #expect(LibraryLocation.isAbsent(backup))
    }

    // MARK: - The stores the graph opens and the token-removal journal

    @Test func subscriptionDisplayChoicesSurviveATemporarilyUnreadableFile() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("subscription-display-preferences.json")
        var saved = SubscriptionDisplayPreferences(); saved.showTitle = true; saved.columns = 4; saved.feedOrder = "2"
        try JSONEncoder().encode(saved).write(to: file)
        let restore = try deny(file)
        #expect(unavailable { _ = try SubscriptionDisplayPreferenceStore(file: file) })
        restore()
        let store = try SubscriptionDisplayPreferenceStore(file: file)
        #expect(store.value == saved)
        var changed = store.value; changed.lastTag = "News"
        try store.update(changed)
        let reopened = try SubscriptionDisplayPreferenceStore(file: file).value
        #expect(reopened.showTitle && reopened.columns == 4 && reopened.feedOrder == "2" && reopened.lastTag == "News")
        // Damaged content still starts from the defaults, as before.
        try Data("{".utf8).write(to: file)
        #expect(try SubscriptionDisplayPreferenceStore(file: file).value == SubscriptionDisplayPreferences())
    }

    @Test func episodeListSortsSurviveATemporarilyUnreadableFile() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("episode-list-preferences.json")
        var saved = EpisodeListPreferences(); saved.inboxSort = 2; saved.episodesSort = 3
        try JSONEncoder().encode(saved).write(to: file)
        let restore = try deny(file)
        #expect(unavailable { _ = try EpisodeListPreferenceStore(file: file) })
        restore()
        let store = try EpisodeListPreferenceStore(file: file)
        #expect(store.value == saved)
        try store.update { $0.doNotPromptRemoveAllFromInbox = true }
        let reopened = try EpisodeListPreferenceStore(file: file).value
        #expect(reopened.inboxSort == 2 && reopened.episodesSort == 3 && reopened.doNotPromptRemoveAllFromInbox)
    }

    @Test func settingsSearchHistorySurvivesATemporarilyUnreadableFile() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings-search-history.json")
        let saved = try SettingsSearchHistoryStore(file: file)
        try saved.add("Proxy"); try saved.add("Playback speed")
        let restore = try deny(file)
        #expect(unavailable { _ = try SettingsSearchHistoryStore(file: file) })
        restore()
        let store = try SettingsSearchHistoryStore(file: file)
        try store.add("Queue")
        #expect(try SettingsSearchHistoryStore(file: file).terms == ["Queue", "Playback speed", "Proxy"])
    }

    /// A launch that cannot read the token-removal journal keeps it: the removal it records is retried once the
    /// journal can be read, never forgotten or written over.
    @Test func tokenRemovalJournalThatCannotBeReadIsKeptAndRetriedOnceReadable() async throws {
        let world = try await ServerLogoutTests.World()
        defer { world.cleanUp() }
        world.saves.locked.withLock { $0 = true }
        try await world.accounts.logout(.goBack, scene: nil)
        world.transport.release()
        for task in world.accounts.signOuts { await task.value }
        let file = world.root.appendingPathComponent(ServerTokenRemovals.fileName)
        let recorded = try Data(contentsOf: file)
        #expect(world.credential?.token == "token-1")
        world.saves.locked.withLock { $0 = false }
        let restore = try deny(file)
        world.relaunch()
        world.accounts.retryTokenRemovals()
        restore()
        #expect(world.credential?.token == "token-1" && (try? Data(contentsOf: file)) == recorded, "kept as it was")
        // Readable again (the next graph start): the token goes and so does the record.
        world.accounts.retryTokenRemovals()
        #expect(world.credential?.token == nil && world.credential?.transportNonce == "nonce-1")
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// The journal (holding removal A) cannot be read while a logout records removal B and the Keychain
    /// refuses writes. Once the journal is readable again, both are saved even though no Keychain removal succeeds yet;
    /// a relaunch keeps both; once the Keychain works, both tokens go and so does the journal.
    @Test func removalsRecordedWhileTheJournalIsUnreadableAreSavedOnceItIsReadable() async throws {
        let world = try await ServerLogoutTests.World()
        defer { world.cleanUp() }
        let other = ContractIdentity.randomUUID(), otherInstall = ContractIdentity.randomUUID()
        try world.secrets.saveInstallation(.init(transportNonce: "nonce-0", token: "token-0"), library: other, install: otherInstall)
        let journal = ServerTokenRemovals(root: world.root)
        try journal.write([.init(library: other, install: otherInstall, token: ServerTokenRemovals.digest("token-0"))])
        let restore = try deny(journal.url)
        world.relaunch()
        world.saves.locked.withLock { $0 = true }
        try await world.accounts.logout(.goBack, scene: nil)
        world.transport.release()
        for task in world.accounts.signOuts { await task.value }
        restore()
        // Readable, the Keychain still refusing: the union is saved.
        world.accounts.retryTokenRemovals()
        #expect(try journal.read().count == 2)
        world.relaunch()
        world.accounts.retryTokenRemovals()
        #expect(try journal.read().count == 2)
        // The Keychain works again: both tokens go, then the journal.
        world.saves.locked.withLock { $0 = false }
        world.relaunch()
        world.accounts.retryTokenRemovals()
        #expect(world.credential?.token == nil && (try? world.secrets.installation(library: other, install: otherInstall))??.token == nil)
        #expect(!FileManager.default.fileExists(atPath: journal.url.path))
    }

    // MARK: - Downloads parked for access

    /// A transfer whose saved state cannot be reached for its first `blocked` attempts.
    private final class Blocked: MediaTransferring {
        let attempts = Mutex(0)
        let blocked: Int
        init(blocked: Int) { self.blocked = blocked }
        func download(_ input: MediaDownloadRequest,
                      progress: @escaping @Sendable (MediaDownloadProgress) -> Void) async throws -> MediaDownloadResult {
            let attempt = attempts.withLock { $0 += 1; return $0 }
            if attempt <= blocked { throw SavedStateUnavailable() }
            try Data("complete".utf8).write(to: input.destination)
            return MediaDownloadResult(destination: input.destination, size: 8, validator: nil)
        }
    }

    private func wait(until condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while try await !condition() {
            try #require(ContinuousClock.now < deadline, "condition not reached")
            await Task.yield()
        }
    }

    /// A coordinator with one episode whose transfer is `transfer`.
    private func withCoordinator(_ transfer: Blocked, _ body: (DownloadCoordinator, FeedLibraryStore) async throws -> Void) async throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let episode = ParsedEpisode(identifier: "episode", title: "Episode", media: ParsedMedia(url: "https://example.test/a.mp3", size: 8))
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Feed", episodes: [episode]),
                                              source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
                                              validator: nil, permanentRedirectURL: nil))
        let network = DownloadNetworkMonitor(startMonitoring: false)
        network.update(.init(connected: true, metered: false, cellular: false))
        let coordinator = DownloadCoordinator(store: store, directory: root.appendingPathComponent("media"), transfer: transfer,
                                              network: network)
        do { try await body(coordinator, store); await coordinator.stop(); try await store.close() }
        catch { await coordinator.stop(); try? await store.close(); throw error }
    }

    /// The job parks (waiting, no failure, not process work, so background time can be released), stays parked
    /// without retrying on its own, gets exactly one attempt per `resumeParked()`, and completes once access returned.
    @Test func downloadParkedForAccessIsNotProcessWorkAndIsRetriedOncePerResume() async throws {
        let transfer = Blocked(blocked: 2)
        try await withCoordinator(transfer) { coordinator, store in
            _ = try await coordinator.request(episodeID: 1)
            let job = try #require(coordinator.jobs.first)
            try await wait { coordinator.parkedForAccess == [job.id] }
            #expect(coordinator.jobs.first?.state == .waiting && coordinator.jobs.first?.countedAttempts == 0)
            #expect(!coordinator.hasProcessWork, "a parked job holds no background time")
            for _ in 0..<20 { await Task.yield() }
            #expect(transfer.attempts.withLock { $0 } == 1, "no retry loop")
            coordinator.resumeParked()
            #expect(coordinator.hasProcessWork)
            try await wait { coordinator.parkedForAccess == [job.id] && transfer.attempts.withLock { $0 } == 2 }
            coordinator.resumeParked()
            try await wait { coordinator.jobs.first?.state == .completed }
            #expect(try await store.episode(id: 1)?.userState.isDownloaded == true)
            #expect(transfer.attempts.withLock { $0 } == 3 && coordinator.parkedForAccess.isEmpty && !coordinator.hasProcessWork)
        }
    }

    /// Unlock or activation arrives after an attempt was denied but before it parked (nothing is parked
    /// yet). The attempt gets one more attempt once it has unwound; duplicate events still give one; a second denial,
    /// with no event since, parks. No polling, no loop.
    @Test func accessEventWhileADeniedAttemptUnwindsGivesItOneMoreAttempt() async throws {
        // Access returned: the retry completes the download.
        try await withCoordinator(Blocked(blocked: 1)) { coordinator, store in
            var delivered = false
            coordinator.beforeParking = { if !delivered { delivered = true; coordinator.resumeParked() } }
            _ = try await coordinator.request(episodeID: 1)
            try await wait { coordinator.jobs.first?.state == .completed }
            #expect(coordinator.parkedForAccess.isEmpty)
        }
        // Still denied, after two events during the unwind: exactly one retry, then parked.
        let transfer = Blocked(blocked: 99)
        try await withCoordinator(transfer) { coordinator, _ in
            var delivered = false
            coordinator.beforeParking = {
                if !delivered { delivered = true; coordinator.resumeParked(); coordinator.resumeParked() }
            }
            _ = try await coordinator.request(episodeID: 1)
            let job = try #require(coordinator.jobs.first)
            try await wait { coordinator.parkedForAccess == [job.id] }
            for _ in 0..<20 { await Task.yield() }
            #expect(transfer.attempts.withLock { $0 } == 2 && coordinator.parkedForAccess == [job.id])
        }
    }

    /// An attempt denied after the latest event parks at once.
    @Test func attemptDeniedAfterTheLatestAccessEventParks() async throws {
        let transfer = Blocked(blocked: 99)
        try await withCoordinator(transfer) { coordinator, _ in
            coordinator.resumeParked()
            _ = try await coordinator.request(episodeID: 1)
            let job = try #require(coordinator.jobs.first)
            try await wait { coordinator.parkedForAccess == [job.id] }
            for _ in 0..<20 { await Task.yield() }
            #expect(transfer.attempts.withLock { $0 } == 1)
        }
    }
}
