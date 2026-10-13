import Foundation

/// DownloadLogDetailsDialog's current-owner resolution and clipboard format.
public struct FeedLogDetails: Equatable, Sendable {
    public let podcast: String?
    public let episode: String?
    public let feedID: Int64?
    public let status, technical, fileURL, clipboard: String
    public let statusKey: String

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
