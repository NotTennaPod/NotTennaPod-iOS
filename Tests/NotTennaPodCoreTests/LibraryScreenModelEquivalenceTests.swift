import Foundation
import Testing
@testable import NotTennaPodCore

/// The incremental screen model against a fresh full read after every step of long seeded sequences of real store
/// operations: the patched mirror equals `snapshot()` (feeds, episodes, queue, deletion targets, statistics units) and its
/// own counts, and every incrementally kept list (Inbox in both sorts, Episodes under sampled filters and sorts,
/// Favorites, History, two podcasts' own lists, Queue and Downloads) equals the frozen full-reload reference
/// (`FullReloadReference`), as do the Inbox badge and the drawer counters.
///
/// S: 2,000 episodes, 12 seeds × 300 steps, standalone and server libraries. L (`NTP_SCALE=1`, release): 54,000 and
/// 100,000 episodes, 2 seeds × 120 steps.
@Suite(.serialized) struct LibraryScreenModelEquivalenceTests {
    typealias Random = ServerChangeSetCaptureTests.Random

    enum Op: String, CaseIterable {
        case played, unplayed, bulkPlayed, favorite, bulkFavorite, inboxOne, inboxFeed, inboxAll, enqueue, dequeue, move, sortQueue,
             clearQueue, download, downloadFinish, cancelDownload, deleteDownload, listen, historyRemove, historyClear,
             statisticsReset, randomize, dateTie, subscribe, archive, unsubscribe, feedFilter, feedSort, refreshAdd, refreshRemove,
             refreshChange, refreshUnchanged, pin, unpin, hideFeed, revealFeed, hideEpisode, revealEpisode,
             heldRemoval, reAdd, releaseHeld
    }

    /// One library with its screen model kept incrementally, and the checks against a fresh read.
    final class World: @unchecked Sendable {
        let directory: URL
        let store: FeedLibraryStore
        let server: Bool
        var random: Random
        var mirror = LibraryScreenMirror()
        /// The keyed reads of what the mirror's list projections leave out (show notes for a search's text).
        var detail: LibraryDetailReader?
        var iterator: AsyncStream<LibraryChangeSet>.Iterator
        var seen: Int64
        var indexes: [EpisodeListIndex] = []
        var player: StorePlayer
        var sources: [Int64: (source: String, count: Int, offset: Int, title: String)] = [:]
        var pinned: Set<Int64> = [], hiddenFeeds: Set<Int64> = [], hiddenEpisodes: Set<Int64> = []
        var coverage: [String: Int] = [:]
        var problems: [String] = []
        var trace: [String] = []
        var feedCount = 0
        /// Server libraries: the fixture, an applier of server units, and the podcasts registered with the server (their
        /// feed, live generation, and whether the server removed them).
        var fixture: ServerLibraryFixture?
        var applier: ServerProjectionUnitTests.Applier?
        var podcasts: [(podcast: String, generation: String, feed: Int64, removed: Bool)] = []
        var jobs: [LibraryDownloadJob] = []
        /// The lists' chunk capacity (small in the sequences, so chunks split and merge often).
        var capacity = 16
        /// Further screen models kept from the same patches and checked at every step (Home, Subscriptions, search).
        var observers: [any ScreenModelObserver] = []

        static let specs: [EpisodeListSpec] = [
            .inbox(.dateNewest), .inbox(.durationShortest), .favorites(.dateOldest), .history,
            .episodes(.init(), .dateNewest), .episodes(.init(.init(values: ["unplayed", "not_queued"])), .durationLongest),
            .episodes(.init(.init(values: ["is_favorite"])), .dateOldest),
            .episodes(.init(.init(values: ["queued", "has_media", "include_archived", "include_not_subscribed"])), .dateNewest),
            .episodes(.init(.init(values: ["paused", "downloaded"])), .durationShortest),
            .episodes(.init(.init(values: ["played", "not_downloaded", "include_subscribed", "include_archived"])), .dateNewest),
        ]

        init(directory: URL, store: FeedLibraryStore, server: Bool, seed: UInt64) async throws {
            self.directory = directory; self.store = store; self.server = server
            random = Random(state: seed)
            let subscription = store.changes.subscribe()
            iterator = subscription.changes.makeAsyncIterator()
            seen = subscription.baseline
            player = StorePlayer(store)
        }

        static func make(server: Bool, seed: UInt64, feeds: Int, episodesPerFeed: Int) async throws -> World {
            let directory: URL, store: FeedLibraryStore
            var serverFixture: ServerLibraryFixture?
            if server {
                let fixture = try await ServerLibraryFixture()
                serverFixture = fixture
                (directory, store) = (fixture.directory, fixture.store)
            } else {
                directory = try EpisodeListKeysTests.directory()
                store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
            }
            let world = try await World(directory: directory, store: store, server: server, seed: seed)
            for number in 0..<feeds { try await world.subscribe(number: number, count: episodesPerFeed + number % 5) }
            if let fixture = serverFixture {
                // Podcasts the server knows, which it can remove while the player holds one of their episodes.
                for number in 0..<3 {
                    let registered = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/held\(number).xml",
                                                                                                       title: "Held \(number)", count: 8, guidPrefix: "held\(number)-"))
                    world.podcasts.append((registered.podcast, registered.generation, registered.feed.id, false))
                }
                world.fixture = fixture
                world.applier = try await ServerProjectionUnitTests.Applier(fixture)
            }
            try await world.open()
            return world
        }

        func close() async {
            try? await store.close()
            try? FileManager.default.removeItem(at: directory)
        }

        func note(_ label: String) { coverage[label, default: 0] += 1 }

        // MARK: Screens

        /// A fresh open: the mirror and every list read in full.
        func open() async throws {
            _ = try await drain()
            let open = try await store.screenSnapshot()
            mirror = LibraryScreenMirror(open)
            detail = try await store.readers().detail
            seen = max(seen, open.sequence)
            jobs = try await store.downloadJobs()
            openIndexes()
            for observer in observers { observer.opened(self) }
        }

        func openIndexes() {
            let candidates = mirror.feeds.flatMap { feed in feed.episodes.map { (feed: feed, episode: $0) } }
            var specs = Self.specs
            for feed in mirror.feeds.prefix(2) { specs.append(.feed(feed, globalSort: .dateNewest)) }
            indexes = specs.map { EpisodeListIndex(spec: $0, candidates: candidates, queued: mirror.queuedIDs, capacity: capacity) }
        }

        func drain() async throws -> [LibraryChangeSet] {
            var sets: [LibraryChangeSet] = []
            while seen < store.changes.emitted, let set = await iterator.next() {
                seen = set.sequence
                sets.append(set)
            }
            return sets
        }

        /// The incremental patch of everything committed since the last one.
        func patch() async throws {
            let sets = try await drain().filter { $0.sequence > mirror.sequence }
            guard !sets.isEmpty else { return }
            let request = mirror.request(for: sets)
            let read = try await store.mirrorRead(request)
            #expect(read.sequence == sets.last!.sequence, "the read saw exactly the delivered commits")
            let queued = mirror.queuedIDs
            let delta = mirror.apply(read)
            #expect(delta.queueMembers == queued.symmetricDifference(mirror.queuedIDs), "the patch names exactly who joined or left the queue")
            for observer in observers { observer.patched(delta, self) }
            if !request.resetFeeds.isEmpty { note("patch feed reset") }
            if delta.queue { note("patch queue") }
            jobs = try await store.downloadJobs()
            for index in indexes.indices {
                if case .feed(let id, _, _) = indexes[index].spec {
                    guard let feed = mirror.feed(id) else {
                        indexes[index] = EpisodeListIndex(spec: indexes[index].spec, candidates: [], queued: [], capacity: capacity)
                        continue
                    }
                    // A podcast's filter or sort changed: its list opens again, as the page reloads it.
                    if EpisodeListSpec.feed(feed, globalSort: .dateNewest) != indexes[index].spec {
                        indexes[index] = EpisodeListIndex(spec: .feed(feed, globalSort: .dateNewest),
                            candidates: feed.episodes.map { (feed: feed, episode: $0) }, queued: mirror.queuedIDs, capacity: capacity)
                        note("reopen feed spec")
                        continue
                    }
                }
                let change = indexes[index].apply(delta, mirror: mirror)
                if !change.removed.isEmpty && !change.inserted.isEmpty { note("list move") }
                else if !change.removed.isEmpty { note("list remove") }
                else if !change.inserted.isEmpty { note("list insert") }
            }
        }

        func check(_ label: String) async throws {
            // The mirror holds list projections: it equals the whole read's projection; observers judge their
            // screens against the whole read.
            let whole = try await store.snapshot()
            let snapshot = whole.listProjection
            var found: [String] = mirror.inconsistencies()
            if mirror.feeds.map(\.id) != snapshot.feeds.map(\.id) { found.append("feed order") }
            for (mine, theirs) in zip(mirror.feeds, snapshot.feeds) where mine != theirs {
                found.append("feed \(theirs.id): \(mine.episodes.map(\.id) == theirs.episodes.map(\.id) ? "values" : "episodes")")
            }
            if mirror.queue != snapshot.queue { found.append("queue") }
            if mirror.deletionTargets != snapshot.deletionTargets { found.append("deletion targets") }
            if mirror.statisticsUnits != snapshot.statisticsUnits { found.append("statistics units") }
            let queued = Set(snapshot.queue.map(\.id))
            for index in indexes {
                let expected: [Int64]
                switch index.spec {
                case .inbox(let sort): expected = FullReloadReference.inbox(snapshot.feeds, sort: sort).map(\.episode.id)
                case .favorites(let sort): expected = FullReloadReference.favorites(snapshot.feeds, sort: sort).map(\.episode.id)
                case .history: expected = FullReloadReference.history(snapshot.feeds).map(\.episode.id)
                case .episodes(let filter, let sort):
                    expected = FullReloadReference.allEpisodesRows(snapshot.feeds, queuedEpisodes: snapshot.queue, filter: filter, sort: sort).map(\.episode.id)
                case .feed(let id, _, _):
                    expected = snapshot.feeds.first { $0.id == id }.map { FullReloadReference.filteredDisplayEpisodes($0, queuedIDs: queued).map(\.id) } ?? []
                }
                if index.allIDs != expected { found.append("list \(index.spec): \(index.allIDs.count) vs \(expected.count)") }
            }
            for order in [nil, FeedEpisodeSortOrder.titleAscending, .durationLongest, .sizeSmallest] {
                if mirror.downloads(jobs: jobs, order: order) != FullReloadReference.downloadsRows(snapshot.feeds, jobs: jobs, order: order) {
                    found.append("downloads \(String(describing: order))")
                }
            }
            if mirror.inboxCount != FullReloadReference.inboxCount(snapshot.feeds) { found.append("inbox badge") }
            for counter in FeedCounter.allCases where mirror.counters(counter) != FullReloadReference.counters(snapshot.feeds, counter) {
                found.append("counters \(counter)")
            }
            for observer in observers { found += observer.check(whole, self) }
            if !found.isEmpty {
                problems.append("\(label): " + found.prefix(8).joined(separator: "; ") + "\n  trace: " + trace.suffix(6).joined(separator: " | "))
            }
        }

        // MARK: Operations

        func shownEpisodes() -> [Int64] { mirror.feeds.flatMap { $0.episodes.map(\.id) } }
        func pick<T>(_ values: [T]) -> T? { random.pick(values) }

        func subscribe(number: Int, count: Int) async throws {
            let source = "https://example.test/screen\(number).xml"
            let title = ["Alpha", "beta", "Gamma", "ALPHA", "é", "e\u{301}", "Zeta"][number % 7] + " \(number / 7)"
            let feed = try await store.insert(EpisodeListKeysTests.fetched(source, title: title, count: count, offset: number * 10_000),
                                              options: .init(now: EpisodeListKeysTests.now))
            sources[feed.id] = (source, count, number * 10_000, title)
            feedCount = max(feedCount, number + 1)
        }

        func perform(_ op: Op) async throws -> Bool {
            let ids = shownEpisodes()
            guard let episode = pick(ids) else { return false }
            let feeds = mirror.feeds.map(\.id)
            switch op {
            case .played, .unplayed: try await store.markEpisodePlayed(episodeID: episode, played: op == .played)
            case .bulkPlayed:
                let chosen = Array(Set((0..<(2 + random.below(20))).compactMap { _ in pick(ids) })).sorted()
                try await store.markEpisodesPlayed(episodeIDs: chosen, played: random.chance(50))
            case .favorite: try await store.setFavorite(episodeID: episode, favorite: random.chance(60))
            case .bulkFavorite:
                let chosen = Array(Set((0..<(2 + random.below(10))).compactMap { _ in pick(ids) })).sorted()
                try await store.setFavorite(episodeIDs: chosen, favorite: random.chance(50))
            case .inboxOne: try await store.removeEpisodeFromInbox(episodeID: episode)
            case .inboxFeed: _ = try await store.removeFeedFromInbox(feedID: pick(feeds)!)
            case .inboxAll: _ = try await store.removeAllFromInbox()
            case .enqueue:
                let chosen = Array(Set((0..<(1 + random.below(4))).compactMap { _ in pick(ids) })).sorted()
                _ = try await store.enqueue(chosen, location: random.chance(50) ? .back : .front)
            case .dequeue:
                guard let item = pick(try await store.queue()) else { return false }
                _ = try await store.removeFromQueue([item.id])
            case .move:
                let queue = try await store.queue()
                guard queue.count >= 2, let item = pick(queue) else { return false }
                _ = try await store.performQueueMove(.item(item.id, finalIndex: random.below(queue.count)), expected: queue.map(QueueEpisodeIdentity.init))
            case .sortQueue: _ = try await store.reorderQueue(pick(QueueSortOrder.allCases) ?? .dateOldNew)
            case .clearQueue: _ = try await store.clearQueue()
            case .download:
                _ = try await store.requestDownload(episodeID: episode, directory: directory.appendingPathComponent("downloads"), enqueue: random.chance(30))
            case .downloadFinish:
                guard let job = pick(try await store.downloadJobs().filter { $0.state.isActive }),
                      let attempt = try await store.beginDownloadAttempt(id: job.id) else { return false }
                try FileManager.default.createDirectory(at: attempt.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 0x41, count: 100).write(to: attempt.destination)
                guard try await store.attachDownloadFile(id: job.id, attempt: attempt.attempts) else { return false }
                _ = try await store.completeDownload(id: job.id, attempt: attempt.attempts)
            case .cancelDownload:
                guard let job = pick(try await store.downloadJobs()) else { return false }
                _ = try await store.cancelDownload(id: job.id)
            case .deleteDownload:
                guard let target = pick(mirror.downloadedIDs.sorted()) else { return false }
                try await store.requestMediaDeletion(episodeID: target, deleteRemovesFromQueue: random.chance(50))
            case .listen:
                guard mirror.episode(episode)?.episode.details.media != nil else { return false }
                if player.episodeID != episode || random.chance(30) { try await player.load(episode) }
                try await player.play()
                try await player.listen(5 + random.below(30), every: 5)
                if random.chance(30) { _ = try await player.end(.ended, at: player.duration) } else { try await player.pause() }
            case .historyRemove:
                let shown = ids.filter { mirror.episode($0)?.episode.userState.lastPlayedHistoryMilliseconds != nil }
                guard let target = pick(shown) else { return false }
                _ = try await store.removeFromPlaybackHistoryWithUndo(target)
            case .historyClear: _ = try await store.clearPlaybackHistory()
            case .statisticsReset: try await store.resetPlayedDurationStatistics()
            case .randomize:
                // Any stored state: NEW, played, favorite, history, positions, durations and dates (ties included).
                var generator = EpisodeListKeysRandomTests.Generator(random: .init(state: random.next()))
                let fresh = generator.episode(id: episode)
                let keepMedia = mirror.episode(episode)?.episode.details.media?.url
                try await store.updateEpisode(id: episode) { stored in
                    stored.userState.playState = fresh.userState.playState
                    stored.userState.isFavorite = fresh.userState.isFavorite
                    stored.userState.positionMilliseconds = max(0, fresh.userState.positionMilliseconds)
                    stored.userState.lastPlayedHistoryMilliseconds = fresh.userState.lastPlayedHistoryMilliseconds
                    stored.userState.lastPlayedTimeMilliseconds = fresh.userState.lastPlayedTimeMilliseconds
                    stored.details.publicationDate = fresh.details.publicationDate
                    stored.details.title = fresh.details.title
                    if var media = fresh.details.media { media.url = keepMedia ?? media.url; stored.details.media = media }
                    else if keepMedia == nil { stored.details.media = nil }
                }
            case .dateTie:
                // Equal list keys in two podcasts (and NULL dates): the ties decide the order.
                guard let other = pick(ids), let date = mirror.episode(other)?.episode.details.publicationDate else { return false }
                let none = random.chance(20)
                try await store.updateEpisode(id: episode) { $0.details.publicationDate = none ? nil : date }
            case .subscribe:
                try await subscribe(number: feedCount, count: 5 + random.below(40))
            case .archive:
                guard let feed = pick(feeds) else { return false }
                try await store.updatePreferences(feedID: feed) { $0.subscriptionState = $0.subscriptionState == .archived ? .subscribed : .archived }
            case .unsubscribe:
                guard feeds.count > 3, let feed = pick(feeds) else { return false }
                if let current = player.episodeID, mirror.episode(current)?.feed.id == feed { _ = try await player.end(.switched) }
                _ = try await store.requestFeedDeletion(feedID: feed)
            case .feedFilter:
                guard let feed = pick(feeds) else { return false }
                let values = [[], ["unplayed"], ["queued"], ["not_queued", "has_media"], ["is_favorite"], ["played", "downloaded"]][random.below(6)]
                try await store.setEpisodeFilter(feedID: feed, filter: .init(values: values))
            case .feedSort:
                guard let feed = pick(feeds) else { return false }
                try await store.setFeedEpisodeSortOrder(feedID: feed, order: pick(FeedEpisodeSortOrder.allCases)!)
            case .refreshAdd, .refreshRemove, .refreshChange, .refreshUnchanged:
                guard let feed = pick(feeds), var source = sources[feed] else { return false }
                var removing: Set<Int> = []
                switch op {
                case .refreshAdd: source.count += 1 + random.below(3)
                case .refreshRemove: removing = [1 + random.below(max(1, source.count))]
                case .refreshChange: source.title += "!"
                default: break
                }
                sources[feed] = source
                var fetched = EpisodeListKeysTests.fetched(source.source, title: source.title, count: source.count, offset: source.offset, removing: removing)
                if op == .refreshChange, !fetched.feed.episodes.isEmpty {
                    let index = random.below(fetched.feed.episodes.count)
                    fetched.feed.episodes[index].title = (fetched.feed.episodes[index].title ?? "") + " (edited)"
                    fetched.feed.episodes[index].publicationDate = EpisodeListKeysTests.now.addingTimeInterval(Double(random.below(500)) * 3_600)
                }
                _ = try await store.applyRefresh(fetched, feedID: feed, options: .init(now: EpisodeListKeysTests.now))
            case .pin, .unpin:
                // A pinned removal leaves every list (PROTOCOL §15.4), and comes back when released.
                let target = op == .pin ? pick(feeds.filter { !pinned.contains($0) }) : pick(pinned.sorted())
                guard let target else { return false }
                if op == .pin { pinned.insert(target) } else { pinned.remove(target) }
                try await store.withDatabaseForTesting { database in
                    try database.transaction {
                        try database.execute(op == .pin ? "INSERT OR IGNORE INTO pinned_feed_removals(feed_id) VALUES (?)"
                                                        : "DELETE FROM pinned_feed_removals WHERE feed_id = ?", [.integer(target)])
                    }
                }
            case .heldRemoval:
                // The server removes a podcast while the player holds one of its episodes: the held episode is cut loose
                // from sync and its feed leaves every list (held-detach).
                guard server, let applier, let index = pick(podcasts.indices.filter { !podcasts[$0].removed }),
                      let held = mirror.feed(podcasts[index].feed)?.episodes.first(where: { $0.details.media != nil })?.id else { return false }
                try await store.retireEverythingForTesting()
                if player.episodeID != held { try await player.load(held) }
                try await applier.apply([ServerRecord(entity: "podcast", id: podcasts[index].podcast, fieldGroup: "subscription",
                                                      value: ["state": "removed", "generation_id": .string(podcasts[index].generation)])])
                podcasts[index].removed = true
            case .reAdd:
                // The podcast subscribed again (here or elsewhere): a fresh subscription in a feed of its own.
                guard server, let applier, let fixture, let index = pick(podcasts.indices.filter { podcasts[$0].removed }) else { return false }
                let next = try ContractIdentity.generationID(namespace: fixture.identity.namespace, podcastID: podcasts[index].podcast,
                                                             creatingOpID: ContractIdentity.randomUUID())
                try await applier.apply([ServerRecord(entity: "podcast", id: podcasts[index].podcast, fieldGroup: "subscription",
                                                      value: ["state": "subscribed", "generation_id": .string(next)])])
                let podcast = podcasts[index].podcast
                guard let feed = try fixture.rows("SELECT feed_id FROM ntp_podcasts WHERE podcast_id = '\(podcast)'").first?.first?.flatMap({ Int64($0) }) else { return false }
                podcasts[index] = (podcast, next, feed, false)
            case .releaseHeld:
                // The player leaves the held episode; the release deletes the detached feed's rows.
                guard server, let current = player.episodeID else { return false }
                _ = try await player.end(.switched)
                try await store.resetPlaybackPosition(episodeID: current)
                _ = try await store.releaseServerPins()
            case .hideFeed, .revealFeed, .hideEpisode, .revealEpisode:
                // Server staging: a podcast or new episodes hidden until their unit reveals them.
                guard server else { return false }
                try await store.withDatabaseForTesting { database in
                    try database.transaction {
                        switch op {
                        case .hideFeed:
                            guard let target = self.pick(feeds) else { return }
                            self.hiddenFeeds.insert(target)
                            try database.execute("INSERT OR IGNORE INTO ntp_hidden_feeds(feed_id, state) VALUES (?, 'staging')", [.integer(target)])
                        case .revealFeed:
                            guard let target = self.pick(self.hiddenFeeds.sorted()) else { return }
                            self.hiddenFeeds.remove(target)
                            try database.execute("DELETE FROM ntp_hidden_feeds WHERE feed_id = ?", [.integer(target)])
                        case .hideEpisode:
                            guard let target = self.pick(ids), let feed = self.mirror.episode(target)?.feed.id else { return }
                            self.hiddenEpisodes.insert(target)
                            try database.execute("INSERT OR IGNORE INTO ntp_hidden_episodes(episode_id, feed_id) VALUES (?, ?)", [.integer(target), .integer(feed)])
                            // As staging and reveal do: every read of the feed sees the change (its cached image is read again).
                            try database.execute("UPDATE feed_changes SET generation = generation + 1, episode_generation = episode_generation + 1 WHERE feed_id = ?", [.integer(feed)])
                        default:
                            guard let target = self.pick(self.hiddenEpisodes.sorted()) else { return }
                            self.hiddenEpisodes.remove(target)
                            try database.execute("UPDATE feed_changes SET generation = generation + 1, episode_generation = episode_generation + 1 WHERE feed_id = (SELECT feed_id FROM ntp_hidden_episodes WHERE episode_id = ?)", [.integer(target)])
                            try database.execute("DELETE FROM ntp_hidden_episodes WHERE episode_id = ?", [.integer(target)])
                        }
                    }
                }
            }
            return true
        }

        func step(_ op: Op) async throws {
            trace.append(op.rawValue)
            do {
                if try await perform(op) { note(op.rawValue) }
            } catch {
                trace.append("(\(op.rawValue) failed: \(error))")
            }
        }
    }

    static func run(server: Bool, seed: UInt64, feeds: Int, episodesPerFeed: Int, steps: Int) async throws -> World {
        let world = try await World.make(server: server, seed: seed, feeds: feeds, episodesPerFeed: episodesPerFeed)
        try await drive(world, steps: steps, seed: seed)
        return world
    }

    static func drive(_ world: World, steps: Int, seed: UInt64) async throws {
        let server = world.server
        let operations = Op.allCases.filter { server || ![.hideFeed, .revealFeed, .hideEpisode, .revealEpisode, .heldRemoval, .reAdd, .releaseHeld].contains($0) }
        // The mandatory prefix: every operation once, in order, before the random steps.
        for (number, op) in (operations + (0..<steps).map { _ in world.random.pick(operations)! }).enumerated() {
            try await world.step(op)
            try await world.patch()
            try await world.check("seed \(seed) step \(number) \(op.rawValue)")
            if !world.problems.isEmpty { break }
            // Now and then the screen opens again (navigation, a resize): it must equal the patched model, which it replaces.
            if number % 97 == 96 { try await world.open(); world.note("reopen") }
        }
    }

    /// L: power-user libraries (restored Android libraries of 54,000 and 100,000 episodes), two seeds of 120 steps each,
    /// every step compared with a fresh read. `NTP_SCALE=1`, release.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NTP_SCALE"] == "1"), arguments: [(54_000, 120), (100_000, 500)])
    func powerUserSequencesStayEqualToAFreshRead(episodes: Int, feeds: Int) async throws {
        let world = try await LibraryScreenBudgetTests.world(episodes: episodes, feeds: feeds)
        for seed in [UInt64(7), 8] {
            world.random = Random(state: seed)
            try await Self.drive(world, steps: 120, seed: seed)
        }
        #expect(world.problems.isEmpty, "\(world.problems.joined(separator: "\n"))")
        print("Equivalence \(episodes) episodes: coverage \(world.coverage.sorted { $0.key < $1.key })")
        await world.close()
    }

    @Test(arguments: Array(UInt64(1)...12))
    func standaloneSequencesStayEqualToAFreshRead(seed: UInt64) async throws {
        let world = try await Self.run(server: false, seed: seed, feeds: 12, episodesPerFeed: 165, steps: 300)
        #expect(world.problems.isEmpty, "\(world.problems.joined(separator: "\n"))")
        for label in ["patch feed reset", "patch queue", "list insert", "list remove", "list move"] {
            #expect(world.coverage[label, default: 0] > 0, "coverage: \(label)")
        }
        await world.close()
    }

    @Test(arguments: Array(UInt64(101)...104))
    func serverSequencesWithStagingStayEqualToAFreshRead(seed: UInt64) async throws {
        let world = try await Self.run(server: true, seed: seed, feeds: 10, episodesPerFeed: 120, steps: 300)
        #expect(world.problems.isEmpty, "\(world.problems.joined(separator: "\n"))")
        for label in ["hideFeed", "revealFeed", "hideEpisode", "revealEpisode", "heldRemoval", "reAdd", "releaseHeld", "patch feed reset"] {
            #expect(world.coverage[label, default: 0] > 0, "coverage: \(label)")
        }
        await world.close()
    }
}

extension FeedLibrarySnapshot {
    /// The snapshot as the screens' library holds it: every episode, the queue's included, a list projection.
    var listProjection: FeedLibrarySnapshot {
        FeedLibrarySnapshot(feeds: feeds.map { var feed = $0; feed.episodes = feed.episodes.map(\.listProjection); return feed },
                            queue: queue.map(\.listProjection), deletionTargets: deletionTargets, statisticsUnits: statisticsUnits)
    }
}
