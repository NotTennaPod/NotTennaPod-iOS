import XCTest

/// Widget journeys on the real Home Screen and Control Center:
/// add the AntennaPod widget with its settings, see the paused episode, play and pause it, rewind, open the speed
/// dialog; the widget's opacity; and the Control Center control. The episode comes from the playback-audio fixture
/// (59431), downloaded as a person would. Labels of the iOS 27 Home Screen were recorded from the Simulator.
@MainActor final class PlayerWidgetJourneyTests: XCTestCase {
    private let app = XCUIApplication()
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let library = UUID().uuidString
    private let title = "Playback mp3"

    override func setUp() {
        continueAfterFailure = false
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback"]
    }

    private func label(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 10,
                       file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "\(element) label \(element.exists ? element.label : "missing"), want \(value)", file: file, line: line)
    }

    private func until(_ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line,
                       _ condition: @escaping @MainActor () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, what, file: file, line: line)
    }

    private func seconds(_ text: String) -> Int? {
        let fields = text.prefix(8).split(separator: ":").compactMap { Int($0) }
        guard fields.count == 3 else { return nil }
        return fields.reduce(0) { $0 * 60 + $1 }
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    /// Subscribes to the fixture feed, downloads its episode, plays it and pauses it at about 20 s.
    private func preparePausedEpisode() {
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 15))
        app.buttons["navigationMore"].tapWhenSettled(); app.buttons["Add podcast"].tapWhenSettled(); app.buttons["addRSS"].tapWhenSettled()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tapWhenSettled()
        address.typeTextSettled("http://127.0.0.1:59431/feed.xml?format=mp3&run=widget-\(library)")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15)); app.buttons["subscribeFeed"].tapWhenSettled()
        let action = app.buttons["episode-action-1"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        XCTAssertEqual(action.label, "Download"); action.tapWhenSettled()
        label(action, "Play", timeout: 30); action.tapWhenSettled()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 15))
        label(app.buttons["miniPlayerPlay"], "Pause")
        app.buttons["miniPlayerOpen"].tapWhenSettled()
        let position = app.staticTexts["playerPosition"]
        until("played to 20 s", timeout: 40) { self.seconds(position.label).map { $0 >= 20 } == true }
        app.buttons["playerPlay"].tapWhenSettled(); label(app.buttons["playerPlay"], "Play")
    }

    /// The Home Screen in edit mode, as a person gets there: long-press AntennaPod's icon, "Edit Home Screen".
    private func editHomeScreen(file: StaticString = #filePath, line: UInt = #line) {
        XCUIDevice.shared.leaveApp()
        // AntennaPod's app icon, not its widget (also an "NotTennaPod" icon, valued "Widget").
        let icon = springboard.icons.matching(NSPredicate(format: "identifier == %@ AND NOT (value CONTAINS[c] %@)",
                                                          "NotTennaPod", "Widget")).firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 10), springboard.debugDescription, file: file, line: line)
        var pages = 0
        while !icon.isHittable && pages < 6 { springboard.swipeLeft(); pages += 1 }
        icon.press(forDuration: 1.5)
        let edit = springboard.buttons["Edit Home Screen"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), springboard.debugDescription, file: file, line: line)
        edit.tapWhenSettled()
    }

    /// Edit → Add Widget → search "NotTennaPod" → the medium size → Add Widget. With `promptsForUserConfiguration`
    /// iOS then shows "Widget settings" (Android's configuration on add).
    private func addMediumWidget(file: StaticString = #filePath, line: UInt = #line) {
        addWidget(size: "Medium", file: file, line: line)
    }

    private func addWidget(size: String, file: StaticString = #filePath, line: UInt = #line) {
        editHomeScreen(file: file, line: line)
        let edit = springboard.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), springboard.debugDescription, file: file, line: line)
        edit.tapWhenSettled()
        let menuItem = springboard.buttons["Add Widget"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), springboard.debugDescription, file: file, line: line)
        menuItem.tapWhenSettled()
        let search = springboard.searchFields["Search Widgets"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), springboard.debugDescription, file: file, line: line)
        search.tapWhenSettled(); search.typeTextSettled("NotTennaPod")
        let result = springboard.cells["NotTennaPod"]
        XCTAssertTrue(result.waitForExistence(timeout: 10), springboard.debugDescription, file: file, line: line)
        result.tapWhenSettled()
        let chosenSize = springboard.buttons.matching(NSPredicate(format: "value CONTAINS %@", size)).firstMatch
        var swipes = 0
        while !(chosenSize.exists && chosenSize.isHittable) && swipes < 3 { springboard.swipeLeft(); swipes += 1 }
        XCTAssertTrue(chosenSize.isHittable, springboard.debugDescription, file: file, line: line)
        // The size page's button reads " Add Widget" (a symbol, then the words).
        let add = springboard.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "Add Widget")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), springboard.debugDescription, file: file, line: line)
        add.tapWhenSettled()
        addTeardownBlock { @MainActor in self.removeWidget() }
    }

    /// The rows of "Widget settings" now on screen, top to bottom.
    private func visibleSettingRows() -> [String] {
        springboard.switches.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
            .sorted { $0.frame.midY < $1.frame.midY }.map(\.label)
    }

    /// Scrolls "Widget settings" by about a row and a half, dragging on the rows' names (not their switches).
    private func scrollSettings(down: Bool) {
        let rows = springboard.switches.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        guard let edge = down ? rows.max(by: { $0.frame.midY < $1.frame.midY })
                              : rows.min(by: { $0.frame.midY < $1.frame.midY }) else { return }
        let origin = springboard.coordinate(withNormalizedOffset: .zero)
        let x = springboard.frame.width * 0.35
        origin.withOffset(CGVector(dx: x, dy: edge.frame.midY))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x, dy: edge.frame.midY + (down ? -140 : 140))))
    }

    /// A row of "Widget settings". The sheet shows about five of its six rows; scroll it for the rest.
    private func setting(_ name: String) -> XCUIElement {
        let toggle = springboard.switches[name]
        _ = toggle.waitForExistence(timeout: 3)
        for down in [true, true, true, false, false, false, false, false, false] where !(toggle.exists && toggle.isHittable) {
            scrollSettings(down: down)
        }
        XCTAssertTrue(toggle.exists && toggle.isHittable, "\(name)\n\(springboard.debugDescription)")
        return toggle
    }

    private func turnOn(_ names: [String]) {
        for name in names {
            let toggle = setting(name)
            // The switch element spans the whole row; its switch is at the trailing end.
            if (toggle.value as? String) != "1" {
                _ = settledFrame(of: toggle)
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            }
            until("\(name) on", timeout: 5) { (toggle.value as? String) == "1" }
        }
    }

    /// Closes "Widget settings" (a tap above the card) and leaves edit mode.
    /// The journeys leave the Simulator's Home Screen as they found it: remove the widget they added.
    private func removeWidget() {
        // A failed step can leave "Widget settings" open and the Home Screen in edit mode.
        if springboard.sliders.firstMatch.exists || springboard.switches.firstMatch.exists {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.09)).tap()
            _ = springboard.switches.firstMatch.waitForNonExistence(timeout: 5)
        }
        if springboard.buttons["Done"].exists { springboard.buttons["Done"].tapWhenSettled() }
        XCUIDevice.shared.leaveApp()
        let widgets = springboard.icons.matching(NSPredicate(format: "identifier == %@ AND value CONTAINS[c] %@",
                                                             "NotTennaPod", "Widget"))
        var removed = 0
        while widgets.firstMatch.waitForExistence(timeout: 5) && removed < 3 {
            let widget = widgets.firstMatch
            var pages = 0
            while !widget.isHittable && pages < 6 { springboard.swipeLeft(); pages += 1 }
            // A short press opens the widget's menu; a long one goes straight to editing the Home Screen.
            _ = settledFrame(of: widget)
            widget.press(forDuration: 0.8)
            let remove = springboard.buttons["com.apple.springboardhome.application-shortcut-item.remove-widget"]
            XCTAssertTrue(remove.waitForExistence(timeout: 5), springboard.debugDescription)
            remove.tapWhenSettled()
            let confirm = springboard.alerts.buttons["Remove"]
            if confirm.waitForExistence(timeout: 5) { confirm.tapWhenSettled() }
            if springboard.buttons["Done"].waitForExistence(timeout: 2) { springboard.buttons["Done"].tapWhenSettled() }
            removed += 1
        }
        XCTAssertFalse(widgets.firstMatch.exists, "NotTennaPod widget left on the Home Screen\n\(springboard.debugDescription)")
    }

    private func closeSettingsAndEditing() {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.09)).tap()
        XCTAssertTrue(springboard.switches.firstMatch.waitForNonExistence(timeout: 5), springboard.debugDescription)
        XCTAssertFalse(springboard.sliders.firstMatch.exists, springboard.debugDescription)
        let done = springboard.buttons["Done"]
        if done.waitForExistence(timeout: 5) { done.tapWhenSettled() }
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), springboard.debugDescription)
    }

    /// The settings of the added widget: long-press it, "Edit Widget".
    private func editWidget(anchor: XCUIElement) {
        _ = settledFrame(of: anchor)
        anchor.press(forDuration: 1.5)
        let edit = springboard.buttons["Edit Widget"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), springboard.debugDescription)
        edit.tapWhenSettled()
    }

    /// Wait for the element's layout, including system sheets, before a coordinate gesture or screenshot.
    /// Match the existing settled-tap helper's 1.2 s unchanged-frame condition; no fixed sleeps.
    private func settledFrame(of element: XCUIElement) -> CGRect {
        var previous = element.frame, stableSince = Date()
        until("\(element.identifier) frame settled", timeout: 5) {
            guard element.exists && element.isHittable else { return false }
            let current = element.frame
            if current != previous || current.isEmpty { previous = current; stableSince = Date(); return false }
            return Date().timeIntervalSince(stableSince) >= 1.2
        }
        return element.frame
    }

    private func distanceFromBackground(_ pixel: RGB?) -> Int {
        guard let pixel else { return 0 }
        return distance(pixel, RGB(r: 0x26, g: 0x2C, b: 0x31))
    }
    private func distance(_ a: RGB?, _ b: RGB) -> Int {
        guard let a else { return 0 }
        return abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
    }

    private struct RGB: CustomStringConvertible { let r, g, b: Int; var description: String { "(\(r), \(g), \(b))" } }
    private func pixel(at point: CGPoint) throws -> RGB {
        let image = XCUIScreen.main.screenshot().image
        let cg = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(cg.width) / image.size.width
        var data = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: -point.x * scale, y: -(CGFloat(cg.height) - point.y * scale), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return RGB(r: Int(data[0]), g: Int(data[1]), b: Int(data[2]))
    }

    /// Android's configuration on add: Rewind, Fast-forward, Skip episode and Playback speed chosen in "Widget
    /// settings"; the widget then shows the paused episode with Android's row in its order; Play/Pause and Rewind act
    /// on the player in the background and the widget follows; the opacity setting; Playback speed opens the app on
    /// the speed dialog, whose player agrees with the widget.
    func testWidgetShowsTheEpisodeAndItsButtonsControlThePlayer() throws {
        restoreHomeScreenAndControlCenter()
        preparePausedEpisode()
        addMediumWidget()
        // "Widget settings": Android's rows in its order, all off by default, Opacity 100 %.
        let opacity = springboard.sliders.firstMatch
        XCTAssertTrue(opacity.waitForExistence(timeout: 10), springboard.debugDescription)
        XCTAssertEqual(opacity.value as? String, "100%")
        let names = ["Playback speed", "Rewind", "Fast-forward", "Skip episode"]
        let order = names + ["Cover as background"]
        // The sheet shows about five rows: Opacity, then the first rows in Android's order; scrolled to the end,
        // the last rows in Android's order. Together they are the whole order.
        let before = visibleSettingRows()
        XCTAssertFalse(before.isEmpty, springboard.debugDescription)
        XCTAssertEqual(before, Array(order.prefix(before.count)), "Android's order")
        XCTAssertLessThan(opacity.frame.midY, springboard.switches[before[0]].frame.midY, "Opacity first")
        let cover = setting("Cover as background")
        let after = visibleSettingRows()
        XCTAssertEqual(after, Array(order.suffix(after.count)), "Android's order")
        XCTAssertGreaterThanOrEqual(before.count + after.count, order.count, "every row seen")
        XCTAssertEqual(cover.value as? String, "0")
        XCTAssertEqual(names.map { setting($0).value as? String }, ["0", "0", "0", "0"])
        turnOn(names)
        closeSettingsAndEditing()

        // The paused episode with the row in Android's order.
        let episode = springboard.staticTexts[title]
        XCTAssertTrue(episode.waitForExistence(timeout: 15), springboard.debugDescription)
        let play = springboard.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5), springboard.debugDescription)
        let row = ["Playback speed", "Rewind", "Play", "Fast-forward", "Skip episode"].map { springboard.buttons[$0] }
        XCTAssertTrue(row.allSatisfy(\.exists), springboard.debugDescription)
        let xs = row.map(\.frame.midX)
        XCTAssertEqual(xs, xs.sorted(), "Android's order")
        let progress = springboard.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^\\d\\d:\\d\\d:\\d\\d / \\d\\d:\\d\\d:\\d\\d$")).firstMatch
        XCTAssertTrue(progress.exists, springboard.debugDescription)
        let paused = seconds(progress.label) ?? -1
        XCTAssertTrue((19...45).contains(paused), progress.label)
        attach("widget-paused")
        // Android's background colour at 100 %: below the button row, inside the widget.
        let inside = CGPoint(x: episode.frame.minX + 2, y: play.frame.maxY + 10)
        let beside = CGPoint(x: episode.frame.minX - 12 - 48 - 12 - 8, y: play.frame.maxY + 10)
        let opaque = try pixel(at: inside)
        // Android's #262C31 as a person sees it: the iOS 27 Home Screen lightens a widget's background slightly
        // (about 12 per channel on the Simulator), so the exact value is not the point; dark and not see-through is.
        XCTAssertLessThanOrEqual(distanceFromBackground(opaque), 48, "\(opaque)")

        // The settings are kept: Edit Widget shows them on.
        editWidget(anchor: episode)
        for name in names { XCTAssertEqual(setting(name).value as? String, "1", name) }
        closeSettingsAndEditing()

        // Play from the widget: the app plays in the background; the widget shows Pause and its time runs.
        play.tapWhenSettled()
        XCTAssertTrue(springboard.buttons["Pause"].waitForExistence(timeout: 15), springboard.debugDescription)
        until("time runs", timeout: 15) { (self.seconds(progress.label) ?? 0) >= paused + 3 }
        attach("widget-playing")
        // Rewind by the default "Rewind skip time", 10 s. Settle the button before reading the time: the episode
        // keeps playing while a tap waits, so the time is read just before the tap itself.
        let rewind = springboard.buttons["Rewind"]
        _ = settledFrame(of: rewind)
        let beforeRewind = seconds(progress.label) ?? 0
        rewind.tap()
        until("rewound \(beforeRewind)", timeout: 10) { (self.seconds(progress.label) ?? 999) <= beforeRewind - 6 }
        // Pause from the widget: the time stops.
        springboard.buttons["Pause"].tapWhenSettled()
        XCTAssertTrue(springboard.buttons["Play"].waitForExistence(timeout: 15), springboard.debugDescription)
        let stopped = seconds(progress.label) ?? -1
        // The time must not advance for 4 s. Read it directly over the window: a waiter that times out can
        // interrupt an in-flight Springboard query, which XCUITest records as a failure.
        let window = Date().addingTimeInterval(4)
        var latest = stopped
        while Date() < window { latest = max(latest, seconds(progress.label) ?? -1) }
        XCTAssertLessThanOrEqual(latest, stopped + 1, "time stops when paused")

        // Opacity 0 %: the Home Screen shows through the widget's background.
        editWidget(anchor: episode)
        let slider = springboard.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 10), springboard.debugDescription)
        slider.adjust(toNormalizedSliderPosition: 0)
        closeSettingsAndEditing()
        until("redrawn", timeout: 10) { self.distance(try? self.pixel(at: inside), opaque) > 30 }
        attach("widget-opacity-0")
        let clear = try pixel(at: inside), wallpaper = try pixel(at: beside)
        print("Widget opacity probe: 100 % \(opaque), 0 % \(clear), wallpaper beside \(wallpaper)")
        let gap: Int = abs(clear.r - wallpaper.r) + abs(clear.g - wallpaper.g) + abs(clear.b - wallpaper.b)
        // A known difference: iOS draws its own backing under a see-through widget background (white in the original
        // light-appearance capture), so the wallpaper never shows. Readability has its own assertion below.
        XCTExpectFailure("iOS shows its own widget backing, not the wallpaper, at 0 % opacity") {
            XCTAssertLessThanOrEqual(gap, 60, "0 %: \(clear), wallpaper beside: \(wallpaper)")
        }
        // A wallpaper-transparency failure must never excuse invisible text or controls.
        try assertWidgetReadable(narrow: false, name: "widget-opacity-0-readability")

        // Playback speed opens the app with its speed dialog; the app's player agrees with the widget.
        springboard.buttons["Playback speed"].tapWhenSettled()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["speedDialog"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["speedPreset-0"].tapWhenSettled()
        XCTAssertTrue(app.descendants(matching: .any)["speedDialog"].waitForNonExistence(timeout: 5))
        let appPlay = app.buttons["playerPlay"].exists ? app.buttons["playerPlay"] : app.buttons["miniPlayerPlay"]
        XCTAssertEqual(appPlay.label, "Play")
        if app.staticTexts["playerPosition"].exists {
            XCTAssertLessThanOrEqual(abs((seconds(app.staticTexts["playerPosition"].label) ?? -99) - stopped), 1)
        }
    }

    /// These exercise the actual installed widget, not an app preview or a reconstructed background, and
    /// change no Home Screen appearance setting. The literal-wallpaper expectation above stays separate.
    func testMediumWidgetIsReadableAtSavedOpacityValuesAndCoverOptions() throws {
        try widgetReadabilityMatrix(narrow: false)
    }

    func testSmallWidgetIsReadableAtSavedOpacityValuesAndCoverOptions() throws {
        try widgetReadabilityMatrix(narrow: true)
        // The narrow widget keeps its real intent capability through the rendering change.
        springboard.buttons["Play"].tapWhenSettled()
        XCTAssertTrue(springboard.buttons["Pause"].waitForExistence(timeout: 15), springboard.debugDescription)
        app.activate()
        label(app.buttons["playerPlay"].exists ? app.buttons["playerPlay"] : app.buttons["miniPlayerPlay"], "Pause")
        XCUIDevice.shared.leaveApp()
        springboard.buttons["Pause"].tapWhenSettled()
        XCTAssertTrue(springboard.buttons["Play"].waitForExistence(timeout: 15), springboard.debugDescription)
        app.activate()
        label(app.buttons["playerPlay"].exists ? app.buttons["playerPlay"] : app.buttons["miniPlayerPlay"], "Play")
    }

    private func widgetReadabilityMatrix(narrow: Bool) throws {
        removeWidget()
        preparePausedEpisode()
        addWidget(size: narrow ? "Small" : "Medium")
        // "Widget settings" loads after the add; its first row is Opacity.
        XCTAssertTrue(springboard.sliders.firstMatch.waitForExistence(timeout: 10), springboard.debugDescription)
        turnOn(["Playback speed", "Rewind", "Fast-forward", "Skip episode"])
        closeSettingsAndEditing()
        let widget = springboard.icons.matching(NSPredicate(format: "identifier == %@ AND value CONTAINS[c] %@",
                                                            "NotTennaPod", "Widget")).firstMatch
        XCTAssertTrue(widget.waitForExistence(timeout: 15), springboard.debugDescription)
        for coverBackground in [false, true] {
            // Both families and cover states at the slider's exact ends. XCUITest cannot set Springboard's
            // continuous 136 pt Opacity slider to an exact midrange percentage (slow drags land within about
            // 3 %), so the midrange and the 70 % switch are covered by the view tests on iPhone, iPad and Duo.
            // Finish at 100% so the small widget's real Play/Pause proof uses the opaque setting.
            for opacity in [0, 100] {
                editWidget(anchor: widget)
                let cover = setting("Cover as background")
                let wantedCover = coverBackground ? "1" : "0"
                if (cover.value as? String) != wantedCover {
                    _ = settledFrame(of: cover)
                    cover.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
                    until("Cover as background saved", timeout: 5) { (cover.value as? String) == wantedCover }
                }
                // Opacity is the first row. Restore it without dragging on a switch or changing any OS setting.
                let slider = springboard.sliders.firstMatch
                for _ in 0..<6 where !(slider.exists && slider.isHittable) { scrollSettings(down: false) }
                XCTAssertTrue(slider.exists && slider.isHittable, springboard.debugDescription)
                _ = settledFrame(of: slider)
                slider.adjust(toNormalizedSliderPosition: CGFloat(opacity) / 100)
                until("Opacity \(opacity)%", timeout: 5) { (slider.value as? String) == "\(opacity)%" }
                closeSettingsAndEditing()

                // Prove saved values through the real edit UI, then capture the live face again.
                editWidget(anchor: widget)
                let savedSlider = springboard.sliders.firstMatch
                XCTAssertTrue(savedSlider.waitForExistence(timeout: 10), springboard.debugDescription)
                XCTAssertEqual(savedSlider.value as? String, "\(opacity)%")
                XCTAssertEqual(setting("Cover as background").value as? String, wantedCover)
                closeSettingsAndEditing()
                let name = "widget-live-\(narrow ? "small" : "medium")-opacity\(opacity)-cover\(coverBackground)"
                try assertWidgetReadable(narrow: narrow, name: name)
            }
        }
    }

    /// Readability is checked from actual screen pixels for every title, progress string and control, rather
    /// than from accessibility existence alone. Retain both the screen and measured local contrast evidence.
    private func assertWidgetReadable(narrow: Bool, name: String) throws {
        let controls = narrow ? ["Play"] : ["Playback speed", "Rewind", "Play", "Fast-forward", "Skip episode"]
        XCTAssertTrue(springboard.buttons["Play"].waitForExistence(timeout: 15), springboard.debugDescription)
        _ = settledFrame(of: springboard.buttons["Play"])
        let progress = springboard.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^\\d\\d:\\d\\d:\\d\\d / \\d\\d:\\d\\d:\\d\\d$")).firstMatch
        var regions: [(String, CGRect, Double)] = []
        if !narrow {
            let episode = springboard.staticTexts[title]
            XCTAssertTrue(episode.waitForExistence(timeout: 15), springboard.debugDescription)
            XCTAssertTrue(progress.waitForExistence(timeout: 5), springboard.debugDescription)
            regions += [("title", episode.frame, 3), ("progress", progress.frame, 3)]
        }
        for control in controls {
            let button = springboard.buttons[control]
            XCTAssertTrue(button.waitForExistence(timeout: 5), springboard.debugDescription)
            let frame = button.frame, side: CGFloat = narrow ? 32 : 36
            regions.append((control, CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side), 3))
        }
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        for (label, rect, contrast) in regions {
            let evidence = try readableInk(screenshot.image, in: rect, minimumContrast: contrast)
            let measurement = "\(label): local background luminance \(evidence.background), visible ink \(evidence.area) square points at \(contrast):1"
            let report = XCTAttachment(string: measurement); report.name = name + "-" + label; report.lifetime = .keepAlways; add(report)
            XCTAssertGreaterThanOrEqual(evidence.area, max(6, Double(rect.width * rect.height) * 0.01),
                "\(name): \(label) is not visibly readable; \(measurement)")
        }
    }

    private func readableInk(_ image: UIImage, in rect: CGRect, minimumContrast: Double) throws -> (background: Double, area: Double) {
        let source = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(source.width) / image.size.width
        let crop = try XCTUnwrap(source.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale,
            width: rect.width * scale, height: rect.height * scale).integral))
        let width = crop.width, height = crop.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        func linear(_ byte: UInt8) -> Double {
            let value = Double(byte) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminances = stride(from: 0, to: bytes.count, by: 4).map { index in
            0.2126 * linear(bytes[index]) + 0.7152 * linear(bytes[index + 1]) + 0.0722 * linear(bytes[index + 2])
        }
        let background = try XCTUnwrap(luminances.sorted().dropFirst(luminances.count / 2).first)
        let ink = luminances.filter { (max($0, background) + 0.05) / (min($0, background) + 0.05) >= minimumContrast }.count
        return (background, Double(ink) / Double(scale * scale))
    }

    private func openControlCenter() {
        let corner = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.005))
        corner.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.6)))
    }

    /// Closes Control Center: its gallery, then its edit mode (a tap low on the screen; one at the top does not), then
    /// Control Center itself (Home).
    private func closeControlCenter() {
        let addControl = springboard.buttons["Add a Control"]
        if springboard.collectionViews["add-sheet-collection-view"].exists { springboard.buttons["Close"].tap() }
        if addControl.exists {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.86)).tap()
            _ = addControl.waitForNonExistence(timeout: 5)
        }
        if springboard.buttons["Add Controls"].exists { XCUIDevice.shared.press(.home) }
        XCTAssertTrue(springboard.buttons["Add Controls"].waitForNonExistence(timeout: 5), springboard.debugDescription)
    }

    /// The journeys leave Control Center as they found it: remove every AntennaPod control.
    private func removeControl() {
        XCUIDevice.shared.leaveApp()
        openControlCenter()
        // A placed control is an icon valued "Control"; in edit mode it leaves the accessibility tree and only its
        // remove badge ("DeleteButton", on its leading edge) remains, so note where the controls are first.
        let controls = springboard.icons.matching(NSPredicate(format: "identifier == %@ AND value CONTAINS[c] %@",
                                                              "NotTennaPod", "Control"))
        guard controls.firstMatch.waitForExistence(timeout: 5) else { closeControlCenter(); return }
        let xs = controls.allElementsBoundByIndex.filter(\.exists).map(\.frame.minX)
        let addControls = springboard.buttons["Add Controls"]
        XCTAssertTrue(addControls.waitForExistence(timeout: 10), springboard.debugDescription)
        addControls.tap()
        XCTAssertTrue(springboard.buttons["Add a Control"].waitForExistence(timeout: 10), springboard.debugDescription)
        for x in xs {
            let badge = springboard.buttons.matching(identifier: "DeleteButton").allElementsBoundByIndex.filter(\.exists)
                .min { abs($0.frame.midX - x) < abs($1.frame.midX - x) }
            guard let badge, abs(badge.frame.midX - x) < 20 else {
                XCTFail("No remove badge for the control at x \(x)\n\(springboard.debugDescription)"); break
            }
            badge.tap()
        }
        closeControlCenter()
        openControlCenter()
        XCTAssertFalse(controls.firstMatch.waitForExistence(timeout: 3), "NotTennaPod control left in Control Center")
        closeControlCenter()
    }

    /// A failed earlier run can leave the widget or the control behind; start from the Simulator's own state.
    private func restoreHomeScreenAndControlCenter() {
        removeWidget()
        removeControl()
    }

    /// The Control Center control: added from Control Center's gallery, off while paused; a tap
    /// plays the episode in the app and turns it on, another pauses it.
    func testControlCenterControlTogglesPlayback() {
        restoreHomeScreenAndControlCenter()
        preparePausedEpisode()
        XCUIDevice.shared.leaveApp()
        openControlCenter()
        let control = springboard.buttons.matching(identifier: "org.nottennapod.app.player-control").firstMatch
        let addControls = springboard.buttons["Add Controls"]
        XCTAssertTrue(addControls.waitForExistence(timeout: 10), springboard.debugDescription)
        addControls.tap()
        let addControl = springboard.buttons["Add a Control"]
        XCTAssertTrue(addControl.waitForExistence(timeout: 10), springboard.debugDescription)
        addControl.tap()
        // The gallery lists every app's controls, alphabetically by app. Its search does not find AntennaPod's on
        // the iOS 27.0 Simulator, so scroll to it; right after installation the list may not have it yet, so close
        // the gallery and open it again (about two minutes in all).
        let gallery = springboard.collectionViews["add-sheet-collection-view"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 10), springboard.debugDescription)
        var attempts = 0
        while !(control.waitForExistence(timeout: 2) && control.isHittable) && attempts < 40 {
            if attempts % 4 == 3 {
                springboard.buttons["Close"].tap()
                XCTAssertTrue(addControl.waitForExistence(timeout: 10), springboard.debugDescription)
                addControl.tap()
                XCTAssertTrue(gallery.waitForExistence(timeout: 10), springboard.debugDescription)
            } else {
                gallery.swipeUp()
            }
            attempts += 1
        }
        XCTAssertTrue(control.exists && control.isHittable, springboard.debugDescription)
        XCTAssertEqual(control.label, "NotTennaPod")
        control.tapWhenSettled()
        addTeardownBlock { @MainActor in self.removeControl() }
        // Leave Control Center's edit mode with a tap low on the screen.
        XCTAssertTrue(gallery.waitForNonExistence(timeout: 10), springboard.debugDescription)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.86)).tap()
        XCTAssertTrue(addControl.waitForNonExistence(timeout: 5), springboard.debugDescription)
        XCTAssertTrue(control.waitForExistence(timeout: 10), springboard.debugDescription)
        until("off while paused") { (control.value as? String) == "Off" }
        attach("control-off")
        control.tap()
        attach("control-after-tap")
        until("on while playing") { (control.value as? String) == "On" }
        attach("control-on")
        // The app's player is playing.
        app.activate()
        label(app.buttons["playerPlay"].exists ? app.buttons["playerPlay"] : app.buttons["miniPlayerPlay"], "Pause")
        XCUIDevice.shared.leaveApp()
        openControlCenter()
        XCTAssertTrue(control.waitForExistence(timeout: 10), springboard.debugDescription)
        until("still on") { (control.value as? String) == "On" }
        control.tap()
        until("off after pausing") { (control.value as? String) == "Off" }
        app.activate()
        label(app.buttons["playerPlay"].exists ? app.buttons["playerPlay"] : app.buttons["miniPlayerPlay"], "Play")
    }
}
