import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite @MainActor
struct GpodderAuthenticationFlowTests {
    private func fixture(_ transport: AuthenticationTestTransport = .init(),
                         _ body: @MainActor (FeedLibraryStore, AuthenticationTestCredentials, SynchronizationAccounts, GpodderAuthenticationFlow) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GpodderAuthentication-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try FeedLibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        let vault = AuthenticationTestCredentials()
        let accounts = SynchronizationAccounts(store: store, credentials: vault, makeTransport: { transport })
        let flow = GpodderAuthenticationFlow(accounts: accounts, deviceModel: "iPhone")
        do { try await body(store, vault, accounts, flow); try await store.close() }
        catch { try? await store.close(); throw error }
    }

    private func replacement() -> SynchronizationAccount {
        .init(backend: .nextcloud, host: "https://replacement.example.test", username: "replacement")
    }

    @Test func cancellationBeforeHostConfirmationChangesNothing() async throws {
        let transport = AuthenticationTestTransport()
        try await fixture(transport) { store, vault, accounts, flow in
            let account = replacement()
            try await accounts.connect(account, password: "original", fullSync: true)
            let before = try await store.synchronizationState()
            #expect(flow.host.isEmpty && flow.stage == .host)
            flow.cancel()
            await flow.proceed(host: "sync.example.test")
            #expect(try await store.synchronizationState() == before)
            #expect(vault.values == [account.credentialID: "original"])
            #expect(await transport.requests.isEmpty)
        }
    }

    @Test func hostResetAndDeviceSelectionHaveSeparateDurableBoundaries() async throws {
        let transport = AuthenticationTestTransport()
        try await fixture(transport) { store, vault, accounts, flow in
            let original = replacement()
            try await accounts.connect(original, password: "original", fullSync: false)
            try await store.setSynchronizationMobileAllowed(true)
            let request = try #require(await store.requestSynchronization(immediately: true))
            let running = try await store.beginSynchronization(request)
            try await store.acknowledgeSynchronization(epoch: running.epoch, phase: .episodes, ids: [], timestamp: 42)
            try await store.finishSynchronization(request, epoch: running.epoch, successful: true)
            _ = try await store.insert(.init(feed: .init(format: .rss, title: "Queued", episodes: []),
                source: "https://feed.example.test/rss", responseURL: URL(string: "https://feed.example.test/rss")!, validator: nil, permanentRedirectURL: nil))
            #expect(try await store.synchronizationQueue().count == 1)
            await flow.proceed(host: "sync.example.test/base")
            let reset = try await store.synchronizationState()
            #expect(flow.stage == .credentials && flow.host == "sync.example.test/base")
            #expect(reset.account == nil && reset.accountID == nil && reset.epoch != running.epoch)
            #expect(reset.lastHost == "sync.example.test/base" && reset.allowMobile && reset.lastAttemptSuccessful)
            #expect(reset.subscriptionTimestamp == 0 && reset.episodeTimestamp == 0 && reset.lastAttempt == nil && reset.request == nil)
            #expect(try await store.synchronizationQueue().isEmpty)
            #expect(vault.values.isEmpty)

            await flow.login(username: "alice", password: "draft-secret")
            #expect(flow.stage == .devices && !flow.busy && flow.error == nil)
            #expect(flow.suggestedDeviceName == "NotTennaPod on iPhone (2)")
            #expect(try await store.synchronizationState() == reset && vault.values.isEmpty)
            let device = try #require(flow.devices.first)
            await flow.choose(device: device)
            let selected = try await store.synchronizationState()
            let account = try #require(selected.account)
            #expect(flow.stage == .finish && flow.selectedDevice == device)
            #expect(flow.connectedEpoch == selected.epoch)
            #expect(account.backend == .gpodder && account.username == "alice" && account.host == "sync.example.test/base" && account.device == "existing")
            #expect(vault.values == [account.credentialID: "draft-secret"])
            #expect(selected.request == nil && selected.allowMobile && selected.lastAttemptSuccessful)
            flow.cancel()
            #expect(try await store.synchronizationState() == selected)
            let requests = await transport.requests
            #expect(requests.map { $0.url!.path } == ["/base/api/2/auth/alice/login.json", "/base/api/2/devices/alice.json"])
            #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Basic " + Data("alice:draft-secret".utf8).base64EncodedString())
        }
    }

    @Test func invalidHostAndFailedLoginStayRetryableWithoutSecretDisclosure() async throws {
        let transport = AuthenticationTestTransport(failures: [0: .status(401), 2: .offline, 3: .secretError])
        try await fixture(transport) { store, vault, _, flow in
            let before = try await store.synchronizationState()
            await flow.proceed(host: "")
            #expect(flow.stage == .host && flow.error == nil)
            #expect(try await store.synchronizationState() == before)
            await flow.proceed(host: "sync.example.test")
            let reset = try await store.synchronizationState()
            await flow.login(username: "email@example.test", password: "draft-secret")
            #expect(flow.error == "Usernames may only contain letters, digits, hyphens and underscores.")
            #expect(await transport.requests.isEmpty)
            // 401, then successful login plus failed device enumeration, then an
            // arbitrary transport error containing a secret must all stay draft.
            for _ in 0..<3 {
                await flow.login(username: "alice", password: "draft-secret")
                #expect(flow.stage == .credentials && !flow.busy && flow.error != nil)
                #expect(flow.error?.contains("draft-secret") == false)
                #expect(vault.values.isEmpty && flow.devices.isEmpty)
                #expect(try await store.synchronizationState() == reset)
            }
            await flow.login(username: "alice", password: "draft-secret")
            #expect(flow.stage == .devices && flow.error == nil)
            flow.cancel()
            #expect(try await store.synchronizationState() == reset)
        }
    }

    @Test func nonemptyInvalidHostCommitsResetThenFailsAtLogin() async throws {
        let transport = AuthenticationTestTransport()
        try await fixture(transport) { store, vault, accounts, flow in
            try await accounts.connect(replacement(), password: "old-secret", fullSync: true)
            await flow.proceed(host: "http://example.test:999999999999999999999999")
            let reset = try await store.synchronizationState()
            #expect(flow.stage == .credentials && flow.error == nil)
            #expect(reset.lastHost == "http://example.test:999999999999999999999999")
            #expect(reset.account == nil && reset.request == nil && vault.values.isEmpty)
            await flow.login(username: "alice", password: "draft-secret")
            #expect(flow.stage == .credentials && flow.error == URLError(.badURL).localizedDescription)
            #expect(try await store.synchronizationState() == reset)
            #expect(await transport.requests.isEmpty)
            flow.cancel()
            #expect(try await store.synchronizationState() == reset)
        }
    }

    @Test func registrationChecksCaptionAndNormalizedIDAndRetriesFailure() async throws {
        let transport = AuthenticationTestTransport(failures: [2: .status(503)])
        try await fixture(transport) { store, vault, _, flow in
            await flow.proceed(host: "sync.example.test")
            await flow.login(username: "alice", password: "draft-secret")
            let reset = try await store.synchronizationState()
            await flow.createDevice(name: "NotTennaPod on iPhone") // caption duplicate
            await flow.createDevice(name: "EXISTING") // normalized ID duplicate
            #expect(await transport.requests.count == 2)
            await flow.createDevice(name: "My iPad-é😀")
            #expect(flow.stage == .devices && flow.error == "sync.example.test is currently unavailable (code 503)" && !flow.busy)
            #expect(try await store.synchronizationState() == reset && vault.values.isEmpty)
            await flow.createDevice(name: "My iPad-é😀")
            let selected = try await store.synchronizationState()
            #expect(flow.stage == .finish && flow.error == nil && selected.account?.device == "my_ipad___")
            #expect(selected.request == nil)
            let sent = try #require(await transport.requests.last)
            #expect(sent.url?.path == "/api/2/devices/alice/my_ipad___.json")
            let body = try #require(sent.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json == ["caption": "My iPad-é😀", "type": "mobile"])
        }
    }

    @Test(arguments: [false, true])
    func cancellationIgnoresLateLoginOrRegistration(registration: Bool) async throws {
        let transport = AuthenticationTestTransport(suspendAt: registration ? 2 : 0)
        try await fixture(transport) { store, vault, _, flow in
            await flow.proceed(host: "sync.example.test")
            if registration { await flow.login(username: "alice", password: "draft-secret") }
            let reset = try await store.synchronizationState()
            let task = Task {
                if registration { await flow.createDevice(name: "new device") }
                else { await flow.login(username: "alice", password: "draft-secret") }
            }
            await transport.waitUntilSuspended()
            #expect(flow.busy)
            flow.cancel()
            await transport.resume()
            await task.value
            #expect(try await store.synchronizationState() == reset && vault.values.isEmpty)
            #expect(flow.stage == (registration ? .devices : .credentials) && !flow.busy)
        }
    }

    @Test(arguments: [false, true])
    func replacementAccountRejectsLateLoginOrRegistration(registration: Bool) async throws {
        let transport = AuthenticationTestTransport(suspendAt: registration ? 2 : 0)
        try await fixture(transport) { store, vault, accounts, flow in
            await flow.proceed(host: "sync.example.test")
            if registration { await flow.login(username: "alice", password: "draft-secret") }
            let task = Task {
                if registration { await flow.createDevice(name: "new device") }
                else { await flow.login(username: "alice", password: "draft-secret") }
            }
            await transport.waitUntilSuspended()
            let account = replacement()
            try await accounts.connect(account, password: "replacement-secret", fullSync: true)
            let selected = try await store.synchronizationState()
            await transport.resume()
            await task.value
            #expect(try await store.synchronizationState() == selected)
            #expect(vault.values == [account.credentialID: "replacement-secret"])
            #expect(flow.stage == (registration ? .devices : .credentials) && flow.error != nil && !flow.busy)
        }
    }

    @Test func epochIsCheckedAtHostResetAndAccountInstallationNotOnlyByDialog() async throws {
        try await fixture { store, vault, accounts, _ in
            let epoch = try await accounts.authenticationEpoch()
            let draft = SynchronizationAccount(backend: .gpodder, host: "sync.example.test", username: "draft", device: "phone")
            try await store.stageSynchronizationCredential(draft.credentialID, expectedEpoch: epoch)
            try vault.insert("draft", id: draft.credentialID)
            let account = replacement()
            try await accounts.connect(account, password: "replacement", fullSync: true)
            let selected = try await store.synchronizationState()
            await #expect(throws: CancellationError.self) {
                try await store.installSynchronizationAccount(draft, fullSync: false, expectedEpoch: epoch)
            }
            await #expect(throws: CancellationError.self) {
                try await accounts.prepareGpodderAuthentication(host: "obsolete.example.test", expectedEpoch: epoch)
            }
            await #expect(throws: CancellationError.self) {
                try await accounts.connect(draft, password: "draft", fullSync: false, expectedEpoch: epoch)
            }
            #expect(try await store.synchronizationState() == selected)
            #expect(vault.values == [account.credentialID: "replacement"])
        }
    }

    @Test func staleConnectedSettingsCannotEditLogoutOrRequestWorkForReplacement() async throws {
        try await fixture { store, vault, accounts, _ in
            let old = replacement()
            try await accounts.connect(old, password: "old", fullSync: false)
            let epoch = try await accounts.authenticationEpoch()
            let new = replacement()
            try await accounts.connect(new, password: "new", fullSync: false)
            let selected = try await store.synchronizationState()
            await #expect(throws: CancellationError.self) { try await accounts.changePassword("obsolete", expectedAccountID: old.id) }
            await #expect(throws: CancellationError.self) { try await accounts.disconnect(expectedAccountID: old.id) }
            await #expect(throws: CancellationError.self) {
                try await store.requestSynchronization(immediately: true, full: true, allowMobile: true, expectedEpoch: epoch)
            }
            #expect(try await store.synchronizationState() == selected && vault.values == [new.credentialID: "new"])
        }
    }
}

private actor AuthenticationTestTransport: SynchronizationHTTPTransport {
    enum Failure: Sendable { case status(Int), offline, secretError }
    private(set) var requests: [URLRequest] = []
    private let failures: [Int: Failure]
    private let suspendAt: Int?
    private var suspended: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    init(failures: [Int: Failure] = [:], suspendAt: Int? = nil) { self.failures = failures; self.suspendAt = suspendAt }
    func send(_ request: URLRequest) async throws -> SynchronizationHTTPResponse {
        let index = requests.count
        requests.append(request)
        if index == suspendAt {
            await withCheckedContinuation { suspended = $0; observer?.resume(); observer = nil }
        }
        if let failure = failures[index] {
            switch failure {
            case .status(let value): return .init(status: value, body: Data())
            case .offline: throw URLError(.notConnectedToInternet)
            case .secretError: throw NSError(domain: "draft-secret", code: 1, userInfo: [NSLocalizedDescriptionKey: "draft-secret"])
            }
        }
        let body = request.httpMethod == "GET"
            ? #"[{"id":"existing","caption":"NotTennaPod on iPhone","type":"mobile","subscriptions":3},{"id":"nottennapod_on_iphone__1_","caption":"Other caption","type":"desktop","subscriptions":0}]"# : ""
        return .init(status: 200, body: Data(body.utf8))
    }
    func waitUntilSuspended() async {
        if suspended != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resume() { suspended?.resume(); suspended = nil }
}

private final class AuthenticationTestCredentials: SynchronizationCredentialStore, Sendable {
    private let storage = Mutex<[UUID: String]>([:])
    var values: [UUID: String] { storage.withLock { $0 } }
    func insert(_ password: String, id: UUID) throws { storage.withLock { $0[id] = password } }
    func password(id: UUID) throws -> String {
        try storage.withLock { guard let value = $0[id] else { throw SynchronizationCredentialError.missing }; return value }
    }
    func remove(id: UUID) throws { storage.withLock { $0[id] = nil } }
}
