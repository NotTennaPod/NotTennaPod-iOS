import UIKit
import Synchronization
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Mounted component evidence. The transport is controlled; these checks do
/// not establish provider interoperability, physical input or application routing.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct SynchronizationSettingsViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let value = view as? T, value.accessibilityIdentifier == id { return value }
        return view.subviews.lazy.compactMap { find(id, in: $0, as: T.self) }.first
    }

    private func wait(_ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try await !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(try await condition(), "The component must reach its observable completion state")
    }

    private func fixture(_ transport: SettingsAuthenticationTransport = .init(),
                         _ body: @MainActor (FeedLibraryStore, SettingsAuthenticationCredentials,
                                            SynchronizationAccounts, GpodderAuthenticationFlow) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SynchronizationSettings-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try FeedLibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        let vault = SettingsAuthenticationCredentials()
        let accounts = SynchronizationAccounts(store: store, credentials: vault, makeTransport: { transport })
        let flow = GpodderAuthenticationFlow(accounts: accounts, deviceModel: "Fixture phone")
        do {
            try await body(store, vault, accounts, flow)
            flow.cancel(); await transport.resume()
            try await store.close()
        } catch {
            flow.cancel(); await transport.resume()
            try? await store.close(); throw error
        }
    }

    private func tap(_ id: String, in view: UIView) throws {
        let button: UIButton = try #require(find(id, in: view))
        try #require(button.isEnabled)
        button.sendActions(for: .touchUpInside)
    }

    private func enterHost(_ host: String, dialog: GpodderAuthenticationController,
                           flow: GpodderAuthenticationFlow) async throws {
        let field: UITextField = try #require(find("gpodderHost", in: dialog.view))
        field.text = host
        try tap("gpodderProceed", in: dialog.view)
        try await wait { flow.stage == .credentials && !flow.busy }
        dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
        let title: UILabel = try #require(find("sourceMessageTitle", in: dialog.view))
        #expect(title.accessibilityLabel == host)
    }

    private func enterCredentials(dialog: GpodderAuthenticationController) throws {
        let username: UITextField = try #require(find("gpodderUsername", in: dialog.view))
        let password: UITextField = try #require(find("gpodderPassword", in: dialog.view))
        username.text = "alice"; password.text = "fixture-secret"
        #expect(password.isSecureTextEntry)
        try tap("gpodderLogin", in: dialog.view)
    }

    @Test(arguments: ["disconnected", "gpodder", "nextcloud"])
    func settingsRowsPreserveSourceOrderAvailabilityAndActions(provider: String) async throws {
        try await fixture { store, _, accounts, _ in
            if provider != "disconnected" {
                try await accounts.connect(.init(backend: provider == "gpodder" ? .gpodder : .nextcloud,
                    host: "https://sync.example.test", username: "alice", device: "phone"), password: "fixture", fullSync: false)
            }
            let state = try await store.synchronizationState()
            try await withViewTestWindow { host, _ in
                let settings = SynchronizationSettingsView(state: state, width: 320)
                settings.traitOverrides.preferredContentSizeCategory = .large
                host.view.addSubview(settings)
                defer { settings.removeFromSuperview() }
                var actions: [String] = []
                settings.onAction = { action in
                    switch action {
                    case .choose: actions.append("choose")
                    case .password: actions.append("password")
                    case .synchronize: actions.append("sync")
                    case .full: actions.append("full")
                    case .logout: actions.append("logout")
                    case .serverPassword, .startOver, .log, .attention, .keptLibraries, .previousLibrary, .stopPlayback: actions.append("server")
                    }
                }
                let expected = ["preference_synchronization_description"]
                    + (provider == "gpodder" ? ["pref_gpodnet_setlogin_information"] : [])
                    + ["pref_synchronization_sync", "pref_synchronization_force_full_sync", "pref_synchronization_logout"]
                for width: CGFloat in [320, 720] {
                    settings.frame.size = settings.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
                    settings.setNeedsLayout(); settings.layoutIfNeeded()
                    let rows = settings.subviews.compactMap { $0 as? UIControl }.sorted { $0.frame.minY < $1.frame.minY }
                    #expect(rows.compactMap(\.accessibilityIdentifier) == expected)
                    for (index, row) in rows.enumerated() {
                        #expect(settings.bounds.contains(row.frame) && row.frame.height >= 64)
                        if index > 0 { #expect(rows[index - 1].frame.maxY <= row.frame.minY + 0.5) }
                        #expect(row.isEnabled == (index == 0 || provider != "disconnected"))
                        #expect(row.alpha == 1)
                        let inset: CGFloat = width >= 600 ? 24 : 16
                        let labels = row.subviews.compactMap { $0 as? UILabel }
                        if let icon = row.subviews.compactMap({ $0 as? UIImageView }).first {
                            // Preference-row icon and text columns as on Android (within a point).
                            #expect(abs(icon.frame.minX - inset) <= 1 && abs(icon.frame.width - 48) <= 1 && abs(icon.frame.height - 48) <= 1)
                            #expect(labels.allSatisfy { abs($0.frame.minX - (width >= 600 ? 96 : 72)) <= 1 })
                        } else { #expect(labels.allSatisfy { abs($0.frame.minX - inset) <= 1 }) }
                    }
                }
                let header: UIControl = try #require(find(expected[0], in: settings))
                header.sendActions(for: .touchUpInside)
                if provider == "disconnected" {
                    #expect(header.accessibilityLabel == Appearance.text("synchronization_choose_title"))
                    #expect(header.accessibilityValue == Appearance.text("synchronization_summary_unchoosen"))
                    #expect(actions == ["choose"])
                    let logout: UIControl = try #require(find("pref_synchronization_logout", in: settings))
                    #expect(logout.accessibilityValue == nil)
                } else {
                    #expect(header.accessibilityTraits.contains(.staticText) && actions.isEmpty)
                    #expect(header.accessibilityValue == Appearance.text(provider == "gpodder" ? "gpodnet_description" : "synchronization_summary_nextcloud"))
                    for id in expected.dropFirst() {
                        let row: UIControl = try #require(find(id, in: settings))
                        row.sendActions(for: .touchUpInside)
                    }
                    #expect(actions == (provider == "gpodder" ? ["password", "sync", "full", "logout"] : ["sync", "full", "logout"]))
                    let logout: UIControl = try #require(find("pref_synchronization_logout", in: settings))
                    #expect(logout.accessibilityValue?.contains("alice") == true)
                    #expect(logout.accessibilityValue?.contains("https://sync.example.test") == true)
                    #expect(logout.accessibilityValue == "Logged in as alice on https://sync.example.test. You can choose your synchronization provider again once you have logged out.")
                }
            }
        }
    }

    @Test func providerChoicesKeepGpodderBeforeNextcloudAndDispatchSelection() async throws {
        try await withViewTestWindow { host, _ in
            let choices = SynchronizationProviderChoices(frame: .zero)
            host.view.addSubview(choices)
            defer { choices.removeFromSuperview() }
            choices.frame.size = choices.sizeThatFits(CGSize(width: 320, height: 600))
            choices.layoutIfNeeded()
            let first: UIControl = try #require(find("syncProvider-gpodder", in: choices))
            let second: UIControl = try #require(find("syncProvider-nextcloud", in: choices))
            #expect(first.frame.maxY <= second.frame.minY + 0.5)
            #expect(first.accessibilityLabel == Appearance.text("gpodnet_description"))
            #expect(second.accessibilityLabel == Appearance.text("synchronization_summary_nextcloud"))
            var selected: [SynchronizationHTTPClient.Backend] = []
            choices.onSelect = { selected.append($0) }
            first.sendActions(for: .touchUpInside); second.sendActions(for: .touchUpInside)
            #expect(selected == [.gpodder, .nextcloud])
        }
    }

    @Test(arguments: [false, true], [false, true])
    func buttonDrivenDeviceSelectionCommitsBeforeExplicitFinishAction(create: Bool, synchronize: Bool) async throws {
        let transport = SettingsAuthenticationTransport()
        try await fixture(transport) { store, vault, _, flow in
            try await withViewTestWindow { host, _ in
                var syncCalls = 0, cancelCalls = 0, syncPresenterWasClear = false
                let dialog = GpodderAuthenticationController(flow: flow, onSync: {
                    syncCalls += 1; syncPresenterWasClear = host.presentedViewController == nil
                }, onCancel: { cancelCalls += 1 })
                host.present(dialog, animated: false)
                try await wait { dialog.view.window != nil && !dialog.isBeingPresented }
                let initialTitle: UILabel = try #require(find("sourceMessageTitle", in: dialog.view))
                #expect(initialTitle.accessibilityLabel == Appearance.text("gpodnetauth_login_butLabel"))
                try await enterHost("https://sync.example.test/base", dialog: dialog, flow: flow)
                let reset = try await store.synchronizationState()
                #expect(reset.account == nil && reset.lastHost == "https://sync.example.test/base")
                try enterCredentials(dialog: dialog)
                try await wait { flow.stage == .devices && !flow.busy }
                dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                let heading: UILabel = try #require(find("gpodnetauth_existing_devices", in: dialog.view))
                #expect(heading.font.fontName == "Roboto-Light")
                #expect(heading.font.pointSize == Appearance.font(22, compatibleWith: heading.traitCollection).pointSize)
                let explanation: UILabel = try #require(find("synchronization_selectDevice_explanation", in: dialog.view))
                #expect(explanation.textColor.resolvedColor(with: explanation.traitCollection) == Appearance.secondary.resolvedColor(with: explanation.traitCollection))
                #expect(try await store.synchronizationState() == reset && vault.values.isEmpty)
                let name: UITextField = try #require(find("gpodderDeviceName", in: dialog.view))
                #expect(name.text == "NotTennaPod on Fixture phone (1)")
                if create {
                    name.text = "My new phone"
                    try tap("gpodderCreateDevice", in: dialog.view)
                } else { try tap("gpodderDevice-existing", in: dialog.view) }
                try await wait { flow.stage == .finish && !flow.busy }
                let selected = try await store.synchronizationState()
                let account = try #require(selected.account)
                #expect(account.device == (create ? "my_new_phone" : "existing"))
                #expect(account.username == "alice" && vault.values == [account.credentialID: "fixture-secret"])
                #expect(selected.request == nil && syncCalls == 0 && cancelCalls == 0)
                #expect(!dialog.accessibilityPerformEscape() && host.presentedViewController === dialog)
                try tap(synchronize ? "gpodderSyncNow" : "gpodderCancel", in: dialog.view)
                try await wait {
                    host.presentedViewController == nil && syncCalls == (synchronize ? 1 : 0)
                        && cancelCalls == (synchronize ? 0 : 1)
                }
                #expect(syncCalls == (synchronize ? 1 : 0) && cancelCalls == (synchronize ? 0 : 1))
                if synchronize { #expect(syncPresenterWasClear) }
                #expect(try await store.synchronizationState() == selected)
                let requests = await transport.requests
                #expect(requests.map { $0.url!.path } == ["/base/api/2/auth/alice/login.json", "/base/api/2/devices/alice.json"]
                    + (create ? ["/base/api/2/devices/alice/my_new_phone.json"] : []))
                if create {
                    let body = try #require(requests.last?.httpBody)
                    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
                    #expect(json == ["caption": "My new phone", "type": "mobile"])
                }
            }
        }
    }

    @Test func nonemptyInvalidHostCommitsResetBeforeLoginReportsFailure() async throws {
        let transport = SettingsAuthenticationTransport()
        try await fixture(transport) { store, vault, accounts, flow in
            let previous = SynchronizationAccount(backend: .nextcloud, host: "https://previous.example.test", username: "previous")
            try await accounts.connect(previous, password: "old-secret", fullSync: false)
            let before = try await store.synchronizationState()
            try await withViewTestWindow { host, _ in
                let dialog = GpodderAuthenticationController(flow: flow, onSync: {})
                host.present(dialog, animated: false)
                try await wait { dialog.view.window != nil && !dialog.isBeingPresented }
                try await enterHost("https://", dialog: dialog, flow: flow)
                let reset = try await store.synchronizationState()
                #expect(reset.epoch != before.epoch && reset.account == nil && reset.lastHost == "https://")
                #expect(vault.values.isEmpty)
                try enterCredentials(dialog: dialog)
                try await wait { flow.error != nil && !flow.busy }
                #expect(flow.stage == .credentials)
                let error: UILabel = try #require(find("gpodderAuthenticationError", in: dialog.view))
                let login: UIButton = try #require(find("gpodderLogin", in: dialog.view))
                // Source exposes the connection failure; native URL parsing supplies its own localized error.
                #expect(error.text == URLError(.badURL).localizedDescription && !error.isHidden && login.isEnabled)
                #expect(await transport.requests.isEmpty)
                try tap("gpodderCancel", in: dialog.view)
                try await wait { host.presentedViewController == nil }
                #expect(try await store.synchronizationState() == reset)
            }
        }
    }

    @Test func failedLoginShowsSourceErrorAndRetriesWithRetainedCredentials() async throws {
        let transport = SettingsAuthenticationTransport(statuses: [0: 401])
        try await fixture(transport) { store, vault, _, flow in
            try await withViewTestWindow { host, _ in
                let dialog = GpodderAuthenticationController(flow: flow, onSync: {})
                host.present(dialog, animated: false)
                try await wait { dialog.view.window != nil && !dialog.isBeingPresented }
                try await enterHost("http://sync.example.test", dialog: dialog, flow: flow)
                let warning: UILabel = try #require(find("gpodderEncryptionWarning", in: dialog.view))
                #expect(warning.alpha == 1 && !warning.accessibilityElementsHidden)
                try enterCredentials(dialog: dialog)
                try await wait { flow.error != nil && !flow.busy }
                let error: UILabel = try #require(find("gpodderAuthenticationError", in: dialog.view))
                let username: UITextField = try #require(find("gpodderUsername", in: dialog.view))
                let password: UITextField = try #require(find("gpodderPassword", in: dialog.view))
                let login: UIButton = try #require(find("gpodderLogin", in: dialog.view))
                #expect(error.text == "Wrong username or password" && !error.isHidden)
                #expect(error.numberOfLines == 2 && error.textAlignment == .center && error.lineBreakMode == .byTruncatingTail)
                #expect(username.text == "alice" && password.text == "fixture-secret" && password.isSecureTextEntry)
                #expect(login.isEnabled && flow.stage == .credentials)
                #expect(try await store.synchronizationState().account == nil && vault.values.isEmpty)
                try tap("gpodderLogin", in: dialog.view)
                try await wait { flow.stage == .devices && !flow.busy }
                #expect(flow.error == nil && password.text?.isEmpty != false)
                #expect(await transport.requests.count == 3)
                try tap("gpodderCancel", in: dialog.view)
                try await wait { host.presentedViewController == nil }
                #expect(try await store.synchronizationState().account == nil)
            }
        }
    }

    @Test func cancelDuringDelayedLoginCannotInstallAnAccountOrAdvanceTheDialog() async throws {
        let transport = SettingsAuthenticationTransport(suspendAt: 0)
        try await fixture(transport) { store, vault, accounts, flow in
            try await withViewTestWindow { host, _ in
                var cancelled = 0, synchronized = 0
                let dialog = GpodderAuthenticationController(flow: flow, onSync: { synchronized += 1 }, onCancel: { cancelled += 1 })
                host.present(dialog, animated: false)
                try await wait { dialog.view.window != nil && !dialog.isBeingPresented }
                try await enterHost("https://sync.example.test", dialog: dialog, flow: flow)
                try enterCredentials(dialog: dialog)
                try await wait { await transport.isSuspended }
                let login: UIButton = try #require(find("gpodderLogin", in: dialog.view))
                let cancel: UIButton = try #require(find("gpodderCancel", in: dialog.view))
                #expect(flow.busy && !login.isEnabled && cancel.isEnabled)
                #expect(!dialog.accessibilityPerformEscape() && host.presentedViewController === dialog)
                try tap("gpodderCancel", in: dialog.view)
                try await wait { host.presentedViewController == nil }
                let replacement = SynchronizationAccount(backend: .nextcloud, host: "https://replacement.example.test", username: "replacement")
                try await accounts.connect(replacement, password: "replacement-secret", fullSync: false)
                let saved = try await store.synchronizationState()
                await transport.resume()
                try await wait { await transport.completed == 1 }
                #expect(cancelled == 1 && synchronized == 0 && flow.stage == .credentials)
                #expect(try await store.synchronizationState() == saved)
                #expect(vault.values == [replacement.credentialID: "replacement-secret"])
                #expect(await transport.requests.count == 1)
            }
        }
    }

    @Test func focusedInputAndSelectionSurviveNarrowAsymmetricResizing() async throws {
        try await fixture { _, _, _, flow in
            try await withViewTestWindow { host, _ in
                let dialog = GpodderAuthenticationController(flow: flow, onSync: {})
                host.addChild(dialog); host.view.addSubview(dialog.view); dialog.didMove(toParent: host)
                defer { dialog.willMove(toParent: nil); dialog.view.removeFromSuperview(); dialog.removeFromParent() }
                dialog.view.traitOverrides.preferredContentSizeCategory = .large
                dialog.view.frame = CGRect(x: 0, y: 0, width: 430, height: 720)
                try await enterHost("https://sync.example.test", dialog: dialog, flow: flow)
                let username: UITextField = try #require(find("gpodderUsername", in: dialog.view))
                let password: UITextField = try #require(find("gpodderPassword", in: dialog.view))
                username.text = "retained-user"; password.text = "retained-secret"
                try #require(username.becomeFirstResponder())
                let start = try #require(username.position(from: username.beginningOfDocument, offset: 2))
                let end = try #require(username.position(from: username.beginningOfDocument, offset: 7))
                username.selectedTextRange = username.textRange(from: start, to: end)
                for (width, left, right): (CGFloat, CGFloat, CGFloat) in [(320, 31, 7), (720, 7, 31), (320, 7, 31)] {
                    dialog.view.frame.size = CGSize(width: width, height: 720)
                    dialog.additionalSafeAreaInsets = .init(top: 0, left: left, bottom: 0, right: right)
                    dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                    #expect(find("gpodderUsername", in: dialog.view, as: UITextField.self) === username)
                    #expect(username.isFirstResponder && username.text == "retained-user" && password.text == "retained-secret")
                    let range = try #require(username.selectedTextRange)
                    #expect(username.offset(from: username.beginningOfDocument, to: range.start) == 2)
                    #expect(username.offset(from: username.beginningOfDocument, to: range.end) == 7)
                    let outer: UIScrollView = try #require(find("sourceMessageContent", in: dialog.view))
                    let body: UIScrollView = try #require(find("sourceMessageBody", in: dialog.view))
                    let safe = dialog.view.safeAreaLayoutGuide.layoutFrame
                    let panel = outer.convert(outer.bounds, to: dialog.view)
                    #expect(panel.minX >= safe.minX && panel.maxX <= safe.maxX)
                    for scroll in [outer, body] {
                        let field = username.convert(username.bounds, to: scroll)
                        #expect(scroll.bounds.insetBy(dx: -0.5, dy: -0.5).contains(field))
                    }
                    let cancel: UIButton = try #require(find("gpodderCancel", in: dialog.view))
                    let actions: UIScrollView = try #require(find("sourceMessageActions", in: dialog.view))
                    #expect(cancel.isEnabled && actions.bounds.insetBy(dx: -0.5, dy: -0.5).contains(cancel.frame))
                    #expect(outer.bounds.insetBy(dx: -0.5, dy: -0.5).contains(actions.convert(actions.bounds, to: outer)))
                }
                username.resignFirstResponder()
            }
        }
    }

    @Test func changedDialogTitleResetsFallbackAndExplicitOnlyCancellationStillWorks() async throws {
        try await withViewTestWindow { host, _ in
            var explicit = 0, implicit = 0
            let dialog = SourceMessageController(title: String(repeating: "Long host ", count: 12), message: "Fixture",
                positive: .init(title: "Cancel", identifier: "explicitCancel", perform: { explicit += 1 }))
            dialog.allowsImplicitCancellation = false
            dialog.onCancel = { implicit += 1 }
            dialog.view.traitOverrides.preferredContentSizeCategory = .large
            host.present(dialog, animated: false)
            try await wait { dialog.view.window != nil && !dialog.isBeingPresented }
            dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
            let title: UILabel = try #require(find("sourceMessageTitle", in: dialog.view))
            #expect(title.numberOfLines == 2 && title.font.pointSize == 18)
            dialog.updateTitle("Short host")
            dialog.view.layoutIfNeeded()
            #expect(title.text == "Short host" && title.accessibilityLabel == "Short host")
            #expect(title.numberOfLines == 1 && title.font.pointSize == 24)
            #expect(!dialog.accessibilityPerformEscape())
            #expect(implicit == 0 && host.presentedViewController === dialog)
            try tap("explicitCancel", in: dialog.view)
            try await wait { host.presentedViewController == nil }
            #expect(explicit == 1 && implicit == 0)
        }
    }
}

private actor SettingsAuthenticationTransport: SynchronizationHTTPTransport {
    private(set) var requests: [URLRequest] = []
    private(set) var completed = 0
    private let statuses: [Int: Int]
    private let suspendAt: Int?
    private var suspended: CheckedContinuation<Void, Never>?
    var isSuspended: Bool { suspended != nil }
    init(statuses: [Int: Int] = [:], suspendAt: Int? = nil) { self.statuses = statuses; self.suspendAt = suspendAt }
    func send(_ request: URLRequest) async throws -> SynchronizationHTTPResponse {
        let index = requests.count
        requests.append(request)
        defer { completed += 1 }
        if index == suspendAt { await withCheckedContinuation { suspended = $0 } }
        if let status = statuses[index] { return .init(status: status, body: Data()) }
        let body = request.httpMethod == "GET"
            ? #"[{"id":"existing","caption":"NotTennaPod on Fixture phone","type":"mobile","subscriptions":3}]"# : ""
        return .init(status: 200, body: Data(body.utf8))
    }
    func resume() { suspended?.resume(); suspended = nil }
}

private final class SettingsAuthenticationCredentials: SynchronizationCredentialStore, Sendable {
    private let storage = Mutex<[UUID: String]>([:])
    var values: [UUID: String] { storage.withLock { $0 } }
    func insert(_ password: String, id: UUID) throws { storage.withLock { $0[id] = password } }
    func password(id: UUID) throws -> String {
        try storage.withLock { guard let value = $0[id] else { throw SynchronizationCredentialError.missing }; return value }
    }
    func remove(id: UUID) throws { storage.withLock { $0[id] = nil } }
}
