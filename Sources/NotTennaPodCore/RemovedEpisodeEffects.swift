import Foundation

/// Diagnoses retained work without exposing feed URLs or local document paths.
/// A legacy record may lack enough historical context to delete files safely.
public enum RemovedEpisodeEffectsError: Error, Equatable, Sendable {
    public struct Failure: Equatable, Sendable {
        public enum Reason: String, Sendable { case missingLegacyContext, cleanupFailed }
        public let effectID: Int64
        public let reason: Reason
    }
    case incomplete([Failure])
}

/// Uses the application's existing deletion command queue, so a removed feed
/// and a removed episode cannot race their shared playback/download owners.
@MainActor
final class RemovedEpisodeEffectRecipient {
    private let store: FeedLibraryStore
    private let retirePlayback: @MainActor (Set<Int64>) async throws -> Void
    private let retireDownloads: @MainActor (Set<Int64>) async throws -> Void
    private let removeFile: @Sendable (URL) throws -> Void

    init(store: FeedLibraryStore,
         retirePlayback: @escaping @MainActor (Set<Int64>) async throws -> Void,
         retireDownloads: @escaping @MainActor (Set<Int64>) async throws -> Void,
         removeFile: @escaping @Sendable (URL) throws -> Void) {
        self.store = store; self.retirePlayback = retirePlayback
        self.retireDownloads = retireDownloads; self.removeFile = removeFile
    }

    func deliver(_ pending: PendingFeedLibraryEffect) async throws {
        guard let cleanup = try await store.prepareRemovedEpisodeCleanup(effectID: pending.id) else { return }
        try await retirePlayback(cleanup.episodeIDs)
        try Task.checkCancellation()
        try await retireDownloads(cleanup.downloadJobIDs)
        try Task.checkCancellation()
        try await store.removeFilesForRemovedEpisodes(effectID: pending.id, removeFile: removeFile)
        try await store.completeRemovedEpisodeCleanup(effectID: pending.id)
    }
}
