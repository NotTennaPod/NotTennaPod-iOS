import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct ArchivedFeedTests {
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let value = view as? T { return value }
        for child in view.subviews { if let value: T = find(id, in: child) { return value } }
        return nil
    }
    @Test(arguments: [false, true])
    func restorePreservesPreferencesEpisodesQueueAndRequests(keepUpdated: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArchivedFeed-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        do {
            let parsed = ParsedFeed(format: .rss, title: "Archived feed", episodes: [.init(identifier: "one", title: "An episode with a long title that uses the released secondary action space", media: .init(url: "https://example.org/audio", size: 100))])
            let inserted = try await store.insert(.init(feed: parsed, source: "https://example.org/feed", responseURL: URL(string: "https://example.org/feed")!, validator: nil, permanentRedirectURL: nil), subscriptionState: .archived)
            let id = inserted.episodes[0].id
            try await store.updatePreferences(feedID: inserted.id) { $0.keepUpdated = keepUpdated; $0.customTitle = "Retained title" }
            try await store.updateEpisode(id: id) { $0.userState.isFavorite = true; $0.userState.positionMilliseconds = 1234 }
            _ = try await store.enqueueAt(id, index: 0)
            let before = try #require(try await store.feed(id: inserted.id))
            let queue = try await store.queue()
            let sync = try await store.synchronizationQueue()
            let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
                timeDisplayPreferences: nil, navigationPreferences: nil, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 760)
                await controller.openNotification(.feed(inserted.id)); controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                let restore: UIButton = try #require(find("restoreFeed", in: controller.view))
                let info: UIButton = try #require(find("feedInformation", in: controller.view))
                let filter: UIButton = try #require(find("feedFilter", in: controller.view))
                let settings: UIButton = try #require(find("feedSettings", in: controller.view))
                #expect(!restore.isHidden && !info.isHidden && filter.isHidden && settings.isHidden)
                #expect(restore.title(for: .normal) == "Restore")
                #expect(restore.frame.minX < info.frame.minX)
                let disabled: UIControl = try #require(find("feedUpdatesDisabled", in: controller.view))
                #expect(!disabled.isHidden)
                let secondary: UIButton = try #require(find("episode-action-\(id)", in: controller.view))
                #expect(secondary.isHidden)
                let row: UIButton = try #require(find("episode-\(id)", in: controller.view))
                #expect(row.frame.width == row.superview?.bounds.width)
                restore.sendActions(for: .touchUpInside)
                let deadline = ContinuousClock.now + .seconds(5)
                while try await store.feed(id: inserted.id)?.subscriptionState != .subscribed, ContinuousClock.now < deadline { await Task.yield() }
                await controller.reloadLibrary()?.value
                controller.view.layoutIfNeeded()
                let after = try #require(try await store.feed(id: inserted.id))
                #expect(after.subscriptionState == .subscribed)
                #expect(after.keepUpdated == keepUpdated && after.customTitle == before.customTitle)
                #expect(after.episodes == before.episodes)
                #expect(try await store.queue() == queue)
                #expect(try await store.synchronizationQueue() == sync)
                #expect(try await store.manualRefreshRequest() == nil)
                #expect((find("restoreFeed", in: controller.view) as UIButton?)?.isHidden == true)
                #expect((find("episode-action-\(id)", in: controller.view) as UIButton?)?.isHidden == false)
                #expect((find("feedFilter", in: controller.view) as UIButton?)?.isHidden == false)
                #expect((find("feedUpdatesDisabled", in: controller.view) as UIControl?)?.isHidden == keepUpdated)
            }
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
}
