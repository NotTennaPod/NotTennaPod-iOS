import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor
@Suite(.serialized)
struct SharedDownloadCancellationViewTests {
    private func element<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let result = view as? T, result.accessibilityIdentifier == id { return result }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: T.self) }.first
    }
    private func wait(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await condition())
    }

    @Test(arguments: [false, true])
    func cancelFromTheOtherEpisodesRowOrDetailsStopsSharedWorkAndUpdatesBothControls(details: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SharedDownloadUI-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let network = DownloadNetworkMonitor(startMonitoring: false)
        network.update(.init(connected: true, metered: true, cellular: true))
        let downloads = DownloadCoordinator(store: store, directory: root.appendingPathComponent("media"), network: network)
        do {
            let url = URL(string: "https://example.invalid/shared-feed")!
            let media = "https://example.invalid/shared.mp3"
            _ = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Shared media", episodes: (1...2).map {
                .init(identifier: "\($0)", title: "Episode \($0)", description: "Notes", media: .init(url: media, size: 100))
            }), source: url.absoluteString, responseURL: url, validator: nil, permanentRedirectURL: nil))
            _ = try await store.enqueue([2])
            _ = try await downloads.confirm(episodeID: 1, choice: .later)
            let job = try #require(downloads.activeJob(source: media))
            let navigation = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
            var preferences = navigation.value; preferences.defaultPage = "remember"; preferences.lastPage = "1"
            try navigation.update(preferences)
            let controller = LibraryViewController(library: store, startupError: nil, downloads: downloads, playback: nil,
                timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil,
                mobileNetworkPreferences: nil, usage: nil)
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
            window.rootViewController = controller; window.makeKeyAndVisible()
            defer { closeTestWindow(window, restoringKey: previous) }
            await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
            for id in [1, 2] {
                let button: UIControl = try #require(element("episode-action-\(id)", in: controller.view))
                #expect(button.accessibilityLabel == Appearance.text("cancel_download_label"))
            }
            let actionID: String
            if details {
                let open: UIButton = try #require(element("episode-2", in: controller.view))
                open.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
                actionID = "episodeSecondaryAction"
            } else { actionID = "episode-action-2" }
            let cancel: UIButton = try #require(element(actionID, in: controller.view))
            // The detail control has a native title; the icon-only row has an explicit spoken label.
            #expect((details ? cancel.currentTitle : cancel.accessibilityLabel) == Appearance.text("cancel_download_label"))
            let frame = cancel.convert(cancel.bounds, to: window)
            #expect(window.bounds.contains(frame))
            #expect(window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil) === cancel)
            cancel.sendActions(for: .touchUpInside)
            try await wait { downloads.activeJob(source: media) == nil }
            try await wait {
                guard let button = element(actionID, in: controller.view, as: UIButton.self) else { return false }
                return (details ? button.currentTitle : button.accessibilityLabel) == Appearance.text("download_label")
            }
            #expect(controller.presentedViewController == nil)
            #expect(try await store.downloadJob(id: job.id)?.state == .cancelled)
            #expect(try await store.queue().map(\.id) == [1])
            #expect(try await store.episode(id: 1)?.userState.autoDownloadEnabled == true)
            #expect(try await store.episode(id: 2)?.userState.autoDownloadEnabled == false)
            if details {
                let back: UIButton = try #require(element("toolbarBack", in: controller.view))
                back.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
            }
            for id in [1, 2] {
                try await wait { element("episode-action-\(id)", in: controller.view, as: UIControl.self)?.accessibilityLabel == Appearance.text("download_label") }
            }
            await downloads.stop(); try await store.close()
        } catch { await downloads.stop(); try? await store.close(); throw error }
    }
}
