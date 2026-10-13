import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct DownloadLogViewTests {
    private func element<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let value = view as? T, value.accessibilityIdentifier == id { return value }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: T.self) }.first
    }
    private func wait(_ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while try await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await condition())
    }
    private func fixture(_ body: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadLogView-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        _ = try await library.insert(.init(feed: .init(format: .rss, title: "Log podcast", episodes: [
            .init(identifier: "one", title: "Log episode", media: .init(url: "https://example.test/media", size: 100))]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        do { try await body(library, root); try await library.close() }
        catch { try? await library.close(); throw error }
    }

    @Test func liveHistoryClearRetryAndReopenedMediaDetailsUseRealStore() async throws {
        try await fixture { library, root in
            try await library.recordFailure(.unauthorized, feedID: 1, date: Date())
            var retries: [DownloadLogEntry] = []
            let controller = DownloadLogController(library: library, retry: { retries.append($0) }, openFeed: { _ in }, failed: { Issue.record($0) })
            try await withViewTestWindow { host, _ in
                host.present(controller, animated: false)
                defer { host.dismiss(animated: false) }
                try await wait { controller.view.window != nil && !controller.isBeingPresented }
                let table: UITableView = try #require(element("downloadLogList", in: controller.view))
                try await wait { table.numberOfRows(inSection: 0) == 1 }
                controller.view.layoutIfNeeded(); table.layoutIfNeeded()
                let first = try #require(table.cellForRow(at: IndexPath(row: 0, section: 0)))
                let title: UILabel = try #require(element("downloadLogTitle", in: first))
                let status: UILabel = try #require(element("downloadLogStatus", in: first))
                let reason: UILabel = try #require(element("downloadLogReason", in: first))
                let icon: UIImageView = try #require(element("downloadLogIcon", in: first))
                #expect(icon.frame.maxX <= title.frame.minX && icon.frame.width > 0, "Status icon precedes the title")
                #expect(abs(status.frame.minX - icon.frame.minX) < 1 && abs(reason.frame.minX - icon.frame.minX) < 1, "Detail lines align with the icon")
                #expect(status.frame.minY >= title.frame.maxY - 0.5 && reason.frame.minY >= status.frame.maxY - 0.5, "Title, status, reason stack in order")
                #expect(title.text == "Log podcast" && status.text == "Feed · 0 minutes ago")
                let clearButton: UIButton = try #require(element("downloadLogClear", in: controller.view))
                #expect(clearButton.convert(clearButton.bounds, to: controller.view).maxY <= table.convert(table.bounds, to: controller.view).minY + 1, "List starts below the toolbar")
                let retry: UIButton = try #require(element("downloadLogRetry-feed-1", in: table))
                let ring: UIView = try #require(element("downloadLogRetryRing", in: retry))
                #expect(retry.bounds.width >= 44 && retry.bounds.height >= 44)
                #expect(retry.bounds.contains(ring.frame))
                #expect(first.contentView.bounds.contains(retry.frame) && retry.frame.minX > max(title.frame.minX, status.frame.minX), "Retry sits at the trailing edge")
                retry.sendActions(for: .touchUpInside)
                try await wait { retries.count == 1 }
                #expect(retry.isHidden && retries[0].feedID == 1)
                let job = try #require(try await library.requestDownload(episodeID: 1, directory: root))
                _ = try await library.beginDownloadAttempt(id: job.id)
                _ = try await library.recordDownloadFailure(id: job.id, attempt: 1, failure: .http(404))
                try await wait { table.numberOfRows(inSection: 0) == 2 }
                controller.tableView(table, didSelectRowAt: IndexPath(row: 0, section: 0))
                try await wait { controller.presentedViewController is SourceMessageController && controller.presentedViewController?.isBeingPresented == false }
                let details = try #require(controller.presentedViewController)
                let episode: UILabel = try #require(element("feedLogEpisode", in: details.view))
                let technical: UILabel = try #require(element("feedLogTechnical", in: details.view))
                #expect(episode.text == "Log episode" && technical.text == "404")
                #expect(element("downloadLogOpenPodcast", in: details.view, as: UIButton.self) != nil)
                details.dismiss(animated: false)
                try await wait { controller.presentedViewController == nil }
                let clear: UIButton = try #require(element("downloadLogClear", in: controller.view))
                clear.sendActions(for: .touchUpInside)
                try await wait { table.numberOfRows(inSection: 0) == 0 }
                controller.view.layoutIfNeeded()
                #expect(element("downloadLogEmpty", in: controller.view)?.isHidden == false)
                #expect(try await library.downloadJob(id: job.id)?.state == .failed)
                #expect(try await library.queue().map(\.id) == [1])
                #expect(try await library.feed(id: 1)?.lastUpdateFailed == true)
            }
        }
    }

    @Test func headerDetailsAndClearedHistoryFallbackAreConnected() async throws {
        try await fixture { library, root in
            try await library.recordFailure(.unauthorized, feedID: 1, date: Date())
            let preferences = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
            var value = preferences.value; value.defaultPage = NavigationDestination.subscriptions.rawValue
            try preferences.update(value)
            let controller = LibraryViewController(library: library, startupError: nil, downloads: nil, playback: nil,
                timeDisplayPreferences: nil, navigationPreferences: preferences, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                controller.view.frame = host.view.bounds
                defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                await controller.reloadLibrary()?.value
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                let feed: UIControl = try #require(element("subscriptionFeed-1", in: controller.view))
                feed.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
                let failure: UIControl = try #require(element("feedRefreshFailure", in: controller.view))
                failure.sendActions(for: .touchUpInside)
                try await wait { controller.presentedViewController is SourceMessageController && controller.presentedViewController?.isBeingPresented == false }
                #expect(element("downloadLogOpenPodcast", in: controller.presentedViewController!.view, as: UIButton.self) == nil)
                controller.dismiss(animated: false)
                try await wait { controller.presentedViewController == nil }
                try await library.clearDownloadLog()
                failure.sendActions(for: .touchUpInside)
                try await wait { controller.presentedViewController is DownloadLogController && controller.presentedViewController?.isBeingPresented == false }
                let sheet = try #require(controller.presentedViewController)
                try await wait { element("downloadLogEmpty", in: sheet.view)?.isHidden == false }
                controller.dismiss(animated: false)
                try await wait { controller.presentedViewController == nil }

            }
        }
    }

    @Test func sheetResizesWithinAsymmetricInsetsAndRetainsScrollableHistory() async throws {
        try await fixture { library, _ in
            for index in 0..<12 { try await library.recordFailure(.unknownHost, feedID: 1, date: Date().addingTimeInterval(Double(index))) }
            let controller = DownloadLogController(library: library, retry: { _ in }, openFeed: { _ in }, failed: { Issue.record($0) })
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                let table: UITableView = try #require(element("downloadLogList", in: controller.view))
                try await wait { table.numberOfRows(inSection: 0) == 12 }
                for size in [CGSize(width: 320, height: 430), CGSize(width: 834, height: 650)] {
                    for rtl in [false, true] {
                        controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 31, left: 13, bottom: 20, right: 27)
                        controller.view.frame = CGRect(origin: .zero, size: size)
                        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded(); table.layoutIfNeeded()
                        let panel = try #require(element("downloadLogSheet", in: controller.view))
                        let safe = controller.view.safeAreaLayoutGuide.layoutFrame
                        #expect(panel.frame.minX >= safe.minX && panel.frame.maxX <= safe.maxX)
                        #expect(controller.view.safeAreaInsets.left >= 13 && controller.view.safeAreaInsets.right >= 27)
                        let visible = panel.frame.intersection(controller.view.bounds)
                        #expect(visible.minY >= 0 && abs(visible.maxY - size.height) < 1, "Sheet reaches the bottom edge")
                        #expect(abs(panel.frame.height - size.height) < 1)
                        let clear: UIButton = try #require(element("downloadLogClear", in: controller.view))
                        #expect(clear.convert(clear.bounds, to: controller.view).minY >= safe.minY)
                        #expect(table.contentSize.height > table.bounds.height)
                        #expect(table.numberOfRows(inSection: 0) == 12)
                    }
                }
            }
        }
    }

    @Test func emptyGroupMatchesSourceCenterAndBoundsAfterClearAndResize() async throws {
        try await fixture { library, _ in
            let controller = DownloadLogController(library: library, retry: { _ in }, openFeed: { _ in }, failed: { Issue.record($0) })
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                for size in [CGSize(width: 320, height: 700), CGSize(width: 834, height: 650)] {
                    controller.view.frame = CGRect(origin: .zero, size: size)
                    controller.additionalSafeAreaInsets = UIEdgeInsets(top: 13, left: 17, bottom: 23, right: 31)
                    controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                    let empty = try #require(element("downloadLogEmpty", in: controller.view))
                    let icon = try #require(empty.subviews.compactMap { $0 as? UIImageView }.first)
                    let labels = empty.subviews.compactMap { $0 as? UILabel }
                    #expect(labels.count == 2)
                    #expect(icon.frame.width > 0 && icon.frame.height > 0 && abs(icon.frame.midX - empty.bounds.midX) < 1)
                    #expect(labels[0].frame.minY >= icon.frame.maxY - 0.5 && labels[1].frame.minY >= labels[0].frame.maxY - 0.5, "Icon, title, message stack in order")
                    #expect(abs((icon.frame.minY + labels[1].frame.maxY) / 2 - empty.bounds.midY) < 2, "Empty group is vertically centred")
                    #expect(labels.allSatisfy { $0.frame.minX > 0 && $0.frame.maxX < empty.bounds.width && abs($0.frame.midX - empty.bounds.midX) < 1 })
                }
            }
        }
    }
}
