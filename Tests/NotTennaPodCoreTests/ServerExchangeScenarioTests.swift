import Foundation
import Testing
@testable import NotTennaPodCore

/// PROTOCOL §16 scenarios 1–4 and 20–23, as far as the exchange's parts reach. Recovery after a restore,
/// copy detection and a new lineage's first attachment are tested elsewhere (`ServerRecoveryTests`,
/// `ServerCopiesTests`, `ServerStartOverTests`); these phones' engines have no Keychain items for installation
/// transitions, so they stop at the pause or conflict that hands over to them, with nothing lost.
@Suite(.serialized, .timeLimit(.minutes(30))) struct ServerExchangeScenarioTests {
    typealias Agreement = ServerExchangeAgreementTests
    typealias Concurrency = ServerExchangeConcurrencyTests

    /// 1. With the server stopped, phones keep working: they mark, queue, reorder and favorite; nothing is lost, and
    /// every device converges once the server returns.
    @Test func scenario1AnOutageLosesNothing() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            world.server.stop(keepingData: true)
            try await a.store.markEpisodePlayed(episodeID: ids[0], played: true)
            _ = try await a.store.enqueue([ids[1], ids[2], ids[3]])
            _ = try await a.store.performQueueMove(.item(ids[3], finalIndex: 0), expected: try await a.store.queue().map(QueueEpisodeIdentity.init))
            try await a.store.setFavorite(episodeID: ids[4], favorite: true)
            try await c.store.setFavorite(episodeID: try await Concurrency.same(ids[1], from: a, on: c), favorite: true)
            let offline = await a.engine.exchange()
            #expect(offline.retryAfter != nil && offline.pause == nil, "an outage only backs off")
            let local = try await a.view()
            try await world.server.launch()
            try await Concurrency.converge(world, [a, c], "outage")
            #expect(try await a.store.serverUnsentChanges() == 0)
            let after = try await a.view()
            #expect(after.queue == local.queue)
            #expect(after.episodes[try #require(try await a.store.wireEpisodeForTesting(ids[0]))]?.playState == .played)
            #expect(after.episodes[try #require(try await a.store.wireEpisodeForTesting(ids[1]))]?.favorite == true, "C's change arrived")
        }
    }

    /// 3. Launched while the server is unreachable and the sign-in has expired: the library opens at once and works;
    /// sync asks to sign in again and keeps every change.
    @Test func scenario3AnUnreachableServerAndAnExpiredSignIn() async throws {
        try await ExchangeWorld.run { world in
            let (a, _, _, ids, _) = try await Concurrency.twoPhones(world)
            // The token is revoked (expired), and the server is down when the app launches.
            _ = try await NTPClient(base: world.server.base, token: a.tokenBox.value).send("POST", "v1/auth/device/sign-out", .object(ContractObject()))
            world.server.stop(keepingData: true)
            let clock = ContinuousClock(), started = clock.now
            try await a.relaunch()
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            #expect(started.duration(to: clock.now) < .seconds(5), "the library opens and works without the server")
            #expect(await a.engine.exchange().retryAfter != nil)
            try await world.server.launch()
            #expect(await a.engine.exchange().pause == .signIn)
            #expect(try await a.store.episode(id: ids[0])?.userState.isFavorite == true)
            try await a.signInAgain(world.server)
            await a.exchange()
            #expect(try await a.store.serverUnsentChanges() == 0)
            try await Agreement.expectAgreement(world, a, "signed in again")
        }
    }

    /// 4. A subscription made during an outage completes when the server returns, with what was done to it meanwhile.
    @Test func scenario4ASubscriptionDuringAnOutage() async throws {
        try await ExchangeWorld.run { world in
            let a = try await world.attach("A")
            world.server.stop(keepingData: true)
            let two = try await a.store.insert(Agreement.fetched(world.url("two.xml"), title: "Two", prefix: "two", count: 3))
            let ids = two.episodes.map(\.id).sorted()
            try await a.store.markEpisodePlayed(episodeID: ids[0], played: true)
            try await a.store.setFavorite(episodeID: ids[1], favorite: true)
            _ = try await a.store.enqueue([ids[2]])
            #expect(try a.rows("SELECT count(*) FROM ntp_drafts") == [["3"]])
            try await world.server.launch()
            try await Agreement.waitForCatalog(a, feedID: two.id)
            #expect(try a.rows("SELECT count(*) FROM ntp_drafts") == [["0"]])
            try await Agreement.expectAgreement(world, a, "outage subscription")
        }
    }

    /// 20. The server is restored from an older backup: sync signs in again, finds the lineage changed and pauses for
    /// recovery; the library, its rows and its acknowledged facts are kept.
    @Test func scenario20ARestoredServerPausesForRecoveryKeepingEverything() async throws {
        try await ExchangeWorld.run { world in
            let (a, _, _, ids, _) = try await Concurrency.twoPhones(world)
            let keys = world.root.appendingPathComponent("keys.bundle"), backups = world.root.appendingPathComponent("backups")
            let passphrase = world.root.appendingPathComponent("passphrase")
            try Data("a test passphrase\n".utf8).write(to: passphrase)
            world.server.stop(keepingData: true)
            _ = try world.server.command(["keys", "export", "--data-dir", world.server.data.path, "--out", keys.path, "--passphrase-file", passphrase.path])
            _ = try world.server.command(["backup", "--data-dir", world.server.data.path, "--out", backups.path])
            try await world.server.launch()
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            await a.exchange()
            let before = try await a.view()
            world.server.stop(keepingData: true)
            let backup = try #require(try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).first)
            _ = try world.server.command(["restore", "--data-dir", world.server.data.path, "--from", backup.path, "--keys", keys.path,
                                          "--passphrase-file", passphrase.path])
            try await world.server.launch()
            #expect(await a.engine.exchange().pause == .signIn, "a restore removes every token")
            try await a.signInAgain(world.server)
            #expect(await a.engine.exchange().pause == .lineageMismatch, "the history differs: recovery handles it")
            #expect(try await a.view() == before, "nothing local changed")
            #expect(try a.rows("SELECT pause_reason FROM ntp_library") == [["lineage_mismatch"]])
        }
    }

    /// 21. The server is replaced by an empty one without a backup: no phone is emptied and sync pauses with an
    /// explanation (`lineage_unknown`).
    @Test func scenario21AnEmptyServerPausesWithoutEmptyingThePhone() async throws {
        try await ExchangeWorld.run { world in
            let (a, _, _, ids, _) = try await Concurrency.twoPhones(world)
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            await a.exchange()
            try await a.store.markEpisodePlayed(episodeID: ids[1], played: true)
            let before = try await a.view()
            try world.server.wipe()
            try await world.server.launch()
            try await world.server.setUp()
            #expect(await a.engine.exchange().pause == .signIn)
            try await a.signInAgain(world.server)
            #expect(await a.engine.exchange().pause == .lineageUnknown)
            #expect(try await a.view() == before, "the phone keeps its library")
            #expect(try await a.store.serverUnsentChanges() == 1, "and its unsent change")
        }
    }

    /// 22. A copy of a library (a phone backup restored onto a new phone) runs beside the original: when both write the
    /// same transport slots, the second is refused as a transport conflict and keeps its changes.
    @Test func scenario22ACopyMeetsATransportConflictAndKeepsItsChanges() async throws {
        try await ExchangeWorld.run { world in
            let (a, _, _, ids, _) = try await Concurrency.twoPhones(world)
            await a.exchange()
            await a.engine.close()
            try await a.store.close()
            let copy = LibraryLocation(root: world.root, reference: .server(ContractIdentity.randomUUID()))
            try FileManager.default.copyItem(at: a.location.folder, to: copy.folder)
            try await a.relaunch()
            let copyStore = try FeedLibraryStore(url: copy.database)
            let vault = MemoryCredentialVault()
            let copyEngine = try ServerSyncEngine(store: copyStore, location: copy, transport: a.transport, vault: vault)
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            try await copyStore.markEpisodePlayed(episodeID: ids[1], played: true)
            await a.exchange()
            let report = await copyEngine.exchange()
            #expect(report.pause == .transportConflict)
            #expect(try await copyEngine.logEntries().contains { $0.kind == "paused" && $0.detail.hasPrefix("transport_conflict") },
                    "the cause is in the synchronization log")
            #expect(try await copyStore.serverUnsentChanges() == 1, "the copy keeps its change")
            #expect(try await copyStore.episode(id: ids[1])?.userState.playState == .played)
            await copyEngine.close()
            try await copyStore.close()
        }
    }

    /// 23. First attachment of a phone with a standalone library adopts the server's library, reuses its downloaded
    /// files as clones, and leaves the standalone library unchanged.
    @Test func scenario23FirstAttachmentReusesDownloadsAndKeepsStandalone() async throws {
        try await ExchangeWorld.run { world in
            // The standalone library in the same Application Support folder, with one download.
            let standalone = LibraryLocation(root: world.root, reference: .standalone)
            let local = try FeedLibraryStore(url: standalone.database)
            let feed = try await local.insert(Agreement.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            let downloaded = try #require(feed.episodes.first { $0.details.identifier == "one-3" })
            let file = standalone.media.appendingPathComponent("one-3.mp3")
            try FileManager.default.createDirectory(at: standalone.media, withIntermediateDirectories: true)
            try Data(repeating: 7, count: 1_000).write(to: file)
            try await local.projectForTesting(downloaded.id) {
                $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path; $0.userState.downloadDate = Date(timeIntervalSince1970: 1_760_000_000)
            }
            let standaloneBefore = try ServerLibraryFixture.read(standalone.database, "SELECT id, record FROM episodes ORDER BY id")
            try await local.close()
            // The account's library (made by another phone).
            let a = try await world.attach("A")
            let one = try await a.store.insert(Agreement.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            try await Agreement.waitForCatalog(a, feedID: one.id)
            let b = try await world.attach("B")
            let reused = try #require(try await b.store.feeds().flatMap(\.episodes).first { $0.details.identifier == "one-3" })
            #expect(reused.userState.isDownloaded)
            let clone = try #require(reused.userState.localFileURL)
            #expect(clone.hasPrefix(b.location.media.path), "the clone is in the server library's own media folder")
            #expect(try Data(contentsOf: URL(fileURLWithPath: clone)) == Data(repeating: 7, count: 1_000))
            #expect(reused.userState.downloadDate == Date(timeIntervalSince1970: 1_760_000_000))
            #expect(try ServerLibraryFixture.read(standalone.database, "SELECT id, record FROM episodes ORDER BY id") == standaloneBefore,
                    "the standalone library is unchanged")
            try FileManager.default.removeItem(atPath: clone)
            #expect(FileManager.default.fileExists(atPath: file.path), "deleting one library's download keeps the other's")
        }
    }
}

extension ServerExchangeScenarioTests {
    /// PROTOCOL §15.4: an attachment that fails before its projection commits (a secret it cannot fetch yet) leaves no projected
    /// row and stays attaching; the next attempt, with a newer snapshot, completes it.
    @Test func anInterruptedAttachmentLeavesNoRowsAndCompletesLater() async throws {
        try await ExchangeWorld.run { world in
            let a = try await world.attach("A")
            let one = try await a.store.insert(Agreement.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            try await Agreement.waitForCatalog(a, feedID: one.id)
            try await FeedAuthentication(store: a.store, vault: a.vault).save(.init(username: "alice", password: "s3cret"), feedID: one.id)
            await a.exchange()
            let installation = try await world.server.signIn()
            let token = installation.client.token ?? ""
            let libraryID = ContractIdentity.randomUUID()
            let location = LibraryLocation(root: world.root, reference: .server(libraryID))
            try location.prepare()
            let provisioning = try FeedLibraryStore(url: location.database)
            try await provisioning.initializeServerLibrary(ServerLibraryIdentity(
                libraryID: libraryID, serverURL: world.server.base.absoluteString, serverID: "test", accountID: installation.accountID,
                namespace: installation.namespace, username: "alice", installID: installation.installID, deviceMarker: nil))
            try await provisioning.close()
            let client = ServerClient(address: ServerAddress(entered: world.server.base.absoluteString)!)
            let transport = ProxyTransport(HTTPServerExchangeTransport(base: world.server.base, token: { token }))
            transport.handler = { method, path, body, server in
                if path.hasPrefix("v1/secrets/") { throw ServerExchangeError.unreachable }
                return try await server.send(method, path, body: body)
            }
            let vault = MemoryCredentialVault()
            let applier = ServerExchangeAttachApplier(vault: { vault }, transport: { _ in transport })
            let target = ServerAttachmentTarget(location: location, libraryID: libraryID, installID: installation.installID, token: token, client: client)
            let first = try await ServerAttachSnapshotDownload(client: client, token: token, installID: installation.installID,
                                                               folder: location.staging!.appendingPathComponent("attach")).run()
            await #expect(throws: ServerExchangeError.unreachable) { try await applier.apply(first, to: target) }
            #expect(try ServerLibraryFixture.read(location.database, "SELECT (SELECT count(*) FROM feeds) + (SELECT count(*) FROM episodes)") == [["0"]],
                    "no projected row")
            #expect(try ServerLibraryFixture.read(location.database, "SELECT cursor FROM ntp_library") == [[nil]])
            // Meanwhile the account changes; the next attempt downloads a newer snapshot.
            try await a.store.setFavorite(episodeID: one.episodes.map(\.id).min()!, favorite: true)
            await a.exchange()
            transport.handler = nil
            let second = try await ServerAttachSnapshotDownload(client: client, token: token, installID: installation.installID,
                                                                folder: location.staging!.appendingPathComponent("attach")).run()
            try await applier.apply(second, to: target)
            let store = try FeedLibraryStore(url: location.database)
            let view = try await store.syncedViewForTesting()
            try await store.close()
            #expect(view.withoutTitles.differences(from: try await a.view().withoutTitles).isEmpty)
            #expect(view.podcasts.values.first?.credentials != nil, "the secret was fetched before the projection")
        }
    }
}
