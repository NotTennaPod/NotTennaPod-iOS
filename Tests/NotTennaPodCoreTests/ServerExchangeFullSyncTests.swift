import Foundation
import Testing
@testable import NotTennaPodCore

/// Force full synchronization (PROTOCOL §6.14) against the real server:
/// wrong live rows are repaired even when the base was right; projected rows the server no longer holds go while
/// local-only state stays; pending local facts, the player's pinned fields and the outbox are untouched; a
/// cross-podcast change publishes in one switch; while audio plays a large one waits for a pause; a local action
/// during staging is kept; and a crash at any step leaves nothing half done.
@Suite(.serialized) struct ServerExchangeFullSyncTests {
    typealias Agreement = ServerExchangeAgreementTests
    typealias Concurrency = ServerExchangeConcurrencyTests
    typealias PushPull = ServerExchangePushPullTests

    /// Two phones on two podcasts; C listened to episodes of both, queued three and favorited one; A has pulled.
    static func world(_ world: ExchangeWorld) async throws -> (a: ExchangePhone, c: ExchangePhone, one: [Int64], two: [Int64]) {
        let (a, c, _, one, _) = try await Concurrency.twoPhones(world)
        let feedTwo = try await a.store.insert(Agreement.fetched(world.url("two.xml"), title: "Two", prefix: "two", count: 3))
        try await Agreement.waitForCatalog(a, feedID: feedTwo.id)
        await c.exchange()
        let two = feedTwo.episodes.map(\.id).sorted()
        for id in [one[0], one[1], two[0]] {
            var listening = RemoteSession(store: c.store, episode: try await Concurrency.same(id, from: a, on: c))
            try await listening.start(at: 0)
            try await listening.checkpoint(position: 90_000, contribution: 90_000)
        }
        _ = try await c.store.enqueue([try await Concurrency.same(one[2], from: a, on: c), try await Concurrency.same(two[1], from: a, on: c),
                                       try await Concurrency.same(one[3], from: a, on: c)])
        try await c.store.setFavorite(episodeID: try await Concurrency.same(two[2], from: a, on: c), favorite: true)
        await c.exchange()
        await a.exchange()
        return (a, c, one, two)
    }

    /// Live rows made wrong without any fact (the base stays right): played times across both podcasts, a favorite, a
    /// play state, the queue's order and membership, and a podcast policy.
    static func corrupt(_ a: ExchangePhone, one: [Int64], two: [Int64]) async throws {
        for id in [one[0], one[1], two[0]] { try await a.store.projectForTesting(id) { $0.userState.playedDurationMilliseconds = 0 } }
        try await a.store.projectForTesting(two[2]) { $0.userState.isFavorite = false }
        try await a.store.projectForTesting(one[4]) { $0.userState.playState = .played }
        try await a.store.setQueueForTesting([one[3], one[4], one[2]])
        let feed = try await a.store.feedID(forEpisode: one[0])
        try await a.store.projectHeaderForTesting(feed) { $0.keepUpdated = false }
    }

    /// What A shows equals what a phone attached now shows.
    static func expectRepaired(_ world: ExchangeWorld, _ a: ExchangePhone, ignoring: Set<String> = [], _ label: String,
                               sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let fresh = try await world.attach("fresh-\(label)")
        var expected = try await fresh.view().withoutTitles, shown = try await a.view().withoutTitles
        for id in ignoring { expected.episodes[id] = nil; shown.episodes[id] = nil }
        let differences = shown.differences(from: expected)
        #expect(differences.isEmpty, "\(label): A differs from a fresh attach:\n\(differences.joined(separator: "\n"))",
                sourceLocation: sourceLocation)
        await fresh.close()
    }

    @Test func wrongLiveRowsAreRepairedWhileFactsTheServerHasNotTakenStay() async throws {
        try await ExchangeWorld.run { world in
            let (a, _, one, two) = try await Self.world(world)
            // The player holds an episode (its play load's queue add is sent): its position is the player's (PROTOCOL §6.8).
            _ = try await a.store.beginPlayback(episodeID: one[1])
            await a.exchange()
            try await Self.corrupt(a, one: one, two: two)
            try await a.store.projectForTesting(one[1]) { $0.userState.positionMilliseconds = 12_345 }
            #expect(try await !Concurrency.converged(world, a), "the live rows are wrong, the base right")
            // A pending local fact the server cannot take yet (it waits for a dependency) and its overlay.
            guard let ref = try await a.store.episodeRefForTesting(two[1]) else { Issue.record("no reference"); return }
            try await a.store.projectForTesting(two[1]) { $0.userState.isFavorite = true }
            try await a.store.appendFactForTesting(type: "favorite.set", targets: [ref.target], payload: ["episode": ref.ref, "on": true],
                dependencies: [ContractIdentity.randomUUID()],
                overlays: [ServerOverlay(entity: "episode", id: ref.target.id, property: "favorite", kind: .register, value: true)])
            let outbox = try a.rows("SELECT op_id, install_seq, receipt IS NULL FROM ntp_outbox ORDER BY install_seq")
            let report = await a.engine.forceFullSynchronization()
            #expect(report.reprojected && report.error == nil, "\(String(describing: report.error))")
            #expect(report.publishedUnits == 1, "one publication")
            let pendingWire = ref.target.id, playingWire = try #require(try await a.store.wireEpisodeForTesting(one[1]))
            try await Self.expectRepaired(world, a, ignoring: [pendingWire, playingWire], "repaired")
            #expect(try await a.store.episode(id: two[1])?.userState.isFavorite == true, "the pending favorite still shows")
            #expect(try a.rows("SELECT op_id, install_seq, receipt IS NULL FROM ntp_outbox ORDER BY install_seq") == outbox, "the outbox is never touched")
            let held = try #require(try await a.store.episode(id: one[1]))
            #expect(held.userState.positionMilliseconds == 12_345, "the player's position stays the player's")
            #expect(held.userState.playedDurationMilliseconds == 90_000, "everything else about it is repaired")
            let log = try await a.engine.logEntries()
            #expect(log.contains { $0.kind == "full" && $0.detail.hasPrefix("reprojected") })
            // A second repair finds nothing to change: it holds the live lock for no more than a handful of writes.
            let again = await a.engine.forceFullSynchronization()
            #expect(again.reprojected && (again.units.first?.work ?? .max) <= 4, "\(again.units)")
        }
    }

    @Test func projectedRowsTheServerNoLongerHoldsGoAndLocalOnlyStateStays() async throws {
        try await ExchangeWorld.run { world in
            let (a, _, one, _) = try await Self.world(world)
            let feed = try await a.store.feedID(forEpisode: one[0])
            let podcast = try #require(try await a.store.podcastOfFeedForTesting(feed))
            // A podcast and an episode the base held (as if pulled before) that the server no longer has.
            let ghostPodcast = "p1:" + String(repeating: "e", count: 64), ghostFeed = try await a.store.insertFeedForTesting(source: "https://gone.example/feed.xml", episodes: 2)
            try await a.store.mapPodcastForTesting(ghostPodcast, feed: ghostFeed.id, records: [
                "identity": ["aliases": [["url": "https://gone.example/feed.xml", "normalized": "https://gone.example/feed.xml"]], "refresh_url": "https://gone.example/feed.xml"],
                "subscription": ["state": "subscribed", "generation_id": .string("g1:" + String(repeating: "f", count: 64))]])
            let ghostEpisode = "e1:" + String(repeating: "d", count: 64)
            let extra = try await a.store.insertEpisodeForTesting(feedID: feed, guid: "gone-1")
            try await a.store.mapEpisodeForTesting(ghostEpisode, local: extra, podcast: podcast)
            // Local-only state: an episode no fact named, a local folder and an unregistered preview.
            let local = try await a.store.insertEpisodeForTesting(feedID: feed, guid: "local-only")
            let folder = try await a.store.registerLocalFolder(title: "Folder", directoryIdentity: "folder-1", bookmark: Data([1]))
            let preview = try await a.store.preparePreview(Agreement.fetched(world.url("three.xml"), title: "Three", prefix: "three", count: 3))
            let report = await a.engine.forceFullSynchronization()
            #expect(report.reprojected && report.error == nil, "\(String(describing: report.error))")
            #expect(try await a.store.feed(id: ghostFeed.id) == nil, "a podcast the server no longer holds goes")
            #expect(try await a.store.episode(id: extra) == nil, "an episode the server no longer holds goes")
            #expect(try await a.store.pendingEffects().contains { if case .deleteFeed = $0.effect.kind { true } else { false } })
            #expect(try await a.store.pendingEffects().contains { if case .removeEpisodes = $0.effect.kind { true } else { false } },
                    "their files go through the two-phase cleanup")
            #expect(try await a.store.episode(id: local) != nil, "an episode the server never knew stays")
            #expect(try await a.store.feed(id: folder.feed.id) != nil, "a local folder stays")
            #expect(try await a.store.feed(id: preview.id) != nil, "an unregistered preview stays")
            try await Self.expectRepaired(world, a, "removed")
        }
    }

    /// A cross-podcast change (played times of both podcasts) and a queue reorder publish in one
    /// switch; a crash inside it leaves everything as it was.
    @Test func aCrossPodcastRepairAndAQueueReorderPublishInOneSwitch() async throws {
        try await ExchangeWorld.run { world in
            let (a, _, one, two) = try await Self.world(world)
            try await Self.corrupt(a, one: one, two: two)
            let wrong = try await a.view()
            await a.engine.setCrashPoint(PushPull.crashOnce(at: "full.written"))
            let crashed = await a.engine.forceFullSynchronization()
            #expect(crashed.error == "InjectedCrash()")
            #expect(try await a.view() == wrong, "nothing of the switch is visible after a crash inside it")
            try await a.relaunch()
            let store = a.store
            let seen = SeenViews()
            await a.engine.setBeforePublish { seen.duringBuild = try await store.syncedViewForTesting() }
            let report = await a.engine.forceFullSynchronization()
            #expect(seen.duringBuild == wrong, "staged outside the live rows")
            #expect(report.reprojected && report.units.count == 1 && report.units.first?.published == true)
            let after = try await a.view()
            for id in [one[0], two[0]] {
                #expect(after.episodes[try #require(try await a.store.wireEpisodeForTesting(id))]?.playedTime == 90_000)
            }
            try await Self.expectRepaired(world, a, "one switch")
        }
    }

    /// A repair over the publication budget waits while the app is in use, even while audio plays; once the person leaves
    /// the app, still playing, it is published whole in one transaction within the background budget (the path a
    /// recovery's repair takes too, `publishFullReprojection` with the engine's ticket).
    @Test func whileAudioPlaysInTheBackgroundALargeRepairIsPublishedWhole() async throws {
        try await ExchangeWorld.run { world in
            let (a, _, one, two) = try await Self.world(world)
            try await Self.corrupt(a, one: one, two: two)
            let wrong = try await a.view()
            await a.engine.setBudgets(publish: 2)
            a.playing.value = true
            a.foreground.value = true
            let waiting = await a.engine.forceFullSynchronization()
            #expect(waiting.waitingForBackground && !waiting.reprojected, "\(waiting)")
            #expect(try await a.view() == wrong)
            a.foreground.value = false
            let left = await a.engine.forceFullSynchronization()
            #expect(left.reprojected && left.units.first?.background == true, "whole while playing in the background: \(left)")
            try await Self.expectRepaired(world, a, "in the background while playing")
        }
    }

    @Test func whileAudioPlaysALargeRepairWaitsForAPause() async throws {
        try await ExchangeWorld.run { world in
            let (a, _, one, two) = try await Self.world(world)
            try await Self.corrupt(a, one: one, two: two)
            let wrong = try await a.view()
            // Over the background budget too: with the app in the background, it waits for the pause.
            await a.engine.setBudgets(publish: 2, background: 2)
            a.playing.value = true
            let waiting = await a.engine.forceFullSynchronization()
            #expect(waiting.waitingForPause && !waiting.reprojected)
            #expect(try await a.view() == wrong)
            a.playing.value = false
            let paused = await a.engine.forceFullSynchronization()
            #expect(paused.reprojected)
            try await Self.expectRepaired(world, a, "after the pause")
        }
    }

    /// A repair over the 100 ms budget never runs while someone uses the app; it waits, says so,
    /// and runs once the app is in the background.
    @Test func whileTheAppIsInUseALargeRepairWaitsForTheBackground() async throws {
        try await ExchangeWorld.run { world in
            let (a, _, one, two) = try await Self.world(world)
            try await Self.corrupt(a, one: one, two: two)
            let wrong = try await a.view()
            await a.engine.setBudgets(publish: 2)
            a.foreground.value = true
            let waiting = await a.engine.forceFullSynchronization()
            #expect(waiting.waitingForBackground && !waiting.waitingForPause && !waiting.reprojected && !waiting.completed, "\(waiting)")
            #expect(try await a.view() == wrong, "nothing of it shows while the app is in use")
            #expect(try await a.engine.logEntries().contains { $0.detail.contains("in the background") })
            a.foreground.value = false
            let background = await a.engine.forceFullSynchronization()
            #expect(background.reprojected)
            try await Self.expectRepaired(world, a, "in the background")
        }
    }

    /// A local action between the repair's build and its switch is kept: the switch re-projects what it touched (PROTOCOL §6.8),
    /// and the repair is not built again.
    @Test func aLocalActionDuringStagingIsKeptAndReprojectedAtThePublication() async throws {
        try await ExchangeWorld.run { world in
            let (a, _, one, two) = try await Self.world(world)
            try await Self.corrupt(a, one: one, two: two)
            let store = a.store, once = PlayingFlag()
            await a.engine.setBeforePublish {
                guard !once.value else { return }
                once.value = true
                try await store.markEpisodePlayed(episodeID: one[0], played: true)
            }
            let report = await a.engine.forceFullSynchronization()
            #expect(report.reprojected)
            #expect(try await a.store.episode(id: one[0])?.userState.playState == .played, "the person's mark is kept")
            #expect(report.shadowsBuilt == 1 && report.rebasedEntities >= 1, "\(report)")
            #expect(try await !a.engine.logEntries().contains { $0.kind == "full" && $0.detail.contains("staged again") })
            await a.engine.setBeforePublish(nil)
            await a.exchange()
            try await Self.expectRepaired(world, a, "re-projected at the publication")
        }
    }

    /// A server library's own listening not sent yet (session facts still in the outbox) is never undone by a
    /// repair: the resume position and last played stay, shown by those facts. While the player saves, a repair of the
    /// playing podcast is published anyway: its switch re-projects the playing episode the saves touched (PROTOCOL §6.8), which
    /// keeps them.
    @Test func listeningNoFactCarriesYetIsKeptAndPlaybackSavesDuringTheRepairAreKept() async throws {
        try await ExchangeWorld.run { world in
            let (a, _, one, two) = try await Self.world(world)
            // A listened to one[2] here (nothing sent), then moved on to one[3], which plays on.
            let earlier = try await a.store.beginPlayback(episodeID: one[2])
            try await a.store.recordPlaybackIntent(sessionID: earlier.id, positionMilliseconds: 0, durationMilliseconds: 600_000,
                                                   baseline: UUID(), intentional: true)
            _ = try await a.store.recordPlayback(sessionID: earlier.id, sample: PlaybackSample(positionMilliseconds: 321_000,
                durationMilliseconds: 600_000, status: .paused))
            let listened = try #require(try await a.store.episode(id: one[2]))
            #expect(listened.userState.positionMilliseconds == 321_000 && listened.userState.lastPlayedTimeMilliseconds > 0)
            let session = try await a.store.beginPlayback(episodeID: one[3])
            try await Self.corrupt(a, one: one, two: two)
            let wrong = try await a.view()
            let store = a.store
            a.playing.value = true
            // A playback save lands in every window between staging and publication (as the player saves every few
            // seconds while the repair stages).
            let position = TokenBox("0")
            await a.engine.setBeforePublish {
                let next = (Int32(position.value) ?? 0) + 1_000
                position.value = String(next)
                _ = try await store.recordPlayback(sessionID: session.id, sample: PlaybackSample(positionMilliseconds: next,
                    durationMilliseconds: 600_000, status: .playing))
            }
            let playing = await a.engine.forceFullSynchronization()
            await a.engine.setBeforePublish(nil)
            #expect(playing.reprojected && !playing.waitingForPause, "the playing podcast's repair is published while playing: \(playing)")
            #expect(playing.shadowsBuilt == 1 && playing.rebasedEntities >= 1, "\(playing)")
            #expect(try await a.store.episode(id: one[3])?.userState.positionMilliseconds == Int32(position.value), "the saves are kept")
            #expect(try await a.view() != wrong)
            a.playing.value = false
            let kept = try #require(try await a.store.episode(id: one[2]))
            #expect(kept.userState.positionMilliseconds == 321_000, "the resume position this device saved stays")
            #expect(kept.userState.lastPlayedTimeMilliseconds == listened.userState.lastPlayedTimeMilliseconds)
            #expect(try await a.store.episode(id: two[2])?.userState.isFavorite == true, "the wrong favorite is repaired")
            #expect(try await a.store.episode(id: one[0])?.userState.playedDurationMilliseconds == 90_000, "the wrong played time is repaired")
        }
    }

    /// A repair requested while it had to wait, then the app was stopped before it could run: after
    /// the relaunch the scheduler runs it at launch and the request is fulfilled.
    @MainActor @Test func aRequestedRepairSurvivesARelaunch() async throws {
        try await ServerSyncSchedulingServerTests.inWorld { world in
            let (a, _, one, two) = try await Self.world(world)
            try await Self.corrupt(a, one: one, two: two)
            await a.engine.setBudgets(publish: 2, background: 2)
            a.playing.value = true
            await a.engine.requestFullSynchronization()
            #expect(await a.engine.forceFullSynchronization().waitingForPause)
            try await a.relaunch()
            a.playing.value = false
            #expect(await a.engine.fullSynchronizationRequested(), "the request is kept across the relaunch")
            let scheduler = ServerSyncScheduler(engine: a.engine, hints: nil, outbox: nil, network: ServerSyncSchedulingServerTests.Permitted())
            scheduler.start()
            #expect(try await ServerSyncSchedulingServerTests.waitFor { scheduler.lastReport?.reprojected == true })
            #expect(await !a.engine.fullSynchronizationRequested(), "fulfilled with the publication")
            await scheduler.stop()
            try await Self.expectRepaired(world, a, "after the relaunch")
        }
    }

    static let crashPoints = ["full.spooled", "full.staged", "full.built", "full.base", "full.written", "full.published"]

    @Test(arguments: crashPoints) func aCrashAtEveryStepLeavesNothingHalfDone(point: String) async throws {
        try await ExchangeWorld.run { world in
            let (a, _, one, two) = try await Self.world(world)
            try await a.store.setFavorite(episodeID: one[2], favorite: true)
            await a.exchange()
            try await Self.corrupt(a, one: one, two: two)
            let wrong = try await a.view()
            let base = try a.rows("SELECT count(*), coalesce(sum(length(value)), 0) FROM ntp_records")
            // A later action, still unsent when the repair starts: it is pushed first, and never lost.
            try await a.store.setFavorite(episodeID: one[3], favorite: true)
            await a.engine.setCrashPoint(PushPull.crashOnce(at: point))
            let crashed = await a.engine.forceFullSynchronization()
            #expect(crashed.error == "InjectedCrash()", "\(point)")
            if point != "full.published" {
                var expected = wrong
                let wire = try #require(try await a.store.wireEpisodeForTesting(one[3]))
                expected.episodes[wire]?.favorite = true
                #expect(try await a.view() == expected, "\(point): nothing of the repair is visible")
                if point == "full.spooled" {
                    #expect(try a.rows("SELECT count(*), coalesce(sum(length(value)), 0) FROM ntp_records") == base, "\(point): the base is unchanged")
                }
            }
            try await a.relaunch()
            let report = await a.engine.forceFullSynchronization()
            #expect(report.reprojected || point == "full.published", "\(point): \(String(describing: report.error))")
            await a.exchange()
            #expect(try await a.store.serverUnsentChanges() == 0, "\(point): the favorite was sent")
            try await Self.expectRepaired(world, a, point)
            let staging = try FileManager.default.contentsOfDirectory(atPath: try #require(a.location.staging).path)
            #expect(!staging.contains { $0.hasPrefix("full") }, "\(point): no staging left: \(staging)")
        }
    }
}

extension ServerExchangeConcurrencyTests {
    /// Whether a phone shows what a phone attached now shows.
    static func converged(_ world: ExchangeWorld, _ phone: ExchangePhone) async throws -> Bool {
        let fresh = try await world.attach("check")
        let same = try await phone.view().withoutTitles.differences(from: fresh.view().withoutTitles).isEmpty
        await fresh.close()
        return same
    }
}

extension FeedLibraryStore {
    /// The queue rewritten without any fact (a wrong live row).
    func setQueueForTesting(_ ids: [Int64]) throws {
        try database.transaction {
            try database.execute("DELETE FROM queue")
            for (index, id) in ids.enumerated() {
                try database.execute("INSERT INTO queue(position, episode_id) VALUES (?, ?)", [.integer(Int64(index)), .integer(id)])
            }
        }
    }

    /// A feed header changed without any fact.
    func projectHeaderForTesting(_ id: Int64, _ change: @Sendable (inout LibraryFeed) -> Void) throws {
        try write(.remote) {
            guard var header = try loadFeedHeader(id) else { return }
            change(&header)
            try saveHeader(header)
        }
    }

    /// A feed with `episodes` episodes written directly (no registration).
    func insertFeedForTesting(source: String, episodes: Int) throws -> LibraryFeed {
        try database.transaction {
            let id = try database.allocateID("feed")
            let feed = LibraryFeed(id: id, source: source, metadata: ParsedFeed(format: .rss, title: "Gone"), episodes: [])
            try database.execute("INSERT INTO feeds(id, title, record) VALUES (?, ?, ?)", [.integer(id), .text("Gone"), .blob(try JSONEncoder().encode(feed))])
            for number in 0..<episodes { _ = try insertEpisodeRow(feedID: id, guid: "gone-feed-\(number)") }
            return feed
        }
    }

    /// An episode row written directly into a feed.
    func insertEpisodeForTesting(feedID: Int64, guid: String) throws -> Int64 {
        try database.transaction { try insertEpisodeRow(feedID: feedID, guid: guid) }
    }

    private func insertEpisodeRow(feedID: Int64, guid: String) throws -> Int64 {
        let id = try database.allocateID("episode")
        let episode = LibraryEpisode(id: id, details: ParsedEpisode(identifier: guid, title: guid, publicationDate: Date(timeIntervalSince1970: 1_700_000_000),
                                                                     media: ParsedMedia(url: "https://media.example/\(guid).mp3", size: 1)))
        try database.execute("INSERT INTO episodes(id, feed_id, pubdate, record) VALUES (?, ?, ?, ?)",
                             [.integer(id), .integer(feedID), .integer(1_700_000_000_000), .blob(try JSONEncoder().encode(episode))])
        return id
    }

    /// A podcast mapped to a local feed with records in the base, as a pull would have left it.
    func mapPodcastForTesting(_ podcast: String, feed: Int64, records: [String: ContractJSON]) throws {
        try database.transaction {
            try database.execute("INSERT INTO ntp_podcasts(podcast_id, feed_id, live_generation) VALUES (?, ?, ?)",
                                 [.text(podcast), .integer(feed), records["subscription"]?["generation_id"]?.stringValue.map(LibrarySQLValue.text) ?? .null])
            for (group, value) in records {
                try FeedLibraryStore.writeRecord(ServerRecord(entity: "podcast", id: podcast, fieldGroup: group, value: value), to: database)
            }
        }
    }

    /// An episode identity in the base mapped to a local row, as a pull would have left it.
    func mapEpisodeForTesting(_ episode: String, local: Int64, podcast: String) throws {
        try database.transaction {
            try FeedLibraryStore.writeRecord(ServerRecord(entity: "episode", id: episode, fieldGroup: "identity", value: [
                "podcast_id": .string(podcast), "occurrence": ["k": "rss-guid", "v": "gone-1", "guid": "gone-1"]]), to: database)
            try database.execute("UPDATE ntp_episodes SET local_id = ? WHERE episode_id = ?", [.integer(local), .text(episode)])
        }
    }
}
