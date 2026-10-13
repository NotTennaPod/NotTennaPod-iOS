import Foundation

/// Download jobs.
extension FeedLibraryStore {
    public func downloadJobs(activeOnly: Bool = true) throws -> [LibraryDownloadJob] {
        try database.rows("SELECT id, episode_id, source, active, record FROM download_jobs" + (activeOnly ? " WHERE active = 1" : "") + " ORDER BY id")
            .map(decodeDownloadJob)
    }

    public func requestDownload(episodeID: Int64, directory: URL, enqueue: Bool = true,
                                location: EnqueueLocation = .back, playing: PlayingItem? = nil,
                                networkConstraint: DownloadNetworkConstraint = .unmetered,
                                automatic: Bool = false, now: Date = Date()) throws -> LibraryDownloadJob? {
        try Task.checkCancellation()
        guard directory.isFileURL else { throw FeedLibraryError.invalidLocation }
        _ = try milliseconds(now)
        return try write(.downloadRequest, now: now) {
            guard let episode = try loadEpisode(episodeID) else { throw FeedLibraryError.missingEpisode(episodeID) }
            guard let source = episode.details.media?.url, !episode.userState.isDownloaded else { return nil }
            if automatic {
                guard episode.userState.autoDownloadEnabled, let feed = try loadFeedHeader(feedID(forEpisode: episodeID)),
                      !feed.source.isLocalFeedSource else { return nil }
            }
            let jobs = try downloadJobs()
            let queue = try loadQueue()
            let shouldEnqueue = enqueue && !queue.contains { $0.id == episodeID }
            if shouldEnqueue {
                // `PlaybackPreferences.currentlyPlayingFeedMediaId`: the selected episode, playing or paused.
                let current = try playing ?? playbackSelectionEpisodeID().map(PlayingItem.episode)
                _ = try addToQueue([episodeID], location: location, playing: current,
                                   downloadingURLs: Set(jobs.map(\.source)), randomIndex: { Int.random(in: $0) })
            }
            if let existing = jobs.first(where: { $0.source.utf16.elementsEqual(source.utf16) }) { return existing }
            // Cancelling shared work from another episode leaves this episode's partial
            // available for its next request, as DownloadRequestCreator does on Android.
            var retained: LibraryDownloadJob?
            if let file = episode.userState.localFileURL,
               let previous = try database.rows("SELECT id, episode_id, source, active, record FROM download_jobs WHERE episode_id = ? ORDER BY id",
                                                [.integer(episodeID)]).map(decodeDownloadJob).last(where: {
                   $0.episodeID == episodeID && $0.state == .cancelled && $0.destination.path == file
                       && $0.source.utf16.elementsEqual(source.utf16)
               }), let attributes = try? FileManager.default.attributesOfItem(atPath: file),
               attributes[.type] as? FileAttributeType == .typeRegular,
               try !pendingEffects(kinds: ["deleteDownloadFile", "deleteFeed", "removeEpisodes"]).contains(where: {
                   if case .deleteDownloadFile(let pending, _, _, _) = $0.effect.kind { return pending == previous.destination }
                   if case .deleteFeed(let deletion) = $0.effect.kind { return deletion.files.contains(previous.destination) }
                   if case .removeEpisodes(let removed) = $0.effect.kind {
                       if let cleanup = $0.effect.removedEpisodeCleanup { return cleanup.files.contains(previous.destination) }
                       // Legacy effects have no sidecar yet. Do not let a new
                       // attempt reuse a file still named by their snapshots.
                       return removed.contains { $0.userState.localFileURL == previous.destination.path }
                   }
                   return false
               }) {
                retained = previous
            }
            try database.execute("INSERT INTO download_jobs(episode_id, source, active, record) VALUES (?, ?, 1, ?)",
                                 [.integer(episodeID), .text(source), .blob(Data())])
            let id = try database.scalar("SELECT last_insert_rowid()")
            var job = LibraryDownloadJob(id: id, episodeID: episodeID, source: source,
                                         destination: retained?.destination ?? directory.appendingPathComponent("episode-\(episodeID)-download-\(id).media"),
                                         enqueuedByDownload: shouldEnqueue, createdAt: now, state: .waiting, attempts: 0, updatedAt: now,
                                         networkConstraint: networkConstraint)
            job.representation = retained?.representation
            job.fileResetRequired = retained?.fileResetRequired
            try saveDownloadJob(job)
            try Task.checkCancellation()
            return job
        }
    }

    public func beginDownloadAttempt(id: Int64, now: Date = Date()) throws -> LibraryDownloadJob? {
        try Task.checkCancellation()
        _ = try milliseconds(now)
        return try write(.local) {
            guard var job = try loadDownloadJob(id), job.state == .waiting, job.fileResetRequired != true,
                  job.retryAt.map({ $0 <= now }) ?? true else { return nil }
            job.state = .transferring
            job.attempts += 1
            job.retryAt = nil
            job.updatedAt = now
            try saveDownloadJob(job)
            return job
        }
    }

    public func attachDownloadFile(id: Int64, attempt: Int) throws -> Bool {
        try Task.checkCancellation()
        return try write(.local) {
            guard let job = try loadDownloadJob(id), job.state == .transferring, job.attempts == attempt else { return false }
            guard FileManager.default.fileExists(atPath: job.destination.path) else { throw FeedLibraryError.invalidLocation }
            guard var episode = try loadEpisode(job.episodeID) else { throw FeedLibraryError.missingEpisode(job.episodeID) }
            episode.userState.localFileURL = job.destination.path
            let feedID = try database.scalar("SELECT feed_id FROM episodes WHERE id = ?", [.integer(episode.id)])
            try saveEpisode(episode, feedID: feedID)
            return true
        }
    }

    public func acceptDownloadRepresentation(id: Int64, attempt: Int,
                                             representation: MediaDownloadRepresentation?) throws -> Bool {
        try Task.checkCancellation()
        return try write(.local) {
            guard var job = try loadDownloadJob(id), job.state == .transferring, job.attempts == attempt else { return false }
            guard representation?.isValid != false else { throw FeedLibraryError.invalidMutation }
            job.representation = representation
            try saveDownloadJob(job)
            try Task.checkCancellation()
            return true
        }
    }

    public func interruptDownload(id: Int64, attempt: Int, now: Date = Date()) throws -> Bool {
        try Task.checkCancellation()
        _ = try milliseconds(now)
        return try write(.local) {
            guard var job = try loadDownloadJob(id), job.state == .transferring, job.attempts == attempt else { return false }
            job.state = .waiting
            job.updatedAt = now
            job.interruptions = (job.interruptions ?? 0) + 1
            try saveDownloadJob(job)
            return true
        }
    }

    public func completeDownload(id: Int64, attempt: Int, measuredDuration: Int32? = nil,
                                 hasEmbeddedPicture: Bool? = nil, now: Date = Date()) throws -> Bool {
        try Task.checkCancellation()
        let downloadTime = try milliseconds(now)
        return try write(.downloadCompleted, now: now) {
            guard var job = try loadDownloadJob(id), job.state == .transferring, job.attempts == attempt else { return false }
            guard var episode = try loadEpisode(job.episodeID), episode.details.media != nil else { return false }
            guard episode.userState.localFileURL == job.destination.path else { return false }
            let attributes = try FileManager.default.attributesOfItem(atPath: job.destination.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.int64Value else { throw FeedLibraryError.invalidLocation }
            episode.details.media?.size = size
            episode.details.media?.hasEmbeddedPicture = hasEmbeddedPicture
            if let measuredDuration { episode.details.media?.durationMilliseconds = measuredDuration }
            episode.userState.isDownloaded = downloadTime > 0
            episode.userState.downloadDate = Date(timeIntervalSince1970: Double(downloadTime) / 1000)
            episode.userState.autoDownloadEnabled = false
            if episode.userState.playState == .new { episode.userState.playState = .unplayed }
            let feedID = try database.scalar("SELECT feed_id FROM episodes WHERE id = ?", [.integer(episode.id)])
            guard let feed = try loadFeedHeader(feedID) else { throw FeedLibraryError.missingFeed(feedID) }
            try saveEpisode(episode, feedID: feedID)
            job.state = .completed
            job.updatedAt = now
            job.logs = (job.logs ?? []) + [.init(date: now, attempt: attempt, failure: nil, title: episode.details.title)]
            try saveDownloadJob(job)
            downloadLogChanged()
            try appendEffect(.init(feedID: feedID, date: now,
                                   kind: .downloadCompleted(source: feed.source, episode: episode,
                                                            synchronize: feed.subscriptionState != .notSubscribed)))
            try Task.checkCancellation()
            return true
        }
    }

    public func cancelDownload(id: Int64, callerEpisodeID: Int64? = nil,
                               deleteRemovesFromQueue: Bool = false, now: Date = Date()) throws -> Bool {
        try Task.checkCancellation()
        _ = try milliseconds(now)
        return try write(.queueRemove(.downloadDeleted), now: now) {
            guard var job = try loadDownloadJob(id), job.state.isActive else { return false }
            let episodeID = callerEpisodeID ?? job.episodeID
            guard var episode = try loadEpisode(episodeID) else {
                if callerEpisodeID != nil { throw FeedLibraryError.missingEpisode(episodeID) }
                return false
            }
            if callerEpisodeID != nil, episode.details.media?.url?.utf16.elementsEqual(job.source.utf16) != true {
                throw FeedLibraryError.invalidMutation
            }
            let feedID = try database.scalar("SELECT feed_id FROM episodes WHERE id = ?", [.integer(episode.id)])
            let callerFile = episodeID == job.episodeID ? job.destination
                : episode.userState.localFileURL.map { URL(fileURLWithPath: $0) }
            let fileExisted = callerFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            if fileExisted, let callerFile {
                guard let feed = try loadFeedHeader(feedID) else { throw FeedLibraryError.missingFeed(feedID) }
                try appendEffect(.init(feedID: feedID, date: now,
                                       kind: .deleteDownloadFile(file: callerFile, episode: episode, source: feed.source,
                                                                  synchronize: feed.subscriptionState != .notSubscribed)))
                if episode.userState.localFileURL == callerFile.path {
                    episode.userState.localFileURL = nil
                    episode.userState.isDownloaded = false
                    episode.userState.downloadDate = nil
                    episode.details.media?.hasEmbeddedPicture = false
                }
            }
            let history = try downloadJobs(activeOnly: false)
            if history.contains(where: { $0.source.utf16.elementsEqual(job.source.utf16) && $0.enqueuedByDownload })
                || (fileExisted && deleteRemovesFromQueue) {
                let queue = try loadQueue().filter { $0.id != episode.id }
                try saveQueue(queue)
            }
            episode.userState.autoDownloadEnabled = false
            try saveEpisode(episode, feedID: feedID)
            job.state = .cancelled
            job.updatedAt = now
            try saveDownloadJob(job)
            try Task.checkCancellation()
            return true
        }
    }

    private func loadDownloadJob(_ id: Int64) throws -> LibraryDownloadJob? {
        guard let row = try database.rows("SELECT id, episode_id, source, active, record FROM download_jobs WHERE id = ?", [.integer(id)]).first else { return nil }
        return try decodeDownloadJob(row)
    }

    public func downloadJob(id: Int64) throws -> LibraryDownloadJob? { try loadDownloadJob(id) }

    public func recordDownloadFailure(id: Int64, attempt: Int, failure: MediaDownloadFailure, diagnostic: String? = nil,
                                       now: Date = Date()) throws -> LibraryDownloadJob? {
        try Task.checkCancellation()
        _ = try milliseconds(now)
        return try write(.local) {
            guard var job = try loadDownloadJob(id), job.state == .transferring, job.attempts == attempt else { return nil }
            let counted = job.countedAttempts
            let terminal = failure.failsImmediately || counted >= 3
            // A 416 that only restarts the file is not a result. The last one is: Android logs nothing for
            // it, so its "Tap to view details." would open a log without the episode.
            let logged = !failure.restartsFile || terminal
            if logged {
                job.logs = (job.logs ?? []) + [.init(date: now, attempt: attempt, failure: failure,
                                                   title: try loadEpisode(job.episodeID)?.details.title,
                                                   detail: diagnostic ?? DownloadDiagnostic.media(failure))]
            }
            job.state = terminal ? .failed : .waiting
            job.updatedAt = now
            job.retryAt = terminal ? nil : now.addingTimeInterval(counted == 1 ? 30 : 60)
            job.fileResetRequired = terminal || failure.restartsFile
            try saveDownloadJob(job)
            if logged { downloadLogChanged() }
            return job
        }
    }

    public func acknowledgeDownloadFileReset(id: Int64, attempt: Int) throws -> Bool {
        try Task.checkCancellation()
        return try write(.local) {
            guard var job = try loadDownloadJob(id), job.fileResetRequired == true, job.attempts == attempt,
                  job.state == .waiting || job.state == .failed else { return false }
            job.fileResetRequired = false
            job.representation = nil
            try saveDownloadJob(job)
            return true
        }
    }

    /// Advance the durable local operation only after provider deletion succeeds.
    /// A later refresh may fail/retry without attempting to delete a replacement file.
    public func completeLocalMediaDeletion(effectID: Int64, refreshedBookmark: Data) throws {
        try write(.local) {
            guard let row = try database.rows("SELECT record FROM pending_effects WHERE id = ?", [.integer(effectID)]).first else { return }
            var effect: FeedLibraryEffect = try decode(row[0])
            guard case .deleteLocalMedia(let reference) = effect.kind else { return }
            if let current = try localFolder(feedID: effect.feedID),
               current.directoryIdentity == reference.folder.directoryIdentity {
                try persistBookmarkRenewal(refreshedBookmark, observed: reference.folder, current: current)
            }
            effect.kind = .refreshAfterLocalMediaDeletion(directoryIdentity: reference.folder.directoryIdentity)
            try database.execute("UPDATE pending_effects SET kind = ?, record = ? WHERE id = ?",
                [.text(effect.kind.name), .blob(try JSONEncoder().encode(effect)), .integer(effectID)])
        }
    }

    public func completeDownloadFileDeletion(effectID: Int64) throws -> Bool {
        try Task.checkCancellation()
        return try write(.local) {
            guard let row = try database.rows("SELECT record FROM pending_effects WHERE id = ?", [.integer(effectID)]).first else { return false }
            var effect: FeedLibraryEffect = try decode(row[0])
            guard case .deleteDownloadFile(_, let episode, let source, let synchronize) = effect.kind else { return false }
            // The file is gone: the work is done. Its DELETE sync action is queued in the same commit.
            effect.kind = .downloadFileDeleted(episode: episode, source: source, synchronize: synchronize)
            try acknowledgeEffect(id: effectID)
            try queueSynchronizationEffect(effect)
            return true
        }
    }

    private func decodeDownloadJob(_ row: [LibrarySQLValue]) throws -> LibraryDownloadJob {
        let job: LibraryDownloadJob = try decode(row[4])
        guard row[0].integer == job.id, row[1].integer == job.episodeID,
              case .text(let source) = row[2], source.utf16.elementsEqual(job.source.utf16),
              row[3].integer == (job.state.isActive ? 1 : 0), job.destination.isFileURL,
              job.attempts >= 0 else { throw FeedLibraryError.corruptRecord }
        return job
    }

    func saveDownloadJob(_ job: LibraryDownloadJob) throws {
        try database.execute("UPDATE download_jobs SET active = ?, record = ? WHERE id = ?",
                             [.integer(job.state.isActive ? 1 : 0), .blob(try JSONEncoder().encode(job)), .integer(job.id)])
        guard try database.scalar("SELECT changes()") == 1 else { throw FeedLibraryError.corruptRecord }
    }
}
