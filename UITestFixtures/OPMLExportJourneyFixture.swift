#if DEBUG
import UIKit
import NotTennaPodCore

/// Explicit UUID test libraries only (`-test-library-id` + `-test-opml-export-journey`). Seeds feeds that
/// exercise export rules without network: renamed order, Atom, escaping/token address, imported
/// placeholder without type, and archived/preview exclusions. Optional one-time write failure
/// (`-test-opml-export-fail-once`) is labelled injected; the real Save picker is never replaced.
@MainActor enum OPMLExportJourneyFixture {
    /// Written once the library is seeded; a library without it is emptied before it opens (`SeededLibraryFixtures`).
    nonisolated static let readyMarker = "opml-export-fixture-ready"

    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-test-opml-export-journey") }

    static func prepare(directory: URL, store: FeedLibraryStore) async throws {
        let marker = directory.appendingPathComponent(readyMarker)
        if !FileManager.default.fileExists(atPath: marker.path) {
            guard try await store.snapshot().feeds.isEmpty else { throw CocoaError(.fileWriteFileExists) }
            // Real parser metadata from in-memory documents; no network.
            func insert(_ source: String, _ xml: String, state: FeedSubscriptionState = .subscribed) async throws -> LibraryFeed {
                let result = try await FeedFetcher(transport: Transport(url: URL(string: source)!, body: Data(xml.utf8)))
                    .fetch(.init(source: source, generateMissingArtwork: false))
                guard case .updated(let fetched) = result else { throw CocoaError(.fileReadCorruptFile) }
                return try await store.insert(fetched, subscriptionState: state)
            }
            func rss(_ title: String, link: String?) -> String {
                "<rss version=\"2.0\"><channel><title>\(title)</title>" + (link.map { "<link>\($0)</link>" } ?? "") + "</channel></rss>"
            }
            let bravo = try await insert("https://bravo.example/feed", rss("Bravo Feed", link: "https://bravo.example/"))
            try await store.updatePreferences(feedID: bravo.id) { $0.customTitle = "Zulu Display" }
            _ = try await insert("https://alpha.example/feed",
                "<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>alpha feed</title><id>urn:opml-export:alpha</id></feed>")
            // Parsed titles are HTML-decoded like Android's HtmlCompat.fromHtml; a user custom title
            // carries literal markup characters that the export must escape.
            let escaping = try await insert("https://example.test/feed?token=fixture&x=1",
                rss("\u{c9}clair &amp; &quot;Quoted&quot;", link: "https://example.test/?a=1&amp;b=2"))
            try await store.updatePreferences(feedID: escaping.id) { $0.customTitle = "\u{c9}clair & <Friends> \"Quoted\"\t\u{1F3A7}" }
            _ = try await insert("https://archived.example/feed", rss("Archived Feed", link: nil), state: .archived)
            _ = try await insert("https://preview.example/feed", rss("Preview Feed", link: nil), state: .notSubscribed)
            _ = try await store.importOPMLEntry(.init(title: "Imported Placeholder", xmlURL: "https://imported.example/feed"))
            try Data("seeded; runner snapshots SQL before export\n".utf8).write(to: marker, options: .atomic)
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                if let controller = window.rootViewController as? LibraryViewController { await controller.reloadLibrary()?.value }
                window.accessibilityIdentifier = "opmlExportFixtureReady"
            }
        }
    }

    private struct Transport: FeedHTTPTransport {
        let url: URL
        let body: Data
        func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
            guard request.url == url else { throw URLError(.badURL) }
            return .init(url: url, status: 200, headers: ["Content-Type": "application/xml", "Content-Length": String(body.count)], body: body)
        }
    }

    /// One injected failure before any byte is written, then the real coordinated write.
    static func writer() -> DocumentExportOperation.Writer? {
        guard enabled, ProcessInfo.processInfo.arguments.contains("-test-opml-export-fail-once") else { return nil }
        let failure = FailOnce()
        return { data, url in
            if failure.consume() {
                throw NSError(domain: "OPMLExportFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Controlled export failure"])
            }
            try await DocumentExportOperation.coordinatedWrite(data, to: url)
        }
    }
    private final class FailOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining = 1
        func consume() -> Bool { lock.withLock { defer { remaining = 0 }; return remaining > 0 } }
    }
}
#endif
