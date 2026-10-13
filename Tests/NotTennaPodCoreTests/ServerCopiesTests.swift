import Foundation
import Testing
@testable import NotTennaPodCore

/// Copies, transport conflicts and already-superseded predecessors against the pinned server (PROTOCOL §6.10–3,
/// scenario 22 PROTOCOL §16, §6.10): a copy forks every author and takes a new installation before it sends anything, a
/// library whose transport another one used takes a new one with a fresh nonce, and every library keeps working;
/// nothing is lost or applied twice. Session copies (tail exports, copied pending transitions) are tested with
/// playback.
@Suite(.serialized, .timeLimit(.minutes(30))) struct ServerCopiesTests {
    typealias Agreement = ServerExchangeAgreementTests
    typealias PushPull = ServerExchangePushPullTests

    /// Exchanges until the server's own fetch of the podcast reached the phone, so an attachment sees every episode.
    static func waitForCatalog(_ phone: DevicePhone, feedID: Int64) async throws {
        let clock = ContinuousClock(), end = clock.now.advanced(by: .seconds(60))
        var requested = false
        while clock.now < end {
            await phone.exchange()
            if let podcast = try await phone.store.podcastOfFeedForTesting(feedID) {
                if try phone.rows("SELECT count(*) FROM ntp_records WHERE entity = 'podcast' AND id = '\(podcast)' AND field_group = 'metadata'") == [["1"]] {
                    return
                }
                if !requested { _ = try? await phone.transport.server.send("POST", "v1/refresh", body: ["podcast_id": .string(podcast)]); requested = true }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("\(phone.name): the catalog never arrived")
    }

    /// A phone with the five-episode podcast, its catalog arrived.
    static func subscribed(_ world: ExchangeWorld, _ name: String = "A") async throws -> (phone: DevicePhone, ids: [Int64]) {
        let phone = try await world.device(name)
        let feed = try await phone.store.insert(Agreement.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
        try await waitForCatalog(phone, feedID: feed.id)
        return (phone, feed.episodes.map(\.id).sorted())
    }

    static func facts(_ phone: DevicePhone, type: String) throws -> Int {
        Int(try phone.rows("SELECT count(*) FROM ntp_outbox WHERE type = '\(type)'")[0][0] ?? "0") ?? 0
    }

    /// 22. A phone backup restored onto a new phone: both run. The copy detects itself before it sends anything, forks
    /// its author onto a new installation, signs in again once (its tokens stayed on the old device), and no change is
    /// lost or applied twice; the original's installation keeps working.
    @Test func scenario22ACopyOnANewDeviceForksAndBothKeepWorking() async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Self.subscribed(world)
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            await a.exchange()
            // Unconfirmed changes the backup carries: both libraries hold them.
            try await a.store.markEpisodePlayed(episodeID: ids[1], played: true)
            _ = try await a.store.enqueue([ids[4]])
            let copy = try await a.copy("A-copy", root: world.root)
            let original = try await a.installID()
            try await a.store.setFavorite(episodeID: ids[2], favorite: true)
            await a.exchange()
            let first = await copy.engine.exchange()
            #expect(first.pause == .signIn, "the copy's new installation signs in first: \(String(describing: first.pause))")
            #expect(try await copy.installID() != original)
            #expect(try copy.rows("SELECT main_author = install_id FROM ntp_library") == [["1"]], "F = T'")
            #expect(try Self.facts(copy, type: "installation.fork") == 1)
            #expect(try await copy.log().contains { $0.kind == "copy" })
            #expect(try await copy.signInAgain() == (try await copy.installID()))
            try await copy.store.markEpisodePlayed(episodeID: ids[3], played: true)
            try await world.converge([a, copy], "copy")
            #expect(try await a.installID() == original, "the original keeps its installation")
            let view = try await a.view()
            #expect(view.queue.count == 1, "the copied queue add applied once")
            for id in ids.prefix(4) {
                let wire = try #require(try await a.store.wireEpisodeForTesting(id))
                #expect(id == ids[0] || id == ids[2] ? view.episodes[wire]?.favorite == true : view.episodes[wire]?.playState == .played)
            }
            await copy.close(); await a.close()
        }
    }

    /// A copy made while a subscription waits for its registration (drafts on the registration's author): both
    /// libraries materialize the copied drafts (the server takes them once, by op ID), the copy's registration author
    /// forks as a draft of it and its later drafts follow the fork (PROTOCOL §6.10).
    @Test func aCopyWithAPendingRegistrationAndDraftsConverges() async throws {
        try await ExchangeWorld.run { world in
            let (a, _) = try await Self.subscribed(world)
            world.server.stop(keepingData: true)
            let two = try await a.store.insert(Agreement.fetched(world.url("two.xml"), title: "Two", prefix: "two", count: 3))
            let pending = two.episodes.map(\.id).sorted()
            try await a.store.setFavorite(episodeID: pending[0], favorite: true)
            try await a.store.markEpisodePlayed(episodeID: pending[1], played: true)
            let copy = try await a.copy("A-copy", root: world.root)
            try await world.server.launch()
            _ = await copy.engine.exchange()
            try await copy.signInAgain()
            #expect(try copy.rows("SELECT count(DISTINCT author_id), sum(kind = 'installation.fork') FROM ntp_drafts") == [["2", "1"]],
                    "the registration's chain forked as a draft")
            try await copy.store.setFavorite(episodeID: pending[2], favorite: true)
            try await a.store.setFavorite(episodeID: pending[1], favorite: true)
            try await world.converge([a, copy], "registration copy")
            #expect(try copy.rows("SELECT count(*) FROM ntp_drafts") == [["0"]] && a.rows("SELECT count(*) FROM ntp_drafts") == [["0"]])
            let view = try await copy.view()
            let wires = try await pending.asyncMap { try #require(try await copy.store.wireEpisodeForTesting($0)) }
            #expect(view.episodes[wires[0]]?.favorite == true && view.episodes[wires[2]]?.favorite == true && view.episodes[wires[1]]?.favorite == true)
            #expect(view.episodes[wires[1]]?.playState == .played)
            await copy.close(); await a.close()
        }
    }

    /// Two working libraries on one transport (PROTOCOL §6.10): the second to push meets `installation_conflict`, takes a
    /// new installation with a fresh nonce (issued with its current token, so the other library's installation and
    /// credentials are left alone) and pushes again; both keep working and converge.
    @Test func aTransportConflictBetweenTwoWorkingLibrariesLeavesBothWorking() async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Self.subscribed(world)
            await a.exchange()
            let twin = try await a.copy("A-twin", root: world.root, keychain: .same)
            let shared = try await a.installID()
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            try await twin.store.markEpisodePlayed(episodeID: ids[1], played: true)
            await a.exchange()
            await twin.exchange()
            #expect(try await twin.installID() != shared, "the twin moved to a new installation")
            #expect(try await twin.log().contains { $0.kind == "transition" && $0.detail.hasPrefix("conflict") })
            #expect(try await a.installID() == shared)
            try await a.store.setFavorite(episodeID: ids[2], favorite: true)
            try await twin.store.setFavorite(episodeID: ids[3], favorite: true)
            try await world.converge([a, twin], "conflict")
            let view = try await a.view()
            #expect(view.episodes[try #require(try await a.store.wireEpisodeForTesting(ids[1]))]?.playState == .played)
            #expect(view.episodes[try #require(try await a.store.wireEpisodeForTesting(ids[3]))]?.favorite == true)
            await twin.close(); await a.close()
        }
    }

    /// An already-superseded predecessor (PROTOCOL §6.10): another library took a successor of this installation with its nonce.
    /// The successor request answers `installation_superseded` (not used yet), or the installation's credentials were
    /// revoked once the successor was used (`401`, and signing in with it answers `installation_superseded`): this
    /// library signs in again with a new installation and its fresh nonce, keeping everything local.
    @Test(arguments: [false, true]) func anAlreadySupersededPredecessorSignsInAgainWithANewInstallation(used: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Self.subscribed(world)
            await a.exchange()
            let install = try await a.installID()
            let item = try #require(try a.secrets.installation(library: a.libraryID, install: install))
            let other = try await NTPClient(base: world.server.base, token: item.token).send("POST", "v1/installations/successor", [
                "install_id": .string(ContractIdentity.randomUUID()), "instance_nonce": .string(item.transportNonce),
                "device": ["name": "Another copy", "app_version": "test", "capabilities": ["favorites", "history", "inbox", "queue", "statistics"]]])
            if used { _ = try await NTPClient(base: world.server.base, token: other["token"]?.stringValue).send("GET", "v1/installations") }
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            let paused = await a.engine.exchange()
            #expect(paused.pause == .signIn, "\(String(describing: paused.pause)) \(paused.error ?? "")")
            #expect(try await a.store.serverUnsentChanges() == 1, "the change is kept")
            let signedIn = try await a.signInAgain()
            #expect(signedIn != install, "signed in with a new installation")
            try await a.store.setFavorite(episodeID: ids[1], favorite: true)
            try await world.converge([a], used ? "superseded-used" : "superseded")
            #expect(try await a.installID() == signedIn)
            #expect(try a.secrets.installIDs(of: a.libraryID) == [signedIn], "the predecessor's token went after the transition")
            await a.close()
        }
    }

    /// A crash (a failure after a commit, before the next step) at every handoff step of a copy's detection and its
    /// installation transition, issued with a working token (PROTOCOL §6.10–3): after a relaunch the transition
    /// finishes once, the original keeps working, and nothing is lost or applied twice.
    @Test(arguments: ["copy.detected", "transition.token", "transition.issued", "transition.committed"])
    func aCrashAtEveryHandoffStepOfACopyResumes(point: String) async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Self.subscribed(world)
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            let copy = try await a.copy("A-copy", root: world.root, keychain: .tokens)
            try await copy.store.markEpisodePlayed(episodeID: ids[1], played: true)
            await copy.engine.setCrashPoint(PushPull.crashOnce(at: point))
            let crashed = await copy.engine.exchange()
            #expect(crashed.error == "InjectedCrash()", "\(point): \(crashed.error ?? "no crash")")
            try await copy.relaunch()
            await copy.exchange()
            #expect(try await copy.installID() != (try await a.installID()), "\(point): a new installation")
            #expect(try copy.rows("SELECT transition FROM ntp_library") == [[nil]], "\(point): the transition committed")
            #expect(try Self.facts(copy, type: "installation.fork") <= 1)
            try await a.store.setFavorite(episodeID: ids[2], favorite: true)
            try await world.converge([a, copy], point)
            await copy.close(); await a.close()
        }
    }
}
