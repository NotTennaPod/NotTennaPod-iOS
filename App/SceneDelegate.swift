import UIKit
import NotTennaPodCore
import OSLog
import UserNotifications
import BackgroundTasks
import Synchronization

@MainActor
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    /// Where this window was when iOS reclaimed it or ended the app, until a started library's screen takes it.
    var restoration = SceneRestorationHandoff()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene,
              let app = UIApplication.shared.delegate as? AppDelegate else { return }
#if DEBUG
        let window = QueueGestureFixture.makeWindow(scene: scene)
#else
        let window = UIWindow(windowScene: scene)
#endif
        self.window = window
        // UIKit reconnects a session it reclaimed, or the app starts again after iOS ended it: the saved place opens
        // first, then any link, quick action or notification that came with the connection is applied over it.
        restoration.receive(session.stateRestorationActivity)
        installRoot(scene: scene)
        window.makeKeyAndVisible()
        if let url = connectionOptions.urlContexts.sorted(by: { $0.url.absoluteString < $1.url.absoluteString }).first?.url {
            openURL(url)
        }
        // A quick action that launched the app arrives here, not in performActionFor.
        if let item = connectionOptions.shortcutItem, let action = ExternalEntry.QuickAction(type: item.type) {
            withLibraryScreen { $0.openExternal(.shortcut(action)) }
        }
        // A start that waits for protected data is tried again as the scene comes to the foreground.
        app.libraryStartup.retry()
        if let response = connectionOptions.notificationResponse,
           DownloadErrorDelivery.opensDownloadLog(identifier: response.notification.request.identifier,
                                                  category: response.notification.request.content.categoryIdentifier) {
            app.routeDownloadLog(in: window.rootViewController as? LibraryViewController)
        }
#if DEBUG
        // UI tests: a simulated tap on the recorded notification, delivered like a cold launch's response.
        if NotificationRecorder.takeSimulatedTap(directory: app.libraryDirectory) == DownloadErrorDelivery.identifier {
            app.routeDownloadLog(in: window.rootViewController as? LibraryViewController)
        }
#endif
        if let response = connectionOptions.notificationResponse,
           let destination = NativeEpisodeNotifications.destination(identifier: response.notification.request.identifier,
                category: response.notification.request.content.categoryIdentifier,
                userInfo: response.notification.request.content.userInfo) {
            app.routeNotification(destination, in: window.rootViewController as? LibraryViewController)
        }
    }

    /// Creates this scene's root screen from the current application graph (launch and after import).
    func installRoot(scene: UIScene) {
        guard let window, let app = UIApplication.shared.delegate as? AppDelegate else { return }
        let session = scene.session
        window.rootViewController?.dismiss(animated: false)
        // While the library cannot start yet: a wait, or the error of a start that failed.
        if let root = app.libraryStartupRoot() { window.rootViewController = root; return }
        let searchTransport = RedirectingProxyTransport(transport: app.proxyNetwork ?? ProxyNetworkEnvironment(configuration: .init()))
        var podcastSearch = PodcastSearchClient(send: { request in
            let response = try await searchTransport.send(request)
            return (response.body, response.status)
        })
#if DEBUG
        let testArguments = ProcessInfo.processInfo.arguments
        if let id = testArguments.firstIndex(of: "-test-library-id"), id + 1 < testArguments.count,
           UUID(uuidString: testArguments[id + 1]) != nil {
            let onlineSearch = testArguments.contains("-test-online-search"), discovery = testArguments.contains("-test-discovery")
            let live = podcastSearch
            podcastSearch = PodcastSearchClient(send: { request in
                var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                let path = components.percentEncodedPath
                // UI tests never reach the live directories for the Add screen's top list; with
                // -test-discovery every directory request goes to the discovery fixture (port 18820),
                // under a path prefix per host. Only the destination changes; parsing stays real.
                if discovery || path.contains("/rss/toppodcasts/") {
                    let prefix = switch components.host { case "api.podcastindex.org": "/podcastindex"; case "api.fyyd.de": "/fyyd"; default: "/apple" }
                    components.scheme = "http"; components.host = "127.0.0.1"; components.port = 18820
                    components.percentEncodedPath = prefix + path
                } else if onlineSearch {
                    let provider = components.host == "itunes.apple.com" ? "apple" : "index"
                    components.scheme = "http"; components.host = "127.0.0.1"; components.port = 18765
                    components.path = request.url?.path == "/lookup" ? "/directory/lookup" : "/directory/" + provider
                } else { return try await live.sendRequest(request) }
                var local = URLRequest(url: components.url!, timeoutInterval: 10)
                request.allHTTPHeaderFields?.forEach { local.setValue($0.value, forHTTPHeaderField: $0.key) }
                let (data, response) = try await URLSession.shared.data(for: local)
                return (data, (response as! HTTPURLResponse).statusCode)
            })
        }
#endif
        window.rootViewController = LibraryViewController(library: app.library, startupError: app.startupError, downloads: app.downloads, playback: app.playback, timeDisplayPreferences: app.timeDisplayPreferences, navigationPreferences: app.navigationPreferences, speedPreferences: app.speedPreferences, mobileNetworkPreferences: app.mobileNetworkPreferences, usage: app.usage, feedDeletion: app.feedDeletion, manualRefresh: app.manualRefresh, podcastSearch: podcastSearch, feedAuthentication: app.feedAuthentication, automaticDownloadPreferences: app.automaticDownloadPreferences, downloadPreferences: app.downloadPreferences, inboxSwipePreferences: app.inboxSwipePreferences, allEpisodesFilterPreferences: app.allEpisodesFilterPreferences, proxyPreferences: app.proxyPreferences, proxyTransport: app.proxyNetwork, transcriptLoader: app.transcriptLoader, chapterAccess: app.chapterAccess, intervalPreferences: app.intervalPreferences, sleepTimerPreferences: app.sleepTimerPreferences, shownotesScroll: app.shownotesScroll, shownotesNetwork: app.shownotesNetwork ?? .unrestricted, playbackQueuePreferences: app.playbackQueuePreferences, playbackHardwarePreferences: app.playbackHardwarePreferences, queueInteractionPreferences: app.queueInteractionPreferences, queueEffects: {
            guard let store = app.library else { return }
            _ = try await store.consumeFeedRefreshQueueEffects(location: app.accountPolicy?.enqueueLocation ?? .back)
        }, castRuntime: app.castRuntime, synchronizationAccounts: app.synchronizationAccounts, synchronization: app.synchronization, synchronizationDelivery: app.synchronizationDelivery, statisticsPreferences: app.statisticsPreferences, accountPolicy: app.accountPolicy)
        if app.firstLaunchNoticeDue, let controller = window.rootViewController as? LibraryViewController {
            controller.showsFirstLaunchNotice = true
            controller.onFirstLaunchNoticeShown = { [weak app] in app?.recordFirstLaunchNoticeShown() }
        }
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-test-download-log-gestures"),
           let index = arguments.firstIndex(of: "-test-library-id"), index + 1 < arguments.count,
           UUID(uuidString: arguments[index + 1]) != nil, let library = app.library {
            window.rootViewController = DownloadLogGestureFixture(library: library)
        }
        if arguments.contains("-test-notification-delivery"),
           let index = arguments.firstIndex(of: "-test-library-id"), index + 1 < arguments.count,
           UUID(uuidString: arguments[index + 1]) != nil {
            window.rootViewController = NotificationDeliveryFixture(app: app)
        }
        if arguments.contains("-test-message-overflow"),
           let index = arguments.firstIndex(of: "-test-library-id"), index + 1 < arguments.count,
           UUID(uuidString: arguments[index + 1]) != nil {
            window.rootViewController = MessageOverflowFixture()
        }
        if arguments.contains("-test-default-page-overflow"),
           let index = arguments.firstIndex(of: "-test-library-id"), index + 1 < arguments.count,
           UUID(uuidString: arguments[index + 1]) != nil, let preferences = app.navigationPreferences {
            window.rootViewController = DefaultPageOverflowFixture(preferences: preferences)
        }
        if arguments.contains("-test-customization-overflow"),
           let index = arguments.firstIndex(of: "-test-library-id"), index + 1 < arguments.count,
           UUID(uuidString: arguments[index + 1]) != nil, let preferences = app.navigationPreferences {
            window.rootViewController = CustomizationOverflowFixture(preferences: preferences)
        }
#endif
        (window.rootViewController as? LibraryViewController)?.nextcloudRestoration = NextcloudAuthenticationRestoration(
            sceneID: session.persistentIdentifier, namespace: app.nextcloudRestorationNamespace)
        // The saved theme is in place before the first screen is drawn.
        if let interface = app.interfacePreferences { InterfaceTheme.apply(interface.value, to: window) }
        (window.rootViewController as? LibraryViewController)?.interfacePreferences = app.interfacePreferences
        if let controller = window.rootViewController as? LibraryViewController, app.library != nil {
            controller.importDatabase = { [weak app] url in try await app?.importDatabase(from: url) }
            controller.importOutcomeShown = { [weak app] in app?.acknowledgeImportOutcome() }
            controller.restartApplication = { [weak app] in app?.restartLibraryGraph() }
            // Manual exports record their attempts and hold the background grant; read when an export starts.
            controller.exportEnvironment = app.exportAttempts.map { ($0, app.backgroundWork) }
            // Its owners, then the window's saved place, once, on the first screen of a started library (a start may have
            // kept it waiting).
            Self.prepare(controller, owners: SceneScreenOwners(automaticBackup: app.automaticBackup, homePreferences: app.homePreferences,
                discoveryPreferences: app.discoveryPreferences, subscriptionPreferences: app.subscriptionPreferences,
                episodeListPreferences: app.episodeListPreferences, notificationPreferences: app.notificationPreferences,
                settingsSearchHistory: app.settingsSearchHistory), restoration: &restoration)
            // The chosen server library could not be found, so this device's library opened: said once.
            app.connectMissingLibraryNotice(controller)
            // A library switch the Synchronization page asked for and that was applied at once reopens that page.
            controller.reopenSynchronizationAfterSwitchIfNeeded(scene: session.persistentIdentifier)
        }
    }

    /// What the scene gives the main screen of a started library, in this order: the owners its screens read, then the
    /// window's saved place, whose screens are built with those owners.
    @discardableResult
    static func prepare(_ controller: LibraryViewController, owners: SceneScreenOwners, restoration: inout SceneRestorationHandoff) -> Bool {
        controller.automaticBackup = owners.automaticBackup
        controller.homePreferences = owners.homePreferences
        controller.discoveryPreferences = owners.discoveryPreferences
        controller.subscriptionPreferences = owners.subscriptionPreferences
        controller.episodeListPreferences = owners.episodeListPreferences
        controller.notificationPreferences = owners.notificationPreferences
        controller.settingsSearchHistory = owners.settingsSearchHistory
        guard let state = restoration.take() else { return false }
        return controller.restoreSceneNavigation(state)
    }

    /// The saved place UIKit could not hand over at connection (protected data still locked), or the same place again
    /// before activation (then nothing happens). A started library's screen takes a late one only while nothing has
    /// moved it; otherwise it waits for the library's start.
    func scene(_ scene: UIScene, restoreInteractionStateWith stateRestorationActivity: NSUserActivity) {
        guard restoration.receive(stateRestorationActivity),
              let controller = window?.rootViewController as? LibraryViewController, controller.library != nil,
              let state = restoration.take() else { return }
        controller.restoreSceneNavigation(state, late: true)
    }

    /// Where this window is, saved by UIKit as the scene goes to the background. A scene still waiting for its
    /// library keeps the place it was given.
    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        if let controller = window?.rootViewController as? LibraryViewController, controller.library != nil {
            return controller.sceneNavigationState()?.activity
        }
        return restoration.pendingActivity
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        guard let url = contexts.sorted(by: { $0.url.absoluteString < $1.url.absoluteString }).first?.url else { return }
        openURL(url)
    }

    /// Podcast links, the Share Extension's handoff and documents; anything else stays with OPML import.
    private func openURL(_ url: URL) {
        withLibraryScreen { controller in
            if !controller.openExternalURL(url) { controller.openOPMLDocument(url) }
        }
    }

    /// Runs `action` on this scene's main screen of a started library; until the start succeeds, once, right after
    /// it, never on the error screen of a failed start.
    private func withLibraryScreen(_ action: @escaping (LibraryViewController) -> Void) {
        guard let app = UIApplication.shared.delegate as? AppDelegate else { return }
        app.libraryStartup.whenStarted { [weak self] in
            if let controller = self?.window?.rootViewController as? LibraryViewController { action(controller) }
        }
    }

    /// A Home Screen quick action while the app is running.
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        guard let action = ExternalEntry.QuickAction(type: shortcutItem.type),
              window?.rootViewController is LibraryViewController
                || (UIApplication.shared.delegate as? AppDelegate)?.libraryStartup.isStarted == false else {
            completionHandler(false); return
        }
        withLibraryScreen { $0.openExternal(.shortcut(action)) }
        completionHandler(true)
    }

    /// A scene is coming to the foreground: a large publication waiting for the store is not admitted any more
    ///; the scheduler learns of the activation at `sceneDidBecomeActive`. A start that waits for protected
    /// data is tried again.
    func sceneWillEnterForeground(_ scene: UIScene) {
        (UIApplication.shared.delegate as? AppDelegate)?.libraryStartup.retry()
        (UIApplication.shared.delegate as? AppDelegate)?.serverPublicationEligibility?.changed()
        (UIApplication.shared.delegate as? AppDelegate)?.streamingRelayScenesChanged(enteringForeground: true)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Another window of the app may still be in the foreground (iPad, Duo).
        (UIApplication.shared.delegate as? AppDelegate)?.streamingRelayScenesChanged()
        guard !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) else { return }
        (UIApplication.shared.delegate as? AppDelegate)?.periodicRefresh?.setForeground(false)
        // A server library's change hints close in the background; unfinished heavy work asks for processing time.
        (UIApplication.shared.delegate as? AppDelegate)?.serverSync?.setForeground(false)
        (UIApplication.shared.delegate as? AppDelegate)?.scheduleServerSyncBackgroundTasks(refresh: false)
        (UIApplication.shared.delegate as? AppDelegate)?.backgroundWork.enterBackground()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // A start that waits for protected data, or failed, is tried again; once it succeeds, the startup owner
        // calls `libraryBecameActive` for the scenes that are active then. A started library's downloads parked
        // because they could not read their files are tried once more.
        (UIApplication.shared.delegate as? AppDelegate)?.libraryStartup.sceneActivated()
        libraryBecameActive(scene)
    }

    /// What an activation does with the library: at `sceneDidBecomeActive`, and when a start that waited resolved.
    func libraryBecameActive(_ scene: UIScene) {
        guard let app = UIApplication.shared.delegate as? AppDelegate else { return }
        app.streamingRelayScenesChanged(enteringForeground: true)
        app.backgroundWork.enterForeground()
        app.runDatabaseMaintenance()
        app.reconcileBackgroundTransfers()
        app.automaticDownloads?.resume()
        app.resumeRefreshServices()
        app.periodicRefresh?.setForeground(true)
        // A server library exchanges at every activation and listens for the server's change hints.
        app.serverSync?.setForeground(true)
        // A library switch waiting for the activation rule (an interruption that ended without resuming sends no
        // player event).
        app.librarySwitch?.attemptSoon()
        // Routes and reports wait for a started library's screen, never the error screen of a failed start.
        guard app.libraryStartup.isStarted, let controller = window?.rootViewController as? LibraryViewController else { return }
#if DEBUG
        // UI tests: a simulated tap on the recorded notification while the app was in the background.
        if NotificationRecorder.takeSimulatedTap(directory: app.libraryDirectory) == DownloadErrorDelivery.identifier {
            app.pendingDownloadLog = true
        }
#endif
        controller.showMissingLibraryNoticeIfDue()
        app.automaticBackupBecameActive(in: controller)
        app.consumeNotification(in: controller)
        if let route = app.pendingExternalRoute { app.pendingExternalRoute = nil; controller.openExternal(route) }
        controller.restoreNextcloudAuthorizationIfNeeded()
    }
}

/// The application's owners a scene gives its main screen besides the graph (`SceneDelegate.prepare`).
struct SceneScreenOwners {
    var automaticBackup: AutomaticDatabaseExportRuntime?
    var homePreferences: HomeSectionPreferenceStore?
    var discoveryPreferences: DiscoveryPreferenceStore?
    var subscriptionPreferences: SubscriptionDisplayPreferenceStore?
    var episodeListPreferences: EpisodeListPreferenceStore?
    var notificationPreferences: NotificationPreferenceStore?
    var settingsSearchHistory: SettingsSearchHistoryStore?
}
