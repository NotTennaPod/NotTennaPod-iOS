import XCTest

/// Actual application adoption checks, reusing ApplicationPlaybackTests' public
/// RSS/download/control flow and the independently documented media fixtures (LongMP3, LongNativeFormats).
final class PCPlaybackAudioJourneyTests: XCTestCase {
    @MainActor func testDownloadedMP3ProcessingSeekPauseAndRelaunch() async throws { try await journey(.mp3) }
    @MainActor func testDownloadedADTSProcessingSeekPauseAndRelaunch() async throws { try await journey(.aac) }
    @MainActor func testDownloadedAudioMP4ProcessingSeekPauseAndRelaunch() async throws { try await journey(.mp4) }

    private enum Format: String {
        case mp3, aac, mp4
        // Independent fixture/source intervals, not values read back from the app.
        // ADTS has a source byte-index estimate; MP4 has the accepted 23ms native
        // presentation/edit-interval distinction. Exact tail checks live natively.
        var durationMilliseconds: ClosedRange<Int> {
            switch self {
            case .mp3: 1_800_000...1_800_045
            case .aac: 368_000...369_448
            case .mp4: 367_977...368_000
            }
        }
        var midpointSeconds: ClosedRange<Int> {
            (durationMilliseconds.lowerBound / 2_000)...(durationMilliseconds.upperBound / 2_000)
        }
    }

    @MainActor private func journey(_ format: Format) async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), library = UUID().uuidString
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap()
        let base = ProcessInfo.processInfo.environment["PC_PLAYBACK_AUDIO_BASE_URL"] ?? "http://127.0.0.1:59431"
        address.typeTextSettled("\(base)/feed.xml?format=\(format.rawValue)&run=\(library)")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15)); app.buttons["subscribeFeed"].tap()
        let action = app.buttons["episode-action-1"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        XCTAssertEqual(action.label, "Download"); action.tap()
        await label(action, "Play", timeout: 25); action.tap()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 15))
        await label(app.buttons["miniPlayerPlay"], "Pause")
        app.buttons["miniPlayerPlay"].tap(); app.buttons["miniPlayerOpen"].tap()
        await label(app.buttons["playerPlay"], "Play")

        app.buttons["playerSpeed"].tap()
        let silence = app.buttons["speedSkipSilence"]
        XCTAssertTrue(silence.waitForExistence(timeout: 5))
        XCTAssertEqual(silence.value as? String, "Off"); silence.tap()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "On"), object: silence)], timeout: 5)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        app.buttons["speedPreset-2"].tap()
        XCTAssertTrue(silence.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["playerSpeedValue"].label, "1.50")

        let position = app.staticTexts["playerPosition"]
        let seek = app.descendants(matching: .any)["playerSeek"]
        XCTAssertTrue(seek.isHittable)
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { self.seconds(position.label).map(format.midpointSeconds.contains) == true }
        }, object: nil)], timeout: 10)
        app.buttons["playerPlay"].tap(); await label(app.buttons["playerPlay"], "Pause")
        await progress(position, beyond: format.midpointSeconds.upperBound)
        app.buttons["playerSpeed"].tap()
        XCTAssertTrue(silence.waitForExistence(timeout: 5)); XCTAssertEqual(silence.value as? String, "On")
        XCTAssertEqual(app.buttons["speedAddPreset"].value as? String, "1.50")
        app.buttons["speedPreset-2"].tap(); XCTAssertTrue(silence.waitForNonExistence(timeout: 5))
        app.buttons["playerPlay"].tap(); await label(app.buttons["playerPlay"], "Play")
        let saved = position.label
        let savedSeconds = try XCTUnwrap(seconds(saved))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 10)); app.buttons["miniPlayerOpen"].tap()
        await label(app.buttons["playerPlay"], "Play")
        XCTAssertEqual(position.label, saved)
        XCTAssertEqual(app.staticTexts["playerSpeedValue"].label, "1.50")
        app.buttons["playerSpeed"].tap()
        XCTAssertTrue(silence.waitForExistence(timeout: 5)); XCTAssertEqual(silence.value as? String, "On")
        app.buttons["speedPreset-2"].tap(); XCTAssertTrue(silence.waitForNonExistence(timeout: 5))
        app.buttons["playerPlay"].tap(); await label(app.buttons["playerPlay"], "Pause")
        await progress(position, beyond: savedSeconds)
        app.buttons["playerPlay"].tap(); await label(app.buttons["playerPlay"], "Play")
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    private func seconds(_ label: String) -> Int? {
        let fields = label.split(separator: ":").compactMap { Int($0) }
        guard fields.count == 3 else { return nil }
        return fields.reduce(0) { $0 * 60 + $1 }
    }
    @MainActor private func progress(_ position: XCUIElement, beyond seconds: Int) async {
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { self.seconds(position.label).map { $0 > seconds } == true }
        }, object: nil)], timeout: 15)
    }
    @MainActor private func label(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 10) async {
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", value), object: element)], timeout: timeout)
    }
}
