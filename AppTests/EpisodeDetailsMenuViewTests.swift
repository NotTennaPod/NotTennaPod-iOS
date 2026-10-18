import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor private final class EpisodeMenuEngine: PlaybackEngine {
    var reading: PlaybackEngineReading?
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    private var generation: UUID?
    private var command: UUID?
    private var position: Int64 = 0
    private var playing = false
    func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
        self.generation = generation; command = generation; position = positionMilliseconds
    }
    func play(commandID: UUID) { command = commandID; playing = true; update() }
    func pause(commandID: UUID) { command = commandID; playing = false; update() }
    func seek(to positionMilliseconds: Int64, commandID: UUID) { command = commandID; position = positionMilliseconds; update() }
    func setSpeed(_ speed: Float, commandID: UUID) throws { command = commandID; update() }
    func unload() { reading = nil; generation = nil; command = nil; playing = false }
    private func update() {
        guard reading != nil, let generation, let command else { return }
        reading = .init(generation: generation, commandID: command,
            sample: .init(positionMilliseconds: Int32(position), durationMilliseconds: 120_000, status: playing ? .playing : .paused))
    }
    func ready() {
        guard let generation, let command else { return }
        reading = .init(generation: generation, commandID: command,
            sample: .init(positionMilliseconds: Int32(position), durationMilliseconds: 120_000, status: playing ? .playing : .paused))
        onEvent?(.ready(reading!))
    }
}

@MainActor @Suite(.serialized)
struct EpisodeDetailsMenuViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(id, in: $0) as T? }.first
    }
    private func wait(sourceLocation: SourceLocation = #_sourceLocation,
                      _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while try await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await condition(), sourceLocation: sourceLocation)
    }
    private func tap(_ id: String, in view: UIView) throws {
        let control: UIControl = try #require(find(id, in: view))
        control.sendActions(for: .touchUpInside)
    }
    private func menu(_ controller: LibraryViewController) async throws -> UIScrollView {
        // Synthetic control dispatch must follow the pending mini-player layout,
        // just as a real touch does after UIKit lays out the visible controls.
        controller.view.layoutIfNeeded()
        try tap("episodeMore", in: controller.view)
        try await wait { (find("episodeMenuPanel", in: controller.view) as UIScrollView?) != nil }
        return try #require(find("episodeMenuPanel", in: controller.view))
    }
    private func silentWave() -> Data {
        // A complete 120-second, 8 kHz mono PCM file without artwork chunks.
        // Artwork inspection must see normal media, not malformed placeholder bytes.
        let sampleRate: UInt32 = 8_000
        let byteCount = sampleRate * 120 * 2
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8)); word(UInt32(36) + byteCount)
        data.append(Data("WAVEfmt ".utf8)); word(UInt32(16))
        word(UInt16(1)); word(UInt16(1)); word(sampleRate); word(sampleRate * 2)
        word(UInt16(2)); word(UInt16(16))
        data.append(Data("data".utf8)); word(byteCount)
        data.append(Data(count: Int(byteCount)))
        return data
    }
    private func fixture(local: Bool = false, media: Bool = true, autoDelete: Bool = false,
                         position: Int32 = 12_345,
                         _ body: @MainActor (LibraryViewController, FeedLibraryStore, LibraryFeed, PlaybackCoordinator, EpisodeMenuEngine, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EpisodeMenu-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let network = DownloadNetworkMonitor(startMonitoring: false)
        network.update(.init(connected: false, metered: false, cellular: false))
        var preferences = DownloadPreferences(); preferences.autoDelete = autoDelete
        let capturedPreferences = preferences
        let downloads = DownloadCoordinator(store: store, directory: root.appendingPathComponent("media"),
            network: network, preferences: { capturedPreferences })
        let engine = EpisodeMenuEngine()
        let playback = PlaybackCoordinator(store: store, engine: engine)
        do {
            let bytes = silentWave()
            let source = URL(string: "https://example.invalid/feed")!
            let inserted = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Menu podcast", episodes: (1...3).map {
                .init(identifier: "\($0)", title: "Menu episode \($0)", description: "Notes", link: "https://example.invalid/episode/\($0)",
                    media: media ? .init(url: "https://example.invalid/\($0).wav", size: Int64(bytes.count),
                        mimeType: "audio/wav", durationMilliseconds: 120_000) : nil)
            }), source: local ? "antennapod_local:menu" : source.absoluteString, responseURL: source,
                validator: nil, permanentRedirectURL: nil))
            let id = inserted.episodes[0].id
            let file = root.appendingPathComponent("episode.wav")
            try bytes.write(to: file)
            let metadata = try LocalMediaMetadataReader.read(url: file)
            try #require(metadata.durationMilliseconds == 120_000)
            try #require(metadata.embeddedArtwork == nil)
            try await store.updateEpisode(id: id) {
                $0.userState.playState = .new; $0.userState.positionMilliseconds = position
                $0.userState.isFavorite = true
                $0.userState.isDownloaded = media; $0.userState.localFileURL = media ? file.path : nil
            }
            let feed = try #require(await store.feed(id: inserted.id))
            let navigation = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
            var settings = navigation.value; settings.defaultPage = "remember"; settings.lastPage = "\(feed.id)"
            try navigation.update(settings)
            let controller = LibraryViewController(library: store, startupError: nil, downloads: downloads, playback: playback,
                timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                controller.view.frame = host.view.bounds
                defer {
                    controller.dismiss(animated: false); controller.willMove(toParent: nil)
                    controller.view.removeFromSuperview(); controller.removeFromParent()
                }
                await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
                try tap("episode-\(id)", in: controller.view); controller.view.layoutIfNeeded()
                if media && !local {
                    // The header asynchronously records its initial artwork lookup.
                    // Await that independent discovery before action-state baselines.
                    try await wait { try await store.episode(id: id)?.details.media?.hasEmbeddedPicture == false }
                }
                try await body(controller, store, feed, playback, engine, root)
            }
            try await playback.stop(); await downloads.stop(); try await store.close()
        } catch { try? await playback.stop(); await downloads.stop(); try? await store.close(); throw error }
    }

    /// Toolbar and overflow popup composition a person would notice: Back leads, More trails,
    /// the bar stays inside the safe area, and the popup opens at More without leaving the safe area.
    private func assertToolbarComposition(_ controller: LibraryViewController, panel: UIScrollView, rightToLeft: Bool) throws {
        let toolbar: UIView = try #require(find("mainToolbar", in: controller.view))
        let more: UIButton = try #require(find("episodeMore", in: toolbar))
        let back: UIButton = try #require(find("toolbarBack", in: toolbar))
        let overlay = try #require(panel.superview)
        let expectedDirection: UIUserInterfaceLayoutDirection = rightToLeft ? .rightToLeft : .leftToRight
        #expect(more.effectiveUserInterfaceLayoutDirection == expectedDirection)
        #expect(back.effectiveUserInterfaceLayoutDirection == expectedDirection)
        #expect(rightToLeft ? more.frame.maxX < back.frame.minX : more.frame.minX > back.frame.maxX, "Back leads, More trails")
        #expect(toolbar.bounds.insetBy(dx: -1, dy: -1).contains(more.frame) && toolbar.bounds.insetBy(dx: -1, dy: -1).contains(back.frame))
        #expect(more.bounds.width >= 40 && more.bounds.height >= 44, "More is a usable touch target")
        let safe = controller.view.safeAreaLayoutGuide.layoutFrame
        let bar = toolbar.convert(toolbar.bounds, to: controller.view)
        #expect(bar.minX >= safe.minX - 1 && bar.maxX <= safe.maxX + 1, "Toolbar stays inside the safe area")
        let shell = panel.convert(panel.bounds, to: controller.view)
        #expect(shell.minX >= safe.minX - 1 && shell.maxX <= safe.maxX + 1, "Popup stays inside the safe area")
        let button = more.convert(more.bounds, to: overlay)
        let popupEdge = rightToLeft ? panel.frame.minX : panel.frame.maxX
        let buttonEdge = rightToLeft ? button.minX : button.maxX
        #expect(abs(popupEdge - buttonEdge) <= 12 || (rightToLeft ? panel.frame.minX <= 1 : panel.frame.maxX >= overlay.bounds.maxX - 1),
                "Popup opens at the More button")
        if let website: UIButton = find("episodeWebsite", in: toolbar) {
            #expect(rightToLeft ? website.frame.minX >= more.frame.maxX - 0.5 : website.frame.maxX <= more.frame.minX + 0.5, "Website sits just before More")
        }
    }

    @Test(arguments: [false, true])
    func toolbarSourceInsetsFollowResizingAndAsymmetricSafeAreas(rightToLeft: Bool) async throws {
        try await fixture { controller, _, _, _, _, _ in
            controller.traitOverrides.layoutDirection = rightToLeft ? .rightToLeft : .leftToRight
            controller.view.updateTraitsIfNeeded()
            let originalFrame = controller.view.frame
            let originalInsets = controller.additionalSafeAreaInsets
            defer { controller.view.frame = originalFrame; controller.additionalSafeAreaInsets = originalInsets }
            // Literal source qualifier boundaries, including resize back below
            // sw600 and safe-area changes without a window-size change.
            let cases: [(CGSize, UIEdgeInsets)] = [
                (.init(width: 320, height: 900), .zero),
                (.init(width: 600, height: 900), .zero),
                (.init(width: 834, height: 1100), .init(top: 0, left: 47, bottom: 0, right: 13)),
                (.init(width: 834, height: 1100), .init(top: 0, left: 13, bottom: 0, right: 47)),
                (.init(width: 900, height: 599), .zero),
                (.init(width: 320, height: 900), .zero)
            ]
            for (size, insets) in cases {
                controller.view.frame.size = size
                controller.additionalSafeAreaInsets = insets
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                let panel = try await menu(controller)
                try assertToolbarComposition(controller, panel: panel, rightToLeft: rightToLeft)
                for row in panel.subviews.compactMap({ $0 as? UIButton }) {
                    #expect(row.effectiveUserInterfaceLayoutDirection == (rightToLeft ? .rightToLeft : .leftToRight))
                    #expect(row.effectiveContentHorizontalAlignment == (rightToLeft ? .right : .left))
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func popupOverlapsActualOverflowAndRendersElevation(rightToLeft: Bool) async throws {
        try await fixture { controller, store, feed, _, _, _ in
            // Match the Android capture's six-row source state: new, unqueued, unselected,
            // undownloaded remote media, zero position and no favorite.
            try await store.updateEpisode(id: feed.episodes[0].id) {
                $0.userState.positionMilliseconds = 0
                $0.userState.isFavorite = false
                $0.userState.isDownloaded = false
                $0.userState.localFileURL = nil
            }
            // Direction must be a trait inherited by newly created row controls.
            // A semantic override on only the root view affects its immediate
            // content and does not establish RTL throughout the subtree.
            controller.traitOverrides.layoutDirection = rightToLeft ? .rightToLeft : .leftToRight
            controller.view.overrideUserInterfaceStyle = .light
            controller.view.updateTraitsIfNeeded()
            // Set direction before rendering the toolbar's explicit frames: the screen opens again (a reload that only
            // follows the library's changes patches it in place).
            await controller.reloadLibrary(reopen: true)?.value
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            let panel = try await menu(controller)
            #expect(panel.subviews.compactMap { ($0 as? UIButton)?.accessibilityIdentifier }
                == ["removeFromInbox", "markPlayed", "addToQueue", "openPodcast", "addFavorite", "share"])
            let overlay = try #require(panel.superview)
            let anchor: UIButton = try #require(find("episodeMore", in: controller.view))
            let button = anchor.convert(anchor.bounds, to: overlay)
            try assertToolbarComposition(controller, panel: panel, rightToLeft: rightToLeft)
            let expectedDirection: UIUserInterfaceLayoutDirection = rightToLeft ? .rightToLeft : .leftToRight
            let expectedAlignment: UIControl.ContentHorizontalAlignment = rightToLeft ? .right : .left
            panel.layoutIfNeeded()
            var titleEdges: [CGFloat] = []
            for row in panel.subviews.compactMap({ $0 as? UIButton }) {
                row.layoutIfNeeded()
                #expect(row.effectiveUserInterfaceLayoutDirection == expectedDirection)
                #expect(row.effectiveContentHorizontalAlignment == expectedAlignment)
                let label = try #require(row.titleLabel)
                try #require(label.window != nil && !label.isHidden && label.alpha > 0)
                let labelRect = label.convert(label.bounds, to: panel)
                try #require(labelRect.width > 0 && labelRect.height > 0)
                #expect(labelRect.minX >= panel.bounds.minX - 0.5 && labelRect.maxX <= panel.bounds.maxX + 0.5, "Row title is not clipped horizontally")
                titleEdges.append(rightToLeft ? labelRect.maxX : labelRect.minX)
            }
            // Titles share one leading edge near the popup's leading side.
            #expect((titleEdges.max() ?? 0) - (titleEdges.min() ?? 0) < 1)
            let leadingGap = rightToLeft ? panel.bounds.maxX - (titleEdges.first ?? 0) : (titleEdges.first ?? 0) - panel.bounds.minX
            #expect(leadingGap > 0 && leadingGap < 32)
            // The source overflow sits on the trailing side (right in LTR, left in RTL).
            #expect(rightToLeft ? button.maxX < overlay.bounds.midX : button.minX > overlay.bounds.midX)
            // The popup opens over the More button (its top aligns with the button's top).
            #expect(abs(panel.frame.minY - button.minY) < 2)
            #expect(panel.clipsToBounds)
            let shadow: UIView = try #require(find("episodeMenuShadow", in: overlay))
            #expect(shadow.frame == panel.frame && !shadow.isHidden)
            #expect(!shadow.clipsToBounds && !shadow.isUserInteractionEnabled, "Elevation is drawn outside the clipped panel and never blocks touches")
        }
    }

    @Test(arguments: [false, true])
    func pausedSelectionOffersSkipAndStaleMenuCannotSkipReplacement(stale: Bool) async throws {
        try await fixture { controller, store, feed, playback, engine, _ in
            let ids = feed.episodes.map(\.id)
            _ = try await store.enqueue([ids[0], ids[2], ids[1]])
            try await playback.select(episodeID: ids[0]); engine.ready()
            try await wait { playback.phase == .playing }
            try await playback.pause()
            #expect(playback.phase == .paused)
            await controller.reloadLibrary()?.value
            let panel = try await menu(controller)
            let actions = panel.subviews.compactMap { ($0 as? UIButton)?.accessibilityIdentifier }
            #expect(actions == ["skip", "markPlayed", "removeFromQueue", "resetPosition", "openPodcast", "removeFavorite", "share"])
            let skip: UIButton = try #require(find("skip", in: panel))
            #expect(skip.currentTitle == "Skip episode")
            let before = try #require(await store.episode(id: ids[0]))
            if stale {
                try await playback.select(episodeID: ids[1]); engine.ready()
                try await wait { playback.episode?.id == ids[1] && playback.phase == .playing }
            }
            skip.sendActions(for: .touchUpInside)
            try await wait { (find("episodeMenuPanel", in: controller.view) as UIScrollView?) == nil }
            if stale {
                // Let the action task drain through the main actor before observing.
                await controller.reloadLibrary()?.value
                #expect(playback.episode?.id == ids[1])
                #expect(try await store.queue().map(\.id) == [ids[0], ids[2], ids[1]])
            } else {
                try await wait { playback.episode?.id == ids[2] }
                let after = try #require(await store.episode(id: ids[0]))
                #expect(after.userState.playState == before.userState.playState)
                #expect(after.userState.positionMilliseconds == before.userState.positionMilliseconds)
                #expect(after.userState.isDownloaded && after.userState.isFavorite)
                #expect(try await store.queue().map(\.id) == [ids[0], ids[2], ids[1]])
                #expect(playback.wantsPlayback)
            }
        }
    }

    @Test(arguments: ["eligible", "disabled", "beforeBoundary", "localDisabled"])
    func inboxRemovalPreservesPositionAndPersistsWithoutUndoOrPlayedSync(scenario: String) async throws {
        let position: Int32 = scenario == "beforeBoundary" ? 89_999 : 90_000
        try await fixture(local: scenario == "localDisabled", autoDelete: scenario != "disabled", position: position) { controller, store, feed, _, _, root in
            let id = feed.episodes[0].id
            try await store.selectSynchronizationAccount(UUID())
            let before = try #require(await store.episode(id: id))
            let effects = try await store.pendingEffects()
            let panel = try await menu(controller)
            let remove: UIButton = try #require(find("removeFromInbox", in: panel))
            #expect(remove.currentTitle == "Remove from inbox")
            remove.sendActions(for: .touchUpInside)
            try await wait { try await store.episode(id: id)?.userState.playState == .unplayed }
            var expected = before; expected.userState.playState = .unplayed
            let observed = try await store.episode(id: id)
            #expect(observed == expected)
            #expect(try await store.pendingEffects() == effects)
            #expect(try await store.synchronizationQueue().isEmpty)
            #expect((find("episodeActionSnackbar", in: controller.view) as UIView?) == nil)
            #expect(controller.presentedViewController == nil)
            let reopened = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
            let persisted = try await reopened.episode(id: id)
            #expect(persisted == expected)
            try await reopened.close()
            let refreshed = try await menu(controller)
            #expect((find("removeFromInbox", in: refreshed) as UIButton?) == nil)
            // Source waits two seconds; even with nondefault deletion enabled the
            // media survives the immediate state write. Favorite protection does
            // not apply to this particular source handler.
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("episode.wav").path))
            if scenario == "eligible" {
                try await wait {
                    try await store.episode(id: id)?.userState.isDownloaded == false
                        && !FileManager.default.fileExists(atPath: root.appendingPathComponent("episode.wav").path)
                }
                #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("episode.wav").path))
                #expect(try await store.episode(id: id)?.userState.isFavorite == true)
                #expect(try await store.episode(id: id)?.userState.positionMilliseconds == position)
            } else {
                // Cross the production callback boundary before asserting its negative result.
                try await Task.sleep(for: .milliseconds(2200))
                let afterDelay = try await store.episode(id: id)
                #expect(afterDelay == expected)
                #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("episode.wav").path))
            }
        }
    }

    @Test(arguments: [false, true])
    func textEpisodeKeepsInboxActionAndLocalFeedsSuppressShare(local: Bool) async throws {
        try await fixture(local: local, media: false) { controller, _, _, _, _, _ in
            let panel = try await menu(controller)
            #expect(panel.subviews.compactMap { ($0 as? UIButton)?.accessibilityIdentifier }
                == (local ? ["removeFromInbox", "openPodcast", "removeFavorite"]
                          : ["removeFromInbox", "openPodcast", "removeFavorite", "share"]))
        }
    }

    @Test func shareCancelRetainsDetailsAndPositionChoiceSurvivesReopening() async throws {
        let old = UserDefaults.standard.object(forKey: "shareEpisodeStartAt")
        defer { UserDefaults.standard.set(old, forKey: "shareEpisodeStartAt") }
        UserDefaults.standard.set(false, forKey: "shareEpisodeStartAt")
        try await fixture { controller, store, feed, _, _, _ in
            let original = try #require(await store.episode(id: feed.episodes[0].id))
            _ = try await menu(controller); try tap("share", in: controller.view)
            try await wait { controller.presentedViewController is EpisodeShareController && controller.presentedViewController?.isBeingPresented == false }
            var sheet = try #require(controller.presentedViewController)
            let position: UIButton = try #require(find("episodeSharePosition", in: sheet.view))
            #expect(position.accessibilityValue == "Not checked")
            position.sendActions(for: .touchUpInside)
            let social: UIButton = try #require(find("episodeShareSocial", in: sheet.view))
            #expect(social.accessibilityValue?.contains("Starting from: 00:00:12") == true)
            try await store.updateEpisode(id: original.id) { $0.userState.positionMilliseconds = 23_456 }
            #expect(social.accessibilityValue?.contains("#t=12") == true)
            #expect(sheet.accessibilityPerformEscape())
            try await wait { controller.presentedViewController == nil }
            #expect((find("episodeMore", in: controller.view) as UIButton?) != nil)
            _ = try await menu(controller); try tap("share", in: controller.view)
            try await wait { controller.presentedViewController is EpisodeShareController && controller.presentedViewController?.isBeingPresented == false }
            sheet = try #require(controller.presentedViewController)
            let retained: UIButton = try #require(find("episodeSharePosition", in: sheet.view))
            #expect(retained.accessibilityValue == "Checked")
            let fresh: UIButton = try #require(find("episodeShareSocial", in: sheet.view))
            #expect(fresh.accessibilityValue?.contains("#t=23") == true)
            #expect(try await store.episode(id: original.id)?.userState.playState == .new)
            #expect(sheet.accessibilityPerformEscape())
            try await wait { controller.presentedViewController == nil }
            #expect((find("episodeMore", in: controller.view) as UIButton?) != nil)
        }
    }

    @Test func mediaAddressSharePreservesEpisodeAndReturnsToDetailsAfterSystemReadiness() async throws {
        // The first system share sheet can take a long time to start on a cold Simulator.
        // Leave room inside the suite's one-minute limit for dismissal and teardown.
        let readinessDeadline = ContinuousClock.now + .seconds(45)
        let old = UserDefaults.standard.object(forKey: "shareEpisodeStartAt")
        defer { UserDefaults.standard.set(old, forKey: "shareEpisodeStartAt") }
        UserDefaults.standard.set(false, forKey: "shareEpisodeStartAt")
        try await fixture { controller, store, feed, _, _, _ in
            let original = try #require(await store.episode(id: feed.episodes[0].id))
            _ = try await menu(controller); try tap("share", in: controller.view)
            try await wait { controller.presentedViewController is EpisodeShareController && controller.presentedViewController?.isBeingPresented == false }
            let sheet = try #require(controller.presentedViewController)
            try tap("episodeShareMediaAddress", in: sheet.view)
            while ContinuousClock.now < readinessDeadline,
                  !(controller.presentedViewController is UIActivityViewController && controller.presentedViewController?.isBeingPresented == false) {
                try await Task.sleep(for: .milliseconds(10))
            }
            let activity = try #require(controller.presentedViewController as? UIActivityViewController,
                "System Share did not appear after choosing the media address")
            #expect(activity.popoverPresentationController?.sourceView?.window != nil, "Share sheet is anchored to a visible view")
            #expect(try await store.episode(id: original.id)?.userState.playState == .new, "Sharing does not change the episode")
            activity.dismiss(animated: false)
            try await wait { controller.presentedViewController == nil }
            #expect((find("episodeMore", in: controller.view) as UIButton?) != nil, "Episode details remain after sharing")
        }
    }
}
