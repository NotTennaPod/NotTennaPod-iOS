import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Nothing plays in these tests; the coordinator only owns the library's playback rows.
@MainActor private final class QuietEngine: PlaybackEngine {
    var reading: PlaybackEngineReading?
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {}
    func play(commandID: UUID) {}
    func pause(commandID: UUID) {}
    func seek(to positionMilliseconds: Int64, commandID: UUID) {}
    func setSpeed(_ speed: Float, commandID: UUID) throws {}
    func unload() {}
}

/// The patched list screens against a fresh open, as a person sees them. Two controllers share one library: T keeps
/// itself current from the change sets (patches), F reads the whole library after every step (the old full reload).
/// After each seeded step on Queue, Episodes, Inbox, Downloads, Favorites, History and a 400-episode podcast page they
/// show the same rows in the same order with the same frames and spoken labels, the same Inbox badge, and T keeps the
/// first visible row where it was (item anchoring; F is placed by the same rule before the comparison). T draws its
/// screen again only when its list goes to or from empty, and builds again only the rows whose episode changed.
@MainActor @Suite(.serialized)
struct IncrementalScreenViewTests {
    struct Fixture {
        let folder: URL, store: FeedLibraryStore, navigation: NavigationPreferenceStore
        let downloads: DownloadCoordinator, playback: PlaybackCoordinator
        var feeds: [Int64] = []
    }

    nonisolated static let now = Date(timeIntervalSince1970: 1_760_000_000)

    static func fetched(_ number: Int, count: Int) -> FetchedFeed {
        let source = "https://example.test/incremental\(number).xml"
        let items = (1...count).map { item in
            ParsedEpisode(identifier: "\(source)#\(item)", title: "Show \(number) episode \(item)" + (item % 9 == 0 ? " with a longer title that wraps onto a second line" : ""),
                          publicationDate: now.addingTimeInterval(Double(item * 3_600 + number * 600)),
                          media: item % 11 == 0 ? nil : ParsedMedia(url: "https://media.example.test/\(number)/\(item).mp3", size: 1_000,
                                                                     durationMilliseconds: Int32(60_000 + item * 7 % 13 * 1_000)))
        }
        return FetchedFeed(feed: ParsedFeed(format: .rss, title: "Show \(number)", episodes: items), source: source,
                           responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil)
    }

    /// `queued`: a podcast of 5,500 episodes (5,000 with media) is added, and this many of them queued.
    func fixture(start: NavigationDestination, queued: Int = 0) async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Incremental-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try FeedLibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        var feeds: [Int64] = []
        for (number, count) in [(0, 400), (1, 120), (2, 60)] {
            feeds.append(try await store.insert(Self.fetched(number, count: count), options: .init(now: Self.now)).id)
        }
        // Some state for every list: favorites, history, a queue, downloads.
        let all = try await store.feeds().flatMap(\.episodes).map(\.id)
        try await store.setFavorite(episodeIDs: all.enumerated().filter { $0.offset % 17 == 0 }.map(\.element), favorite: true)
        for id in all.enumerated().filter({ $0.offset % 13 == 0 }).map(\.element) {
            try await store.updateEpisode(id: id) { $0.userState.lastPlayedHistoryMilliseconds = 1_700_000_000_000 + id * 1_000; $0.userState.playState = .played }
        }
        _ = try await store.enqueue(all.enumerated().filter { $0.offset % 23 == 0 }.map(\.element))
        if queued > 0 {
            let large = try await store.insert(Self.fetched(3, count: 5_500), options: .init(now: Self.now))
            feeds.append(large.id)
            _ = try await store.enqueue(Array(large.episodes.filter { $0.details.media != nil }.map(\.id).prefix(queued)))
        }
        // An Inbox: every third episode NEW.
        for id in all.enumerated().filter({ $0.offset % 3 == 1 }).map(\.element) {
            try await store.updateEpisode(id: id) { $0.userState.playState = .new }
        }
        let navigation = try NavigationPreferenceStore(file: folder.appendingPathComponent("navigation.json"))
        var value = navigation.value
        value.defaultPage = "remember"; value.lastPage = start.rawValue
        try navigation.update(value)
        let network = DownloadNetworkMonitor(startMonitoring: false)
        network.update(.init(connected: false, metered: false, cellular: false))
        let downloads = DownloadCoordinator(store: store, directory: folder.appendingPathComponent("media"), network: network,
                                            preferences: { DownloadPreferences() })
        return Fixture(folder: folder, store: store, navigation: navigation, downloads: downloads,
                       playback: PlaybackCoordinator(store: store, engine: QuietEngine()), feeds: feeds)
    }

    func controller(_ fixture: Fixture, full: Bool) -> LibraryViewController {
        let controller = LibraryViewController(library: fixture.store, startupError: nil, downloads: fixture.downloads, playback: fixture.playback,
            timeDisplayPreferences: nil, navigationPreferences: fixture.navigation, speedPreferences: nil,
            mobileNetworkPreferences: nil, usage: nil)
        if full { controller.useFullReadsForTesting() }
        return controller
    }

    func close(_ fixture: Fixture) async {
        try? await fixture.playback.stop(); await fixture.downloads.stop()
        try? await fixture.store.close(); try? FileManager.default.removeItem(at: fixture.folder)
    }

    func wait(_ stage: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate(), Comment(rawValue: stage))
    }

    /// What a person sees of the list: rows in order with their frames, the spoken labels of the rows built in both, and
    /// the Inbox badge.
    struct Shown: Equatable {
        var ids: [Int64]
        var frames: [CGRect]
        var labels: [Int64: String]
        var badge: Int?
    }

    /// What VoiceOver reads of a row: its accessible controls in traversal order (the row is only their container), each
    /// with its label, value, traits and actions.
    static func spoken(_ row: UIView) -> [String] {
        (row.accessibilityElements as? [UIView] ?? []).filter { !$0.isHidden }.map { element in
            [element.accessibilityLabel ?? "", element.accessibilityValue ?? "", String(element.accessibilityTraits.rawValue),
             (element.accessibilityCustomActions ?? []).map(\.name).joined(separator: ",")].joined(separator: " | ")
        }
    }

    func shown(_ controller: LibraryViewController, labelsOf ids: Set<Int64>? = nil) -> Shown {
        let list = controller.episodeList
        var labels: [Int64: String] = [:]
        for (id, (_, row)) in controller.episodeRows where ids?.contains(id) ?? true {
            labels[id] = Self.spoken(row).joined(separator: " || ")
        }
        let badge = (controller.view.firstSubview { $0.accessibilityIdentifier == NavigationDestination.inbox.rawValue } as? NavigationButton)?.badgeCount
        return Shown(ids: list?.ids ?? [], frames: list?.frames.map { $0.integral } ?? [], labels: labels, badge: badge)
    }

    enum Step: CaseIterable { case played, unplayed, favorite, unfavorite, dismiss, enqueue, dequeue, move, history, dateTie, refresh, download }

    func perform(_ step: Step, _ fixture: inout Fixture, random: inout ViewTestRandom, visible: [Int64]) async throws {
        let store = fixture.store
        let all = try await store.feeds().flatMap(\.episodes).map(\.id)
        // Mostly rows on screen or near it, sometimes anywhere.
        let target = (random.chance(70) && !visible.isEmpty ? visible[random.below(visible.count)] : all[random.below(all.count)])
        switch step {
        case .played, .unplayed: try await store.markEpisodePlayed(episodeID: target, played: step == .played)
        case .favorite, .unfavorite: try await store.setFavorite(episodeID: target, favorite: step == .favorite)
        case .dismiss: try await store.removeEpisodeFromInbox(episodeID: target)
        case .enqueue: _ = try await store.enqueue([target], location: random.chance(50) ? .front : .back)
        case .dequeue: _ = try await store.removeFromQueue([target])
        case .move:
            let queue = try await store.queue()
            guard queue.count > 1 else { return }
            _ = try await store.performQueueMove(.item(queue[random.below(queue.count)].id, finalIndex: random.below(queue.count)),
                                                 expected: queue.map(QueueEpisodeIdentity.init))
        case .history:
            let value = random.chance(30) ? nil : Int64(1_700_000_000_000 + random.below(1_000_000))
            let state: EpisodePlayState = random.chance(50) ? .new : .unplayed
            try await store.updateEpisode(id: target) { $0.userState.lastPlayedHistoryMilliseconds = value; $0.userState.playState = state }
        case .dateTie:
            let other = all[random.below(all.count)]
            let date = try await store.feeds().flatMap(\.episodes).first { $0.id == other }?.details.publicationDate
            try await store.updateEpisode(id: target) { $0.details.publicationDate = date }
        case .refresh:
            // A new episode at the top of the big podcast.
            let count = 400 + random.below(3) + 1
            _ = try await store.applyRefresh(Self.fetched(0, count: count), feedID: fixture.feeds[0], options: .init(now: Self.now))
        case .download:
            _ = try await store.updateEpisode(id: target) { episode in
                episode.userState.isDownloaded.toggle()
                episode.userState.downloadDate = episode.userState.isDownloaded ? Self.now : nil
            }
        }
    }

    func run(_ destination: NavigationDestination?, feedPage: Bool = false, rtl: Bool, steps: Int, seed: UInt64) async throws {
        var fixture = try await fixture(start: destination ?? .home)
        var random = ViewTestRandom(state: seed)
        weak var patchedScreen: LibraryViewController?, freshScreen: LibraryViewController?
        // Everything is closed, and both screens freed, before the next test starts (no work left behind).
        do {
            let patched = controller(fixture, full: false), fresh = controller(fixture, full: true)
            patchedScreen = patched; freshScreen = fresh
            try await compare(patched, fresh, &fixture, &random, destination: destination, feedPage: feedPage, rtl: rtl, steps: steps)
        } catch { await close(fixture); throw error }
        await close(fixture)
        try await wait("the screens are freed") { patchedScreen == nil && freshScreen == nil }
    }

    func compare(_ patched: LibraryViewController, _ fresh: LibraryViewController, _ fixture: inout Fixture, _ random: inout ViewTestRandom,
                 destination: NavigationDestination?, feedPage: Bool, rtl: Bool, steps: Int) async throws {
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
            for controller in [patched, fresh] {
                await controller.reloadLibrary()?.value
                if feedPage { controller.drawerAction(.feed(fixture.feeds[0])) }
                controller.view.layoutIfNeeded()
            }
            try await wait("both open") { patched.libraryLoaded && fresh.libraryLoaded && shown(patched).ids == shown(fresh).ids }
            // Read from the middle of the first page.
            for controller in [patched, fresh] {
                controller.content.setContentOffset(CGPoint(x: 0, y: min(1_500, max(0, controller.content.contentSize.height - controller.content.bounds.height))), animated: false)
                controller.updateVisibleContent()
            }
            for number in 0..<steps {
                let step = Step.allCases[random.below(Step.allCases.count)]
                let before = shown(patched)
                let renders = patched.renderCountForTesting
                let rowsBefore = patched.episodeRows.mapValues { ObjectIdentifier($0.1) }
                let valuesBefore = patched.displayedEpisodeValues.mapValues(\.episode)
                let queuedBefore = patched.mirror.queuedIDs
                let headersBefore = patched.displayedEpisodeValues.mapValues { RowPaint.Header($0.feed) }
                let anchor = patched.episodeList.map { patched.captureItemAnchor($0) }
                let visible = patched.episodeList?.views.keys.map { $0 } ?? []
                patched.episodeList?.metrics = .init()
                try await perform(step, &fixture, random: &random, visible: visible)
                await patched.reloadLibrary()?.value
                await fresh.reloadLibrary()?.value
                patched.view.layoutIfNeeded(); fresh.view.layoutIfNeeded()
                // The reference is placed by the same rule: its first visible row where the patched one keeps it.
                if let anchor, let list = fresh.episodeList { fresh.restoreItemAnchor(anchor, in: list); fresh.updateVisibleContent() }
                let label = "\(destination.map { $0.rawValue } ?? "feed") \(rtl ? "RTL" : "LTR") step \(number) \(step)"
                let after = shown(patched)
                let common = Set(after.labels.keys).intersection(shown(fresh).labels.keys)
                #expect(after.ids == shown(fresh).ids, "\(label): rows")
                #expect(after.frames == shown(fresh).frames, "\(label): frames")
                #expect(shown(patched, labelsOf: common).labels == shown(fresh, labelsOf: common).labels, "\(label): spoken rows")
                // What is compared is real: every compared row speaks its episode's title and a nonempty value.
                for id in common {
                    let first = (patched.episodeRows[id]?.1.accessibilityElements?.first as? UIView)
                    #expect(first?.accessibilityLabel?.isEmpty == false && first?.accessibilityValue?.isEmpty == false, "\(label): row \(id) speaks")
                }
                #expect(after.badge == shown(fresh).badge, "\(label): Inbox badge")
                #expect(abs(patched.content.contentOffset.y - fresh.content.contentOffset.y) < 0.5, "\(label): reading position")
                // Geometry work on the main actor: one chunk of row entries per change, and only the views that exist.
                if let metrics = patched.episodeList?.metrics {
                    #expect(metrics.rowsMoved <= 4 * 256, "\(label): row entries moved \(metrics.rowsMoved)")
                    #expect(metrics.viewsMoved <= 8 * max(1, patched.episodeList?.views.count ?? 0), "\(label): views moved \(metrics.viewsMoved)")
                }
                // Drawn again only to or from empty; rows rebuilt only when their episode changed.
                let emptyChange = before.ids.isEmpty != after.ids.isEmpty
                if !emptyChange { #expect(patched.renderCountForTesting == renders, "\(label): no full render") }
                for (id, row) in rowsBefore {
                    guard let now = patched.episodeRows[id], ObjectIdentifier(now.1) != row else { continue }
                    // A legitimate rebuild: the stored episode, its queue membership or what it shows of its podcast changed.
                    let inputsChanged = valuesBefore[id] != patched.displayedEpisodeValues[id]?.episode
                        || queuedBefore.contains(id) != patched.mirror.queuedIDs.contains(id)
                        || headersBefore[id] != patched.displayedEpisodeValues[id].map({ RowPaint.Header($0.feed) })
                    #expect(inputsChanged, "\(label): row \(id) rebuilt without a change")
                }
                // VoiceOver reads the built rows in list order.
                let order = patched.content.subviews.compactMap { view in patched.episodeList?.views.first { $0.value === view }?.key }
                #expect(order == after.ids.filter { patched.episodeList?.views[$0] != nil }, "\(label): reading order")
                if after.ids != shown(fresh).ids { break }
            }
            #expect(patched.screenPatchCount > 0)
        }
    }

    @Test(arguments: [NavigationDestination.inbox, .episodes, .favorites, .history, .queue, .downloads])
    func listsEqualAFreshOpenAfterEveryStep(destination: NavigationDestination) async throws {
        try await run(destination, rtl: false, steps: 40, seed: 0xD2A0 &+ UInt64(destination.rawValue.count))
    }

    @Test func aPodcastPageEqualsAFreshOpenAfterEveryStep() async throws {
        try await run(nil, feedPage: true, rtl: false, steps: 40, seed: 0xD2A1)
    }

    @Test(arguments: [NavigationDestination.inbox, .queue])
    func rightToLeftListsEqualAFreshOpen(destination: NavigationDestination) async throws {
        try await run(destination, rtl: true, steps: 20, seed: 0xD2A2)
    }

    /// Each mutation of the patch is caught by the comparison with a fresh open: a reading position not kept, every
    /// built row built again, a full render on a routine change.
    @Test(arguments: [ScreenPatchFault.readingPositionNotKept, .everyRowRebuilt, .renderEveryPatch])
    func patchMutationsAreCaught(fault: ScreenPatchFault) async throws {
        screenPatchFaults = [fault]
        defer { screenPatchFaults = [] }
        await withKnownIssue("\(fault) is caught") {
            try await run(.inbox, rtl: false, steps: 30, seed: 0xD2A3)
        }
    }

    /// Held-detach on a patched list: the server removes a podcast while the player holds one of its episodes (the
    /// podcast leaves Episodes, its held episode stays for the player only), the podcast is subscribed again (a fresh
    /// subscription of its own shows), and the player leaves the episode (the release deletes the detached rows). After
    /// each step the patched screen equals one reading the whole library, and no row of a removed podcast shows.
    @Test func aPodcastRemovedWhileHeldLeavesThePatchedListAsAFullReadShowsIt() async throws { try await heldDetach() }

    /// Its mutation: a podcast that left the lists patched as a header change only keeps its rows on screen.
    @Test func aHeldRemovalPatchedAsAHeaderChangeIsCaught() async {
        screenModelFaults = [.feedResetIgnored]
        defer { screenModelFaults = [] }
        await withKnownIssue("a feed reset ignored is caught") { try await heldDetach() }
    }

    func heldDetach() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IncrementalHeld-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try FeedLibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        let namespace = ContractIdentity.randomUUID()
        try await store.initializeServerLibrary(ServerLibraryIdentity(libraryID: ContractIdentity.randomUUID(), serverURL: "http://127.0.0.1:1",
            serverID: nil, accountID: ContractIdentity.randomUUID(), namespace: namespace, username: nil,
            installID: ContractIdentity.randomUUID(), deviceMarker: nil))
        // Two podcasts the server knows.
        var registered: [(feed: Int64, podcast: String, generation: String)] = []
        for number in 0..<2 {
            let feed = try await store.insert(Self.fetched(10 + number, count: 30), options: .init(now: Self.now))
            let creating = try #require(try await store.registrationOpForViewTests(feedID: feed.id))
            let podcast = try ContractIdentity.podcastID(namespace: namespace, creatingOpID: creating)
            let generation = try ContractIdentity.generationID(namespace: namespace, podcastID: podcast, creatingOpID: creating)
            try await store.resolveRegistration(opID: creating, .init(podcastID: podcast, generationID: generation, mode: "created", decisionID: nil))
            registered.append((feed.id, podcast, generation))
        }
        try await store.retireFactsForViewTests()
        let log = ContractIdentity.randomUUID()
        var seq: Int64 = 0
        func apply(_ records: [ServerRecord]) async throws {
            seq += 1
            let cursor = try SyncCursor(logID: log, epoch: 1, seq: seq, digest: ContractIdentity.sha256Hex(Array("\(log)\(seq)".utf8)))
            _ = try await store.applyServerUnit(ServerUnitInput(commit: ServerCommit(epoch: 1, seq: seq, records: records), cursor: cursor,
                                                                watermark: nil, now: 1_760_000_000_000), history: nil, maxWork: nil)
        }
        try await store.setCursorForViewTests(try SyncCursor(logID: log, epoch: 1, seq: 0, digest: String(repeating: "0", count: 64)))
        let navigation = try NavigationPreferenceStore(file: folder.appendingPathComponent("navigation.json"))
        var value = navigation.value; value.defaultPage = "remember"; value.lastPage = NavigationDestination.episodes.rawValue
        try navigation.update(value)
        weak var patchedScreen: LibraryViewController?, freshScreen: LibraryViewController?
        do {
            let patched = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil, timeDisplayPreferences: nil,
                navigationPreferences: navigation, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
            let fresh = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil, timeDisplayPreferences: nil,
                navigationPreferences: navigation, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
            fresh.useFullReadsForTesting()
            patchedScreen = patched; freshScreen = fresh
            try await withViewTestWindow { host, _ in
                for controller in [fresh, patched] {
                    host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                    controller.view.frame = host.view.bounds
                    controller.view.layoutIfNeeded()
                }
                defer { for controller in [patched, fresh] { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() } }
                for controller in [patched, fresh] { await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded() }
                @MainActor func compare(_ label: String, removed: Int64?) async throws {
                    await patched.reloadLibrary()?.value
                    await fresh.reloadLibrary()?.value
                    patched.view.layoutIfNeeded(); fresh.view.layoutIfNeeded()
                    #expect(shown(patched).ids == shown(fresh).ids, "\(label): rows")
                    #expect(shown(patched).frames == shown(fresh).frames, "\(label): frames")
                    #expect(shown(patched).badge == shown(fresh).badge, "\(label): Inbox badge")
                    if let removed {
                        #expect(patched.feeds.allSatisfy { $0.id != removed }, "\(label): the removed podcast is in no list")
                        #expect(patched.displayedEpisodeValues.values.allSatisfy { $0.feed.id != removed }, "\(label): no row of it shows")
                    }
                }
                try await compare("open", removed: nil)
                // The player holds an episode of the first podcast; the server removes the podcast.
                let held = try #require(try await store.feed(id: registered[0].feed)?.episodes.first { $0.details.media != nil }).id
                _ = try await store.beginPlayback(episodeID: held)
                try await apply([ServerRecord(entity: "podcast", id: registered[0].podcast, fieldGroup: "subscription",
                                              value: ["state": "removed", "generation_id": .string(registered[0].generation)])])
                try await compare("removed while held", removed: registered[0].feed)
                // Subscribed again: a fresh subscription in a feed of its own.
                let next = try ContractIdentity.generationID(namespace: namespace, podcastID: registered[0].podcast, creatingOpID: ContractIdentity.randomUUID())
                try await apply([ServerRecord(entity: "podcast", id: registered[0].podcast, fieldGroup: "subscription",
                                              value: ["state": "subscribed", "generation_id": .string(next)])])
                try await compare("subscribed again while held", removed: registered[0].feed)
                #expect(patched.feeds.count == 2 && patched.feeds.contains { $0.id != registered[0].feed && $0.id != registered[1].feed },
                        "the podcast subscribed again shows in a feed of its own")
                // The player leaves the episode: the release deletes the detached rows.
                try await store.resetPlaybackPosition(episodeID: held)
                _ = try await store.releaseServerPins()
                try await compare("released", removed: registered[0].feed)
                #expect(try await store.episode(id: held) == nil, "the held row is gone after the release")
            }
        } catch { try? await store.close(); try? FileManager.default.removeItem(at: folder); throw error }
        try await store.close(); try? FileManager.default.removeItem(at: folder)
        try await wait("the screens are freed") { patchedScreen == nil && freshScreen == nil }
    }

    // MARK: - Rows painted from what they show

    /// A patched and a full-reading screen on one library, open on `destination`, for a targeted probe.
    func mounted(_ destination: NavigationDestination, queued: Int = 0,
                 _ body: @MainActor (LibraryViewController, LibraryViewController, Fixture) async throws -> Void) async throws {
        let fixture = try await fixture(start: destination, queued: queued)
        weak var patchedScreen: LibraryViewController?, freshScreen: LibraryViewController?
        do {
            let patched = controller(fixture, full: false), fresh = controller(fixture, full: true)
            patchedScreen = patched; freshScreen = fresh
            try await withViewTestWindow { host, _ in
                for controller in [fresh, patched] {
                    host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                    controller.view.frame = host.view.bounds
                    controller.view.layoutIfNeeded()
                }
                defer { for controller in [patched, fresh] { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() } }
                for controller in [patched, fresh] { await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded() }
                try await body(patched, fresh, fixture)
            }
        } catch { await close(fixture); throw error }
        await close(fixture)
        try await wait("the screens are freed") { patchedScreen == nil && freshScreen == nil }
    }

    /// The episode control VoiceOver reads for row `id` (label and value), from the row on screen.
    func episodeControl(_ controller: LibraryViewController, _ id: Int64) -> String? {
        controller.view.layoutIfNeeded()
        guard let row = controller.episodeRows[id]?.1 else { return nil }
        return Self.spoken(row).first
    }

    func settle(_ controllers: LibraryViewController...) async {
        for controller in controllers { await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded() }
    }

    /// A queue change repaints the row's queue indicator and spoken value, on a list that does not depend on the queue.
    @Test func aQueueChangeRepaintsAnExistingRow() async throws {
        try await mounted(.episodes) { patched, fresh, fixture in
            let id = try #require(patched.episodeRows.keys.sorted().first { id in
                guard let episode = patched.libraryEpisode(id)?.episode else { return false }
                return episode.details.media != nil && episode.userState.playState != .new && !patched.mirror.queuedIDs.contains(id)
            })
            let before = try #require(episodeControl(patched, id))
            _ = try await fixture.store.enqueue([id])
            await settle(patched, fresh)
            let queued = try #require(episodeControl(patched, id))
            #expect(queued != before, "the row shows and speaks In queue")
            #expect(queued == episodeControl(fresh, id), "as a fresh open does")
            _ = try await fixture.store.removeFromQueue([id])
            await settle(patched, fresh)
            #expect(episodeControl(patched, id) == before, "and no longer after the dequeue")
            #expect(episodeControl(patched, id) == episodeControl(fresh, id))
        }
    }

    /// An action that completes before its patch: the model and library hold the commit, and the row on screen shows
    /// it.
    @Test func anActionBeforeItsPatchRepaintsItsRow() async throws {
        try await mounted(.episodes) { patched, fresh, fixture in
            let id = try #require(patched.episodeRows.keys.sorted().first { patched.libraryEpisode($0)?.episode.userState.playState == .new })
            let captured = try #require(patched.captureAction(id))
            let before = try #require(episodeControl(patched, id))
            // The action's write completes and is reconciled before the screen's patch of it.
            patched.screenUpdater?.beginOpen()
            try await fixture.store.removeEpisodeFromInbox(episodeID: id)
            let receipt = try #require(patched.library?.changes.emitted)
            patched.reconcileCommittedAction(captured, delta: .init(playState: .unplayed), receipt: receipt)
            patched.screenUpdater?.opened(at: nil)
            await settle(patched, fresh)
            #expect(patched.actionBindings[id]?.model.snapshot().episode.userState.playState == .unplayed)
            #expect(patched.mirror.episode(id)?.episode.userState.playState == .unplayed)
            #expect(episodeControl(patched, id) != before, "the row no longer speaks the Inbox indicator")
            #expect(episodeControl(patched, id) == episodeControl(fresh, id), "as a fresh open shows it")
        }
    }

    /// An action's late result, delivered after the screen shows a newer commit of the same episode, changes nothing:
    /// not the library the screens show, not the bound action model.
    @Test func aLateActionResultCannotOverwriteANewerShownState() async throws {
        try await mounted(.episodes) { patched, fresh, fixture in
            let id = try #require(patched.episodeRows.keys.sorted().first { patched.libraryEpisode($0)?.episode.userState.playState == .new })
            let captured = try #require(patched.captureAction(id))
            patched.screenUpdater?.beginOpen()
            try await fixture.store.removeEpisodeFromInbox(episodeID: id)                         // W1
            let receipt = try #require(patched.library?.changes.emitted)
            try await fixture.store.updateEpisode(id: id) { $0.userState.playState = .new }       // W2
            patched.screenUpdater?.opened(at: nil)
            await settle(patched, fresh)
            // W1's result arrives now.
            patched.reconcileCommittedAction(captured, delta: .init(playState: .unplayed), receipt: receipt)
            patched.view.layoutIfNeeded()
            #expect(patched.mirror.episode(id)?.episode.userState.playState == .new)
            #expect(patched.actionBindings[id]?.model.snapshot().episode.userState.playState == .new, "the bound model keeps the newer state")
            #expect(episodeControl(patched, id) == episodeControl(fresh, id))
        }
    }

    /// The same for swipes: a swipe's result that arrives after the screen shows a newer commit of the same episode
    /// changes nothing: not the bound model (which the swipe owner would change first), not the library. The row keeps
    /// offering Remove from Inbox, as a fresh open does.
    @Test func aDelayedSwipeCannotOverwriteANewerShownState() async throws {
        try await mounted(.episodes) { patched, fresh, fixture in
            let id = try #require(patched.episodeRows.keys.sorted().first {
                patched.libraryEpisode($0).map { $0.episode.userState.playState == .new && $0.episode.details.media != nil } == true
            })
            let captured = try #require(patched.captureAction(id))
            let gate = ResultGate()
            var persistence = EpisodeSwipeCoordinator.Persistence(store: fixture.store)
            let write = persistence.apply
            persistence.apply = { id, action in let written = try await write(id, action); await gate.wait(); return written }
            let coordinator = EpisodeSwipeCoordinator(persistence: persistence, downloads: fixture.downloads, clock: .continuous,
                                                      delete: { _ in .deleted })
            defer { coordinator.invalidateLibrary() }
            patched.connectInboxSwipe(coordinator)
            patched.screenUpdater?.beginOpen()
            let swipe = Task { await coordinator.perform(model: captured.model, action: .removeInbox, target: captured.deletionTarget, offersUndo: true) }
            try await wait("the swipe's mark is written") { gate.entered }                       // W1, its result held
            try await fixture.store.updateEpisode(id: id) { $0.userState.playState = .new }       // W2
            patched.screenUpdater?.opened(at: nil)
            await settle(patched, fresh)
            gate.release()
            _ = await swipe.value
            patched.view.layoutIfNeeded()
            #expect(patched.mirror.episode(id)?.episode.userState.playState == .new)
            let model = try #require(patched.actionBindings[id]?.model)
            #expect(model.snapshot().episode.userState.playState == .new, "the bound model keeps the newer state")
            #expect(EpisodeListMenu.actions([patched.contextItem(model)], selection: false).contains(.removeInbox))
            #expect(episodeControl(patched, id) == episodeControl(fresh, id))
        }
    }

    /// A favourite change, a queued episode's own position save and a refresh that changes nothing the rows show look
    /// only at the queue members those changes named, never at the whole queue: the same work with 10 and with 5,000 queued
    /// episodes.
    @Test func routinePatchesDoNotWalkTheQueue() async throws {
        var work: [Int: [Int]] = [:]
        for queued in [10, 5_000] {
            try await mounted(.episodes, queued: queued) { patched, fresh, fixture in
                let large = try #require(fixture.feeds.last)
                let favourite = try #require(patched.episodeRows.keys.sorted().first)
                let queuedEpisode = try #require(patched.mirror.queue.first { $0.id != favourite && patched.mirror.episode($0.id)?.feed.id == large })
                var counted: [Int] = []
                @MainActor func measure(_ change: () async throws -> Void) async throws {
                    let before = patched.queueMembershipChecks
                    try await change()
                    await settle(patched, fresh)
                    counted.append(patched.queueMembershipChecks - before)
                }
                try await measure { try await fixture.store.setFavorite(episodeIDs: [favourite], favorite: true) }
                try await measure { try await fixture.store.updateEpisode(id: queuedEpisode.id) { $0.userState.positionMilliseconds = 30_000 } }
                try await measure { _ = try await fixture.store.applyRefresh(Self.fetched(1, count: 120), feedID: fixture.feeds[1], options: .init(now: Self.now)) }
                #expect(patched.mirror.queuedIDs.count >= queued)
                work[queued] = counted
            }
        }
        #expect(work[10] == work[5_000], "the work does not grow with the queue")
        #expect(work[5_000] == [0, 0, 0], "none of these changes the queue's members")
    }

    /// A refresh that adds a newest episode and changes the podcast's artwork: the podcast's existing rows show the new
    /// artwork, on screen and when built again while scrolling.
    @Test func aRefreshAddingARowAlsoRepaintsTheOtherRowsOfItsPodcast() async throws {
        try await mounted(.episodes) { patched, fresh, fixture in
            let feedID = fixture.feeds[0]
            let id = try #require(patched.episodeRows.keys.sorted().first { patched.displayedEpisodeValues[$0]?.feed.id == feedID })
            let row = try #require(patched.episodeRows[id]?.1)
            var fetched = Self.fetched(0, count: 401)
            fetched.feed.imageURL = "https://media.example.test/new-artwork.png"
            _ = try await fixture.store.applyRefresh(fetched, feedID: feedID, options: .init(now: Self.now))
            await settle(patched, fresh)
            #expect(patched.mirror.feed(feedID)?.metadata.imageURL == "https://media.example.test/new-artwork.png")
            #expect(patched.displayedEpisodeValues[id]?.feed.metadata.imageURL == "https://media.example.test/new-artwork.png",
                    "a row built again later shows the new artwork")
            #expect(patched.episodeRows[id].map { $0.1 !== row } ?? true, "the row on screen was painted again")
            // Scrolled away and back: built from the kept value.
            patched.content.setContentOffset(CGPoint(x: 0, y: max(0, patched.content.contentSize.height - patched.content.bounds.height)), animated: false)
            patched.updateVisibleContent()
            patched.content.setContentOffset(.zero, animated: false)
            patched.updateVisibleContent()
            #expect(patched.displayedEpisodeValues[id]?.feed.metadata.imageURL == "https://media.example.test/new-artwork.png")
        }
    }

    /// The oracle fails when a queue change does not repaint rows or a row is repainted only when its model is replaced
    /// (the mutations `queueRepaintSkipped` and `paintedStateIgnored`).
    @Test func theOracleCatchesStaleRows() async {
        screenPatchFaults = [.queueRepaintSkipped]
        await withKnownIssue("a queue change that does not repaint is caught") { try await run(.episodes, rtl: false, steps: 40, seed: 0xD2A4) }
        screenPatchFaults = [.paintedStateIgnored]
        await withKnownIssue("a row repainted only with a new model is caught") { try await anActionBeforeItsPatchRepaintsItsRow() }
        screenPatchFaults = []
    }

    /// The pager opens over the list as it is at the time of the tap, not as it was when the row was built.
    @Test func aRowOpensThePagerOverTheCurrentList() async throws {
        let fixture = try await fixture(start: .inbox)
        let controller = controller(fixture, full: false)
        do { try await opensThePager(controller, fixture) } catch { await close(fixture); throw error }
        await close(fixture)
    }

    func opensThePager(_ controller: LibraryViewController, _ fixture: Fixture) async throws {
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            controller.view.frame = host.view.bounds
            controller.view.layoutIfNeeded()
            await controller.reloadLibrary()?.value
            controller.view.layoutIfNeeded()
            let ids = controller.displayedEpisodeIDs
            try #require(ids.count > 3)
            let tapped = ids[2], neighbour = ids[1]
            let row = try #require(controller.episodeRows[tapped]?.1)
            try await fixture.store.markEpisodePlayed(episodeID: neighbour, played: true)
            await controller.reloadLibrary()?.value
            #expect(controller.episodeRows[tapped]?.1 === row, "the unchanged row is not built again")
            let button = try #require(row.firstSubview { $0.accessibilityIdentifier == "episode-\(tapped)" } as? UIButton)
            let current = try #require(controller.listScreen?.allIDs)
            button.sendActions(for: .touchUpInside)
            let pager = try #require(controller.episodePagers.values.first)
            #expect(pager.model.items.map(\.episodeID) == current)
            #expect(!pager.model.items.contains { $0.episodeID == neighbour }, "the neighbour that left is not a page")
        }
    }
}

/// Holds a write's result until released.
@MainActor final class ResultGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

/// SplitMix64: one seed, one sequence.
struct ViewTestRandom {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ bound: Int) -> Int { bound <= 1 ? 0 : Int(next() % UInt64(bound)) }
    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
}

private extension UIView {
    func firstSubview(where predicate: (UIView) -> Bool) -> UIView? {
        if predicate(self) { return self }
        for subview in subviews { if let found = subview.firstSubview(where: predicate) { return found } }
        return nil
    }
}

extension FeedLibraryStore {
    /// The applied commit the next server unit follows.
    func setCursorForViewTests(_ cursor: SyncCursor) throws { try database.transaction { try setCursor(cursor, watermark: nil) } }
    /// The registration a subscription recorded.
    func registrationOpForViewTests(feedID: Int64) throws -> String? {
        try database.rows("SELECT op_id FROM ntp_registrations WHERE feed_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 1", [.integer(feedID)]).first?.first?.text
    }
    /// As if the server had acknowledged every pending fact: no overlay waits on the next units.
    func retireFactsForViewTests() throws {
        try database.transaction { try database.execute("DELETE FROM ntp_overlays"); try database.execute("DELETE FROM ntp_outbox") }
    }
}
