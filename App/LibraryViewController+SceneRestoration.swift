import UIKit
import NotTennaPodCore

// Where a window was. Android's FragmentManager restores MainActivity's screen and back stack, and its bottom
// sheet the expanded player, after the system ended the process; UIKit hands a scene the activity it saved when the
// scene went to the background, when it reconnects a session it reclaimed (iPad, Duo) or the app starts again after
// iOS ended it. A window that is new, or that the person closed or swiped away, has none and opens on the start page.

extension SceneNavigationState {
    /// The scene's restoration activity: only for restoring this window, never handed off, indexed or suggested.
    var activity: NSUserActivity {
        let activity = NSUserActivity(activityType: Self.activityType)
        activity.isEligibleForHandoff = false
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        activity.isEligibleForPrediction = false
        activity.userInfo = userInfo
        return activity
    }

    init?(activity: NSUserActivity?) {
        guard let activity, activity.activityType == Self.activityType else { return nil }
        self.init(userInfo: activity.userInfo)
    }
}

/// A scene's saved place on its way to the scene's main screen. UIKit hands it over at connection, or later
/// (`scene(_:restoreInteractionStateWith:)`) when it could not be read at connection (before the first unlock), and
/// then again before activation; the first one counts. The main screen of a started library takes it once (until
/// the library starts, the scene waits and keeps it to save again).
struct SceneRestorationHandoff {
    private(set) var pending: SceneNavigationState?
    private var received = false

    /// Records the saved place; false when one was already received for this connection.
    @discardableResult mutating func receive(_ activity: NSUserActivity?) -> Bool {
        guard !received, let state = SceneNavigationState(activity: activity) else { return false }
        received = true
        pending = state
        return true
    }

    mutating func take() -> SceneNavigationState? {
        defer { pending = nil }
        return pending
    }

    /// What the scene saves while its place waits for the library.
    var pendingActivity: NSUserActivity? { pending?.activity }
}

extension LibraryViewController {
    /// Where this screen is, for its scene's restoration activity: the library, the stack and the player; nil for a
    /// podcast preview's screen or a screen without a library.
    func sceneNavigationState() -> SceneNavigationState? {
        guard !isPreview, let identity = library?.identityAtOpen?.identity,
              path.count <= SceneNavigationState.maximumScreens else { return nil }
        let screens = path.enumerated().map { index, screen -> SceneNavigationState.Screen in
            switch screen {
            case .destination(let destination): return .destination(destination.rawValue)
            case .archive: return .archive
            case .feed(let id): return .feed(id)
            case .feedInformation(let id): return .feedInformation(id)
            case .feedSettings(let id): return .feedSettings(id)
            case .episode(let feedID, let episodeID):
                let shown = EpisodePagerItem(feedID: feedID, episodeID: episodeID)
                guard let pager = episodePagers[index], pager.model.visible == shown else {
                    return .episode(shown, pager: [shown], index: 0)
                }
                return SceneNavigationState.episode(shown, pager: pager.model.items, index: pager.model.index)
            case .settings(let page): return .settings(page.restorationName)
            case .search(let search):
                return .search(query: search.session.query, feedID: search.session.feedID,
                               feedTitle: search.session.feedTitle, archived: search.session.archived)
            case .onlineSearch(let search):
                return .onlineSearch(query: search.session.submittedQuery, provider: search.session.provider)
            case .discover: return .discover
            case .settingsSearch(let search): return .settingsSearch(query: search.field.text ?? "")
            }
        }
        // A restored expansion still waiting for its episode is saved as expanded until it is applied or given up.
        return SceneNavigationState(library: identity, rootTag: rootNavigationTag, rootDestination: rootDestination.rawValue,
                                    screens: screens, playerExpanded: (playerView?.expansion ?? 0) >= 1 || restoredPlayerExpansion)
    }

    /// Opens the saved place on this new screen: its stack and, once the episode is loaded, the expanded player. Only
    /// for this library (`library_identity`; after an import, a switch or a Keep the saved place names another), never
    /// a root page the navigation settings now hide (the start page shows, as `MainActivity.onResume`), and, when it
    /// arrives `late`, only while nothing has moved this screen yet (no route, no navigation, nothing presented, the
    /// player collapsed). Screens whose podcast or episode is gone are left out at the first library read. The scene
    /// gives this screen its owners first (`SceneDelegate.prepare`): the screens are built with them. Screens that read
    /// the library start at its first read; a settings search's index is built again once the synchronization account
    /// is read, keeping its text. Returns whether the place was taken.
    @discardableResult func restoreSceneNavigation(_ state: SceneNavigationState, late: Bool = false) -> Bool {
        guard !isPreview, library != nil, state.library == library?.identityAtOpen?.identity,
              let rootDestination = NavigationDestination(rawValue: state.rootDestination),
              navigationPreferences?.value.configuration.hiddenTags.contains(state.rootTag) != true else { return false }
        if late {
            guard navigationChanges == 0, pendingExternalRoute == nil, presentedViewController == nil,
                  (playerView?.expansion ?? 0) == 0 else { return false }
        }
        // Everything is read before any screen is built, so a place this version cannot show starts nothing.
        for screen in state.screens {
            switch screen {
            case .destination(let tag):
                guard let destination = NavigationDestination(rawValue: tag), destination != .subscriptionList else { return false }
            case .settings(let name): guard SettingsPage(restorationName: name) != nil else { return false }
            default: break
            }
        }
        var screens: [Screen] = [], pagers: [Int: EpisodePagerState] = [:], starts: [(view: UIView, start: () -> Void)] = []
        var settingsPages: [SettingsPage] = [], settingsSearches: [SettingsSearchView] = []
        for saved in state.screens {
            switch saved {
            case .destination(let tag): screens.append(.destination(NavigationDestination(rawValue: tag)!))
            case .archive: screens.append(.archive)
            case .feed(let id): screens.append(.feed(id))
            case .feedInformation(let id): screens.append(.feedInformation(id))
            case .feedSettings(let id): screens.append(.feedSettings(id))
            case .episode(let shown, let items, let index):
                var model = EpisodePagerModel(items: items, tapped: shown)
                model.select(index)
                pagers[screens.count] = EpisodePagerState(model: model)
                screens.append(.episode(model.visible.feedID, model.visible.episodeID))
            case .settings(let name):
                let page = SettingsPage(restorationName: name)!
                settingsPages.append(page)
                screens.append(.settings(page))
            case .search(let query, let feedID, let feedTitle, let archived):
                guard let search = makeRestoredLibrarySearch(query: query, feedID: feedID, feedTitle: feedTitle, archived: archived) else { return false }
                screens.append(.search(search.view)); starts.append((view: search.view as UIView, start: search.start))
            case .onlineSearch(let query, let provider):
                screens.append(.onlineSearch(makeOnlineSearch(provider: provider, query: query.isEmpty ? nil : query)))
            case .discover:
                let discover = makeDiscover()
                screens.append(.discover(discover.view)); starts.append((view: discover.view as UIView, start: discover.load))
            case .settingsSearch(let query):
                let search = makeSettingsSearch()
                if !query.isEmpty { search.setQuery(query) }
                screens.append(.settingsSearch(search)); settingsSearches.append(search)
            }
        }
        restoredPlayerExpansion = state.playerExpanded
        restoredStarts = starts
        if synchronizationSettings?.loaded == false { settingsSearchesAwaitingAccount = settingsSearches }
        applyRestoredStack(screens, rootTag: state.rootTag, rootDestination: rootDestination, pagers: pagers)
        for page in settingsPages {
            do { try prepareSettingsPage(page) } catch { showError(error) }
        }
        refreshRestoredSettingsSearchIndex()
        return true
    }

    /// The first library read after a restoration: the restored screens that read the library (the search, Discover's
    /// list, which leaves out the podcasts the library has) start, those still in the stack.
    func startRestoredScreens() {
        let starts = restoredStarts
        restoredStarts = []
        for (view, start) in starts where path.contains(where: { $0.restoredView === view }) { start() }
    }

    /// A restored settings search was built before the synchronization account was read: once it is, its index is built
    /// again (the gpodder.net login row exists only while gpodder.net is selected), keeping the text typed.
    func refreshRestoredSettingsSearchIndex() {
        guard !settingsSearchesAwaitingAccount.isEmpty, synchronizationSettings?.loaded != false else { return }
        let searches = settingsSearchesAwaitingAccount
        settingsSearchesAwaitingAccount = []
        let items = settingsSearchItems()
        for search in searches where path.contains(where: { $0.restoredView === search }) { search.replaceItems(items) }
    }

    /// The player as the saved place had it: expanded on the restored episode, once that is loaded, unless a route, the
    /// person's navigation or the person moving the player gave it up first (each clears `restoredPlayerExpansion`,
    /// from the moment the place was taken). A video episode stays collapsed (its own screen is not restored); without
    /// an episode the player stays hidden.
    func expandRestoredPlayer() {
        guard restoredPlayerExpansion, let playback else { restoredPlayerExpansion = false; return }
        Task { [weak self] in
            try? await playback.restore()
            guard let self, restoredPlayerExpansion else { return }
            restoredPlayerExpansion = false
            guard let episode = playback.episode,
                  episode.details.media?.mimeType?.hasPrefix("video/") != true,
                  playback.videoPresentation?.videoDisplayLayer == nil else { return }
            updatePlayer()
            playerView?.setExpanded(true, animated: false)
        }
    }
}

extension LibraryViewController.Screen {
    /// The view a screen holds, if it holds one.
    var restoredView: UIView? {
        switch self {
        case .search(let view): view
        case .onlineSearch(let view): view
        case .discover(let view): view
        case .settingsSearch(let view): view
        default: nil
        }
    }
}
