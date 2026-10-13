import XCTest

final class ApplicationPlaybackTests: XCTestCase {
    @MainActor func testDownloadedMP3ProcessingSeekAndRelaunch() async throws { try await journey(live: false) }
    @MainActor func testUnknownDurationMP3ProcessingAndRelaunch() async throws { try await journey(live: true) }

    @MainActor private func journey(live: Bool) async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), run = UUID().uuidString, mode = live ? "live" : "download"
        app.launchArguments = ["-test-library-id", run, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap()
        address.typeTextSettled("http://127.0.0.1:18803/feed.xml?mode=\(mode)&run=\(run)")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 10))
        if live {
            app.buttons["episode-1"].tap()
            XCTAssertTrue(app.buttons["episodePrimaryAction"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons["episodePrimaryAction"].label, "Stream")
            app.buttons["episodePrimaryAction"].tap()
        } else {
            let action = app.buttons["episode-action-1"]
            XCTAssertEqual(action.label, "Download"); action.tap()
            try await label(action, equals: "Play", timeout: 25); action.tap()
        }
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 15))
        try await label(app.buttons["miniPlayerPlay"], equals: "Pause")
        app.buttons["miniPlayerPlay"].tap(); app.buttons["miniPlayerOpen"].tap()
        try await label(app.buttons["playerPlay"], equals: "Play")
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
        if !live {
            let seek = app.descendants(matching: .any)["playerSeek"]
            XCTAssertTrue(seek.isHittable)
            seek.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            try await label(position, equals: "00:15:00")
        }
        let initial = position.label
        app.buttons["playerPlay"].tap(); try await label(app.buttons["playerPlay"], equals: "Pause")
        if !live {
            await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", initial), object: position)], timeout: 15)
            // A paused seek shows the requested position at once; only the advancing clock shows where audio
            // actually resumed. It must continue from the seek target (00:15:00), a second or two later.
            XCTAssertTrue(position.label.hasPrefix("00:15:0"), "Playback resumed at \(position.label), not at the seek target 00:15:00")
        }
        app.buttons["playerSpeed"].tap()
        XCTAssertTrue(silence.waitForExistence(timeout: 5)); XCTAssertEqual(silence.value as? String, "On")
        XCTAssertEqual(app.buttons["speedAddPreset"].value as? String, "1.50")
        app.buttons["speedPreset-2"].tap(); XCTAssertTrue(silence.waitForNonExistence(timeout: 5))
        app.buttons["playerPlay"].tap(); try await label(app.buttons["playerPlay"], equals: "Play")
        let saved = position.label
        if live {
            // The original unknown-duration UI clock does not advance. Actual
            // output is covered by native source tests and persisted pause data.
            XCTAssertEqual(saved, initial)
        }
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 10)); app.buttons["miniPlayerOpen"].tap()
        XCTAssertEqual(app.staticTexts["playerSpeedValue"].label, "1.50")
        try await label(app.buttons["playerPlay"], equals: "Play")
        if !live { XCTAssertEqual(position.label, saved) }
        app.buttons["playerSpeed"].tap(); XCTAssertTrue(silence.waitForExistence(timeout: 5))
        XCTAssertEqual(silence.value as? String, "On")
        app.buttons["speedPreset-2"].tap(); XCTAssertTrue(silence.waitForNonExistence(timeout: 5))
        app.buttons["playerPlay"].tap(); try await label(app.buttons["playerPlay"], equals: "Pause")
        if !live {
            await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", saved), object: position)], timeout: 15)
        }
        XCTAssertFalse(app.alerts.firstMatch.exists)
        app.buttons["playerPlay"].tap(); try await label(app.buttons["playerPlay"], equals: "Play")
    }

    @MainActor private func label(_ element: XCUIElement, equals value: String, timeout: TimeInterval = 10) async throws {
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", value), object: element)], timeout: timeout)
    }
}
