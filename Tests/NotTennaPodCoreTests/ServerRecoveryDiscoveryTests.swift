import Foundation
import Testing
@testable import NotTennaPodCore

/// Recovery and discovery (PROTOCOL §9; scenarios 32 and 38 PROTOCOL §16) against the pinned server restored with
/// its own commands: the recovery's full snapshot and its holds work with the discovery ledger (`ntp_ledger`), the local
/// items, the observation work and provisional releases of rotating enclosures. A release this phone never saw drives
/// its ledger once; a release it saw keeps its finished work; nothing is lost, repeated or left orphaned.
@Suite(.serialized) struct ServerRecoveryDiscoveryTests {
    typealias Discovery = ServerDiscoveryScenarioTests
    typealias Recovery = ServerRecoveryTests
    typealias Copies = ServerCopiesTests
    typealias PushPull = ServerExchangePushPullTests

    // MARK: - Helpers (as the discovery scenarios', on phones of their own devices)

    static func subscribe(_ phone: DevicePhone, _ url: String) async throws -> LibraryFeed {
        guard case .updated(let fetched) = try await FeedFetcher().fetch(FeedFetchRequest(source: url)) else { throw HarnessError.server("no feed at \(url)") }
        let feed = try await phone.store.insert(fetched)
        try await Copies.waitForCatalog(phone, feedID: feed.id)
        return feed
    }

    static func refresh(_ phone: DevicePhone, _ feedID: Int64) async throws {
        _ = try await FeedRefreshService(store: phone.store).refresh(feedID: feedID, force: true)
        _ = try await phone.store.consumeFeedRefreshQueueEffects(location: .back)
    }

    static func local(_ phone: DevicePhone, guid: String, enclosure: String? = nil) async throws -> LibraryEpisode? {
        try await phone.store.feeds().flatMap(\.episodes).first { $0.details.identifier == guid && (enclosure == nil || $0.details.media?.url == enclosure) }
    }

    static func ledger(_ phone: DevicePhone) throws -> [[String?]] {
        try phone.rows("SELECT occurrence, state, notified FROM ntp_ledger ORDER BY occurrence")
    }

    static func exchange(until condition: @escaping () async throws -> Bool, _ phones: [DevicePhone], label: String) async throws {
        let clock = ContinuousClock(), end = clock.now.advanced(by: .seconds(60))
        while clock.now < end {
            for phone in phones { await phone.exchange() }
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HarnessError.server("\(label): the condition never held")
    }

    static func serverRefresh(_ phone: DevicePhone, podcast: String) async throws {
        _ = try await phone.transport.server.send("POST", "v1/refresh", body: ["podcast_id": .string(podcast)])
    }

    // MARK: - 38: a recovery snapshot's unseen release

    /// 38 (recovery). A finds a release after the backup; B, whose cursor also moved past the backup, never pulled it.
    /// The server is restored; A restores the release; B recovers from a full snapshot that holds it: B's ledger takes it
    /// once (to download and to notify), across a crash in the publication, and nothing brings it back once done: more
    /// exchanges, a relaunch, a repair. A phone attaching afterwards sees it as seen.
    @Test(arguments: [nil, "full.written", "full.published"])
    func scenario38ARecoverySnapshotsUnseenReleaseDrivesTheLedgerOnce(crash point: String?) async throws {
        try await ExchangeWorld.run { world in
            Discovery.serve(world, "/r38.xml", "R38", Discovery.items("r38", 1...3))
            let a = try await world.device("A")
            let feed = try await Self.subscribe(a, world.url("r38.xml"))
            let b = try await world.device("B")
            let backup = try await world.backUp()
            // B's cursor moves past the backup: its recovery takes a full snapshot.
            let r38One = try #require(try await Self.local(a, guid: "r38-1"))
            try await a.store.setFavorite(episodeID: r38One.id, favorite: true)
            await a.exchange(); await b.exchange()
            // A finds a release; B does not exchange again before the restore.
            Discovery.serve(world, "/r38.xml", "R38", Discovery.items("r38", 1...4))
            try await Self.refresh(a, feed.id)
            await a.exchange()
            let found = try #require(try await Self.local(a, guid: "r38-4"))
            let wire = try #require(try await a.store.wireEpisodeForTesting(found.id))
            Discovery.serve(world, "/r38.xml", "R38", Discovery.items("r38", 1...3))
            try await world.restore(backup)
            _ = try await Recovery.recover(a)
            #expect(try Self.ledger(a).filter { $0[0] == wire }.count == 1, "A's own release, once")
            #expect(await b.engine.exchange().pause == .signIn)
            try await b.signInAgain()
            if let point {
                await b.engine.setCrashPoint(PushPull.crashOnce(at: point))
                let crashed = await b.engine.exchange()
                #expect(crashed.error == "InjectedCrash()", "\(point): \(crashed.error ?? "no crash")")
                try await b.relaunch()
            }
            await b.exchange()
            let recovery = try #require(try await Recovery.recovery(b))
            #expect(recovery.finished && recovery.complete == true && recovery.prefix == false, "a full recovery: \(recovery)")
            let release = try #require(try await Self.local(b, guid: "r38-4"))
            #expect(try Self.ledger(b).filter { $0[0] == wire } == [[wire, "pending", "0"]], "a release B never saw drives its ledger")
            #expect(try await b.store.serverReleaseCandidates() == [release.id], "to download")
            let notifications = try await b.store.serverReleaseNotifications()
            #expect(notifications.flatMap(\.keys).map(\.occurrence) == [wire], "to notify about")
            // Done once: nothing brings it back.
            try await b.store.markServerReleasesNotified(notifications.flatMap(\.keys))
            try await b.store.finishServerReleases([release.id])
            await b.exchange(); await b.exchange()
            try await b.relaunch()
            await b.exchange()
            #expect(await b.engine.forceFullSynchronization().reprojected)
            #expect(try Self.ledger(b).filter { $0[0] == wire } == [[wire, "done", "1"]])
            let left = try await b.store.serverReleaseNotifications(), candidates = try await b.store.serverReleaseCandidates()
            #expect(left.isEmpty && candidates == [])
            let c = try await world.attach("C")
            #expect(try c.rows("SELECT state, notified FROM ntp_ledger WHERE occurrence = '\(wire)'") == [["done", "1"]], "an attachment's release is seen")
            await c.close()
            try await world.converge([a, b], "r38 \(point ?? "")")
        }
    }

    // MARK: - Provisional releases of rotating enclosures

    /// A phone alone sees a GUID rotate two enclosures (days 4, 20, 40, 60) after the backup; it sends every occurrence but
    /// is restored before it pulls the server's mapping, so its ledger still keys a provisional release by its row. The
    /// restored server's own fetch disputes the GUID again (the publisher still lists the rotation); the phone's full
    /// recovery snapshot brings that mapping: each row becomes the release of its date, each release has one ledger entry
    /// whose finished work is kept (day 60's done, the others owed once), no row key is left, and the phone converges.
    @Test func provisionalRotatingReleasesKeepOneLedgerEntryThroughAFullRecovery() async throws {
        try await ExchangeWorld.run { world in
            Discovery.serve(world, "/rot.xml", "ROT", Discovery.items("rot", 1...3))
            let a = try await world.device("A")
            let feed = try await Self.subscribe(a, world.url("rot.xml"))
            let podcast = try #require(try await a.store.podcastOfFeedForTesting(feed.id))
            let b = try await world.device("B")
            let backup = try await world.backUp()
            // A's and B's cursors move past the backup.
            let rotOne = try #require(try await Self.local(b, guid: "rot-1"))
            try await b.store.setFavorite(episodeID: rotOne.id, favorite: true)
            await b.exchange(); await a.exchange()
            world.server.stop(keepingData: true)
            let rotating = [(4.0, "a"), (20, "b"), (40, "a"), (60, "b")].map { day, slot in
                Discovery.Item(guid: "rg", title: "Rot \(Int(day))", day: day, enclosure: "https://media.example/rot-\(slot).mp3")
            }
            Discovery.serve(world, "/rot.xml", "ROT", rotating.reversed() + Discovery.items("rot", 1...3))
            try await Self.refresh(a, feed.id)
            let rows = try await a.store.feeds().flatMap(\.episodes).filter { $0.details.identifier == "rg" }
            #expect(rows.count == 4)
            let sixty = try #require(rows.first { $0.details.title == "Rot 60" })
            try await a.store.executeForTesting("UPDATE ntp_ledger SET state = 'done', notified = 1 WHERE occurrence = ?", [.text("local-episode:\(sixty.id)")])
            #expect(try a.rows("SELECT count(*) FROM ntp_ledger WHERE occurrence = 'local-episode:\(sixty.id)'") == [["1"]], "a provisional release keyed by its row")
            try await world.server.launch()
            // Sent and acknowledged, never pulled: then the server is restored.
            _ = await a.engine.run([.push])
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox WHERE receipt IS NULL") == [["0"]])
            try await world.restore(backup)
            // B recovers; the server fetches the feed itself and disputes the GUID before A recovers.
            _ = try await Recovery.recover(b)
            func releases(_ phone: DevicePhone) throws -> Int {
                guard let text = try phone.rows("SELECT CAST(value AS TEXT) FROM ntp_records WHERE entity = 'podcast' AND id = '\(podcast)' AND field_group = 'identity_rules'").first?.first ?? nil else { return 0 }
                return ServerIdentityRules(try ContractJSON.decode(text)).disputedGUIDs["rg"]?.count ?? 0
            }
            try await Self.serverRefresh(b, podcast: podcast)
            try await Self.exchange(until: { try releases(b) == 4 }, [b], label: "the restored server's dispute")
            _ = try await Recovery.recover(a)
            for _ in 0..<2 { await a.exchange() }
            let recovery = try #require(try await Recovery.recovery(a))
            #expect(recovery.finished && recovery.complete == true && recovery.prefix == false, "\(recovery)")
            #expect(try releases(a) == 4)
            let ledger = try Self.ledger(a)
            #expect(try a.rows("SELECT count(*) FROM ntp_ledger WHERE occurrence LIKE 'local-episode:%'") == [["0"]], "no row key is left: \(ledger)")
            for row in try await a.store.feeds().flatMap(\.episodes).filter({ $0.details.identifier == "rg" }) {
                let wire = try #require(try await a.store.wireEpisodeForTesting(row.id), "\(row.details.title ?? ""): mapped")
                #expect(try a.rows("SELECT state, notified FROM ntp_ledger WHERE occurrence = '\(wire)'") == [row.id == sixty.id ? ["done", "1"] : ["pending", "0"]],
                        "\(row.details.title ?? ""): its own follow-ups, once: \(ledger)")
            }
            #expect(try await a.store.serverReleaseNotifications().flatMap(\.keys).count == 3, "the three owed, not four or more")
            try await world.converge([a, b], "rotating recovery")
        }
    }

    // MARK: - 32: discovery's changes through recovery from two replicas

    /// 32 (first admission, occurrence correction, removed/live merge). After the backup, A finds a release (its first
    /// admission; its follow-ups done on A), the server's dispute of a reused GUID moves A's downloaded row onto its later
    /// release (an occurrence correction), and A removes P while Q moves onto P's URL (a removed/live merge, Q's favorite
    /// on it). B pulls all of it. Restored, A and B recover in either order: every effect exactly once (one podcast, the
    /// live state, the file on its release, one ledger entry per release with its work as each phone left it).
    @Test(arguments: [true, false]) func scenario32DiscoveryChangesRecoverFromTwoReplicasInEitherOrder(authorFirst: Bool) async throws {
        try await ExchangeWorld.run { world in
            let merged = Discovery.items("m", 1...3)
            Discovery.serve(world, "/p.xml", "Merged", merged)
            Discovery.serve(world, "/q.xml", "Merged", merged)
            let later = Discovery.Item(guid: "rd", title: "Later", day: 30, enclosure: "https://media.example/rd-later.mp3")
            Discovery.serve(world, "/d.xml", "D", Discovery.items("d", 1...3) + [later])
            let a = try await world.device("A")
            let pFeed = try await Self.subscribe(a, world.url("p.xml"))
            let qFeed = try await Self.subscribe(a, world.url("q.xml"))
            let dFeed = try await Self.subscribe(a, world.url("d.xml"))
            let p = try #require(try await a.store.podcastOfFeedForTesting(pFeed.id))
            let q = try #require(try await a.store.podcastOfFeedForTesting(qFeed.id))
            let d = try #require(try await a.store.podcastOfFeedForTesting(dFeed.id))
            let row = try #require(try await Self.local(a, guid: "rd"))
            let file = world.root.appendingPathComponent("rd-later.media")
            try Data([3, 0]).write(to: file)
            try await a.store.projectForTesting(row.id) { $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path }
            let b = try await world.device("B")
            await a.exchange()
            let backup = try await world.backUp()
            // First admission: A finds d-4; its follow-ups are done on A.
            let newest = Discovery.Item(guid: "d-4", title: "d 4", day: 31, enclosure: "https://media.example/d-4.mp3")
            Discovery.serve(world, "/d.xml", "D", Discovery.items("d", 1...3) + [later, newest])
            try await Self.refresh(a, dFeed.id)
            await a.exchange()
            let four = try #require(try await Self.local(a, guid: "d-4"))
            let fourWire = try #require(try await a.store.wireEpisodeForTesting(four.id))
            try await a.store.markServerReleasesNotified(try await a.store.serverReleaseNotifications().flatMap(\.keys))
            try await a.store.finishServerReleases([four.id])
            // Occurrence correction: the publisher lists an older occurrence of rd; the server's dispute moves A's row.
            Discovery.serve(world, "/d.xml", "D", Discovery.items("d", 1...3) + [later, newest, Discovery.Item(guid: "rd", title: "Older", day: 1, enclosure: "https://media.example/rd-older.mp3")])
            try await Self.serverRefresh(a, podcast: d)
            try await Self.exchange(until: {
                let rules = try a.rows("SELECT CAST(value AS TEXT) FROM ntp_records WHERE entity = 'podcast' AND id = '\(d)' AND field_group = 'identity_rules'").first?.first ?? nil
                return rules?.contains("disputed_guids") == true
            }, [a], label: "the dispute")
            // Removed/live merge: Q's favorite, P removed, Q moved onto P's URL.
            let qOne = try #require(try await a.store.feed(id: qFeed.id)?.episodes.first { $0.details.identifier == "m-1" })
            try await a.store.setFavorite(episodeID: qOne.id, favorite: true)
            _ = try await a.store.requestFeedDeletion(feedID: pFeed.id)
            try await Discovery.cleanUp(a.store)
            await a.exchange()
            world.setResponse("/q.xml", .init(status: 301, headers: ["Location": world.url("p.xml")], body: Data()))
            try await Self.serverRefresh(a, podcast: q)
            try await Self.exchange(until: {
                try a.rows("SELECT CAST(value AS TEXT) FROM ntp_records WHERE entity = 'podcast' AND id = '\(q)' AND field_group = 'subscription'").first?.first??.contains("\"merged\"") == true
            }, [a], label: "the merge")
            await a.exchange(); await b.exchange(); await b.exchange()
            let expected = try await a.view()
            let bLedger = try Self.ledger(b)
            let aBefore = try Self.ledger(a)
            #expect(bLedger.filter { $0[0] == fourWire } == [[fourWire, "pending", "0"]], "B's release, owed: \(bLedger) A: \(aBefore)")
            // The publisher as at the backup, so the restored server's own fetches find nothing of it again.
            Discovery.serve(world, "/d.xml", "D", Discovery.items("d", 1...3) + [later])
            Discovery.serve(world, "/q.xml", "Merged", merged)
            try await world.restore(backup)
            for phone in authorFirst ? [a, b] : [b, a] { _ = try await Recovery.recover(phone) }
            for phone in [a, b] {
                await phone.exchange()
                let recovery = try #require(try await Recovery.recovery(phone))
                #expect(recovery.finished && recovery.complete == true, "\(phone.name): \(recovery)")
            }
            try await world.converge([a, b], authorFirst ? "author first" : "replica first")
            let view = try await b.view()
            #expect(view.withoutTitles.differences(from: expected.withoutTitles).isEmpty,
                    "every change once: \(view.withoutTitles.differences(from: expected.withoutTitles))")
            #expect(view.podcasts.keys.sorted() == [d, p].sorted(), "one podcast for P and Q, and D")
            let kept = try #require(try await a.store.episode(id: row.id))
            #expect(kept.details.title == "Later" && kept.userState.isDownloaded && kept.userState.localFileURL == file.path, "the file stays on its release")
            let aAfter = try Self.ledger(a), bAfter = try Self.ledger(b)
            #expect(aAfter.filter { $0[0] == fourWire } == [[fourWire, "done", "1"]], "A's finished work, kept: \(aAfter)")
            #expect(bAfter.filter { $0[0] == fourWire } == [[fourWire, "pending", "0"]], "B's owed work, once: \(bAfter)")
            for phone in [a, b] {
                let occurrences = try Self.ledger(phone).compactMap { $0[0] }
                #expect(Set(occurrences).count == occurrences.count && !occurrences.contains { $0.hasPrefix("local-episode:") }, "\(phone.name): \(occurrences)")
            }
        }
    }

    // MARK: - Observation work

    /// A large batch's observations still listed when the server is restored (the app ended before they were drained):
    /// the recovery never drops them; they are recorded on the new installation and reach the server, and a refused
    /// podcast's removal leaves none of its rows behind.
    @Test func observationWorkListedAtTheRestoreReachesTheServerAfterRecovery() async throws {
        try await ExchangeWorld.run { world in
            Discovery.serve(world, "/large.xml", "Large", Discovery.items("large", 300...302))
            let a = try await world.device("A")
            let feed = try await Self.subscribe(a, world.url("large.xml"))
            let b = try await world.device("B")
            let backup = try await world.backUp()
            let large = try #require(try await Self.local(b, guid: "large-300"))
            try await b.store.setFavorite(episodeID: large.id, favorite: true)
            await b.exchange(); await a.exchange()
            Discovery.serve(world, "/large.xml", "Large", Discovery.items("large", 1...250) + Discovery.items("large", 300...302))
            guard case .updated(let fetched) = try await FeedFetcher().fetch(FeedFetchRequest(source: world.url("large.xml"), force: true, parity: true)) else {
                throw HarnessError.server("no feed")
            }
            _ = try await a.store.applyRefresh(fetched, feedID: feed.id, options: .init(now: Date()))
            #expect(try a.rows("SELECT count(*) FROM ntp_observation_work") != [["0"]])
            try await world.restore(backup)
            _ = try await Recovery.recover(a)
            _ = try await Recovery.recover(b)
            for _ in 0..<2 { await a.exchange() }
            #expect(try await Recovery.recovery(a)?.finished == true)
            #expect(try a.rows("SELECT count(*) FROM ntp_observation_work") == [["0"]], "recorded, none left")
            let one = try #require(try await Self.local(a, guid: "large-1"))
            let wire = try #require(try await a.store.wireEpisodeForTesting(one.id))
            try await Self.exchange(until: { try a.rows("SELECT count(*) FROM ntp_records WHERE entity = 'episode' AND id = '\(wire)' AND field_group = 'metadata'") == [["1"]] },
                                    [a], label: "the observed backfill's canonical record")
            #expect(try a.rows("SELECT count(*) FROM ntp_local_items i LEFT JOIN episodes e ON e.id = i.local_id WHERE e.id IS NULL") == [["0"]], "no orphan local item")
            try await world.converge([a, b], "observation work")
        }
    }
}

/// Full recovery with identity changes, merges and pending registrations.
extension ServerRecoveryDiscoveryTests {
    static func identityRules(_ phone: DevicePhone, _ podcast: String) throws -> ServerIdentityRules? {
        guard let text = try phone.rows("SELECT CAST(value AS TEXT) FROM ntp_records WHERE entity = 'podcast' AND id = '\(podcast)' AND field_group = 'identity_rules'").first?.first ?? nil else { return nil }
        return ServerIdentityRules(try ContractJSON.decode(text))
    }


    /// A maps a later reused-GUID release under the plain ID; B supplies an earlier occurrence, so the server gives the
    /// plain ID to Earlier and Later its own. Restored before A pulled that, A's full recovery reassigns its row (and a
    /// new row for Earlier) without a constraint failure, and converges.
    @Test func recoveryReassignsAnAlreadyMappedReleaseWithoutUniqueFailure() async throws {
        try await ExchangeWorld.run { world in
            let later = Discovery.Item(guid: "rg", title: "Later", day: 30, enclosure: "https://media.example/rg-later.mp3")
            let earlier = Discovery.Item(guid: "rg", title: "Earlier", day: 10, enclosure: "https://media.example/rg-earlier.mp3")
            Discovery.serve(world, "/ra.xml", "RA", Discovery.items("ra", 1...3))
            let a = try await world.device("A")
            let feed = try await Self.subscribe(a, world.url("ra.xml"))
            let podcast = try #require(try await a.store.podcastOfFeedForTesting(feed.id))
            let b = try await world.device("B")
            let bFeed = try #require(try await b.store.feedOfPodcastForTesting(podcast))
            let backup = try await world.backUp()
            Discovery.serve(world, "/ra.xml", "RA", Discovery.items("ra", 1...3) + [later])
            try await Self.refresh(a, feed.id)
            await a.exchange(); await b.exchange()
            let row = try #require(try await Self.local(a, guid: "rg"))
            Discovery.serve(world, "/ra.xml", "RA", Discovery.items("ra", 1...3) + [later, earlier])
            try await Self.refresh(b, bFeed)
            try await Self.exchange(until: { try Self.identityRules(b, podcast)?.disputedGUIDs["rg"]?.count == 2 }, [b], label: "the dispute")
            try await world.restore(backup)
            _ = try await Recovery.recover(b)
            #expect(await a.engine.exchange().pause == .signIn)
            try await a.signInAgain()
            let report = await a.engine.exchange()
            #expect(report.error == nil, "\(report.error ?? "")")
            await a.exchange()
            let recovery = try #require(try await Recovery.recovery(a))
            #expect(recovery.finished && recovery.complete == true && recovery.prefix == false, "\(recovery)")
            #expect(try await a.store.episode(id: row.id)?.details.title == "Later", "the row stays Later's")
            try await world.converge([a, b], "reassigned")
        }
    }


    /// A finds Later (day 30) offline, under the reused GUID's plain ID, and finishes its follow-ups; B finds Earlier (day
    /// 10) and is admitted first; A's proposal follows, unpulled; the server holds two admissions. Restored, B recovers,
    /// then A from a full snapshot: Later's finished entry moves to Later's own ID, and Earlier, which A never saw, is
    /// owed once (to download, to notify), also after further exchanges.
    @Test func fullRecoveryDoesNotSkipAnUnseenAdmissionWhoseKeyHasAnotherOwner() async throws {
        try await ExchangeWorld.run { world in
            let later = Discovery.Item(guid: "rg", title: "Later", day: 30, enclosure: "https://media.example/rg-later.mp3")
            let earlier = Discovery.Item(guid: "rg", title: "Earlier", day: 10, enclosure: "https://media.example/rg-earlier.mp3")
            Discovery.serve(world, "/ua.xml", "UA", Discovery.items("ua", 1...3))
            let a = try await world.device("A")
            let feed = try await Self.subscribe(a, world.url("ua.xml"))
            let podcast = try #require(try await a.store.podcastOfFeedForTesting(feed.id))
            let b = try await world.device("B")
            let bFeed = try #require(try await b.store.feedOfPodcastForTesting(podcast))
            let backup = try await world.backUp()
            // A's and B's cursors move past the backup.
            let one = try #require(try await Self.local(b, guid: "ua-1"))
            try await b.store.setFavorite(episodeID: one.id, favorite: true)
            await b.exchange(); await a.exchange()
            world.server.stop(keepingData: true)
            Discovery.serve(world, "/ua.xml", "UA", Discovery.items("ua", 1...3) + [earlier])
            try await Self.refresh(b, bFeed)
            Discovery.serve(world, "/ua.xml", "UA", Discovery.items("ua", 1...3) + [later])
            try await Self.refresh(a, feed.id)
            let laterRow = try #require(try await Self.local(a, guid: "rg"))
            try await a.store.markServerReleasesNotified(try await a.store.serverReleaseNotifications().flatMap(\.keys))
            try await a.store.finishServerReleases([laterRow.id])
            try await world.server.launch()
            await b.exchange()
            _ = await a.engine.run([.push])
            try await Self.exchange(until: { try b.rows("SELECT count(*) FROM ntp_records WHERE entity = 'episode' AND field_group = 'admission'") == [["2"]] }, [b],
                                    label: "two admissions")
            Discovery.serve(world, "/ua.xml", "UA", Discovery.items("ua", 1...3) + [later, earlier])
            try await world.restore(backup)
            _ = try await Recovery.recover(b)
            _ = try await Recovery.recover(a)
            for _ in 0..<2 { await a.exchange() }
            let recovery = try #require(try await Recovery.recovery(a))
            #expect(recovery.finished && recovery.complete == true && recovery.prefix == false, "\(recovery)")
            let laterWire = try #require(try await a.store.wireEpisodeForTesting(laterRow.id))
            let earlierRow = try #require(try await Self.local(a, guid: "rg", enclosure: "https://media.example/rg-earlier.mp3"))
            let earlierWire = try #require(try await a.store.wireEpisodeForTesting(earlierRow.id))
            let ledger = try Self.ledger(a)
            #expect(ledger.filter { $0[0] == laterWire } == [[laterWire, "done", "1"]], "Later's finished work: \(ledger)")
            #expect(ledger.filter { $0[0] == earlierWire } == [[earlierWire, "pending", "0"]], "Earlier, which A never saw, is owed once: \(ledger)")
            #expect(try await a.store.serverReleaseNotifications().flatMap(\.keys).map(\.occurrence) == [earlierWire])
            try await world.converge([a, b], "unseen admission")
        }
    }


    /// A, subscribed to P and Q, parses 250 phone-only backfill items of Q and stops with their observations listed; one
    /// of them is downloaded. B pulls Q's merge into P (Q's feed moved onto P's URL), which A has not. Restored, B
    /// recovers the merge, then A: the downloaded row keeps its file (on Q's row until its mapping into P resolves, then
    /// on P's), nothing queues its deletion, the observations reach the server, and A converges.
    @Test func recoveryMergeMustNotDeletePendingObservationsOrTheirDownload() async throws {
        try await ExchangeWorld.run { world in
            let items = Discovery.items("mg", 300...302)
            Discovery.serve(world, "/mp.xml", "Merged", items)
            Discovery.serve(world, "/mq.xml", "Merged", items)
            let a = try await world.device("A")
            let pFeed = try await Self.subscribe(a, world.url("mp.xml"))
            let qFeed = try await Self.subscribe(a, world.url("mq.xml"))
            let q = try #require(try await a.store.podcastOfFeedForTesting(qFeed.id))
            let b = try await world.device("B")
            let backup = try await world.backUp()
            let one = try #require(try await b.store.feeds().flatMap(\.episodes).first { $0.details.identifier == "mg-300" })
            try await b.store.setFavorite(episodeID: one.id, favorite: true)
            await b.exchange(); await a.exchange()
            // A parses Q's backfill and stops before its observations are recorded.
            Discovery.serve(world, "/mq.xml", "Merged", Discovery.items("mg", 1...250) + items)
            guard case .updated(let fetched) = try await FeedFetcher().fetch(FeedFetchRequest(source: world.url("mq.xml"), force: true, parity: true)) else {
                throw HarnessError.server("no feed")
            }
            _ = try await a.store.applyRefresh(fetched, feedID: qFeed.id, options: .init(now: Date()))
            #expect(try a.rows("SELECT count(*) FROM ntp_observation_work WHERE feed_id = \(qFeed.id)") != [["0"]])
            let backfill = try #require(try await a.store.feed(id: qFeed.id)?.episodes.first { $0.details.identifier == "mg-1" })
            let file = world.root.appendingPathComponent("mg-1.media")
            try Data([7, 7]).write(to: file)
            try await a.store.projectForTesting(backfill.id) { $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path }
            // B: Q's feed moves onto P's URL, the server merges Q into P.
            Discovery.serve(world, "/mq.xml", "Merged", items)
            world.setResponse("/mq.xml", .init(status: 301, headers: ["Location": world.url("mp.xml")], body: Data()))
            try await Self.serverRefresh(b, podcast: q)
            try await Self.exchange(until: {
                try b.rows("SELECT CAST(value AS TEXT) FROM ntp_records WHERE entity = 'podcast' AND id = '\(q)' AND field_group = 'subscription'").first?.first??.contains("\"merged\"") == true
            }, [b], label: "the merge")
            try await world.restore(backup)
            _ = try await Recovery.recover(b)
            _ = try await Recovery.recover(a)
            for _ in 0..<3 { await a.exchange() }
            #expect(try await Recovery.recovery(a)?.finished == true)
            #expect(try a.rows("SELECT count(*) FROM ntp_observation_work") == [["0"]], "the observations were recorded")
            let rows = try await a.store.feeds().flatMap(\.episodes).filter { $0.details.identifier == "mg-1" }
            #expect(rows.count == 1, "one row for the backfill episode: \(rows.map(\.id))")
            #expect(rows.first?.userState.isDownloaded == true && rows.first?.userState.localFileURL == file.path, "its download kept")
            // The removals' file cleanup runs (as the app's deletion coordinator does): the file is the kept row's.
            try await Discovery.cleanUp(a.store)
            #expect(FileManager.default.fileExists(atPath: file.path), "the file is still there")
            let kept = try await a.store.feeds().flatMap(\.episodes).first { $0.details.identifier == "mg-1" }
            #expect(kept?.userState.isDownloaded == true && kept?.userState.localFileURL == file.path, "and still the row's")
            _ = pFeed
            try await world.converge([a, b], "merge with pending observations")
        }
    }


    /// A (past the backup) subscribes to a new feed and finds release 4 while the registration is pending (its catalog
    /// observation and discovery are drafts, its ledger entry keyed by the registration); it pushes only the
    /// subscription, unpulled. Restored, B then A recover: the subscription's resolution, in A's full snapshot,
    /// materializes the drafts (sent, the ledger keyed by the podcast's generation), and release 4 reaches the server.
    @Test(arguments: [nil, "full.written", "full.published"])
    func acceptedRegistrationInFullSnapshotResolvesItsDiscoveryDrafts(crash point: String?) async throws {
        try await ExchangeWorld.run { world in
            Discovery.serve(world, "/nr.xml", "NR", Discovery.items("nr", 1...3))
            let (a, ids) = try await Copies.subscribed(world)
            let b = try await world.device("B")
            let backup = try await world.backUp()
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            await a.exchange(); await b.exchange()
            guard case .updated(let fetched) = try await FeedFetcher().fetch(FeedFetchRequest(source: world.url("nr.xml"))) else { throw HarnessError.server("no feed") }
            let feed = try await a.store.insert(fetched)
            Discovery.serve(world, "/nr.xml", "NR", Discovery.items("nr", 1...4))
            try await Self.refresh(a, feed.id)
            #expect(try a.rows("SELECT count(*) FROM ntp_drafts") != [["0"]], "its discoveries wait as drafts")
            #expect(try a.rows("SELECT count(*) FROM ntp_ledger WHERE generation_id LIKE 'registration:%'") != [["0"]])
            _ = await a.engine.run([.push])
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox WHERE receipt IS NULL") == [["0"]], "the subscription sent, not pulled")
            Discovery.serve(world, "/nr.xml", "NR", Discovery.items("nr", 1...3))
            try await world.restore(backup)
            _ = try await Recovery.recover(b)
            #expect(await a.engine.exchange().pause == .signIn)
            try await a.signInAgain()
            if let point {
                await a.engine.setCrashPoint(PushPull.crashOnce(at: point))
                #expect(await a.engine.exchange().error == "InjectedCrash()")
                try await a.relaunch()
            }
            for _ in 0..<3 { await a.exchange() }
            #expect(try await Recovery.recovery(a)?.finished == true)
            #expect(try a.rows("SELECT state FROM ntp_registrations WHERE feed_id = \(feed.id)") == [["resolved"]], "resolved")
            #expect(try a.rows("SELECT count(*) FROM ntp_drafts") == [["0"]], "the drafts materialized")
            #expect(try await a.store.serverUnsentChanges() == 0, "and were sent")
            #expect(try a.rows("SELECT count(*) FROM ntp_ledger WHERE generation_id LIKE 'registration:%'") == [["0"]], "the ledger keyed by the generation")
            let fresh = try await world.attach("fresh-nr")
            #expect(try await fresh.store.feeds().flatMap(\.episodes).contains { $0.details.identifier == "nr-4" }, "release 4 reached the server")
            await fresh.close()
            try await world.converge([a, b], "registration in full snapshot")
        }
    }
}

/// Recovery with discovery against the pinned server.
extension ServerRecoveryDiscoveryTests {
    /// A, subscribed to P and Q, refreshes Q with a GUID rotating two enclosures (days 4, 20, 40, 60) without pushing;
    /// day 60 has no wire binding and a downloaded file. The server, fetching Q itself, knows only days 4, 20 and 40, then
    /// Q moves onto P's URL and is merged into P. A pulls the merge before it pushes its discovery: day 60's row and
    /// file stay; once its discovery reaches the server, its file is its row's under P, through the deletion coordinator.
    @Test func ordinaryMergeWithPendingRotatingDownload() async throws {
        try await ExchangeWorld.run { world in
            Discovery.serve(world, "/rp.xml", "Merged", Discovery.items("rr", 1...3))
            Discovery.serve(world, "/rq.xml", "Merged", Discovery.items("rr", 1...3))
            let a = try await world.device("A")
            _ = try await Self.subscribe(a, world.url("rp.xml"))
            let qFeed = try await Self.subscribe(a, world.url("rq.xml"))
            let q = try #require(try await a.store.podcastOfFeedForTesting(qFeed.id))
            let b = try await world.device("B")
            let rotating = [(4.0, "a"), (20, "b"), (40, "a"), (60, "b")].map { day, slot in
                Discovery.Item(guid: "rg", title: "Rot \(Int(day))", day: day, enclosure: "https://media.example/rq-\(slot).mp3")
            }
            Discovery.serve(world, "/rq.xml", "Merged", rotating.reversed() + Discovery.items("rr", 1...3))
            try await Self.refresh(a, qFeed.id)
            let sixty = try #require(try await a.store.feeds().flatMap(\.episodes).first { $0.details.title == "Rot 60" })
            #expect(try await a.store.wireEpisodeForTesting(sixty.id) == nil, "day 60 has no wire binding")
            let file = world.root.appendingPathComponent("rot-60.media")
            try Data([6, 0]).write(to: file)
            try await a.store.projectForTesting(sixty.id) { $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path }
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox WHERE type IN ('catalog.observe', 'discovery.propose')") != [["0"]], "A's discovery is unsent")
            // The server knows three releases, then merges Q into P.
            Discovery.serve(world, "/rq.xml", "Merged", Array(rotating.prefix(3)).reversed() + Discovery.items("rr", 1...3))
            try await Self.serverRefresh(b, podcast: q)
            try await Self.exchange(until: { try Self.identityRules(b, q)?.disputedGUIDs["rg"]?.count == 3 }, [b], label: "the three-release dispute")
            world.setResponse("/rq.xml", .init(status: 301, headers: ["Location": world.url("rp.xml")], body: Data()))
            try await Self.serverRefresh(b, podcast: q)
            try await Self.exchange(until: {
                try b.rows("SELECT CAST(value AS TEXT) FROM ntp_records WHERE entity = 'podcast' AND id = '\(q)' AND field_group = 'subscription'").first?.first??.contains("\"merged\"") == true
            }, [b], label: "the merge")
            // A applies the merge before pushing its discovery.
            _ = await a.engine.run([.pull, .apply])
            try await Discovery.cleanUp(a.store)
            #expect(try await a.store.episode(id: sixty.id)?.userState.localFileURL == file.path, "the row keeps its file while its discovery is pending")
            try await a.relaunch()
            for _ in 0..<3 { await a.exchange() }
            await b.exchange()
            try await Discovery.cleanUp(a.store)
            var rows: [LibraryEpisode] = []
            for feed in try await a.store.feeds() { for episode in feed.episodes where episode.details.title == "Rot 60" { rows.append(episode) } }
            #expect(rows.count == 1 && rows.first?.userState.isDownloaded == true && rows.first?.userState.localFileURL == file.path,
                    "one day-60 row, its file: \(rows.map { ($0.id, $0.userState.isDownloaded) })")
            #expect(FileManager.default.fileExists(atPath: file.path), "the file survives")
            #expect(try await a.store.feed(id: qFeed.id) == nil, "the merge completed")
            try await world.converge([a, b], "merge with a pending rotating release")
        }
    }

    /// The accepted-registration recovery with a URL edit while the registration and its discoveries are drafts. The
    /// server fetched the catalog (old URL) before A's full snapshot: the snapshot's podcast is A's own feed (the
    /// registration's), never a second one, in one publication with the drafts' materialization, across both crashes.
    @Test(arguments: [nil, "full.written", "full.published"])
    func registrationWithPendingURLEdit(crash point: String?) async throws {
        try await ExchangeWorld.run { world in
            Discovery.serve(world, "/ne.xml", "NE", Discovery.items("ne", 1...3))
            let (a, ids) = try await Copies.subscribed(world)
            let b = try await world.device("B")
            let backup = try await world.backUp()
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            await a.exchange(); await b.exchange()
            guard case .updated(let fetched) = try await FeedFetcher().fetch(FeedFetchRequest(source: world.url("ne.xml"))) else { throw HarnessError.server("no feed") }
            let feed = try await a.store.insert(fetched)
            Discovery.serve(world, "/ne.xml", "NE", Discovery.items("ne", 1...4))
            try await Self.refresh(a, feed.id)
            #expect(try a.rows("SELECT count(*) FROM ntp_drafts") != [["0"]])
            Discovery.serve(world, "/ne-moved.xml", "NE", Discovery.items("ne", 1...4))
            #expect(try await a.store.updateFeedDownloadURL(original: world.url("ne.xml"), updated: world.url("ne-moved.xml")) == [feed.id])
            _ = await a.engine.run([.push])
            Discovery.serve(world, "/ne.xml", "NE", Discovery.items("ne", 1...3))
            try await world.restore(backup)
            _ = try await Recovery.recover(b)
            #expect(await a.engine.exchange().pause == .signIn)
            try await a.signInAgain()
            // A uploads; the server fetches the subscription's catalog (old URL) before A's snapshot is taken.
            await a.engine.setCrashPoint(PushPull.crashOnce(at: "recovery.uploaded"))
            #expect(await a.engine.exchange().error == "InjectedCrash()")
            // The catalog's first episode by its whole GUID: "ne-1" alone also matches the other feed's "one-1".
            try await Self.exchange(until: { try b.rows("SELECT count(*) FROM ntp_records WHERE entity = 'episode' AND field_group = 'identity' AND CAST(value AS TEXT) LIKE '%\"guid\":\"ne-1\"%'") == [["1"]] },
                                    [b], label: "the server's catalog")
            try await a.relaunch()
            if let point {
                await a.engine.setCrashPoint(PushPull.crashOnce(at: point))
                #expect(await a.engine.exchange().error == "InjectedCrash()")
                try await a.relaunch()
            }
            for _ in 0..<3 { await a.exchange() }
            let recovery = try #require(try await Recovery.recovery(a))
            #expect(recovery.finished && recovery.complete == true && recovery.prefix == false, "\(recovery)")
            let feeds = try await a.store.feeds().filter { $0.metadata.title == "NE" || $0.episodes.contains { $0.details.identifier == "ne-1" } }
            #expect(feeds.map(\.id) == [feed.id], "one feed, the registration's: \(feeds.map { ($0.id, $0.source, $0.episodes.count) })")
            #expect(feeds.first?.source == world.url("ne-moved.xml"), "with the edited URL")
            #expect(try await a.store.feeds().flatMap(\.episodes).filter { $0.details.identifier == "ne-1" }.count == 1)
            #expect(try a.rows("SELECT state FROM ntp_registrations WHERE feed_id = \(feed.id)") == [["resolved"]])
            #expect(try a.rows("SELECT count(*) FROM ntp_drafts") == [["0"]])
            try await world.converge([a, b], "registration with a URL edit")
        }
    }

    /// The same accepted registration with a URL edit, the server's catalog under another canonical title
    /// (the switch writes the registration's feed header). A's switch, which binds that still unmapped feed to the
    /// snapshot's podcast (`resolvedFeeds`), is kept while audio plays and the app is in use; the person then sets the
    /// podcast's custom title and episode notifications. The switch must not write its stale header over them: it is
    /// published as a whole once it may run, and both settings survive the recovery, more exchanges and a relaunch.
    @Test func recoveryResolvedFeedKeepsConcurrentDeviceSettings() async throws {
        try await ExchangeWorld.run { world in
            Discovery.serve(world, "/ne.xml", "NE", Discovery.items("ne", 1...3))
            let (a, ids) = try await Copies.subscribed(world)
            let b = try await world.device("B")
            let backup = try await world.backUp()
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            await a.exchange(); await b.exchange()
            guard case .updated(let fetched) = try await FeedFetcher().fetch(FeedFetchRequest(source: world.url("ne.xml"))) else { throw HarnessError.server("no feed") }
            let feed = try await a.store.insert(fetched)
            Discovery.serve(world, "/ne.xml", "NE", Discovery.items("ne", 1...4))
            try await Self.refresh(a, feed.id)
            #expect(try a.rows("SELECT count(*) FROM ntp_drafts") != [["0"]])
            Discovery.serve(world, "/ne-moved.xml", "NE", Discovery.items("ne", 1...4))
            #expect(try await a.store.updateFeedDownloadURL(original: world.url("ne.xml"), updated: world.url("ne-moved.xml")) == [feed.id])
            _ = await a.engine.run([.push])
            // The server's own fetch finds another canonical title.
            Discovery.serve(world, "/ne.xml", "NE Canonical", Discovery.items("ne", 1...3))
            try await world.restore(backup)
            _ = try await Recovery.recover(b)
            #expect(await a.engine.exchange().pause == .signIn)
            try await a.signInAgain()
            await a.engine.setCrashPoint(PushPull.crashOnce(at: "recovery.uploaded"))
            #expect(await a.engine.exchange().error == "InjectedCrash()")
            // The catalog's first episode by its whole GUID: "ne-1" alone also matches the other feed's "one-1".
            try await Self.exchange(until: { try b.rows("SELECT count(*) FROM ntp_records WHERE entity = 'episode' AND field_group = 'identity' AND CAST(value AS TEXT) LIKE '%\"guid\":\"ne-1\"%'") == [["1"]] },
                                    [b], label: "the server's catalog")
            try await a.relaunch()
            // A's switch waits while audio plays and the app is in use.
            a.playing.value = true
            a.foreground.value = true
            await a.engine.setBudgets(publish: 1)
            let waiting = await a.engine.exchange()
            #expect(waiting.error == nil && waiting.waitingForBackground, "\(waiting)")
            let kept = try #require(await a.engine.keptFull)
            #expect(kept.build.revisions.context.resolvedFeeds.values.contains(feed.id), "the switch binds the registration's feed")
            #expect(kept.build.revisions.scope.structuralFeeds.contains(feed.id))
            #expect(try a.rows("SELECT count(*) FROM ntp_podcasts WHERE feed_id = \(feed.id)") == [["0"]], "no live mapping yet")
            #expect(try await Recovery.recovery(a)?.caughtUp == false)
            try await a.store.updatePreferences(feedID: feed.id) {
                $0.customTitle = "Keep my title"
                $0.showEpisodeNotification = true
            }
            a.playing.value = false
            a.foreground.value = false
            a.eligibility.changed()
            let resumed = await a.exchange()
            #expect(resumed.shadowsBuilt == 0, "the kept switch: \(resumed)")
            #expect(try await a.log().contains { $0.detail.contains("reprojected as a whole") }, "published as a whole")
            for _ in 0..<2 { await a.exchange() }
            try await a.relaunch()
            for _ in 0..<2 { await a.exchange() }
            let recovery = try #require(try await Recovery.recovery(a))
            #expect(recovery.finished && recovery.complete == true, "\(recovery)")
            let feeds = try await a.store.feeds().filter { $0.metadata.title?.hasPrefix("NE") == true || $0.episodes.contains { $0.details.identifier == "ne-1" } }
            #expect(feeds.map(\.id) == [feed.id], "one feed, the registration's: \(feeds.map { ($0.id, $0.source, $0.episodes.count) })")
            let shown = try #require(feeds.first)
            #expect(shown.customTitle == "Keep my title" && shown.showEpisodeNotification, "the settings made meanwhile stay: \(String(describing: shown.customTitle)) \(shown.showEpisodeNotification)")
            #expect(shown.source == world.url("ne-moved.xml"), "with the edited URL")
            #expect(try a.rows("SELECT state FROM ntp_registrations WHERE feed_id = \(feed.id)") == [["resolved"]])
            #expect(try a.rows("SELECT count(*) FROM ntp_drafts") == [["0"]])
            try await world.converge([a, b], "settings during a kept switch")
        }
    }
}

/// On the store: a full publication built with a pending registration's feed resolved (`resolvedFeeds`, the feed not
/// mapped yet, its URL edited while the registration is pending) whose feed changes after the build. The change is
/// the person's newer one: the switch is deferred under a limit, nothing written, and published as a whole without
/// one, keeping it; its registration materializes in that publication.
@Suite(.serialized) struct ServerResolvedFeedRebaseTests {
    typealias Discovery = ServerDiscoveryTests

    static let source = "https://example.test/pending.xml"
    static let moved = "https://example.test/pending-moved.xml"

    /// A subscription whose registration is pending, its URL edited, and a full build of the library's base plus the
    /// snapshot's podcast for it (another canonical title), with its resolution.
    static func built(_ fixture: ServerLibraryFixture) async throws -> (feed: LibraryFeed, build: ServerFullBuild, head: SyncCursor, decision: ServerDecision) {
        let store = fixture.store
        if try await store.serverExchangeState().cursor == nil {
            try await store.setCursorForTesting(try SyncCursor(logID: ContractIdentity.randomUUID(), epoch: 1, seq: 0, digest: String(repeating: "0", count: 64)))
        }
        let head = try #require(try await store.serverExchangeState().cursor)
        let feed = try await store.insert(Discovery.fetched(Discovery.base, source: source))
        let op = try fixture.registrationOp(feedID: feed.id)
        let ids = try fixture.created(op)
        #expect(try await store.updateFeedDownloadURL(original: source, updated: moved) == [feed.id])
        #expect(try fixture.rows("SELECT state FROM ntp_registrations WHERE op_id = '\(op)'") == [["pending"]])
        var items: [ContractJSON] = try fixture.rows("SELECT entity, id, field_group, CAST(value AS TEXT) FROM ntp_records").map { row in
            ["record": ["entity": .string(row[0]!), "id": .string(row[1]!), "field_group": .string(row[2]!),
                        "value": try ContractJSON.decode(Array(row[3]!.utf8)), "provenance": []]]
        }
        let podcast: [(String, ContractJSON)] = [
            ("identity", ["refresh_url": .string(source), "aliases": [["url": .string(source), "normalized": .string(ContractURL.normalize(source))]]]),
            ("subscription", ["state": "subscribed", "generation_id": .string(ids.generation)]),
            ("metadata", ["title": "Canonical", "revision": .string(ContractIdentity.randomUUID())]),
        ]
        for (group, value) in podcast {
            items.append(["record": ["entity": "podcast", "id": .string(ids.podcast), "field_group": .string(group), "value": value, "provenance": []]])
        }
        let page = fixture.directory.appendingPathComponent("page-\(UUID()).json")
        try ContractJSON.object(["items": .array(items)]).canonicalData().write(to: page)
        let snapshot = ServerAttachSnapshot(head: head.encoded, installWatermark: 0, itemCount: items.count, podcastCount: 1, pages: [page])
        let staged = fixture.directory.appendingPathComponent("full-\(UUID()).sqlite")
        try ServerFullReprojection.stageBase(snapshot, into: staged)
        let reserved = try await store.reserveServerLocalIDs(feeds: 64, episodes: 64)
        let touches = try await store.serverTouchWatermark()
        let build = try ServerFullReprojection.build(database: fixture.url, file: staged, history: nil, now: 3_000_000, feedIDs: reserved.feeds,
                                                     episodeIDs: reserved.episodes, touches: touches, target: head, admissionsSeen: false,
                                                     resolvedFeeds: [ids.podcast: feed.id])
        #expect(build.revisions.scope.structuralFeeds.contains(feed.id), "the switch maps the feed anew")
        #expect(try fixture.rows("SELECT count(*) FROM ntp_podcasts WHERE feed_id = \(feed.id)") == [["0"]], "no live mapping")
        let decision = try ServerDecision(["decision_id": .string(ContractIdentity.randomUUID()), "decision_type": "podcast.resolution",
                                           "subject": .string(op), "epoch": 1, "seq": 1, "normalized_time": 1,
                                           "result": ["podcast_id": .string(ids.podcast), "generation_id": .string(ids.generation), "mode": "created"]])
        return (feed, build, head, decision)
    }

    /// Within a limit the switch is deferred, nothing written; without one it is published as a whole. (Admitted
    /// within the limit, the test reads what that publication left.)
    static func publish(_ fixture: ServerLibraryFixture, _ built: (feed: LibraryFeed, build: ServerFullBuild, head: SyncCursor, decision: ServerDecision)) async throws {
        let store = fixture.store
        do {
            let admitted = try await store.publishFullReprojection(built.build, head: built.head, now: 3_000_000, crash: nil, workLimit: 1_000,
                                                                   resolutions: [built.decision])
            Issue.record("published within the limit, not deferred: \(admitted)")
        } catch ServerApplyError.deferred {
            #expect(try fixture.rows("SELECT state FROM ntp_registrations WHERE feed_id = \(built.feed.id)") == [["pending"]], "nothing written while deferred")
            let result = try await store.publishFullReprojection(built.build, head: built.head, now: 3_000_000, crash: nil, resolutions: [built.decision])
            #expect(result.published && result.wholeAtPause, "\(result)")
        }
        #expect(try fixture.rows("SELECT state FROM ntp_registrations WHERE feed_id = \(built.feed.id)") == [["resolved"]])
        #expect(try fixture.rows("SELECT count(*) FROM ntp_podcasts WHERE feed_id = \(built.feed.id)") == [["1"]])
        #expect(try fixture.rows("SELECT count(*) FROM ntp_drafts") == [["0"]])
    }

    @Test func devicePreferencesChangedAfterTheBuildAreKept() async throws {
        let fixture = try await ServerLibraryFixture()
        let built = try await Self.built(fixture)
        try await fixture.store.updatePreferences(feedID: built.feed.id) {
            $0.customTitle = "Keep my title"
            $0.showEpisodeNotification = true
        }
        try await Self.publish(fixture, built)
        let feed = try #require(try await fixture.store.feed(id: built.feed.id))
        #expect(feed.customTitle == "Keep my title" && feed.showEpisodeNotification, "\(String(describing: feed.customTitle)) \(feed.showEpisodeNotification)")
        #expect(feed.source == Self.moved)
        await fixture.close()
    }

    @Test func aSecondPendingURLEditAfterTheBuildIsKept() async throws {
        let fixture = try await ServerLibraryFixture()
        let built = try await Self.built(fixture)
        let again = "https://example.test/pending-moved-again.xml"
        #expect(try await fixture.store.updateFeedDownloadURL(original: Self.moved, updated: again) == [built.feed.id])
        try await Self.publish(fixture, built)
        #expect(try await fixture.store.feed(id: built.feed.id)?.source == again, "the newer edit, not the one the build saw")
        await fixture.close()
    }
}

/// A full publication's episode bindings on the library's own data: a staged permutation of which local row each
/// episode owns publishes in any staging-row order, and a failure rolls all of it back.
@Suite(.serialized) struct ServerFullBindingTests {
    /// A registered podcast of three episodes; E1 and E2 own rows 1 and 2, row 3 is unmapped; the base holds their
    /// identities; each has a ledger entry.
    static func library() async throws -> (fixture: ServerLibraryFixture, podcast: String, rows: [Int64], episodes: [String]) {
        let fixture = try await ServerLibraryFixture()
        let registered = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(count: 3))
        let store = fixture.store
        let rows = registered.feed.episodes.map(\.id).sorted()
        let episodes = ["e1:perm-1", "e1:perm-2", "e1:perm-3"]
        try await store.executeForTesting("DELETE FROM ntp_episodes WHERE local_id IN (SELECT id FROM episodes WHERE feed_id = ?)", [.integer(registered.feed.id)])
        for (index, episode) in episodes.enumerated() {
            if index < 2 {
                try await store.executeForTesting("INSERT INTO ntp_episodes(episode_id, local_id, podcast_id, kind, value) VALUES (?, ?, ?, 'guid', ?)",
                                                  [.text(episode), .integer(rows[index]), .text(registered.podcast), .text(episode)])
            }
            try await store.executeForTesting("INSERT OR REPLACE INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('episode', ?, 'identity', ?, '[]')",
                                              [.text(episode), .blob(try ContractJSON.object(["podcast_id": .string(registered.podcast)]).canonicalData())])
            try await store.executeForTesting("INSERT INTO ntp_ledger(generation_id, occurrence, entry_id, state, notified, record) VALUES (?, ?, NULL, ?, ?, CAST('{}' AS BLOB))",
                                              [.text(registered.generation), .text(episode), .text(index == 0 ? "done" : "pending"), .integer(index == 0 ? 1 : 0)])
        }
        return (fixture, registered.podcast, rows, episodes)
    }

    /// A staged build of the live base itself, whose mappings are replaced by `mappings` in this staging-row order.
    static func build(_ fixture: ServerLibraryFixture, podcast: String, mappings: [(String, Int64?)]) async throws -> ServerFullBuild {
        let file = fixture.directory.appendingPathComponent("full-\(UUID().uuidString.prefix(6)).sqlite")
        let staging = try SyncSQLite(url: file, durable: false)
        try staging.execute("PRAGMA journal_mode = DELETE")
        try staging.transaction {
            for statement in ServerFullReprojection.schema + ServerShadow.schema.filter({ !$0.contains(" records ") && !$0.contains(" identities ") }) {
                try staging.execute(statement)
            }
        }
        try staging.close()
        let live = try LibrarySQLite(readingOnly: fixture.url)
        let records = try live.rows("SELECT entity, id, field_group, value, provenance FROM ntp_records")
        try live.close()
        let writer = try SyncSQLite(url: file, durable: false)
        try writer.transaction {
            for record in records {
                try writer.execute("INSERT INTO records(entity, id, field_group, value, provenance) VALUES (?, ?, ?, ?, ?)", record)
            }
        }
        try writer.close()
        let reserved = try await fixture.store.reserveServerLocalIDs(feeds: 8, episodes: 8)
        let built = try ServerFullReprojection.build(database: fixture.url, file: file, history: nil, now: 1, feedIDs: reserved.feeds, episodeIDs: reserved.episodes,
                                                     touches: try await fixture.store.serverTouchWatermark())
        let edit = try SyncSQLite(url: file, durable: false)
        try edit.transaction {
            try edit.execute("DELETE FROM mappings")
            for (episode, local) in mappings {
                try edit.execute("INSERT INTO mappings(episode_id, local_id, podcast_id, kind, value) VALUES (?, ?, ?, 'guid', ?)",
                                 [.text(episode), local.map(LibrarySQLValue.integer) ?? .null, .text(podcast), .text(episode)])
            }
        }
        try edit.close()
        return built
    }

    static func bindings(_ fixture: ServerLibraryFixture) throws -> [[String?]] {
        try fixture.rows("SELECT episode_id, local_id FROM ntp_episodes WHERE episode_id LIKE 'e1:perm-%' ORDER BY episode_id")
    }

    /// E1 moves from row 1 to row 3 and the new E3 takes row 1 (a release's identity reassigned, the earlier owner moving
    /// on); E2 and row 2 swap with nothing (an unchanged binding). Both staging orders publish the same bindings; the
    /// ledger stays with its releases; a crash in the publication leaves everything as it was.
    @Test(arguments: [true, false]) func fullPermutationStagesAllLedgerOwnersAndRollsBackAtomically(newOwnerFirst: Bool) async throws {
        let (fixture, podcast, rows, episodes) = try await Self.library()
        defer { Task { await fixture.close() } }
        let store = fixture.store
        let order: [(String, Int64?)] = newOwnerFirst ? [(episodes[2], rows[0]), (episodes[0], rows[2]), (episodes[1], rows[1])]
                                                      : [(episodes[1], rows[1]), (episodes[0], rows[2]), (episodes[2], rows[0])]
        let ledger = try fixture.rows("SELECT occurrence, state, notified FROM ntp_ledger ORDER BY occurrence")
        let before = try Self.bindings(fixture)
        let head = try SyncCursor(logID: ContractIdentity.randomUUID(), epoch: 1, seq: 3, digest: String(repeating: "a", count: 64))
        try await store.setServerRecoveryCursor(head)
        // A failure inside the publication rolls every binding back.
        let crashing = try await Self.build(fixture, podcast: podcast, mappings: order)
        do {
            _ = try await store.publishFullReprojection(crashing, head: head, now: 1, crash: { if $0 == "full.written" { throw ServerExchangePushPullTests.InjectedCrash() } })
            Issue.record("no crash")
        } catch is ServerExchangePushPullTests.InjectedCrash {}
        #expect(try Self.bindings(fixture) == before, "rolled back")
        let built = try await Self.build(fixture, podcast: podcast, mappings: order)
        _ = try await store.publishFullReprojection(built, head: head, now: 1, crash: nil)
        #expect(try Self.bindings(fixture) == [[episodes[0], "\(rows[2])"], [episodes[1], "\(rows[1])"], [episodes[2], "\(rows[0])"]])
        #expect(try fixture.rows("SELECT occurrence, state, notified FROM ntp_ledger ORDER BY occurrence") == ledger, "the ledger stays with its releases")
    }
}

/// A merge never deletes a provisional release this library's pending discovery covers,
/// and deferred merges complete in bounded steps (debt), on the library's own data.
@Suite(.serialized) struct ServerMergeProtectionTests {
    typealias Discovery = ServerDiscoveryTests
    typealias Merge = ServerMergeTests
    typealias Applier = ServerProjectionUnitTests.Applier

    /// A registered podcast whose first canonical metadata arrived, at `source`.
    static func registered(_ fixture: ServerLibraryFixture, _ source: String, _ items: [Discovery.Item] = Discovery.base) async throws
        -> (feed: LibraryFeed, podcast: String, generation: String) {
        let result = try await fixture.subscribeRegistered(Discovery.fetched(items, source: source))
        try await fixture.store.executeForTesting("INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('podcast', ?, 'metadata', ?, '[]')",
                                                  [.text(result.podcast), .blob(try (["title": "Show", "revision": .string(ContractIdentity.randomUUID())] as ContractJSON).canonicalData())])
        return result
    }

    static func identity(_ episode: String, podcast: String, occurrence: ContractJSON, mergedInto: String? = nil) -> ServerRecord {
        var value: ContractObject = ["podcast_id": .string(podcast), "occurrence": occurrence]
        if let mergedInto { value["merged_into"] = .string(mergedInto) }
        return ServerRecord(entity: "episode", id: episode, fieldGroup: "identity", value: .object(value))
    }

    /// Q's rotating releases (days 4, 20, 40, 60) refreshed here, its observations and proposals unsent; day 60 has no wire
    /// binding and a downloaded file. The server merges Q into P, giving each release it knows (days 4, 20, 40 and Q's
    /// three base episodes) merged identities. The day-60 row, its file and the feed stay while its own discovery is
    /// pending; then, once the server knows day 60 under P, the merge completes and the file is the row's under P.
    @Test func aMergeProtectsAnUnmappedRotatingRelease() async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let store = fixture.store
        let p = try await Self.registered(fixture, "https://example.test/p.xml")
        let q = try await Self.registered(fixture, "https://example.test/q.xml")
        var options = FeedRefreshOptions(now: Discovery.date(61))
        options.globalNewEpisodesAction = .inbox
        _ = try await store.applyRefresh(Discovery.fetched(Discovery.base + Discovery.rotating, source: "https://example.test/q.xml"), feedID: q.feed.id, options: options)
        let rows = try await store.feed(id: q.feed.id)?.episodes ?? []
        let sixty = try #require(rows.first { $0.details.title == "Rot 60" })
        #expect(try fixture.wireID(sixty.id) == nil, "day 60 has no wire binding")
        let file = fixture.directory.appendingPathComponent("rot-60.mp3")
        try Data([6, 0]).write(to: file)
        try await store.projectForTesting(sixty.id) { $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path }
        // The server's merge: every Q release it knows merges into a P episode of its own.
        var records: [ServerRecord] = [ServerRecord(entity: "podcast", id: q.podcast, fieldGroup: "subscription",
                                                    value: ["state": "merged", "merged_into": .string(p.podcast), "generation_id": .string(q.generation)])]
        for row in rows where row.id != sixty.id {
            let wire = try #require(try fixture.wireID(row.id))
            let occurrence: ContractJSON = ["k": "rss-guid", "v": .string(row.details.identifier ?? ""), "guid": .string(row.details.identifier ?? ""),
                                            "publication_time": .integer(Int64((row.details.publicationDate ?? Date()).timeIntervalSince1970 * 1_000))]
            let survivor = "e1:survivor-\(row.id)"
            records.append(Self.identity(survivor, podcast: p.podcast, occurrence: occurrence))
            records.append(Self.identity(wire, podcast: q.podcast, occurrence: occurrence, mergedInto: survivor))
        }
        // The server's dispute knows three of the releases (days 4, 20, 40): day 60 derives one of their IDs.
        var releases: [ContractJSON] = []
        for row in rows where row.details.identifier == "rot" && row.id != sixty.id {
            releases.append(["episode_id": .string(try #require(try fixture.wireID(row.id))),
                             "publication_time": .integer(Int64((row.details.publicationDate ?? Date()).timeIntervalSince1970 * 1_000)),
                             "enclosures": [.string(ContractURL.normalize(row.details.media?.url ?? ""))]])
        }
        let rules: ContractJSON = ["aliases": [], "disputed_enclosures": [], "disputed_guids": [["guid": "rot", "releases": .array(releases)]]]
        records.append(ServerRecord(entity: "podcast", id: q.podcast, fieldGroup: "identity_rules", value: rules))
        // Day 60, outside every listed release's window, derives an ID the server holds as an earlier release's, merged
        // into P like the others: that merge says nothing of day 60.
        let evidence = ServerItemEvidence(guid: "rot", enclosureURL: "https://media.example.test/slot-b.mp3", publicationTime: Discovery.ms(60), title: nil, atom: false)
        let derived = try #require(try ServerEpisodeIdentity.derive(evidence, rules: ServerIdentityRules(rules), namespace: fixture.identity.namespace, podcast: q.podcast))
        if !records.contains(where: { $0.entity == "episode" && $0.id == derived.episodeID && $0.value?["merged_into"] != nil }) {
            let occurrence: ContractJSON = ["k": .string(derived.key.kind), "v": .string(derived.key.value), "guid": "rot", "publication_time": .integer(Discovery.ms(20))]
            records.append(Self.identity("e1:survivor-b", podcast: p.podcast, occurrence: occurrence))
            records.append(Self.identity(derived.episodeID, podcast: q.podcast, occurrence: occurrence, mergedInto: "e1:survivor-b"))
        }
        let applier = try await Applier(fixture)
        try await applier.apply(records)
        try await Merge.cleanUp(store)
        #expect(try await store.episode(id: sixty.id)?.userState.localFileURL == file.path, "the row keeps its file while its discovery is pending")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try await store.feed(id: q.feed.id) != nil, "the merged feed waits with it")
        _ = try await store.completeDeferredServerMerges(history: nil, now: 1_760_000_000_000)
        #expect(try await store.episode(id: sixty.id) != nil, "still waiting")
        // The work reaches the server: it knows day 60 under P.
        try await store.retireEverythingForTesting()
        try await store.executeForTesting("DELETE FROM ntp_observation_work")
        let occurrence: ContractJSON = ["k": "rss-guid+enclosure", "v": .string("rot\u{1F}" + ContractURL.normalize("https://media.example.test/slot-b.mp3")),
                                        "guid": "rot", "enclosure_url": "https://media.example.test/slot-b.mp3", "publication_time": .integer(Discovery.ms(60))]
        try await applier.apply([Self.identity("e0:survivor-60", podcast: p.podcast, occurrence: occurrence)])
        while try await store.completeDeferredServerMerges(history: nil, now: 1_760_000_000_000).isEmpty == false {}
        try await Merge.cleanUp(store)
        #expect(try await store.feed(id: q.feed.id) == nil, "the merge completed")
        let kept = try await store.feeds().flatMap(\.episodes).filter { $0.details.title == "Rot 60" || ($0.details.identifier == "rot" && $0.userState.localFileURL == file.path) }
        #expect(kept.count == 1 && kept.first?.userState.isDownloaded == true && kept.first?.userState.localFileURL == file.path, "one day-60 row, downloaded: \(kept.map(\.id))")
        #expect(FileManager.default.fileExists(atPath: file.path), "the file survives the deletion coordinator")
    }

    /// Many merged podcasts waiting for this library's discovery work: each completion step handles one, holds the store
    /// briefly, and a relaunch continues where the steps stopped.
    @Test func deferredMergesCompleteInBoundedSteps() async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let store = fixture.store
        let p = try await Self.registered(fixture, "https://example.test/p.xml")
        var merged: [Int64] = []
        var records: [ServerRecord] = []
        for index in 0..<12 {
            let q = try await Self.registered(fixture, "https://example.test/q\(index).xml")
            merged.append(q.feed.id)
            records.append(ServerRecord(entity: "podcast", id: q.podcast, fieldGroup: "subscription",
                                        value: ["state": "merged", "merged_into": .string(p.podcast), "generation_id": .string(q.generation)]))
        }
        // Their first populations' observations are still listed: every merge waits.
        try await Applier(fixture).apply(records)
        #expect(try fixture.rows("SELECT count(*) FROM feeds WHERE id IN (\(merged.map(String.init).joined(separator: ",")))") == [["12"]])
        try await store.executeForTesting("DELETE FROM ntp_observation_work")
        try await store.retireEverythingForTesting()
        let candidates = try ServerDeferredMerges.candidates(fixture.url)
        #expect(candidates.count == 12)
        // One step completes one merge.
        let first = try await ServerDeferredMerges.step(store, database: fixture.url, candidate: candidates[0], history: nil, now: 1_760_000_000_000)
        #expect(first != nil)
        #expect(try ServerDeferredMerges.candidates(fixture.url).count == 11, "the rest wait for later steps (or a relaunch)")
        while let next = try ServerDeferredMerges.candidates(fixture.url).first {
            _ = try await ServerDeferredMerges.step(store, database: fixture.url, candidate: next, history: nil, now: 1_760_000_000_000)
        }
        #expect(try fixture.rows("SELECT count(*) FROM feeds WHERE id IN (\(merged.map(String.init).joined(separator: ",")))") == [["0"]])
    }
}
