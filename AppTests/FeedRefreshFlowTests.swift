import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized)
struct FeedRefreshFlowTests {
    private func element<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if let value = view as? T, value.accessibilityIdentifier == id { return value }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: type) }.first
    }
    private func wait(_ condition: @MainActor () async throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let end = ContinuousClock.now + .seconds(20)
        while try await !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await condition(), sourceLocation: sourceLocation)
    }
    private func tap(_ id: String, in controller: UIViewController) throws {
        let control: UIControl = try #require(element(id, in: controller.view))
        control.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
    }
    private final class Publisher: EpisodeNotificationPublishing {
        func isAuthorized() async -> Bool { false }
        func existingIdentifiers() async -> Set<String> { [] }
        func publish(_ publication: EpisodeNotificationPublication) async throws { Issue.record("Permission denied") }
    }
    private actor Transport: FeedHTTPTransport {
        var requested: URL?
        private var continuation: CheckedContinuation<Void, Never>?
        func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
            requested = request.url
            await withCheckedContinuation { continuation = $0 }
            try Task.checkCancellation()
            return .init(url: request.url!, status: 200, body: Data("<rss version=\"2.0\"><channel><title>Refreshed podcast</title><item><guid>new</guid><title>Delivered episode</title></item></channel></rss>".utf8))
        }
        func release() { continuation?.resume(); continuation = nil }
    }
    /// Each feed answers after a simulated network time, so refreshing every podcast takes seconds, as on a phone.
    private actor SlowFeeds: FeedHTTPTransport {
        private(set) var fetched = 0
        func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
            try await Task.sleep(for: .milliseconds(80))
            fetched += 1
            let url = try #require(request.url), number = url.lastPathComponent
            return .init(url: url, status: 200, body: Data("""
                <rss version="2.0"><channel><title>Podcast \(number)</title><item><guid>episode-\(number)</guid>\
                <title>Episode \(number)</title><enclosure url="https://example.org/media/\(number).mp3" type="audio/mpeg" length="1000"/>\
                </item></channel></rss>
                """.utf8))
        }
    }

    @Test func editURLFromInformationPersistsFetchesAndReturnsToUpdatedList() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FeedRefreshFlow-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let original = "https://example.org/original", updated = "https://example.org/edited"
        let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Original podcast"), source: original,
            responseURL: URL(string: original)!, validator: nil, permanentRedirectURL: nil))
        let deletion = FeedDeletionCoordinator(store: store, retirePlayback: { _ in }, retireDownloads: { _ in })
        let automatic = AutomaticDownloadCoordinator(store: store, preferences: { .init() },
            environment: { .init(connection: .unavailable, allowMobile: false, charging: false) }, cleanup: { _ in }, download: { _ in })
        weak var displayed: LibraryViewController?
        let delivery = ManualFeedRefreshDelivery(store: store, deletion: deletion,
            notifications: .init(store: store, publisher: Publisher(), text: NewEpisodeNotificationContent.text, artwork: { _ in nil }),
            automaticDownloads: automatic, allowMobileSync: { false }, libraryChanged: {
                await displayed?.reloadLibrary(preservingEpisodeDetails: true)?.value
            })
        let transport = Transport(), network = DownloadNetworkMonitor(startMonitoring: false)
        network.update(.init(connected: true, metered: false, cellular: false))
        let refresh = ManualFeedRefreshCoordinator(store: store, worker: .init(store: store,
            remote: .init(store: store, fetcher: .init(transport: transport)), local: .init(store: store),
            localDescription: "Local", localAuthor: "Folder", network: network, credentials: { _ in nil }, options: { _ in .init() }, effects: delivery))
        let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: nil, speedPreferences: nil, mobileNetworkPreferences: nil,
            usage: nil, feedDeletion: deletion, manualRefresh: refresh,
            refreshNetwork: { .init(connected: true, metered: false, cellular: false) })
        displayed = controller
        delivery.onChange = { [weak controller] _ in controller?.refreshProgressChanged() }
        refresh.onChange = { [weak controller] state in controller?.refreshStateChanged(state) }
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer {
                controller.dismiss(animated: false)
                controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent()
                refresh.suspend()
            }
            controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            await controller.openNotification(.feed(feed.id))
            controller.view.layoutIfNeeded()
            try tap("feedInformation", in: controller)
            try tap("feedInformationMore", in: controller)
            try tap("editFeedURL", in: controller)
            try await wait { controller.presentedViewController is SourceMessageController && controller.presentedViewController?.isBeingPresented == false }
            let dialog = try #require(controller.presentedViewController)
            let input: UITextView = try #require(element("editFeedURLInput", in: dialog.view))
            #expect(input.text == original)
            input.text = updated
            try tap("editFeedURLNext", in: dialog)
            try await wait { controller.presentedViewController is FeedURLConfirmationController }
            let confirmation = try #require(controller.presentedViewController)
            let confirm: UIButton = try #require(element("editFeedURLConfirm", in: confirmation.view))
            #expect(!confirm.isEnabled)
            #expect(try await store.feed(id: feed.id)?.source == original)
            try await wait { confirm.isEnabled }
            try tap("editFeedURLConfirm", in: confirmation)
            try await wait { await transport.requested != nil && controller.presentedViewController == nil }
            #expect(await transport.requested?.absoluteString == updated)
            #expect(try await store.feed(id: feed.id)?.source == updated)
            try tap("toolbarBack", in: controller)
            let progress: UIView = try #require(element("feedRefreshProgress", in: controller.view))
            controller.refreshProgressChanged()
            #expect(!progress.isHidden)
            let request = try #require(try await store.manualRefreshRequest())
            #expect(request.feedID == feed.id && request.force)
            controller.view.frame.size = CGSize(width: 720, height: 500)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            #expect(element("feedRefreshProgress", in: controller.view, as: UIView.self) === progress)
            #expect(!progress.isHidden)
            await transport.release()
            try await refresh.waitUntilIdle()
            #expect(refresh.state == .idle)
            #expect(try await store.feed(id: feed.id)?.title == "Refreshed podcast")
            #expect(try await store.feed(id: feed.id)?.episodes.count == 1)
            #expect(progress.isHidden)
            #expect(try await store.synchronizationState().request != nil)
            try tap("feedListMore", in: controller)
            let menuRefresh: UIButton = try #require(element("refreshFeed", in: controller.view))
            let more: UIButton = try #require(element("feedListMore", in: controller.view))
            #expect(menuRefresh.title(for: .normal) == "Refresh")
            let menuSort: UIButton = try #require(element("sortFeed", in: controller.view))
            let rowTop = menuSort.convert(menuSort.bounds, to: controller.view).minY
            let anchorTop = more.convert(more.bounds, to: controller.view).minY
            #expect(rowTop >= anchorTop && rowTop - anchorTop <= 16, "Overflow menu opens at the More button")
            #expect(element("removeArchiveFeed", in: controller.view, as: UIButton.self) != nil)
        }
        await transport.release()
        try await store.close()
    }

    @Test(arguments: ["once", "always", "no", "offline"])
    func refreshMenuAdmissionAndMobilePreference(choice: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RefreshAdmission-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let source = "https://example.org/feed"
        let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Admission"), source: source,
            responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil))
        let preferences = try MobileNetworkPreferenceStore(file: root.appendingPathComponent("mobile.json"))
        let refresh = ManualFeedRefreshCoordinator(store: store, execute: { request in
            _ = try await store.finishManualRefresh(id: request.id)
        })
        let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: nil, speedPreferences: nil, mobileNetworkPreferences: preferences,
            usage: nil, manualRefresh: refresh, refreshNetwork: {
                .init(connected: choice != "offline", metered: true, cellular: true)
            })
        var accepted: [FeedRefreshRequest] = []
        refresh.onChange = { if case .active(let request) = $0 { accepted.append(request) } }
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer {
                controller.dismiss(animated: false)
                controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent()
                refresh.suspend()
            }
            controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            await controller.openNotification(.feed(feed.id)); controller.view.layoutIfNeeded()
            try tap("feedListMore", in: controller); try tap("refreshFeed", in: controller)
            if choice == "offline" {
                try await wait { self.element("applicationNotice", in: controller.view.window ?? controller.view, as: UILabel.self)?.text == "No network connection" }
                #expect(controller.presentedViewController == nil)
            } else {
                try await wait { controller.presentedViewController is SourceMessageController && controller.presentedViewController?.isBeingPresented == false }
                let dialog = try #require(controller.presentedViewController)
                let identifiers = ["once": "refreshOnce", "always": "refreshAlways", "no": "refreshNo"]
                try tap(try #require(identifiers[choice]), in: dialog)
                try await wait { controller.presentedViewController == nil }
                if choice != "no" {
                    try await wait { accepted.count == 1 }
                    try await refresh.waitUntilIdle()
                    #expect(accepted[0].feedID == feed.id && accepted[0].force)
                    try tap("feedListMore", in: controller); try tap("refreshFeed", in: controller)
                    try await wait { self.element("applicationNotice", in: controller.view.window ?? controller.view, as: UILabel.self)?.text == Appearance.text("please_wait_before_refreshing") }
                    #expect(accepted.count == 1)
                }
            }
            #expect(preferences.allows(.feedRefresh) == (choice == "always"))
            let reopened = try MobileNetworkPreferenceStore(file: root.appendingPathComponent("mobile.json"))
            #expect(reopened.allows(.feedRefresh) == (choice == "always"))
            if choice == "offline" || choice == "no" { #expect(accepted.isEmpty) }
        }
        try await store.close()
    }

    /// Refreshing every podcast (70, over seconds) redraws the lists at most once a second while it runs, plus once when
    /// it ends, instead of once per podcast (a stutter while a person scrolls). When it ends the screen shows everything
    /// the refresh brought, exactly as a full reload does.
    @Test func refreshingEveryPodcastRedrawsTheListsAtMostOnceASecond() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RefreshAllReloads-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        for number in 0..<70 {
            let source = "https://example.org/feeds/\(number)"
            _ = try await store.insert(.init(feed: .init(format: .rss, title: "Podcast \(number)"), source: source,
                responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil))
        }
        let deletion = FeedDeletionCoordinator(store: store, retirePlayback: { _ in }, retireDownloads: { _ in })
        let automatic = AutomaticDownloadCoordinator(store: store, preferences: { .init() },
            environment: { .init(connection: .unavailable, allowMobile: false, charging: false) }, cleanup: { _ in }, download: { _ in })
        weak var displayed: LibraryViewController?
        // Wired as the app wires it (AppDelegate): each refreshed podcast requests a reload, the end waits for one.
        var starts: [ContinuousClock.Instant] = []
        let reloads = LibraryReloadCoalescer {
            starts.append(.now)
            await displayed?.reloadLibrary(preservingEpisodeDetails: true, keepsUnchangedScreen: true)?.value
        }
        let delivery = ManualFeedRefreshDelivery(store: store, deletion: deletion,
            notifications: .init(store: store, publisher: Publisher(), text: NewEpisodeNotificationContent.text, artwork: { _ in nil }),
            automaticDownloads: automatic, allowMobileSync: { false },
            libraryChanged: { await reloads.requestAndWait() }, feedRefreshed: { reloads.request() })
        let transport = SlowFeeds(), network = DownloadNetworkMonitor(startMonitoring: false)
        network.update(.init(connected: true, metered: false, cellular: false))
        let refresh = ManualFeedRefreshCoordinator(store: store, worker: .init(store: store,
            remote: .init(store: store, fetcher: .init(transport: transport)), local: .init(store: store),
            localDescription: "Local", localAuthor: "Folder", network: network, credentials: { _ in nil }, options: { _ in .init() }, effects: delivery))
        let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: nil, speedPreferences: nil, mobileNetworkPreferences: nil,
            usage: nil, feedDeletion: deletion, manualRefresh: refresh,
            refreshNetwork: { .init(connected: true, metered: false, cellular: false) })
        displayed = controller
        delivery.onChange = { [weak controller] _ in controller?.refreshProgressChanged() }
        refresh.onChange = { [weak controller] state in controller?.refreshStateChanged(state) }
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer {
                controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent()
                refresh.suspend()
            }
            controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
            await controller.reloadLibrary()?.value
            controller.select(.episodes)
            controller.view.layoutIfNeeded()
            #expect(controller.displayedEpisodeIDs.isEmpty)

            let begin = ContinuousClock.now
            _ = try await refresh.runOnce(feedID: nil).value
            try await refresh.waitUntilIdle()
            let elapsed = ContinuousClock.now - begin
            print("REFRESH-ALL reloads: \(starts.count) in \(elapsed)")
            #expect(await transport.fetched == 70)
            #expect(elapsed > .seconds(1), "the refresh spans more than one interval")
            // At most one start a second (the first at once), plus the final one.
            #expect(starts.count >= 2 && starts.count <= Int(elapsed / .seconds(1)) + 2, "\(starts.count) reloads in \(elapsed)")
            let during = starts.dropLast()
            for (earlier, later) in zip(during, during.dropFirst()) {
                #expect(earlier.duration(to: later) >= .milliseconds(900), "reloads \(earlier.duration(to: later)) apart")
            }

            // Nothing stale: the screen is what a full reload of the library shows.
            controller.view.layoutIfNeeded()
            let (feeds, rows) = (controller.feeds, controller.displayedEpisodeIDs)
            #expect(rows.count == 70)
            #expect(feeds == (try await store.snapshot()).feeds)
            await controller.reloadLibrary()?.value
            controller.view.layoutIfNeeded()
            #expect(controller.feeds == feeds && controller.displayedEpisodeIDs == rows)
        }
        try await store.close()
    }
}
