import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.timeLimit(.minutes(1))) struct FeedPreviewSubscriptionTests {
    private let now = Date(timeIntervalSince1970: 1700000000)
    private func fixture(_ body: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Preview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library.sqlite"), store = try FeedLibraryStore(url: file)
        do { try await body(store, file); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    private var fetched: FetchedFeed {
        .init(feed: .init(format: .rss, title: "Preview", episodes: (1...4).map {
            .init(identifier: "\($0)", title: "Episode \($0)", publicationDate: now.addingTimeInterval(Double($0)),
                media: $0 == 4 ? nil : .init(url: "https://example.org/\($0).mp3", size: 100, durationMilliseconds: 30000))
        }), source: "https://example.org/feed", responseURL: URL(string: "https://example.org/feed")!, validator: "etag", permanentRedirectURL: nil)
    }
    @Test func previewRefreshUsesStrictAgeAndSubscriptionState() {
        for state in [FeedSubscriptionState.notSubscribed, .subscribed, .archived] {
            for age in [-1.0, 0, 86_399.999, 86_400, 86_400.001] {
                var feed = LibraryFeed(id: 1, source: fetched.source, metadata: fetched.feed, episodes: [])
                feed.subscriptionState = state; feed.lastRefreshAttempt = now.addingTimeInterval(-age)
                #expect(feed.needsPreviewRefresh(at: now) == (state == .notSubscribed && age > 86_400))
                feed.lastRefreshAttempt = nil
                #expect(feed.needsPreviewRefresh(at: now) == (state == .notSubscribed))
            }
        }
    }

    @Test(arguments: [false, true]) func previewPersistsThenSubscribePreservesStateAndQueuesSourceEffects(connected: Bool) async throws {
        try await fixture { store, file in
            if connected { try await store.selectSynchronizationAccount(UUID()) }
            let feed = try await store.preparePreview(fetched, now: now)
            #expect(feed.subscriptionState == .notSubscribed && !feed.keepUpdated)
            #expect(feed.lastRefreshAttempt == now && feed.episodes.count == 4)
            #expect(try await store.pendingEffects().isEmpty)
            #expect(try await store.synchronizationQueue().isEmpty)
            for episode in feed.episodes where episode.details.identifier != "2" {
                try await store.updateEpisode(id: episode.id) { $0.userState.playState = .played; $0.userState.isFavorite = true }
            }
            _ = try await store.enqueueAt(feed.episodes[1].id, index: 0)
            let before = try #require(try await store.feed(id: feed.id)), queue = try await store.queue()
            let changed = try await store.subscribePreview(feedID: feed.id, now: now.addingTimeInterval(10))
            #expect(changed)
            let subscribed = try #require(try await store.feed(id: feed.id))
            #expect(subscribed.keepUpdated && subscribed.subscriptionState == .subscribed)
            #expect(subscribed.episodes == before.episodes && subscribed.validator == before.validator)
            #expect(try await store.queue() == queue)
            // The subscription and played actions go only to a connected account's outbox.
            let effects = try await store.pendingEffects()
            #expect(effects.isEmpty)
            let sync = try await store.synchronizationQueue()
            #expect(sync.count == (connected ? 3 : 0))
            if connected { #expect(sync.first?.value == .added(feed.source)) }
            let actions = sync.compactMap { change -> SynchronizationEpisodeAction? in if case .episode(let event) = change.value { event } else { nil } }
            if connected {
                #expect(actions.map(\.guid) == ["3", "1"])
                #expect(actions.allSatisfy { $0.action == .play && $0.started == 30 && $0.position == 30 && $0.total == 30 })
            }
            #expect(try await !store.subscribePreview(feedID: feed.id, now: now))
            #expect(try await store.pendingEffects() == effects)
            let reopened = try FeedLibraryStore(url: file)
            #expect(try await reopened.feed(id: feed.id) == subscribed)
            try await reopened.close()
        }
    }
    @Test func cancelledPreparationLeavesExistingMetadataAndPreferencesUntouched() async throws {
        try await fixture { store, _ in
            let feed = try await store.preparePreview(fetched, now: now)
            var update = fetched; update.feed.description = "Cancelled replacement"
            let supplied = update
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await store.preparePreview(supplied, now: now.addingTimeInterval(5))
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.feed(id: feed.id) == feed)
            #expect(try await store.pendingEffects().isEmpty)
        }
    }
    @Test(arguments: [FeedSubscriptionState.archived, .subscribed])
    func existingIdentityIsNotDemotedOrResubscribed(state: FeedSubscriptionState) async throws {
        try await fixture { store, _ in
            let feed = try await store.insert(fetched, subscriptionState: state)
            try await store.updatePreferences(feedID: feed.id) { $0.keepUpdated = false }
            let effects = try await store.pendingEffects()
            let preview = try await store.preparePreview(fetched, now: now)
            #expect(preview.id == feed.id && preview.subscriptionState == state && !preview.keepUpdated)
            #expect(try await !store.subscribePreview(feedID: feed.id))
            #expect(try await store.pendingEffects() == effects)
        }
    }
}
