import Foundation
import Testing
@testable import NotTennaPodCore

/// Concurrent remote changes against pending, rejected and `not_applied` local facts (PROTOCOL §6.8),
/// with A's displayed state checked after each prefix of the exchange, and PROTOCOL §16 multi-device scenarios 5–13 as
/// far as the exchange's parts reach (listening facts are written directly).
@Suite(.serialized, .timeLimit(.minutes(30))) struct ServerExchangeConcurrencyTests {
    typealias Agreement = ServerExchangeAgreementTests

    /// Everyone exchanges until nothing is pending, and every phone, and a phone attached now, shows the same.
    static func converge(_ world: ExchangeWorld, _ phones: [ExchangePhone], _ label: String,
                         sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<2 { for phone in phones { await phone.exchange(sourceLocation: sourceLocation) } }
        let fresh = try await world.attach("fresh-\(label)")
        let expected = try await fresh.view()
        for phone in phones {
            let differences = try await phone.view().withoutTitles.differences(from: expected.withoutTitles)
            #expect(differences.isEmpty, "\(label): \(phone.name) differs from a fresh attach:\n\(differences.joined(separator: "\n"))",
                    sourceLocation: sourceLocation)
        }
        await fresh.close()
    }

    /// Two phones on one podcast: A subscribed it, C pulled it.
    static func twoPhones(_ world: ExchangeWorld) async throws -> (a: ExchangePhone, c: ExchangePhone, feedA: LibraryFeed, episodesA: [Int64], podcast: String) {
        let a = try await world.attach("A")
        let feed = try await a.store.insert(Agreement.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
        try await Agreement.waitForCatalog(a, feedID: feed.id)
        let c = try await world.attach("C")
        let podcast = try #require(try await a.store.podcastOfFeedForTesting(feed.id))
        return (a, c, feed, feed.episodes.map(\.id).sorted(), podcast)
    }

    /// The local episode on `phone` of `a`'s local episode.
    static func same(_ episode: Int64, from a: ExchangePhone, on phone: ExchangePhone) async throws -> Int64 {
        let wire = try #require(try await a.store.wireEpisodeForTesting(episode))
        return try #require(try await phone.store.localEpisodeForTesting(wire: wire))
    }

    static func feed(of podcast: String, on phone: ExchangePhone) async throws -> Int64 {
        try #require(try await phone.store.feedOfPodcastForTesting(podcast))
    }

    // MARK: - Named cases

    @Test func aPendingKeepUpdatedChangeShowsARemoteNewEpisodesAction() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, feed, _, podcast) = try await Self.twoPhones(world)
            try await a.store.updatePreferences(feedID: feed.id) { $0.keepUpdated = false }
            try await c.store.updatePreferences(feedID: try await Self.feed(of: podcast, on: c)) { $0.newEpisodesAction = .queue }
            await c.exchange()
            await a.run([.pull, .apply])
            let shown = try #require(try await a.view().podcasts[podcast])
            #expect(shown.keepUpdated == false, "A's pending keep updated stays")
            #expect(shown.newEpisodesAction == .queue, "C's action shows over the base")
            try await Self.converge(world, [a, c], "policies")
            let converged = try #require(try await a.view().podcasts[podcast])
            #expect(converged.keepUpdated == false && converged.newEpisodesAction == .queue)
        }
    }

    @Test func aPendingHistoryRemovalShowsARemoteEntryItNeverObserved() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Self.twoPhones(world)
            let d = try await world.attach("D")
            let episode = ids[0]
            // C listens now; A learns it.
            var listening = RemoteSession(store: c.store, episode: try await Self.same(episode, from: a, on: c))
            try await listening.start(at: 0)
            try await listening.end(position: 60_000, contribution: 60_000, completed: false)
            await c.exchange()
            await a.exchange()
            let known = try #require(try await a.store.episode(id: episode)?.userState.lastPlayedHistoryMilliseconds)
            // A removes the episode from history; before it is sent, D's listening of yesterday arrives.
            #expect(try await a.store.removeFromPlaybackHistoryWithUndo(episode) != nil)
            #expect(try await a.store.episode(id: episode)?.userState.lastPlayedHistoryMilliseconds == nil)
            let yesterday = Date(timeIntervalSince1970: Double(known) / 1_000 - 86_400)
            var old = RemoteSession(store: d.store, episode: try await Self.same(episode, from: a, on: d))
            try await old.start(at: 0, now: yesterday)
            try await old.end(position: 1_000, contribution: 1_000, completed: false, now: yesterday.addingTimeInterval(1))
            await d.exchange()
            await a.run([.pull, .apply])
            let shown = try await a.store.episode(id: episode)?.userState.lastPlayedHistoryMilliseconds
            #expect(shown != nil && shown! < known, "D's older entry, which A's removal never observed, shows: \(String(describing: shown))")
            try await Self.converge(world, [a, c, d], "history removal")
            #expect(try await a.store.episode(id: episode)?.userState.lastPlayedHistoryMilliseconds == shown, "as the server folds it")
        }
    }

    @Test func aPendingHistoryClearShowsRemoteActivityItNeverObserved() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Self.twoPhones(world)
            let d = try await world.attach("D")
            var first = RemoteSession(store: c.store, episode: try await Self.same(ids[0], from: a, on: c))
            try await first.start(at: 0)
            try await first.end(position: 30_000, contribution: 30_000, completed: false)
            await c.exchange()
            await a.exchange()
            let known = try #require(try await a.store.episode(id: ids[0])?.userState.lastPlayedHistoryMilliseconds)
            _ = try await a.store.clearPlaybackHistory()
            // Activity the clear never observed: D's listening of the same episode yesterday, and C's of another now.
            let yesterday = Date(timeIntervalSince1970: Double(known) / 1_000 - 86_400)
            var old = RemoteSession(store: d.store, episode: try await Self.same(ids[0], from: a, on: d))
            try await old.start(at: 0, now: yesterday)
            try await old.end(position: 1_000, contribution: 1_000, completed: false, now: yesterday.addingTimeInterval(1))
            await d.exchange()
            var later = RemoteSession(store: c.store, episode: try await Self.same(ids[1], from: a, on: c))
            try await later.start(at: 0)
            try await later.end(position: 10_000, contribution: 10_000, completed: false)
            await c.exchange()
            await a.run([.pull, .apply])
            let shown = try await a.store.episode(id: ids[0])?.userState.lastPlayedHistoryMilliseconds
            #expect(shown != nil && shown! < known, "the cleared entry stays cleared and D's unobserved one shows: \(String(describing: shown))")
            #expect(try await a.store.episode(id: ids[1])?.userState.lastPlayedHistoryMilliseconds != nil, "activity the clear never observed shows")
            try await Self.converge(world, [a, c, d], "history clear")
            #expect(try await a.store.episode(id: ids[0])?.userState.lastPlayedHistoryMilliseconds == shown, "as the server folds it")
        }
    }

    @Test func aPendingStatisticsResetCountsOnlyLaterRemoteListening() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Self.twoPhones(world)
            var listening = RemoteSession(store: c.store, episode: try await Self.same(ids[0], from: a, on: c))
            try await listening.start(at: 0)
            try await listening.checkpoint(position: 100_000, contribution: 100_000)
            await c.exchange()
            await a.exchange()
            #expect(try await a.store.episode(id: ids[0])?.userState.playedDurationMilliseconds == 100_000)
            try await a.store.resetPlayedDurationStatistics()
            try await listening.checkpoint(position: 250_000, contribution: 250_000)
            await c.exchange()
            await a.run([.pull, .apply])
            #expect(try await a.store.episode(id: ids[0])?.userState.playedDurationMilliseconds == 150_000,
                    "only the listening after the reset counts")
            try await Self.converge(world, [a, c], "statistics reset")
            #expect(try await a.store.episode(id: ids[0])?.userState.playedDurationMilliseconds == 150_000, "as the server folds it")
        }
    }

    /// A local archive the server finds `not_applied` (another device unsubscribed first) retires: the server's
    /// removal shows.
    @Test func aNotAppliedArchiveRetiresAndTheRemoteRemovalShows() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, feed, _, podcast) = try await Self.twoPhones(world)
            try await a.store.updatePreferences(feedID: feed.id) { $0.subscriptionState = .archived }
            #expect(try await c.store.requestFeedDeletion(feedID: try await Self.feed(of: podcast, on: c)))
            await c.exchange()
            await a.run([.pull, .apply])
            #expect(try await a.view().podcasts[podcast]?.subscription == .archived, "A's pending archive shows until it retires")
            await a.exchange()
            #expect(try await a.view().podcasts[podcast] == nil, "the removal shows once the archive retired")
            let log = try await a.engine.logEntries()
            #expect(log.contains { $0.kind == "outcome" && $0.detail.hasPrefix("podcast.archive not_applied") })
            try await Self.converge(world, [a, c], "not applied")
        }
    }

    // MARK: - Scenarios 5–13 (PROTOCOL §16)

    /// 5. Two phones offline for a day each listen to the same episode: the position is the session that started
    /// last, and statistics count both.
    @Test func scenario5TwoOfflinePhonesListenToTheSameEpisode() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Self.twoPhones(world)
            // A's session starts first (its clock says two hours ago; causality clamps it to A's last action), C's
            // later; neither sees the other's.
            let now = Date()
            var onA = RemoteSession(store: a.store, episode: ids[0])
            try await onA.start(at: 0, now: now.addingTimeInterval(-7_200))
            try await onA.checkpoint(position: 600_000, contribution: 600_000, now: now.addingTimeInterval(-6_600))
            var onC = RemoteSession(store: c.store, episode: try await Self.same(ids[0], from: a, on: c))
            try await onC.start(at: 0, now: now.addingTimeInterval(1))
            try await onC.checkpoint(position: 300_000, contribution: 300_000, now: now.addingTimeInterval(2))
            await c.exchange()
            await a.exchange()
            try await Self.converge(world, [a, c], "scenario 5")
            let episode = try #require(try await a.store.episode(id: ids[0]))
            #expect(episode.userState.positionMilliseconds == 300_000, "the session that started last")
            #expect(episode.userState.playedDurationMilliseconds == 900_000, "both count")
        }
    }

    /// 6. An old session keeps sending checkpoints; the newer listening is never rewound.
    @Test func scenario6AnOldSessionNeverRewindsNewerListening() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Self.twoPhones(world)
            var old = RemoteSession(store: c.store, episode: try await Self.same(ids[0], from: a, on: c))
            try await old.start(at: 0)
            try await old.checkpoint(position: 60_000, contribution: 60_000)
            await c.exchange()
            await a.exchange()
            var newer = RemoteSession(store: a.store, episode: ids[0])
            try await newer.start(at: 60_000)
            try await newer.checkpoint(position: 900_000, contribution: 840_000)
            await a.exchange()
            try await old.checkpoint(position: 120_000, contribution: 120_000)
            await c.exchange()
            try await Self.converge(world, [a, c], "scenario 6")
            #expect(try await a.store.episode(id: ids[0])?.userState.positionMilliseconds == 900_000)
        }
    }

    /// 7. Paused 10 s from the end on A, replayed from the start on C; later A starts another episode: the episode is
    /// not marked played (A's lazy finalization lost its claim).
    @Test func scenario7AStaleFinalizationDoesNotMarkPlayed() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Self.twoPhones(world)
            var onA = RemoteSession(store: a.store, episode: ids[0])
            try await onA.start(at: 0)
            try await onA.checkpoint(position: 590_000, contribution: 590_000)
            await a.exchange()
            await c.exchange()
            var onC = RemoteSession(store: c.store, episode: try await Self.same(ids[0], from: a, on: c))
            try await onC.start(at: 0)
            try await onC.checkpoint(position: 30_000, contribution: 30_000)
            await c.exchange()
            try await onA.finalize(completed: true)
            await a.exchange()
            try await Self.converge(world, [a, c], "scenario 7")
            let episode = try #require(try await a.store.episode(id: ids[0]))
            #expect(episode.userState.playState != .played)
            #expect(episode.userState.positionMilliseconds == 30_000)
        }
    }

    /// 8. A removes an episode from the queue while offline C moves it: it is not in the queue, in either order.
    @Test(arguments: [true, false]) func scenario8ARemovalWinsOverAConcurrentMove(removalFirst: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Self.twoPhones(world)
            _ = try await a.store.enqueue(Array(ids.prefix(3)))
            await a.exchange()
            await c.exchange()
            _ = try await a.store.removeFromQueue([ids[1]])
            let onC = try await Self.same(ids[1], from: a, on: c)
            _ = try await c.store.performQueueMove(.item(onC, finalIndex: 0), expected: try await c.store.queue().map(QueueEpisodeIdentity.init))
            if removalFirst { await a.exchange(); await c.exchange() } else { await c.exchange(); await a.exchange() }
            try await Self.converge(world, [a, c], "scenario 8")
            let wire = try #require(try await a.store.wireEpisodeForTesting(ids[1]))
            #expect(try await !a.view().queue.contains(wire))
        }
    }

    /// 8c. Two offline phones each reset statistics after listening: after sync, neither phone's listening before its
    /// own reset is counted; while A's reset is pending it shows only what its reset did not observe.
    @Test func scenario8cTwoOfflineResetsCountNothingBeforeThem() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Self.twoPhones(world)
            var onA = RemoteSession(store: a.store, episode: ids[0])
            try await onA.start(at: 0)
            try await onA.checkpoint(position: 100_000, contribution: 100_000)
            await a.exchange()
            try await a.store.resetPlayedDurationStatistics()
            var onC = RemoteSession(store: c.store, episode: try await Self.same(ids[0], from: a, on: c))
            try await onC.start(at: 0)
            try await onC.checkpoint(position: 200_000, contribution: 200_000)
            await c.exchange()
            await a.run([.pull, .apply])
            #expect(try await a.store.episode(id: ids[0])?.userState.playedDurationMilliseconds == 200_000,
                    "C's listening, which A's reset did not observe, counts")
            try await c.store.resetPlayedDurationStatistics()
            await c.exchange()
            await a.run([.pull, .apply])
            #expect(try await a.store.episode(id: ids[0])?.userState.playedDurationMilliseconds == 0)
            try await Self.converge(world, [a, c], "scenario 8c")
            #expect(try await a.store.episode(id: ids[0])?.userState.playedDurationMilliseconds == 0)
        }
    }

    /// 9. A clears the queue while offline C adds an episode: C's episode remains.
    @Test func scenario9AClearKeepsAConcurrentAdd() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Self.twoPhones(world)
            _ = try await a.store.enqueue([ids[0], ids[1]])
            await a.exchange()
            await c.exchange()
            _ = try await a.store.clearQueue()
            _ = try await c.store.enqueue([try await Self.same(ids[2], from: a, on: c)])
            await c.exchange()
            await a.exchange()
            try await Self.converge(world, [a, c], "scenario 9")
            #expect(try await a.view().queue == [try #require(try await a.store.wireEpisodeForTesting(ids[2]))])
        }
    }

    /// 10. A unsubscribes while offline C listens to one of its episodes: the podcast is gone everywhere, C's later
    /// listening is recorded but not applied, and C's player keeps its episode until it leaves it (PROTOCOL §6.8).
    @Test func scenario10AnUnsubscribeWhileAnotherPhoneListens() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, feed, ids, podcast) = try await Self.twoPhones(world)
            let three = try await a.store.insert(Agreement.fetched(world.url("three.xml"), title: "Three", prefix: "three", count: 3))
            try await Agreement.waitForCatalog(a, feedID: three.id)
            await c.exchange()
            let playing = try await Self.same(ids[0], from: a, on: c)
            _ = try await c.store.beginPlayback(episodeID: playing)
            try await c.store.setFavorite(episodeID: playing, favorite: true)
            await c.exchange()
            #expect(try await a.store.requestFeedDeletion(feedID: feed.id))
            await a.exchange()
            var listening = RemoteSession(store: c.store, episode: playing)
            try await listening.start(at: 0)
            try await listening.checkpoint(position: 30_000, contribution: 30_000)
            await c.exchange()
            // C's podcast leaves every library-wide read at once; only the player still reads its episode.
            #expect(try await !c.store.feeds().contains { $0.title == "One" })
            #expect(try await !c.store.snapshot().feeds.contains { $0.title == "One" })
            let kept = try #require(try await c.store.episode(id: playing))
            #expect(!kept.userState.isFavorite && kept.userState.lastPlayedHistoryMilliseconds == nil)
            let log = try await c.engine.logEntries()
            #expect(log.contains { $0.kind == "outcome" && $0.detail.contains("not_applied") }, "C's later listening is not applied")
            // The player leaves the episode: the removal finishes.
            _ = try await c.store.beginPlayback(episodeID: try await Self.same(three.episodes.map(\.id).min()!, from: a, on: c))
            await c.exchange()
            #expect(try await c.store.episode(id: playing) == nil)
            #expect(try c.rows("SELECT pinned_removal FROM ntp_podcasts WHERE podcast_id = '\(podcast)'") == [["0"]])
            try await Self.converge(world, [a, c], "scenario 10")
        }
    }

    /// 11. "Remove all from Inbox" on A does not dismiss an episode filed into the Inbox concurrently.
    @Test func scenario11RemoveAllFromInboxKeepsAConcurrentFiling() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, _, podcast) = try await Self.twoPhones(world)
            // The publisher adds an episode; the server's own fetch files it into the Inbox (PROTOCOL §9).
            world.setFeed("/one.xml", ("One", "one", 6))
            _ = try await a.transport.server.send("POST", "v1/refresh", body: ["podcast_id": .string(podcast)])
            try await Self.waitForInbox(a, count: 1)
            world.setFeed("/one.xml", ("One", "one", 7))
            _ = try await c.transport.server.send("POST", "v1/refresh", body: ["podcast_id": .string(podcast)])
            try await Self.waitForInbox(c, count: 2)
            // A has not pulled the second filing when it removes all from its Inbox.
            #expect(try await a.store.removeAllFromInbox().count == 1)
            try await Self.converge(world, [a, c], "scenario 11")
            let inbox = try await a.store.feeds().flatMap(\.episodes).filter { $0.userState.playState == .new }
            #expect(inbox.map(\.details.title) == ["One 7"])
        }
    }

    static func waitForInbox(_ phone: ExchangePhone, count: Int) async throws {
        let clock = ContinuousClock(), end = clock.now.advanced(by: .seconds(60))
        while clock.now < end {
            await phone.exchange()
            if try await phone.store.feeds().flatMap(\.episodes).filter({ $0.userState.playState == .new }).count >= count { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HarnessError.server("the server's filing never arrived")
    }

    /// 12. A favorite added on A and removed on offline C converge to the later action, in either push order.
    @Test(arguments: [true, false]) func scenario12AFavoriteConvergesToTheLaterAction(laterFirst: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Self.twoPhones(world)
            let onC = try await Self.same(ids[0], from: a, on: c)
            try await c.store.setFavorite(episodeID: onC, favorite: true)
            await c.exchange()
            await a.exchange()
            try await a.store.setFavorite(episodeID: ids[0], favorite: false)
            try await c.store.setFavorite(episodeID: onC, favorite: false)
            try await c.store.setFavorite(episodeID: onC, favorite: true)
            if laterFirst { await c.exchange(); await a.exchange() } else { await a.exchange(); await c.exchange() }
            try await Self.converge(world, [a, c], "scenario 12")
            #expect(try await a.store.episode(id: ids[0])?.userState.isFavorite == true, "C's favorite is the later action")
        }
    }

    /// 13. Undo of a mark played restores the previous state and position on every device.
    @Test func scenario13UndoOfAMarkRestoresStateAndPositionEverywhere() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Self.twoPhones(world)
            var listening = RemoteSession(store: c.store, episode: try await Self.same(ids[0], from: a, on: c))
            try await listening.start(at: 0)
            try await listening.checkpoint(position: 60_000, contribution: 60_000)
            await c.exchange()
            await a.exchange()
            let receipt = try #require(try await a.store.applySwipeMark(episodeID: ids[0], action: .togglePlayed))
            await a.exchange()
            await c.exchange()
            #expect(try await c.store.episode(id: try await Self.same(ids[0], from: a, on: c))?.userState.playState == .played)
            #expect(try await a.store.undoSwipeMark(receipt) == .restored)
            try await Self.converge(world, [a, c], "scenario 13")
            let restored = try #require(try await c.store.episode(id: try await Self.same(ids[0], from: a, on: c)))
            #expect(restored.userState.playState == .unplayed && restored.userState.positionMilliseconds == 60_000)
        }
    }
}
