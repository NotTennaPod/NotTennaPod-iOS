import Foundation
import Synchronization

public struct FeedRefreshService: Sendable {
    public enum Outcome: Equatable, Sendable {
        case unchanged
        case updated(FeedRefreshResult)
        case failed(FeedFetchError)
    }

    private let store: FeedLibraryStore
    private let fetcher: FeedFetcher
    private let clock: @Sendable () -> Date

    public init(store: FeedLibraryStore, fetcher: FeedFetcher = FeedFetcher(),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.fetcher = fetcher
        self.clock = clock
    }

    public func refresh(feedID: Int64, force: Bool = false, nextPage: Bool = false,
                        credentials: FeedCredentials? = nil,
                        options: FeedRefreshOptions = FeedRefreshOptions(), manualRequestID: UUID? = nil) async throws -> Outcome {
        try Task.checkCancellation()
        // The header is all a fetch needs: no episode of the feed is read before the merge.
        guard let feed = try await store.refreshHeader(id: feedID) else { throw FeedLibraryError.missingFeed(feedID) }
        let pageURL = nextPage ? feed.metadata.nextPageURL : nil
        // A server library parses with the parity parse.
        let request = FeedFetchRequest(source: pageURL ?? feed.source, validator: feed.validator,
                                       credentials: credentials, force: force || feed.lastUpdateFailed,
                                       parity: await store.isServerLibrary && !feed.source.isLocalFeedSource)
        let fetched: FeedFetchResult
        let diagnostic = Mutex<String?>(nil)
        do { fetched = try await fetcher.fetch(request, failureDiagnostic: { message in diagnostic.withLock { $0 = message } }) }
        catch let failure as FeedFetchError {
            try Task.checkCancellation()
            try await store.recordFailure(failure, feedID: feedID, date: clock(),
                                          diagnostic: diagnostic.withLock { $0 }, manualRequestID: manualRequestID)
            return .failed(failure)
        }
        try Task.checkCancellation()
        switch fetched {
        case .notModified:
            // Unchanged: this device's attempt is noted for its details only; observations waiting for this feed are
            // recorded now (PROTOCOL §9.4).
            try await store.recordUnchangedRefresh(feedID: feedID, date: clock())
            if await store.isServerLibrary { try? await FeedLibraryStore.drainObservations(store, feedID: feedID, catalog: nil, items: [:]) }
            return .unchanged
        case .updated(var result):
            var settings = options
            settings.now = clock()
            settings.refreshAttempt = settings.now
            settings.pageNumber = feed.pageNumber + (pageURL == nil ? 0 : 1)
            // The parse's digest for the store's unchanged-refresh check (`FeedRefreshMemo`), made here rather than on
            // the store.
            if settings.pageNumber == 0 { result.parseDigest = FeedLibraryStore.refreshParseDigest(result) }
            let refreshed = try await store.applyRefresh(result, feedID: feedID, options: settings, manualRequestID: manualRequestID)
            // An unchanged refresh observed nothing new: observations waiting for this feed are recorded as after a 304.
            if refreshed.itemsUnchanged {
                if await store.isServerLibrary { try? await FeedLibraryStore.drainObservations(store, feedID: feedID, catalog: nil, items: [:]) }
                return .updated(refreshed)
            }
            // A server library's large batch: its other observations in bounded transactions (PROTOCOL §9.4). The refresh
            // has committed; what this cannot record stays listed for the next push.
            if let catalog = result.catalog, !refreshed.serverItems.isEmpty {
                try? await FeedLibraryStore.drainObservations(store, feedID: feedID, catalog: catalog, items: refreshed.serverItems)
            }
            return .updated(refreshed)
        }
    }
}
