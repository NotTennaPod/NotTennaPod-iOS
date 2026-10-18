import UIKit
import Synchronization
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Mounted dialog and secure-restoration checks. Real browser/provider handoff
/// is covered separately by NextcloudAuthenticationTests in the UI target.
@MainActor @Suite(.serialized)
struct NextcloudAuthenticationViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let result = view as? T, result.accessibilityIdentifier == id { return result }
        return view.subviews.lazy.compactMap { find(id, in: $0, as: T.self) }.first
    }
    private func wait(_ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await condition())
    }
    private func tap(_ id: String, _ view: UIView) throws {
        let button: UIButton = try #require(find(id, in: view))
        try #require(button.isEnabled); button.sendActions(for: .touchUpInside)
    }
    private func fixture(_ transport: NextcloudViewTransport = .init(),
                         _ body: @MainActor (FeedLibraryStore, SynchronizationAccounts, NextcloudAuthenticationFlow,
                                              NextcloudViewBrowser) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NextcloudView-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try FeedLibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        let accounts = SynchronizationAccounts(store: store, credentials: NextcloudViewCredentials(), makeTransport: { transport })
        let browser = NextcloudViewBrowser()
        let flow = NextcloudAuthenticationFlow(accounts: accounts) { browser.urls.append($0); return true }
        do {
            try await body(store, accounts, flow, browser)
            flow.cancel(); await transport.release(); try await store.close()
        } catch {
            flow.cancel(); await transport.release(); try? await store.close(); throw error
        }
    }

    @Test(arguments: [CGFloat(288), 512, 720], [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge])
    func bodyPreservesSourceOrderInsetsAndBusyReplacement(width: CGFloat, category: UIContentSizeCategory) async throws {
        try await withViewTestWindow { hostController, _ in
        let body = NextcloudAuthenticationBody()
        hostController.view.addSubview(body)
        defer { body.removeFromSuperview() }
        body.traitOverrides.preferredContentSizeCategory = category
        body.updateTraitsIfNeeded()
        // Idle, waiting for the browser, then idle again when the entry returns.
        for busy in [false, true, false] {
            body.update(busy: busy, host: "https://nextcloud.example.test/cloud")
            body.frame.size = body.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            body.setNeedsLayout(); body.layoutIfNeeded()
            let explanation: UILabel = try #require(find("nextcloudHostExplanation", in: body))
            let host: UITextField = try #require(find("nextcloudHost", in: body))
            let field = try #require(host.superview?.superview)
            let proceed: UIButton = try #require(find("nextcloudProceed", in: body))
            let instruction: UILabel = try #require(find("nextcloudBrowserInstruction", in: body))
            let spinner: PlayerLoadingIndicator = try #require(find("nextcloudAuthenticationProgress", in: body))
            let first = explanation.convert(explanation.bounds, to: body)
            let second = field.convert(field.bounds, to: body)
            // Explanation, then host field, then Proceed (or the busy instruction): inside the
            // dialog's margins, in that order, not overlapping, text not clipped.
            #expect(body.bounds.insetBy(dx: 8, dy: 8).contains(first), "First \(first); width \(width)")
            #expect(second.minY >= first.maxY, "Explanation \(first); host \(second)")
            #expect(body.bounds.insetBy(dx: 8, dy: 0).contains(second))
            #expect(explanation.bounds.height >= explanation.sizeThatFits(CGSize(width: explanation.bounds.width, height: .greatestFiniteMagnitude)).height - 0.5)
            #expect(host.isEnabled == !busy && proceed.isHidden == busy)
            #expect(spinner.isAnimating == busy && spinner.isHidden == !busy && instruction.superview?.isHidden == !busy)
            let last = (busy ? instruction.superview! : proceed).convert((busy ? instruction.superview! : proceed).bounds, to: body)
            #expect(last.minY >= second.maxY, "Host \(second); next \(last)")
            #expect(body.bounds.insetBy(dx: 8, dy: 8).contains(last), "Body \(body.bounds); last \(last); busy \(busy)")
            if busy {
                #expect(!spinner.isHidden && spinner.bounds.width >= 24 && spinner.bounds.height >= 24)
                #expect(!spinner.frame.intersects(instruction.frame))
                #expect(instruction.bounds.height >= instruction.sizeThatFits(CGSize(width: instruction.bounds.width, height: .greatestFiniteMagnitude)).height - 0.5)
                #expect(host.text == "https://nextcloud.example.test/cloud")
            }
        }
    }

    }

    @Test func proceedLaunchesBrowserAndCancelClearsPendingWithoutSelectingAccount() async throws {
        let transport = NextcloudViewTransport()
        try await fixture(transport) { store, _, flow, browser in
            try await withViewTestWindow { host, _ in
                let dialog = NextcloudAuthenticationController(flow: flow)
                var sessions: [NextcloudAuthenticationSession?] = []
                dialog.onSessionChange = { sessions.append($0) }
                host.present(dialog, animated: false)
                try await wait { dialog.view.window != nil && !dialog.isBeingPresented }
                let title: UILabel = try #require(find("sourceMessageTitle", in: dialog.view))
                #expect(title.accessibilityLabel == Appearance.text("gpodnetauth_login_butLabel"))
                let field: UITextField = try #require(find("nextcloudHost", in: dialog.view))
                field.text = "https://cloud.example.test/base"
                try tap("nextcloudProceed", dialog.view)
                try await wait { await transport.isWaiting }
                #expect(browser.urls == [URL(string: "https://cloud.example.test/browser")!])
                #expect(!field.isEnabled && flow.busy && sessions.contains { $0 != nil })
                #expect(!dialog.accessibilityPerformEscape() && host.presentedViewController === dialog)
                #expect(try await store.synchronizationState().account == nil)
                try tap("nextcloudCancel", dialog.view)
                try await wait { host.presentedViewController == nil }
                await transport.release()
                #expect(flow.pendingSession == nil && !flow.busy && sessions.last! == nil)
                #expect(try await store.synchronizationState().account == nil)
            }
        }
    }

    @Test(arguments: ["OK", "Escape", "presenter", "ancestor"])
    func nestedAdviceKeepsOneBackdropDimsRetainedSurfaceAndRestoresOnDismissal(dismissal: String) async throws {
        try await fixture { _, _, flow, _ in
            try await withViewTestWindow { host, window in
                host.view.backgroundColor = UIColor(red: 249 / 255, green: 252 / 255, blue: 255 / 255, alpha: 1)
                let dialog = NextcloudAuthenticationController(flow: flow)
                dialog.overrideUserInterfaceStyle = .light
                host.present(dialog, animated: false)
                try await wait { dialog.view.window != nil && !dialog.isBeingPresented }
                let outside = CGPoint(x: 2, y: window.bounds.height * 0.8)
                func capture(_ name: String) throws -> CGImage {
                    window.layoutIfNeeded()
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
                    let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                        #expect(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                    }
                    Attachment.record(try #require(image.pngData()), named: name + ".png")
                    return try #require(image.cgImage)
                }
                func rgb(_ image: CGImage, _ point: CGPoint) throws -> [Int] {
                    let pixel = try #require(image.cropping(to: CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1)))
                    var bytes = [UInt8](repeating: 0, count: 4)
                    try bytes.withUnsafeMutableBytes { buffer in
                        let context = try #require(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                    }
                    return bytes.prefix(3).map(Int.init)
                }
                // Colour comparisons are relative with a generous tolerance: they check only that
                // the backdrop is dimmed once (not doubled by nested advice) and never left behind.
                func close(_ actual: [Int], _ expected: [Int]) {
                    #expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= 12 }, "RGB \(actual), expected \(expected)")
                }
                func darker(_ actual: [Int], than reference: [Int], by amount: Int = 20) {
                    #expect(actual.reduce(0, +) < reference.reduce(0, +) - amount, "RGB \(actual) not darker than \(reference)")
                }
                let background = [249, 252, 255]
                let original = try rgb(capture("nextcloud-before-advice-\(dismissal)"), outside)
                darker(original, than: background)
                let advice = SourceMessageController(title: "Error", message: "Advice")
                advice.showsSourceElevation = true
                advice.replacesPresentingMessageDim = true
                dialog.present(advice, animated: false)
                try await wait { advice.view.window != nil && !advice.isBeingPresented }
                let parentContent: UIScrollView = try #require(find("sourceMessageContent", in: dialog.view))
                let childContent: UIScrollView = try #require(find("sourceMessageContent", in: advice.view))
                for inset: CGFloat in [0, 40, 0] {
                    // Change the retained surface geometry while the advice stays
                    // presented. The dim must follow rounded edges and elevation.
                    dialog.additionalSafeAreaInsets = .init(top: 0, left: inset, bottom: 0, right: 0)
                    dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                    advice.view.setNeedsLayout(); advice.view.layoutIfNeeded()
                    let parentPanel = parentContent.convert(parentContent.bounds, to: window)
                    let childPanel = childContent.convert(childContent.bounds, to: window)
                    let surface = CGPoint(x: parentPanel.midX, y: parentPanel.minY + 10)
                    try #require(!childPanel.insetBy(dx: -20, dy: -20).contains(surface))
                    let covered = try capture("nextcloud-advice-\(dismissal)-\(Int(inset))")
                    // Outside both dialogs: still a single dim, not a doubled one.
                    close(try rgb(covered, outside), original)
                    // The Nextcloud dialog behind the advice is dimmed (it follows resizing).
                    advice.view.isHidden = true
                    let retained = try capture("nextcloud-retained-surface-\(dismissal)-\(Int(inset))")
                    advice.view.isHidden = false
                    darker(try rgb(covered, surface), than: try rgb(retained, surface))
                }
                if dismissal == "OK" { try tap("sourceMessageOK", advice.view) }
                else if dismissal == "Escape" { #expect(advice.accessibilityPerformEscape()) }
                else if dismissal == "presenter" { dialog.dismiss(animated: true) }
                else { host.dismiss(animated: true) }
                if dismissal == "ancestor" {
                    try await wait { host.presentedViewController == nil }
                    close(try rgb(capture("nextcloud-after-ancestor-dismissal"), outside), background)
                    host.present(dialog, animated: false)
                    try await wait { dialog.view.window != nil && !dialog.isBeingPresented }
                } else { try await wait { dialog.presentedViewController == nil } }
                close(try rgb(capture("nextcloud-after-advice-\(dismissal)"), outside), original)
                #expect(host.presentedViewController === dialog)
                let ordinary = SourceMessageController(message: "Unrelated advice")
                dialog.present(ordinary, animated: false)
                try await wait { ordinary.view.window != nil && !ordinary.isBeingPresented }
                // Ordinary (non-replacing) advice adds its own dim on top.
                darker(try rgb(capture("ordinary-advice-\(dismissal)"), outside), than: original)
                ordinary.dismiss(animated: false)
                try await wait { dialog.presentedViewController == nil }
                try tap("nextcloudCancel", dialog.view)
                try await wait { host.presentedViewController == nil }
                close(try rgb(capture("nextcloud-after-cancel-\(dismissal)"), outside), background)
            }
        }
    }

    @Test func failedStartShowsSeparateAdviceRestoresHostAndRetryCanConnect() async throws {
        let transport = NextcloudViewTransport(startFailures: 1, holdsPoll: false)
        try await fixture(transport) { store, _, flow, browser in
            try await withViewTestWindow { host, _ in
                let dialog = NextcloudAuthenticationController(flow: flow)
                host.present(dialog, animated: false)
                try await wait { dialog.view.window != nil && !dialog.isBeingPresented }
                let field: UITextField = try #require(find("nextcloudHost", in: dialog.view))
                field.text = "https://cloud.example.test/base"
                try tap("nextcloudProceed", dialog.view)
                try await wait { dialog.presentedViewController != nil && !flow.busy }
                let error = try #require(dialog.presentedViewController as? SourceMessageController)
                #expect(error.replacesPresentingMessageDim)
                let message: UILabel = try #require(find("sourceMessage", in: error.view))
                #expect(message.attributedText?.string == Appearance.text("nextcloud_login_error_generic") + "\n\nReturn code 503")
                #expect(field.isEnabled && field.text == "https://cloud.example.test/base" && browser.urls.isEmpty)
                try tap("sourceMessageOK", error.view)
                try await wait { dialog.presentedViewController == nil }
                try tap("nextcloudProceed", dialog.view)
                try await wait { host.presentedViewController == nil && flow.connectedEpoch != nil }
                let state = try await store.synchronizationState()
                #expect(state.account?.host == "https://returned.example.test/subfolder")
                #expect(state.account?.username == "alice" && state.request != nil && state.subscriptionTimestamp == 0 && state.episodeTimestamp == 0)
                #expect(browser.urls.count == 1)
            }
        }
    }

    @Test func restoredTokenSurvivesInitialViewLoadAndSkipsBrowser() async throws {
        let transport = NextcloudViewTransport()
        try await fixture(transport) { store, accounts, flow, browser in
            let session = NextcloudAuthenticationSession(rawHost: "https://cloud.example.test/base", token: "opaque",
                endpoint: URL(string: "https://cloud.example.test/poll")!, expectedEpoch: try await accounts.authenticationEpoch())
            try await withViewTestWindow { host, _ in
                let dialog = NextcloudAuthenticationController(flow: flow, restoring: session)
                var saved: NextcloudAuthenticationSession? = session
                var cleared = false
                dialog.onSessionChange = { saved = $0; if $0 == nil { cleared = true } }
                dialog.loadViewIfNeeded()
                #expect(saved == session)
                host.present(dialog, animated: false)
                try await wait { await transport.isWaiting }
                #expect(browser.urls.isEmpty && saved == session && !cleared)
                let field: UITextField = try #require(find("nextcloudHost", in: dialog.view))
                #expect(field.text == session.rawHost && !field.isEnabled)
                await transport.release()
                try await wait { host.presentedViewController == nil && flow.connectedEpoch != nil }
                #expect(saved == nil && browser.urls.isEmpty)
                #expect(await transport.starts == 0)
                #expect(try await store.synchronizationState().account?.username == "alice")
            }
        }
    }

    @Test func staleRestorationCannotReplaceNewerAccount() async throws {
        try await fixture { store, accounts, flow, browser in
            let session = NextcloudAuthenticationSession(rawHost: "https://cloud.example.test", token: "opaque",
                endpoint: URL(string: "https://cloud.example.test/poll")!, expectedEpoch: try await accounts.authenticationEpoch())
            _ = try await accounts.connect(.init(backend: .gpodder, host: "https://new.example.test", username: "new", device: "phone"), password: "new", fullSync: false)
            await flow.resume(session: session)
            #expect(flow.error != nil && flow.pendingSession == nil && flow.connectedEpoch == nil)
            #expect(browser.urls.isEmpty && !flow.busy)
            #expect(try await store.synchronizationState().account?.username == "new")
        }
    }

    @Test func focusedHostAndCancelSurviveNarrowAsymmetricResizing() async throws {
        try await fixture { _, _, flow, _ in
            try await withViewTestWindow { host, _ in
                let dialog = NextcloudAuthenticationController(flow: flow)
                host.addChild(dialog); host.view.addSubview(dialog.view); dialog.didMove(toParent: host)
                defer { dialog.willMove(toParent: nil); dialog.view.removeFromSuperview(); dialog.removeFromParent() }
                dialog.view.traitOverrides.preferredContentSizeCategory = .large
                dialog.view.frame = CGRect(x: 0, y: 0, width: 430, height: 720)
                dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                let field: UITextField = try #require(find("nextcloudHost", in: dialog.view))
                field.text = "https://cloud.example.test/base"
                try #require(field.becomeFirstResponder())
                let start = try #require(field.position(from: field.beginningOfDocument, offset: 2))
                let end = try #require(field.position(from: field.beginningOfDocument, offset: 7))
                field.selectedTextRange = field.textRange(from: start, to: end)
                for (width, left, right): (CGFloat, CGFloat, CGFloat) in [(320, 31, 7), (720, 7, 31), (320, 7, 31)] {
                    dialog.view.frame.size = CGSize(width: width, height: 720)
                    dialog.additionalSafeAreaInsets = .init(top: 0, left: left, bottom: 0, right: right)
                    dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                    #expect(find("nextcloudHost", in: dialog.view, as: UITextField.self) === field)
                    #expect(field.isFirstResponder && field.text == "https://cloud.example.test/base")
                    let range = try #require(field.selectedTextRange)
                    #expect(field.offset(from: field.beginningOfDocument, to: range.start) == 2)
                    #expect(field.offset(from: field.beginningOfDocument, to: range.end) == 7)
                    let outer: UIScrollView = try #require(find("sourceMessageContent", in: dialog.view))
                    let body: UIScrollView = try #require(find("sourceMessageBody", in: dialog.view))
                    let safe = dialog.view.safeAreaLayoutGuide.layoutFrame
                    let panel = outer.convert(outer.bounds, to: dialog.view)
                    #expect(panel.minX >= safe.minX && panel.maxX <= safe.maxX)
                    for scroll in [outer, body] {
                        #expect(scroll.bounds.insetBy(dx: -0.5, dy: -0.5).contains(field.convert(field.bounds, to: scroll)))
                    }
                    let cancel: UIButton = try #require(find("nextcloudCancel", in: dialog.view))
                    let actions: UIScrollView = try #require(find("sourceMessageActions", in: dialog.view))
                    #expect(cancel.isEnabled && actions.bounds.insetBy(dx: -0.5, dy: -0.5).contains(cancel.frame))
                    #expect(outer.bounds.insetBy(dx: -0.5, dy: -0.5).contains(actions.convert(actions.bounds, to: outer)))
                }
                field.resignFirstResponder()
            }
        }
    }

    @Test func restorationUsesSceneAndLibraryNamespacesAndClearWorksWithoutLoad() throws {
        let namespace = "test-\(UUID())"
        let first = NextcloudAuthenticationRestoration(sceneID: "first", namespace: namespace)
        let second = NextcloudAuthenticationRestoration(sceneID: "second", namespace: namespace)
        let isolated = NextcloudAuthenticationRestoration(sceneID: "first", namespace: namespace + "-other")
        defer { try? first.clear(); try? second.clear(); try? isolated.clear() }
        let session = NextcloudAuthenticationSession(rawHost: "https://cloud.example.test/base", token: "fixture-secret",
            endpoint: URL(string: "https://cloud.example.test/poll")!, expectedEpoch: UUID())
        try first.update(session)
        #expect(try second.load() == nil && isolated.load() == nil)
        #expect(try NextcloudAuthenticationRestoration(sceneID: "first", namespace: namespace).load() == session)
        try NextcloudAuthenticationRestoration(sceneID: "first", namespace: namespace).update(nil)
        #expect(try NextcloudAuthenticationRestoration(sceneID: "first", namespace: namespace).load() == nil)
        #expect(!session.description.contains("fixture-secret"))
    }
}

@MainActor private final class NextcloudViewBrowser { var urls: [URL] = [] }
private actor NextcloudViewTransport: SynchronizationHTTPTransport {
    private(set) var starts = 0
    private var failures: Int
    private let holdsPoll: Bool
    private var suspended: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { suspended != nil }
    init(startFailures: Int = 0, holdsPoll: Bool = true) { failures = startFailures; self.holdsPoll = holdsPoll }
    func send(_ request: URLRequest) async throws -> SynchronizationHTTPResponse {
        if request.url?.path.hasSuffix("/login/v2") == true {
            starts += 1
            if failures > 0 { failures -= 1; return .init(status: 503, body: Data()) }
            return .init(status: 200, body: Data(#"{"login":"https://cloud.example.test/browser","poll":{"token":"opaque","endpoint":"https://cloud.example.test/poll"}}"#.utf8))
        }
        if holdsPoll { await withCheckedContinuation { suspended = $0 } }
        return .init(status: 200, body: Data(#"{"server":"https://returned.example.test/subfolder","loginName":"alice","appPassword":"fixture-secret"}"#.utf8))
    }
    func release() { suspended?.resume(); suspended = nil }
}
private final class NextcloudViewCredentials: SynchronizationCredentialStore, Sendable {
    private let storage = Mutex<[UUID: String]>([:])
    func insert(_ password: String, id: UUID) throws { storage.withLock { $0[id] = password } }
    func password(id: UUID) throws -> String {
        try storage.withLock { guard let value = $0[id] else { throw SynchronizationCredentialError.missing }; return value }
    }
    func remove(id: UUID) throws { storage.withLock { $0[id] = nil } }
}
