import UIKit
import Security
import Synchronization
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ProxySettingsViewTests {
    private func find<T: UIView>(_ id: String, _ view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let value = view as? T { return value }
        return view.subviews.lazy.compactMap { find(id, $0) as T? }.first
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
    @Test func realKeychainRoundtripAndResetRetainSelectedTypeWithoutPassword() throws {
        let account = "ProxyViewTest-\(UUID())"
        defer { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: "org.nottennapod.app.proxy", kSecAttrAccount: account, kSecUseDataProtectionKeychain: true] as CFDictionary) }
        let persistence = KeychainProxyPreferences(account: account)
        let store = try ProxyPreferenceStore(persistence: persistence)
        let config = PodcastProxy(kind: .http, host: "localhost", port: 1234, username: "fixture", password: "fixture-secret")
        try store.update(config, reinitializeShared: true)
        #expect(try ProxyPreferenceStore(persistence: persistence).value == config)
        let session = ProxySettingsSession(preferences: store, test: { _ in })
        try session.reset(); session.cancel()
        #expect(try ProxyPreferenceStore(persistence: persistence).value == PodcastProxy(kind: .http))
    }
    @Test func visibleActionsRequireTestThenSaveAndResetSurvivesCancel() async throws {
        let preferences = try ProxyPreferenceStore(persistence: Memory())
        try await withViewTestWindow { host, _ in
            let dialog = ProxySettingsController(preferences: preferences, test: { _ in })
            host.present(dialog, animated: false)
            try await wait { dialog.viewIfLoaded?.window != nil && !dialog.isBeingPresented }
            defer { host.dismiss(animated: false) }
            @MainActor func button(_ id: String) throws -> UIButton { try #require(find(id, dialog.view)) }
            #expect(try button("proxyConfirm").title(for: .normal) == "OK")
            #expect(!dialog.body.host.isEnabled && !dialog.body.password.isEnabled)
            try button("proxyType").sendActions(for: .touchUpInside)
            try await wait { dialog.presentedViewController != nil && dialog.presentedViewController?.isBeingPresented == false }
            let choice: UIButton = try #require(find("proxyType-HTTP", dialog.presentedViewController!.view))
            choice.sendActions(for: .touchUpInside)
            try await wait { dialog.presentedViewController == nil }
            #expect(dialog.body.host.isEnabled && dialog.body.password.isSecureTextEntry)
            dialog.body.host.text = "localhost"; dialog.body.host.sendActions(for: .editingChanged)
            dialog.body.port.text = "8080"; dialog.body.port.sendActions(for: .editingChanged)
            #expect(try button("proxyConfirm").title(for: .normal) == "Test")
            try button("proxyConfirm").sendActions(for: .touchUpInside)
            try await wait { dialog.session.testSuccessful }
            #expect(preferences.value.kind == .direct && dialog.body.info.text == "Test successful")
            try button("proxyConfirm").sendActions(for: .touchUpInside)
            try await wait { host.presentedViewController == nil }
            #expect(preferences.value.kind == .http && preferences.value.host == "localhost")
            let reopened = ProxySettingsController(preferences: preferences)
            host.present(reopened, animated: false)
            try await wait { !reopened.isBeingPresented }
            let reset: UIButton = try #require(find("proxyReset", reopened.view)); reset.sendActions(for: .touchUpInside)
            #expect(preferences.value == PodcastProxy(kind: .http))
            let cancel: UIButton = try #require(find("proxyCancel", reopened.view)); cancel.sendActions(for: .touchUpInside)
            try await wait { host.presentedViewController == nil }
            #expect(preferences.value == PodcastProxy(kind: .http))
        }
    }
    @Test func resizingRetainsDraftAndControlsStayOrderedInsideAsymmetricSafeAreas() async throws {
        let preferences = try ProxyPreferenceStore(persistence: Memory())
        try await withViewTestWindow { host, _ in
            let dialog = ProxySettingsController(preferences: preferences, test: { _ in })
            host.addChild(dialog); host.view.addSubview(dialog.view); dialog.didMove(toParent: host)
            defer { dialog.willMove(toParent: nil); dialog.view.removeFromSuperview(); dialog.removeFromParent() }
            dialog.session.selectType(.socks)
            dialog.body.host.text = "localhost"; dialog.body.host.sendActions(for: .editingChanged)
            dialog.body.password.text = "retained"; dialog.body.password.sendActions(for: .editingChanged)
            for size in [CGSize(width: 390, height: 700), CGSize(width: 720, height: 360), CGSize(width: 320, height: 500)] {
                for rtl in [false, true] {
                    dialog.view.frame = CGRect(origin: .zero, size: size)
                    dialog.additionalSafeAreaInsets = UIEdgeInsets(top: 11, left: 27, bottom: 19, right: 7)
                    dialog.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                    dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded(); dialog.body.layoutIfNeeded()
                    #expect(dialog.session.draft.password == "retained" && dialog.session.draft.host == "localhost")
                    let controls: [UIView] = [dialog.body.type, dialog.body.host, dialog.body.port, dialog.body.username, dialog.body.password]
                    let rects = controls.map { $0.convert($0.bounds, to: dialog.body) }
                    #expect(zip(rects, rects.dropFirst()).allSatisfy { $0.maxY <= $1.minY })
                    #expect(rects.allSatisfy { $0.minX >= 0 && $0.maxX <= dialog.body.bounds.width })
                    let action: UIButton = try #require(find("proxyConfirm", dialog.view))
                    #expect(action.isEnabled && action.title(for: .normal) == "Test")
                }
            }
        }
    }
    @Test func fieldValidationShowsAndClearsVisibleError() async throws {
        try await withViewTestWindow { host, _ in
            let dialog = ProxySettingsController(preferences: try ProxyPreferenceStore(persistence: Memory()), test: { _ in })
            host.present(dialog, animated: false)
            try await wait { !dialog.isBeingPresented && dialog.view.window != nil }
            dialog.session.selectType(.http)
            dialog.body.host.becomeFirstResponder()
            await dialog.session.verify().value
            dialog.view.layoutIfNeeded(); dialog.body.layoutIfNeeded()
            let error: UILabel = try #require(find("proxyFieldErrorMessage", dialog.view))
            #expect(error.text == "Host can not be empty" && !error.superview!.isHidden)
            #expect(dialog.body.info.isHidden)
            let icon: UIButton = try #require(find("proxyHostError", dialog.view))
            let image = UIGraphicsImageRenderer(size: icon.bounds.size).image { icon.layer.render(in: $0.cgContext) }
            let cg = try #require(image.cgImage)
            let data = try #require(cg.dataProvider?.data)
            let bytes = CFDataGetBytePtr(data)!
            let x = Int(CGFloat(cg.width) / 2), y = Int(CGFloat(cg.height) / 2 - 3 * image.scale)
            let offset = y * cg.bytesPerRow + x * 4
            #expect(bytes[offset] > 240 && bytes[offset + 1] > 240 && bytes[offset + 2] > 240,
                    "Field error exclamation must remain visible, not a solid tinted disk")
            dialog.body.host.text = "localhost"; dialog.body.host.sendActions(for: .editingChanged)
            dialog.body.layoutIfNeeded()
            #expect(error.superview!.isHidden)
            host.dismiss(animated: false)
            try await wait { host.presentedViewController == nil }
        }
    }
    @Test func fieldErrorRemainsVisibleWhenKeyboardViewportEndsAtFocusedField() async throws {
        try await withViewTestWindow { host, _ in
            let scroll = UIScrollView(frame: CGRect(x: 20, y: 80, width: 300, height: 120))
            scroll.contentInsetAdjustmentBehavior = .never; host.view.addSubview(scroll)
            let body = ProxySettingsBody(draft: .init(.init(kind: .http)))
            scroll.addSubview(body)
            defer { body.endEditing(true); scroll.removeFromSuperview() }
            for rtl in [false, true] {
                body.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                body.frame = CGRect(origin: .zero, size: body.sizeThatFits(CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)))
                scroll.contentSize = body.bounds.size
                body.host.becomeFirstResponder()
                body.update(draft: .init(.init(kind: .http)), errors: [.host: "proxy_host_empty_error"], status: .none)
                body.layoutIfNeeded()
                let field = body.host.convert(body.host.bounds, to: body)
                scroll.contentOffset.y = field.maxY - 110
                body.setNeedsLayout(); body.layoutIfNeeded()
                let label: UILabel = try #require(find("proxyFieldErrorMessage", body))
                let bubble = try #require(label.superview)
                let visible = bubble.convert(bubble.bounds, to: scroll)
                #expect(!bubble.isHidden && visible.minY >= scroll.bounds.minY && visible.maxY <= scroll.bounds.maxY)
                #expect(visible.width > 0 && visible.height > 20)
            }
        }
    }
    private final class Memory: ProxyPreferencePersistence {
        private let value = Mutex<PodcastProxy?>(nil)
        func load() -> PodcastProxy? { value.withLock { $0 } }
        func save(_ configuration: PodcastProxy) { value.withLock { $0 = configuration } }
    }
}
