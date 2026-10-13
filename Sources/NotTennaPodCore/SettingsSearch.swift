import Foundation

/// Settings search: Android 3.12.1's SearchPreference index and matching.
///
/// - The index is `MainPreferencesFragment.setupSearch` (MPF:127–153): nine preference XMLs, each with its
///   breadcrumb; every row with a title or summary that is not `search:ignore` is a result, in XML order.
///   `preferences.xml`, `preferences_about.xml` and `preferences_auto_deletion.xml` are not indexed.
/// - Matching is lib.preferencesearch 2.7.3 with fuzzy search on (`PreferenceParser.searchFor`): commons-text
///   `FuzzyScore` of the "ø"-joined title, summary, list entries, breadcrumbs and keywords against "ø" + query,
///   divided in `Float` by `(query length + 1) * 3 - 2`; a row matches above 0.3; highest score first, ties in
///   index order, at most ten.
/// - iOS shows no result for a row its screens do not show.
public enum SettingsSearch {
    /// An indexed preference XML: the screen a result opens.
    public enum Screen: String, Sendable, CaseIterable {
        case userInterface = "preferences_user_interface"
        case playback = "preferences_playback"
        case downloads = "preferences_downloads"
        case importExport = "preferences_import_export"
        case automaticDownload = "preferences_autodownload"
        case synchronization = "preferences_synchronization"
        case notifications = "preferences_notifications"
        case podcast = "feed_settings"
        case swipeActions = "preferences_swipe"

        /// The breadcrumb `setupSearch` gives the file (string keys, MPF:133–153).
        public var breadcrumbKeys: [String] {
            switch self {
            case .userInterface: ["user_interface_label"]
            case .playback: ["playback_pref"]
            case .downloads: ["downloads_pref"]
            case .importExport: ["import_export_pref"]
            case .automaticDownload: ["downloads_pref", "automation", "pref_automatic_download_title"]
            case .synchronization: ["synchronization_pref"]
            case .notifications: ["notification_pref_fragment"]
            case .podcast: ["feed_settings_label"]
            case .swipeActions: ["user_interface_label", "swipeactions_label"]
            }
        }

        /// `PreferenceActivity.getTitleOfPage` (PA:88–111): the toolbar title of the screen a result opens.
        public var titleKey: String {
            switch self {
            case .userInterface: "user_interface_label"
            case .playback: "playback_pref"
            case .downloads: "downloads_pref"
            case .importExport: "import_export_pref"
            case .automaticDownload: "pref_automatic_download_title"
            case .synchronization: "synchronization_pref"
            case .notifications: "notification_pref_fragment"
            case .podcast: "feed_settings_label"
            case .swipeActions: "swipeactions_label"
            }
        }

        /// `PreferenceActivity.onSearchResultClicked` (PA:145–159).
        public var action: Action {
            switch self {
            case .podcast: .podcastSettingsDialog
            case .notifications: .open
            default: .openAndHighlight
            }
        }
    }

    public enum Action: Sendable, Equatable {
        /// Open the screen, scroll to the row and highlight it.
        case openAndHighlight
        /// Open the screen only (Notifications).
        case open
        /// Podcast settings rows: a "Podcast settings" dialog saying the setting is per podcast.
        case podcastSettingsDialog
    }

    /// A list entry: a string key, or a literal Android keeps untranslated ("5", "30").
    public enum Text: Sendable, Equatable {
        case key(String)
        case literal(String)
    }

    /// One indexed preference, as string keys (Android `strings.xml` names).
    public struct Entry: Sendable, Equatable {
        public let screen: Screen
        public let key: String
        public let titleKey: String?
        /// A title the page composes itself (a previous library's "Library from before …"), used as it is.
        public let titleText: String?
        public let summaryKey: String?
        public let entries: [Text]?
        public let keywordsKey: String?
        /// The enclosing `PreferenceCategory` title, which `PreferenceParser` adds to the breadcrumbs.
        public let categoryKey: String?

        init(_ screen: Screen, _ key: String, title: String?, titleText: String? = nil, summary: String? = nil, entries: [Text]? = nil,
             keywords: String? = nil, category: String? = nil) {
            self.screen = screen; self.key = key; titleKey = title; self.titleText = titleText; summaryKey = summary
            self.entries = entries; keywordsKey = keywords; categoryKey = category
        }

        public var breadcrumbKeys: [String] { screen.breadcrumbKeys + (categoryKey.map { [$0] } ?? []) }
    }

    // MARK: - Index (source order)

    private static func keys(_ names: String...) -> [Text] { names.map(Text.key) }
    private static func literals(_ values: String...) -> [Text] { values.map(Text.literal) }

    /// The Android 3.12.1 index: every result row of the nine XMLs, in `setupSearch` and XML order.
    public static let index: [Entry] = {
        let ui = Screen.userInterface, playback = Screen.playback, downloads = Screen.downloads
        let backup = Screen.importExport, automatic = Screen.automaticDownload, sync = Screen.synchronization
        let notifications = Screen.notifications, podcast = Screen.podcast, swipe = Screen.swipeActions
        let buttonActions = keys("button_action_fast_forward", "button_action_rewind", "button_action_skip_episode",
                                 "button_action_restart_episode")
        return [
            // preferences_user_interface.xml (prefTheme has no title or summary; prefExpandNotify is search:ignore)
            Entry(ui, "prefThemeBlack", title: "pref_black_theme_title", summary: "pref_black_theme_message", category: "theming"),
            Entry(ui, "prefTintedColors", title: "pref_tinted_theme_title", summary: "pref_tinted_theme_message", category: "theming"),
            Entry(ui, "prefEpisodeCover", title: "pref_episode_cover_title", summary: "pref_episode_cover_summary",
                  category: "episode_information"),
            Entry(ui, "showTimeLeft", title: "pref_show_remain_time_title", summary: "pref_show_remain_time_summary",
                  category: "episode_information"),
            Entry(ui, "prefPlaybackTimeRespectsSpeed", title: "pref_playback_time_respects_speed_title",
                  summary: "pref_playback_time_respects_speed_sum", category: "episode_information"),
            Entry(ui, "prefPersistNotify", title: "pref_persistNotify_title", summary: "pref_persistNotify_sum",
                  category: "external_elements"),
            Entry(ui, "prefFullNotificationButtons", title: "pref_full_notification_buttons_title",
                  summary: "pref_full_notification_buttons_sum", category: "external_elements"),
            Entry(ui, "prefDefaultPage", title: "pref_default_page", summary: "pref_default_page_sum",
                  entries: keys("home_label", "queue_label", "inbox_label", "episodes_label", "subscriptions_label",
                                "statistics_label", "remember_last_page"), category: "behavior"),
            Entry(ui, "prefBottomNavigation", title: "bottom_navigation", summary: "bottom_navigation_summary", category: "behavior"),
            Entry(ui, "prefHiddenDrawerItems", title: "pref_nav_drawer_items_title", summary: "pref_nav_drawer_items_sum",
                  category: "behavior"),
            Entry(ui, "prefBackButtonOpensDrawer", title: "pref_back_button_opens_drawer",
                  summary: "pref_back_button_opens_drawer_summary", category: "behavior"),
            Entry(ui, "prefGlobalDefaultSortedOrder", title: "pref_global_default_episode_list_sort_order_title",
                  summary: "pref_global_default_episode_list_sort_order_sum", category: "episode_lists"),
            Entry(ui, "prefSwipe", title: "swipeactions_label", summary: "swipeactions_summary", category: "episode_lists"),
            Entry(ui, "prefStreamOverDownload", title: "pref_stream_over_download_title", summary: "pref_stream_over_download_sum",
                  category: "episode_lists"),
            Entry(ui, "prefDownloadsButtonAction", title: "pref_downloads_button_action_title",
                  summary: "pref_downloads_button_action_sum", category: "episode_lists"),
            // preferences_playback.xml (the two reconnect rows are search:ignore)
            Entry(playback, "prefPauseOnHeadsetDisconnect", title: "pref_pauseOnHeadsetDisconnect_title",
                  summary: "pref_pauseOnDisconnect_sum", category: "interruptions"),
            Entry(playback, "prefPlaybackFastForwardDeltaLauncher", title: "pref_fast_forward", summary: "pref_fast_forward_sum",
                  category: "playback_control"),
            Entry(playback, "prefPlaybackRewindDeltaLauncher", title: "pref_rewind", summary: "pref_rewind_sum",
                  category: "playback_control"),
            Entry(playback, "prefPlaybackSpeedLauncher", title: "playback_speed", summary: "pref_playback_speed_sum",
                  category: "playback_control"),
            Entry(playback, "prefHardwareForwardButton", title: "pref_hardware_forward_button_title",
                  summary: "pref_hardware_forward_button_summary", entries: buttonActions, category: "reassign_hardware_buttons"),
            Entry(playback, "prefHardwarePreviousButton", title: "pref_hardware_previous_button_title",
                  summary: "pref_hardware_previous_button_summary", entries: buttonActions, category: "reassign_hardware_buttons"),
            Entry(playback, "prefEnqueueLocation", title: "pref_enqueue_location_title",
                  entries: keys("enqueue_location_back", "enqueue_location_front", "enqueue_location_after_current",
                                "enqueue_location_random"), category: "queue_label"),
            Entry(playback, "prefEnqueueDownloaded", title: "pref_enqueue_downloaded_title",
                  summary: "pref_enqueue_downloaded_summary", category: "queue_label"),
            Entry(playback, "prefFollowQueue", title: "pref_followQueue_title", summary: "pref_followQueue_sum", category: "queue_label"),
            Entry(playback, "prefSmartMarkAsPlayedSecs", title: "pref_smart_mark_as_played_title",
                  summary: "pref_smart_mark_as_played_sum", entries: literals("0", "15", "30", "60", "120", "300", "600"),
                  category: "queue_label"),
            Entry(playback, "prefSkipKeepsEpisode", title: "pref_skip_keeps_episodes_title", summary: "pref_skip_keeps_episodes_sum",
                  category: "queue_label"),
            // preferences_downloads.xml (prefAutoDownloadSettings is search:ignore; its XML is indexed on its own)
            Entry(downloads, "prefChooseDataDir", title: "choose_data_directory"),
            Entry(downloads, "prefAutoUpdateIntervall", title: "feed_refresh_title", summary: "feed_refresh_sum",
                  entries: keys("feed_refresh_never", "feed_every_hour", "feed_every_2_hours", "feed_every_4_hours",
                                "feed_every_8_hours", "feed_every_12_hours", "feed_every_24_hours", "feed_every_72_hours"),
                  category: "automation"),
            Entry(downloads, "prefNewEpisodesAction", title: "pref_new_episodes_action_title", summary: "pref_new_episodes_action_sum",
                  entries: keys("feed_new_episodes_action_add_to_inbox", "feed_new_episodes_action_add_to_queue",
                                "feed_new_episodes_action_nothing"), category: "automation"),
            Entry(downloads, "prefAutoDeleteScreen", title: "pref_auto_delete_title", summary: "pref_auto_delete_sum",
                  category: "automation"),
            Entry(downloads, "prefDeleteRemovesFromQueue", title: "pref_delete_removes_from_queue_title",
                  summary: "pref_delete_removes_from_queue_sum", category: "automation"),
            Entry(downloads, "prefMobileUpdateTypes", title: "pref_mobileUpdate_title", summary: "pref_mobileUpdate_sum",
                  entries: keys("pref_mobileUpdate_refresh", "pref_mobileUpdate_episode_download", "pref_automatic_download_title",
                                "pref_mobileUpdate_streaming", "pref_mobileUpdate_images", "synchronization_pref"),
                  category: "download_pref_details"),
            Entry(downloads, "prefProxy", title: "pref_proxy_title", summary: "pref_proxy_sum", category: "download_pref_details"),
            // preferences_import_export.xml
            Entry(backup, "prefDatabaseExport", title: "database_export_label", summary: "database_export_summary",
                  keywords: "import_export_search_keywords", category: "database"),
            Entry(backup, "prefAutomaticDatabaseExport", title: "automatic_database_export_label",
                  summary: "automatic_database_export_summary", category: "database"),
            Entry(backup, "prefDatabaseImport", title: "database_import_label", summary: "database_import_summary",
                  keywords: "import_export_search_keywords", category: "database"),
            Entry(backup, "prefOpmlExport", title: "opml_export_label", summary: "opml_export_summary", category: "opml"),
            Entry(backup, "prefOpmlImport", title: "opml_import_label", summary: "opml_import_summary", category: "opml"),
            Entry(backup, "prefHtmlExport", title: "html_export_label", summary: "html_export_summary", category: "html"),
            Entry(backup, "prefFavoritesExport", title: "favorites_export_label", summary: "favorites_export_summary", category: "html"),
            // preferences_autodownload.xml
            Entry(automatic, "prefEnableAutoDl", title: "pref_automatic_download_title",
                  summary: "pref_automatic_download_global_description"),
            Entry(automatic, "prefEnableAutoDlQueue", title: "pref_automatic_download_queue_title",
                  summary: "pref_automatic_download_queue_description"),
            Entry(automatic, "prefEpisodeCacheSize", title: "pref_episode_cache_title", summary: "pref_episode_cache_summary",
                  entries: literals("5", "10", "25", "50", "100", "500") + keys("pref_episode_cache_unlimited")),
            Entry(automatic, "prefEnableAutoDownloadOnBattery", title: "pref_automatic_download_on_battery_title",
                  summary: "pref_automatic_download_on_battery_sum"),
            // preferences_synchronization.xml
            Entry(sync, "preference_synchronization_description", title: nil, summary: "synchronization_summary_unchoosen"),
            Entry(sync, "pref_gpodnet_setlogin_information", title: "pref_gpodnet_setlogin_information_title",
                  summary: "pref_gpodnet_setlogin_information_sum"),
            Entry(sync, "pref_synchronization_sync", title: "synchronization_sync_changes_title", summary: "synchronization_sync_summary"),
            Entry(sync, "pref_synchronization_force_full_sync", title: "synchronization_full_sync_title",
                  summary: "synchronization_force_sync_summary"),
            Entry(sync, "pref_synchronization_logout", title: "synchronization_logout"),
            // preferences_notifications.xml
            Entry(notifications, "prefShowDownloadReport", title: "notification_channel_download_error",
                  summary: "notification_channel_download_error_description", category: "notification_group_errors"),
            Entry(notifications, "pref_gpodnet_notifications", title: "notification_channel_sync_error",
                  summary: "notification_channel_sync_error_description", category: "notification_group_errors"),
            // feed_settings.xml
            Entry(podcast, "rename", title: "rename_feed_label", category: "pref_display"),
            Entry(podcast, "tags", title: "feed_tags_label", summary: "feed_tags_summary", category: "pref_display"),
            Entry(podcast, "feedPlaybackSpeed", title: "playback_speed", summary: "pref_feed_playback_speed_sum", category: "playback_pref"),
            Entry(podcast, "feedAutoSkip", title: "pref_feed_skip", summary: "pref_feed_skip_sum", category: "playback_pref"),
            Entry(podcast, "volumeReduction", title: "feed_volume_adapdation", summary: "feed_volume_adaptation_summary",
                  entries: keys("feed_volume_reduction_heavy", "feed_volume_reduction_light", "feed_volume_reduction_off",
                                "feed_volume_boost_light", "feed_volume_boost_medium", "feed_volume_boost_heavy"),
                  category: "playback_pref"),
            Entry(podcast, "keepUpdated", title: "keep_updated", summary: "keep_updated_summary", category: "automation"),
            Entry(podcast, "episodeNotification", title: "episode_notification", summary: "episode_notification_summary",
                  category: "automation"),
            Entry(podcast, "autoDelete", title: "pref_auto_delete_playback_title", summary: "global_default",
                  entries: keys("global_default", "feed_auto_download_always", "feed_auto_download_never"), category: "automation"),
            Entry(podcast, "feedNewEpisodesAction", title: "pref_new_episodes_action_title", summary: "global_default",
                  entries: keys("global_default", "feed_new_episodes_action_add_to_inbox", "feed_new_episodes_action_add_to_queue",
                                "feed_new_episodes_action_nothing"), category: "automation"),
            Entry(podcast, "includeAutoDownload", title: "auto_download_label",
                  entries: keys("global_default", "enabled", "disabled"), category: "automation"),
            Entry(podcast, "episodeFilter", title: "episode_filters_label", summary: "episode_filters_description", category: "automation"),
            Entry(podcast, "authentication", title: "authentication_label", summary: "authentication_descr", category: "pref_advanced"),
            // preferences_swipe.xml
        ] + SwipeActionsSettingsRow.allCases.map { Entry(swipe, $0.key, title: $0.titleKey) }
    }()

    /// Rows the iOS screens never show: a result would open a screen without the row.
    public static let hiddenKeys: Set<String> = [
        "prefTintedColors",   // Dynamic colors: not implemented
        "prefChooseDataDir",  // Choose data folder: hidden
        "prefPersistNotify",  // hidden by Android on API 30+ (UserInterfacePreferencesFragment:100–102); not on iOS
    ]
    /// Shown only while gpodder.net is the selected provider (SynchronizationPreferencesFragment:135–137).
    public static let gpodderOnlyKeys: Set<String> = ["pref_gpodnet_setlogin_information"]

    /// Which NotTennaPod server rows the Synchronization page shows now (PROTOCOL §15.5).
    public struct ServerRows: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// A server library is open: "Change login information" and "Synchronization log".
        public static let serverMode = ServerRows(rawValue: 1)
        /// No provider is chosen and server libraries are kept: "Server libraries on this device".
        public static let keptLibraries = ServerRows(rawValue: 2)
        /// Server mode with items to act on: "Needs attention".
        public static let attention = ServerRows(rawValue: 4)
        /// A server library being prepared or ready to switch to: the page shows the provider, its status and Logout,
        /// without "Synchronize now" and "Force full synchronization".
        public static let preparing = ServerRows(rawValue: 8)
        /// The server no longer has this library's history (PROTOCOL §6.11 `lineage_unknown`): "Start over".
        public static let startOver = ServerRows(rawValue: 16)

        /// What the Synchronization page shows now (PROTOCOL §15.5 "only when they apply"), from its rows.
        public init(page: ServerSynchronizationPage) {
            self = []
            if page.mode == .server { insert(.serverMode) }
            if page.rows.contains(.keptLibraries) { insert(.keptLibraries) }
            if page.rows.contains(.attention) { insert(.attention) }
            if page.rows.contains(.startOver) { insert(.startOver) }
            if !page.showsOrdinaryRows && !page.rows.contains(.synchronize) { insert(.preparing) }
        }
    }

    /// The page's own actions, absent while a server library is prepared (`ServerRows.preparing`).
    static let synchronizeKeys: Set<String> = ["pref_synchronization_sync", "pref_synchronization_force_full_sync"]

    /// The server rows, indexed only while the page shows them (Android has none, so they are not in `index`).
    public static let serverIndex: [Entry] = [
        Entry(.synchronization, "ntp_server_start_over", title: "ntp_server_start_over_title", summary: "ntp_server_start_over_sum"),
        Entry(.synchronization, "ntp_server_setlogin_information", title: "pref_gpodnet_setlogin_information_title",
              summary: "ntp_server_setlogin_information_sum"),
        Entry(.synchronization, "ntp_server_log", title: "ntp_server_log_title", summary: "ntp_server_log_sum"),
        Entry(.synchronization, "ntp_server_attention", title: "ntp_server_attention_title", summary: "ntp_server_attention_sum"),
        Entry(.synchronization, "ntp_server_libraries", title: "ntp_server_libraries_title", summary: "ntp_server_libraries_sum"),
    ]

    /// A screen of its own behind a server row: its search result opens that screen (on top of the Synchronization
    /// page, so Back returns there) instead of highlighting the row.
    public enum ServerScreen: Sendable, Equatable { case log, attention }

    public static func serverScreen(forKey key: String) -> ServerScreen? {
        switch key {
        case "ntp_server_log": .log
        case "ntp_server_attention": .attention
        default: nil
        }
    }

    /// The index iOS searches: Android's, without rows the destination screen does not show, with the server rows
    /// the page shows now after the Synchronization page's own, then one row per previous library the page lists
    /// (PROTOCOL §15.5), titled as the page titles it and found by the row's key.
    public static func visibleIndex(gpodderSelected: Bool, server: ServerRows = [],
                                    previousLibraries: [(id: String, label: String)] = []) -> [Entry] {
        let visible = index.filter { !hiddenKeys.contains($0.key) && (gpodderSelected || !gpodderOnlyKeys.contains($0.key))
            && !(server.contains(.preparing) && synchronizeKeys.contains($0.key)) }
        let rows = serverIndex.filter { entry in
            switch entry.key {
            case "ntp_server_libraries": server.contains(.keptLibraries)
            case "ntp_server_attention": server.contains(.serverMode) && server.contains(.attention)
            case "ntp_server_start_over": server.contains(.serverMode) && server.contains(.startOver)
            default: server.contains(.serverMode)
            }
        } + previousLibraries.map { library in
            Entry(.synchronization, "ntp_server_previous_library-\(library.id)", title: nil, titleText: library.label)
        }
        guard !rows.isEmpty, let last = visible.lastIndex(where: { $0.screen == .synchronization }) else { return visible }
        var result = visible
        result.insert(contentsOf: rows, at: last + 1)
        return result
    }

    // MARK: - Resolved items

    /// An entry with its text in the current language.
    public struct Item: Sendable, Equatable {
        public let entry: Entry
        public let title: String?
        /// Android's summary text (format placeholders kept, as the library indexes it).
        public let summary: String?
        public let entries: String?
        public let breadcrumbs: String
        public let keywords: String?
        /// `PreferenceItem.getInfo`: the searched text.
        public let info: String

        /// What a result row shows: Android's summary without an unfilled format placeholder
        /// (Android would show a raw "%1$s").
        public var displaySummary: String? {
            guard let summary else { return nil }
            let stripped = summary.replacingOccurrences(of: #"\s*[:：]?\s*%(\d+\$)?[sd@]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return stripped.isEmpty ? nil : stripped
        }
    }

    public static let breadcrumbSeparator = " > "
    public static let maxResults = 10

    /// Resolves keys with `text` (the app passes its localized strings). Format specifiers are written back in
    /// Android's `%1$s` form, because that is the text the library searches.
    public static func resolve(_ entries: [Entry], text: (String) -> String) -> [Item] {
        entries.map { entry in
            let title = entry.titleText ?? entry.titleKey.map { androidFormat(text($0)) }
            let summary = entry.summaryKey.map { androidFormat(text($0)) }
            let list = entry.entries.map { items in
                items.map { item -> String in
                    switch item { case .key(let key): androidFormat(text(key)); case .literal(let value): value }
                }.joined(separator: ",")
            }
            let breadcrumbs = entry.breadcrumbKeys.map(text).filter { !$0.isEmpty }.joined(separator: breadcrumbSeparator)
            let keywords = entry.keywordsKey.map(text)
            let info = [title, summary, list, breadcrumbs, keywords].compactMap { $0 }.filter { !$0.isEmpty }
                .map { "ø" + $0 }.joined()
            return Item(entry: entry, title: title, summary: summary, entries: list, breadcrumbs: breadcrumbs,
                        keywords: keywords, info: info)
        }
    }

    /// iOS format specifiers (`%@`, `%d`, `%1$@`) back in Android's positional form (`%1$s`, `%1$d`).
    static func androidFormat(_ text: String) -> String {
        guard text.contains("%") else { return text }
        var result = "", position = 0
        var scanner = Substring(text)
        while let percent = scanner.firstIndex(of: "%") {
            result += scanner[scanner.startIndex..<percent]
            let rest = scanner[scanner.index(after: percent)...]
            if rest.first == "%" { result += "%%"; scanner = rest.dropFirst(); continue }
            var digits = "", cursor = rest.startIndex
            while cursor < rest.endIndex, rest[cursor].isNumber { digits.append(rest[cursor]); cursor = rest.index(after: cursor) }
            var explicit: Int?
            if !digits.isEmpty, cursor < rest.endIndex, rest[cursor] == "$" { explicit = Int(digits); cursor = rest.index(after: cursor) }
            else { cursor = rest.startIndex }
            while cursor < rest.endIndex, rest[cursor] == "l" { cursor = rest.index(after: cursor) }
            guard cursor < rest.endIndex, let conversion = ["@": "s", "d": "d", "s": "s", "f": "f"][rest[cursor]] else {
                result += "%"; scanner = rest; continue
            }
            position += 1
            result += "%\(explicit ?? position)$\(conversion)"
            scanner = rest[rest.index(after: cursor)...]
        }
        return result + scanner
    }

    // MARK: - Matching

    /// commons-text 1.3 `FuzzyScore.fuzzyScore`: one point per query character found in order in the term,
    /// two more when it directly follows the previous match. Case-folded with `locale`, compared as UTF-16 units.
    public static func fuzzyScore(term: String, query: String, locale: Locale) -> Int {
        let term = Array(term.lowercased(with: locale).utf16), query = Array(query.lowercased(with: locale).utf16)
        var score = 0, termIndex = 0, previous = Int.min
        for character in query {
            var found = false
            while termIndex < term.count && !found {
                if character == term[termIndex] {
                    score += 1
                    if previous != Int.min && previous + 1 == termIndex { score += 2 }
                    previous = termIndex
                    found = true
                }
                termIndex += 1
            }
        }
        return score
    }

    /// `PreferenceItem.getScore`: a Java `float` division.
    public static func score(_ item: Item, query: String, locale: Locale) -> Float {
        guard !query.isEmpty else { return 0 }
        let raw = Float(fuzzyScore(term: item.info, query: "ø" + query, locale: locale))
        let maximum = Float((query.utf16.count + 1) * 3 - 2)
        return raw / maximum
    }

    /// `PreferenceParser.searchFor(query, fuzzy: true)`: score above 0.3, best first, ties in index order, ten at most.
    public static func search(_ query: String, in items: [Item], locale: Locale = .current) -> [Item] {
        guard !query.isEmpty else { return [] }
        let scored = items.enumerated().compactMap { offset, item -> (Int, Float, Item)? in
            let value = score(item, query: query, locale: locale)
            return Double(value) > 0.3 ? (offset, value, item) : nil
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(maxResults).map(\.2)
    }
}
