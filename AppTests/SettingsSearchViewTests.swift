import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Mounted Settings search: the root search card
/// opens the search page; results show title, summary and breadcrumbs in the oracle's order; a result opens its page
/// with the row on screen and briefly tinted, a podcast setting explains itself in a dialog, Notifications opens
/// without a tint; history, Clear and Clear history; hidden rows never appear; nothing clipped at any width or in RTL.
/// Expected texts and orders are the oracle's (Android 3.12.1), not read back from the app.
@MainActor @Suite(.serialized)
struct SettingsSearchViewTests {
    private func find<T: UIView>(_ id: String, _ view: UIView, as: T.Type = T.self) -> T? { settingsSearchFind(id, view, as: T.self) }
    private func all<T: UIView>(_ view: UIView, _ type: T.Type) -> [T] { settingsSearchAll(view, T.self) }
    private func png(_ image: UIImage?) -> Data? {
        guard let image else { return nil }
        return UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(at: .zero) }.pngData()
    }
    private func wait(_ timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool,
                      sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), sourceLocation: sourceLocation)
    }
    private func tap(_ id: String, _ view: UIView, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let control: UIControl = try #require(find(id, view), "Missing \(id)", sourceLocation: sourceLocation)
        control.sendActions(for: .touchUpInside)
        view.layoutIfNeeded()
    }

    @MainActor struct Screen {
        let controller: LibraryViewController
        let host: ViewTestWindowHost
        let history: SettingsSearchHistoryStore
        var title: String? { settingsSearchFind("screenTitle", controller.view, as: UILabel.self)?.text }
        func find<T: UIView>(_ id: String, as: T.Type = T.self) -> T? { settingsSearchFind(id, controller.view, as: T.self) }
        var search: SettingsSearchView? { settingsSearchAll(controller.view, SettingsSearchView.self).first }
    }

    private func withSettings(history terms: [String] = [], _ body: @MainActor (Screen) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsSearchView-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let navigation = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
        let downloads = try DownloadPreferenceStore(file: root.appendingPathComponent("downloads.json"))
        let automatic = try AutomaticDownloadPreferenceStore(file: root.appendingPathComponent("automatic.json"))
        let history = try SettingsSearchHistoryStore(file: root.appendingPathComponent("settings-search-history.json"))
        for term in terms.reversed() { try history.add(term) }
        let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil, mobileNetworkPreferences: nil,
            usage: nil, automaticDownloadPreferences: automatic, downloadPreferences: downloads)
        controller.settingsSearchHistory = history
        controller.interfacePreferences = try InterfacePreferenceStore(file: root.appendingPathComponent("interface.json"))
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            controller.view.frame = host.view.bounds
            defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
            try tap("navigationMore", controller.view)
            let settings = try #require(all(controller.view, UIControl.self).first { $0.accessibilityLabel == "Settings" })
            settings.sendActions(for: .touchUpInside)
            controller.view.layoutIfNeeded()
            try await body(Screen(controller: controller, host: host, history: history))
        }
        try await store.close()
    }

    /// Opens the page from the root's search card and types `query` as the keyboard would.
    private func openSearch(_ screen: Screen, _ query: String? = nil) async throws -> SettingsSearchView {
        if screen.search == nil { try tap("searchPreference", screen.controller.view) }
        let search = try #require(screen.search)
        if let query { search.field.text = query; search.field.sendActions(for: .editingChanged) }
        screen.controller.view.layoutIfNeeded(); search.layoutIfNeeded()
        return search
    }
    private func results(_ search: SettingsSearchView) -> [SettingsSearchRow] {
        all(search, SettingsSearchRow.self).filter { $0.accessibilityIdentifier?.hasPrefix("settingsSearchResult-") == true }
            .sorted { $0.frame.minY < $1.frame.minY }
    }
    private func historyRows(_ search: SettingsSearchView) -> [SettingsSearchRow] {
        all(search, SettingsSearchRow.self).filter { $0.accessibilityIdentifier?.hasPrefix("settingsSearchHistory-") == true }
            .sorted { $0.frame.minY < $1.frame.minY }
    }
    /// What a person sees in a result row, top to bottom.
    private func texts(_ row: UIView) -> [String] {
        all(row, UILabel.self).filter { !$0.isHidden }.sorted { $0.frame.minY < $1.frame.minY }.compactMap(\.text)
    }
    /// The row is entirely inside the visible part of the page.
    private func onScreen(_ row: UIView, _ controller: LibraryViewController) -> Bool {
        let frame = row.convert(row.bounds, to: controller.content)
        let visible = CGRect(origin: controller.content.contentOffset, size: controller.content.bounds.size)
        return visible.insetBy(dx: -0.5, dy: -0.5).contains(frame)
    }
    private func tint(_ row: UIView) -> UIView? { row.subviews.first { $0.accessibilityIdentifier == "settingsSearchHighlight" } }

    @Test func searchCardOpensThePageWithFocusAndNoResultsWhileHistoryIsEmpty() async throws {
        try await withSettings { screen in
            let card: UIControl = try #require(screen.find("searchPreference"))
            #expect(card.accessibilityLabel == "Search…" && card.accessibilityTraits.contains(.button))
            let first: UIControl = try #require(screen.find("prefScreenInterface"))
            #expect(card.frame.maxY <= first.frame.minY + 0.5, "search card first")
            let search = try await openSearch(screen)
            #expect(screen.title == "Settings", "the toolbar keeps Settings")
            #expect(screen.find("toolbarBack", as: UIButton.self) != nil)
            #expect(search.field.placeholder == "Search…" && (search.field.text ?? "").isEmpty)
            try await wait { search.field.isFirstResponder }
            // SearchPreferenceFragment.showHistory with no history: the "No results" text.
            let noResults: UILabel = try #require(find("settingsSearchNoResults", search))
            #expect(!noResults.isHidden && noResults.text == "No results")
            #expect(search.card.clear?.isHidden == true, "Clear appears only with text")
            #expect(search.card.more?.isHidden == false && search.card.more?.accessibilityLabel == "More")
            try tap("toolbarBack", screen.controller.view)
            #expect(screen.search == nil && screen.find("prefScreenInterface", as: UIControl.self) != nil, "Back returns to Settings")
        }
    }

    /// "black" shows Full black first; it opens User interface with the row on screen and tinted for
    /// about a second; Back returns to the same results; the title joins the history.
    @Test func blackOpensFullBlackOnUserInterfaceHighlighted() async throws {
        try await withSettings { screen in
            let search = try await openSearch(screen, "black")
            let rows = results(search)
            #expect(rows.count == 10)
            #expect(texts(rows[0]) == ["Full black", "Use full black for the dark theme", "User interface > Theming"])
            // VoiceOver: title, then where it is, then the description.
            #expect(rows[0].accessibilityLabel == "Full black" && rows[0].accessibilityValue == "User interface > Theming"
                    && rows[0].accessibilityHint == "Use full black for the dark theme" && rows[0].accessibilityTraits.contains(.button))
            rows[0].sendActions(for: .touchUpInside)
            screen.controller.view.layoutIfNeeded()
            #expect(screen.title == "User interface")
            let row: UIControl = try #require(screen.find("prefThemeBlack"))
            #expect(onScreen(row, screen.controller), "navigation lands on the row")
            try await wait { tint(row) != nil }
            let color = try #require(tint(row)?.backgroundColor)
            var alpha: CGFloat = 0; color.getWhite(nil, alpha: &alpha)
            #expect(abs(alpha - 0.2) < 0.01, "20 % of the primary text colour")
            try await wait(.seconds(3)) { tint(row) == nil }
            #expect(screen.history.terms == ["Full black"])
            try tap("toolbarBack", screen.controller.view)
            let back = try #require(screen.search)
            #expect(back.field.text == "black" && texts(results(back)[0]).first == "Full black", "Back keeps the query and results")
        }
    }

    /// "speed" shows the global and the podcast Playback speed with their breadcrumbs; the podcast one
    /// explains in a dialog; the global one opens Playback at the row.
    @Test func speedShowsGlobalAndPodcastResults() async throws {
        try await withSettings { screen in
            let search = try await openSearch(screen, "speed")
            let rows = results(search)
            #expect(texts(rows[0]) == ["Playback speed", "Customize the speeds available for variable speed playback",
                                       "Playback > Playback control"])
            #expect(texts(rows[1]) == ["Playback speed", "The speed to use when starting audio playback for episodes in this podcast",
                                       "Podcast settings > Playback"])
            #expect(rows.map { $0.accessibilityLabel ?? "" } == ["Playback speed", "Playback speed", "Adjust media info to playback speed",
                "Default page", "Swipe actions", "Show remaining time", "Smart mark as played", "Favorites export", "Auto skip",
                "Volume adaptation"], "oracle order; Persistent playback controls is hidden on iOS")
            rows[1].sendActions(for: .touchUpInside)
            try await wait { screen.controller.presentedViewController is SourceMessageController }
            let dialog = try #require(screen.controller.presentedViewController)
            dialog.view.layoutIfNeeded()
            let words = all(dialog.view, UILabel.self).compactMap(\.text)
            #expect(words.contains("Podcast settings"))
            #expect(words.contains { $0.hasPrefix("This setting is unique to each podcast. You can change it by opening the podcast page.") })
            try tap("sourceMessageOK", dialog.view)
            try await wait { screen.controller.presentedViewController == nil }
            #expect(screen.search != nil && screen.title == "Settings", "the dialog leaves the search page in place")
            results(try #require(screen.search))[0].sendActions(for: .touchUpInside)
            screen.controller.view.layoutIfNeeded()
            #expect(screen.title == "Playback")
            let row: UIControl = try #require(screen.find("prefPlaybackSpeedLauncher"))
            #expect(onScreen(row, screen.controller))
            try await wait { tint(row) != nil }
            #expect(screen.history.terms == ["Playback speed"], "a title is kept once")
        }
    }

    /// A row low on a long page is scrolled into view; Automatic download opens on its own page (not Downloads);
    /// Notifications opens without a tint (`PreferenceActivity.onSearchResultClicked`).
    @Test func resultsOpenTheirOwnPages() async throws {
        try await withSettings { screen in
            screen.controller.view.frame.size.height = 500; screen.controller.view.layoutIfNeeded()
            var search = try await openSearch(screen, "keep skipped episodes")
            results(search)[0].sendActions(for: .touchUpInside); screen.controller.view.layoutIfNeeded()
            #expect(screen.title == "Playback")
            let skip: UIControl = try #require(screen.find("prefSkipKeepsEpisode"))
            #expect(screen.controller.content.contentOffset.y > 0 && onScreen(skip, screen.controller), "scrolled to the last Playback row")
            try tap("toolbarBack", screen.controller.view)

            search = try await openSearch(screen, "download when not charging")
            #expect(texts(results(search)[0]).last == "Downloads > Automation > Automatic download")
            results(search)[0].sendActions(for: .touchUpInside); screen.controller.view.layoutIfNeeded()
            #expect(screen.title == "Automatic download")
            let battery: UIControl = try #require(screen.find("prefEnableAutoDownloadOnBattery"))
            try await wait { tint(battery) != nil }
            try tap("toolbarBack", screen.controller.view)
            #expect(screen.search != nil, "Back returns to the search page, not Downloads")

            search = try await openSearch(screen, "download failed")
            let failed = try #require(results(search).first { $0.accessibilityLabel == "Download failed" })
            #expect(texts(failed).last == "Notifications > Errors")
            failed.sendActions(for: .touchUpInside); screen.controller.view.layoutIfNeeded()
            #expect(screen.title == "Notifications")
            let row: UIView = try #require(screen.find("prefShowDownloadReport"))
            try await Task.sleep(for: .milliseconds(600))
            #expect(tint(row) == nil, "Notifications rows are not highlighted")
            try tap("toolbarBack", screen.controller.view)

            search = try await openSearch(screen, "opml import")
            results(search)[0].sendActions(for: .touchUpInside); screen.controller.view.layoutIfNeeded()
            #expect(screen.title == "Backup & restore")
            let opml: UIView = try #require(screen.find("opmlImportPreference"))
            try await wait { tint(opml) != nil }
        }
    }

    /// Dynamic colors, Persistent playback controls and Choose data folder are not on the iOS pages, so they are
    /// never results; the rest of Android's order is kept (the next row moves up).
    @Test func rowsIOSDoesNotShowAreNeverResults() async throws {
        try await withSettings { screen in
            let search = try await openSearch(screen)
            for query in ["dynamic", "persistent", "data folder", "Dynamic colors", "tinted"] {
                search.field.text = query; search.field.sendActions(for: .editingChanged); search.layoutIfNeeded()
                let titles = results(search).compactMap(\.accessibilityLabel)
                #expect(!titles.contains("Dynamic colors") && !titles.contains("Persistent playback controls")
                        && !titles.contains("Choose data folder"), "\(query): \(titles)")
            }
            search.field.text = "download"; search.field.sendActions(for: .editingChanged); search.layoutIfNeeded()
            #expect(results(search).compactMap(\.accessibilityLabel) == ["Download queued", "Download when not charging",
                "Download failed", "Downloads", "Play from downloads screen", "Enqueue downloaded", "Proxy", "Automatic download",
                "Prefer streaming", "Episode limit"], "Choose data folder (Android's tenth) is hidden; the eleventh moves up")
            search.field.text = "jjj"; search.field.sendActions(for: .editingChanged); search.layoutIfNeeded()
            #expect(results(search).isEmpty && find("settingsSearchNoResults", search, as: UILabel.self)?.isHidden == false)
        }
    }

    /// Rotation or a window resize re-renders the screen: the query, the results and the keyboard stay (Android keeps
    /// the field's text and recomputes the list).
    @Test func resizeKeepsQueryResultsAndKeyboard() async throws {
        try await withSettings { screen in
            let search = try await openSearch(screen, "black")
            try await wait { search.field.isFirstResponder }
            let size = screen.controller.view.frame.size
            for frame in [CGRect(x: 0, y: 0, width: size.height, height: size.width), CGRect(origin: .zero, size: size)] {
                screen.controller.view.frame = frame; screen.controller.view.layoutIfNeeded(); search.layoutIfNeeded()
                #expect(screen.search === search && search.field.text == "black")
                #expect(results(search).first?.accessibilityLabel == "Full black" && results(search).count == 10)
                #expect(search.field.isFirstResponder, "the keyboard stays up")
                #expect(search.frame.width == screen.controller.content.bounds.width)
            }
        }
    }

    /// History newest first with its icon; a history row searches its term; Clear empties the field and shows the
    /// history again; More → Clear history empties it.
    @Test func historyClearAndClearHistory() async throws {
        try await withSettings(history: ["Proxy", "Full black"]) { screen in
            let search = try await openSearch(screen)
            var rows = historyRows(search)
            #expect(rows.map { texts($0) } == [["Proxy"], ["Full black"]])
            #expect(rows.allSatisfy { row in all(row, UIImageView.self).contains { png($0.image) == png(UIImage(named: "ic_history")) } })
            #expect(find("settingsSearchNoResults", search, as: UILabel.self)?.isHidden == true)
            rows[1].sendActions(for: .touchUpInside); search.layoutIfNeeded()
            #expect(search.field.text == "Full black" && results(search).first?.accessibilityLabel == "Full black")
            #expect(search.card.clear?.isHidden == false)
            try tap("settingsSearchClear", search)
            #expect((search.field.text ?? "").isEmpty && historyRows(search).count == 2 && results(search).isEmpty)
            try tap("settingsSearchMore", search)
            try await wait { screen.controller.presentedViewController is PopupMenuController }
            let menu = try #require(screen.controller.presentedViewController)
            menu.view.layoutIfNeeded()
            let clear: UIButton = try #require(find("settingsSearchClearHistory", menu.view))
            #expect(clear.title(for: .normal) == "Clear history")
            clear.sendActions(for: .touchUpInside)
            try await wait { screen.controller.presentedViewController == nil && historyRows(search).isEmpty }
            rows = historyRows(search)
            #expect(screen.history.terms.isEmpty && find("settingsSearchNoResults", search, as: UILabel.self)?.isHidden == false)
        }
    }

    /// The card, the field and every result stay inside the page and do not overlap, on phone and tablet widths
    /// and right-to-left (the search glyph leads, More trails).
    @Test func layoutHoldsAtEveryWidthAndRightToLeft() async throws {
        try await withSettings { screen in
            for rtl in [false, true] {
                if rtl { screen.controller.traitOverrides.layoutDirection = .rightToLeft }
                for width in [320, screen.host.view.bounds.width, 744, 1366] as [CGFloat] {
                    screen.controller.view.frame = CGRect(x: 0, y: 0, width: width, height: max(screen.host.view.bounds.height, 600))
                    screen.controller.view.layoutIfNeeded()
                    let label = "\(rtl ? "RTL" : "LTR") \(width)"
                    // The root card.
                    if screen.search == nil {
                        let card: UIControl = try #require(screen.find("searchPreference"), "\(label)")
                        let inner = try #require(all(card, SettingsSearchCard.self).first)
                        #expect(inner.frame.minX >= 7.5 && inner.frame.maxX <= card.bounds.width - 7.5, "\(label)")
                        let hint = try #require(inner.hint)
                        #expect(rtl ? inner.icon.frame.minX > hint.frame.maxX - 0.5 : inner.icon.frame.maxX < hint.frame.minX + 0.5, "\(label)")
                    }
                    let search = try await openSearch(screen, "playback")
                    search.layoutIfNeeded(); search.card.layoutIfNeeded()
                    let card = search.card
                    #expect(card.frame.minX >= 7.5 && card.frame.maxX <= search.bounds.width - 7.5 && card.frame.height == 48, "\(label)")
                    let field = search.field, icon = card.icon, more = try #require(card.more)
                    #expect(rtl ? icon.frame.minX > field.frame.maxX - 0.5 && more.frame.maxX < field.frame.minX + 0.5
                                : icon.frame.maxX < field.frame.minX + 0.5 && more.frame.minX > field.frame.maxX - 0.5, "\(label)")
                    #expect(field.frame.width > 100 && card.bounds.contains(more.frame), "\(label)")
                    let rows = results(search)
                    #expect(rows.count == 10, "\(label)")
                    for (upper, lower) in zip(rows, rows.dropFirst()) { #expect(upper.frame.maxY <= lower.frame.minY + 0.5, "\(label)") }
                    for row in rows {
                        #expect(row.frame.minX == 0 && row.frame.width == search.bounds.width, "\(label)")
                        for text in all(row, UILabel.self) {
                            let needed = text.sizeThatFits(CGSize(width: text.bounds.width, height: .greatestFiniteMagnitude)).height
                            #expect(text.bounds.height >= needed - 0.5 && row.bounds.contains(text.frame), "\(label): \(text.text ?? "")")
                            #expect(text.textAlignment == (rtl ? .right : .left), "\(label)")
                        }
                    }
                    try tap("toolbarBack", screen.controller.view)
                }
            }
            screen.controller.traitOverrides.remove(UITraitLayoutDirection.self)
        }
    }
}

@MainActor private func settingsSearchFind<T: UIView>(_ id: String, _ view: UIView, as: T.Type = T.self) -> T? {
    if view.accessibilityIdentifier == id, let found = view as? T { return found }
    return view.subviews.lazy.compactMap { settingsSearchFind(id, $0, as: T.self) }.first
}
@MainActor private func settingsSearchAll<T: UIView>(_ view: UIView, _ type: T.Type) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { settingsSearchAll($0, T.self) }
}
