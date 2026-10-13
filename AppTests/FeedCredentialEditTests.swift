import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct FeedCredentialEditTests {
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let result = view as? T { return result }
        for child in view.subviews { if let result: T = find(id, in: child) { return result } }
        return nil
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate())
    }
    @Test(arguments: ["success", "saveFailure", "refreshFailure", "cancel"])
    func editingPreservesDraftAndOrdersDurableSaveBeforeRefresh(outcome: String) async throws {
        let original = FeedCredentials(username: "saved-user", password: "saved-password")
        var selected = original, events: [String] = [], failures = 0
        var saveGate: CheckedContinuation<Void, Never>?
        let flow = FeedCredentialEditFlow(read: { selected }, save: { value in
            events.append("saveStarted")
            await withCheckedContinuation { saveGate = $0 }
            if outcome == "saveFailure" { throw CocoaError(.fileWriteNoPermission) }
            selected = value; events.append("saved")
        }, requestRefresh: {
            #expect(selected == .init(username: "", password: "updated"))
            events.append("refresh")
            if outcome == "refreshFailure" { throw CocoaError(.fileWriteNoPermission) }
        }, failed: { _ in failures += 1 })
        defer { saveGate?.resume() }
        try await withViewTestWindow { host, _ in
            flow.show(from: host)
            try await wait { host.presentedViewController?.viewIfLoaded?.window != nil && host.presentedViewController?.isBeingPresented == false }
            let dialog = try #require(host.presentedViewController)
            #expect(find("feedAuthenticationFailure", in: dialog.view) as UILabel? == nil)
            let user: UITextField = try #require(find("feedUsername", in: dialog.view))
            let password: UITextField = try #require(find("feedPassword", in: dialog.view))
            #expect(user.text == original.username && password.text == original.password && password.isSecureTextEntry)
            user.text = ""; password.text = "updated"
            let action: UIButton = try #require(find(outcome == "cancel" ? "feedAuthenticationCancel" : "feedAuthenticationConfirm", in: dialog.view))
            action.sendActions(for: .touchUpInside)
            try await wait { host.presentedViewController == nil }
            if outcome == "cancel" {
                #expect(selected == original && events.isEmpty && failures == 0)
                return
            }
            try await wait { saveGate != nil }
            #expect(events == ["saveStarted"] && selected == original && flow.isBusy)
            // The dialog has already gone away. Its authorized operation remains owned.
            let continuation = saveGate; saveGate = nil; continuation?.resume()
            try await wait { !flow.isBusy }
            #expect(events == (outcome == "saveFailure" ? ["saveStarted"] : ["saveStarted", "saved", "refresh"]))
            #expect(selected == (outcome == "saveFailure" ? original : .init(username: "", password: "updated")))
            #expect(failures == (outcome == "success" ? 0 : 1))
        }
    }

    @Test func lateCredentialReadDoesNotOpenOnAnotherScreen() async throws {
        var readGate: CheckedContinuation<FeedCredentials?, Never>?, allowed = true, reads = 0
        let flow = FeedCredentialEditFlow(read: {
            reads += 1
            return await withCheckedContinuation { readGate = $0 }
        }, save: { _ in Issue.record("No edit was confirmed") }, requestRefresh: { Issue.record("No refresh was requested") }, failed: { _ in Issue.record("Unexpected failure") })
        defer { readGate?.resume(returning: nil) }
        try await withViewTestWindow { host, _ in
            flow.show(from: host) { allowed }
            flow.show(from: host) { allowed }
            try await wait { readGate != nil }
            #expect(reads == 1)
            allowed = false
            let continuation = readGate; readGate = nil; continuation?.resume(returning: nil)
            try await wait { !flow.isBusy }
            #expect(host.presentedViewController == nil)
        }
    }

    @Test(arguments: [false, true]) func authenticationRowFollowsAutomationAndIsHiddenForLocalFeed(local: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CredentialRow-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let feed: LibraryFeed
        if local {
            let folder = root.appendingPathComponent("Local podcast")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let selection = try await LocalFolderSelection.prepare(directory: folder)
            feed = try await store.registerLocalFolder(title: "Podcast", directoryIdentity: selection.identity, bookmark: selection.bookmark).feed
        } else {
            let source = "https://example.test/feed"
            feed = try await store.insert(.init(feed: .init(format: .rss, title: "Podcast", episodes: []), source: source,
                responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil))
        }
        let view = FeedSettingsView(feed: feed)
        view.frame = CGRect(origin: .zero, size: view.sizeThatFits(.init(width: 320, height: 600)))
        view.layoutIfNeeded()
        let row: UIControl? = find("feedAuthentication", in: view)
        #expect((row == nil) == local)
        if let row {
            let notification: UIControl = try #require(find("feedNotification", in: view))
            #expect(notification.frame.maxY < row.frame.minY && view.bounds.insetBy(dx: -0.01, dy: -0.01).contains(row.frame), "row \(row.frame) in \(view.bounds)")  // row edges are sums of fractional heights
            #expect(row.accessibilityLabel == "Authentication")
            #expect(row.accessibilityHint == Appearance.text("authentication_descr"))
            var invoked = false
            view.onAction = { if case .authentication = $0 { invoked = true } }
            row.sendActions(for: .touchUpInside); #expect(invoked)
        }
        try await store.close()
    }
}
