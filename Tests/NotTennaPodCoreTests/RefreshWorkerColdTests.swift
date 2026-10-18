import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// The unchanged-refresh memo through the refresh worker: on a library opened afresh (a relaunch or a background
/// launch), choosing the feeds a refresh covers reads their headers only, so an unchanged refresh decodes no stored
/// episode, for all feeds and for one selected podcast, and a changed feed decodes only its own episodes. The selection
/// and its order are those of the whole-library read it replaces.
@Suite(.serialized)
struct RefreshWorkerColdTests {
    typealias Item = RefreshSharedReadsDifferentialTests.Item

    private struct NoEffects: FeedRefreshEffects {
        func handle(_ event: FeedRefreshWorker.Event, request: FeedRefreshRequest) async throws {}
    }

    private static func network() -> DownloadNetworkMonitor {
        let monitor = DownloadNetworkMonitor(startMonitoring: false)
        monitor.update(.init(connected: true, metered: false, cellular: false))
        return monitor
    }

    /// One worker run of `request` over prepared parses (no network): each refresh's `itemsUnchanged`, by feed.
    private static func run(_ request: FeedRefreshRequest, store: FeedLibraryStore, parses: [Int64: FetchedFeed],
                            options: FeedRefreshOptions) async throws -> [Int64: Bool] {
        let results = Mutex<[Int64: Bool]>([:])
        try await store.enqueueManualRefresh(request)
        let worker = FeedRefreshWorker(store: store, network: network(), effects: NoEffects(), shuffle: { $0 }) { feed, _ in
            guard let fetched = parses[feed.id] else { Issue.record("no parse for \(feed.id)"); return .failed }
            let result = try await store.applyRefresh(fetched, feedID: feed.id, options: options)
            results.withLock { $0[feed.id] = result.itemsUnchanged }
            return .updated(result.feed)
        }
        try await worker.run(request)
        return results.withLock { $0 }
    }

    @Test func aColdRefreshWorkerDecodesOnlyTheChangedFeeds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RefreshWorkerCold-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let sizes = (0..<100).map { 450 + ($0 * 37) % 201 }
        func feed(_ index: Int, extra: Bool = false) -> FetchedFeed {
            var items = RefreshMemoTests.items(sizes[index], prefix: "f\(index)-", host: "media\(index).example.test")
            if extra { items.append(Item(guid: "f\(index)-new", title: "New", description: "New", day: 9_999, url: "https://media\(index).example.test/new.mp3")) }
            var fetched = RefreshMemoTests.feed(items, source: "https://example.test/\(index).xml", title: "Show \(index)")
            fetched.parseDigest = FeedLibraryStore.refreshParseDigest(fetched)
            return fetched
        }
        // 100 podcasts, 54,888 episodes, each with its memo proven by an unchanged refresh.
        var store = try FeedLibraryStore(url: url)
        var feedIDs: [Int64] = []
        for index in sizes.indices { feedIDs.append(try await store.insert(feed(index), options: RefreshMemoTests.options(0)).id) }
        for index in sizes.indices { _ = try await store.applyRefresh(feed(index), feedID: feedIDs[index], options: RefreshMemoTests.options(1)) }
        try await store.close()
        var parses: [Int64: FetchedFeed] = [:]
        for index in sizes.indices { parses[feedIDs[index]] = feed(index) }

        store = try FeedLibraryStore(url: url)
        var decoded = await store.episodeRecordsDecoded
        var started = ContinuousClock.now
        let all = try await Self.run(FeedRefreshRequest(feedID: nil, enqueuedAt: .distantPast), store: store, parses: parses,
                                     options: RefreshMemoTests.options(2))
        let allTime = started.duration(to: .now)
        let allDecoded = await store.episodeRecordsDecoded - decoded
        #expect(all.count == 100 && all.values.allSatisfy { $0 })
        #expect(allDecoded == 0)
        try await store.close()

        store = try FeedLibraryStore(url: url)
        decoded = await store.episodeRecordsDecoded
        started = ContinuousClock.now
        let one = try await Self.run(FeedRefreshRequest(feedID: feedIDs[17], enqueuedAt: .distantPast), store: store, parses: parses,
                                     options: RefreshMemoTests.options(3))
        let oneTime = started.duration(to: .now)
        let oneDecoded = await store.episodeRecordsDecoded - decoded
        #expect(one == [feedIDs[17]: true])
        #expect(oneDecoded == 0)
        try await store.close()

        // One podcast changed: it decodes its own episodes, once; the other 99 apply their memos.
        parses[feedIDs[42]] = feed(42, extra: true)
        store = try FeedLibraryStore(url: url)
        decoded = await store.episodeRecordsDecoded
        started = ContinuousClock.now
        let changed = try await Self.run(FeedRefreshRequest(feedID: nil, enqueuedAt: .distantPast), store: store, parses: parses,
                                         options: RefreshMemoTests.options(4))
        let changedTime = started.duration(to: .now)
        let changedDecoded = await store.episodeRecordsDecoded - decoded
        #expect(changed.count == 100 && changed.filter { !$0.value }.map(\.key) == [feedIDs[42]])
        #expect(changedDecoded == sizes[42])
        try await store.close()
        print("Unchanged refresh worker budget, library opened afresh, 100 feeds, \(sizes.reduce(0, +)) episodes: all \(allTime), \(allDecoded) decoded; "
              + "one selected \(oneTime), \(oneDecoded) decoded; one changed \(changedTime), \(changedDecoded) decoded (its \(sizes[42]))")
    }

    /// The feeds a request covers, and their order, from headers equal those from whole feeds: subscribed, archived,
    /// previews, keep-updated off, a local folder, a pinned removal, a hidden (staged) podcast, titles in mixed case;
    /// all feeds, a selected podcast (also one no list shows), and periodic refreshes due and not due.
    @Test(arguments: [false, true])
    func headerSelectionEqualsWholeFeedSelection(server: Bool) async throws {
        let fixture = try await ServerLibraryFixture(server: server)
        defer { Task { await fixture.close() } }
        let store = fixture.store
        let now = ServerLibraryFixture.now
        func add(_ title: String, _ index: Int, local: Bool = false, attempt: TimeInterval = 0) async throws -> Int64 {
            var options = FeedRefreshOptions(now: now.addingTimeInterval(attempt), timeZone: .gmt)
            options.isLocalFeed = local
            var fetched = RefreshMemoTests.feed(RefreshMemoTests.items(3, prefix: "s\(index)-"), source: "https://example.test/select-\(index).xml", title: title)
            if local { fetched.source = LibraryFeed.localSourcePrefix + "folder-\(index)"; fetched.catalog = nil }
            return try await store.insert(fetched, options: options).id
        }
        var ids: [Int64] = []
        for (index, title) in ["beta", "Alpha", "gamma", "alpha", "Delta", "epsilon", "Zeta", "eta", "theta"].enumerated() {
            ids.append(try await add(title, index, local: index == 7, attempt: Double(index) * -3_600))
        }
        // Set in the stored headers directly (a server library takes these only from its sync).
        for (id, path, value) in [(ids[2], "$.keepUpdatedValue", "json('false')"), (ids[3], "$.subscriptionState", "2"), (ids[4], "$.subscriptionState", "1")] {
            try await store.executeForTesting("UPDATE feeds SET record = CAST(json_set(CAST(record AS TEXT), '\(path)', \(value)) AS BLOB) WHERE id = ?", [.integer(id)])
        }
        let kept = try await store.feedHeader(id: ids[2]), archived = try await store.feedHeader(id: ids[3]), preview = try await store.feedHeader(id: ids[4])
        #expect(kept?.keepUpdated == false && archived?.subscriptionState == .archived && preview?.subscriptionState == .notSubscribed)
        try await store.executeForTesting("INSERT INTO pinned_feed_removals(feed_id) VALUES (?)", [.integer(ids[5])])
        if server {
            try await store.executeForTesting("INSERT INTO ntp_hidden_feeds(feed_id, state) VALUES (?, 'staging')", [.integer(ids[6])])
        }
        let wholeFeeds = try await store.feeds(), headers = try await store.feedHeaders()
        #expect(headers.map(\.id) == wholeFeeds.map(\.id))
        #expect(headers == wholeFeeds.map { var header = $0; header.episodes = []; return header })
        #expect(headers.allSatisfy(\.episodes.isEmpty) && wholeFeeds.contains { !$0.episodes.isEmpty })
        var requests = [FeedRefreshRequest(feedID: nil, enqueuedAt: now)]
        requests += [ids[0], ids[2], ids[3], ids[5], ids[6], ids[7], 999].map { FeedRefreshRequest(feedID: $0, enqueuedAt: now) }
        for interval in [60, 240, 1_440] {
            requests.append(FeedRefreshRequest(periodic: PeriodicFeedRefreshSchedule(intervalMinutes: interval, allowMobile: true, now: now), enqueuedAt: now))
        }
        for request in requests {
            for at in [now, now.addingTimeInterval(4 * 3_600)] {
                let expected = request.eligibleFeeds(from: wholeFeeds, now: at).map(\.id)
                #expect(request.eligibleFeeds(from: headers, now: at).map(\.id) == expected, "\(request.feedID.map(String.init) ?? "all") \(request.periodic?.intervalMinutes ?? 0)")
            }
        }
    }
}
