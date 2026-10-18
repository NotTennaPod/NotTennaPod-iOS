import Foundation
import Testing
@testable import NotTennaPodCore

/// A refresh run does no whole-library work it does not need: a header-only change keeps the decoded episodes,
/// the notification baseline reads only feeds with notifications on, and expiry cleanup looks only at previews.
@MainActor @Suite struct RefreshLibraryWorkTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func options(_ offset: TimeInterval = 0) -> FeedRefreshOptions {
        FeedRefreshOptions(now: now.addingTimeInterval(offset), timeZone: .gmt)
    }

    private func fetched(_ identifiers: [String], source: String) -> FetchedFeed {
        let episodes = identifiers.enumerated().map { offset, id in
            ParsedEpisode(identifier: id, title: "Episode \(id)", description: "Notes \(id)",
                          publicationDate: now.addingTimeInterval(Double(offset)),
                          media: ParsedMedia(url: "\(source)/\(id).mp3", size: 1_000, durationMilliseconds: 60_000))
        }
        return FetchedFeed(feed: ParsedFeed(format: .rss, title: source, episodes: episodes), source: source,
                           responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil)
    }

    private func withLibrary(_ operation: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RefreshWork-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        do { try await operation(store, url); try await store.close() }
        catch { try? await store.close(); throw error }
    }

    private func freshSnapshot(_ url: URL) async throws -> FeedLibrarySnapshot {
        let fresh = try FeedLibraryStore(url: url)
        let snapshot = try await fresh.snapshot()
        try await fresh.close()
        return snapshot
    }

    /// Nothing decoded stays in the store: an unchanged refresh and an episode change read no feed's episodes,
    /// and every read equals a fresh store's.
    @Test func refreshThatOnlyRecordsTheAttemptReadsNoFeedEpisodes() async throws {
        try await withLibrary { store, url in
            let ids = (0..<30).map { "e\($0)" }
            let feed = try await store.insert(fetched(ids, source: "https://example.test/a"), options: options())
            _ = try await store.applyRefresh(fetched(ids, source: "https://example.test/a"), feedID: feed.id, options: options())
            _ = try await store.applyRefresh(fetched(ids, source: "https://example.test/a"), feedID: feed.id, options: options(1))
            let reads = await store.feedEpisodeReads

            // A later refresh with the same episodes records only its attempt time in the header.
            let result = try await store.applyRefresh(fetched(ids, source: "https://example.test/a"), feedID: feed.id, options: options(3_600))
            #expect(result.feed.lastRefreshAttempt == now.addingTimeInterval(3_600))
            #expect(await store.feedEpisodeReads == reads)
            let snapshot = try await store.snapshot()
            #expect(snapshot.feeds.first?.lastRefreshAttempt == now.addingTimeInterval(3_600))
            #expect(snapshot == (try await freshSnapshot(url)))

            // An episode change reads no feed either; the next read sees it.
            let before = await store.feedEpisodeReads
            try await store.markEpisodePlayed(episodeID: feed.episodes[0].id, played: true)
            #expect(await store.feedEpisodeReads == before)
            let changed = try await store.snapshot()
            #expect(changed.feeds.first?.episodes.first { $0.id == feed.episodes[0].id }?.userState.playState == .played)
            #expect(changed == (try await freshSnapshot(url)))
        }
    }

    @Test func notificationBaselineReadsOnlyFeedsWithNotificationsOn() async throws {
        try await withLibrary { store, url in
            let quiet = try await store.insert(fetched(["q1", "q2"], source: "https://example.test/quiet"), options: options())
            let loud = try await store.insert(fetched(["l1", "l2", "l3"], source: "https://example.test/loud"), options: options())
            let late = try await store.insert(fetched(["x1"], source: "https://example.test/late"), options: options())
            for id in loud.episodes.prefix(2).map(\.id) + late.episodes.map(\.id) {
                try await store.updateEpisode(id: id) { $0.userState.playState = .new }
            }
            // A record the baseline must not need: reading it would fail.
            let other = try LibrarySQLite(url: url)
            try other.execute("UPDATE episodes SET record = x'7B' WHERE feed_id = ?", [.integer(quiet.id)])
            try other.close()

            let request = FeedRefreshRequest(feedID: nil, enqueuedAt: now)
            try await store.enqueueManualRefresh(request)
            let none = try await store.beginEpisodeNotificationAttempt(requestID: request.id)
            #expect(none.counts.isEmpty && none.notifyingFeedIDs == [])

            try await store.updatePreferences(feedID: loud.id) { $0.showEpisodeNotification = true }
            let baseline = try await store.beginEpisodeNotificationAttempt(requestID: request.id)
            #expect(baseline.counts == [loud.id: 2] && baseline.notifyingFeedIDs == [loud.id])

            // Notifications switched on during the attempt have no baseline count: no notification this run.
            try await store.updatePreferences(feedID: late.id) { $0.showEpisodeNotification = true }
            let lateFeed = try #require(try await store.feed(id: late.id))
            #expect(try await store.stageEpisodeNotification(lateFeed, baseline: baseline) == nil)
            let loudFeed = try #require(try await store.feed(id: loud.id))
            let pending = try #require(try await store.stageEpisodeNotification(loudFeed, baseline: baseline))
            #expect(pending.beforeCount == 2)
        }
    }

    @Test func expiryCleanupWithOnlySubscriptionsCommitsNothingAndDoesNotNotify() async throws {
        try await withLibrary { store, _ in
            for index in 0..<10 { _ = try await store.insert(fetched(["e"], source: "https://example.test/\(index)"), options: options()) }
            var changes = 0
            let owner = FeedDeletionCoordinator(store: store, retirePlayback: { _ in }, retireDownloads: { _ in })
            owner.onChange = { changes += 1 }
            let request = FeedRefreshRequest(feedID: nil, enqueuedAt: now)
            try await store.enqueueManualRefresh(request)
            let commits = await store.writeCommits
            try await owner.cleanExpired(requestID: request.id, now: now.addingTimeInterval(100 * 86_400)).value
            #expect(await store.writeCommits - commits <= 1)
            #expect(changes == 0)
            #expect(try await store.feeds().count == 10)
        }
    }

    @Test func expiryCleanupDeletesOnlyExpiredUnprotectedPreviewsInOneTransaction() async throws {
        try await withLibrary { store, _ in
            let subscribed = try await store.insert(fetched(["s"], source: "https://example.test/s"), options: options())
            let expired = try await store.preparePreview(fetched(["p"], source: "https://example.test/p"), now: now)
            let queued = try await store.preparePreview(fetched(["q"], source: "https://example.test/q"), now: now)
            let fresh = try await store.preparePreview(fetched(["f"], source: "https://example.test/f"), now: now.addingTimeInterval(2 * 86_400))
            _ = try await store.enqueue([queued.episodes[0].id, subscribed.episodes[0].id])
            var changes = 0
            let owner = FeedDeletionCoordinator(store: store, retirePlayback: { _ in }, retireDownloads: { _ in })
            owner.onChange = { changes += 1 }
            let request = FeedRefreshRequest(feedID: nil, enqueuedAt: now)
            try await store.enqueueManualRefresh(request)
            let commits = await store.writeCommits
            try await owner.cleanExpired(requestID: request.id, now: now.addingTimeInterval(2 * 86_400 + 1)).value
            #expect(try await store.feeds().map(\.id).sorted() == [subscribed.id, queued.id, fresh.id].sorted())
            #expect(try await store.feed(id: expired.id) == nil)
            #expect(try await store.queue().map(\.id) == [queued.episodes[0].id, subscribed.episodes[0].id])
            #expect(changes >= 1)
            // One deletion transaction plus the drained deletion effect's completion.
            #expect(await store.writeCommits - commits == 2)
            #expect(try await store.pendingEffects().allSatisfy { if case .deleteFeed = $0.effect.kind { false } else { true } })
        }
    }
}
