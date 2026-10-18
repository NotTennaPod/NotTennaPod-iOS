import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite
struct ManualFeedRefreshDeliveryTests {
    private func withStore(_ body: (FeedLibraryStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RefreshDelivery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        do { try await body(store); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    private func fetched(_ url: String, title: String = "Old") -> FetchedFeed {
        .init(feed: .init(format: .rss, title: title), source: url,
              responseURL: URL(string: url)!, validator: nil, permanentRedirectURL: nil)
    }
    private func delivery(_ store: FeedLibraryStore, publisher: EpisodeNotificationDeliveryTests.Publisher,
                          changed: @escaping @MainActor () async -> Void = {}) -> ManualFeedRefreshDelivery {
        let deletion = FeedDeletionCoordinator(store: store, retirePlayback: { _ in }, retireDownloads: { _ in })
        let notifications = EpisodeNotificationDelivery(store: store, publisher: publisher,
            text: .init(title: { "New \($0)" }, message: { "\($1): \($0)" }, summary: "Inbox"), artwork: { _ in nil })
        // Suspended automatic owner: observe durable acceptance separately from
        // transfer completion, which refresh must not await.
        let automatic = AutomaticDownloadCoordinator(store: store, preferences: { .init() },
            environment: { .init(connection: .unavailable, allowMobile: false, charging: false) },
            cleanup: { _ in Issue.record("No cleanup expected") }, download: { _ in Issue.record("No transfer expected") })
        return .init(store: store, deletion: deletion, notifications: notifications,
            automaticDownloads: automatic, allowMobileSync: { true }, libraryChanged: changed)
    }

    @Test func realHTTPRefreshDeliversNotificationsCleansPreviewAndAcceptsImmediateFollowup() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(body: Data("""
        <rss version="2.0"><channel><title>Updated</title><item><guid>new</guid><title>New episode</title></item></channel></rss>
        """.utf8)) }
        defer { server.stop() }
        try await withStore { store in
            let feed = try await store.insert(fetched(server.url.absoluteString))
            try await store.updatePreferences(feedID: feed.id) { $0.showEpisodeNotification = true }
            let old = try await store.insert(fetched("https://example.org/expired"),
                options: .init(now: Date().addingTimeInterval(-172_800)), subscriptionState: .notSubscribed)
            let publisher = EpisodeNotificationDeliveryTests.Publisher()
            var reloads = 0
            let effects = delivery(store, publisher: publisher, changed: { reloads += 1 })
            var progress: [ManualFeedRefreshDelivery.Progress?] = []
            effects.onChange = { progress.append($0) }
            let network = DownloadNetworkMonitor(startMonitoring: false)
            network.update(.init(connected: true, metered: false, cellular: false))
            let owner = ManualFeedRefreshCoordinator(store: store, worker: .init(store: store,
                remote: .init(store: store), local: .init(store: store), localDescription: "Local", localAuthor: "Folder",
                network: network, credentials: { _ in nil }, options: { _ in .init() }, effects: effects))
            let request = try await owner.runOnce(feedID: feed.id).value
            try await owner.waitUntilIdle()
            #expect(owner.state == .idle)
            #expect(try await store.feed(id: feed.id)?.title == "Updated")
            #expect(try await store.feed(id: old.id) == nil)
            #expect(try await store.manualRefreshRequest() == nil)
            #expect(try await store.automaticDownloadRequest() != nil)
            let sync = try #require(try await store.synchronizationState().request)
            #expect(sync.notBefore <= Date())
            #expect(sync.network == .connected)
            #expect(publisher.posts.map(\.destination) == [.feed(feed.id), .inbox])
            #expect(progress.compactMap { $0?.requestID } == [request.id])
            #expect(progress.last! == nil)
            #expect(reloads >= 1)
        }
    }

    @Test(arguments: [NewEpisodesAction.global, .inbox, .queue, .nothing], [NewEpisodesAction.inbox, .queue, .nothing])
    func savedNewEpisodeActionReachesInboxOrQueueWithoutVisibleScreen(action: NewEpisodesAction, global: NewEpisodesAction) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("GlobalEpisodeAction-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let initial = try DownloadPreferenceStore(file: file)
        var value = initial.value; value.newEpisodesAction = global; try initial.update(value)
        let preferences = try DownloadPreferenceStore(file: file)
        let server = try await LoopbackHTTPServer.start { _ in .init(body: Data("""
        <rss version="2.0"><channel><title>Updated</title>
        <item><guid>new</guid><title>New episode</title><enclosure url="https://example.org/new.mp3" length="1000" type="audio/mpeg"/></item>
        <item><guid>existing</guid><title>Existing</title><enclosure url="https://example.org/existing.mp3" length="1000" type="audio/mpeg"/></item>
        </channel></rss>
        """.utf8)) }
        defer { server.stop() }
        try await withStore { store in
            var original = fetched(server.url.absoluteString)
            original.feed.episodes = [.init(identifier: "existing", title: "Existing",
                media: .init(url: "https://example.org/existing.mp3", size: 1000))]
            let feed = try await store.insert(original)
            let oldID = try #require(feed.episodes.first?.id)
            try await store.updateEpisode(id: oldID) { $0.userState.playState = .played; $0.userState.isFavorite = true }
            try await store.updatePreferences(feedID: feed.id) { $0.newEpisodesAction = action }
            let effects = delivery(store, publisher: .init())
            let network = DownloadNetworkMonitor(startMonitoring: false)
            network.update(.init(connected: true, metered: false, cellular: false))
            let owner = ManualFeedRefreshCoordinator(store: store, worker: .init(store: store,
                remote: .init(store: store), local: .init(store: store), localDescription: "Local", localAuthor: "Folder",
                network: network, credentials: { _ in nil }, options: { _ in
                    await MainActor.run {
                        var options = FeedRefreshOptions(); options.globalNewEpisodesAction = preferences.value.newEpisodesAction ?? .inbox
                        return options
                    }
                }, effects: effects))
            _ = try await owner.runOnce(feedID: feed.id).value
            try await owner.waitUntilIdle()
            #expect(owner.state == .idle)
            let saved = try #require(try await store.feed(id: feed.id))
            let added = try #require(saved.episodes.first { $0.details.identifier == "new" })
            let effective = action == .global ? global : action
            #expect(added.userState.playState == (effective == .inbox ? .new : .unplayed))
            #expect(try await store.queue().map(\.id) == (effective == .queue ? [added.id] : []))
            #expect(try await store.episode(id: oldID)?.userState.playState == .played)
            #expect(try await store.episode(id: oldID)?.userState.isFavorite == true)
            #expect(saved.newEpisodesAction == action)
            #expect(try await store.consumeFeedRefreshQueueEffects().isEmpty)
        }
    }

    @Test func replacedRequestsCannotEnqueueAutomaticOrSynchronizationWork() async throws {
        try await withStore { store in
            let old = FeedRefreshRequest(feedID: nil, enqueuedAt: Date())
            let new = FeedRefreshRequest(feedID: nil, enqueuedAt: Date())
            try await store.enqueueManualRefresh(old)
            try await store.enqueueManualRefresh(new)
            await #expect(throws: CancellationError.self) { try await store.requestAutomaticDownload(manualRequestID: old.id) }
            await #expect(throws: CancellationError.self) {
                try await store.requestSynchronization(immediately: true, manualRequestID: old.id, allowMobile: true)
            }
            #expect(try await store.automaticDownloadRequest() == nil)
            let state = try await store.synchronizationState()
            #expect(state.request == nil)
            #expect(!state.allowMobile)
        }
    }

    @Test func staleDismissCannotHideReplacementProgress() async throws {
        try await withStore { store in
            let effects = delivery(store, publisher: .init())
            let old = FeedRefreshRequest(feedID: nil, enqueuedAt: Date())
            let new = FeedRefreshRequest(feedID: nil, enqueuedAt: Date())
            try await store.enqueueManualRefresh(old)
            try await effects.handle(.remaining([]), request: old)
            try await store.enqueueManualRefresh(new)
            try await effects.handle(.remaining([]), request: new)
            effects.clear(requestID: old.id)
            #expect(effects.progress?.requestID == new.id)
            await #expect(throws: CancellationError.self) { try await effects.handle(.dismissProgress, request: old) }
            #expect(effects.progress?.requestID == new.id)
            effects.clear(requestID: new.id)
            #expect(effects.progress == nil)
        }
    }
}
