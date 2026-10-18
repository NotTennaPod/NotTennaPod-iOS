import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// The episode details pager, mounted on the oracle's Android fixture (`TestSupport/Data/episode-pager/pager.db`)
/// through the database import. Expected menus and the
/// journey come from the independent oracle (`expected/pager.json`); list orders come from the screen a person sees.
/// Pages change through the pager's accessibility scroll action (VoiceOver's three-finger swipe); finger swipes are
/// covered by the UI journey `EpisodePagerJourneyTests`.
@MainActor @Suite(.serialized)
struct EpisodePagerViewTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestSupport/Data/episode-pager")
    static let oracle: [String: Any] = (try? JSONSerialization.jsonObject(with: Data(contentsOf:
        fixtures.appendingPathComponent("expected/pager.json")))) as? [String: Any] ?? [:]
    static func menu(_ id: Int64) -> (icons: [String], overflow: [String]) {
        let value = (oracle["menus"] as? [String: [String: [String]]])?[String(id)]
        return (value?["toolbar_icons"] ?? ["missing"], value?["overflow"] ?? ["missing"])
    }
    static let titles: [Int64: String] = [301: "Opening night", 302: "Halfway there", 303: "No website here", 304: "Page four",
        305: "Already heard", 306: "Text-only post", 307: "Local recording", 308: "Now selected", 309: "Preview episode", 310: "Newest"]

    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(id, in: $0) as T? }.first
    }
    private func wait(_ message: String = "", sourceLocation: SourceLocation = #_sourceLocation,
                      _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while try await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await condition(), "\(message)", sourceLocation: sourceLocation)
    }
    private func tap(_ id: String, in view: UIView, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let control: UIControl = try #require(find(id, in: view), "\(id)", sourceLocation: sourceLocation)
        control.sendActions(for: .touchUpInside)
    }

    // MARK: Fixture

    private func mounted(start: NavigationDestination, rtl: Bool = false,
                         _ body: @MainActor (LibraryViewController, FeedLibraryStore, UIWindow) async throws -> Void) async throws {
        try await mounted(start: start, rtl: rtl) { controller, store, window, _ in try await body(controller, store, window) }
    }
    private func mounted(start: NavigationDestination, rtl: Bool = false,
                         _ body: @MainActor (LibraryViewController, FeedLibraryStore, UIWindow, URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EpisodePager-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let restored = try AndroidDatabaseRestore.read(Self.fixtures.appendingPathComponent("pager.db"), staging: folder.appendingPathComponent("s"))
        let store = try FeedLibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        do {
            try await store.installRestoredLibrary(restored, carrying: try await store.restoreCarryOver())
            let navigation = try NavigationPreferenceStore(file: folder.appendingPathComponent("navigation.json"))
            var value = navigation.value; value.defaultPage = "remember"; value.lastPage = start.rawValue
            try navigation.update(value)
            let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
                timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
            try await withViewTestWindow { host, window in
                if rtl { host.traitOverrides.layoutDirection = .rightToLeft; controller.view.semanticContentAttribute = .forceRightToLeft }
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                controller.view.frame = host.view.bounds
                defer {
                    controller.dismiss(animated: false); controller.willMove(toParent: nil)
                    controller.view.removeFromSuperview(); controller.removeFromParent()
                    host.traitOverrides.remove(UITraitLayoutDirection.self)
                }
                await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
                try await body(controller, store, window, folder.appendingPathComponent("library.sqlite"))
            }
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

    /// The episode rows of the current list, top to bottom, as a person reads them (scrolling builds the rest).
    private func rows(_ controller: LibraryViewController) -> [Int64] { controller.displayedEpisodeIDs }
    private func pager(_ controller: LibraryViewController) throws -> EpisodePagerState {
        try #require(controller.visibleEpisodePager, "an episode pager is shown")
    }
    private func scroll(_ controller: LibraryViewController) throws -> EpisodePagerView.PagingScrollView {
        try #require(find("episodePagerScroll", in: controller.view))
    }
    /// The visible episode as a person sees it: the title in the page that fills the pager.
    private func visibleTitle(_ controller: LibraryViewController) throws -> String? {
        let state = try pager(controller), scroll = try scroll(controller)
        let shown = state.pages.values.filter { abs($0.container.frame.minX - scroll.contentOffset.x) < 1 }
        try #require(shown.count == 1, "exactly one page fills the pager")
        return (find("episodeTitle", in: shown[0].header) as UILabel?)?.text
    }
    @discardableResult
    private func swipe(_ controller: LibraryViewController, _ direction: UIAccessibilityScrollDirection) throws -> Bool {
        let moved = try scroll(controller).accessibilityScroll(direction)
        controller.view.layoutIfNeeded()
        return moved
    }
    private func open(_ id: Int64, in controller: LibraryViewController) throws {
        try tap("episode-\(id)", in: controller.view); controller.view.layoutIfNeeded()
    }
    /// The overflow as a person reads it, then closed again.
    private func overflow(_ controller: LibraryViewController) async throws -> [String] {
        controller.view.layoutIfNeeded()
        try tap("episodeMore", in: controller.view)
        try await wait("menu opens") { (find("episodeMenuPanel", in: controller.view) as UIScrollView?) != nil }
        let panel: UIScrollView = try #require(find("episodeMenuPanel", in: controller.view))
        let titles = panel.subviews.compactMap { $0 as? UIButton }.sorted { $0.frame.minY < $1.frame.minY }.compactMap { $0.title(for: .normal) }
        controller.popup?.removeFromSuperview(); controller.popup = nil
        return titles
    }
    private func toolbarIcons(_ controller: LibraryViewController) -> [String] {
        (find("episodeWebsite", in: controller.view) as UIButton?).map { _ in ["Visit website"] } ?? []
    }
    private func expectMenu(_ controller: LibraryViewController, of id: Int64, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let expected = Self.menu(id)
        #expect(toolbarIcons(controller) == expected.icons, "toolbar of \(id)", sourceLocation: sourceLocation)
        #expect(try await overflow(controller) == expected.overflow, "overflow of \(id)", sourceLocation: sourceLocation)
    }
    private func shownotes(_ web: ShownotesWebView) async throws -> String {
        try #require(try await web.callAsyncJavaScript("return document.body?.innerText ?? ''", in: nil, contentWorld: .defaultClient) as? String)
    }

    // MARK: Tests

    /// An open page shows its episode's notes again, read by key, after a commit that changed only them (Android's
    /// ItemFragment reloads on the episode's FeedItemEvent), and keeps its document when a commit changed something
    /// else of the episode.
    @Test func anOpenPageShowsChangedNotesAndKeepsItsDocumentOtherwise() async throws {
        try await mounted(start: .inbox) { controller, store, _ in
            try await wait("Inbox rows") { rows(controller).count == 5 }
            try open(303, in: controller)
            let state = try pager(controller)
            let page = try #require(state.pages[state.model.index])
            try await wait("the stored notes") { (try? await shownotes(page.notes))?.contains("Shownotes of \(Self.titles[303]!)") == true }
            let revision = page.notes.notesRevisionForTesting
            try await store.setFavorite(episodeID: 303, favorite: true)
            await controller.settleLibraryChanges()
            #expect(page.notes.notesRevisionForTesting == revision, "a change outside the notes keeps the document")
            try await store.updateEpisode(id: 303) { $0.details.description = "<p>Corrected notes of page three</p>" }
            await controller.settleLibraryChanges()
            #expect(try pager(controller).pages[state.model.index]?.notes === page.notes, "the same page")
            try await wait("the corrected notes") { (try? await shownotes(page.notes))?.contains("Corrected notes of page three") == true }
            #expect(try await shownotes(page.notes).contains("Shownotes of \(Self.titles[303]!)") == false)
        }
    }

    /// The pager journey on the mounted screen: row 3 of the Inbox, next/previous/next, Mark as played on page 4, Back.
    @Test func inboxJourneyMenuFollowsTheVisiblePageAndMarksOnlyThatEpisode() async throws {
        try await mounted(start: .inbox) { controller, store, _, file in
            let journey = try #require(Self.oracle["journey"] as? [String: Any])
            let inbox = (journey["inbox_before"] as? [Int] ?? []).map(Int64.init)
            try await wait("Inbox rows") { rows(controller) == inbox }
            try open(303, in: controller)
            let opened = try pager(controller)
            #expect(opened.model.items.map(\.episodeID) == inbox, "the pager holds the displayed rows in their order")
            #expect(try visibleTitle(controller) == Self.titles[303])
            try await expectMenu(controller, of: 303)
            #expect(try swipe(controller, .left))
            #expect(try visibleTitle(controller) == Self.titles[304])
            try await expectMenu(controller, of: 304)
            #expect(try swipe(controller, .right))
            #expect(try visibleTitle(controller) == Self.titles[303])
            #expect(try swipe(controller, .left))
            #expect(try visibleTitle(controller) == Self.titles[304])
            let before303 = try #require(await store.episode(id: 303)), before304 = try #require(await store.episode(id: 304))
            #expect(before304.userState.playState == .new && before304.userState.positionMilliseconds == 45_000)
            try tap("episodeMore", in: controller.view)
            try await wait("menu opens") { (find("markPlayed", in: controller.view) as UIButton?) != nil }
            try tap("markPlayed", in: controller.view)
            try await wait("304 marked played") { try await store.episode(id: 304)?.userState.playState == .played }
            let after304 = try #require(await store.episode(id: 304))
            #expect(after304.userState.positionMilliseconds == 0, "Mark as played resets the position")
            #expect(after304.userState.isFavorite == before304.userState.isFavorite && after304.userState.isDownloaded == before304.userState.isDownloaded)
            #expect(try await store.episode(id: 303) == before303, "the previous page's episode is untouched")
            // Independent read of the saved library: a second store on the same file.
            let reopened = try FeedLibraryStore(url: file)
            let saved304 = try await reopened.episode(id: 304), saved303 = try await reopened.episode(id: 303)
            try await reopened.close()
            #expect(saved304?.userState.playState == .played && saved304?.userState.positionMilliseconds == 0)
            #expect(saved303?.userState.playState == .new, "303 stays new on disk")
            let after = try #require((journey["pager_after_action"] as? [String: Any])?["menu_after"] as? [String: [String]])
            try await wait("menu of the played episode") { (try? await overflow(controller)) == after["overflow"] }
            #expect(toolbarIcons(controller) == after["toolbar_icons"])
            #expect(try pager(controller).model.items.map(\.episodeID) == inbox, "the pager keeps its ids")
            #expect(try visibleTitle(controller) == Self.titles[304])
            #expect((find("episodeActionSnackbar", in: controller.view) as UIView?) == nil, "no snackbar for one episode")
            try tap("toolbarBack", in: controller.view); controller.view.layoutIfNeeded()
            let back = ((journey["after_back"] as? [String: Any])?["list"] as? [Int] ?? []).map(Int64.init)
            try await wait("Inbox after Back") { rows(controller) == back }
            #expect(controller.visibleEpisodePager == nil)
        }
    }

    @Test(arguments: [false, true])
    func boundariesStayPutAndRightToLeftPutsTheNextEpisodeOnTheLeft(rtl: Bool) async throws {
        try await mounted(start: .inbox, rtl: rtl) { controller, _, _ in
            try await wait("Inbox rows") { rows(controller).count == 5 }
            let inbox = rows(controller)
            let forward: UIAccessibilityScrollDirection = rtl ? .right : .left, backward: UIAccessibilityScrollDirection = rtl ? .left : .right
            try open(inbox[0], in: controller)
            #expect(try !swipe(controller, backward), "no page before the first")
            #expect(try visibleTitle(controller) == Self.titles[inbox[0]])
            #expect(try swipe(controller, forward))
            #expect(try visibleTitle(controller) == Self.titles[inbox[1]])
            // The next page sits after the visible one in reading direction.
            let state = try pager(controller), window = try #require(controller.view.window)
            let shown = try #require(state.pages[1]).container, following = try #require(state.pages[2]).container
            let visible = shown.convert(shown.bounds, to: window), next = following.convert(following.bounds, to: window)
            #expect(rtl ? next.midX < visible.midX : next.midX > visible.midX)
            try tap("toolbarBack", in: controller.view); controller.view.layoutIfNeeded()
            try await wait("Inbox again") { rows(controller) == inbox }
            try open(inbox[4], in: controller)
            #expect(try !swipe(controller, forward), "no page after the last")
            #expect(try visibleTitle(controller) == Self.titles[inbox[4]])
            #expect(try swipe(controller, backward))
            #expect(try visibleTitle(controller) == Self.titles[inbox[3]])
        }
    }

    /// The oracle's `rapid_swipes`: after a burst of swipes each resident page shows its own episode
    /// and shownotes, and the menu belongs to the page that is shown.
    @Test func rapidSwipesKeepEveryPageItsOwnEpisodeAndTheMenuOnTheShownPage() async throws {
        try await mounted(start: .episodes) { controller, _, _ in
            try await wait("Episodes rows") { rows(controller).count >= 9 }
            let list = rows(controller)
            try open(list[1], in: controller)
            for _ in 0..<5 { try swipe(controller, .left) }
            for _ in 0..<2 { try swipe(controller, .right) }
            let state = try pager(controller)
            #expect(state.model.index == 4 && state.model.visible.episodeID == list[4])
            #expect(try visibleTitle(controller) == Self.titles[list[4]])
            for (index, page) in state.pages {
                #expect(page.episodeID == list[index], "page \(index) belongs to its own row")
                #expect((find("episodeTitle", in: page.header) as UILabel?)?.text == Self.titles[list[index]])
                try await wait("shownotes of page \(index)") { (try? await shownotes(page.notes))?.contains("Shownotes of \(Self.titles[list[index]]!)") == true }
            }
            #expect(Set(state.pages.keys) == [3, 4, 5], "the shown page and its neighbours are resident")
            try await expectMenu(controller, of: list[4])
        }
    }

    /// Rotation or a window resize keeps the page, its episode and the menu target; the shown page fills
    /// the new width without a neighbour showing.
    @Test func resizeAndRotationKeepTheShownEpisode() async throws {
        try await mounted(start: .inbox) { controller, _, window in
            try await wait("Inbox rows") { rows(controller).count == 5 }
            try open(303, in: controller)
            try swipe(controller, .left)
            #expect(try visibleTitle(controller) == Self.titles[304])
            let full = controller.view.frame
            controller.view.frame = CGRect(x: full.minX, y: full.minY, width: (full.width * 0.6).rounded(), height: full.height)
            controller.view.layoutIfNeeded()
            let pagerView = try pager(controller).view
            #expect(abs(pagerView.bounds.width - controller.content.bounds.width) < 1)
            #expect(try visibleTitle(controller) == Self.titles[304])
            try await expectMenu(controller, of: 304)
            controller.view.frame = full; controller.view.layoutIfNeeded()
            let scene = try #require(window.windowScene), original = scene.effectiveGeometry.interfaceOrientation
            var refusal: String?
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: original.isPortrait ? .landscapeRight : .portrait)) { refusal = String(describing: $0) }
            let host = try #require(controller.view.superview), before = host.bounds.size
            try await wait("rotated or refused") { refusal != nil || (scene.effectiveGeometry.interfaceOrientation != original && host.bounds.size != before) }
            try #require(refusal == nil || windowingRefusesRotation(refusal), "\(refusal ?? "")")
            controller.view.frame = controller.view.superview?.bounds ?? full; controller.view.layoutIfNeeded()
            #expect(try visibleTitle(controller) == Self.titles[304])
            #expect(try pager(controller).model.index == 3)
            try await expectMenu(controller, of: 304)
        }
    }

    /// One Back from any page returns to the list at the scroll position it had.
    @Test func backReturnsToTheListWhereItWasScrolled() async throws {
        try await mounted(start: .episodes) { controller, _, _ in
            try await wait("Episodes rows") { rows(controller).count >= 9 }
            // A short window makes the ten-row list scroll on every device.
            let full = controller.view.frame
            controller.view.frame = CGRect(x: full.minX, y: full.minY, width: full.width, height: min(full.height, 480))
            controller.view.layoutIfNeeded()
            let content = controller.content
            try #require(content.contentSize.height > content.bounds.height + 40, "the list scrolls")
            let offset = CGPoint(x: 0, y: min(120, content.contentSize.height - content.bounds.height))
            content.setContentOffset(offset, animated: false); controller.view.layoutIfNeeded()
            let visibleRow = try #require(controller.episodeRows.values.map(\.1).filter { $0.frame.minY >= offset.y }.min { $0.frame.minY < $1.frame.minY })
            let id = try #require(controller.episodeRows.first { $0.value.1 === visibleRow }?.key)
            try open(id, in: controller)
            try swipe(controller, .left); try swipe(controller, .left)
            try tap("toolbarBack", in: controller.view); controller.view.layoutIfNeeded()
            #expect(controller.visibleEpisodePager == nil, "one Back leaves the pager however many pages were swiped")
            #expect(abs(content.contentOffset.y - offset.y) < 2, "the list keeps its scroll position")
            controller.view.frame = full
        }
    }

    /// Home sections pass only their visible items; Queue passes the whole queue; Search its results.
    @Test func callersPassTheirDisplayedRows() async throws {
        try await mounted(start: .home) { controller, _, _ in
            @MainActor func homeInbox() -> [Int64] { rows(controller).filter { controller.homeRowScopes[$0] == .inbox } }
            try await wait("Home Inbox rows") { homeInbox().count == 2 }
            let home = homeInbox()
            #expect(home == [310, 301], "See what's new shows two Inbox rows")
            try open(home[1], in: controller)
            #expect(try pager(controller).model.items.map(\.episodeID) == home)
            #expect(try !swipe(controller, .left), "the Inbox rows beyond the section are not reachable")
            try tap("toolbarBack", in: controller.view); controller.view.layoutIfNeeded()
            // Continue listening: the queue's cards, in the strip's order.
            try await wait("Home rendered") { (find("homeQueueStrip", in: controller.view) as UIView?) != nil }
            let strip: UIView = try #require(find("homeQueueStrip", in: controller.view))
            func cards(_ view: UIView) -> [HomeEpisodeCard] { view.subviews.flatMap { ($0 as? HomeEpisodeCard).map { [$0] } ?? cards($0) } }
            let cardIDs = cards(strip).sorted { $0.convert($0.bounds, to: strip).minX < $1.convert($1.bounds, to: strip).minX }.map(\.episodeID)
            #expect(cardIDs.count == 3)
            let card = try #require(cardIDs.last)
            try tap("homeEpisode-\(card)", in: controller.view); controller.view.layoutIfNeeded()
            #expect(try pager(controller).model.items.map(\.episodeID) == cardIDs, "a card opens the pager over its own section's cards")
            #expect(try visibleTitle(controller) == Self.titles[card])
            try tap("toolbarBack", in: controller.view); controller.view.layoutIfNeeded()
            controller.select(.queue); controller.view.layoutIfNeeded()
            try await wait("Queue rows") { rows(controller).count == 3 }
            let queue = rows(controller)
            try open(queue[1], in: controller)
            #expect(try pager(controller).model.items.map(\.episodeID) == queue && pager(controller).model.index == 1)
            try tap("toolbarBack", in: controller.view); controller.view.layoutIfNeeded()
            controller.select(.inbox); controller.view.layoutIfNeeded()
            try tap("inboxSearch", in: controller.view); controller.view.layoutIfNeeded()
            let field: UITextField = try #require(find("librarySearchQuery", in: controller.view))
            field.text = "o"; field.sendActions(for: .editingChanged); _ = field.delegate?.textFieldShouldReturn?(field)
            // Rows are placed by the search screen's layout once the search has finished.
            try await wait("search results") {
                guard case .search(let search) = controller.path.last, !search.session.loading else { return false }
                controller.view.layoutIfNeeded()
                return rows(controller).count >= 3
            }
            let results = rows(controller)
            try open(results[2], in: controller)
            #expect(try pager(controller).model.items.map(\.episodeID) == results && pager(controller).model.index == 2)
            #expect(try visibleTitle(controller) == Self.titles[results[2]])
        }
    }

    /// Open podcast stacks the podcast screen over the pager; Back returns to the same page.
    @Test func openPodcastStacksOverThePagerAndBackReturnsToTheSamePage() async throws {
        try await mounted(start: .inbox) { controller, _, _ in
            try await wait("Inbox rows") { rows(controller).count == 5 }
            let inbox = rows(controller)
            try open(303, in: controller)
            try swipe(controller, .left)
            #expect(try visibleTitle(controller) == Self.titles[304])
            try tap("episodeMore", in: controller.view)
            try await wait("menu opens") { (find("openPodcast", in: controller.view) as UIButton?) != nil }
            try tap("openPodcast", in: controller.view); controller.view.layoutIfNeeded()
            #expect(controller.visibleEpisodePager == nil)
            try await wait("podcast screen") { (find("subscribedFeedHeader", in: controller.view) as UIView?) != nil }
            try tap("toolbarBack", in: controller.view); controller.view.layoutIfNeeded()
            #expect(try pager(controller).model.items.map(\.episodeID) == inbox)
            #expect(try visibleTitle(controller) == Self.titles[304])
            try tap("toolbarBack", in: controller.view); controller.view.layoutIfNeeded()
            try await wait("Inbox") { rows(controller) == inbox }
        }
    }

    /// A neighbour whose WebKit process iOS ended stays as it is while nobody sees it, and its notes are back when
    /// the person swipes to it, with no alert.
    @Test func neighbourWhoseProcessEndedIsRebuiltWhenSwipedTo() async throws {
        try await mounted(start: .episodes) { controller, _, _ in
            try await wait("Episodes rows") { rows(controller).count >= 9 }
            let list = rows(controller)
            try open(list[1], in: controller)
            let state = try pager(controller)
            let neighbour = try #require(state.pages[2]?.notes)
            try await wait("neighbour notes") { (try? await shownotes(neighbour))?.contains("Shownotes of \(Self.titles[list[2]]!)") == true }
            try await wait("neighbour ready") { neighbour.isDocumentReady }
            #expect(!neighbour.isShownInActiveScene, "a neighbour is in the window but not shown")
            try neighbour.killWebContentProcess()
            try await wait("ended") { neighbour.processTerminations == 1 }
            #expect(neighbour.isAwaitingLoad && !neighbour.isLoading)
            controller.view.layoutIfNeeded()
            #expect(neighbour.isAwaitingLoad, "layout of the shown page does not rebuild a hidden neighbour")
            try swipe(controller, .left)
            #expect(try visibleTitle(controller) == Self.titles[list[2]])
            #expect(try pager(controller).pages[2]?.notes === neighbour)
            try await wait("rebuilt on its visit") {
                guard neighbour.isDocumentReady else { return false }
                return (try? await shownotes(neighbour))?.contains("Shownotes of \(Self.titles[list[2]]!)") == true
            }
            #expect(controller.presentedViewController == nil, "no alert")
        }
    }

    /// A pager nobody sees keeps only its shown page: its neighbours are built again when it is shown in the foreground.
    @Test func hiddenPagerReleasesItsNeighboursUntilItIsShownAgain() async throws {
        try await mounted(start: .inbox) { controller, _, window in
            try await wait("Inbox rows") { rows(controller).count == 5 }
            let inbox = rows(controller)
            try open(inbox[2], in: controller)
            let state = try pager(controller)
            #expect(Set(state.pages.keys) == [1, 2, 3])
            let shown = try #require(state.pages[2]?.notes)
            try tap("episodeMore", in: controller.view)
            try await wait("menu opens") { (find("openPodcast", in: controller.view) as UIButton?) != nil }
            try tap("openPodcast", in: controller.view); controller.view.layoutIfNeeded()
            #expect(controller.visibleEpisodePager == nil)
            #expect(Set(state.pages.keys) == [2], "covered by the podcast screen")
            #expect(state.pages[2]?.notes === shown, "Back shows the same page at once")
            try tap("toolbarBack", in: controller.view); controller.view.layoutIfNeeded()
            #expect(Set(try pager(controller).pages.keys) == [1, 2, 3])
            #expect(try visibleTitle(controller) == Self.titles[inbox[2]])
            for index in [1, 3] {
                let notes = try #require(state.pages[index]?.notes)
                try await wait("neighbour \(index) rebuilt") { (try? await shownotes(notes))?.contains("Shownotes of \(Self.titles[inbox[index]]!)") == true }
            }
            let scene = try #require(window.windowScene)
            NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: scene)
            #expect(Set(state.pages.keys) == [2], "in the background")
            NotificationCenter.default.post(name: UIScene.willEnterForegroundNotification, object: scene)
            #expect(Set(state.pages.keys) == [1, 2, 3])
            #expect(try visibleTitle(controller) == Self.titles[inbox[2]])
            try swipe(controller, .left)
            #expect(try visibleTitle(controller) == Self.titles[inbox[3]])
        }
    }

    /// A missing neighbour never closes the pager; landing on it, or losing the shown
    /// episode, returns to the list.
    @Test func missingEpisodesCloseOnlyWhenShown() async throws {
        try await mounted(start: .inbox) { controller, store, _ in
            try await wait("Inbox rows") { rows(controller).count == 5 }
            try open(304, in: controller)
            let deletion = FeedDeletionCoordinator(store: store, retirePlayback: { _ in }, retireDownloads: { _ in })
            try await deletion.delete(feedID: 4).value // 303, the previous page
            await controller.reloadLibrary(preservingEpisodeDetails: true)?.value; controller.view.layoutIfNeeded()
            #expect(controller.visibleEpisodePager != nil, "a missing neighbour keeps the pager open")
            #expect(try visibleTitle(controller) == Self.titles[304])
            try swipe(controller, .right)
            #expect(controller.visibleEpisodePager == nil, "landing on the missing episode returns to the list")
            try await wait("Inbox without 303") { rows(controller) == [310, 301, 304, 307] }
            try open(304, in: controller)
            try await deletion.delete(feedID: 1).value // 304 itself
            await controller.reloadLibrary(preservingEpisodeDetails: true)?.value; controller.view.layoutIfNeeded()
            #expect(controller.visibleEpisodePager == nil, "the shown episode was removed")
            try await wait("Inbox without feed 1") { rows(controller) == [307] }
        }
    }
}
