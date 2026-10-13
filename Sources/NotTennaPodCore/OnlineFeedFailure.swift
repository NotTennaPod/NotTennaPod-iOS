import Foundation

// MARK: - Error dialog (OnlineFeedViewActivity.showErrorDialog)

public struct OnlineFeedFailure: Equatable, Sendable {
    /// Localizable key of the human-readable label (DownloadErrorLabel or the website wording).
    public var labelKey: String
    /// The technical reason.
    public var details: String
    public init(labelKey: String, details: String) { self.labelKey = labelKey; self.details = details }

    /// HttpDownloader failure → DownloadErrorLabel; `diagnostic` is the transport's message.
    public init(_ error: FeedFetchError, diagnostic: String?) {
        let message = diagnostic ?? "null"
        switch error {
        case .malformedURL: self.init(labelKey: "download_error_error_unknown", details: message)
        case .unauthorized: self.init(labelKey: "download_error_unauthorized", details: "401")
        case .forbidden: self.init(labelKey: "download_error_forbidden", details: "403")
        case .notFound(let status): self.init(labelKey: "download_error_not_found", details: String(status))
        case .httpStatus(let status): self.init(labelKey: "download_error_http_data_error", details: String(status))
        case .tooManyRedirects, .io: self.init(labelKey: "download_error_io_error", details: message)
        case .connection: self.init(labelKey: "download_error_connection_error", details: message)
        case .unknownHost: self.init(labelKey: "download_error_unknown_host", details: message)
        case .certificate: self.init(labelKey: "download_error_certificate", details: message)
        case .blocked: self.init(labelKey: "download_error_blocked", details: message)
        case .wrongSize(let expected, let received):
            self.init(labelKey: "download_error_wrong_size", details: DownloadDiagnostic.wrongSize(expected: expected, received: received))
        case .websiteInsteadOfFeed, .unsupportedFeed, .missingFeedTitle, .missingEpisodeTitle:
            self.init(labelKey: "download_error_parser_exception", details: message)
        case .parsing(let parsing): self.init(labelKey: "download_error_parser_exception", details: FeedDocumentClassifier.parserMessage(parsing))
        }
    }
    /// A website without feed links: manual or non-manual wording; any other document: broken feed.
    public init(document root: String?, message: String, manual: Bool) {
        if root?.lowercased() == "html" {
            self.init(labelKey: manual ? "download_error_unsupported_type_html_manual" : "download_error_unsupported_type_html",
                      details: message)
        } else { self.init(labelKey: "download_error_parser_exception", details: message) }
    }

    /// `download_log_details_message`: "%1$s \n\nTechnical reason: \n%2$s \n\nFile URL:\n%3$s".
    /// Returns the full text and the length of the label (the rest is drawn grey).
    public static func message(label: String, details: String, url: String, template: String) -> (text: String, labelLength: Int) {
        let text = template.replacingOccurrences(of: "%1$@", with: label).replacingOccurrences(of: "%2$@", with: details)
            .replacingOccurrences(of: "%3$@", with: url)
        return (text, (label as NSString).length)
    }
}
