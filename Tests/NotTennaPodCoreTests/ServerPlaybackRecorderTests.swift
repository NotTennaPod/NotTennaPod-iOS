import Foundation
import Testing
@testable import NotTennaPodCore

/// The session recorder (PROTOCOL §8): golden facts for every playback path.
@Suite struct ServerPlaybackRecorderTests {
    typealias Fact = ServerLibraryFixture.Fact

    static func library() async throws -> (fixture: ServerLibraryFixture, ids: [Int64], podcast: String, generation: String) {
        let fixture = try await ServerLibraryFixture()
        let registered = try await fixture.subscribeRegistered()
        return (fixture, registered.feed.episodes.map(\.id).sorted(), registered.podcast, registered.generation)
    }

    static func facts(_ fixture: ServerLibraryFixture, after count: Int, types: Set<String>? = nil) throws -> [Fact] {
        try fixture.newFacts(after: count).filter { types?.contains($0.type) ?? true }
    }

    static let playback: Set<String> = ["session.start", "session.checkpoint", "session.end", "session.finalize", "episode.leave"]

    /// Play, five-second saves, the minute's export, a pause, a resume (its claim) and the natural end.
    @Test func aSessionStartsChecksInClaimsAResumeAndEnds() async throws {
        let (fixture, ids, podcast, generation) = try await Self.library()
        defer { Task { await fixture.close() } }
        let player = StorePlayer(fixture.store)
        let before = try fixture.outboxCount()
        try await player.load(ids[1])
        #expect(try Self.facts(fixture, after: before).map(\.type) == ["queue.add"], "a load records no session")
        try await player.play()
        try await player.listen(65)
        try await player.pause()
        try await player.play()
        try await player.listen(10)
        try await player.end(.ended, at: 599_500)
        let facts = try Self.facts(fixture, after: before, types: Self.playback)
        #expect(facts.map(\.type) == ["session.start", "session.checkpoint", "session.checkpoint", "session.checkpoint", "session.end"])
        let wire = try #require(try fixture.wireID(ids[1]))
        #expect(wire == (try fixture.expectedEpisodeID(podcast: podcast, guid: "guid-2")))
        let start = facts[0], minute = facts[1], pause = facts[2], resume = facts[3], end = facts[4]
        let session = try #require(start.payload["session_id"]?.stringValue)
        #expect(start.payload["episode"]?["episode_id"]?.stringValue == wire)
        #expect(start.payload["episode"]?["generation_id"]?.stringValue == generation)
        #expect(start.payload["start_position"]?.integerValue == 0 && start.payload["activity"]?.boolValue == true)
        #expect(start.payload["observed_claim"] == nil, "nothing owned the position")
        #expect(start.payload["duration"]?.integerValue == 600_000)
        #expect(start.payload["baseline"]?.stringValue.map(ContractIdentity.isUUID) == true)
        #expect(start.json["client_time"]?.integerValue == 1_760_000_000_000)
        for fact in facts { #expect(fact.payload["session_id"]?.stringValue == session) }
        // The minute's export covers the start's save and the saves after it.
        #expect(minute.payload["ordinal"]?.integerValue == 1 && minute.payload["position"]?.integerValue == 60_000)
        #expect(minute.payload["contribution"]?.integerValue == 60_000 && minute.payload["activity"]?.boolValue == true)
        #expect(minute.payload["save"]?["index"]?.integerValue == 13 && minute.payload["save"]?["passive"]?.boolValue == false)
        #expect(minute.payload["save"]?["first"] != nil)
        #expect(minute.payload["save"]?["baseline"] == start.payload["baseline"])
        #expect(minute.payload["claim"] == nil)
        #expect(pause.payload["ordinal"]?.integerValue == 2 && pause.payload["position"]?.integerValue == 65_000)
        // The resume claims (PROTOCOL §8.1): the save made as playback started, not passive, with its claim.
        #expect(resume.payload["ordinal"]?.integerValue == 3 && resume.payload["claim"]?.boolValue == true)
        #expect(resume.payload["observed_claim"]?.stringValue == start.opID, "the start owned the position")
        #expect(resume.payload["save"]?["first"]?.stringValue == resume.payload["save"]?["id"]?.stringValue)
        #expect(resume.payload["position"]?.integerValue == 65_000)
        // The end: the final save, the decisions endPlayback took.
        #expect(end.payload["ordinal"]?.integerValue == 4 && end.payload["reason"]?.stringValue == "ended")
        #expect(end.payload["position"]?.integerValue == 599_500 && end.payload["contribution"]?.integerValue == 599_500)
        #expect(end.payload["completed"]?.boolValue == true && end.payload["threshold_ms"]?.integerValue == 30_000)
        #expect(end.payload["remove_from_queue"]?.boolValue == false && end.payload["history"]?.boolValue == true)
        #expect(end.payload["activity"]?.boolValue == true)
        // Every fact of the session follows the previous one on the author's chain.
        for (earlier, later) in zip(facts, facts.dropFirst()) { #expect(later.json["previous_op_id"]?.stringValue == earlier.opID) }
        #expect(try fixture.overlays(opID: end.opID).contains { $0[2] == "completion" && $0[3] == "completion" })
        // The episode shows completed, as endPlayback left it, and nothing marks it any more.
        let episode = try #require(try await fixture.store.episode(id: ids[1])).userState
        #expect(episode.playState == .played && episode.positionMilliseconds == 0 && episode.playedDurationMilliseconds == 599_500)
        #expect(try fixture.rows("SELECT count(*) FROM ntp_local_playback") == [["0"]])
        #expect(try await fixture.store.transitionStateForTesting().current == nil)
    }

    /// An episode loaded paused and switched away from without playing here: `episode.leave` (PROTOCOL §8.4).
    @Test func anEpisodeLoadedAndLeftRecordsALeave() async throws {
        let (fixture, ids, _, _) = try await Self.library()
        defer { Task { await fixture.close() } }
        let player = StorePlayer(fixture.store)
        try await fixture.store.projectForTesting(ids[1]) { $0.userState.positionMilliseconds = 590_000 }
        let before = try fixture.outboxCount()
        try await player.load(ids[1])
        let transition = try #require(try await fixture.store.transitionStateForTesting().current)
        #expect(transition.kind == .leave && transition.episodeID == ids[1])
        let result = try #require(try await player.end(.switched))
        #expect(result.markedPlayed, "within the smart threshold, as Android's switch")
        let facts = try Self.facts(fixture, after: before, types: Self.playback)
        #expect(facts.map(\.type) == ["episode.leave"])
        let leave = try #require(facts.first)
        #expect(leave.payload["transition_id"]?.stringValue == transition.id)
        #expect(leave.payload["reason"]?.stringValue == "switched" && leave.payload["position"]?.integerValue == 590_000)
        #expect(leave.payload["completed"]?.boolValue == true && leave.payload["threshold_ms"]?.integerValue == 30_000)
        #expect(leave.payload["remove_from_queue"]?.boolValue == false && leave.payload["history"]?.boolValue == true)
        #expect(leave.payload["observed_claim"] == nil, "the position had no claim")
        #expect(try fixture.overlays(opID: leave.opID).map { $0[2] }.contains("completion"))
    }

    /// A skip outside the threshold with "Keep skipped episodes" off removes from the queue, without completing.
    @Test func aSkipRecordsItsQueueRemoval() async throws {
        let (fixture, ids, _, _) = try await Self.library()
        defer { Task { await fixture.close() } }
        let player = StorePlayer(fixture.store)
        player.skipKeepsEpisode = false
        let before = try fixture.outboxCount()
        try await player.load(ids[1])
        try await player.play()
        try await player.listen(20)
        let result = try #require(try await player.end(.skipped))
        #expect(result.removedFromQueue && !result.markedPlayed)
        let end = try #require(try Self.facts(fixture, after: before, types: ["session.end"]).first)
        #expect(end.payload["reason"]?.stringValue == "skipped" && end.payload["completed"]?.boolValue == false)
        #expect(end.payload["remove_from_queue"]?.boolValue == true)
        #expect(try await fixture.store.queue().map(\.id).contains(ids[1]) == false)
    }

    /// A session restored after a relaunch is exported passively (the restart export) and finalized at the switch.
    @Test func aRelaunchExportsPassivelyAndTheSwitchFinalizes() async throws {
        let (fixture, ids, _, _) = try await Self.library()
        defer { Task { await fixture.close() } }
        var player = StorePlayer(fixture.store)
        let before = try fixture.outboxCount()
        try await player.load(ids[1])
        try await player.play()
        try await player.listen(30)
        // The process dies while playing: the last saves were never exported.
        player = try await player.relaunch(fixture.url)
        #expect(try Self.facts(fixture, after: before, types: Self.playback).map(\.type) == ["session.start"])
        try await player.store.flushServerPlayback()
        var facts = try Self.facts(fixture, after: before, types: Self.playback)
        #expect(facts.map(\.type) == ["session.start", "session.checkpoint"])
        #expect(facts[1].payload["save"]?["passive"]?.boolValue == true, "a save of an earlier process (PROTOCOL §8.2)")
        #expect(facts[1].payload["position"]?.integerValue == 30_000)
        let transition = try #require(try await player.store.transitionStateForTesting().current)
        #expect(transition.kind == .finalize && transition.claim == facts[0].opID)
        try await player.end(.switched)
        facts = try Self.facts(fixture, after: before, types: Self.playback)
        #expect(facts.map(\.type) == ["session.start", "session.checkpoint", "session.finalize"])
        let finalize = facts[2]
        #expect(finalize.payload["ordinal"]?.integerValue == 1 && finalize.payload["claim_id"]?.stringValue == facts[0].opID)
        #expect(finalize.payload["completed"]?.boolValue == false && finalize.payload["history"]?.boolValue == true)
        #expect(finalize.payload["session_id"] == facts[0].payload["session_id"])
        try await player.store.close()
    }

    /// Loading the same episode again (a stop, then play) closes its session after exporting its save and starts a new
    /// one at the next play; the reload consumes the transition without completion (PROTOCOL §8).
    @Test func reloadingTheSameEpisodeStartsANewSession() async throws {
        let (fixture, ids, _, _) = try await Self.library()
        defer { Task { await fixture.close() } }
        let player = StorePlayer(fixture.store)
        let before = try fixture.outboxCount()
        try await player.load(ids[1])
        try await player.play()
        try await player.listen(15)
        try await player.load(ids[1], at: 15_000)
        try await player.play()
        try await player.listen(5)
        try await player.pause()
        let facts = try Self.facts(fixture, after: before, types: Self.playback)
        #expect(facts.map(\.type) == ["session.start", "session.checkpoint", "session.start", "session.checkpoint"])
        #expect(facts[0].payload["session_id"] != facts[2].payload["session_id"])
        #expect(facts[2].payload["observed_claim"]?.stringValue == facts[0].opID, "it saw its own earlier claim")
        let episode = try #require(try await fixture.store.episode(id: ids[1])).userState
        #expect(episode.playedDurationMilliseconds == 20_000, "both sessions count, as Android counts them")
    }

    /// A timeline reset exports the settled save and rebases the accounting at 0 with the contribution so far.
    @Test func aTimelineResetExportsAndRebases() async throws {
        let (fixture, ids, _, _) = try await Self.library()
        defer { Task { await fixture.close() } }
        let player = StorePlayer(fixture.store)
        let before = try fixture.outboxCount()
        try await player.load(ids[1])
        try await player.play()
        try await player.listen(20)
        let session = try #require(player.session)
        _ = try await fixture.store.recordPlaybackTimelineReset(sessionID: session.id, finalSample: .init(positionMilliseconds: 25_000,
            durationMilliseconds: 600_000, status: .playing), now: player.time.addingTimeInterval(5))
        _ = try await fixture.store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 10_000, durationMilliseconds: 600_000,
                                                                                       status: .paused), now: player.time.addingTimeInterval(15), synchronize: true)
        let facts = try Self.facts(fixture, after: before, types: Self.playback)
        #expect(facts.map(\.type) == ["session.start", "session.checkpoint", "session.checkpoint"])
        #expect(facts[1].payload["position"]?.integerValue == 25_000 && facts[1].payload["contribution"]?.integerValue == 25_000)
        #expect(facts[2].payload["position"]?.integerValue == 10_000 && facts[2].payload["contribution"]?.integerValue == 35_000)
        #expect(try await fixture.store.episode(id: ids[1])?.userState.playedDurationMilliseconds == 35_000)
    }

    /// Flush before cuts and position resets (PROTOCOL §8.2): the unexported save is exported first, and the cut depends on it.
    @Test(arguments: ["history.clear", "statistics.reset", "history.remove", "episode.reset_position"])
    func aCutOrResetFlushesTheOpenSessionFirst(_ type: String) async throws {
        let (fixture, ids, _, _) = try await Self.library()
        defer { Task { await fixture.close() } }
        let player = StorePlayer(fixture.store)
        try await player.load(ids[1])
        try await player.play()
        try await player.listen(20)
        let before = try fixture.outboxCount()
        switch type {
        case "history.clear": _ = try await fixture.store.clearPlaybackHistory()
        case "statistics.reset": try await fixture.store.resetPlayedDurationStatistics()
        case "history.remove": _ = try await fixture.store.removeFromPlaybackHistoryWithUndo(ids[1])
        default: try await fixture.store.resetPlaybackPosition(episodeID: ids[1])
        }
        let facts = try Self.facts(fixture, after: before)
        #expect(facts.map(\.type) == ["session.checkpoint", type])
        #expect(facts[0].payload["position"]?.integerValue == 20_000)
        #expect(facts[1].dependencies.contains(facts[0].opID), "the cut observed the flushed save")
        if type == "statistics.reset" {
            #expect(try await fixture.store.episode(id: ids[1])?.userState.playedDurationMilliseconds == 0)
            try await player.listen(10)
            #expect(try await fixture.store.episode(id: ids[1])?.userState.playedDurationMilliseconds == 10_000,
                    "only listening after the reset counts")
        }
        if type == "episode.reset_position" {
            #expect(try await fixture.store.transitionStateForTesting().current == nil)
        }
    }

    /// Local folders never reach the server (PROTOCOL §7.6): no session, no transition, no fact.
    @Test func aLocalFolderEpisodeRecordsNothing() async throws {
        let (fixture, _, _, _) = try await Self.library()
        defer { Task { await fixture.close() } }
        let folder = try await fixture.store.insertLocalFolderForTesting()
        let player = StorePlayer(fixture.store)
        let before = try fixture.outboxCount()
        try await player.load(folder)
        try await player.play()
        try await player.listen(70)
        try await player.end(.ended)
        #expect(try fixture.newFacts(after: before).isEmpty)
        #expect(try await fixture.store.syncSessionsForTesting().isEmpty)
        #expect(try await fixture.store.episode(id: folder)?.userState.playedDurationMilliseconds == 70_000, "Android's arithmetic stays")
    }

    /// A pending registration's session is a draft on its chain for life (PROTOCOL §15.2) and materializes with it.
    @Test func aSessionOfAPendingPodcastIsADraftOnItsChain() async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let feed = try await fixture.store.insert(ServerLibraryFixture.fetched("https://example.test/pending.xml", title: "Pending"))
        let ids = feed.episodes.map(\.id).sorted()
        let player = StorePlayer(fixture.store)
        try await player.load(ids[0])
        try await player.play()
        try await player.listen(10)
        try await player.pause()
        let drafts = try fixture.drafts().filter { Self.playback.contains($0.type) }
        #expect(drafts.map(\.type) == ["session.start", "session.checkpoint"])
        let op = try fixture.registrationOp(feedID: feed.id)
        let created = try fixture.created(op)
        try await fixture.store.resolveRegistration(opID: op, .init(podcastID: created.podcast, generationID: created.generation, mode: "created", decisionID: nil))
        // After resolution the session keeps its registration author.
        try await player.play()
        try await player.listen(5)
        try await player.end(.switched)
        let facts = try fixture.outbox().filter { Self.playback.contains($0.type) }
        #expect(facts.map(\.type) == ["session.start", "session.checkpoint", "session.checkpoint", "session.end"])
        #expect(Set(facts.map { $0.json["author_id"]?.stringValue }).count == 1)
        #expect(facts[0].json["author_id"]?.stringValue != fixture.identity.installID, "the registration author, not the main one")
        #expect(facts.allSatisfy { $0.payload["episode"]?["generation_id"]?.stringValue == created.generation })
    }
}

extension ServerPlaybackRecorderTests {
    /// A pending leave names the podcast generation its episode was loaded under (PROTOCOL §8.4 `leave {episode, generation,
    /// observed_claim}`), not one the podcast took since.
    @Test func aLeaveNamesTheGenerationItsEpisodeWasLoadedUnder() async throws {
        let (fixture, ids, podcast, generation) = try await Self.library()
        defer { Task { await fixture.close() } }
        let player = StorePlayer(fixture.store)
        try await player.load(ids[1])
        #expect(try await fixture.store.transitionStateForTesting().current?.generation == generation)
        try await fixture.store.setLiveGenerationForTesting(podcast: podcast, generation: ContractIdentity.randomUUID())
        let before = try fixture.outboxCount()
        _ = try await player.end(.switched)
        let leave = try #require(try Self.facts(fixture, after: before, types: ["episode.leave"]).first)
        #expect(leave.targets.first?["generation"]?.stringValue == generation)
        #expect(leave.payload["episode"]?["generation_id"]?.stringValue == generation)
    }

    /// 41 (second part): a switch of libraries ends the graph of the library that played (the switch waits until
    /// nothing plays); its remaining listening is exported in that library only, by its restart export, never in the
    /// library switched to.
    @Test func remainingListeningStaysInTheLibraryThatPlayedIt() async throws {
        let first = try await Self.library(), second = try await Self.library()
        defer { Task { await second.fixture.close() } }
        var player = StorePlayer(first.fixture.store)
        try await player.load(first.ids[1]); try await player.play(); try await player.listen(30)
        try await player.store.close() // the switch: the first library's graph stops with a save not exported
        let other = StorePlayer(second.fixture.store)
        try await other.load(second.ids[1]); try await other.play(); try await other.listen(10); try await other.pause()
        let secondFacts = try second.fixture.outbox().filter { Self.playback.contains($0.type) }
        #expect(secondFacts.map(\.type) == ["session.start", "session.checkpoint"])
        #expect(secondFacts.allSatisfy { $0.payload["position"]?.integerValue ?? 10_000 <= 10_000 }, "nothing of the first library's listening")
        // Switching back: the first library's restart export records its remaining listening there.
        player = try await StorePlayer.restored(try FeedLibraryStore(url: first.fixture.url), time: player.time)
        try await player.store.flushServerPlayback()
        let firstFacts = try first.fixture.outbox().filter { Self.playback.contains($0.type) }
        #expect(firstFacts.map(\.type) == ["session.start", "session.checkpoint"])
        #expect(firstFacts.last?.payload["position"]?.integerValue == 30_000 && firstFacts.last?.payload["save"]?["passive"]?.boolValue == true)
        #expect(try second.fixture.outbox().filter { Self.playback.contains($0.type) }.count == 2)
        try await player.store.close()
        try? FileManager.default.removeItem(at: first.fixture.directory)
    }
}

extension FeedLibraryStore {
    /// A local-folder feed with one episode, as `addLocalFolder` would add it (PROTOCOL §7.6), for tests.
    func insertLocalFolderForTesting() throws -> Int64 {
        var feed = LibraryFeed(id: try database.allocateID("feed"), source: LibraryFeed.localSourcePrefix + "test-folder",
                               metadata: ParsedFeed(format: .rss, title: "Folder"), episodes: [])
        let episodeID = try database.allocateID("episode")
        feed.episodes = [LibraryEpisode(id: episodeID, details: ParsedEpisode(identifier: "file-1", title: "File",
            publicationDate: Date(timeIntervalSince1970: 1_700_000_000), media: ParsedMedia(url: "file:///file-1.mp3", size: 10, durationMilliseconds: 600_000)))]
        try write(.local) { try save(feed) }
        return episodeID
    }
}

// MARK: - Cuts and listening the server refused (PROTOCOL §6.13, §8.2)

extension ServerPlaybackRecorderTests {
    /// The cut's error, nil when it went through.
    static func refusal(_ body: () async throws -> Void) async throws -> ServerRecordingError? {
        do { try await body(); return nil } catch let error as ServerRecordingError { return error }
    }

    /// What a cut must leave alone: the large episode's history, last played, played time and position, and the outbox.
    static func image(_ fixture: ServerLibraryFixture, _ id: Int64) async throws -> [Int64?] {
        let state = try #require(try await fixture.store.episode(id: id)).userState
        return [state.lastPlayedHistoryMilliseconds, state.lastPlayedTimeMilliseconds, state.playedDurationMilliseconds,
                Int64(state.positionMilliseconds), Int64(try fixture.outboxCount())]
    }

    /// Listening the server refused as too large blocks every cut that would cover it: a history clear, a statistics reset
    /// and a removal of its episode's history are refused and change nothing (rows, played time, outbox); removing another
    /// episode's history is not blocked. After "Keep only on this device" the clear and the reset go through, cover it
    /// here, and a full reprojection matches.
    @Test func cutsWaitForRefusedListeningUntilItIsKeptOnThisDevice() async throws {
        let (fixture, small, large) = try await ServerOwedReplayTests.oversizedEpisode()
        do {
            let store = fixture.store
            let player = StorePlayer(store)
            try await player.load(small[0]); try await player.play(); try await player.listen(20); try await player.pause()
            try await player.load(large); try await player.play(); try await player.listen(65); try await player.pause()
            let refusedImage = try await Self.image(fixture, large)
            #expect(refusedImage[0] != nil && refusedImage[2] == 65_000)
            #expect(try await Self.refusal { _ = try await store.clearPlaybackHistory() } == .cutBlockedByRefusedListening(intent: "historyClear"))
            #expect(try await Self.image(fixture, large) == refusedImage, "the clear changed nothing")
            #expect(try await store.episode(id: small[0])?.userState.lastPlayedHistoryMilliseconds != nil, "nor another episode's history")
            #expect(try await Self.refusal { try await store.resetPlayedDurationStatistics() } == .cutBlockedByRefusedListening(intent: "statisticsReset"))
            #expect(try await Self.image(fixture, large) == refusedImage, "the reset changed nothing")
            #expect(try await store.episode(id: small[0])?.userState.playedDurationMilliseconds == 20_000)
            #expect(try await Self.refusal { _ = try await store.removeFromPlaybackHistoryWithUndo(large) } == .cutBlockedByRefusedListening(intent: "historyRemove"))
            #expect(try await Self.image(fixture, large) == refusedImage)
            // Another episode's history removal is not blocked.
            #expect(try await store.removeFromPlaybackHistoryWithUndo(small[0]) != nil)
            #expect(try await store.episode(id: small[0])?.userState.lastPlayedHistoryMilliseconds == nil)
            // Keep only on this device: the listening stays here, and the cuts cover it.
            let item = try #require(try await store.serverAttentionItems().first)
            try await store.keepRefusedListeningOnThisDevice(item)
            #expect(try await store.serverAttentionItems().isEmpty)
            #expect(try await Self.image(fixture, large).prefix(4) == refusedImage.prefix(4), "kept as it was")
            #expect(try await store.pendingListeningForTesting(large).history != nil, "its listening is still this device's history")
            _ = try await store.clearPlaybackHistory()
            #expect(try await store.episode(id: large)?.userState.lastPlayedHistoryMilliseconds == nil)
            // What every later projection of the episode reads: the clear covers the kept listening's history entries, not
            // its last played.
            let pending = try await store.pendingListeningForTesting(large)
            #expect(pending.history == nil && pending.lastPlayed != nil, "\(pending)")
            try await store.resetPlayedDurationStatistics()
            #expect(try await store.episode(id: large)?.userState.playedDurationMilliseconds == 0)
            var differences = try await ServerChangeSetCaptureTests.rebuildDifferences(store, ownedRoot: fixture.directory, archive: nil)
            #expect(differences.isEmpty, "a full reprojection matches: \(differences.prefix(3))")
            // Listening after the reset counts from it: what the reset covered never comes back.
            try await player.play(); try await player.listen(5); try await player.pause()
            #expect(try await store.episode(id: large)?.userState.playedDurationMilliseconds == 5_000)
            differences = try await ServerChangeSetCaptureTests.rebuildDifferences(store, ownedRoot: fixture.directory, archive: nil)
            #expect(differences.isEmpty, "after more listening: \(differences.prefix(3))")
            // Its session never exports, whatever is recorded later.
            let before = try fixture.outboxCount()
            try await player.load(small[1])
            #expect(try fixture.newFacts(after: before).filter { Self.playback.contains($0.type) && $0.episodeIDs == [(try? fixture.wireID(large)) ?? ""] }.isEmpty)
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    /// Kept on this device, the episode's history can be removed and the removal undone: the history returns as it was,
    /// a full reprojection matches at each step, and the kept session exports nothing.
    @Test func keptListeningsHistoryRemovalIsUndone() async throws {
        let (fixture, _, large) = try await ServerOwedReplayTests.oversizedEpisode()
        do {
            let store = fixture.store
            let player = StorePlayer(store)
            try await player.load(large); try await player.play(); try await player.listen(30); try await player.pause()
            let history = try #require(try await store.episode(id: large)?.userState.lastPlayedHistoryMilliseconds)
            try await store.keepRefusedListeningOnThisDevice(try #require(try await store.serverAttentionItems().first))
            // Kept for good: even once the episode's facts fit again (here, its history removal), its session never exports.
            await store.setServerFactBoundForTesting(nil)
            let receipt = try #require(try await store.removeFromPlaybackHistoryWithUndo(large))
            #expect(try await store.episode(id: large)?.userState.lastPlayedHistoryMilliseconds == nil)
            #expect(try await store.pendingListeningForTesting(large).history == nil, "the removal covers it in later projections")
            var differences = try await ServerChangeSetCaptureTests.rebuildDifferences(store, ownedRoot: fixture.directory, archive: nil)
            #expect(differences.isEmpty, "removed: \(differences.prefix(3))")
            #expect(try await store.undoHistoryRemoval(receipt).status == .restored)
            #expect(try await store.episode(id: large)?.userState.lastPlayedHistoryMilliseconds == history)
            #expect(try await store.pendingListeningForTesting(large).history == history, "the Undo gives it back")
            differences = try await ServerChangeSetCaptureTests.rebuildDifferences(store, ownedRoot: fixture.directory, archive: nil)
            #expect(differences.isEmpty, "restored: \(differences.prefix(3))")
            #expect(try fixture.outbox().filter { Self.playback.contains($0.type) }.isEmpty, "the kept session never exports")
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    /// A cut whose own flush finds the listening too large (the open session's first export) is refused, and the
    /// refusal is kept: Needs attention lists the episode, so the message's way out is there.
    @Test func aCutWhoseFlushFindsListeningTooLargeKeepsTheRefusalListed() async throws {
        let (fixture, _, large) = try await ServerOwedReplayTests.oversizedEpisode()
        do {
            let store = fixture.store
            await store.setServerFactBoundForTesting(nil)
            let player = StorePlayer(store)
            try await player.load(large); try await player.play(); try await player.listen(10)
            // Still playing, nothing exported since the start: the bound falls, then a clear flushes the open session.
            await store.setServerFactBoundForTesting(ServerOwedReplayTests.smallBound)
            let before = try fixture.outboxCount()
            #expect(try await Self.refusal { _ = try await store.clearPlaybackHistory() } == .cutBlockedByRefusedListening(intent: "historyClear"))
            #expect(try await store.serverAttentionItems().map(\.kind) == [.refusedListening(episodeTitle: ServerOwedReplayTests.largeTitle)])
            #expect(try fixture.outboxCount() == before)
            #expect(try await store.episode(id: large)?.userState.lastPlayedHistoryMilliseconds != nil, "the history is not cleared")
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }
}

// MARK: - Leaves and finalizations too large for the server (PROTOCOL §6.13)

extension ServerPlaybackRecorderTests {
    /// A paused, never-played load of the oversized episode, then a switch away: its `episode.leave` is too large. It is kept
    /// due, refused, listed by its episode; what projections read keeps its history; a history clear waits for it; once
    /// the bound is restored, Try again records it, and nothing is left due or listed.
    @Test func aLeaveTooLargeIsKeptListedAndSentOnceItFits() async throws {
        let (fixture, small, large) = try await ServerOwedReplayTests.oversizedEpisode()
        do {
            let store = fixture.store
            let player = StorePlayer(store)
            try await player.load(large)
            let before = try fixture.outboxCount()
            try await player.load(small[0])
            let due = try await store.transitionStateForTesting().due
            #expect(due.map(\.refused) == [.tooLarge] && due.first?.transition.kind == .leave && due.first?.transition.episodeID == large)
            #expect(try await store.serverAttentionItems().map(\.kind) == [.refusedListening(episodeTitle: ServerOwedReplayTests.largeTitle)])
            #expect(try fixture.newFacts(after: before).filter { $0.type == "episode.leave" }.isEmpty)
            let history = try #require(try await store.episode(id: large)?.userState.lastPlayedHistoryMilliseconds)
            #expect(try await store.pendingListeningForTesting(large).history == history, "projections keep its history")
            let differences = try await ServerChangeSetCaptureTests.rebuildDifferences(store, ownedRoot: fixture.directory, archive: nil)
            #expect(differences.isEmpty, "\(differences.prefix(3))")
            #expect(try await Self.refusal { _ = try await store.clearPlaybackHistory() } == .cutBlockedByRefusedListening(intent: "historyClear"))
            await store.setServerFactBoundForTesting(nil)
            #expect(try await store.retryRefusedListening())
            let leaves = try fixture.newFacts(after: before).filter { $0.type == "episode.leave" }
            let wire = try #require(try fixture.wireID(large))
            #expect(leaves.count == 1 && leaves.first?.episodeIDs == [wire])
            #expect(try await store.transitionStateForTesting().due.isEmpty)
            #expect(try await store.serverAttentionItems().isEmpty)
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    /// A finalization alone too large (the session's facts were recorded under a larger bound, the bound fell before the
    /// switch finalized it after a relaunch): kept due, listed, its history kept in what projections read, recorded by Try
    /// again once it fits. Kept on this device instead, it stays due as this device's, never sent.
    @Test(arguments: [false, true]) func aFinalizationTooLargeIsKeptListedAndSentOnceItFits(keep: Bool) async throws {
        let (fixture, _, large) = try await ServerOwedReplayTests.oversizedEpisode()
        await fixture.store.setServerFactBoundForTesting(nil)
        var player = StorePlayer(fixture.store)
        try await player.load(large); try await player.play(); try await player.listen(20); try await player.pause()
        player = try await player.relaunch(fixture.url)
        let store = player.store
        do {
            try await store.flushServerPlayback()
            await store.setServerFactBoundForTesting(ServerOwedReplayTests.smallBound)
            let before = try fixture.outboxCount()
            try await player.end(.switched)
            let due = try await store.transitionStateForTesting().due
            #expect(due.map(\.refused) == [.tooLarge] && due.first?.transition.kind == .finalize, "\(due)")
            let item = try #require(try await store.serverAttentionItems().first)
            let title = await ServerOwedReplayTests.largeTitle
            #expect(item.kind == .refusedListening(episodeTitle: title))
            let history = try #require(try await store.episode(id: large)?.userState.lastPlayedHistoryMilliseconds)
            #expect(try await store.pendingListeningForTesting(large).history == history, "projections keep its history")
            await store.setServerFactBoundForTesting(nil)
            if keep {
                try await store.keepRefusedListeningOnThisDevice(item)
                #expect(try await store.transitionStateForTesting().due.map(\.refused) == [.keptLocal])
                #expect(!(try await store.retryRefusedListening()), "nothing to try: it is this device's")
                #expect(try fixture.newFacts(after: before).filter { $0.type == "session.finalize" }.isEmpty)
                _ = try await store.clearPlaybackHistory()
                #expect(try await store.pendingListeningForTesting(large).history == nil, "a later clear covers it")
            } else {
                #expect(try await store.retryRefusedListening())
                #expect(try fixture.newFacts(after: before).map(\.type) == ["session.finalize"])
                #expect(try await store.transitionStateForTesting().due.isEmpty)
            }
            #expect(try await store.serverAttentionItems().isEmpty)
            try await store.close()
            await fixture.close()
        } catch { try? await store.close(); await fixture.close(); throw error }
    }
}

extension FeedLibraryStore {
    /// This device's unexported listening of an episode as every projection reads it (`ServerProjector.pendingListening`).
    func pendingListeningForTesting(_ localID: Int64) throws -> (lastPlayed: Int64?, history: Int64?) {
        guard let context = serverContext else { throw ServerRecordingError.notAServerLibrary }
        return try unitProjector(context: context, now: 0).pendingListening(localID)
    }
}
