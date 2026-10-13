import Foundation
import Testing
@testable import NotTennaPodCore

/// The coverage test: every public store mutator, run with random state in a server library, either records a
/// fact for every synced change it commits or commits nothing. Synced changes are found here independently of
/// the recorder, from the rows before and after, and each must be explained by the facts and drafts the call
/// recorded, by their fixed effects, or by the code that owns the call (playback). Previews the account does
/// not know and local folders record nothing by design.
@MainActor @Suite(.timeLimit(.minutes(10))) struct ServerRecordingCoverageTests {
    enum Change: Hashable, CustomStringConvertible {
        case episode(Int64, String), episodeInserted(Int64), episodeDeleted(Int64)
        case feed(Int64, String), feedInserted(Int64), feedDeleted(Int64), credentials(Int64)
        case queueIn(Int64), queueOut(Int64), queueOrder
        var description: String {
            switch self {
            case .episode(let id, let field): "episode \(id) \(field)"
            case .episodeInserted(let id): "episode \(id) inserted"
            case .episodeDeleted(let id): "episode \(id) deleted"
            case .feed(let id, let field): "feed \(id) \(field)"
            case .feedInserted(let id): "feed \(id) inserted"
            case .feedDeleted(let id): "feed \(id) deleted"
            case .credentials(let id): "feed \(id) credentials"
            case .queueIn(let id): "queue add \(id)"
            case .queueOut(let id): "queue removal \(id)"
            case .queueOrder: "queue order"
            }
        }
    }

    struct State: Equatable {
        var episodes: [Int64: SyncedEpisode] = [:]
        var episodeFeed: [Int64: Int64] = [:]
        var feeds: [Int64: SyncedFeed] = [:]
        var queue: [Int64] = []
        var credentials: [Int64: String] = [:]
    }

    /// A seeded generator, so a failing run can be repeated.
    struct Random: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// What a mutator may change without a fact: the stage that maps it later.
    /// `previewCleanup`: preview expiry never propagates (PROTOCOL §7.2, §15.2).
    enum Owner { case recorded, playback, refresh, discoveryQueue, remote, previewCleanup }

    struct Mutator {
        let name: String
        let owner: Owner
        let run: (ServerLibraryFixture, inout Random, Context) async throws -> Void
    }

    final class Context {
        var queueReceipts: [EpisodeQueueRemovalReceipt] = []
        var historyReceipts: [EpisodeHistoryRemovalReceipt] = []
        var markReceipts: [EpisodeMarkReceipt] = []
        var session: LibraryPlaybackSession?
        var feedCount = 0
    }

    private func state(_ fixture: ServerLibraryFixture) async throws -> State {
        try await fixture.store.syncedStateForTesting()
    }

    private func diff(_ a: State, _ b: State) -> Set<Change> {
        var changes = Set<Change>()
        for (id, old) in a.episodes {
            guard let new = b.episodes[id] else { changes.insert(.episodeDeleted(id)); continue }
            if old.playState != new.playState { changes.insert(.episode(id, "play_state")) }
            if old.favorite != new.favorite { changes.insert(.episode(id, "favorite")) }
            if old.position != new.position { changes.insert(.episode(id, "position")) }
            if old.playedDuration != new.playedDuration { changes.insert(.episode(id, "played_time")) }
            if old.lastPlayed != new.lastPlayed { changes.insert(.episode(id, "last_played")) }
            if old.history != new.history { changes.insert(.episode(id, "history")) }
        }
        for id in b.episodes.keys where a.episodes[id] == nil { changes.insert(.episodeInserted(id)) }
        for (id, old) in a.feeds {
            guard let new = b.feeds[id] else { changes.insert(.feedDeleted(id)); continue }
            if old.subscription != new.subscription { changes.insert(.feed(id, "subscription")) }
            if old.keepUpdated != new.keepUpdated { changes.insert(.feed(id, "keep_updated")) }
            if old.newEpisodesAction != new.newEpisodesAction { changes.insert(.feed(id, "new_episodes_action")) }
            if !old.source.utf8.elementsEqual(new.source.utf8) { changes.insert(.feed(id, "refresh_url")) }
        }
        for id in b.feeds.keys where a.feeds[id] == nil { changes.insert(.feedInserted(id)) }
        for id in Set(a.credentials.keys).union(b.credentials.keys) where a.credentials[id] != b.credentials[id] { changes.insert(.credentials(id)) }
        let before = Set(a.queue), after = Set(b.queue)
        for id in b.queue where !before.contains(id) { changes.insert(.queueIn(id)) }
        for id in a.queue where !after.contains(id) { changes.insert(.queueOut(id)) }
        if a.queue.filter(after.contains) != b.queue.filter(before.contains) { changes.insert(.queueOrder) }
        return changes
    }

    /// What one recorded fact or draft explains: its payload's local episodes and podcast, with its fixed effects.
    private func explained(type: String, episodes: [Int64], feed: Int64?, state: State) -> Set<Change> {
        var result = Set<Change>()
        func each(_ fields: [String]) { for id in episodes { for field in fields { result.insert(.episode(id, field)) } } }
        switch type {
        case "episode.mark_played", "episode.mark_unplayed", "episode.reset_position", "episode.restore_state": each(["play_state", "position"])
        case "inbox.dismiss", "inbox.dismiss_all": each(["play_state"])
        case "favorite.set": each(["favorite"])
        case "queue.add", "queue.restore":
            each(["play_state"]); for id in episodes { result.insert(.queueIn(id)) }; result.insert(.queueOrder)
        case "queue.remove", "queue.clear": for id in episodes { result.insert(.queueOut(id)) }
        case "queue.move", "queue.reorder": result.insert(.queueOrder)
        case "history.remove", "history.restore": each(["history"])
        case "history.clear": for id in state.episodes.keys { result.insert(.episode(id, "history")) }
        case "statistics.reset": for id in state.episodes.keys { result.insert(.episode(id, "played_time")) }
        case "podcast.subscribe", "podcast.register_preview":
            if let feed {
                result.formUnion([.feedInserted(feed), .feed(feed, "subscription"), .feed(feed, "keep_updated")])
                // The first population of a new subscription is never proposed (PROTOCOL §15.2).
                for (id, owner) in state.episodeFeed where owner == feed { result.insert(.episodeInserted(id)) }
            }
        case "podcast.unsubscribe":
            if let feed {
                result.formUnion([.feedDeleted(feed), .credentials(feed)])
                for (id, owner) in state.episodeFeed where owner == feed { result.formUnion([.episodeDeleted(id), .queueOut(id)]) }
            }
        case "podcast.archive", "podcast.restore": if let feed { result.insert(.feed(feed, "subscription")) }
        case "podcast.set_policy": if let feed { result.formUnion([.feed(feed, "keep_updated"), .feed(feed, "new_episodes_action")]) }
        case "podcast.set_credentials": if let feed { result.insert(.credentials(feed)) }
        case "podcast.change_url": if let feed { result.insert(.feed(feed, "refresh_url")) }
        // A release's filing (PROTOCOL §9.5): NEW, or a queue filing with its placement.
        case "discovery.propose":
            each(["play_state"]); for id in episodes { result.insert(.queueIn(id)) }; result.insert(.queueOrder)
        default: break
        }
        return result
    }

    private func allowedWithoutFact(_ change: Change, owner: Owner) -> Bool {
        switch (owner, change) {
        case (.remote, _): true
        case (.previewCleanup, .feedDeleted), (.previewCleanup, .credentials), (.previewCleanup, .episodeDeleted), (.previewCleanup, .queueOut): true
        case (.playback, .episode(_, let field)): ["position", "last_played", "history", "played_time", "play_state"].contains(field)
        case (.playback, .queueOut): true
        // A refresh's filings are proposals (PROTOCOL §9.5); a permanent redirect records nothing (PROTOCOL §9.7).
        case (.refresh, .episodeInserted), (.refresh, .episodeDeleted),
             (.refresh, .feed(_, "refresh_url")), (.refresh, .queueOut), (.refresh, .queueOrder): true
        case (.discoveryQueue, .queueOrder): true
        default: false
        }
    }

    // MARK: Mutators

    private func pick<T>(_ list: [T], _ random: inout Random) -> T? { list.isEmpty ? nil : list[Int.random(in: 0..<list.count, using: &random)] }

    private func mutators() -> [Mutator] {
        func episode(_ f: ServerLibraryFixture, _ r: inout Random) async throws -> Int64? {
            pick(try await f.store.syncedStateForTesting().episodes.keys.sorted(), &r)
        }
        func episodes(_ f: ServerLibraryFixture, _ r: inout Random) async throws -> [Int64] {
            let all = try await f.store.syncedStateForTesting().episodes.keys.sorted()
            return all.filter { _ in Bool.random(using: &r) }
        }
        func feed(_ f: ServerLibraryFixture, _ r: inout Random) async throws -> Int64? {
            pick(try await f.store.syncedStateForTesting().feeds.keys.sorted(), &r)
        }
        func queued(_ f: ServerLibraryFixture, _ r: inout Random) async throws -> Int64? { pick(try await f.store.queue().map(\.id), &r) }
        return [
            Mutator(name: "insert", owner: .refresh) { f, r, c in
                c.feedCount += 1
                _ = try await f.store.insert(ServerLibraryFixture.fetched("https://example.test/feed-\(c.feedCount).xml", title: "Feed \(c.feedCount)",
                                                                          count: Int.random(in: 1...4, using: &r)))
            },
            Mutator(name: "preparePreview", owner: .refresh) { f, r, c in
                c.feedCount += 1
                _ = try await f.store.preparePreview(ServerLibraryFixture.fetched("https://example.test/preview-\(c.feedCount).xml", title: "Preview \(c.feedCount)"),
                                                     now: ServerLibraryFixture.now)
            },
            Mutator(name: "subscribePreview", owner: .recorded) { f, r, _ in if let id = try await feed(f, &r) { _ = try await f.store.subscribePreview(feedID: id) } },
            Mutator(name: "applyRefresh", owner: .refresh) { f, r, _ in
                guard let id = try await feed(f, &r), let source = try await f.store.feed(id: id)?.source, !source.isLocalFeedSource else { return }
                _ = try await f.store.applyRefresh(ServerLibraryFixture.fetched(source, title: "R\(id)", count: Int.random(in: 1...6, using: &r)), feedID: id,
                                                   options: .init(now: ServerLibraryFixture.now.addingTimeInterval(86_400 * 10)))
            },
            Mutator(name: "updateEpisode", owner: .recorded) { f, r, _ in
                guard let id = try await episode(f, &r) else { return }
                let which = Int.random(in: 0..<3, using: &r)
                try await f.store.updateEpisode(id: id) { e in
                    switch which { case 0: e.userState.isFavorite.toggle(); case 1: e.userState.playState = .played; default: e.userState.positionMilliseconds += 1_000 }
                }
            },
            Mutator(name: "setFavorite", owner: .recorded) { f, r, _ in try await f.store.setFavorite(episodeIDs: try await episodes(f, &r), favorite: Bool.random(using: &r)) },
            Mutator(name: "removeFeedFromInbox", owner: .recorded) { f, r, _ in if let id = try await feed(f, &r) { _ = try await f.store.removeFeedFromInbox(feedID: id) } },
            Mutator(name: "removeAllFromInbox", owner: .recorded) { f, _, _ in _ = try await f.store.removeAllFromInbox() },
            Mutator(name: "clearPlaybackHistory", owner: .recorded) { f, _, _ in _ = try await f.store.clearPlaybackHistory() },
            Mutator(name: "applySwipeMark", owner: .recorded) { f, r, c in
                guard let id = try await episode(f, &r) else { return }
                if let receipt = try await f.store.applySwipeMark(episodeID: id, action: Bool.random(using: &r) ? .togglePlayed : .removeInbox) { c.markReceipts.append(receipt) }
            },
            Mutator(name: "undoSwipeMark", owner: .recorded) { f, r, c in if let receipt = pick(c.markReceipts, &r) { _ = try await f.store.undoSwipeMark(receipt) } },
            Mutator(name: "removeEpisodesFromInbox", owner: .recorded) { f, r, _ in try await f.store.removeEpisodesFromInbox(episodeIDs: try await episodes(f, &r)) },
            Mutator(name: "markEpisodesPlayed", owner: .recorded) { f, r, _ in
                try await f.store.markEpisodesPlayed(episodeIDs: try await episodes(f, &r), played: Bool.random(using: &r), resetPosition: Bool.random(using: &r))
            },
            Mutator(name: "resetPlaybackPosition", owner: .recorded) { f, r, _ in if let id = try await episode(f, &r) { try await f.store.resetPlaybackPosition(episodeID: id) } },
            Mutator(name: "enqueue", owner: .recorded) { f, r, _ in
                let locations: [EnqueueLocation] = [.back, .front, .afterCurrentlyPlaying, .random]
                _ = try await f.store.enqueue(try await episodes(f, &r), location: pick(locations, &r) ?? .back)
            },
            Mutator(name: "keepSorted", owner: .recorded) { f, r, _ in
                f.store.setQueueInsertionSettings(.init(keepSortedOrder: Bool.random(using: &r) ? pick(QueueSortOrder.allCases, &r) : nil))
                _ = try await f.store.enqueueUsingSettings(try await episodes(f, &r))
            },
            Mutator(name: "reorderQueue", owner: .recorded) { f, r, _ in _ = try await f.store.reorderQueue(pick(QueueSortOrder.allCases, &r) ?? .dateNewOld) },
            Mutator(name: "removeFromQueueWithUndo", owner: .recorded) { f, r, c in
                if let id = try await queued(f, &r), let receipt = try await f.store.removeFromQueueWithUndo(id).receipt { c.queueReceipts.append(receipt) }
            },
            Mutator(name: "undoQueueRemoval", owner: .recorded) { f, r, c in if let receipt = pick(c.queueReceipts, &r) { _ = try await f.store.undoQueueRemoval(receipt) } },
            Mutator(name: "removeFromPlaybackHistoryWithUndo", owner: .recorded) { f, r, c in
                if let id = try await episode(f, &r), let receipt = try await f.store.removeFromPlaybackHistoryWithUndo(id) { c.historyReceipts.append(receipt) }
            },
            Mutator(name: "undoHistoryRemoval", owner: .recorded) { f, r, c in if let receipt = pick(c.historyReceipts, &r) { _ = try await f.store.undoHistoryRemoval(receipt) } },
            Mutator(name: "removeFromQueue", owner: .recorded) { f, r, _ in if let id = try await queued(f, &r) { _ = try await f.store.removeFromQueue([id]) } },
            Mutator(name: "performQueueMove", owner: .recorded) { f, r, _ in
                let queue = try await f.store.queue()
                guard let id = pick(queue.map(\.id), &r) else { return }
                let move: QueueManualMove = Bool.random(using: &r) ? .item(id, finalIndex: Int.random(in: 0..<queue.count, using: &r))
                    : .boundary(queue.map(\.id).filter { _ in Bool.random(using: &r) }, Bool.random(using: &r) ? .top : .bottom)
                _ = try await f.store.performQueueMove(move, expected: queue.map(QueueEpisodeIdentity.init))
            },
            Mutator(name: "clearQueue", owner: .recorded) { f, _, _ in _ = try await f.store.clearQueue() },
            Mutator(name: "consumeFeedRefreshQueueEffects", owner: .discoveryQueue) { f, _, _ in _ = try await f.store.consumeFeedRefreshQueueEffects() },
            Mutator(name: "requestDownload", owner: .recorded) { f, r, _ in
                if let id = try await episode(f, &r) { _ = try await f.store.requestDownload(episodeID: id, directory: f.directory, enqueue: Bool.random(using: &r)) }
            },
            Mutator(name: "cancelDownload", owner: .recorded) { f, r, _ in
                if let job = pick(try await f.store.downloadJobs(), &r) { _ = try await f.store.cancelDownload(id: job.id, deleteRemovesFromQueue: Bool.random(using: &r)) }
            },
            Mutator(name: "requestMediaDeletion", owner: .recorded) { f, r, _ in
                guard let id = try await episode(f, &r), try await f.store.episode(id: id)?.details.media != nil,
                      let feedID = try? await f.store.feedID(forEpisode: id), try await f.store.feed(id: feedID)?.source.isLocalFeedSource == false,
                      try await f.store.downloadJobs().allSatisfy({ $0.episodeID != id }) else { return }
                try await f.store.requestMediaDeletion(episodeID: id, deleteRemovesFromQueue: Bool.random(using: &r))
            },
            Mutator(name: "beginPlayback", owner: .playback) { f, r, c in
                guard let id = try await episode(f, &r), try await f.store.episode(id: id)?.details.media != nil else { return }
                c.session = try await f.store.beginPlayback(episodeID: id)
            },
            Mutator(name: "recordPlayback", owner: .playback) { f, r, c in
                guard let session = c.session else { return }
                _ = try await f.store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: Int32.random(in: 0...600_000, using: &r),
                                                                                          durationMilliseconds: 600_000, status: .playing), synchronize: Bool.random(using: &r))
            },
            Mutator(name: "endPlayback", owner: .playback) { f, r, c in
                guard let session = c.session else { return }
                _ = try await f.store.endPlayback(sessionID: session.id, reason: pick([PlaybackEndReason.ended, .skipped, .switched], &r) ?? .ended)
                c.session = nil
            },
            Mutator(name: "resetPlayedDurationStatistics", owner: .recorded) { f, _, _ in try await f.store.resetPlayedDurationStatistics() },
            Mutator(name: "requestFeedDeletion", owner: .recorded) { f, r, _ in if let id = try await feed(f, &r) { _ = try await f.store.requestFeedDeletion(feedID: id) } },
            Mutator(name: "requestExpiredFeedDeletions", owner: .previewCleanup) { f, _, _ in
                _ = try await f.store.requestExpiredFeedDeletions(expiredAt: ServerLibraryFixture.now.addingTimeInterval(86_400 * 400))
            },
            Mutator(name: "updatePreferences", owner: .recorded) { f, r, _ in
                guard let id = try await feed(f, &r) else { return }
                let which = Int.random(in: 0..<5, using: &r)
                try await f.store.updatePreferences(feedID: id) { p in
                    switch which {
                    case 0: p.keepUpdated.toggle()
                    case 1: p.newEpisodesAction = .queue
                    case 2: p.subscriptionState = p.subscriptionState == .archived ? .subscribed : .archived
                    case 3: p.tags = ["t"]
                    default: p.subscriptionState = .notSubscribed
                    }
                }
            },
            Mutator(name: "applyBulk", owner: .recorded) { f, r, _ in
                let ids = try await f.store.syncedStateForTesting().feeds.keys.sorted().filter { _ in Bool.random(using: &r) }
                try await f.store.applyBulk(.keepUpdated(Bool.random(using: &r)), feedIDs: ids)
            },
            Mutator(name: "removeFeedsFromInbox", owner: .recorded) { f, r, _ in
                _ = try await f.store.removeFeedsFromInbox(feedIDs: try await f.store.syncedStateForTesting().feeds.keys.sorted().filter { _ in Bool.random(using: &r) })
            },
            Mutator(name: "updateFeedDownloadURL", owner: .recorded) { f, r, c in
                guard let id = try await feed(f, &r), let source = try await f.store.feed(id: id)?.source, !source.isLocalFeedSource else { return }
                c.feedCount += 1
                _ = try await f.store.updateFeedDownloadURL(original: source, updated: "https://example.test/moved-\(c.feedCount).xml")
            },
            Mutator(name: "credentials", owner: .recorded) { f, r, _ in
                guard let id = try await feed(f, &r) else { return }
                try await FeedAuthentication(store: f.store, vault: f.vault).save(.init(username: Bool.random(using: &r) ? "u" : "", password: "p"), feedID: id)
            },
            Mutator(name: "accountPolicy", owner: .recorded) { f, r, _ in try await f.store.setServerAccountPolicy(.enqueueLocation(pick(EnqueueLocation.allCases, &r) ?? .back)) },
            Mutator(name: "projectNew", owner: .remote) { f, r, _ in
                // Pulled records (`.remote`) bring NEW filings, history and played time to dismiss, clear and reset.
                guard let id = try await episode(f, &r) else { return }
                let value = Int64.random(in: 1...100_000, using: &r)
                try await f.store.projectForTesting(id) { $0.userState.playState = .new; $0.userState.lastPlayedHistoryMilliseconds = value; $0.userState.playedDurationMilliseconds = value }
            },
            Mutator(name: "resolve", owner: .recorded) { f, r, _ in
                guard let op = pick(try f.rows("SELECT op_id FROM ntp_registrations WHERE state = 'pending'").compactMap { $0[0] }, &r) else { return }
                let ids = try f.created(op)
                try await f.store.resolveRegistration(opID: op, .init(podcastID: ids.podcast, generationID: ids.generation, mode: "created", decisionID: nil))
            },
            Mutator(name: "registerLocalFolder", owner: .recorded) { f, _, c in
                c.feedCount += 1
                _ = try await f.store.registerLocalFolder(title: "Folder \(c.feedCount)", directoryIdentity: "folder-\(c.feedCount)", bookmark: Data([1]))
            },
        ]
    }

    @Test(arguments: [1, 2, 3, 4, 5, 6]) func everySyncedChangeHasAFact(_ seed: Int) async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        var random = Random(state: UInt64(seed) &* 1_000_003)
        let context = Context()
        let list = mutators()
        var exercised: [String: Int] = [:], failures: [String: Int] = [:]
        for _ in 0..<2 { try await list[0].run(fixture, &random, context); try await list[1].run(fixture, &random, context) }
        for step in 0..<180 {
            guard let mutator = pick(list, &random) else { continue }
            let before = try await state(fixture)
            let outbox = Set(try fixture.outbox().map(\.opID)), drafts = Set(try fixture.drafts().map(\.opID))
            let bindings = try await fixture.store.bindingsForTesting()
            var failed: Error?
            do { try await mutator.run(fixture, &random, context) } catch { failed = error }
            let after = try await state(fixture)
            let changes = diff(before, after)
            if let failed {
                #expect(changes.isEmpty, "seed \(seed) step \(step) \(mutator.name) failed with \(failed) but changed \(changes)")
                // Only a write the intent cannot map, or an action refused for its arguments (as in a standalone
                // library), may fail; the recorder must never fail an action a person can take.
                switch failed {
                case ServerRecordingError.unmappedChange(let intent, _):
                    #expect(["updateEpisode", "updatePreferences"].contains(mutator.name) && intent == "registers",
                            "seed \(seed) step \(step) \(mutator.name): \(failed)")
                case is FeedLibraryError: break
                default: Issue.record("seed \(seed) step \(step) \(mutator.name) failed: \(failed)")
                }
                failures[mutator.name, default: 0] += 1
                continue
            }
            exercised[mutator.name, default: 0] += 1
            // Facts and drafts this call recorded (a materialization turns drafts into facts: not new).
            var recorded: [(type: String, episodes: [Int64], feed: Int64?)] = []
            for fact in try fixture.outbox() where !outbox.contains(fact.opID) && !drafts.contains(fact.opID) {
                recorded.append((fact.type, try await fixture.store.localEpisodesForTesting(fact.json), try await fixture.store.localFeedForTesting(fact.json)))
            }
            for draft in try fixture.drafts() where !drafts.contains(draft.opID) {
                recorded.append((draft.type, try await fixture.store.localEpisodesForTesting(draft.template),
                                 try await fixture.store.localFeedForTesting(draft.template, registration: draft.registration)))
            }
            var explanation = Set<Change>()
            let union = State(episodes: before.episodes.merging(after.episodes) { a, _ in a },
                              episodeFeed: before.episodeFeed.merging(after.episodeFeed) { a, _ in a })
            for fact in recorded { explanation.formUnion(explained(type: fact.type, episodes: fact.episodes, feed: fact.feed, state: union)) }
            for change in changes where !explanation.contains(change) && !allowedWithoutFact(change, owner: mutator.owner) {
                // Local folders and previews the account does not know stay local by design.
                let feed: Int64? = switch change {
                case .episode(let id, _), .episodeInserted(let id), .episodeDeleted(let id), .queueIn(let id), .queueOut(let id): union.episodeFeed[id]
                case .feed(let id, _), .feedInserted(let id), .feedDeleted(let id), .credentials(let id): id
                case .queueOrder: nil
                }
                if let feed, (bindings[feed] ?? .unregistered) == .unregistered || bindings[feed] == .localFolder { continue }
                if change == .queueOrder, try await queueOrderChangeIsDeviceOnly(before.queue, after.queue, fixture) { continue }
                Issue.record("seed \(seed) step \(step) \(mutator.name): \(change) without a fact (recorded \(recorded.map(\.type)))")
            }
            #expect(try fixture.queueOrderMatchesKeys(), "seed \(seed) step \(step) \(mutator.name): queue order differs from key order")
        }
        #expect(exercised.count > 25, "seed \(seed) exercised \(exercised.keys.sorted())")
    }

    private func queueOrderChangeIsDeviceOnly(_ a: [Int64], _ b: [Int64], _ fixture: ServerLibraryFixture) async throws -> Bool {
        let local = try await fixture.store.deviceOnlyEpisodesForTesting()
        let before = Set(a), after = Set(b)
        return a.filter { after.contains($0) && !local.contains($0) } == b.filter { before.contains($0) && !local.contains($0) }
    }
}

extension FeedLibraryStore {
    func syncedStateForTesting() throws -> ServerRecordingCoverageTests.State {
        var state = ServerRecordingCoverageTests.State()
        try database.transaction(write: false) {
            for feed in try loadFeeds() {
                state.feeds[feed.id] = SyncedFeed(feed)
                for episode in feed.episodes { state.episodes[episode.id] = SyncedEpisode(episode); state.episodeFeed[episode.id] = feed.id }
            }
            state.queue = try queueEpisodeIDs()
            for row in try database.rows("SELECT feed_id, credential_id FROM feed_credentials") {
                if let id = row[0].integer, case .text(let credential) = row[1] { state.credentials[id] = credential }
            }
        }
        return state
    }

    /// How each local feed is known to the account now.
    func bindingsForTesting() throws -> [Int64: PodcastBinding] {
        guard let context = serverContext else { return [:] }
        let session = RecordingSession(intent: .local, capture: ChangeCapture(clientTime: Date()),
                                       writer: ServerOutboxWriter(database: database, context: context, failAfter: nil), clientTime: 0, now: 0)
        var result: [Int64: PodcastBinding] = [:]
        for row in try database.rows("SELECT id FROM feeds") { if let id = row[0].integer { result[id] = try binding(id, session) } }
        return result
    }

    func deviceOnlyEpisodesForTesting() throws -> Set<Int64> {
        var result = Set<Int64>()
        for feed in try loadFeeds() where feed.source.isLocalFeedSource { result.formUnion(feed.episodes.map(\.id)) }
        return result
    }

    /// The local episodes a fact or draft template names.
    func localEpisodesForTesting(_ json: ContractJSON) throws -> [Int64] {
        var result: [Int64] = []
        func walk(_ value: ContractJSON) throws {
            switch value {
            case .object(let object):
                if let local = object["ntp_local_episode"]?.integerValue { result.append(local); return }
                if let wire = object["episode_id"]?.stringValue,
                   let row = try database.rows("SELECT local_id FROM ntp_episodes WHERE episode_id = ?", [.text(wire)]).first, let id = row[0].integer {
                    result.append(id); return
                }
                for member in object.members { try walk(member.value) }
            case .array(let items): for item in items { try walk(item) }
            default: break
            }
        }
        try walk(json["payload"] ?? .null)
        return result
    }

    /// The local feed a podcast-level fact or draft names.
    func localFeedForTesting(_ json: ContractJSON, registration: String? = nil) throws -> Int64? {
        if let registration, json["targets"]?.arrayValue?.contains(where: { $0["ntp_registration"] != nil }) == true {
            return try database.rows("SELECT feed_id FROM ntp_registrations WHERE op_id = ?", [.text(registration)]).first?.first?.integer
        }
        if let type = json["type"]?.stringValue, type == "podcast.subscribe" || type == "podcast.register_preview", let op = json["op_id"]?.stringValue {
            return try database.rows("SELECT feed_id FROM ntp_registrations WHERE op_id = ?", [.text(op)]).first?.first?.integer
        }
        for target in json["targets"]?.arrayValue ?? [] where target["entity"]?.stringValue == "podcast" {
            if let id = target["id"]?.stringValue {
                return try database.rows("SELECT feed_id FROM ntp_podcasts WHERE podcast_id = ?", [.text(id)]).first?.first?.integer
            }
        }
        return nil
    }
}
