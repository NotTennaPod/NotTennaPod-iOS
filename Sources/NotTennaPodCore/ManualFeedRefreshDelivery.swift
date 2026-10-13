import Foundation

/// The selected application's completion recipients. Per-feed notification
/// progress starts inside the worker; the list uses the owner's active state.
@MainActor public final class ManualFeedRefreshDelivery: FeedRefreshEffects {
    public struct Progress: Equatable, Sendable {
        public let requestID: UUID
        public let remainingFeedIDs: [Int64]
    }
    public private(set) var progress: Progress?
    public var onChange: ((Progress?) -> Void)?
    private let store: FeedLibraryStore
    private let deletion: FeedDeletionCoordinator
    private let notifications: EpisodeNotificationDelivery
    private let automaticDownloads: AutomaticDownloadCoordinator
    private let allowMobileSync: @MainActor () -> Bool
    private let libraryChanged: @MainActor () async -> Void
    private let feedRefreshed: @MainActor () async -> Void
    private let consumeQueueEffects: @MainActor () async throws -> Void

    public init(store: FeedLibraryStore, deletion: FeedDeletionCoordinator,
                notifications: EpisodeNotificationDelivery, automaticDownloads: AutomaticDownloadCoordinator,
                allowMobileSync: @escaping @MainActor () -> Bool,
                libraryChanged: @escaping @MainActor () async -> Void,
                feedRefreshed: (@MainActor () async -> Void)? = nil,
                consumeQueueEffects: (@MainActor () async throws -> Void)? = nil) {
        self.store = store; self.deletion = deletion; self.notifications = notifications
        self.automaticDownloads = automaticDownloads; self.allowMobileSync = allowMobileSync
        self.libraryChanged = libraryChanged
        self.feedRefreshed = feedRefreshed ?? libraryChanged
        self.consumeQueueEffects = consumeQueueEffects ?? { _ = try await store.consumeFeedRefreshQueueEffects() }
    }

    public func handle(_ event: FeedRefreshWorker.Event, request: FeedRefreshRequest) async throws {
        try Task.checkCancellation()
        guard try await store.refreshRequest(id: request.id) != nil else { throw CancellationError() }
        try Task.checkCancellation()
        switch event {
        case .prepareNotifications: try await notifications.prepare(requestID: request.id)
        case .remaining(let feeds):
            publish(.init(requestID: request.id, remainingFeedIDs: feeds.map(\.id)))
        case .refreshed(let feed):
            try await consumeQueueEffects()
            try await notifications.refreshed(feed, requestID: request.id)
            // A server library's releases (PROTOCOL §9.9); nothing in a standalone library.
            if await store.isServerLibrary { try await notifications.deliverServerReleases() }
            // `feedRefreshed` (when given) lets the lists catch up without holding the next podcast back,
            // like FeedUpdateWorker's update event; the final `libraryChanged` below is awaited.
            await feedRefreshed()
        case .cleanUnsubscribedFeeds:
            try await deletion.cleanExpired(requestID: request.id).value
            await libraryChanged()
        case .autoDownload: try await automaticDownloads.request(manualRequestID: request.id)
        case .dismissProgress: clear(requestID: request.id)
        case .synchronize:
            // FeedUpdateWorker calls syncImmediately, including when there is
            // no account (the sync worker then exits without contacting a server).
            try await store.requestSynchronization(immediately: true, manualRequestID: request.id,
                                                    allowMobile: allowMobileSync())
        }
    }

    /// Clear only this execution's progress on failure/suspension/replacement.
    /// Queued work and network waiting must not masquerade as an active refresh.
    public func clear(requestID: UUID) {
        guard progress?.requestID == requestID else { return }
        publish(nil)
    }
    private func publish(_ value: Progress?) { progress = value; onChange?(value) }
}
