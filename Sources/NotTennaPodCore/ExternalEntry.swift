import Foundation

/// Entry points from outside the app.
public enum ExternalEntry {
    /// The podcast-protocol filters of `OnlineFeedViewActivity` (`AndroidManifest.xml:222–233`).
    public static let subscribeSchemes = ["itpc", "pcast", "feed", "antennapod-subscribe"]

    public enum Route: Equatable, Sendable {
        /// `OnlineFeedViewActivity` with a link's data string or the link found in shared text, not yet
        /// prepared.
        case feedPreview(String)
        /// `feedUrl == null`: the no-podcast error (`OnlineFeedViewActivity.java:111–113`).
        case noPodcast
        /// A document opened with the app: RSS/Atom (`ExternalDocument`) or OPML.
        case document(URL)
        /// A Home Screen quick action (launcher shortcut).
        case shortcut(QuickAction)
        /// App Action `OPEN_APP_FEATURE`.
        case openPage(NavigationDestination)
        /// App Action `GET_THING`.
        case search(String)
        /// Widget: the cover/text area opens the player (`MainActivityStarter.withOpenPlayer()`).
        case openPlayer
        /// Widget: the speed button opens the speed dialog (`PlaybackSpeedActivityStarter`).
        case playbackSpeed
    }

    /// What an opened URL asks for; nil for a URL that is not an entry point.
    public static func route(for url: URL) -> Route? {
        if url.isFileURL { return .document(url) }
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if subscribeSchemes.contains(scheme) { return .feedPreview(url.absoluteString) }
        switch PlayerWidgetLink.destination(for: url) {
        case .player: return .openPlayer
        case .playbackSpeed: return .playbackSpeed
        case nil: break
        }
        if scheme == ShareHandoff.scheme {
            return ShareHandoff.text(from: url).flatMap(sharedLink(in:)).map(Route.feedPreview) ?? .noPodcast
        }
        return nil
    }

    /// Where a link starts in shared text: web links, the four podcast protocols and a bare `www.`
    /// address. `pcast:` also counts without `//`, as `UrlChecker.prepareUrl` strips it.
    static let sharedLinkPrefixes = ["https://", "http://", "itpc://", "pcast://", "feed://", "antennapod-subscribe://",
                                     "pcast:", "www."]

    /// Deliberate difference from Android: the address in
    /// shared text is its **first link**, so "Listen to this: https://example.com/feed.xml" and AntennaPod's
    /// own "Share podcast" text (also with a ':' in the title) open that podcast; Android prepares the whole
    /// text instead. A link runs to the next whitespace, without trailing sentence punctuation, quotes or an
    /// unmatched closing bracket, and is then prepared like any other address (`FeedAddress.prepare`, the
    /// `UrlChecker.prepareUrl` port). Text without a link is used whole when it is a single word (a bare
    /// address such as "example.com/feed.xml", as on Android); otherwise nil, the no-podcast error.
    public static func sharedLink(in text: String) -> String? {
        let characters = Array(text)
        for start in characters.indices where start == 0 || !isSchemeCharacter(characters[start - 1]) {
            for prefix in sharedLinkPrefixes where hasPrefix(characters, at: start, prefix) {
                var end = start + prefix.count
                while end < characters.count, !characters[end].isWhitespace { end += 1 }
                let link = trimmingTrailingPunctuation(characters[start..<end])
                if link.count > prefix.count { return String(link) }
            }
        }
        let whole = JavaString.trim(text)
        return whole.isEmpty || whole.contains(where: \.isWhitespace) ? nil : whole
    }

    /// A character that can precede a link's first letter inside a word (URI scheme characters).
    private static func isSchemeCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "+-.".contains(character))
    }

    private static func hasPrefix(_ characters: [Character], at start: Int, _ prefix: String) -> Bool {
        guard start + prefix.count <= characters.count else { return false }
        return zip(characters[start...], prefix).allSatisfy { $0.lowercased() == String($1) }
    }

    private static func trimmingTrailingPunctuation(_ link: ArraySlice<Character>) -> ArraySlice<Character> {
        var link = link
        let brackets: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        while let last = link.last {
            if ".,;:!?'\"’”»›>。，、".contains(last) {
                link.removeLast()
            } else if let open = brackets[last], link.filter({ $0 == last }).count > link.filter({ $0 == open }).count {
                link.removeLast()
            } else { break }
        }
        return link
    }

    /// The four launcher shortcuts in `shortcuts.xml` order.
    public enum QuickAction: String, CaseIterable, Sendable {
        case queue, episodes, subscriptions, refresh

        public static let typePrefix = "org.nottennapod.app.shortcut."
        /// `UIApplicationShortcutItemType`; the suffix is Android's `shortcutId`.
        public var type: String { Self.typePrefix + rawValue }
        public init?(type: String) {
            guard type.hasPrefix(Self.typePrefix) else { return nil }
            self.init(rawValue: String(type.dropFirst(Self.typePrefix.count)))
        }
        /// `shortcutShortLabel`.
        public var titleKey: String {
            switch self {
            case .queue: "queue_label"
            case .episodes: "episodes_label"
            case .subscriptions: "subscriptions_label"
            case .refresh: "refresh_label"
            }
        }
        /// The glyph of `ic_shortcut_*` (drawn by iOS without Android's grey circle).
        public var iconName: String {
            switch self {
            case .queue: "ic_playlist_play"
            case .episodes: "ic_feed"
            case .subscriptions: "ic_subscriptions"
            case .refresh: "ic_refresh"
            }
        }
        /// `fragment_tag`; nil for Refresh (`refresh_on_start`).
        public var destination: NavigationDestination? {
            switch self {
            case .queue: .queue
            case .episodes: .episodes
            case .subscriptions: .subscriptions
            case .refresh: nil
            }
        }
    }

    /// `MainActivity.handleDeeplink` for `/deeplink/main?page=` (`MainActivity.java:813–834`); nil is the
    /// "\"%1$s\" not found" message. The Assistant entity set offers only `AppActionPage`.
    public static func deeplinkPage(_ feature: String) -> NavigationDestination? {
        switch feature {
        case "DOWNLOADS": .downloads
        case "HISTORY": .history
        case "EPISODES": .episodes
        case "QUEUE": .queue
        case "SUBSCRIPTIONS": .subscriptions
        case "STATISTICS": .statistics
        default: nil
        }
    }

    /// `actions.xml` `featureEntitySet`, in its order.
    public enum AppActionPage: String, CaseIterable, Sendable {
        case queue = "QUEUE", episodes = "EPISODES", downloads = "DOWNLOADS", subscriptions = "SUBSCRIPTIONS", history = "HISTORY"
        public var destination: NavigationDestination { ExternalEntry.deeplinkPage(rawValue)! }
        public var titleKey: String {
            switch self {
            case .queue: "queue_label"
            case .episodes: "episodes_label"
            case .downloads: "downloads_label"
            case .subscriptions: "subscriptions_label"
            case .history: "playback_history_label"
            }
        }
    }
}

/// Adaptation: what an opened XML document is. A feed document carries the address it is
/// published at, which is what Android's browser would hand over (`AndroidManifest.xml:207–220`).
public enum ExternalDocument: Equatable, Sendable {
    case feed(address: String?)
    case opml
    case other

    /// Reads at most this many bytes; the root and the channel's own links come first.
    public static let prefixLength = 256 * 1024

    public static func classify(_ data: Data) -> ExternalDocument {
        let reader = Reader()
        let parser = XMLParser(data: data.prefix(prefixLength))
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        parser.parse()
        switch reader.root?.lowercased() {
        case "rss", "feed", "rdf": return .feed(address: reader.selfLink ?? reader.newFeedURL)
        case "opml": return .opml
        default: return .other
        }
    }

    public static func classify(fileAt url: URL) -> ExternalDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .other }
        defer { try? handle.close() }
        return classify((try? handle.read(upToCount: prefixLength)) ?? Data())
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var root: String?
        var selfLink: String?
        var newFeedURL: String?
        private var text: String?

        private static func address(_ value: String?) -> String? {
            guard let value = value.map(JavaString.trim), let scheme = URLComponents(string: value)?.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            return value
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if root == nil { root = name; return }
            let local = name.lowercased()
            // The channel's own links precede its items; stop at the first item or entry.
            if local == "item" || local == "entry" { parser.abortParsing(); return }
            if local == "link", attributes["rel"]?.lowercased() == "self", selfLink == nil {
                selfLink = Self.address(attributes["href"])
            } else if local == "new-feed-url" { text = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text? += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name.lowercased() == "new-feed-url", let value = text {
                if newFeedURL == nil { newFeedURL = Self.address(value) }
                text = nil
            }
        }
    }
}
