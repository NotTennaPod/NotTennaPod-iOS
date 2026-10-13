import XCTest

/// NotTennaPod server mode on Settings → Synchronization (PROTOCOL §15.4) against the real server
/// (`serve-ntp-server-fixture.py`, started by the scheme's pre-action): sign in to an empty account and attach it,
/// log out and back in (a resume, not a new library), remove the kept library, and sign in again after the password
/// was changed elsewhere; an account with a library attaches and shows its podcasts; logging out shows this device's
/// own library and logging in again brings the server library back with its changes; an attachment made while an
/// episode plays waits for the pause; the exchange runs from the app (changes sent and received, the page's status,
/// "Synchronize now" and "Paused"); after a server restore the app recovers what the restored server lost; when the
/// server no longer has the library's history it pauses and explains, and "Start over with the server's library"
/// attaches to the server's new library, keeping this one; listening on the phone (subscribe, play, pause, complete)
/// reaches another installation, and a position another installation took is adopted by the paused player; the
/// synchronization log is shared and found by settings search.
@MainActor final class ServerSynchronizationJourneyTests: XCTestCase {
    private let app = XCUIApplication()
    private let library = UUID().uuidString
    private let server = "http://127.0.0.1:18830"
    private let control = URL(string: "http://127.0.0.1:18831")!

    override func setUp() {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "System password save prompt") { alert in
            let later = alert.buttons["Not Now"]
            guard later.exists else { return false }
            later.tap(); return true
        }
    }

    // MARK: - The fixture's control API

    private struct Account { let username: String; let id: String }

    private func call(_ method: String, _ path: String, _ body: [String: Any] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: control.appendingPathComponent(path), timeoutInterval: 600)
        request.httpMethod = method
        if method == "POST" { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let answer = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        XCTAssertTrue((200..<300).contains(status), "\(path): \(status) \(answer)")
        return answer
    }

    /// A fresh account; `library` names an Android database the account imports first (as on the server's web page).
    private func account(password: String, library: String? = nil) async throws -> Account {
        _ = try await call("GET", "ready")
        var body: [String: Any] = ["password": password]
        if let library { body["import"] = library }
        let answer = try await call("POST", "accounts", body)
        return Account(username: try XCTUnwrap(answer["username"] as? String), id: try XCTUnwrap(answer["account_id"] as? String))
    }

    // MARK: - Steps

    private func launch(_ extra: [String] = []) {
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback"] + extra
        app.launch()
    }

    /// From the Synchronization page (or any page under the toolbar) back to the main screens, one level per tap.
    private func leaveSettings() {
        let title = app.staticTexts["screenTitle"], back = app.buttons["toolbarBack"]
        for _ in 0..<4 where back.exists && !app.buttons["navigationMore"].isHittable {
            let before = title.label
            // iOS may offer to save a password just entered a second time, late; its sheet covers the toolbar.
            if !waitHittable(back, timeout: 5) { app.dismissSavePasswordPrompt(timeout: 1) }
            XCTAssertTrue(waitHittable(back), "Back is ready")
            back.tapWhenSettled()
            let left = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", before), object: title)
            if XCTWaiter.wait(for: [left], timeout: 10) != .completed { lostTap("Back"); return }
        }
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
    }

    private func destination(_ id: String, title: String) {
        let direct = app.buttons[id]
        if direct.waitForExistence(timeout: 2), direct.isHittable { direct.tapWhenSettled(); return }
        moreMenu(title).tapWhenSettled()
    }

    /// An item of the More menu, opened by one settled tap: a menu that does not open is a failure a person would
    /// notice, recorded with what the screen showed.
    private func moreMenu(_ title: String) -> XCUIElement {
        let more = element("navigationMore")
        XCTAssertTrue(waitHittable(more), "More is ready")
        more.tapWhenSettled()
        let item = app.otherElements["morePopup"].buttons[title]
        if !item.waitForExistence(timeout: 10) { lostTap("More") }
        return item
    }

    /// Ready to take a tap: shown and hittable.
    private func waitHittable(_ target: XCUIElement, timeout: TimeInterval = 20) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: target)],
                       timeout: timeout) == .completed
    }

    /// A settled tap that did nothing: the screen is kept for the record and the journey fails.
    private func lostTap(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        screenshot("lost-tap-\(name)")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "lost-tap-\(name)-hierarchy"; hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTFail("one settled tap on \(name) did nothing", file: file, line: line)
    }

    /// This device's queue as a person reads it: each row's title and what it says (favorite, position, duration),
    /// top to bottom.
    private func queueAsShown() -> [String] {
        destination("QueueFragment", title: "Queue")
        let rows = app.buttons.matching(NSPredicate(format: "identifier MATCHES 'episode-[0-9]+'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        return rows.allElementsBoundByIndex.map { "\($0.label): \(($0.value as? String) ?? "")" }
    }

    /// The podcast tile with this title on Subscriptions, if shown.
    private func podcast(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'subscriptionFeed-' AND label CONTAINS %@", title)).firstMatch
    }

    /// Subscriptions shows one library's podcasts and not the other's.
    private func subscriptionsShow(_ shown: String, notShown: String, _ label: String) {
        destination("SubscriptionFragment", title: "Subscriptions")
        XCTAssertTrue(podcast(shown).waitForExistence(timeout: 30), "\(label): \(shown)\n\(app.debugDescription)")
        for _ in 0..<8 where !podcast(shown).isRevealed(in: app) { app.scrollViews["libraryContent"].swipeUp() }
        XCTAssertTrue(podcast(shown).isRevealed(in: app), "\(label): \(shown) visible")
        XCTAssertFalse(podcast(notShown).exists, "\(label): \(notShown) is the other library's")
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
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue, !secure {
            field.typeTextSettled(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeTextSettled(text)
    }

    private func openSynchronization() {
        moreMenu("Settings").tapWhenSettled()
        let row = app.buttons["prefScreenSynchronization"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        for _ in 0..<5 where !row.isHittable { app.scrollViews["libraryContent"].swipeUp() }
        XCTAssertTrue(waitHittable(row), "Synchronization is ready")
        row.tapWhenSettled()
        if !app.buttons["pref_synchronization_logout"].waitForExistence(timeout: 10) { lostTap("Synchronization") }
    }

    private func waitValue(_ id: String, contains text: String, timeout: TimeInterval = 40) {
        let target = element(id, timeout: timeout)
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", text), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "\(id) value \(String(describing: target.value)) lacks \(text)")
    }

    private func waitStatus(_ prefix: String, timeout: TimeInterval = 40) {
        let status = app.staticTexts["synchronizationStatus"]
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", prefix), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "status \(status.exists ? status.label : "missing"), expected \(prefix)")
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Provider chooser → NotTennaPod server → address → credentials.
    private func signIn(_ account: Account, password: String, wrongFirst: Bool = false) {
        tap("preference_synchronization_description")
        screenshot("provider-choices")
        tap("syncProvider-server")
        fill("serverHost", server)
        tap("serverProceed")
        XCTAssertTrue(app.staticTexts["serverEncryptionWarning"].waitForExistence(timeout: 20), "plain HTTP outside Tailscale warns")
        fill("serverUsername", account.username)
        if wrongFirst {
            fill("serverPassword", "wrong-password", secure: true)
            tap("serverLogin")
            let error = app.staticTexts["serverAuthenticationError"]
            XCTAssertTrue(error.waitForExistence(timeout: 20))
            XCTAssertEqual(error.label, "Wrong username or password")
            screenshot("sign-in-error")
            app.secureTextFields["serverPassword"].tapWhenSettled()
            app.secureTextFields["serverPassword"].typeTextSettled(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
            app.secureTextFields["serverPassword"].typeTextSettled(password)
        } else {
            fill("serverPassword", password, secure: true)
        }
        tap("serverLogin")
    }

    /// The attachment of an empty account, from the confirmation to the server library's page.
    private func attachEmpty(_ account: Account) {
        let message = element("sourceMessage")
        XCTAssertTrue(message.label.contains("NotTennaPod will use your library from \(server) on this device"), message.label)
        screenshot("attach-confirmation")
        tap("serverAttachConfirm")
        let empty = element("serverUseEmptyLibrary", timeout: 60)
        XCTAssertTrue(app.staticTexts["sourceMessage"].label.hasPrefix("This account has no podcasts yet."))
        screenshot("empty-account")
        _ = empty
        tap("serverUseEmptyLibrary")
        // The switch restarts the app's screens and reopens this page in server mode.
        waitValue("pref_synchronization_logout", contains: "Logged in as \(account.username) on \(server).", timeout: 60)
        waitValue("preference_synchronization_description", contains: "NotTennaPod server is an open-source synchronization server")
        waitStatus("Successful (")
        XCTAssertTrue(app.buttons["ntp_server_setlogin_information"].exists)
        XCTAssertFalse(app.buttons["ntp_server_status"].exists)
    }

    private enum LogoutChoice { case keep, goBack }

    /// Logout in server mode asks which library this phone uses afterwards (PROTOCOL §15.5).
    private func logOut(_ choice: LogoutChoice) {
        tap("pref_synchronization_logout")
        let message = element("sourceMessage")
        XCTAssertTrue(message.label.hasPrefix("Which library should this phone use after logging out?"), message.label)
        XCTAssertEqual(element("serverLogoutKeep").label, "Keep using this library")
        XCTAssertEqual(element("serverLogoutGoBack").label, "Go back to the library from before you signed in")
        XCTAssertEqual(element("serverLogoutCancel").label, "Cancel")
        screenshot("logout-choice")
        tap(choice == .keep ? "serverLogoutKeep" : "serverLogoutGoBack")
    }

    // MARK: - Journeys

    func test01AttachAnEmptyAccountLogOutResumeAndRemoveTheKeptLibrary() async throws {
        let account = try await account(password: "journey-password-1")
        launch()
        openSynchronization()
        XCTAssertFalse(app.buttons["ntp_server_libraries"].exists)
        signIn(account, password: "journey-password-1", wrongFirst: true)
        attachEmpty(account)
        screenshot("server-mode")

        // Logout: "Go back to the library from before you signed in": this device's library returns; the server
        // library is kept.
        logOut(.goBack)
        waitValue("ntp_server_libraries", contains: "1 library", timeout: 60)
        XCTAssertEqual(app.buttons["preference_synchronization_description"].label, "Choose synchronization provider")
        XCTAssertFalse(app.buttons["pref_synchronization_sync"].isEnabled)
        screenshot("kept-library")

        // Log in again from the kept library: a resume, not a new library.
        tap("ntp_server_libraries")
        let entry = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "keptLibraryLogin-")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["\(account.username) on 127.0.0.1"].exists)
        screenshot("kept-libraries-dialog")
        entry.tapWhenSettled()
        XCTAssertEqual(app.textFields["serverUsername"].value as? String, account.username)
        fill("serverPassword", "journey-password-1", secure: true)
        tap("serverLogin")
        XCTAssertTrue(element("sourceMessage").label.hasPrefix("This device already has a library for this account."))
        screenshot("resume-confirmation")
        tap("serverAttachConfirm")
        waitValue("pref_synchronization_logout", contains: "Logged in as \(account.username)", timeout: 60)

        // A relaunch keeps the server library.
        app.terminate(); launch(); openSynchronization()
        waitValue("pref_synchronization_logout", contains: "Logged in as \(account.username)")

        // Remove the kept library.
        logOut(.goBack)
        tap("ntp_server_libraries", timeout: 60)
        let remove = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "keptLibraryRemove-")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.tapWhenSettled()
        XCTAssertTrue(element("sourceMessage").label.hasPrefix("Remove this server library from this device? Its downloads are deleted."))
        screenshot("remove-confirmation")
        tap("keptLibraryRemoveConfirm")
        XCTAssertTrue(app.buttons["ntp_server_libraries"].waitForNonExistence(timeout: 30))
        XCTAssertEqual(app.buttons["preference_synchronization_description"].label, "Choose synchronization provider")
    }

    func test02SignInAgainAfterThePasswordChangedElsewhere() async throws {
        let account = try await account(password: "journey-password-1")
        launch()
        openSynchronization()
        signIn(account, password: "journey-password-1")
        attachEmpty(account)

        // The password changes on the server: the token is revoked. The next start notices.
        _ = try await call("POST", "accounts/\(account.id)/password", ["password": "journey-password-2"])
        app.terminate(); launch(); openSynchronization()
        waitStatus("Sign in again")
        let status = element("ntp_server_status")
        XCTAssertEqual(status.label, "Sign in again")
        XCTAssertTrue((status.value as? String)?.hasPrefix("The server no longer accepts this device's login.") == true)
        screenshot("sign-in-again")
        tap("ntp_server_status")
        XCTAssertFalse(app.textFields["feedUsername"].isEnabled)
        XCTAssertEqual(app.textFields["feedUsername"].value as? String, account.username)
        fill("feedPassword", "journey-password-2", secure: true)
        tap("serverPasswordConfirm")
        XCTAssertTrue(app.buttons["ntp_server_status"].waitForNonExistence(timeout: 30))
        waitStatus("Successful (")
        waitValue("pref_synchronization_logout", contains: "Logged in as \(account.username)")
    }

    func test03AnAccountWithALibraryAttachesWithoutAskingAndShowsItsPodcasts() async throws {
        let account = try await account(password: "journey-password-1", library: "TestSupport/Data/subscriptions-screen/databases/mixed.db")
        launch()
        openSynchronization()
        signIn(account, password: "journey-password-1")
        XCTAssertTrue(element("sourceMessage").label.contains("NotTennaPod will use your library from \(server) on this device"))
        tap("serverAttachConfirm")
        // No empty-account question: the server's library is built and used at once.
        waitValue("pref_synchronization_logout", contains: "Logged in as \(account.username) on \(server).", timeout: 90)
        XCTAssertFalse(app.buttons["serverUseEmptyLibrary"].exists)
        waitStatus("Successful (")
        screenshot("server-mode-with-library")
        app.buttons["toolbarBack"].tapWhenSettled(); app.buttons["toolbarBack"].tapWhenSettled()
        let subscriptions = app.navigation("Subscriptions")
        if subscriptions.waitForExistence(timeout: 5) { subscriptions.tapWhenSettled() } else { tap("navigationMore"); tap("Subscriptions") }
        let zebra = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Zebra")).firstMatch
        XCTAssertTrue(zebra.waitForExistence(timeout: 30), app.debugDescription)
        screenshot("server-library-subscriptions")
    }

    /// Logout and back (PROTOCOL §15.4): after the logout this device's own library is shown again, unchanged (its podcast, and its
    /// queue with favorites and played positions); signing in again to the same account resumes the kept server
    /// library, with the change made in it before the logout.
    func test04LogOutShowsThisDevicesLibraryAndSigningInAgainResumesTheServerLibrary() async throws {
        let account = try await account(password: "journey-password-1", library: "TestSupport/Data/subscriptions-screen/databases/mixed.db")
        launch(["-test-list-inbox-cleanup"])
        subscriptionsShow("Controlled inbox cleanup", notShown: "Zebra", "this device's library")
        // This device's library beyond its podcast: two queued favorites with played positions, in order.
        let deviceQueue = queueAsShown()
        XCTAssertEqual(deviceQueue.count, 2, "\(deviceQueue)")
        XCTAssertTrue(deviceQueue.first?.hasPrefix("Inbox cleanup target:") == true && deviceQueue.last?.hasPrefix("Inbox cleanup survivor:") == true, "\(deviceQueue)")
        XCTAssertTrue(deviceQueue.allSatisfy { $0.contains("Marked as favorite") }, "\(deviceQueue)")
        screenshot("device-queue")
        openSynchronization()
        signIn(account, password: "journey-password-1")
        XCTAssertTrue(element("sourceMessage").label.contains("NotTennaPod will use your library from \(server) on this device"))
        tap("serverAttachConfirm")
        waitValue("pref_synchronization_logout", contains: "Logged in as \(account.username) on \(server).", timeout: 90)
        leaveSettings()
        subscriptionsShow("Zebra", notShown: "Controlled inbox cleanup", "the server library")

        // A change in the server library: one episode leaves the Inbox.
        destination("NewEpisodesFragment", title: "Inbox")
        // Rows are `episode-<id>`; the server library keeps its IDs across a logout.
        let rows = app.buttons.matching(NSPredicate(format: "identifier MATCHES 'episode-[0-9]+' AND label BEGINSWITH 'Episode '"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        let removed = rows.firstMatch.identifier
        let removedRow = app.buttons[removed]
        XCTAssertTrue(removedRow.isRevealed(in: app), removed)
        removedRow.press(forDuration: 0.7)
        tap("removeInbox")
        XCTAssertTrue(removedRow.waitForNonExistence(timeout: 10), "\(removed) left the Inbox")
        let kept = rows.firstMatch.identifier
        XCTAssertNotEqual(kept, removed)
        screenshot("server-library-inbox-change")

        // Logout, going back: this device's library returns as it was.
        openSynchronization()
        logOut(.goBack)
        waitValue("ntp_server_libraries", contains: "1 library", timeout: 60)
        screenshot("logged-out")
        leaveSettings()
        subscriptionsShow("Controlled inbox cleanup", notShown: "Zebra", "this device's library after the logout")
        XCTAssertEqual(queueAsShown(), deviceQueue, "this device's queue, favorites and positions are as they were")

        // Signing in again to the same account (the provider choice, not the kept-library dialog) resumes it.
        openSynchronization()
        signIn(account, password: "journey-password-1")
        XCTAssertTrue(element("sourceMessage").label.hasPrefix("This device already has a library for this account."))
        tap("serverAttachConfirm")
        waitValue("pref_synchronization_logout", contains: "Logged in as \(account.username) on \(server).", timeout: 60)
        XCTAssertFalse(app.buttons["ntp_server_libraries"].exists, "the kept library is the active one again")
        leaveSettings()
        subscriptionsShow("Zebra", notShown: "Controlled inbox cleanup", "the server library after signing in again")
        destination("NewEpisodesFragment", title: "Inbox")
        XCTAssertTrue(app.buttons[kept].waitForExistence(timeout: 30), "\(kept) is still in the Inbox\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons[removed].exists, "\(removed) stays out of the Inbox")
        screenshot("server-library-resumed")
    }

    /// The activation rule (PROTOCOL §15.4) through a real attachment: while an episode plays the server library is prepared
    /// and waits ("Server library ready"); the same episode keeps playing, its position advancing, and this device's
    /// library stays; the person pauses and the server library is used. The episode is half an hour long, far more than
    /// the whole journey, so the end of the audio cannot satisfy the rule instead of the pause.
    func test05AnAttachmentMadeWhilePlayingWaitsForThePause() async throws {
        let account = try await account(password: "journey-password-1")
        launch()
        // A half-hour episode (the app playback fixture), downloaded, then played.
        moreMenu("Add podcast").tapWhenSettled()
        tap("addRSS")
        fill("rssAddress", "http://127.0.0.1:18803/feed.xml?mode=download&run=\(library)")
        let confirm = app.buttons["Confirm"]
        XCTAssertTrue(waitHittable(confirm))
        confirm.tapWhenSettled()
        tap("subscribeFeed")
        let action = element("episode-action-1")
        XCTAssertEqual(action.label, "Download")
        action.tapWhenSettled()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: action)], timeout: 60), .completed, "downloaded")
        action.tapWhenSettled()
        let play = app.buttons["miniPlayerPlay"]
        func isPlaying(timeout: TimeInterval) -> Bool {
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", "Pause"), object: play)],
                           timeout: timeout) == .completed
        }
        XCTAssertTrue(isPlaying(timeout: 20), "playing")

        openSynchronization()
        signIn(account, password: "journey-password-1")
        XCTAssertTrue(element("sourceMessage").label.contains("NotTennaPod will use your library from \(server) on this device"))
        tap("serverAttachConfirm")
        tap("serverUseEmptyLibrary", timeout: 60)
        // Built, but not used while the episode plays.
        let status = element("ntp_server_status", timeout: 60)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Server library ready"), object: status)], timeout: 60), .completed,
                       "status \(status.label)")
        XCTAssertEqual(status.value as? String, "It will be used when playback is paused or stopped.")
        waitStatus("Ready")
        screenshot("ready-while-playing")
        leaveSettings()
        XCTAssertTrue(isPlaying(timeout: 10), "audio goes on")
        destination("SubscriptionFragment", title: "Subscriptions")
        let own = podcast("App Playback Lab")
        XCTAssertTrue(own.waitForExistence(timeout: 10), "this device's library is still shown while playing")

        // The same episode plays on: its position advances while the server library waits.
        tap("miniPlayerOpen")
        XCTAssertTrue(app.staticTexts["download episode"].waitForExistence(timeout: 10), "the playing episode")
        let position = element("playerPosition")
        let first = position.label
        let advancing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", first), object: position)
        XCTAssertEqual(XCTWaiter.wait(for: [advancing], timeout: 15), .completed, "the position advances from \(first)")
        func seconds(_ text: String) -> Int { text.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) } }
        XCTAssertGreaterThan(seconds(position.label), seconds(first))
        XCTAssertLessThan(seconds(position.label), 25 * 60, "far from the end of the half hour: \(position.label)")
        XCTAssertTrue(app.staticTexts["download episode"].exists)
        screenshot("playing-while-ready")

        // The person pauses: the server library (empty) is used.
        let pause = app.buttons["playerPlay"]
        XCTAssertEqual(pause.label, "Pause")
        pause.tapWhenSettled()
        XCTAssertTrue(own.waitForNonExistence(timeout: 60), "this device's podcast leaves with the switch")
        destination("SubscriptionFragment", title: "Subscriptions")
        XCTAssertTrue(app.staticTexts["subscriptionsEmptyTitle"].waitForExistence(timeout: 30), "the server library's empty Subscriptions\n\(app.debugDescription)")
        XCTAssertFalse(own.exists)
        XCTAssertFalse(play.exists && play.label == "Pause")
        openSynchronization()
        waitValue("pref_synchronization_logout", contains: "Logged in as \(account.username) on \(server).", timeout: 60)
        XCTAssertFalse(app.buttons["ntp_server_status"].exists)
        screenshot("server-mode-after-pause")
    }

    // MARK: - The exchange from the app

    /// "Keep using this library" at logout (PROTOCOL §15.4): the server's library becomes this phone's own and
    /// stays after a relaunch; the library from before signing in is kept aside as "Library from before …", with its
    /// exports and its removal; signing in later is a new attachment, never a resume of the kept library.
    func test07KeepUsingTheServerLibraryAtLogout() async throws {
        let account = try await account(password: "journey-password-1", library: "TestSupport/Data/subscriptions-screen/databases/mixed.db")
        launch(["-test-list-inbox-cleanup"])
        subscriptionsShow("Controlled inbox cleanup", notShown: "Zebra", "this device's library")
        openSynchronization()
        signIn(account, password: "journey-password-1")
        tap("serverAttachConfirm")
        waitValue("pref_synchronization_logout", contains: "Logged in as \(account.username) on \(server).", timeout: 90)
        waitStatus("Successful (")

        // Keep: nothing plays, so the Keep runs at once and the page reopens with no provider and the previous library.
        logOut(.keep)
        let previous = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "ntp_server_previous_library-")).firstMatch
        XCTAssertTrue(previous.waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertTrue(previous.label.hasPrefix("Library from before "), previous.label)
        XCTAssertEqual(app.buttons["preference_synchronization_description"].label, "Choose synchronization provider")
        XCTAssertFalse(app.buttons["ntp_server_libraries"].exists, "the kept library is this phone's own, not a server library")
        XCTAssertFalse(app.buttons["ntp_server_status"].exists, "the Keep has finished")
        screenshot("kept-library-page")
        leaveSettings()
        subscriptionsShow("Zebra", notShown: "Controlled inbox cleanup", "the kept library")

        // A relaunch keeps it.
        app.terminate(); launch()
        subscriptionsShow("Zebra", notShown: "Controlled inbox cleanup", "the kept library after a relaunch")
        openSynchronization()
        XCTAssertTrue(previous.waitForExistence(timeout: 20))

        // The previous library: Export offers the four exports; Remove library deletes it.
        tap(previous.identifier)
        XCTAssertEqual(element("previousLibraryExport").label, "Export")
        XCTAssertEqual(element("previousLibraryRemove").label, "Remove library")
        screenshot("previous-library-dialog")
        tap("previousLibraryExport")
        for (kind, label) in [("database", "Database export"), ("opml", "OPML export"), ("html", "HTML export"), ("favorites", "Favorites export")] {
            XCTAssertEqual(element("previousLibraryExport-\(kind)").label, label)
        }
        screenshot("previous-library-exports")
        tap("previousLibraryExportCancel")
        tap(previous.identifier)
        tap("previousLibraryRemove")
        XCTAssertEqual(element("sourceMessage").label, "Remove this library from this device? Its library data and downloads will be deleted.")
        tap("previousLibraryRemoveConfirm")
        XCTAssertTrue(previous.waitForNonExistence(timeout: 30))
        leaveSettings()
        subscriptionsShow("Zebra", notShown: "Controlled inbox cleanup", "the kept library after removing the previous one")
    }

    /// While a server library is active each export asks "Export which library?" (PROTOCOL §11.5): this
    /// phone's own library exports its podcasts, the server's library its own; both through the real Save picker.
    func test08EveryExportAsksWhichLibrary() async throws {
        keepLocalFilesSeeded(removing: [LocalFilesStorage.htmlExport, LocalFilesStorage.databaseExport])
        let account = try await account(password: "journey-password-1", library: "TestSupport/Data/subscriptions-screen/databases/mixed.db")
        launch(["-test-list-inbox-cleanup"])
        openSynchronization()
        signIn(account, password: "journey-password-1")
        tap("serverAttachConfirm")
        waitValue("pref_synchronization_logout", contains: "Logged in as \(account.username) on \(server).", timeout: 90)
        leaveSettings()
        moreMenu("Settings").tapWhenSettled()
        tap("Backup & restore")

        /// Chooses a library in the dialog, saves through the picker and returns the saved file.
        func export(_ row: String, choose: String, prefix: String, suffix: String) throws -> URL {
            tap(row)
            XCTAssertEqual(element("sourceMessageTitle").label, "Export which library?")
            let server = element("exportServerLibrary"), own = element("exportOwnLibrary")
            XCTAssertEqual(server.label, "The server's library")
            XCTAssertEqual(server.value as? String, "\(account.username) on 127.0.0.1")
            XCTAssertEqual(own.label, "This phone's own library")
            screenshot("export-choice-\(row)")
            tap(choose)
            let confirm = app.buttons["DOCPicker.actionButton"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 20), app.debugDescription)
            app.openLocalFilesRoot()
            confirm.tap()
            XCTAssertTrue(app.buttons["opmlExportShare"].waitForExistence(timeout: 150), app.debugDescription)
            XCTAssertTrue(app.staticTexts["Export successful"].exists)
            let saved = try XCTUnwrap(LocalFilesStorage.items(prefix: prefix, suffix: suffix).last)
            let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["OK", "Close"])).firstMatch
            if done.exists { done.tapWhenSettled() }
            return saved
        }
        let own = try export("htmlExport", choose: "exportOwnLibrary", prefix: "nottennapod-feeds-", suffix: ".html")
        let page = String(decoding: try Data(contentsOf: own), as: UTF8.self)
        XCTAssertTrue(page.contains("Controlled inbox cleanup") && !page.contains("Zebra"), "this phone's own library")
        let serverFile = try export("databaseExport", choose: "exportServerLibrary", prefix: "NotTennaPodBackup-", suffix: ".db")
        let summary = try LocalFilesStorage.backupSummary(serverFile)
        XCTAssertEqual(summary.userVersion, ["3110000"]); XCTAssertEqual(summary.integrity, ["ok"])
        XCTAssertTrue(summary.feeds.contains { $0.contains("Zebra") } && !summary.feeds.contains("Controlled inbox cleanup"), "\(summary.feeds)")
    }

    /// The Synchronization log (PROTOCOL §15.5): after Synchronize now the log lists the request,
    /// newest first; Share offers the log as a text file through the share sheet; Back returns to the page; settings
    /// search finds the log and opens it.
    func test09ShareTheSynchronizationLog() async throws {
        let account = try await account(password: "journey-password-1")
        launch()
        openSynchronization()
        signIn(account, password: "journey-password-1")
        attachEmpty(account)
        XCTAssertFalse(app.buttons["ntp_server_attention"].exists, "nothing needs attention")
        tap("pref_synchronization_sync")
        waitStatus("Successful (")

        func waitTitle(_ text: String) {
            let title = app.staticTexts["screenTitle"]
            let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", text), object: title)
            XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 20), .completed, "title \(title.exists ? title.label : "missing")")
        }
        let requested = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label == %@", "serverSyncLogRow", "Requested")).firstMatch
        tap("ntp_server_log")
        waitTitle("Synchronization log")
        XCTAssertTrue(requested.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue((requested.value as? String)?.hasPrefix("synchronize now, ") == true, "\(String(describing: requested.value))")
        screenshot("sync-log")

        tap("serverSyncLogShare")
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(sheet.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "nottennapod-sync-log-")).firstMatch
            .waitForExistence(timeout: 10), app.debugDescription)
        screenshot("sync-log-share")
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Cancel"])).firstMatch
        let region = app.otherElements["PopoverDismissRegion"]
        if close.exists && close.isHittable { close.tap() }
        else if region.exists { region.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.12)).tap() }
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
        waitTitle("Synchronization log")
        tap("toolbarBack")
        waitValue("pref_synchronization_logout", contains: "Logged in as \(account.username)")

        // Settings search finds the log and opens it, over the Synchronization page.
        leaveSettings()
        moreMenu("Settings").tapWhenSettled()
        tap("searchPreference")
        let field = app.textFields["settingsSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeTextSettled("Synchronization log")
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "settingsSearchResult-",
                                                      "Synchronization log")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10), app.debugDescription)
        result.tapWhenSettled()
        waitTitle("Synchronization log")
        XCTAssertTrue(requested.waitForExistence(timeout: 30))
        tap("toolbarBack")
        waitTitle("Synchronization")
    }

    /// The hub's proxy as every journey expects it: passing, no fault armed.
    private static func restoreProxy(_ control: URL) async {
        for (path, body) in [("proxy/rules/clear", [String: Any]()), ("proxy/state", ["state": "pass"])] {
            var request = URLRequest(url: control.appendingPathComponent(path), timeoutInterval: 60)
            request.httpMethod = "POST"
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    /// R, the hub's wire client: another installation of the account that signs in, pulls and listens. `client` names
    /// another R (one that never ran before a restore: R does not recover).
    private func r(_ action: String, _ body: [String: Any] = [:], client: String = "") async throws -> [String: Any] {
        try await call("POST", "r/journey-\(library.prefix(8))\(client)/\(action)", body)
    }

    /// Whether R, pulling until `timeout`, sees the episode titled `title` queued (`queued`) on the server.
    private func serverHas(_ title: String, queued: Bool, timeout: TimeInterval = 90, client: String = "") async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let episodes = try await r("pull", client: client)["episodes"] as? [[String: Any]] ?? []
            if episodes.contains(where: { $0["title"] as? String == title && $0["in_queue"] as? Bool == queued }) { return true }
            if Date() >= deadline { return false }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    /// The row of the episode titled `title` on the current list.
    private func episodeRow(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier MATCHES 'episode-[0-9]+' AND label BEGINSWITH %@", title)).firstMatch
    }

    /// Adds an episode of Zebra to the queue from the podcast's episode list, as a person does.
    private func queueFromZebra(_ title: String) {
        leaveSettings()
        destination("SubscriptionFragment", title: "Subscriptions")
        let zebra = podcast("Zebra")
        XCTAssertTrue(zebra.waitForExistence(timeout: 30), app.debugDescription)
        for _ in 0..<8 where !zebra.isRevealed(in: app) { app.scrollViews["libraryContent"].swipeUp() }
        zebra.tapWhenSettled()
        let row = episodeRow(title)
        XCTAssertTrue(row.waitForExistence(timeout: 30), "\(title)\n\(app.debugDescription)")
        for _ in 0..<5 where !row.isRevealed(in: app) { app.scrollViews["libraryContent"].swipeUp() }
        row.press(forDuration: 0.7)
        tap("addQueue")
        leaveSettings()
    }

    /// The server library's exchange runs from the app: a change made on this device reaches the server; a
    /// change made by another installation arrives and shows, and its end shows too; while the server cannot be
    /// reached the page says so with the change still to send, and "Synchronize now" sends it once it can; a server
    /// restored from a backup asks to sign in again, then recovers (PROTOCOL §6.11): the changes the restored server lost
    /// reach it again, and the library keeps everything.
    func test06TheExchangeRunsFromTheApp() async throws {
        let password = "journey-password-1"
        let account = try await account(password: password, library: "TestSupport/Data/subscriptions-screen/databases/mixed.db")
        launch()
        openSynchronization()
        signIn(account, password: password)
        XCTAssertTrue(element("sourceMessage").label.contains("NotTennaPod will use your library from \(server) on this device"))
        tap("serverAttachConfirm")
        waitValue("pref_synchronization_logout", contains: "Logged in as \(account.username) on \(server).", timeout: 90)
        waitStatus("Successful (")
        _ = try await r("login", ["username": account.username, "password": password])
        let backup = "journey-\(library)"
        _ = try await call("POST", "server/backup", ["name": backup])

        // A change made here reaches the server.
        queueFromZebra("Episode 12")
        let pushed = try await serverHas("Episode 12", queued: true)
        XCTAssertTrue(pushed, "the queue add reached the server")

        // Another installation listens to an episode: it arrives queued here, and leaves the queue when that
        // listening completes there.
        let listening = try await r("play", ["title": "Episode 13", "position_ms": 0])
        let session = try XCTUnwrap(listening["session"] as? String)
        destination("QueueFragment", title: "Queue")
        let thirteen = episodeRow("Episode 13")
        XCTAssertTrue(thirteen.waitForExistence(timeout: 90), "another installation's listening arrives\n\(app.debugDescription)")
        XCTAssertTrue(episodeRow("Episode 12").exists, "this device's own change is kept")
        screenshot("remote-change-shown")
        _ = try await r("end", ["session": session, "position_ms": 60_000, "completed": true])
        XCTAssertTrue(thirteen.waitForNonExistence(timeout: 90), "completed there, it leaves the queue here")
        XCTAssertTrue(episodeRow("Episode 12").exists)

        // The server cannot be reached (no new connection, and the open one drops what the app sends): the change waits
        // and the page says so; Synchronize now sends it when it can. The hub is restored whatever happens.
        addTeardownBlock { [control] in await Self.restoreProxy(control) }
        _ = try await call("POST", "proxy/state", ["state": "refuse"])
        _ = try await call("POST", "proxy/rules", ["mode": "drop_request", "path": "/v1/push", "count": 1_000])
        queueFromZebra("Episode 14")
        openSynchronization()
        waitStatus("Waiting for the server", timeout: 90)
        waitValue("pref_synchronization_sync", contains: "1 change not yet synchronized")
        screenshot("waiting-for-the-server")
        await Self.restoreProxy(control)
        tap("pref_synchronization_sync")
        waitStatus("Successful (", timeout: 90)
        let sync = element("pref_synchronization_sync")
        let sent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT (value CONTAINS %@)", "not yet synchronized"), object: sync)
        XCTAssertEqual(XCTWaiter.wait(for: [sent], timeout: 30), .completed, "sent: \(String(describing: sync.value))")
        let sentLater = try await serverHas("Episode 14", queued: true)
        XCTAssertTrue(sentLater, "Synchronize now sent the change")
        screenshot("synchronized")

        // The server is restored from the backup made before these changes: sign in again, then the recovery sends
        // back what the restored server lost (PROTOCOL §6.11), and synchronization is successful again.
        _ = try await call("POST", "server/restore", ["name": backup])
        tap("pref_synchronization_sync")
        waitStatus("Sign in again", timeout: 90)
        tap("ntp_server_status")
        fill("feedPassword", password, secure: true)
        tap("serverPasswordConfirm")
        // iOS may offer to save the password just entered; it covers the page until answered.
        app.dismissSavePasswordPrompt()
        waitStatus("Successful (", timeout: 120)
        XCTAssertFalse(app.buttons["ntp_server_status"].exists, "a complete recovery leaves nothing to explain")
        screenshot("recovered")
        // Another installation that signs in now (R itself does not recover) sees this device's changes on the server.
        _ = try await r("login", ["username": account.username, "password": password], client: "-after")
        let restored = try await serverHas("Episode 14", queued: true, client: "-after")
        XCTAssertTrue(restored, "the restored server has this device's changes again")
        let kept = try await serverHas("Episode 12", queued: true, client: "-after")
        XCTAssertTrue(kept)
        leaveSettings()
        destination("QueueFragment", title: "Queue")
        XCTAssertTrue(episodeRow("Episode 12").waitForExistence(timeout: 20), "the library is kept")
        XCTAssertTrue(episodeRow("Episode 14").exists)
    }

    /// The server is replaced by an empty one and the account made again (scenario 21 PROTOCOL §16, §6.11 `lineage_unknown`):
    /// signing in again finds the server without this library's history, so synchronization pauses and the page says
    /// why, keeping this library. "Start over with the server's library" signs in to the account's new library (an
    /// import of a database on the server's web page) and uses it on this device; the old library stays on the device
    /// with its changes.
    func test09StartOverWithTheServersLibraryAfterTheServerLostThisLibrarysHistory() async throws {
        let password = "journey-password-1"
        let account = try await account(password: password, library: "TestSupport/Data/subscriptions-screen/databases/mixed.db")
        launch()
        openSynchronization()
        signIn(account, password: password)
        tap("serverAttachConfirm")
        waitValue("pref_synchronization_logout", contains: "Logged in as \(account.username) on \(server).", timeout: 90)
        waitStatus("Successful (")
        queueFromZebra("Episode 12")
        openSynchronization()
        // The server is replaced by an empty one; the account is made again under its name, with a library imported.
        _ = try await call("POST", "server/wipe", ["setup": true])
        _ = try await call("POST", "accounts", ["password": password, "username": account.username,
                                                "import": "TestSupport/Data/subscriptions-screen/databases/mixed.db"])
        // A change made now cannot reach the server: the library keeps it.
        queueFromZebra("Episode 13")
        openSynchronization()
        tap("pref_synchronization_sync")
        waitStatus("Sign in again", timeout: 90)
        tap("ntp_server_status")
        fill("feedPassword", password, secure: true)
        tap("serverPasswordConfirm")
        app.dismissSavePasswordPrompt()
        waitStatus("Paused", timeout: 90)
        let status = element("ntp_server_status")
        XCTAssertEqual(status.label, "Synchronization paused")
        XCTAssertEqual(status.value as? String, "The server no longer has this library's history. This library and its changes are kept on this device.")
        let startOver = element("ntp_server_start_over")
        XCTAssertEqual(startOver.label, "Start over with the server's library")
        screenshot("lineage-unknown")
        tap("ntp_server_start_over")
        XCTAssertEqual(app.textFields["serverUsername"].value as? String, account.username)
        fill("serverPassword", password, secure: true)
        tap("serverLogin")
        XCTAssertTrue(element("sourceMessage").label.contains("NotTennaPod will use your library from \(server) on this device"))
        tap("serverAttachConfirm")
        waitValue("pref_synchronization_logout", contains: "Logged in as \(account.username) on \(server).", timeout: 90)
        waitStatus("Successful (", timeout: 90)
        XCTAssertFalse(app.buttons["ntp_server_start_over"].exists)
        screenshot("started-over")
        // The new library is the account's: its queue does not have what the old library queued.
        leaveSettings()
        destination("QueueFragment", title: "Queue")
        XCTAssertFalse(episodeRow("Episode 13").waitForExistence(timeout: 5), "nothing of the old lineage is replayed")
        // The old library is kept on the device, with its change.
        openSynchronization()
        logOut(.goBack)
        waitValue("ntp_server_libraries", contains: "2 libraries", timeout: 60)
        waitValue("ntp_server_libraries", contains: "1 change not yet synchronized")
    }

    // MARK: - Playback sessions

    /// Subscribes, on this phone in server mode, to the playback lab (a half-hour episode, `serve-app-playback-fixture`)
    /// and downloads its episode; returns its action button.
    private func subscribeAndDownloadTheLab() -> XCUIElement {
        leaveSettings()
        moreMenu("Add podcast").tapWhenSettled()
        tap("addRSS")
        fill("rssAddress", "http://127.0.0.1:18803/feed.xml?mode=download&run=\(library)")
        let confirm = app.buttons["Confirm"]
        XCTAssertTrue(waitHittable(confirm))
        confirm.tapWhenSettled()
        tap("subscribeFeed")
        let action = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'episode-action-'")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertEqual(action.label, "Download")
        action.tapWhenSettled()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: action)],
                                      timeout: 90), .completed, "downloaded")
        return action
    }

    /// The full player's position label (`HH:MM:SS`) as seconds.
    private func playerSeconds() -> Int {
        app.staticTexts["playerPosition"].label.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }

    /// Waits until the full player's position satisfies `condition` (seconds).
    private func waitPlayerPosition(_ description: String, timeout: TimeInterval = 60, _ condition: @escaping (Int) -> Bool) {
        let position = element("playerPosition")
        let reached = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            condition(position.label.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) })
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reached], timeout: timeout), .completed, "\(description): \(position.label)")
    }

    /// The episode titled `title` as another installation (R) reads it from the server, once `condition` holds.
    private func serverEpisode(_ title: String, timeout: TimeInterval = 120, _ condition: ([String: Any]) -> Bool) async throws -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: Any]?
        while Date() < deadline {
            let episodes = try await r("pull")["episodes"] as? [[String: Any]] ?? []
            last = episodes.first { $0["title"] as? String == title }
            if let last, condition(last) { return last }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("\(title) on the server: \(String(describing: last))")
        return nil
    }

    /// Listening on the phone reaches another installation (end to end): subscribed, played and
    /// paused here, the server has its position; completed here (played to its natural end), the server has it played,
    /// at position 0, out of the queue, with its listening counted.
    func test09ListeningOnThePhoneReachesAnotherInstallation() async throws {
        let password = "journey-password-1"
        let account = try await account(password: password)
        launch()
        openSynchronization()
        signIn(account, password: password)
        attachEmpty(account)
        let action = subscribeAndDownloadTheLab()
        action.tapWhenSettled()
        let mini = app.buttons["miniPlayerPlay"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", "Pause"), object: mini)],
                                      timeout: 30), .completed, "playing")
        tap("miniPlayerOpen")
        waitPlayerPosition("it plays") { $0 >= 3 }
        let play = app.buttons["playerPlay"]
        XCTAssertEqual(play.label, "Pause")
        play.tapWhenSettled()
        let paused = playerSeconds()
        screenshot("paused-on-the-phone")
        _ = try await r("login", ["username": account.username, "password": password])
        let shown = try await serverEpisode("download episode") { ($0["position"] as? Int ?? 0) >= 3_000 && $0["play_state"] as? String == "unplayed" }
        XCTAssertLessThanOrEqual(abs((shown?["position"] as? Int ?? 0) / 1_000 - paused), 1, "the pause's position reached the server")

        // Played to its end here (a seek to the end of the media, then playing what is left if any): the completion
        // reaches the server.
        let seek = app.descendants(matching: .any)["playerSeek"]
        XCTAssertTrue(seek.waitForExistence(timeout: 10))
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        // The seek reaches the end of the media and ends the episode; if any of it is left, it plays to its end.
        if !play.waitForNonExistence(timeout: 10), play.label == "Play" { play.tapWhenSettled() }
        let completed = try await serverEpisode("download episode", timeout: 180) {
            $0["play_state"] as? String == "played" && ($0["position"] as? Int) == 0 && $0["in_queue"] as? Bool == false
        }
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForNonExistence(timeout: 30), "the episode ended here")
        XCTAssertGreaterThanOrEqual(completed?["played_ms"] as? Int ?? 0, 3_000, "the listening counts")
        screenshot("completed-on-the-phone")
    }

    /// A position another installation took is adopted by this phone's paused player (PROTOCOL §8.6): it shows there, and the
    /// person's resume goes on from it, which the server then has.
    func test10ARemotePositionIsAdoptedByAPausedPlayer() async throws {
        let password = "journey-password-1"
        let account = try await account(password: password)
        launch()
        openSynchronization()
        signIn(account, password: password)
        attachEmpty(account)
        let action = subscribeAndDownloadTheLab()
        action.tapWhenSettled()
        tap("miniPlayerOpen")
        waitPlayerPosition("it plays") { $0 >= 2 }
        let play = app.buttons["playerPlay"]
        XCTAssertEqual(play.label, "Pause")
        play.tapWhenSettled()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: play)],
                                      timeout: 10), .completed)
        app.buttons["playerCollapse"].tapWhenSettled()
        // Another installation plays the same episode on from 10:00 to 15:00.
        _ = try await r("login", ["username": account.username, "password": password])
        _ = try await serverEpisode("download episode") { ($0["position"] as? Int ?? 0) > 0 }
        let listening = try await r("play", ["title": "download episode", "position_ms": 600_000])
        let session = try XCTUnwrap(listening["session"] as? String)
        _ = try await r("checkpoint", ["session": session, "position_ms": 900_000])
        // The phone synchronizes; its paused player moves to 15:00.
        openSynchronization()
        tap("pref_synchronization_sync")
        waitStatus("Successful (", timeout: 90)
        leaveSettings()
        tap("miniPlayerOpen")
        waitPlayerPosition("the remote position is adopted", timeout: 90) { $0 == 900 }
        XCTAssertEqual(play.label, "Play", "adoption never plays")
        screenshot("adopted-remote-position")
        // The person resumes: playback goes on from 15:00, and the server follows.
        play.tapWhenSettled()
        waitPlayerPosition("it plays on from the adopted position") { $0 >= 903 && $0 < 960 }
        play.tapWhenSettled()
        let resumed = try await serverEpisode("download episode") { ($0["position"] as? Int ?? 0) >= 903_000 }
        XCTAssertLessThan(resumed?["position"] as? Int ?? .max, 960_000)
    }
}
