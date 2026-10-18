import UIKit
import Testing
import Synchronization
@testable import NotTennaPod
@testable import NotTennaPodCore

/// A window iOS reclaimed, or the app iOS ended, opens where the person left it (its screen stack and the expanded
/// player), as Android restores MainActivity's fragments and bottom sheet. Checked with the scene delegate's own
/// save (`stateRestorationActivity`), a binary property-list round trip as UIKit keeps it, and the main screen's restore
/// (what `SceneDelegate.installRoot` does): two windows with different histories; a relaunch on the same library;
/// podcasts and episodes that are gone; another library at the same place; new and closed windows; links, quick actions
/// and notifications that arrive with the window; a window that waits for its library; screens that hold their own
/// text; at iPhone, iPad and Duo sizes, left to right and right to left.
@MainActor @Suite(.serialized)
struct SceneRestorationViewTests {
    struct Library {
        let directory: URL, file: URL
        let podcast: LibraryFeed, other: LibraryFeed
        let navigation: NavigationPreferenceStore, time: TimeDisplayPreferenceStore
        /// The scene's owners the restored screens read (`SceneDelegate.prepare`).
        let discovery: DiscoveryPreferenceStore, history: SettingsSearchHistoryStore
        var identity: String
        var owners: SceneScreenOwners { SceneScreenOwners(discoveryPreferences: discovery, settingsSearchHistory: history) }
    }

    /// Requests the screens make to podcast directories (none leave the test); the top list holds `topList`'s titles.
    final class DirectoryRequests: Sendable {
        let urls = Mutex<[URL]>([])
        let topList: [String]
        init(topList: [String] = []) { self.topList = topList }
        var client: PodcastSearchClient {
            PodcastSearchClient(send: { [self] request in
                urls.withLock { $0.append(request.url!) }
                let entries = topList.enumerated().map { index, title in
                    ["im:name": ["label": title], "im:artist": ["label": "\(title) author"], "id": ["attributes": ["im:id": "\(index + 1)"]],
                     "im:image": [["label": "https://example.invalid/\(index).png", "attributes": ["height": "170"]]]] as [String: Any]
                }
                let body: [String: Any] = ["results": [], "feeds": [], "data": [], "feed": ["entry": entries]]
                return (try JSONSerialization.data(withJSONObject: body), 200)
            })
        }
        func contains(_ host: String, _ text: String) -> Bool {
            urls.withLock { $0.contains { $0.host == host && ($0.query ?? "").contains(text) } }
        }
        func requested(path text: String) -> Bool { urls.withLock { $0.contains { $0.path.contains(text) } } }
        var isEmpty: Bool { urls.withLock { $0.isEmpty } }
    }

    /// Holds the first library read until it is opened (`loadSnapshot`), as a slow first read does.
    final class Gate: Sendable {
        private let state = Mutex<(open: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))
        func wait() async {
            await withCheckedContinuation { continuation in
                let open = state.withLock { value -> Bool in
                    if !value.open { value.waiting.append(continuation) }
                    return value.open
                }
                if open { continuation.resume() }
            }
        }
        func open() {
            let waiting = state.withLock { value -> [CheckedContinuation<Void, Never>] in
                value.open = true
                defer { value.waiting = [] }
                return value.waiting
            }
            waiting.forEach { $0.resume() }
        }
    }

    private func held(_ store: FeedLibraryStore, _ gate: Gate) -> @Sendable () async throws -> FeedLibrarySnapshot {
        { await gate.wait(); return try await store.snapshot() }
    }

    // MARK: Fixtures

    private func feed(_ title: String, _ count: Int, prefix: String) -> FetchedFeed {
        let source = URL(string: "https://example.invalid/\(prefix).xml")!
        return FetchedFeed(feed: ParsedFeed(format: .rss, title: title, author: "\(title) author", episodes: (1...count).map {
            ParsedEpisode(identifier: "\(prefix)-\($0)", title: "\(title) episode \($0)", description: "Notes \($0)",
                          media: ParsedMedia(url: "https://example.invalid/\(prefix)-\($0).mp3", size: 0, mimeType: "audio/mpeg",
                                             durationMilliseconds: 600_000))
        }), source: source.absoluteString, responseURL: source, validator: nil, permanentRedirectURL: nil)
    }

    /// A library with two podcasts (five and three episodes), the third episode selected in the player, and a start
    /// page (Queue) that differs from every restored page.
    private func withLibrary(selected: Bool = true, _ body: (Library, FeedLibraryStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SceneRestoration-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: file)
        do {
            let podcast = try await store.insert(feed("Restored podcast", 5, prefix: "restored"))
            let other = try await store.insert(feed("Other podcast", 3, prefix: "other"))
            if selected { _ = try await store.beginPlayback(episodeID: podcast.episodes[2].id) }
            let navigation = try NavigationPreferenceStore(file: directory.appendingPathComponent("navigation.json"))
            var value = navigation.value; value.defaultPage = NavigationDestination.queue.rawValue; try navigation.update(value)
            let library = Library(directory: directory, file: file, podcast: podcast, other: other, navigation: navigation,
                                  time: try TimeDisplayPreferenceStore(file: directory.appendingPathComponent("time.json")),
                                  discovery: try DiscoveryPreferenceStore(file: directory.appendingPathComponent("discovery.json")),
                                  history: try SettingsSearchHistoryStore(file: directory.appendingPathComponent("settings-search-history.json")),
                                  identity: try #require(store.identityAtOpen?.identity))
            try await body(library, store)
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

    private func screen(_ library: Library, store: FeedLibraryStore, playback: PlaybackCoordinator? = nil,
                        directories: DirectoryRequests = .init(),
                        loadSnapshot: (@Sendable () async throws -> FeedLibrarySnapshot)? = nil) -> LibraryViewController {
        LibraryViewController(library: store, startupError: nil, downloads: nil,
            playback: playback ?? PlaybackCoordinator(store: store, engine: AVPlayerPlaybackEngine(muted: true)),
            timeDisplayPreferences: library.time, navigationPreferences: library.navigation, speedPreferences: nil,
            mobileNetworkPreferences: nil, usage: nil, loadSnapshot: loadSnapshot, podcastSearch: directories.client)
    }

    private var scene: UIWindowScene {
        get throws {
            try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
        }
    }

    /// The screen in a window of its own, as a scene's root; the window is closed afterwards (the scene reclaimed).
    private func shown(_ controller: LibraryViewController, rtl: Bool = false, loaded: Bool = true,
                       _ body: (UIWindow) async throws -> Void) async throws {
        let scene = try self.scene
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        if rtl { window.traitOverrides.layoutDirection = .rightToLeft }
        controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { closeTestWindow(window, restoringKey: previous) }
        try await wait { controller.viewIfLoaded?.window != nil && (!loaded || controller.libraryLoaded) }
        try await body(window)
    }

    private func wait(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let end = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    private func element<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if let value = view as? T, value.accessibilityIdentifier == id { return value }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: type) }.first
    }

    /// The scene's saved place as UIKit keeps it: from the scene delegate, through a binary property list.
    private func saved(_ window: UIWindow) throws -> NSUserActivity {
        let scene = try self.scene, delegate = SceneDelegate()
        delegate.window = window
        let activity = try #require(delegate.stateRestorationActivity(for: scene))
        #expect(activity.activityType == "org.nottennapod.app.scene-restoration")
        #expect(!activity.isEligibleForHandoff && !activity.isEligibleForSearch && !activity.isEligibleForPrediction)
        let data = try PropertyListSerialization.data(fromPropertyList: try #require(activity.userInfo), format: .binary, options: 0)
        let copy = NSUserActivity(activityType: activity.activityType)
        copy.userInfo = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [AnyHashable: Any])
        return copy
    }

    /// What `SceneDelegate.installRoot` does with a connection's saved place and a new main screen of a started library:
    /// the scene's owners, then the place (`SceneDelegate.prepare`).
    @discardableResult
    private func restore(_ activity: NSUserActivity?, on controller: LibraryViewController,
                         owners: SceneScreenOwners = SceneScreenOwners()) -> Bool {
        var handoff = SceneRestorationHandoff()
        handoff.receive(activity)
        return SceneDelegate.prepare(controller, owners: owners, restoration: &handoff)
    }

    private func names(_ controller: LibraryViewController) -> [String] {
        controller.path.map { screen in
            switch screen {
            case .destination(let destination): "destination:\(destination.rawValue)"
            case .archive: "archive"
            case .feed(let id): "feed:\(id)"
            case .feedInformation(let id): "feedInformation:\(id)"
            case .feedSettings(let id): "feedSettings:\(id)"
            case .episode(let feed, let episode): "episode:\(feed)/\(episode)"
            case .settings(let page): "settings:\(page.restorationName)"
            case .search(let search): "search:\(search.session.query)|\(search.session.feedID.map(String.init) ?? "-")|\(search.session.archived)"
            case .onlineSearch(let search): "onlineSearch:\(search.session.submittedQuery)|\(search.session.provider.restorationName)"
            case .discover: "discover"
            case .settingsSearch(let search): "settingsSearch:\(search.field.text ?? "")"
            }
        }
    }

    private func pager(_ controller: LibraryViewController) -> EpisodePagerModel? {
        controller.episodePagers[controller.path.count - 1]?.model
    }

    /// The expansion task has run (or never will): the restored episode was loaded and the player expanded or not.
    private func settled(_ controller: LibraryViewController) async throws {
        try await wait { !controller.restoredPlayerExpansion && !controller.restoredNavigationNeedsCheck }
        if let playback = controller.playback { try await playback.restore() }
        await Task.yield()
    }

    // MARK: Tests

    /// UIKit keeps a scene's restoration activity only when the app declares its type.
    @Test func theRestorationActivityTypeIsDeclared() throws {
        let types = try #require(Bundle.main.infoDictionary?["NSUserActivityTypes"] as? [String])
        #expect(types == [SceneNavigationState.activityType])
        #expect(SceneNavigationState.activityType == "org.nottennapod.app.scene-restoration")
    }

    /// Two windows on one library, each with its own history: one at a podcast's episode (opened from the podcast's
    /// list, the player expanded), one at Settings → Playback over Queue. Each window's saved place reopens only its
    /// own stack, pager and player, at iPhone, iPad and Duo sizes and in both directions.
    @Test(arguments: [false, true])
    func twoWindowsWithDifferentHistoriesEachReopenWhereTheyWere(rtl: Bool) async throws {
        try await withLibrary { library, store in
            let playback = PlaybackCoordinator(store: store, engine: AVPlayerPlaybackEngine(muted: true))
            let first = screen(library, store: store, playback: playback), second = screen(library, store: store, playback: playback)
            let items = library.podcast.episodes.map { EpisodePagerItem(feedID: library.podcast.id, episodeID: $0.id) }
            var firstSaved: NSUserActivity?, secondSaved: NSUserActivity?
            var firstNames: [String] = [], secondNames: [String] = []
            try await shown(first, rtl: rtl) { window in
                first.selectTag(NavigationDestination.subscriptions.rawValue)
                first.push(.feed(library.podcast.id))
                first.openEpisode(feedID: library.podcast.id, episodeID: library.podcast.episodes[1].id, list: items)
                try await wait { first.playerView?.isHidden == false }
                first.playerView?.setExpanded(true, animated: false)
                firstNames = names(first)
                firstSaved = try saved(window)
            }
            try await shown(second, rtl: rtl) { window in
                second.selectTag(NavigationDestination.queue.rawValue)
                second.drawerAction(.settings)
                second.openSettingsPage(.playback)
                secondNames = names(second)
                secondSaved = try saved(window)
            }
            #expect(firstNames == ["destination:SubscriptionFragment", "feed:\(library.podcast.id)",
                                   "episode:\(library.podcast.id)/\(library.podcast.episodes[1].id)"])
            #expect(secondNames == ["destination:QueueFragment", "settings:main", "settings:playback"])

            // The windows were reclaimed; UIKit reconnects them with their sessions.
            let firstAgain = screen(library, store: store, playback: playback), secondAgain = screen(library, store: store, playback: playback)
            let firstRestored = restore(firstSaved, on: firstAgain, owners: library.owners)
            let secondRestored = restore(secondSaved, on: secondAgain, owners: library.owners)
            #expect(firstRestored && secondRestored)
            try await shown(firstAgain, rtl: rtl) { window in
                try await settled(firstAgain)
                #expect(names(firstAgain) == firstNames)
                #expect(firstAgain.rootNavigationTag == NavigationDestination.subscriptions.rawValue)
                #expect(pager(firstAgain)?.items == items && pager(firstAgain)?.index == 1, "the pager of the podcast's list")
                try await wait { firstAgain.episodeDetailsID == library.podcast.episodes[1].id }
                try await wait { firstAgain.playerView?.expansion == 1 }
                #expect(playback.episode?.id == library.podcast.episodes[2].id && !playback.wantsPlayback, "restored, not playing")
                try checkLayout(firstAgain, in: window, rtl: rtl, title: "", playerExpanded: true)
                // Back goes where it went: collapse the player, then the podcast, then Subscriptions.
                #expect(firstAgain.accessibilityPerformEscape())
                #expect(firstAgain.playerView?.expansion == 0)
                #expect(firstAgain.accessibilityPerformEscape())
                #expect(names(firstAgain) == Array(firstNames.prefix(2)))
            }
            try await shown(secondAgain, rtl: rtl) { window in
                try await settled(secondAgain)
                #expect(names(secondAgain) == secondNames)
                #expect(secondAgain.rootNavigationTag == NavigationDestination.queue.rawValue)
                #expect(secondAgain.playerView?.expansion == 0, "this window's player was collapsed")
                try checkLayout(secondAgain, in: window, rtl: rtl, title: "Playback", playerExpanded: false)
                #expect(secondAgain.accessibilityPerformEscape())
                #expect(names(secondAgain) == Array(secondNames.prefix(2)))
            }
        }
    }

    /// The restored screen at the iPhone, iPad and Duo sizes: its title, and its Back button where the direction puts it,
    /// inside the safe area; the expanded player inside the window.
    private func checkLayout(_ controller: LibraryViewController, in window: UIWindow, rtl: Bool, title: String,
                             playerExpanded: Bool) throws {
        let own = window.bounds.size
        for size in [own, CGSize(width: 402, height: 874), CGSize(width: 874, height: 402), CGSize(width: 1024, height: 1366),
                     CGSize(width: 1366, height: 1024), CGSize(width: 540, height: 720), CGSize(width: 1114, height: 720)] {
            controller.view.frame = CGRect(origin: .zero, size: size)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            let back: UIView = try #require(element("toolbarBack", in: controller.view), "Back at \(size)")
            let heading: UILabel = try #require(element("screenTitle", in: controller.view), "title at \(size)")
            #expect((heading.text ?? "") == title, "title at \(size)")
            let safe = controller.view.safeAreaLayoutGuide.layoutFrame
            let frame = back.convert(back.bounds, to: controller.view)
            #expect(safe.insetBy(dx: -0.5, dy: -0.5).contains(frame), "Back inside the safe area at \(size): \(frame) in \(safe)")
            #expect(rtl ? frame.midX > safe.midX : frame.midX < safe.midX, "Back on the leading side at \(size)")
            if playerExpanded {
                let player = try #require(controller.playerView)
                #expect(player.expansion == 1 && !player.isHidden)
                let collapse: UIView = try #require(element("playerCollapse", in: player))
                let collapseFrame = collapse.convert(collapse.bounds, to: controller.view)
                #expect(controller.view.bounds.contains(collapseFrame), "the expanded player's collapse button at \(size)")
            }
        }
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    }

    /// The app restarts after iOS ended it: a new store on the same library file (same `library_identity`), a new
    /// player that restores the selection without playing, and the saved place reopens with the player expanded.
    @Test func relaunchOnTheSameLibraryReopensTheEpisodeAndThePlayer() async throws {
        try await withLibrary { library, store in
            let items = library.other.episodes.map { EpisodePagerItem(feedID: library.other.id, episodeID: $0.id) }
            let before = screen(library, store: store)
            var activity: NSUserActivity?
            var expected: [String] = []
            try await shown(before) { window in
                before.selectTag(NavigationDestination.episodes.rawValue)
                before.openEpisode(feedID: library.other.id, episodeID: library.other.episodes[2].id, list: items)
                try await wait { before.playerView?.isHidden == false }
                before.playerView?.setExpanded(true, animated: false)
                expected = names(before)
                activity = try saved(window)
            }
            try await store.close()
            let relaunched = try FeedLibraryStore(url: library.file)
            do {
                #expect(relaunched.identityAtOpen?.identity == library.identity)
                let playback = PlaybackCoordinator(store: relaunched, engine: AVPlayerPlaybackEngine(muted: true))
                let after = screen(library, store: relaunched, playback: playback)
                #expect(restore(activity, on: after))
                try await shown(after) { _ in
                    try await settled(after)
                    #expect(names(after) == expected)
                    #expect(pager(after)?.items == items && pager(after)?.index == 2)
                    try await wait { after.playerView?.expansion == 1 }
                    #expect(playback.episode?.id == library.podcast.episodes[2].id && !playback.wantsPlayback)
                }
                try await relaunched.close()
            } catch { try? await relaunched.close(); throw error }
            // `withLibrary` closes its own store again; that is harmless.
        }
    }

    /// Saved screens whose podcast or episode is gone (removed here or elsewhere) are left out at the first library
    /// read, so the nearest screen that still exists shows; a root podcast that is gone gives way to the start page. Never
    /// another item, never an empty episode page.
    @Test func goneScreensFallBackToTheNearestScreenThatExists() async throws {
        try await withLibrary { library, store in
            let podcast = library.podcast.id, missing: Int64 = 999_999
            let episode = SceneNavigationState.Screen.episode(.init(feedID: podcast, episodeID: missing),
                                                              pager: [.init(feedID: podcast, episodeID: missing)], index: 0)
            let neighbours = library.podcast.episodes.prefix(2).map { EpisodePagerItem(feedID: podcast, episodeID: $0.id) }
                + [EpisodePagerItem(feedID: podcast, episodeID: missing)]
            let cases: [(root: String, screens: [SceneNavigationState.Screen], expected: [String], tag: String)] = [
                ("SubscriptionFragment", [.destination("SubscriptionFragment"), .feed(missing)], ["destination:SubscriptionFragment"], "SubscriptionFragment"),
                ("SubscriptionFragment", [.destination("SubscriptionFragment"), .feed(podcast), episode],
                 ["destination:SubscriptionFragment", "feed:\(podcast)"], "SubscriptionFragment"),
                ("HomeFragment", [.destination("HomeFragment"), .feed(missing), .feedInformation(missing), .settings("main")],
                 ["destination:HomeFragment", "settings:main"], "HomeFragment"),
                ("HomeFragment", [.destination("HomeFragment"), .search(query: "episode", feedID: missing, feedTitle: "Gone", archived: false)],
                 ["destination:HomeFragment"], "HomeFragment"),
                // A podcast opened from the drawer that is gone: the start page (Queue), as a new window.
                ("\(missing)", [.feed(missing), .feedSettings(missing)], ["destination:QueueFragment"], "QueueFragment"),
                // A missing neighbour stays a blank page of the pager, as when it is removed while the pager is open.
                ("EpisodesFragment", [.destination("EpisodesFragment"), SceneNavigationState.episode(neighbours[1], pager: neighbours, index: 1)],
                 ["destination:EpisodesFragment", "episode:\(podcast)/\(neighbours[1].episodeID)"], "EpisodesFragment"),
            ]
            for (root, screens, expected, tag) in cases {
                let state = SceneNavigationState(library: library.identity, rootTag: root,
                    rootDestination: root == "\(missing)" ? "SubscriptionFragment" : root, screens: screens, playerExpanded: true)
                let controller = screen(library, store: store)
                #expect(controller.restoreSceneNavigation(state))
                try await shown(controller) { _ in
                    try await settled(controller)
                    #expect(names(controller) == expected, "\(screens)")
                    #expect(controller.rootNavigationTag == tag)
                    if case .episode(_, let id) = controller.path.last {
                        try await wait { controller.episodeDetailsID == id }
                        #expect(pager(controller)?.items == neighbours)
                    } else {
                        #expect(controller.episodeDetailsID == nil, "no episode page")
                    }
                    // The player still opens as it was: the selected episode exists.
                    try await wait { controller.playerView?.expansion == 1 }
                }
            }
        }
    }

    /// A saved place this version cannot show, or one whose root page the navigation settings now hide, restores
    /// nothing: the start page shows, as for a new window.
    @Test func unreadableOrHiddenPlacesOpenTheStartPage() async throws {
        try await withLibrary { library, store in
            let states = [
                SceneNavigationState(library: library.identity, rootTag: "UnknownFragment", rootDestination: "UnknownFragment",
                                     screens: [.destination("UnknownFragment")], playerExpanded: false),
                SceneNavigationState(library: library.identity, rootTag: "HomeFragment", rootDestination: "HomeFragment",
                                     screens: [.destination("HomeFragment"), .settings("removedPage")], playerExpanded: true),
                SceneNavigationState(library: library.identity, rootTag: "SubscriptionList", rootDestination: "SubscriptionList",
                                     screens: [.destination("SubscriptionList")], playerExpanded: false),
            ]
            for state in states {
                let controller = screen(library, store: store)
                #expect(!controller.restoreSceneNavigation(state))
                try await shown(controller) { _ in
                    try await settled(controller)
                    #expect(names(controller) == ["destination:QueueFragment"])
                    #expect(controller.playerView?.expansion == 0)
                }
            }
            var value = library.navigation.value
            value.configuration.hiddenTags = [NavigationDestination.statistics.rawValue]
            try library.navigation.update(value)
            let hidden = SceneNavigationState(library: library.identity, rootTag: "StatisticsFragment", rootDestination: "StatisticsFragment",
                                              screens: [.destination("StatisticsFragment"), .settings("main")], playerExpanded: false)
            let controller = screen(library, store: store)
            #expect(!controller.restoreSceneNavigation(hidden))
            #expect(names(controller) == ["destination:QueueFragment"])
        }
    }

    /// Another library at the same place (a database import replaces the file with a new library; a switch or a Keep
    /// opens another): the saved place names the old library's identity and restores nothing, even though the new
    /// library has a podcast and episodes with the same IDs. Never another library's item.
    @Test func anotherLibraryRestoresNothingEvenWithTheSameIDs() async throws {
        var activity: NSUserActivity?
        var savedPath: [String] = []
        var savedIdentity = ""
        try await withLibrary { library, store in
            savedIdentity = library.identity
            let controller = screen(library, store: store)
            try await shown(controller) { window in
                controller.selectTag(NavigationDestination.subscriptions.rawValue)
                controller.push(.feed(library.podcast.id))
                controller.openEpisode(feedID: library.podcast.id, episodeID: library.podcast.episodes[0].id,
                                       list: [.init(feedID: library.podcast.id, episodeID: library.podcast.episodes[0].id)])
                savedPath = names(controller)
                activity = try saved(window)
            }
            // The same file, replaced by a new library with the same IDs.
            try await store.close()
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: library.file.path + suffix)) }
            let replaced = try FeedLibraryStore(url: library.file)
            do {
                let same = try await replaced.insert(feed("Replacement podcast", 5, prefix: "replacement"))
                #expect(same.id == library.podcast.id && same.episodes[0].id == library.podcast.episodes[0].id, "the IDs repeat")
                #expect(replaced.identityAtOpen?.identity != savedIdentity)
                let controller = screen(library, store: replaced)
                #expect(!controller.restoreSceneNavigation(try #require(SceneNavigationState(activity: activity))))
                try await shown(controller) { _ in
                    try await settled(controller)
                    #expect(names(controller) == ["destination:QueueFragment"])
                    #expect(controller.episodeDetailsID == nil && controller.playerView?.expansion == 0)
                }
                try await replaced.close()
            } catch { try? await replaced.close(); throw error }
        }
        #expect(savedPath.count == 3)
    }

    /// A new window, or the window of a session the person closed (UIKit discards its saved place with it), connects
    /// without a saved place and opens the start page with the player collapsed. A saved place of another kind or
    /// format is ignored; the saved place of a start page restores just that.
    @Test func newAndClosedWindowsOpenTheStartPage() async throws {
        try await withLibrary { library, store in
            var handoff = SceneRestorationHandoff()
            let none = handoff.receive(nil)
            #expect(!none && handoff.take() == nil && handoff.pendingActivity == nil)
            let foreign = NSUserActivity(activityType: "org.nottennapod.app.other")
            foreign.userInfo = SceneNavigationState(library: library.identity, rootTag: "HomeFragment", rootDestination: "HomeFragment",
                                                    screens: [.destination("HomeFragment")], playerExpanded: true).userInfo
            let other = handoff.receive(foreign)
            #expect(!other && handoff.take() == nil)
            let future = NSUserActivity(activityType: SceneNavigationState.activityType)
            future.userInfo = ["version": 2, "library": library.identity]
            let unknown = handoff.receive(future)
            #expect(!unknown && handoff.take() == nil)

            let fresh = screen(library, store: store)
            #expect(!restore(nil, on: fresh))
            var startPage: NSUserActivity?
            try await shown(fresh) { window in
                try await settled(fresh)
                #expect(names(fresh) == ["destination:QueueFragment"] && fresh.playerView?.expansion == 0)
                startPage = try saved(window)
            }
            let again = screen(library, store: store)
            #expect(restore(startPage, on: again))
            try await shown(again) { _ in
                try await settled(again)
                #expect(names(again) == ["destination:QueueFragment"] && again.playerView?.expansion == 0)
            }
        }
    }

    /// Links, quick actions, notifications and widget buttons that arrive with the window run after the saved place
    /// opens and decide what shows: a quick action or a notification opens its page and the restored player stays
    /// collapsed; a podcast link opens its preview over the restored screens. A saved place UIKit hands over late is
    /// taken only while nothing has moved the screen.
    @Test func incomingRoutesTakePrecedenceOverTheSavedPlace() async throws {
        try await withLibrary { library, store in
            let podcast = library.podcast
            let place = SceneNavigationState(library: library.identity, rootTag: "SubscriptionFragment", rootDestination: "SubscriptionFragment",
                screens: [.destination("SubscriptionFragment"), .feed(podcast.id),
                          SceneNavigationState.episode(.init(feedID: podcast.id, episodeID: podcast.episodes[3].id),
                                                       pager: [.init(feedID: podcast.id, episodeID: podcast.episodes[3].id)], index: 0)],
                playerExpanded: true)
            let scene = try self.scene
            let restoredNames = ["destination:SubscriptionFragment", "feed:\(podcast.id)", "episode:\(podcast.id)/\(podcast.episodes[3].id)"]

            // A quick action delivered with the connection, before the screen appears.
            let quick = screen(library, store: store)
            #expect(quick.restoreSceneNavigation(place))
            quick.openExternal(.shortcut(.episodes))
            try await shown(quick) { _ in
                try await settled(quick)
                #expect(names(quick) == ["destination:EpisodesFragment"])
                #expect(quick.playerView?.expansion == 0, "the quick action's fresh main screen, player collapsed")
            }

            // A notification for a podcast.
            let notified = screen(library, store: store)
            #expect(notified.restoreSceneNavigation(place))
            try await shown(notified) { _ in
                await notified.openNotification(.feed(library.other.id))
                try await settled(notified)
                #expect(names(notified) == ["feed:\(library.other.id)"])
                #expect(notified.playerView?.expansion == 0)
            }

            // A link with no podcast in it: its preview opens over the restored screens.
            let linked = screen(library, store: store)
            #expect(linked.restoreSceneNavigation(place))
            linked.openExternal(.noPodcast)
            try await shown(linked) { _ in
                try await wait { linked.presentedViewController is FeedPreviewController }
                try await settled(linked)
                #expect(names(linked) == restoredNames, "the restored screens stay under the preview")
                linked.dismiss(animated: false)
            }

            // A widget's "open the player" over the restored screens: the player opens, the screens stay.
            let widget = screen(library, store: store)
            #expect(widget.restoreSceneNavigation(SceneNavigationState(library: place.library, rootTag: place.rootTag,
                rootDestination: place.rootDestination, screens: place.screens, playerExpanded: false)))
            widget.openExternal(.openPlayer)
            try await shown(widget) { _ in
                try await settled(widget)
                try await wait { widget.playerView?.expansion == 1 }
                #expect(names(widget) == restoredNames)
            }

            // Late: a screen that a route already moved keeps what the route opened.
            let moved = screen(library, store: store)
            try await shown(moved) { window in
                moved.openExternal(.openPage(.history))
                let delegate = SceneDelegate()
                delegate.window = window
                let activity = place.activity
                delegate.scene(scene, restoreInteractionStateWith: activity)
                try await settled(moved)
                #expect(names(moved) == ["destination:PlaybackHistoryFragment"])
                #expect(moved.playerView?.expansion == 0)
            }

            // Late, on a screen nothing has moved: the place opens at once, checked against the library already read.
            let untouched = screen(library, store: store)
            try await shown(untouched) { window in
                let delegate = SceneDelegate()
                delegate.window = window
                delegate.scene(scene, restoreInteractionStateWith: place.activity)
                try await settled(untouched)
                #expect(names(untouched) == restoredNames)
                try await wait { untouched.playerView?.expansion == 1 }
                // The same place handed over again before activation changes nothing.
                untouched.playerView?.setExpanded(false, animated: false)
                untouched.selectTag(NavigationDestination.inbox.rawValue)
                delegate.scene(scene, restoreInteractionStateWith: place.activity)
                #expect(names(untouched) == ["destination:NewEpisodesFragment"])
            }
        }
    }

    /// A window that connects while its library waits (before the first unlock) keeps its saved place: it saves it
    /// again if it goes to the background, a late hand-over waits too, and the first main screen of the started library
    /// takes it once. A place UIKit could not read at connection (nil) and hands over late is kept the same way.
    @Test(arguments: [false, true])
    func aWindowWaitingForItsLibraryKeepsItsPlace(late: Bool) async throws {
        try await withLibrary { library, store in
            let place = SceneNavigationState(library: library.identity, rootTag: "HomeFragment", rootDestination: "HomeFragment",
                screens: [.destination("HomeFragment"), .feed(library.other.id), .feedInformation(library.other.id)], playerExpanded: true)
            let scene = try self.scene
            let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
            window.rootViewController = LibraryStartupWaitingController(); window.makeKeyAndVisible()
            defer { closeTestWindow(window, restoringKey: previous) }
            let delegate = SceneDelegate()
            delegate.window = window
            // At connection: nothing readable yet (locked), or the place itself.
            let atConnection = delegate.restoration.receive(late ? nil : place.activity)
            #expect(atConnection == !late)
            // Late, or again before activation.
            delegate.scene(scene, restoreInteractionStateWith: place.activity)
            // Saved again while waiting, unchanged.
            #expect(SceneNavigationState(activity: delegate.stateRestorationActivity(for: scene)) == place)
            #expect(delegate.restoration.pending == place)
            // The library starts: the scene's new main screen takes the place (SceneDelegate.installRoot).
            let started = screen(library, store: store)
            let restored = SceneDelegate.prepare(started, owners: library.owners, restoration: &delegate.restoration)
            #expect(restored)
            let again = delegate.restoration.take()
            #expect(again == nil, "taken once")
            window.rootViewController = started
            try await wait { started.libraryLoaded }
            try await settled(started)
            #expect(names(started) == ["destination:HomeFragment", "feed:\(library.other.id)", "feedInformation:\(library.other.id)"])
            try await wait { started.playerView?.expansion == 1 }
            #expect(SceneNavigationState(activity: delegate.stateRestorationActivity(for: scene))?.screens == place.screens)
        }
    }

    /// Screens that hold their own text reopen with it: the library search (scoped to a podcast, searched again), the
    /// online search (its provider asked again for its text), the settings search (its results) and Discover (its list
    /// read again). Nothing reaches the network: the directory requests stay in the test.
    @Test func screensWithTheirOwnTextReopenWithIt() async throws {
        try await withLibrary { library, store in
            let directories = DirectoryRequests()
            let before = screen(library, store: store, directories: directories)
            var activity: NSUserActivity?
            try await shown(before) { window in
                before.selectTag(NavigationDestination.home.rawValue)
                before.openSearch(try #require(before.feeds.first { $0.id == library.podcast.id }))
                guard case .search(let search) = before.path.last else { Issue.record("no search"); return }
                search.field.text = "episode 4"; search.session.change("episode 4"); search.session.submit()
                before.openProviderSearch(.podcastIndex, query: "Restoration news")
                before.drawerAction(.settings)
                before.openSettingsSearch()
                guard case .settingsSearch(let settings) = before.path.last else { Issue.record("no settings search"); return }
                settings.setQuery("speed")
                activity = try saved(window)
            }
            let expected = ["destination:HomeFragment", "search:episode 4|\(library.podcast.id)|false",
                            "onlineSearch:Restoration news|podcastIndex", "settings:main", "settingsSearch:speed"]
            let after = DirectoryRequests()
            let again = screen(library, store: store, directories: after)
            #expect(restore(activity, on: again, owners: library.owners))
            try await shown(again) { _ in
                try await settled(again)
                #expect(names(again) == expected)
                guard case .settingsSearch(let settings) = again.path.last else { Issue.record("no settings search"); return }
                #expect(!settings.results.isEmpty, "the settings search shows its results")
                guard case .search(let search) = again.path[1] else { Issue.record("no search"); return }
                #expect(search.field.text == "episode 4" && search.session.feedTitle == "Restored podcast")
                try await wait { search.session.result.episodes.map(\.episode.id) == [library.podcast.episodes[3].id] }
                try await wait { after.contains("api.podcastindex.org", "Restoration") }
            }

            // Discover as the root, with Settings over it; the archive's search.
            let discover = SceneNavigationState(library: library.identity, rootTag: "DiscoveryFragment", rootDestination: "HomeFragment",
                screens: [.discover, .settings("main")], playerExpanded: false)
            let archive = SceneNavigationState(library: library.identity, rootTag: "SubscriptionFragment", rootDestination: "SubscriptionFragment",
                screens: [.destination("SubscriptionFragment"), .archive, .search(query: "", feedID: nil, feedTitle: "Archive", archived: true)],
                playerExpanded: false)
            let lists = DirectoryRequests()
            let discovering = screen(library, store: store, directories: lists)
            #expect(discovering.restoreSceneNavigation(discover))
            try await shown(discovering) { _ in
                try await settled(discovering)
                #expect(names(discovering) == ["discover", "settings:main"])
                #expect(discovering.rootNavigationTag == "DiscoveryFragment")
                try await wait { lists.urls.withLock { !$0.isEmpty } }
                #expect(discovering.accessibilityPerformEscape())
                #expect(names(discovering) == ["discover"])
            }
            let archived = screen(library, store: store)
            #expect(archived.restoreSceneNavigation(archive))
            try await shown(archived) { _ in
                try await settled(archived)
                #expect(names(archived) == ["destination:SubscriptionFragment", "archive", "search:|-|true"])
            }
        }
    }

    // MARK: Restored screens and their owners

    /// Discover restored through the scene's own order (owners, then the place): its country and Hide setting are the
    /// saved ones, and its list is asked for only once the library has been read, so a podcast the library has is left
    /// out even when that read is slow. Hidden: nothing is asked.
    @Test(arguments: [false, true])
    func restoredDiscoverReadsItsSettingsAndTheLibraryFirst(hidden: Bool) async throws {
        try await withLibrary { library, store in
            try library.discovery.update(DiscoveryPreferences(countryCode: "jp", hidden: hidden))
            let lists = DirectoryRequests(topList: ["Restored podcast", "Suggested show"])
            let gate = Gate()
            defer { gate.open() }
            let controller = screen(library, store: store, directories: lists, loadSnapshot: held(store, gate))
            let place = SceneNavigationState(library: library.identity, rootTag: "DiscoveryFragment", rootDestination: "HomeFragment",
                                             screens: [.discover], playerExpanded: false)
            #expect(restore(place.activity, on: controller, owners: library.owners))
            try await shown(controller, loaded: false) { _ in
                guard case .discover(let discover) = controller.path.first else { Issue.record("no Discover"); return }
                for _ in 0..<5 { await Task.yield() }
                #expect(lists.isEmpty, "nothing is asked before the library is read")
                gate.open()
                try await wait { controller.libraryLoaded }
                if hidden {
                    try await wait { discover.session.state == .hidden }
                    #expect(lists.isEmpty, "Hide asks for nothing")
                } else {
                    try await wait { if case .loaded = discover.session.state { true } else { false } }
                    #expect(lists.requested(path: "/jp/rss/toppodcasts"), "the saved country")
                    guard case .loaded(let shown) = discover.session.state else { return }
                    #expect(shown.map(\.title) == ["Suggested show"], "the library's own podcast is left out")
                }
            }
        }
    }

    /// The settings search restored through the scene's own order: it keeps the saved history (Clear history clears the
    /// saved history), and once the synchronization account is read its results include gpodder.net's login row, with
    /// the text typed kept.
    @Test func restoredSettingsSearchUsesTheSavedHistoryAndTheSelectedAccount() async throws {
        try await withLibrary { library, store in
            try library.history.add("speed")
            let accounts = SynchronizationAccounts(store: store, credentials: MemoryCredentials())
            try await accounts.connect(SynchronizationAccount(backend: .gpodder, host: "https://gpodder.example.test",
                                                              username: "alice", device: "phone"), password: "secret", fullSync: false)
            let delivery = SynchronizationDelivery(store: store, publisher: SilentSynchronizationPublisher(),
                text: .init(errorTitle: "Synchronization failed", errorPrefix: "Error: "), foreground: { _ in false },
                episodesChanged: { _ in })
            let coordinator = SynchronizationCoordinator(store: store, execute: { _ in throw CancellationError() })
            @MainActor func settingsScreen() -> LibraryViewController {
                LibraryViewController(library: store, startupError: nil, downloads: nil,
                    playback: PlaybackCoordinator(store: store, engine: AVPlayerPlaybackEngine(muted: true)),
                    timeDisplayPreferences: library.time, navigationPreferences: library.navigation, speedPreferences: nil,
                    mobileNetworkPreferences: nil, usage: nil, synchronizationAccounts: accounts, synchronization: coordinator,
                    synchronizationDelivery: delivery)
            }
            @MainActor func place(_ query: String) -> SceneNavigationState {
                SceneNavigationState(library: library.identity, rootTag: "HomeFragment", rootDestination: "HomeFragment",
                                     screens: [.destination("HomeFragment"), .settings("main"), .settingsSearch(query: query)], playerExpanded: false)
            }

            let history = settingsScreen()
            #expect(restore(place("").activity, on: history, owners: library.owners))
            try await shown(history) { _ in
                guard case .settingsSearch(let search) = history.path.last else { Issue.record("no settings search"); return }
                #expect(search.history === library.history, "the saved history, not one in memory")
                let row: UIControl = try #require(element("settingsSearchHistory-0", in: search))
                #expect(row.accessibilityLabel == "speed")
                search.clearHistory()
                #expect(library.history.terms.isEmpty, "Clear history clears the saved history")
            }

            let account = settingsScreen()
            #expect(account.synchronizationSettings?.loaded == false, "the account is read after the place opens")
            #expect(restore(place("login information").activity, on: account, owners: library.owners))
            try await shown(account) { _ in
                guard case .settingsSearch(let search) = account.path.last else { Issue.record("no settings search"); return }
                try await wait { search.results.contains { $0.title == "Change login information" } }
                #expect(search.field.text == "login information")
            }
        }
    }

    /// A move the person makes before the first library read (another page, or opening and closing the player) is
    /// theirs: when the read arrives, the restored player does not open over it.
    @Test(arguments: ["navigation", "player"])
    func aMoveBeforeTheFirstReadKeepsThePlayerClosed(move: String) async throws {
        try await withLibrary { library, store in
            let gate = Gate()
            defer { gate.open() }
            let controller = screen(library, store: store, loadSnapshot: held(store, gate))
            #expect(restore(expandedPlace(library).activity, on: controller, owners: library.owners))
            try await shown(controller, loaded: false) { _ in
                if move == "navigation" {
                    controller.selectTag(NavigationDestination.queue.rawValue)
                } else {
                    try await wait { controller.playerView?.isHidden == false }
                    controller.playerView?.setExpanded(true, animated: false)
                    controller.playerView?.setExpanded(false, animated: false)
                }
                #expect(!controller.libraryLoaded, "the read is still held")
                gate.open()
                try await wait { controller.libraryLoaded }
                try await settled(controller)
                #expect(controller.playerView?.expansion == 0, "the person's choice stands")
                #expect(names(controller) == (move == "navigation" ? ["destination:QueueFragment"] : expandedNames(library)))
            }
        }
    }

    /// Saved again while the restored place still waits for its first library read: the player is saved as expanded,
    /// and the next reconnection opens it. A route or the person's navigation in between is saved as collapsed. Without
    /// a selected episode the expansion settles with the player hidden, saved as collapsed.
    @Test func savingAgainBeforeThePlayerOpensKeepsItsState() async throws {
        try await withLibrary { library, store in
            let gate = Gate()
            defer { gate.open() }
            let first = screen(library, store: store, loadSnapshot: held(store, gate))
            #expect(restore(expandedPlace(library).activity, on: first, owners: library.owners))
            var again: NSUserActivity?
            try await shown(first, loaded: false) { window in
                #expect(!first.libraryLoaded)
                again = try saved(window)
                #expect(SceneNavigationState(activity: again)?.playerExpanded == true, "still expanded while the read is held")
                #expect(SceneNavigationState(activity: again)?.screens == expandedPlace(library).screens)
                gate.open()
                try await settled(first)
                try await wait { first.playerView?.expansion == 1 }
            }
            let second = screen(library, store: store)
            #expect(restore(again, on: second, owners: library.owners))
            try await shown(second) { _ in
                try await settled(second)
                try await wait { second.playerView?.expansion == 1 }
                #expect(names(second) == expandedNames(library))
            }

            for move in ["route", "navigation"] {
                let held = Gate()
                defer { held.open() }
                let controller = screen(library, store: store, loadSnapshot: self.held(store, held))
                #expect(restore(expandedPlace(library).activity, on: controller, owners: library.owners))
                try await shown(controller, loaded: false) { window in
                    if move == "route" { controller.openExternal(.openPage(.inbox)) }
                    else { controller.selectTag(NavigationDestination.inbox.rawValue) }
                    let state = SceneNavigationState(activity: try saved(window))
                    #expect(state?.playerExpanded == false, "\(move): saved as collapsed")
                    #expect(state?.screens == [.destination(NavigationDestination.inbox.rawValue)])
                    held.open()
                    try await settled(controller)
                    #expect(controller.playerView?.expansion == 0)
                }
            }
        }
        try await withLibrary(selected: false) { library, store in
            let controller = screen(library, store: store)
            #expect(restore(expandedPlace(library).activity, on: controller, owners: library.owners))
            try await shown(controller) { window in
                try await settled(controller)
                #expect(controller.playerView?.expansion == 0 && controller.playerView?.isHidden == true, "no empty expanded player")
                #expect(SceneNavigationState(activity: try saved(window))?.playerExpanded == false)
            }
        }
    }

    /// "Remember last page" on a podcast that is gone: a restored window whose root was that podcast, and a new window,
    /// open Home (as a remembered page that is not a page does) and remember it, instead of an empty page. A
    /// remembered podcast that exists still opens.
    @Test func aRememberedPodcastThatIsGoneOpensHome() async throws {
        try await withLibrary { library, store in
            let missing: Int64 = 999_999
            @MainActor func remember(_ page: String) throws {
                var value = library.navigation.value
                value.defaultPage = "remember"; value.lastPage = page
                try library.navigation.update(value)
            }
            try remember(String(missing))
            let restored = screen(library, store: store)
            let place = SceneNavigationState(library: library.identity, rootTag: String(missing), rootDestination: "SubscriptionFragment",
                                             screens: [.feed(missing), .feedInformation(missing)], playerExpanded: false)
            #expect(restore(place.activity, on: restored, owners: library.owners))
            try await shown(restored) { _ in
                try await settled(restored)
                #expect(names(restored) == ["destination:HomeFragment"] && restored.rootNavigationTag == "HomeFragment")
            }
            #expect(library.navigation.value.lastPage == "HomeFragment")

            try remember(String(missing))
            let fresh = screen(library, store: store)
            #expect(names(fresh) == ["feed:\(missing)"], "before the library is read")
            try await shown(fresh) { _ in
                #expect(names(fresh) == ["destination:HomeFragment"] && fresh.rootNavigationTag == "HomeFragment")
            }
            #expect(library.navigation.value.lastPage == "HomeFragment")

            try remember(String(library.podcast.id))
            let existing = screen(library, store: store)
            try await shown(existing) { _ in
                #expect(names(existing) == ["feed:\(library.podcast.id)"] && existing.rootNavigationTag == String(library.podcast.id))
            }
        }
    }

    private func expandedPlace(_ library: Library) -> SceneNavigationState {
        let shown = EpisodePagerItem(feedID: library.podcast.id, episodeID: library.podcast.episodes[1].id)
        return SceneNavigationState(library: library.identity, rootTag: "SubscriptionFragment", rootDestination: "SubscriptionFragment",
            screens: [.destination("SubscriptionFragment"), .feed(library.podcast.id), .episode(shown, pager: [shown], index: 0)],
            playerExpanded: true)
    }

    private func expandedNames(_ library: Library) -> [String] {
        ["destination:SubscriptionFragment", "feed:\(library.podcast.id)", "episode:\(library.podcast.id)/\(library.podcast.episodes[1].id)"]
    }
}

/// Synchronization passwords kept in memory for the test.
private final class MemoryCredentials: SynchronizationCredentialStore, Sendable {
    private let storage = Mutex<[UUID: String]>([:])
    func insert(_ password: String, id: UUID) throws { storage.withLock { $0[id] = password } }
    func password(id: UUID) throws -> String {
        try storage.withLock { guard let value = $0[id] else { throw SynchronizationCredentialError.missing }; return value }
    }
    func remove(id: UUID) throws { storage.withLock { $0[id] = nil } }
}

/// Synchronization notifications that go nowhere.
@MainActor private final class SilentSynchronizationPublisher: SynchronizationNotificationPublishing {
    func isAuthorized() async -> Bool { false }
    func publishError(title: String, body: String) async throws {}
    func clearErrors() async {}
}
