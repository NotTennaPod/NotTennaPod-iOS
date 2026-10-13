import Foundation
import Testing
@testable import NotTennaPodCore

/// NotTennaPod: the app calls itself NotTennaPod everywhere a person reads its name, and nothing it
/// shares or exports points to AntennaPod. AntennaPod is named only where the app says it is not AntennaPod.
@Suite struct NotTennaPodNamingTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized

    @Test func appTextsNameNotTennaPod() throws {
        let url = Self.root.appendingPathComponent("App/Resources/en.lproj/Localizable.strings")
        let strings = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
        let statement = ["about_nottennapod_title", "about_nottennapod_message"]
        for (key, value) in strings where !statement.contains(key) {
            #expect(!value.contains("AntennaPod") || value.contains("NotTennaPod") && !value.replacingOccurrences(of: "NotTennaPod", with: "").contains("AntennaPod"),
                    "\(key): \(value)")
        }
        #expect(strings["home_welcome_title"] == "Welcome to NotTennaPod!")
        #expect(strings["about_nottennapod_title"] == "NotTennaPod is not AntennaPod")
        #expect(strings["about_nottennapod_message"]?.contains("has nothing to do with NotTennaPod") == true)
        #expect(strings["about_nottennapod_message"]?.contains("best podcast app ever made") == true)
    }

    @Test func sharedAndExportedTextsNameNotTennaPod() throws {
        #expect(HTTPUserAgent.application(version: "1.2.3") == "NotTennaPod/1.2.3")
        #expect(!HTTPUserAgent.search.contains("AntennaPod") && !HTTPUserAgent.proxyTest.contains("AntennaPod"))
        let share = FeedShareText.make(title: "Show", source: "https://example.com/feed.xml")
        #expect(share == "Show\n\nhttps://example.com/feed.xml")
        let html = String(decoding: HTMLExportWriter.subscriptions([]), as: UTF8.self)
        #expect(html.contains("<title>NotTennaPod Subscriptions</title>") && html.contains("<h1>NotTennaPod Subscriptions</h1>"))
        #expect(!html.contains("antennapod.org") && !html.contains("play.google.com") && !html.contains("AntennaPod"))
        let opml = String(decoding: try OPMLExportWriter.data(for: [LibraryFeed](), createdAt: Date(timeIntervalSince1970: 0), timeZone: .gmt), as: UTF8.self)
        #expect(opml.contains("<title>NotTennaPod Subscriptions</title>") && !opml.contains("AntennaPod"))
        #expect(SettingsRootComposition.spinOffNotice.hasPrefix("NotTennaPod is not AntennaPod"))
        #expect(SettingsRootComposition.application.contains { $0.key == "prefAbout" })
        #expect(!SettingsRootComposition.application.contains {
            ["prefDocumentation", "prefViewForum", "prefContribute", "prefSendBugReport"].contains($0.key ?? "")
        })
    }
}
