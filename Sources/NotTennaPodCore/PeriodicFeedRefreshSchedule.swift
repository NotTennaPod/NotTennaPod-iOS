import Foundation

/// The source polls hourly; the user's interval filters individual feeds at execution.
public struct PeriodicFeedRefreshSchedule: Codable, Equatable, Sendable {
    public static let intervals = [0, 60, 120, 240, 480, 720, 1440, 4320]
    public static let defaultInterval = 720
    public let id: UUID
    public let intervalMinutes: Int
    public let allowMobile: Bool
    public var nextCheck: Date

    public init(intervalMinutes: Int, allowMobile: Bool, now: Date) {
        id = UUID(); self.intervalMinutes = intervalMinutes
        self.allowMobile = allowMobile; nextCheck = now
    }
}
