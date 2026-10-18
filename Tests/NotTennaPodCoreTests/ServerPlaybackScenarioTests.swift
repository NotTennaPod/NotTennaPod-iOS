import Foundation
import Testing
@testable import NotTennaPodCore

/// PROTOCOL §16's playback scenarios (5–8c, 31, 36, 37, 41, 43, 44) and the named playback agreement cases, with
/// each phone's own recorder against the pinned server: the phones' players are driven
/// through the store as the coordinator drives it (`StorePlayer`, on the real clock: the order of a scenario's actions
/// is the order the test makes them), the sync layer's adoption runs where a paused player would adopt, and every
/// phone converges with a fresh attachment.
@Suite(.serialized) struct ServerPlaybackScenarioTests {
    typealias Concurrency = ServerExchangeConcurrencyTests
    typealias Discovery = ServerDiscoveryScenarioTests

    static func state(_ phone: ExchangePhone, _ episode: Int64) async throws -> EpisodeUserState {
        try #require(try await phone.store.episode(id: episode)).userState
    }

    /// An Undo after listening: a NEW episode is dismissed with a swipe, played without a pause (its listening not exported
    /// yet), then the swipe is undone (NEW again). After a relaunch (its restart export) and an exchange, this phone, a
    /// Force full synchronization and the other phone all show NEW: the listening saved before the Undo is exported
    /// before the Undo's restore, which follows it. Also when the Undo's first recording fails midway (after the listening's
    /// export, before the restore): it rolls back whole, and the Undo made again keeps the order.
    @Test(arguments: [false, true]) func anUndoAfterUnpausedListeningSurvivesARestart(recorderFails: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, _, podcast) = try await Concurrency.twoPhones(world)
            // A new episode is published: filed NEW (the Inbox).
            world.setFeed("/one.xml", ("One", "one", 6))
            _ = try? await a.transport.server.send("POST", "v1/refresh", body: ["podcast_id": .string(podcast)])
            func newest(_ phone: ExchangePhone) async throws -> LibraryEpisode? {
                try await phone.store.feeds().flatMap(\.episodes).first { $0.details.identifier == "one-6" }
            }
            let deadline = ContinuousClock.now + .seconds(60)
            while ContinuousClock.now < deadline {
                await a.exchange(); await c.exchange()
                if try await newest(a) != nil, try await newest(c) != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let episode = try #require(try await newest(a))
            try #require(episode.userState.playState == .new, "filed in the Inbox")
            let receipt = try #require(try await a.store.applySwipeMark(episodeID: episode.id, action: .togglePlayed))
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(episode.id); try await player.play(); try await player.listen(41)
            if recorderFails {
                await a.store.injectRecorderFailure(after: 1)
                await #expect(throws: (any Error).self) { _ = try await a.store.undoSwipeMark(receipt) }
                await a.store.injectRecorderFailure(after: nil)
                #expect(try await Self.state(a, episode.id).playState == .unplayed, "the failed Undo changed nothing")
            }
            #expect(try await a.store.undoSwipeMark(receipt) == .restored)
            #expect(try await Self.state(a, episode.id).playState == .new, "the Undo restores NEW")
            // A relaunch: the next exchange exports what the earlier opening journaled, then pushes and pulls.
            try await a.relaunch()
            for _ in 0..<2 { await a.exchange() }
            #expect(try await Self.state(a, episode.id).playState == .new, "after a relaunch and an exchange")
            await a.engine.requestFullSynchronization()
            _ = await a.engine.forceFullSynchronization()
            #expect(try await Self.state(a, episode.id).playState == .new, "after a Force full synchronization")
            await c.exchange()
            let onC = try #require(try await newest(c))
            #expect(onC.userState.playState == .new, "on the other phone")
        }
    }

    /// B's player plays an episode (41 s, never paused) of a podcast A removes; B listens on while the removed episode is
    /// held; A subscribes to it again. B shows the subscription again at the server's head with fresh statistics (the
    /// held session's listening is the closed generation's), its player not rewound; after a skip that really releases
    /// the selection and the pins, B equals a fresh attachment, and a Force full keeps the reopened played time at 0. In
    /// the second variant A removes the reopened subscription again while the episode is still held.
    @Test(arguments: [false, true]) func activeHeldResubscription(removedAgain: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, b, feedA, ids, _) = try await Concurrency.twoPhones(world)
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            let onB = try await Concurrency.same(ids[0], from: a, on: b)
            let identifier = try #require(try await b.store.episode(id: onB)?.details.identifier)
            let player = StorePlayer(b.store, realTime: ())
            try await player.load(onB); try await player.play(); try await player.listen(41)
            func shown() async throws -> LibraryFeed? { try await b.store.feeds().first { $0.source.hasSuffix("/one.xml") } }
            _ = try await a.store.requestFeedDeletion(feedID: feedA.id)
            await a.exchange(); await b.exchange()
            #expect(try await shown() == nil, "removed from B's lists while its player holds the episode")
            try await player.listen(5)
            let again = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: again.id)
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            let reopened = try await shown()
            #expect(reopened?.subscriptionState == .subscribed, "B shows the subscription again while the old episode is held")
            #expect(reopened?.episodes.count == 5)
            let fresh = try #require(reopened?.episodes.first { $0.details.identifier == identifier })
            #expect(fresh.id != onB, "the reopened episode has a row of its own; the held row stays the closed generation's")
            #expect(fresh.userState.playedDurationMilliseconds == 0, "the reopened subscription's statistics are fresh")
            try await player.listen(5)
            #expect(try await Self.state(b, onB).positionMilliseconds == 51_000, "the player was not rewound")
            if removedAgain {
                let reopenedOnA = try #require(try await a.store.feeds().first { $0.source.hasSuffix("/one.xml") })
                _ = try await a.store.requestFeedDeletion(feedID: reopenedOnA.id)
                await a.exchange(); await b.exchange()
                try await player.listen(5)
                #expect(try await shown() == nil)
            }
            // A skip leaves the episode for good: the selection is released, then the pins.
            player.skipKeepsEpisode = true
            _ = try await player.end(.skipped)
            #expect(try await b.store.playbackSelectionEpisodeID() == nil, "the selection is released")
            await b.engine.releasePins()
            if !removedAgain {
                #expect(try await shown()?.subscriptionState == .subscribed, "the subscription stays once the pins are released")
            }
            try await Concurrency.converge(world, [a, b], "resubscribed")
            if !removedAgain {
                await b.engine.requestFullSynchronization()
                _ = await b.engine.forceFullSynchronization()
                let episode = try #require(try await shown()?.episodes.first { $0.details.identifier == identifier })
                #expect(episode.userState.playedDurationMilliseconds == 0, "a Force full keeps the reopened played time fresh")
            }
        }
    }

    // A podcast subscribed again while a player holds an episode of its removal: the held episode is cut loose from
    // the account at the removal (PROTOCOL §6.8), so the subscription is a fresh one, as on a phone that never held it.

    /// The reopened podcast's feed on `phone` and its episode `identifier`.
    static func reopened(_ phone: ExchangePhone, _ identifier: String) async throws -> (feed: LibraryFeed, episode: LibraryEpisode)? {
        guard let feed = try await phone.store.feeds().first(where: { $0.episodes.contains { $0.details.identifier == identifier } }),
              let episode = feed.episodes.first(where: { $0.details.identifier == identifier }) else { return nil }
        return (feed, episode)
    }

    /// The listening Statistics show for a podcast: its played seconds (marked as played not included).
    static func statisticsSeconds(_ phone: ExchangePhone, feedID: Int64) async throws -> Int64 {
        let input = try await phone.store.statisticsLibrary()
        let statistics = try LibraryStatistics(feeds: input.feeds, units: input.units, includeMarkedAsPlayed: false, now: Date())
        return statistics.feeds.first { $0.feedID == feedID }?.playedSeconds ?? 0
    }

    /// An ordinary (bound) held session: the reopened podcast's Statistics start at 0, and a statistics reset, pending or
    /// accepted, never brings the closed generation's listening back.
    @Test(arguments: [false, true]) func reopenedStatisticsAndReset(accepted: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, b, feedA, ids, _) = try await Concurrency.twoPhones(world)
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            let onB = try await Concurrency.same(ids[0], from: a, on: b)
            let identifier = try #require(try await b.store.episode(id: onB)?.details.identifier)
            let player = StorePlayer(b.store, realTime: ())
            try await player.load(onB); try await player.play(); try await player.listen(41)
            _ = try await a.store.requestFeedDeletion(feedID: feedA.id)
            await a.exchange(); await b.exchange()
            try await player.listen(5)
            let again = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: again.id)
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            let shown = try #require(try await Self.reopened(b, identifier))
            #expect(try await Self.statisticsSeconds(b, feedID: shown.feed.id) == 0, "the reopened podcast's Statistics start at 0")
            try await b.store.resetPlayedDurationStatistics()
            if accepted { await b.exchange() }
            #expect(try await Self.statisticsSeconds(b, feedID: shown.feed.id) == 0, accepted ? "after an accepted reset" : "with a pending reset")
            #expect(try await Self.reopened(b, identifier)?.episode.userState.playedDurationMilliseconds == 0)
            player.skipKeepsEpisode = true
            _ = try await player.end(.skipped)
            await b.engine.releasePins()
            try await Concurrency.converge(world, [a, b], "reopened statistics")
        }
    }

    /// The generations B's recorded session facts name (their targets').
    static func sessionGenerations(_ phone: ExchangePhone) throws -> Set<String> {
        var generations = Set<String>()
        for row in try phone.rows("SELECT CAST(fact AS TEXT) FROM ntp_outbox WHERE type LIKE 'session.%'") {
            guard let text = row[0], let fact = try? ContractJSON.decode(text) else { continue }
            for target in fact["targets"]?.arrayValue ?? [] { if let generation = target["generation"]?.stringValue { generations.insert(generation) } }
        }
        return generations
    }

    /// The session facts `phone` pushed after its request `mark`.
    static func pushedSessionFacts(_ phone: ExchangePhone, since mark: Int) -> [ContractJSON] {
        pushed(phone, since: mark).compactMap { $0["fact"] }.filter { $0["type"]?.stringValue?.hasPrefix("session.") == true }
    }

    /// The generations facts' targets name.
    static func generations(of facts: [ContractJSON]) -> Set<String> {
        Set(facts.flatMap { $0["targets"]?.arrayValue ?? [] }.compactMap { $0["generation"]?.stringValue })
    }

    /// The largest listening contribution the facts carry.
    static func contribution(of facts: [ContractJSON]) -> Int64 {
        facts.compactMap { $0["payload"]?["contribution"]?.integerValue }.max() ?? 0
    }

    /// A session refused as too large and kept on this device, then finalized lazily after a relaunch (the switch away of
    /// the restored player): the finalization is the device's own as the session is, whenever it was made. Its history shows
    /// as the journal says, a full rebuild and a real Force full synchronization keep the new entry and its date, a later
    /// removal covers it and its Undo restores it, a later clear covers it, and nothing of it is sent.
    @Test(arguments: [false, true]) func keptSessionFinalizedAfterRelaunchKeepsHistory(clear: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, _, _, ids, _) = try await Concurrency.twoPhones(world)
            await a.exchange()
            var player = StorePlayer(a.store, realTime: ())
            try await player.load(ids[0])
            await a.store.setServerFactBoundForTesting(400)
            try await player.play(); try await player.listen(10); try await player.pause()
            let item = try #require(try await a.store.serverAttentionItems().first)
            try await a.store.keepRefusedListeningOnThisDevice(item)
            await a.store.setServerFactBoundForTesting(nil)
            if clear { _ = try await a.store.clearPlaybackHistory() }
            await a.exchange()
            try await a.relaunch()
            player = try await StorePlayer.restored(a.store)
            _ = try await player.end(.switched)
            let history = try #require(try await a.store.episode(id: ids[0])?.userState.lastPlayedHistoryMilliseconds, "the switch's history entry")
            #expect(try await a.store.transitionStateForTesting().due.map(\.refused) == [.keptLocal], "the finalization is the device's own")
            #expect(try await a.store.pendingListeningForTesting(ids[0]).history == history, "what projections read")
            let differences = try await ServerChangeSetCaptureTests.rebuildDifferences(a)
            #expect(differences.isEmpty, "\(differences.prefix(3))")
            await a.engine.requestFullSynchronization()
            _ = await a.engine.forceFullSynchronization()
            #expect(try await a.store.episode(id: ids[0])?.userState.lastPlayedHistoryMilliseconds == history, "after a Force full synchronization")
            let receipt = try #require(try await a.store.removeFromPlaybackHistoryWithUndo(ids[0]))
            #expect(try await a.store.pendingListeningForTesting(ids[0]).history == nil, "a removal covers it")
            #expect(try await a.store.undoHistoryRemoval(receipt).status == .restored)
            #expect(try await a.store.pendingListeningForTesting(ids[0]).history == history, "its Undo restores it")
            _ = try await a.store.clearPlaybackHistory()
            #expect(try await a.store.pendingListeningForTesting(ids[0]).history == nil, "a later clear covers it")
            await a.exchange()
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox WHERE type LIKE 'session.%'") == [["0"]], "never sent")
        }
    }

    /// A refused draft chain whose podcast another phone removes (and, `readd`, subscribes to again), with or without A's
    /// player holding one of its episodes: the removal applies here as everywhere. The refused draft ends, the session's
    /// checkpoints redirected behind it are sent under the closed generation in author order, the item goes, nothing of the
    /// old chain reaches the fresh subscription, and both phones equal a fresh attachment.
    @Test(arguments: [(false, false), (false, true), (true, false), (true, true)])
    func aRefusedDraftChainEndsWithItsRemovedPodcast(readd: Bool, held: Bool) async throws {
        try await ExchangeWorld.run(feeds: ["/one.xml": ("One", "one", 3)]) { world in
            let a = try await world.attach("A"), c = try await world.attach("C")
            let feed = try await a.store.insert(ServerOwedReplayRefusedExchangeTests.fetched(world.url("one.xml")))
            let large = try #require(feed.episodes.first { $0.details.identifier == "one-3" }).id
            let small = try #require(feed.episodes.first { $0.details.identifier == "one-1" }).id
            let registration = try #require(try a.rows("SELECT op_id, author_id FROM ntp_registrations WHERE feed_id = \(feed.id)").first)
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(small); try await player.play(); try await player.listen(5); try await player.pause()
            try await a.store.setFavorite(episodeID: large, favorite: true)
            await a.store.setServerFactBoundForTesting(ServerOwedReplayRefusedExchangeTests.smallBound)
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: feed.id)
            try await player.play(); try await player.listen(5); try await player.pause()
            if !held { _ = try await player.end(.switched) }
            let waiting = try a.rows("SELECT kind, state FROM ntp_drafts ORDER BY author_seq")
            #expect(waiting.first == ["favorite.set", "refused_too_large"] && waiting.count >= 2, "\(waiting)")
            #expect(try await a.store.serverAttentionItems().count == 1)
            let redirected = try a.rows("SELECT op_id FROM ntp_drafts WHERE state = 'waiting' ORDER BY author_seq").compactMap { $0[0] }
            let generation = try #require(try a.rows("SELECT generation_id FROM ntp_registrations WHERE op_id = '\(registration[0] ?? "")'").first?.first ?? nil)
            await a.exchange()
            await c.exchange()
            let onC = try #require(try await c.store.feeds().first { $0.source.hasSuffix("one.xml") })
            _ = try await c.store.requestFeedDeletion(feedID: onC.id)
            await c.exchange()
            if readd {
                let again = try await c.store.insert(ServerAgreementTests.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 3))
                try await ServerExchangeAgreementTests.waitForCatalog(c, feedID: again.id)
            }
            await a.exchange()
            #expect(try await a.store.serverAttentionItems().isEmpty, "the item ends with the removal")
            #expect(try a.rows("SELECT count(*) FROM ntp_drafts WHERE registration_op = '\(registration[0] ?? "")'") == [["0"]], "no draft of the old chain is left")
            if held {
                player.skipKeepsEpisode = true
                _ = try await player.end(.skipped)
                await a.engine.releasePins()
            }
            for _ in 0..<2 { await a.exchange() }
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox WHERE receipt IS NULL") == [["0"]], "nothing is stranded")
            // The facts redirected behind it went out on the old author's chain, contiguous, under the closed generation only.
            let old = Self.pushed(a, since: 0).compactMap { $0["fact"] }.filter { $0["author_id"]?.stringValue == registration[1] }
            let sent = Set(old.compactMap { $0["op_id"]?.stringValue })
            #expect(Set(redirected).isSubset(of: sent), "every redirected fact is sent: \(redirected.count) of \(sent.count)")
            let seqs = Set(old.compactMap { $0["author_seq"]?.integerValue }).sorted()
            #expect(seqs == Array(1...Int64(max(1, seqs.count))).prefix(seqs.count).map { $0 }, "contiguous: \(seqs)")
            for fact in old {
                for target in fact["targets"]?.arrayValue ?? [] {
                    if let named = target["generation"]?.stringValue { #expect(named == generation, "only the closed generation") }
                }
            }
            try await Concurrency.converge(world, [a, c], "ended chain \(readd) \(held)")
        }
    }

    /// The same chain, removed on this phone (its feed row goes before the server's commit comes back): the generation still
    /// closes, so the refused draft ends, the item goes and nothing waits; subscribed again here (`readd`), the episode is
    /// fresh, as on a fresh attachment, also after a real Force full synchronization.
    @Test(arguments: [false, true]) func aRefusedDraftChainEndsWithLocalRemoval(readd: Bool) async throws {
        try await ExchangeWorld.run(feeds: ["/one.xml": ("One", "one", 3)]) { world in
            let a = try await world.attach("A")
            let feed = try await a.store.insert(ServerOwedReplayRefusedExchangeTests.fetched(world.url("one.xml")))
            let large = try #require(feed.episodes.first { $0.details.identifier == "one-3" }).id
            let small = try #require(feed.episodes.first { $0.details.identifier == "one-1" }).id
            let registration = try #require(try a.rows("SELECT op_id FROM ntp_registrations WHERE feed_id = \(feed.id)").first?.first ?? nil)
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(small); try await player.play(); try await player.listen(5); try await player.pause()
            try await a.store.setFavorite(episodeID: large, favorite: true)
            await a.store.setServerFactBoundForTesting(ServerOwedReplayRefusedExchangeTests.smallBound)
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: feed.id)
            try await player.play(); try await player.listen(5); try await player.pause()
            _ = try await player.end(.switched)
            #expect(try a.rows("SELECT state FROM ntp_drafts ORDER BY author_seq").first == ["refused_too_large"])
            await a.exchange()
            _ = try await a.store.requestFeedDeletion(feedID: feed.id)
            for _ in 0..<2 { await a.exchange() }
            #expect(try await a.store.serverAttentionItems().isEmpty, "the item ends with the removal")
            #expect(try a.rows("SELECT count(*) FROM ntp_drafts WHERE registration_op = '\(registration)'") == [["0"]], "no draft of the old chain is left")
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox WHERE receipt IS NULL") == [["0"]], "nothing waits")
            if readd {
                let again = try await a.store.insert(ServerAgreementTests.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 3))
                try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: again.id)
                let fresh = try #require(again.episodes.first { $0.details.identifier == "one-1" }).id
                func expectFresh(_ label: String) async throws {
                    let state = try #require(try await a.store.episode(id: fresh)).userState
                    #expect(state.positionMilliseconds == 0 && state.lastPlayedHistoryMilliseconds == nil, "\(label): \(state)")
                }
                try await expectFresh("subscribed again")
                await a.engine.requestFullSynchronization()
                _ = await a.engine.forceFullSynchronization()
                try await expectFresh("after a Force full synchronization")
            }
            try await Concurrency.converge(world, [a], "local removal \(readd)")
        }
    }

    /// Where a refusal (PROTOCOL §6.13) meets a removal (PROTOCOL §6.8): B plays an episode whose session is too large for
    /// its bound, refused once and listed (a later pause does not try it again); A removes the podcast while B's player
    /// holds the episode. At the removal B tries the refused listening once more under the generation it was played in:
    /// if it fits it is sent there, never later; if not, it goes with the detached journal, and so does its Needs attention
    /// item. Releasing the episode leaves nothing pointing at it, and both phones equal a fresh attachment.
    @Test(arguments: [false, true]) func refusedListeningOfAHeldEpisodeEndsWithItsRemoval(fits: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, b, feedA, ids, podcast) = try await Concurrency.twoPhones(world)
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            let onB = try await Concurrency.same(ids[0], from: a, on: b)
            let played = try #require(try b.rows("SELECT live_generation FROM ntp_podcasts WHERE podcast_id = '\(podcast)'").first?.first ?? nil)
            let player = StorePlayer(b.store, realTime: ())
            try await player.load(onB)
            await b.store.setServerFactBoundForTesting(400)
            try await player.play(); try await player.listen(10); try await player.pause()
            try await player.play(); try await player.listen(5); try await player.pause()
            await b.exchange()
            #expect(try await b.engine.logEntries().filter { $0.kind == "too_large" }.count == 1, "refused once, not tried again")
            #expect(try await b.store.serverAttentionItems().count == 1)
            let mark = b.transport.requests.count
            _ = try await a.store.requestFeedDeletion(feedID: feedA.id)
            await a.exchange()
            if fits { await b.store.setServerFactBoundForTesting(nil) }
            await b.exchange()
            #expect(try await b.store.serverAttentionItems().isEmpty, "the item ends with the removal")
            #expect(try b.rows("SELECT count(*) FROM ntp_sessions WHERE episode_id = \(onB)") == [["0"]], "the journal is cut loose")
            #expect(try await b.store.transitionStateForTesting().due.allSatisfy { $0.transition.episodeID != onB })
            await b.store.setServerFactBoundForTesting(nil)
            try await player.listen(5)
            player.skipKeepsEpisode = true
            _ = try await player.end(.skipped)
            await b.engine.releasePins()
            #expect(try await b.store.episode(id: onB) == nil, "released")
            #expect(try await b.store.serverAttentionItems().isEmpty)
            let pushed = Self.pushedSessionFacts(b, since: mark)
            if fits {
                #expect(Self.generations(of: pushed) == [played], "sent under the generation it was played in: \(Self.generations(of: pushed))")
                #expect(Self.contribution(of: pushed) >= 15_000)
            } else {
                #expect(pushed.isEmpty, "nothing of it is sent: \(pushed.count)")
            }
            try await Concurrency.converge(world, [a, b], "refused held")
        }
    }

    /// B's player holds an episode (loaded, paused) of a podcast A removes; A subscribes to it again. B shows the
    /// subscription at the server's head while its player holds the old episode, and keeps it once the selection and the
    /// pins are released; both phones then equal a fresh attachment.
    @Test func resubscribeAgainstServerWhileBStillHoldsRemovedEpisode() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, feedA, ids, _) = try await Concurrency.twoPhones(world)
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            let onB = try await Concurrency.same(ids[0], from: a, on: b)
            let identifier = try #require(try await b.store.episode(id: onB)?.details.identifier)
            let player = StorePlayer(b.store, realTime: ())
            try await player.load(onB)
            _ = try await a.store.requestFeedDeletion(feedID: feedA.id)
            await a.exchange(); await b.exchange()
            #expect(try await Self.reopened(b, identifier) == nil, "removed from B's lists while the episode is held")
            let again = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: again.id)
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            let shown = try #require(try await Self.reopened(b, identifier))
            #expect(shown.feed.subscriptionState == .subscribed && shown.feed.episodes.count == 5, "shown while the old episode is held")
            try await b.store.resetPlaybackPosition(episodeID: onB)
            #expect(try await b.store.playbackSelectionEpisodeID() == nil, "the selection is released")
            await b.engine.releasePins()
            #expect(try await Self.reopened(b, identifier)?.feed.subscriptionState == .subscribed, "kept after the release")
            try await Concurrency.converge(world, [a, b], "resubscribed while held")
        }
    }

    /// The old session's natural end (the held episode of the closed generation) never touches the reopened episode: it
    /// stays unplayed and in the queue A put it in.
    @Test func oldCompletionDoesNotMarkReopenedEpisodePlayed() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, feedA, ids, _) = try await Concurrency.twoPhones(world)
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            let onB = try await Concurrency.same(ids[0], from: a, on: b)
            let identifier = try #require(try await b.store.episode(id: onB)?.details.identifier)
            let player = StorePlayer(b.store, realTime: ())
            try await player.load(onB); try await player.play(); try await player.listen(41)
            _ = try await a.store.requestFeedDeletion(feedID: feedA.id)
            await a.exchange(); await b.exchange()
            let again = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: again.id)
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            let onA = try #require(try await Self.reopened(a, identifier)?.episode)
            _ = try await a.store.enqueue([onA.id])
            await a.exchange(); await b.exchange()
            let fresh = try #require(try await Self.reopened(b, identifier)?.episode)
            #expect(try await b.store.queue().map(\.id).contains(fresh.id), "the reopened episode is queued on B")
            _ = try await player.end(.ended, at: player.duration)
            let after = try #require(try await b.store.episode(id: fresh.id))
            #expect(after.userState.playState != .played, "the old session's end does not mark the reopened episode played")
            #expect(try await b.store.queue().map(\.id).contains(fresh.id), "nor take it out of its queue")
            await b.engine.releasePins()
            try await Concurrency.converge(world, [a, b], "old completion")
        }
    }

    /// B's recorder fails from just after loading, before Play; it listens 41 s, holds the episode through A's removal
    /// (5 s more) and reopening (5 s more), then recording works again. The listening before the removal is exported under
    /// the generation it was played under, never the reopened one (the episode, cut loose at the removal, records nothing
    /// more); the reopened episode's played time stays 0 on both phones and through a Force full. In the second variant A
    /// removes the reopened subscription again while the episode is held.
    @Test(arguments: [false, true]) func unboundHeldResubscription(removedAgain: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, b, feedA, ids, podcast) = try await Concurrency.twoPhones(world)
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            let onB = try await Concurrency.same(ids[0], from: a, on: b)
            let identifier = try #require(try await b.store.episode(id: onB)?.details.identifier)
            let played = try #require(try b.rows("SELECT live_generation FROM ntp_podcasts WHERE podcast_id = '\(podcast)'").first?.first ?? nil)
            let mark = b.transport.requests.count
            let player = StorePlayer(b.store, realTime: ())
            try await player.load(onB)
            await b.store.injectRecorderFailure(after: 0)
            try await player.play(); try await player.listen(41)
            _ = try await a.store.requestFeedDeletion(feedID: feedA.id)
            await a.exchange(); await b.exchange()
            try await player.listen(5)
            let again = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: again.id)
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            try await player.listen(5)
            if removedAgain {
                let reopenedOnA = try #require(try await Self.reopened(a, identifier)?.feed)
                _ = try await a.store.requestFeedDeletion(feedID: reopenedOnA.id)
                await a.exchange(); await b.exchange()
                try await player.listen(5)
            }
            await b.store.injectRecorderFailure(after: nil)
            try await b.store.flushServerPlayback()
            player.skipKeepsEpisode = true
            _ = try await player.end(.skipped)
            // The listening before the removal (journaled while the recorder failed) is exported at the removal under the
            // generation it was played in; the detached episode records nothing after it.
            let pushed = Self.pushedSessionFacts(b, since: mark)
            let generations = try Self.sessionGenerations(b).union(Self.generations(of: pushed))
            #expect(generations == [played], "the session facts name the generation it was played under: \(generations)")
            #expect(Self.contribution(of: pushed) >= 41_000, "the 41 s before the removal are exported")
            await b.engine.releasePins()
            try await Concurrency.converge(world, [a, b], "unbound")
            if !removedAgain {
                for phone in [a, b] {
                    let episode = try #require(try await Self.reopened(phone, identifier)?.episode)
                    #expect(episode.userState.playedDurationMilliseconds == 0, "\(phone.name): the reopened played time stays 0")
                }
                await b.engine.requestFullSynchronization()
                _ = await b.engine.forceFullSynchronization()
                #expect(try await Self.reopened(b, identifier)?.episode.userState.playedDurationMilliseconds == 0, "after a Force full")
            }
        }
    }

    /// A draft session: B subscribes and listens 41 s while the server is offline (its registration pending), then its
    /// registration resolves. A removes and reopens the podcast while B holds the episode (5 s more each time). The
    /// reopened episode's played time and Statistics start at 0, and stay so through the release, a fresh attachment's
    /// comparison and a Force full; in the second variant a statistics reset (pending, then accepted) and 3 s more listening
    /// cannot revive the closed generation's listening either.
    @Test(arguments: [false, true]) func draftHeldResubscription(withReset: Bool) async throws {
        try await ExchangeWorld.run { world in
            let b = try await world.attach("B")
            world.server.stop(keepingData: true)
            let feed = try await b.store.insert(ServerExchangeAgreementTests.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            let onB = try #require(feed.episodes.map(\.id).sorted().first)
            let identifier = try #require(try await b.store.episode(id: onB)?.details.identifier)
            let player = StorePlayer(b.store, realTime: ())
            try await player.load(onB); try await player.play(); try await player.listen(41)
            try await world.server.launch()
            try await ServerExchangeAgreementTests.waitForCatalog(b, feedID: feed.id)
            let a = try await world.attach("A")
            await b.exchange(); await a.exchange()
            let feedA = try #require(try await Self.reopened(a, identifier)?.feed)
            _ = try await a.store.requestFeedDeletion(feedID: feedA.id)
            await a.exchange(); await b.exchange()
            try await player.listen(5)
            let again = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: again.id)
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            let shown = try #require(try await Self.reopened(b, identifier))
            #expect(shown.episode.userState.playedDurationMilliseconds == 0, "the reopened episode starts at 0")
            #expect(try await Self.statisticsSeconds(b, feedID: shown.feed.id) == 0, "and so do its Statistics")
            try await player.listen(5)
            if withReset {
                try await b.store.resetPlayedDurationStatistics()
                #expect(try await Self.reopened(b, identifier)?.episode.userState.playedDurationMilliseconds == 0, "a pending reset")
                await b.exchange()
                #expect(try await Self.reopened(b, identifier)?.episode.userState.playedDurationMilliseconds == 0, "an accepted reset")
                try await player.listen(3)
            }
            player.skipKeepsEpisode = true
            _ = try await player.end(.skipped)
            await b.engine.releasePins()
            try await Concurrency.converge(world, [a, b], "draft held")
            let settled = try #require(try await Self.reopened(b, identifier))
            #expect(settled.episode.userState.playedDurationMilliseconds == 0)
            #expect(try await Self.statisticsSeconds(b, feedID: settled.feed.id) == 0)
            await b.engine.requestFullSynchronization()
            _ = await b.engine.forceFullSynchronization()
            #expect(try await Self.reopened(b, identifier)?.episode.userState.playedDurationMilliseconds == 0, "after a Force full")
        }
    }

    /// A merged source's session: P is created, removed and cleaned up; Q (the same releases) is subscribed and B plays
    /// its episode 41 s; Q's feed moves onto P's address, so the server merges Q into the removed P and B's row becomes P's
    /// (its listening still counts). P is removed with the episode held (5 s more) and subscribed again: the reopened
    /// episode starts at 0 and stays so through the release, the deletion cleanup, a fresh attachment and a Force full.
    @Test func mergedSourceSessionCannotEnterReopenedSurvivor() async throws {
        try await ExchangeWorld.run { world in
            let items = Discovery.items("mrg", 1...3)
            Discovery.serve(world, "/mrg-p.xml", "Merged", items)
            Discovery.serve(world, "/mrg-q.xml", "Merged", items)
            let a = try await world.attach("A")
            let pFeed = try await Discovery.subscribe(a, world.url("mrg-p.xml"))
            let p = try #require(try await a.store.podcastOfFeedForTesting(pFeed.id))
            _ = try await a.store.requestFeedDeletion(feedID: pFeed.id)
            try await Discovery.cleanUp(a.store)
            await a.exchange()
            let qFeed = try await Discovery.subscribe(a, world.url("mrg-q.xml"))
            let q = try #require(try await a.store.podcastOfFeedForTesting(qFeed.id))
            let b = try await world.attach("B")
            let held = try #require(try await Discovery.local(b, guid: "mrg-1"))
            let player = StorePlayer(b.store, realTime: ())
            try await player.load(held.id); try await player.play(); try await player.listen(41)
            func subscription(_ phone: ExchangePhone, _ podcast: String) throws -> ContractJSON? {
                guard let text = try phone.rows("SELECT CAST(value AS TEXT) FROM ntp_records WHERE entity = 'podcast' AND id = '\(podcast)' AND field_group = 'subscription'").first?.first ?? nil else { return nil }
                return try ContractJSON.decode(text)
            }
            world.setResponse("/mrg-q.xml", .init(status: 301, headers: ["Location": world.url("mrg-p.xml")], body: Data()))
            try await Discovery.serverRefresh(a, podcast: q)
            try await Discovery.exchange(until: { try subscription(a, q)?["state"] == "merged" }, [a, b], label: "the podcast merge")
            try await Discovery.exchange(until: { try subscription(b, q)?["state"] == "merged" }, [b], label: "the merge on B")
            #expect(try await b.store.episode(id: held.id)?.userState.playedDurationMilliseconds == 41_000, "the merged listening still counts")
            // The survivor is removed while B holds its episode, then subscribed again.
            let survivor = try #require(try await Discovery.local(a, guid: "mrg-1"))
            let survivorFeed = try #require(try await a.store.feeds().first { $0.episodes.contains { $0.id == survivor.id } })
            _ = try await a.store.requestFeedDeletion(feedID: survivorFeed.id)
            try await Discovery.cleanUp(a.store)
            await a.exchange(); await b.exchange()
            try await Discovery.cleanUp(b.store)
            try await player.listen(5)
            _ = try await Discovery.subscribe(a, world.url("mrg-p.xml"))
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            #expect(try subscription(b, p)?["state"] == "subscribed")
            let reopened = try #require(try await Discovery.local(b, guid: "mrg-1"))
            #expect(reopened.id != held.id, "a row of its own")
            #expect(reopened.userState.playedDurationMilliseconds == 0, "the reopened survivor's episode starts at 0")
            try await player.listen(5)
            player.skipKeepsEpisode = true
            _ = try await player.end(.skipped)
            await b.engine.releasePins()
            try await Discovery.cleanUp(b.store)
            // (A, which made the merge, names the merged episodes by their alias identities: a representation, not a
            // difference a person sees; B is compared.)
            await a.exchange()
            try await Concurrency.converge(world, [b], "merged source")
            #expect(try await Discovery.local(b, guid: "mrg-1")?.userState.playedDurationMilliseconds == 0)
            await b.engine.requestFullSynchronization()
            _ = await b.engine.forceFullSynchronization()
            #expect(try await Discovery.local(b, guid: "mrg-1")?.userState.playedDurationMilliseconds == 0, "after a Force full")
        }
    }

    /// B plays 41 s; A removes and reopens the podcast; B receives both. B shows the reopened podcast's own feed (five
    /// episodes, its queue without the held row) while its player keeps the old row at 41 s through a Force full and a
    /// relaunch. In the second variant B then loads and plays the held episode again (5 s) after the relaunch: the
    /// reopened generation on the server (A, a fresh attachment) still shows no listening. Releasing the selection then
    /// deletes only the retained feed.
    @Test(arguments: [false, true]) func heldFullExportRestartAndRelease(resume: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, b, feedA, ids, _) = try await Concurrency.twoPhones(world)
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            let onB = try await Concurrency.same(ids[0], from: a, on: b)
            let identifier = try #require(try await b.store.episode(id: onB)?.details.identifier)
            var player = StorePlayer(b.store, realTime: ())
            try await player.load(onB); try await player.play(); try await player.listen(41)
            _ = try await a.store.requestFeedDeletion(feedID: feedA.id)
            await a.exchange(); await b.exchange()
            let again = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: again.id)
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            let shown = try #require(try await Self.reopened(b, identifier), "B shows the reopened podcast")
            #expect(shown.feed.episodes.count == 5 && shown.episode.id != onB, "its own feed and rows")
            #expect(!(try await b.store.queue().map(\.id).contains(onB)), "the queue holds no retained row")
            await b.engine.requestFullSynchronization()
            _ = await b.engine.forceFullSynchronization()
            #expect(try await Self.state(b, onB).positionMilliseconds == 41_000, "the old player keeps its position")
            try await b.relaunch()
            player = try await StorePlayer.restored(b.store)
            #expect(try await b.store.playbackSelectionEpisodeID() == onB, "the restored selection still names the old row")
            if resume {
                try await player.load(onB); try await player.play(); try await player.listen(5); try await player.pause()
            }
            for _ in 0..<3 { await a.exchange(); await b.exchange() }
            let fresh = try await world.attach("C")
            for phone in [a, fresh] {
                let episode = try #require(try await Self.reopened(phone, identifier)?.episode)
                #expect(episode.userState.playedDurationMilliseconds == 0, "\(phone.name): no listening in the reopened generation")
            }
            await fresh.close()
            try await b.store.resetPlaybackPosition(episodeID: onB)
            await b.engine.releasePins()
            #expect(try await b.store.episode(id: onB) == nil, "the retained row goes once released")
            #expect(try await Self.reopened(b, identifier)?.feed.subscriptionState == .subscribed, "the reopened podcast stays")
        }
    }

    /// B's old session's facts stay pending (B pushes first, then plays and pauses at 41 s, and only pulls and applies
    /// afterwards) while A removes and reopens the podcast and then resets the reopened episode's position. The reopened
    /// row on B never takes the old position, and playing it records nothing of the old session: A shows 0 after the
    /// exchanges and after its Force full.
    @Test func pendingOldPositionCanBecomeANewGenerationClaim() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, feedA, ids, _) = try await Concurrency.twoPhones(world)
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            let onB = try await Concurrency.same(ids[0], from: a, on: b)
            let identifier = try #require(try await b.store.episode(id: onB)?.details.identifier)
            await b.run([.push])
            let player = StorePlayer(b.store, realTime: ())
            try await player.load(onB); try await player.play(); try await player.listen(41); try await player.pause()
            _ = try await a.store.requestFeedDeletion(feedID: feedA.id)
            await a.exchange()
            await b.run([.pull, .apply])
            let again = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: again.id)
            await a.exchange()
            await b.run([.pull, .apply])
            let reopenedOnB = try #require(try await Self.reopened(b, identifier)?.episode, "B shows the reopened episode")
            #expect(reopenedOnB.userState.positionMilliseconds == 0)
            let onA = try #require(try await Self.reopened(a, identifier)?.episode)
            try await a.store.resetPlaybackPosition(episodeID: onA.id)
            await a.exchange()
            await b.run([.pull, .apply])
            #expect(try await b.store.episode(id: reopenedOnB.id)?.userState.positionMilliseconds == 0, "the old position never reaches the new row")
            let newPlayer = StorePlayer(b.store, realTime: ())
            try await newPlayer.load(reopenedOnB.id); try await newPlayer.play(); try await newPlayer.pause()
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            #expect(try await Self.reopened(a, identifier)?.episode.userState.positionMilliseconds == 0, "A: no old position")
            await a.engine.requestFullSynchronization()
            _ = await a.engine.forceFullSynchronization()
            #expect(try await Self.reopened(a, identifier)?.episode.userState.positionMilliseconds == 0, "A after its Force full")
        }
    }

    /// B, whose player holds the removed episode, subscribes to the podcast again itself: the subscription shows at once
    /// and reaches A, and stays once the player leaves the episode and the pins are released.
    @Test func localReopenWhileOldEpisodeIsHeld() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, feedA, ids, _) = try await Concurrency.twoPhones(world)
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            let onB = try await Concurrency.same(ids[0], from: a, on: b)
            let identifier = try #require(try await b.store.episode(id: onB)?.details.identifier)
            let player = StorePlayer(b.store, realTime: ())
            try await player.load(onB); try await player.play(); try await player.listen(41)
            _ = try await a.store.requestFeedDeletion(feedID: feedA.id)
            await a.exchange(); await b.exchange()
            let held = try await b.store.feedID(forEpisode: onB)
            let subscribed = try await b.store.insert(ServerExchangeAgreementTests.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            #expect(subscribed.id != held, "a podcast of its own: the detached feed never matches")
            #expect(try await b.store.feed(id: subscribed.id) != nil, "shown at once")
            #expect(try await b.store.episode(id: onB)?.userState.positionMilliseconds == 41_000, "the player's episode is untouched")
            for _ in 0..<3 { await b.exchange(); await a.exchange() }
            #expect(try await Self.reopened(b, identifier) != nil, "B shows the subscription")
            #expect(try await Self.reopened(a, identifier) != nil, "and it reaches A")
            player.skipKeepsEpisode = true
            _ = try await player.end(.skipped)
            await b.engine.releasePins()
            for _ in 0..<2 { await b.exchange(); await a.exchange() }
            #expect(try await Self.reopened(b, identifier) != nil, "still there after the release")
            #expect(try await b.store.episode(id: onB) == nil, "the detached episode went with the release")
        }
    }

    // MARK: - A held episode cut loose from sync (PROTOCOL §6.8)

    /// B plays an episode 41 s; A removes its podcast and both exchange: B's player holds the episode, detached.
    static func detachedOnB(_ world: ExchangeWorld) async throws -> (a: ExchangePhone, b: ExchangePhone, episode: Int64, feed: Int64, player: StorePlayer) {
        let (a, b, feedA, ids, _) = try await Concurrency.twoPhones(world)
        for _ in 0..<2 { await a.exchange(); await b.exchange() }
        let onB = try await Concurrency.same(ids[0], from: a, on: b)
        let feedB = try await b.store.feedID(forEpisode: onB)
        _ = try await b.store.enqueue([onB])
        await b.exchange()
        let player = StorePlayer(b.store, realTime: ())
        try await player.load(onB); try await player.play(); try await player.listen(41)
        _ = try await a.store.requestFeedDeletion(feedID: feedA.id)
        await a.exchange(); await b.exchange()
        return (a, b, onB, feedB, player)
    }

    /// The operations `phone` pushed after its request `mark`.
    static func pushed(_ phone: ExchangePhone, since mark: Int) -> [ContractJSON] {
        phone.transport.requests.dropFirst(mark).filter { $0.path == "v1/push" }.flatMap { $0.body?["operations"]?.arrayValue ?? [] }
    }

    /// Nothing of the account names the detached episode or its feed on `phone`.
    static func expectDetached(_ phone: ExchangePhone, episode: Int64, feed: Int64, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(try phone.rows("SELECT count(*) FROM ntp_episodes WHERE local_id = \(episode)") == [["0"]], "no episode mapping", sourceLocation: sourceLocation)
        #expect(try phone.rows("SELECT count(*) FROM ntp_podcasts WHERE feed_id = \(feed)") == [["0"]], "no podcast mapping", sourceLocation: sourceLocation)
        #expect(try phone.rows("SELECT count(*) FROM ntp_sessions WHERE episode_id = \(episode)") == [["0"]], "no session", sourceLocation: sourceLocation)
    }

    /// A removal without a new subscription while B's player holds an episode (41 s in, queued): on B the podcast is gone
    /// from every list (Subscriptions, Episodes, Inbox, the queue, downloads, search, Statistics) while the player plays
    /// on, pauses and seeks from where it was; nothing B does with the episode from then on reaches the server; once the
    /// player leaves it, the episode and its feed are deleted, and both phones equal a fresh attachment.
    @Test func aRemovedPodcastsHeldEpisodePlaysOnCutLooseFromSync() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, onB, feedB, player) = try await Self.detachedOnB(world)
            let mark = b.transport.requests.count
            let title = try #require(try await b.store.episode(id: onB)?.details.title)
            #expect(try await b.store.feeds().isEmpty, "Subscriptions")
            let snapshot = try await b.store.snapshot()
            #expect(snapshot.feeds.isEmpty && snapshot.queue.isEmpty, "downloads and the queue")
            #expect(try await b.store.queue().isEmpty)
            #expect(try await b.store.search(query: title).episodes.isEmpty, "search")
            #expect(try await b.store.statisticsLibrary().feeds.isEmpty, "Statistics")
            #expect(try b.rows("SELECT feed_eligible FROM episode_list_keys WHERE id = \(onB)") == [["0"]], "Episodes and Inbox")
            #expect(try await b.store.feed(id: feedB) == nil)
            #expect(try await b.store.playbackFeed(id: feedB)?.metadata.title == "One", "the player still shows its podcast")
            try Self.expectDetached(b, episode: onB, feed: feedB)
            try await player.listen(5); try await player.pause()
            try await player.seek(to: 20_000)
            try await player.play(); try await player.listen(5); try await player.pause()
            #expect(try await Self.state(b, onB).positionMilliseconds == 25_000, "played, paused and seeked here")
            for _ in 0..<2 { await b.exchange(); await a.exchange() }
            let pushed = Self.pushed(b, since: mark)
            #expect(pushed.isEmpty, "nothing of it reached the server: \(pushed)")
            #expect(try b.rows("SELECT count(*) FROM ntp_outbox") == [["0"]])
            try Self.expectDetached(b, episode: onB, feed: feedB)
            _ = try await player.end(.skipped)
            await b.engine.releasePins()
            #expect(try await b.store.episode(id: onB) == nil, "deleted once the player left it")
            #expect(try await b.store.playbackFeed(id: feedB) == nil, "with its feed")
            try await Concurrency.converge(world, [a, b], "detached")
        }
    }

    /// After a relaunch the restored player still holds the detached episode; loading it again and listening 5 s registers
    /// nothing and records nothing: no push carries anything, and the server (A, a fresh attachment) still has no podcast
    /// and no listening.
    @Test func aDetachedEpisodeResumedAfterARelaunchReachesNothing() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, onB, feedB, _) = try await Self.detachedOnB(world)
            try await b.relaunch()
            let player = try await StorePlayer.restored(b.store)
            #expect(try await b.store.playbackSelectionEpisodeID() == onB, "the restored player holds it")
            let mark = b.transport.requests.count
            try await player.load(onB); try await player.play(); try await player.listen(5); try await player.pause()
            #expect(try await Self.state(b, onB).positionMilliseconds == 46_000, "resumed where it was")
            #expect(try b.rows("SELECT count(*) FROM ntp_registrations WHERE feed_id = \(feedB)") == [["0"]], "nothing registered")
            try Self.expectDetached(b, episode: onB, feed: feedB)
            for _ in 0..<3 { await b.exchange(); await a.exchange() }
            let pushed = Self.pushed(b, since: mark)
            #expect(pushed.isEmpty, "nothing reached the server: \(pushed)")
            let fresh = try await world.attach("fresh")
            for phone in [a, fresh] {
                #expect(try await phone.store.feeds().isEmpty, "\(phone.name): the podcast stays removed")
                #expect(try await phone.store.statisticsLibrary().units.isEmpty, "\(phone.name): no listening")
            }
            await fresh.close()
            _ = try await player.end(.skipped)
            await b.engine.releasePins()
            #expect(try await b.store.episode(id: onB) == nil)
            try await Concurrency.converge(world, [a, b], "relaunched")
        }
    }

    /// A Force full synchronization while the player holds a detached episode: the podcast stays removed and out of every
    /// list, the episode stays detached at its position, and listening on reaches nothing.
    @Test func aForceFullKeepsADetachedEpisodeDetached() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, onB, feedB, player) = try await Self.detachedOnB(world)
            await b.engine.requestFullSynchronization()
            _ = await b.engine.forceFullSynchronization()
            #expect(try await b.store.feeds().isEmpty, "still removed")
            #expect(try await Self.state(b, onB).positionMilliseconds == 41_000, "the player keeps its position")
            #expect(try await b.store.playbackFeed(id: feedB) != nil)
            try Self.expectDetached(b, episode: onB, feed: feedB)
            let mark = b.transport.requests.count
            try await player.listen(5); try await player.pause()
            for _ in 0..<2 { await b.exchange(); await a.exchange() }
            let pushed = Self.pushed(b, since: mark)
            #expect(pushed.isEmpty, "nothing reached the server: \(pushed)")
            try Self.expectDetached(b, episode: onB, feed: feedB)
            _ = try await player.end(.skipped)
            await b.engine.releasePins()
            #expect(try await b.store.episode(id: onB) == nil)
            try await Concurrency.converge(world, [a, b], "force full")
        }
    }

    /// An Android database export while the player holds a detached episode (relaunched, listened 5 s more, exchanged)
    /// holds neither the podcast nor the episode, on B or on A.
    @Test func anAndroidExportWhileDetachedHoldsNeitherThePodcastNorTheEpisode() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, onB, _, _) = try await Self.detachedOnB(world)
            try await b.relaunch()
            let player = try await StorePlayer.restored(b.store)
            try await player.load(onB); try await player.play(); try await player.listen(5); try await player.pause()
            for _ in 0..<3 { await b.exchange(); await a.exchange() }
            let title = try #require(try await b.store.episode(id: onB)?.details.title)
            for phone in [b, a] {
                let file = world.root.appendingPathComponent("\(phone.name)-export.db")
                try await AndroidDatabaseBackup.data(library: phone.store, speeds: .init(), credentials: { _ in nil }).write(to: file)
                #expect(try RawLibrary.rows(file, "SELECT count(*) FROM Feeds") == [["0"]], "\(phone.name): no podcast")
                #expect(try RawLibrary.rows(file, "SELECT count(*) FROM FeedItems") == [["0"]], "\(phone.name): no episode")
                #expect(try RawLibrary.rows(file, "SELECT count(*) FROM FeedItems WHERE title = '\(title)'") == [["0"]])
                #expect(try RawLibrary.rows(file, "SELECT count(*) FROM Queue") == [["0"]])
            }
        }
    }

    /// B listens 41 s without pausing (the journal holds it: the minute's export is not due yet) and A removes the podcast.
    /// The 41 s are exported at the removal, under the generation they were played in; the 5 s after it are not.
    @Test func normalUnpausedTailIsNotLostAtDetach() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, feedA, ids, podcast) = try await Concurrency.twoPhones(world)
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            let onB = try await Concurrency.same(ids[0], from: a, on: b)
            let played = try #require(try b.rows("SELECT live_generation FROM ntp_podcasts WHERE podcast_id = '\(podcast)'").first?.first ?? nil)
            let mark = b.transport.requests.count
            let player = StorePlayer(b.store, realTime: ())
            try await player.load(onB); try await player.play(); try await player.listen(41)
            _ = try await a.store.requestFeedDeletion(feedID: feedA.id)
            await a.exchange(); await b.exchange()
            try await player.listen(5); try await player.pause()
            for _ in 0..<2 { await b.exchange(); await a.exchange() }
            let facts = Self.pushedSessionFacts(b, since: mark)
            #expect(Self.contribution(of: facts) >= 41_000, "the listening before the removal reached the server: \(Self.contribution(of: facts))")
            #expect(Self.contribution(of: facts) < 46_000, "the listening after it did not")
            #expect(Self.generations(of: facts) == [played], "under the generation it was played in")
            #expect(try b.rows("SELECT count(*) FROM ntp_outbox") == [["0"]])
            try Self.expectDetached(b, episode: onB, feed: try await b.store.feedID(forEpisode: onB))
        }
    }

    /// B's facts about episode X stay pending (B pushes first, then plays X to 41 s and pauses, and only pulls and applies
    /// afterwards) while A removes and subscribes again to the podcast; B leaves X (`held`: for another episode of it,
    /// which the removal detaches; else the player stops). The re-added X shows 0 on B, also after A resets it, and
    /// playing it records no old position under the new generation: A shows 0, also after its Force full.
    @Test(arguments: [false, true]) func anotherEpisodesOldOverlayCannotBecomeNewGenerationPosition(held: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, b, feedA, ids, _) = try await Concurrency.twoPhones(world)
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            let x = try await Concurrency.same(ids[0], from: a, on: b), y = try await Concurrency.same(ids[1], from: a, on: b)
            let identifier = try #require(try await b.store.episode(id: x)?.details.identifier)
            await b.run([.push])
            let player = StorePlayer(b.store, realTime: ())
            try await player.load(x); try await player.play(); try await player.listen(41); try await player.pause()
            if held {
                try await player.load(y); try await player.play(); try await player.listen(5); try await player.pause()
            } else {
                _ = try await player.end(.skipped)
            }
            _ = try await a.store.requestFeedDeletion(feedID: feedA.id)
            await a.exchange()
            await b.run([.pull, .apply])
            let again = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: again.id)
            await a.exchange()
            await b.run([.pull, .apply])
            let reopened = try #require(try await Self.reopened(b, identifier)?.episode, "B shows the re-added X")
            #expect(reopened.userState.positionMilliseconds == 0, "the re-added X starts at 0")
            let onA = try #require(try await Self.reopened(a, identifier)?.episode)
            try await a.store.resetPlaybackPosition(episodeID: onA.id)
            await a.exchange()
            await b.run([.pull, .apply])
            #expect(try await b.store.episode(id: reopened.id)?.userState.positionMilliseconds == 0, "and stays 0 after A's reset")
            let newPlayer = StorePlayer(b.store, realTime: ())
            try await newPlayer.load(reopened.id); try await newPlayer.play(); try await newPlayer.pause()
            for _ in 0..<3 { await a.exchange(); await b.exchange() }
            #expect(try await b.store.serverUnsentChanges() == 0)
            #expect(try await Self.reopened(a, identifier)?.episode.userState.positionMilliseconds == 0, "A: no old position")
            await a.engine.requestFullSynchronization()
            _ = await a.engine.forceFullSynchronization()
            #expect(try await Self.reopened(a, identifier)?.episode.userState.positionMilliseconds == 0, "A after its Force full")
        }
    }

    /// Two live podcasts P and Q with the same releases; B plays Q's episode 41 s and exchanges. Q's feed moves onto P's
    /// address, so the server merges Q into P while B's player still holds Q's row: no generation closed, so the session
    /// keeps syncing. B listens 5 s more: A and a fresh attachment show 46 s.
    @Test func aMergeOfTwoLivePodcastsKeepsRecordingTheHeldSourceSession() async throws {
        try await ExchangeWorld.run { world in
            let items = Discovery.items("mlv", 1...3)
            Discovery.serve(world, "/mlv-p.xml", "Merged live", items)
            Discovery.serve(world, "/mlv-q.xml", "Merged live", items)
            let a = try await world.attach("A")
            _ = try await Discovery.subscribe(a, world.url("mlv-p.xml"))
            let qFeed = try await Discovery.subscribe(a, world.url("mlv-q.xml"))
            let q = try #require(try await a.store.podcastOfFeedForTesting(qFeed.id))
            let b = try await world.attach("B")
            let qOnB = try await Concurrency.feed(of: q, on: b)
            let held = try #require(try await b.store.feed(id: qOnB)?.episodes.first { $0.details.identifier == "mlv-1" })
            let player = StorePlayer(b.store, realTime: ())
            try await player.load(held.id); try await player.play(); try await player.listen(41); try await player.pause()
            await b.exchange()
            func subscription(_ phone: ExchangePhone) throws -> ContractJSON? {
                guard let text = try phone.rows("SELECT CAST(value AS TEXT) FROM ntp_records WHERE entity = 'podcast' AND id = '\(q)' AND field_group = 'subscription'").first?.first ?? nil else { return nil }
                return try ContractJSON.decode(text)
            }
            world.setResponse("/mlv-q.xml", .init(status: 301, headers: ["Location": world.url("mlv-p.xml")], body: Data()))
            try await Discovery.serverRefresh(a, podcast: q)
            try await Discovery.exchange(until: { try subscription(a)?["state"] == "merged" }, [a, b], label: "the podcast merge")
            try await Discovery.exchange(until: { try subscription(b)?["state"] == "merged" }, [b], label: "the merge on B")
            #expect(try await b.store.episode(id: held.id) != nil, "the player still holds the row")
            try await player.play(); try await player.listen(5); try await player.pause()
            for _ in 0..<2 { await b.exchange(); await a.exchange() }
            let fresh = try await world.attach("fresh")
            for phone in [a, fresh] {
                let episode = try #require(try await Discovery.local(phone, guid: "mlv-1"))
                #expect(episode.userState.playedDurationMilliseconds == 46_000, "\(phone.name): the listening after the merge is recorded")
            }
            await fresh.close()
        }
    }

    /// Keep at logout ends the player's hold of a detached episode: the conversion lets the saved selection and session
    /// go, and the standalone library's cleanup deletes the episode and its feed.
    @Test func keepAtLogoutDoesNotPreserveTheDetachedEpisode() async throws {
        try await ExchangeWorld.run { world in
            let (_, b, onB, feedB, player) = try await Self.detachedOnB(world)
            try await player.pause()
            await b.engine.close()
            try await b.store.close()
            let database = try LibrarySQLite(url: b.location.database)
            try database.transaction { try LibraryKeep.convert(database, operation: ContractIdentity.randomUUID()) }
            try database.close()
            let kept = try FeedLibraryStore(url: b.location.database)
            _ = try await kept.finishPinnedFeedRemovals()
            #expect(try await kept.playbackSelectionEpisodeID() == nil, "the saved selection went")
            #expect(try await kept.episode(id: onB) == nil, "the detached episode went")
            #expect(try await kept.playbackFeed(id: feedB) == nil, "with its feed")
            try await kept.close()
        }
    }

    /// Leaving the library (a sign-out, an account or library switch) ends the player's hold of a detached episode: its
    /// rows go, nothing is pushed, and B's other subscription is unchanged.
    @Test func aLibrarySwitchReleasesTheDetachedEpisode() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, onB, feedB, player) = try await Self.detachedOnB(world)
            let other = try await b.store.insert(ServerExchangeAgreementTests.fetched(world.url("two.xml"), title: "Two", prefix: "two", count: 3))
            try await ServerExchangeAgreementTests.waitForCatalog(b, feedID: other.id)
            try await player.pause()
            for _ in 0..<2 { await b.exchange(); await a.exchange() }
            let mark = b.transport.requests.count
            #expect(try await b.store.releaseDetachedEpisodes())
            #expect(try await b.store.playbackSelectionEpisodeID() == nil)
            #expect(try await b.store.episode(id: onB) == nil, "the detached episode went")
            #expect(try await b.store.playbackFeed(id: feedB) == nil, "with its feed")
            #expect(try await b.store.feed(id: other.id)?.episodes.count == 3, "the other subscription is unchanged")
            for _ in 0..<2 { await b.exchange(); await a.exchange() }
            #expect(Self.pushed(b, since: mark).isEmpty, "nothing recorded")
            try await Concurrency.converge(world, [a, b], "switch")
        }
    }

    /// 5. Two phones offline for a day each listen to the same episode; once both reconnect and are paused, the
    /// position is the one from the device where play was pressed last, and statistics count both. In both orders.
    @Test(arguments: [true, false]) func scenario5TwoOfflinePhonesListenToTheSameEpisode(aFirst: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let onC = try await Concurrency.same(ids[0], from: a, on: c)
            let playerA = StorePlayer(a.store, realTime: ()), playerC = StorePlayer(c.store, realTime: ())
            try await playerA.load(ids[0]); try await playerA.play(); try await playerA.listen(600, every: 60); try await playerA.pause()
            try await playerC.load(onC); try await playerC.play(); try await playerC.listen(300, every: 60); try await playerC.pause()
            if aFirst { await a.exchange(); await c.exchange(); await a.exchange() } else { await c.exchange(); await a.exchange(); await c.exchange() }
            // The paused players adopt where play was pressed last (C's): A's session is sealed there.
            #expect(try await playerA.adopt() == 300_000)
            #expect(try await playerC.adopt() == nil, "C's own claim owns the position")
            try await Concurrency.converge(world, [a, c], "scenario 5")
            for (phone, id) in [(a, ids[0]), (c, onC)] {
                let state = try await Self.state(phone, id)
                #expect(state.positionMilliseconds == 300_000, "\(phone.name): where play was pressed last")
                #expect(state.playedDurationMilliseconds == 900_000, "\(phone.name): both sessions count")
            }
        }
    }

    /// 5a. A starts Monday and pauses with the app open; B plays to 60% Tuesday; A, still offline, resumes Wednesday to
    /// 30%: every device resumes at A's 30%, and statistics count A's one session and B's one session (PROTOCOL §8.1:
    /// the resume is a claim).
    @Test func scenario5aWherePlayWasPressedLast() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, ids, _) = try await Concurrency.twoPhones(world)
            let onB = try await Concurrency.same(ids[0], from: a, on: b)
            let playerA = StorePlayer(a.store, realTime: ()), playerB = StorePlayer(b.store, realTime: ())
            playerA.duration = 1_000_000; playerB.duration = 1_000_000
            try await playerA.load(ids[0]); try await playerA.play(); try await playerA.listen(100, every: 50); try await playerA.pause()
            try await playerB.load(onB); try await playerB.play(); try await playerB.listen(600, every: 60); try await playerB.pause()
            try await playerA.play(); try await playerA.listen(200, every: 50); try await playerA.pause()
            await b.exchange(); await a.exchange(); await b.exchange()
            #expect(try await playerB.adopt() == 300_000, "B adopts A's resumed listening")
            #expect(try await playerA.adopt() == nil)
            try await Concurrency.converge(world, [a, b], "scenario 5a")
            for (phone, id) in [(a, ids[0]), (b, onB)] {
                let state = try await Self.state(phone, id)
                #expect(state.positionMilliseconds == 300_000, "\(phone.name): where play was pressed last")
                #expect(state.playedDurationMilliseconds == 900_000, "\(phone.name): A's 300 s and B's 600 s")
            }
        }
    }

    /// A start whose recording failed stays owed while another phone's later listening arrives: recorded at last, it
    /// depends only on what its Play observed, so the position stays where play was pressed last (B's), and both
    /// sessions count (PROTOCOL §8.1).
    @Test func anOwedOlderStartMustNotAcquireALaterRemoteClaimAsItsDependency() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, ids, _) = try await Concurrency.twoPhones(world)
            let onB = try await Concurrency.same(ids[0], from: a, on: b)
            let playerA = StorePlayer(a.store, realTime: ()), playerB = StorePlayer(b.store, realTime: ())
            try await playerA.load(ids[0])
            await a.store.injectRecorderFailure(after: 1)
            try await playerA.play(); try await playerA.listen(100, every: 50); try await playerA.pause()
            try await playerB.load(onB); try await playerB.play(); try await playerB.listen(300, every: 60); try await playerB.pause()
            await b.exchange()
            await a.exchange() // A pulls B while its start is still owed
            #expect(try await a.store.serverExportOwedForTesting(), "A's start is still owed")
            await a.store.injectRecorderFailure(after: nil)
            try await a.store.flushServerPlayback()
            await a.exchange(); await b.exchange()
            #expect(try await playerA.adopt() == 300_000, "A adopts where play was pressed last")
            #expect(try await playerB.adopt() == nil)
            try await Concurrency.converge(world, [a, b], "owed older start")
            for (phone, id) in [(a, ids[0]), (b, onB)] {
                let state = try await Self.state(phone, id)
                #expect(state.positionMilliseconds == 300_000, "\(phone.name): where play was pressed last")
                #expect(state.playedDurationMilliseconds == 400_000, "\(phone.name): both sessions count")
            }
        }
    }

    /// 6. An old session elsewhere keeps sending checkpoints; this phone's newer listening is never rewound.
    @Test func scenario6AnOldSessionNeverRewindsNewerListening() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            var old = RemoteSession(store: c.store, episode: try await Concurrency.same(ids[0], from: a, on: c))
            try await old.start(at: 0)
            try await old.checkpoint(position: 60_000, contribution: 60_000)
            await c.exchange()
            await a.exchange()
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(ids[0]); try await player.play(); try await player.listen(300, every: 60); try await player.pause()
            await a.exchange()
            try await old.checkpoint(position: 120_000, contribution: 120_000)
            await c.exchange()
            await a.exchange()
            #expect(try await player.adopt() == nil, "the old session takes nothing back")
            try await Concurrency.converge(world, [a, c], "scenario 6")
            #expect(try await Self.state(a, ids[0]).positionMilliseconds == 360_000)
        }
    }

    /// 7. Paused 10 s from the end on A, replayed from the start on C; later A, offline, switches to another episode: its
    /// end reports a completion under a claim C took over, so the episode is not marked played.
    @Test func scenario7AStaleCompletionDoesNotMarkPlayed() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let onC = try await Concurrency.same(ids[0], from: a, on: c)
            let playerA = StorePlayer(a.store, realTime: ())
            try await playerA.load(ids[0], at: 560_000); try await playerA.play(); try await playerA.listen(30, every: 10); try await playerA.pause()
            await a.exchange(); await c.exchange()
            let playerC = StorePlayer(c.store, realTime: ())
            try await playerC.load(onC, at: 0); try await playerC.play(); try await playerC.listen(30, every: 10); try await playerC.pause()
            await c.exchange()
            try await playerA.load(ids[1])
            #expect(try await Self.state(a, ids[0]).playState == .played, "A's own decision shows while it is pending")
            await a.exchange()
            try await Concurrency.converge(world, [a, c], "scenario 7")
            let state = try await Self.state(a, ids[0])
            #expect(state.playState != .played)
            #expect(state.positionMilliseconds == 30_000)
            #expect(try await a.view().queue.contains(try #require(try await a.store.wireEpisodeForTesting(ids[0]))), "still queued")
        }
    }

    /// 8a. A pauses at 100 s; B continues to 300 s; A adopts 300 s and the person resumes on A to 450 s: every device
    /// resumes at 450 s, and statistics count A's 0→100, B's 100→300 and A's 300→450 only (the jump is not listening).
    @Test func scenario8aAdoptionThenResume() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, ids, _) = try await Concurrency.twoPhones(world)
            let onB = try await Concurrency.same(ids[0], from: a, on: b)
            let playerA = StorePlayer(a.store, realTime: ())
            try await playerA.load(ids[0]); try await playerA.play(); try await playerA.listen(100, every: 50); try await playerA.pause()
            await a.exchange(); await b.exchange()
            let playerB = StorePlayer(b.store, realTime: ())
            try await playerB.load(onB); try await playerB.play(); try await playerB.listen(200, every: 50); try await playerB.pause()
            await b.exchange(); await a.exchange()
            let before = try await Self.state(a, ids[0])
            #expect(before.playedDurationMilliseconds == 300_000, "B's listening shows on A's paused player")
            #expect(try await playerA.adopt() == 300_000)
            let adopted = try await Self.state(a, ids[0])
            #expect(adopted.positionMilliseconds == 300_000 && adopted.playedDurationMilliseconds == 300_000, "the jump adds nothing")
            #expect(adopted.lastPlayedHistoryMilliseconds == before.lastPlayedHistoryMilliseconds, "nor a history time")
            try await playerA.play(); try await playerA.listen(150, every: 50); try await playerA.pause()
            await a.exchange(); await b.exchange()
            #expect(try await playerB.adopt() == 450_000)
            try await Concurrency.converge(world, [a, b], "scenario 8a")
            for (phone, id) in [(a, ids[0]), (b, onB)] {
                let state = try await Self.state(phone, id)
                #expect(state.positionMilliseconds == 450_000 && state.playedDurationMilliseconds == 450_000, "\(phone.name)")
            }
        }
    }

    /// 8b, 31 (second part). B takes over from A's paused session before A's lazy finalization in the deterministic
    /// order, without observing it; A's finalization reaches the server first or second. With no other played mark the
    /// episode is unplayed at B's position and queued in both cases.
    @Test(arguments: [true, false]) func scenario8bATakeoverBeforeALazyFinalization(finalizationFirst: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, ids, _) = try await Concurrency.twoPhones(world)
            let onB = try await Concurrency.same(ids[0], from: a, on: b)
            var playerA = StorePlayer(a.store, realTime: ())
            try await playerA.load(ids[0], at: 560_000); try await playerA.play(); try await playerA.listen(30, every: 10); try await playerA.pause()
            await a.exchange(); await b.exchange()
            // A's app is closed and opened again: its player is restored paused, the session finalizable.
            try await a.relaunch()
            playerA = try await StorePlayer.restored(a.store)
            let playerB = StorePlayer(b.store, realTime: ())
            try await playerB.load(onB, at: 100_000); try await playerB.play(); try await playerB.listen(10, every: 10); try await playerB.pause()
            try await playerA.load(ids[1]) // the switch finalizes, completed (A's position is within the threshold)
            if finalizationFirst { await a.exchange(); await b.exchange() } else { await b.exchange(); await a.exchange() }
            try await Concurrency.converge(world, [a, b], "scenario 8b")
            let state = try await Self.state(a, ids[0])
            #expect(state.playState != .played, "the takeover ordered before it suppresses the completion")
            #expect(state.positionMilliseconds == 110_000)
            #expect(try await a.view().queue.contains(try #require(try await a.store.wireEpisodeForTesting(ids[0]))))
        }
    }

    /// 8c. Two offline phones each reset statistics after listening: neither phone's listening before its own reset is
    /// counted; listening after it is.
    @Test func scenario8cTwoOfflineResetsCountNothingBeforeThem() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let onC = try await Concurrency.same(ids[0], from: a, on: c)
            let playerA = StorePlayer(a.store, realTime: ()), playerC = StorePlayer(c.store, realTime: ())
            try await playerA.load(ids[0]); try await playerA.play(); try await playerA.listen(100, every: 50); try await playerA.pause()
            try await playerC.load(onC); try await playerC.play(); try await playerC.listen(200, every: 50); try await playerC.pause()
            try await a.store.resetPlayedDurationStatistics()
            try await c.store.resetPlayedDurationStatistics()
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 0)
            await a.exchange(); await c.exchange()
            #expect(try await Self.state(c, onC).playedDurationMilliseconds == 0, "A's listening was covered by A's own reset")
            try await playerC.play(); try await playerC.listen(20, every: 10); try await playerC.pause()
            #expect(try await Self.state(c, onC).playedDurationMilliseconds == 20_000, "listening after the resets counts")
            await c.exchange(); await a.exchange()
            _ = try await playerA.adopt()
            try await Concurrency.converge(world, [a, c], "scenario 8c")
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 20_000)
        }
    }

    /// 8d. Starting at 100 s, playing to 150 s, rewinding to 50 s while playing, playing to 80 s and switching episodes
    /// counts 50 s, as Android 3.12.1 does (PROTOCOL §8.8: the contribution freezes below the session's start), here and on the
    /// server.
    @Test func scenario8dARewindBelowTheStartThenASwitch() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(ids[0], at: 100_000); try await player.play(); try await player.listen(50, every: 10)
            try await player.seek(to: 50_000)
            try await player.listen(30, every: 10)
            try await player.load(ids[1]) // the switch
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 50_000)
            await a.exchange()
            try await Concurrency.converge(world, [a, c], "scenario 8d")
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 50_000)
            #expect(try await Self.state(c, try await Concurrency.same(ids[0], from: a, on: c)).playedDurationMilliseconds == 50_000)
        }
    }

    /// 31 (first part). Finished normally, the completion is seen everywhere; replaying without marking unplayed keeps
    /// it PLAYED (a new session that follows a completion does not undo it).
    @Test func scenario31ReplayingAPlayedEpisodeKeepsItPlayed() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let onC = try await Concurrency.same(ids[0], from: a, on: c)
            let playerA = StorePlayer(a.store, realTime: ())
            try await playerA.load(ids[0], at: 590_000); try await playerA.play(); try await playerA.listen(10, every: 10)
            #expect(try await playerA.end(.ended)?.markedPlayed == true)
            await a.exchange(); await c.exchange()
            #expect(try await Self.state(c, onC).playState == .played)
            let playerC = StorePlayer(c.store, realTime: ())
            try await playerC.load(onC); try await playerC.play(); try await playerC.listen(30, every: 10); try await playerC.pause()
            await c.exchange(); await a.exchange()
            try await Concurrency.converge(world, [a, c], "scenario 31")
            let state = try await Self.state(a, ids[0])
            #expect(state.playState == .played && state.positionMilliseconds == 30_000)
        }
    }

    /// 31 (third part). An explicit position reset elsewhere, ordered before A's lazy completion, suppresses it.
    @Test func scenario31ARemoteResetBeforeALazyCompletionSuppressesIt() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            var playerA = StorePlayer(a.store, realTime: ())
            try await playerA.load(ids[0], at: 560_000); try await playerA.play(); try await playerA.listen(30, every: 10); try await playerA.pause()
            await a.exchange(); await c.exchange()
            try await a.relaunch()
            playerA = try await StorePlayer.restored(a.store)
            try await c.store.resetPlaybackPosition(episodeID: try await Concurrency.same(ids[0], from: a, on: c))
            await c.exchange()
            // A's finalization is decided after the reset (A has not seen it): the reset is ordered before it.
            try await playerA.load(ids[1])
            await a.exchange()
            try await Concurrency.converge(world, [a, c], "scenario 31 reset")
            let state = try await Self.state(a, ids[0])
            #expect(state.playState == .unplayed && state.positionMilliseconds == 0)
            #expect(try await a.view().queue.contains(try #require(try await a.store.wireEpisodeForTesting(ids[0]))),
                    "the suppressed completion did not take it out of the queue")
        }
    }

    /// 36. Reset at 20 s, rewind to 10 s, reset again, then advance to 15 s: 5 s count, as the server folds it.
    @Test func scenario36ResetsAndARewind() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(ids[0]); try await player.play(); try await player.listen(20, every: 10); try await player.pause()
            try await a.store.resetPlayedDurationStatistics()
            try await player.seek(to: 10_000)
            try await player.play(); try await player.pause()
            try await a.store.resetPlayedDurationStatistics()
            try await player.play(); try await player.listen(5); try await player.pause()
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 5_000)
            await a.exchange()
            try await Concurrency.converge(world, [a, c], "scenario 36")
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 5_000)
        }
    }

    ///: reset at 20 s, advance to 25 s, rewind to 15 s: nothing counts (`max(0, 15 − 20)`), as the server
    /// computes; Android's rebased baseline would show 5 s.
    @Test func aResetThenARewindBelowItCountsNothing() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(ids[0]); try await player.play(); try await player.listen(20, every: 10)
            try await a.store.resetPlayedDurationStatistics()
            try await player.listen(5)
            try await player.seek(to: 15_000)
            try await player.listen(0); try await player.pause()
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 0)
            await a.exchange()
            try await Concurrency.converge(world, [a, c], "reset and rewind")
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 0)
        }
    }

    /// 37. Listen 0→100 s, restart the player, rewind to 50 s and save: the total stays 100 s. Pause near the end,
    /// relaunch and start another episode: the lazy finalization completes once.
    @Test func scenario37ARestartedPlayerAndALazyCompletion() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            var player = StorePlayer(a.store, realTime: ())
            try await player.load(ids[0]); try await player.play(); try await player.listen(100, every: 50); try await player.pause()
            try await player.load(ids[0], at: 50_000); try await player.play(); try await player.pause()
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 100_000, "a rewind below the new baseline adds nothing")
            try await player.load(ids[0], at: 575_000); try await player.play(); try await player.listen(10, every: 10); try await player.pause()
            await a.exchange()
            try await a.relaunch()
            player = try await StorePlayer.restored(a.store)
            try await player.load(ids[1])
            await a.exchange()
            try await Concurrency.converge(world, [a, c], "scenario 37")
            let state = try await Self.state(a, ids[0])
            #expect(state.playState == .played && state.positionMilliseconds == 0)
            #expect(state.playedDurationMilliseconds == 100_000 + 10_000)
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox") == [["0"]], "the finalization was sent once, and retired")
        }
    }

    /// 41. A remote unsubscribe while this phone plays: playing continues from the pinned episode, the podcast leaves
    /// every list at once, the remaining listening is recorded (the server does not apply it, PROTOCOL §7.2), and the podcast's
    /// rows go when the player leaves the episode.
    @Test func scenario41ARemoteUnsubscribeWhilePlaying() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, feed, ids, podcast) = try await Concurrency.twoPhones(world)
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(ids[0]); try await player.play(); try await player.listen(60, every: 30)
            await a.exchange()
            #expect(try await c.store.requestFeedDeletion(feedID: try await Concurrency.feed(of: podcast, on: c)))
            await c.exchange()
            a.playing.value = true
            await a.run([.pull, .apply])
            #expect(try await a.store.feeds().contains { $0.id == feed.id } == false, "shared state hides at once")
            try await player.listen(60, every: 30); try await player.pause()
            #expect(try await a.store.episode(id: ids[0]) != nil, "the player keeps its episode")
            a.playing.value = false
            await a.exchange()
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox") == [["0"]], "the later listening was sent, and retired")
            try await player.end(.skipped) // the player leaves the episode
            await a.exchange()
            #expect(try await a.store.episode(id: ids[0]) == nil, "the podcast's rows went once the player left")
            #expect(try await a.store.feeds().isEmpty)
            try await Concurrency.converge(world, [a, c], "scenario 41")
        }
    }

    /// 43. A exits paused at 100 s; B reaches 300 s. A relaunched without pulling first, and separately after pulling
    /// B: the passive restore records nothing; after sync the shared position is still 300 s; A's deliberate resume
    /// adopts 300 s and then advances it.
    @Test(arguments: [true, false]) func scenario43ARelaunchedPausedPlayer(pullFirst: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, ids, _) = try await Concurrency.twoPhones(world)
            let onB = try await Concurrency.same(ids[0], from: a, on: b)
            var playerA = StorePlayer(a.store, realTime: ())
            try await playerA.load(ids[0]); try await playerA.play(); try await playerA.listen(100, every: 50); try await playerA.pause()
            await a.exchange(); await b.exchange()
            let playerB = StorePlayer(b.store, realTime: ())
            try await playerB.load(onB); try await playerB.play(); try await playerB.listen(200, every: 50); try await playerB.pause()
            await b.exchange()
            if pullFirst { await a.exchange() }
            try await a.relaunch()
            let outbox = try a.rows("SELECT count(*) FROM ntp_outbox")
            playerA = try await StorePlayer.restored(a.store)
            try await a.store.flushServerPlayback()
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox") == outbox, "the passive restore records nothing")
            await a.exchange()
            #expect(try await Self.state(b, onB).positionMilliseconds == 300_000, "the shared position is still B's")
            #expect(try await playerA.adopt() == 300_000, "the restored player adopts")
            let sealed = try a.rows("SELECT type FROM ntp_outbox ORDER BY install_seq")
            #expect(sealed.allSatisfy { $0 == ["session.end"] }, "only the seal, no ownership, queue, Inbox or history fact: \(sealed)")
            try await playerA.load(ids[0]); try await playerA.play(); try await playerA.listen(50, every: 50); try await playerA.pause()
            await a.exchange(); await b.exchange()
            #expect(try await playerB.adopt() == 350_000)
            try await Concurrency.converge(world, [a, b], "scenario 43")
            #expect(try await Self.state(a, ids[0]).positionMilliseconds == 350_000)
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 350_000)
        }
    }

    /// 44. A standalone library's playback is never recorded: its listening stays in the standalone library, and
    /// nothing reaches a server library (the switch waits for playback to stop).
    @Test func scenario44StandalonePlaybackStaysStandalone() async throws {
        let fixture = try await ServerLibraryFixture(server: false)
        defer { Task { await fixture.close() } }
        let feed = try await fixture.store.insert(ServerLibraryFixture.fetched())
        let player = StorePlayer(fixture.store)
        try await player.load(feed.episodes[0].id, at: 600_000 - 30_000)
        try await player.play(); try await player.listen(30, every: 10)
        #expect(try await player.end(.ended)?.markedPlayed == true)
        #expect(try fixture.rows("SELECT (SELECT count(*) FROM ntp_sessions) + (SELECT count(*) FROM ntp_outbox) + (SELECT count(*) FROM ntp_library)") == [["0"]])
    }
}

extension ServerPlaybackScenarioTests {
    // MARK: - Named agreement cases

    /// A phone's queue as a full re-projection of its own base shows it: a Force full synchronization from a snapshot
    /// holding exactly the phone's base records, published locally (nothing is sent or pulled).
    static func fullReprojectionQueue(_ phone: ExchangePhone) async throws -> [Int64] {
        let records = try phone.rows("SELECT entity, id, field_group, CAST(value AS TEXT), provenance FROM ntp_records")
        let items: [ContractJSON] = try records.map { row in
            ["record": ["entity": .string(row[0]!), "id": .string(row[1]!), "field_group": .string(row[2]!),
                        "value": try ContractJSON.decode(Array(row[3]!.utf8)),
                        "provenance": try row[4].map { try ContractJSON.decode(Array($0.utf8)) } ?? []]]
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("full-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = folder.appendingPathComponent("page.json")
        try ContractJSON.object(["items": .array(items)]).canonicalData().write(to: page)
        let head = try #require(try await phone.store.serverExchangeState().cursor)
        let snapshot = ServerAttachSnapshot(head: head.encoded, installWatermark: 0, itemCount: items.count, podcastCount: 1, pages: [page])
        let staged = folder.appendingPathComponent("full.sqlite")
        try ServerFullReprojection.stageBase(snapshot, into: staged)
        let ids = try await phone.store.reserveServerLocalIDs(feeds: 64, episodes: 64)
        let now = Int64(StorePlayer.realClock().timeIntervalSince1970 * 1_000)
        let build = try ServerFullReprojection.build(database: phone.location.database, file: staged, history: nil, now: now,
                                                     feedIDs: ids.feeds, episodeIDs: ids.episodes, touches: try await phone.store.serverTouchWatermark())
        _ = try await phone.store.publishFullReprojection(build, head: head, now: now, crash: nil)
        return try await phone.store.queue().map(\.id)
    }

    /// A pin release must never empty the queue. B plays an episode, pauses and syncs, then resumes; A plays the same
    /// episode for 13 s, pauses and syncs; B pulls A's newer position (deferred: B's player holds the episode), then
    /// finishes its old session naturally. The completion's claim no longer owns the position, so releasing the pin
    /// projects the queue again: it ends as a full re-projection shows it, the two unrelated episodes kept. In both
    /// forms: B listened before the takeover, or only pressed play.
    @Test(arguments: [true, false]) func aRealCompletionAndPinReleaseMustNotEmptyTheQueue(listened: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, ids, _) = try await Concurrency.twoPhones(world)
            let target = try await Concurrency.same(ids[0], from: a, on: b)
            var unrelated: [Int64] = []
            for id in ids[1..<3] { unrelated.append(try await Concurrency.same(id, from: a, on: b)) }
            _ = try await a.store.enqueue(Array(ids.prefix(3)))
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            #expect(try await b.store.queue().map(\.id) == [target] + unrelated)
            let playerB = StorePlayer(b.store, realTime: ())
            try await playerB.load(target); try await playerB.play()
            if listened { try await playerB.listen(30) }
            try await playerB.pause()
            await b.exchange()
            try await playerB.play()
            await b.exchange()
            let playerA = StorePlayer(a.store, realTime: ())
            try await playerA.load(ids[0]); try await playerA.play(); try await playerA.listen(13); try await playerA.pause()
            await a.exchange()
            await b.run([.pull, .apply])
            let wire = try #require(try await b.store.wireEpisodeForTesting(target))
            #expect(try b.rows("SELECT fields FROM ntp_deferred_pins WHERE episode_id = '\(wire)'").first?.first.flatMap { $0 } != nil,
                    "A's newer position waits for B's player")
            // B's old session ends naturally: its completion, under a claim A took over, is pending.
            try await playerB.end(.ended, at: 600_000)
            let ended = try await b.store.queue().map(\.id)
            #expect(Set(unrelated).isSubset(of: Set(ended)))
            #expect(try b.rows("SELECT count(*) FROM ntp_deferred_pins") != [["0"]], "the pin is still held")
            await b.engine.releasePins()
            #expect(try b.rows("SELECT count(*) FROM ntp_deferred_pins") == [["0"]], "the pin was released")
            let released = try await b.store.queue().map(\.id)
            #expect(Set(unrelated).isSubset(of: Set(released)), "the unrelated queued episodes stay")
            #expect(released == [target] + unrelated, "the completion's claim was taken over: the episode stays queued")
            #expect(try await Self.fullReprojectionQueue(b) == released, "a full re-projection shows the same queue")
            let state = try await Self.state(b, target)
            #expect(state.playState != .played && state.positionMilliseconds == 13_000, "A's position shows, unplayed")
        }
    }

    /// A completion overlay whose claim was taken over remotely: A's end completes under its session's claim, but C's
    /// later start arrives before A's end is sent; A shows the base (C's position, unplayed), as the server folds it.
    @Test func aCompletionWhoseClaimWasTakenOverShowsTheBase() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let onC = try await Concurrency.same(ids[0], from: a, on: c)
            let playerA = StorePlayer(a.store, realTime: ())
            try await playerA.load(ids[0], at: 560_000); try await playerA.play(); try await playerA.listen(20, every: 10); try await playerA.pause()
            await a.exchange(); await c.exchange()
            let playerC = StorePlayer(c.store, realTime: ())
            try await playerC.load(onC, at: 0); try await playerC.play(); try await playerC.listen(20, every: 10); try await playerC.pause()
            await c.exchange()
            try await playerA.load(ids[1]) // A's end completes, pending
            #expect(try await Self.state(a, ids[0]).playState == .played)
            await a.run([.pull, .apply])
            let shown = try await Self.state(a, ids[0])
            #expect(shown.playState == .unplayed && shown.positionMilliseconds == 20_000, "the completion's claim no longer holds")
            try await Concurrency.converge(world, [a, c], "completion taken over")
            #expect(try await Self.state(a, ids[0]) .playState == .unplayed)
        }
    }

    /// Other sessions total 10 s; this phone's retired 20 s are covered by a remote reset; a pending rewind to 15 s
    /// shows `10 + max(0, 15 − 20)` = 10 s, as the server will fold it (PROTOCOL §8.8).
    @Test func aRemoteResetOverARetiredContributionAndAPendingRewind() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let d = try await world.attach("D")
            let onC = try await Concurrency.same(ids[0], from: a, on: c)
            let playerA = StorePlayer(a.store, realTime: ())
            try await playerA.load(ids[0]); try await playerA.play(); try await playerA.listen(20, every: 10); try await playerA.pause()
            await a.exchange(); await d.exchange()
            // D resets having seen A's 20 s; C listens 10 s, unseen by D.
            try await d.store.resetPlayedDurationStatistics()
            await d.exchange()
            let playerC = StorePlayer(c.store, realTime: ())
            try await playerC.load(onC, at: 300_000); try await playerC.play(); try await playerC.listen(10, every: 10); try await playerC.pause()
            await c.exchange()
            await a.exchange()
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 10_000, "C's 10 s; A's 20 s are cut")
            // A, still on its own session (the adoption has not happened: A plays), rewinds to 15 s and saves.
            try await playerA.seek(to: 15_000)
            try await playerA.play(); try await playerA.pause()
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 10_000, "10 + max(0, 15 − 20)")
            await a.exchange(); await c.exchange()
            #expect(try await playerC.adopt() == 15_000, "A's resume claimed last")
            try await Concurrency.converge(world, [a, c, d], "remote reset over a retired contribution")
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 10_000)
        }
    }

    /// A paused player receiving a larger remote played total shows it, and its next save never writes back an older
    /// total from its own baseline (PROTOCOL §8.8).
    @Test func aPausedPlayerReceivesALargerRemoteTotal() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let onC = try await Concurrency.same(ids[0], from: a, on: c)
            let playerA = StorePlayer(a.store, realTime: ())
            try await playerA.load(ids[0]); try await playerA.play(); try await playerA.listen(100, every: 50); try await playerA.pause()
            await a.exchange(); await c.exchange()
            let playerC = StorePlayer(c.store, realTime: ())
            try await playerC.load(onC, at: 100_000); try await playerC.play(); try await playerC.listen(300, every: 60); try await playerC.pause()
            await c.exchange(); await a.exchange()
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 400_000)
            try await playerA.pause() // a save of the paused player
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 400_000, "never an older total")
            _ = try await playerA.adopt()
            try await Concurrency.converge(world, [a, c], "larger remote total")
        }
    }

    /// A takeover seek (PROTOCOL §8.6) while another device's newer claim waits, and a resume paused again within 5 s after an
    /// adoption: both claim, and every device follows.
    @Test func aTakeoverSeekAndAResumePausedWithinFiveSeconds() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let onC = try await Concurrency.same(ids[0], from: a, on: c)
            let playerA = StorePlayer(a.store, realTime: ())
            try await playerA.load(ids[0]); try await playerA.play(); try await playerA.listen(60, every: 30)
            await a.exchange(); await c.exchange()
            let playerC = StorePlayer(c.store, realTime: ())
            try await playerC.load(onC, at: 200_000); try await playerC.play(); try await playerC.listen(30, every: 30); try await playerC.pause()
            await c.exchange()
            a.playing.value = true
            await a.exchange()
            a.playing.value = false
            #expect(try await Self.state(a, ids[0]).positionMilliseconds == 60_000, "sync never moves playing audio")
            try await playerA.seek(to: 400_000)
            try await playerA.listen(10, every: 5); try await playerA.pause()
            let types = try a.rows("SELECT type FROM ntp_outbox ORDER BY install_seq").map { $0[0] ?? "" }
            #expect(types == ["session.end", "session.start", "session.checkpoint"], "\(types)")
            await a.exchange(); await c.exchange()
            #expect(try await playerC.adopt() == 410_000)
            // C resumes and pauses again within 5 s: its start is recorded at the resume.
            try await playerC.play(); try await playerC.listen(3, every: 3); try await playerC.pause()
            await c.exchange(); await a.exchange()
            #expect(try await playerA.adopt() == 413_000)
            try await Concurrency.converge(world, [a, c], "takeover and resume")
            #expect(try await Self.state(a, ids[0]).positionMilliseconds == 413_000)
        }
    }

    /// A paused player follows the claim it adopted: another device's later checkpoint under that claim moves it again,
    /// while a seek the person makes while paused is never undone by sync.
    @Test func aPausedPlayerFollowsLaterCheckpointsOfTheClaimItAdopted() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(ids[0]); try await player.play(); try await player.listen(30, every: 10); try await player.pause()
            await a.exchange(); await c.exchange()
            var other = RemoteSession(store: c.store, episode: try await Concurrency.same(ids[0], from: a, on: c))
            try await other.start(at: 600_000)
            await c.exchange(); await a.exchange()
            #expect(try await player.adopt() == 600_000)
            try await other.checkpoint(position: 900_000, contribution: 300_000)
            await c.exchange(); await a.exchange()
            #expect(try await player.adopt() == 900_000, "a later checkpoint of the adopted claim")
            // The person moves the paused player: sync leaves it there.
            try await player.seek(to: 120_000)
            try await player.pause()
            await a.exchange()
            #expect(try await player.adopt() == nil)
            #expect(try await Self.state(a, ids[0]).positionMilliseconds == 120_000)
        }
    }

    /// Deferred cuts over drafts (PROTOCOL §15.2): a statistics reset while a subscription waits for the server covers the
    /// listening recorded as drafts before it and nothing after.
    @Test func aDeferredResetCoversTheDraftListeningBeforeIt() async throws {
        try await ExchangeWorld.run { world in
            let a = try await world.attach("A")
            world.server.stop(keepingData: true)
            let two = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("two.xml"), title: "Two", prefix: "two", count: 3))
            let episode = two.episodes.map(\.id).min()!
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(episode); try await player.play(); try await player.listen(100, every: 50); try await player.pause()
            try await a.store.resetPlayedDurationStatistics()
            try await player.play(); try await player.listen(50, every: 50); try await player.pause()
            #expect(try await Self.state(a, episode).playedDurationMilliseconds == 50_000)
            try await world.server.launch()
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: two.id)
            await a.exchange()
            #expect(try a.rows("SELECT count(*) FROM ntp_drafts") == [["0"]])
            let b = try await world.attach("B")
            try await Concurrency.converge(world, [a, b], "deferred reset over drafts")
            #expect(try await Self.state(a, episode).playedDurationMilliseconds == 50_000)
        }
    }
}
