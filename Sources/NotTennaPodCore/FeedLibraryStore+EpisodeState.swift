import Foundation

/// Episode state: favorites, sort order, Inbox, played and swipe marks with undo.
extension FeedLibraryStore {
    /// A direct edit of the stored episode, read in the same transaction. `scope`: what of it the edit may change (any
    /// field by default: tests and tools edit details this way; the store's own actions name a narrower scope).
    public func updateEpisode(id: Int64, scope: EpisodeWriteScope = .metadata, change: @Sendable (inout LibraryEpisode) throws -> Void) throws {
        try Task.checkCancellation()
        try write(.registers) {
            guard var episode = try loadEpisode(id) else { throw FeedLibraryError.missingEpisode(id) }
            try change(&episode)
            guard episode.id == id else { throw FeedLibraryError.invalidMutation }
            let feedID = try database.scalar("SELECT feed_id FROM episodes WHERE id = ?", [.integer(id)])
            try saveEpisode(episode, feedID: feedID, scope: scope)
        }
    }

    /// Explicit Add/Remove favorite commands are idempotent, never stale toggles.
    public func setFavorite(episodeID: Int64, favorite: Bool) throws {
        try Task.checkCancellation()
        try write(.registers) {
            guard try setFavoriteInTransaction(episodeID, favorite: favorite) else { throw FeedLibraryError.missingEpisode(episodeID) }
        }
    }

    public func setFeedEpisodeSortOrder(feedID: Int64, order: FeedEpisodeSortOrder) throws {
        try Task.checkCancellation()
        try write(.local) {
            guard var feed = try loadFeedHeader(feedID) else { throw FeedLibraryError.missingFeed(feedID) }
            feed.episodeSortOrderCode = order.rawValue
            try saveHeader(feed)
        }
    }

    /// DBWriter.removeFeedNewFlag changes only NEW to UNPLAYED for this feed.
    /// It does not mark episodes played, reset positions, unqueue or sync them.
    @discardableResult
    public func removeFeedFromInbox(feedID: Int64) throws -> [Int64] {
        try Task.checkCancellation()
        return try write(.dismiss) {
            guard let feed = try loadFeed(feedID) else { throw FeedLibraryError.missingFeed(feedID) }
            var changed: [Int64] = []
            for var episode in feed.episodes where episode.userState.playState == .new {
                episode.userState.playState = .unplayed
                try saveEpisode(episode, feedID: feedID)
                changed.append(episode.id)
            }
            try Task.checkCancellation()
            return changed
        }
    }

    /// `DBWriter.removeAllNewFlags`: every NEW episode in every feed, archived and not-subscribed
    /// included, becomes UNPLAYED. Nothing else changes: no position, queue or favorite change, no sync
    /// action and no undo.
    @discardableResult
    public func removeAllFromInbox() throws -> [Int64] {
        try Task.checkCancellation()
        return try write(.dismissAll) {
            var changed: [Int64] = []
            if keyedReads {
                // Only the NEW episodes are read, by the derived keys, in the same order.
                for (id, feedID) in try keyedVisibleEpisodes("k.state = -1") {
                    guard var episode = try loadEpisode(id) else { throw FeedLibraryError.corruptRecord }
                    guard episode.userState.playState == .new else { continue }
                    episode.userState.playState = .unplayed
                    try saveEpisode(episode, feedID: feedID)
                    changed.append(id)
                }
                try Task.checkCancellation()
                return changed
            }
            for row in try database.rows("SELECT id FROM feeds f\(hiddenFeedsCondition("f.id").map { " WHERE " + $0 } ?? "") ORDER BY id") {
                guard let id = row[0].integer, let feed = try loadFeed(id) else { throw FeedLibraryError.corruptRecord }
                for var episode in feed.episodes where episode.userState.playState == .new {
                    episode.userState.playState = .unplayed
                    try saveEpisode(episode, feedID: feed.id)
                    changed.append(episode.id)
                }
            }
            try Task.checkCancellation()
            return changed
        }
    }

    /// `DBWriter.clearPlaybackHistory`: clears every completion date (`playback_completion_date`).
    /// Played state, position, played duration, last-played time, downloads, queue and favorites are kept.
    @discardableResult
    public func clearPlaybackHistory() throws -> [Int64] {
        try Task.checkCancellation()
        return try write(.historyClear) {
            var changed: [Int64] = []
            if keyedReads {
                // Only the episodes with a history entry (zero and negative included) are read, by the derived keys,
                // in the same order.
                for (id, feedID) in try keyedVisibleEpisodes("k.history_ms IS NOT NULL") {
                    guard var episode = try loadEpisode(id) else { throw FeedLibraryError.corruptRecord }
                    guard episode.userState.lastPlayedHistoryMilliseconds != nil else { continue }
                    episode.userState.lastPlayedHistoryMilliseconds = nil
                    try saveEpisode(episode, feedID: feedID)
                    changed.append(id)
                }
            } else {
                for row in try database.rows("SELECT id FROM feeds f\(hiddenFeedsCondition("f.id").map { " WHERE " + $0 } ?? "") ORDER BY id") {
                    guard let id = row[0].integer, let feed = try loadFeed(id) else { throw FeedLibraryError.corruptRecord }
                    for var episode in feed.episodes where episode.userState.lastPlayedHistoryMilliseconds != nil {
                        episode.userState.lastPlayedHistoryMilliseconds = nil
                        try saveEpisode(episode, feedID: feed.id)
                        changed.append(episode.id)
                    }
                }
            }
            // A standalone library's statistics units are rows to Android's `clearPlaybackHistory` too (schema 20). In
            // a server library they are the server's records and follow its fold of the clear.
            if serverContext == nil { try database.execute("UPDATE statistics_units SET history = NULL WHERE history IS NOT NULL") }
            try Task.checkCancellation()
            return changed
        }
    }

    /// The episodes matching `condition` (over the derived keys `k`) of the feeds library-wide reads show, staged ones
    /// left out, in the order a feed-by-feed read visits them: feed ID, then each feed's stored order (`pubdate DESC, id`).
    /// Reads only the matching keys (each condition is a partial index); needs the derived data complete.
    func keyedVisibleEpisodes(_ condition: String) throws -> [(id: Int64, feedID: Int64)] {
        let shown = hiddenFeedsCondition("k.feed_id").map { " AND " + $0 } ?? ""
        return try database.rows("SELECT k.id, k.feed_id FROM episode_list_keys k JOIN episodes e ON e.id = k.id WHERE \(condition) AND k.hidden = 0\(shown) ORDER BY k.feed_id, e.pubdate DESC, k.id").map { row in
            guard let id = row[0].integer, let feed = row[1].integer else { throw FeedLibraryError.corruptRecord }
            return (id, feed)
        }
    }

    /// Capture the accepted prior state and guard in the same commit as a swipe
    /// mark. Neither direction resets position or emits a manual sync action.
    /// `body` run on the store, with the library's last commit right after it: the receipt of the write `body` made (a
    /// change set is emitted before its write returns, and nothing else runs on the store in between).
    public func withChangeReceipt<T: Sendable>(_ body: @Sendable (isolated FeedLibraryStore) throws -> T) rethrows -> (value: T, receipt: Int64) {
        (try body(self), changes.emitted)
    }

    public func applySwipeMark(episodeID: Int64, action: EpisodeSwipeMark) throws -> EpisodeMarkReceipt? {
        try Task.checkCancellation()
        return try write(.swipeMark) {
            guard var episode = try loadEpisode(episodeID) else { throw FeedLibraryError.missingEpisode(episodeID) }
            let previous = episode.userState.playState
            let applied: EpisodePlayState
            switch action {
            case .removeInbox:
                guard previous == .new else { return nil }
                applied = .unplayed
            case .togglePlayed:
                applied = previous == .unplayed ? .played : .unplayed
            case .markPlayed: applied = .played
            case .markUnplayed: applied = .unplayed
            }
            let feedID = try feedID(forEpisode: episodeID)
            let receipt = EpisodeMarkReceipt(operationID: UUID(), episodeID: episodeID, feedID: feedID,
                previousState: previous, appliedState: applied, storeEpoch: swipeUndoEpoch)
            episode.userState.playState = applied
            try saveEpisode(episode, feedID: feedID, explicitStateIntent: true)
            try updateSwipeSessionState(episodeID: episodeID, state: applied)
            try database.execute("INSERT INTO episode_swipe_undo(episode_id, operation_id) VALUES (?, ?)",
                [.integer(episodeID), .text(receipt.operationID.uuidString)])
            try Task.checkCancellation()
            return receipt
        }
    }

    /// Restore only the state delta, preserving current progress and metadata.
    /// Timer cancellation belongs to the caller and must not depend on success.
    public func undoSwipeMark(_ receipt: EpisodeMarkReceipt) throws -> EpisodeMarkUndoResult {
        try Task.checkCancellation()
        guard receipt.storeEpoch == swipeUndoEpoch else { return .unavailable }
        return try write(.undoMark) {
            guard var episode = try loadEpisode(receipt.episodeID) else { return .unavailable }
            guard try feedID(forEpisode: receipt.episodeID) == receipt.feedID,
                  episode.userState.playState == receipt.appliedState,
                  try hasSwipeUndo(receipt) else { return .superseded }
            episode.userState.playState = receipt.previousState
            // saveEpisode consumes the old guard along with the changed state.
            try saveEpisode(episode, feedID: receipt.feedID, explicitStateIntent: true)
            try updateSwipeSessionState(episodeID: receipt.episodeID, state: receipt.previousState)
            try Task.checkCancellation()
            return .restored
        }
    }

    /// Dismissal expires this offer only; it is not deletion cancellation.
    public func releaseSwipeUndo(_ receipt: EpisodeMarkReceipt) throws {
        try Task.checkCancellation()
        guard receipt.storeEpoch == swipeUndoEpoch else { return }
        try write(.local) {
            try database.execute("DELETE FROM episode_swipe_undo WHERE episode_id = ? AND operation_id = ?",
                [.integer(receipt.episodeID), .text(receipt.operationID.uuidString)])
            try Task.checkCancellation()
        }
    }

    private func hasSwipeUndo(_ receipt: EpisodeMarkReceipt) throws -> Bool {
        try database.scalar("SELECT count(*) FROM episode_swipe_undo WHERE episode_id = ? AND operation_id = ?",
            [.integer(receipt.episodeID), .text(receipt.operationID.uuidString)]) == 1
    }

    private func updateSwipeSessionState(episodeID: Int64, state: EpisodePlayState) throws {
        if var session = try playbackSession(), session.episodeID == episodeID {
            session.itemPlayState = state
            try savePlaybackSession(session)
        }
    }

    /// Context Remove from inbox does not emit a played/unplayed sync action.
    public func removeEpisodeFromInbox(episodeID: Int64) throws {
        try Task.checkCancellation()
        try write(.dismiss) {
            guard try removeFromInboxInTransaction(episodeID) else { throw FeedLibraryError.missingEpisode(episodeID) }
        }
    }

    /// Multi-select Remove from inbox: `removeEpisodeFromInbox` for each episode, in one transaction (source
    /// `DBWriter.removeNewFlag` style batch). An episode that no longer exists is skipped, as the source's
    /// `UPDATE … WHERE id IN (…)` skips it.
    public func removeEpisodesFromInbox(episodeIDs: [Int64]) throws {
        try Task.checkCancellation()
        try write(.dismiss) {
            for id in episodeIDs { _ = try removeFromInboxInTransaction(id) }
            try Task.checkCancellation()
        }
    }

    private func removeFromInboxInTransaction(_ episodeID: Int64) throws -> Bool {
        guard var episode = try loadEpisode(episodeID) else { return false }
        episode.userState.playState = .unplayed
        try saveEpisode(episode, feedID: feedID(forEpisode: episodeID), explicitStateIntent: true)
        if var session = try playbackSession(), session.episodeID == episodeID {
            session.itemPlayState = .unplayed; try savePlaybackSession(session)
        }
        return true
    }

    /// Multi-select Add/Remove favorite: `setFavorite` for each episode, in one transaction. An episode that
    /// no longer exists is skipped. Every selected episode is set, as Android's `DBWriter.addFavoriteItems` sets the
    /// whole selection, also one already shown with the value.
    public func setFavorite(episodeIDs: [Int64], favorite: Bool) throws {
        try Task.checkCancellation()
        try write(.registers) {
            for id in episodeIDs { _ = try setFavoriteInTransaction(id, favorite: favorite) }
            try Task.checkCancellation()
        }
    }

    /// One episode of an explicit favorite command; false when it no longer exists. In a server library it is recorded
    /// with the value asked for even when the stored value already has it.
    private func setFavoriteInTransaction(_ id: Int64, favorite: Bool) throws -> Bool {
        guard var episode = try loadEpisode(id) else { return false }
        episode.userState.isFavorite = favorite
        try saveEpisode(episode, feedID: feedID(forEpisode: id))
        activeCapture?.favoriteTargets.insert(id)
        return true
    }

    public func markEpisodePlayed(episodeID: Int64, played: Bool, resetPosition: Bool = true,
                                  syncProviderConnected: Bool? = nil, now: Date = Date()) throws {
        try Task.checkCancellation()
        try write(.mark(played: played, resetPosition: resetPosition), now: now) {
            var headers: [Int64: LibraryFeed] = [:]
            let connected = try syncProviderConnected ?? (synchronizationState().accountID != nil)
            guard try markPlayedInTransaction(episodeID, played: played, resetPosition: resetPosition,
                                              providerConnected: connected, now: now, headers: &headers) else {
                throw FeedLibraryError.missingEpisode(episodeID)
            }
            try Task.checkCancellation()
        }
    }

    /// Multi-select Mark played/unplayed: `markEpisodePlayed` for each episode in the given order, with the same
    /// sync actions and statistics-session handling, in one transaction (source `DBWriter.markItemPlayed(state,
    /// ids…)` is one statement). An episode that no longer exists is skipped, as that statement skips it.
    public func markEpisodesPlayed(episodeIDs: [Int64], played: Bool, resetPosition: Bool = true,
                                   syncProviderConnected: Bool? = nil, now: Date = Date()) throws {
        try Task.checkCancellation()
        try write(.mark(played: played, resetPosition: resetPosition), now: now) {
            var headers: [Int64: LibraryFeed] = [:]
            let connected = try syncProviderConnected ?? (synchronizationState().accountID != nil)
            for id in episodeIDs {
                _ = try markPlayedInTransaction(id, played: played, resetPosition: resetPosition,
                                                providerConnected: connected, now: now, headers: &headers)
            }
            try Task.checkCancellation()
        }
    }

    private func markPlayedInTransaction(_ episodeID: Int64, played: Bool, resetPosition: Bool, providerConnected: Bool,
                                         now: Date, headers: inout [Int64: LibraryFeed]) throws -> Bool {
        guard var episode = try loadEpisode(episodeID) else { return false }
        let feedID = try feedID(forEpisode: episodeID)
        let feed: LibraryFeed
        if let cached = headers[feedID] { feed = cached } else {
            guard let header = try loadFeedHeader(feedID) else { throw FeedLibraryError.missingFeed(feedID) }
            headers[feedID] = header; feed = header
        }
        if let action = EpisodeStateSyncAction(episode: episode, feed: feed, played: played, providerConnected: providerConnected) {
            try appendEffect(.init(feedID: feedID, date: now, kind: .episodeStateChanged(action)))
        }
        episode.userState.playState = played ? .played : .unplayed
        if played && resetPosition && episode.details.media != nil { episode.userState.positionMilliseconds = 0 }
        try saveEpisode(episode, feedID: feedID, explicitStateIntent: true)
        // The statistics session may still be playing. Retain its identity
        // and counters, but never let a saved New flag undo an explicit mark.
        if var session = try playbackSession(), session.episodeID == episodeID {
            session.itemPlayState = episode.userState.playState
            try savePlaybackSession(session)
        }
        return true
    }

    /// Reset is not playback completion: keep queue, history, statistics and files.
    public func resetPlaybackPosition(episodeID: Int64) throws {
        try Task.checkCancellation()
        try write(.resetPosition) {
            guard var episode = try loadEpisode(episodeID) else { throw FeedLibraryError.missingEpisode(episodeID) }
            guard episode.details.media != nil else { throw FeedLibraryError.invalidMutation }
            episode.userState.positionMilliseconds = 0
            episode.userState.playState = .unplayed
            let feedID = try feedID(forEpisode: episodeID)
            try saveEpisode(episode, feedID: feedID, explicitStateIntent: true)
            // Invalidate the statistics writer in the same commit so a late
            // engine reading cannot restore the position that was just reset.
            try database.execute("DELETE FROM playback_session WHERE episode_id = ?", [.integer(episodeID)])
            try database.execute("DELETE FROM playback_selection WHERE episode_id = ?", [.integer(episodeID)])
            // A server library flushes and closes the episode's sessions, and clears its pending transition (PROTOCOL §8).
            try journalPositionReset(episodeID: episodeID, now: try milliseconds(Date()))
            try Task.checkCancellation()
        }
    }
}
