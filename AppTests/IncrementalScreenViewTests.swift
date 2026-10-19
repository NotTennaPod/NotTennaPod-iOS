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

/// Plays whatever position the test says it reached (the coordinator saves it every five seconds).
@MainActor private final class ScriptedEngine: PlaybackEngine {
    var reading: PlaybackEngineReading?
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    private var generation: UUID?, commandID: UUID?
    private var position: Int32 = 0, playing = false
    func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
        self.generation = generation; commandID = generation; position = Int32(positionMilliseconds); reading = nil
    }
    func play(commandID: UUID) { self.commandID = commandID; playing = true; reading?.commandID = commandID; reading?.sample.status = .playing }
    func pause(commandID: UUID) { self.commandID = commandID; playing = false; reading?.commandID = commandID; reading?.sample.status = .paused }
    func seek(to positionMilliseconds: Int64, commandID: UUID) { self.commandID = commandID; position = Int32(positionMilliseconds) }
    func setSpeed(_ speed: Float, commandID: UUID) throws { self.commandID = commandID }
    func unload() { reading = nil; generation = nil; commandID = nil }
    private func value(_ position: Int32) -> PlaybackEngineReading? {
        guard let generation, let commandID else { return nil }
        return PlaybackEngineReading(generation: generation, commandID: commandID,
            sample: .init(positionMilliseconds: position, durationMilliseconds: 1_800_000, status: playing ? .playing : .paused))
    }
    func ready() { guard let value = value(position) else { return }; reading = value; onEvent?(.ready(value)) }
    func moved(to position: Int32) {
        self.position = position
        guard let value = value(position) else { return }
        reading = value; onEvent?(.position(value))
    }
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

// MARK: - Rows and what lives on them, after patches

extension IncrementalScreenViewTests {
    /// The menu a long press presented on `controller`, if any.
    func presentedMenu(_ controller: LibraryViewController) -> PopupMenuController? {
        (controller.presentedViewController ?? controller.view.window?.rootViewController?.presentedViewController) as? PopupMenuController
    }

    func dismissMenu(_ controller: LibraryViewController) async throws {
        guard let menu = presentedMenu(controller) else { return }
        menu.dismiss(animated: false)
        try await wait("the menu is dismissed") { presentedMenu(controller) == nil }
    }

    /// A playback save (every five seconds while an episode plays) changes only the playing episode's position and
    /// listening times. Its row on the Queue stays the view on screen and shows the saved position, as Android's row
    /// does (`DBWriter.setFeedMediaPlaybackInformation` posts no list event): a row replaced every five seconds
    /// cancels a press or a long press on it and moves VoiceOver's focus.
    @Test func aPlaybackSaveKeepsThePlayingRowOnTheQueue() async throws {
        try await mounted(.queue) { patched, fresh, fixture in
            let id = try #require(patched.episodeList?.ids.first { id in
                patched.episodeRows[id] != nil && patched.libraryEpisode(id)?.episode.details.media != nil
            })
            let session = try await fixture.store.beginPlayback(episodeID: id)
            await settle(patched, fresh)
            let row = try #require(patched.episodeRows[id]?.1)
            let duration = try #require(patched.libraryEpisode(id)?.episode.details.media?.durationMilliseconds)
            _ = try await fixture.store.recordPlayback(sessionID: session.id,
                sample: PlaybackSample(positionMilliseconds: 12_000, durationMilliseconds: duration, status: .playing))
            await settle(patched, fresh)
            #expect(patched.mirror.episode(id)?.episode.userState.positionMilliseconds == 12_000, "the save reached the screen")
            #expect(patched.episodeRows[id]?.1 === row, "the playing row is the same view after a save")
            #expect(row.window != nil, "and stays on screen")
            #expect(episodeControl(patched, id) == episodeControl(fresh, id), "showing the saved position as a fresh open does")
        }
    }

    /// The same save on Home: the Continue listening strip (the playing episode's card) stays the strip on screen,
    /// so a horizontal scroll of it or a press on a card is not cut off every five seconds.
    @Test func aPlaybackSaveKeepsHomesContinueStrip() async throws {
        try await mounted(.home) { patched, fresh, fixture in
            @MainActor func strip() -> HomeStrip? { patched.content.firstSubview { $0.accessibilityIdentifier == "homeQueueStrip" } as? HomeStrip }
            let id = try #require((strip()?.itemViews.first as? HomeEpisodeCard)?.episodeID)
            let session = try await fixture.store.beginPlayback(episodeID: id)
            await settle(patched, fresh)
            let shown = try #require(strip())
            let duration = try #require(patched.libraryEpisode(id)?.episode.details.media?.durationMilliseconds)
            _ = try await fixture.store.recordPlayback(sessionID: session.id,
                sample: PlaybackSample(positionMilliseconds: 12_000, durationMilliseconds: duration, status: .playing))
            await settle(patched, fresh)
            #expect(patched.mirror.episode(id)?.episode.userState.positionMilliseconds == 12_000, "the save reached the screen")
            #expect(strip() === shown, "the Continue listening strip is the same view after a save")
            #expect(shown.window != nil, "and stays on screen")
        }
    }

    /// Home's Continue listening and Get surprised cards open the episode menu on a long press, as Android's
    /// `HorizontalItemListAdapter` cards do.
    @Test func aLongPressOnAHomeCardOpensTheEpisodeMenu() async throws {
        try await mounted(.home) { patched, fresh, fixture in
            let strip = try #require(patched.content.firstSubview { $0.accessibilityIdentifier == "homeQueueStrip" } as? HomeStrip)
            let card = try #require(strip.itemViews.compactMap { $0 as? HomeEpisodeCard }.first { patched.episodeRows[$0.episodeID] == nil })
            card.contextMenu?(card, CGPoint(x: 0.5, y: 0.5))
            try? await wait("the card's menu opens") { presentedMenu(patched) != nil }
            #expect(presentedMenu(patched) != nil, "a long press on a Continue listening card opens its menu")
            try await dismissMenu(patched)
        }
    }

    /// An episode shown in both Home's See what's new and Downloads sections (a new episode already downloaded) keeps
    /// its See what's new row working when it later leaves the Downloads section (newer downloads push it out): a long
    /// press on that row opens its menu, as it does after a fresh open of the same library.
    @Test func aHomeRowKeepsItsMenuWhenItsTwinLeavesAnotherSection() async throws {
        try await mounted(.home) { patched, fresh, fixture in
            @MainActor func section(_ controller: LibraryViewController, _ kind: HomeSection) -> HomeSectionState? { controller.homeSections.first { $0.section == kind } }
            let inbox = try #require(section(patched, .inbox)?.shown.rows.map(\.1))
            let twin = try #require(inbox.first)
            // The newest new episode is downloaded: it shows in both sections.
            try await fixture.store.updateEpisode(id: twin.id) { $0.userState.isDownloaded = true; $0.userState.downloadDate = Self.now }
            await settle(patched, fresh)
            try #require(section(patched, .downloads)?.shown.rows.contains { $0.1.id == twin.id } == true)
            // Two newer episodes that are not new are downloaded (one commit each): the Downloads section's two places go
            // to them, See what's new does not change.
            let date = try #require(twin.details.publicationDate)
            let others = patched.mirror.feeds.flatMap(\.episodes).filter {
                $0.userState.playState != .new && $0.details.media != nil && !$0.userState.isDownloaded
            }.prefix(2)
            try #require(others.count == 2)
            for (offset, other) in others.enumerated() {
                try await fixture.store.updateEpisode(id: other.id) {
                    $0.details.publicationDate = date.addingTimeInterval(Double(offset + 1) * 3_600)
                    $0.userState.isDownloaded = true; $0.userState.downloadDate = Self.now
                }
                await settle(patched, fresh)
            }
            try #require(section(patched, .downloads)?.shown.rows.contains { $0.1.id == twin.id } == false)
            try #require(section(patched, .inbox)?.shown.rows.map(\.1.id) == inbox.map(\.id))
            @MainActor func row(_ controller: LibraryViewController) -> EpisodeRowView? {
                section(controller, .inbox)?.views.compactMap { $0 as? EpisodeRowView }.first { $0.actionModel?.episodeID == twin.id }
            }
            // The reference: a fresh open of the same library opens the menu.
            let reference = try #require(row(fresh))
            reference.contextMenu?(reference, CGPoint(x: 0.5, y: 0.5))
            try await wait("a fresh open's row opens its menu") { presentedMenu(fresh) != nil }
            try await dismissMenu(fresh)
            let shown = try #require(row(patched))
            shown.contextMenu?(shown, CGPoint(x: 0.5, y: 0.5))
            try? await wait("the patched row opens its menu") { presentedMenu(patched) != nil }
            #expect(presentedMenu(patched) != nil, "a long press on the See what's new row opens its menu after the Downloads section changed")
            try await dismissMenu(patched)
        }
    }

    /// Android's Queue empty state (`QueueFragment.loadItems`): its icon, and when the Inbox has new episodes, the message
    /// that new episodes await and a Go to inbox button.
    @Test func anEmptyQueueWithNewEpisodesOffersTheInbox() async throws {
        try await mounted(.queue) { patched, fresh, fixture in
            _ = try await fixture.store.clearQueue()
            await settle(patched, fresh)
            try #require(patched.mirror.queue.isEmpty && patched.mirror.inboxCount > 0)
            let texts = patched.content.subviews.compactMap { ($0 as? UILabel)?.text }
            #expect(texts.contains("No queued episodes"))
            #expect(texts.contains("No episodes lined up, but there are new episodes that await you!"), "\(texts)")
            let button = patched.content.firstSubview { ($0 as? UIButton)?.title(for: .normal) == "Go to inbox" || ($0 as? UIButton)?.configuration?.title == "Go to inbox" }
            #expect(button != nil, "a Go to inbox button")
            #expect(patched.content.subviews.contains { $0 is UIImageView }, "the empty state's icon")
        }
    }

    /// The empty Queue follows the Inbox: its invitation goes when the Inbox empties and comes back with a new episode.
    @Test func theEmptyQueueFollowsTheInbox() async throws {
        try await mounted(.queue) { patched, fresh, fixture in
            @MainActor func texts(_ controller: LibraryViewController) -> [String] {
                controller.content.subviews.compactMap { ($0 as? UILabel)?.text }
            }
            @MainActor func offersInbox(_ controller: LibraryViewController) -> Bool {
                controller.content.firstSubview { $0.accessibilityIdentifier == "queueEmptyButton" } != nil
            }
            _ = try await fixture.store.clearQueue()
            await settle(patched, fresh)
            try #require(offersInbox(patched))
            // Icon, title, message and button, top to bottom, each whole within the screen and none over another.
            let icon = UIImage(named: "ic_playlist_play")
            let parts = patched.content.subviews.filter {
                ($0 as? UIImageView)?.image == icon || ["queueEmptyTitle", "queueEmptyMessage", "queueEmptyButton"].contains($0.accessibilityIdentifier)
            }.map(\.frame).sorted { $0.minY < $1.minY }
            #expect(parts.count == 4)
            #expect(parts.allSatisfy { patched.content.bounds.contains($0) && $0.width > 0 && $0.height > 0 }, "\(parts)")
            #expect(zip(parts, parts.dropFirst()).allSatisfy { $0.maxY <= $1.minY + 0.5 }, "\(parts)")
            let new = try await fixture.store.removeAllFromInbox()
            await settle(patched, fresh)
            #expect(!offersInbox(patched), "no invitation without new episodes")
            #expect(texts(patched) == texts(fresh) && texts(patched).contains(Appearance.text("no_items_label")))
            let id = try #require(new.first)
            try await fixture.store.updateEpisode(id: id) { $0.userState.playState = .new }
            await settle(patched, fresh)
            #expect(offersInbox(patched), "the invitation is back with a new episode")
            #expect(texts(patched) == texts(fresh))
            let button = try #require(patched.content.firstSubview { $0.accessibilityIdentifier == "queueEmptyButton" } as? UIButton)
            button.sendActions(for: .primaryActionTriggered)
            try await wait("Go to inbox opens the Inbox") { if case .destination(.inbox) = patched.path.last { true } else { false } }
        }
    }

    /// The selection toolbar (close, "N/M selected", more) stays the same while a download runs: the 1 Hz progress
    /// updates rows' buttons only, so a tap on the toolbar is not cut off and VoiceOver's focus stays.
    @Test func downloadProgressKeepsTheSelectionToolbar() async throws {
        try await mounted(.inbox) { patched, fresh, fixture in
            let id = try #require(patched.episodeList?.ids.first { patched.episodeRows[$0] != nil })
            patched.startFeedSelection(id)
            let bar = try #require(patched.toolbar.subviews.first { $0.accessibilityIdentifier == "feedSelectionToolbar" })
            // What each download progress report does on a list screen.
            patched.updateDownloadRows()
            #expect(patched.toolbar.subviews.first { $0.accessibilityIdentifier == "feedSelectionToolbar" } === bar,
                    "the selection toolbar is the same view after a progress update")
            #expect(bar.window != nil)
            patched.endFeedSelection()
        }
    }

    /// Locking the queue hides the drag handles, which widens every row's text: each row on screen takes the height its
    /// title now needs (no gap under a title that now fits one line, no title running into the next row), as Android's
    /// rows do when the lock rebinds them (`updateDragDropEnabled`).
    @Test func lockingTheQueueFitsEveryRowToItsTitle() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("QueueLockRows-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try FeedLibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        // Titles one character longer each: around the width where a title wraps, a 12-point change of the text width
        // moves some of them between one and two lines.
        let sentence = "An episode title that goes on with several more words until it needs a second line to finish"
        let titles = (30...45).map { String(sentence.prefix($0)) }
        do {
            let source = "https://example.test/queue-lock.xml"
            _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Queue lock", episodes: titles.enumerated().map { index, title in
                ParsedEpisode(identifier: "\(source)#\(index)", title: title, publicationDate: Self.now.addingTimeInterval(Double(index) * 60),
                              media: ParsedMedia(url: "https://media.example.test/lock/\(index).mp3", size: 1_000, durationMilliseconds: 120_000))
            }), source: source, responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil), options: .init(now: Self.now))
            _ = try await store.enqueue(try await store.feeds().flatMap(\.episodes).map(\.id))
            let navigation = try NavigationPreferenceStore(file: folder.appendingPathComponent("navigation.json"))
            var value = navigation.value; value.defaultPage = NavigationDestination.queue.rawValue; try navigation.update(value)
            let preferences = try QueueInteractionPreferenceStore(file: folder.appendingPathComponent("queue.json"))
            try preferences.update(.init(locked: false, showLockWarning: false))
            let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
                timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil,
                mobileNetworkPreferences: nil, usage: nil, queueInteractionPreferences: preferences)
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                controller.view.frame = host.view.bounds
                defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
                // On this screen's width (iPhone, iPad, Duo), the titles that wrap differently with and without the
                // handle: every queued episode takes one of them.
                let metrics = EpisodeRowMetrics(queueTraits: controller.traitCollection, scale: controller.view.window?.screen.scale ?? 3)
                let width = controller.content.bounds.width
                @MainActor func crosses(_ title: String) -> Bool {
                    metrics.height(title: title, progressLine: true, width: width, draggable: true, showAction: true)
                        != metrics.height(title: title, progressLine: true, width: width, draggable: false, showAction: true)
                }
                let long = String(repeating: sentence + " ", count: 4)
                let wrapping = (20...long.count).map { String(long.prefix($0)) }.filter(crosses)
                try #require(!wrapping.isEmpty, "some title wraps differently with the handle")
                for (index, id) in try await store.queue().map(\.id).enumerated() {
                    try await store.updateEpisode(id: id) { $0.details.title = wrapping[index % wrapping.count] }
                }
                await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
                @MainActor func misfits() -> [Int64] {
                    controller.view.layoutIfNeeded()
                    guard let list = controller.episodeList else { return [-1] }
                    return list.ids.filter { id in
                        guard let row = list.views[id] else { return false }
                        return abs(row.frame.height - row.sizeThatFits(CGSize(width: row.bounds.width, height: .greatestFiniteMagnitude)).height) > 0.5
                    }
                }
                // The rows on screen include one whose title wraps differently with and without the handle.
                let crossing = (controller.episodeList?.views.keys.map { $0 } ?? []).filter { id in
                    crosses(controller.libraryEpisode(id)?.episode.details.title ?? "")
                }
                try #require(!crossing.isEmpty, "a row on screen changes height with the handle")
                try #require(misfits().isEmpty, "unlocked, every row fits its title")
                controller.toggleQueueLock()
                try #require(preferences.value.locked)
                #expect(misfits().isEmpty, "locked, every row fits its title")
                controller.toggleQueueLock()
                try #require(!preferences.value.locked)
                #expect(misfits().isEmpty, "unlocked again, every row fits its title")
            }
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

    /// Move to bottom from a Queue row's menu moves that episode although sync added another episode to the queue while
    /// the menu was open, as Android's `DBWriter.moveQueueItemToBottom` does.
    @Test func moveToBottomFromAMenuOpenedBeforeASyncChangeMoves() async throws {
        try await mounted(.queue) { patched, fresh, fixture in
            let ids = try #require(patched.episodeList?.ids)
            let id = try #require(ids.dropLast().first { patched.episodeRows[$0] != nil })
            let row = try #require(patched.episodeRows[id]?.1)
            row.contextMenu?(row, CGPoint(x: 0.5, y: 0.5))
            try await wait("the menu opens") { presentedMenu(patched) != nil }
            // Meanwhile another device adds an episode to the queue.
            let queued = Set(try await fixture.store.queue().map(\.id))
            let joining = try #require(patched.mirror.feeds.flatMap(\.episodes).first { !queued.contains($0.id) && $0.details.media != nil })
            _ = try await fixture.store.enqueue([joining.id], location: .back)
            await settle(patched, fresh)
            let menu = try #require(presentedMenu(patched))
            menu.view.layoutIfNeeded()
            let bottom = try #require(menu.view.firstSubview { $0.accessibilityIdentifier == "queue-bottom" } as? UIButton)
            bottom.sendActions(for: .touchUpInside)
            try await wait("the menu closes") { presentedMenu(patched) == nil }
            var last: Int64?
            let deadline = ContinuousClock.now + .seconds(5)
            while last != id, ContinuousClock.now < deadline {
                last = try await fixture.store.queue().last?.id
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(last == id, "the episode moved to the bottom of the queue")
        }
    }

    /// Move to bottom from a Queue row's menu also moves the episode when the queue changed in storage and the screen
    /// has not shown it yet: it moves by id in the stored queue, as `DBWriter` does.
    @Test func moveToBottomMovesInTheStoredQueueBeforeTheScreenShowsIt() async throws {
        try await mounted(.queue) { patched, fresh, fixture in
            let ids = try #require(patched.episodeList?.ids)
            let id = try #require(ids.dropLast().first { patched.episodeRows[$0] != nil })
            let row = try #require(patched.episodeRows[id]?.1)
            row.contextMenu?(row, CGPoint(x: 0.5, y: 0.5))
            try await wait("the menu opens") { presentedMenu(patched) != nil }
            let queued = Set(try await fixture.store.queue().map(\.id))
            let joining = try #require(patched.mirror.feeds.flatMap(\.episodes).first { !queued.contains($0.id) && $0.details.media != nil })
            // The screen does not show the joining episode yet.
            patched.screenUpdater?.beginOpen()
            _ = try await fixture.store.enqueue([joining.id], location: .back)
            let menu = try #require(presentedMenu(patched))
            menu.view.layoutIfNeeded()
            let bottom = try #require(menu.view.firstSubview { $0.accessibilityIdentifier == "queue-bottom" } as? UIButton)
            bottom.sendActions(for: .touchUpInside)
            try await wait("the menu closes") { presentedMenu(patched) == nil }
            var last: Int64?
            let deadline = ContinuousClock.now + .seconds(5)
            while last != id, ContinuousClock.now < deadline {
                last = try await fixture.store.queue().last?.id
                try await Task.sleep(for: .milliseconds(20))
            }
            patched.screenUpdater?.opened(at: nil)
            #expect(last == id, "the episode moved to the bottom of the stored queue")
            await settle(patched, fresh)
            #expect(patched.episodeList?.ids == fresh.episodeList?.ids, "and the screen shows the stored queue")
        }
    }

    // MARK: - Playback shown in place

    /// A queued episode with media, not new and not started, whose row is built on the patched screen.
    func unstartedQueuedRow(_ patched: LibraryViewController) throws -> Int64 {
        try #require(patched.episodeList?.ids.first { id in
            guard patched.episodeRows[id] != nil, let episode = patched.libraryEpisode(id)?.episode else { return false }
            return episode.details.media != nil && episode.userState.playState == .unplayed && episode.userState.positionMilliseconds == 0
        })
    }

    /// The player's save of `position` (and the duration it knows) for the open session, shown on both screens.
    func save(_ position: Int32, duration: Int32, session: LibraryPlaybackSession, _ fixture: Fixture,
              _ patched: LibraryViewController, _ fresh: LibraryViewController) async throws {
        _ = try await fixture.store.recordPlayback(sessionID: session.id,
            sample: PlaybackSample(positionMilliseconds: position, durationMilliseconds: duration, status: .playing))
        await settle(patched, fresh)
    }

    /// The row of `id` as a person sees it on the two screens: the same place and height, and what VoiceOver reads.
    func expectRowAsFresh(_ patched: LibraryViewController, _ fresh: LibraryViewController, _ id: Int64, _ comment: Comment) {
        #expect(episodeControl(patched, id) == episodeControl(fresh, id), comment)
        #expect(patched.episodeList?.frame(of: id) == fresh.episodeList?.frame(of: id), comment)
        if let row = patched.episodeRows[id]?.1 {
            #expect(abs(row.frame.height - row.sizeThatFits(CGSize(width: row.bounds.width, height: .greatestFiniteMagnitude)).height) < 0.5, comment)
        }
    }

    /// The player learns the duration of an episode whose feed gave none: its row keeps its view and shows the progress
    /// line it now has (taller), as a fresh open of the same library.
    @Test func aSaveThatLearnsTheDurationShowsItInPlace() async throws {
        try await mounted(.queue) { patched, fresh, fixture in
            let id = try unstartedQueuedRow(patched)
            // A title on two lines, so the progress line makes the row taller than its cover.
            let title = String(repeating: "An episode title that goes on with several more words until it needs a second line. ", count: 2)
            try await fixture.store.updateEpisode(id: id) { $0.details.title = title; $0.details.media?.durationMilliseconds = 0 }
            let session = try await fixture.store.beginPlayback(episodeID: id)
            await settle(patched, fresh)
            let row = try #require(patched.episodeRows[id]?.1)
            let height = row.frame.height
            try await save(12_000, duration: 90_000, session: session, fixture, patched, fresh)
            try #require(patched.mirror.episode(id)?.episode.details.media?.durationMilliseconds == 90_000, "the save reached the screen")
            #expect(patched.episodeRows[id]?.1 === row, "the row is the same view")
            #expect(row.frame.height > height, "with its progress line")
            expectRowAsFresh(patched, fresh, id, "showing the position and duration as a fresh open does")
        }
    }

    /// A save back at the start (a reset to zero) takes the row's position and progress away in place.
    @Test func aSaveBackAtTheStartShowsItInPlace() async throws {
        try await mounted(.queue) { patched, fresh, fixture in
            let id = try unstartedQueuedRow(patched)
            let duration = try #require(patched.libraryEpisode(id)?.episode.details.media?.durationMilliseconds)
            let session = try await fixture.store.beginPlayback(episodeID: id)
            await settle(patched, fresh)
            let row = try #require(patched.episodeRows[id]?.1)
            try await save(12_000, duration: duration, session: session, fixture, patched, fresh)
            #expect(patched.episodeRows[id]?.1 === row, "the row is the same view")
            expectRowAsFresh(patched, fresh, id, "showing the position from zero")
            try await save(0, duration: duration, session: session, fixture, patched, fresh)
            try #require(patched.mirror.episode(id)?.episode.userState.positionMilliseconds == 0, "the reset reached the screen")
            #expect(patched.episodeRows[id]?.1 === row, "the row is the same view")
            expectRowAsFresh(patched, fresh, id, "showing no position after the reset")
        }
    }

    /// Anything else a row shows is not a position: an episode marked played with the position is painted again.
    @Test func aPlayedChangeWithThePositionStillPaintsTheRowAgain() async throws {
        try await mounted(.queue) { patched, fresh, fixture in
            let id = try unstartedQueuedRow(patched)
            let duration = try #require(patched.libraryEpisode(id)?.episode.details.media?.durationMilliseconds)
            let session = try await fixture.store.beginPlayback(episodeID: id)
            await settle(patched, fresh)
            try await save(12_000, duration: duration, session: session, fixture, patched, fresh)
            let row = try #require(patched.episodeRows[id]?.1)
            try await fixture.store.updateEpisode(id: id) { $0.userState.playState = .played; $0.userState.positionMilliseconds = 30_000 }
            await settle(patched, fresh)
            #expect(patched.episodeRows[id]?.1 !== row, "the row is painted again")
            expectRowAsFresh(patched, fresh, id, "showing it played, as a fresh open does")
        }
    }

    /// The same save on Home: the Continue listening card shows the saved progress in place, as a fresh open draws it.
    @Test func aPlaybackSaveShowsItsProgressOnHomesCard() async throws {
        try await mounted(.home) { patched, fresh, fixture in
            @MainActor func card(_ controller: LibraryViewController, _ id: Int64) -> HomeEpisodeCard? {
                controller.homeCards.first { $0.1.episodeID == id && $0.1.window != nil }?.1
            }
            let strip = try #require(patched.content.firstSubview { $0.accessibilityIdentifier == "homeQueueStrip" } as? HomeStrip)
            let id = try #require((strip.itemViews.first as? HomeEpisodeCard)?.episodeID)
            let session = try await fixture.store.beginPlayback(episodeID: id)
            await settle(patched, fresh)
            let shown = try #require(card(patched, id))
            let before = shown.progress
            let duration = try #require(patched.libraryEpisode(id)?.episode.details.media?.durationMilliseconds)
            try await save(duration / 2, duration: duration, session: session, fixture, patched, fresh)
            #expect(card(patched, id) === shown, "the card is the same view")
            #expect(shown.progress != before, "showing the new progress")
            #expect(shown.progress == card(fresh, id)?.progress, "as a fresh open does")
        }
    }

    /// An episode with a row in both See what's new and Downloads: a playback save reaches both rows in place.
    @Test func aPlaybackSaveReachesBothHomeRowsOfAnEpisode() async throws {
        try await mounted(.home) { patched, fresh, fixture in
            @MainActor func rows(_ controller: LibraryViewController, _ id: Int64) -> [EpisodeRowView] {
                controller.homeSections.filter { [.inbox, .downloads].contains($0.section) }.flatMap(\.views)
                    .compactMap { $0 as? EpisodeRowView }.filter { $0.actionModel?.episodeID == id }
            }
            let twin = try #require(patched.homeSections.first { $0.section == .inbox }?.shown.rows.first?.1)
            try await fixture.store.updateEpisode(id: twin.id) { $0.userState.isDownloaded = true; $0.userState.downloadDate = Self.now }
            await settle(patched, fresh)
            let both = rows(patched, twin.id)
            try #require(both.count == 2, "the episode has a row in each section")
            // What a save writes: the position and the listening times.
            try await fixture.store.updateEpisode(id: twin.id) {
                $0.userState.positionMilliseconds = 12_000; $0.userState.lastPlayedTimeMilliseconds = 1_760_000_000_000
            }
            await settle(patched, fresh)
            try #require(patched.mirror.episode(twin.id)?.episode.userState.positionMilliseconds == 12_000)
            #expect(rows(patched, twin.id).map(ObjectIdentifier.init) == both.map(ObjectIdentifier.init), "both rows are the same views")
            #expect(rows(patched, twin.id).map { Self.spoken($0) } == rows(fresh, twin.id).map { Self.spoken($0) },
                    "each shows the saved position, as a fresh open does")
        }
    }

    /// While an episode plays, its row on the Queue shows the playing background (Android's activated row) and its
    /// Continue listening card on Home the playing card's background and the live progress (`HorizontalItemViewHolder`
    /// on `PlaybackPositionEvent`); both go when it pauses. Only the playing episode's row and card are highlighted.
    @Test func thePlayingEpisodesRowAndCardFollowPlayback() async throws {
        try await withPlayingScreen { controller, playback, engine, _ in
            let id = try #require(controller.episodeList?.ids.first { id in
                controller.episodeRows[id] != nil && controller.libraryEpisode(id)?.episode.details.media != nil
            })
            @MainActor func highlighted() -> [Int64] {
                controller.episodeRows.filter { $0.value.1.showsPlayingBackground }.map(\.key)
            }
            try #require(highlighted().isEmpty)
            try await playback.select(episodeID: id, play: true)
            engine.ready()
            try await wait("it plays") { playback.phase == .playing }
            try await wait("the playing row shows its background") { highlighted() == [id] }
            try await playback.pause()
            try await wait("paused, no row is highlighted") { highlighted().isEmpty }
            controller.select(.home); controller.view.layoutIfNeeded()
            @MainActor func card() -> HomeEpisodeCard? { controller.homeCards.first { $0.1.episodeID == id && $0.1.window != nil }?.1 }
            let shown = try #require(card(), "the episode has a Continue listening card")
            #expect(!shown.playing)
            try await playback.select(episodeID: id, play: true)
            engine.moved(to: 900_000)
            try await wait("the card shows the playing background") { shown.playing }
            try await wait("and the live progress") { abs((shown.progress ?? 0) - 0.5) < 0.01 }
            #expect(controller.homeCards.filter { $0.1.playing }.map(\.1) == [shown], "only the playing episode's card")
            try await playback.pause()
            try await wait("paused, the card is not highlighted") { !shown.playing }
        }
    }

    /// The Queue on a screen that follows a player of scripted positions (the coordinator saves every five seconds).
    private func withPlayingScreen(_ body: @MainActor (LibraryViewController, PlaybackCoordinator, ScriptedEngine, Fixture) async throws -> Void) async throws {
        let fixture = try await fixture(start: .queue)
        let engine = ScriptedEngine()
        let playback = PlaybackCoordinator(store: fixture.store, engine: engine)
        weak var screen: LibraryViewController?
        do {
            let controller = LibraryViewController(library: fixture.store, startupError: nil, downloads: fixture.downloads, playback: playback,
                timeDisplayPreferences: try TimeDisplayPreferenceStore(file: fixture.folder.appendingPathComponent("time.json")),
                navigationPreferences: fixture.navigation, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
            screen = controller
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                controller.view.frame = host.view.bounds
                defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
                try await body(controller, playback, engine, fixture)
            }
        } catch { try? await playback.stop(); await close(fixture); throw error }
        try? await playback.stop()
        await close(fixture)
        try await wait("the screen is freed") { screen == nil }
    }

    /// An action the model holds before its patch, with the player's live position ahead of the stored one (a Played
    /// swipe between two saves): the commit then differs from the model only in the position, but the row was painted
    /// unplayed. It is painted again: dimmed and spoken as played, as a fresh row is.
    @Test func aPlayedActionBeforeItsPatchDimsTheRowWhileTheLivePositionIsUnsaved() async throws {
        try await withPlayingScreen { controller, playback, engine, fixture in
            let id = try unstartedQueuedRow(controller)
            try await playback.select(episodeID: id, play: true)
            engine.ready()
            try await wait("it plays") { playback.phase == .playing }
            engine.moved(to: 20_000)
            try await wait("the row shows the live position") {
                controller.actionBindings[id]?.model.snapshot().episode.userState.positionMilliseconds == 20_000
            }
            await controller.settleLibraryChanges(); controller.view.layoutIfNeeded()
            try #require(try await fixture.store.episode(id: id)?.userState.positionMilliseconds != 20_000, "the live position is not saved")
            let row = try #require(controller.episodeRows[id]?.1)
            try #require(row.alpha == 1)
            let captured = try #require(controller.captureAction(id))
            // The action's write completes and is reconciled before the screen's patch of it.
            controller.screenUpdater?.beginOpen()
            try await fixture.store.updateEpisode(id: id, scope: .userState) { $0.userState.playState = .played }
            let receipt = try #require(controller.library?.changes.emitted)
            controller.reconcileCommittedAction(captured, delta: .init(playState: .played), receipt: receipt)
            controller.screenUpdater?.opened(at: nil)
            await controller.settleLibraryChanges(); controller.view.layoutIfNeeded()
            let shown = try #require(controller.episodeRows[id]?.1)
            #expect(shown.alpha == 0.5, "the played row is dimmed")
            #expect(Self.spoken(shown).first?.contains(Appearance.text("is_played")) == true, "and spoken as played")
            #expect(!controller.rowIsStale(id), "and its paint record says what it shows")
            try await playback.pause()
        }
    }

    /// A Home row whose saved duration brings its progress line (a two-line title, the duration learned by the player)
    /// keeps its view, takes its new height, and what follows moves, as a fresh open places them.
    @Test func homeKeepsARowThatALearnedDurationMakesTaller() async throws {
        try await mounted(.home) { patched, fresh, fixture in
            @MainActor func row(_ controller: LibraryViewController, _ id: Int64) -> EpisodeRowView? {
                controller.homeSections.first { $0.section == .downloads }?.views.compactMap { $0 as? EpisodeRowView }
                    .first { $0.actionModel?.episodeID == id }
            }
            let id = try #require(patched.mirror.feeds.flatMap(\.episodes).first {
                $0.details.media != nil && $0.userState.playState == .unplayed && $0.userState.positionMilliseconds == 0
            }?.id)
            let title = String(repeating: "An episode title that goes on with several more words until it needs a second line. ", count: 2)
            try await fixture.store.updateEpisode(id: id) {
                $0.details.title = title; $0.details.media?.durationMilliseconds = 0
                $0.userState.isDownloaded = true; $0.userState.downloadDate = Self.now
            }
            let session = try await fixture.store.beginPlayback(episodeID: id)
            await settle(patched, fresh)
            let shown = try #require(row(patched, id), "the episode has a Downloads row")
            let height = shown.frame.height
            try await save(12_000, duration: 90_000, session: session, fixture, patched, fresh)
            try #require(patched.mirror.episode(id)?.episode.details.media?.durationMilliseconds == 90_000, "the save reached the screen")
            #expect(row(patched, id) === shown && shown.window != nil, "the row is the same view")
            #expect(shown.frame.height > height, "taller with its progress line")
            #expect(shown.frame == row(fresh, id)?.frame, "placed as a fresh open places it")
            #expect(Self.spoken(shown) == row(fresh, id).map { Self.spoken($0) }, "showing what a fresh open shows")
            #expect(patched.homeSections.map(\.top) == fresh.homeSections.map(\.top), "the sections below move")
            #expect(patched.homeSections.map(\.height) == fresh.homeSections.map(\.height))
            #expect(patched.content.contentSize.height == fresh.content.contentSize.height)
        }
    }
}
