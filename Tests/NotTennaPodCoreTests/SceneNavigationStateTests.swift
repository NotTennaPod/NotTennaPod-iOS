import Foundation
import Testing
@testable import NotTennaPodCore

/// A window's saved stack survives the round trip UIKit makes with it (a binary property list inside the scene's
/// restoration activity), and anything that is not exactly a state this version wrote restores nothing.
struct SceneNavigationStateTests {
    private static let every: [SceneNavigationState.Screen] = [
        .destination(NavigationDestination.home.rawValue), .archive, .feed(7), .feedInformation(7), .feedSettings(7),
        .episode(.init(feedID: 7, episodeID: 70), pager: [.init(feedID: 7, episodeID: 71), .init(feedID: 7, episodeID: 70)], index: 1),
        .settings("synchronization"), .search(query: "news ", feedID: 7, feedTitle: "Podcast ⁷", archived: false),
        .search(query: "", feedID: nil, feedTitle: "Archive", archived: true),
        .onlineSearch(query: "ﺍﻟﻌﺮﺑﻴﺔ", provider: .podcastIndex), .discover, .settingsSearch(query: "speed"),
        .destination(NavigationDestination.statistics.rawValue),
    ]

    private static func state(_ screens: [SceneNavigationState.Screen] = every, player: Bool = true) -> SceneNavigationState {
        .init(library: "3f1c6b0e-5d2a-4c1b-9e8f-7a6b5c4d3e2f", rootTag: "7", rootDestination: NavigationDestination.subscriptions.rawValue,
              screens: screens, playerExpanded: player)
    }

    /// As UIKit keeps it: serialized, then read back as Foundation objects.
    private static func roundTrip(_ userInfo: [String: Any]) throws -> [AnyHashable: Any] {
        let data = try PropertyListSerialization.data(fromPropertyList: userInfo, format: .binary, options: 0)
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [AnyHashable: Any])
    }

    @Test(arguments: [false, true])
    func everyScreenSurvivesThePropertyListRoundTrip(player: Bool) throws {
        let state = Self.state(player: player)
        #expect(SceneNavigationState(userInfo: state.userInfo) == state)
        #expect(SceneNavigationState(userInfo: try Self.roundTrip(state.userInfo)) == state)
        // Large identifiers keep every bit.
        let large = Self.state([.feed(.max), .episode(.init(feedID: .max, episodeID: .max - 1),
                                                       pager: [.init(feedID: .max, episodeID: .max - 1)], index: 0)])
        #expect(SceneNavigationState(userInfo: try Self.roundTrip(large.userInfo)) == large)
    }

    @Test func providersHaveStableNames() {
        let all: [PodcastSearchProvider] = [.combined, .apple, .podcastIndex, .fyyd]
        #expect(all.map(\.restorationName) == ["combined", "apple", "podcastIndex", "fyyd"])
        for provider in all { #expect(PodcastSearchProvider(restorationName: provider.restorationName) == provider) }
        #expect(PodcastSearchProvider(restorationName: "Apple") == nil)
    }

    /// A long list keeps the shown page and at most `pagerReach` pages on each side, so the activity stays small.
    @Test func episodePagerKeepsAWindowAroundTheShownPage() {
        let items = (0..<1_000).map { EpisodePagerItem(feedID: 1, episodeID: Int64($0)) }
        guard case .episode(let shown, let pager, let index) = SceneNavigationState.episode(items[500], pager: items, index: 500) else {
            Issue.record("not an episode"); return
        }
        #expect(shown == items[500] && pager[index] == shown)
        #expect(pager.first == items[400] && pager.last == items[600] && pager.count == 201)
        guard case .episode(_, let near, let nearIndex) = SceneNavigationState.episode(items[3], pager: items, index: 3) else { return }
        #expect(near.first == items[0] && near.count == 104 && nearIndex == 3)
        // A pager whose list does not hold the shown page at that index keeps the shown page alone.
        guard case .episode(_, let alone, let aloneIndex) = SceneNavigationState.episode(items[3], pager: items, index: 4) else { return }
        #expect(alone == [items[3]] && aloneIndex == 0)
        let state = Self.state([.destination(NavigationDestination.episodes.rawValue), SceneNavigationState.episode(items[500], pager: items, index: 500)])
        #expect(SceneNavigationState(userInfo: state.userInfo) == state)
    }

    /// Anything else restores nothing: no state, another version, missing or mistyped values, an unknown screen, an
    /// empty or overlong stack, a pager that does not hold its shown page, Booleans or fractions for identifiers.
    @Test func malformedStatesRestoreNothing() throws {
        #expect(SceneNavigationState(userInfo: nil) == nil)
        #expect(SceneNavigationState(userInfo: [:]) == nil)
        let valid = Self.state().userInfo
        func changed(_ key: String, _ value: Any?) -> [AnyHashable: Any] {
            var copy = valid; copy[key] = value; return copy
        }
        for (key, value) in [("version", 2), ("version", "1"), ("library", ""), ("library", 5), ("rootTag", nil),
                             ("rootDestination", nil), ("player", nil), ("player", "yes"), ("screens", []),
                             ("screens", [["kind": "unknown"]]), ("screens", "feed")] as [(String, Any?)] {
            #expect(SceneNavigationState(userInfo: changed(key, value)) == nil, "\(key)")
        }
        #expect(SceneNavigationState(userInfo: changed("screens", Array(repeating: ["kind": "archive"], count: 65))) == nil)
        #expect(SceneNavigationState(userInfo: changed("screens", Array(repeating: ["kind": "archive"], count: 64))) != nil)
        let screens: [[String: Any]] = [
            ["kind": "feed"], ["kind": "feed", "feed": true], ["kind": "feed", "feed": 1.5], ["kind": "feed", "feed": "7"],
            ["kind": "destination"], ["kind": "settings"], ["kind": "settingsSearch"],
            ["kind": "episode", "feed": 7, "episode": 70, "index": 0, "pager": [7, 71]],
            ["kind": "episode", "feed": 7, "episode": 70, "index": 2, "pager": [7, 70]],
            ["kind": "episode", "feed": 7, "episode": 70, "index": -1, "pager": [7, 70]],
            ["kind": "episode", "feed": 7, "episode": 70, "index": 0, "pager": [7, 70, 7]],
            ["kind": "episode", "feed": 7, "episode": 70, "index": 0, "pager": [7, "70"]],
            ["kind": "episode", "feed": 7, "episode": 70, "index": 0, "pager": Array(repeating: 7, count: 2 * 202)],
            ["kind": "search", "query": "a", "title": "b"], ["kind": "search", "query": "a", "title": "b", "archived": false, "feed": "7"],
            ["kind": "onlineSearch", "query": "a", "provider": "bing"],
        ]
        for screen in screens {
            #expect(SceneNavigationState(userInfo: changed("screens", [["kind": "destination", "tag": "HomeFragment"], screen])) == nil,
                    "\(screen)")
        }
    }
}
