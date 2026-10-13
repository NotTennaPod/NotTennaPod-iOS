import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Mounted checks: the app's declared entry points, routing of shared text, quick actions, App
/// Intents and documents on a mounted main screen. Expectations from Android 3.12.1, except that shared text
/// opens its first link (a deliberate iOS deviation).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct EntryPointsViewTests {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    private func texts(in view: UIView) -> [String] {
        var result: [String] = []
        if let label = view as? UILabel, let text = label.text { result.append(text) }
        if let text = (view as? UITextView)?.text { result.append(text) }
        return result + view.subviews.flatMap(texts)
    }

    /// A main screen mounted in its own window, with its own navigation preferences.
    private func withController(configure: (inout NavigationPreferences) -> Void = { _ in }, library: Bool = false,
                                refreshed: ((FeedRefreshRequest) -> Void)? = nil,
                                _ body: @MainActor (LibraryViewController, NavigationPreferenceStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("M34View-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let navigation = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
        var value = navigation.value; configure(&value); try navigation.update(value)
        let store = library ? try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite")) : nil
        let refresh = store.map { store in
            ManualFeedRefreshCoordinator(store: store, execute: { request in
                _ = try await store.finishManualRefresh(id: request.id)
            })
        }
        refresh?.onChange = { if case .active(let request) = $0 { refreshed?(request) } }
        let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil,
            mobileNetworkPreferences: nil, usage: nil, manualRefresh: refresh,
            refreshNetwork: { .init(connected: true, metered: false, cellular: false) })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { closeTestWindow(window, restoringKey: previous) }
        try await wait { controller.viewIfLoaded?.window != nil }
        try await body(controller, navigation)
    }

    @Test func infoPlistDeclaresAndroidsProtocolsDocumentsAndQuickActions() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let schemes = (info["CFBundleURLTypes"] as? [[String: Any]] ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        for scheme in ExternalEntry.subscribeSchemes + [ShareHandoff.scheme] { #expect(schemes.contains(scheme), "\(scheme)") }
        let types = (info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []).flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        for type in ["public.rss", "org.ietf.atom", "org.opml.opml"] { #expect(types.contains(type), "\(type)") }
        // shortcuts.xml: order, Android labels, glyphs.
        let items = try #require(info["UIApplicationShortcutItems"] as? [[String: Any]])
        let actions = ExternalEntry.QuickAction.allCases
        #expect(items.map { $0["UIApplicationShortcutItemType"] as? String } == actions.map(\.type))
        #expect(items.map { $0["UIApplicationShortcutItemTitle"] as? String } == actions.map { Appearance.text($0.titleKey) })
        #expect(items.map { $0["UIApplicationShortcutItemTitle"] as? String } == ["Queue", "Episodes", "Subscriptions", "Refresh"])
        #expect(items.map { $0["UIApplicationShortcutItemIconFile"] as? String } == actions.map(\.iconName))
        for action in actions { #expect(UIImage(named: action.iconName) != nil, "\(action.iconName)") }
        // The Share Extension is embedded and accepts a web link or text.
        let plugins = try #require(Bundle.main.builtInPlugInsURL)
        let share = try #require(Bundle(url: plugins.appendingPathComponent("NotTennaPodShare.appex")))
        let rule = (share.infoDictionary?["NSExtension"] as? [String: Any])
            .flatMap { $0["NSExtensionAttributes"] as? [String: Any] }.flatMap { $0["NSExtensionActivationRule"] as? [String: Any] }
        #expect(rule?["NSExtensionActivationSupportsWebURLWithMaxCount"] as? Int == 1)
        #expect(rule?["NSExtensionActivationSupportsText"] as? Bool == true)
    }

    /// Launcher shortcuts reset to a fresh main screen: Settings closes, the page opens top-level and is
    /// remembered; a hidden page gives way to the default page (`MainActivity.onResume`).
    @Test func pageQuickActionsCloseSettingsAndOpenTheirPage() async throws {
        try await withController { controller, navigation in
            for action in [ExternalEntry.QuickAction.queue, .episodes, .subscriptions] {
                controller.drawerAction(.settings)
                #expect(controller.settingsVisible)
                controller.openExternal(.shortcut(action))
                #expect(!controller.settingsVisible)
                #expect(controller.path.count == 1)
                #expect(controller.rootNavigationTag == action.destination?.rawValue)
                #expect(navigation.value.lastPage == action.destination?.rawValue)
            }
            // A full-screen screen over the main screen (e.g. OPML import) detaches its view; the route
            // still runs at once and closes that screen.
            let cover = UIViewController(); cover.modalPresentationStyle = .fullScreen
            controller.present(cover, animated: false)
            try await wait { controller.viewIfLoaded?.window == nil && cover.viewIfLoaded?.window != nil }
            controller.openExternal(.shortcut(.episodes))
            #expect(controller.pendingExternalRoute == nil)
            #expect(controller.rootNavigationTag == NavigationDestination.episodes.rawValue)
            try await wait { controller.presentedViewController == nil }
        }
        try await withController(configure: {
            $0.configuration.hiddenTags = [NavigationDestination.queue.rawValue]
            $0.defaultPage = NavigationDestination.subscriptions.rawValue
        }) { controller, _ in
            controller.openExternal(.shortcut(.queue))
            #expect(controller.rootNavigationTag == NavigationDestination.subscriptions.rawValue)
        }
    }

    /// Refresh keeps (or returns to) the startup page — the default page, or the remembered one — and
    /// starts one refresh of all podcasts (`runOnceOrAsk`, no feed).
    @Test func refreshQuickActionOpensTheStartupPageAndRefreshesAll() async throws {
        var requests: [FeedRefreshRequest] = []
        try await withController(configure: { $0.defaultPage = NavigationDestination.episodes.rawValue }, library: true,
                                 refreshed: { requests.append($0) }) { controller, _ in
            controller.selectTag(NavigationDestination.queue.rawValue)
            controller.drawerAction(.settings)
            controller.openExternal(.shortcut(.refresh))
            #expect(!controller.settingsVisible)
            #expect(controller.rootNavigationTag == NavigationDestination.episodes.rawValue)
            try await wait { requests.count == 1 }
            #expect(requests.first?.feedID == nil)
            // Page actions do not refresh.
            controller.openExternal(.shortcut(.queue))
            try await Task.sleep(for: .milliseconds(200))
            #expect(requests.count == 1)
        }
        try await withController(configure: { $0.defaultPage = "remember"; $0.lastPage = NavigationDestination.inbox.rawValue }) { controller, _ in
            controller.selectTag(NavigationDestination.history.rawValue)
            controller.openExternal(.shortcut(.refresh))
            // The remembered page is the last one opened (history), as a relaunch would show.
            #expect(controller.rootNavigationTag == NavigationDestination.history.rawValue)
        }
    }

    /// A route delivered before the screen is in a window (cold launch) runs when it first appears.
    @Test func coldRouteWaitsForTheScreen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("M34Cold-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let navigation = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
        let controller = LibraryViewController(library: nil, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil,
            mobileNetworkPreferences: nil, usage: nil)
        controller.openExternal(.shortcut(.subscriptions))
        #expect(controller.pendingExternalRoute == .shortcut(.subscriptions))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { closeTestWindow(window, restoringKey: previous) }
        try await wait { controller.pendingExternalRoute == nil }
        #expect(controller.rootNavigationTag == NavigationDestination.subscriptions.rawValue)
    }

    /// App Intents hand Android's App Action routes to the app; Open replaces the page, Search opens
    /// the library search with the query submitted and without the keyboard.
    @Test func intentsRouteOpenPageAndSearch() async throws {
        var routes: [ExternalEntry.Route] = []
        let original = EntryIntentRouter.handler
        EntryIntentRouter.handler = { routes.append($0) }
        defer { EntryIntentRouter.handler = original }
        for page in AntennaPodPage.allCases { _ = try await OpenPageIntent(page: page).perform() }
        _ = try await SearchLibraryIntent(query: "news").perform()
        #expect(routes == [.openPage(.queue), .openPage(.episodes), .openPage(.downloads), .openPage(.subscriptions),
                           .openPage(.history), .search("news")])
        // The Page parameter's choices carry Android's labels (actions.xml entity names).
        let labels = AntennaPodPage.allCases.map { String(localized: AntennaPodPage.caseDisplayRepresentations[$0]!.title) }
        #expect(labels == ["Queue", "Episodes", "Downloads", "Subscriptions", "Playback history"])

        try await withController(library: true) { controller, _ in
            controller.drawerAction(.settings)
            controller.openExternal(.openPage(.history))
            #expect(!controller.settingsVisible && controller.path.count == 1)
            #expect(controller.rootNavigationTag == NavigationDestination.history.rawValue)
            controller.openExternal(.search("news"))
            guard case .search(let search) = controller.path.last else { Issue.record("no search"); return }
            #expect(controller.path.count == 2) // on top of the current page, as loadChildFragment
            #expect(search.field.text == "news" && search.session.query == "news")
            try await Task.sleep(for: .milliseconds(100))
            #expect(!search.field.isFirstResponder)
        }
    }

    /// iOS adaptation: an RSS document opens the preview of its own address; one without an address
    /// shows Android's no-podcast error; the preview is not a manual address (no Edit feed URL).
    @Test func feedDocumentsOpenThePreviewOfTheirAddress() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("M34Docs-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let address = "http://127.0.0.1:9/m34-\(UUID().uuidString).xml"
        let withSelf = folder.appendingPathComponent("feed.rss"), without = folder.appendingPathComponent("plain.rss")
        try Data("<rss xmlns:atom=\"http://www.w3.org/2005/Atom\"><channel><title>T</title><atom:link rel=\"self\" href=\"\(address)\"/></channel></rss>".utf8).write(to: withSelf)
        try Data("<rss><channel><title>T</title></channel></rss>".utf8).write(to: without)

        try await withController(library: true) { controller, _ in
            #expect(controller.openExternalURL(withSelf))
            try await wait { controller.presentedViewController is FeedPreviewController }
            let preview = try #require(controller.presentedViewController as? FeedPreviewController)
            // The download fails (nothing listens); the error names the document's own address.
            try await wait { preview.presentedViewController is SourceMessageController }
            let error = try #require(preview.presentedViewController)
            #expect(texts(in: error.view).contains { $0.contains(address) })
            #expect(!texts(in: error.view).contains(Appearance.text("edit_url_menu")))
            controller.dismiss(animated: false)
            try await wait { controller.presentedViewController == nil }

            #expect(controller.openExternalURL(without))
            try await wait { (controller.presentedViewController?.presentedViewController as? SourceMessageController) != nil }
            let noPodcast = try #require(controller.presentedViewController?.presentedViewController)
            #expect(texts(in: noPodcast.view).contains(Appearance.text("null_value_podcast_error")))
            #expect(texts(in: noPodcast.view).contains("Error"))
            controller.dismiss(animated: false)
            try await wait { controller.presentedViewController == nil }

            // An OPML document keeps the OPML import screen.
            let opml = folder.appendingPathComponent("list.opml")
            try Data("<opml version=\"2.0\"><head/><body><outline text=\"A\" xmlUrl=\"https://example.com/a.xml\"/></body></opml>".utf8).write(to: opml)
            #expect(controller.openExternalURL(opml))
            try await wait { controller.presentedViewController is OPMLImportController }
        }
    }

    /// Text handed over by the Share Extension opens the
    /// preview of its first link — words around it, AntennaPod's own share text with a ':' in the title —
    /// and text without a link shows the no-podcast error.
    @Test func sharedTextOpensThePreviewOfItsFirstLink() async throws {
        let first = "http://127.0.0.1:9/m34-first-\(UUID().uuidString).xml"
        let second = "http://127.0.0.1:9/m34-second-\(UUID().uuidString).xml"
        let shared = "http://127.0.0.1:9/m34-shared-\(UUID().uuidString).xml"
        try await withController(library: true) { controller, _ in
            for (text, address) in [("Listen to this: \(first), then \(second) too!", first),
                                    (FeedShareText.make(title: "Planet Money: The Indicator", source: shared), shared)] {
                #expect(controller.openExternalURL(try #require(ShareHandoff.url(text: text))))
                try await wait { controller.presentedViewController is FeedPreviewController }
                let preview = try #require(controller.presentedViewController as? FeedPreviewController)
                // The download fails (nothing listens); the error names the link, not the words around it.
                try await wait { preview.presentedViewController is SourceMessageController }
                let error = try #require(preview.presentedViewController)
                #expect(texts(in: error.view).contains { $0.contains(address) }, "\(texts(in: error.view))")
                #expect(!texts(in: error.view).contains { $0.contains("Listen") || $0.contains("Planet") || $0.contains(second) })
                #expect(!texts(in: error.view).contains(Appearance.text("edit_url_menu")))
                controller.dismiss(animated: false)
                try await wait { controller.presentedViewController == nil }
            }

            #expect(controller.openExternalURL(try #require(ShareHandoff.url(text: "Listen to this podcast, it is great"))))
            try await wait { (controller.presentedViewController?.presentedViewController as? SourceMessageController) != nil }
            let noPodcast = try #require(controller.presentedViewController?.presentedViewController)
            #expect(texts(in: noPodcast.view).contains(Appearance.text("null_value_podcast_error")))
            #expect(texts(in: noPodcast.view).contains("Error"))
            controller.dismiss(animated: false)
            try await wait { controller.presentedViewController == nil }
        }
    }
}
