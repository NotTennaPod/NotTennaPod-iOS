import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct StatisticsPeriodViewTests {
    private let now = Date(timeIntervalSince1970: 1_789_578_000)
    private var formatter: StatisticsTextFormatter { .init(locale: Locale(identifier: "en-US"), timeZone: TimeZone(identifier: "America/Los_Angeles")!, now: now) }
    private func element<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if view.accessibilityIdentifier == id { return view as? T }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: T.self) }.first
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StatisticsPeriod-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func selector(_ store: StatisticsPreferenceStore) throws -> StatisticsFilterController {
        try .init(preferences: store, oldestMilliseconds: 1_751_353_200_000, formatter: formatter, applied: {})
    }
    @Test func draftCancelAndReconstructionLeaveSavedTupleThenOKCommitsOnce() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("period.json"), store = try StatisticsPreferenceStore(file: folder.appendingPathComponent("period.json"))
        let first = try selector(store)
        first.body.draft.selectPastYear(); first.body.draft.includeMarkedAsPlayed = true
        #expect(first.accessibilityPerformEscape())
        #expect(store.value == .init()); #expect(!FileManager.default.fileExists(atPath: file.path))
        let recreated = try selector(store)
        #expect(!recreated.body.draft.includeMarkedAsPlayed)
        recreated.body.draft.selectFrom(14); recreated.body.draft.selectTo(14)
        recreated.confirm()
        let reopened = try StatisticsPreferenceStore(file: file)
        #expect(reopened.value == .init(timeFrom: 1_788_246_000_000, timeTo: 1_790_838_000_000))
    }
    @Test func markedDisablesOnlyDatesAndAllTimeRestoresDraftSelections() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try StatisticsPreferenceStore(file: folder.appendingPathComponent("period.json"))
        let controller = try selector(store); let body = controller.body
        body.frame = .init(x: 0, y: 0, width: 342, height: 400); body.layoutIfNeeded()
        let check = try #require(element("statisticsIncludeMarked", in: body, as: UIButton.self))
        check.sendActions(for: .touchUpInside)
        for id in ["statisticsFrom", "statisticsTo", "statisticsPastYear", "statisticsAllTime"] {
            let button = try #require(element(id, in: body, as: UIButton.self))
            #expect(!button.isEnabled); #expect(button.superview?.alpha == 0.5)
        }
        #expect(check.isEnabled); #expect(store.value == .init())
        controller.confirm(); #expect(store.value == .init(includeMarkedAsPlayed: true))
        check.sendActions(for: .touchUpInside)
        element("statisticsPastYear", in: body, as: UIButton.self)?.sendActions(for: .touchUpInside)
        #expect(body.draft.fromIndex == 3); #expect(body.draft.toIndex == 14)
        element("statisticsAllTime", in: body, as: UIButton.self)?.sendActions(for: .touchUpInside)
        #expect(body.draft.fromIndex == 0); #expect(body.draft.toIndex == 15)
    }
    @Test func failedCommitRetainsDraftAndPreviouslySavedTuple() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("period.json"), store = try StatisticsPreferenceStore(file: folder.appendingPathComponent("period.json"))
        let previous = StatisticsPeriodPreferences(timeFrom: 17, timeTo: 31)
        try store.update(previous)
        let controller = try selector(store); controller.body.draft.includeMarkedAsPlayed = true
        try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let marker = file.appendingPathComponent("keep"); try Data("unchanged".utf8).write(to: marker)
        controller.confirm()
        #expect(store.value == previous); #expect(controller.body.draft.includeMarkedAsPlayed)
        #expect(try Data(contentsOf: marker) == Data("unchanged".utf8))
    }
    @Test func chartClampsToObservedPhoneTabletWidthAndRowsUseCapturedMetadata() throws {
        var state = EpisodeUserState(); state.playedDurationMilliseconds = 3_600_000; state.lastPlayedTimeMilliseconds = 1_788_300_000_000
        let feed = LibraryFeed(id: 9, source: "fixture://statistics", metadata: .init(format: .rss, title: "Captured title"), episodes: [
            .init(id: 91, details: .init(media: .init(url: "fixture://episode", size: 0, durationMilliseconds: 7_200_000)), userState: state)])
        let snapshot = try SubscriptionStatisticsSnapshot(feeds: [feed], request: .init(preferences: .init(), formatter: formatter))
        let view = StatisticsPieListView(snapshot: snapshot)
        var opened: Int64?; view.openFeedStatistics = { opened = $0 }
        for width: CGFloat in [390, 1024, 558] {
            view.frame = .init(origin: .zero, size: view.sizeThatFits(.init(width: width, height: 1000))); view.setNeedsLayout(); view.layoutIfNeeded()
            let chart = try #require(element("statisticsChart", in: view, as: UIView.self))
            // Chart size and placement as on Android phone/tablet, to within a point.
            #expect(abs(chart.frame.width - min(460, width - 48)) <= 1); #expect(abs(chart.frame.height - chart.frame.width / 2) <= 1)
            #expect(abs(chart.center.x - width / 2) <= 1); #expect(abs(chart.frame.minY - 32) <= 1)
        }
        let row = try #require(element("statisticsFeed-9", in: view, as: UIControl.self))
        #expect(row.accessibilityLabel == "Captured title, 1.0 hours")
        #expect(element("statisticsTotal", in: view, as: UILabel.self)?.text == "1.0 hours")
        row.sendActions(for: .touchUpInside); #expect(opened == 9)
    }
    @Test func selectorKeepsColumnsPresetsAndNoticeOrderedWhenResizedAndRTL() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try StatisticsPreferenceStore(file: folder.appendingPathComponent("period.json"))
        let body = try selector(store).body
        for width: CGFloat in [342, 528, 270] {
            for rtl in [false, true] {
                body.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                body.frame = .init(origin: .zero, size: body.sizeThatFits(.init(width: width, height: 1000))); body.setNeedsLayout(); body.layoutIfNeeded()
                let from = try #require(element("statisticsFrom", in: body, as: UIButton.self)), to = try #require(element("statisticsTo", in: body, as: UIButton.self))
                let past = try #require(element("statisticsPastYear", in: body, as: UIButton.self)), all = try #require(element("statisticsAllTime", in: body, as: UIButton.self))
                #expect(from.frame.width == to.frame.width); #expect(from.frame.minY == to.frame.minY)
                #expect((from.frame.minX > to.frame.minX) == rtl)
                #expect(past.frame.minY >= from.frame.maxY); #expect(all.frame.minY == past.frame.minY)
            }
        }
    }
    @Test func connectedLibraryFilterPersistsAndDetailUsesAllTime() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try FeedLibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        let feed = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Period fixture", episodes: [
            .init(identifier: "one", title: "One", media: .init(url: "fixture://one", size: 0, durationMilliseconds: 3_600_000))]),
            source: "https://example.test/period", responseURL: URL(string: "https://example.test/period")!, validator: nil, permanentRedirectURL: nil))
        try await store.updateEpisode(id: feed.episodes[0].id) { $0.userState.playState = .played }
        let prefs = try StatisticsPreferenceStore(file: folder.appendingPathComponent("period.json"))
        let navigation = try NavigationPreferenceStore(file: folder.appendingPathComponent("navigation.json"))
        var nav = navigation.value; nav.defaultPage = NavigationDestination.statistics.rawValue; try navigation.update(nav)
        let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil,
            mobileNetworkPreferences: nil, usage: nil, statisticsPreferences: prefs)
        func wait(_ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(6)
            while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(predicate())
        }
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            controller.view.frame = host.view.bounds; controller.view.layoutIfNeeded()
            defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            try await wait { element("statisticsTotal", in: controller.view, as: UILabel.self)?.text == "0.0 hours" }
            let filter = try #require(element("statisticsFilter", in: controller.view, as: UIButton.self))
            filter.sendActions(for: .touchUpInside)
            try await wait { controller.presentedViewController is StatisticsFilterController && controller.presentedViewController?.isBeingPresented == false }
            let dialog = try #require(controller.presentedViewController as? StatisticsFilterController)
            let check = try #require(element("statisticsIncludeMarked", in: dialog.view, as: UIButton.self))
            check.sendActions(for: .touchUpInside)
            element("statisticsFilterOK", in: dialog.view, as: UIButton.self)?.sendActions(for: .touchUpInside)
            try await wait { controller.presentedViewController == nil && element("statisticsTotal", in: controller.view, as: UILabel.self)?.text == "1.0 hours" }
            #expect(try StatisticsPreferenceStore(file: folder.appendingPathComponent("period.json")).value.includeMarkedAsPlayed)
            // A global empty range must not restrict the feed's all-time cards.
            try prefs.update(.init(timeFrom: 17, timeTo: 31))
            try await wait { element("statisticsTotal", in: controller.view, as: UILabel.self)?.text == "0.0 hours" }
            let row = try #require(element("statisticsFeed-\(feed.id)", in: controller.view, as: UIControl.self))
            row.sendActions(for: .touchUpInside)
            try await wait {
                guard let view = controller.presentedViewController?.view,
                      let card = element("statistics.playbackTime", in: view, as: UIView.self) else { return false }
                return element("statisticsValue", in: card, as: UILabel.self)?.text == "1.0 hours"
            }
            controller.dismiss(animated: false)
            #expect(element("statisticsTotal", in: controller.view, as: UILabel.self)?.text == "0.0 hours")
        }
        try await store.close()
    }

    /// Source posts StatisticsEvent on every successful OK, so confirming unchanged
    /// choices must reload current library totals and recover after a failed read.
    @Test func unchangedOKReloadsCurrentTotalsAndRecoversAfterFailedRead() async throws {
        final class Reads: @unchecked Sendable {
            let lock = NSLock(); var failing = false; var count = 0
            func next() -> (Bool, Int) { lock.withLock { count += 1; return (failing, count) } }
            func set(failing value: Bool) { lock.withLock { failing = value } }
        }
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = try FeedLibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        let feed = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Refresh fixture", episodes: [
            .init(identifier: "one", title: "One", media: .init(url: "fixture://one", size: 0, durationMilliseconds: 3_600_000)),
            .init(identifier: "two", title: "Two", media: .init(url: "fixture://two", size: 0, durationMilliseconds: 7_200_000))]),
            source: "https://example.test/refresh", responseURL: URL(string: "https://example.test/refresh")!, validator: nil, permanentRedirectURL: nil))
        let one = try #require(feed.episodes.first { $0.details.identifier == "one" }), two = try #require(feed.episodes.first { $0.details.identifier == "two" })
        try await store.updateEpisode(id: one.id) { $0.userState.playState = .played }
        let prefs = try StatisticsPreferenceStore(file: folder.appendingPathComponent("period.json"))
        try prefs.update(.init(includeMarkedAsPlayed: true))
        let navigation = try NavigationPreferenceStore(file: folder.appendingPathComponent("navigation.json"))
        var nav = navigation.value; nav.defaultPage = NavigationDestination.statistics.rawValue; try navigation.update(nav)
        let reads = Reads()
        let controller = LibraryViewController(library: nil, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil,
            mobileNetworkPreferences: nil, usage: nil, loadSnapshot: {
                if reads.next().0 { throw CocoaError(.fileReadUnknown) }
                return try await store.snapshot()
            }, statisticsPreferences: prefs)
        func wait(_ stage: String, _ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(6)
            while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(predicate(), Comment(rawValue: stage))
        }
        func total() -> String? { element("statisticsTotal", in: controller.view, as: UILabel.self)?.text }
        func confirmUnchanged() async throws {
            let before = try Data(contentsOf: folder.appendingPathComponent("period.json"))
            try #require(element("statisticsFilter", in: controller.view, as: UIButton.self)).sendActions(for: .touchUpInside)
            try await wait("selector presented") { controller.presentedViewController is StatisticsFilterController && controller.presentedViewController?.isBeingPresented == false }
            let dialog = try #require(controller.presentedViewController as? StatisticsFilterController)
            try #require(element("statisticsFilterOK", in: dialog.view, as: UIButton.self)).sendActions(for: .touchUpInside)
            try await wait("selector dismissed") { controller.presentedViewController == nil }
            let after = try Data(contentsOf: folder.appendingPathComponent("period.json"))
            // The saved tuple must be unchanged; byte order of the JSON encoding is not a product contract.
            #expect(try JSONDecoder().decode(StatisticsPeriodPreferences.self, from: after) == JSONDecoder().decode(StatisticsPeriodPreferences.self, from: before),
                    "before=\(String(decoding: before, as: UTF8.self)) after=\(String(decoding: after, as: UTF8.self))")
        }
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            controller.view.frame = host.view.bounds; controller.view.layoutIfNeeded()
            defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            try await wait("initial total") { total() == "1.0 hours" }
            // The library changes while the screen stays open; unchanged OK must show current totals.
            try await store.updateEpisode(id: two.id) { $0.userState.playState = .played }
            try await confirmUnchanged()
            try await wait("unchanged OK reloads current library") { total() == "3.0 hours" }
            // A failed read after an unchanged OK leaves no stale total; the next unchanged OK recovers.
            reads.set(failing: true)
            try await confirmUnchanged()
            try await wait("failed read shows loading, not a stale total") {
                total() == nil && element("statisticsLoading", in: controller.view, as: UIActivityIndicatorView.self) != nil
            }
            reads.set(failing: false)
            try await confirmUnchanged()
            try await wait("unchanged OK recovers after failure") { total() == "3.0 hours" }
        }
        try await store.close()
    }

    @Test func exactMidnightMountedCancelReopenAndOKPreserveSavedBytesUntilConfirmation() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("period.json")
        let store = try StatisticsPreferenceStore(file: file)
        let previous = StatisticsPeriodPreferences(timeFrom: 1_785_567_600_000, timeTo: 1_788_246_000_000)
        try store.update(previous)
        let bytes = try Data(contentsOf: file)
        let fixed = StatisticsTextFormatter(locale: Locale(identifier: "en-US"),
            timeZone: TimeZone(identifier: "America/Los_Angeles")!, now: Date(timeIntervalSince1970: 1_788_246_000))
        func make() throws -> StatisticsFilterController {
            try .init(preferences: store, oldestMilliseconds: 1_788_246_000_000, formatter: fixed, applied: {})
        }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(6)
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(condition())
        }
        try await withViewTestWindow { host, _ in
            let canceled = try make(); host.present(canceled, animated: false)
            try await wait { canceled.viewIfLoaded?.window != nil && !canceled.isBeingPresented }
            #expect(element("statisticsFrom", in: canceled.view, as: UIButton.self)?.title(for: .normal) == "Sep 2026")
            #expect(element("statisticsTo", in: canceled.view, as: UIButton.self)?.title(for: .normal) == "Sep 2026")
            element("statisticsIncludeMarked", in: canceled.view, as: UIButton.self)?.sendActions(for: .touchUpInside)
            #expect(canceled.accessibilityPerformEscape())
            try await wait { host.presentedViewController == nil }
            #expect(store.value == previous); #expect(try Data(contentsOf: file) == bytes)
            let reopened = try make(); host.present(reopened, animated: false)
            try await wait { reopened.viewIfLoaded?.window != nil && !reopened.isBeingPresented }
            #expect(!reopened.body.draft.includeMarkedAsPlayed)
            let ok = try #require(element("statisticsFilterOK", in: reopened.view, as: UIButton.self))
            ok.sendActions(for: .touchUpInside)
            try await wait { host.presentedViewController == nil }
            #expect(try StatisticsPreferenceStore(file: file).value == .init(timeFrom: 1_788_246_000_000, timeTo: 1_790_838_000_000))
            let snapshot = try SubscriptionStatisticsSnapshot(feeds: [], request: .init(preferences: store.value, formatter: fixed))
            let statistics = StatisticsPieListView(snapshot: snapshot)
            host.view.addSubview(statistics)
            defer { statistics.removeFromSuperview() }
            statistics.frame = host.view.bounds; statistics.layoutIfNeeded()
            #expect(element("statisticsTotal", in: statistics, as: UILabel.self)?.text == "0.0 hours")
            #expect(snapshot.rows.isEmpty)
            #expect(StatisticsPeriodCaption(preferences: store.value, oldestMilliseconds: 1_788_246_000_000, formatter: fixed).interval == .empty)
        }
    }

    @Test func exactMidnightDefaultControlsKeepRealMonthThroughMarkedAndPresets() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("period.json")
        let store = try StatisticsPreferenceStore(file: file)
        let fixed = StatisticsTextFormatter(locale: Locale(identifier: "en-US"),
            timeZone: TimeZone(identifier: "UTC")!, now: Date(timeIntervalSince1970: 1_788_220_800))
        let controller = try StatisticsFilterController(preferences: store, oldestMilliseconds: 1_788_220_800_000,
            formatter: fixed, applied: {})
        let body = controller.body
        body.frame = .init(x: 0, y: 0, width: 342, height: 400); body.layoutIfNeeded()
        let from = try #require(element("statisticsFrom", in: body, as: UIButton.self))
        let to = try #require(element("statisticsTo", in: body, as: UIButton.self))
        let marked = try #require(element("statisticsIncludeMarked", in: body, as: UIButton.self))
        let past = try #require(element("statisticsPastYear", in: body, as: UIButton.self))
        let all = try #require(element("statisticsAllTime", in: body, as: UIButton.self))
        #expect(from.title(for: .normal) == "Sep 2026" && to.title(for: .normal) == "Today")
        marked.sendActions(for: .touchUpInside)
        #expect(!from.isEnabled && !to.isEnabled && !past.isEnabled && !all.isEnabled)
        marked.sendActions(for: .touchUpInside)
        #expect(from.isEnabled && to.isEnabled && past.isEnabled && all.isEnabled)
        past.sendActions(for: .touchUpInside)
        #expect(body.draft.confirmedPreferences() == .init(timeFrom: 1_788_220_800_000, timeTo: 1_790_812_800_000))
        #expect(to.title(for: .normal) == "Sep 2026")
        all.sendActions(for: .touchUpInside)
        #expect(to.title(for: .normal) == "Today")
        #expect(store.value == .init() && !FileManager.default.fileExists(atPath: file.path))
        controller.confirm()
        #expect(try StatisticsPreferenceStore(file: file).value == .init(timeFrom: 1_788_220_800_000))
    }

}
