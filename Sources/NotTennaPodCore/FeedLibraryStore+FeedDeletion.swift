import Foundation

/// Removing feeds and the cleanup of their episodes.
extension FeedLibraryStore {
    /// Atomically invalidate the feed and retain external cleanup. Expiry is
    /// rechecked inside this transaction, so a queued/favorited/newly refreshed
    /// preview cannot be removed from a stale cleaner snapshot.
    @discardableResult
    public func requestFeedDeletion(feedID: Int64, expiredAt: Date? = nil,
                                    manualRequestID: UUID? = nil, now: Date = Date()) throws -> Bool {
        try Task.checkCancellation()
        return try write(expiredAt == nil ? .unsubscribe : .local, now: now) {
            try requireManualRefresh(manualRequestID)
            // Expiry applies only to previews: a subscribed or archived feed is never loaded for it.
            if expiredAt != nil, try loadFeedHeader(feedID)?.subscriptionState != .notSubscribed { return false }
            guard let feed = try loadFeed(feedID) else { return false }
            var queue = try loadQueue()
            if let expiredAt, !NonSubscribedFeedCleanup.shouldDelete(feed, queuedIDs: Set(queue.map(\.id)), now: expiredAt) { return false }
            try deleteFeedInTransaction(feed, queue: &queue, now: now)
            try Task.checkCancellation()
            return true
        }
    }

    /// Refresh completion's cleanup of expired previews (`NonSubscribedFeedCleanup`), in one transaction. Only
    /// not-subscribed feeds are examined, so a library of subscriptions costs one header read per feed.
    /// Returns the deleted feeds' IDs; the caller drains their deletion effects.
    @discardableResult
    public func requestExpiredFeedDeletions(expiredAt: Date, manualRequestID: UUID? = nil,
                                            now: Date = Date()) throws -> [Int64] {
        try Task.checkCancellation()
        return try write(.local, now: now) {
            try requireManualRefresh(manualRequestID)
            let previews = try database.rows("SELECT record FROM feeds ORDER BY title COLLATE NOCASE ASC, id").compactMap { row in
                let header: LibraryFeed = try decode(row[0])
                return header.subscriptionState == .notSubscribed ? header.id : nil
            }
            guard !previews.isEmpty else { return [] }
            var queue = try loadQueue(), deleted: [Int64] = []
            for id in previews {
                try Task.checkCancellation()
                guard let feed = try loadFeed(id),
                      NonSubscribedFeedCleanup.shouldDelete(feed, queuedIDs: Set(queue.map(\.id)), now: expiredAt) else { continue }
                try deleteFeedInTransaction(feed, queue: &queue, now: now)
                deleted.append(id)
            }
            return deleted
        }
    }

    /// `sharedAddressJobs`: also cancel other feeds' active jobs of its addresses (AntennaPod's deletion cancels by URL);
    /// a server library's projected removals stop only their own.
    func deleteFeedInTransaction(_ feed: LibraryFeed, queue: inout [LibraryEpisode], now: Date, sharedAddressJobs: Bool = true) throws {
        let episodeIDs = Set(feed.episodes.map(\.id))
        let deletion = try captureEpisodeRemoval(feed.episodes, feed: feed, now: now, sharedAddressJobs: sharedAddressJobs)
        try removePendingQueueEpisodes(episodeIDs)
        try appendEffect(.init(feedID: feed.id, date: now, kind: .deleteFeed(deletion)))
        try captureFeedDeletion(feed)
        try database.execute("DELETE FROM feeds WHERE id = ?", [.integer(feed.id)])
        downloadLogChanged()
        // Cascades remove media/jobs/logs/local grants and both playback
        // rows. Rewrite queue positions without changing remaining order.
        queue.removeAll { episodeIDs.contains($0.id) }
        try saveQueue(queue)
    }

    public func completeFeedDeletion(effectID: Int64) throws {
        try Task.checkCancellation()
        try write(.local) {
            guard let row = try database.rows("SELECT record FROM pending_effects WHERE id = ?", [.integer(effectID)]).first else { return }
            let effect: FeedLibraryEffect = try decode(row[0])
            guard case .deleteFeed(let deletion) = effect.kind else { throw FeedLibraryError.invalidMutation }
            if deletion.synchronize {
                let currentAccount = try synchronizationState().accountID
                let queueSync = deletion.synchronizationAccount.map { $0.id != nil && $0.id == currentAccount } ?? true
                for episode in deletion.downloadedEpisodes {
                    try appendEffect(.init(feedID: deletion.feedID, date: effect.date,
                        kind: .downloadFileDeleted(episode: episode, source: deletion.source, synchronize: true)), queueSync: queueSync)
                }
                // File teardown can finish after the user subscribes again.
                // Do not let that older removal cancel the newer queued add.
                let resubscribed = try loadFeeds().contains {
                    $0.subscriptionState != .notSubscribed && $0.source.utf16.elementsEqual(deletion.source.utf16)
                }
                try appendEffect(.init(feedID: deletion.feedID, date: effect.date, kind: .feedRemoved(source: deletion.source)),
                                 queueSync: queueSync && !resubscribed)
            }
            try acknowledgeEffect(id: effectID)
            try Task.checkCancellation()
        }
    }

    /// Capture before episode/job cascades, including source cancel-by-URL work owned by a different episode. IDs
    /// fence later replacement downloads. `sharedAddressJobs`: also another episode's active job of one of their
    /// addresses (AntennaPod cancels by URL); a server library's projected removals stop only their own.
    func captureEpisodeRemoval(_ episodes: [LibraryEpisode], feed: LibraryFeed, now: Date, sharedAddressJobs: Bool = true) throws -> FeedDeletion {
        let local = feed.source.isLocalFeedSource
        let ids = Set(episodes.map(\.id))
        let sources = episodes.compactMap { $0.details.media?.url }
        let jobs = try downloadJobs(activeOnly: false).filter { job in
            ids.contains(job.episodeID) || (sharedAddressJobs && !local && job.state.isActive
                && sources.contains { $0.utf16.elementsEqual(job.source.utf16) })
        }
        let downloaded = local ? [] : episodes.filter { $0.details.media != nil && $0.userState.isDownloaded }
        var files = Set(downloaded.compactMap { $0.userState.localFileURL.map { URL(fileURLWithPath: $0) } })
        for var job in jobs where job.state.isActive {
            job.state = .cancelled; job.updatedAt = now
            try saveDownloadJob(job)
            if !local { files.insert(job.destination) }
        }
        return FeedDeletion(feedID: feed.id, episodeIDs: ids, downloadJobIDs: Set(jobs.map(\.id)),
            files: files.sorted { $0.path < $1.path }, source: feed.source,
            synchronize: !local && feed.subscriptionState != .notSubscribed,
            downloadedEpisodes: downloaded, synchronizationAccount: .init(id: try synchronizationState().accountID))
    }

    func removePendingQueueEpisodes(_ episodeIDs: Set<Int64>) throws {
        // A deferred insertion must not resurrect removed IDs or block the
        // surviving members of the same queue intent.
        for pending in try pendingEffects(kinds: ["queueEpisodes"]) {
            guard case .queueEpisodes(let ids) = pending.effect.kind else { continue }
            let remaining = ids.filter { !episodeIDs.contains($0) }
            if remaining == ids { continue }
            if remaining.isEmpty { try acknowledgeEffect(id: pending.id) }
            else {
                var effect = pending.effect; effect.kind = .queueEpisodes(remaining)
                try database.execute("UPDATE pending_effects SET record = ? WHERE id = ?",
                    [.blob(try JSONEncoder().encode(effect)), .integer(pending.id)])
            }
        }
    }

    /// Old removeEpisodes records did not preserve their pre-cascade account or
    /// job identities. Recover only provable context; never bind them to today's
    /// account or cancel today's job merely because it uses the same URL.
    func prepareRemovedEpisodeCleanup(effectID: Int64) throws -> FeedDeletion? {
        try Task.checkCancellation()
        return try write(.local) {
            guard let pending = try pendingEffect(id: effectID) else { return nil }
            guard case .removeEpisodes(let episodes) = pending.effect.kind else { throw FeedLibraryError.invalidMutation }
            if let cleanup = pending.effect.removedEpisodeCleanup { return cleanup }
            let source: String, synchronize: Bool
            if let feed = try loadFeedHeader(pending.effect.feedID) {
                source = feed.source; synchronize = feed.subscriptionState != .notSubscribed
            } else {
                let deletions = try pendingEffects(kinds: ["deleteFeed"]).compactMap { entry -> FeedDeletion? in
                    guard case .deleteFeed(let deletion) = entry.effect.kind,
                          deletion.feedID == pending.effect.feedID else { return nil }
                    return deletion
                }
                guard let deletion = deletions.first,
                      deletions.allSatisfy({ $0.source == deletion.source && $0.synchronize == deletion.synchronize }) else {
                    throw RemovedEpisodeEffectsError.incomplete([.init(effectID: effectID, reason: .missingLegacyContext)])
                }
                source = deletion.source; synchronize = deletion.synchronize
            }
            let local = source.isLocalFeedSource
            let downloaded = local ? [] : episodes.filter { $0.details.media != nil && $0.userState.isDownloaded }
            let cleanup = FeedDeletion(feedID: pending.effect.feedID, episodeIDs: Set(episodes.map(\.id)),
                downloadJobIDs: [], files: Array(Set(downloaded.compactMap {
                    $0.userState.localFileURL.map { URL(fileURLWithPath: $0) }
                })).sorted { $0.path < $1.path }, source: source, synchronize: !local && synchronize,
                downloadedEpisodes: downloaded, synchronizationAccount: .init(id: nil))
            var effect = pending.effect; effect.removedEpisodeCleanup = cleanup
            try database.execute("UPDATE pending_effects SET record = ? WHERE id = ?",
                [.blob(try JSONEncoder().encode(effect)), .integer(effectID)])
            return cleanup
        }
    }

    /// Run synchronous unlinking on the storage actor, after runtime writers have
    /// retired. Holding the transaction also excludes another store connection
    /// from assigning a file to a replacement owner between check and unlink.
    func removeFilesForRemovedEpisodes(effectID: Int64, removeFile: @Sendable (URL) throws -> Void) throws {
        try Task.checkCancellation()
        try write(.local) {
            guard let pending = try pendingEffect(id: effectID) else { return }
            guard case .removeEpisodes = pending.effect.kind,
                  let cleanup = pending.effect.removedEpisodeCleanup else { throw FeedLibraryError.invalidMutation }
            guard !cleanup.source.isLocalFeedSource else { return }
            // Nothing to unlink: nothing to check.
            guard !cleanup.files.isEmpty else { return }
            // Paths owned by other jobs and by other episodes, collected once (not per file).
            let jobPaths = Set(try downloadJobs(activeOnly: false).filter { !cleanup.downloadJobIDs.contains($0.id) }
                .map { $0.destination.standardizedFileURL.path })
            var episodePaths: Set<String> = []
            if serverContext != nil {
                // A server library reads only the episodes that name a file, by index: a removal's
                // bounded transactions never decode the whole library.
                episodePaths = try serverFileOwnerPaths(excluding: cleanup.episodeIDs)
            } else {
                for feed in try loadFeeds() {
                    for episode in feed.episodes where !cleanup.episodeIDs.contains(episode.id)
                        && (episode.userState.isDownloaded || feed.source.isLocalFeedSource) {
                        if let path = episode.userState.localFileURL { episodePaths.insert(URL(fileURLWithPath: path).standardizedFileURL.path) }
                    }
                }
            }
            for file in cleanup.files {
                try Task.checkCancellation()
                // A newer job/download or provider document wins ownership.
                // An old URL-shared job is cancelled but can still name its old
                // partial file, which this effect continues to own.
                let paths = [file.standardizedFileURL.path, file.standardizedFileURL.path + ".transcript"]
                let replacedJob = paths.contains(where: jobPaths.contains)
                let replacement = paths.contains(where: episodePaths.contains)
                if !replacedJob && !replacement { try removeFile(file) }
            }
        }
    }

    /// The files episodes other than `excluded` own, as the standalone check counts them (downloaded, or of a local
    /// folder), read through `ntp_episodes_by_file`: only the episodes that name a file are read.
    private func serverFileOwnerPaths(excluding excluded: Set<Int64>) throws -> Set<String> {
        var localFeeds: Set<Int64>?
        var paths: Set<String> = []
        let file = "json_extract(CAST(record AS TEXT), '$.userState.localFileURL')"
        for row in try database.rows("SELECT id, feed_id, \(file), json_extract(CAST(record AS TEXT), '$.userState.isDownloaded') FROM episodes WHERE \(file) > ''") {
            guard let id = row[0].integer, !excluded.contains(id), let feed = row[1].integer, let path = row[2].text else { continue }
            if row[3].integer != 1 {
                if localFeeds == nil {
                    localFeeds = Set(try database.rows("SELECT id, record FROM feeds").compactMap { row -> Int64? in
                        let header: LibraryFeed = try decode(row[1])
                        return header.source.isLocalFeedSource ? row[0].integer : nil
                    })
                }
                guard localFeeds?.contains(feed) == true else { continue }
            }
            paths.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
        }
        return paths
    }

    /// DELETE actions and acknowledgement share one commit. Replaying an unlink
    /// after a failed commit is harmless; no action escapes to a new account.
    func completeRemovedEpisodeCleanup(effectID: Int64) throws {
        try Task.checkCancellation()
        try write(.local) {
            guard let pending = try pendingEffect(id: effectID) else { return }
            guard case .removeEpisodes = pending.effect.kind,
                  let cleanup = pending.effect.removedEpisodeCleanup else { throw FeedLibraryError.invalidMutation }
            let account = try synchronizationState().accountID
            let queueSync = cleanup.synchronizationAccount.map { $0.id != nil && $0.id == account } ?? false
            for episode in cleanup.downloadedEpisodes {
                try appendEffect(.init(feedID: cleanup.feedID, date: pending.effect.date,
                    kind: .downloadFileDeleted(episode: episode, source: cleanup.source, synchronize: cleanup.synchronize)),
                    queueSync: queueSync)
            }
            try acknowledgeEffect(id: effectID)
            try Task.checkCancellation()
        }
    }
}
