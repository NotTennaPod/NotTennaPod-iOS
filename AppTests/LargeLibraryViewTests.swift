import QuartzCore
import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// With a realistically large library restored from an Android backup (500
/// podcasts, 50,000 episodes; `LargeAndroidLibrary`), every main list opens in under a second on the
/// Simulator and shows the right episodes in Android's order. Long lists show Android's pages of 150
/// episodes (`EpisodesListFragment.EPISODES_PER_PAGE`) and add the next page as the end comes into view.
/// Before paging, the Episodes list built a row for every episode and took five minutes to open.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)))
struct LargeLibraryViewTests {
    struct Fixture { let root: URL; let summary: LargeAndroidLibrary.Summary; let store: FeedLibraryStore }

    private func withLibrary(_ body: @MainActor (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GapRobustView-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backup = root.appendingPathComponent("Antennapod.db")
        let summary = try LargeAndroidLibrary.write(to: backup)
        let restored = try AndroidDatabaseRestore.read(backup, staging: root.appendingPathComponent("staging"))
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        try await store.installRestoredLibrary(restored, carrying: try await store.restoreCarryOver())
        do { try await body(Fixture(root: root, summary: summary, store: store)) }
        catch { try? await store.close(); throw error }
        try await store.close()
    }

    private func withController(_ fixture: Fixture, start: NavigationDestination,
                                _ body: @MainActor (LibraryViewController, Duration) async throws -> Void) async throws {
        let navigation = try NavigationPreferenceStore(file: fixture.root.appendingPathComponent("navigation-\(UUID()).json"))
        var value = navigation.value; value.defaultPage = start.rawValue; try navigation.update(value)
        let controller = LibraryViewController(library: fixture.store, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
        controller.episodeListPreferences = try EpisodeListPreferenceStore(file: fixture.root.appendingPathComponent("lists-\(UUID()).json"))
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            controller.view.frame = host.view.bounds
            let begin = ContinuousClock.now
            await controller.reloadLibrary()?.value
            controller.view.layoutIfNeeded(); CATransaction.flush()
            try await body(controller, ContinuousClock.now - begin)
        }
    }

    /// Episode ids of the list's rows, top to bottom (rows are built as they come near the screen).
    private func rows(_ controller: LibraryViewController) -> [Int64] { controller.displayedEpisodeIDs }

    /// What a person sees of a long list: every row (or Subscriptions tile) on screen is there, where the list
    /// places it, in list order for VoiceOver; rows far from the screen are not built (Android's RecyclerView).
    private func expectOnlyNearbyContentBuilt(_ list: LazyContentList?, in controller: LibraryViewController,
                                              sourceLocation: SourceLocation = #_sourceLocation) {
        guard let list else { Issue.record("no long list on screen", sourceLocation: sourceLocation); return }
        let content = controller.content
        let onScreen = list.indices(from: content.bounds.minY, to: content.bounds.maxY)
        #expect(!onScreen.isEmpty, sourceLocation: sourceLocation)
        for index in onScreen {
            let view = list.views[list.ids[index]], frame = list.frames[index]
            #expect(view?.superview === content && view.map { abs($0.frame.minY - frame.minY) < 0.5 && abs($0.frame.minX - frame.minX) < 0.5 } == true,
                    "item \(index) on screen is shown: \(String(describing: view?.frame)) vs \(frame)", sourceLocation: sourceLocation)
        }
        let far = content.bounds.insetBy(dx: 0, dy: -3 * content.bounds.height)
        #expect(list.views.keys.allSatisfy { id in list.frame(of: id).map { $0.intersects(far) } == true },
                "only rows near the screen exist", sourceLocation: sourceLocation)
        #expect(list.views.count < 120, "\(list.views.count) built", sourceLocation: sourceLocation)
        let order = content.subviews.compactMap { view in list.views.first { $0.value === view }?.key }
        #expect(order == list.ids.filter { list.views[$0] != nil }, "VoiceOver reads them in list order", sourceLocation: sourceLocation)
    }

    /// The fastest of two openings (the shared Simulator host can stall one), drawn and committed.
    private func open(_ destination: NavigationDestination, in controller: LibraryViewController) -> Duration {
        var fastest = Duration.seconds(3600)
        for _ in 0..<2 {
            controller.select(destination == .home ? .downloads : .home)
            controller.view.layoutIfNeeded(); CATransaction.flush()
            let start = ContinuousClock.now
            controller.select(destination)
            controller.view.layoutIfNeeded(); CATransaction.flush()
            fastest = min(fastest, ContinuousClock.now - start)
        }
        return fastest
    }

    @Test func mainListsOpenWithinASecondInAndroidsOrder() async throws {
        try await withLibrary { fixture in
            try await withController(fixture, start: .subscriptions) { controller, launch in
                // The whole library is read and the first screen drawn at launch.
                #expect(launch < .seconds(3), "library load and first screen took \(launch)")
                print("GAP-ROBUST timing: launch \(launch)")
                let summary = fixture.summary
                for destination in [NavigationDestination.inbox, .episodes, .favorites, .history, .queue, .downloads, .home, .subscriptions] {
                    let time = open(destination, in: controller)
                    #expect(time < .seconds(1), "\(destination.rawValue) took \(time)")
                    print("GAP-ROBUST timing: open \(destination.rawValue) \(time)")
                    switch destination {
                    case .subscriptions:
                        expectOnlyNearbyContentBuilt(controller.subscriptionGrid, in: controller)
                    case .inbox, .episodes, .history, .queue:
                        expectOnlyNearbyContentBuilt(controller.episodeList, in: controller)
                    default: break
                    }
                    switch destination {
                    case .inbox:
                        #expect(rows(controller) == Array(summary.inboxOrder.prefix(LibraryViewController.episodesPerPage)))
                        #expect(controller.feedSelectionIDs == summary.inboxOrder, "the whole Inbox is the list's content")
                    case .history:
                        #expect(rows(controller) == Array(summary.historyOrder.prefix(LibraryViewController.episodesPerPage)))
                    case .queue:
                        #expect(rows(controller) == summary.queue, "the queue shows every episode, as Android's does")
                    case .episodes:
                        // Episodes lists the subscribed podcasts' episodes (archived and previewed podcasts' are not).
                        let subscribed = summary.episodes.filter { summary.subscribedFeedIDs.contains($0.feed) }.count
                        #expect(rows(controller).count == LibraryViewController.episodesPerPage && controller.feedSelectionIDs.count == subscribed)
                    case .favorites:
                        #expect(Set(controller.feedSelectionIDs) == summary.favorites)
                    default: break
                    }
                }
                // A podcast with 1,500 episodes.
                var fastest = Duration.seconds(3600)
                for _ in 0..<2 {
                    controller.select(.home); controller.view.layoutIfNeeded()
                    let start = ContinuousClock.now
                    controller.drawerAction(.feed(summary.largestFeedID)); controller.view.layoutIfNeeded(); CATransaction.flush()
                    fastest = min(fastest, ContinuousClock.now - start)
                }
                #expect(fastest < .seconds(1), "podcast with 1,500 episodes took \(fastest)")
                print("GAP-ROBUST timing: open podcast of 1,500 episodes \(fastest)")
                let newest = summary.episodes.filter { $0.feed == summary.largestFeedID }
                    .sorted { $0.pubDate == $1.pubDate ? $0.id < $1.id : $0.pubDate > $1.pubDate }.map(\.id)
                #expect(rows(controller) == Array(newest.prefix(LibraryViewController.episodesPerPage)))
            }
        }
    }

    /// Scrolling to the end of the 150 shown adds the next 150 in the same order, quickly; selecting all
    /// covers the whole list (Android's lazily loaded selection) and stays responsive.
    @Test func longListsAddPagesAsTheyScrollAndSelectEverything() async throws {
        try await withLibrary { fixture in
            try await withController(fixture, start: .episodes) { controller, _ in
                let all = controller.feedSelectionIDs
                let subscribed = fixture.summary.episodes.filter { fixture.summary.subscribedFeedIDs.contains($0.feed) }
                #expect(all.count == subscribed.count && all.count > 45_000 && rows(controller) == Array(all.prefix(150)))
                @MainActor func nextPage(_ page: Int) {
                    let content = controller.content
                    let start = ContinuousClock.now
                    content.setContentOffset(CGPoint(x: 0, y: content.contentSize.height - content.bounds.height), animated: false)
                    controller.view.layoutIfNeeded(); CATransaction.flush()
                    let time = ContinuousClock.now - start
                    #expect(time < .seconds(1), "page \(page) took \(time)")
                    print("GAP-ROBUST timing: page \(page) \(time)")
                    #expect(rows(controller) == Array(all.prefix(150 * page)), "page \(page) continues the list")
                    expectOnlyNearbyContentBuilt(controller.episodeList, in: controller)
                }
                nextPage(2)

                // Opening an episode 250 rows down and coming back: quick, and the list returns to the same place
                // with the pages it had (the reading position needs rows beyond the first page). Fastest of two.
                let target = all[250]
                var opened = Duration.seconds(3600), returned = Duration.seconds(3600)
                for _ in 0..<2 {
                    // Scrolled into view, as a person would.
                    let frame = try #require(controller.episodeList?.frame(of: target))
                    controller.content.setContentOffset(CGPoint(x: 0, y: frame.minY - 100), animated: false)
                    controller.view.layoutIfNeeded()
                    let row = try #require(controller.episodeRows[target]?.1)
                    let rowTop = row.convert(row.bounds, to: controller.view).minY
                    let button: UIButton = try #require(find("episode-\(target)", in: row))
                    var begin = ContinuousClock.now
                    button.sendActions(for: .touchUpInside)
                    controller.view.layoutIfNeeded(); CATransaction.flush()
                    opened = min(opened, ContinuousClock.now - begin)
                    #expect(controller.episodeDetailsID == target)
                    begin = ContinuousClock.now
                    #expect(controller.accessibilityPerformEscape())
                    controller.view.layoutIfNeeded(); CATransaction.flush()
                    returned = min(returned, ContinuousClock.now - begin)
                    let back = try #require(controller.episodeRows[target]?.1)
                    #expect(abs(back.convert(back.bounds, to: controller.view).minY - rowTop) < 2, "same reading position")
                    #expect(rows(controller).count == 300)
                }
                #expect(opened < .seconds(1) && returned < .seconds(1), "open \(opened), back \(returned)")
                print("GAP-ROBUST timing: open episode 251 \(opened), back to 300 rows \(returned)")

                nextPage(3); nextPage(4)
                // A reload (any library change) keeps the pages already shown and the reading position.
                let offset = controller.content.contentOffset.y
                await controller.reloadLibrary()?.value
                controller.view.layoutIfNeeded()
                #expect(Array(rows(controller).prefix(600)) == Array(all.prefix(600)) && abs(controller.content.contentOffset.y - offset) < 2)

                let first = try #require(all.first)
                let start = ContinuousClock.now
                controller.startFeedSelection(first)
                controller.changeFeedSelection("select_toggle")
                controller.view.layoutIfNeeded(); CATransaction.flush()
                #expect(ContinuousClock.now - start < .seconds(1), "select all took \(ContinuousClock.now - start)")
                print("GAP-ROBUST timing: select all \(ContinuousClock.now - start)")
                #expect(controller.feedSelection.ids.count == all.count)
                #expect(texts(controller.view).contains("\(all.count)/\(all.count) selected"))
                controller.endFeedSelection()
            }
        }
    }

    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.find(id, in: $0) as T? }.first
    }

    private func texts(_ view: UIView) -> [String] {
        ((view as? UILabel)?.text.map { [$0] } ?? []) + view.subviews.flatMap(texts)
    }

    /// A refresh reports each refreshed podcast without waiting for the library screens to reread and
    /// redraw the whole library; only its final report waits for an up-to-date screen.
    @Test func refreshIsNotHeldBackByLibraryReloads() async throws {
        actor Gate {
            var open = false, started = 0, finished = 0
            func reload() async { started += 1; while !open { try? await Task.sleep(for: .milliseconds(5)) }; finished += 1 }
            func release() { open = true }
        }
        let gate = Gate()
        let reloads = LibraryReloadCoalescer { await gate.reload() }
        // Twenty podcasts refreshed while the first reload is still running: none waits for it.
        let start = ContinuousClock.now
        for _ in 0..<20 { reloads.request() }
        #expect(ContinuousClock.now - start < .milliseconds(100))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await gate.started == 1, "one reload runs; the requests made meanwhile merge into one follow-up")
        // The refresh's last report waits for a reload that starts after it.
        let final = Task { await reloads.requestAndWait() }
        try await Task.sleep(for: .milliseconds(50))
        await gate.release()
        await final.value
        let (started, finished) = await (gate.started, gate.finished)
        #expect(started == 2 && finished == 2)
    }
}
