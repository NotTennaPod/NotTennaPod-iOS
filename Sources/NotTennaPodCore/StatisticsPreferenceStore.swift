import Foundation

/// Persist all three global choices as one atomic value. A failed write cannot
/// publish a tuple that differs from the durable one.
@MainActor public final class StatisticsPreferenceStore: JSONPreferenceStore<StatisticsPeriodPreferences> {
    public init(file: URL) throws { try super.init(file: file, defaultValue: .init()) }
}
