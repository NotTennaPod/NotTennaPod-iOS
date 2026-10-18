import Foundation

public struct FeedRefreshOptions: Sendable {
    public var now: Date
    public var refreshAttempt: Date
    public var timeZone: TimeZone
    public var pageNumber = 0
    public var validator: String?
    public var isLocalFeed = false
    public var removeUnlistedItems = false
    public var globalNewEpisodesAction: NewEpisodesAction = .inbox
    public var globalAutoDownload = false

    public init(now: Date = Date(), timeZone: TimeZone = .current) {
        self.now = now
        self.refreshAttempt = now
        self.timeZone = timeZone
    }
}

public struct FeedRefreshResult: Equatable, Sendable {
    public enum Duplicate: Equatable, Codable, Sendable {
        case repeatedEpisode(ignored: ParsedEpisode, canonical: ParsedEpisode)
        case changedIdentifier(previous: ParsedEpisode, replacement: ParsedEpisode, episodeID: Int64)
    }

    public struct CompletedEpisodeSync: Equatable, Codable, Sendable {
        public var episodeID: Int64
        public var identifier: String?
        public var mediaURL: String?
        public var totalSeconds: Int32
    }

    public var feed: LibraryFeed
    public var queueEpisodeIDs: [Int64]
    public var removedEpisodes: [LibraryEpisode]
    public var duplicates: [Duplicate]
    public var completedEpisodeSync: [CompletedEpisodeSync]
    /// A server library's refresh: each kept item's local episode → its index in the record-level parse.
    var serverItems: [Int64: Int] = [:]
    /// The refresh was identical to the feed's last applied one: only its header was written, and
    /// `feed` holds the header alone (no episodes).
    public var itemsUnchanged = false
}

extension FeedRefreshResult.Duplicate {
    /// Source `FeedDatabaseWriter`'s Download log reason for a repaired duplicate (English there too), shown as the
    /// entry's technical details: what happened, then title, ID and media URL of both episodes.
    public var detail: String {
        switch self {
        case .repeatedEpisode(let ignored, let canonical):
            "The podcast host appears to have added the same episode twice. "
                + "NotTennaPod still refreshed the feed and attempted to repair it."
                + "\n\nOriginal episode:\n" + Self.details(ignored)
                + "\n\nSecond episode that is also in the feed:\n" + Self.details(canonical)
        case .changedIdentifier(let previous, let replacement, _):
            "The podcast host changed the ID of an existing episode instead of just "
                + "updating the episode itself. NotTennaPod still refreshed the feed and "
                + "attempted to repair it."
                + "\n\nOriginal episode:\n" + Self.details(previous)
                + "\n\nNow the feed contains:\n" + Self.details(replacement)
        }
    }

    /// Source `duplicateEpisodeDetails`: Java string concatenation writes a missing value as `null`.
    private static func details(_ episode: ParsedEpisode) -> String {
        "Title: " + (episode.title ?? "null") + "\nID: " + (episode.identifier ?? "null")
            + (episode.media.map { "\nURL: " + ($0.url ?? "null") } ?? "")
    }

    /// Only what the Download log shows of each episode (title, ID, media URL), for the stored log row.
    var logged: Self {
        func trimmed(_ episode: ParsedEpisode) -> ParsedEpisode {
            ParsedEpisode(identifier: episode.identifier, title: episode.title,
                          media: episode.media.map { ParsedMedia(url: $0.url, size: 0) })
        }
        return switch self {
        case .repeatedEpisode(let ignored, let canonical): .repeatedEpisode(ignored: trimmed(ignored), canonical: trimmed(canonical))
        case .changedIdentifier(let previous, let replacement, let id):
            .changedIdentifier(previous: trimmed(previous), replacement: trimmed(replacement), episodeID: id)
        }
    }
}

public enum FeedRefreshMerger {
    public static func merge(_ incoming: ParsedFeed, into saved: LibraryFeed,
                             options: FeedRefreshOptions = FeedRefreshOptions(),
                             allocateEpisodeID: () throws -> Int64) rethrows -> FeedRefreshResult {
        var feed = saved
        feed.updateMetadata(incoming, options: options)
        var episodes = saved.episodes.map(RefreshEpisode.init)
        let incomingEpisodes = sorted(incoming.episodes).map {
            RefreshEpisode(LibraryEpisode(id: 0, details: $0))
        }
        let incomingPool = EpisodeDuplicatePool(incomingEpisodes, timeZone: options.timeZone)
        var savedPool = EpisodeDuplicatePool(episodes, timeZone: options.timeZone)
        let priorMostRecent = saved.episodes.compactMap(\.details.publicationDate)
            .filter { $0 > Date(timeIntervalSince1970: 0) }.max() ?? options.now
        var queue: [RefreshEpisode] = []
        var duplicates: [FeedRefreshResult.Duplicate] = []
        var sync: [FeedRefreshResult.CompletedEpisodeSync] = []

        for (index, candidate) in incomingEpisodes.enumerated() {
            let item = candidate.value.details
            if !options.isLocalFeed, let duplicate = incomingPool.guess(item), duplicate !== candidate {
                duplicates.append(.repeatedEpisode(ignored: item, canonical: duplicate.value.details))
                continue
            }
            var previous = savedPool.findByID(item)
            if previous == nil && !options.isLocalFeed, let duplicate = savedPool.guess(item) {
                duplicates.append(.changedIdentifier(previous: duplicate.value.details,
                                                     replacement: item, episodeID: duplicate.value.id))
                duplicate.value.details.identifier = item.identifier
                if duplicate.value.userState.playState == .played,
                   let media = duplicate.value.details.media, saved.subscriptionState != .notSubscribed {
                    sync.append(.init(episodeID: duplicate.value.id, identifier: item.identifier,
                                      mediaURL: media.url, totalSeconds: media.durationMilliseconds / 1_000))
                }
                previous = duplicate
            }
            if let previous {
                previous.value.update(from: item)
            } else {
                candidate.value.id = try allocateEpisodeID()
                episodes.insert(candidate, at: min(index, episodes.count))
                savedPool.add(candidate)
                if saved.subscriptionState == .subscribed,
                   item.publicationDate == nil || item.publicationDate! >= priorMostRecent {
                    var action = saved.newEpisodesAction == .global
                        ? options.globalNewEpisodesAction : saved.newEpisodesAction
                    if !options.isLocalFeed && (saved.autoDownload == .enabled
                        || (saved.autoDownload == .global && options.globalAutoDownload)) {
                        action = .inbox
                    }
                    switch action {
                    case .inbox: candidate.value.userState.playState = .new
                    case .queue: queue.append(candidate)
                    case .global, .nothing: break
                    }
                }
            }
        }

        var removed: [LibraryEpisode] = []
        if options.removeUnlistedItems {
            episodes.removeAll { episode in
                guard incomingPool.findByID(episode.value.details) == nil else { return false }
                removed.append(episode.value)
                return true
            }
        }
        for episode in episodes {
            if episode.value.details.publicationDate == nil { episode.value.details.publicationDate = options.now }
            if episode.value.details.chapters != nil { episode.value.hasStoredChapters = true }
        }
        feed.episodes = episodes.map(\.value)
        return FeedRefreshResult(feed: feed, queueEpisodeIDs: queue.map(\.value.id), removedEpisodes: removed,
                                 duplicates: duplicates, completedEpisodeSync: sync)
    }

    public static func insert(_ incoming: ParsedFeed, feedID: Int64, source: String,
                              options: FeedRefreshOptions = FeedRefreshOptions(),
                              allocateEpisodeID: () throws -> Int64) rethrows -> LibraryFeed {
        let episodes = try incoming.episodes.map { item in
            var episode = item
            if episode.publicationDate == nil { episode.publicationDate = options.now }
            return LibraryEpisode(id: try allocateEpisodeID(), details: episode, hasStoredChapters: episode.chapters != nil)
        }
        var feed = LibraryFeed(id: feedID, source: source, metadata: incoming, episodes: episodes)
        feed.pageNumber = options.pageNumber
        feed.validator = options.validator
        feed.lastRefreshAttempt = options.refreshAttempt
        return feed
    }

    private static func sorted(_ episodes: [ParsedEpisode]) -> [ParsedEpisode] {
        episodes.enumerated().sorted { lhs, rhs in
            switch (lhs.element.publicationDate, rhs.element.publicationDate) {
            case (nil, nil): return lhs.offset < rhs.offset
            case (nil, _): return true
            case (_, nil): return false
            case (let lhsDate?, let rhsDate?):
                return lhsDate == rhsDate ? lhs.offset < rhs.offset : lhsDate > rhsDate
            }
        }.map(\.element)
    }
}
