import UIKit
import SwiftUI
import WidgetKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Mounted checks: the shipped widget extension, the widget's face at real widget sizes, the widget's and the
/// control's intents on a player, the widget's links, and the App Group snapshot the app keeps for them.
@MainActor @Suite(.serialized)
struct PlayerWidgetViewTests {
    private func wait(_ what: String = "", _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "\(what)")
    }

    private func widgetBundle() throws -> Bundle {
        let plugins = try #require(Bundle.main.builtInPlugInsURL)
        return try #require(Bundle(url: plugins.appendingPathComponent("NotTennaPodWidget.appex")))
    }

    // MARK: - The shipped extension

    @Test func appShipsTheWidgetWithAndroidsWordingIconsAndAnAppGroup() throws {
        let widget = try widgetBundle()
        let extensionInfo = try #require(widget.infoDictionary?["NSExtension"] as? [String: Any])
        #expect(extensionInfo["NSExtensionPointIdentifier"] as? String == "com.apple.widgetkit-extension")
        #expect(widget.infoDictionary?["CFBundleDisplayName"] as? String == "NotTennaPod")
        // Android's strings (strings.xml 251–968), from the extension's own bundle.
        let wording = ["widget_settings": "Widget settings", "widget_opacity": "Opacity", "cover_as_background": "Cover as background",
                       "playback_speed": "Playback speed", "rewind_label": "Rewind", "fast_forward_label": "Fast-forward",
                       "skip_episode_label": "Skip episode", "no_media_playing_label": "No media playing",
                       "play_label": "Play", "pause_label": "Pause"]
        for (key, text) in wording { #expect(widget.localizedString(forKey: key, value: nil, table: nil) == text, "\(key)") }
        // Android's ic_widget_* icons and the launcher icon layers are in the extension's catalog.
        let presentation = PlayerWidgetPresentation(snapshot: nil, configuration: .init(), date: Date(), narrow: false, hasCover: false)
        var icons = PlayerWidgetPresentation.Control.allCases.map(presentation.iconName(for:)) + ["ic_widget_pause"]
        icons += ["Logo-main-background", "Logo-main-foreground", "Logo-debug-background", "Logo-debug-foreground"]
        for name in icons { #expect(UIImage(named: name, in: widget, with: nil) != nil, "\(name)") }
        #expect((widget.infoDictionary?["UIAppFonts"] as? [String])?.allSatisfy { widget.url(forResource: $0, withExtension: nil) != nil } == true)
        // The unsigned Simulator build gets the shared container, and the widget's links reach the app.
        let container = try #require(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: PlayerWidget.appGroup))
        let probe = container.appendingPathComponent("widget-probe-\(UUID())")
        try Data([1]).write(to: probe); try FileManager.default.removeItem(at: probe)
        let schemes = (Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes.contains(PlayerWidgetLink.scheme))
    }

    // MARK: - The widget's face

    private final class Frames: @unchecked Sendable { var value: [String: CGRect] = [:] }

    /// Keep the hosting controller alive for the mounted face's layout and pixel capture. Releasing this
    /// test container also releases the controller; a detached hosting view alone does not own its controller.
    private final class RenderedWidget: UIView {
        private let controller: UIViewController
        init(controller: UIViewController, frame: CGRect) {
            self.controller = controller
            super.init(frame: frame)
            controller.view.frame = bounds
            addSubview(controller.view)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    /// Lays the widget's face out at `size` in a window and returns where each part went.
    private func render(_ presentation: PlayerWidgetPresentation, size: CGSize, rtl: Bool, in window: UIWindow,
                        cover: UIImage? = nil, mode: WidgetRenderingMode = .fullColor,
                        colorScheme: ColorScheme = .light, contrastSwatch: UIColor? = nil,
                        compositionBacking: UIColor? = nil,
                        renderingContext: PlayerWidgetRenderingContext? = nil) async throws -> (UIView, [String: CGRect]) {
        let widget = try widgetBundle()
        let frames = Frames()
        let face = PlayerWidgetView(presentation: presentation, cover: cover, resources: widget, renderingContext: renderingContext)
        let hosting = UIHostingController(rootView: Group {
            if let contrastSwatch {
                // Foreground-only contrast harness. Replace the removable container with clear before adding
                // a stated solid swatch; never present this app rendering as actual OS background evidence.
                face.containerBackground(for: .widget) { Color.clear }.background(Color(uiColor: contrastSwatch))
            } else if let compositionBacking {
                // Mount the SAME production card and 60% blurred-cover layers in an ordinary SwiftUI
                // background, so UIKit actually renders them. Only the explicit backing is a fixture;
                // WidgetKit's removable container/tint/glass pipeline is not simulated by this render.
                face.containerBackground(for: .widget) { Color.clear }
                    .background(face.backgroundView).background(Color(uiColor: compositionBacking))
            } else {
                face
            }
        }
            .frame(width: size.width, height: size.height)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            .environment(\.widgetRenderingMode, mode)
            .environment(\.colorScheme, colorScheme)
            .onPreferenceChange(PlayerWidgetLayout.self) { value in frames.value = value })
        let mounted = RenderedWidget(controller: hosting, frame: CGRect(origin: CGPoint(x: 20, y: 120), size: size))
        window.rootViewController?.view.addSubview(mounted)
        try await wait("laid out") {
            mounted.layoutIfNeeded()
            return !frames.value.isEmpty
        }
        return (mounted, frames.value)
    }

    private func snapshot(title: String = "Deletion episode 0", playing: Bool = false) -> PlayerWidgetSnapshot {
        PlayerWidgetSnapshot(episodeID: 7, title: title, isPlaying: playing, positionRate: 0, positionMilliseconds: 13_000,
            durationMilliseconds: 30_000, savedAt: Date())
    }

    /// At iPhone and iPad widget sizes, in both directions: everything is inside the widget, the buttons keep
    /// Android's order (mirrored right-to-left), don't overlap and stay tappable, the cover leads, the text is above
    /// the button row, the standalone play button sits at the trailing edge, and a long title stays on one line.
    @Test(arguments: [false, true], ["fullColor", "accented", "vibrant"])
    func widgetFaceKeepsAndroidsCompositionAtWidgetSizes(rtl: Bool, renderingMode: String) async throws {
        // This exercises our layout branches, not WidgetKit's actual tint/glass pipeline. The read-only
        // showsWidgetContainerBackground environment remains under system control.
        let mode: WidgetRenderingMode = renderingMode == "accented" ? .accented : renderingMode == "vibrant" ? .vibrant : .fullColor
        let all = PlayerWidgetConfiguration(playbackSpeed: true, rewind: true, fastForward: true, skip: true)
        let long = String(repeating: "A very long episode title that does not fit ", count: 4)
        let mediums = [CGSize(width: 338, height: 158), CGSize(width: 364, height: 170), CGSize(width: 305, height: 141)]
        let smalls = [CGSize(width: 158, height: 158), CGSize(width: 170, height: 170), CGSize(width: 141, height: 141)]
        let order = ["playbackSpeed", "rewind", "playPause", "fastForward", "skip"].map { "playerWidget-" + $0 }
        func before(_ a: CGRect, _ b: CGRect) -> Bool { rtl ? a.minX >= b.maxX - 0.5 : a.maxX <= b.minX + 0.5 }
        try await withViewTestWindow { _, window in
            for size in mediums {
                let bounds = CGRect(origin: .zero, size: size)
                // Extended row, playing, a title far too long for one line.
                var (view, frames) = try await render(.init(snapshot: snapshot(title: long, playing: true), configuration: all,
                    date: Date(), narrow: false, hasCover: false), size: size, rtl: rtl, in: window, mode: mode)
                for (id, frame) in frames { #expect(bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(id) \(frame) in \(size)") }
                let controls = try order.map { try #require(frames[$0], "\($0) in \(size)") }
                for (a, b) in zip(controls, controls.dropFirst()) { #expect(before(a, b), "\(a) then \(b)") }
                for control in controls { #expect(control.width >= 30 && control.height >= 30, "\(control)") }
                let cover = try #require(frames["playerWidgetCover"])
                let title = try #require(frames["playerWidgetTitle"])
                let progress = try #require(frames["playerWidgetProgress"])
                #expect(before(cover, title) && before(cover, controls[0]))
                #expect(title.height < 30, "one line: \(title)")
                #expect(title.maxY <= progress.minY + 0.5 && controls.allSatisfy { progress.maxY <= $0.minY + 0.5 })
                #expect(frames["playerWidget-playPause"] != nil && frames.keys.filter { $0.hasPrefix("playerWidget-") }.count == 5)
                view.removeFromSuperview()

                // Default settings: the standalone Play at the trailing edge, after the text; no other buttons.
                (view, frames) = try await render(.init(snapshot: snapshot(), configuration: .init(), date: Date(),
                    narrow: false, hasCover: false), size: size, rtl: rtl, in: window, mode: mode)
                let play = try #require(frames["playerWidget-playPause"])
                let text = try #require(frames["playerWidgetTitle"])
                #expect(frames.keys.filter { $0.hasPrefix("playerWidget-") } == ["playerWidget-playPause"])
                #expect(rtl ? play.minX <= 13 : size.width - play.maxX <= 13, "\(play)")
                #expect(before(text, play) && play.width >= 30 && play.height >= 30)
                view.removeFromSuperview()

                // No media, with buttons chosen: "No media playing" and the row, no progress.
                (view, frames) = try await render(.init(snapshot: nil, configuration: all, date: Date(), narrow: false, hasCover: false),
                    size: size, rtl: rtl, in: window, mode: mode)
                #expect(frames["playerWidgetNoMedia"] != nil && frames["playerWidgetTitle"] == nil && frames["playerWidgetProgress"] == nil)
                #expect(frames.keys.filter { $0.hasPrefix("playerWidget-") }.count == 5)
                view.removeFromSuperview()

                // Cover as background: no small cover; the text starts at the leading margin.
                (view, frames) = try await render(.init(snapshot: snapshot(), configuration: .init(coverAsBackground: true), date: Date(),
                    narrow: false, hasCover: true), size: size, rtl: rtl, in: window, cover: UIImage(systemName: "star"), mode: mode)
                let alone = try #require(frames["playerWidgetTitle"])
                #expect(frames["playerWidgetCover"] == nil)
                #expect(rtl ? abs(size.width - alone.maxX - 12) <= 1 : abs(alone.minX - 12) <= 1, "\(alone)")
                view.removeFromSuperview()
            }
            for size in smalls {
                // The narrow widget: cover and play/pause only, also with buttons chosen.
                let (view, frames) = try await render(.init(snapshot: snapshot(playing: true), configuration: all, date: Date(),
                    narrow: true, hasCover: false), size: size, rtl: rtl, in: window, mode: mode)
                #expect(Set(frames.keys) == ["playerWidgetCover", "playerWidget-playPause"], "\(frames.keys)")
                let pause = try #require(frames["playerWidget-playPause"]), cover = try #require(frames["playerWidgetCover"])
                #expect(CGRect(origin: .zero, size: size).contains(pause) && pause.width >= 30 && pause.height >= 30)
                #expect(before(cover, pause))
                view.removeFromSuperview()
            }
        }
    }

    /// Controlled cover-OFF foreground-policy proof, using stated solid swatches and an explicit semantic
    /// rendering context. These are not wallpaper, and app rendering does not prove a WidgetKit background,
    /// actual system recoloring, or literal opacity. The separate Home Screen journey must prove readability.
    @Test(arguments: [false, true])
    func fullColorFaceHasReadableTextAndIconsAtSavedOpacityValues(dark: Bool) async throws {
        let androidDark = UIColor(red: 0x26 / 255.0, green: 0x2C / 255.0, blue: 0x31 / 255.0, alpha: 1)
        // Independent representative contrast fixtures, not calibrated Simulator colors or predictions of
        // WidgetKit's compositor. The dense midrange covers both sides of the proposed foreground switch.
        let lightSwatches: [(opacity: Double, backing: UIColor)] = [
            (0, .white), (25, UIColor(white: 0.8, alpha: 1)), (50, UIColor(white: 0.6, alpha: 1)),
            (60, UIColor(white: 0.55, alpha: 1)), (64, UIColor(white: 0.5, alpha: 1)),
            (65, UIColor(white: 0.5, alpha: 1)), (66, UIColor(white: 0.5, alpha: 1)),
            (67, UIColor(white: 0.5, alpha: 1)), (68, UIColor(white: 0.5, alpha: 1)),
            (69, UIColor(white: 0.5, alpha: 1)), (70, UIColor(white: 0.45, alpha: 1)),
            (75, UIColor(white: 0.4, alpha: 1)), (100, androidDark)
        ]
        try await withViewTestWindow { _, window in
            for narrow in [false, true] {
                let size = narrow ? CGSize(width: 158, height: 158) : CGSize(width: 338, height: 158)
                for (opacity, representativeBacking) in lightSwatches {
                    let configuration = PlayerWidgetConfiguration(opacity: opacity, playbackSpeed: true, rewind: true,
                        fastForward: true, skip: true, coverAsBackground: false)
                    let (view, frames) = try await render(.init(snapshot: snapshot(), configuration: configuration,
                        date: Date(), narrow: narrow, hasCover: false), size: size, rtl: false, in: window,
                        colorScheme: dark ? .dark : .light, contrastSwatch: dark ? androidDark : representativeBacking,
                        renderingContext: .init(mode: .fullColor, showsContainerBackground: true, colorScheme: dark ? .dark : .light))
                    defer { view.removeFromSuperview() }
                    let name = "widget-policy-\(narrow ? "small" : "medium")-\(dark ? "dark" : "light")-opacity\(Int(opacity))-coverfalse"
                    _ = try recordReadableFace(view, frames: frames, narrow: narrow, name: name)
                }
            }
        }
    }

    /// Controlled ACTUAL composition, over stated white/light and black/dark backing. Uniform dark artwork
    /// represents a dark cover without texture masquerading as glyph ink. This may reject the opacity-only
    /// foreground prototype: retain a real failure instead of replacing the cover with an opaque dark swatch.
    /// These are ordinary app components; actual WidgetKit cover art, OS modes and wallpaper need a live check.
    @Test(arguments: [false, true])
    func actualCardAndDarkCoverLayersHaveReadableTextAndIconsOverKnownBacking(dark: Bool) async throws {
        let art = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48)).image { context in
            UIColor(red: 0.08, green: 0.18, blue: 0.3, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        }
        try await withViewTestWindow { _, window in
            for narrow in [false, true] {
                let size = narrow ? CGSize(width: 158, height: 158) : CGSize(width: 338, height: 158)
                for coverBackground in [false, true] {
                    for opacity in [0.0, 25, 50, 65, 70, 100] {
                        let configuration = PlayerWidgetConfiguration(opacity: opacity, playbackSpeed: true, rewind: true,
                            fastForward: true, skip: true, coverAsBackground: coverBackground)
                        let (view, frames) = try await render(.init(snapshot: snapshot(), configuration: configuration,
                            date: Date(), narrow: narrow, hasCover: true), size: size, rtl: false, in: window,
                            cover: art, colorScheme: dark ? .dark : .light, compositionBacking: dark ? .black : .white,
                            renderingContext: .init(mode: .fullColor, showsContainerBackground: true, colorScheme: dark ? .dark : .light))
                        defer { view.removeFromSuperview() }
                        let name = "widget-component-composition-\(narrow ? "small" : "medium")-\(dark ? "dark" : "light")-opacity\(Int(opacity))-cover\(coverBackground)"
                        let image = try recordReadableFace(view, frames: frames, narrow: narrow, name: name)
                        // An empty top-center patch proves the real layers were mounted, rather than
                        // silently omitted by app-only container handling. These broad ranges distinguish
                        // known white/black backing, a dark card and the 60% dark-cover layer; no OS RGB fit.
                        let luminances = try pixelLuminances(image, in: CGRect(x: size.width / 2 - 2, y: 6, width: 4, height: 4), description: name)
                        let background = try #require(luminances.sorted().dropFirst(luminances.count / 2).first)
                        if opacity == 0 && !coverBackground {
                            #expect(dark ? background < 0.01 : background > 0.95, "\(name): explicit backing must render")
                        } else if opacity == 100 && !coverBackground {
                            #expect(background > 0.005 && background < 0.1, "\(name): actual opaque dark card must render")
                        } else if coverBackground {
                            // Cover as background forces the card opaque whatever the saved opacity (Android locks
                            // the slider at 100 %), so the explicit backing must never show under the 60 % cover.
                            #expect(background > 0.003 && background < 0.1,
                                    "\(name): opaque dark card under the 60% dark cover must render, hiding the backing")
                        }
                    }
                }
            }
        }
    }

    private func recordReadableFace(_ view: UIView, frames: [String: CGRect], narrow: Bool, name: String) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            #expect(view.drawHierarchy(in: view.bounds, afterScreenUpdates: true))
        }
        Attachment.record(try #require(image.pngData()), named: name + ".png")
        let identifiers = narrow ? ["playerWidget-playPause"] : ["playerWidgetTitle", "playerWidgetProgress",
            "playerWidget-playbackSpeed", "playerWidget-rewind", "playerWidget-playPause", "playerWidget-fastForward", "playerWidget-skip"]
        for identifier in identifiers {
            let frame = try #require(frames[identifier], "\(name): \(identifier)")
            let side: CGFloat = narrow ? 32 : 36
            let region = identifier.hasPrefix("playerWidget-") ?
                CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side) : frame
            if let crop = image.cgImage?.cropping(to: CGRect(x: region.minX * image.scale, y: region.minY * image.scale,
                width: region.width * image.scale, height: region.height * image.scale).integral) {
                Attachment.record(try #require(UIImage(cgImage: crop).pngData()), named: name + "-" + identifier + ".png")
            }
            try requireReadablePixels(image, in: region, minimumContrast: 3, description: name + ": " + identifier)
        }
        return image
    }

    /// The system foreground responds to the environment when a container is removed. This controlled
    /// render proves the component branch only; actual StandBy/Lock Screen treatment still needs a capture.
    @Test(arguments: [false, true])
    func controlledRemovedContainerKeepsItsSystemForegroundReadable(dark: Bool) async throws {
        try await withViewTestWindow { _, window in
            for narrow in [false, true] {
                let size = narrow ? CGSize(width: 158, height: 158) : CGSize(width: 338, height: 158)
                let (view, frames) = try await render(.init(snapshot: snapshot(), configuration: .init(), date: Date(),
                    narrow: narrow, hasCover: false), size: size, rtl: false, in: window, colorScheme: dark ? .dark : .light,
                    contrastSwatch: dark ? .black : .white,
                    renderingContext: .init(mode: .fullColor, showsContainerBackground: false, colorScheme: dark ? .dark : .light))
                defer { view.removeFromSuperview() }
                let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
                    #expect(view.drawHierarchy(in: view.bounds, afterScreenUpdates: true))
                }
                Attachment.record(try #require(image.pngData()),
                                  named: "widget-policy-removed-\(narrow ? "small" : "medium")-\(dark ? "dark" : "light").png")
                let play = try #require(frames["playerWidget-playPause"])
                try requireReadablePixels(image, in: CGRect(x: play.midX - 16, y: play.midY - 16, width: 32, height: 32),
                                          minimumContrast: 3, description: "controlled removed-container Play")
                if !narrow {
                    let title = try #require(frames["playerWidgetTitle"])
                    try requireReadablePixels(image, in: title, minimumContrast: 3,
                                              description: "controlled removed-container title")
                }
            }
        }
    }

    /// Count visible ink against the local median background. Checking rendered glyphs catches white-on-white
    /// text/icons even when their accessibility elements, labels and frames still exist. Thresholds concern
    /// visible strokes, not an exact-color or accessibility-conformance contract. A 3:1 visibility floor is
    /// supplemented by a visual check of the captured face; antialiasing at one pixel is not a requirement.
    private func requireReadablePixels(_ image: UIImage, in rect: CGRect, minimumContrast: Double,
                                       description: String) throws {
        let luminances = try pixelLuminances(image, in: rect, description: description)
        let background = try #require(luminances.sorted().dropFirst(luminances.count / 2).first)
        let ink = luminances.filter { (max($0, background) + 0.05) / (min($0, background) + 0.05) >= minimumContrast }.count
        let visibleInkArea = Double(ink) / Double(image.scale * image.scale)
        #expect(visibleInkArea >= max(6, Double(rect.width * rect.height) * 0.01),
                "\(description): only \(visibleInkArea) square points of visible ink at \(minimumContrast):1 contrast")
    }

    private func pixelLuminances(_ image: UIImage, in rect: CGRect, description: String) throws -> [Double] {
        let crop = try #require(image.cgImage?.cropping(to: CGRect(x: rect.minX * image.scale, y: rect.minY * image.scale,
            width: rect.width * image.scale, height: rect.height * image.scale).integral), "\(description)")
        let width = crop.width, height = crop.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        func linear(_ byte: UInt8) -> Double {
            let value = Double(byte) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return stride(from: 0, to: bytes.count, by: 4).map { index -> Double in
            let red = 0.2126 * linear(bytes[index])
            let green = 0.7152 * linear(bytes[index + 1])
            let blue = 0.0722 * linear(bytes[index + 2])
            return red + green + blue
        }
    }

    // MARK: - The app's router

    /// Every widget and control command the system runs in the app goes through the startup owner's one ordered
    /// dispatcher to the graph's player commands: in the order the buttons arrived whatever their tasks' priorities,
    /// after a command still running, and a command cancelled while it waits never reaches the player.
    @Test func appRoutesWidgetCommandsInArrivalOrderThroughItsDispatcher() async throws {
        let app = try #require(UIApplication.shared.delegate as? AppDelegate)
        try #require(app.libraryStartup.isStarted)
        let perform = try #require(PlayerWidgetIntentRouter.perform)
        let saved = app.startupHandoff.widgetCommands
        defer { app.startupHandoff.widgetCommands = saved }
        var received: [PlayerWidgetCommand] = []
        let gate = AsyncStream<Void>.makeStream()
        app.startupHandoff.widgetCommands = { command, _ in
            received.append(command)
            if received.count == 1 { for await _ in gate.stream { break } }
            return nil
        }
        let play = Task { try await perform(.play, .widget) }
        try await wait("play runs") { received == [.play] }
        let pause = Task.detached(priority: .low) { try await perform(.pause, .control) }
        try await wait("pause admitted") { app.libraryStartup.admittedCommands == 1 }
        let skip = Task.detached(priority: .high) { try await perform(.skip, .widget) }
        try await wait("skip admitted") { app.libraryStartup.admittedCommands == 2 }
        let rewind = Task.detached(priority: .high) { try await perform(.rewind, .widget) }
        try await wait("rewind admitted") { app.libraryStartup.admittedCommands == 3 }
        rewind.cancel()
        gate.continuation.yield()
        try await play.value; try await pause.value; try await skip.value
        await #expect(throws: CancellationError.self) { try await rewind.value }
        #expect(received == [.play, .pause, .skip])
    }

    /// A widget Play, then a Control Center Pause, both waiting for the start with about a second left. Play is
    /// applied and the player buffers (the widget's settle wait would last up to two seconds); Pause is applied at
    /// once after it, never held behind that wait until its time runs out, through the real router, commands and
    /// widget runtime.
    @Test func controlPauseIsNotHeldBehindAWidgetPlaysSettleWait() async throws {
        let saved = PlayerWidgetIntentRouter.perform
        defer { PlayerWidgetIntentRouter.perform = saved }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlayerWidgetSettle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let widgetStore = PlayerWidgetStore(directory: root.appendingPathComponent("widget"))
        let time = try TimeDisplayPreferenceStore(file: root.appendingPathComponent("time.json"))
        try await PCPlaybackFixture.withFixture { f in
            let runtime = PlayerWidgetRuntime(playback: f.player, library: f.store, store: widgetStore,
                timeDisplay: { time.value }, reload: { _, _ in })
            runtime.start(); defer { runtime.stop() }
            try await f.player.select(episodeID: 1); f.engine.ready(); try await f.player.awaitPendingOperations()
            try await f.player.pause()
            // Buffering: once Play is applied the player wants to play but does not advance.
            f.engine.state(.paused, buffering: true); try await f.player.awaitPendingOperations()
            final class Start { var locked = true }
            let start = Start()
            let startup = LibraryStartup(.init(build: { if start.locked { throw POSIXError(.EPERM) } }, retire: {}, discard: {},
                                               protectedDataAvailable: { !start.locked }, resolved: { _, _ in }))
            startup.start()
            let commands = PlayerWidgetIntentRouter.bound(playback: { f.player }, intervals: { .init() }, widget: { runtime })
            PlayerWidgetIntentRouter.perform = AppDelegate.orderedWidgetRouter(startup: startup, lifetime: .seconds(1)) { commands }
            let play = Task { @MainActor in _ = try await PlayerWidgetPlayPauseIntent(play: true).perform() }
            try await wait("play admitted") { startup.admittedCommands == 1 }
            let pause = Task { @MainActor in
                let toggle = PlayerControlToggleIntent(); toggle.value = false
                _ = try await toggle.perform()
            }
            try await wait("pause admitted") { startup.admittedCommands == 2 }
            start.locked = false
            let started = ContinuousClock.now
            startup.retry()
            try await pause.value
            #expect(ContinuousClock.now - started < .seconds(1), "Pause is applied promptly")
            #expect(!f.player.wantsPlayback, "paused as asked")
            try await play.value
            #expect(!f.player.wantsPlayback)
        }
    }

    // MARK: - Intents on the player

    /// The widget's buttons and the control's toggle, run as the system runs them in the app, act on the player
    /// with the user's "Rewind skip time" and "Fast-forward skip time". Play/Pause does what it shows: a Pause
    /// shown over a paused player leaves it paused, and Play over a playing one keeps it playing.
    @Test func intentsActOnThePlayerWithThePreferredIntervals() async throws {
        let saved = PlayerWidgetIntentRouter.perform
        defer { PlayerWidgetIntentRouter.perform = saved }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlayerWidgetIntents-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let intervals = try PlaybackIntervalPreferenceStore(file: root.appendingPathComponent("intervals.json"))
        var preferred = PlaybackIntervalPreferences(); preferred.rewindSeconds = 20; preferred.forwardSeconds = 45
        try intervals.update(preferred)
        try await PCPlaybackFixture.withFixture { f in
            PlayerWidgetIntentRouter.bind(playback: { f.player }, intervals: { intervals.value })
            _ = try await f.store.enqueue([1, 2, 3])
            try await f.player.select(episodeID: 1); f.engine.ready(); try await f.player.awaitPendingOperations()
            _ = try await PlayerWidgetPlayPauseIntent(play: true).perform()
            #expect(f.player.wantsPlayback)
            _ = try await PlayerWidgetPlayPauseIntent(play: false).perform()
            #expect(!f.player.wantsPlayback)
            _ = try await PlayerWidgetPlayPauseIntent(play: false).perform()
            #expect(!f.player.wantsPlayback && !f.engine.playing)
            _ = try await PlayerWidgetPlayPauseIntent(play: true).perform()
            #expect(f.player.wantsPlayback && f.engine.playing)
            // The buttons the widget draws carry what they show.
            let shown = PlayerWidgetPresentation(snapshot: PlayerWidgetPlayback.snapshot(playback: f.player, timeDisplay: .init(),
                cover: nil, now: Date()), configuration: .init(), date: Date(), narrow: false, hasCover: false)
            #expect(shown.isPlaying && shown.action(for: .playPause) == .command(.pause))
            f.engine.position(50_000); try await f.player.awaitPendingOperations()
            _ = try await PlayerWidgetRewindIntent().perform()
            #expect(f.engine.seeks.last == 30_000)
            _ = try await PlayerWidgetFastForwardIntent().perform()
            #expect(f.engine.seeks.last == 75_000)
            // A changed preference applies to the next tap.
            preferred.forwardSeconds = 10; try intervals.update(preferred)
            _ = try await PlayerWidgetFastForwardIntent().perform()
            #expect(f.engine.seeks.last == 85_000)
            _ = try await PlayerWidgetSkipIntent().perform()
            try await f.player.awaitPendingOperations()
            #expect(f.player.episode?.id == 2)
            f.engine.ready(); try await f.player.awaitPendingOperations()
            let toggle = PlayerControlToggleIntent(); toggle.value = false
            _ = try await toggle.perform()
            #expect(!f.player.wantsPlayback && !f.engine.playing)
            toggle.value = true
            _ = try await toggle.perform()
            #expect(f.player.wantsPlayback && f.engine.playing)
        }
    }

    // MARK: - Links into the app

    private func mainScreen(_ body: @MainActor (LibraryViewController, PlaybackCoordinator) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PlayerWidgetLinks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        do {
            let source = URL(string: "https://example.invalid/feed")!
            let feed = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Podcast", episodes: [
                ParsedEpisode(identifier: "episode", title: "Episode", description: "Notes",
                    media: ParsedMedia(url: "https://example.invalid/media.mp3", size: 0, durationMilliseconds: 60_000))
            ]), source: source.absoluteString, responseURL: source, validator: nil, permanentRedirectURL: nil))
            _ = try await store.beginPlayback(episodeID: feed.episodes[0].id)
            let playback = PlaybackCoordinator(store: store, engine: AVPlayerPlaybackEngine(muted: true))
            let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: playback,
                timeDisplayPreferences: try TimeDisplayPreferenceStore(file: directory.appendingPathComponent("time.json")),
                navigationPreferences: nil,
                speedPreferences: try PlaybackSpeedPreferenceStore(file: directory.appendingPathComponent("speed.json")),
                mobileNetworkPreferences: nil, usage: nil)
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                controller.view.frame = host.view.bounds
                try await body(controller, playback)
            }
            try await playback.stop()
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

    private func player(in view: UIView) -> PlayerView? {
        (view as? PlayerView) ?? view.subviews.lazy.compactMap { player(in: $0) }.first
    }

    /// The cover/text area opens the app with the player expanded (`withOpenPlayer`), closing Settings; the
    /// speed button opens the speed dialog over whatever is on screen.
    @Test func widgetLinksOpenThePlayerAndTheSpeedDialog() async throws {
        try await mainScreen { controller, playback in
            controller.drawerAction(.settings)
            #expect(controller.settingsVisible)
            #expect(controller.openExternalURL(PlayerWidgetLink.player))
            try await wait("player expanded") { (self.player(in: controller.view)?.expansion ?? 0) == 1 }
            #expect(!controller.settingsVisible && playback.episode != nil)
            let player = try #require(self.player(in: controller.view))
            #expect(!player.isHidden)

            #expect(controller.openExternalURL(PlayerWidgetLink.speed))
            try await wait("speed dialog") { controller.presentedViewController is PlaybackSpeedController }
            // Opening it again keeps the one dialog.
            controller.openExternalURL(PlayerWidgetLink.speed)
            try await Task.sleep(for: .milliseconds(100))
            #expect(controller.presentedViewController?.presentedViewController == nil)
            controller.dismiss(animated: false)
            try await wait("dismissed") { controller.presentedViewController == nil }

            // Over another screen (a dialog the app shows), the speed dialog opens on top of it.
            let other = UIViewController(); other.modalPresentationStyle = .overFullScreen
            controller.present(other, animated: false)
            try await wait { controller.presentedViewController === other }
            controller.openExternalURL(PlayerWidgetLink.speed)
            try await wait("speed over the dialog") { other.presentedViewController is PlaybackSpeedController }
        }
    }

    // MARK: - The App Group snapshot

    /// The app writes what the widget shows: the restored episode (never "No media playing" first), play state
    /// changes, seeks and the cover; it does not rewrite for progress the widget predicts itself, and reloads the
    /// control only when the play state changes.
    @Test func runtimeKeepsTheWidgetSnapshotInStepWithThePlayer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlayerWidgetRuntime-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let widgetStore = PlayerWidgetStore(directory: root.appendingPathComponent("widget"))
        let library = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        var reloads: [Bool] = [], shown: [PlayerWidgetSnapshot?] = []
        do {
            // A podcast without its own image gets AntennaPod's generated cover (FeedParserTask.java:58).
            let source = URL(string: "https://example.invalid/feed")!
            var parsed = ParsedFeed(format: .rss, title: "Podcast", episodes: [ParsedEpisode(identifier: "1", title: "Episode 1",
                media: ParsedMedia(url: "https://example.invalid/1.mp3", size: 0, durationMilliseconds: 100_000))])
            parsed.imageURL = "antennapod_generative_cover:" + source.absoluteString
            let feed = try await library.insert(FetchedFeed(feed: parsed, source: source.absoluteString, responseURL: source,
                validator: nil, permanentRedirectURL: nil))
            _ = try await library.beginPlayback(episodeID: feed.episodes[0].id)
            let engine = PCPlaybackEngine()
            let playback = PlaybackCoordinator(store: library, engine: RoutedPlaybackEngine(local: engine))
            let time = try TimeDisplayPreferenceStore(file: root.appendingPathComponent("time.json"))
            let runtime = PlayerWidgetRuntime(playback: playback, library: library, store: widgetStore,
                timeDisplay: { time.value }, reload: { widget, control in
                    #expect(widget, "the app reloads the widget on its own changes")
                    reloads.append(control); shown.append(widgetStore.read())
                })
            runtime.start(); defer { runtime.stop() }
            // The saved episode, never "No media playing" first.
            try await wait("restored episode written") { widgetStore.read()?.episodeID == feed.episodes[0].id }
            #expect(reloads.first == true && shown.first??.episodeID == feed.episodes[0].id)
            var written = try #require(widgetStore.read())
            #expect(written.title == "Episode 1" && !written.isPlaying && written.durationMilliseconds == 100_000)
            // Its cover, as a small square image beside the snapshot.
            try await wait("cover written") { widgetStore.read()?.cover != nil }
            let cover = try #require(widgetStore.read()?.cover.flatMap(widgetStore.cover(named:)).flatMap(UIImage.init(data:)))
            #expect(cover.size.width == cover.size.height && cover.size.width <= 300 && cover.size.width >= 48)

            let beforePlay = reloads.count
            try await playback.play(); engine.ready(); try await playback.awaitPendingOperations()
            try await wait("playing written") { widgetStore.read()?.isPlaying == true && widgetStore.read()?.positionRate == 1 }
            #expect(reloads[beforePlay...].contains(true))
            // Progress along the predicted line is not rewritten.
            let count = reloads.count
            written = try #require(widgetStore.read())
            engine.position(written.position(at: Date()) + 300); try await playback.awaitPendingOperations()
            runtime.refresh()
            #expect(reloads.count == count)
            // A seek is, without reloading the control.
            try await playback.seek(to: 80_000); try await playback.awaitPendingOperations()
            try await wait("seek written") { widgetStore.read().map { abs(Int($0.positionMilliseconds) - 80_000) < 1_000 } == true }
            #expect(reloads.last == false)
            // Quitting the app while it plays: the widget shows the episode paused, not a running time.
            runtime.processEnds()
            let ended = try #require(widgetStore.read())
            #expect(!ended.isPlaying && ended.positionRate == 0 && abs(Int(ended.positionMilliseconds) - 80_000) < 1_000)
            #expect(PlayerWidgetTimeline.schedule(for: ended, now: Date()).entries.count == 1 && reloads.last == true)
            // "Show remaining time" reaches the widget when the app is left.
            try time.toggleRemainingTime()
            NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
            try await wait("time setting written") { widgetStore.read()?.showRemainingTime == true }
            let beforePause = reloads.count
            try await playback.pause()
            try await wait("paused written") { widgetStore.read()?.isPlaying == false }
            #expect(reloads[beforePause...].contains(true))
            try await playback.stop()
            try await library.close()
        } catch { try? await library.close(); throw error }
    }

    private final class Clocks {
        var wall = Date(timeIntervalSince1970: 1_800_000_000)
        var monotonic = ContinuousClock.now
        func advance(_ seconds: Int) { wall.addTimeInterval(TimeInterval(seconds)); monotonic += .seconds(seconds) }
    }

    /// While it plays, the app renews the snapshot's lease about once a minute on its playback events, by its own
    /// monotonic clock, and asks only for the widget to reload; progress along the prediction in between is not
    /// rewritten. The wall clock set back an hour without the app being told does not hold the renewal back; told
    /// (`NSSystemClockDidChange`), it renews at once. A paused snapshot is never renewed.
    @Test func runtimeRenewsThePlayingLeaseAboutOnceAMinute() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlayerWidgetLease-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let widgetStore = PlayerWidgetStore(directory: root.appendingPathComponent("widget"))
        let time = try TimeDisplayPreferenceStore(file: root.appendingPathComponent("time.json"))
        let clocks = Clocks()
        var reloads: [(widget: Bool, control: Bool)] = []
        try await PCPlaybackFixture.withFixture { f in
            let runtime = PlayerWidgetRuntime(playback: f.player, library: f.store, store: widgetStore,
                timeDisplay: { time.value }, reload: { reloads.append(($0, $1)) }, now: { clocks.wall }, clock: { clocks.monotonic })
            runtime.start(); defer { runtime.stop() }
            try await f.player.select(episodeID: 1)
            f.engine.duration = 3_600_000; f.engine.ready(); try await f.player.awaitPendingOperations()
            f.engine.position(10_000); try await f.player.awaitPendingOperations()
            try await wait("playing written") { widgetStore.read().map { $0.positionRate == 1 && $0.positionMilliseconds == 10_000 } == true }
            #expect(widgetStore.read()?.leaseSeconds == PlayerWidgetLease.duration && widgetStore.read()?.isFresh(at: clocks.wall) == true)
            var position: Int32 = 10_000
            /// One second of playback along the prediction, then the runtime's refresh as on a playback event.
            @MainActor func tick(_ seconds: Int = 1) async throws {
                clocks.advance(seconds); position += Int32(seconds * 1_000)
                f.engine.position(position); try await f.player.awaitPendingOperations()
                runtime.refresh()
            }
            reloads.removeAll()
            var renewedAt = clocks.wall
            for _ in 1..<60 { try await tick() }
            #expect(reloads.isEmpty && widgetStore.read()?.savedAt == renewedAt, "\(reloads)")
            // A minute after the last write: renewed, the widget reloaded, not the control.
            try await tick()
            renewedAt = clocks.wall
            #expect(widgetStore.read()?.savedAt == renewedAt && widgetStore.read()?.positionMilliseconds == position)
            #expect(reloads.count == 1 && reloads.allSatisfy { $0.widget && !$0.control }, "\(reloads)")
            for _ in 1..<60 { try await tick() }
            #expect(reloads.count == 1)
            try await tick()
            #expect(reloads.count == 2 && widgetStore.read()?.savedAt == clocks.wall)

            // Buffering: nothing to predict, so only the cadence renews it.
            f.engine.state(.playing, buffering: true); try await f.player.awaitPendingOperations()
            try await wait("buffering written") { widgetStore.read()?.positionRate == 0 }
            #expect(widgetStore.read()?.isPlaying == true)
            reloads.removeAll()
            // The wall clock set back an hour, the app not told: renewed a minute later by the monotonic clock.
            clocks.wall.addTimeInterval(-3_600)
            for _ in 1...59 { clocks.monotonic += .seconds(1); clocks.wall.addTimeInterval(1); runtime.refresh() }
            #expect(reloads.isEmpty && widgetStore.read()?.isFresh(at: clocks.wall) == false)
            clocks.monotonic += .seconds(1); clocks.wall.addTimeInterval(1); runtime.refresh()
            #expect(reloads.count == 1 && widgetStore.read()?.savedAt == clocks.wall && widgetStore.read()?.isFresh(at: clocks.wall) == true)
            // Set forward two hours, the app told: renewed at once.
            clocks.wall.addTimeInterval(7_200)
            #expect(widgetStore.read()?.isFresh(at: clocks.wall) == false)
            NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
            try await wait("renewed once told") { reloads.count == 2 }
            #expect(widgetStore.read()?.savedAt == clocks.wall && widgetStore.read()?.isFresh(at: clocks.wall) == true)

            // Paused: written once, never renewed.
            try await f.player.pause()
            try await wait("paused written") { widgetStore.read()?.isPlaying == false }
            reloads.removeAll()
            let paused = widgetStore.read()
            clocks.advance(600); runtime.refresh()
            #expect(reloads.isEmpty && widgetStore.read() == paused)
        }
    }

    /// The lease renews from the coordinator's own events, without the test calling `refresh`: a live stream
    /// (unknown duration, which has no position events) whose position advances at its rate, three times its rate
    /// (Skip silence) or irregularly, and buffering with and without a known duration, for four leases. Every second
    /// the shared file holds a playing snapshot whose lease holds, and the app asked for the widget to reload once a
    /// minute: a live stream's position drift shows nothing, so it causes no extra writes.
    @Test(arguments: [(Int32(0), false, [Int32(1_000)]), (Int32(0), false, [3_000]), (Int32(0), false, [500, 4_000, 1_500, 0, 3_000]),
                      (Int32(0), true, [0]), (Int32(3_600_000), true, [0])])
    func runtimeRenewsFromPlaybackEventsAlone(duration: Int32, buffering: Bool, steps: [Int32]) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlayerWidgetEvents-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let widgetStore = PlayerWidgetStore(directory: root.appendingPathComponent("widget"))
        let time = try TimeDisplayPreferenceStore(file: root.appendingPathComponent("time.json"))
        let clocks = Clocks()
        var reloads: [(widget: Bool, control: Bool)] = []
        try await PCPlaybackFixture.withFixture { f in
            let runtime = PlayerWidgetRuntime(playback: f.player, library: f.store, store: widgetStore,
                timeDisplay: { time.value }, reload: { reloads.append(($0, $1)) }, now: { clocks.wall }, clock: { clocks.monotonic })
            runtime.start(); defer { runtime.stop() }
            try await f.player.select(episodeID: 1)
            f.engine.duration = duration; f.engine.ready(); try await f.player.awaitPendingOperations()
            if buffering { f.engine.state(.playing, buffering: true); try await f.player.awaitPendingOperations() }
            try await wait("playing written") {
                widgetStore.read().map { $0.isPlaying && $0.positionRate == (buffering ? 0 : 1) && $0.durationMilliseconds == duration } == true
            }
            reloads.removeAll()
            var position: Int32 = 0, stale: [Int] = []
            for second in 1...720 {
                clocks.advance(1)
                position += steps[second % steps.count]
                f.engine.position(position); try await f.player.awaitPendingOperations()
                if second % 60 == 0 { try await wait("renewed at \(second) s") { reloads.count == second / 60 } }
                if widgetStore.read()?.isFresh(at: clocks.wall) != true { stale.append(second) }
            }
            #expect(stale.isEmpty, "\(stale)")
            #expect(reloads.count == 12 && reloads.allSatisfy { $0.widget && !$0.control }, "\(reloads)")
            #expect(widgetStore.read().map { $0.isPlaying && $0.savedAt == clocks.wall } == true)
        }
    }

    /// A Play/Pause button drawn before buttons said Play or Pause (the intent without `play`) may still show Pause
    /// over a silent player: the one the app restored after it ended, one paused by an interruption or headphone
    /// removal, one being prepared paused. Nothing plays, and the widget is asked to draw again with today's
    /// buttons. It only pauses a playing player. Explicit Pause there changes nothing and Play plays.
    @Test func aLegacyPlayPauseNeverStartsPlayback() async throws {
        let saved = PlayerWidgetIntentRouter.perform
        defer { PlayerWidgetIntentRouter.perform = saved }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlayerWidgetLegacy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let widgetStore = PlayerWidgetStore(directory: root.appendingPathComponent("widget"))
        let time = try TimeDisplayPreferenceStore(file: root.appendingPathComponent("time.json"))
        var reloads: [(widget: Bool, control: Bool)] = []
        try await PCPlaybackFixture.withFixture { f in
            // The app played episode 2 and ended; its selection is saved.
            try await f.player.select(episodeID: 2); f.engine.ready(); try await f.player.awaitPendingOperations()
            f.engine.position(42_000); try await f.player.awaitPendingOperations()
            try await f.player.pause(); try await f.player.stop()
            // Launched again for the tap: a new player and widget runtime.
            let engine = PCPlaybackEngine()
            let launched = PlaybackCoordinator(store: f.store, engine: RoutedPlaybackEngine(local: engine))
            let runtime = PlayerWidgetRuntime(playback: launched, library: f.store, store: widgetStore,
                timeDisplay: { time.value }, reload: { reloads.append(($0, $1)) })
            runtime.start(); defer { runtime.stop() }
            PlayerWidgetIntentRouter.bind(playback: { launched }, intervals: { .init() }, widget: { runtime })
            try await wait("restored episode written") { widgetStore.read()?.episodeID == 2 }
            reloads.removeAll()
            _ = try await PlayerWidgetPlayPauseIntent().perform()
            #expect(launched.episode?.id == 2 && !launched.wantsPlayback && !engine.playing && engine.reading == nil)
            #expect(reloads.contains { $0.widget } && widgetStore.read()?.isPlaying == false, "\(reloads)")
            _ = try await PlayerWidgetPlayPauseIntent(play: false).perform()
            #expect(!launched.wantsPlayback && !engine.playing && engine.reading == nil)
            let play = Task { @MainActor in _ = try await PlayerWidgetPlayPauseIntent(play: true).perform() }
            try await wait("loading") { launched.wantsPlayback }
            engine.ready()
            try await play.value
            #expect(launched.wantsPlayback && engine.playing && widgetStore.read()?.isPlaying == true)
            // Playing: the old button pauses.
            _ = try await PlayerWidgetPlayPauseIntent().perform()
            #expect(!launched.wantsPlayback && !engine.playing && widgetStore.read()?.isPlaying == false)
            // Paused, loaded: refused, redrawn.
            reloads.removeAll()
            _ = try await PlayerWidgetPlayPauseIntent().perform()
            #expect(!launched.wantsPlayback && !engine.playing && reloads.contains { $0.widget }, "\(reloads)")
            // Paused from outside (an interruption, headphones removed) while the old widget shows Pause: refused.
            try await launched.play(); try await launched.awaitPendingOperations()
            #expect(launched.wantsPlayback && engine.playing)
            try await wait("playing written") { widgetStore.read()?.isPlaying == true }
            engine.state(.paused); try await launched.awaitPendingOperations()
            #expect(!launched.wantsPlayback && launched.phase == .paused && engine.reading != nil)
            try await wait("paused written") { widgetStore.read()?.isPlaying == false }
            reloads.removeAll()
            _ = try await PlayerWidgetPlayPauseIntent().perform()
            try await launched.awaitPendingOperations()
            #expect(!launched.wantsPlayback && !engine.playing && launched.phase == .paused)
            #expect(reloads.contains { $0.widget }, "\(reloads)")
            // Being prepared paused (selected without playing, still loading): refused; it stays paused when ready.
            try await launched.select(episodeID: 1, play: false)
            #expect(launched.phase == .preparing && !launched.wantsPlayback)
            try await wait("episode 1 written") { widgetStore.read().map { $0.episodeID == 1 && !$0.isPlaying } == true }
            reloads.removeAll()
            _ = try await PlayerWidgetPlayPauseIntent().perform()
            #expect(!launched.wantsPlayback && reloads.contains { $0.widget }, "\(reloads)")
            engine.ready(); try await launched.awaitPendingOperations()
            #expect(launched.episode?.id == 1 && !launched.wantsPlayback && !engine.playing)
            try await launched.stop()
        }
    }

    /// A widget button: the system reloads the widget once the command returns, so the settled result (after a
    /// seek still under way) is written by then and the app does not reload the widget itself; a second reload a
    /// moment later replaced the widget under the next tap, and that tap was lost. The control's toggle is reloaded
    /// by the system as a control only, so the app still reloads the widget for it.
    @Test func widgetButtonsWriteTheSettledResultAndLeaveTheReloadToTheSystem() async throws {
        let saved = PlayerWidgetIntentRouter.perform
        defer { PlayerWidgetIntentRouter.perform = saved }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlayerWidgetCommands-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let widgetStore = PlayerWidgetStore(directory: root.appendingPathComponent("widget"))
        let time = try TimeDisplayPreferenceStore(file: root.appendingPathComponent("time.json"))
        var reloads: [(widget: Bool, control: Bool)] = []
        try await PCPlaybackFixture.withFixture { f in
            let runtime = PlayerWidgetRuntime(playback: f.player, library: f.store, store: widgetStore,
                timeDisplay: { time.value }, reload: { reloads.append(($0, $1)) })
            runtime.start(); defer { runtime.stop() }
            PlayerWidgetIntentRouter.bind(playback: { f.player }, intervals: { .init() }, widget: { runtime })
            try await f.player.select(episodeID: 1); f.engine.ready(); try await f.player.awaitPendingOperations()
            f.engine.position(50_000); try await f.player.awaitPendingOperations()
            try await wait("playing written") { widgetStore.read()?.positionRate == 1 }

            // Rewind while the seek is still under way when the command itself is done.
            reloads.removeAll()
            try await runtime.runWidgetCommand {
                _ = try await PlayerWidgetPlayback.perform(.rewind, playback: f.player, intervals: .init())
                f.engine.state(.playing, buffering: true)
                Task { @MainActor in f.engine.state(.playing, buffering: false) }
            }
            let rewound = try #require(widgetStore.read())
            #expect(rewound.isPlaying && rewound.positionRate == 1, "\(rewound)")
            #expect(abs(Int(rewound.positionMilliseconds) - 40_000) < 1_000, "\(rewound)")
            #expect(!reloads.contains { $0.widget }, "\(reloads)")

            // Pause from the widget: written before the intent returns; only the control is reloaded by the app.
            reloads.removeAll()
            _ = try await PlayerWidgetPlayPauseIntent(play: false).perform()
            #expect(widgetStore.read()?.isPlaying == false)
            #expect(!reloads.contains { $0.widget } && reloads.contains { $0.control }, "\(reloads)")

            // The control's toggle: the app reloads the widget.
            reloads.removeAll()
            let toggle = PlayerControlToggleIntent(); toggle.value = true
            _ = try await toggle.perform()
            try await wait("playing written and the widget reloaded") {
                widgetStore.read()?.isPlaying == true && reloads.contains { $0.widget && $0.control }
            }
        }
    }
}
