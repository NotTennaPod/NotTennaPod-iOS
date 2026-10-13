import Foundation
import Testing
@testable import NotTennaPodCore

struct NavigationCustomizationTests {
    @Test func startupUsesNamedDefaultOrRememberedRootAndSourceFallbacks() {
        var preferences = NavigationPreferences()
        for destination in NavigationDestination.allCases {
            preferences.defaultPage = destination.rawValue
            #expect(preferences.startupRoute == .destination(destination == .subscriptionList ? .home : destination))
            preferences.lastPage = destination.rawValue; preferences.defaultPage = "remember"
            #expect(preferences.startupRoute == .destination(destination == .subscriptionList ? .home : destination))
        }
        for id in [Int32.min, 0, 42, Int32.max] {
            preferences.lastPage = String(id)
            #expect(preferences.startupRoute == .feed(Int64(id)))
        }
        for value in ["removed-tag", "2147483648", "-2147483649", ""] {
            preferences.lastPage = value
            #expect(preferences.startupRoute == .destination(.home))
        }
        preferences.defaultPage = "42"
        #expect(preferences.startupRoute == .destination(.home))
    }

    @Test func initialGroupsPreserveHiddenOrderAndBottomModeOmitsSubscriptionList() {
        var preferences = NavigationPreferences()
        preferences.configuration = .init(hiddenTags: ["QueueFragment", "HomeFragment", "SubscriptionList"], orderedTags: ["DownloadsFragment"])
        for bottom in [true, false] {
            preferences.bottomNavigation = bottom
            let model = NavigationCustomization(preferences: preferences)
            #expect(model.items.prefix(2) == [.shown, .destination(.downloads)])
            #expect(model.items.suffix(bottom ? 3 : 4) == (bottom
                ? [.hidden, .destination(.queue), .destination(.home)]
                : [.hidden, .destination(.queue), .destination(.home), .destination(.subscriptionList)]))
        }
    }

    @Test func everyMovePreservesItemsAndProtectsOnlyTheFirstHeader() {
        for bottom in [false, true] {
            var preferences = NavigationPreferences(); preferences.bottomNavigation = bottom
            let initial = NavigationCustomization(preferences: preferences)
            for from in -1...initial.items.count {
                for to in -1...initial.items.count {
                    var edited = initial
                    let valid = from > 0 && to > 0 && from < initial.items.count && to < initial.items.count
                    #expect(edited.move(from: from, to: to) == valid)
                    if valid {
                        #expect(edited.items[to] == initial.items[from])
                        #expect(edited.items.enumerated().filter { $0.offset != to }.map(\.element)
                            == initial.items.enumerated().filter { $0.offset != from }.map(\.element))
                    } else { #expect(edited == initial) }
                    #expect(edited.items.first == .shown)
                }
            }
        }
    }

    @Test func confirmationRepairsDefaultUsingOriginalOrderAndResetDoesNotResetDefault() {
        var preferences = NavigationPreferences()
        preferences.defaultPage = "HomeFragment"
        preferences.configuration.orderedTags = ["DownloadsFragment", "HomeFragment", "QueueFragment"]
        var editor = NavigationCustomization(preferences: preferences)
        let home = editor.items.firstIndex(of: .destination(.home))!
        editor.move(from: home, to: editor.items.count - 1)
        #expect(preferences.configuration.hiddenTags.isEmpty) // Dragging/cancellation has no saved effect.
        let saved = editor.confirmed(updating: preferences)
        #expect(saved.configuration.hiddenTags == ["HomeFragment"])
        #expect(saved.configuration.orderedTags.first == "DownloadsFragment")
        #expect(saved.defaultPage == "QueueFragment") // Resource order, not user's reordered Downloads.
        let reset = NavigationCustomization.reset(updating: saved)
        #expect(reset.configuration == NavigationConfiguration())
        #expect(reset.defaultPage == "QueueFragment")
    }

    @Test func allHiddenSubsetsAndDefaultsKeepReleaseFallbackIncludingRemember() {
        let tags = NavigationDestination.allCases.map(\.rawValue)
        for mask in 0..<(1 << tags.count) {
            for bottom in [false, true] {
                var preferences = NavigationPreferences(); preferences.bottomNavigation = bottom
                preferences.configuration.hiddenTags = tags.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
                let editor = NavigationCustomization(preferences: preferences)
                let expectedHidden = preferences.configuration.hiddenTags.filter { !bottom || $0 != "SubscriptionList" }
                for current in tags + ["remember"] {
                    preferences.defaultPage = current
                    let result = editor.confirmed(updating: preferences)
                    #expect(result.configuration.hiddenTags == expectedHidden)
                    let replacement = tags.first { !expectedHidden.contains($0) }
                    #expect(result.defaultPage == (expectedHidden.contains(current) ? replacement ?? current : current))
                }
            }
        }
    }

    @Test func addingDefaultPageFieldsReadsExistingNavigationFilesAndRetainsUnrelatedEdits() throws {
        let old = Data(#"{"bottomNavigation":false,"backButtonOpensDrawer":true,"configuration":{"hiddenTags":[],"orderedTags":[]}}"#.utf8)
        var preferences = try JSONDecoder().decode(NavigationPreferences.self, from: old)
        #expect(!preferences.bottomNavigation && preferences.backButtonOpensDrawer)
        #expect(preferences.defaultPage == "HomeFragment" && preferences.startupPage == "HomeFragment")
        let editor = NavigationCustomization(preferences: preferences)
        preferences.defaultPage = "remember"; preferences.lastPage = "42"; preferences.bottomNavigation = true
        let confirmed = editor.confirmed(updating: preferences)
        #expect(confirmed.startupPage == "42" && confirmed.bottomNavigation)
        #expect(try JSONDecoder().decode(NavigationPreferences.self, from: JSONEncoder().encode(confirmed)) == confirmed)
    }
}
