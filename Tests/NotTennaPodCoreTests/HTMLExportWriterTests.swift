import Foundation
import Testing
@testable import NotTennaPodCore

/// The Swift HTML writers against the independent Python oracle, written from the pinned source without
/// reading this code. Libraries come from Android-schema databases through the database import, so every
/// field has its Android value. Expected documents are the oracle's `--variant escaped` output, which
/// applies the iOS escaping and NULL decisions to otherwise byte-exact Android 3.12.1 output.
@Suite(.serialized) struct HTMLExportWriterTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized
    static let evidence = root.appendingPathComponent("TestSupport/Data/html-export")

    // The three templates are covered by the whole-document comparisons below: the oracle builds its
    // expected documents from the pinned source assets, so any template byte that differs fails them.

    private func library(_ database: URL) async throws -> [LibraryFeed] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M17-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let restored = try AndroidDatabaseRestore.read(database, staging: directory.appendingPathComponent("s"))
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try await store.installRestoredLibrary(restored, carrying: try await store.restoreCarryOver())
        let feeds = try await store.feeds()
        try await store.close()
        return feeds
    }

    @Test(arguments: ["empty", "multiple", "unicode", "special", "missing", "local", "local-no-favorites", "states", "ties",
                      "npe-title", "npe-feed-image"])
    func syntheticLibrariesMatchTheOracle(_ name: String) async throws {
        let feeds = try await library(Self.evidence.appendingPathComponent("databases/\(name).db"))
        try compare(feeds, name)
    }

    @Test(arguments: ["archived-credentials-library", "authentication-preview-library", "emulator-parity-library", "first-journey-downloaded"])
    func realAndroidLibrariesMatchTheOracle(_ name: String) async throws {
        let feeds = try await library(Self.root.appendingPathComponent("TestSupport/Data/database-restore/android-3.12.1/\(name).db"))
        try compare(feeds, name)
    }

    /// Two hand-made NULLs the native library cannot hold (Android never writes either): a NULL
    /// `download_url` is stored as "" on import, so the export writes `href=""` where the source writes
    /// `href="null"`; a NULL `state` reads as subscribed, but the source's favorites SQL `state IN (0)`
    /// excludes it. Only these exact spans may differ, and only in these fixtures.
    private func expectedDocument(_ name: String, _ suffix: String) throws -> Data {
        var text = try String(contentsOf: Self.evidence.appendingPathComponent("expected-escaped/\(name)-\(suffix).html"), encoding: .utf8)
        // NotTennaPod: only the branding differs from Android's document; every other byte is compared.
        for (android, renamed) in [("<title>AntennaPod ", "<title>NotTennaPod "), ("<h1>AntennaPod ", "<h1>NotTennaPod "),
                                   ("background: #0d8eff;", "background: #158789;"),
                                   ("linear-gradient(180deg, #0f9cff, #0682ff)", "linear-gradient(180deg, #1FA8A6, #0B6670)"),
                                   ("        <img src=\"https://antennapod.org/assets/img/antennapod-logo.png\" />\r\n", ""),
                                   ("        <a href=\"https://play.google.com/store/apps/details?id=de.danoeh.antennapod\" target=\"_blank\">Get AntennaPod</a>\r\n", "")] {
            #expect(text.contains(android), "Android's document has \(android)")
            text = text.replacingOccurrences(of: android, with: renamed)
        }
        if name == "missing", suffix == "feeds" {
            let null = "<li><div><img src=\"null\" /><p>null <span><a href=\"null\">Website</a> \u{2022} <a href=\"null\">Feed</a>"
            #expect(text.contains(null))
            text = text.replacingOccurrences(of: null, with: "<li><div><img src=\"null\" /><p>null <span><a href=\"null\">Website</a> \u{2022} <a href=\"\">Feed</a>")
        }
        if name == "states", suffix == "favorites" {
            let group = "<li><div>\n<img src=\"https://example.org/4.png\" />\r\n<p>\r\n    Null state feed\r\n    <span>\r\n        <a href=\"https://example.org/4\">Website</a> \u{2022} <a href=\"https://example.org/4.xml\">Feed</a>\r\n    </span>\r\n</p><ul>\n"
                + "<li><span>\r\n    Null-state fav<br>\r\n    <a href=\"https://example.org/ep/4\">Website</a> \u{2022} <a href=\"https://example.org/ep/4.mp3\">Media</a>\r\n</span></li>\r\n</ul></div></li>\n"
            let parts = text.components(separatedBy: "</ul></div></li>\n")
            #expect(parts.count == 2, "one subscribed group in the source output")
            text = parts[0] + "</ul></div></li>\n" + group + parts[1]
        }
        return Data(text.utf8)
    }

    private func compare(_ feeds: [LibraryFeed], _ name: String) throws {
        for (suffix, data) in [("feeds", HTMLExportWriter.subscriptions(feeds)), ("favorites", HTMLExportWriter.favorites(feeds))] {
            let expected = try expectedDocument(name, suffix)
            if data != expected, let keep = ProcessInfo.processInfo.environment["M17_KEEP_DIR"] {
                try? data.write(to: URL(fileURLWithPath: keep).appendingPathComponent("\(name)-\(suffix).html"))
            }
            #expect(data == expected, "\(name)-\(suffix)")
        }
    }

    @Test func escapingAndSinglePassSubstitution() {
        #expect(HTMLExportWriter.escape("Tom & \"Jerry\" <b>'x'</b>") == "Tom &amp; &quot;Jerry&quot; &lt;b&gt;'x'&lt;/b&gt;")
        #expect(HTMLExportWriter.substitute("<a>{FEED_TITLE}|{FEED_LINK}|{OTHER}</a>", ["{FEED_TITLE}": "{FEED_LINK}", "{FEED_LINK}": nil])
                == "<a>{FEED_LINK}||{OTHER}</a>", "Data is not re-substituted; NULL becomes empty")
        #expect(JavaString.trim("\u{0}\t Title\u{A0} \n") == "Title\u{A0}")
    }
}
