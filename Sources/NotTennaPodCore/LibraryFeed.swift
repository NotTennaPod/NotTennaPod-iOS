import Foundation

public enum EpisodePlayState: Int, Codable, Sendable, CaseIterable {
    case new = -1, unplayed = 0, played = 1
}

public struct EpisodeUserState: Equatable, Codable, Sendable {
    public var playState: EpisodePlayState = .unplayed
    public var isFavorite = false
    public var autoDownloadEnabled = true
    public var positionMilliseconds: Int32 = 0
    public var playedDurationMilliseconds: Int64 = 0
    public var timeSpentMilliseconds: Int64 = 0
    public var lastPlayedTimeMilliseconds: Int64 = 0
    public var lastPlayedHistoryMilliseconds: Int64?
    public var playbackCompletionDate: Date?
    public var localFileURL: String?
    public var isDownloaded = false
    public var downloadDate: Date?
    /// Device-local, never synced or exported: when this device last saved the episode's playback (every save,
    /// listening or not, receiver playback it observed included), in a server library only. It is what a standalone
    /// library's last-played date holds after the same saves; the rewinds after a pause or an interruption measure
    /// from it, because the synced last-played date moves only with listening this phone started and with other
    /// devices' listening. Nil in a standalone library and for a local folder's episode, whose every save writes the
    /// last-played date itself.
    public var playedHereMilliseconds: Int64?

    public init() {}
}

public struct LibraryEpisode: Equatable, Codable, Sendable {
    public var id: Int64
    public var details: ParsedEpisode
    public var userState: EpisodeUserState
    public var hasStoredChapters: Bool

    public init(id: Int64, details: ParsedEpisode, userState: EpisodeUserState = EpisodeUserState(),
                hasStoredChapters: Bool = false) {
        self.id = id
        self.details = details
        self.userState = userState
        self.hasStoredChapters = hasStoredChapters
    }

    mutating func update(from other: ParsedEpisode) {
        if let value = other.title { details.title = value }
        if let value = other.imageURL { details.imageURL = value }
        if let value = other.description { details.description = value }
        if let value = other.link { details.link = value }
        if let value = other.publicationDate { details.publicationDate = value }
        if let value = other.paymentLink { details.paymentLink = value }
        if let value = other.chapterURL { details.chapterURL = value }
        if let value = other.socialInteractionURL { details.socialInteractionURL = value }
        if let value = other.transcript { details.transcript = value }
        if let value = other.chapters, !hasStoredChapters { details.chapters = value }
        if let media = other.media {
            if var old = details.media {
                old.url = media.url
                if media.size > 0 { old.size = media.size }
                if media.durationMilliseconds > 0 && old.durationMilliseconds <= 0 {
                    old.durationMilliseconds = media.durationMilliseconds
                }
                if let mime = media.mimeType { old.mimeType = mime }
                if let picture = media.hasEmbeddedPicture { old.hasEmbeddedPicture = picture }
                old.metadataPending = media.metadataPending
                details.media = old
            } else {
                details.media = media
                userState.playState = .new
            }
        }
    }
}

public enum FeedSubscriptionState: Int, Codable, Sendable, CaseIterable {
    case subscribed = 0, notSubscribed = 1, archived = 2
}

public enum NewEpisodesAction: Int, Codable, Sendable, CaseIterable {
    case global = 0, inbox = 1, nothing = 2, queue = 3

    public init(storedValue: Int) { self = Self(rawValue: storedValue) ?? .inbox }
    public static let displayOrder: [Self] = [.global, .inbox, .queue, .nothing]
    public var titleKey: String {
        switch self {
        case .global: "global_default"
        case .inbox: "feed_new_episodes_action_add_to_inbox"
        case .queue: "feed_new_episodes_action_add_to_queue"
        case .nothing: "feed_new_episodes_action_nothing"
        }
    }
}

public enum FeedAutoDownload: Int, Codable, Sendable, CaseIterable {
    case disabled = 0, global = 1, enabled = 2

    public init(storedValue: Int) { self = Self(rawValue: storedValue) ?? .global }
    public static let displayOrder: [Self] = [.global, .enabled, .disabled]
    public var titleKey: String {
        switch self { case .global: "global_default"; case .enabled: "enabled"; case .disabled: "disabled" }
    }
}

public extension LibraryFeed {
    /// Source `LocalFeedUpdater.PREFIX_LOCAL_FOLDER`: a local folder feed's source is this prefix
    /// followed by the folder's identity.
    static let localSourcePrefix = "antennapod_local:"
}

public extension String {
    /// Whether this feed source names a local folder rather than a remote address.
    var isLocalFeedSource: Bool { hasPrefix(LibraryFeed.localSourcePrefix) }
}

public struct LibraryFeed: Equatable, Codable, Sendable {
    public var id: Int64
    public var source: String
    public private(set) var metadata: ParsedFeed
    /// Explicit import provenance, independent of failed/zero refresh timestamps.
    /// Missing in legacy records preserves their established parsed format.
    private var sourceTypeAbsent: Bool?
    public var sourceFeedType: String? {
        guard !source.isLocalFeedSource, sourceTypeAbsent != true else { return nil }
        return metadata.format.rawValue
    }
    mutating func markImportedPlaceholder() { sourceTypeAbsent = true }
    public var episodes: [LibraryEpisode]
    public var customTitle: String?
    public var subscriptionState: FeedSubscriptionState = .subscribed
    public var newEpisodesAction: NewEpisodesAction = .global
    public var autoDownload: FeedAutoDownload = .global
    public func newEpisodeActionIsAutomatic(globalAutoDownload: Bool) -> Bool {
        !source.isLocalFeedSource &&
            (autoDownload == .enabled || (autoDownload == .global && globalAutoDownload))
    }
    /// Absent in older Swift records; FeedPreferences defaults this to true.
    private var keepUpdatedValue: Bool?
    public var keepUpdated: Bool {
        get { keepUpdatedValue ?? true }
        set { keepUpdatedValue = newValue }
    }
    /// Original FeedPreferences defaults notifications off. Optional storage
    /// preserves that default when reading earlier Swift library records.
    private var showEpisodeNotificationValue: Bool?
    public var showEpisodeNotification: Bool {
        get { showEpisodeNotificationValue ?? false }
        set { showEpisodeNotificationValue = newValue }
    }
    private var automaticDownloadFilterValue: AutomaticDownloadFilter?
    public var automaticDownloadFilter: AutomaticDownloadFilter {
        get { automaticDownloadFilterValue ?? .init() }
        set { automaticDownloadFilterValue = newValue }
    }
    /// Missing in older Swift headers; original FeedPreferences starts empty.
    private var tagValues: [String]?
    public var tags: [String] {
        get { tagValues ?? [] }
        set { tagValues = FeedTags.unique(newValue) }
    }
    /// Older Swift headers and the original feed defaults both mean no skipping.
    private var skipPreferencesValue: FeedSkipPreferences?
    public var skipPreferences: FeedSkipPreferences {
        get { skipPreferencesValue ?? .init() }
        set { skipPreferencesValue = newValue }
    }
    private var volumeAdaptationValue: FeedVolumeAdaptation?
    public var volumeAdaptation: FeedVolumeAdaptation {
        get { volumeAdaptationValue ?? .off }
        set { volumeAdaptationValue = newValue }
    }
    private var autoDeleteValue: FeedAutoDelete?
    public var autoDelete: FeedAutoDelete {
        get { autoDeleteValue ?? .global }
        set { autoDeleteValue = newValue }
    }
    public var pageNumber = 0
    public var validator: String?
    public var lastRefreshAttempt: Date?
    /// FeedItemlistFragment.refreshHeaderView uses a strict24-hour boundary.
    /// Legacy missing attempts correspond to the source's zero timestamp.
    public func needsPreviewRefresh(at now: Date) -> Bool {
        subscriptionState == .notSubscribed &&
            (lastRefreshAttempt ?? Date(timeIntervalSince1970: 0)) < now.addingTimeInterval(-86_400)
    }
    public var lastUpdateFailed = false
    /// Original SortOrder code. Nil retains the existing/default presentation.
    public var episodeSortOrderCode: Int?
    /// Optional so existing stored headers decode as unfiltered.
    public var episodeFilterValues: [String]?
    public var episodeFilter: FeedEpisodeFilter { FeedEpisodeFilter(values: episodeFilterValues ?? []) }
    public func filteredDisplayEpisodes(queuedIDs: Set<Int64>, globalSort: FeedEpisodeSortOrder = .dateNewest) -> [LibraryEpisode] {
        let filter = episodeFilter
        return sortedEpisodes(global: globalSort).filter { filter.includes($0, queued: queuedIDs.contains($0.id)) }
    }

    /// Test inspection API: not called by the app.
    var displayEpisodes: [LibraryEpisode] {
        sortedEpisodes()
    }
    public func sortedEpisodes(global: FeedEpisodeSortOrder = .dateNewest) -> [LibraryEpisode] {
        let order = episodeSortOrderCode.flatMap(FeedEpisodeSortOrder.init(rawValue:)) ?? .global
        return order.sorted(episodes, global: global)
    }

    public var title: String? {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        return metadata.title
    }

    public var identifyingValue: String? {
        if let value = metadata.identifier, !value.isEmpty { return value }
        if !source.isEmpty { return source }
        if let value = metadata.title, !value.isEmpty { return value }
        return metadata.link
    }

    public init(id: Int64, source: String, metadata: ParsedFeed, episodes: [LibraryEpisode]) {
        self.id = id
        self.source = source
        self.metadata = metadata
        self.metadata.episodes = []
        self.episodes = episodes
    }

    mutating func resetPagination() {
        metadata.nextPageURL = source
        pageNumber = 0
    }

    mutating func updateMetadata(_ other: ParsedFeed, options: FeedRefreshOptions) {
        if pageNumber == options.pageNumber {
            if let value = other.identifier { metadata.identifier = value }
            if let value = other.title { metadata.title = value }
            if let value = other.imageURL { metadata.imageURL = value }
            if let value = other.description { metadata.description = value }
            if let value = other.link { metadata.link = value }
            if let value = other.author { metadata.author = value }
            if let value = other.language { metadata.language = value }
            if !other.funding.isEmpty { metadata.funding = other.funding }
            if options.refreshAttempt > (lastRefreshAttempt ?? Date(timeIntervalSince1970: 0)) {
                lastRefreshAttempt = options.refreshAttempt
            }
            if !metadata.isPaged && other.isPaged {
                metadata.isPaged = true
                metadata.nextPageURL = other.nextPageURL
            }
        } else {
            metadata.nextPageURL = other.nextPageURL
            // A refreshed preview must not be expired by completion cleanup.
            // Android retains the old attempt on another page and deletes the
            // just-refreshed preview; the confirmed empty-card defect is avoided.
            if subscriptionState == .notSubscribed,
               options.refreshAttempt > (lastRefreshAttempt ?? Date(timeIntervalSince1970: 0)) {
                lastRefreshAttempt = options.refreshAttempt
            }
        }
        sourceTypeAbsent = false
        metadata.format = other.format
        validator = options.validator
        lastUpdateFailed = false
    }
}

extension LibraryFeed {
    /// A server library's canonical podcast metadata (PROTOCOL §6.8): the fields the `metadata` record
    /// carries replace the stored ones; paging and refresh bookkeeping stay the device's.
    mutating func applyCanonicalMetadata(title: String?, description: String?, author: String?, language: String?,
                                         link: String?, imageURL: String?, funding: [FeedFunding], format: ParsedFeed.Format?) {
        metadata.title = title; metadata.description = description; metadata.author = author
        metadata.language = language; metadata.link = link; metadata.imageURL = imageURL; metadata.funding = funding
        if let format { metadata.format = format }
    }
}
