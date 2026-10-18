import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Mounted screens: the User interface rows
/// (theme cards, Full black, no Dynamic colors, Use episode cover), the theme applied at once to the screen, main
/// screens readable in Light, Dark and Full black, the cover rules per surface, the Playback speed row and the
/// hidden Choose data folder row. Expected text and rules come from Android 3.12.1, not from the app.
@MainActor @Suite(.serialized)
struct InterfaceSettingsViewTests {
    static let feedImage = "https://covers.test/feed.png", episodeImage = "https://covers.test/episode.png"

    private func find<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if view.accessibilityIdentifier == id, let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(id, in: $0, as: type) }.first
    }
    private func all<T: UIView>(_ view: UIView, _ type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all($0, T.self) }
    }
    private func wait(_ condition: @MainActor () async throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while try await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await condition(), sourceLocation: sourceLocation)
    }

    /// A solid 8×8 PNG: the podcast cover is red, the episode cover blue, so a person can tell them apart.
    private static func png(_ color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData()!
    }
    /// The colour drawn at the centre of a view, as a person sees it.
    /// A view not laid out yet (zero size) draws nothing: report black, so waiting checks retry instead of crashing the run.
    private func drawnColor(_ view: UIView) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        guard !view.bounds.isEmpty else { return (0, 0, 0) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { view.layer.render(in: $0.cgContext) }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let cgImage = image.cgImage, let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0, 0) }
        context.draw(cgImage, in: CGRect(x: -view.bounds.midX.rounded(.down), y: -view.bounds.midY.rounded(.down),
                                                width: view.bounds.width, height: view.bounds.height))
        return (CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255)
    }
    private enum Cover { case podcast, episode, other }
    private func cover(_ view: UIView) -> Cover {
        let color = drawnColor(view)
        if color.red > 0.6 && color.blue < 0.3 { return .podcast }
        if color.blue > 0.6 && color.red < 0.3 { return .episode }
        return .other
    }

    struct Fixture {
        let root: URL, store: FeedLibraryStore, feed: LibraryFeed, withImage: Int64, plain: Int64
        let interface: InterfacePreferenceStore, speed: PlaybackSpeedPreferenceStore, playback: PlaybackCoordinator
    }
    /// One podcast (red cover) with "Own cover" (blue episode image) and "No cover" (none), both queued.
    private func withFixture(_ body: @MainActor (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InterfaceSettingsView-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        var own = ParsedEpisode(identifier: "own", title: "Own cover", publicationDate: Date(timeIntervalSince1970: 1_780_000_000),
                                media: .init(url: "https://covers.test/own.mp3", size: 1, durationMilliseconds: 600_000))
        own.imageURL = Self.episodeImage
        let plain = ParsedEpisode(identifier: "plain", title: "No cover", publicationDate: Date(timeIntervalSince1970: 1_779_000_000),
                                  media: .init(url: "https://covers.test/plain.mp3", size: 1, durationMilliseconds: 600_000))
        var parsed = ParsedFeed(format: .rss, title: "Covers podcast", episodes: [own, plain])
        parsed.imageURL = Self.feedImage
        let feed = try await store.insert(.init(feed: parsed, source: "https://covers.test/feed", responseURL: URL(string: "https://covers.test/feed")!,
                                                validator: nil, permanentRedirectURL: nil))
        let ids = Dictionary(uniqueKeysWithValues: feed.episodes.map { ($0.details.title!, $0.id) })
        _ = try await store.enqueue([ids["Own cover"]!, ids["No cover"]!])
        let interface = try InterfacePreferenceStore(file: root.appendingPathComponent("interface-preferences.json"))
        let speed = try PlaybackSpeedPreferenceStore(file: root.appendingPathComponent("playback-speed-preferences.json"))
        let playback = PlaybackCoordinator(store: store, engine: QuietEngine(), speedPreferences: speed)
        let previousLoader = EpisodeArtworkView.remoteLoader
        EpisodeArtworkView.remoteLoader = { url in
            let body = url.absoluteString == Self.feedImage ? Self.png(.red) : url.absoluteString == Self.episodeImage ? Self.png(.blue) : Data()
            return (body, HTTPURLResponse(url: url, statusCode: body.isEmpty ? 404 : 200, httpVersion: nil, headerFields: nil)!)
        }
        defer { EpisodeArtworkView.remoteLoader = previousLoader }
        var failure: (any Error)?
        do {
            try await body(Fixture(root: root, store: store, feed: feed, withImage: ids["Own cover"]!, plain: ids["No cover"]!,
                                   interface: interface, speed: speed, playback: playback))
        } catch { failure = error }
        // Every window returns to the device's own appearance for later suites.
        InterfaceTheme.applyEverywhere(InterfacePreferences())
        try? await playback.stop()
        try await store.close()
        if let failure { throw failure }
    }

    private func withScreen(_ destination: NavigationDestination, _ fixture: Fixture, rtl: Bool = false,
                            _ body: @MainActor (LibraryViewController, UIWindow) async throws -> Void) async throws {
        let navigation = try NavigationPreferenceStore(file: fixture.root.appendingPathComponent("navigation-\(UUID()).json"))
        var value = navigation.value; value.defaultPage = destination.rawValue; try navigation.update(value)
        let timeDisplay = try TimeDisplayPreferenceStore(file: fixture.root.appendingPathComponent("time-\(UUID()).json"))
        let controller = LibraryViewController(library: fixture.store, startupError: nil, downloads: nil, playback: fixture.playback,
            timeDisplayPreferences: timeDisplay, navigationPreferences: navigation, speedPreferences: fixture.speed,
            mobileNetworkPreferences: nil, usage: nil)
        controller.interfacePreferences = fixture.interface
        try await withViewTestWindow { host, window in
            InterfaceTheme.apply(fixture.interface.value, to: window)
            if rtl { window.traitOverrides.layoutDirection = .rightToLeft; controller.view.semanticContentAttribute = .forceRightToLeft }
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            controller.view.frame = host.view.bounds
            await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
            try await body(controller, window)
        }
    }
    private func tap(_ id: String, _ view: UIView) throws {
        let control: UIControl = try #require(find(id, in: view), "Missing \(id)")
        #expect(control.isEnabled, "\(id) enabled")
        control.sendActions(for: .touchUpInside)
        view.layoutIfNeeded()
    }
    private func openSettings(_ controller: LibraryViewController, _ screen: String? = nil) throws {
        try tap("navigationMore", controller.view)
        let settings = try #require(all(controller.view, UIControl.self).first { $0.accessibilityLabel == "Settings" })
        settings.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
        if let screen { try tap(screen, controller.view) }
    }
    private func settingsScreen(_ controller: LibraryViewController) throws -> NavigationSettingsView {
        controller.view.layoutIfNeeded()
        return try #require(all(controller.view, NavigationSettingsView.self).first)
    }
    private func texts(_ view: UIView) -> [String] {
        all(view, UILabel.self).filter { !$0.isHidden }.sorted { a, b in
            let fa = a.convert(a.bounds, to: view), fb = b.convert(b.bounds, to: view)
            return fa.minY == fb.minY ? fa.minX < fb.minX : fa.minY < fb.minY
        }.compactMap(\.text)
    }
    /// A broad reading of the page background, as a person would describe it.
    private enum Shade { case light, dark, black }
    private func shade(_ color: UIColor?, _ traits: UITraitCollection) -> Shade? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color?.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a) == true else { return nil }
        if min(r, g, b) > 0.85 { return .light }
        if max(r, g, b) < 0.04 { return .black }
        if max(r, g, b) < 0.3 { return .dark }
        return nil
    }

    @Test(arguments: [false, true]) func userInterfaceRowsAndThemeCardsApplyAtOnceAndPersist(rtl: Bool) async throws {
        try await withFixture { fixture in
            try await withScreen(.queue, fixture, rtl: rtl) { controller, window in
                try openSettings(controller, "prefScreenInterface")
                var screen = try settingsScreen(controller)
                let order = texts(screen)
                // Theming (cards, Full black; no Dynamic colors), then Episode information with Use episode cover.
                // (The three cards share one line; their order is checked by position below.)
                let expected = ["Theming", "Automatic", "Full black", "Use full black for the dark theme", "Episode information", "Use episode cover"]
                let positions = expected.map { order.firstIndex(of: $0) }
                #expect(positions.allSatisfy { $0 != nil } && positions == positions.sorted { ($0 ?? 0) < ($1 ?? 0) }, "\(order)")
                #expect(!order.contains("Dynamic colors") && !order.contains("Adapt app colors based on the wallpaper"))
                let cards = try ["themeSystemCard", "themeLightCard", "themeDarkCard"].map { try #require(find($0, in: screen, as: UIControl.self)) }
                #expect(cards.map(\.accessibilityLabel) == ["Automatic", "Light", "Dark"])
                let frames = cards.map { $0.convert($0.bounds, to: screen) }
                #expect(frames.allSatisfy { abs($0.minY - frames[0].minY) < 1 && abs($0.width - frames[0].width) < 1 })
                #expect(rtl ? frames[0].minX > frames[1].maxX && frames[1].minX > frames[2].maxX
                            : frames[0].maxX < frames[1].minX && frames[1].maxX < frames[2].minX, "Automatic, Light, Dark from the leading edge")
                #expect(frames.allSatisfy { screen.bounds.contains($0) }, "No card is clipped")
                #expect(cards.map { $0.accessibilityTraits.contains(.selected) } == [true, false, false])
                let black = try #require(find("prefThemeBlack", in: screen, as: UIControl.self))
                #expect(black.isEnabled && black.accessibilityValue == "Off")
                #expect(find("prefEpisodeCover", in: screen, as: UIControl.self)?.accessibilityValue == "On")

                // Dark: the saved value, every window and this screen change at once; Dark is now the active card.
                try tap("themeDarkCard", screen)
                #expect(fixture.interface.value.theme == .dark && window.overrideUserInterfaceStyle == .dark)
                #expect(controller.view.traitCollection.userInterfaceStyle == .dark)
                #expect(shade(controller.view.backgroundColor, controller.view.traitCollection) == .dark)
                screen = try settingsScreen(controller)
                #expect(["themeSystemCard", "themeLightCard", "themeDarkCard"].map {
                    find($0, in: screen, as: UIControl.self)?.accessibilityTraits.contains(.selected) } == [false, false, true])
                // The active card is visibly more tinted than the others (32 dp versus 1 dp surface elevation).
                let dark = try #require(find("themeDarkCard", in: screen, as: UIControl.self)), light = try #require(find("themeLightCard", in: screen, as: UIControl.self))
                #expect(dark.backgroundColor?.resolvedColor(with: dark.traitCollection) != light.backgroundColor?.resolvedColor(with: light.traitCollection))

                // Full black: the page turns black; the setting row reads On.
                try tap("prefThemeBlack", screen)
                #expect(fixture.interface.value.blackTheme && controller.view.traitCollection[FullBlackThemeTrait.self])
                #expect(shade(controller.view.backgroundColor, controller.view.traitCollection) == .black)
                screen = try settingsScreen(controller)
                #expect(find("prefThemeBlack", in: screen, as: UIControl.self)?.accessibilityValue == "On")
                // Light keeps Full black saved but draws light (Full black only applies to the dark theme).
                try tap("themeLightCard", screen)
                #expect(window.overrideUserInterfaceStyle == .light && fixture.interface.value.blackTheme)
                #expect(shade(controller.view.backgroundColor, controller.view.traitCollection) == .light)
                // Automatic follows the device again. The device's dark appearance is stood in for by a trait on
                // this scene (no system setting changes): Automatic with Full black then draws black, as `readThemeValue`.
                try tap("themeSystemCard", try settingsScreen(controller))
                #expect(window.overrideUserInterfaceStyle == .unspecified && fixture.interface.value.theme == .system)
                let scene = try #require(window.windowScene)
                scene.traitOverrides.userInterfaceStyle = .dark
                defer { scene.traitOverrides.remove(UITraitUserInterfaceStyle.self) }
                window.updateTraitsIfNeeded()
                #expect(shade(controller.view.backgroundColor, controller.view.traitCollection) == .black)
                scene.traitOverrides.remove(UITraitUserInterfaceStyle.self)
                window.updateTraitsIfNeeded()

                // Independent check of the saved file: Android's keys and values.
                let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf:
                    fixture.root.appendingPathComponent("interface-preferences.json"))) as? [String: Any])
                #expect(saved["prefTheme"] as? String == "system" && saved["prefThemeBlack"] as? Bool == true && saved["prefEpisodeCover"] as? Bool == true)
                // A new store (relaunch) reads the same values.
                #expect(try InterfacePreferenceStore(file: fixture.root.appendingPathComponent("interface-preferences.json")).value
                        == .init(theme: .system, blackTheme: true, useEpisodeCover: true))
            }
        }
    }

    @Test func downloadsHasNoChooseDataFolderRow() async throws {
        try await withFixture { fixture in
            try await withScreen(.queue, fixture) { controller, _ in
                try openSettings(controller, "prefScreenDownloads")
                let order = texts(try settingsScreen(controller))
                #expect(!order.contains("Choose data folder") && order.first == "Automation", "\(order)")
            }
        }
    }

    /// Every visible text on the main screens is readable (WCAG 4.5:1, or 3:1 for large text) in Light, Dark and
    /// Full black. Disabled (dimmed) rows are excluded, as their low contrast is Material's disabled state.
    @Test func mainScreensStayReadableInLightDarkAndFullBlack() async throws {
        try await withFixture { fixture in
            for theme in [InterfacePreferences(theme: .light), .init(theme: .dark), .init(theme: .dark, blackTheme: true)] {
                try fixture.interface.update(theme)
                for destination in [NavigationDestination.home, .queue, .inbox, .episodes, .subscriptions, .downloads, .history, .favorites] {
                    try await withScreen(destination, fixture) { controller, _ in
                        try await Task.sleep(for: .milliseconds(50))
                        try checkContrast(controller.view, "\(theme) \(destination)")
                        if destination == .queue {
                            controller.push(.feed(fixture.feed.id)); controller.view.layoutIfNeeded()
                            try checkContrast(controller.view, "\(theme) podcast screen")
                            try tap("toolbarBack", controller.view)
                            for screen in [nil, "prefScreenInterface", "prefScreenPlayback", "prefScreenDownloads"] {
                                try openSettings(controller, screen)
                                try checkContrast(controller.view, "\(theme) settings \(screen ?? "root")")
                                while controller.path.count > 1 { try tap("toolbarBack", controller.view) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func checkContrast(_ root: UIView, _ label: String) throws {
        root.layoutIfNeeded()
        var checked = 0
        for text in all(root, UILabel.self) where !(text.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            var alpha: CGFloat = 1, view: UIView? = text, visible = true
            while let current = view { alpha *= current.alpha; if current.isHidden { visible = false }; view = current.superview }
            let frame = text.convert(text.bounds, to: root)
            guard visible, alpha > 0.9, frame.width > 1, frame.height > 1, root.bounds.intersects(frame) else { continue }
            if text.superview is EpisodeArtworkView { continue } // Cover placeholder, hidden once the cover loads.
            // White text with a readability shadow over the podcast's own artwork (the podcast header, as in
            // Android's `feeditemlist_header.xml`): its contrast depends on the artwork, not on the theme.
            if text.layer.shadowOpacity > 0 { continue }
            let traits = text.traitCollection
            let foreground = (text.attributedText?.length ?? 0) > 0
                ? text.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor ?? text.textColor
                : text.textColor
            var background: UIColor?
            view = text
            while let current = view {
                if let color = current.backgroundColor?.resolvedColor(with: traits) {
                    var a: CGFloat = 0; color.getRed(nil, green: nil, blue: nil, alpha: &a)
                    if a > 0.9 { background = color; break }
                }
                view = current.superview
            }
            guard let foreground, let background else { continue }
            let ratio = Self.contrast(foreground.resolvedColor(with: traits), background)
            let large = text.font.pointSize >= 18 || (text.font.pointSize >= 14 && text.font.fontName.contains("Bold"))
            #expect(ratio >= (large ? 3 : 4.5), "\(label): \"\(text.text ?? "")\" contrast \(ratio)")
            checked += 1
        }
        #expect(checked > 0, "\(label): some text was checked")
    }
    private static func contrast(_ a: UIColor, _ b: UIColor) -> CGFloat {
        func luminance(_ color: UIColor) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &alpha)
            func channel(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// The cover of an episode row once its image has loaded.
    private func settled(row id: Int64, in view: UIView) async throws -> EpisodeArtworkView {
        try await wait {
            guard let button = self.find("episode-\(id)", in: view, as: UIButton.self), let row = button.superview,
                  let artwork = self.all(row, EpisodeArtworkView.self).first else { return false }
            view.layoutIfNeeded()
            // Shown, and laid out: the colour check reads what is drawn on screen.
            return artwork.displayedSource != nil && !artwork.bounds.isEmpty && artwork.window != nil
        }
        let button = try #require(find("episode-\(id)", in: view, as: UIButton.self))
        let row = try #require(button.superview)
        return try #require(all(row, EpisodeArtworkView.self).first)
    }
    private func settled(_ id: String, in view: UIView) async throws -> EpisodeArtworkView {
        try await wait { (self.find(id, in: view, as: EpisodeArtworkView.self))?.displayedSource != nil }
        return try #require(find(id, in: view, as: EpisodeArtworkView.self))
    }

    /// Lists, Home cards and the mini player follow "Use episode cover"; the podcast's own list, the full player
    /// cover and the episode details always prefer the episode image.
    @Test func coverSettingAppliesToListsHomeAndMiniPlayerOnly() async throws {
        try await withFixture { fixture in
            try await fixture.playback.select(episodeID: fixture.withImage, play: false)
            try await withScreen(.queue, fixture) { controller, _ in
                let view = controller.view!
                // Setting on (default): the episode's own image where it has one.
                #expect(cover(try await settled(row: fixture.withImage, in: view)) == .episode)
                #expect(cover(try await settled(row: fixture.plain, in: view)) == .podcast)
                #expect(try await settled("miniPlayerArtwork", in: view).displayedSource == Self.episodeImage)

                // Off, from the User interface screen: lists, Home and the mini player show the podcast cover at once.
                try openSettings(controller, "prefScreenInterface")
                try tap("prefEpisodeCover", try settingsScreen(controller))
                #expect(!fixture.interface.value.useEpisodeCover)
                #expect(try await settled("miniPlayerArtwork", in: view).displayedSource == Self.feedImage)
                #expect(try await settled("playerCoverArtwork", in: view).displayedSource == Self.episodeImage,
                        "The full player cover ignores the setting")
                while controller.path.count > 1 { try tap("toolbarBack", view) }
                view.layoutIfNeeded()
                #expect(cover(try await settled(row: fixture.withImage, in: view)) == .podcast)
                try tap("HomeFragment", view)
                let card = try #require(controller.homeCards.first { $0.0.id == fixture.withImage }?.1)
                let cardArtwork = try #require(all(card, EpisodeArtworkView.self).first)
                try await wait { cardArtwork.displayedSource != nil }
                #expect(cardArtwork.displayedSource == Self.feedImage)
                // The podcast's own episode list keeps the episode image.
                controller.push(.feed(fixture.feed.id)); view.layoutIfNeeded()
                #expect(cover(try await settled(row: fixture.withImage, in: view)) == .episode)
            }
        }
    }

    /// Playback → Playback speed opens the speed dialog: the global speed when no episode is selected, the selected
    /// episode's speed otherwise; a preset saves the global speed.
    @Test func playbackSpeedRowOpensTheDialogAndSavesTheGlobalSpeed() async throws {
        try await withFixture { fixture in
            try fixture.speed.setGlobal(1.5)
            try await withScreen(.queue, fixture) { controller, _ in
                try openSettings(controller, "prefScreenPlayback")
                let screen = try settingsScreen(controller)
                let row = try #require(find("prefPlaybackSpeedLauncher", in: screen, as: UIControl.self))
                #expect(row.accessibilityLabel == "Playback speed" && row.accessibilityHint == "Customize the speeds available for variable speed playback")
                let order = texts(screen)
                let control = try #require(order.firstIndex(of: "Playback control")), speed = try #require(order.firstIndex(of: "Playback speed"))
                #expect(control < speed && order.firstIndex(of: "Rewind skip time").map { $0 < speed } == true, "\(order)")
                row.sendActions(for: .touchUpInside)
                try await wait { (controller.presentedViewController as? PlaybackSpeedController)?.isBeingPresented == false }
                let dialog = try #require(controller.presentedViewController as? PlaybackSpeedController)
                dialog.view.layoutIfNeeded()
                try await wait { self.find("speedSlider", in: dialog.view, as: UIControl.self)?.accessibilityValue == PlaybackSpeedDialogState.text(1.5) }
                try tap("speedPreset-1", dialog.view) // 1.25
                try await wait { fixture.speed.value.global == 1.25 }
                try await wait { controller.presentedViewController == nil }
                let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf:
                    fixture.root.appendingPathComponent("playback-speed-preferences.json"))) as? [String: Any])
                #expect(saved["global"] as? Double == 1.25)

                // With an episode of a podcast that has its own speed, the dialog shows that episode's speed.
                try fixture.speed.setFeed(fixture.feed.id, speed: 2)
                try await fixture.playback.select(episodeID: fixture.plain, play: false)
                #expect(fixture.playback.speed == 2)
                try tap("prefPlaybackSpeedLauncher", try settingsScreen(controller))
                try await wait { (controller.presentedViewController as? PlaybackSpeedController)?.isBeingPresented == false }
                let second = try #require(controller.presentedViewController as? PlaybackSpeedController)
                second.view.layoutIfNeeded()
                try await wait { self.find("speedSlider", in: second.view, as: UIControl.self)?.accessibilityValue == PlaybackSpeedDialogState.text(2) }
                second.dismiss(animated: false)
            }
        }
    }
}

/// Selects episodes without loading media (the fixture's addresses are not reachable), so no playback error appears.
@MainActor private final class QuietEngine: PlaybackEngine {
    var reading: PlaybackEngineReading?
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {}
    func play(commandID: UUID) {}
    func pause(commandID: UUID) {}
    func seek(to positionMilliseconds: Int64, commandID: UUID) {}
    func setSpeed(_ speed: Float, commandID: UUID) throws {}
    func unload() {}
}
