import Foundation

/// DownloadLogDetailsDialog's current-owner resolution and clipboard format.
public struct FeedLogDetails: Equatable, Sendable {
    public let podcast: String?
    public let episode: String?
    public let feedID: Int64?
    public let status, technical, fileURL: String
    public private(set) var clipboard: String
    public let statusKey: String
    /// In a server library, where and when each side last refreshed the podcast ("The server: Failed (…)", "This
    /// device: Successful (…)"); empty otherwise.
    public private(set) var origins: [String] = []

    public init(log: FeedLibraryLog, feed: LibraryFeed?, text: (String) -> String) {
        // A deleted/unavailable feed uses the logged title and literal unknown URL.
        let current = feed.flatMap { $0.id == log.feedID ? $0 : nil }
        feedID = current?.id
        episode = nil
        podcast = current?.title ?? log.title
        fileURL = current?.source ?? "unknown"
        statusKey = Self.statusKey(for: log.kind)
        status = text(statusKey)
        // Duplicate rows written before the reason text was stored derive it from their episodes.
        let duplicateDetail: String? = if case .duplicate(let duplicate) = log.kind { duplicate.detail } else { nil }
        let detail = log.kind.isSuccessful ? text("download_successful") : log.detail ?? duplicateDetail
        technical = detail ?? ""
        // Source String.format renders a missing diagnostic as null, whereas
        // TextView.setText(null) leaves the on-screen field empty.
        clipboard = "\(text("download_log_details_human_readable_reason_title")): \n\(status) \n\n"
            + "\(text("download_log_details_technical_reason_title")): \n\(detail ?? "null") \n\n"
            + "\(text("download_log_details_file_url_title")): \n\(fileURL)"
    }

    public init(entry: DownloadLogEntry, feed: LibraryFeed?, episode: LibraryEpisode?, text: (String) -> String) {
        if case .feed(let log) = entry.result {
            self = Self(log: log, feed: feed, text: text)
            return
        }
        if case .imported(let log) = entry.result, log.type != 2 {
            // Restored feed row: same owner resolution as a native feed log.
            let current = feed.flatMap { $0.id == log.feedID ? $0 : nil }
            feedID = current?.id; self.episode = nil
            podcast = current?.title ?? log.title
            fileURL = current?.source ?? "unknown"
            statusKey = log.statusKey; status = text(statusKey)
            let detail = log.successful ? text("download_successful") : log.detail
            technical = detail ?? ""
            clipboard = "\(text("download_log_details_human_readable_reason_title")): \n\(status) \n\n"
                + "\(text("download_log_details_technical_reason_title")): \n\(detail ?? "null") \n\n"
                + "\(text("download_log_details_file_url_title")): \n\(fileURL)"
            return
        }
        let currentEpisode = episode.flatMap { $0.id == entry.episodeID ? $0 : nil }
        let currentFeed = feed.flatMap { currentEpisode != nil && $0.id == entry.feedID ? $0 : nil }
        feedID = currentFeed?.id
        podcast = currentFeed?.title
        self.episode = currentEpisode?.details.title ?? entry.title
        fileURL = currentEpisode?.details.media?.url ?? "unknown"
        statusKey = entry.statusKey
        status = text(statusKey)
        let detail: String?
        if entry.isSuccessful { detail = text("download_successful") }
        else if case .media(let log) = entry.result { detail = log.detail ?? log.failure.flatMap(DownloadDiagnostic.media) }
        else if case .imported(let log) = entry.result { detail = log.detail }
        else { detail = nil }
        technical = detail ?? ""
        clipboard = "\(text("download_log_details_human_readable_reason_title")): \n\(status) \n\n"
            + "\(text("download_log_details_technical_reason_title")): \n\(detail ?? "null") \n\n"
            + "\(text("download_log_details_file_url_title")): \n\(fileURL)"
    }

    /// The server's failed refresh of a podcast (its `refresh_status`): Android's dialog with the server's wording, its
    /// sanitized detail (never the internal label) and the podcast's address.
    public init(server status: ServerRefreshStatus, feed: LibraryFeed, text: (String) -> String) {
        feedID = feed.id; episode = nil
        podcast = feed.title
        fileURL = feed.source
        statusKey = status.statusKey
        self.status = text(statusKey)
        let detail = status.technical
        technical = detail ?? ""
        clipboard = "\(text("download_log_details_human_readable_reason_title")): \n\(self.status) \n\n"
            + "\(text("download_log_details_technical_reason_title")): \n\(detail ?? "null") \n\n"
            + "\(text("download_log_details_file_url_title")): \n\(fileURL)"
    }

    /// What the notice of a failed refresh opens (`LibraryFeed.refreshFailed`): this device's latest refresh when it
    /// failed (its log entry has the device's own details), else the server's failure; nil when neither failed (the
    /// Download log then). In a server library the details also say how and when each side last refreshed: the server's
    /// published status, and this device's own last refresh (`localRefreshAttempt`; none for a podcast it never
    /// refreshed, whatever its creation time).
    public static func refreshFailure(latestLog log: FeedLibraryLog?, feed: LibraryFeed?, text: (String) -> String,
                                      date: (Date) -> String) -> FeedLogDetails? {
        var details: FeedLogDetails
        if let log, !log.kind.isSuccessful { details = FeedLogDetails(log: log, feed: feed, text: text) }
        else if let feed, let status = feed.serverRefresh, status.failed { details = FeedLogDetails(server: status, feed: feed, text: text) }
        else { return nil }
        guard let feed, let server = feed.serverRefresh else { return details }
        func outcome(_ successful: Bool, _ time: Date?) -> String {
            let word = text(successful ? "gpodnetsync_pref_report_successful" : "gpodnetsync_pref_report_failed")
            return time.map { word + " (" + date($0) + ")" } ?? word
        }
        details.origins = [String(format: text("ntp_refresh_by_server"), outcome(!server.failed, server.lastAttempt))]
        if let time = feed.localRefreshAttempt {
            details.origins.append(String(format: text("ntp_refresh_by_device"), outcome(!feed.lastUpdateFailed, time)))
        }
        details.clipboard += " \n\n\(text("ntp_refresh_last_title")): \n" + details.origins.joined(separator: "\n")
        return details
    }

    public static func statusKey(for kind: FeedLibraryLog.Kind) -> String {
        switch kind {
        case .success: "download_successful"
        case .duplicate: "download_error_parser_exception"
        case .failure(let error):
            switch error {
            case .malformedURL: "download_error_error_unknown"
            case .unauthorized: "download_error_unauthorized"
            case .forbidden: "download_error_forbidden"
            case .notFound: "download_error_not_found"
            case .httpStatus: "download_error_http_data_error"
            case .tooManyRedirects, .io: "download_error_io_error"
            case .connection: "download_error_connection_error"
            case .unknownHost: "download_error_unknown_host"
            case .certificate: "download_error_certificate"
            case .blocked: "download_error_blocked"
            case .wrongSize: "download_error_wrong_size"
            case .unsupportedFeed: "download_error_unsupported_type"
            case .websiteInsteadOfFeed: "download_error_unsupported_type_html"
            case .parsing, .missingFeedTitle, .missingEpisodeTitle: "download_error_parser_exception"
            }
        }
    }
}
