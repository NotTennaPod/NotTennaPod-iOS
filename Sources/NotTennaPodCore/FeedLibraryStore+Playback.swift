import Foundation

/// Playback sessions, history and statistics periods.
extension FeedLibraryStore {
    /// The displayed/restored episode survives a switch whose successor needs streaming consent.
    /// It is independent of the generation-scoped statistics session.
    public func playbackSelectionEpisodeID() throws -> Int64? {
        try database.rows("SELECT episode_id FROM playback_selection WHERE id = 1").first?.first?.integer
    }

    public func playbackSession() throws -> LibraryPlaybackSession? {
        guard let row = try database.rows("SELECT episode_id, record FROM playback_session WHERE id = 1").first else { return nil }
        let session: LibraryPlaybackSession = try decode(row[1])
        guard row[0].integer == session.episodeID else { throw FeedLibraryError.corruptRecord }
        return session
    }

    public func beginPlayback(episodeID: Int64, positionMilliseconds: Int32? = nil,
                              enqueueLocation: EnqueueLocation = .back) throws -> LibraryPlaybackSession {
        try Task.checkCancellation()
        return try write(.playLoad) {
            guard let episode = try loadEpisode(episodeID) else { throw FeedLibraryError.missingEpisode(episodeID) }
            guard episode.details.media != nil else { throw FeedLibraryError.invalidMutation }
            let previous = try playbackSession()
            let playingID = try previous?.episodeID ?? playbackSelectionEpisodeID()
            if try !loadQueue().contains(where: { $0.id == episodeID }) {
                let downloading = Set(try downloadJobs().map(\.source))
                _ = try addToQueue([episodeID], location: enqueueLocation, playing: playingID.map { .episode($0) },
                                   downloadingURLs: downloading, randomIndex: { Int.random(in: $0) })
            }
            let position = positionMilliseconds ?? episode.userState.positionMilliseconds
            let currentState = try loadEpisode(episodeID)?.userState.playState ?? episode.userState.playState
            let session = LibraryPlaybackSession(id: UUID(), episodeID: episodeID,
                                                 startPositionMilliseconds: max(0, position),
                                                 playedDurationWhenStarted: episode.userState.playedDurationMilliseconds,
                                                 itemPlayState: position > 0 && currentState == .new ? .unplayed : currentState,
                                                 status: .paused)
            try savePlaybackSession(session)
            try database.execute("INSERT OR REPLACE INTO playback_selection VALUES (1, ?)", [.integer(episodeID)])
            // A server library's pending session and transition for the load (PROTOCOL §8).
            try journalPlaybackLoad(previous: previous, session: session, now: try milliseconds(Date()))
            try Task.checkCancellation()
            return session
        }
    }

    /// Source `DBWriter.resetStatistics` → `resetAllMediaPlayedDuration`: zero every episode's played
    /// duration in one transaction. Position, play state, played dates, queue, downloads, favorites and
    /// subscriptions are unchanged. An active playback session is rebased onto its saved position with a
    /// zero baseline, so later or already-queued samples count only listening after the reset and
    /// cannot restore the erased totals (the session baseline is absolute, not a delta).
    public func resetPlayedDurationStatistics() throws {
        try Task.checkCancellation()
        try write(.statisticsReset) {
            for row in try database.rows("SELECT feed_id, record FROM episodes ORDER BY id") {
                guard let feedID = row[0].integer else { throw FeedLibraryError.corruptRecord }
                var episode: LibraryEpisode = try decode(row[1])
                guard episode.userState.playedDurationMilliseconds != 0 else { continue }
                episode.userState.playedDurationMilliseconds = 0
                try saveEpisode(episode, feedID: feedID)
            }
            if let session = try playbackSession(), let episode = try loadEpisode(session.episodeID) {
                try savePlaybackSession(.init(id: session.id, episodeID: session.episodeID,
                    startPositionMilliseconds: episode.userState.positionMilliseconds, playedDurationWhenStarted: 0,
                    itemPlayState: session.itemPlayState, status: session.status))
            }
            // Statistics units (schema 20) are rows to Android's `resetAllMediaPlayedDuration` too: their played time
            // goes to 0 and nothing else changes. In a server library the pending reset covers every unit the library
            // knows, which the server drops, so none is projected (PROTOCOL §6.8).
            if serverContext == nil { try database.execute("UPDATE statistics_units SET played_ms = 0 WHERE played_ms != 0") }
            else { try database.execute("DELETE FROM statistics_units") }
            try Task.checkCancellation()
        }
    }

    public func recordPlayback(sessionID: UUID, sample: PlaybackSample, now: Date = Date(),
                               synchronize: Bool = false) throws -> LibraryEpisode? {
        try recordPlaybackPeriod(sessionID: sessionID, sample: sample, now: now,
                                 synchronize: synchronize, resetsTimeline: false)?.episode
    }

    /// Settles the consumed source period and rebases its replacement in one durable write.
    /// Ordinary position samples and user seeks retain their existing session baseline.
    public func recordPlaybackTimelineReset(sessionID: UUID, finalSample: PlaybackSample, now: Date = Date()) throws
        -> (episode: LibraryEpisode, session: LibraryPlaybackSession)? {
        try recordPlaybackPeriod(sessionID: sessionID, sample: finalSample, now: now,
                                 synchronize: false, resetsTimeline: true)
    }

    private func recordPlaybackPeriod(sessionID: UUID, sample: PlaybackSample, now: Date,
                                      synchronize: Bool, resetsTimeline: Bool) throws
        -> (episode: LibraryEpisode, session: LibraryPlaybackSession)? {
        try Task.checkCancellation()
        let timestamp = try milliseconds(now)
        // The periodic position save (every 5 s while playing) does not wait for the disk; a pause, stop or
        // timeline reset does, and so does every other write. In a server library so does the minute's checkpoint
        // export (PROTOCOL §8.2): a power loss loses at most the saves since it.
        let durable = try synchronize || resetsTimeline || playbackExportDue(local: sessionID, now: timestamp)
        let saved: (episode: LibraryEpisode, session: LibraryPlaybackSession)? = try write(.playbackSave, durable: durable, now: now) {
            guard var session = try playbackSession(), session.id == sessionID,
                  var episode = try loadEpisode(session.episodeID), episode.details.media != nil else { return nil }
            episode.userState.positionMilliseconds = sample.positionMilliseconds
            if sample.seekable, sample.durationMilliseconds > 0 { episode.details.media?.durationMilliseconds = sample.durationMilliseconds }
            // In a server library only listening this phone started writes the listening-only fields (PROTOCOL §8): a paused
            // load's save, an adopted position's, or a Cast receiver's that no Play here started saves the position
            // alone. A standalone library counts every save, as Android does.
            let kind = try playbackSaveKind(local: session.id, episodeID: episode.id)
            if kind.listens {
                if case .listening = kind {
                    // A server library shows the greatest listening time known (PROTOCOL §8.7): another device's, or
                    // the server's normalized time of this one's, may be later than this save's own clock.
                    episode.userState.lastPlayedTimeMilliseconds = max(episode.userState.lastPlayedTimeMilliseconds, timestamp)
                    episode.userState.lastPlayedHistoryMilliseconds = max(episode.userState.lastPlayedHistoryMilliseconds ?? timestamp, timestamp)
                } else {
                    episode.userState.lastPlayedTimeMilliseconds = timestamp
                    episode.userState.lastPlayedHistoryMilliseconds = timestamp
                }
                if session.itemPlayState == .new {
                    if sample.positionMilliseconds <= 0 { episode.userState.playState = .unplayed }
                    session.itemPlayState = .unplayed
                }
                if sample.positionMilliseconds > session.startPositionMilliseconds {
                    let delta = Int64(sample.positionMilliseconds) - Int64(session.startPositionMilliseconds)
                    let (played, overflow) = session.playedDurationWhenStarted.addingReportingOverflow(delta)
                    guard !overflow else { throw FeedLibraryError.invalidMutation }
                    episode.userState.playedDurationMilliseconds = played
                }
            }
            // A server library journals the save in its session, and played time follows the server's rule (PROTOCOL §8.8).
            if let played = try journalPlaybackSave(kind, episodeID: episode.id, sample: sample, now: timestamp,
                                                    synchronize: synchronize, resetsTimeline: resetsTimeline) {
                episode.userState.playedDurationMilliseconds = played
            }
            // When this device last played the episode, whatever the synced last-played date does (the rewind after a
            // pause measures from it, as from a standalone library's last-played date).
            if case .unsynced = kind {} else { episode.userState.playedHereMilliseconds = timestamp }
            if resetsTimeline {
                episode.userState.positionMilliseconds = 0
                session = .init(id: session.id, episodeID: session.episodeID, startPositionMilliseconds: 0,
                    playedDurationWhenStarted: episode.userState.playedDurationMilliseconds,
                    itemPlayState: session.itemPlayState, status: sample.status)
            }
            let feedID = try database.scalar("SELECT feed_id FROM episodes WHERE id = ?", [.integer(episode.id)])
            try saveEpisode(episode, feedID: feedID, scope: .media)
            session.status = sample.status
            try savePlaybackSession(session)
            if synchronize { try appendPlaybackSync(episode, session: session, completed: false, now: now, feedID: feedID) }
            try Task.checkCancellation()
            return (episode, session)
        }
#if DEBUG
        if let saved, let observer = ServerDebugHooks.observer {
            observer.saved(.init(episodeID: saved.episode.id, positionMilliseconds: saved.episode.userState.positionMilliseconds,
                                 durable: synchronize || resetsTimeline, serverLibrary: serverContext != nil))
        }
#endif
        return saved
    }

    public func endPlayback(sessionID: UUID, reason: PlaybackEndReason, preferences: PlaybackEndPreferences = .init(),
                            now: Date = Date(), continueQueue: Bool = true) throws -> PlaybackEndResult? {
        try Task.checkCancellation()
        let timestamp = try milliseconds(now)
        return try write(.playbackEnd, now: now) {
            guard let session = try playbackSession(), session.id == sessionID,
                  var episode = try loadEpisode(session.episodeID), let media = episode.details.media else { return nil }
            let queue = try loadQueue()
            let next: LibraryEpisode?
            if continueQueue, reason != .switched, let index = queue.firstIndex(where: { $0.id == episode.id }), index + 1 < queue.count {
                let candidate = queue[index + 1]
                next = candidate.details.media == nil ? nil : candidate
            } else { next = nil }
            let almostEnded = media.durationMilliseconds > 0 && episode.userState.positionMilliseconds
                >= media.durationMilliseconds &- (preferences.smartMarkAsPlayedSeconds &* 1_000)
            let completed = reason == .ended || almostEnded
            let remove = completed || (reason == .skipped && !preferences.skipKeepsEpisode)
            let feedID = try database.scalar("SELECT feed_id FROM episodes WHERE id = ?", [.integer(episode.id)])
            // A server library's end that covers an unexported save is listening at its own time (PROTOCOL §8.7): the row
            // shows it as the projection of its facts will, never earlier than what it shows already.
            let listeningEnd = try serverContext != nil && liveSyncSession(local: session.id).map {
                $0.state == .open && $0.incarnation == playbackIncarnation && ($0.last?.index ?? 0) > $0.exportedIndex
            } == true
            // A server library records these decisions through the pending transition (PROTOCOL §8.4).
            try journalPlaybackEnd(local: session.id, episodeID: episode.id, reason: reason, completed: completed,
                                   removeFromQueue: !completed && reason == .skipped && !preferences.skipKeepsEpisode,
                                   thresholdMs: Int64(max(0, preferences.smartMarkAsPlayedSeconds)) * 1_000,
                                   position: episode.userState.positionMilliseconds, now: timestamp)
            if preferences.synchronize { try appendPlaybackSync(episode, session: session, completed: completed, now: now, feedID: feedID) }
            if completed { episode.userState.playState = .played; episode.userState.positionMilliseconds = 0 }
            if remove {
                try saveQueue(queue.filter { $0.id != episode.id })
                if reason == .ended { try requestQueueAutoDownload() }
                if preferences.autoDelete, !episode.userState.isFavorite || !preferences.favoriteKeepsEpisode,
                   let feed = try loadFeedHeader(feedID) {
                    if feed.source.isLocalFeedSource {
                        guard let reference = try loadLocalDocument(episodeID: episode.id) else { throw FeedLibraryError.invalidMutation }
                        try appendEffect(.init(feedID: feedID, date: now, kind: .deleteLocalMedia(reference: reference)))
                    } else if let path = episode.userState.localFileURL {
                        try appendEffect(.init(feedID: feedID, date: now,
                            kind: .deleteDownloadFile(file: URL(fileURLWithPath: path), episode: episode,
                                source: feed.source, synchronize: feed.subscriptionState != .notSubscribed)))
                        episode.userState.localFileURL = nil
                        episode.userState.isDownloaded = false
                        episode.userState.downloadDate = nil
                        episode.details.media?.hasEmbeddedPicture = false
                    } else {
                        // DBWriter still records DELETE for streamed media when
                        // this completion policy requests deletion without a file.
                        try appendEffect(.init(feedID: feedID, date: now,
                            kind: .downloadFileDeleted(episode: episode, source: feed.source,
                                synchronize: feed.subscriptionState != .notSubscribed)))
                    }
                }
            }
            if serverContext != nil {
                episode.userState.lastPlayedHistoryMilliseconds = max(episode.userState.lastPlayedHistoryMilliseconds ?? timestamp, timestamp)
                if listeningEnd { episode.userState.lastPlayedTimeMilliseconds = max(episode.userState.lastPlayedTimeMilliseconds, timestamp) }
            } else {
                episode.userState.lastPlayedHistoryMilliseconds = timestamp
            }
            try saveEpisode(episode, feedID: feedID, scope: .media)
            try database.execute("DELETE FROM playback_session WHERE id = 1")
            if reason != .switched, next == nil {
                try database.execute("DELETE FROM playback_selection WHERE id = 1")
            }
            try Task.checkCancellation()
            return PlaybackEndResult(episode: episode, nextEpisodeID: next?.id, markedPlayed: completed,
                                     removedFromQueue: remove && queue.contains { $0.id == episode.id })
        }
    }

    func savePlaybackSession(_ session: LibraryPlaybackSession) throws {
        try database.execute("INSERT INTO playback_session (id, episode_id, record) VALUES (1, ?, ?) ON CONFLICT(id) DO UPDATE SET episode_id = excluded.episode_id, record = excluded.record",
                             [.integer(session.episodeID), .blob(try JSONEncoder().encode(session))])
    }

    private func appendPlaybackSync(_ episode: LibraryEpisode, session: LibraryPlaybackSession, completed: Bool,
                                     now: Date, feedID: Int64) throws {
        // Source `SynchronizationQueueSink.enqueueEpisodePlayedIfSyncActive`: nothing without a sync account.
        guard try synchronizationState().accountID != nil else { return }
        guard let feed = try loadFeedHeader(feedID) else { throw FeedLibraryError.missingFeed(feedID) }
        guard feed.subscriptionState != .notSubscribed,
              completed || session.startPositionMilliseconds < episode.userState.positionMilliseconds else { return }
        try appendEffect(.init(feedID: feedID, date: now, kind: .episodePlayed(episode: episode, source: feed.source,
                                                                            startPositionMilliseconds: session.startPositionMilliseconds,
                                                                            completed: completed)))
    }
}
