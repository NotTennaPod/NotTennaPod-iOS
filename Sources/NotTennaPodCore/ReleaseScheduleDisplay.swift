import Foundation

/// FeedStatisticsFragment's expected-release and schedule cards. Localized date
/// formatting belongs to the view; this value preserves the source decisions.
public struct ReleaseScheduleDisplay: Equatable, Sendable {
    public enum Next: Equatable, Sendable { case textKey(String), date(Date) }
    public let next: Next
    public let scheduleKeys: [String]

    public init(guess: ReleaseScheduleGuess?, local: Bool, keepUpdated: Bool, now: Date) {
        let unknown = "statistics_expected_next_episode_unknown"
        if local {
            next = .textKey("local_folder"); scheduleKeys = ["local_folder"]
        } else if !keepUpdated {
            next = .textKey("updates_disabled_label"); scheduleKeys = ["updates_disabled_label"]
        } else if let guess, let expected = guess.nextExpectedDate, expected > now.addingTimeInterval(-7 * 24 * 3600) {
            next = expected <= now
                ? .textKey(guess.multipleReleasesPerDay ? "statistics_expected_next_episode_any_time" : "statistics_expected_next_episode_any_day")
                : .date(expected)
            var keys: [String] = []
            if guess.multipleReleasesPerDay && guess.schedule != .unknown { keys.append("release_schedule_multiple_per_day") }
            switch guess.schedule {
            case .daily: keys.append("release_schedule_daily")
            case .weekdays: keys.append("release_schedule_weekdays")
            case .weekly, .biweekly, .fourweekly:
                keys.append(guess.schedule == .weekly ? "release_schedule_weekly" : guess.schedule == .biweekly ? "release_schedule_biweekly" : "release_schedule_monthly")
                keys.append(Self.dayKey(guess.days?.first ?? 0))
            case .monthly: keys.append("release_schedule_monthly")
            case .specificDays: keys += (guess.days ?? []).map(Self.dayKey)
            case .unknown: keys.append(unknown)
            }
            scheduleKeys = keys
        } else {
            next = .textKey(unknown); scheduleKeys = [unknown]
        }
    }

    public func scheduleText(text: (String) -> String) -> String { scheduleKeys.map(text).joined(separator: ", ") }

    private static func dayKey(_ day: Int) -> String {
        switch day {
        case 1: "release_schedule_sunday"
        case 2: "release_schedule_monday"
        case 3: "release_schedule_tuesday"
        case 4: "release_schedule_wednesday"
        case 5: "release_schedule_thursday"
        case 6: "release_schedule_friday"
        case 7: "release_schedule_saturday"
        default: "error"
        }
    }
}
