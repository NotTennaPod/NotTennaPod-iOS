import Foundation

/// The Settings root screen (Android `MainPreferencesFragment` + `preferences.xml`, 3.12.1).
///
/// Android decides the root's composition from `getPackageName().hashCode()` (MPF:44–64):
/// the official package shows the Project category; the official debug package also shows a
/// red development notice first; every other package hides Project and appends a red spin-off
/// notice as the last row. The iOS bundle identifier is not an official package in any
/// configuration, so the app shows the unofficial composition.
/// Nothing here is stored: the branch is derived, never persisted.
public enum SettingsRootComposition {
    public enum Branch: String, Sendable, Equatable {
        case official, debug, unofficial
    }

    public struct Row: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable { case search, preference, category, notice }
        public let kind: Kind
        /// Android preference key; nil for the code-created notices.
        public let key: String?
        /// Localizable string keys (Android `strings.xml` names).
        public let titleKey: String?
        public let summaryKey: String?
        /// Literal text for rows Android hard-codes in Java (never translated).
        public let text: String?
        public let icon: String?
        /// The category this row belongs to (hidden with it), if any.
        public let category: String?

        init(_ kind: Kind, key: String? = nil, title: String? = nil, summary: String? = nil, text: String? = nil,
             icon: String? = nil, category: String? = nil) {
            self.kind = kind; self.key = key; titleKey = title; summaryKey = summary; self.text = text
            self.icon = icon; self.category = category
        }
    }

    /// `String.hashCode()` constants of `de.danoeh.antennapod` and `de.danoeh.antennapod.debug` (MPF:45, 56).
    public static let officialHash: Int32 = 1_790_437_538
    public static let debugHash: Int32 = -1_190_467_065

    /// Hard-coded English in MPF:51–54; Android never translates it. Android shows it for every
    /// non-official package; the iOS app shows `spinOffNotice` in its place.
    public static let androidSpinOffNotice = "This application is based on AntennaPod."
        + " The AntennaPod team does NOT provide support for this unofficial version."
        + " If you can read this message, the developers of this modification"
        + " violate the GNU General Public License (GPL)."
    /// The iOS notice, in the same row, icon, colour and place: the
    /// copyright notice the source comment asks legitimate spin-offs to show (MPF:40–43), naming NotTennaPod,
    /// instead of Android's text, which says this app's developers violate the GPL.
    public static let spinOffNotice = "NotTennaPod is not AntennaPod and has no affiliation with the AntennaPod project."
        + " Please don't report NotTennaPod problems to the AntennaPod team."
        + " NotTennaPod is free software, licensed under the GNU General Public License (GPL) version 3."
    /// MPF:62. Only the official debug package shows it; never on iOS.
    public static let developmentNotice = "This is a development version of AntennaPod and not meant for daily use"
    /// Both notices use `ic_info_white` with a MULTIPLY filter of 0xffcc0000 (MPF:48–50, 58–60):
    /// white × #CC0000 renders #CC0000 in both themes.
    public static let noticeIcon = "ic_info_white"
    public static let noticeColor: UInt32 = 0xCC0000

    /// Java `String.hashCode()`: `s[0]*31^(n-1) + … + s[n-1]` over UTF-16 code units with int overflow.
    public static func javaHash(_ string: String) -> Int32 { JavaString.hashCode(string) }

    public static func branch(forPackage package: String) -> Branch {
        switch javaHash(package) {
        case officialHash: .official
        case debugHash: .debug
        default: .unofficial
        }
    }

    /// `preferences.xml` rows in XML order (ordering-as-added gives orders 0–7; Project children 0–4).
    static let xmlRows: [Row] = [
        Row(.search, key: "searchPreference", summary: "preference_search_hint"),
        Row(.preference, key: "prefScreenInterface", title: "user_interface_label", summary: "user_interface_sum", icon: "ic_appearance"),
        Row(.preference, key: "prefScreenPlayback", title: "playback_pref", summary: "playback_pref_sum", icon: "ic_play_24dp"),
        Row(.preference, key: "prefScreenDownloads", title: "downloads_pref", summary: "downloads_pref_sum", icon: "ic_download"),
        Row(.preference, key: "prefScreenSynchronization", title: "synchronization_pref", summary: "synchronization_sum", icon: "ic_cloud"),
        Row(.preference, key: "prefScreenImportExport", title: "import_export_pref", summary: "import_export_summary", icon: "ic_storage"),
        Row(.preference, key: "notifications", title: "notification_pref_fragment", icon: "ic_notifications"),
        Row(.category, key: "project", title: "project_pref"),
        Row(.preference, key: "prefDocumentation", title: "documentation_support", icon: "ic_questionmark", category: "project"),
        Row(.preference, key: "prefViewForum", title: "visit_user_forum", icon: "ic_chat", category: "project"),
        Row(.preference, key: "prefContribute", title: "pref_contribute", icon: "ic_contribute", category: "project"),
        Row(.preference, key: "prefSendBugReport", title: "report_bug_title", icon: "ic_bug", category: "project"),
        Row(.preference, key: "prefAbout", title: "about_pref", icon: "ic_info", category: "project"),
    ]

    /// Visible root rows in display order for a branch (androidx `sortPreferences` + `isVisible`).
    public static func rows(for branch: Branch, notice: String = androidSpinOffNotice) -> [Row] {
        switch branch {
        case .official:
            return xmlRows
        case .debug:
            // Explicit order −1 sorts before the search field (order 0).
            return [Row(.notice, text: developmentNotice, icon: noticeIcon)] + xmlRows
        case .unofficial:
            // The Project category and its children are hidden; the notice is added to the root
            // after inflation with the next as-added order (8), so it is the last row.
            return xmlRows.filter { $0.key != "project" && $0.category != "project" }
                + [Row(.notice, text: notice, icon: noticeIcon)]
        }
    }

    public static func rows(forPackage package: String) -> [Row] { rows(for: branch(forPackage: package)) }

    /// The iOS app, NotTennaPod. Its bundle identifier (`org.nottennapod.app`) is not an official Android package, so
    /// it takes the unofficial branch, with one addition: the Project category
    /// keeps About, NotTennaPod's own page. Documentation, Forum, Contribute and Report bug lead to AntennaPod and stay out.
    public static let application: [Row] = rows(for: .unofficial, notice: spinOffNotice).flatMap { row -> [Row] in
        row.kind == .notice ? xmlRows.filter { $0.key == "project" || $0.key == "prefAbout" } + [row] : [row]
    }
}
