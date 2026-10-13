import Foundation
import Testing
import SwiftSoup
@testable import NotTennaPodCore

struct ShownotesFormatterTests {
    private struct Oracle: Decodable {
        struct Case: Decodable {
            struct Expected: Decodable {
                struct Anchor: Decodable, Equatable { let text, href, className: String }
                let text, direction, html: String
                let breaks, paragraphs: Int
                let anchors: [Anchor]
                let inlineStyles: [String]
            }
            let input: String?
            let duration: Int32
            let expected: Expected
        }
        let referenceCommit: String
        let cases: [Case]
        let durationTransitions: [Case]
    }

    @Test func timestampBoundaryFollowsOriginalFeedPlaybackAndDownloadDurations() throws {
        let url = try #require(Bundle.module.url(forResource: "shownotes-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        #expect(oracle.durationTransitions.map(\.duration) == [30000, 30040, 30041])
        for item in oracle.durationTransitions {
            let raw = try #require(item.input)
            let output = try ShownotesFormatter.format(raw, durationMilliseconds: item.duration,
                noShownotesLabel: "empty", style: style)
            let anchors = try SwiftSoup.parse(output).select("a").map {
                try Oracle.Case.Expected.Anchor(text: $0.text(), href: $0.attr("href"), className: $0.className())
            }
            #expect(anchors == item.expected.anchors)
            #expect(raw == "<p>0:30 End boundary</p>")
        }
    }
    private let style = ShownotesFormatter.Style(foreground: "rgba(0,0,0,1.0)", accent: "rgba(0,120,194,1.0)", padding: 21)

    @Test func outputMatchesOriginalJavaCleaner() throws {
        let url = try #require(Bundle.module.url(forResource: "shownotes-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        #expect(oracle.referenceCommit == "f8c641887e4677237b01b6e942ff8fe20fc8beec")
        #expect(oracle.cases.count == 245)
        for (index, item) in oracle.cases.enumerated() {
            let output = try ShownotesFormatter.format(item.input, durationMilliseconds: item.duration,
                noShownotesLabel: "This episode has no shownotes.", style: style)
            let document = try SwiftSoup.parse(output)
            let expected = item.expected
            #expect(try document.body()?.text() == expected.text, "case \(index)")
            #expect(try document.body()?.attr("dir") == expected.direction, "case \(index)")
            #expect(try document.select("br").size() == expected.breaks, "case \(index)")
            #expect(try document.select("p").size() == expected.paragraphs, "case \(index)")
            let anchors = try document.select("a").map { try Oracle.Case.Expected.Anchor(text: $0.text(), href: $0.attr("href"), className: $0.className()) }
            #expect(anchors == expected.anchors, "case \(index)")
            #expect(try document.select("[style]").map { try $0.attr("style") } == expected.inlineStyles, "case \(index)")
            let original = try SwiftSoup.parse(expected.html)
            // Whitespace is serializer-specific; compare CSS tokens, not HTML indentation.
            func css(_ document: Document) throws -> [String] {
                try document.select("style").map { try $0.html().filter { !$0.isWhitespace } }
            }
            #expect(try css(document) == css(original), "case \(index)")
            #expect(try document.select("img").map { try $0.attr("src") } == original.select("img").map { try $0.attr("src") })
            #expect(try document.select("iframe").map { try $0.attr("src") } == original.select("iframe").map { try $0.attr("src") })
        }
    }

    @Test(arguments: ["antennapod://timecode/0", "antennapod://timecode/00072", "antennapod://timecode/2147483647"])
    func validTimecodeLinks(_ link: String) {
        #expect(ShownotesFormatter.timecodeMilliseconds(for: link) == Int32(link.split(separator: "/").last!))
    }

    @Test(arguments: ["", "https://timecode/0", "ANTENNAPOD://timecode/0", "antennapod://timecode/-1",
                     "antennapod://timecode/2147483648", "antennapod://timecode/1?x", "antennapod://timecode/1\n",
                     "antennapod://timecode/١", "antennapod://timecode/1/"])
    func invalidTimecodeLinks(_ link: String) { #expect(ShownotesFormatter.timecodeMilliseconds(for: link) == nil) }

    @Test func preservesExistingLinksAttributesAndUnrepresentableTimestamps() throws {
        let raw = #"<p title="Chapter 1:12">1:12 <a href="https://example.test/1:12">1:12</a> 99999999999999999999999:00</p>"#
        let html = try ShownotesFormatter.format(raw, durationMilliseconds: 120000, noShownotesLabel: "empty", style: style)
        let document = try SwiftSoup.parse(html)
        #expect(try document.select("p").first()?.attr("title") == "Chapter 1:12")
        #expect(try document.select("a").map { try $0.attr("href") } == ["antennapod://timecode/72000", "https://example.test/1:12"])
        #expect(try document.text().contains("99999999999999999999999:00"))
    }

    @Test func localizedEmptyTextCannotBecomeMarkup() throws {
        let html = try ShownotesFormatter.format(nil, durationMilliseconds: .max, noShownotesLabel: "None <&> مرحبا", style: style)
        #expect(try SwiftSoup.parse(html).select("#apNoShownotes").text() == "None <&> مرحبا")
    }

    @Test func mobileViewportKeepsPublisherContentAndStylePriority() throws {
        let raw = "<head><meta name='viewport' content='width=980'><style>body {font-size:20px}</style></head><body><p>Notes</p></body>"
        let result = try ShownotesFormatter.webKitDocument(raw, defaultFontCSS: "body {font-size:16px}")
        let document = try SwiftSoup.parse(result)
        #expect(try document.select("meta[name=viewport]").size() == 1)
        #expect(try document.select("meta[name=viewport]").attr("content") == "width=device-width, initial-scale=1")
        #expect(try document.select("style").map { try $0.html() } == ["body {font-size:16px}", "body {font-size:20px}"])
        #expect(try document.select("p").text() == "Notes")
    }

    /// The large font CSS joins after serialisation; the page WebKit receives is unchanged.
    @Test func leadingCSSGivesTheSameDocumentWithoutParsingIt() throws {
        let font = "@font-face { font-family: F; src: url(data:font/ttf;base64,\(String(repeating: "QUJD", count: 5_000))); }"
        let rest = " :root { --a: red; } img { x: y; }"
        for raw in ["<p>Notes /*ap-leading-css*/ 1:00</p>", "<head><meta name='viewport' content='width=980'><style>b {}</style></head><body>x</body>",
                    "", "Plain\ntext", "<html><head><title>T</title></head><body><img src='//example.test/a.png'></body></html>"] {
            let html = try ShownotesFormatter.format(raw, durationMilliseconds: 120_000, noShownotesLabel: "None", style: style)
            #expect(try ShownotesFormatter.webKitDocument(html, defaultFontCSS: rest, leadingCSS: font)
                    == ShownotesFormatter.webKitDocument(html, defaultFontCSS: font + rest))
        }
    }
}
