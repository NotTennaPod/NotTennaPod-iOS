import Foundation

/// Owns a manual local refresh independently of the currently displayed screen.
/// The Android manual work name uses REPLACE; superseded work cannot publish
/// terminal state for a newer request. Durable background scheduling is separate.
@MainActor
public final class LocalFolderCoordinator {
    public enum Event: Sendable, Equatable {
        case stateChanged
        case libraryChanged
        case storageFailed(String)
    }
    public private(set) var refreshingFeedID: Int64?
    public var onEvent: (@MainActor (Event) -> Void)?
    private let store: FeedLibraryStore
    private let refresh: @Sendable (Int64) async throws -> LocalFeedRefreshService.Outcome
    private var work: Task<Void, Never>?
    private var generation = UUID()

    public convenience init(store: FeedLibraryStore, description: String, author: String,
                            options: @escaping @Sendable () async -> FeedRefreshOptions = { .init() }) {
        self.init(store: store, refresh: { id in
            try await LocalFeedRefreshService(store: store).refresh(feedID: id, description: description, author: author,
                                                                 options: await options())
        })
    }

    init(store: FeedLibraryStore, refresh: @escaping @Sendable (Int64) async throws -> LocalFeedRefreshService.Outcome) {
        self.store = store; self.refresh = refresh
    }

    deinit { work?.cancel() }

    /// Registration returns before enumeration/metadata work completes, allowing
    /// the episode list to open while the first refresh is still running.
    public func add(_ selection: LocalFolderSelection, fallbackTitle: String) async throws -> LibraryFeed {
        let context = try await store.registerLocalFolder(title: selection.title ?? fallbackTitle,
            directoryIdentity: selection.identity, bookmark: selection.bookmark)
        startRefresh(feedID: context.feed.id)
        return context.feed
    }

    /// The original reconnect action changes access and URL, then reports OK;
    /// it does not automatically refresh or replace the feed's title/history.
    public func reconnect(_ selection: LocalFolderSelection, feedID: Int64) async throws {
        _ = try await store.reconnectLocalFolder(feedID: feedID, directoryIdentity: selection.identity,
                                                 bookmark: selection.bookmark)
        onEvent?(.libraryChanged)
    }

    public func startRefresh(feedID: Int64) {
        work?.cancel()
        let request = UUID(); generation = request
        refreshingFeedID = feedID
        onEvent?(.stateChanged)
        guard generation == request else { return }
        work = Task { [refresh, weak self] in
            let outcome: Result<LocalFeedRefreshService.Outcome, any Error>
            do { outcome = .success(try await refresh(feedID)) }
            catch { outcome = .failure(error) }
            guard let self, generation == request else { return }
            refreshingFeedID = nil; work = nil
            onEvent?(.stateChanged)
            guard generation == request else { return }
            switch outcome {
            case .success(.updated), .success(.failed): onEvent?(.libraryChanged)
            case .success(.superseded): break
            case .failure(is CancellationError): break
            case .failure(let error): onEvent?(.storageFailed(error.localizedDescription))
            }
        }
    }

    public func deleteMedia(target: EpisodeMediaDeletionTarget, playback: PlaybackCoordinator,
        removeFromQueue: Bool) async throws -> EpisodeMediaDeletionOutcome {
        guard case .local(let reference) = target.media else { throw FeedLibraryError.invalidMutation }
        let outcome = try await playback.deleteLocalMedia(target: target) { [store] in
            guard try await store.admitsMediaDeletion(target) else { return .stale }
            // Use only the captured grant; reconnect cannot redirect this I/O.
            let documents = LocalFolderDocuments(bookmark: reference.folder.bookmark)
            guard try await documents.delete(reference) != .stale else { return .stale }
            return try await store.recordLocalMediaDeletion(target: target, removeFromQueue: removeFromQueue)
        }
        guard outcome == .deleted else { return outcome }
        let refreshed = try await refresh(target.feedID)
        onEvent?(.libraryChanged)
        if case .failed(let failure) = refreshed { throw failure }
        return outcome
    }

    public func deleteMedia(episodeID: Int64, playback: PlaybackCoordinator, removeFromQueue: Bool) async throws {
        guard let reference = try await store.localDocument(episodeID: episodeID) else { throw FeedLibraryError.invalidMutation }
        let documents = LocalFolderDocuments(bookmark: reference.folder.bookmark)
        _ = try await documents.delete(fileNamed: reference.filename)
        try await store.recordLocalMediaDeletion(episodeID: episodeID, reference: reference, removeFromQueue: removeFromQueue)
        try await playback.retireDeletedEpisodes([episodeID])
        // The source requests a complete refresh, not a synthetic episode removal.
        let outcome = try await refresh(reference.folder.feedID)
        onEvent?(.libraryChanged)
        if case .failed(let failure) = outcome { throw failure }
    }
}
