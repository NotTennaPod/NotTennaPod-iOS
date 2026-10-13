import Foundation
import Testing
@testable import NotTennaPodCore

struct NavigationBackPolicyTests {
    @Test func matchesUnmodifiedMainActivityBackHandler() throws {
        struct Oracle: Decodable { let page: String; let root: String; let depth: Int; let bottom: Bool; let back: Bool; let persistent: Bool; let action: String }
        let url = try #require(Bundle.module.url(forResource: "navigation-back-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let cases = try JSONDecoder().decode([Oracle].self, from: Data(contentsOf: url))
        #expect(cases.count == 3744)
        for item in cases {
            var preferences = NavigationPreferences()
            preferences.defaultPage = item.page; preferences.bottomNavigation = item.bottom; preferences.backButtonOpensDrawer = item.back
            let result = NavigationBackPolicy.action(preferences: preferences, rootTag: item.root, childDepth: item.depth,
                playerExpanded: false, drawerOpen: false, persistentDrawer: item.persistent)
            let actual: String
            switch result {
            case .popChild: actual = "pop"
            case .openDefault(let tag): actual = "default:" + tag
            case .openDrawer: actual = "drawer"
            case .system: actual = "system"
            default: actual = "unexpected"
            }
            #expect(actual == item.action)
        }
    }

    @Test func modalAndPlayerCallbacksPrecedeTheMainHandler() {
        // Source registration puts the expanded bottom-sheet callback above MainActivity.
        // Settings owns its separate activity stack; persistent sidebar isn't an open modal.
        var preferences = NavigationPreferences(); preferences.bottomNavigation = false
        for depth in [0, 1, 3] {
            #expect(NavigationBackPolicy.action(preferences: preferences, rootTag: "QueueFragment", childDepth: depth,
                playerExpanded: true, drawerOpen: false, persistentDrawer: false) == .collapsePlayer)
            #expect(NavigationBackPolicy.action(preferences: preferences, rootTag: "QueueFragment", childDepth: depth,
                playerExpanded: true, drawerOpen: true, persistentDrawer: false) == .closeDrawer)
            #expect(NavigationBackPolicy.action(preferences: preferences, rootTag: "QueueFragment", childDepth: depth,
                playerExpanded: true, drawerOpen: true, persistentDrawer: true) == .collapsePlayer)
        }
        #expect(NavigationBackPolicy.action(preferences: preferences, rootTag: "QueueFragment", childDepth: 2,
            playerExpanded: true, drawerOpen: true, persistentDrawer: false, settingsVisible: true) == .popChild)
    }

    @Test func chooserPreservesAllOtherStateAndDoesNotFilterHiddenOptions() {
        let expected = ["HomeFragment", "QueueFragment", "NewEpisodesFragment", "EpisodesFragment", "SubscriptionFragment", "StatisticsFragment", "remember"]
        #expect(NavigationPreferences.defaultPageChoices == expected)
        var preferences = NavigationPreferences()
        preferences.lastPage = "42"; preferences.configuration.hiddenTags = NavigationDestination.allCases.map(\.rawValue)
        for index in -1...expected.count {
            var edited = preferences
            let valid = edited.selectDefaultPage(at: index)
            if expected.indices.contains(index) {
                #expect(valid && edited.defaultPage == expected[index])
                #expect(edited.selectedDefaultPageIndex == index)
                edited.defaultPage = preferences.defaultPage
                #expect(edited == preferences)
            } else { #expect(!valid && edited == preferences) }
        }
        preferences.defaultPage = "DownloadsFragment"
        #expect(preferences.selectedDefaultPageIndex == nil)
        #expect(preferences.startupTag == "DownloadsFragment")
        preferences.defaultPage = "SubscriptionList"
        #expect(preferences.startupTag == "SubscriptionList" && preferences.startupRoute == .destination(.home))
        preferences.defaultPage = "remember"; preferences.lastPage = "obsolete"
        #expect(preferences.startupTag == "HomeFragment")
    }
}
