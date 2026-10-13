import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Testing
@testable import NotTennaPodCore

private final class OPMLExportTestBundleMarker {}

struct OPMLExportWriterTests {
    private struct Input: Decodable {
        var title: String?
        var customTitle: String?
        var url: String?
        var type: String?
        var link: String?
        var state: Int?
    }
    private struct Fixture: Decodable {
        var name: String
        var feeds: [Input]
        var attributes: [[String: String]]
        var dateCreated: String
        var epochSeconds: Int64
    }
    private struct DateFixture: Decodable {
        var timeZone: String
        var milliseconds: Int64
        var formatted: String
    }
    private func fixture(_ name: String, extension ext: String) throws -> Data {
#if SWIFT_PACKAGE
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext,
            subdirectory: "Fixtures/OPMLExportFixtures"))
#else
        // The iOS view-test target copies the fixture folder itself as a resource.
        let url = try #require(Bundle(for: OPMLExportTestBundleMarker.self).url(forResource: name, withExtension: ext,
            subdirectory: "OPMLExportFixtures"))
#endif
        return try Data(contentsOf: url)
    }

    @Test(arguments: ["empty", "states", "custom-escaping", "local-private", "preserve-input-order", "not-subscribed-invalid"])
    func independentSourceDocuments(name: String) throws {
        let cases = try JSONDecoder().decode([Fixture].self, from: fixture("cases", extension: "json"))
        let sample = try #require(cases.first { $0.name == name })
        let inputs = sample.feeds.map { input in
            OPMLExportWriter.Outline(title: input.customTitle.flatMap { $0.isEmpty ? nil : $0 } ?? input.title,
                source: input.url, type: input.type, link: input.link,
                state: FeedSubscriptionState(rawValue: input.state ?? 0)!)
        }
        let native = try OPMLExportWriter.data(for: inputs,
            createdAt: Date(timeIntervalSince1970: Double(sample.epochSeconds)),
            timeZone: #require(TimeZone(identifier: "Asia/Kathmandu")))
        let parsed = try parse(native)
        // NotTennaPod titles the document with its own name; everything else is Android's document.
        let android = String(decoding: try fixture(name, extension: "opml"), as: UTF8.self)
        #expect(android.contains("<title>AntennaPod Subscriptions</title>"))
        let original = try parse(Data(android.replacingOccurrences(of: "<title>AntennaPod Subscriptions</title>",
                                                                   with: "<title>NotTennaPod Subscriptions</title>").utf8))
        #expect(parsed == original)
        #expect(parsed.name == "opml")
        #expect(parsed.attributes == ["version": "2.0"])
        #expect(parsed.children.map(\.name) == ["head", "body"])
        #expect(parsed.children[0].children.map(\.name) == ["title", "dateCreated"])
        #expect(parsed.children[0].children[0].text == "NotTennaPod Subscriptions")
        #expect(parsed.children[0].children[1].text == sample.dateCreated)
        #expect(parsed.children[1].children.map(\.attributes) == sample.attributes)
        #expect(String(decoding: native, as: UTF8.self).hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>"))
    }

    @Test func sourceDateFormattingUsesExplicitZoneAndClock() throws {
        let cases = try JSONDecoder().decode([DateFixture].self, from: fixture("date-cases", extension: "json"))
        #expect(cases.count == 16)
        for sample in cases {
            let data = try OPMLExportWriter.data(for: [LibraryFeed](),
                createdAt: Date(timeIntervalSince1970: Double(sample.milliseconds) / 1_000),
                timeZone: #require(TimeZone(identifier: sample.timeZone)))
            #expect(try parse(data).children[0].children[1].text == sample.formatted)
        }
    }

    @Test func libraryProjectionIncludesLocalAndPrivateWithoutAccessOrCredentialFields() throws {
        var local = LibraryFeed(id: 1, source: "antennapod_local:file:///fixture/podcasts",
            metadata: ParsedFeed(format: .rss, title: "Original Local"), episodes: [])
        local.customTitle = "Renamed Local"
        let remote = LibraryFeed(id: 2, source: "https://fixture-user:fixture-pass@example.test/a?token=fixture",
            metadata: ParsedFeed(format: .atom, title: "Atom", description: "Not exported", author: "Not exported",
                                 link: "https://example.test/?a=1&b=2"), episodes: [])
        var archived = remote; archived.subscriptionState = .archived
        let data = try OPMLExportWriter.data(for: [local, remote, archived], createdAt: Date(timeIntervalSince1970: 0), timeZone: .gmt)
        let outlines = try parse(data).children[1].children
        #expect(outlines.map(\.attributes) == [
            ["text": "Renamed Local", "title": "Renamed Local", "xmlUrl": "antennapod_local:file:///fixture/podcasts"],
            ["text": "Atom", "title": "Atom", "type": "atom", "xmlUrl": "https://fixture-user:fixture-pass@example.test/a?token=fixture",
             "htmlUrl": "https://example.test/?a=1&b=2"]
        ])
        #expect(outlines.allSatisfy { $0.children.isEmpty })
    }

    @Test func missingRequiredFieldsFailBeforeReturningAnyDocument() throws {
        let title = OPMLExportWriter.Outline(title: nil, source: "url", type: nil, link: nil, state: .subscribed)
        let url = OPMLExportWriter.Outline(title: "Title", source: nil, type: nil, link: nil, state: .subscribed)
        #expect(throws: OPMLExportWriter.Failure.missingTitle) {
            try OPMLExportWriter.data(for: [title], createdAt: Date(), timeZone: .gmt)
        }
        #expect(throws: OPMLExportWriter.Failure.missingSource) {
            try OPMLExportWriter.data(for: [url], createdAt: Date(), timeZone: .gmt)
        }
        var feed = LibraryFeed(id: 1, source: "", metadata: ParsedFeed(format: .rss), episodes: [])
        #expect(throws: OPMLExportWriter.Failure.missingTitle) {
            try OPMLExportWriter.data(for: [feed], createdAt: Date(), timeZone: .gmt)
        }
        feed.customTitle = ""; feed.subscriptionState = .notSubscribed
        #expect(try parse(OPMLExportWriter.data(for: [feed], createdAt: Date(), timeZone: .gmt)).children[1].children.isEmpty)
    }

    @Test(arguments: [UInt32(0), 1, 0xB, 0xC, 0xFFFE, 0xFFFF])
    func invalidXMLScalarsProduceAnError(codePoint: UInt32) throws {
        let invalid = String(try #require(Unicode.Scalar(codePoint)))
        for field in 0..<4 {
            let outline = OPMLExportWriter.Outline(title: field == 0 ? invalid : "Title", source: field == 1 ? invalid : "url",
                type: field == 2 ? invalid : nil, link: field == 3 ? invalid : nil, state: .subscribed)
            #expect(throws: OPMLExportWriter.Failure.invalidXMLCharacter(codePoint)) {
                try OPMLExportWriter.data(for: [outline], createdAt: Date(), timeZone: .gmt)
            }
        }
    }

    @Test func invalidDateIsAnError() {
        #expect(throws: OPMLExportWriter.Failure.invalidDate) {
            try OPMLExportWriter.data(for: [LibraryFeed](), createdAt: Date(timeIntervalSince1970: .infinity), timeZone: .gmt)
        }
    }

    @Test func originalTitleStoreOrderSurvivesCustomNamesAndDoesNotWriteLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OPMLExport-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        for (name, custom, address) in [("Bravo", "Alpha Display", "b"), ("alpha", "Zed Display", "a")] {
            let source = "https://example.test/\(address)"
            let saved = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: name),
                source: source, responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil))
            try await store.updatePreferences(feedID: saved.id) { $0.customTitle = custom }
        }
        try await store.close()
        let before = try Data(contentsOf: url)
        let reopened = try FeedLibraryStore(url: url)
        let feeds = try await reopened.feeds()
        #expect(feeds.map(\.title) == ["Zed Display", "Alpha Display"])
        let native = try OPMLExportWriter.data(for: feeds, createdAt: Date(timeIntervalSince1970: 0), timeZone: .gmt)
        #expect(try parse(native).children[1].children.map { $0.attributes["text"] } == ["Zed Display", "Alpha Display"])
        try await reopened.close()
        #expect(try Data(contentsOf: url) == before)
    }

    /// OPML-imported placeholders have no stored type until a successful parsed
    /// refresh; failed and 304 refreshes must not invent one.
    @Test func importedPlaceholderTypeFollowsPersistedRefreshTransitions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OPMLExport-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        var store = try FeedLibraryStore(url: url)
        let source = "https://example.test/imported.xml"
        let imported = try await store.importOPMLEntry(.init(title: "Imported", xmlURL: source, htmlURL: "https://ignored.test", type: "rss"))
        func outline() async throws -> [String: String] {
            let data = try OPMLExportWriter.data(for: try await store.feeds(), createdAt: Date(timeIntervalSince1970: 0), timeZone: .gmt)
            return try #require(try parse(data).children[1].children.first).attributes
        }
        let placeholder = ["text": "Imported", "title": "Imported", "xmlUrl": source]
        #expect(try await outline() == placeholder)
        try await store.recordFailure(.connection, feedID: imported.id, date: Date())
        #expect(try await outline() == placeholder)
        let service = FeedRefreshService(store: store, fetcher: FeedFetcher(transport: ExportNotModifiedTransport()))
        #expect(try await service.refresh(feedID: imported.id) == .unchanged)
        #expect(try await outline() == placeholder)
        _ = try await store.applyRefresh(FetchedFeed(feed: ParsedFeed(format: .atom, title: "Parsed", link: "https://example.test/"),
            source: source, responseURL: URL(string: source)!, validator: nil), feedID: imported.id)
        let parsed = ["text": "Parsed", "title": "Parsed", "type": "atom", "xmlUrl": source, "htmlUrl": "https://example.test/"]
        #expect(try await outline() == parsed)
        try await store.close()
        store = try FeedLibraryStore(url: url)
        #expect(try await outline() == parsed)
        try await store.close()
    }

    private struct ExportNotModifiedTransport: FeedHTTPTransport {
        func send(_ request: URLRequest) async throws -> FeedHTTPResponse { .init(url: request.url!, status: 304) }
    }

    private struct Element: Equatable {
        var name: String
        var attributes: [String: String]
        var text = ""
        var children: [Element] = []
    }
    private final class Parser: NSObject, XMLParserDelegate {
        var stack: [Element] = []
        var root: Element?
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            stack.append(Element(name: name, attributes: attributes))
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack[stack.count - 1].text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            var completed = stack.removeLast()
            // Only source-insignificant indentation between container children is normalized.
            if ["opml", "head", "body"].contains(name), completed.text.allSatisfy(\.isWhitespace) { completed.text = "" }
            if stack.isEmpty { root = completed } else { stack[stack.count - 1].children.append(completed) }
        }
    }
    private func parse(_ data: Data) throws -> Element {
        let delegate = Parser(), parser = XMLParser(data: data)
        parser.delegate = delegate
        #expect(parser.parse(), "\(String(describing: parser.parserError))")
        return try #require(delegate.root)
    }
}
