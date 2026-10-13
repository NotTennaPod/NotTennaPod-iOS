import Foundation

public struct LibrarySearchResult: Equatable, Sendable {
    public struct Episode: Equatable, Sendable {
        public let feedID: Int64
        public let episode: LibraryEpisode
        public let deletionTarget: EpisodeMediaDeletionTarget?
        public init(feedID: Int64, episode: LibraryEpisode, deletionTarget: EpisodeMediaDeletionTarget? = nil) {
            self.feedID = feedID; self.episode = episode; self.deletionTarget = deletionTarget
        }
    }
    public var feeds: [LibraryFeed] = []
    public var episodes: [Episode] = []
    public init() {}
}

extension FeedLibraryStore {
    /// PodDBAdapter searchItems/searchFeeds: AND across words, OR across fields,
    /// SQLite LIKE wildcard/ASCII-case behavior, source ordering and300-result caps.
    /// `archived` is SearchFragment's `INCLUDE_ARCHIVED`-only filter (archived feeds instead of subscribed).
    public func search(query: String, feedID: Int64? = nil, archived: Bool = false) throws -> LibrarySearchResult {
        try Task.checkCancellation()
        // Java's default \\s is ASCII, not the Unicode whitespace character set.
        let words = query.components(separatedBy: CharacterSet(charactersIn: " \t\n\u{b}\u{c}\r")).filter { !$0.isEmpty }
        guard !words.isEmpty else { return .init() }
        return try database.transaction(write: false) {
            var result = LibrarySearchResult()
            let episodeRecord = "CAST(e.record AS TEXT)", feedRecord = "CAST(f.record AS TEXT)"
            var bindings: [LibrarySQLValue] = []
            var conditions: [String] = []
            if let feedID {
                conditions.append("e.feed_id = ?"); bindings.append(.integer(feedID))
            } else {
                conditions.append("json_extract(\(feedRecord), '$.subscriptionState') = \(archived ? 2 : 0)")
            }
            // Podcasts no list shows: a pinned removal (PROTOCOL §15.4), and in a server library a hidden podcast or
            // staged episode.
            let hidden = hiddenFeedsCondition("f.id")
            if let hidden {
                conditions.append(serverContext == nil ? hidden : hidden + " AND e.id NOT IN (SELECT episode_id FROM ntp_hidden_episodes)")
            }
            for word in words {
                conditions.append("(json_extract(\(episodeRecord), '$.details.title') LIKE ? OR json_extract(\(episodeRecord), '$.details.description') LIKE ?)")
                bindings += [.text("%\(word)%"), .text("%\(word)%")]
            }
            let sql = "SELECT e.feed_id, e.record FROM episodes e JOIN feeds f ON f.id = e.feed_id WHERE "
                + conditions.joined(separator: " AND ") + " ORDER BY e.pubdate DESC, e.id LIMIT 300"
            result.episodes = try database.rows(sql, bindings).map { row in
                try Task.checkCancellation()
                guard let id = row[0].integer, let data = row[1].data else { throw FeedLibraryError.corruptRecord }
                let episode = try JSONDecoder().decode(LibraryEpisode.self, from: data)
                return .init(feedID: id, episode: episode, deletionTarget: try loadMediaDeletionTarget(episodeID: episode.id))
            }
            if feedID == nil {
                let fields = ["$.metadata.title", "$.customTitle", "$.metadata.author", "$.metadata.description"]
                let predicate = "(" + fields.map { "json_extract(\(feedRecord), '\($0)') LIKE ?" }.joined(separator: " OR ") + ")"
                let sql = "SELECT f.record FROM feeds f WHERE json_extract(\(feedRecord), '$.subscriptionState') = \(archived ? 2 : 0) AND "
                    + (hidden.map { $0 + " AND " } ?? "")
                    + Array(repeating: predicate, count: words.count).joined(separator: " AND ") + " ORDER BY f.title ASC, f.id LIMIT 300"
                let values = words.flatMap { Array(repeating: LibrarySQLValue.text("%\($0)%"), count: fields.count) }
                result.feeds = try database.rows(sql, values).map { row in
                    try Task.checkCancellation()
                    guard let data = row[0].data else { throw FeedLibraryError.corruptRecord }
                    return try JSONDecoder().decode(LibraryFeed.self, from: data)
                }
            }
            return result
        }
    }
}

extension LibrarySearchResult {
    /// `FeedLibraryStore.search` over a library already loaded in memory: the same results in
    /// the same order, without SQLite parsing every episode record's JSON for each query (0.3–0.4 s on a
    /// 23,000-episode library). `deletionTargets` are the loaded snapshot's.
    public static func search(query: String, feeds: [LibraryFeed], deletionTargets: [Int64: EpisodeMediaDeletionTarget],
                              feedID: Int64? = nil, archived: Bool = false) throws -> LibrarySearchResult {
        try Task.checkCancellation()
        let words = query.components(separatedBy: CharacterSet(charactersIn: " \t\n\u{b}\u{c}\r")).filter { !$0.isEmpty }
        guard !words.isEmpty else { return .init() }
        let patterns = words.map(SQLiteLikePattern.init(containing:))
        let state: FeedSubscriptionState = archived ? .archived : .subscribed
        var result = LibrarySearchResult()
        var matches: [(pubdate: Int64, episode: LibraryEpisode, feedID: Int64)] = []
        for feed in feeds {
            if let feedID { guard feed.id == feedID else { continue } } else { guard feed.subscriptionState == state else { continue } }
            try Task.checkCancellation()
            for episode in feed.episodes where patterns.allSatisfy({ $0.matches(episode.details.title) || $0.matches(episode.details.description) }) {
                // The episodes table's pubdate column: whole milliseconds, truncated.
                let pubdate = episode.details.publicationDate.map { Int64($0.timeIntervalSince1970 * 1_000) } ?? 0
                matches.append((pubdate, episode, feed.id))
            }
        }
        // ORDER BY e.pubdate DESC, e.id LIMIT 300
        matches.sort { $0.pubdate != $1.pubdate ? $0.pubdate > $1.pubdate : $0.episode.id < $1.episode.id }
        result.episodes = matches.prefix(300).map { .init(feedID: $0.feedID, episode: $0.episode, deletionTarget: deletionTargets[$0.episode.id]) }
        if feedID == nil {
            let found = feeds.filter { feed in
                feed.subscriptionState == state && patterns.allSatisfy { pattern in
                    [feed.metadata.title, feed.customTitle, feed.metadata.author, feed.metadata.description].contains { pattern.matches($0) }
                }
            }
            // ORDER BY f.title ASC (the metadata title column; NULL first; byte order), f.id LIMIT 300
            result.feeds = Array(found.sorted { lhs, rhs in
                switch (lhs.metadata.title, rhs.metadata.title) {
                case (nil, nil): return lhs.id < rhs.id
                case (nil, _): return true
                case (_, nil): return false
                case let (left?, right?):
                    if left.utf8.elementsEqual(right.utf8) { return lhs.id < rhs.id }
                    return left.utf8.lexicographicallyPrecedes(right.utf8)
                }
            }.prefix(300)).map { var feed = $0; feed.episodes = []; return feed }
        }
        return result
    }
}

/// SQLite's default `LIKE '%word%'`: `%` matches any run of characters, `_` one character, ASCII letters match
/// either case and every other character only itself; NULL never matches.
struct SQLiteLikePattern: Sendable {
    /// Runs between `%`s; each element is a lowercased byte, or -1 for `_`.
    private let segments: [[Int16]]

    init(containing word: String) {
        var segments: [[Int16]] = [[]]
        for byte in word.utf8 {
            switch byte {
            case UInt8(ascii: "%"): segments.append([])
            case UInt8(ascii: "_"): segments[segments.count - 1].append(-1)
            default: segments[segments.count - 1].append(Int16(Self.lower(byte)))
            }
        }
        self.segments = segments.filter { !$0.isEmpty }
    }

    private static func lower(_ byte: UInt8) -> UInt8 { byte >= 65 && byte <= 90 ? byte + 32 : byte }

    func matches(_ value: String?) -> Bool {
        guard var text = value else { return false }
        if segments.isEmpty { return true }
        return text.withUTF8 { bytes in
            var position = 0
            for segment in segments {
                guard let end = find(segment, in: bytes, from: position) else { return false }
                position = end
            }
            return true
        }
    }

    /// The end of the first match of `segment` starting at or after `start` (on a character boundary).
    private func find(_ segment: [Int16], in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        var index = start
        while index < bytes.count {
            if bytes[index] & 0xC0 != 0x80, let end = match(segment, in: bytes, at: index) { return end }
            index += 1
        }
        return nil
    }

    private func match(_ segment: [Int16], in bytes: UnsafeBufferPointer<UInt8>, at start: Int) -> Int? {
        var index = start
        for element in segment {
            guard index < bytes.count else { return nil }
            if element < 0 {
                // One whole UTF-8 character.
                index += 1
                while index < bytes.count, bytes[index] & 0xC0 == 0x80 { index += 1 }
            } else {
                guard Int16(Self.lower(bytes[index])) == element else { return nil }
                index += 1
            }
        }
        return index
    }
}
