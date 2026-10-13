import Foundation
import Testing
@testable import NotTennaPodCore

struct NavigationConfigurationTests {
    @Test func releaseDefaults() {
        let configuration = NavigationConfiguration()
        #expect(configuration.visibleDrawerItems == [
            .home, .queue, .inbox, .subscriptions, .episodes, .downloads,
            .history, .favorites, .statistics, .addPodcast, .subscriptionList
        ])
        #expect(configuration.bottomBarActions == [
            .destination(.home), .destination(.queue), .destination(.inbox), .destination(.subscriptions), .more
        ])
        #expect(configuration.moreActions == [
            .destination(.episodes), .destination(.downloads), .destination(.history),
            .destination(.favorites), .destination(.statistics), .destination(.addPodcast), .customize, .settings
        ])
    }

    @Test func reorderingHidingAndUnknownSavedTags() {
        let configuration = NavigationConfiguration(
            hiddenTags: ["QueueFragment", "Unknown"],
            orderedTags: ["Unknown", "DownloadsFragment", "HomeFragment", "DownloadsFragment", "QueueFragment"]
        )
        #expect(configuration.visibleDrawerItems == [
            .downloads, .home, .inbox, .subscriptions, .episodes,
            .history, .favorites, .statistics, .addPodcast, .subscriptionList
        ])
        #expect(configuration.bottomBarActions == [
            .destination(.downloads), .destination(.home), .destination(.inbox), .destination(.subscriptions), .more
        ])
    }

    @Test func subscriptionListNeverConsumesATabSlot() {
        let configuration = NavigationConfiguration(orderedTags: ["SubscriptionList", "AddFeedFragment"])
        #expect(configuration.visibleDrawerItems.first == .subscriptionList)
        #expect(configuration.bottomBarActions == [
            .destination(.addPodcast), .destination(.home), .destination(.queue), .destination(.inbox), .more
        ])
    }

    @Test func emptyNavigationStillExposesCustomizationAndSettings() {
        let configuration = NavigationConfiguration(hiddenTags: NavigationDestination.allCases.map(\.rawValue))
        #expect(configuration.bottomBarActions == [.more])
        #expect(configuration.moreActions == [.customize, .settings])
        #expect(configuration.selectedBottomAction(for: .home) == .more)
    }

    @Test func everyHiddenItemCombinationRetainsExactlyTheVisibleDestinations() {
        let destinations = NavigationDestination.allCases
        for mask in 0..<(1 << destinations.count) {
            let hidden = destinations.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            let configuration = NavigationConfiguration(hiddenTags: hidden.map(\.rawValue))
            let expected = destinations.filter { !hidden.contains($0) && $0 != .subscriptionList }
            let actions = configuration.bottomBarActions + configuration.moreActions
            let actual = actions.compactMap { action -> NavigationDestination? in
                if case let .destination(destination) = action { return destination }
                return nil
            }
            #expect(actual == expected, "hidden mask=\(mask)")
            #expect(configuration.bottomBarActions.count <= 5)
            #expect(configuration.bottomBarActions.last == .more)
            #expect(configuration.moreActions.suffix(2) == [.customize, .settings])
            for destination in expected {
                #expect(configuration.selectedBottomAction(for: destination)
                    == (expected.prefix(4).contains(destination) ? .destination(destination) : .more))
            }
        }
    }
}
