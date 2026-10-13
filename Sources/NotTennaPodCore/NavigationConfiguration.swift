public enum NavigationDestination: String, CaseIterable, Codable, Sendable {
    case home = "HomeFragment"
    case queue = "QueueFragment"
    case inbox = "NewEpisodesFragment"
    case subscriptions = "SubscriptionFragment"
    case episodes = "EpisodesFragment"
    case downloads = "DownloadsFragment"
    case history = "PlaybackHistoryFragment"
    case favorites = "FavoritesFragment"
    case statistics = "StatisticsFragment"
    case addPodcast = "AddFeedFragment"
    case subscriptionList = "SubscriptionList"
}

public enum NavigationAction: Equatable, Sendable {
    case destination(NavigationDestination)
    case more
    case customize
    case settings
}

public struct NavigationConfiguration: Equatable, Codable, Sendable {
    public var hiddenTags: [String]
    public var orderedTags: [String]

    public init(hiddenTags: [String] = [], orderedTags: [String] = []) {
        self.hiddenTags = hiddenTags
        self.orderedTags = orderedTags
    }

    public var visibleDrawerItems: [NavigationDestination] {
        NavigationDestination.allCases.enumerated().sorted { left, right in
            let leftOrder = orderedTags.firstIndex(of: left.element.rawValue) ?? Int.max
            let rightOrder = orderedTags.firstIndex(of: right.element.rawValue) ?? Int.max
            return leftOrder == rightOrder ? left.offset < right.offset : leftOrder < rightOrder
        }.map(\.element).filter { !hiddenTags.contains($0.rawValue) }
    }

    public var bottomBarActions: [NavigationAction] {
        Array(bottomDestinations.prefix(4)).map(NavigationAction.destination) + [.more]
    }

    public var moreActions: [NavigationAction] {
        Array(bottomDestinations.dropFirst(4)).map(NavigationAction.destination) + [.customize, .settings]
    }

    public func selectedBottomAction(for destination: NavigationDestination) -> NavigationAction {
        let action = NavigationAction.destination(destination == .subscriptionList ? .home : destination)
        return bottomBarActions.contains(action) ? action : .more
    }

    private var bottomDestinations: [NavigationDestination] {
        visibleDrawerItems.filter { $0 != .subscriptionList }
    }
}
