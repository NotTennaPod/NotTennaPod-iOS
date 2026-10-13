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
    /// `releases`: in a server library, the discovery ledger's pending releases take the place of NEW episodes
    /// (PROTOCOL §9.9, §9.10: automatic download no longer needs the Inbox); nil in a standalone library.
    public static func candidates(feeds: [LibraryFeed], queue: [LibraryEpisode], preferences: AutomaticDownloadPreferences,
                                  locale: Locale = .current, releases: Set<Int64>? = nil) -> [LibraryEpisode] {
        let owners = Dictionary(uniqueKeysWithValues: feeds.flatMap { feed in feed.episodes.map { ($0.id, feed) } })
        let new = feeds.filter { $0.subscriptionState == .subscribed }.flatMap(\.episodes)
            .filter { episode in
                // A played release is no candidate, as a played episode is never NEW.
                releases.map { $0.contains(episode.id) && episode.userState.playState != .played } ?? (episode.userState.playState == .new)
            }.sorted(by: newestFirst)
        var result: [LibraryEpisode] = [], seen = Set<Int64>()
        var matchers: [Int64: AutomaticDownloadFilter.Matcher] = [:]
        for episode in new {
            guard let feed = owners[episode.id], feed.autoDownload == .enabled || (feed.autoDownload == .global && preferences.global) else { continue }
            let matcher = matchers[feed.id] ?? AutomaticDownloadFilter.Matcher(feed.automaticDownloadFilter, locale: locale)
            matchers[feed.id] = matcher
            guard matcher.includes(episode), seen.insert(episode.id).inserted else { continue }
            result.append(episode)
        }
        if preferences.queue {
            for episode in queue where seen.insert(episode.id).inserted { result.append(episode) }
        }
        return result.filter { episode in
            guard let feed = owners[episode.id] else { return false }
            return episode.userState.autoDownloadEnabled && !episode.userState.isDownloaded
                && episode.details.media != nil && !feed.source.isLocalFeedSource
        }
    }
    /// The releases no automatic download will take (PROTOCOL §9.9): gone, played, without media, downloaded, excluded from
    /// automatic download, or of a local folder. One a podcast's setting or filter, the network, storage or power
    /// leaves out now stays pending, as an Inbox episode does.
    public static func settledReleases(feeds: [LibraryFeed], releases: Set<Int64>) -> Set<Int64> {
        var open = Set<Int64>()
        for feed in feeds where !feed.source.isLocalFeedSource {
            for episode in feed.episodes where releases.contains(episode.id) && episode.details.media != nil
                && !episode.userState.isDownloaded && episode.userState.autoDownloadEnabled && episode.userState.playState != .played {
                open.insert(episode.id)
            }
        }
        return releases.subtracting(open)
    }

    public static func cleanupCandidates(feeds: [LibraryFeed], queuedIDs: Set<Int64>, policy: Int, now: Date) -> [LibraryEpisode] {
        guard policy != -2 else { return [] }
        // Filtering first keeps the order: the sort is total (date, then id).
        let candidates = feeds.filter { $0.subscriptionState == .subscribed }.flatMap(\.episodes).filter { episode in
            guard episode.details.media != nil, episode.userState.isDownloaded, !episode.userState.isFavorite else { return false }
            if policy == -3 { return true }
            guard !queuedIDs.contains(episode.id) else { return false }
            if policy == -1 { return true }
            guard episode.userState.playState == .played, let played = episode.userState.lastPlayedHistoryMilliseconds else { return false }
            return Double(played) / 1000 < now.timeIntervalSince1970 - Double(policy) * 3600
        }.sorted(by: newestFirst)
        // Stable source sort retains the incoming newest-first order for ties.
        return candidates.enumerated().sorted { left, right in
            let a = left.element, b = right.element
            if policy >= 0 || policy < -3 {
                let av = a.userState.lastPlayedHistoryMilliseconds ?? Int64(now.timeIntervalSince1970 * 1000)
                let bv = b.userState.lastPlayedHistoryMilliseconds ?? Int64(now.timeIntervalSince1970 * 1000)
                return av == bv ? left.offset < right.offset : av < bv
            }
            if policy == -3, a.details.publicationDate == nil || b.details.publicationDate == nil { return a.id < b.id }
            let av = a.details.publicationDate ?? now, bv = b.details.publicationDate ?? now
            return av == bv ? left.offset < right.offset : av < bv
        }.map(\.element)
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
    private static func newestFirst(_ a: LibraryEpisode, _ b: LibraryEpisode) -> Bool {
        let av = a.details.publicationDate ?? .distantPast, bv = b.details.publicationDate ?? .distantPast
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
