import Foundation

/// Where one window of the app was: its screen stack and whether the player was expanded, saved through UIKit's
/// scene state restoration so that a window iOS reclaimed, or the app iOS ended, opens where the person left it, as
/// Android's FragmentManager and bottom sheet restore MainActivity. Compact identifiers only (library identity, tags,
/// feed and episode IDs, search text); the app checks them against the library it opens before showing anything.
public struct SceneNavigationState: Equatable, Sendable {
    /// The `NSUserActivity` type of the restoration activity (declared in the app's `NSUserActivityTypes`).
    public static let activityType = "org.nottennapod.app.scene-restoration"
    /// The userInfo format; another version is not restored.
    public static let version = 1
    /// An episode screen keeps at most this many of its pager's pages before and after the one shown.
    public static let pagerReach = 100
    /// A saved stack deeper than this is not restored.
    public static let maximumScreens = 64

    public enum Screen: Equatable, Sendable {
        /// A navigation destination (`NavigationDestination` raw value): a root page, or Statistics pushed.
        case destination(String)
        case archive
        case feed(Int64)
        case feedInformation(Int64)
        case feedSettings(Int64)
        /// The episode shown and its pager's pages around it (`pager[index] == shown`).
        case episode(EpisodePagerItem, pager: [EpisodePagerItem], index: Int)
        /// A settings page by its stable name.
        case settings(String)
        /// The library search: its text, its podcast scope (or the archive) and the scope's title.
        case search(query: String, feedID: Int64?, feedTitle: String, archived: Bool)
        /// The online search: its submitted text and its provider.
        case onlineSearch(query: String, provider: PodcastSearchProvider)
        case discover
        case settingsSearch(query: String)
    }

    /// The identity of the library the screens name (`library_identity`); another library restores nothing.
    public var library: String
    /// The root's navigation tag (a destination, a podcast's ID or Discover's tag) and the root destination behind it.
    public var rootTag: String
    public var rootDestination: String
    /// The stack, root first; never empty.
    public var screens: [Screen]
    public var playerExpanded: Bool

    public init(library: String, rootTag: String, rootDestination: String, screens: [Screen], playerExpanded: Bool) {
        self.library = library; self.rootTag = rootTag; self.rootDestination = rootDestination
        self.screens = screens; self.playerExpanded = playerExpanded
    }

    /// An episode screen's pager as saved: the pages within `pagerReach` of the one shown.
    public static func episode(_ shown: EpisodePagerItem, pager items: [EpisodePagerItem], index: Int) -> Screen {
        guard items.indices.contains(index), items[index] == shown else { return .episode(shown, pager: [shown], index: 0) }
        let lower = max(0, index - pagerReach), upper = min(items.count - 1, index + pagerReach)
        return .episode(shown, pager: Array(items[lower...upper]), index: index - lower)
    }

    // MARK: Property-list form (`NSUserActivity.userInfo`)

    public var userInfo: [String: Any] {
        ["version": Self.version, "library": library, "rootTag": rootTag, "rootDestination": rootDestination,
         "player": playerExpanded, "screens": screens.map(\.propertyList)]
    }

    /// Reads a saved state; nil for anything else (another version, a missing or malformed value, an empty or
    /// overlong stack, an episode pager that does not hold its shown page).
    public init?(userInfo: [AnyHashable: Any]?) {
        guard let userInfo, Self.integer(userInfo["version"]) == Int64(Self.version),
              let library = userInfo["library"] as? String, !library.isEmpty,
              let rootTag = userInfo["rootTag"] as? String, let rootDestination = userInfo["rootDestination"] as? String,
              let player = userInfo["player"] as? Bool,
              let list = userInfo["screens"] as? [Any], !list.isEmpty, list.count <= Self.maximumScreens else { return nil }
        var screens: [Screen] = []
        for item in list {
            guard let values = item as? [String: Any], let screen = Screen(propertyList: values) else { return nil }
            screens.append(screen)
        }
        self.init(library: library, rootTag: rootTag, rootDestination: rootDestination, screens: screens, playerExpanded: player)
    }

    /// A property-list integer (`NSNumber`), never a Boolean or a fraction.
    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integer = number.int64Value
        return NSNumber(value: integer) == number ? integer : nil
    }
}

extension SceneNavigationState.Screen {
    var propertyList: [String: Any] {
        switch self {
        case .destination(let tag): ["kind": "destination", "tag": tag]
        case .archive: ["kind": "archive"]
        case .feed(let id): ["kind": "feed", "feed": id]
        case .feedInformation(let id): ["kind": "feedInformation", "feed": id]
        case .feedSettings(let id): ["kind": "feedSettings", "feed": id]
        case .episode(let shown, let pager, let index):
            ["kind": "episode", "feed": shown.feedID, "episode": shown.episodeID, "index": index,
             "pager": pager.flatMap { [$0.feedID, $0.episodeID] }]
        case .settings(let page): ["kind": "settings", "page": page]
        case .search(let query, nil, let feedTitle, let archived):
            ["kind": "search", "query": query, "title": feedTitle, "archived": archived]
        case .search(let query, let feedID?, let feedTitle, let archived):
            ["kind": "search", "query": query, "title": feedTitle, "archived": archived, "feed": feedID]
        case .onlineSearch(let query, let provider): ["kind": "onlineSearch", "query": query, "provider": provider.restorationName]
        case .discover: ["kind": "discover"]
        case .settingsSearch(let query): ["kind": "settingsSearch", "query": query]
        }
    }

    init?(propertyList values: [String: Any]) {
        let integer = { (key: String) in SceneNavigationState.integer(values[key]) }
        switch values["kind"] as? String {
        case "destination": guard let tag = values["tag"] as? String else { return nil }; self = .destination(tag)
        case "archive": self = .archive
        case "feed": guard let id = integer("feed") else { return nil }; self = .feed(id)
        case "feedInformation": guard let id = integer("feed") else { return nil }; self = .feedInformation(id)
        case "feedSettings": guard let id = integer("feed") else { return nil }; self = .feedSettings(id)
        case "episode":
            guard let feed = integer("feed"), let episode = integer("episode"), let index = integer("index"),
                  let flat = values["pager"] as? [Any], flat.count % 2 == 0,
                  flat.count / 2 <= 2 * SceneNavigationState.pagerReach + 1 else { return nil }
            let ids = flat.compactMap { SceneNavigationState.integer($0) }
            guard ids.count == flat.count else { return nil }
            let pager = stride(from: 0, to: ids.count, by: 2).map { EpisodePagerItem(feedID: ids[$0], episodeID: ids[$0 + 1]) }
            let shown = EpisodePagerItem(feedID: feed, episodeID: episode)
            guard pager.indices.contains(Int(clamping: index)), pager[Int(index)] == shown else { return nil }
            self = .episode(shown, pager: pager, index: Int(index))
        case "settings": guard let page = values["page"] as? String else { return nil }; self = .settings(page)
        case "search":
            guard let query = values["query"] as? String, let title = values["title"] as? String,
                  let archived = values["archived"] as? Bool else { return nil }
            let feedID = integer("feed")
            guard values["feed"] == nil || feedID != nil else { return nil }
            self = .search(query: query, feedID: feedID, feedTitle: title, archived: archived)
        case "onlineSearch":
            guard let query = values["query"] as? String,
                  let provider = (values["provider"] as? String).flatMap(PodcastSearchProvider.init(restorationName:)) else { return nil }
            self = .onlineSearch(query: query, provider: provider)
        case "discover": self = .discover
        case "settingsSearch": guard let query = values["query"] as? String else { return nil }; self = .settingsSearch(query: query)
        default: return nil
        }
    }
}

extension PodcastSearchProvider {
    /// The provider's name in a saved scene (stable, never shown).
    public var restorationName: String {
        switch self { case .combined: "combined"; case .apple: "apple"; case .podcastIndex: "podcastIndex"; case .fyyd: "fyyd" }
    }

    public init?(restorationName: String) {
        switch restorationName {
        case "combined": self = .combined
        case "apple": self = .apple
        case "podcastIndex": self = .podcastIndex
        case "fyyd": self = .fyyd
        default: return nil
        }
    }
}
