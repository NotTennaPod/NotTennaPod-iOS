import Foundation

/// Deleting downloaded media and repairing missing files.
extension FeedLibraryStore {
    /// Durable media deletion intent. File removal is consumed by the download
    /// worker; retiring selection here prevents late playback saves reviving it.
    public func requestMediaDeletion(episodeID: Int64, deleteRemovesFromQueue: Bool = false, now: Date = Date()) throws {
        _ = try requestMediaDeletion(episodeID: episodeID, target: nil,
            deleteRemovesFromQueue: deleteRemovesFromQueue, now: now)
    }

    /// Validate the action's original artifact in the transaction that stages
    /// its deletion. A reused row ID is not permission to delete its new media.
    public func requestMediaDeletion(target: EpisodeMediaDeletionTarget,
        deleteRemovesFromQueue: Bool = false, now: Date = Date()) throws -> EpisodeMediaDeletionOutcome {
        guard case .remote = target.media else { throw FeedLibraryError.invalidMutation }
        return try requestMediaDeletion(episodeID: target.episodeID, target: target,
            deleteRemovesFromQueue: deleteRemovesFromQueue, now: now)
    }

    private func requestMediaDeletion(episodeID: Int64, target: EpisodeMediaDeletionTarget?,
        deleteRemovesFromQueue: Bool, now: Date) throws -> EpisodeMediaDeletionOutcome {
        try Task.checkCancellation()
        _ = try milliseconds(now)
        return try write(.queueRemove(.downloadDeleted), now: now) {
            if let target, try !matchesDeletionTarget(target) { return .stale }
            guard var episode = try loadEpisode(episodeID) else { throw FeedLibraryError.missingEpisode(episodeID) }
            guard episode.details.media != nil else { throw FeedLibraryError.invalidMutation }
            let feedID = try feedID(forEpisode: episodeID)
            guard let feed = try loadFeedHeader(feedID) else { throw FeedLibraryError.missingFeed(feedID) }
            // Local folder deletion also refreshes/removes the document-provider
            // item. That integration must not be mistaken for a downloaded file.
            guard !feed.source.isLocalFeedSource else { throw FeedLibraryError.invalidMutation }
            guard try database.scalar("SELECT count(*) FROM download_jobs WHERE episode_id = ? AND active = 1",
                                      [.integer(episodeID)]) == 0 else { throw FeedLibraryError.invalidMutation }
            let snapshot = episode
            let synchronize = feed.subscriptionState != .notSubscribed
            let kind: FeedLibraryEffect.Kind
            if let path = episode.userState.localFileURL {
                kind = .deleteDownloadFile(file: URL(fileURLWithPath: path), episode: snapshot, source: feed.source, synchronize: synchronize)
                episode.userState.localFileURL = nil
                episode.userState.isDownloaded = false
                episode.userState.downloadDate = nil
                episode.details.media?.hasEmbeddedPicture = false
                try saveEpisode(episode, feedID: feedID, scope: .media)
            } else {
                kind = .downloadFileDeleted(episode: snapshot, source: feed.source, synchronize: synchronize)
            }
            try appendEffect(.init(feedID: feedID, date: now, kind: kind))
            try database.execute("DELETE FROM playback_session WHERE episode_id = ?", [.integer(episodeID)])
            try database.execute("DELETE FROM playback_selection WHERE episode_id = ?", [.integer(episodeID)])
            if deleteRemovesFromQueue {
                let queue = try loadQueue()
                if queue.contains(where: { $0.id == episodeID }) { try saveQueue(queue.filter { $0.id != episodeID }) }
            }
            try Task.checkCancellation()
            return .deleted
        }
    }

    /// Called while the library/search result owns a coherent read transaction.
    func loadMediaDeletionTarget(episodeID: Int64) throws -> EpisodeMediaDeletionTarget? {
        guard let episode = try loadEpisode(episodeID) else { return nil }
        let feedID = try feedID(forEpisode: episodeID)
        guard let row = try database.rows("SELECT record FROM feeds WHERE id = ?", [.integer(feedID)]).first else { return nil }
        let feed: LibraryFeed = try decode(row[0])
        return try Self.mediaDeletionTarget(episode: episode, feed: feed,
            localFolder: feed.source.isLocalFeedSource ? localFolder(feedID: feedID) : nil)
    }

    static func mediaDeletionTarget(episode: LibraryEpisode, feed: LibraryFeed,
        localFolder: LocalFolderLink?) -> EpisodeMediaDeletionTarget? {
        guard let media = episode.details.media else { return nil }
        let artifact: EpisodeMediaDeletionTarget.Media
        if feed.source.isLocalFeedSource {
            guard let link = localFolder, let filename = episode.details.link, let identity = media.url,
                  feed.source.utf16.elementsEqual((LibraryFeed.localSourcePrefix + link.directoryIdentity).utf16) else { return nil }
            artifact = .local(.init(folder: link, filename: filename, identity: identity, size: media.size,
                resourceIdentity: link.documentResources?.first { $0.filename.utf16.elementsEqual(filename.utf16) }?.identity))
        } else { artifact = .remote(mediaURL: media.url, originalFile: episode.userState.localFileURL) }
        return .init(episodeID: episode.id, feedID: feed.id, source: feed.source, media: artifact)
    }

    public func recordLocalMediaDeletion(target: EpisodeMediaDeletionTarget,
        removeFromQueue: Bool) throws -> EpisodeMediaDeletionOutcome {
        guard case .local = target.media else { throw FeedLibraryError.invalidMutation }
        return try write(.local) {
            guard try matchesDeletionTarget(target), var episode = try loadEpisode(target.episodeID) else { return .stale }
            episode.userState.localFileURL = nil
            try saveEpisode(episode, feedID: target.feedID)
            try database.execute("DELETE FROM playback_session WHERE episode_id = ?", [.integer(target.episodeID)])
            try database.execute("DELETE FROM playback_selection WHERE episode_id = ?", [.integer(target.episodeID)])
            if removeFromQueue { try saveQueue(loadQueue().filter { $0.id != target.episodeID }) }
            return .deleted
        }
    }

    /// Actor-isolated admission used both before provider I/O and at commit.
    /// Swift String equality normalizes Unicode; destructive identity must not.
    public func admitsMediaDeletion(_ target: EpisodeMediaDeletionTarget) throws -> Bool {
        try database.transaction(write: false) { try matchesDeletionTarget(target) }
    }

    private func matchesDeletionTarget(_ target: EpisodeMediaDeletionTarget) throws -> Bool {
        guard let episode = try loadEpisode(target.episodeID),
              try feedID(forEpisode: target.episodeID) == target.feedID,
              let feed = try loadFeedHeader(target.feedID),
              feed.source.utf16.elementsEqual(target.source.utf16),
              let media = episode.details.media else { return false }
        switch target.media {
        case .remote(let mediaURL, let originalFile):
            return !feed.source.isLocalFeedSource
                && exactlyEqual(media.url, mediaURL) && exactlyEqual(episode.userState.localFileURL, originalFile)
        case .local(let reference):
            guard feed.source.isLocalFeedSource else { return false }
            guard let current = try loadLocalDocument(episodeID: target.episodeID) else {
                throw LocalFolderDocuments.Failure.resourceIdentityUnavailable
            }
            guard current.isSameDeletionLocation(as: reference) else { return false }
            guard current.resourceIdentity != nil, reference.resourceIdentity != nil else {
                throw LocalFolderDocuments.Failure.resourceIdentityUnavailable
            }
            return current.isSameDeletionDocument(as: reference)
        }
    }

    /// PlayActionButton repairs missing download metadata and returns without
    /// starting playback. This is not Delete: no queue, selection or sync effect.
    @discardableResult
    public func repairMissingDownloadedMedia(episodeID: Int64) throws -> Bool {
        try Task.checkCancellation()
        return try write(.local) {
            guard var episode = try loadEpisode(episodeID) else { throw FeedLibraryError.missingEpisode(episodeID) }
            guard episode.details.media != nil, episode.userState.isDownloaded else { return false }
            let feedID = try feedID(forEpisode: episodeID)
            guard let feed = try loadFeedHeader(feedID) else { throw FeedLibraryError.missingFeed(feedID) }
            guard !feed.source.isLocalFeedSource else { return false }
            if let path = episode.userState.localFileURL, FileManager.default.fileExists(atPath: path) { return false }
            episode.userState.isDownloaded = false
            episode.userState.localFileURL = nil
            episode.userState.downloadDate = nil
            try saveEpisode(episode, feedID: feedID)
            try Task.checkCancellation()
            return true
        }
    }
}
