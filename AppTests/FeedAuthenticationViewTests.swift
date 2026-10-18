import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized) struct FeedAuthenticationViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let result = view as? T { return result }
        for child in view.subviews { if let result: T = find(id, in: child) { return result } }
        return nil
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(predicate())
    }
    @Test(arguments: [false, true]) func credentialsVisibilityLayoutAndConfirm(rtl: Bool) async throws {
        let initial = FeedCredentials(username: "fixture-name", password: "fixture-secret")
        var confirmed: FeedCredentials?, cancelled = 0
        let dialog = FeedAuthenticationController.make(credentials: initial, confirm: { confirmed = $0 }, cancel: { cancelled += 1 })
        try await withViewTestWindow { host, _ in
            host.present(dialog, animated: false)
            try await wait { dialog.view.window != nil && !dialog.isBeingPresented }
            dialog.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            let username: UITextField = try #require(find("feedUsername", in: dialog.view))
            let password: UITextField = try #require(find("feedPassword", in: dialog.view))
            let eye: UIButton = try #require(find("feedPasswordVisibility", in: dialog.view))
            #expect(username.text == initial.username && password.text == initial.password && password.isSecureTextEntry)
            #expect(find("feedAuthenticationFailure", in: dialog.view) as UILabel? != nil)
            for width in [320.0, 402, 720] {
                dialog.view.frame.size.width = width; dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                let body: UIView = try #require(find("feedAuthenticationBody", in: dialog.view))
                body.layoutIfNeeded()
                let u = username.convert(username.bounds, to: body), p = password.convert(password.bounds, to: body)
                #expect(u.maxY < p.minY)
                #expect(rtl ? eye.frame.maxX < p.minX : p.maxX < eye.frame.minX)
                #expect(body.bounds.contains(eye.frame) && body.bounds.contains(u) && body.bounds.contains(p))
                // The wrapped failure message stays inside its rounded toast, clear of the corners, and on screen.
                let failure: UILabel = try #require(find("feedAuthenticationFailure", in: dialog.view))
                let toast = try #require(sequence(first: failure as UIView, next: \.superview).first { $0.layer.cornerRadius > 0 })
                let text = failure.convert(failure.bounds, to: toast)
                #expect(text.minX >= 12 && toast.bounds.maxX - text.maxX >= 12, "Text inset from the toast's rounded ends")
                #expect(text.minY >= 8 && toast.bounds.maxY - text.maxY >= 8)
                #expect(failure.bounds.height >= failure.sizeThatFits(CGSize(width: failure.bounds.width, height: .greatestFiniteMagnitude)).height - 1)
                #expect(dialog.view.bounds.contains(toast.convert(toast.bounds, to: dialog.view)))
            }
            eye.sendActions(for: .touchUpInside)
            #expect(!password.isSecureTextEntry && password.text == initial.password && eye.alpha == 1)
            eye.sendActions(for: .touchUpInside)
            #expect(password.isSecureTextEntry)
            #expect(password.text == initial.password)
            #expect(eye.alpha < 1 && eye.alpha > 0.3, "Eye icon is dimmed while the password is hidden")
            username.text = ""; password.text = ""
            let button: UIButton = try #require(find("feedAuthenticationConfirm", in: dialog.view))
            button.sendActions(for: .touchUpInside)
            try await wait { confirmed != nil }
            #expect(confirmed == FeedCredentials(username: "", password: "") && cancelled == 0)
            #expect(host.presentedViewController == nil)
        }
    }
    @Test(arguments: [false, true]) func cancelClosesOnlyAfterDialogDismisses(escape: Bool) async throws {
        var cancelled = 0, confirmed = false, presenterWasClear = false
        try await withViewTestWindow { host, _ in
            let dialog = FeedAuthenticationController.make(credentials: nil, confirm: { _ in confirmed = true }, cancel: {
                cancelled += 1; presenterWasClear = host.presentedViewController == nil
            })
            host.present(dialog, animated: false)
            try await wait { dialog.view.window != nil && !dialog.isBeingPresented }
            #expect(find("feedAuthenticationFailure", in: dialog.view) as UILabel? == nil)
            if escape { #expect(dialog.accessibilityPerformEscape()) }
            else {
                let button: UIButton = try #require(find("feedAuthenticationCancel", in: dialog.view))
                button.sendActions(for: .touchUpInside)
            }
            try await wait { cancelled == 1 }
            #expect(!confirmed && presenterWasClear)
        }
    }
    @Test func realKeychainPreviewReopenAndDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FeedKeychain-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let vault = KeychainSynchronizationCredentials(service: "org.nottennapod.app.tests.feeds.\(UUID())")
        let auth = FeedAuthentication(store: store, vault: vault)
        let secret = FeedCredentials(username: "fixture", password: "test-secret")
        let feed = try await auth.preparePreview(.init(feed: .init(format: .rss, episodes: []), source: "https://example.test/feed",
            responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil), credentials: secret)
        do {
            #expect(try await auth.credentials(feedID: feed.id) == secret)
            let reopened = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
            #expect(try await FeedAuthentication(store: reopened, vault: vault).credentials(feedID: feed.id) == secret)
            try await reopened.close()
            #expect(try await store.requestFeedDeletion(feedID: feed.id))
            try await auth.recoverCredentialCleanup()
            #expect(try await auth.credentials(feedID: feed.id) == nil)
            try await store.close()
        } catch {
            _ = try? await store.requestFeedDeletion(feedID: feed.id)
            try? await auth.recoverCredentialCleanup(); try? await store.close(); throw error
        }
    }
}
