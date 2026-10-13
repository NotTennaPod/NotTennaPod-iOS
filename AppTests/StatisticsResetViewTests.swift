import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Mounted: Statistics overflow → Reset statistics data → source confirmation. Cancel writes
/// nothing; Confirm restores default period choices, zeroes played durations only, and reloads.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct StatisticsResetViewTests {
    private func element<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let match = view as? T, view.accessibilityIdentifier == id { return match }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: T.self) }.first
    }

    @Test func overflowResetCancelKeepsEverythingConfirmResetsChoicesAndPlayedTimeOnly() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("M14Reset-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try FeedLibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        let feed = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Reset view fixture", episodes: [
            .init(identifier: "one", title: "One", media: .init(url: "fixture://one", size: 0, durationMilliseconds: 7_200_000))]),
            source: "https://example.test/reset-view", responseURL: URL(string: "https://example.test/reset-view")!, validator: nil))
        let episode = try #require(feed.episodes.first).id
        try await store.updateEpisode(id: episode) {
            $0.userState.playState = .played; $0.userState.positionMilliseconds = 1_000
            $0.userState.playedDurationMilliseconds = 7_200_000; $0.userState.lastPlayedTimeMilliseconds = 1_700_000_000_000
        }
        let prefsFile = folder.appendingPathComponent("period.json")
        let prefs = try StatisticsPreferenceStore(file: prefsFile)
        try prefs.update(.init(includeMarkedAsPlayed: false, timeFrom: 1_600_000_000_000, timeTo: 1_800_000_000_000))
        let navigation = try NavigationPreferenceStore(file: folder.appendingPathComponent("navigation.json"))
        var nav = navigation.value; nav.defaultPage = NavigationDestination.statistics.rawValue; try navigation.update(nav)
        let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil,
            mobileNetworkPreferences: nil, usage: nil, statisticsPreferences: prefs)
        func wait(_ stage: String, _ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(6)
            while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(predicate(), Comment(rawValue: stage))
        }
        func total() -> String? { element("statisticsTotal", in: controller.view, as: UILabel.self)?.text }
        func openReset() async throws -> SourceMessageController {
            let more = try #require(element("statisticsMore", in: controller.view, as: UIButton.self))
            #expect(more.accessibilityLabel == "More")
            more.sendActions(for: .touchUpInside)
            try await wait("overflow menu") { element("statisticsReset", in: controller.view, as: UIControl.self) != nil }
            let entry = try #require(element("statisticsReset", in: controller.view, as: UIControl.self))
            entry.sendActions(for: .touchUpInside)
            try await wait("confirmation presented") {
                (controller.presentedViewController as? SourceMessageController)?.isBeingPresented == false
            }
            let dialog = try #require(controller.presentedViewController as? SourceMessageController)
            #expect(element("sourceMessageTitle", in: dialog.view, as: UILabel.self)?.text == "Reset statistics data")
            #expect(element("sourceMessage", in: dialog.view, as: UILabel.self)?.text
                    == "This will erase the history of duration played for all episodes. Are you sure you want to proceed?")
            #expect(element("statisticsResetConfirm", in: dialog.view, as: UIButton.self)?.title(for: .normal) == "Confirm")
            #expect(element("statisticsResetCancel", in: dialog.view, as: UIButton.self)?.title(for: .normal) == "Cancel")
            return dialog
        }
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            controller.view.frame = host.view.bounds; controller.view.layoutIfNeeded()
            defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            try await wait("initial total") { total() == "2.0 hours" }
            let feedBefore = try await store.feed(id: feed.id)
            let prefsBefore = prefs.value

            try #require(element("statisticsResetCancel", in: try await openReset().view, as: UIButton.self)).sendActions(for: .touchUpInside)
            try await wait("cancel dismissed") { controller.presentedViewController == nil }
            try await Task.sleep(for: .milliseconds(200))
            #expect(prefs.value == prefsBefore, "Cancel writes no choices")
            #expect(try StatisticsPreferenceStore(file: prefsFile).value == prefsBefore, "Cancel writes no saved choices")
            #expect(try await store.feed(id: feed.id) == feedBefore, "Cancel writes no library data")
            #expect(total() == "2.0 hours")

            try #require(element("statisticsResetConfirm", in: try await openReset().view, as: UIButton.self)).sendActions(for: .touchUpInside)
            try await wait("reset reloads zero total") { controller.presentedViewController == nil && total() == "0.0 hours" }
            #expect(try StatisticsPreferenceStore(file: prefsFile).value == StatisticsPeriodPreferences(), "Default choices saved")
            var expected = try #require(feedBefore); expected.episodes[0].userState.playedDurationMilliseconds = 0
            #expect(try await store.feed(id: feed.id) == expected, "Only played duration changes")
        }
        try await store.close()
    }
}
