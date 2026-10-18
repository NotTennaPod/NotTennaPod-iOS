import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized)
struct DownloadsScreenViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if let result = view as? T, view.accessibilityIdentifier == id { return result }
        return view.subviews.lazy.compactMap { find(id, in: $0, as: T.self) }.first
    }
    private func find<T: UIView>(_ id: String, in view: UIView, as: T.Type) -> T? { find(id, in: view) }
    private func wait(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while try await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await condition())
    }
    @Test func crossFeedSelectionUsesVisibleDownloadsAndCancelsActiveJobsWithoutDeletingOtherEpisodes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadsSelection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let navigation = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
        var nav = navigation.value; nav.defaultPage = NavigationDestination.downloads.rawValue; try navigation.update(nav)
        var downloadedIDs: [Int64] = [], excludedIDs: [Int64] = [], files: [URL] = []
        var activeID: Int64 = 0
        for (index, state) in [FeedSubscriptionState.subscribed, .archived, .notSubscribed].enumerated() {
            let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Podcast \(index)", episodes: (0..<3).map { offset in
                .init(identifier: "\(index)-\(offset)", title: "Episode \(index)-\(offset)", publicationDate: Date(timeIntervalSince1970: Double(index * 10 + offset)),
                      media: .init(url: "https://example.test/\(index)-\(offset).mp3", size: 120017))
            }), source: "https://example.test/feed-\(index)", responseURL: URL(string: "https://example.test/feed-\(index)")!, validator: nil, permanentRedirectURL: nil), subscriptionState: state)
            let episode = try #require(feed.episodes.first { $0.details.identifier == "\(index)-0" })
            downloadedIDs.append(episode.id)
            let file = root.appendingPathComponent("\(index).mp3"); files.append(file)
            let fixture = try #require(Bundle(for: ViewTestBundleMarker.self).url(forResource: "playback-30sec", withExtension: "mp3"))
            try FileManager.default.copyItem(at: fixture, to: file)
            try await store.updateEpisode(id: episode.id) { $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path }
            for other in feed.episodes where other.id != episode.id {
                if index == 0 && other.details.identifier == "0-1" { activeID = other.id }
                else { excludedIDs.append(other.id) }
            }
        }
        let expected = Set(downloadedIDs + [activeID])
        _ = try await store.enqueue(Array(expected).sorted())
        let network = DownloadNetworkMonitor(startMonitoring: false)
        network.update(.init(connected: true, metered: true, cellular: true))
        let downloads = DownloadCoordinator(store: store, directory: root.appendingPathComponent("media"), network: network)
        let playback = PlaybackCoordinator(store: store, engine: AVPlayerPlaybackEngine(muted: true))
        let controller = LibraryViewController(library: store, startupError: nil, downloads: downloads, playback: playback,
            timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
        do {
            _ = try await downloads.confirm(episodeID: activeID, choice: .later)
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                controller.view.frame = host.view.bounds
                await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
                @MainActor func button(_ id: String, in view: UIView? = nil) throws -> UIButton {
                    controller.view.layoutIfNeeded()
                    return try #require(find(id, in: view ?? controller.view), "Missing \(id)")
                }
                let content: UIScrollView = try #require(find("libraryContent", in: controller.view))
                let preview = try button("episode-\(downloadedIDs[2])")
                let row = try #require(preview.superview as? EpisodeRowView)
                row.contextMenu?(row, CGPoint(x: 0.5, y: 0.5))
                try await wait { controller.presentedViewController != nil && controller.presentedViewController?.isBeingPresented == false }
                let menu = try #require(controller.presentedViewController)
                #expect(find("markPlayed", in: menu.view, as: UIButton.self) == nil)
                #expect(find("delete", in: menu.view, as: UIButton.self) != nil)
                try button("multiSelect", in: menu.view).sendActions(for: .touchUpInside)
                try await wait { controller.feedSelection.active && controller.presentedViewController == nil }
                #expect(controller.feedSelection.ids == [downloadedIDs[2]])
                let close = try button("endEpisodeSelection")
                #expect(close.bounds.width >= 48 && !close.isHidden)
                // Downloads' default Delete is replaced by the ordinary Play icon in select mode.
                let secondary = try button("episode-action-\(downloadedIDs[0])")
                #expect(secondary.accessibilityLabel == Appearance.text("play_label"))
                secondary.sendActions(for: .touchUpInside)
                #expect(controller.feedSelection.ids == [downloadedIDs[2], downloadedIDs[0]])
                #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
                try button("episode-\(downloadedIDs[0])").sendActions(for: .touchUpInside)
                controller.changeFeedSelection("select_all_below")
                #expect(controller.feedSelection.ids == Set(downloadedIDs))
                controller.changeFeedSelection("select_all_above")
                #expect(controller.feedSelection.ids == expected)
                await controller.reloadLibrary()?.value
                controller.view.frame.size = CGSize(width: 720, height: 420)
                controller.additionalSafeAreaInsets = .init(top: 0, left: 19, bottom: 0, right: 47)
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                #expect(controller.feedSelection.ids == expected)
                let count: UILabel = try #require(find("episodeSelectionCount", in: controller.view))
                #expect(count.text == "4/4 selected")
                let bar: UIView = try #require(find("episodeSelectionActions", in: controller.view))
                #expect(!bar.isHidden && abs(bar.frame.maxY - content.frame.maxY) < 0.5)
                content.contentOffset.y = max(0, content.contentSize.height - content.bounds.height)
                let last = try button("episode-\(downloadedIDs[0])")
                #expect(last.convert(last.bounds, to: bar.superview).maxY <= bar.frame.minY + 0.5)
                controller.changeFeedSelection("select_toggle")
                #expect(controller.feedSelection.active && controller.feedSelection.ids.isEmpty)
                try button("episodeBulk-addFavorite").sendActions(for: .touchUpInside)
                #expect(controller.feedSelection.active)
                controller.changeFeedSelection("select_toggle")
                try button("episodeBulk-addFavorite").sendActions(for: .touchUpInside)
                try await wait { try await store.episode(id: activeID)?.userState.isFavorite == true }
                await controller.reloadLibrary()?.value
                #expect(!controller.feedSelection.active)
                for id in expected { #expect(try await store.episode(id: id)?.userState.isFavorite == true) }
                for id in excludedIDs { #expect(try await store.episode(id: id)?.userState.isFavorite == false) }
                #expect(try await store.queue().count == 4)
                controller.startFeedSelection(downloadedIDs[1])
                try button("endEpisodeSelection").sendActions(for: .touchUpInside)
                #expect(!controller.feedSelection.active)
                #expect(try button("episode-action-\(downloadedIDs[0])").accessibilityLabel == Appearance.text("delete_label"))
                controller.startFeedSelection(activeID); controller.changeFeedSelection("select_toggle")
                try button("episodeBulk-delete").sendActions(for: .touchUpInside)
                try await wait { downloads.activeJob(source: "https://example.test/0-1.mp3") == nil && files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } }
                await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
                #expect(!controller.feedSelection.active)
                #expect(content.subviews.compactMap { $0 as? EpisodeRowView }.isEmpty)
                #expect(try await store.queue().count == 4)
                for id in expected { #expect(try await store.episode(id: id)?.userState.isFavorite == true) }
                for id in excludedIDs { #expect(try await store.episode(id: id) != nil) }
            }
            await downloads.stop(); try await playback.stop(); try await store.close()
        } catch { await downloads.stop(); try? await playback.stop(); try? await store.close(); throw error }
    }

    @Test func activeRowsSortGlobalSearchRefreshAndConfirmedDeletionUseRealOwners() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadsScreen-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let navigation = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
        var nav = navigation.value; nav.defaultPage = NavigationDestination.downloads.rawValue; try navigation.update(nav)
        let preferences = try DownloadPreferenceStore(file: root.appendingPathComponent("downloads.json"))
        let titles = ["Alpha", "Zulu", "Active", "Unplayed"]
        let sizes: [Int64] = [100, 500, 40, 250]
        let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Downloads fixture", episodes: titles.enumerated().map { i, title in
            .init(identifier: title, title: title, publicationDate: Date(timeIntervalSince1970: Double(i)),
                  media: .init(url: "https://example.test/\(i).mp3", size: sizes[i]))
        }), source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        let ids = Dictionary(uniqueKeysWithValues: feed.episodes.map { ($0.details.title!, $0.id) })
        var files: [String: URL] = [:]
        for title in ["Alpha", "Zulu", "Unplayed"] {
            let file = root.appendingPathComponent(title + ".mp3"); files[title] = file
            let media = try #require(Bundle(for: ViewTestBundleMarker.self).url(forResource: "playback-30sec", withExtension: "mp3"))
            try FileManager.default.copyItem(at: media, to: file)
            try await store.updateEpisode(id: ids[title]!) {
                $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path
                $0.details.media?.size = 120017
                $0.userState.playState = title == "Unplayed" ? .unplayed : .played
                $0.userState.isFavorite = title == "Zulu"
            }
        }
        _ = try await store.enqueue([ids["Alpha"]!, ids["Zulu"]!])
        let network = DownloadNetworkMonitor(startMonitoring: false)
        network.update(.init(connected: true, metered: true, cellular: true))
        let downloads = DownloadCoordinator(store: store, directory: root.appendingPathComponent("media"), network: network, preferences: { preferences.value })
        let playback = PlaybackCoordinator(store: store, engine: AVPlayerPlaybackEngine(muted: true))
        var requests: [FeedRefreshRequest] = []
        let refresh = ManualFeedRefreshCoordinator(store: store, execute: { request in _ = try await store.finishManualRefresh(id: request.id) })
        refresh.onChange = { state in if case .active(let request) = state { requests.append(request) } }
        let controller = LibraryViewController(library: store, startupError: nil, downloads: downloads, playback: playback,
            timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil, mobileNetworkPreferences: nil,
            usage: nil, manualRefresh: refresh, downloadPreferences: preferences,
            refreshNetwork: { .init(connected: true, metered: false, cellular: false) })
        do {
            _ = try await downloads.confirm(episodeID: ids["Active"]!, choice: .later)
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                controller.view.frame = host.view.bounds
                await controller.reloadLibrary()?.value; controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                @MainActor func tap(_ id: String, in view: UIView? = nil) throws {
                    controller.view.layoutIfNeeded()
                    let button: UIButton = try #require(find(id, in: view ?? controller.view), "Missing button \(id)"); button.sendActions(for: .touchUpInside)
                }
                let active: UIButton = try #require(find("episode-\(ids["Active"]!)", in: controller.view))
                let completed: UIButton = try #require(find("episode-\(ids["Unplayed"]!)", in: controller.view))
                #expect(active.convert(active.bounds, to: controller.view).minY < completed.convert(completed.bounds, to: controller.view).minY)
                let delete: UIButton = try #require(find("episode-action-\(ids["Alpha"]!)", in: controller.view))
                #expect(delete.accessibilityLabel == Appearance.text("delete_label"))
                try tap("downloadsMore"); try tap("downloadsSort")
                try await wait { controller.presentedViewController is FeedSortController && controller.presentedViewController?.isBeingPresented == false }
                let sort = try #require(controller.presentedViewController as? FeedSortController)
                #expect(sort.editor.fields == [.title, .duration, .date, .size])
                try tap("feedSort-size", in: sort.view)
                try await wait { preferences.value.listSortOrder == .sizeLargest }
                #expect(try DownloadPreferenceStore(file: root.appendingPathComponent("downloads.json")).value.listSortOrder == .sizeLargest)
                // The open list follows the chosen sort at once (newest first before: Unplayed, Zulu, Alpha).
                try tap("feedSort-title", in: sort.view)
                try await wait { preferences.value.listSortOrder == .titleAscending }
                sort.dismiss(animated: false); try await wait { controller.presentedViewController == nil }
                @MainActor func rowTop(_ title: String) throws -> CGFloat {
                    controller.view.layoutIfNeeded()
                    let row: UIButton = try #require(find("episode-\(ids[title]!)", in: controller.view))
                    return row.convert(row.bounds, to: controller.view).minY
                }
                let (alpha, unplayed, zulu) = (try rowTop("Alpha"), try rowTop("Unplayed"), try rowTop("Zulu"))
                #expect(alpha < unplayed && unplayed < zulu)
                try tap("downloadsSearch")
                let field: UITextField = try #require(find("librarySearchQuery", in: controller.view))
                #expect(find("searchFeedScopeChip", in: controller.view, as: UIView.self)?.isHidden != false)
                field.text = "Alpha"; field.sendActions(for: .editingChanged)
                _ = field.delegate?.textFieldShouldReturn?(field)
                try await wait { find("episode-\(ids["Alpha"]!)", in: controller.view, as: UIButton.self) != nil }
                try tap("toolbarBack")
                try tap("downloadsMore"); try tap("downloadsRefresh")
                try await wait { !requests.isEmpty }
                #expect(requests[0].feedID == nil)
                try tap("downloadsMore"); try tap("downloadsDeletePlayed")
                try await wait { controller.presentedViewController is SourceMessageController && controller.presentedViewController?.isBeingPresented == false }
                try tap("downloadsDeletePlayedCancel", in: controller.presentedViewController!.view)
                try await wait { controller.presentedViewController == nil }
                #expect(files.values.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
                try tap("downloadsMore"); try tap("downloadsDeletePlayed")
                try await wait { controller.presentedViewController is SourceMessageController && controller.presentedViewController?.isBeingPresented == false }
                try tap("downloadsDeletePlayedConfirm", in: controller.presentedViewController!.view)
                try await wait { try await store.episode(id: ids["Alpha"]!)?.userState.isDownloaded == false }
                try await wait { try await store.episode(id: ids["Zulu"]!)?.userState.isDownloaded == false }
                try await wait { !FileManager.default.fileExists(atPath: files["Alpha"]!.path) && !FileManager.default.fileExists(atPath: files["Zulu"]!.path) }
                #expect(!FileManager.default.fileExists(atPath: files["Alpha"]!.path))
                #expect(!FileManager.default.fileExists(atPath: files["Zulu"]!.path))
                #expect(FileManager.default.fileExists(atPath: files["Unplayed"]!.path))
                #expect(try await store.queue().map(\.id).contains(ids["Zulu"]!) == true)
                #expect(downloads.activeJob(source: "https://example.test/2.mp3") != nil)
            }
            refresh.suspend(); await downloads.stop(); try await playback.stop(); try await store.close()
        } catch { refresh.suspend(); await downloads.stop(); try? await playback.stop(); try? await store.close(); throw error }
    }

    /// Rows refresh their download button on every playback/download tick; the ring repaints only when
    /// its drawing changes.
    @Test func downloadRingRepaintsOnlyWhenItsDrawingChanges() {
        let ring = DownloadRingView()
        ring.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        ring.update(0.4, indeterminate: false, animated: false)
        ring.layer.displayIfNeeded()
        ring.update(0.4, indeterminate: false); ring.drawsIdleCircle = true; ring.strokeColor = nil
        #expect(!ring.layer.needsDisplay())
        ring.update(0.4, indeterminate: true)
        #expect(ring.layer.needsDisplay())
        ring.layer.displayIfNeeded()
        ring.update(0.6, indeterminate: true, animated: false)
        #expect(ring.layer.needsDisplay())
        ring.layer.displayIfNeeded()
        ring.drawsIdleCircle = false
        #expect(ring.layer.needsDisplay())
    }
}

private final class ViewTestBundleMarker: NSObject {
}
