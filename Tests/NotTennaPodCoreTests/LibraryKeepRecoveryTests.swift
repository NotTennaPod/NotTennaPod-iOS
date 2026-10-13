import Foundation
import Security
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Keep recovery: a Keep at logout across removing its previous library, an older Keep's pending cleanup, a database
/// import before publication and playback started while the Keep waits; exports that waited for the gate or cannot
/// read a credential; download records after a restore.
@MainActor @Suite(.serialized) struct LibraryKeepRecoveryTests {
    let fixture = LibraryKeepTests()

    /// A recorded Keep with a chosen operation ID (so two operations sort in a known order).
    func request(_ device: LibraryKeepTests.Device, source: String, operation: String) throws -> LibraryKeepManifest {
        let manifest = LibraryKeepManifest(operation: operation, source: source, archive: ContractIdentity.randomUUID(), keptAt: 1_780_000_000_000)
        try device.keep().writeManifest(manifest)
        try LibraryRegistryFile(root: device.root).update { registry in
            let index = try #require(registry.libraries.firstIndex { $0.id == source })
            registry.libraries[index].state = .keeping
            registry.libraries[index].operation = operation
            registry.pendingSwitch = nil
        }
        return manifest
    }

    /// What `ServerAccounts.removePreviousLibrary` does to the files and the registry (no feed credentials here).
    func removePrevious(_ device: LibraryKeepTests.Device) throws {
        let previous = try #require(device.registry.previous.first)
        try FileManager.default.removeItem(at: PreviousLibraryLocation(root: device.root, id: previous.id).folder)
        try LibraryRegistryFile(root: device.root).update { $0.previous.removeAll { $0.id == previous.id } }
    }

    // MARK: - Publication survives removing the previous library

    @Test func removingThePreviousLibraryWhileCleanupWaitsNeverUndoesPublication() async throws {
        let device = try await fixture.device()
        defer { fixture.remove(device) }
        let keep = device.keep { if $0 == .cleanupTokens { throw LibraryKeepInterruption() } }
        #expect(keep.run(try keep.request(source: LibraryKeepTests.source)) == .cleanupPending)
        try removePrevious(device)
        let recovery = device.keep()
        #expect(try LibraryGraphStart.converted(recovery) == nil, "the published library opens from the root folder")
        #expect(recovery.run(try #require(try recovery.unfinished())) == .finished)
        #expect(try LibraryGraphStart.converted(recovery) == nil)
        #expect(try recovery.unfinished() == nil)
        // The root settings stay S's: nothing fell back to defaults.
        let speeds = try JSONDecoder().decode(PlaybackSpeedPreferences.self,
            from: Data(contentsOf: device.root.appendingPathComponent("playback-speed-preferences.json")))
        #expect(speeds.feeds.values.sorted() == [2.0] && speeds.temporary == 2.0)
    }

    /// The crash between the registry's publication and the manifest's update, then the previous library removed.
    @Test func aCrashBeforeTheManifestSaysPublishedThenARemovalStillCountsAsPublished() async throws {
        let device = try await fixture.device()
        defer { fixture.remove(device) }
        let keep = device.keep { if $0 == .publishWrite { throw LibraryKeepInterruption() } }
        let manifest = try keep.request(source: LibraryKeepTests.source)
        #expect(keep.run(manifest) == .notPublished(.interrupted))
        #expect(try keep.readManifest(manifest.operation).phase != .published)
        try removePrevious(device)
        let recovery = device.keep()
        #expect(try LibraryGraphStart.converted(recovery) == nil)
        #expect(try LibraryGraphStart.finishKeep(recovery, gate: LibraryGate())?.outcome == .finished)
        #expect(device.registry.conversions.isEmpty && device.registry.active == .standalone)
        #expect(try LibraryDatabaseInspection.identity(of: device.root.appendingPathComponent("library.sqlite"))?.identity == LibraryKeepTests.source)
    }

    // MARK: - An older cleanup never holds back the current Keep

    @Test func anOlderKeepsPendingCleanupNeverBlocksTheCurrentKeep() async throws {
        let device = try await fixture.device()
        defer { fixture.remove(device) }
        let first = try request(device, source: LibraryKeepTests.source, operation: "00000000-0000-4000-8000-000000000001")
        let locked = device.keep { if $0 == .cleanupTokens { throw LibraryKeepInterruption() } }
        #expect(locked.run(first) == .cleanupPending)
        // Log in to another library, then Keep it too.
        let secondID = "99999999-2222-4333-8444-555555555555"
        let location = LibraryLocation(root: device.root, reference: .server(secondID))
        try await StoreServerLibraryProvisioning(feedVault: { MemoryCredentialVault() }).provision(location, ServerLibraryProvision(
            libraryID: secondID, serverURL: "http://127.0.0.1:1", serverID: "server", accountID: ContractIdentity.randomUUID(),
            namespace: ContractIdentity.randomUUID(), username: "bob", installID: ContractIdentity.randomUUID(), deviceMarker: "marker"))
        try LibraryRegistryFile(root: device.root).update { registry in
            registry.libraries.append(.init(id: secondID, serverURL: "http://127.0.0.1:1", serverID: "server",
                                            accountID: ContractIdentity.randomUUID(), username: "bob", state: .active, createdAt: 0))
            registry.active = .server(secondID)
        }
        let second = try request(device, source: secondID, operation: "ffffffff-ffff-4fff-8fff-ffffffffffff")
        // The Keychain is still locked: the current Keep converts and publishes anyway; the older cleanup waits.
        let result = try #require(try LibraryGraphStart.finishKeep(locked, gate: LibraryGate()))
        #expect(result.manifest.operation == second.operation && result.outcome == .cleanupPending)
        #expect(try device.keep().committed(second))
        #expect(try LibraryGraphStart.converted(device.keep()) == nil)
        #expect(device.registry.standaloneIdentity == secondID && device.registry.libraries.isEmpty)
        #expect(Set(device.registry.conversions.map(\.operation)) == [first.operation, second.operation])
        // The second Keep's markers were never taken by the first one's cleanup; unlocked, both clean up.
        #expect(try LibraryGraphStart.finishKeep(device.keep(), gate: LibraryGate())?.outcome == .finished)
        #expect(device.registry.conversions.isEmpty && device.registry.previous.count == 2)
        #expect(try device.keep().unfinished() == nil)
    }

    // MARK: - A database import before publication

    func pendingPublication(_ device: LibraryKeepTests.Device) throws -> LibraryLocation {
        let failing = device.keep { if $0 == .settingsSpeeds { throw POSIXError(.ENOSPC) } }
        #expect(failing.run(try failing.request(source: LibraryKeepTests.source)) == .notPublished(.storage))
        return try #require(try LibraryGraphStart.converted(device.keep()))
    }

    func stagedImport(_ device: LibraryKeepTests.Device) async throws -> URL {
        let folder = device.root.appendingPathComponent("restore-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("library.sqlite")
        let staged = try FeedLibraryStore(url: url)
        _ = try await staged.insert(ServerLibraryFixture.fetched("https://imported.example/feed", title: "Imported", count: 1))
        try await staged.close()
        return url
    }

    @Test func anImportBeforePublicationPublishesTheKeepFirstAndOpensTheImport() async throws {
        let device = try await fixture.device()
        defer { fixture.remove(device) }
        let converted = try pendingPublication(device)
        let staged = try await stagedImport(device)
        // `AppDelegate.importDatabase` under the exclusive gate with the graph stopped.
        let gate = LibraryGate()
        await gate.acquireExclusive()
        let target = try LibraryGraphStart.importTarget(current: converted, identity: LibraryKeepTests.source, keep: device.keep())
        #expect(target.keep == .finished && target.location.converted == nil && target.location.reference == .standalone)
        try await LibraryReplacement.replace(live: target.location.database, with: staged)
        gate.releaseExclusive()
        // The next graph start opens the import, not an empty library.
        #expect(try LibraryGraphStart.finishKeep(device.keep(), gate: gate) == nil)
        let next = try LibraryGraphStart.converted(device.keep())
            ?? LibraryLocation(root: device.root, reference: try LibraryRegistryFile(root: device.root).openingLibrary())
        let opened = try FeedLibraryStore(url: next.database, ownedRoot: next.ownedRoot)
        #expect(try await opened.feeds().map(\.title) == ["Imported"])
        try await opened.close()
        #expect(LibraryLocation.isAbsent(device.source.folder), "no empty server library was created")
    }

    /// When publication still fails, nothing is replaced: the converted library and its commit stay.
    @Test func anImportWaitsWhileTheKeepStillCannotPublish() async throws {
        let device = try await fixture.device()
        defer { fixture.remove(device) }
        let converted = try pendingPublication(device)
        let stillFull = device.keep { if $0 == .settingsSpeeds { throw POSIXError(.ENOSPC) } }
        #expect(throws: LibraryImportBlocked(keep: .storage)) {
            try LibraryGraphStart.importTarget(current: converted, identity: LibraryKeepTests.source, keep: stillFull)
        }
        #expect(try LibraryDatabaseInspection.identity(of: converted.database)?.keepRole == .converted)
        #expect(try LibraryGraphStart.converted(device.keep()) != nil)
        // A library that is no longer the one the import began on is never replaced either.
        #expect(throws: FeedLibraryError.closed) {
            try LibraryGraphStart.importTarget(current: converted, identity: ContractIdentity.randomUUID(), keep: device.keep())
        }
    }

    // MARK: - Playback started while the Keep waits is never stopped by it

    @MainActor final class Graph {
        var retired = false, playing = false
        var events: [String] = []
        /// A Play from another scene, the system controls or the widget: admitted unless the graph is retired.
        func play() { if !retired { playing = true; events.append("play admitted") } else { events.append("play refused") } }
    }

    @Test func theKeepRetiresCommandsInTheSameStepAsItsActivationCheck() async {
        let graph = Graph()
        var play: Task<Void, Never>?
        let runtime = LibraryKeepRuntime(gate: LibraryGate(), mayRun: {
            graph.events.append("check")
            // A Play arrives just after the check, before the Keep's first wait.
            play = Task { @MainActor in graph.play() }
            return !graph.playing
        }, retire: {
            graph.retired = true; graph.events.append("retire")
        }, stop: {
            // The account-policy writes settle: anything waiting runs now.
            await Task.yield(); await Task.yield()
            graph.events.append(graph.playing ? "stop stops playback" : "stop")
        }, keep: { graph.events.append("keep") }, restart: { graph.events.append("restart") })
        #expect(await runtime.run())
        await play?.value
        #expect(!graph.playing)
        #expect(graph.events.prefix(2) == ["check", "retire"] && graph.events.contains("play refused") && graph.events.contains("stop"))
        #expect(!graph.events.contains("stop stops playback"))
    }

    @Test func playbackAdmittedBeforeTheCheckLeavesTheGraphRunning() async {
        let graph = Graph()
        graph.play()
        let runtime = LibraryKeepRuntime(gate: LibraryGate(), mayRun: { !graph.playing }, retire: { graph.retired = true },
                                         stop: {}, keep: { graph.events.append("keep") }, restart: {})
        #expect(await runtime.run() == false)
        #expect(!graph.retired && graph.playing && !graph.events.contains("keep"))
    }

    // MARK: - An export resolves its library once it holds the gate

    @Test func anExportThatWaitedThroughAKeepReadsTheLibraryWhereItIsNow() async throws {
        let device = try await fixture.device()
        defer { fixture.remove(device) }
        let store = try FeedLibraryStore(url: device.source.database)
        let captured = LibraryExport.OpenLibrary(store: store, identity: LibraryKeepTests.source, speeds: .init())
        try await store.close()
        let keep = device.keep()
        #expect(keep.run(try keep.request(source: LibraryKeepTests.source)) == .finished)
        let exported = try await LibraryExport.collect(identity: LibraryKeepTests.source, root: device.root, open: captured,
                                                       vault: MemoryCredentialVault(), gate: LibraryGate())
        #expect(exported.feeds.map(\.title) == ["Server"])
        #expect(exported.speeds.feeds.values.sorted() == [2.0], "the root's speeds, now S's own")
    }

    @Test func theOpenLibraryIsAskedForOnlyOnceTheGateIsHeld() async throws {
        let device = try await fixture.device()
        defer { fixture.remove(device) }
        let gate = LibraryGate()
        await gate.acquireExclusive()
        let graph = Graph()
        let root = device.root
        let export = Task { @MainActor in
            try await LibraryExport.collect(identity: LibraryKeepTests.source, root: root, current: {
                graph.events.append("asked"); return nil
            }, vault: MemoryCredentialVault(), gate: gate)
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(graph.events.isEmpty)
        gate.releaseExclusive()
        #expect(try await export.value.feeds.map(\.title) == ["Server"])
        #expect(graph.events == ["asked"])
    }

    // MARK: - A credential that cannot be read fails the database export

    final class LockedVault: SynchronizationCredentialStore, @unchecked Sendable {
        func insert(_ password: String, id: UUID) throws {}
        func password(id: UUID) throws -> String { throw SynchronizationCredentialError.keychain(errSecInteractionNotAllowed) }
        func remove(id: UUID) throws {}
    }

    /// A Keychain that reports an item as gone, as `KeychainSynchronizationCredentials` does.
    final class MissingVault: SynchronizationCredentialStore, @unchecked Sendable {
        let base = MemoryCredentialVault()
        func insert(_ password: String, id: UUID) throws { try base.insert(password, id: id) }
        func remove(id: UUID) throws { try base.remove(id: id) }
        func password(id: UUID) throws -> String {
            guard base.contains(id) else { throw SynchronizationCredentialError.missing }
            return try base.password(id: id)
        }
    }

    /// Only the database export carries credentials: it refuses a backup without a visible feed's login, while OPML,
    /// HTML and favorites HTML are written.
    @Test func anUnreadableFeedCredentialFailsTheDatabaseExportOnly() async throws {
        let device = try await fixture.device()
        defer { fixture.remove(device) }
        let store = try FeedLibraryStore(url: device.source.database)
        let feed = try #require(try await store.feeds().first { $0.title == "Server" })
        let vault = MemoryCredentialVault()
        try await FeedAuthentication(store: store, vault: vault).save(.init(username: "subscriber", password: "private-feed-password"), feedID: feed.id)
        let open = LibraryExport.OpenLibrary(store: store, identity: LibraryKeepTests.source, speeds: .init())
        let locked = try await LibraryExport.collect(identity: LibraryKeepTests.source, root: device.root, open: open, vault: LockedVault(), gate: LibraryGate())
        #expect(throws: SynchronizationCredentialError.keychain(errSecInteractionNotAllowed)) { _ = try locked.databaseData() }
        #expect(try locked.opmlData().count > 0)
        #expect(locked.htmlData(favorites: false).count > 0 && locked.htmlData(favorites: true).count > 0)
        let exported = try await LibraryExport.collect(identity: LibraryKeepTests.source, root: device.root, open: open, vault: vault, gate: LibraryGate())
        #expect(exported.credentials[feed.id]?.username == "subscriber")
        #expect(try exported.databaseData().count > 0)
        try await store.close()
    }

    /// A stale credential (its Keychain item gone) of a visible feed: the same, the database export alone refuses.
    @Test func aStaleCredentialStopsOnlyTheDatabaseExport() async throws {
        let device = try await fixture.device()
        defer { fixture.remove(device) }
        let store = try FeedLibraryStore(url: device.source.database)
        let feed = try #require(try await store.feeds().first { $0.title == "Server" })
        let vault = MissingVault()
        try await FeedAuthentication(store: store, vault: vault).save(.init(username: "private", password: "secret"), feedID: feed.id)
        try vault.remove(id: try #require(try await store.feedCredentialID(feedID: feed.id)))
        let source = try await LibraryExport.collect(identity: LibraryKeepTests.source, root: device.root,
            open: .init(store: store, identity: LibraryKeepTests.source, speeds: .init()), vault: vault, gate: LibraryGate())
        #expect(throws: SynchronizationCredentialError.missing) { _ = try source.databaseData() }
        #expect(try source.opmlData().count > 0 && source.htmlData(favorites: false).count > 0)
        try await store.close()
    }

    /// A podcast the export leaves out (a pinned removal) never holds it back with its credential;
    /// the included feeds' credentials are still required and written.
    @Test func anExcludedPodcastsCredentialNeverStopsABackup() async throws {
        let device = try await fixture.device()
        defer { fixture.remove(device) }
        let store = try FeedLibraryStore(url: device.source.database)
        // The pinned removal is in no library-wide read; its row is found directly.
        let removed = try #require(try RawLibrary.rows(device.source.database, "SELECT id FROM feeds WHERE title = 'Removed'").first?.first.flatMap { $0 }.flatMap(Int64.init))
        let visible = try #require(try await store.feeds().first { $0.title == "Server" })
        #expect(try await store.feeds().allSatisfy { $0.id != removed })
        let vault = MissingVault()
        let authentication = FeedAuthentication(store: store, vault: vault)
        try await authentication.save(.init(username: "gone", password: "stale"), feedID: removed)
        try vault.remove(id: try #require(try await store.feedCredentialID(feedID: removed)))
        try await authentication.save(.init(username: "kept", password: "secret"), feedID: visible.id)
        let source = try await LibraryExport.collect(identity: LibraryKeepTests.source, root: device.root,
            open: .init(store: store, identity: LibraryKeepTests.source, speeds: .init()), vault: vault, gate: LibraryGate())
        #expect(source.feeds.map(\.title) == ["Server"], "the pinned removal is left out")
        #expect(source.credentialFailure == nil && source.credentials.keys.sorted() == [visible.id])
        #expect(source.credentials[visible.id]?.username == "kept")
        #expect(try source.databaseData().count > 0)
        try await store.close()
    }

    // MARK: - Download records after a restore and at adoption

    @Test func aRestoredBackupsResumeDataFollowsItsNewContainer() async throws {
        let original = try await fixture.device()
        defer { fixture.remove(original) }
        let keep = original.keep()
        #expect(keep.run(try keep.request(source: LibraryKeepTests.source)) == .finished)
        let saved = Data("opaque-urlsession-resume-data".utf8)
        try BackgroundMediaDownloads.Files(destination: original.root.appendingPathComponent("media/episode-x.media")).writeResumeData(saved)
        let restored = try fixture.copy(original)
        defer { fixture.remove(restored) }
        try await FeedLibraryStore(url: restored.root.appendingPathComponent("library.sqlite")).close()
        let destination = restored.root.appendingPathComponent("media/episode-x.media")
        let expected = BackgroundMediaDownloads.TaskRecord(destination: destination.standardizedFileURL.path, base: 0, library: LibraryKeepTests.source)
        #expect(BackgroundMediaDownloads.Files(destination: destination).resumeData(matching: expected) == saved)
        // Another request (another base) still never takes it.
        var other = expected; other.base = 10
        #expect(BackgroundMediaDownloads.Files(destination: destination).resumeData(matching: other) == nil)
    }

    /// A live task still described with its library's former folder is adopted for the job at the current folder,
    /// without waiting for the asynchronous normalization; another library's task at another path is not. (A live
    /// background URLSession cannot run in host tests: this is the comparison `transfer` makes under the move lock.)
    @Test func aLiveTaskIsAdoptedByItsResolvedRecord() throws {
        let downloads = BackgroundMediaDownloads(identifier: "test-\(UUID())")
        let old = "/old-root/Server Libraries/\(LibraryKeepTests.source)/media/episode-x.media"
        let current = "/new-root/media/episode-x.media"
        downloads.setResolver { destination, library in
            library == LibraryKeepTests.source && destination == old ? current : destination
        }
        let live = BackgroundMediaDownloads.describe(.init(destination: old, base: 0, library: LibraryKeepTests.source))
        #expect(downloads.adopts(live, as: .init(destination: current, base: 0, library: LibraryKeepTests.source)))
        #expect(!downloads.adopts(live, as: .init(destination: current, base: 5, library: LibraryKeepTests.source)))
        let foreign = BackgroundMediaDownloads.describe(.init(destination: "/old-root/media/episode-x.media", base: 0, library: "other"))
        #expect(!downloads.adopts(foreign, as: .init(destination: current, base: 0, library: LibraryKeepTests.source)))
    }
}
