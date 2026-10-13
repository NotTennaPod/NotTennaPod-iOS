import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

private final class KeepSkippedEpisodesTestBundle {}

@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct KeepSkippedEpisodesPreferenceViewTests {
    private func row(_ id: String, in view: UIView) throws -> UIControl {
        try #require(view.subviews.compactMap { $0 as? UIControl }.first { $0.accessibilityIdentifier == id })
    }
    private func settings(_ store: PlaybackQueuePreferenceStore, width: CGFloat = 402) -> NavigationSettingsView {
        NavigationSettingsView(navigation: nil, timeDisplay: nil, page: .playback,
            width: width, playbackQueue: store)
    }
    private func wait(_ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while try await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await condition())
    }

    private func expectRenderedLeadingAlignment(_ label: UILabel, rtl: Bool) throws {
        // UILabel can carry an attributed paragraph style independently of its
        // textAlignment property. Inspect the glyphs drawn by the actual label.
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = false
        let image = UIGraphicsImageRenderer(size: label.bounds.size, format: format).image { _ in
            label.drawText(in: label.bounds)
        }
        let cg = try #require(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try #require(CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        var columns = [Int]()
        for x in 0..<cg.width where (0..<cg.height).contains(where: { bytes[($0 * cg.width + x) * 4 + 3] > 32 }) {
            columns.append(x)
        }
        let left = CGFloat(try #require(columns.first)) / format.scale
        let right = label.bounds.width - CGFloat(try #require(columns.last) + 1) / format.scale
        // Allow glyph side bearings, while distinguishing a wrong edge or centered text.
        #expect(rtl ? right <= 3 && left > 24 : left <= 3 && right > 24)
    }

    @Test(arguments: [CGFloat(320), 402, 768])
    func settingPreservesSourceOrderWordingAndPersistsBothDirections(width: CGFloat) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeepSkippedView-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("queue.json")
        let store = try PlaybackQueuePreferenceStore(file: file)
        var initial = store.value; initial.followQueue = false; try store.update(initial)
        let view = settings(store, width: width)
        let keep = try row("prefSkipKeepsEpisode", in: view)
        let smart = try row("prefSmartMarkAsPlayedSecs", in: view)
        #expect(keep.accessibilityLabel == "Keep skipped episodes")
        #expect(keep.accessibilityHint == "Keep episodes when they are skipped")
        #expect(keep.accessibilityValue == "On" && keep.isEnabled)
        #expect(abs(keep.frame.minY - smart.frame.maxY) < 0.5, "Directly after Smart mark as played")
        let indicator = try #require(keep.subviews.compactMap { $0 as? PreferenceSwitchView }.first)
        let trailing = width - indicator.frame.maxX
        #expect(indicator.isOn && trailing > 0 && trailing <= 32, "Switch at the trailing edge")
        for label in keep.subviews.compactMap({ $0 as? UILabel }) {
            #expect(label.frame.minX > 0 && label.frame.minX <= 32 && label.frame.maxX <= indicator.frame.minX, "Text leads and never runs under the switch")
            #expect(label.frame.minY >= 0 && label.frame.maxY <= keep.bounds.height)
        }
        keep.sendActions(for: .touchUpInside)
        #expect(!store.value.skipKeepsEpisode && !store.value.followQueue)
        #expect(keep.accessibilityValue == "Off" && !indicator.isOn)
        let reopened = try PlaybackQueuePreferenceStore(file: file)
        let restoredView = settings(reopened, width: width)
        try withExtendedLifetime(restoredView) {
            let restored = try row("prefSkipKeepsEpisode", in: restoredView)
            #expect(restored.accessibilityValue == "Off")
            restored.sendActions(for: .touchUpInside)
            #expect(restored.accessibilityValue == "On")
            #expect(try PlaybackQueuePreferenceStore(file: file).value.skipKeepsEpisode)
            #expect(!reopened.value.followQueue)
        }
    }

    /// Rows keep their composition (text leading, switch trailing, mirrored in RTL) and state across
    /// phone, landscape and tablet window sizes.
    @Test(arguments: [false, true])
    func playbackLayoutFollowsLocalWindowSmallestDimensionAndPreservesControls(rtl: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("KeepSkippedResize-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = try PlaybackQueuePreferenceStore(file: file)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let container = UIView(frame: window.bounds)
        container.traitOverrides.layoutDirection = rtl ? .rightToLeft : .leftToRight
        window.addSubview(container)
        let view = settings(store)
        container.addSubview(view)
        defer { view.removeFromSuperview(); container.removeFromSuperview() }
        let expectedDirection: UIUserInterfaceLayoutDirection = rtl ? .rightToLeft : .leftToRight
        try await wait {
            container.updateTraitsIfNeeded(); view.updateTraitsIfNeeded()
            return view.effectiveUserInterfaceLayoutDirection == expectedDirection
                && view.subviews.allSatisfy { control in
                    control.updateTraitsIfNeeded()
                    return control.effectiveUserInterfaceLayoutDirection == expectedDirection
                        && control.subviews.allSatisfy {
                            $0.updateTraitsIfNeeded()
                            return $0.effectiveUserInterfaceLayoutDirection == expectedDirection
                        }
                }
        }
        let keep = try row("prefSkipKeepsEpisode", in: view)
        let indicator = try #require(keep.subviews.compactMap { $0 as? PreferenceSwitchView }.first)
        keep.sendActions(for: .touchUpInside)
        let originalRows = view.subviews.compactMap { $0 as? UIControl }
        let cases: [CGSize] = [
            CGSize(width: 402, height: 874), CGSize(width: 874, height: 402), CGSize(width: 600, height: 800),
            CGSize(width: 800, height: 600), CGSize(width: 800, height: 1280), CGSize(width: 320, height: 800),
            CGSize(width: 402, height: 874)
        ]
        var initialHeight: CGFloat?
        for size in cases {
            window.frame.size = size; container.frame = window.bounds
            view.frame.size.width = size.width
            view.setNeedsLayout(); view.layoutIfNeeded()
            #expect(view.window === window)
            #expect(window.bounds.size == size)
            #expect(view.effectiveUserInterfaceLayoutDirection == expectedDirection)
            #expect(try row("prefSkipKeepsEpisode", in: view) === keep)
            #expect(keep.subviews.compactMap { $0 as? PreferenceSwitchView }.first === indicator)
            #expect(!indicator.isOn && keep.accessibilityValue == "Off" && keep.isEnabled)
            #expect(!store.value.skipKeepsEpisode && store.value.followQueue)
            let rows = view.subviews.compactMap { $0 as? UIControl }
            #expect(rows.count == originalRows.count)
            var bottom: CGFloat = 0
            for (index, control) in rows.enumerated() {
                #expect(control === originalRows[index])
                #expect(control.effectiveUserInterfaceLayoutDirection == expectedDirection)
                // Rows stack without gaps or overlap across the full width.
                #expect(abs(control.frame.minY - bottom) < 0.5 && abs(control.bounds.width - size.width) < 0.5)
                let toggle = control.subviews.compactMap { $0 as? PreferenceSwitchView }.first
                if let toggle {
                    // Switch: visible, vertically centred, at the trailing edge (left in RTL).
                    #expect(toggle.effectiveUserInterfaceLayoutDirection == expectedDirection)
                    #expect(toggle.bounds.width > 0 && toggle.bounds.height > 0)
                    #expect(abs(toggle.center.y - control.bounds.midY) < 1)
                    let margin = rtl ? toggle.frame.minX : size.width - toggle.frame.maxX
                    #expect(margin > 0 && margin <= 32)
                }
                for label in control.subviews.compactMap({ $0 as? UILabel }) {
                    #expect(label.effectiveUserInterfaceLayoutDirection == expectedDirection)
                    #expect(label.textAlignment == (rtl ? .right : .left))
                    #expect(label.frame.minY >= 0 && label.frame.maxY <= control.bounds.height)
                    // Text at the leading edge, never under the switch.
                    let margin = rtl ? size.width - label.frame.maxX : label.frame.minX
                    #expect(margin > 0 && margin <= 32)
                    if let toggle { #expect(rtl ? label.frame.minX >= toggle.frame.maxX : label.frame.maxX <= toggle.frame.minX) }
                }
                bottom = control.frame.maxY
            }
            #expect(view.bounds.height >= bottom && view.bounds.height - bottom <= 32)
            if size == CGSize(width: 800, height: 1280) {
                for label in keep.subviews.compactMap({ $0 as? UILabel }) {
                    try expectRenderedLeadingAlignment(label, rtl: rtl)
                }
            }
            if size == cases[0] {
                if let initialHeight { #expect(view.bounds.height == initialHeight) }
                else { initialHeight = view.bounds.height }
            }
        }
        // A live control retains its callback after repeated width, height and orientation changes.
        keep.sendActions(for: .touchUpInside)
        #expect(indicator.isOn && keep.accessibilityValue == "On")
        #expect(try PlaybackQueuePreferenceStore(file: file).value.skipKeepsEpisode)
    }

    @Test func playbackRouteKeepsResizedContentScrollableAndSettingSaved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeepSkippedScroll-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let queue = try PlaybackQueuePreferenceStore(file: root.appendingPathComponent("queue.json"))
        let nav = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
        let controller = LibraryViewController(library: library, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: nav, speedPreferences: nil, mobileNetworkPreferences: nil,
            usage: nil, playbackQueuePreferences: queue)
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        do {
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                controller.view.frame = host.view.bounds
                defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
                let more = try #require(descendants(controller.view).compactMap { $0 as? UIControl }.first { $0.accessibilityIdentifier == "navigationMore" })
                more.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
                let settingsAction = try #require(descendants(controller.view).compactMap { $0 as? UIControl }.first { $0.accessibilityLabel == "Settings" })
                settingsAction.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
                let playback = try #require(descendants(controller.view).compactMap { $0 as? UIControl }.first { $0.accessibilityIdentifier == "prefScreenPlayback" })
                playback.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
                let firstView = try #require(descendants(controller.view).compactMap { $0 as? NavigationSettingsView }.first)
                try row("prefSkipKeepsEpisode", in: firstView).sendActions(for: .touchUpInside)
                for width in [CGFloat(320), host.view.bounds.width] {
                    controller.view.frame.size = CGSize(width: width, height: min(600, host.view.bounds.height))
                    controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                    let view = try #require(descendants(controller.view).compactMap { $0 as? NavigationSettingsView }.first)
                    let scroll = try #require(view.superview as? UIScrollView)
                    let keep = try row("prefSkipKeepsEpisode", in: view)
                    #expect(keep.accessibilityValue == "Off" && !queue.value.skipKeepsEpisode)
                    #expect(scroll.contentSize == view.bounds.size)
                    #expect(scroll.contentSize.height > scroll.bounds.height)
                    let target = keep.convert(keep.bounds, to: scroll)
                    scroll.scrollRectToVisible(target, animated: false)
                    #expect(scroll.bounds.contains(target))
                    #expect(try PlaybackQueuePreferenceStore(file: root.appendingPathComponent("queue.json")).value.skipKeepsEpisode == false)
                }
            }
            try await library.close()
        } catch { try? await library.close(); throw error }
    }

    @Test func settingWriteFailureReportsErrorAndRetainsVisibleAndStoredState() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("KeepSkippedFailure-\(UUID())")
        let store = try PlaybackQueuePreferenceStore(file: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: file) }
        let view = settings(store)
        var failures = 0; view.onFailure = { _ in failures += 1 }
        let keep = try row("prefSkipKeepsEpisode", in: view)
        keep.sendActions(for: .touchUpInside)
        #expect(failures == 1 && store.value.skipKeepsEpisode)
        #expect(keep.accessibilityValue == "On")
        #expect(keep.subviews.compactMap { $0 as? PreferenceSwitchView }.first?.isOn == true)
    }

    /// Uses the application's actual coordinator and preference closure. The
    /// setting changes after media selection so a captured startup value fails.
    @Test(arguments: [true, false])
    func selectedApplicationReadsChangedKeepSettingAtSkipAndRetainsUnplayedPosition(keep: Bool) async throws {
        let arguments = ProcessInfo.processInfo.arguments
        let index = try #require(arguments.firstIndex(of: "-test-library-id"))
        try #require(index + 1 < arguments.count && UUID(uuidString: arguments[index + 1]) != nil)
        try #require(arguments.contains("-test-muted-playback"))
        let app = try #require(UIApplication.shared.delegate as? AppDelegate)
        try #require(app.startupError == nil)
        let store = try #require(app.library), playback = try #require(app.playback)
        let queue = try #require(app.playbackQueuePreferences), downloads = try #require(app.downloadPreferences)
        let deletion = try #require(app.feedDeletion)
        try #require(playback.episode == nil, "Run in an isolated host with no selected media")
        let priorQueue = queue.value, priorDownloads = downloads.value
        defer { try? queue.update(priorQueue); try? downloads.update(priorDownloads) }
        var downloadValue = downloads.value
        downloadValue.smartMarkAsPlayedSeconds = 0; downloadValue.autoDelete = false
        try downloads.update(downloadValue)
        var queueValue = queue.value; queueValue.followQueue = true; queueValue.skipKeepsEpisode = !keep
        try queue.update(queueValue)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeepSkippedApp-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try #require(Bundle(for: KeepSkippedEpisodesTestBundle.self).url(forResource: "playback-30sec", withExtension: "mp3"))
        let source = URL(string: "https://example.invalid/keep-skipped/\(UUID())")!
        let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Keep skipped test", episodes: (1...3).map {
            .init(identifier: "\($0)", title: "Skip item \($0)", media: .init(url: source.appendingPathComponent("\($0).mp3").absoluteString,
                size: 0, durationMilliseconds: 30_000))
        }), source: source.absoluteString, responseURL: source, validator: nil, permanentRedirectURL: nil))
        do {
            let ids = feed.episodes.map(\.id)
            for id in ids {
                let file = root.appendingPathComponent("\(id).mp3")
                try FileManager.default.copyItem(at: audio, to: file)
                try await store.updateEpisode(id: id) {
                    $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path
                    $0.userState.downloadDate = Date()
                }
            }
            _ = try await store.enqueue(ids)
            try await playback.select(episodeID: ids[0], play: false)
            try await wait { playback.phase == .paused && app.playbackRoutes?.reading?.isPrepared == true }
            try await playback.seek(to: 4_000)
            try await wait { abs((app.playbackRoutes?.reading?.sample.positionMilliseconds ?? 0) - 4_000) < 100 }
            let view = settings(queue)
            let control = try row("prefSkipKeepsEpisode", in: view)
            control.sendActions(for: .touchUpInside)
            #expect(queue.value.skipKeepsEpisode == keep)
            try await playback.skip()
            try await wait { playback.episode?.id == ids[1] && playback.phase == .playing }
            try await playback.pause()
            let skipped = try #require(try await store.episode(id: ids[0]))
            #expect(skipped.userState.playState == .unplayed)
            #expect(abs(skipped.userState.positionMilliseconds - 4_000) < 100)
            #expect(skipped.userState.lastPlayedHistoryMilliseconds != nil)
            #expect(skipped.userState.isDownloaded)
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(ids[0]).mp3").path))
            #expect(try await store.queue().map(\.id) == (keep ? ids : Array(ids.dropFirst())))
            #expect(try await store.playbackSelectionEpisodeID() == ids[1])
            try await deletion.delete(feedID: feed.id).value
        } catch {
            try? await deletion.delete(feedID: feed.id).value
            throw error
        }
    }
}
