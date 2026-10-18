import Foundation

public struct AutomaticDownloadFilter: Codable, Equatable, Sendable {
    public var include: String
    public var exclude: String
    public var minimumDurationSeconds: Int
    public init(include: String = "", exclude: String = "", minimumDurationSeconds: Int = -1) {
        self.include = include; self.exclude = exclude; self.minimumDurationSeconds = minimumDurationSeconds
    }
    public func includes(_ episode: LibraryEpisode, locale: Locale = .current) -> Bool {
        Matcher(self, locale: locale).includes(episode)
    }

    /// The filter's terms parsed and normalized once, for checking many episodes of one feed.
    struct Matcher: Sendable {
        private let filter: AutomaticDownloadFilter
        private let locale: Locale
        private let included: [String], excluded: [String]
        init(_ filter: AutomaticDownloadFilter, locale: Locale) {
            self.filter = filter; self.locale = locale
            // Java trim removes only UTF-16 units <= U+0020.
            func normalized(_ raw: String) -> String {
                JavaString.trim(raw).lowercased(with: locale)
            }
            included = AutomaticDownloadFilter.terms(filter.include).map(normalized)
            excluded = AutomaticDownloadFilter.terms(filter.exclude).map(normalized)
        }
        func includes(_ episode: LibraryEpisode) -> Bool {
            let minimumDurationSeconds = filter.minimumDurationSeconds
            if included.isEmpty && excluded.isEmpty && minimumDurationSeconds < 0 { return true }
            if minimumDurationSeconds >= 0, let media = episode.details.media,
               media.durationMilliseconds > 0, Int(media.durationMilliseconds / 1000) < minimumDurationSeconds { return false }
            let title = (episode.details.title ?? "").lowercased(with: locale)
            // Literal matching avoids treating canonically equivalent spellings as the same text.
            func matches(_ term: String) -> Bool {
                term.isEmpty || (title as NSString).range(of: term, options: .literal).location != NSNotFound
            }
            if excluded.contains(where: matches) { return false }
            if included.contains(where: matches) { return true }
            if filter.include.isEmpty && !filter.exclude.isEmpty { return true }
            // Source permits a duration-qualified item even without an include match.
            return minimumDurationSeconds >= 0
        }

        /// `includes(_:)` over what it reads of an episode: its title, and its media's duration (nil without media).
        func includes(title: String?, durationMilliseconds: Int32?) -> Bool {
            let minimumDurationSeconds = filter.minimumDurationSeconds
            if included.isEmpty && excluded.isEmpty && minimumDurationSeconds < 0 { return true }
            if minimumDurationSeconds >= 0, let duration = durationMilliseconds,
               duration > 0, Int(duration / 1000) < minimumDurationSeconds { return false }
            let title = (title ?? "").lowercased(with: locale)
            func matches(_ term: String) -> Bool {
                term.isEmpty || (title as NSString).range(of: term, options: .literal).location != NSNotFound
            }
            if excluded.contains(where: matches) { return false }
            if included.contains(where: matches) { return true }
            if filter.include.isEmpty && !filter.exclude.isEmpty { return true }
            return minimumDurationSeconds >= 0
        }
    }

    // Java Pattern's default \s is ASCII; ICU's default is Unicode. Immutable, safe to share.
    private static let termPattern = try! NSRegularExpression(
        pattern: #"([^\"][^\x09-\x0D ]*|\"[^\n\r\u0085\u2028\u2029]+?\")[\x09-\x0D ]*"#)
    static func terms(_ value: String) -> [String] {
        let regex = termPattern
        let string = value as NSString
        return regex.matches(in: value, range: NSRange(location: 0, length: string.length)).map {
            string.substring(with: $0.range(at: 1)).replacingOccurrences(of: "\"", with: "")
        }
    }
}

public struct AutomaticDownloadPreferences: Codable, Equatable, Sendable {
    public var global = false
    public var queue = false
    public var onBattery = true
    private var storedCacheSize: Int?
    public var cacheSize: Int { // Reader default differs from the settings XML's first-visit default.
        get { storedCacheSize ?? 20 }
        set { storedCacheSize = newValue }
    }
    public mutating func initializeSettingsDefaults() { if storedCacheSize == nil { storedCacheSize = 25 } }
    public var cleanup = -2 // -3 except favorites, -2 never, -1 outside queue, >=0 played hours.
    public init() {}
    private enum CodingKeys: String, CodingKey { case global, queue, onBattery, storedCacheSize = "cacheSize", cleanup }
}

public enum AutomaticDownloadPolicy {
    public enum Connection: Equatable, Sendable { case unavailable, wifi(metered: Bool), ethernet, other(restricted: Bool) }
    public static func permitted(connection: Connection, allowMobile: Bool, charging: Bool,
                                 preferences: AutomaticDownloadPreferences) -> Bool {
        let network: Bool = switch connection {
        case .unavailable: false
        case .wifi(let metered): !metered
        case .ethernet: true
        case .other(let restricted): allowMobile || !restricted
        }
        return network && (charging || preferences.onBattery)
    }
    /// What the selection reads of an episode: from a stored episode, or from its derived keys
    /// (`EpisodeListKeys`), so a pass reads no episode record.
    public struct Item: Equatable, Sendable {
        public var id: Int64
        public var feedID: Int64
        public var publicationDate: Date?
        /// Nil without media.
        public var durationMilliseconds: Int32?
        public var title: String?
        public var playState: EpisodePlayState
        public var isDownloaded: Bool
        public var isFavorite: Bool
        public var autoDownloadEnabled: Bool
        public var lastPlayedHistoryMilliseconds: Int64?
        public var hasMedia: Bool { durationMilliseconds != nil }

        public init(_ episode: LibraryEpisode, feedID: Int64) {
            id = episode.id; self.feedID = feedID
            publicationDate = episode.details.publicationDate
            durationMilliseconds = episode.details.media?.durationMilliseconds
            title = episode.details.title
            playState = episode.userState.playState
            isDownloaded = episode.userState.isDownloaded
            isFavorite = episode.userState.isFavorite
            autoDownloadEnabled = episode.userState.autoDownloadEnabled
            lastPlayedHistoryMilliseconds = episode.userState.lastPlayedHistoryMilliseconds
        }

        init(_ keys: EpisodeListKeys) {
            id = keys.id; feedID = keys.feedID
            publicationDate = keys.publicationReference.map(Date.init(timeIntervalSinceReferenceDate:))
            durationMilliseconds = keys.hasMedia ? Int32(clamping: keys.durationMilliseconds ?? 0) : nil
            title = keys.title
            playState = EpisodePlayState(rawValue: Int(keys.state)) ?? .unplayed
            isDownloaded = keys.isDownloaded
            isFavorite = keys.isFavorite
            autoDownloadEnabled = keys.autoDownloadEnabled
            lastPlayedHistoryMilliseconds = keys.lastPlayedHistoryMilliseconds
        }
    }

    /// What one pass selects from: the feeds library-wide reads show (headers), and those of their visible episodes that
    /// can matter (NEW, pending releases, queued, downloaded), with the visible queue in order.
    public struct Library: Sendable {
        public var feeds: [LibraryFeed]
        public var episodes: [Item]
        public var queue: [Int64]
        public init(feeds: [LibraryFeed], episodes: [Item], queue: [Int64]) { self.feeds = feeds; self.episodes = episodes; self.queue = queue }

        /// A whole library's (every visible episode, decoded): the reference and the fallback before the derived keys
        /// are complete.
        public init(_ snapshot: FeedLibrarySnapshot) {
            feeds = snapshot.feeds.map { var header = $0; header.episodes = []; return header }
            episodes = snapshot.feeds.flatMap { feed in feed.episodes.map { Item($0, feedID: feed.id) } }
            queue = snapshot.queue.map(\.id)
        }
    }

    /// `releases`: in a server library, the discovery ledger's pending releases take the place of NEW episodes
    /// (PROTOCOL §9.9, §9.10: automatic download no longer needs the Inbox); nil in a standalone library.
    public static func candidates(feeds: [LibraryFeed], queue: [LibraryEpisode], preferences: AutomaticDownloadPreferences,
                                  locale: Locale = .current, releases: Set<Int64>? = nil) -> [LibraryEpisode] {
        let library = Library(FeedLibrarySnapshot(feeds: feeds, queue: queue))
        var episodes: [Int64: LibraryEpisode] = [:]
        for episode in feeds.flatMap(\.episodes) + queue { episodes[episode.id] = episode }
        return candidates(library, preferences: preferences, locale: locale, releases: releases).compactMap { episodes[$0.id] }
    }

    public static func candidates(_ library: Library, preferences: AutomaticDownloadPreferences,
                                  locale: Locale = .current, releases: Set<Int64>? = nil) -> [Item] {
        var feedsByID: [Int64: LibraryFeed] = [:]
        for feed in library.feeds where feedsByID[feed.id] == nil { feedsByID[feed.id] = feed }
        var items: [Int64: Item] = [:]
        for item in library.episodes where feedsByID[item.feedID] != nil && items[item.id] == nil { items[item.id] = item }
        let new = library.episodes.filter { item in
            guard feedsByID[item.feedID]?.subscriptionState == .subscribed, items[item.id] == item else { return false }
            // A played release is no candidate, as a played episode is never NEW.
            return releases.map { $0.contains(item.id) && item.playState != .played } ?? (item.playState == .new)
        }.sorted(by: newestFirst)
        var result: [Item] = [], seen = Set<Int64>()
        var matchers: [Int64: AutomaticDownloadFilter.Matcher] = [:]
        for item in new {
            guard let feed = feedsByID[item.feedID], feed.autoDownload == .enabled || (feed.autoDownload == .global && preferences.global) else { continue }
            let matcher = matchers[feed.id] ?? AutomaticDownloadFilter.Matcher(feed.automaticDownloadFilter, locale: locale)
            matchers[feed.id] = matcher
            guard matcher.includes(title: item.title, durationMilliseconds: item.durationMilliseconds), seen.insert(item.id).inserted else { continue }
            result.append(item)
        }
        if preferences.queue {
            for id in library.queue where seen.insert(id).inserted { if let item = items[id] { result.append(item) } }
        }
        return result.filter { item in
            guard let feed = feedsByID[item.feedID] else { return false }
            return item.autoDownloadEnabled && !item.isDownloaded && item.hasMedia && !feed.source.isLocalFeedSource
        }
    }

    /// The releases no automatic download will take (PROTOCOL §9.9): gone, played, without media, downloaded, excluded from
    /// automatic download, or of a local folder. One a podcast's setting or filter, the network, storage or power
    /// leaves out now stays pending, as an Inbox episode does.
    public static func settledReleases(feeds: [LibraryFeed], releases: Set<Int64>) -> Set<Int64> {
        settledReleases(Library(FeedLibrarySnapshot(feeds: feeds, queue: [])), releases: releases)
    }

    public static func settledReleases(_ library: Library, releases: Set<Int64>) -> Set<Int64> {
        let remote = Set(library.feeds.filter { !$0.source.isLocalFeedSource }.map(\.id))
        var open = Set<Int64>()
        for item in library.episodes where remote.contains(item.feedID) && releases.contains(item.id) && item.hasMedia
            && !item.isDownloaded && item.autoDownloadEnabled && item.playState != .played {
            open.insert(item.id)
        }
        return releases.subtracting(open)
    }

    public static func cleanupCandidates(feeds: [LibraryFeed], queuedIDs: Set<Int64>, policy: Int, now: Date) -> [LibraryEpisode] {
        var episodes: [Int64: LibraryEpisode] = [:]
        for episode in feeds.flatMap(\.episodes) { episodes[episode.id] = episode }
        return cleanupCandidates(Library(FeedLibrarySnapshot(feeds: feeds, queue: [])), queuedIDs: queuedIDs, policy: policy, now: now)
            .compactMap { episodes[$0.id] }
    }

    public static func cleanupCandidates(_ library: Library, queuedIDs: Set<Int64>, policy: Int, now: Date) -> [Item] {
        guard policy != -2 else { return [] }
        let subscribed = Set(library.feeds.filter { $0.subscriptionState == .subscribed }.map(\.id))
        // Filtering first keeps the order: the sort is total (date, then id).
        let candidates = library.episodes.filter { item in
            guard subscribed.contains(item.feedID), item.hasMedia, item.isDownloaded, !item.isFavorite else { return false }
            if policy == -3 { return true }
            guard !queuedIDs.contains(item.id) else { return false }
            if policy == -1 { return true }
            guard item.playState == .played, let played = item.lastPlayedHistoryMilliseconds else { return false }
            return Double(played) / 1000 < now.timeIntervalSince1970 - Double(policy) * 3600
        }.sorted(by: newestFirst)
        // Stable source sort retains the incoming newest-first order for ties.
        return candidates.enumerated().sorted { left, right in
            let a = left.element, b = right.element
            if policy >= 0 || policy < -3 {
                let av = a.lastPlayedHistoryMilliseconds ?? Int64(now.timeIntervalSince1970 * 1000)
                let bv = b.lastPlayedHistoryMilliseconds ?? Int64(now.timeIntervalSince1970 * 1000)
                return av == bv ? left.offset < right.offset : av < bv
            }
            if policy == -3, a.publicationDate == nil || b.publicationDate == nil { return a.id < b.id }
            let av = a.publicationDate ?? now, bv = b.publicationDate ?? now
            return av == bv ? left.offset < right.offset : av < bv
        }.map(\.element)
    }

    /// Downloaded episodes with media of subscribed podcasts: what the cache size counts.
    public static func downloadedCount(_ library: Library) -> Int {
        let subscribed = Set(library.feeds.filter { $0.subscriptionState == .subscribed }.map(\.id))
        return library.episodes.count { subscribed.contains($0.feedID) && $0.hasMedia && $0.isDownloaded }
    }
    public static func cleanupCount(downloaded: Int, candidates: Int, cacheSize: Int) -> Int {
        guard cacheSize != -1 else { return 0 }
        return max(0, downloaded + candidates - cacheSize)
    }
    public static func downloadCount(candidates: Int, downloaded: Int, active: Int, deleted: Int, cacheSize: Int) -> Int {
        guard cacheSize != -1 else { return candidates }
        // Source can pass a negative end index to subList when already over
        // capacity. Clamp to the actual candidate range instead of crashing.
        return min(candidates, max(0, cacheSize - (downloaded + active - deleted)))
    }
    private static func newestFirst(_ a: Item, _ b: Item) -> Bool {
        let av = a.publicationDate ?? .distantPast, bv = b.publicationDate ?? .distantPast
        return av == bv ? a.id < b.id : av > bv
    }
}

@MainActor public final class AutomaticDownloadPreferenceStore: JSONPreferenceStore<AutomaticDownloadPreferences> {
    public init(file: URL) throws { try super.init(file: file, defaultValue: .init()) }
    override public func update(_ value: AutomaticDownloadPreferences) throws {
        guard value.cacheSize == -1 || value.cacheSize >= 0 else { throw FeedLibraryError.invalidMutation }
        try super.update(value)
    }
}
