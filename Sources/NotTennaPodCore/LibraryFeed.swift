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

extension LibraryEpisode {
    /// An episode as lists show it: without its show notes (`details.description`) and chapters, which only an
    /// episode's own page and the player read. Never saved: every writer refuses to change the stored details
    /// (`EpisodeWriteScope`).
    public var listProjection: LibraryEpisode {
        var episode = self
        episode.details.description = nil
        episode.details.chapters = nil
        return episode
    }

    /// `listProjection` made by SQLite from a record column, as JSON text: the left-out values are never decoded.
    static func listProjectionSQL(_ column: String) -> String {
        "json_remove(CAST(\(column) AS TEXT), '$.details.description', '$.details.chapters')"
    }
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
    /// This device's last refresh of the feed failed (cleared by its next successful refresh). Android's flag, exported.
    public var lastUpdateFailed = false
    /// In a server library, the server's latest known refresh status of the podcast (its `refresh_status` record):
    /// kept apart from this device's own (`lastUpdateFailed`), so neither erases the other. Device-only; never exported.
    public var serverRefresh: ServerRefreshStatus?
    /// When this device last refreshed the feed: a refresh that read it, or one that failed; nil until it does. Unlike
    /// `lastRefreshAttempt`, never set by a server library's projection nor by a preview's aging. Device-only.
    public var localRefreshAttempt: Date?
    /// The icon and notice of a failed refresh: this device's last refresh failed, or the server reports that its own
    /// fails. A healthy refresh on one side does not hide a failure on the other; the details show both.
    public var refreshFailed: Bool { lastUpdateFailed || serverRefresh?.failed == true }
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

    /// Android's `Feed.getHumanReadableIdentifier`: the title, else the feed's address (a subscription whose metadata
    /// has not arrived yet still says which podcast it is).
    public var humanReadableIdentifier: String {
        if let title, !title.isEmpty { return title }
        return source
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
            if options.refreshAttempt > (localRefreshAttempt ?? Date(timeIntervalSince1970: 0)) {
                localRefreshAttempt = options.refreshAttempt
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

/// A podcast's `refresh_status` record as a server library shows it (PROTOCOL §9.4): the server's last attempt, its last
/// success, and the failure of the last attempt with Android's DownloadError label, the HTTP status for `http_status` and
/// a sanitized detail. Published when its outcome or error changes, and at most once a day otherwise, so `lastAttempt` is
/// when the server last published, not necessarily its latest attempt.
public struct ServerRefreshStatus: Equatable, Codable, Sendable {
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    /// The failure's label; nil when the last attempt succeeded.
    public var label: String?
    public var code: Int?
    public var detail: String?

    public init(lastAttempt: Date?, lastSuccess: Date? = nil, label: String? = nil, code: Int? = nil, detail: String? = nil) {
        self.lastAttempt = lastAttempt; self.lastSuccess = lastSuccess; self.label = label; self.code = code; self.detail = detail
    }

    /// The record's value (`{last_attempt, last_success, error: {label, code, detail} or null, next_attempt}`); nil for
    /// no record or a null one.
    init?(record value: ContractJSON?) {
        guard let value, value.objectValue != nil else { return nil }
        func date(_ name: String) -> Date? { value[name]?.integerValue.map { Date(timeIntervalSince1970: Double($0) / 1_000) } }
        lastAttempt = date("last_attempt"); lastSuccess = date("last_success")
        if let error = value["error"], error.objectValue != nil {
            label = error["label"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            code = error["code"]?.integerValue.map { Int(clamping: $0) }
            detail = error["detail"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    public var failed: Bool { label != nil }

    /// The Download log's wording of the label (Android's DownloadErrorLabel, as the web shows it).
    public var statusKey: String {
        switch label {
        case nil: "download_successful"
        case "unauthorized": "download_error_unauthorized"
        case "forbidden": "download_error_forbidden"
        case "not_found": "download_error_not_found"
        case "http_status": "download_error_http_data_error"
        case "io", "too_many_redirects": "download_error_io_error"
        case "time_limit": "download_error_connection_error"
        case "refused_destination": "download_error_unknown_host"
        case "parser_exception": "download_error_parser_exception"
        case "unsupported_type": "download_error_unsupported_type"
        case "unsupported_type_html": "download_error_unsupported_type_html"
        default: "download_error_error_unknown"
        }
    }

    /// The technical detail: the server's sanitized detail, else the HTTP status; nothing else (never the label).
    public var technical: String? { detail ?? code.map(String.init) }
}
