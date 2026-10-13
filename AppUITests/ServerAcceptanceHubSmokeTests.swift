import XCTest

/// The app bridge against the acceptance hub (`serve-ntp-server-fixture.py`, started by the scheme's pre-action):
/// the app, launched with `-test-hub-bridge` and `-test-sync-crash-at push.barrier`, reports the crash point its first
/// attachment's catch-up reaches and is killed there (SIGKILL, after the hub's receipt); relaunched, the attachment
/// resumes and finishes, a Mark as played in the server library is reported as the fact the recorder exported, and a
/// hub command reaches the app and is answered.
@MainActor final class ServerAcceptanceHubSmokeTests: XCTestCase {
    private let app = XCUIApplication()
    private let library = UUID().uuidString
    private let server = "http://127.0.0.1:18830"
    private let hub = URL(string: "http://127.0.0.1:18831")!

    override func setUp() {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "System password save prompt") { alert in
            let later = alert.buttons["Not Now"]
            guard later.exists else { return false }
            later.tap(); return true
        }
    }

    // MARK: - The hub

    private func call(_ method: String, _ path: String, _ body: [String: Any] = [:], timeout: TimeInterval = 600) async throws -> [String: Any] {
        var request = URLRequest(url: hub.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = method
        if method == "POST" {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let answer = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        XCTAssertTrue((200..<300).contains(status), "\(path): \(status) \(answer)")
        return answer
    }

    /// The first hub event after `after` with these members, waiting for it (with a limit).
    private func event(after: Int, _ filters: [String: Any], timeout: TimeInterval = 120) async throws -> [String: Any] {
        let answer = try await call("POST", "events/wait", ["after": after, "filters": filters, "timeout": timeout], timeout: timeout + 30)
        return try XCTUnwrap((answer["events"] as? [[String: Any]])?.first, "no event \(filters)")
    }

    private func mark(_ label: String) async throws -> Int {
        let answer = try await call("POST", "mark", ["label": label])
        return try XCTUnwrap(answer["seq"] as? Int)
    }

    // MARK: - The app

    private func launch(crashAt point: String? = nil) {
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback", "-test-hub-bridge", hub.absoluteString + "/bridge"]
            + (point.map { ["-test-sync-crash-at", $0] } ?? [])
        app.launch()
    }

    private func element(_ id: String, timeout: TimeInterval = 20) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout), id + "\n" + app.debugDescription)
        return element
    }

    private func tap(_ id: String, timeout: TimeInterval = 20) {
        app.dismissSavePasswordPrompt(timeout: 0.5)
        let target = element(id, timeout: timeout)
        for _ in 0..<5 where !target.isHittable {
            let body = app.scrollViews["sourceMessageBody"]
            (body.exists ? body : app.scrollViews["libraryContent"]).swipeUp()
        }
        target.tapWhenSettled()
    }

    private func fill(_ id: String, _ text: String, secure: Bool = false) {
        let field = secure ? app.secureTextFields[id] : app.textFields[id]
        XCTAssertTrue(field.waitForExistence(timeout: 20), id)
        field.tapWhenSettled()
        field.typeTextSettled(text)
    }

    private func openSynchronization() {
        element("navigationMore").tapWhenSettled()
        app.buttons["Settings"].tapWhenSettled()
        let row = app.buttons["prefScreenSynchronization"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        for _ in 0..<5 where !row.isHittable { app.scrollViews["libraryContent"].swipeUp() }
        row.tapWhenSettled()
        XCTAssertTrue(app.buttons["pref_synchronization_logout"].waitForExistence(timeout: 10))
    }

    private func waitValue(_ id: String, contains text: String, timeout: TimeInterval = 90) {
        let target = element(id, timeout: timeout)
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", text), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "\(id) value \(String(describing: target.value)) lacks \(text)")
    }

    // MARK: - The journey

    func testTheBridgeReportsACrashPointWhereTheAppIsKilledAndAnExport() async throws {
        _ = try await call("GET", "ready")
        let password = "hub-smoke-password-1"
        let account = try await call("POST", "accounts", ["password": password,
                                                          "import": "TestSupport/Data/subscriptions-screen/databases/mixed.db"])
        let username = try XCTUnwrap(account["username"] as? String)
        let start = try await mark("hub smoke: first launch")

        // First launch: the attachment's catch-up reaches push.barrier, the bridge reports it, the hub answers with
        // its receipt and the app kills itself there.
        launch(crashAt: "push.barrier")
        let hello = try await event(after: start, ["source": "app", "kind": "hello", "library": library])
        let pid = try XCTUnwrap(hello["pid"] as? Int)
        XCTAssertEqual(hello["crash_at"] as? String, "push.barrier")
        openSynchronization()
        tap("preference_synchronization_description")
        tap("syncProvider-server")
        fill("serverHost", server)
        tap("serverProceed")
        fill("serverUsername", username)
        fill("serverPassword", password, secure: true)
        tap("serverLogin")
        tap("serverAttachConfirm")
        let crash = try await event(after: start, ["source": "app", "kind": "crash_point", "armed": true, "pid": pid])
        XCTAssertEqual(crash["point"] as? String, "push.barrier")
        let exited = try await call("POST", "app/wait-exit", ["pid": pid, "timeout": 60])
        XCTAssertEqual(exited["exited"] as? Bool, true)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 30), "the app was killed at the crash point")
        let crashSeq = try XCTUnwrap(crash["seq"] as? Int)
        let exitSeq = try XCTUnwrap(exited["event"] as? Int)
        XCTAssertLessThan(crashSeq, exitSeq, "the hub had the receipt before the process ended")

        // Relaunched without the crash point: the attachment resumes at the graph start and finishes; the crash points
        // it passes are reported, unarmed.
        let second = try await mark("hub smoke: relaunch")
        launch()
        let relaunched = try await event(after: second, ["source": "app", "kind": "hello", "library": library])
        let session = try XCTUnwrap(relaunched["session"] as? String)
        XCTAssertNotEqual(relaunched["pid"] as? Int, pid)
        _ = try await event(after: second, ["source": "app", "kind": "crash_point", "point": "push.barrier", "armed": false,
                                            "session": session])
        // The server library opens: its podcasts show.
        let subscriptions = app.navigation("Subscriptions")
        if subscriptions.waitForExistence(timeout: 10) { subscriptions.tapWhenSettled() } else { tap("navigationMore"); tap("Subscriptions") }
        let zebra = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Zebra")).firstMatch
        XCTAssertTrue(zebra.waitForExistence(timeout: 90), app.debugDescription)
        openSynchronization()
        waitValue("pref_synchronization_logout", contains: "Logged in as \(username) on \(server).")

        // An action in the server library: the recorder's export is reported once its transaction commits.
        let action = try await mark("hub smoke: mark played")
        while app.buttons["toolbarBack"].exists { app.buttons["toolbarBack"].tapWhenSettled() }
        if subscriptions.waitForExistence(timeout: 5) { subscriptions.tapWhenSettled() } else { tap("navigationMore"); tap("Subscriptions") }
        XCTAssertTrue(zebra.waitForExistence(timeout: 30), app.debugDescription)
        zebra.tapWhenSettled()
        let episode = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Episode 12")).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 20), app.debugDescription)
        episode.press(forDuration: 0.7)
        tap("markPlayed")
        let export = try await event(after: action, ["source": "app", "kind": "export", "type": "episode.mark_played"])
        XCTAssertNotNil(export["op_id"] as? String)
        XCTAssertNotNil(export["install_seq"] as? Int)

        // The hub's commands reach the app and come back answered: in the foreground no background lease is held.
        let answer = try await call("POST", "app/command", ["command": "expire_lease", "timeout": 60])
        XCTAssertEqual(answer["ok"] as? Bool, false, "\(answer)")
        XCTAssertEqual(answer["error"] as? String, "no background lease is held")
    }
}
