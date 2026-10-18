import Synchronization
import UIKit
import XCTest

/// Interface settings journey:
/// Theme Dark → Full black → relaunch keeps it; Use episode cover off → lists and the mini player show the podcast
/// cover while the podcast's own list keeps the episode cover; Settings → Playback speed 1.50 → a new episode plays at
/// 1.50, and a podcast's own speed wins. The page colour and the covers are read from screenshots, at the level a
/// person sees them (light / dark grey / black; red podcast cover / blue episode cover). Saved values are read from the
/// app's files directly.
final class InterfaceSettingsJourneyTests: XCTestCase {
    private var app: XCUIApplication!

    /// Feed "Cover colours" (red cover) with three episodes that each have a blue episode image; the audio comes from
    /// the listening fixture (18765, started by the scheme pre-action).
    private final class CoverServer: Sendable {
        let server: LoopbackHTTPServer
        let port: Int
        private init(server: LoopbackHTTPServer, port: Int) { self.server = server; self.port = port }
        static func start(red: Data, blue: Data) async throws -> CoverServer {
            let port = Mutex(0)
            let server = try await LoopbackHTTPServer.start { request in
                switch request.path {
                case "/feed.png": return .init(status: 200, headers: ["Content-Type": "image/png"], body: red)
                case "/episode.png": return .init(status: 200, headers: ["Content-Type": "image/png"], body: blue)
                case "/feed.xml":
                    let base = "http://127.0.0.1:\(port.withLock { $0 })"
                    let items = (1...3).map { index in """
                        <item><guid>cover-episode-\(index)</guid><title>Cover episode \(index)</title>
                        <pubDate>Mon, 2\(index) Sep 2026 08:00:00 GMT</pubDate>
                        <itunes:image href="\(base)/episode.png"/>
                        <enclosure url="http://127.0.0.1:18765/30sec.mp3?cover=\(index)" type="audio/mpeg" length="120017"/>
                        <itunes:duration>00:30</itunes:duration></item>
                        """ }.joined()
                    let feed = """
                        <?xml version="1.0" encoding="UTF-8"?>
                        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
                        <title>Cover colours</title><link>https://example.test/covers</link><itunes:image href="\(base)/feed.png"/>
                        \(items)</channel></rss>
                        """
                    return .init(status: 200, headers: ["Content-Type": "application/rss+xml"], body: Data(feed.utf8))
                default: return .init(status: 404, headers: [:], body: Data())
                }
            }
            port.withLock { $0 = server.url.port! }
            return CoverServer(server: server, port: server.url.port!)
        }
    }
    private static func png(_ color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }.pngData()!
    }

    // MARK: Reading the screen as a person sees it

    private func samples(_ rect: CGRect) -> [(r: CGFloat, g: CGFloat, b: CGFloat)] {
        let shot = XCUIScreen.main.screenshot().image
        guard let image = shot.cgImage else { return [] }
        let scale = shot.scale, size = 24
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let context = CGContext(data: &bytes, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        guard let crop = image.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale,
                                                   width: rect.width * scale, height: rect.height * scale)) else { return [] }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: size, height: size))
        var result: [(r: CGFloat, g: CGFloat, b: CGFloat)] = []
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let r = CGFloat(bytes[index]) / 255, g = CGFloat(bytes[index + 1]) / 255, b = CGFloat(bytes[index + 2]) / 255
            result.append((r, g, b))
        }
        return result
    }
    private enum Shade: String { case light, dark, black, unclear }
    /// The page background along the leading edge, below the toolbar and above the navigation bar.
    private func pageShade() -> Shade {
        let window = app.windows.firstMatch.frame
        let values = samples(CGRect(x: 2, y: window.height * 0.35, width: 6, height: window.height * 0.2))
        guard !values.isEmpty else { return .unclear }
        let average = values.reduce((0.0, 0.0, 0.0)) { ($0.0 + $1.r, $0.1 + $1.g, $0.2 + $1.b) }
        let (r, g, b) = (average.0 / CGFloat(values.count), average.1 / CGFloat(values.count), average.2 / CGFloat(values.count))
        if min(r, g, b) > 0.85 { return .light }
        if max(r, g, b) < 0.04 { return .black }
        if max(r, g, b) < 0.3 { return .dark }
        return .unclear
    }
    private enum Cover: String { case podcast, episode, none }
    /// Which cover the leading part of an element shows: red (podcast) or blue (episode).
    private func cover(in element: XCUIElement) -> Cover {
        let frame = element.frame
        let values = samples(CGRect(x: frame.minX, y: frame.minY, width: frame.width * 0.35, height: frame.height))
        let red = values.filter { $0.r > 0.7 && $0.g < 0.3 && $0.b < 0.3 }.count
        let blue = values.filter { $0.b > 0.7 && $0.r < 0.3 && $0.g < 0.3 }.count
        if red > 10 && red > blue * 3 { return .podcast }
        if blue > 10 && blue > red * 3 { return .episode }
        return .none
    }
    private func waitFor(_ description: String, timeout: TimeInterval = 15, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        XCTAssertTrue(condition(), description)
    }

    // MARK: Saved data, read directly from the app's container

    private func libraryFolder(_ library: String) -> URL? {
        let applications = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        for container in (try? FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil)) ?? [] {
            let folder = container.appendingPathComponent("Library/Application Support/UITests-\(library)")
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("library.sqlite").path) { return folder }
        }
        return nil
    }
    private func saved(_ file: String, library: String) -> [String: Any] {
        guard let url = libraryFolder(library)?.appendingPathComponent(file), let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: Navigation through the app's own controls

    private func tap(_ id: String) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 10), id)
        button.tap()
    }
    private func openSettings(_ screen: String) {
        tap("navigationMore"); tap("Settings"); tap(screen)
    }
    private func back(_ times: Int) { for _ in 0..<times { tap("toolbarBack") } }
    private func open(_ destination: String, title: String) {
        if app.buttons[destination].exists { app.buttons[destination].tap(); return }
        tap("navigationMore")
        let item = app.otherElements["morePopup"].buttons[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
    }
    private func waitLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 30) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label), object: element)], timeout: timeout), .completed, "\(label)")
    }
    private func play(_ id: Int) {
        let action = app.buttons["episode-action-\(id)"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        action.tap(); waitLabel(action, "Play")  // Download, then Play.
        action.tap(); waitLabel(app.buttons["miniPlayerPlay"], "Pause")
        app.buttons["miniPlayerPlay"].tap()
    }
    private func playerSpeed() -> String {
        tap("miniPlayerOpen")
        let value = app.staticTexts["playerSpeedValue"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        let label = value.label
        tap("playerCollapse")
        return label
    }

    @MainActor func testThemeFullBlackEpisodeCoverAndGlobalSpeedJourney() async throws {
        continueAfterFailure = false
        let server = try await CoverServer.start(red: Self.png(.red), blue: Self.png(.blue))
        let library = UUID().uuidString
        app = XCUIApplication()
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        XCTAssertEqual(pageShade(), .light, "A fresh install follows the device (light on a default Simulator)")

        // 1. Theme Dark, then Full black: each applies at once.
        openSettings("prefScreenInterface")
        XCTAssertTrue(app.buttons["themeSystemCard"].isSelected)
        XCTAssertFalse(app.staticTexts["Dynamic colors"].exists)
        tap("themeDarkCard")
        waitFor("Dark page") { pageShade() == .dark }
        XCTAssertTrue(app.buttons["themeDarkCard"].isSelected)
        tap("prefThemeBlack")
        waitFor("Black page") { pageShade() == .black }
        XCTAssertEqual(app.buttons["prefThemeBlack"].value as? String, "On")
        var interface = saved("interface-preferences.json", library: library)
        XCTAssertEqual(interface["prefTheme"] as? String, "1"); XCTAssertEqual(interface["prefThemeBlack"] as? Bool, true)

        // 2. Relaunch: still black from the first screen, and the settings show it.
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        waitFor("Black after relaunch") { pageShade() == .black }
        openSettings("prefScreenInterface")
        XCTAssertTrue(app.buttons["themeDarkCard"].isSelected)
        XCTAssertEqual(app.buttons["prefThemeBlack"].value as? String, "On")
        back(2)

        // 3. Subscribe; the podcast's list and the Episodes list show the blue episode covers.
        tap("navigationMore"); tap("Add podcast"); tap("addRSS")
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap()
        address.typeTextSettled("http://127.0.0.1:\(server.port)/feed.xml")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15)); app.buttons["subscribeFeed"].tap()
        let row = app.buttons["episode-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        waitFor("Episode cover in the podcast's list") { cover(in: row) == .episode }
        open("EpisodesFragment", title: "Episodes")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        waitFor("Episode cover in Episodes") { cover(in: row) == .episode }

        // 4. Use episode cover off: Episodes shows the red podcast cover; the podcast's own list keeps blue.
        openSettings("prefScreenInterface")
        tap("prefEpisodeCover")
        XCTAssertEqual(app.buttons["prefEpisodeCover"].value as? String, "Off")
        interface = saved("interface-preferences.json", library: library)
        XCTAssertEqual(interface["prefEpisodeCover"] as? Bool, false)
        back(2)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        waitFor("Podcast cover in Episodes") { cover(in: row) == .podcast }
        XCTAssertEqual(pageShade(), .black)

        // 5. Settings → Playback → Playback speed: nothing selected, so it shows the global 1.00; choose 1.50.
        openSettings("prefScreenPlayback")
        tap("prefPlaybackSpeedLauncher")
        let slider = app.descendants(matching: .any)["speedSlider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        XCTAssertEqual(slider.value as? String, "1.00")
        tap("speedPreset-2")
        XCTAssertTrue(slider.waitForNonExistence(timeout: 5), "A preset closes the dialog")
        XCTAssertEqual(saved("playback-speed-preferences.json", library: library)["global"] as? Double, 1.5)
        back(2)

        // 6. A new episode plays at the global 1.50; the mini player shows the podcast cover (setting off).
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        play(1)
        XCTAssertEqual(playerSpeed(), "1.50")
        waitFor("Podcast cover in the mini player") { cover(in: app.buttons["miniPlayerOpen"]) == .podcast }

        // 7. The podcast's own speed 1.25 wins for its next episode.
        tap("SubscriptionFragment")
        let feed = app.buttons["subscriptionFeed-1"]
        XCTAssertTrue(feed.waitForExistence(timeout: 5)); feed.tap()
        tap("feedSettings"); tap("feedSettingsPlaybackSpeed")
        tap("feedSpeedUseGlobal")
        let feedSpeed = app.descendants(matching: .any)["feedSpeedSlider"]
        XCTAssertTrue(feedSpeed.waitForExistence(timeout: 5))
        func current() -> String { feedSpeed.value as? String ?? "" }
        for _ in 0..<40 where current() != "1.25" {
            tap((Double(current()) ?? 0) > 1.25 ? "feedSpeedDecrease" : "feedSpeedIncrease")
        }
        XCTAssertEqual(current(), "1.25")
        tap("feedSpeedSave")
        back(1)
        play(2)
        XCTAssertEqual(playerSpeed(), "1.25")
        XCTAssertEqual(saved("playback-speed-preferences.json", library: library)["global"] as? Double, 1.5,
                       "The podcast's speed leaves the global speed unchanged")

        // 8. Relaunch keeps every choice.
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        waitFor("Black after the second relaunch") { pageShade() == .black }
        openSettings("prefScreenInterface")
        XCTAssertEqual(app.buttons["prefEpisodeCover"].value as? String, "Off")
        XCTAssertTrue(app.buttons["themeDarkCard"].isSelected)
        _ = server
    }
}
