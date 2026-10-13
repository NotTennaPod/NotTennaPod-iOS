import Foundation

/// Per-feed preferences, failures and the download log.
extension FeedLibraryStore {
    public func updatePreferences(feedID: Int64,
                                  change: @Sendable (inout FeedLibraryPreferences) throws -> Void) throws {
        try Task.checkCancellation()
        try write(.registers) { try updatePreferencesInTransaction(feedID: feedID, change: change) }
    }

    /// Bulk edit: the same change applied to each feed (in the given order) in one transaction, each
    /// from its current stored preferences. Either every feed changes or none does.
    public func updatePreferences(feedIDs: [Int64],
                                  change: @Sendable (Int64, inout FeedLibraryPreferences) throws -> Void) throws {
        try Task.checkCancellation()
        try write(.registers) {
            for id in feedIDs { try updatePreferencesInTransaction(feedID: id) { try change(id, &$0) } }
        }
    }

    /// Bulk "Remove all from inbox": `DBWriter.removeFeedNewFlag` for each feed, in one transaction.
    @discardableResult
    public func removeFeedsFromInbox(feedIDs: [Int64]) throws -> [Int64] {
        try Task.checkCancellation()
        return try write(.dismiss) {
            var changed: [Int64] = []
            for id in feedIDs {
                guard let feed = try loadFeed(id) else { throw FeedLibraryError.missingFeed(id) }
                for var episode in feed.episodes where episode.userState.playState == .new {
                    episode.userState.playState = .unplayed
                    try saveEpisode(episode, feedID: id)
                    changed.append(episode.id)
                }
            }
            return changed
        }
    }

    private func updatePreferencesInTransaction(feedID: Int64,
                                                change: (inout FeedLibraryPreferences) throws -> Void) throws {
        guard var feed = try loadFeedHeader(feedID) else { throw FeedLibraryError.missingFeed(feedID) }
        var preferences = FeedLibraryPreferences(customTitle: feed.customTitle, subscriptionState: feed.subscriptionState,
                                                newEpisodesAction: feed.newEpisodesAction, autoDownload: feed.autoDownload,
                                                keepUpdated: feed.keepUpdated, showEpisodeNotification: feed.showEpisodeNotification,
                                                automaticDownloadFilter: feed.automaticDownloadFilter, tags: feed.tags,
                                                skip: feed.skipPreferences, volumeAdaptation: feed.volumeAdaptation, autoDelete: feed.autoDelete)
        try change(&preferences)
        feed.customTitle = preferences.customTitle
        feed.subscriptionState = preferences.subscriptionState
        feed.newEpisodesAction = preferences.newEpisodesAction
        feed.autoDownload = preferences.autoDownload
        feed.keepUpdated = preferences.keepUpdated
        feed.showEpisodeNotification = preferences.showEpisodeNotification
        feed.automaticDownloadFilter = preferences.automaticDownloadFilter
        feed.tags = preferences.tags
        feed.skipPreferences = preferences.skip
        feed.volumeAdaptation = preferences.volumeAdaptation
        feed.autoDelete = preferences.autoDelete
        try saveHeader(feed)
    }

    public func playbackDeletionPolicy(forEpisode episodeID: Int64) throws -> PlaybackDeletionPolicy {
        let id = try feedID(forEpisode: episodeID)
        guard let feed = try loadFeedHeader(id) else { throw FeedLibraryError.missingFeed(id) }
        return .init(choice: feed.autoDelete, isLocalFeed: feed.source.isLocalFeedSource)
    }

    public func volumeAdaptation(forEpisode episodeID: Int64) throws -> FeedVolumeAdaptation {
        let id = try feedID(forEpisode: episodeID)
        guard let feed = try loadFeedHeader(id) else { throw FeedLibraryError.missingFeed(id) }
        return feed.volumeAdaptation
    }

    public func skipPreferences(forEpisode episodeID: Int64) throws -> FeedSkipPreferences {
        let id = try feedID(forEpisode: episodeID)
        guard let feed = try loadFeedHeader(id) else { throw FeedLibraryError.missingFeed(id) }
        return feed.skipPreferences
    }

    /// DBWriter.updateFeedDownloadURL changes every exact original URL, not
    /// only the selected feed. Preserve all other stored state and validators;
    /// the caller separately requests a forced refresh of the selected feed.
    @discardableResult
    public func updateFeedDownloadURL(original: String, updated: String) throws -> [Int64] {
        try Task.checkCancellation()
        return try write(.changeURL) {
            var changed: [Int64] = []
            for row in try database.rows("SELECT record FROM feeds ORDER BY id") {
                var feed: LibraryFeed = try decode(row[0])
                guard feed.source.utf16.elementsEqual(original.utf16) else { continue }
                feed.source = updated
                try saveHeader(feed)
                changed.append(feed.id)
            }
            try Task.checkCancellation()
            return changed
        }
    }

    public func setEpisodeFilter(feedID: Int64, filter: FeedEpisodeFilter) throws {
        try Task.checkCancellation()
        try write(.local) {
            guard var feed = try loadFeedHeader(feedID) else { throw FeedLibraryError.missingFeed(feedID) }
            feed.episodeFilterValues = filter.values
            try saveHeader(feed)
            try Task.checkCancellation()
        }
    }

    public func recordFailure(_ failure: FeedFetchError, feedID: Int64, date: Date, diagnostic: String? = nil,
                              manualRequestID: UUID? = nil) throws {
        try Task.checkCancellation()
        try write(.local, now: date) {
            try requireManualRefresh(manualRequestID)
            guard var feed = try loadFeedHeader(feedID) else { throw FeedLibraryError.missingFeed(feedID) }
            feed.lastUpdateFailed = true
            feed.lastRefreshAttempt = date
            try saveHeader(feed)
            // HttpDownloader records the response code separately from its
            // human-readable category. Persist it for details and clipboard.
            let fallback: String? = switch failure {
            case .unauthorized: "401"
            case .forbidden: "403"
            case .notFound(let status), .httpStatus(let status): String(status)
            case .wrongSize(let expected, let received): DownloadDiagnostic.wrongSize(expected: expected, received: received)
            case .parsing(.malformedXML(let line, let column)): "Malformed XML at line \(line), column \(column)."
            case .parsing(.limitExceeded(let message)): message
            default: nil
            }
            try appendLog(.init(feedID: feedID, date: date, title: feed.title, kind: .failure(failure), detail: diagnostic ?? fallback))
        }
    }

    public func logs(feedID: Int64) throws -> [FeedLibraryLog] {
        try database.rows("SELECT record FROM refresh_log WHERE feed_id = ? ORDER BY completed_at DESC, id", [.integer(feedID)])
            .map { try decode($0[0]) }
    }

    public func downloadLogChanges() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        downloadLogListeners[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeDownloadLogListener(id) } }
        continuation.yield(())
        return stream
    }

    private func removeDownloadLogListener(_ id: UUID) { downloadLogListeners[id] = nil }

    func downloadLogChanged() { downloadLogListeners.values.forEach { $0.yield(()) } }

    public func downloadLog() throws -> [DownloadLogEntry] {
        try database.transaction(write: false) { try loadDownloadLog() }
    }

    /// The download log inside the caller's read transaction (an export reads it with everything else, PROTOCOL §11.5).
    func loadDownloadLog() throws -> [DownloadLogEntry] {
        do {
            var entries: [DownloadLogEntry] = try database.rows(
                "SELECT id, record FROM refresh_log ORDER BY completed_at DESC, id LIMIT 200").map { row in
                    let log: FeedLibraryLog = try decode(row[1])
                    guard let id = row[0].integer else { throw FeedLibraryError.corruptRecord }
                    return .init(id: .feed(id), feedID: log.feedID, episodeID: nil,
                                 title: log.title, result: .feed(log))
                }
            // Restored Android rows, in the source's completion-date order.
            entries += try database.rows("SELECT id, record FROM imported_download_log ORDER BY completed_at DESC, id LIMIT 200").map { row in
                let log: ImportedDownloadLog = try decode(row[1])
                guard let id = row[0].integer else { throw FeedLibraryError.corruptRecord }
                return .init(id: .imported(id), feedID: log.feedID ?? 0, episodeID: log.episodeID, title: log.title, result: .imported(log))
            }
            for job in try downloadJobs(activeOnly: false) where !(job.logs ?? []).isEmpty {
                let episode = try loadEpisode(job.episodeID)
                let feedID = try feedID(forEpisode: job.episodeID)
                entries += (job.logs ?? []).map { log in
                    .init(id: .media(job: job.id, attempt: log.attempt), feedID: feedID, episodeID: job.episodeID,
                          title: log.title ?? episode?.details.title, result: .media(log))
                }
            }
            // Equal timestamps retain insertion order within each source, as
            // SQLite's source query does; no retry is inferred outside the cap.
            return Array(entries.enumerated().sorted {
                $0.element.date == $1.element.date ? $0.offset < $1.offset : $0.element.date > $1.element.date
            }.prefix(200).map(\.element))
        }
    }

    /// After the restored credentials are installed: queue the replaced library's Keychain entries
    /// for the ordinary cleanup, which runs once this library is the live one.
    public func retireReplacedCredentials(_ ids: [UUID]) throws {
        try write(.local) {
            for id in ids { try database.execute("INSERT OR IGNORE INTO feed_credential_cleanup VALUES (?)", [.text(id.uuidString)]) }
        }
    }

    public func clearDownloadLog() throws {
        try Task.checkCancellation()
        try write(.local) {
            try database.execute("DELETE FROM refresh_log")
            try database.execute("DELETE FROM imported_download_log")
            for var job in try downloadJobs(activeOnly: false) where !(job.logs ?? []).isEmpty {
                job.logs = []
                try saveDownloadJob(job)
            }
            try Task.checkCancellation()
        }
        downloadLogChanged()
    }

    /// Source `clearOldDownloadLog` (PodDBAdapter.java:983–986) over every Download log source: feed
    /// refreshes, media attempts and restored Android rows whose date is strictly before `cutoff`
    /// (milliseconds). Restored rows whose source date was NULL are kept. Active transfer jobs, their retry
    /// timing and queue state are untouched, as with Clear history. Finished jobs (completed, cancelled,
    /// failed) that no longer carry a log entry and ended before the cutoff are removed, as WorkManager prunes
    /// finished work; a job is kept while it still names its episode's file or awaits a file reset.
    /// Returns the deleted entry count.
    @discardableResult
    public func pruneDownloadLog(beforeMilliseconds cutoff: Int64) throws -> Int {
        try Task.checkCancellation()
        let deleted: Int = try write(.local) {
            var deleted = Int(try database.scalar("SELECT count(*) FROM refresh_log WHERE completed_at < ?", [.integer(cutoff)]))
            try database.execute("DELETE FROM refresh_log WHERE completed_at < ?", [.integer(cutoff)])
            for row in try database.rows("SELECT id, record FROM imported_download_log WHERE completed_at < ?", [.integer(cutoff)]) {
                let log: ImportedDownloadLog = try decode(row[1])
                guard log.completionMissing != true, let id = row[0].integer else { continue }
                try database.execute("DELETE FROM imported_download_log WHERE id = ?", [.integer(id)])
                deleted += 1
            }
            for var job in try downloadJobs(activeOnly: false) where !(job.logs ?? []).isEmpty {
                let kept = try (job.logs ?? []).filter { try milliseconds($0.date) >= cutoff }
                guard kept.count != job.logs?.count else { continue }
                deleted += (job.logs?.count ?? 0) - kept.count
                job.logs = kept
                try saveDownloadJob(job)
            }
            for job in try downloadJobs(activeOnly: false) where !job.state.isActive && (job.logs ?? []).isEmpty
                && job.fileResetRequired != true {
                guard try milliseconds(job.updatedAt) < cutoff else { continue }
                if try loadEpisode(job.episodeID)?.userState.localFileURL == job.destination.path { continue }
                try database.execute("DELETE FROM download_jobs WHERE id = ?", [.integer(job.id)])
            }
            try Task.checkCancellation()
            return deleted
        }
        if deleted > 0 { downloadLogChanged() }
        return deleted
    }
}
