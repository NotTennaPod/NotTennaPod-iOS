import Foundation
import Testing
@testable import NotTennaPodCore

/// The incremental list index against the frozen full-reload reference, in memory: random libraries with colliding keys
/// (equal list milliseconds in different podcasts, NULL dates and durations, composed and decomposed titles), every list
/// kind and sort, and random changes applied one batch at a time. Plus the deterministic witnesses of each ordering rule.
@Suite struct EpisodeListIndexTests {
    typealias Random = ServerChangeSetCaptureTests.Random

    static func library(_ random: inout Random, feeds: Int, episodes: Int) -> [LibraryFeed] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return (0..<feeds).map { feedIndex in
            var feed = LibraryFeed(id: Int64(feedIndex + 1), source: "fixture://\(feedIndex)", metadata: .init(format: .rss, title: "F\(feedIndex)"), episodes: [])
            feed.subscriptionState = [.subscribed, .subscribed, .archived, .notSubscribed][feedIndex % 4]
            feed.episodes = (0..<episodes).map { number in episode(&random, id: Int64(feedIndex * 1_000 + number + 1), base: base) }
            return feed
        }
    }

    static func episode(_ random: inout Random, id: Int64, base: Date) -> LibraryEpisode {
        var details = ParsedEpisode(title: ["a", "B", "é", "e\u{301}", "a", nil][random.below(6)].map { $0 + "\(random.below(3))" })
        // Few distinct dates: ties across podcasts, sub-millisecond differences that round to the same key, and none.
        details.publicationDate = random.chance(10) ? nil : base.addingTimeInterval(Double(random.below(20)) + [0, 0.0004, 0.0006][random.below(3)])
        details.link = random.chance(20) ? nil : "file\(random.below(5))"
        if !random.chance(15) {
            details.media = ParsedMedia(url: "https://media.test/\(id)", size: Int64(random.chance(10) ? -1 : random.below(4)),
                                        durationMilliseconds: Int32(random.below(4) * 1_000))
        }
        var state = EpisodeUserState()
        state.playState = EpisodePlayState.allCases[random.below(EpisodePlayState.allCases.count)]
        state.isFavorite = random.chance(30)
        state.positionMilliseconds = random.chance(50) ? 0 : 1_000
        state.lastPlayedHistoryMilliseconds = random.chance(50) ? nil : Int64(random.below(5))
        state.isDownloaded = random.chance(30)
        state.downloadDate = state.isDownloaded ? Date(timeIntervalSince1970: 1) : nil
        return LibraryEpisode(id: id, details: details, userState: state)
    }

    static func reference(_ spec: EpisodeListSpec, _ feeds: [LibraryFeed], queued: Set<Int64>) -> [Int64] {
        switch spec {
        case .inbox(let sort): FullReloadReference.inbox(feeds, sort: sort).map(\.episode.id)
        case .favorites(let sort): FullReloadReference.favorites(feeds, sort: sort).map(\.episode.id)
        case .history: FullReloadReference.history(feeds).map(\.episode.id)
        case .episodes(let filter, let sort):
            FullReloadReference.allEpisodesRows(feeds, queuedEpisodes: queued.sorted().map { LibraryEpisode(id: $0, details: .init()) },
                                                filter: filter, sort: sort).map(\.episode.id)
        case .feed(let id, _, _):
            feeds.first { $0.id == id }.map { FullReloadReference.filteredDisplayEpisodes($0, queuedIDs: queued).map(\.id) } ?? []
        }
    }

    static func specs(_ feeds: [LibraryFeed]) -> [EpisodeListSpec] {
        var specs: [EpisodeListSpec] = [.history]
        for sort in EpisodeListSort.allCases { specs += [.inbox(sort), .favorites(sort), .episodes(.init(), sort)] }
        for values in [["unplayed", "not_queued"], ["is_favorite"], ["played", "include_archived"], ["queued", "include_not_subscribed"], ["paused", "has_media"], ["new", "not_downloaded"]] {
            specs.append(.episodes(.init(.init(values: values)), EpisodeListSort.allCases[values.count % 4]))
        }
        for order in FeedEpisodeSortOrder.allCases {
            var feed = feeds[0]
            feed.episodeSortOrderCode = order.rawValue
            feed.episodeFilterValues = order.rawValue % 3 == 0 ? ["not_queued"] : []
            specs.append(.feed(feed, globalSort: order == .global ? .sizeLargest : .dateNewest))
        }
        return specs
    }

    @Test(arguments: Array(UInt64(1)...20))
    func randomChangesKeepEveryListEqualToItsFullRead(seed: UInt64) {
        var random = Random(state: seed)
        let feeds = Self.library(&random, feeds: 6, episodes: 60)
        let queued = Set(feeds.flatMap(\.episodes).map(\.id).filter { _ in random.chance(20) })
        for spec in Self.specs(feeds) {
            var feedsCopy = feeds, queuedCopy = queued, generator = random
            // The podcast's own list follows the feed's stored filter and sort.
            if case .feed(_, let filter, let order) = spec {
                feedsCopy[0].episodeFilterValues = filter.values; feedsCopy[0].episodeSortOrderCode = order.rawValue
            }
            let candidates = feedsCopy.flatMap { feed in feed.episodes.map { (feed: feed, episode: $0) } }
            var index = EpisodeListIndex(spec: spec, candidates: candidates, queued: queuedCopy, capacity: 4)
            #expect(index.allIDs == Self.reference(spec, feedsCopy, queued: queuedCopy), "open \(spec)")
            for step in 0..<60 {
                var changes: [Int64: (feed: LibraryFeed, episode: LibraryEpisode)?] = [:]
                for _ in 0..<(1 + generator.below(6)) {
                    let feedIndex = generator.below(feedsCopy.count)
                    guard !feedsCopy[feedIndex].episodes.isEmpty else { continue }
                    let position = generator.below(feedsCopy[feedIndex].episodes.count)
                    let id = feedsCopy[feedIndex].episodes[position].id
                    switch generator.below(6) {
                    case 0: feedsCopy[feedIndex].episodes.remove(at: position)
                    case 1: queuedCopy.formSymmetricDifference([id])
                    default: feedsCopy[feedIndex].episodes[position] = Self.episode(&generator, id: id, base: Date(timeIntervalSince1970: 1_700_000_000))
                    }
                    changes.updateValue(feedsCopy[feedIndex].episodes.first { $0.id == id }.map { (feedsCopy[feedIndex], $0) }, forKey: id)
                }
                _ = index.apply(changes, queued: queuedCopy)
                let expected = Self.reference(spec, feedsCopy, queued: queuedCopy)
                #expect(index.allIDs == expected, "seed \(seed) \(spec) step \(step)")
                if index.allIDs != expected { return }
            }
        }
    }

    /// The change an update reports: removals from the list before (highest rank first), then insertions into the list
    /// after (lowest first), replayed on the shown window, give the list after.
    @Test func theReportedChangeReplaysTheListBeforeIntoTheListAfter() {
        var random = Random(state: 77)
        let feeds = Self.library(&random, feeds: 3, episodes: 80)
        let candidates = feeds.flatMap { feed in feed.episodes.map { (feed: feed, episode: $0) } }
        var index = EpisodeListIndex(spec: .inbox(.dateNewest), candidates: candidates, queued: [], capacity: 8)
        for _ in 0..<200 {
            let before = index.allIDs
            var changes: [Int64: (feed: LibraryFeed, episode: LibraryEpisode)?] = [:]
            for _ in 0..<(1 + random.below(5)) {
                let feed = feeds[random.below(feeds.count)]
                let id = feed.episodes[random.below(feed.episodes.count)].id
                changes.updateValue(random.chance(10) ? nil : (feed, Self.episode(&random, id: id, base: Date(timeIntervalSince1970: 1_700_000_000))), forKey: id)
            }
            let change = index.apply(changes, queued: [])
            var replay = before
            for removal in change.removed {
                #expect(replay[removal.rank] == removal.id)
                replay.remove(at: removal.rank)
            }
            for insertion in change.inserted { replay.insert(insertion.id, at: insertion.rank) }
            #expect(replay == index.allIDs)
        }
    }

    // MARK: Witnesses

    static func row(_ id: Int64, feed: Int64, date: Double?, duration: Int32? = 1_000, new: Bool = true, title: String? = nil) -> (LibraryFeed, LibraryEpisode) {
        var episode = LibraryEpisode(id: id, details: ParsedEpisode(title: title, publicationDate: date.map { Date(timeIntervalSince1970: $0) },
            media: duration.map { ParsedMedia(url: "u\(id)", size: 1, durationMilliseconds: $0) }))
        episode.userState.playState = new ? .new : .unplayed
        return (LibraryFeed(id: feed, source: "s\(feed)", metadata: .init(format: .rss), episodes: []), episode)
    }

    /// Episodes breaks equal dates by podcast, then episode (AntennaPod's query plan), not by episode alone.
    @Test func episodesTieByPodcastThenEpisode() {
        let rows = [Self.row(5, feed: 2, date: 100), Self.row(9, feed: 1, date: 100)]
        let index = EpisodeListIndex(spec: .episodes(.init(), .dateNewest), candidates: rows.map { (feed: $0.0, episode: $0.1) }, queued: [])
        #expect(index.allIDs == [9, 5])
        let byEpisode = EpisodeListIndex(spec: .episodes(.init(.init(values: ["played"])), .dateNewest),
            candidates: rows.map { row in var row = row; row.1.userState.playState = .played; return (feed: row.0, episode: row.1) }, queued: [])
        #expect(byEpisode.allIDs == [5, 9])
    }

    /// A missing duration sorts first shortest-first and last longest-first (SQLite's NULL).
    @Test func missingValuesSortAsSQLiteNull() {
        let rows = [Self.row(1, feed: 1, date: 1, duration: nil), Self.row(2, feed: 1, date: 1, duration: 5)].map { (feed: $0.0, episode: $0.1) }
        #expect(EpisodeListIndex(spec: .inbox(.durationShortest), candidates: rows, queued: []).allIDs == [1, 2])
        #expect(EpisodeListIndex(spec: .inbox(.durationLongest), candidates: rows, queued: []).allIDs == [2, 1])
    }

    /// A member whose key changed is found by the key it was placed by, not its new one.
    @Test func aRekeyedMemberLeavesItsOldPlace() {
        let rows = (1...5).map { Self.row(Int64($0), feed: 1, date: Double($0)) }
        var index = EpisodeListIndex(spec: .inbox(.dateNewest), candidates: rows.map { (feed: $0.0, episode: $0.1) }, queued: [])
        let moved = Self.row(2, feed: 1, date: 10)
        _ = index.apply([2: (moved.0, moved.1)], queued: [])
        #expect(index.allIDs == [2, 5, 4, 3, 1])
    }

    /// An equal primary key goes on the episode-ID side of its tie.
    @Test func anEqualKeyInsertsOnItsIDSide() {
        let rows = [Self.row(1, feed: 1, date: 5), Self.row(3, feed: 1, date: 5)]
        var index = EpisodeListIndex(spec: .inbox(.dateNewest), candidates: rows.map { (feed: $0.0, episode: $0.1) }, queued: [])
        let added = Self.row(2, feed: 1, date: 5)
        let change = index.apply([2: (added.0, added.1)], queued: [])
        #expect(index.allIDs == [1, 2, 3] && change.inserted == [.init(id: 2, rank: 1)])
    }

    /// Composed and decomposed titles are different bytes: a podcast's title sort keeps them apart, in byte order.
    @Test func titlesSortByTheirBytes() {
        let rows = [Self.row(1, feed: 1, date: 1, title: "e\u{301}"), Self.row(2, feed: 1, date: 1, title: "é"), Self.row(3, feed: 1, date: 1, title: "f")]
        let index = EpisodeListIndex(spec: .feed(1, .init(), .titleAscending), candidates: rows.map { (feed: $0.0, episode: $0.1) }, queued: [])
        #expect(index.allIDs == [1, 3, 2])
    }
}
