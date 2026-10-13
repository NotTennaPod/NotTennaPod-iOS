import Foundation

/// Android `DatabaseMaintenanceWorker` (DatabaseMaintenanceWorker.java:22–27, 36–41): a unique periodic
/// work of 3 days (KEEP, no constraints, first period at once) that runs `PodDBAdapter.clearOldDownloadLog`
/// (PodDBAdapter.java:983–986): `DELETE FROM DownloadLog WHERE completion_date < now - 7 days`.
///
/// iOS cannot run periodic work while the app is closed, so the schedule is kept as a durable `lastRun`
/// and applied whenever the app starts, becomes active or gets background time (an adaptation). A person
/// sees the same Download log: rows older than 7 days are gone, at most 3 days later than the exact cutoff.
public enum DatabaseMaintenanceSchedule {
    /// `7L * 24L * 3600L * 1000L` (PodDBAdapter.java:985).
    public static let retentionMilliseconds: Int64 = 604_800_000
    /// `PeriodicWorkRequest.Builder(…, 3, TimeUnit.DAYS)` (DatabaseMaintenanceWorker.java:23–24).
    public static let periodMilliseconds: Int64 = 259_200_000

    /// Rows with a completion date strictly before this are deleted; a row exactly 7 days old is kept.
    public static func cutoff(nowMilliseconds: Int64) -> Int64 { nowMilliseconds - retentionMilliseconds }

    /// Never run, or at least one full period since the last run. A clock set back before the last run
    /// waits until that period has passed again, as WorkManager's period does.
    public static func isDue(lastRunMilliseconds: Int64?, nowMilliseconds: Int64) -> Bool {
        guard let last = lastRunMilliseconds else { return true }
        return nowMilliseconds - last >= periodMilliseconds
    }
}

/// Owns the durable maintenance schedule beside one library. The record lives outside the database,
/// as Android's WorkManager schedule does, so a database import keeps the schedule.
public actor DatabaseMaintenance {
    struct Record: Codable, Equatable { var lastRunMilliseconds: Int64? }

    private let store: FeedLibraryStore
    private let file: URL
    private let clock: @Sendable () -> Date

    public init(store: FeedLibraryStore, file: URL, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.file = file; self.clock = clock
    }

    public var lastRun: Date? {
        (try? load().lastRunMilliseconds).flatMap { $0 }.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    /// Runs the source maintenance when it is due. Returns the number of deleted log entries, or nil
    /// when it was not due. The schedule advances only after the deletion committed.
    @discardableResult public func runIfDue() async throws -> Int? {
        let now = Self.milliseconds(clock())
        guard DatabaseMaintenanceSchedule.isDue(lastRunMilliseconds: try load().lastRunMilliseconds, nowMilliseconds: now) else {
            return nil
        }
        let deleted = try await store.pruneDownloadLog(beforeMilliseconds: DatabaseMaintenanceSchedule.cutoff(nowMilliseconds: now))
        try JSONEncoder().encode(Record(lastRunMilliseconds: now)).write(to: file, options: .atomic)
        return deleted
    }

    private func load() throws -> Record {
        guard FileManager.default.fileExists(atPath: file.path) else { return Record() }
        return try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
    }

    static func milliseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
}
