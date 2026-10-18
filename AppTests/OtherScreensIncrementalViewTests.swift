import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Home, Subscriptions (grid and list), Archive, search, Statistics, the episode pager, the player and the drawer kept
/// from patches, as a person sees them. As in `IncrementalScreenViewTests`, two controllers share one library: T keeps
/// itself current from the change sets, F reads the whole library after every step. After each seeded step both show the
/// same sections, tiles, results and labels in the same places; T draws its screen again only for a welcome or empty
/// transition or chips that change, and builds again only what changed.
@MainActor @Suite(.serialized)
struct OtherScreensIncrementalViewTests {
    let base = IncrementalScreenViewTests()

    enum Opened: Equatable { case home, subscriptions(columns: Int), archive, search(String), pager }

    /// Labels of the accessibility elements under `view`, in subview order.
    static func labels(_ view: UIView) -> [String] {
        var result: [String] = []
        if view.isAccessibilityElement, let label = view.accessibilityLabel { result.append(label + "|" + (view.accessibilityValue ?? "")) }
        if let label = view as? UILabel, !view.isAccessibilityElement, let text = label.text, !label.isHidden { result.append(text) }
        for subview in view.subviews where !subview.isHidden { result += labels(subview) }
        return result
    }

    struct Shown: Equatable {
        var ids: [[Int64]] = []
        var frames: [CGRect] = []
        var labels: [String] = []
        var badge: Int?
        var rows: [Int64: [String]] = [:]
        /// The rows built in both, with their labels.
        func rows(sharedWith other: Shown) -> [Int64: [String]] { rows.filter { other.rows[$0.key] != nil } }
    }

    func shown(_ controller: LibraryViewController, _ opened: Opened) -> Shown {
        var shown = Shown()
        shown.badge = (Self.find(controller.view) { $0.accessibilityIdentifier == NavigationDestination.inbox.rawValue } as? NavigationButton)?.badgeCount
        switch opened {
        case .home:
            for state in controller.homeSections {
                shown.ids.append(state.shown.rows.map(\.1.id) + state.shown.feeds.map(\.id))
                shown.frames += state.views.map { $0.frame.integral }
                shown.labels += state.views.flatMap(Self.labels)
            }
        case .subscriptions, .archive:
            let grid = controller.subscriptionGrid
            shown.ids = [grid?.ids ?? []]
            shown.frames = grid?.frames.map(\.integral) ?? []
            shown.labels = (grid?.ids ?? []).compactMap { grid?.views[$0] }.flatMap(Self.labels)
        case .search:
            guard case .search(let search) = controller.path.last else { return shown }
            shown.ids = [search.displayedIDs, search.session.result.feeds.map(\.id)]
            // The rows on screen (built lazily: both are compared on the rows built in both).
            for (id, value) in controller.episodeRows where value.1.window != nil { shown.rows[id] = Self.labels(value.1) }
        case .pager:
            guard let pager = controller.visibleEpisodePager, let page = pager.pages[pager.model.index] else { return shown }
            shown.ids = [pager.model.items.map(\.episodeID)]
            shown.labels = Self.labels(page.header)
        }
        return shown
    }

    static func find(_ view: UIView, _ predicate: (UIView) -> Bool) -> UIView? {
        if predicate(view) { return view }
        for subview in view.subviews { if let found = find(subview, predicate) { return found } }
        return nil
    }

    enum Extra: CaseIterable { case archive, title, localFailure, serverFailure, recovered }

    /// A podcast-level step: archive or subscribe again, a custom title, a refresh failure on this device or on the server,
    /// and a recovery.
    func perform(_ extra: Extra, _ fixture: IncrementalScreenViewTests.Fixture, random: inout ViewTestRandom) async throws {
        let store = fixture.store
        let feed = fixture.feeds[1 + random.below(fixture.feeds.count - 1)]
        switch extra {
        case .archive:
            try await store.updatePreferences(feedID: feed) { $0.subscriptionState = $0.subscriptionState == .archived ? .subscribed : .archived }
        case .title:
            let title = [nil, "Custom é", "custom e\u{301}", "A podcast"][random.below(4)]
            try await store.updatePreferences(feedID: feed) { $0.customTitle = title }
        case .localFailure:
            try await store.recordFailure(.httpStatus(500), feedID: feed, date: IncrementalScreenViewTests.now.addingTimeInterval(Double(random.below(1_000))))
        case .serverFailure: try await Self.setServerRefresh(store, feed: feed, failed: random.chance(70))
        case .recovered: try await Self.clearLocalFailure(store, feed: feed)
        }
    }

    nonisolated static func rewriteHeader(_ store: FeedLibraryStore, feed: Int64, _ change: @escaping @Sendable (inout LibraryFeed) -> Void) async throws {
        try await store.withDatabaseForTesting { database in
            try database.transaction {
                guard let data = try database.rows("SELECT record FROM feeds WHERE id = ?", [.integer(feed)]).first?[0].recordData else { return }
                var header = try JSONDecoder.libraryRecord(LibraryFeed.self, from: data)
                change(&header)
                try database.execute("UPDATE feeds SET record = ? WHERE id = ?", [.blob(try JSONEncoder().encode(header)), .integer(feed)])
            }
        }
    }

    nonisolated static func setServerRefresh(_ store: FeedLibraryStore, feed: Int64, failed: Bool) async throws {
        try await rewriteHeader(store, feed: feed) { $0.serverRefresh = ServerRefreshStatus(lastAttempt: Date(timeIntervalSince1970: 1_760_000_000), label: failed ? "gone" : nil) }
    }

    nonisolated static func clearLocalFailure(_ store: FeedLibraryStore, feed: Int64) async throws {
        try await rewriteHeader(store, feed: feed) { $0.lastUpdateFailed = false }
    }

    func open(_ opened: Opened, _ controller: LibraryViewController, _ fixture: IncrementalScreenViewTests.Fixture) async throws {
        switch opened {
        case .home: controller.select(.home)
        case .subscriptions(let columns):
            controller.subscriptionFallback.columns = columns
            controller.select(.subscriptions)
        case .archive:
            controller.select(.subscriptions)
            controller.push(.archive)
        case .search(let query):
            controller.select(.home)
            controller.openSearch()
            guard case .search(let search) = controller.path.last else { return }
            search.field.text = query
            search.session.restoreQuery(query)
            search.session.submit()
        case .pager:
            controller.select(.inbox)
            controller.view.layoutIfNeeded()
            let id = controller.displayedEpisodeIDs[1]
            controller.openEpisode(feedID: controller.libraryEpisode(id)!.feed.id, episodeID: id, list: controller.currentPagerList())
        }
        controller.view.layoutIfNeeded()
    }

    func run(_ opened: Opened, rtl: Bool = false, steps: Int, seed: UInt64) async throws {
        var fixture = try await base.fixture(start: .home)
        if opened == .archive {
            try await fixture.store.updatePreferences(feedIDs: [fixture.feeds[1], fixture.feeds[2]]) { _, preferences in preferences.subscriptionState = .archived }
        }
        weak var patchedScreen: LibraryViewController?, freshScreen: LibraryViewController?
        do {
            let patched = base.controller(fixture, full: false), fresh = base.controller(fixture, full: true)
            patchedScreen = patched; freshScreen = fresh
            try await compare(patched, fresh, &fixture, opened: opened, rtl: rtl, steps: steps, seed: seed)
        } catch { await base.close(fixture); throw error }
        await base.close(fixture)
        try await base.wait("the screens are freed") { patchedScreen == nil && freshScreen == nil }
    }

    func compare(_ patched: LibraryViewController, _ fresh: LibraryViewController, _ fixture: inout IncrementalScreenViewTests.Fixture,
                 opened: Opened, rtl: Bool, steps: Int, seed: UInt64) async throws {
        var random = ViewTestRandom(state: seed)
        try await withViewTestWindow { host, _ in
            if rtl { host.traitOverrides.layoutDirection = .rightToLeft }
            for controller in [fresh, patched] {
                if rtl { controller.view.semanticContentAttribute = .forceRightToLeft }
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                controller.view.frame = host.view.bounds
                controller.view.layoutIfNeeded()
            }
            defer {
                for controller in [patched, fresh] {
                    controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent()
                }
                host.traitOverrides.remove(UITraitLayoutDirection.self)
            }
            for controller in [patched, fresh] { await controller.reloadLibrary()?.value }
            for controller in [patched, fresh] { try await open(opened, controller, fixture) }
            if case .search = opened {
                try await base.wait("both searched") {
                    [patched, fresh].allSatisfy { controller in
                        guard case .search(let search) = controller.path.last else { return false }
                        return search.session.resultRevision > 0 && !search.session.loading
                    }
                }
            }
            try await base.wait("both open") {
                let mine = shown(patched, opened), theirs = shown(fresh, opened)
                return mine.ids == theirs.ids && mine.labels == theirs.labels && !mine.ids.joined().isEmpty
            }
            let searchRevision: UInt64? = if case .search(let search) = patched.path.last { search.session.resultRevision } else { nil }
            let pagesBuilt = patched.episodePagesBuilt
            for number in 0..<steps {
                let before = shown(patched, opened)
                let renders = patched.renderCountForTesting
                let tilesBefore = patched.subscriptionGrid?.views.mapValues(ObjectIdentifier.init) ?? [:]
                let facesBefore = patched.subscriptionTiles.mapValues { SubscriptionTileFace($0.feed, counter: $0.counter) }
                let chipsBefore = patched.subscriptionChips
                let welcomeBefore = patched.homeShowsWelcome
                let label: String
                if random.chance(30), opened != .pager {
                    let extra = Extra.allCases[random.below(Extra.allCases.count)]
                    label = "\(extra)"
                    try await perform(extra, fixture, random: &random)
                } else {
                    let step = IncrementalScreenViewTests.Step.allCases[random.below(IncrementalScreenViewTests.Step.allCases.count)]
                    label = "\(step)"
                    let visible = patched.homeSections.flatMap { $0.shown.rows.map(\.1.id) } + (patched.visibleEpisodePager.map { [$0.model.visible.episodeID] } ?? [])
                    try await base.perform(step, &fixture, random: &random, visible: visible)
                }
                await patched.reloadLibrary()?.value
                await fresh.reloadLibrary()?.value
                if case .search = opened {
                    try await base.wait("the fresh search read again") {
                        guard case .search(let search) = fresh.path.last else { return false }
                        return !search.session.loading
                    }
                    try await Task.sleep(for: .milliseconds(30))
                }
                patched.view.layoutIfNeeded(); fresh.view.layoutIfNeeded()
                let name = "\(opened) \(rtl ? "RTL" : "LTR") step \(number) \(label)"
                let after = shown(patched, opened), reference = shown(fresh, opened)
                #expect(after.ids == reference.ids, "\(name): contents")
                #expect(after.frames == reference.frames, "\(name): frames")
                #expect(after.labels == reference.labels, "\(name): spoken labels")
                #expect(after.rows(sharedWith: reference) == reference.rows(sharedWith: after), "\(name): spoken rows")
                #expect(after.badge == reference.badge, "\(name): Inbox badge")
                // Drawn again only for a welcome or empty transition or chips that change.
                switch opened {
                case .home:
                    if welcomeBefore == patched.homeShowsWelcome { #expect(patched.renderCountForTesting == renders, "\(name): no full render") }
                case .subscriptions, .archive:
                    if chipsBefore == patched.subscriptionChips, !before.ids.joined().isEmpty, !after.ids.joined().isEmpty {
                        #expect(patched.renderCountForTesting == renders, "\(name): no full render")
                        // A tile is built again only when what it shows changed.
                        for (id, view) in tilesBefore {
                            guard let now = patched.subscriptionGrid?.views[id], ObjectIdentifier(now) != view,
                                  let face = patched.subscriptionTiles[id].map({ SubscriptionTileFace($0.feed, counter: $0.counter) }) else { continue }
                            #expect(facesBefore[id] != face, "\(name): tile \(id) built again without a change")
                        }
                    }
                case .search, .pager:
                    #expect(patched.renderCountForTesting == renders, "\(name): no full render")
                }
                if after.ids != reference.ids || after.labels != reference.labels { break }
            }
            // The search was never read again: every change patched its matches.
            if let searchRevision, case .search(let search) = patched.path.last {
                #expect(search.session.resultRevision == searchRevision, "no new scan")
            }
            if opened == .pager { #expect(patched.episodePagesBuilt == pagesBuilt, "no page built again") }
            #expect(patched.screenPatchCount > 0)
        }
    }

    @Test func homeEqualsAFreshOpenAfterEveryStep() async throws { try await run(.home, steps: 40, seed: 0xD2B0) }
    @Test func homeRightToLeft() async throws { try await run(.home, rtl: true, steps: 20, seed: 0xD2B1) }
    @Test(arguments: [3, 1])
    func subscriptionsEqualAFreshOpenAfterEveryStep(columns: Int) async throws {
        try await run(.subscriptions(columns: columns), steps: 40, seed: 0xD2B2 &+ UInt64(columns))
    }
    @Test func subscriptionsRightToLeft() async throws { try await run(.subscriptions(columns: 3), rtl: true, steps: 20, seed: 0xD2B3) }
    @Test func archiveEqualsAFreshOpenAfterEveryStep() async throws { try await run(.archive, steps: 30, seed: 0xD2B4) }
    @Test func searchEqualsAFreshSearchAfterEveryStep() async throws { try await run(.search("Show"), steps: 40, seed: 0xD2B5) }
    @Test func searchRightToLeft() async throws { try await run(.search("episode 1"), rtl: true, steps: 20, seed: 0xD2B6) }
    @Test func pagerEqualsAFreshOpenAfterEveryStep() async throws { try await run(.pager, steps: 30, seed: 0xD2B7) }

    /// The mutations of the other screens, each caught by the comparison: Home's Inbox not patched, the search not
    /// patched.
    @Test func otherScreenMutationsAreCaught() async {
        for (fault, opened) in [(OtherScreenFault.homeInboxNotPatched, Opened.home), (.searchNotPatched, .search("Show"))] {
            otherScreenFaults = [fault]
            await withKnownIssue("\(fault) is caught") { try await run(opened, steps: 40, seed: 0xD2B8) }
            otherScreenFaults = []
        }
    }

    // MARK: - Refresh failures

    /// A tile, list row and its spoken label follow the effective refresh failure (this device's or the server's), with
    /// every other field the same: local only, server only, one recovering while the other still fails, both recovering.
    @Test(arguments: [(3, false), (1, false), (3, true)])
    func tilesFollowTheRefreshFailure(columns: Int, rtl: Bool) async throws {
        let fixture = try await base.fixture(start: .home)
        let patched = base.controller(fixture, full: false), fresh = base.controller(fixture, full: true)
        do {
            try await withViewTestWindow { host, _ in
                if rtl { host.traitOverrides.layoutDirection = .rightToLeft }
                for controller in [fresh, patched] {
                    if rtl { controller.view.semanticContentAttribute = .forceRightToLeft }
                    host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                    controller.view.frame = host.view.bounds
                }
                defer {
                    for controller in [patched, fresh] { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                    host.traitOverrides.remove(UITraitLayoutDirection.self)
                }
                for controller in [patched, fresh] {
                    await controller.reloadLibrary()?.value
                    try await open(.subscriptions(columns: columns), controller, fixture)
                }
                let feed = fixture.feeds[1]
                @MainActor func failed(_ controller: LibraryViewController) -> (icon: Bool, label: String) {
                    let tile = controller.subscriptionGrid?.views[feed]
                    let icon = tile.flatMap { Self.find($0) { $0.accessibilityIdentifier == "subscriptionFailure-\(feed)" } }
                    return (icon.map { !$0.isHidden } ?? false, tile?.accessibilityLabel ?? "")
                }
                let steps: [(String, () async throws -> Void, Bool)] = [
                    ("local fails", { try await fixture.store.recordFailure(.httpStatus(500), feedID: feed, date: IncrementalScreenViewTests.now) }, true),
                    ("server fails too", { try await Self.setServerRefresh(fixture.store, feed: feed, failed: true) }, true),
                    ("local recovers, server still fails", { try await Self.clearLocalFailure(fixture.store, feed: feed) }, true),
                    ("server recovers", { try await Self.setServerRefresh(fixture.store, feed: feed, failed: false) }, false),
                    ("server only fails", { try await Self.setServerRefresh(fixture.store, feed: feed, failed: true) }, true),
                    ("local fails, server recovers", {
                        try await fixture.store.recordFailure(.httpStatus(404), feedID: feed, date: IncrementalScreenViewTests.now.addingTimeInterval(1))
                        try await Self.setServerRefresh(fixture.store, feed: feed, failed: false)
                    }, true),
                    ("both recover", { try await Self.clearLocalFailure(fixture.store, feed: feed) }, false),
                ]
                for (name, step, expected) in steps {
                    let renders = patched.renderCountForTesting
                    try await step()
                    await patched.reloadLibrary()?.value
                    await fresh.reloadLibrary()?.value
                    patched.view.layoutIfNeeded(); fresh.view.layoutIfNeeded()
                    #expect(failed(patched).icon == expected, "\(name): the failure icon")
                    #expect(failed(patched).label.contains(Appearance.text("refresh_failed_msg")) == expected, "\(name): the spoken label")
                    #expect(failed(patched).icon == failed(fresh).icon && failed(patched).label == failed(fresh).label, "\(name): as a fresh open")
                    #expect(patched.renderCountForTesting == renders, "\(name): the tile is patched")
                }
            }
        } catch { await base.close(fixture); throw error }
        await base.close(fixture)
    }

    // MARK: - Queue rows in two sections, returns, statistics shown again and strip places

    /// Mounts `controllers` in one test window (right-to-left when asked), loaded.
    func mounted(_ controllers: [LibraryViewController], rtl: Bool = false, _ body: @MainActor (ViewTestWindowHost) async throws -> Void) async throws {
        try await withViewTestWindow { host, _ in
            if rtl { host.traitOverrides.layoutDirection = .rightToLeft }
            for controller in controllers {
                if rtl { controller.view.semanticContentAttribute = .forceRightToLeft }
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                controller.view.frame = host.view.bounds
                controller.view.layoutIfNeeded()
            }
            defer {
                for controller in controllers { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                host.traitOverrides.remove(UITraitLayoutDirection.self)
            }
            for controller in controllers { await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded() }
            try await body(host)
        }
    }

    /// Listening to `episode` now (played time, last played and history), as a player's saves leave it.
    nonisolated static func listen(_ store: FeedLibraryStore, episode: Int64, minutes: Int64) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await store.updateEpisode(id: episode) { stored in
            stored.userState.playedDurationMilliseconds += minutes * 60_000
            stored.userState.lastPlayedTimeMilliseconds = now
            stored.userState.lastPlayedHistoryMilliseconds = now
        }
    }

    /// An episode with a row in two Home sections (a downloaded NEW episode in Inbox and Downloads) shows and speaks
    /// its queue membership in both when it changes, in either section order. (Add to queue takes an episode out of the
    /// Inbox, so the queued NEW episode is taken out of the queue.)
    @Test(arguments: [false, true])
    func aDuplicateHomeEpisodeShowsTheQueueInBothSections(downloadsFirst: Bool) async throws {
        let fixture = try await base.fixture(start: .home)
        let controller = base.controller(fixture, full: false)
        if downloadsFirst {
            let preferences = try HomeSectionPreferenceStore(file: fixture.folder.appendingPathComponent("home.json"))
            try preferences.update(.init(order: "DownloadsSection,InboxSection,QueueSection,EpisodesSurpriseSection,SubscriptionsSection"))
            controller.homePreferences = preferences
        }
        // The newest episode, NEW and the only download, not queued.
        let target = try #require(try await fixture.store.feed(id: fixture.feeds[0])?.episodes.first { $0.details.media != nil }).id
        try await fixture.store.updateEpisode(id: target) { stored in
            stored.userState.playState = .new; stored.userState.isDownloaded = true; stored.userState.downloadDate = IncrementalScreenViewTests.now
            stored.details.publicationDate = IncrementalScreenViewTests.now.addingTimeInterval(86_400 * 3_650)
        }
        _ = try await fixture.store.enqueue([target])
        try await fixture.store.updateEpisode(id: target) { $0.userState.playState = .new }
        do {
            try await mounted([controller]) { _ in
                @MainActor func spoken(_ section: HomeSection) -> String? {
                    guard let state = controller.homeSections.first(where: { $0.section == section }) else { return nil }
                    let row = state.views.compactMap { $0 as? EpisodeRowView }.first { $0.actionModel?.episodeID == target }
                    // What VoiceOver says of the row (its open control's label and value, the indicators included).
                    let open = row.flatMap { Self.find($0) { $0.accessibilityIdentifier == "episode-\(target)" } }
                    return open.map { [$0.accessibilityLabel, $0.accessibilityValue].compactMap { $0 }.joined(separator: ", ") }
                }
                let inQueue = Appearance.text("in_queue_label")
                let inbox = try #require(spoken(.inbox)), downloads = try #require(spoken(.downloads))
                #expect(inbox.contains(inQueue) && downloads.contains(inQueue), "both rows show In queue: \(inbox) / \(downloads)")
                _ = try await fixture.store.removeFromQueue([target])
                await controller.reloadLibrary()?.value
                controller.view.layoutIfNeeded()
                #expect(spoken(.inbox).map { !$0.contains(inQueue) } == true, "Inbox's row no longer shows In queue: \(spoken(.inbox) ?? "")")
                #expect(spoken(.downloads).map { !$0.contains(inQueue) } == true, "Downloads' row no longer shows In queue: \(spoken(.downloads) ?? "")")
            }
        } catch { await base.close(fixture); throw error }
        await base.close(fixture)
    }

    /// Listening while the app is in the background, then the return: Classics, loaded at the return, counts that
    /// listening (as a fresh open does), after the changes made meanwhile reach the screen.
    @Test func foregroundClassicsFollowTheBackgroundChanges() async throws {
        let fixture = try await base.fixture(start: .home)
        let patched = base.controller(fixture, full: false), fresh = base.controller(fixture, full: true)
        do {
            try await mounted([patched, fresh]) { _ in
                let before = try #require(patched.homeModel?.classics)
                let last = try #require(before.last)
                let episode = try #require(patched.mirror.feed(last)?.episodes.first { $0.details.media != nil }).id
                patched.applicationInBackground = { true }
                patched.applicationDidEnterBackgroundForScreens()
                try await Self.listen(fixture.store, episode: episode, minutes: 600)
                await fresh.reloadLibrary()?.value
                #expect(fresh.homeModel?.classics.first == last, "a fresh open ranks the listened podcast first")
                patched.applicationInBackground = { false }
                patched.applicationDidBecomeActive()
                try await base.wait("Classics at the return equals a fresh open") {
                    patched.homeModel?.classics == fresh.homeModel?.classics && patched.homeModel?.classics.first == last
                }
            }
        } catch { await base.close(fixture); throw error }
        await base.close(fixture)
    }

    /// A Statistics page selected again loads against the library now.
    @Test func aStatisticsTabSelectedAgainShowsTheNewTotals() async throws {
        let fixture = try await base.fixture(start: .home)
        let preferences = try StatisticsPreferenceStore(file: fixture.folder.appendingPathComponent("statistics.json"))
        let controller = LibraryViewController(library: fixture.store, startupError: nil, downloads: fixture.downloads, playback: fixture.playback,
            timeDisplayPreferences: nil, navigationPreferences: fixture.navigation, speedPreferences: nil,
            mobileNetworkPreferences: nil, usage: nil, statisticsPreferences: preferences)
        do {
            try await mounted([controller]) { _ in
                controller.select(.statistics)
                controller.view.layoutIfNeeded()
                try await base.wait("loaded") { if case .loaded = controller.subscriptionStatistics?.state { true } else { false } }
                controller.statisticsPager.onSelect?(StatisticsTab.years.rawValue)
                let episode = try #require(controller.mirror.feeds.last?.episodes.first { $0.details.media != nil }).id
                try await Self.listen(fixture.store, episode: episode, minutes: 90)
                await controller.reloadLibrary()?.value
                controller.statisticsPager.onSelect?(StatisticsTab.subscriptions.rawValue)
                let input = try await fixture.store.statisticsLibrary()
                let expected = try SubscriptionStatisticsSnapshot(feeds: input.feeds, units: input.units,
                    request: .init(preferences: preferences.value, formatter: .init())).rows.map(\.statistics)
                try await base.wait("the page shows the new totals") {
                    if case .loaded(let snapshot) = controller.subscriptionStatistics?.state { snapshot.rows.map(\.statistics) == expected } else { false }
                }
            }
        } catch { await base.close(fixture); throw error }
        await base.close(fixture)
    }

    /// Feed Information shown again after Back loads its statistics against the library now, equal to a fresh open.
    @Test func feedInformationShownAgainShowsTheNewTotals() async throws {
        let fixture = try await base.fixture(start: .home)
        let patched = base.controller(fixture, full: false), fresh = base.controller(fixture, full: true)
        let feed = fixture.feeds[1]
        do {
            try await mounted([patched, fresh]) { _ in
                for controller in [patched, fresh] { controller.push(.feedInformation(feed)); controller.view.layoutIfNeeded() }
                let information = try #require(patched.feedInformation), opened = try #require(fresh.feedInformation)
                let played = Appearance.text("statistics_time_played")
                try await base.wait("both loaded their statistics") {
                    Self.labels(information).contains(played) && Self.labels(information) == Self.labels(opened)
                }
                let before = Self.labels(information)
                patched.push(.feed(feed))
                let episode = try #require(patched.mirror.feed(feed)?.episodes.first { $0.details.media != nil }).id
                try await Self.listen(fixture.store, episode: episode, minutes: 90)
                await patched.reloadLibrary()?.value
                // Back, as the person taps it.
                let back = try #require(Self.find(patched.view) { $0.accessibilityIdentifier == "toolbarBack" } as? UIButton)
                back.sendActions(for: .touchUpInside)
                patched.view.layoutIfNeeded()
                guard case .feedInformation(feed) = patched.path.last else { Issue.record("Back shows Feed Information"); return }
                #expect(patched.feedInformation === information, "the same screen is shown again")
                #expect(information.statisticsLoads == 2, "its statistics load again at its return")
                // A fresh open: a new screen, reading the statistics now.
                fresh.popToParent(); fresh.feedInformation = nil
                fresh.push(.feedInformation(feed)); fresh.view.layoutIfNeeded()
                let reference = try #require(fresh.feedInformation)
                #expect(reference !== opened)
                try await base.wait("the cards show the new totals, as a fresh open: \(Self.labels(information)) / \(Self.labels(reference)) / \(before)") {
                    let mine = Self.labels(information), theirs = Self.labels(reference)
                    return theirs.contains(played) && mine == theirs && mine != before
                }
            }
        } catch { await base.close(fixture); throw error }
        await base.close(fixture)
    }

    /// A Home strip keeps the person's place when its section changes: the first visible card stays where it was, or
    /// the nearest one that stays when it left.
    @Test(arguments: [false, true])
    func aHomeStripKeepsItsPlace(rtl: Bool) async throws {
        let fixture = try await base.fixture(start: .home)
        let controller = base.controller(fixture, full: false)
        do {
            try await mounted([controller], rtl: rtl) { _ in
                @MainActor func strip() throws -> (HomeStrip, [Int64]) {
                    let state = try #require(controller.homeSections.first { $0.section == .queue })
                    return (try #require(state.views.compactMap { $0 as? HomeStrip }.first), state.shown.rows.map(\.1.id))
                }
                @MainActor func firstVisible() throws -> (id: Int64, distance: CGFloat) {
                    let (view, ids) = try strip()
                    view.layoutIfNeeded()
                    let cards = view.itemViews.enumerated().filter { $0.offset < ids.count && $0.element.frame.intersects(view.bounds) }
                    let first = try #require(rtl ? cards.max { $0.element.frame.maxX < $1.element.frame.maxX } : cards.min { $0.element.frame.minX < $1.element.frame.minX })
                    return (ids[first.offset], rtl ? view.bounds.maxX - first.element.frame.maxX : first.element.frame.minX - view.bounds.minX)
                }
                let (view, ids) = try strip()
                try #require(ids.count >= 6 && view.contentSize.width > view.bounds.width)
                view.layoutIfNeeded()
                // Scrolled towards card 3, as far as the strip scrolls (a wide screen shows most cards at once).
                let card = view.itemViews[3].frame, limit = max(0, view.contentSize.width - view.bounds.width)
                view.contentOffset.x = min(max(0, rtl ? card.maxX + 5 - view.bounds.width : card.minX - 5), limit)
                let place = try firstVisible()
                let index = try #require(ids.firstIndex(of: place.id))
                // A change to a card's episode (a favourite) draws the strip again: the place is kept.
                try await fixture.store.setFavorite(episodeID: ids[min(index + 1, ids.count - 1)], favorite: true)
                await controller.reloadLibrary()?.value
                controller.view.layoutIfNeeded()
                #expect(try strip().0 !== view, "the strip was drawn again")
                let kept = try firstVisible()
                #expect(kept.id == place.id && abs(kept.distance - place.distance) < 1, "the first visible card stays in place")
                // The first visible card leaves (out of the queue): the next one takes its place, unless the strip ends
                // before (then it is scrolled to its end).
                _ = try await fixture.store.removeFromQueue([place.id])
                await controller.reloadLibrary()?.value
                controller.view.layoutIfNeeded()
                let (after, now) = try strip()
                after.layoutIfNeeded()
                let successor = try #require(now.firstIndex(of: ids[index + 1]))
                let frame = after.itemViews[successor].frame
                let desired = rtl ? frame.maxX + place.distance - after.bounds.width : frame.minX - place.distance
                let expected = min(max(0, desired), max(0, after.contentSize.width - after.bounds.width))
                #expect(abs(after.contentOffset.x - expected) < 1, "the nearest surviving card takes the place (within the strip)")
            }
        } catch { await base.close(fixture); throw error }
        await base.close(fixture)
    }

    // MARK: - Work independent of the queue's length, notes in an open search and Classics' place

    /// The fixture with `extra` more queued episodes (a podcast of that many, all in the queue).
    func queuedFixture(extra: Int) async throws -> IncrementalScreenViewTests.Fixture {
        var fixture = try await base.fixture(start: .home)
        guard extra > 0 else { return fixture }
        let feed = try await fixture.store.insert(IncrementalScreenViewTests.fetched(7, count: extra), options: .init(now: IncrementalScreenViewTests.now))
        fixture.feeds.append(feed.id)
        _ = try await fixture.store.enqueue(feed.episodes.map(\.id))
        return fixture
    }

    /// A commit that changes only an episode's notes reaches an open search: a word the notes gain starts matching and
    /// a word they lose stops, as a fresh search finds.
    @Test func aShowNotesOnlyChangeReachesAnOpenSearch() async throws {
        let fixture = try await base.fixture(start: .home)
        let controller = base.controller(fixture, full: false)
        do {
            try await mounted([controller]) { _ in
                await controller.reloadLibrary()?.value
                let target = try #require(controller.mirror.feeds.first { $0.subscriptionState == .subscribed }?.episodes.first).id
                try await fixture.store.updateEpisode(id: target) { $0.details.description = "<p>zebrafinch</p>" }
                await controller.reloadLibrary()?.value
                try await open(.search("quokkaword"), controller, fixture)
                guard case .search(let search) = controller.path.last else { Issue.record("no search"); return }
                try await base.wait("searched") { search.session.resultRevision > 0 && !search.session.loading }
                #expect(search.displayedIDs.isEmpty)
                for (notes, expected) in [("<p>quokkaword</p>", [target]), ("<p>zebrafinch</p>", [])] {
                    try await fixture.store.updateEpisode(id: target) { $0.details.description = notes }
                    await controller.reloadLibrary()?.value
                    let fresh = try await fixture.store.search(query: "quokkaword").episodes.map(\.episode.id)
                    #expect(fresh == expected)
                    #expect(search.displayedIDs == fresh, "after \(notes)")
                }
            }
        } catch { await base.close(fixture); throw error }
        await base.close(fixture)
    }

    /// One row painted again (a favourite on an Inbox row out of the queue) tests queue membership the same number of
    /// times with a short queue and with 5,000 more queued episodes: the kept set, never a walk of the queue.
    @Test func aRowRepaintTestsTheQueueByKey() async throws {
        var visited: [Int] = []
        for extra in [0, 5_000] {
            let fixture = try await queuedFixture(extra: extra)
            let controller = base.controller(fixture, full: false)
            do {
                try await mounted([controller]) { _ in
                    controller.select(.inbox); controller.view.layoutIfNeeded()
                    let target = try #require(controller.episodeList?.views.keys.sorted().first { !controller.mirror.queuedIDs.contains($0) })
                    let row = try #require(controller.episodeRows[target]?.1)
                    let favorite = try #require(controller.libraryEpisode(target)?.episode.userState.isFavorite)
                    let before = controller.queueEntriesVisited
                    try await fixture.store.setFavorite(episodeID: target, favorite: !favorite)
                    await controller.reloadLibrary()?.value
                    #expect(controller.episodeRows[target]?.1 !== row, "the row was painted again")
                    visited.append(controller.queueEntriesVisited - before)
                }
            } catch { await base.close(fixture); throw error }
            await base.close(fixture)
        }
        print("Queue entries visited by one repaint (short queue, +5,000): \(visited)")
        #expect(visited.count == 2 && visited[0] == visited[1] && visited[0] <= 16, "queue entries visited: \(visited)")
    }

    /// Home's Continue does work independent of the queue's length for a queued card's favourite and for a change
    /// outside the queue, and shows what a fresh open shows.
    @Test func continueDoesNotSortTheQueue() async throws {
        var work: [[Int]] = []
        for extra in [0, 5_000] {
            let fixture = try await queuedFixture(extra: extra)
            let patched = base.controller(fixture, full: false), fresh = base.controller(fixture, full: true)
            do {
                try await mounted([patched, fresh]) { _ in
                    @MainActor func cards(_ controller: LibraryViewController) -> [Int64] {
                        controller.homeSections.first { $0.section == .queue }?.shown.rows.map(\.1.id) ?? []
                    }
                    let card = try #require(cards(patched).first)
                    let outside = try #require(patched.mirror.feeds.first?.episodes.first { !patched.mirror.queuedIDs.contains($0.id) }).id
                    var counts: [Int] = []
                    for target in [card, outside] {
                        let before = try #require(patched.homeModel?.metrics.continueVisited)
                        let favorite = try #require(patched.libraryEpisode(target)?.episode.userState.isFavorite)
                        let patches = patched.screenPatchCount
                        try await fixture.store.setFavorite(episodeID: target, favorite: !favorite)
                        await patched.reloadLibrary()?.value
                        await fresh.reloadLibrary()?.value
                        #expect(patched.screenPatchCount > patches, "the change reached Home")
                        counts.append(try #require(patched.homeModel?.metrics.continueVisited) - before)
                        #expect(cards(patched) == cards(fresh), "Continue as a fresh open")
                    }
                    work.append(counts)
                }
            } catch { await base.close(fixture); throw error }
            await base.close(fixture)
        }
        print("Continue work per change [queued card, outside] (short queue, +5,000): \(work)")
        #expect(work.count == 2 && work[0] == work[1] && work.joined().allSatisfy { $0 <= 64 }, "Continue's work per change: \(work)")
    }

    /// Classics' strip keeps the person's place when it is drawn again: the first visible podcast stays at its distance
    /// from the reading edge (a podcast's title changed), or the nearest one that stays takes it (that podcast archived),
    /// within the strip.
    @Test(arguments: [false, true])
    func aClassicsStripKeepsItsPlace(rtl: Bool) async throws {
        var fixture = try await base.fixture(start: .home)
        for number in 3..<9 {
            fixture.feeds.append(try await fixture.store.insert(IncrementalScreenViewTests.fetched(number, count: 3), options: .init(now: IncrementalScreenViewTests.now)).id)
        }
        let controller = base.controller(fixture, full: false)
        do {
            try await mounted([controller], rtl: rtl) { _ in
                @MainActor func strip() throws -> (HomeStrip, [Int64]) {
                    let state = try #require(controller.homeSections.first { $0.section == .classics })
                    let view = try #require(state.views.compactMap { $0 as? HomeStrip }.first)
                    view.layoutIfNeeded()
                    return (view, state.shown.feeds.map(\.id))
                }
                @MainActor func firstVisible() throws -> (id: Int64, distance: CGFloat) {
                    let (view, ids) = try strip()
                    let cards = view.itemViews.enumerated().filter { $0.offset < ids.count && $0.element.frame.intersects(view.bounds) }
                    let first = try #require(rtl ? cards.max { $0.element.frame.maxX < $1.element.frame.maxX } : cards.min { $0.element.frame.minX < $1.element.frame.minX })
                    return (ids[first.offset], rtl ? view.bounds.maxX - first.element.frame.maxX : first.element.frame.minX - view.bounds.minX)
                }
                /// The offset that puts podcast `id` at `distance` from the reading edge, within the strip.
                @MainActor func expectedOffset(_ id: Int64, _ distance: CGFloat) throws -> CGFloat {
                    let (view, ids) = try strip()
                    let frame = view.itemViews[try #require(ids.firstIndex(of: id))].frame
                    let desired = rtl ? frame.maxX + distance - view.bounds.width : frame.minX - distance
                    return min(max(0, desired), max(0, view.contentSize.width - view.bounds.width))
                }
                // A phone's width, where Classics' eight covers scroll (an iPad shows them all at once).
                controller.view.frame.size.width = min(controller.view.frame.width, 402)
                controller.view.layoutIfNeeded()
                controller.render(); controller.view.layoutIfNeeded()
                let (view, ids) = try strip()
                try #require(ids.count >= 6 && view.contentSize.width > view.bounds.width)
                let card = view.itemViews[3].frame, limit = max(0, view.contentSize.width - view.bounds.width)
                view.contentOffset.x = min(max(0, rtl ? card.maxX + 5 - view.bounds.width : card.minX - 5), limit)
                let place = try firstVisible()
                let index = try #require(ids.firstIndex(of: place.id))
                // A shown podcast's title changes: Classics loads again and its strip is drawn again, keeping the place.
                try await fixture.store.updatePreferences(feedID: ids[min(index + 1, ids.count - 1)]) { $0.customTitle = "Renamed" }
                await controller.reloadLibrary()?.value
                controller.view.layoutIfNeeded()
                #expect(try strip().0 !== view, "the strip was drawn again")
                #expect(abs(try strip().0.contentOffset.x - expectedOffset(place.id, place.distance)) < 1, "the first visible podcast stays in place")
                // That podcast is archived (it leaves Classics): the nearest one that stays takes the place.
                let order = try strip().1
                let at = try #require(order.firstIndex(of: place.id))
                try await fixture.store.updatePreferences(feedID: place.id) { $0.subscriptionState = .archived }
                await controller.reloadLibrary()?.value
                controller.view.layoutIfNeeded()
                let now = try strip().1
                let successor = try #require((order[(at + 1)...] + order[..<at].reversed()).first { now.contains($0) })
                #expect(abs(try strip().0.contentOffset.x - expectedOffset(successor, place.distance)) < 1, "the nearest podcast that stays takes the place")
            }
        } catch { await base.close(fixture); throw error }
        await base.close(fixture)
    }

    // MARK: - Statistics

    /// Statistics load on open, on their return and on StatisticsEvent, never on routine changes (Android's statistics
    /// fragments do not listen to them); after an event they equal a fresh read.
    @Test func statisticsFollowTheirEventsNotTheLibrary() async throws {
        var fixture = try await base.fixture(start: .home)
        let preferences = try StatisticsPreferenceStore(file: fixture.folder.appendingPathComponent("statistics.json"))
        let controller = LibraryViewController(library: fixture.store, startupError: nil, downloads: fixture.downloads, playback: fixture.playback,
            timeDisplayPreferences: nil, navigationPreferences: fixture.navigation, speedPreferences: nil,
            mobileNetworkPreferences: nil, usage: nil, statisticsPreferences: preferences)
        do {
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                controller.view.frame = host.view.bounds
                await controller.reloadLibrary()?.value
                controller.select(.statistics)
                controller.view.layoutIfNeeded()
                try await base.wait("statistics loaded") { if case .loaded = controller.subscriptionStatistics?.state { true } else { false } }
                #expect(controller.statisticsLoads == 1)
                var random = ViewTestRandom(state: 0xD2B9)
                for _ in 0..<12 {
                    let step = IncrementalScreenViewTests.Step.allCases[random.below(IncrementalScreenViewTests.Step.allCases.count)]
                    try await base.perform(step, &fixture, random: &random, visible: [])
                    await controller.reloadLibrary()?.value
                }
                #expect(controller.statisticsLoads == 1, "no load on routine changes")
                // StatisticsEvent (the filter's OK): a load, equal to a fresh read now.
                try preferences.update(preferences.value)
                try await base.wait("loaded again") { controller.statisticsLoads == 2 }
                try await base.wait("the event's load") { if case .loaded = controller.subscriptionStatistics?.state { true } else { false } }
                let input = try await fixture.store.statisticsLibrary()
                let fresh = try SubscriptionStatisticsSnapshot(feeds: input.feeds, units: input.units,
                    request: .init(preferences: preferences.value, formatter: .init()))
                if case .loaded(let snapshot) = controller.subscriptionStatistics?.state {
                    #expect(snapshot.rows.map(\.statistics) == fresh.rows.map(\.statistics))
                }
            }
        } catch { await base.close(fixture); throw error }
        await base.close(fixture)
    }

    // MARK: - Player

    /// The player reads its podcast and episode by key: a remote pinned removal while playing takes the podcast out of
    /// every list, and the player keeps its title through the player's own read.
    @Test func thePlayerKeepsAPinnedRemovalsMetadata() async throws {
        let fixture = try await base.fixture(start: .inbox)
        let controller = LibraryViewController(library: fixture.store, startupError: nil, downloads: fixture.downloads, playback: fixture.playback,
            timeDisplayPreferences: try TimeDisplayPreferenceStore(file: fixture.folder.appendingPathComponent("time.json")),
            navigationPreferences: fixture.navigation, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
        do {
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                controller.view.frame = host.view.bounds
                await controller.reloadLibrary()?.value
                let feed = fixture.feeds[2]
                let episode = try #require(controller.mirror.feed(feed)?.episodes.first { $0.details.media != nil }).id
                try await fixture.playback.select(episodeID: episode, play: false)
                controller.updatePlayer()
                let title = try #require(controller.mirror.feed(feed)?.title)
                try await base.wait("the player shows the podcast") { controller.playerView.map { Self.labels($0).joined().contains(title) } ?? false }
                try await Self.pin(fixture.store, feed: feed)
                await controller.reloadLibrary()?.value
                #expect(!controller.mirror.contains(feed: feed), "no list shows the podcast")
                #expect(!controller.displayedEpisodeIDs.contains(episode))
                controller.updatePlayer()
                try await base.wait("the player keeps its podcast") { controller.playerView.map { Self.labels($0).joined().contains(title) } ?? false }
            }
        } catch { await base.close(fixture); throw error }
        await base.close(fixture)
    }

    nonisolated static func pin(_ store: FeedLibraryStore, feed: Int64) async throws {
        try await store.withDatabaseForTesting { database in
            try database.transaction { try database.execute("INSERT INTO pinned_feed_removals(feed_id) VALUES (?)", [.integer(feed)]) }
        }
    }

    // MARK: - Drawer at 50,000 episodes

    /// The drawer's order (every order, Most played and Most recent episode included) after a favourite, a played mark, a
    /// queue change and a position save at 50,000 episodes: computed from the kept counts and newest dates through the
    /// whole controller path, never from a scan of the episodes, and equal to the full read.
    @Test func theDrawerNeverScansTheLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DrawerBudget-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backup = root.appendingPathComponent("Antennapod.db")
        _ = try LargeAndroidLibrary.write(to: backup)
        let restored = try AndroidDatabaseRestore.read(backup, staging: root.appendingPathComponent("staging"))
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        try await store.installRestoredLibrary(restored, carrying: try await store.restoreCarryOver())
        let navigation = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
        var value = navigation.value; value.bottomNavigation = false; value.defaultPage = NavigationDestination.queue.rawValue
        try navigation.update(value)
        let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil, timeDisplayPreferences: nil,
            navigationPreferences: navigation, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
        do {
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                controller.view.frame = host.view.bounds
                await controller.reloadLibrary()?.value
                controller.view.layoutIfNeeded()
                #expect(controller.mirror.episodeCount >= 45_000)
                let ids = controller.mirror.feeds.flatMap { $0.episodes.prefix(3).map(\.id) }
                var random = ViewTestRandom(state: 0xD2BA)
                for order in FeedOrder.allCases {
                    controller.subscriptionFallback.feedOrder = order.stored
                    controller.drawerSignature = nil
                    controller.refreshNavigationCounters()
                    for step in ["favorite", "played", "queue", "position"] {
                        let target = ids[random.below(ids.count)]
                        switch step {
                        case "favorite": try await store.setFavorite(episodeID: target, favorite: true)
                        case "played": try await store.markEpisodePlayed(episodeID: target, played: true)
                        case "queue": _ = try await store.enqueue([target])
                        default: try await store.updateEpisode(id: target) { $0.userState.positionMilliseconds += 5_000 }
                        }
                        SubscriptionListQueries.episodesScanned = 0
                        await controller.reloadLibrary()?.value
                        #expect(SubscriptionListQueries.episodesScanned == 0, "\(order) \(step): no episode scanned by the drawer")
                        let expected = SubscriptionListQueries.load(controller.feeds, preferences: controller.subscriptionDisplay,
                                                                    state: .subscribed, globalAutoDownload: false)
                        let mine = controller.subscriptionList(controller.subscriptionDisplay, state: .subscribed)
                        #expect(mine.feeds.map(\.id) == expected.feeds.map(\.id), "\(order) \(step): the drawer's order")
                        #expect(mine.counters == expected.counters)
                    }
                }
            }
        } catch { try? await store.close(); throw error }
        try await store.close()
    }

    // MARK: - The drawer on the subscription screens

    enum SubscriptionRoute: CaseIterable { case subscriptions, archive, subscriptionList }

    /// A queue-only change (another device queues an episode that is neither NEW nor queued) while Subscriptions,
    /// Archive or the subscription-list route is open: the drawer's Queue counter, shown and spoken, follows at once,
    /// while the grid keeps its tiles and the screen is not drawn again.
    @Test(arguments: [(SubscriptionRoute.subscriptions, false), (.archive, false), (.subscriptionList, false), (.subscriptions, true)])
    func aQueueOnlyChangeUpdatesTheDrawerOnSubscriptionScreens(route: SubscriptionRoute, rtl: Bool) async throws {
        let fixture = try await base.fixture(start: .home)
        var value = fixture.navigation.value; value.bottomNavigation = false
        try fixture.navigation.update(value)
        try await fixture.store.updatePreferences(feedIDs: [fixture.feeds[2]]) { _, preferences in preferences.subscriptionState = .archived }
        let controller = base.controller(fixture, full: false)
        do {
            try await mounted([controller], rtl: rtl) { _ in
                switch route {
                case .subscriptions: controller.select(.subscriptions)
                case .archive: controller.select(.subscriptions); controller.push(.archive)
                case .subscriptionList:
                    controller.loadRootScreen(.destination(.subscriptionList), tag: NavigationDestination.subscriptions.rawValue)
                }
                controller.view.layoutIfNeeded()
                try await base.wait("the grid") { !(controller.subscriptionGrid?.ids ?? []).isEmpty }
                @MainActor func queueCounter() -> String? {
                    (Self.find(controller.view) { $0.accessibilityIdentifier == "drawer-" + NavigationDestination.queue.rawValue } as? UIControl)?
                        .accessibilityValue
                }
                let queued = controller.queuedEpisodes.count
                #expect(queueCounter() == "\(queued)")
                let target = try #require(controller.mirror.feed(fixture.feeds[0])?.episodes.first {
                    $0.details.media != nil && $0.userState.playState != .new && !controller.mirror.queuedIDs.contains($0.id)
                }).id
                let renders = controller.renderCountForTesting
                let tiles = controller.subscriptionGrid?.views.mapValues(ObjectIdentifier.init) ?? [:]
                _ = try await fixture.store.enqueue([target])
                await controller.settleLibraryChanges()
                controller.view.layoutIfNeeded()
                #expect(controller.queuedEpisodes.count == queued + 1)
                #expect(queueCounter() == "\(queued + 1)", "the drawer's Queue counter follows")
                #expect(controller.renderCountForTesting == renders, "no full render")
                #expect((controller.subscriptionGrid?.views.mapValues(ObjectIdentifier.init) ?? [:]) == tiles, "no tile built again")
            }
        } catch { await base.close(fixture); throw error }
        await base.close(fixture)
    }
}
