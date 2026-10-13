import Foundation

/// A presentation of the existing durable refresh and transfer records. Clearing
/// history must never remove transfer jobs, their retry timing or queue state.
public struct DownloadLogEntry: Equatable, Sendable, Identifiable {
    public enum ID: Hashable, Sendable { case feed(Int64), media(job: Int64, attempt: Int), imported(Int64) }
    public enum Result: Equatable, Sendable { case feed(FeedLibraryLog), media(DownloadAttemptLog), imported(ImportedDownloadLog) }
    public let id: ID
    public let feedID: Int64
    public let episodeID: Int64?
    public let title: String?
    public let result: Result
    public var date: Date {
        switch result { case .feed(let log): log.date; case .media(let log): log.date; case .imported(let log): log.date }
    }
    /// Feed file type as shown (Feed / Media file); restored rows keep their source type.
    public var isMedia: Bool {
        switch result { case .feed: false; case .media: true; case .imported(let log): log.type == 2 }
    }
    /// DownloadLogAdapter status prefix; a restored pre-1.7 FeedImage row (type 1) has none.
    public var typeLabelKey: String? {
        if case .imported(let log) = result, log.type != 0, log.type != 2 { return nil }
        return isMedia ? "download_type_media" : "download_type_feed"
    }
    public var isSuccessful: Bool {
        switch result {
        case .feed(let log): log.kind.isSuccessful
        case .media(let log): log.failure == nil
        case .imported(let log): log.successful
        }
    }
    public var isInformational: Bool {
        switch result {
        case .feed(let log): if case .duplicate = log.kind { true } else { false }
        case .imported(let log): log.reason == 22
        case .media: false
        }
    }
    public var statusKey: String {
        switch result {
        case .feed(let log): FeedLogDetails.statusKey(for: log.kind)
        case .media(let log): Self.statusKey(for: log.failure)
        case .imported(let log): log.statusKey
        }
    }
    /// DownloadLogAdapter searches only the preceding rows in the displayed log.
    public func canRetry(in entries: [Self]) -> Bool {
        guard !isSuccessful, let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        return !entries[..<index].contains {
            $0.isSuccessful && $0.feedID == feedID && $0.episodeID == episodeID
        }
    }
    public static func statusKey(for failure: MediaDownloadFailure?) -> String {
        guard let failure else { return "download_successful" }
        let suffix: String = switch failure {
        case .http(401): "unauthorized"
        case .http(403): "forbidden"
        case .http(404), .http(410): "not_found"
        case .http: "http_data_error"
        case .malformedURL: "error_unknown"
        case .fileType: "file_type_type"
        case .invalidRange, .tooManyFollowUps, .io: "io_error"
        case .connection: "connection_error"
        case .unknownHost: "unknown_host"
        case .certificate: "certificate"
        case .blocked: "blocked"
        case .database: "db_access"
        case .wrongSize: "wrong_size"
        case .notEnoughSpace: "insufficient_space"
        }
        return "download_error_" + suffix
    }
}
