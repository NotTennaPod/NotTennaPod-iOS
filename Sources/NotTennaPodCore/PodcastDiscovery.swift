import Foundation

// Add-podcast suggestions, the Discover top list and its preferences, and the Java
// ordering rules that decide what a person sees in which order.

// MARK: - Top list (ItunesTopListLoader)

public enum TopListError: Error, Equatable, Sendable {
    /// HTTP 400: "iTunes does not have data for the selected country." (a literal, not a resource).
    case noDataForCountry
    /// Other non-2xx: shown after the "An error occurred:" prefix.
    case http(Int)
    case invalidResponse
}

/// What `removeSubscribed` reads from a stored feed: `Feed.getTitle()` (the custom title when
/// set), the author and the state.
public struct DiscoverySubscription: Sendable {
    public var title: String?, author: String?, state: FeedSubscriptionState
    public init(title: String?, author: String?, state: FeedSubscriptionState) {
        self.title = title; self.author = author; self.state = state
    }
}

public enum ItunesTopList {
    /// QuickFeedDiscoveryFragment.NUM_SUGGESTIONS and DiscoveryFragment.NUM_OF_TOP_PODCASTS.
    public static let addScreenLimit = 12
    public static let discoverLimit = 25
    public static let noDataMessage = "iTunes does not have data for the selected country."

    public static func url(country: String) -> URL? {
        URL(string: "https://itunes.apple.com/\(country)/rss/toppodcasts/limit=25/explicit=true/json")
    }

    /// `parseFeed` + `toSearchResult`: entries in feed order; a missing `feed`/`entry` or an
    /// `entry` object instead of an array is an empty list; a malformed entry is an error.
    public static func parse(_ data: Data) throws -> [PodcastSearchResult] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TopListError.invalidResponse
        }
        guard let feed = object["feed"] as? [String: Any], let entries = feed["entry"] as? [Any] else { return [] }
        return try entries.map { value in
            guard let entry = value as? [String: Any],
                  let name = entry["im:name"] as? [String: Any], let title = name["label"] as? String,
                  let images = entry["im:image"] as? [Any],
                  let id = (entry["id"] as? [String: Any])?["attributes"] as? [String: Any],
                  let identifier = id["im:id"].flatMap(Self.jsonString) else { throw TopListError.invalidResponse }
            var image: String?
            for case let item as [String: Any] in images where image == nil {
                guard let height = (item["attributes"] as? [String: Any])?["height"].flatMap(Self.jsonString),
                      let value = Int(height) else { throw TopListError.invalidResponse }
                if value >= 100 { image = item["label"].flatMap(Self.jsonString) }
            }
            let author = (entry["im:artist"] as? [String: Any])?["label"].flatMap(Self.jsonString)
            return PodcastSearchResult(title: title, imageURL: image,
                                       feedURL: "https://itunes.apple.com/lookup?id=" + identifier, author: author)
        }
    }
    private static func jsonString(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// `removeSubscribed`: exclusion by trimmed display title (custom title when set), for every
    /// stored feed with a title and an author that is not a preview; case-sensitive; the limit
    /// counts kept entries only.
    public static func removeSubscribed(_ suggested: [PodcastSearchResult], feeds: [LibraryFeed],
                                        limit: Int) -> [PodcastSearchResult] {
        removeSubscribed(suggested, subscriptions: feeds.map {
            DiscoverySubscription(title: $0.title, author: $0.metadata.author, state: $0.subscriptionState)
        }, limit: limit)
    }
    public static func removeSubscribed(_ suggested: [PodcastSearchResult], subscriptions: [DiscoverySubscription],
                                        limit: Int) -> [PodcastSearchResult] {
        var titles = Set<String>()
        for feed in subscriptions where feed.state != .notSubscribed && feed.author != nil {
            if let title = feed.title { titles.insert(JavaString.trim(title)) }
        }
        var kept: [PodcastSearchResult] = []
        for item in suggested {
            if !titles.contains(JavaString.trim(item.title)) { kept.append(item) }
            if kept.count == limit { break }
        }
        return kept
    }
}

extension PodcastSearchClient {
    /// ItunesTopListLoader.loadToplist for one country, then `removeSubscribed`.
    public func topList(country: String, limit: Int, feeds: [LibraryFeed]) async throws -> [PodcastSearchResult] {
        guard let url = ItunesTopList.url(country: country) else { throw TopListError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(HTTPUserAgent.search, forHTTPHeaderField: "User-Agent")
        let (data, status) = try await sendRequest(request)
        try Task.checkCancellation()
        guard (200..<300).contains(status) else {
            throw status == 400 ? TopListError.noDataForCountry : TopListError.http(status)
        }
        return ItunesTopList.removeSubscribed(try ItunesTopList.parse(data), feeds: feeds, limit: limit)
    }
}

// MARK: - Preferences (SharedPreferences "CountryRegionPrefs")

public struct DiscoveryPreferences: Codable, Equatable, Sendable {
    /// `country_code`; absent means the device country, read at each load.
    public var countryCode: String?
    /// `hidden_discovery_country`.
    public var hidden: Bool
    public init(countryCode: String? = nil, hidden: Bool = false) {
        self.countryCode = countryCode; self.hidden = hidden
    }
    public func country(device: String) -> String { countryCode ?? device }
}

/// One JSON file beside the library, like the other preference stores. It is not part of the
/// Android database backup, as in the source.
@MainActor public final class DiscoveryPreferenceStore {
    public private(set) var value: DiscoveryPreferences
    private let file: URL
    private var observers: [UUID: AsyncStream<DiscoveryPreferences>.Continuation] = [:]

    public init(file: URL) throws {
        self.file = file
        value = try SavedState.contents(of: file).map { try JSONDecoder().decode(DiscoveryPreferences.self, from: $0) } ?? .init()
    }
    public func update(_ value: DiscoveryPreferences) throws {
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        self.value = value
        for observer in observers.values { observer.yield(value) }
    }
    /// The source's DiscoveryDefaultUpdateEvent: every change reloads the suggestions.
    public func events() -> AsyncStream<DiscoveryPreferences> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.observers.removeValue(forKey: id) }
            }
        }
    }
    deinit { for observer in observers.values { observer.finish() } }
}

// MARK: - Suggestions and Discover state (QuickFeedDiscoveryFragment.loadToplist, DiscoveryFragment.loadToplist)

@MainActor public final class TopListSession {
    public enum State: Equatable, Sendable {
        case loading
        case loaded([PodcastSearchResult])
        /// Every entry excluded, or no entries: "No results were found".
        case empty
        /// The error text, with Retry.
        case failed(String)
        /// `hidden_discovery_country`: "You selected to hide suggestions.", no request.
        case hidden
    }
    public private(set) var state: State = .loading
    public var onChange: (() -> Void)?
    private let read: @Sendable (String) async throws -> [PodcastSearchResult]
    private let describe: @Sendable (any Error) -> String
    private var task: Task<Void, Never>?
    private var generation = UUID()

    /// `read` loads the kept entries for a country; `describe` gives an error's shown text.
    public init(read: @escaping @Sendable (String) async throws -> [PodcastSearchResult],
                describe: @escaping @Sendable (any Error) -> String) {
        self.read = read; self.describe = describe
    }
    isolated deinit { task?.cancel() }

    public func load(_ preferences: DiscoveryPreferences, device: String) {
        cancel()
        guard !preferences.hidden else { state = .hidden; onChange?(); return }
        let country = preferences.country(device: device)
        state = .loading; onChange?()
        let generation = generation, read = read, describe = describe
        task = Task { [weak self] in
            let result: State
            do {
                let items = try await read(country)
                result = items.isEmpty ? .empty : .loaded(items)
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                result = .failed(describe(error))
            }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            state = result; task = nil; onChange?()
        }
    }
    public func cancel() { generation = UUID(); task?.cancel(); task = nil }
}

// MARK: - Select country (DiscoveryFragment.onMenuItemClick)

public struct DiscoveryCountries: Sendable {
    /// Display name for every ISO code; equal names collapse into one entry (a HashMap).
    public let names: [String]
    private let codes: [String: String]
    private let displayNames: [String: String]

    /// `codeToName` in `Locale.getISOCountries()` order: for a shared name the later code wins.
    public init(_ codeToName: [(code: String, name: String)]) {
        var codes: [String: String] = [:], displayNames: [String: String] = [:]
        for entry in codeToName { codes[entry.name] = entry.code; displayNames[entry.code] = entry.name }
        self.codes = codes; self.displayNames = displayNames
        names = codes.keys.sorted(by: JavaString.precedes)
    }
    public func name(for code: String) -> String? { displayNames[code] }
    public func code(for name: String) -> String? { codes[name] }

    /// ArrayAdapter's filter: case-insensitive prefix of the name or of one of its words.
    public func matches(_ typed: String) -> [String] {
        let prefix = typed.lowercased()
        guard !prefix.isEmpty else { return names }
        return names.filter { name in
            let value = name.lowercased()
            return value.hasPrefix(prefix) || value.split(separator: " ", omittingEmptySubsequences: false).contains { $0.hasPrefix(prefix) }
        }
    }
    /// OK: text exactly equal to a listed name selects it and un-hides; any other text keeps
    /// both values. Both values are saved either way (the current country becomes explicit).
    public func confirm(_ typed: String, current: DiscoveryPreferences, device: String) -> DiscoveryPreferences {
        var result = DiscoveryPreferences(countryCode: current.country(device: device), hidden: current.hidden)
        if let code = codes[typed] { result.countryCode = code; result.hidden = false }
        return result
    }
}
