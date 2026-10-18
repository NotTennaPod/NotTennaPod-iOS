import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// These checks use each control's actual text rect and every enclosing clipping
/// viewport, so an offscreen control or clipped label cannot pass via sendActions alone.
@MainActor @Suite(.serialized)
struct SleepTimerAccessibilityTests {
    private func find<T: UIView>(_ id: String, in root: UIView) throws -> T {
        func search(_ view: UIView) -> T? {
            if view.accessibilityIdentifier == id { return view as? T }
            return view.subviews.lazy.compactMap { search($0) }.first
        }
        return try #require(search(root), "Missing control: \(id)")
    }
    private func visible(_ view: UIView, in window: UIWindow) -> CGRect {
        var result = view.convert(view.bounds, to: window).intersection(window.bounds)
        var ancestor: UIView? = view
        while let value = ancestor {
            if value.isHidden || value.alpha < 0.01 { return .null }
            if value.clipsToBounds { result = result.intersection(value.convert(value.bounds, to: window)) }
            ancestor = value.superview
        }
        return result
    }
    private func reveal(_ rect: CGRect, of view: UIView) {
        var ancestor = view.superview
        while let value = ancestor {
            if let scroll = value as? UIScrollView, scroll.isScrollEnabled {
                scroll.scrollRectToVisible(view.convert(rect, to: scroll), animated: false)
                scroll.layoutIfNeeded()
            }
            ancestor = value.superview
        }
    }
    private func verifyReachable(_ control: UIControl, in window: UIWindow) {
        #expect(!control.isHidden, "\(control.accessibilityIdentifier ?? "control") must be displayed")
        var textRect = control.bounds
        var line = min(44, control.bounds.height)
        if let button = control as? UIButton, let label = button.titleLabel, let text = label.text, !text.isEmpty {
            textRect = button.titleRect(forContentRect: button.contentRect(forBounds: button.bounds))
            let required = (text as NSString).boundingRect(with: CGSize(width: max(1, textRect.width), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: label.font!], context: nil).size
            #expect(required.height <= textRect.height + 1,
                "\(control.accessibilityIdentifier ?? text) needs \(required.height)pt for full text, has \(textRect.height)pt")
            if label.numberOfLines == 1 {
                let unwrapped = (text as NSString).size(withAttributes: [.font: label.font!])
                #expect(unwrapped.width <= textRect.width + 1,
                    "\(control.accessibilityIdentifier ?? text) truncates its one-line label: \(unwrapped.width) > \(textRect.width)")
            }
            line = min(label.font.lineHeight, textRect.height)
        }
        // A control taller than the viewport remains valid when both ends of
        // its text can be revealed. Do not require the entire control at once.
        for y in [textRect.minY, max(textRect.minY, textRect.maxY - line)] {
            let target = CGRect(x: textRect.minX, y: y, width: textRect.width, height: line)
            reveal(target, of: control)
            let frame = control.convert(target, to: window)
            let exposed = visible(control, in: window).intersection(frame)
            #expect(exposed.width >= frame.width - 1 && exposed.height >= frame.height - 1,
                "\(control.accessibilityIdentifier ?? "control") text must be reachable through its real scroll viewport")
            if !exposed.isNull && !exposed.isEmpty {
                let hit = window.hitTest(CGPoint(x: exposed.midX, y: exposed.midY), with: nil)
                #expect(hit === control || hit?.isDescendant(of: control) == true,
                    "\(control.accessibilityIdentifier ?? "control") must receive the exposed hit")
            }
        }
    }
    private func fixture(_ body: @MainActor (SleepTimerController, SleepTimerPreferenceStore, PlaybackQueuePreferenceStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SleepAccessibility-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        do {
            let sleep = try SleepTimerPreferenceStore(file: directory.appendingPathComponent("sleep.json"))
            let queue = try PlaybackQueuePreferenceStore(file: directory.appendingPathComponent("queue.json"))
            let playback = PlaybackCoordinator(store: library, engine: AVPlayerPlaybackEngine(muted: true), sleepTimerPreferences: sleep)
            let controller = SleepTimerController(playback: playback, preferences: sleep, queuePreferences: queue,
                library: library, openPlaybackSettings: {})
            try await body(controller, sleep, queue)
            try await library.close()
        } catch { try? await library.close(); throw error }
    }

    @Test(arguments: [false, true])
    func setupControlsStayReadableReachableAndOrderedAtLargestText(rtl: Bool) async throws {
        try await fixture { controller, preferences, _ in
            try await withViewTestWindow { host, window in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
                controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                let input: UITextField = try find("sleepTimerInput", in: controller.view)
                input.text = "123"; input.sendActions(for: .editingChanged)
                let ids = ["sleepTimerSet", "sleepTimerShake", "sleepTimerVibrate", "sleepTimerAutomatic", "sleepTimerHours"]
                let controls: [UIButton] = try ids.map { try find($0, in: controller.view) }
                for size in [CGSize(width: 340, height: 300), CGSize(width: 320, height: 240), CGSize(width: 340, height: 300)] {
                    controller.view.frame = CGRect(origin: CGPoint(x: host.view.safeAreaInsets.left, y: host.view.safeAreaInsets.top), size: size)
                    for insets in [UIEdgeInsets(top: 0, left: 23, bottom: 0, right: 7), .init(top: 0, left: 7, bottom: 0, right: 23)] {
                        controller.additionalSafeAreaInsets = insets
                        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                        #expect(input.text == "123")
                        // Source order is independent of scroll offset and view hierarchy.
                        for (before, after) in zip(controls.prefix(3), controls.dropFirst().prefix(3)) {
                            // Conversion through a scrolled 3x-scale viewport
                            // can round the same shared edge by ~3e-14 points.
                            #expect(before.convert(before.bounds, to: controller.view).maxY <= after.convert(after.bounds, to: controller.view).minY + 0.000001)
                        }
                        let automatic = controls[3], hours = controls[4]
                        #expect(abs(automatic.convert(automatic.bounds, to: controller.view).midY - hours.convert(hours.bounds, to: controller.view).midY) < 1)
                        for control in controls { verifyReachable(control, in: window) }
                    }
                }
                for control in controls[1...3] {
                    verifyReachable(control, in: window); control.sendActions(for: .touchUpInside)
                }
                #expect(!preferences.value.shakeToReset && preferences.value.vibrate && preferences.value.autoEnable)
                controller.view.frame.size = CGSize(width: 320, height: 240)
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                #expect(input.text == "123" && !preferences.value.shakeToReset && preferences.value.vibrate && preferences.value.autoEnable)
            }
        }
    }

    @Test(arguments: [false, true])
    func modePopupAndBlockedSettingsRemainReachableAtLargestText(rtl: Bool) async throws {
        try await fixture { controller, preferences, queue in
            try await withViewTestWindow { host, window in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
                controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                controller.view.frame = CGRect(x: host.view.safeAreaInsets.left, y: host.view.safeAreaInsets.top, width: 320, height: 280)
                controller.additionalSafeAreaInsets = .init(top: 0, left: 23, bottom: 0, right: 7)
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                let input: UITextField = try find("sleepTimerInput", in: controller.view)
                input.text = "123"; input.sendActions(for: .editingChanged)
                let mode: UIButton = try find("sleepTimerMode", in: controller.view)
                for (choiceID, expected) in [("sleepTimerModeEpisodes", SleepTimerMode.episodes), ("sleepTimerModeMinutes", .minutes), ("sleepTimerModeEpisodes", .episodes)] {
                    verifyReachable(mode, in: window)
                    mode.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
                    let minutes: UIButton = try find("sleepTimerModeMinutes", in: controller.view)
                    let episodes: UIButton = try find("sleepTimerModeEpisodes", in: controller.view)
                    verifyReachable(minutes, in: window); verifyReachable(episodes, in: window)
                    let choice: UIButton = try find(choiceID, in: controller.view)
                    verifyReachable(choice, in: window); choice.sendActions(for: .touchUpInside)
                    controller.view.layoutIfNeeded()
                    #expect(preferences.value.mode == expected)
                    verifyReachable(mode, in: window)
                    if expected == .minutes { #expect(input.text == "123") }
                }
                var value = queue.value; value.followQueue = false; try queue.update(value)
                input.sendActions(for: .editingChanged); controller.view.layoutIfNeeded()
                let settings: UIButton = try find("sleepTimerPlaybackSettings", in: controller.view)
                verifyReachable(settings, in: window)
                let set: UIButton = try find("sleepTimerSet", in: controller.view)
                #expect(!set.isEnabled && !input.isEnabled)
                let hint: UILabel = try find("sleepTimerHint", in: controller.view)
                #expect(hint.text == Appearance.text("multiple_sleep_episodes_while_continuous_playback_disabled") && !hint.isHidden)
                for y in [CGFloat.zero, max(0, hint.bounds.height - hint.font.lineHeight)] {
                    let line = CGRect(x: 0, y: y, width: hint.bounds.width, height: hint.font.lineHeight)
                    reveal(line, of: hint)
                    #expect(visible(hint, in: window).intersection(hint.convert(line, to: window)).height >= hint.font.lineHeight - 1)
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func paintedCheckboxStaysSquareAndSeparateFromTextAfterWidthChanges(rtl: Bool) async throws {
        try await fixture { controller, _, _ in
            try await withViewTestWindow { host, _ in
                controller.loadViewIfNeeded()
                controller.view.frame = CGRect(x: 0, y: 0, width: 340, height: 600)
                controller.traitOverrides.preferredContentSizeCategory = .large
                controller.view.layoutIfNeeded()
                let checkbox: UIButton = try find("sleepTimerShake", in: controller.view)
                // Keep the real configured control and its draw implementation,
                // but isolate width changes from owner refreshes that also call
                // setNeedsDisplay and could hide a stale-layer scaling defect.
                checkbox.removeFromSuperview()
                let canvas = UIView(frame: CGRect(x: 16, y: host.view.safeAreaInsets.top + 16, width: 320, height: 88))
                canvas.overrideUserInterfaceStyle = .light
                canvas.backgroundColor = .white
                canvas.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                checkbox.semanticContentAttribute = canvas.semanticContentAttribute
                host.view.addSubview(canvas); canvas.addSubview(checkbox)
                defer { canvas.removeFromSuperview() }
                #expect(checkbox.accessibilityValue == "On")
                for width: CGFloat in [120, 300, 180, 120] {
                    checkbox.frame = CGRect(x: 0, y: 20, width: width, height: 48)
                    canvas.layoutIfNeeded(); checkbox.layoutIfNeeded()
                    // Flush only invalidated layers. scaleToFill leaves the old
                    // drawing clean; redraw invalidates it on bounds changes.
                    // Never call setNeedsDisplay or drawHierarchy here: either
                    // could conceal the retained-layer defect being tested.
                    checkbox.layer.displayIfNeeded()
                    checkbox.titleLabel?.layer.displayIfNeeded()
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 3; format.opaque = true; format.preferredRange = .standard
                    let image = UIGraphicsImageRenderer(bounds: checkbox.bounds, format: format).image { context in
                        UIColor.white.setFill(); context.fill(checkbox.bounds)
                        checkbox.layer.render(in: context.cgContext)
                    }
                    let boxes = try checkboxPixelBounds(image)
                    let mark = try #require(boxes.mark, "Checked square must actually render")
                    let text = try #require(boxes.text, "Checkbox label must actually render")
                    // The source paints an 18pt square with a 2pt outline. A visibly
                    // stretched or resized box fails; sub-point raster differences do not.
                    let tolerance: CGFloat = 1
                    #expect(abs(mark.width - mark.height) <= tolerance,
                        "width=\(width), rtl=\(rtl): checkbox raster stretched to \(mark.size)")
                    #expect(abs(mark.width - 20) <= tolerance && abs(mark.height - 20) <= tolerance)
                    #expect(rtl ? text.maxX < mark.minX : mark.maxX < text.minX,
                        "width=\(width), rtl=\(rtl): painted checkbox \(mark) overlaps painted label \(text)")
                }
            }
        }
    }

    private func checkboxPixelBounds(_ image: UIImage) throws -> (mark: CGRect?, text: CGRect?) {
        let source = try #require(image.cgImage)
        let width = source.width, height = source.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(rendered)
        var mark: CGRect?, text: CGRect?
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
                let pixel = CGRect(x: CGFloat(x) / image.scale, y: CGFloat(y) / image.scale,
                    width: 1 / image.scale, height: 1 / image.scale)
                // Accent-blue drawing and foreground-black text remain distinct
                // even at antialiased edges; white check/parent pixels are excluded.
                if b > r + 40 && b > g + 20 && g > r + 20 { mark = mark.map { $0.union(pixel) } ?? pixel }
                else if r < 80 && g < 80 && b < 80 { text = text.map { $0.union(pixel) } ?? pixel }
            }
        }
        return (mark, text)
    }
}
