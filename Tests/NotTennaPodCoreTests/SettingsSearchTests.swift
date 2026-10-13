import Foundation
import Testing
@testable import NotTennaPodCore

/// Settings search against the independent oracle: written from the
/// pinned Android source, identical to the real lib.preferencesearch 2.7.3 bytecode on 4,048 queries and to the
/// compiled 3.12.1 APK's XMLs and strings; it shares no code with Swift. The app's English strings are read from
/// its Localizable.strings, so a wrong key or text fails here too.
@Suite struct SettingsSearchTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized
    static let english = Locale(identifier: "en_US")

    private func oracle() throws -> [String: Any] {
        let url = Self.root.appendingPathComponent("TestSupport/Data/settings-search/expected/settings-search.json")
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    /// The app's English strings with NotTennaPod's rename undone, so the oracle comparison stays
    /// exact for every other character and score. `NotTennaPodNamingTests` checks the rename itself.
    private func strings() throws -> [String: String] {
        let url = Self.root.appendingPathComponent("App/Resources/en.lproj/Localizable.strings")
        let strings = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
        return strings.mapValues {
            $0.replacingOccurrences(of: "independent of NotTennaPod", with: "independent of the AntennaPod project")
                .replacingOccurrences(of: "NotTennaPod", with: "AntennaPod")
        }
    }
    private func resolved(_ entries: [SettingsSearch.Entry]) throws -> [SettingsSearch.Item] {
        let strings = try strings()
        return SettingsSearch.resolve(entries) { strings[$0] ?? "<missing \($0)>" }
    }
    private func androidIndex() throws -> [[String: Any]] {
        try #require(try oracle()["android_index"] as? [[String: Any]])
    }

    @Test func androidIndexEqualsTheSourceIndex() throws {
        let expected = try androidIndex()
        let items = try resolved(SettingsSearch.index)
        #expect(items.count == expected.count && items.count == 70)
        for (item, row) in zip(items, expected) {
            let label = "\(row["file"] ?? "") \(row["key"] ?? "")"
            #expect(item.entry.screen.rawValue == row["file"] as? String, "\(label)")
            #expect(item.entry.key == row["key"] as? String, "\(label)")
            #expect(item.title == row["title"] as? String, "\(label)")
            #expect(item.summary == row["summary"] as? String, "\(label)")
            #expect(item.entries == row["entries"] as? String, "\(label)")
            #expect(item.breadcrumbs == row["breadcrumbs"] as? String, "\(label)")
            #expect(item.keywords == row["keywords"] as? String, "\(label)")
            #expect(item.info == row["info"] as? String, "\(label)")
        }
    }

    /// Only the nine source XMLs are searched, in `setupSearch` order with its breadcrumbs; the root, About and
    /// Automatic deletion screens are not (so neither Project rows nor the auto-deletion switches are results).
    @Test func indexedAndExcludedFilesFollowSetupSearch() throws {
        let config = try #require(try oracle()["config"] as? [String: Any])
        let files = try #require(config["indexed_files"] as? [[String: Any]])
        #expect(SettingsSearch.Screen.allCases.map(\.rawValue) == files.compactMap { $0["xml"] as? String })
        let strings = try strings()
        for (screen, file) in zip(SettingsSearch.Screen.allCases, files) {
            #expect(screen.breadcrumbKeys.compactMap { strings[$0] }.joined(separator: " > ") == file["breadcrumb"] as? String)
        }
        let excluded = try #require(config["excluded_xmls"] as? [[String: Any]]).compactMap { $0["xml"] as? String }
        #expect(excluded == ["preferences", "preferences_about", "preferences_auto_deletion"])
        let keys = Set(SettingsSearch.index.map(\.key))
        for absent in ["searchPreference", "prefScreenInterface", "notifications", "prefAbout", "prefSendBugReport",
                       "about_contributors", "prefAutoDelete", "prefAutoDeleteLocal", "prefFavoriteKeepsEpisode",
                       "prefEpisodeCleanup", "prefExpandNotify", "prefUnpauseOnHeadsetReconnect", "prefAutoDownloadSettings", "prefTheme"] {
            #expect(!keys.contains(absent), "\(absent)")
        }
    }

    @Test func iosIndexOmitsRowsItsScreensDoNotShow() throws {
        let android = try androidIndex()
        let positions = try #require(try oracle()["ios_index_positions"] as? [String: [Int]])
        let none = try #require(positions["none"]), gpodder = try #require(positions["gpodder"])
        #expect(SettingsSearch.visibleIndex(gpodderSelected: false).map(\.key) == none.map { android[$0]["key"] as? String })
        #expect(SettingsSearch.visibleIndex(gpodderSelected: true).map(\.key) == gpodder.map { android[$0]["key"] as? String })
        let visible = Set(SettingsSearch.visibleIndex(gpodderSelected: true).map(\.key))
        for hidden in ["prefTintedColors", "prefChooseDataDir", "prefPersistNotify"] { #expect(!visible.contains(hidden)) }
    }

    @Test func resultActionsFollowPreferenceActivity() throws {
        let handler = try #require((try oracle()["config"] as? [String: Any])?["result_handler"] as? [String: Any])
        let dialog = try #require((handler["dialog"] as? [String: Any])?["xml"] as? String)
        let plain = try #require(handler["open_without_highlight"] as? [String])
        for screen in SettingsSearch.Screen.allCases {
            let expected: SettingsSearch.Action = screen.rawValue == dialog ? .podcastSettingsDialog
                : plain.contains(screen.rawValue) ? .open : .openAndHighlight
            #expect(screen.action == expected, "\(screen)")
        }
        #expect(SettingsSearch.Screen.automaticDownload.titleKey == "pref_automatic_download_title")
    }

    /// Fifteen source-derived queries: every result (title, summary, breadcrumbs, order and score) on the Android
    /// index and on the iOS index without and with gpodder.net selected.
    @Test func namedQueriesGiveTheOracleResults() throws {
        let named = try #require(try oracle()["named_queries"] as? [[String: Any]])
        #expect(named.count == 15)
        let android = try resolved(SettingsSearch.index)
        let ios = try resolved(SettingsSearch.visibleIndex(gpodderSelected: false))
        let gpodder = try resolved(SettingsSearch.visibleIndex(gpodderSelected: true))
        for query in named {
            let text = try #require(query["query"] as? String)
            for (index, name) in [(android, "android"), (ios, "ios"), (gpodder, "ios_gpodder")] {
                let expected = try #require(query[name] as? [[String: Any]])
                let results = SettingsSearch.search(text, in: index, locale: Self.english)
                #expect(results.map(\.entry.key) == expected.map { $0["key"] as? String }, "\(name) '\(text)'")
                for (item, row) in zip(results, expected) {
                    #expect(item.title == row["title"] as? String && item.summary == row["summary"] as? String
                            && item.breadcrumbs == row["breadcrumbs"] as? String, "\(name) '\(text)' \(item.entry.key)")
                    let score = SettingsSearch.score(item, query: text, locale: Self.english)
                    #expect(Double(score) == row["score"] as? Double, "\(name) '\(text)' \(item.entry.key)")
                }
            }
        }
        // The two acceptance queries, as a person reads them.
        let black = SettingsSearch.search("black", in: ios, locale: Self.english)
        #expect(black.first?.title == "Full black" && black.first?.breadcrumbs == "User interface > Theming")
        let speed = SettingsSearch.search("speed", in: ios, locale: Self.english).prefix(2)
        #expect(speed.map(\.title) == ["Playback speed", "Playback speed"])
        #expect(speed.map(\.breadcrumbs) == ["Playback > Playback control", "Podcast settings > Playback"])
        #expect(SettingsSearch.search("jjj", in: ios, locale: Self.english).isEmpty)
        #expect(SettingsSearch.search("", in: ios, locale: Self.english).isEmpty)
    }

    /// 541 generated queries (title words and prefixes, letters, seeded random strings, punctuation, accents):
    /// the same results in the same order as the oracle on both indexes.
    @Test func generatedQueryMatrixMatchesTheOracle() throws {
        let matrix = try #require(try oracle()["matrix"] as? [String: Any])
        let queries = try #require(matrix["queries"] as? [String])
        let androidExpected = try #require(matrix["android"] as? [[Int]]), iosExpected = try #require(matrix["ios"] as? [[Int]])
        let keys = try androidIndex().map { $0["key"] as? String }
        let android = try resolved(SettingsSearch.index)
        let ios = try resolved(SettingsSearch.visibleIndex(gpodderSelected: false))
        var mismatches: [String] = []
        for (query, (a, i)) in zip(queries, zip(androidExpected, iosExpected)) {
            if SettingsSearch.search(query, in: android, locale: Self.english).map(\.entry.key) != a.map({ keys[$0] }) { mismatches.append("android '\(query)'") }
            if SettingsSearch.search(query, in: ios, locale: Self.english).map(\.entry.key) != i.map({ keys[$0] }) { mismatches.append("ios '\(query)'") }
        }
        #expect(queries.count == 541)
        #expect(mismatches.isEmpty, "\(mismatches.prefix(20))")
    }

    @Test func resultRowsNeverShowARawFormatPlaceholder() throws {
        let items = try resolved(SettingsSearch.visibleIndex(gpodderSelected: true))
        let volume = try #require(items.first { $0.entry.key == "volumeReduction" })
        #expect(volume.summary == "Turn volume for episodes of this podcast up or down: %1$s", "searched as Android indexes it")
        #expect(volume.displaySummary == "Turn volume for episodes of this podcast up or down")
        for item in items { #expect(!(item.displaySummary ?? "").contains("%"), "\(item.entry.key)") }
        #expect(SettingsSearch.androidFormat("a %@ b %d c %1$@ 100%%") == "a %1$s b %2$d c %1$s 100%%")
    }

    @Test func searchScreenTextsAreAndroids() throws {
        let expected = try #require(try oracle()["strings"] as? [String: String])
        let strings = try strings()
        for (key, value) in expected { #expect(strings[key] == value, "\(key)") }
    }

    /// `SearchPreferenceFragment.addHistoryEntry`: newest first, five at most, a known title is neither added
    /// nor moved; Clear history empties it; the history survives a relaunch.
    @MainActor @Test func historyKeepsTheFiveNewestDistinctTitles() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("M33History-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = try SettingsSearchHistoryStore(file: file)
        #expect(store.terms.isEmpty)
        for term in ["Full black", "Playback speed", "Proxy"] { try store.add(term) }
        #expect(store.terms == ["Proxy", "Playback speed", "Full black"])
        try store.add("Full black")
        #expect(store.terms == ["Proxy", "Playback speed", "Full black"], "a known title stays where it is")
        for term in ["Queue", "Logout", "Tags"] { try store.add(term) }
        #expect(store.terms == ["Tags", "Logout", "Queue", "Proxy", "Playback speed"])
        #expect(try SettingsSearchHistoryStore(file: file).terms == store.terms, "kept across launches")
        try store.clear()
        #expect(try store.terms.isEmpty && SettingsSearchHistoryStore(file: file).terms.isEmpty)
    }
}
