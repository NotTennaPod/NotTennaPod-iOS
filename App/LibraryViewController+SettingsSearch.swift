import UIKit
import NotTennaPodCore

// Settings search: the page opened from the Settings root, the More menu, and what a result does
// (`PreferenceActivity.onSearchResultClicked`).
extension LibraryViewController {
    /// The search page's history store: the scene's, or one kept in memory.
    var activeSettingsSearchHistory: SettingsSearchHistoryStore { settingsSearchHistory ?? settingsSearchHistoryFallback }

    /// `SearchPreference.onClick` → `SearchConfiguration.showSearchFragment`.
    func openSettingsSearch() { push(.settingsSearch(makeSettingsSearch())) }

    /// The rows the settings show now, as the settings search finds them.
    func settingsSearchItems() -> [SettingsSearch.Item] {
        // The gpodder.net login row exists only while gpodder.net is the selected provider.
        let gpodder = synchronizationSettings?.saved.account?.backend == .gpodder
        // The NotTennaPod server rows are found only while the Synchronization page shows them (PROTOCOL §15.5).
        var server: SettingsSearch.ServerRows = []
        var previous: [(id: String, label: String)] = []
        if let page = synchronizationSettings?.serverPage {
            server = SettingsSearch.ServerRows(page: page)
            // A previous library's row, titled as the page titles it, while the page lists it.
            let labels = SynchronizationSettingsView.previousLibraryLabels(page.previousLibraries)
            previous = page.rows.compactMap { row in
                guard case .previousLibrary(let id) = row, let label = labels[id] else { return nil }
                return (id, label)
            }
        }
        return SettingsSearch.resolve(SettingsSearch.visibleIndex(gpodderSelected: gpodder, server: server, previousLibraries: previous),
                                      text: Appearance.text)
    }

    /// The settings search page with the rows the settings show now (opened, or restored with its scene).
    func makeSettingsSearch() -> SettingsSearchView {
        let search = SettingsSearchView(items: settingsSearchItems(), history: activeSettingsSearchHistory)
        search.onSelect = { [weak self] item in self?.openSettingsSearchResult(item) }
        search.onMore = { [weak self, weak search] anchor in
            guard let self, let search else { return }
            let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            let menu = PopupMenuController(title: "", identifier: "settingsSearchMoreMenu", anchor: anchor,
                anchorFraction: CGPoint(x: rtl ? 0 : 1, y: 1),
                actions: [("settingsSearchClearHistory", Appearance.text("preference_search_clear_history"))]) { [weak search] _ in
                    search?.clearHistory()
                }
            present(menu, animated: true)
        }
        search.onFailure = { [weak self] in self?.showError($0) }
        return search
    }

    func renderSettingsSearch(_ search: SettingsSearchView) {
        content.isScrollEnabled = false
        search.frame = content.bounds; search.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        guard search.superview !== content else { return }
        // Shown again (opened, or Back from a result's page): fresh results over the rows the settings show now, and
        // the keyboard, as `onResume` does.
        content.addSubview(search)
        search.refreshItems(settingsSearchItems())
        search.update()
        search.focus()
    }

    /// Every settings search in the stack, shown or kept behind a result's page, searches the rows the settings show
    /// now: the server rows come and go with the Synchronization page (PROTOCOL §15.5). The text typed stays.
    func refreshSettingsSearchIndexes() {
        let searches = path.compactMap { screen -> SettingsSearchView? in if case .settingsSearch(let search) = screen { search } else { nil } }
        guard !searches.isEmpty else { return }
        let items = settingsSearchItems()
        for search in searches { search.refreshItems(items) }
    }

    /// `SearchPreferenceFragment.onItemClicked` + `PreferenceActivity.onSearchResultClicked`.
    func openSettingsSearchResult(_ item: SettingsSearch.Item) {
        view.endEditing(true)
        if let title = item.title {
            do { try activeSettingsSearchHistory.add(title) } catch { showError(error) }
        }
        switch item.entry.screen.action {
        case .podcastSettingsDialog:
            present(SourceMessageController(title: Appearance.text("feed_settings_label"),
                                            message: Appearance.text("pref_feed_settings_dialog_msg")), animated: true)
        case .open:
            if let page = SettingsPage(item.entry.screen) { openSettingsPage(page) }
        case .openAndHighlight:
            if let page = SettingsPage(item.entry.screen) { openSettingsPage(page) }
            // The Synchronization log and Needs attention open their own screens, over the page (PROTOCOL §15.5).
            if let screen = SettingsSearch.serverScreen(forKey: item.entry.key) {
                openSettingsPage(screen == .log ? .synchronizationLog : .synchronizationAttention)
                return
            }
            highlightSettingsRow(item.entry.key)
        }
    }

    /// The row's view identifier on its iOS page (Backup & restore names its rows after their actions).
    static func settingsRowIdentifier(_ key: String) -> String {
        [
            "prefDatabaseExport": "databaseExport", "prefAutomaticDatabaseExport": "automaticDatabaseExport",
            "prefDatabaseImport": "databaseImport", "prefOpmlExport": "opmlExport", "prefOpmlImport": "opmlImportPreference",
            "prefHtmlExport": "htmlExport", "prefFavoritesExport": "favoritesExport",
        ][key] ?? key
    }

    private func settingsRow(_ identifier: String) -> UIView? {
        func find(_ view: UIView) -> UIView? {
            if view.accessibilityIdentifier == identifier { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(content)
    }

    /// `SearchPreferenceResult.highlight`: scroll the row into view, then 200 ms later tint it with the primary
    /// text colour at 20 % (`color & 0xFFFFFF | 0x33000000`) for one second.
    func highlightSettingsRow(_ key: String) {
        let identifier = Self.settingsRowIdentifier(key)
        view.layoutIfNeeded()
        guard let row = settingsRow(identifier) else { return }
        content.scrollRectToVisible(row.convert(row.bounds, to: content), animated: false)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, let row = settingsRow(identifier) else { return }
            let tint = UIView(frame: row.bounds)
            tint.backgroundColor = Appearance.foreground.withAlphaComponent(0x33 / 255)
            tint.isUserInteractionEnabled = false
            tint.accessibilityIdentifier = "settingsSearchHighlight"
            tint.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            row.insertSubview(tint, at: 0)
            try? await Task.sleep(for: .seconds(1))
            tint.removeFromSuperview()
        }
    }
}
