import AppIntents
import UIKit
import NotTennaPodCore

// Android's Assistant App Actions (`actions.xml`) as App Intents. OPEN_APP_FEATURE
// becomes "Open" with the entity set's five pages; GET_THING becomes "Search". Both open the app.
// No intent takes a podcast (no per-podcast shortcut on iOS).

enum AntennaPodPage: String, AppEnum {
    case queue = "QUEUE", episodes = "EPISODES", downloads = "DOWNLOADS", subscriptions = "SUBSCRIPTIONS", history = "HISTORY"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "app_intent_page"
    static let caseDisplayRepresentations: [AntennaPodPage: DisplayRepresentation] = [
        .queue: "queue_label", .episodes: "episodes_label", .downloads: "downloads_label",
        .subscriptions: "subscriptions_label", .history: "playback_history_label"
    ]
    var entryPage: ExternalEntry.AppActionPage { ExternalEntry.AppActionPage(rawValue: rawValue)! }
}

struct OpenPageIntent: AppIntent {
    static let title: LocalizedStringResource = "app_intent_open"
    static let supportedModes: IntentModes = .foreground
    @Parameter(title: "app_intent_page") var page: AntennaPodPage

    init() {}
    init(page: AntennaPodPage) { self.page = page }

    static var parameterSummary: some ParameterSummary { Summary("\(\.$page)") }

    @MainActor func perform() async throws -> some IntentResult {
        EntryIntentRouter.route(.openPage(page.entryPage.destination))
        return .result()
    }
}

struct SearchLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "search_label"
    static let supportedModes: IntentModes = .foreground
    @Parameter(title: "search_label") var query: String

    init() {}
    init(query: String) { self.query = query }

    static var parameterSummary: some ParameterSummary { Summary("\(\.$query)") }

    @MainActor func perform() async throws -> some IntentResult {
        EntryIntentRouter.route(.search(query))
        return .result()
    }
}

struct NotTennaPodAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenPageIntent(), phrases: ["Open \(\.$page) in \(.applicationName)", "Show \(\.$page) in \(.applicationName)"],
                    shortTitle: "app_intent_open", systemImageName: "list.bullet")
        AppShortcut(intent: SearchLibraryIntent(), phrases: ["Search in \(.applicationName)"],
                    shortTitle: "search_label", systemImageName: "magnifyingglass")
    }
}

/// Where the intents hand their route; view tests replace it to observe the route.
@MainActor enum EntryIntentRouter {
    static var handler: (ExternalEntry.Route) -> Void = { route in
        (UIApplication.shared.delegate as? AppDelegate)?.routeExternal(route)
    }
    static func route(_ route: ExternalEntry.Route) { handler(route) }
}
