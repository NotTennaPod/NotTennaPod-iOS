import Foundation

public struct NavigationPreferences: Codable, Equatable, Sendable {
    public var bottomNavigation = true
    public var backButtonOpensDrawer = false
    public var streamOverDownload = false
    public var streamingSuggestionHidden = false
    public var configuration = NavigationConfiguration()
    public var defaultPage = NavigationDestination.home.rawValue
    public var lastPage = NavigationDestination.home.rawValue
    public var defaultFeedSortOrder: FeedEpisodeSortOrder = .dateNewest
    public init() {}

    public mutating func chooseStreamOverDownload(_ enabled: Bool) {
        streamOverDownload = enabled
        // The original explicit setting choice calls UsageStatistics.doNotAskAgain.
        streamingSuggestionHidden = true
    }

    /// ItemFragment's suggestion differs from the explicit Settings choice:
    /// Yes changes the preference only; No suppresses both suggestion directions.
    public mutating func respondToStreamingSuggestion(offerStreaming: Bool, accept: Bool) {
        if accept { streamOverDownload = offerStreaming }
        else { streamingSuggestionHidden = true }
    }

    private enum CodingKeys: String, CodingKey { case bottomNavigation, backButtonOpensDrawer, streamOverDownload, streamingSuggestionHidden, configuration, defaultPage, lastPage, defaultFeedSortOrder }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bottomNavigation = try values.decodeIfPresent(Bool.self, forKey: .bottomNavigation) ?? true
        backButtonOpensDrawer = try values.decodeIfPresent(Bool.self, forKey: .backButtonOpensDrawer) ?? false
        streamOverDownload = try values.decodeIfPresent(Bool.self, forKey: .streamOverDownload) ?? false
        streamingSuggestionHidden = try values.decodeIfPresent(Bool.self, forKey: .streamingSuggestionHidden) ?? false
        configuration = try values.decodeIfPresent(NavigationConfiguration.self, forKey: .configuration) ?? .init()
        defaultPage = try values.decodeIfPresent(String.self, forKey: .defaultPage) ?? NavigationDestination.home.rawValue
        lastPage = try values.decodeIfPresent(String.self, forKey: .lastPage) ?? NavigationDestination.home.rawValue
        defaultFeedSortOrder = try values.decodeIfPresent(FeedEpisodeSortOrder.self, forKey: .defaultFeedSortOrder) ?? .dateNewest
    }

    public enum StartupRoute: Equatable, Sendable { case destination(NavigationDestination), feed(Int64) }
    public var startupRoute: StartupRoute {
        if let destination = NavigationDestination(rawValue: startupPage), destination != .subscriptionList {
            return .destination(destination)
        }
        // MainActivity only parses a remembered feed ID, with Integer.parseInt's range.
        if defaultPage == "remember", let id = Int32(startupPage) { return .feed(Int64(id)) }
        return .destination(.home)
    }
    /// The source saves the root tag while loading it; fallback screen and tag can differ.
    public var startupTag: String {
        if defaultPage != "remember" { return defaultPage }
        if NavigationDestination(rawValue: lastPage) != nil || Int32(lastPage) != nil { return lastPage }
        return NavigationDestination.home.rawValue
    }
    public var selectedDefaultPageIndex: Int? { Self.defaultPageChoices.lastIndex(of: defaultPage) }
    @discardableResult public mutating func selectDefaultPage(at index: Int) -> Bool {
        guard Self.defaultPageChoices.indices.contains(index) else { return false }
        defaultPage = Self.defaultPageChoices[index]
        return true
    }

    public var startupPage: String { defaultPage == "remember" ? lastPage : defaultPage }
    public static let defaultPageChoices = ["HomeFragment", "QueueFragment", "NewEpisodesFragment", "EpisodesFragment",
                                           "SubscriptionFragment", "StatisticsFragment", "remember"]
}

@MainActor public final class NavigationPreferenceStore: JSONPreferenceStore<NavigationPreferences> {
    public init(file: URL) throws { try super.init(file: file, defaultValue: .init()) }
}
