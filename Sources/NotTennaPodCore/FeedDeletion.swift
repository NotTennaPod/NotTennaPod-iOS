import Foundation
import Darwin

/// Durable external work committed with removal of a feed. External local-folder
/// documents never appear in files; unlinking is confined to recorded downloads.
public struct FeedDeletion: Codable, Equatable, Sendable {
    public let feedID: Int64
    public let episodeIDs: Set<Int64>
    public let downloadJobIDs: Set<Int64>
    public let files: [URL]
    public let source: String
    public let synchronize: Bool
    public let downloadedEpisodes: [LibraryEpisode]
    /// Nil binding decodes older records; a present binding can represent no account.
    struct AccountBinding: Codable, Equatable, Sendable { let id: UUID? }
    var synchronizationAccount: AccountBinding? = nil
}

public enum NonSubscribedFeedCleanup {
    public static func shouldDelete(_ feed: LibraryFeed, queuedIDs: Set<Int64>, now: Date) -> Bool {
        guard feed.subscriptionState == .notSubscribed else { return false }
        guard !feed.episodes.contains(where: {
            $0.userState.isFavorite || queuedIDs.contains($0.id) || $0.userState.isDownloaded
        }) else { return false }
        let interacted = feed.episodes.contains {
            $0.userState.playState == .played || ($0.details.media != nil && $0.userState.positionMilliseconds > 0)
        }
        let age = now.timeIntervalSince(feed.lastRefreshAttempt ?? Date(timeIntervalSince1970: 0))
        return age > (interacted ? 30 : 1) * 86_400
    }
}

/// One application-owned deletion queue. Commit first invalidates refresh,
/// playback and download persistence; external teardown is replayable after a
/// failure or restart. UI lifetime never cancels an accepted deletion.
@MainActor
public final class FeedDeletionCoordinator {
    private let store: FeedLibraryStore
    private let retirePlayback: @MainActor (Set<Int64>) async throws -> Void
    private let retireDownloads: @MainActor (Set<Int64>) async throws -> Void
    private let removeFile: @Sendable (URL) throws -> Void
    private let cleanupCredentials: @MainActor () async -> Void
    private let removedEpisodes: RemovedEpisodeEffectRecipient
    private var commands: Task<Void, Never>?
    public var onChange: (() -> Void)?

    public init(store: FeedLibraryStore,
                retirePlayback: @escaping @MainActor (Set<Int64>) async throws -> Void,
                retireDownloads: @escaping @MainActor (Set<Int64>) async throws -> Void,
                removeFile: @escaping @Sendable (URL) throws -> Void = FeedDeletionCoordinator.unlinkDownload,
                cleanupCredentials: @escaping @MainActor () async -> Void = {}) {
        self.store = store; self.retirePlayback = retirePlayback
        self.retireDownloads = retireDownloads; self.removeFile = removeFile
        self.cleanupCredentials = cleanupCredentials
        self.removedEpisodes = RemovedEpisodeEffectRecipient(store: store,
            retirePlayback: retirePlayback, retireDownloads: retireDownloads, removeFile: removeFile)
    }
    @discardableResult
    public func delete(feedID: Int64) -> Task<Void, any Error> {
        command {
            _ = try await self.store.requestFeedDeletion(feedID: feedID)
            self.onChange?()
            try await self.drain()
        }
    }
    @discardableResult
    public func deleteSynchronizationSubscription(source: String, epoch: UUID) -> Task<Void, any Error> {
        command {
            _ = try await self.store.requestSynchronizationFeedDeletion(source: source, epoch: epoch)
            self.onChange?()
            try await self.drain()
        }
    }
    @discardableResult
    public func resume() -> Task<Void, any Error> { command { try await self.drain() } }
    @discardableResult
    public func cleanExpired(requestID: UUID, now: Date = Date()) -> Task<Void, any Error> {
        command {
            try await self.drain()
            // One transaction over the previews only; a library of subscriptions deletes and drains nothing.
            let deleted = try await self.store.requestExpiredFeedDeletions(expiredAt: now, manualRequestID: requestID)
            guard !deleted.isEmpty else { return }
            self.onChange?()
            try await self.drain()
        }
    }
    private func command(_ body: @escaping @MainActor () async throws -> Void) -> Task<Void, any Error> {
        let previous = commands
        let task = Task { await previous?.value; try await body() }
        commands = Task { _ = try? await task.value }
        return task
    }
    private func drain() async throws {
        var failures: [RemovedEpisodeEffectsError.Failure] = []
        for pending in try await store.pendingEffects(kinds: ["removeEpisodes", "deleteFeed"]) {
            try Task.checkCancellation()
            switch pending.effect.kind {
            case .removeEpisodes:
                do {
                    try await removedEpisodes.deliver(pending)
                    onChange?()
                } catch is CancellationError { throw CancellationError() }
                catch RemovedEpisodeEffectsError.incomplete(let retained) { failures += retained }
                catch { failures.append(.init(effectID: pending.id, reason: .cleanupFailed)) }
            case .deleteFeed(let deletion):
                try await retirePlayback(deletion.episodeIDs)
                try await retireDownloads(deletion.downloadJobIDs)
                let remove = removeFile
                if await store.isServerLibrary {
                    // A server library re-checks current references before it deletes (post-commit work, PROTOCOL §15.2).
                    for file in deletion.files { try await store.deleteServerDownloadIfUnreferenced(file, remove: remove) }
                } else {
                    // File operations cannot block the UI or race a still-running writer.
                    try await Task.detached(priority: .utility) {
                        for file in deletion.files { try remove(file) }
                    }.value
                }
                try await store.completeFeedDeletion(effectID: pending.id)
                onChange?()
            default: break
            }
        }
        await cleanupCredentials()
        if !failures.isEmpty { throw RemovedEpisodeEffectsError.incomplete(failures) }
    }
    public nonisolated static func unlinkDownload(_ file: URL) throws {
        guard file.isFileURL, !file.path.contains("\0") else { throw FeedLibraryError.invalidLocation }
        try unlinkIfPresent(URL(fileURLWithPath: file.path + ".transcript"))
        try unlinkIfPresent(file)
    }
    private nonisolated static func unlinkIfPresent(_ file: URL) throws {
        try file.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw FeedLibraryError.invalidLocation }
            if unlink(path) == 0 || errno == ENOENT { return }
            // Source File.delete can remove an empty directory, never its contents.
            if errno == EISDIR || errno == EPERM {
                if rmdir(path) == 0 || errno == ENOENT { return }
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
