import NotTennaPodCore

/// A settings screen, identified by what it is rather than by its translated title,
/// so pages keep opening once the titles are translated.
enum SettingsPage: Equatable, CaseIterable {
    case main
    case userInterface
    case playback
    case downloads
    case importExport
    case automaticDownload
    case autoDeletion
    case synchronization
    /// The NotTennaPod server's Synchronization log and Needs attention (PROTOCOL §15.5), opened from the
    /// Synchronization page.
    case synchronizationLog
    case synchronizationAttention
    case notifications
    case swipeActions
    /// NotTennaPod's About page and its Licenses page.
    case about
    case licenses

    /// `PreferenceActivity.getTitleOfPage` (PA:88–111): the toolbar title.
    var titleKey: String {
        switch self {
        case .main: "settings_label"
        case .userInterface: "user_interface_label"
        case .playback: "playback_pref"
        case .downloads: "downloads_pref"
        case .importExport: "import_export_pref"
        case .automaticDownload: "pref_automatic_download_title"
        case .autoDeletion: "pref_auto_delete_title"
        case .synchronization: "synchronization_pref"
        case .synchronizationLog: "ntp_server_log_title"
        case .synchronizationAttention: "ntp_server_attention_title"
        case .notifications: NotificationSettingsComposition.titleKey
        case .swipeActions: "swipeactions_label"
        case .about: "about_pref"
        case .licenses: "licenses"
        }
    }

    /// The page's name in a window's saved place: stable across versions and languages, never shown.
    var restorationName: String {
        switch self {
        case .main: "main"
        case .userInterface: "userInterface"
        case .playback: "playback"
        case .downloads: "downloads"
        case .importExport: "importExport"
        case .automaticDownload: "automaticDownload"
        case .autoDeletion: "autoDeletion"
        case .synchronization: "synchronization"
        case .synchronizationLog: "synchronizationLog"
        case .synchronizationAttention: "synchronizationAttention"
        case .notifications: "notifications"
        case .swipeActions: "swipeActions"
        case .about: "about"
        case .licenses: "licenses"
        }
    }

    init?(restorationName: String) {
        guard let page = Self.allCases.first(where: { $0.restorationName == restorationName }) else { return nil }
        self = page
    }

    /// The page a settings search result opens; podcast settings rows open a dialog instead.
    init?(_ screen: SettingsSearch.Screen) {
        switch screen {
        case .userInterface: self = .userInterface
        case .playback: self = .playback
        case .downloads: self = .downloads
        case .importExport: self = .importExport
        case .automaticDownload: self = .automaticDownload
        case .synchronization: self = .synchronization
        case .notifications: self = .notifications
        case .swipeActions: self = .swipeActions
        case .podcast: return nil
        }
    }
}
