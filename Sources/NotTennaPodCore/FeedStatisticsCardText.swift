import Foundation

/// FeedStatisticsFragment.showStats' exact card assignments and resource keys.
public struct FeedStatisticsCardText: Equatable, Sendable {
    public enum ID: String, CaseIterable, Sendable {
        case playbackTime, episodesStarted, spaceDownloaded
        case durationTotal, episodesTotal, episodesDownloaded
        case expectedNextEpisode, episodeSchedule
    }
    public struct Text: Equatable, Sendable {
        public let value: String
        public let subtitle: String
        public init(value: String, subtitle: String) { self.value = value; self.subtitle = subtitle }
    }
    public let values: [ID: Text]

    public init(snapshot: FeedStatisticsSnapshot, formatter: StatisticsTextFormatter,
                text: (String) -> String, quantity: (String, Int64) -> String) {
        let statistics = snapshot.statistics
        let next: String
        switch snapshot.release.next {
        case .textKey(let key): next = text(key)
        case .date(let date): next = formatter.abbreviatedDate(date)
        }
        values = [
            .playbackTime: Text(value: formatter.duration(seconds: statistics.playedSeconds, hoursLabel: text("time_hours")), subtitle: text("statistics_time_played")),
            .episodesStarted: Text(value: quantity("num_episodes", statistics.episodesStarted), subtitle: quantity("statistics_episodes_started", statistics.episodesStarted)),
            .spaceDownloaded: Text(value: formatter.fileSize(bytes: statistics.downloadedBytes), subtitle: text("statistics_episodes_space")),
            .durationTotal: Text(value: formatter.duration(seconds: statistics.totalSeconds, hoursLabel: text("time_hours")), subtitle: text("statistics_time_total")),
            .episodesTotal: Text(value: quantity("num_episodes", statistics.episodes), subtitle: quantity("statistics_episodes_total", statistics.episodes)),
            .episodesDownloaded: Text(value: quantity("num_episodes", statistics.downloadedEpisodes), subtitle: quantity("statistics_episodes_downloaded", statistics.downloadedEpisodes)),
            .expectedNextEpisode: Text(value: next, subtitle: text("statistics_release_next")),
            .episodeSchedule: Text(value: snapshot.release.scheduleText(text: text), subtitle: text("statistics_release_schedule"))
        ]
    }
}
