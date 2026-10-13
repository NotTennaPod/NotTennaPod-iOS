import Foundation
import Testing
@testable import NotTennaPodCore

/// Settings root composition against the independent oracle (written from the pinned Android source and
/// cross-checked with real Java `String.hashCode()` and the emulator capture; it shares no code with Swift).
@Suite struct SettingsRootCompositionTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized
    static let fixtures = root.appendingPathComponent("TestSupport/Data/project-about")

    private func json(_ path: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtures.appendingPathComponent(path))) as? [String: Any])
    }

    /// English strings the app displays, resolved independently of the app bundle.
    private func strings() throws -> [String: String] {
        let url = Self.root.appendingPathComponent("App/Resources/en.lproj/Localizable.strings")
        return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    }

    private func oracleCase(_ package: String) throws -> [String: Any] {
        let cases = try #require(try json("expected/settings-root.json")["cases"] as? [[String: Any]])
        return try #require(cases.first { $0["package"] as? String == package })
    }

    @Test func rowsMatchOracleInOrderWithTitlesSummariesAndIcons() throws {
        let strings = try strings()
        let cases = try #require(try json("expected/settings-root.json")["cases"] as? [[String: Any]])
        #expect(cases.count == 7)
        for expected in cases {
            let package = try #require(expected["package"] as? String)
            let oracleRows = try #require(expected["rows"] as? [[String: Any]])
            let rows = SettingsRootComposition.rows(forPackage: package)
            #expect(rows.count == oracleRows.count, "\(package)")
            for (row, oracle) in zip(rows, oracleRows) {
                #expect(row.kind.rawValue == oracle["kind"] as? String, "\(package) \(oracle)")
                #expect(row.key == oracle["key"] as? String, "\(package) \(oracle)")
                #expect(row.icon == oracle["icon"] as? String, "\(package) \(oracle)")
                #expect(row.category == oracle["in_category"] as? String, "\(package) \(oracle)")
                #expect(row.titleKey.flatMap { strings[$0] } == oracle["title"] as? String, "\(package) \(oracle)")
                let summary = row.text ?? row.summaryKey.flatMap { strings[$0] }
                #expect(summary == oracle["summary"] as? String, "\(package) \(oracle)")
                if let filter = oracle["icon_color_filter"] as? [String: Any] {
                    #expect(filter["color"] as? String == String(format: "#%06X", SettingsRootComposition.noticeColor))
                    #expect(filter["mode"] as? String == "MULTIPLY")
                }
            }
            let reachable = Set(rows.compactMap(\.key)).intersection(["prefDocumentation", "prefViewForum", "prefContribute", "prefSendBugReport", "prefAbout"])
            #expect(reachable == Set(expected["reachable_project_rows"] as? [String] ?? []), "\(package)")
        }
    }

    @Test func applicationIsUnofficialInEveryConfiguration() throws {
        let spec = try String(contentsOf: Self.root.appendingPathComponent("project.yml"), encoding: .utf8)
        let identifiers = spec.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "PRODUCT_BUNDLE_IDENTIFIER" else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        // App extensions (the Share Extension) must carry the app's identifier as a prefix; only the
        // application itself is a package whose identifier selects the Settings composition.
        let applications = identifiers.filter { !$0.hasPrefix("org.nottennapod.app.") }
        #expect(applications == ["org.nottennapod.app"])
        #expect(identifiers.allSatisfy { $0 == "org.nottennapod.app" || $0.hasPrefix("org.nottennapod.app.") })
        for identifier in applications { #expect(SettingsRootComposition.branch(forPackage: identifier) == .unofficial) }

        // Any non-official package takes Android's unofficial branch; the oracle records it for the old iOS identifier.
        let oracle = try oracleCase("org.antennapod.swift")
        #expect(oracle["branch"] as? String == "unofficial")
        // Android's unofficial composition with two NotTennaPod changes: the Project category
        // holds only About (NotTennaPod's own page; the other Project rows lead to AntennaPod), and the notice names NotTennaPod.
        let android = SettingsRootComposition.rows(forPackage: "org.nottennapod.app")
        let application = SettingsRootComposition.application
        #expect(Array(application.prefix(android.count - 1)) == Array(android.dropLast()))
        #expect(application.dropFirst(android.count - 1).map(\.key) == ["project", "prefAbout", nil])
        #expect(android.last?.text == SettingsRootComposition.androidSpinOffNotice)
        let strings = try strings()
        let visible = application.map { $0.text ?? $0.titleKey.flatMap { strings[$0] } ?? $0.summaryKey.flatMap { strings[$0] } }
        var expected = try #require(oracle["row_titles_or_text"] as? [String])
        #expect(expected.last == SettingsRootComposition.androidSpinOffNotice)
        expected[expected.count - 1] = SettingsRootComposition.spinOffNotice
        expected.insert(contentsOf: ["Project", "About"], at: expected.count - 1)
        #expect(visible == expected)
        #expect(!SettingsRootComposition.spinOffNotice.contains("violate"))
        // The notice is last; About is the only Project row; the debug notice never appears.
        #expect(application.last?.text == SettingsRootComposition.spinOffNotice)
        #expect(application.filter { $0.category == "project" }.map(\.key) == ["prefAbout"])
        #expect(!application.contains { $0.text == SettingsRootComposition.developmentNotice })
    }

    /// No rating prompt. Android's free flavor never shows one (RatingDialogManager:37),
    /// so no review/rating component may be compiled into the app.
    @Test func noRatingPromptIsCompiledIntoTheApp() throws {
        let forbidden = ["SKStoreReviewController", "requestReview", "RequestReviewAction", "AppStore.requestReview",
                         "rating_tagline", "rating_contribute", "rating_volunteers", "rating_rate", "rating_later",
                         "RatingDialog", "RatingPrefs", "Rate AntennaPod"]
        var files: [URL] = []
        for directory in ["App", "Sources"] {
            let enumerator = FileManager.default.enumerator(at: Self.root.appendingPathComponent(directory), includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                if ["swift", "m", "mm", "h", "strings", "stringsdict", "json", "plist"].contains(url.pathExtension) { files.append(url) }
            }
        }
        #expect(files.count > 50)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden { #expect(!text.contains(token), "\(file.lastPathComponent) contains \(token)") }
        }
    }
}
