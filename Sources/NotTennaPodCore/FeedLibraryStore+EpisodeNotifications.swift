import Foundation

/// New-episode notifications and counters.
extension FeedLibraryStore {
    /// PodDBAdapter SHOW_NEW: without IDs only subscribed feeds participate;
    /// explicit IDs count every subscription state. Zero counts are omitted.
    /// Test inspection API: not called by the app.
    func newEpisodeCounts(feedIDs: [Int64] = []) throws -> [Int64: Int] {
        try Task.checkCancellation()
        return try database.transaction(write: false) { try readNewEpisodeCounts(feedIDs: feedIDs) }
    }

    /// Test inspection API: not called by the app.
    func newEpisodeNotificationBaseline(manualRequestID: UUID) throws -> NewEpisodeNotificationBaseline {
        try Task.checkCancellation()
        return try database.transaction(write: false) {
            try requireManualRefresh(manualRequestID)
            return NewEpisodeNotificationBaseline(requestID: manualRequestID, counts: try readNewEpisodeCounts(feedIDs: []))
        }
    }

    /// Source uses the just-refreshed feed's preference/title snapshot and a
    /// fresh count. The caller must retain ownership through OS publication.
    /// Test inspection API: not called by the app.
    func newEpisodeNotification(for feed: LibraryFeed, baseline: NewEpisodeNotificationBaseline) throws -> NewEpisodeNotification? {
        try Task.checkCancellation()
        return try database.transaction(write: false) {
            try requireManualRefresh(baseline.requestID)
            guard feed.keepUpdated && feed.showEpisodeNotification else { return nil }
            return baseline.notification(for: feed, newCount: try readNewEpisodeCounts(feedIDs: [feed.id])[feed.id] ?? 0)
        }
    }

    /// Installed before the worker starts feed writes. Recovery drains old work
    /// first; each subsequent attempt retains the source's fresh baseline rule.
    func beginEpisodeNotificationAttempt(requestID: UUID) throws -> NewEpisodeNotificationBaseline {
        try Task.checkCancellation()
        return try write(.local) {
            try requireManualRefresh(requestID)
            // Only feeds with notifications on use a baseline (off by default): counting every episode of the
            // library at the start of every refresh run parsed all of its records for nothing.
            let notifying = try notifyingFeedIDs()
            let baseline = NewEpisodeNotificationBaseline(requestID: requestID,
                counts: notifying.isEmpty ? [:] : try readNewEpisodeCounts(feedIDs: [], within: notifying),
                notifyingFeedIDs: notifying)
            try database.execute("INSERT INTO episode_notification_attempt(id, record) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET record = excluded.record",
                [.integer(try refreshSlot(requestID)), .blob(try JSONEncoder().encode(baseline))])
            try Task.checkCancellation()
            return baseline
        }
    }

    func stageCommittedEpisodeNotification(_ feed: LibraryFeed, manualRequestID: UUID?) throws {
        guard let manualRequestID,
              let row = try database.rows("SELECT record FROM episode_notification_attempt WHERE id = ?", [.integer(try refreshSlot(manualRequestID))]).first else { return }
        let baseline: NewEpisodeNotificationBaseline = try decode(row[0])
        guard baseline.requestID == manualRequestID else { throw CancellationError() }
        _ = try writeEpisodeNotification(feed, baseline: baseline)
    }

    /// Also admits explicitly reported refreshes. A merge already journals this
    /// inside its transaction, closing the commit→completion-callback crash gap.
    func stageEpisodeNotification(_ feed: LibraryFeed, baseline: NewEpisodeNotificationBaseline) throws -> PendingEpisodeNotification? {
        try Task.checkCancellation()
        return try write(.local) {
            try requireManualRefresh(baseline.requestID)
            let pending = try writeEpisodeNotification(feed, baseline: baseline)
            try Task.checkCancellation()
            return pending
        }
    }

    private func writeEpisodeNotification(_ feed: LibraryFeed, baseline: NewEpisodeNotificationBaseline) throws -> PendingEpisodeNotification? {
        // A server library notifies once per release of its discovery ledger instead (PROTOCOL §9.9, `deliverServerReleases`).
        guard serverContext == nil else { return nil }
        if let pending = try loadEpisodeNotification(feedID: feed.id, requestID: baseline.requestID) { return pending }
        guard feed.keepUpdated && feed.showEpisodeNotification, baseline.counted(feed.id),
              try database.scalar("SELECT count(*) FROM feeds WHERE id = ?", [.integer(feed.id)]) == 1, try !isHiddenFeed(feed.id) else { return nil }
        let pending = PendingEpisodeNotification(feed: feed, baseline: baseline)
        try saveEpisodeNotification(pending)
        return pending
    }

    func pendingEpisodeNotifications(requestID: UUID) throws -> [PendingEpisodeNotification] {
        try Task.checkCancellation()
        return try database.transaction(write: false) {
            try requireManualRefresh(requestID)
            return try database.rows("SELECT record FROM episode_notification_work WHERE request_slot = ? ORDER BY feed_id", [.integer(try refreshSlot(requestID))]).map { row in
                let pending: PendingEpisodeNotification = try decode(row[0])
                guard pending.requestID == requestID else { throw FeedLibraryError.corruptRecord }
                return pending
            }
        }
    }

    func pendingEpisodeNotification(_ pending: PendingEpisodeNotification) throws -> Bool {
        try Task.checkCancellation()
        return try database.transaction(write: false) {
            try requireManualRefresh(pending.requestID)
            return try loadEpisodeNotification(feedID: pending.feedID, requestID: pending.requestID)?.id == pending.id
        }
    }

    func episodeNotificationCandidate(_ pending: PendingEpisodeNotification) throws -> NewEpisodeNotification? {
        try Task.checkCancellation()
        return try database.transaction(write: false) {
            try requireManualRefresh(pending.requestID)
            guard try loadEpisodeNotification(feedID: pending.feedID, requestID: pending.requestID)?.id == pending.id else { return nil }
            // Checked again at publication: a podcast hidden since (a removal from the server) notifies nothing.
            guard try !isHiddenFeed(pending.feedID) else { return nil }
            let count = try readNewEpisodeCounts(feedIDs: [pending.feedID])[pending.feedID] ?? 0
            guard count > pending.beforeCount else { return nil }
            return NewEpisodeNotification(feedID: pending.feedID, title: pending.title, imageURL: pending.imageURL, count: count)
        }
    }

    @discardableResult
    func markEpisodeNotificationChildPublished(_ pending: PendingEpisodeNotification) throws -> Bool {
        try Task.checkCancellation()
        return try write(.local) {
            try requireManualRefresh(pending.requestID)
            guard var current = try loadEpisodeNotification(feedID: pending.feedID, requestID: pending.requestID), current.id == pending.id else { return false }
            current.childPublished = true
            try saveEpisodeNotification(current)
            try Task.checkCancellation()
            return true
        }
    }

    func acknowledgeEpisodeNotification(_ pending: PendingEpisodeNotification) throws {
        try Task.checkCancellation()
        try write(.local) {
            try requireManualRefresh(pending.requestID)
            guard try loadEpisodeNotification(feedID: pending.feedID, requestID: pending.requestID)?.id == pending.id else { return }
            try database.execute("DELETE FROM episode_notification_work WHERE feed_id = ? AND request_slot = ?", [.integer(pending.feedID), .integer(try refreshSlot(pending.requestID))])
            try Task.checkCancellation()
        }
    }

    private func loadEpisodeNotification(feedID: Int64, requestID: UUID) throws -> PendingEpisodeNotification? {
        guard let row = try database.rows("SELECT record FROM episode_notification_work WHERE feed_id = ? AND request_slot = ?", [.integer(feedID), .integer(try refreshSlot(requestID))]).first else { return nil }
        let pending: PendingEpisodeNotification = try decode(row[0])
        guard pending.feedID == feedID else { throw FeedLibraryError.corruptRecord }
        return pending
    }

    private func saveEpisodeNotification(_ pending: PendingEpisodeNotification) throws {
        try database.execute("INSERT INTO episode_notification_work(feed_id, request_slot, record) VALUES (?, ?, ?) ON CONFLICT(feed_id, request_slot) DO UPDATE SET record = excluded.record",
            [.integer(pending.feedID), .integer(try refreshSlot(pending.requestID)), .blob(try JSONEncoder().encode(pending))])
    }

    private struct CounterFeed: Decodable {
        let id: Int64
        let subscriptionState: FeedSubscriptionState
        /// `LibraryFeed`'s stored optionals (absent: true and false respectively).
        let keepUpdatedValue: Bool?
        let showEpisodeNotificationValue: Bool?
    }

    /// Feeds with episode notifications on (`keepUpdated && showEpisodeNotification`), in any subscription state.
    private func notifyingFeedIDs() throws -> Set<Int64> {
        var ids: Set<Int64> = []
        for row in try database.rows("SELECT f.id, f.record FROM feeds f" + (hiddenFeedsCondition("f.id").map { " WHERE " + $0 } ?? "")) {
            let feed: CounterFeed = try decode(row[1])
            guard row[0].integer == feed.id else { throw FeedLibraryError.corruptRecord }
            if feed.keepUpdatedValue ?? true, feed.showEpisodeNotificationValue ?? false { ids.insert(feed.id) }
        }
        return ids
    }

    private struct CounterEpisode: Decodable {
        struct State: Decodable { let playState: EpisodePlayState }
        let id: Int64
        let userState: State
    }

    /// `within` limits the counted feeds further (feeds outside it are left out, like zero counts).
    private func readNewEpisodeCounts(feedIDs: [Int64], within: Set<Int64>? = nil) throws -> [Int64: Int] {
        let selected = Set(feedIDs)
        var counts: [Int64: Int] = [:]
        // Count from a projection: avoid retaining every feed's full episode
        // metadata/artwork/chapters in memory for a single notification baseline.
        // A server library counts only what the screens show: no hidden podcast, no staged episode.
        let hiddenEpisodes = serverContext != nil ? " AND id NOT IN (SELECT episode_id FROM ntp_hidden_episodes)" : ""
        for row in try database.rows("SELECT f.id, f.record FROM feeds f" + (hiddenFeedsCondition("f.id").map { " WHERE " + $0 } ?? "")) {
            try Task.checkCancellation()
            guard let id = row[0].integer else { throw FeedLibraryError.corruptRecord }
            if !selected.isEmpty && !selected.contains(id) { continue }
            if let within, !within.contains(id) { continue }
            let feed: CounterFeed = try decode(row[1])
            guard feed.id == id else { throw FeedLibraryError.corruptRecord }
            if selected.isEmpty && feed.subscriptionState != .subscribed { continue }
            var count = 0
            for episodeRow in try database.rows("SELECT id, record FROM episodes WHERE feed_id = ?" + hiddenEpisodes, [.integer(id)]) {
                try Task.checkCancellation()
                let episode: CounterEpisode = try decode(episodeRow[1])
                guard episodeRow[0].integer == episode.id else { throw FeedLibraryError.corruptRecord }
                if episode.userState.playState == .new { count += 1 }
            }
            if count != 0 { counts[id] = count }
        }
        return counts
    }
}
