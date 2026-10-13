import Foundation

/// The Statistics screen's pages, in source tab order (`StatisticsFragment.java:48–51, 85–99`).
/// The selected page is screen state only: it is never stored.
public enum StatisticsTab: Int, CaseIterable, Sendable {
    case subscriptions = 0, years = 1, downloads = 2

    public var titleKey: String {
        switch self {
        case .subscriptions: "subscriptions_label"
        case .years: "years_statistics_label"
        case .downloads: "downloads_label"
        }
    }

    /// Toolbar menu per page (`statistics.xml`, `SubscriptionStatisticsFragment:84–89`,
    /// `YearsStatisticsFragment:71–76`, `DownloadStatisticsFragment:56–61`). Echo never shows
    /// in a 2026+ release build and is excluded.
    public var showsFilter: Bool { self == .subscriptions }
    public var showsReset: Bool { self != .downloads }
}
