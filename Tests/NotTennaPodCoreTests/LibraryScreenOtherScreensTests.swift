import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Further screen models kept from the same patches as the lists (`LibraryScreenModelEquivalenceTests.World`), checked at
/// every step against a fresh read.
protocol ScreenModelObserver: AnyObject {
    func opened(_ world: LibraryScreenModelEquivalenceTests.World)
    func patched(_ delta: LibraryMirrorDelta, _ world: LibraryScreenModelEquivalenceTests.World)
    func check(_ snapshot: FeedLibrarySnapshot, _ world: LibraryScreenModelEquivalenceTests.World) -> [String]
}

/// Home, Subscriptions with the drawer, and library searches, kept incrementally from the world's patches. At every step:
/// - Home's Inbox, Get surprised, Continue, Downloads and welcome state equal the frozen full read (`ScreenReference`) at
///   the model's clock, which advances between steps (picks expire by publication age and by the one-hour window);
/// - Classics equals the frozen full read taken at its last trigger (the event-aware oracle: an open, the subscription
///   set, a podcast's state, title or cover), never refreshed by routine changes;
/// - Subscriptions and Archive under every order, several counters and filters (order, counters, folders) equal the full
///   read, and so does the drawer's order;
/// - each search's first 300 episodes and its podcast results equal a new search of the library now.
final class OtherScreenModels: ScreenModelObserver {
    var clock: Date
    var random: LibraryScreenModelEquivalenceTests.Random
    var home: HomeScreenModel?
    let inboxSort: EpisodeListSort
    var seed: Int32
    var latest = FeedLatestDates()
    var searches: [(query: String, feedID: Int64?, archived: Bool, matches: LibrarySearchMatches?)] = []
    var classicsTriggered = false
    var classicsExpected: [Int64] = []
    var classicsTriggers = 0
    var coverage: [String: Int] = [:]
    var lastSurprise: [Int64] = []

    static let preferences: [SubscriptionDisplayPreferences] = {
        var result: [SubscriptionDisplayPreferences] = []
        for (index, order) in FeedOrder.allCases.enumerated() {
            for counter in [FeedCounter.showNew, .showUnplayed, .showDownloadedUnplayed, .showNone] {
                var value = SubscriptionDisplayPreferences()
                value.feedOrder = order.stored; value.feedCounter = counter.stored
                value.subscriptionsFilter = ["", "counter_greater_zero", "enabled_updates,show_non_subscribed", ""][(index + Int(counter.rawValue)) % 4]
                result.append(value)
            }
        }
        return result
    }()

    init(seed: UInt64, inboxSort: EpisodeListSort = .dateNewest) {
        random = .init(state: seed ^ 0xD2B)
        clock = EpisodeListKeysTests.now
        self.inboxSort = inboxSort
        self.seed = Int32(truncatingIfNeeded: Int64(bitPattern: seed &* 0x9E37_79B9) | 1)
    }

    func opened(_ world: LibraryScreenModelEquivalenceTests.World) {
        home = HomeScreenModel(mirror: world.mirror, inboxSort: inboxSort, seed: seed, now: clock, includeMarkedAsPlayed: false,
                               capacity: world.capacity)
        classicsTriggered = true
        latest = FeedLatestDates(world.mirror)
        let first = world.mirror.feeds.first?.id
        let queries: [(String, Int64?, Bool)] = [("Episode", nil, false), ("notes 1", nil, false), ("1 e", nil, false),
                                                 ("episode", first, false), ("Episode", nil, true), ("alpha", nil, false),
                                                 ("edited", nil, false), ("a_%", nil, false)]
        // The mirror holds list projections: a query's text is matched in SQLite, as the screens match it.
        let all = Set(world.mirror.feeds.flatMap(\.episodes).map(\.id))
        searches = queries.map { query in
            let words = LibrarySearchMatches.words(query.0)
            let matched = (try? world.detail?.episodes(all, matching: words)) ?? []
            let text = matched.sorted().compactMap { id in world.mirror.episode(id).map { (id: id, pubdate: LibrarySearchMatches.pubdate($0.episode)) } }
            return (query.0, query.1, query.2, try? LibrarySearchMatches(query: query.0, textMatches: text, mirror: world.mirror, feedID: query.1,
                                                                         archived: query.2, capacity: world.capacity))
        }
    }

    func patched(_ delta: LibraryMirrorDelta, _ world: LibraryScreenModelEquivalenceTests.World) {
        // The clock moves on (seconds to hours) and sometimes stands still.
        clock = max(clock, world.player.time).addingTimeInterval(Double(random.below(4) == 0 ? 0 : random.below(5_400)))
        if let change = home?.apply(delta, mirror: world.mirror, now: clock), change.classics { classicsTriggered = true }
        latest.apply(delta, mirror: world.mirror)
        for index in searches.indices {
            guard var matches = searches[index].matches else { continue }
            searches[index].matches = nil
            matches.apply(delta, mirror: world.mirror, text: { [detail = world.detail] ids, words in try detail?.episodes(ids, matching: words) })
            searches[index].matches = matches
        }
    }

    func check(_ snapshot: FeedLibrarySnapshot, _ world: LibraryScreenModelEquivalenceTests.World) -> [String] {
        var found: [String] = []
        let feeds = snapshot.feeds
        if var home {
            let now = home.now
            let inbox = home.inbox()
            let expectedInbox = ScreenReference.inbox(feeds, sort: inboxSort)
            if inbox.ids != expectedInbox.items.map(\.1.id) || inbox.total != expectedInbox.total { found.append("home inbox") }
            let surprise = home.surprise()
            if surprise != ScreenReference.surprise(feeds, seed: seed, now: now).map(\.1.id) { found.append("home surprise") }
            if surprise != lastSurprise { coverage["surprise changed", default: 0] += 1; lastSurprise = surprise }
            let date = Date(timeIntervalSince1970: Double(now) / 1000)
            if home.continueIDs != ScreenReference.continueListening(queue: snapshot.queue, now: now).map(\.id) {
                found.append("home continue")
            }
            for order in [nil, FeedEpisodeSortOrder.durationLongest] where HomeScreenModel.downloads(world.mirror, order: order) != ScreenReference.homeDownloads(feeds, order: order) {
                found.append("home downloads")
            }
            if HomeScreenModel.showsWelcome(world.mirror) != ScreenReference.showsWelcome(feeds) { found.append("home welcome") }
            // Classics: the full read at its last trigger, unchanged by routine changes in between.
            if classicsTriggered {
                classicsTriggered = false; classicsTriggers += 1
                classicsExpected = ((try? ScreenReference.classics(feeds, units: snapshot.statisticsUnits, includeMarkedAsPlayed: false, now: date)) ?? []).map(\.id)
            }
            if home.classics != classicsExpected { found.append("home classics") }
            self.home = home
        }
        for preferences in Self.preferences {
            for state in [FeedSubscriptionState.subscribed, .archived] {
                let mine = world.mirror.subscriptionList(preferences: preferences, state: state, globalAutoDownload: false, latest: latest)
                let theirs = ScreenReference.load(feeds, preferences: preferences, state: state, globalAutoDownload: false)
                if mine.feeds.map(\.id) != theirs.feeds.map(\.id) { found.append("subscriptions order \(preferences.order) \(state)") }
                if mine.counters != theirs.counters { found.append("subscriptions counters \(preferences.counter)") }
                if mine.folders.map({ [$0.title] + $0.feeds.map { String($0.id) } }) != theirs.folders.map({ [$0.title] + $0.feeds.map { String($0.id) } }) {
                    found.append("subscriptions folders")
                }
            }
        }
        for search in searches {
            guard var matches = search.matches else { continue }
            let mine = matches.result(mirror: world.mirror)
            let theirs = (try? ScreenReference.search(query: search.query, feeds: feeds, deletionTargets: snapshot.deletionTargets,
                                                      feedID: search.feedID, archived: search.archived)) ?? .init()
            if mine.episodes.map(\.episode.id) != theirs.episodes.map(\.episode.id) { found.append("search \(search.query) episodes") }
            else if mine != theirs.listProjection { found.append("search \(search.query) values") }
            if mine.feeds.map(\.id) != theirs.feeds.map(\.id) { found.append("search \(search.query) podcasts") }
            if theirs.episodes.count == 300 { coverage["search full", default: 0] += 1 }
        }
        return found
    }
}

@Suite(.serialized) struct LibraryScreenOtherScreensTests {
    typealias World = LibraryScreenModelEquivalenceTests.World
    typealias Random = LibraryScreenModelEquivalenceTests.Random

    // MARK: - Held-detach steps

    /// What a server removal of a podcast does to the screens while the player holds one of its episodes (PROTOCOL §6.8):
    /// the podcast's other episodes go, the held episode's shared state is cleared and it leaves the queue, and its podcast
    /// becomes a detached feed no list shows; the release deletes the rest; a re-add subscribes the same address again as
    /// a fresh podcast.
    enum HeldStep: String, CaseIterable { case detachHeld, releaseHeld, readd }

    final class Held: @unchecked Sendable {
        var held: [Int64: Int64] = [:]
        var released: [(source: String, count: Int, offset: Int, title: String)] = []
    }

    static func perform(_ step: HeldStep, _ world: World, _ held: Held) async throws -> Bool {
        switch step {
        case .detachHeld:
            let candidates = world.mirror.feeds.filter { feed in feed.episodes.count > 2 && held.held[feed.id] == nil }
            guard world.mirror.feeds.count > 4, let feed = world.random.pick(candidates),
                  let episode = feed.episodes.first(where: { $0.details.media != nil }) else { return false }
            if let current = world.player.episodeID, world.mirror.episode(current)?.feed.id == feed.id, current != episode.id {
                _ = try await world.player.end(.switched)
            }
            try await world.store.updateEpisode(id: episode.id) { stored in
                stored.userState.isFavorite = false
                stored.userState.lastPlayedHistoryMilliseconds = nil
                if stored.userState.playState == .new { stored.userState.playState = .unplayed }
            }
            try await world.store.withDatabaseForTesting { database in
                try database.transaction {
                    try database.execute("DELETE FROM queue WHERE episode_id IN (SELECT id FROM episodes WHERE feed_id = ?)", [.integer(feed.id)])
                    try database.execute("DELETE FROM episodes WHERE feed_id = ? AND id <> ?", [.integer(feed.id), .integer(episode.id)])
                    try database.execute("INSERT OR IGNORE INTO pinned_feed_removals(feed_id) VALUES (?)", [.integer(feed.id)])
                }
            }
            held.held[feed.id] = episode.id
            world.pinned.insert(feed.id)
        case .releaseHeld:
            guard let (feed, _) = held.held.sorted(by: { $0.key < $1.key }).first else { return false }
            if let current = world.player.episodeID, current == held.held[feed] { _ = try await world.player.end(.switched) }
            try await world.store.withDatabaseForTesting { database in
                try database.transaction {
                    try database.execute("DELETE FROM feeds WHERE id = ?", [.integer(feed)])
                    try database.execute("DELETE FROM pinned_feed_removals WHERE feed_id = ?", [.integer(feed)])
                }
            }
            held.held[feed] = nil
            world.pinned.remove(feed)
            if let source = world.sources.removeValue(forKey: feed) { held.released.append(source) }
        case .readd:
            guard !held.released.isEmpty else { return false }
            let source = held.released.removeFirst()
            let feed = try await world.store.insert(EpisodeListKeysTests.fetched(source.source, title: source.title, count: source.count, offset: source.offset),
                                                    options: .init(now: EpisodeListKeysTests.now))
            world.sources[feed.id] = source
        }
        return true
    }

    /// The world's operations and the held-detach steps, every one first, then random ones; the lists and every other screen
    /// model compared with a fresh read after each step.
    static func drive(_ world: World, models: OtherScreenModels, steps: Int, seed: UInt64) async throws -> Held {
        let held = Held()
        let server = world.server
        let operations = LibraryScreenModelEquivalenceTests.Op.allCases.filter { server || ![.hideFeed, .revealFeed, .hideEpisode, .revealEpisode].contains($0) }
        enum Step { case world(LibraryScreenModelEquivalenceTests.Op), held(HeldStep), tag, title }
        let all: [Step] = operations.map(Step.world) + HeldStep.allCases.map(Step.held) + [.tag, .title]
        var sequence = all
        for _ in 0..<steps {
            switch world.random.below(10) {
            case 0: sequence.append(.held(HeldStep.allCases[world.random.below(3)]))
            case 1: sequence.append(world.random.chance(50) ? .tag : .title)
            default: sequence.append(.world(world.random.pick(operations)!))
            }
        }
        for (number, step) in sequence.enumerated() {
            let label: String
            switch step {
            case .world(let op): label = op.rawValue; try await world.step(op)
            case .held(let op):
                label = op.rawValue; world.trace.append(label)
                do { if try await perform(op, world, held) { world.note(label) } } catch { world.trace.append("(\(label) failed: \(error))") }
            case .tag:
                label = "tag"; world.trace.append(label)
                if let feed = world.random.pick(world.mirror.feeds.map(\.id)) {
                    let tags = [[], ["Tag A"], ["tag a", "Zed"], ["Zed"]][world.random.below(4)]
                    try await world.store.updatePreferences(feedID: feed) { $0.tags = tags }
                    world.note(label)
                }
            case .title:
                label = "title"; world.trace.append(label)
                if let feed = world.random.pick(world.mirror.feeds.map(\.id)) {
                    let title = [nil, "Custom é", "custom e\u{301}", "ALPHA"][world.random.below(4)]
                    try await world.store.updatePreferences(feedID: feed) { $0.customTitle = title }
                    world.note(label)
                }
            }
            try await world.patch()
            try await world.check("seed \(seed) step \(number) \(label)")
            if !world.problems.isEmpty { break }
            if number % 97 == 96 { try await world.open(); world.note("reopen") }
        }
        return held
    }

    static func run(server: Bool, seed: UInt64, feeds: Int, episodesPerFeed: Int, steps: Int) async throws -> (World, OtherScreenModels) {
        let world = try await World.make(server: server, seed: seed, feeds: feeds, episodesPerFeed: episodesPerFeed)
        let models = OtherScreenModels(seed: seed, inboxSort: EpisodeListSort.allCases[Int(seed % 4)])
        world.observers = [models]
        models.opened(world)
        _ = try await drive(world, models: models, steps: steps, seed: seed)
        return (world, models)
    }

    @Test(arguments: Array(UInt64(21)...26))
    func standaloneScreensStayEqualToAFreshRead(seed: UInt64) async throws {
        let (world, models) = try await Self.run(server: false, seed: seed, feeds: 12, episodesPerFeed: 165, steps: 300)
        #expect(world.problems.isEmpty, "\(world.problems.joined(separator: "\n"))")
        for label in ["detachHeld", "releaseHeld", "readd", "tag", "title", "listen", "refreshAdd"] {
            #expect(world.coverage[label, default: 0] > 0, "coverage: \(label)")
        }
        #expect(models.classicsTriggers > 2 && models.coverage["surprise changed", default: 0] > 3)
        #expect(models.coverage["search full", default: 0] > 0, "a search with more than 300 matches")
        await world.close()
    }

    @Test(arguments: Array(UInt64(121)...123))
    func serverScreensWithStagingStayEqualToAFreshRead(seed: UInt64) async throws {
        let (world, _) = try await Self.run(server: true, seed: seed, feeds: 10, episodesPerFeed: 120, steps: 300)
        #expect(world.problems.isEmpty, "\(world.problems.joined(separator: "\n"))")
        for label in ["hideFeed", "revealFeed", "hideEpisode", "revealEpisode", "detachHeld", "releaseHeld", "readd"] {
            #expect(world.coverage[label, default: 0] > 0, "coverage: \(label)")
        }
        await world.close()
    }

    /// L: power-user libraries (54,000 and 100,000 episodes), every step compared with a fresh read. `NTP_SCALE=1`, release.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NTP_SCALE"] == "1"), arguments: [(54_000, 120), (100_000, 500)])
    func powerUserScreensStayEqualToAFreshRead(episodes: Int, feeds: Int) async throws {
        let world = try await LibraryScreenBudgetTests.world(episodes: episodes, feeds: feeds)
        let models = OtherScreenModels(seed: 31)
        world.observers = [models]
        models.opened(world)
        _ = try await Self.drive(world, models: models, steps: 80, seed: 31)
        #expect(world.problems.isEmpty, "\(world.problems.joined(separator: "\n"))")
        await world.close()
    }

    // MARK: - Podcast lists at page boundaries

    /// Composed U+00E9 against decomposed e + U+0301, byte ties and missing values under every podcast sort order (also
    /// inherited from each global order), at the 149 / 150 / 151 and later page boundaries, through inserts at those
    /// ranks and re-sorts.
    @Test func podcastListsAtPageBoundariesEqualTheFullRead() {
        var random = Random(state: 0xA)
        var feed = LibraryFeed(id: 1, source: "fixture://a", metadata: .init(format: .rss, title: "A"), episodes: [])
        feed.subscriptionState = .subscribed
        func episode(_ id: Int64) -> LibraryEpisode {
            let titles: [String?] = ["\u{E9}t\u{E9}", "e\u{301}te\u{301}", "\u{E9}", "e\u{301}", "Zed", "zed", "a", nil]
            var details = ParsedEpisode(title: titles[random.below(titles.count)],
                                        publicationDate: random.chance(8) ? nil : Date(timeIntervalSince1970: 1_700_000_000 + Double(random.below(40))))
            details.link = random.chance(30) ? nil : ["x/\u{E9}.mp3", "x/e\u{301}.mp3", "x/a.mp3"][random.below(3)]
            if !random.chance(10) {
                details.media = ParsedMedia(url: "https://media.test/\(id)", size: Int64(random.below(3) * 100),
                                            durationMilliseconds: Int32(random.below(3) * 1_000))
            }
            return LibraryEpisode(id: id, details: details)
        }
        feed.episodes = (1...455).map { episode(Int64($0)) }
        var nextID: Int64 = 1_000
        for global in [FeedEpisodeSortOrder.dateNewest, .titleAscending, .durationShortest] {
            for order in FeedEpisodeSortOrder.allCases {
                var shown = feed
                shown.episodeSortOrderCode = order.rawValue
                let spec = EpisodeListSpec.feed(shown, globalSort: global)
                var index = EpisodeListIndex(spec: spec, candidates: shown.episodes.map { (feed: shown, episode: $0) }, queued: [], capacity: 16)
                func expectEqual(_ label: String) {
                    let expected = FullReloadReference.filteredDisplayEpisodes(shown, queuedIDs: [], globalSort: global).map(\.id)
                    #expect(index.allIDs == expected, "\(order) under \(global) \(label)")
                    for range in [149..<152, 0..<150, 150..<300, 300..<450, 450..<600] {
                        #expect(index.ids(range) == Array(expected[min(range.lowerBound, expected.count)..<min(range.upperBound, expected.count)]),
                                "\(order) under \(global) \(label) ranks \(range)")
                    }
                }
                expectEqual("open")
                // Inserts that tie, byte for byte, with the members at the page boundary.
                for rank in [149, 150, 151] {
                    let at = index.ids(rank..<rank + 1)[0]
                    var twin = shown.episodes.first { $0.id == at }!
                    nextID += 1
                    twin = LibraryEpisode(id: nextID, details: twin.details, userState: twin.userState)
                    shown.episodes.append(twin)
                    _ = index.apply([twin.id: (feed: shown, episode: twin)], queued: [])
                }
                expectEqual("after inserts")
            }
        }
    }

    // MARK: - Get surprised and Continue with an advancing clock

    static func mirror(_ feeds: [LibraryFeed], queue: [LibraryEpisode] = []) -> LibraryScreenMirror {
        LibraryScreenMirror(LibraryScreenSnapshot(snapshot: FeedLibrarySnapshot(feeds: feeds, queue: queue, deletionTargets: [:], statisticsUnits: [:]),
                                                  pubdates: Dictionary(uniqueKeysWithValues: feeds.flatMap(\.episodes).map {
                                                      ($0.id, Int64(($0.details.publicationDate?.timeIntervalSince1970 ?? 0) * 1000)) })))
    }

    /// Applies a changed episode to `mirror` as a patch's read would, returning the delta.
    static func change(_ mirror: inout LibraryScreenMirror, _ episode: LibraryEpisode, feed: Int64) -> LibraryMirrorDelta {
        var read = LibraryMirrorRead()
        read.episodes[episode.id] = LibraryMirrorRead.Episode(feedID: feed, pubdate: Int64((episode.details.publicationDate?.timeIntervalSince1970 ?? 0) * 1000), episode: episode)
        read.unitsRead = [episode.id]
        return mirror.apply(read)
    }

    @Test func surpriseFollowsTheClockAndTheTieRule() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let nowMS = Int64(now.timeIntervalSince1970 * 1000)
        // Seed 1: the hash is the ID modulo 46471, so IDs 46,471 apart tie.
        let a: Int64 = 46_480, b: Int64 = 46_479, low: Int64 = 9
        func episode(_ id: Int64, published: Date, lastPlayed: Int64 = 0, played: Bool = false) -> LibraryEpisode {
            var value = LibraryEpisode(id: id, details: ParsedEpisode(title: "e\(id)", publicationDate: published,
                                                                      media: ParsedMedia(url: "u\(id)", size: 1, durationMilliseconds: 1_000)))
            value.userState.lastPlayedTimeMilliseconds = lastPlayed
            value.userState.playState = played ? .played : .unplayed
            return value
        }
        var feed = LibraryFeed(id: 1, source: "s", metadata: .init(format: .rss, title: "F"), episodes: [])
        feed.subscriptionState = .subscribed
        // A: the pick, played 3,599,999 ms ago; B: the runner-up; low: the same hash as A with a lower ID, played (not a
        // candidate yet); old: published exactly at the window's edge.
        let edge = Date(timeIntervalSince1970: Double(nowMS - 1000 * 3600 * 24 * 356 * 2 + 5) / 1000)
        feed.episodes = [episode(a, published: now, lastPlayed: nowMS - 3_599_999), episode(b, published: now),
                         episode(low, published: now, played: true), episode(7, published: edge)]
        var mirror = Self.mirror([feed])
        var model = HomeScreenModel(mirror: mirror, inboxSort: .dateNewest, seed: 1, now: now, includeMarkedAsPlayed: false, capacity: 4)
        func expectReference(_ label: String) {
            let expected = ScreenReference.surprise(mirror.feeds, seed: 1, now: model.now).map(\.1.id)
            #expect(model.surprise() == expected, "\(label)")
        }
        #expect(model.surprise() == [a]); expectReference("open")
        // Two milliseconds later, at the player's status change (no episode changed): A left the one-hour window.
        model.apply(LibraryMirrorDelta(), mirror: mirror, now: now.addingTimeInterval(0.002))
        #expect(model.surprise() == [b], "the runner-up"); expectReference("hour window")
        // The equal-hash newcomer with the lower ID becomes a candidate: it is picked (the lower ID on equal hashes).
        let delta = Self.change(&mirror, episode(low, published: now), feed: 1)
        model.apply(delta, mirror: mirror, now: now.addingTimeInterval(0.003))
        #expect(model.surprise() == [low], "the lower ID"); expectReference("tie")
        // Publication age: the edge episode is a candidate until its window passes.
        let played = Self.change(&mirror, episode(low, published: now, played: true), feed: 1)
        model.apply(played, mirror: mirror, now: now.addingTimeInterval(0.004))
        let playedB = Self.change(&mirror, episode(b, published: now, played: true), feed: 1)
        model.apply(playedB, mirror: mirror, now: now.addingTimeInterval(0.004))
        #expect(model.surprise() == [7], "the edge episode"); expectReference("edge")
        model.apply(LibraryMirrorDelta(), mirror: mirror, now: now.addingTimeInterval(0.010))
        #expect(model.surprise().isEmpty, "the edge passed"); expectReference("edge passed")
        #expect(model.metrics.candidateRescans >= 3)
    }

    @Test func continueFollowsTheThirtySecondWindow() {
        let now = Date(timeIntervalSince1970: 1_760_000_000), nowMS = Int64(now.timeIntervalSince1970 * 1000)
        // In queue order: B played long ago, A 29,999 ms ago (resumed for one more millisecond).
        var queue: [LibraryEpisode] = []
        for (id, lastPlayed) in [(Int64(2), nowMS - 100_000), (1, nowMS - 29_999)] {
            var episode = LibraryEpisode(id: id, details: ParsedEpisode(title: "e", media: ParsedMedia(url: "u\(id)", size: 1, durationMilliseconds: 1)))
            episode.userState.lastPlayedTimeMilliseconds = lastPlayed
            queue.append(episode)
        }
        var feed = LibraryFeed(id: 1, source: "s", metadata: .init(format: .rss), episodes: queue)
        feed.subscriptionState = .subscribed
        let mirror = Self.mirror([feed], queue: queue)
        var model = HomeScreenModel(mirror: mirror, inboxSort: .dateNewest, seed: 1, now: now, includeMarkedAsPlayed: false)
        #expect(model.continueIDs == [1, 2], "resumed first")
        for offset in [0.001, 0.002, 0.020] {
            let at = now.addingTimeInterval(offset)
            model.apply(LibraryMirrorDelta(), mirror: mirror, now: at)
            #expect(model.continueIDs == ScreenReference.continueListening(queue: queue, now: model.now).map(\.id))
        }
        #expect(model.continueIDs == [2, 1], "the window passed: queue order")
    }

    // MARK: - Explicit events use the current clock

    /// Returning to Home and Shuffle check Get surprised against the time now, as Android loads it on start: a pick played
    /// 3,599 seconds ago has left the one-hour window ten seconds later.
    @Test func homeReturnAndShuffleUseTheCurrentClock() {
        let now = Date(timeIntervalSince1970: 1_760_000_000), nowMS = Int64(now.timeIntervalSince1970 * 1000)
        func episode(_ id: Int64, lastPlayed: Int64) -> LibraryEpisode {
            var value = LibraryEpisode(id: id, details: ParsedEpisode(title: "e\(id)", publicationDate: now,
                                                                      media: ParsedMedia(url: "u\(id)", size: 1, durationMilliseconds: 1_000)))
            value.userState.lastPlayedTimeMilliseconds = lastPlayed
            return value
        }
        var feed = LibraryFeed(id: 1, source: "s", metadata: .init(format: .rss, title: "F"), episodes: [])
        feed.subscriptionState = .subscribed
        // Every episode was played 3,599 seconds ago: ten seconds later none is a candidate.
        feed.episodes = (1...4).map { episode(Int64($0), lastPlayed: nowMS - 3_599_000) }
        let mirror = Self.mirror([feed])
        let later = now.addingTimeInterval(10)
        var returned = HomeScreenModel(mirror: mirror, inboxSort: .dateNewest, seed: 5, now: now, includeMarkedAsPlayed: false)
        #expect(returned.surprise().count == 1)
        returned.appear(mirror: mirror, now: later)
        #expect(returned.surprise() == ScreenReference.surprise(mirror.feeds, seed: 5, now: Int64(later.timeIntervalSince1970 * 1000)).map(\.1.id),
                "Home's return checks the picks at the time now")
        var shuffled = HomeScreenModel(mirror: mirror, inboxSort: .dateNewest, seed: 5, now: now, includeMarkedAsPlayed: false)
        shuffled.reseed(9, mirror: mirror, now: later)
        #expect(shuffled.surprise() == ScreenReference.surprise(mirror.feeds, seed: 9, now: Int64(later.timeIntervalSince1970 * 1000)).map(\.1.id),
                "Shuffle picks at the time now")
    }

    // MARK: - The search changes its matches in place

    /// Through the session's patch, which the screen uses: adding one match changes the kept matches in place (their map
    /// keeps its storage), with the shown result before the change still returned, at 2,000 and 100,000 matches.
    @MainActor @Test(arguments: [2_000, 100_000])
    func aSearchPatchChangesItsMatchesInPlace(matches count: Int) async throws {
        var feed = LibraryFeed(id: 1, source: "s", metadata: .init(format: .rss, title: "F"), episodes: [])
        feed.subscriptionState = .subscribed
        feed.episodes = (1...count).map { LibraryEpisode(id: Int64($0), details: ParsedEpisode(title: "Episode \($0)",
            publicationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double($0)))) }
        var mirror = Self.mirror([feed])
        let scanned = mirror.feeds
        let session = LibrarySearchSession(feedID: nil, feedTitle: "", delay: {}, read: { query, _ in
            var result = LibrarySearchResult()
            result.matches = try LibrarySearchMatches(query: query, feeds: scanned, feedID: nil, archived: false)
            return result
        })
        let current = mirror
        session.library = { current }
        session.change("episode")
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while session.resultRevision == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(session.result.matches?.count == count)
#if DEBUG
        let storage = try #require(session.result.matches?.keysStorage)
#endif
        let shown = session.result.episodes.map(\.episode.id)
        let added = LibraryEpisode(id: Int64(count + 1), details: ParsedEpisode(title: "Episode new", publicationDate: Date(timeIntervalSince1970: 1_800_000_000)))
        let delta = Self.change(&mirror, added, feed: 1)
        let patched = session.patch(delta, mirror: mirror)
        #expect(patched.changed && patched.previous.episodes.map(\.episode.id) == shown && patched.previous.matches == nil)
        #expect(session.result.matches?.count == count + 1)
#if DEBUG
        #expect(session.result.matches?.keysStorage == storage, "the matches changed in place, not as a copy of every match")
#endif
        #expect(session.result.episodes.first?.episode.id == added.id)
    }

    // MARK: - One sort per read

    /// A catch-up read naming 50,000 episodes sorts the statistics IDs once, then reads them in chunks.
    @Test func aLargeReadSortsTheStatisticsIDsOnce() async throws {
        let world = try await World.make(server: false, seed: 51, feeds: 2, episodesPerFeed: 10)
        let episode = try #require(world.mirror.feeds.first?.episodes.first).id
        try await world.store.withDatabaseForTesting { database in
            try database.transaction {
                try database.execute("INSERT INTO statistics_units(episode_id, unit_id, played_ms) VALUES (?, 'u', 1000)", [.integer(episode)])
            }
        }
        try await world.patch()
        var request = LibraryMirrorRequest()
        request.episodes = Set((1...50_000).map(Int64.init))
        let read = try await world.store.mirrorRead(request)
        #expect(read.statisticsSorts == 1, "\(read.statisticsSorts) sorts")
        #expect(read.units[episode] != nil)
        await world.close()
    }

    // MARK: - Subscriptions by counter with a tag, two NEW dismissed in one transaction

    @Test func dismissingAPodcastsNewMovesItAndItsTagSum() async throws {
        let world = try await World.make(server: false, seed: 9, feeds: 4, episodesPerFeed: 10)
        let models = OtherScreenModels(seed: 9)
        world.observers = [models]
        models.opened(world)
        let ids = world.mirror.feeds.map(\.id)
        // NEW counts 4, 3, 2 (F), 1: F has exactly two NEW and carries the tag.
        for (feed, count) in zip(ids, [4, 3, 2, 1]) {
            let episodes = try #require(world.mirror.feed(feed)?.episodes.map(\.id))
            for (offset, id) in episodes.enumerated() {
                try await world.store.updateEpisode(id: id) { $0.userState.playState = offset < count ? .new : .unplayed }
            }
        }
        let f = ids[2]
        try await world.store.updatePreferences(feedID: f) { $0.tags = ["Tag"] }
        try await world.store.updatePreferences(feedID: ids[3]) { $0.tags = ["Tag"] }
        try await world.patch(); try await world.check("set up")
        var preferences = SubscriptionDisplayPreferences()
        preferences.feedOrder = FeedOrder.counter.stored; preferences.feedCounter = FeedCounter.showNew.stored
        func shown() -> SubscriptionListQueries.Result {
            world.mirror.subscriptionList(preferences: preferences, state: .subscribed, globalAutoDownload: false, latest: models.latest)
        }
        func tagSum(_ result: SubscriptionListQueries.Result) -> Int {
            result.folders.first { $0.title == "Tag" }?.feeds.reduce(0) { $0 + result.counters[$1.id, default: 0] } ?? -1
        }
        let before = shown()
        #expect(before.feeds.map(\.id) == ids, "ordered by NEW count")
        #expect(tagSum(before) == 3)
        #expect(NavigationCounters(queueLength: 0, inbox: world.mirror.inboxCount, feedCounters: before.counters).subscriptions == 10)
        let emitted = world.store.changes.emitted
        _ = try await world.store.removeFeedFromInbox(feedID: f)
        #expect(world.store.changes.emitted == emitted + 1, "one transaction")
        try await world.patch(); try await world.check("dismissed")
        let after = shown()
        #expect(after.feeds.map(\.id) == [ids[0], ids[1], ids[3], ids[2]], "F moves to the end")
        #expect(tagSum(after) == 1, "the tag's sum drops")
        #expect(after.counters[f] == nil)
        #expect(NavigationCounters(queueLength: 0, inbox: world.mirror.inboxCount, feedCounters: after.counters).subscriptions == 8, "the drawer")
        #expect(world.problems.isEmpty, "\(world.problems)")
        await world.close()
    }

    // MARK: - Two incremental screens and a late subscriber

    /// One screen kept by its own updater from the library's hub, as a controller keeps it.
    @MainActor final class Screen {
        var mirror = LibraryScreenMirror()
        let updater: LibraryScreenUpdater
        var appliedSequences: [Int64] = []
        init(store: FeedLibraryStore, subscription: LibraryChangeHub.Subscription) async throws {
            var configuration = LibraryScreenUpdater.Configuration()
            configuration.syncPacing = .milliseconds(250)
            updater = LibraryScreenUpdater(subscription: subscription, configuration: configuration)
            let readers = try await store.readers()
            updater.request = { [unowned self] sets in mirror.request(for: sets) }
            updater.read = { request in try await readers.quick.mirrorRead(request) }
            updater.apply = { [unowned self] read in mirror.apply(read); appliedSequences.append(read.sequence) }
            updater.beginOpen()
            let open = try await store.screenSnapshot()
            mirror = LibraryScreenMirror(open)
            updater.opened(at: open.sequence)
        }
    }

    @MainActor @Test func twoIncrementalScreensAndALateSubscriberStayEqual() async throws {
        try await Self.twoScreens(sharedStream: false)
    }

    /// One subscription's stream split between two consumers, alternately (a single consumed stream).
    static func split(_ subscription: LibraryChangeHub.Subscription) -> (LibraryChangeHub.Subscription, LibraryChangeHub.Subscription) {
        let (a, toA) = AsyncStream<LibraryChangeSet>.makeStream()
        let (b, toB) = AsyncStream<LibraryChangeSet>.makeStream()
        Task {
            var first = true
            for await set in subscription.changes { (first ? toA : toB).yield(set); first.toggle() }
            toA.finish(); toB.finish()
        }
        return (.init(identity: subscription.identity, baseline: subscription.baseline, changes: a),
                .init(identity: subscription.identity, baseline: subscription.baseline, changes: b))
    }

    nonisolated static func rolledBack(_ store: FeedLibraryStore) async {
        try? await store.withDatabaseForTesting { database in
            try database.transaction {
                try database.execute("DELETE FROM queue")
                throw CancellationError()
            }
        }
    }

    /// `configure`: applied to the first screen before any change (a mutation's fault, in debug builds).
    @MainActor static func twoScreens(sharedStream: Bool, configure: (Screen) -> Void = { _ in }) async throws {
        let world = try await World.make(server: false, seed: 77, feeds: 4, episodesPerFeed: 30)
        let store = world.store
        // The mutation: one stream consumed by both screens, each set reaching only one of them.
        let (first, second) = sharedStream ? Self.split(store.changes.subscribe()) : (store.changes.subscribe(), store.changes.subscribe())
        let a = try await Screen(store: store, subscription: first)
        configure(a)
        let b = try await Screen(store: store, subscription: second)
        var late: Screen?
        var random = Random(state: 0xE)
        let ids = world.mirror.feeds.flatMap(\.episodes).map(\.id)
        for step in 0..<40 {
            let target = ids[random.below(ids.count)]
            switch step % 5 {
            case 0: try await store.markEpisodePlayed(episodeID: target, played: random.chance(50))
            case 1:
                // Two sync units' commits (the second held by the pacing), then a local one overtaking it.
                let other = ids[random.below(ids.count)]
                try await LibraryChangeOrigin.$current.withValue(.sync) { try await store.setFavorite(episodeID: target, favorite: true) }
                try await LibraryChangeOrigin.$current.withValue(.sync) { try await store.markEpisodePlayed(episodeID: other, played: true) }
                try await store.setFavorite(episodeID: ids[random.below(ids.count)], favorite: random.chance(50))
            case 2:
                // A rolled-back transaction delivers nothing.
                await Self.rolledBack(store)
                _ = try await store.enqueue([target])
            case 3:
                // A net-zero commit (a value written as it was) delivers nothing.
                let current = try #require(try await store.episode(id: target))
                try await store.updateEpisode(id: target) { $0 = current }
                try await LibraryChangeOrigin.$current.withValue(.sync) { try await store.markEpisodePlayed(episodeID: target, played: false) }
            default: try await store.removeEpisodeFromInbox(episodeID: target)
            }
            if step == 12 { late = try await Screen(store: store, subscription: store.changes.subscribe()) }
            let receipt = store.changes.emitted
            for screen in [a, b] + [late].compactMap({ $0 }) {
                // settle(receipt:) returns once the screen covers the receipt (a screen that never does is stopped at the
                // end, which ends the wait).
                let waiter = Task { await screen.updater.settle(receipt: receipt) }
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while screen.updater.covered < receipt, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
                #expect(screen.updater.covered == receipt, "step \(step): the covered prefix is exactly the receipt")
                if screen.updater.covered >= receipt { #expect(await waiter.value == .settled, "step \(step): settled") }
            }
            let fresh = try await store.screenSnapshot()
            var equal = true
            for (name, screen) in [("A", a), ("B", b)] + [late].compactMap({ $0.map { ("late", $0) } }) {
                #expect(screen.mirror.snapshot == fresh.snapshot, "step \(step): screen \(name) equals a fresh open")
                #expect(screen.mirror.sequence == fresh.sequence, "step \(step): screen \(name) is at the library's sequence")
                equal = equal && screen.mirror.snapshot == fresh.snapshot && screen.mirror.sequence == fresh.sequence
            }
            if !equal { break }
        }
        #expect(a.appliedSequences == a.appliedSequences.sorted() && b.appliedSequences == b.appliedSequences.sorted())
        for screen in [a, b] + [late].compactMap({ $0 }) { screen.updater.stop() }
        await world.close()
    }

    // MARK: - Budgets

    struct Work: CustomStringConvertible {
        var homeEpisodes = 0, rescans = 0, populationVisited = 0, populationMoved = 0, classicsLoads = 0
        var latestVisited = 0, searchEvaluated = 0, searchFeeds = 0
        var description: String {
            "home episodes \(homeEpisodes), re-picks \(rescans) visiting \(populationVisited), population moves \(populationMoved), classics \(classicsLoads), newest dates \(latestVisited), search \(searchEvaluated) episodes \(searchFeeds) podcasts"
        }
    }

    /// The routine events, each performed once and patched into Home, the newest dates and the searches (one of them
    /// matching every episode), with their work counted per event.
    static func measure(_ world: World) async throws -> [String: Work] {
        let models = OtherScreenModels(seed: 5)
        world.observers = [models]
        models.opened(world)
        let small = try #require(world.sources.first { $0.value.source.hasSuffix("screen900.xml") }?.key)
        let episodes = world.mirror.feeds.filter { $0.id != small }.flatMap(\.episodes)
        let target = try #require(episodes.first { $0.details.media != nil && $0.userState.playState != .new }).id
        let subscribed = world.mirror.feeds.filter { $0.subscriptionState == .subscribed && $0.id != small }.flatMap(\.episodes)
        let inboxMember: Int64
        if let member = subscribed.first(where: { $0.userState.playState == .new && $0.id != target }) { inboxMember = member.id } else {
            inboxMember = try #require(subscribed.first { $0.id != target }).id
            try await world.store.updateEpisode(id: inboxMember) { $0.userState.playState = .new }
            try await world.patch()
        }
        let events: [(String, () async throws -> Void)] = [
            ("own position save", {
                try await world.player.load(target); try await world.player.play()
                try await world.player.listen(10, every: 5); try await world.player.pause()
            }),
            ("played mark", { try await world.store.markEpisodePlayed(episodeID: target, played: true) }),
            ("unplayed mark", { try await world.store.markEpisodePlayed(episodeID: target, played: false) }),
            ("favorite toggle", { try await world.store.setFavorite(episodeID: target, favorite: true) }),
            ("inbox dismiss", { try await world.store.removeEpisodeFromInbox(episodeID: inboxMember) }),
            ("queue add", { _ = try await world.store.enqueue([target], location: .front) }),
            ("queue remove", { _ = try await world.store.removeFromQueue([target]) }),
            ("download state", { try await world.store.updateEpisode(id: target) { $0.userState.isDownloaded = true; $0.userState.downloadDate = EpisodeListKeysTests.now } }),
            ("history removal", { _ = try await world.store.removeFromPlaybackHistoryWithUndo(target) }),
            ("one-new-episode refresh", {
                var source = try #require(world.sources[small]); source.count += 1; world.sources[small] = source
                _ = try await world.store.applyRefresh(EpisodeListKeysTests.fetched(source.source, title: source.title, count: source.count, offset: source.offset),
                                                       feedID: small, options: .init(now: EpisodeListKeysTests.now))
            }),
            ("unchanged refresh", {
                let source = try #require(world.sources[small])
                _ = try await world.store.applyRefresh(EpisodeListKeysTests.fetched(source.source, title: source.title, count: source.count, offset: source.offset),
                                                       feedID: small, options: .init(now: EpisodeListKeysTests.now.addingTimeInterval(60)))
            }),
        ]
        var results: [String: Work] = [:]
        for (name, event) in events {
            let home = models.home?.metrics ?? .init(), latest = models.latest.visited
            let search = models.searches.compactMap(\.matches).map(\.metrics)
            try await event()
            try await world.patch()
            try await world.check(name)
            let after = models.home?.metrics ?? .init()
            let searchAfter = models.searches.compactMap(\.matches).map(\.metrics)
            results[name] = Work(homeEpisodes: after.episodesVisited - home.episodesVisited, rescans: after.candidateRescans - home.candidateRescans,
                                 populationVisited: after.populationVisited - home.populationVisited,
                                 populationMoved: after.populationMoved - home.populationMoved,
                                 classicsLoads: after.classicsLoads - home.classicsLoads, latestVisited: models.latest.visited - latest,
                                 searchEvaluated: zip(searchAfter, search).map { $0.episodesEvaluated - $1.episodesEvaluated }.max() ?? 0,
                                 searchFeeds: zip(searchAfter, search).map { $0.feedsEvaluated - $1.feedsEvaluated }.max() ?? 0)
        }
        #expect(world.problems.isEmpty, "\(world.problems)")
        return results
    }

    static func expectWithinBudget(_ results: [String: Work], sourceLocation: SourceLocation = #_sourceLocation) {
        for (name, work) in results.sorted(by: { $0.key < $1.key }) {
            // What the change named: a few episodes, plus the small podcast's 60 for a refresh that adds one.
            let named = name == "one-new-episode refresh" ? 70 : 4
            #expect(work.homeEpisodes <= named, "\(name): Home looks at the changed episodes only (\(work))", sourceLocation: sourceLocation)
            #expect(work.classicsLoads == 0, "\(name): Classics is not loaded on a routine change (\(work))", sourceLocation: sourceLocation)
            #expect(work.rescans <= 1, "\(name): at most the changed podcast's pick is made again (\(work))", sourceLocation: sourceLocation)
            #expect(work.populationVisited <= 64 + 70, "\(name): a re-pick visits one podcast's recent population (\(work))", sourceLocation: sourceLocation)
            #expect(work.latestVisited <= named, "\(name): newest dates look at the changed episodes (\(work))", sourceLocation: sourceLocation)
            #expect(work.searchEvaluated <= named, "\(name): the searches match the changed episodes only (\(work))", sourceLocation: sourceLocation)
            #expect(work.searchFeeds <= 2, "\(name): the searches match the changed podcasts only (\(work))", sourceLocation: sourceLocation)
        }
    }

    @Test func routineChangesStayWithinTheirBudgetsOnTheOtherScreens() async throws {
        let world = try await LibraryScreenBudgetTests.world(episodes: 2_000, feeds: 40)
        let results = try await Self.measure(world)
        Self.expectWithinBudget(results)
        print("Other screens budgets 2k:\n" + results.sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value)" }.joined(separator: "\n"))
        await world.close()
    }

    /// The same events at 10,000, 54,000 and 100,000 episodes: every count within the absolute bounds, so flat.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NTP_SCALE"] == "1"))
    func otherScreensAreFlatAtPowerUserScale() async throws {
        for (episodes, feeds) in [(10_000, 120), (54_000, 120), (100_000, 500)] {
            let world = try await LibraryScreenBudgetTests.world(episodes: episodes, feeds: feeds)
            let results = try await Self.measure(world)
            Self.expectWithinBudget(results)
            print("Other screens budgets \(episodes):\n" + results.sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value)" }.joined(separator: "\n"))
            await world.close()
        }
    }

    /// A Surprise pick that leaves is picked again from its podcast's recent population only: linear in that
    /// population, flat in the podcast's played and old episodes and in every other podcast.
    @Test func aSurpriseRepickIsBoundedByThePodcastsRecentPopulation() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        func run(recent: Int, others: Int, otherFeeds: Int) throws -> (visited: Int, rescans: Int) {
            var id: Int64 = 0
            func episode(published: Date, played: Bool) -> LibraryEpisode {
                id += 1
                var value = LibraryEpisode(id: id, details: ParsedEpisode(title: "e", publicationDate: published,
                                                                          media: ParsedMedia(url: "u\(id)", size: 1, durationMilliseconds: 1)))
                value.userState.playState = played ? .played : .unplayed
                return value
            }
            var feeds: [LibraryFeed] = []
            var f = LibraryFeed(id: 1, source: "s1", metadata: .init(format: .rss, title: "F"), episodes: [])
            f.subscriptionState = .subscribed
            f.episodes = (0..<recent).map { episode(published: now.addingTimeInterval(-Double($0)), played: false) }
                + (0..<others).map { episode(published: now.addingTimeInterval(-Double($0)), played: true) }
                + (0..<others).map { episode(published: now.addingTimeInterval(-1e9 - Double($0)), played: false) }
            feeds.append(f)
            for number in 0..<otherFeeds {
                var other = LibraryFeed(id: Int64(number + 2), source: "s\(number + 2)", metadata: .init(format: .rss, title: "O"), episodes: [])
                other.subscriptionState = .subscribed
                other.episodes = (0..<200).map { episode(published: now.addingTimeInterval(-Double($0)), played: false) }
                feeds.append(other)
            }
            var mirror = Self.mirror(feeds)
            var model = HomeScreenModel(mirror: mirror, inboxSort: .dateNewest, seed: 3, now: now, includeMarkedAsPlayed: false)
            let pick = try #require(model.pick(of: 1))
            var played = try #require(mirror.episode(pick)?.episode)
            played.userState.playState = .played
            let delta = Self.change(&mirror, played, feed: 1)
            model.metrics = .init()
            model.apply(delta, mirror: mirror, now: now)
            #expect(model.surprise() == ScreenReference.surprise(mirror.feeds, seed: 3, now: model.now).map(\.1.id))
            #expect(model.pick(of: 1) != pick)
            return (model.metrics.populationVisited, model.metrics.candidateRescans)
        }
        var visited: [Int: Int] = [:]
        for recent in [10, 1_000, 3_000] {
            let base = try run(recent: recent, others: 0, otherFeeds: 1)
            #expect(base.rescans == 1)
            #expect(base.visited <= recent + 64, "linear in the recent population: \(base.visited) for \(recent)")
            // The podcast's played and old episodes, and other podcasts, add nothing.
            let crowded = try run(recent: recent, others: 3_000, otherFeeds: 20)
            #expect(crowded.visited <= base.visited + 1, "flat in non-candidates and other podcasts: \(crowded.visited) vs \(base.visited)")
            visited[recent] = crowded.visited
        }
        print("Surprise re-pick visits by recent population: \(visited.sorted { $0.key < $1.key })")
    }

    /// A search's kept matches cost a bounded number of bytes per match, counted honestly (the ID → key map, the
    /// chunks at their capacity and the directory).
    @Test func searchMatchesMemoryIsBoundedPerMatch() throws {
        for count in [2_000, 20_000] {
            var feed = LibraryFeed(id: 1, source: "s", metadata: .init(format: .rss, title: "F"), episodes: [])
            feed.subscriptionState = .subscribed
            feed.episodes = (1...count).map { LibraryEpisode(id: Int64($0), details: ParsedEpisode(title: "Episode \($0)",
                publicationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double($0)))) }
            let matches = try #require(try LibrarySearchMatches(query: "episode", feeds: [feed], feedID: nil, archived: false))
            #expect(matches.count == count)
            let perMatch = Double(matches.estimatedBytes) / Double(count)
            // Members are 16 bytes and each map entry another 16: anything below misses part of what is held.
            #expect(perMatch >= 32, "every structure counted: \(perMatch) B per match")
            #expect(perMatch <= 96, "bounded: \(perMatch) B per match")
            print("Search matches \(count): \(matches.estimatedBytes) bytes, \(perMatch) B per match")
        }
    }

    // MARK: - Mutations

#if DEBUG
    func caught(_ fault: OtherScreenFault, seed: UInt64 = 22, steps: Int = 120) async {
        otherScreenFaults = [fault]
        defer { otherScreenFaults = [] }
        await withKnownIssue("\(fault) is caught") {
            let (world, _) = try await Self.run(server: false, seed: seed, feeds: 8, episodesPerFeed: 60, steps: steps)
            #expect(world.problems.isEmpty, "\(world.problems.first ?? "")")
            await world.close()
        }
    }

    /// Home's Inbox, the search matches and the newest dates not patched, each caught by the comparison with a fresh
    /// read in a seeded sequence.
    @Test(arguments: [OtherScreenFault.homeInboxNotPatched, .searchNotPatched, .latestNotPatched])
    func otherScreenMutationIsCaught(fault: OtherScreenFault) async {
        await caught(fault)
    }

    /// The clock kept on Home's return and Shuffle.
    @Test func theClockKeptOnExplicitEventsIsCaught() {
        otherScreenFaults = [.clockKeptOnEvents]
        defer { otherScreenFaults = [] }
        withKnownIssue("the kept clock is caught") { homeReturnAndShuffleUseTheCurrentClock() }
    }

    /// The previous result keeping the matches (every match copied).
    @MainActor @Test func aCopiedMatchMapIsCaught() async {
        otherScreenFaults = [.searchPreviousKeepsMatches]
        defer { otherScreenFaults = [] }
        await withKnownIssue("the copied matches are caught") { try await aSearchPatchChangesItsMatchesInPlace(matches: 2_000) }
    }

    /// A pick that left kept, caught by the clock witness.
    @Test func aSurprisePickThatLeftKeptIsCaught() {
        otherScreenFaults = [.surpriseNotRepicked]
        defer { otherScreenFaults = [] }
        withKnownIssue("the kept pick is caught") { surpriseFollowsTheClockAndTheTieRule() }
    }

    /// Classics loaded on every patch, caught by the listening witness.
    @Test func classicsOnEveryPatchIsCaught() async {
        otherScreenFaults = [.classicsOnEveryPatch]
        defer { otherScreenFaults = [] }
        await withKnownIssue("Classics on every patch is caught") { try await classicsIgnoreListening() }
    }
#endif

    /// Classics follows its events, not listening (Android's `SubscriptionsSection` reloads on `FeedListUpdateEvent`
    /// only): listening that changes the ranking leaves Classics as loaded, equal to the full read at that load; Home's
    /// next open shows the new ranking.
    @Test func classicsIgnoreListening() async throws {
        let world = try await World.make(server: false, seed: 41, feeds: 4, episodesPerFeed: 10)
        let models = OtherScreenModels(seed: 41)
        world.observers = [models]
        models.opened(world)
        try await world.check("open")
        let before = try #require(models.home?.classics)
        // The last-ranked podcast is listened to for ten minutes: the full ranking now puts it first.
        let last = try #require(before.last)
        let episode = try #require(world.mirror.feed(last)?.episodes.first { $0.details.media != nil }).id
        try await world.player.load(episode); try await world.player.play()
        try await world.player.listen(600, every: 30); try await world.player.pause()
        try await world.patch(); try await world.check("listened")
        #expect(models.home?.classics == before, "Classics is not loaded again by listening")
        let snapshot = try await world.store.snapshot()
        let now = try #require(ScreenReference.classics(snapshot.feeds, units: snapshot.statisticsUnits, includeMarkedAsPlayed: false,
                                                        now: models.clock).first?.id)
        #expect(now == last, "the full read ranks the listened podcast first")
        try await world.open()
        #expect(models.home?.classics.first == last, "Home's next open shows it")
        #expect(world.problems.isEmpty, "\(world.problems)")
        await world.close()
    }
#if DEBUG

    /// (e)'s mutation: two screens sharing one stream (each set reaches one of them) differ from a fresh open.
    @MainActor @Test func aSharedStreamIsCaught() async {
        await withKnownIssue("one consumed stream is caught") { try await Self.twoScreens(sharedStream: true) }
    }

    /// (e)'s mutation: a sync set held by the pacing dropped when a local set overtakes it.
    @MainActor @Test func aSyncSetDroppedAfterALocalOvertakeIsCaught() async {
        await withKnownIssue("a dropped sync set is caught") { try await Self.twoScreens(sharedStream: false) { $0.updater.faults = [.dropOvertakenSync] } }
    }
#endif
}

extension LibrarySearchResult {
    /// The result as the screens show it: each episode a list projection.
    var listProjection: LibrarySearchResult {
        var result = self
        result.episodes = episodes.map { .init(feedID: $0.feedID, episode: $0.episode.listProjection, deletionTarget: $0.deletionTarget) }
        return result
    }
}
