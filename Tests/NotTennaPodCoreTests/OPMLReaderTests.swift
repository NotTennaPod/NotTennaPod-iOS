import Foundation
import Testing
@testable import NotTennaPodCore

private final class OPMLTestBundleMarker {}

struct OPMLReaderTests {
    private struct Oracle: Decodable {
        struct Case: Decodable {
            let name: String
            let scope: String
            let input: String
            let entries: [OPMLDocument.Entry]
            let outcome: String
        }
        let provider: String
        let cases: [Case]
    }

    private func fixtureDirectory(_ name: String) throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
#else
        try #require(Bundle(for: OPMLTestBundleMarker.self).url(forResource: name, withExtension: nil))
#endif
    }

    private func fixture(_ name: String) throws -> Data {
        let directory = try fixtureDirectory("OPMLFixtures")
        return try Data(contentsOf: directory.appendingPathComponent(name))
    }

    @Test func unchangedHostReaderFixtures() throws {
        let oracle = try JSONDecoder().decode(Oracle.self, from: fixture("oracle.json"))
        #expect(oracle.provider == "org.kxml2.io.KXmlParser")
        let supported = oracle.cases.filter { $0.scope == "supported" }
        #expect(supported.count == 29)
        for item in supported {
            let data = try fixture(item.input)
            if item.outcome == "error" {
                #expect(throws: OPMLReadingError.self, "Fixture: \(item.name)") {
                    try OPMLReader().read(data)
                }
            } else {
                let result = try OPMLReader().read(data)
                #expect(result.entries == item.entries, "Fixture: \(item.name)")
                for (actual, expected) in zip(result.entries, item.entries) {
                    // Swift canonical equality alone cannot prove raw source strings.
                    #expect(Array(actual.title.utf16) == Array(expected.title.utf16))
                    #expect(Array(actual.xmlURL.utf16) == Array(expected.xmlURL.utf16))
                }
            }
        }
    }

    @Test func literalTitleFallbackOrderAndRepeatedRows() throws {
        let xml = """
        <opml><body><outline text="Group">
        <outline title="Named" text="Ignored" xmlUrl="a"/>
        <outline title="" text="Text" xmlUrl="same"/>
        <outline xmlUrl="same"/><outline text="" xmlUrl=""/>
        <outline title=" " xmlUrl="a"/></outline></body></opml>
        """
        let result = try OPMLReader().read(Data(xml.utf8))
        #expect(result.entries == [.init(title: "Named", xmlURL: "a"),
            .init(title: "Text", xmlURL: "same"), .init(title: "same", xmlURL: "same"),
            .init(title: " ", xmlURL: "a")])
    }

    @Test func attributesKeepAbsenceDistinctFromExplicitEmpty() throws {
        let result = try OPMLReader().read(Data("<opml><outline xmlUrl=\"a\"/><outline xmlUrl=\"b\" type=\"\" htmlUrl=\"\"/></opml>".utf8))
        #expect(result.entries[0].type == nil)
        #expect(result.entries[0].htmlURL == nil)
        #expect(result.entries[1].type == "")
        #expect(result.entries[1].htmlURL == "")
    }

    @Test func addressAndUnicodeAreNotNormalized() throws {
        let xml = "<opml><outline title=\"Café\" xmlUrl=\" HTTPS://E.test/a// \"/><outline title=\"Café\" xmlUrl=\"https://e.test/a\"/></opml>"
        let result = try OPMLReader().read(Data(xml.utf8))
        #expect(result.entries.map(\.xmlURL) == [" HTTPS://E.test/a// ", "https://e.test/a"])
        #expect(Array(result.entries[0].title.utf16) == [67, 97, 102, 101, 769])
        #expect(Array(result.entries[1].title.utf16) == [67, 97, 102, 233])
    }

    @Test func aFailedReadDoesNotPublishPrefixOrContaminateNextRead() throws {
        let reader = OPMLReader()
        #expect(throws: OPMLReadingError.self) {
            try reader.read(Data("<opml><outline xmlUrl=\"partial\"/></wrong>".utf8))
        }
        #expect(try reader.read(Data("<rss><outline xmlUrl=\"none\"/></rss>".utf8)).entries.isEmpty)
        #expect(try reader.read(Data("<opml><outline xmlUrl=\"fresh\"/></opml>".utf8)).entries
                == [.init(title: "fresh", xmlURL: "fresh")])
    }

    @Test func independentConcurrentReadsHaveNoSharedDocumentState() async throws {
        try await withThrowingTaskGroup(of: OPMLDocument.self) { group in
            for number in 0..<20 {
                group.addTask {
                    try OPMLReader().read(Data("<opml><outline xmlUrl=\"\(number)\"/></opml>".utf8))
                }
            }
            var values: Set<String> = []
            for try await result in group {
                #expect(result.entries.count == 1)
                values.insert(try #require(result.entries.first).xmlURL)
            }
            #expect(values == Set((0..<20).map(String.init)))
        }
    }
    @Test(arguments: ["duplicate-attributes", "empty", "multiple-roots", "nul-in-title", "plain-text", "truncated", "whitespace"])
    func approvedMalformedRejection(_ name: String) throws {
        #expect(throws: OPMLReadingError.self) { try OPMLReader().read(fixture(name + ".opml")) }
    }
    @Test func actualAndroidValidAttributeCases() throws {
        let a = try OPMLReader().read(fixture("attribute-prefixed.opml"))
        #expect(a.entries == [.init(title: "A", xmlURL: "a"), .init(title: "B", xmlURL: "b")])
        let w = try OPMLReader().read(fixture("xml-attribute-whitespace.opml"))
        #expect(w.entries[0].title.utf16.elementsEqual("a\tb c d\te\nf\rg".utf16))
        #expect(throws: OPMLReadingError.unresolvedEntity("title")) { try OPMLReader().read(fixture("doctype-internal.opml")) }
        #expect(try OPMLReader().read(Data("<!DOCTYPE opml><opml><outline xmlUrl='a'/></opml>".utf8)).entries.count == 1)
        #expect(try OPMLReader().read(Data("<!DOCTYPE opml [<!ENTITY unused 'Allowed declaration'>]><opml/>".utf8)).entries.isEmpty)
    }
    @Test func validWrapperRetainsPostClosedOPMLOutlines() throws {
        // Exact bytes and rows already observed with the original APK.
        #expect(try OPMLReader().read(fixture("wrapped.opml")).entries == [
            .init(title: "a", xmlURL: "a"), .init(title: "b", xmlURL: "b")])
    }
    @Test func namespaceSourceOrderMatchesUnchangedAndroidProviderSource() throws {
        let directory = try fixtureDirectory("OPMLNamespaceFixtures")
        let bytes = try Data(contentsOf: directory.appendingPathComponent("oracle.json"))
        // A distinct host execution of unchanged Android16 parser and pinned
        // AntennaPod reader produced this oracle before the Swift correction.
        // These are not new observations of the installed Android runtime.
        struct Case: Decodable { let name: String; let entries: [OPMLDocument.Entry]; let outcome: String }
        struct Result: Decodable { let provider: String; let cases: [Case] }
        struct SourceOracle: Decodable { let results: [String: Result] }
        let oracle = try JSONDecoder().decode(SourceOracle.self, from: bytes)
        let android = try #require(oracle.results["android16-source"])
        #expect(android.provider == "com.android.org.kxml2.io.KXmlParser" && android.cases.count == 8)
        for item in android.cases {
            #expect(item.outcome == "success")
            let actual = try OPMLReader().read(Data(contentsOf: directory.appendingPathComponent(item.name + ".opml")))
            #expect(actual.entries == item.entries, "Source fixture: \(item.name)")
            for (actual, expected) in zip(actual.entries, item.entries) {
                #expect(actual.title.utf16.elementsEqual(expected.title.utf16))
                #expect(actual.xmlURL.utf16.elementsEqual(expected.xmlURL.utf16))
            }
        }
    }

}
