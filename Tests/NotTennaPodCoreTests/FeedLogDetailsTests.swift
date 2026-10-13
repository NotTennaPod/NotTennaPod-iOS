import Foundation
import Testing
@testable import NotTennaPodCore

struct FeedLogDetailsTests {
    private func text(_ key: String) -> String {
        ["download_log_details_human_readable_reason_title": "Status",
         "download_log_details_technical_reason_title": "Technical details",
         "download_log_details_file_url_title": "File URL", "download_error_io_error": "IO error",
         "download_successful": "successful"][key] ?? key
    }
    private func log(detail: String? = nil) -> FeedLibraryLog {
        .init(feedID: 7, date: Date(timeIntervalSince1970: 0), title: "Logged title", kind: .failure(.io(code: 13)), detail: detail)
    }

    @Test func currentFeedWinsButDeletedAndUnrelatedFeedsUseRecordedIdentity() {
        var feed = LibraryFeed(id: 7, source: "antennapod-local://current", metadata: .init(format: .rss, title: "Current title"), episodes: [])
        let current = FeedLogDetails(log: log(), feed: feed, text: text)
        #expect(current.podcast == "Current title" && current.fileURL == "antennapod-local://current")
        feed.id = 8
        for value in [nil, feed] {
            let details = FeedLogDetails(log: log(), feed: value, text: text)
            #expect(details.podcast == "Logged title" && details.fileURL == "unknown")
        }
        var missingTitle = log(); missingTitle.title = nil
        #expect(FeedLogDetails(log: missingTitle, feed: nil, text: text).podcast == nil)
        missingTitle.title = ""
        #expect(FeedLogDetails(log: missingTitle, feed: nil, text: text).podcast == "")
    }

    @Test func clipboardPreservesOriginalSeparatorsRawDiagnosticsAndNullVersusEmpty() {
        for detail in [nil, "", "Permission denied", "line one\nfile: café/🎧 & <folder>"] as [String?] {
            let value = FeedLogDetails(log: log(detail: detail), feed: nil, text: text)
            #expect(value.technical == (detail ?? ""))
            #expect(value.clipboard == "Status: \nIO error \n\nTechnical details: \n\(detail ?? "null") \n\nFile URL: \nunknown")
            #expect(!value.clipboard.contains("Logged title"))
        }
        var success = log(detail: "obsolete failure"); success.kind = .success
        let value = FeedLogDetails(log: success, feed: nil, text: text)
        #expect(value.status == "successful" && value.technical == "successful")
        #expect(!value.clipboard.contains("obsolete failure"))
    }

    @Test func everyRepresentableFeedFailureUsesOriginalDownloadErrorLabel() {
        let rows: [(FeedFetchError, String)] = [
            (.malformedURL, "error_unknown"), (.unauthorized, "unauthorized"), (.forbidden, "forbidden"),
            (.notFound(status: 404), "not_found"), (.notFound(status: 410), "not_found"), (.httpStatus(503), "http_data_error"),
            (.tooManyRedirects, "io_error"), (.connection, "connection_error"), (.unknownHost, "unknown_host"),
            (.certificate, "certificate"), (.blocked, "blocked"), (.io(code: nil), "io_error"), (.io(code: 13), "io_error"),
            (.wrongSize(expected: 100, received: 40), "wrong_size"), (.unsupportedFeed, "unsupported_type"),
            (.websiteInsteadOfFeed, "unsupported_type_html"), (.parsing(.malformedXML(line: 1, column: 2)), "parser_exception"),
            (.missingFeedTitle, "parser_exception"), (.missingEpisodeTitle(index: 2), "parser_exception")]
        for (error, suffix) in rows {
            #expect(FeedLogDetails.statusKey(for: .failure(error)) == "download_error_" + suffix)
        }
        let episode = ParsedEpisode(title: "Duplicate")
        #expect(FeedLogDetails.statusKey(for: .duplicate(.repeatedEpisode(ignored: episode, canonical: episode))) == "download_error_parser_exception")
        #expect(FeedLogDetails.statusKey(for: .success) == "download_successful")
    }
}
