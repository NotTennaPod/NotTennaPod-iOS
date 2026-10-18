import CryptoKit
import Foundation
import Testing

/// The frozen full-reload reference (`Reference/FullReloadReference.swift`) stays as copied: its bytes are pinned, and
/// it names none of the incremental types it judges.
@Suite struct FullReloadReferencePinTests {
    static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Reference/FullReloadReference.swift")

    @Test func theReferenceIsUnchanged() throws {
        let data = try Data(contentsOf: Self.file)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "9bc06349da4f9d03bfd5767cf073164032681ba84fbae2ee7aeb82f6250b9913",
                "the reference changed: it must stay the verbatim copy of the full reload it was taken from")
    }

    static let screens = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Reference/ScreenReference.swift")

    /// The other screens' reference (Home, Subscriptions and the drawer, search), likewise.
    @Test func theScreensReferenceIsUnchanged() throws {
        let data = try Data(contentsOf: Self.screens)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "c5025a3bbe21e1e80565d869437404a3559dc1a60cdc9144d143c279487f2d3a",
                "the reference changed: it must stay the verbatim copy of the full reload it was taken from")
        let text = String(decoding: data, as: UTF8.self)
        for name in ["EpisodeListKeys", "ChunkedOrderedList", "EpisodeListIndex", "LibraryScreenMirror", "HomeScreenModel", "LibrarySearchMatches", "FeedLatestDates", "subscriptionList("] {
            #expect(!text.contains(name), "the reference uses \(name)")
        }
    }

    static let automaticDownload = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Reference/AutomaticDownloadReference.swift")

    /// Automatic download's whole-library selection, likewise; it names none of the keyed types.
    @Test func theAutomaticDownloadReferenceIsUnchanged() throws {
        let data = try Data(contentsOf: Self.automaticDownload)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "63ca93f7acb1b6cac1d1f6466c60d5ebd7c8177253d60b415f701e0694c37de7",
                "the reference changed: it must stay the verbatim copy of the selection it was taken from")
        let text = String(decoding: data, as: UTF8.self)
        for name in ["EpisodeListKeys", "Policy.Item", "Policy.Library", "automaticDownloadLibrary", "EpisodeSummary", "downloadedCount"] {
            #expect(!text.contains(name), "the reference uses \(name)")
        }
    }

    @Test func theReferenceNamesNoIncrementalType() throws {
        let text = try String(contentsOf: Self.file, encoding: .utf8)
        for name in ["EpisodeListKeys", "ChunkedOrderedList", "EpisodeListIndex", "EpisodeListSpec", "LibraryScreenMirror", "LibraryScreenUpdater", "LibraryMirror"] {
            #expect(!text.contains(name), "the reference uses \(name)")
        }
    }
}
