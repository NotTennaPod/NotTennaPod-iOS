import Foundation

/// Manual and periodic feed refresh requests.
extension FeedLibraryStore {
    /// Manual replacement is isolated from the periodic slot and its recovery journal.
    public func enqueueManualRefresh(_ request: FeedRefreshRequest, resetPagination: Bool = false) throws {
        try Task.checkCancellation()
        guard request.periodic == nil else { throw FeedLibraryError.invalidMutation }
        try write(.local) {
            if resetPagination {
                guard let id = request.feedID, !request.nextPage else { throw FeedLibraryError.invalidMutation }
                guard var feed = try loadFeedHeader(id) else { throw FeedLibraryError.missingFeed(id) }
                feed.resetPagination()
                try saveHeader(feed)
            }
            try saveRefreshRequest(request)
            try Task.checkCancellation()
        }
    }

    private func saveRefreshRequest(_ request: FeedRefreshRequest) throws {
        if try refreshRequest(slot: request.slot)?.id != request.id {
            try database.execute("DELETE FROM episode_notification_work WHERE request_slot = ?", [.integer(request.slot)])
            try database.execute("DELETE FROM episode_notification_attempt WHERE id = ?", [.integer(request.slot)])
        }
        try database.execute("INSERT INTO feed_refresh_request(id, record) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET record = excluded.record",
            [.integer(request.slot), .blob(try JSONEncoder().encode(request))])
    }

    public func manualRefreshRequest() throws -> FeedRefreshRequest? { try refreshRequest(slot: 1) }

    private func refreshRequest(slot: Int64) throws -> FeedRefreshRequest? {
        guard let row = try database.rows("SELECT record FROM feed_refresh_request WHERE id = ?", [.integer(slot)]).first else { return nil }
        let request: FeedRefreshRequest = try decode(row[0])
        guard request.slot == slot else { throw FeedLibraryError.corruptRecord }
        return request
    }

    public func refreshRequest(id: UUID) throws -> FeedRefreshRequest? {
        for slot: Int64 in [1, 2] {
            if let request = try refreshRequest(slot: slot), request.id == id { return request }
        }
        return nil
    }

    @discardableResult
    public func finishManualRefresh(id: UUID) throws -> Bool {
        guard try manualRefreshRequest()?.id == id else { return false }
        return try finishRefresh(id: id)
    }

    @discardableResult
    public func finishRefresh(id: UUID, now: Date = Date()) throws -> Bool {
        try Task.checkCancellation()
        return try write(.local) {
            guard let request = try refreshRequest(id: id) else { return false }
            if let periodic = request.periodic, var schedule = try periodicRefreshSchedule(), schedule.id == periodic.id {
                schedule.nextCheck = now.addingTimeInterval(3_600)
                try savePeriodicSchedule(schedule)
            }
            try database.execute("DELETE FROM feed_refresh_request WHERE id = ?", [.integer(request.slot)])
            try Task.checkCancellation()
            return true
        }
    }

    // Existing refresh services pass the execution UUID here. Both independent
    // slots now use this guard; an obsolete/replaced execution cannot commit.
    func requireManualRefresh(_ id: UUID?) throws {
        if let id, try refreshRequest(id: id) == nil { throw CancellationError() }
    }

    func refreshSlot(_ id: UUID) throws -> Int64 {
        guard let request = try refreshRequest(id: id) else { throw CancellationError() }
        return request.slot
    }

    public func periodicRefreshSchedule() throws -> PeriodicFeedRefreshSchedule? {
        guard let row = try database.rows("SELECT record FROM periodic_feed_schedule WHERE id = 1").first else { return nil }
        return try decode(row[0])
    }

    private func savePeriodicSchedule(_ schedule: PeriodicFeedRefreshSchedule) throws {
        try database.execute("INSERT INTO periodic_feed_schedule(id, record) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET record = excluded.record",
            [.blob(try JSONEncoder().encode(schedule))])
    }

    @discardableResult
    public func configurePeriodicRefresh(intervalMinutes: Int, allowMobile: Bool, replace: Bool, now: Date = Date()) throws -> PeriodicFeedRefreshSchedule? {
        guard PeriodicFeedRefreshSchedule.intervals.contains(intervalMinutes) else { throw FeedLibraryError.invalidMutation }
        try Task.checkCancellation()
        return try write(.local) {
            if intervalMinutes == 0 {
                try database.execute("DELETE FROM feed_refresh_request WHERE id = 2")
                try database.execute("DELETE FROM periodic_feed_schedule")
                try Task.checkCancellation()
                return nil
            }
            if !replace, let saved = try periodicRefreshSchedule() { return saved }
            try database.execute("DELETE FROM feed_refresh_request WHERE id = 2")
            let schedule = PeriodicFeedRefreshSchedule(intervalMinutes: intervalMinutes, allowMobile: allowMobile, now: now)
            try savePeriodicSchedule(schedule)
            try Task.checkCancellation()
            return schedule
        }
    }

    public func beginPeriodicRefresh(now: Date = Date()) throws -> FeedRefreshRequest? {
        try Task.checkCancellation()
        return try write(.local) {
            guard let schedule = try periodicRefreshSchedule() else { return nil }
            if let saved = try refreshRequest(slot: 2) { return saved }
            guard schedule.nextCheck <= now else { return nil }
            let request = FeedRefreshRequest(periodic: schedule, enqueuedAt: now)
            try saveRefreshRequest(request)
            try Task.checkCancellation()
            return request
        }
    }
}
