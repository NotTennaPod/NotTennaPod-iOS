import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

private let nextcloudStartJSON = #"{"login":"https://browser.example.test/authorize?state=fixture","poll":{"token":"poll-secret","endpoint":"https://poll.example.test/cloud/login/v2/poll"}}"#
private let nextcloudCredentialsJSON = #"{"server":"https://returned.example.test/cloud","loginName":"returned-user","appPassword":"returned-secret"}"#

@Suite
struct NextcloudAuthenticationClientTests {
    private func session() -> NextcloudAuthenticationSession {
        .init(rawHost: "cloud.example.test/subfolder", token: "poll-secret",
            endpoint: URL(string: "https://poll.example.test/cloud/login/v2/poll")!, expectedEpoch: UUID())
    }

    @Test(arguments: [
        ["cloud.example.test/cloud///", "https://cloud.example.test/cloud/index.php/login/v2"],
        ["cloud.example.test:80/cloud", "http://cloud.example.test:80/cloud/index.php/login/v2"],
        ["http://cloud.example.test:8123/a%20b/", "http://cloud.example.test:8123/a%20b/index.php/login/v2"]
    ])
    func hostAndSubfolderStartThenProviderDefinedPollAddress(values: [String]) async throws {
        let transport = NextcloudTestTransport([.json(nextcloudStartJSON), .json(nextcloudCredentialsJSON)])
        let client = try NextcloudAuthenticationClient(host: values[0], userAgent: "fixture-agent", transport: transport)
        let challenge = try await client.start()
        #expect(challenge.login.absoluteString == "https://browser.example.test/authorize?state=fixture")
        #expect(challenge.token == "poll-secret")
        #expect(challenge.endpoint.absoluteString == "https://poll.example.test/cloud/login/v2/poll")
        let credentials = try await client.poll(session())
        #expect(credentials.server == "https://returned.example.test/cloud")
        #expect(credentials.username == "returned-user" && credentials.password == "returned-secret")
        let requests = await transport.requests
        #expect(requests.map { $0.url!.absoluteString } == [values[1], "https://poll.example.test/cloud/login/v2/poll"])
        #expect(requests.map(\.httpBody) == [Data(), Data("token=poll-secret".utf8)])
        #expect(requests.allSatisfy { $0.httpMethod == "POST" && $0.value(forHTTPHeaderField: "Authorization") == nil })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded; charset=utf-8" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "fixture-agent" })
    }

    @Test(arguments: ["", "[]", "{", "{}", #"{"login":"https://cloud.test","poll":{"endpoint":"https://cloud.test/poll"}}"#,
        #"{"login":"file:///secret","poll":{"token":"secret","endpoint":"https://cloud.test/poll"}}"#])
    func malformedStartDoesNotProduceBrowserSession(json: String) async throws {
        let transport = NextcloudTestTransport([.json(json)])
        let client = try NextcloudAuthenticationClient(host: "cloud.test", transport: transport)
        await #expect(throws: SynchronizationError.invalidResponse) { try await client.start() }
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: [201, 204, 401, 404, 503])
    func startRequiresExactlyHTTP200(status: Int) async throws {
        let transport = NextcloudTestTransport([.status(status)])
        let client = try NextcloudAuthenticationClient(host: "cloud.test", transport: transport)
        await #expect(throws: SynchronizationError.httpStatus(status)) { try await client.start() }
    }

    @Test func pollRetriesTransportStatusAndJSONFailuresExactlyOneSecondApart() async throws {
        let transport = NextcloudTestTransport([.secretError, .status(404), .json("not JSON"), .json("{}"), .json(nextcloudCredentialsJSON)])
        let sleeper = NextcloudTestSleeper()
        let client = try NextcloudAuthenticationClient(host: "cloud.test", transport: transport)
        let work = Task { try await client.authorize(session(), sleep: { try await sleeper.sleep($0) }) }
        for attempt in 1...4 {
            await sleeper.waitFor(.seconds(1), occurrence: attempt)
            #expect(await transport.requests.count == attempt)
            await sleeper.release(.seconds(1))
        }
        let credentials = try await work.value
        #expect(credentials.password == "returned-secret")
        #expect(await transport.requests.count == 5)
        #expect(await sleeper.count(.seconds(1)) == 4)
        #expect(await sleeper.count(.seconds(300)) == 1)
    }

    @Test func timeoutIncludesAnUnfinishedPollRequestAndCancelsIt() async throws {
        let transport = NextcloudTestTransport([.holdUntilCancelled])
        let sleeper = NextcloudTestSleeper()
        let client = try NextcloudAuthenticationClient(host: "cloud.test", transport: transport)
        let work = Task { try await client.authorize(session(), sleep: { try await sleeper.sleep($0) }) }
        await transport.waitForRequests(1)
        await sleeper.waitFor(.seconds(300))
        await sleeper.release(.seconds(300))
        await #expect(throws: NextcloudAuthenticationError.timedOut) { try await work.value }
        #expect(await transport.requests.count == 1)
        #expect(await transport.heldRequestCancelled)
    }

    @Test func cancelledRetryWaitDoesNotMakeAnotherRequest() async throws {
        let transport = NextcloudTestTransport([.status(404)])
        let sleeper = NextcloudTestSleeper()
        let client = try NextcloudAuthenticationClient(host: "cloud.test", transport: transport)
        let work = Task { try await client.authorize(session(), sleep: { try await sleeper.sleep($0) }) }
        await sleeper.waitFor(.seconds(1))
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(await transport.requests.count == 1)
    }

    @Test func realHTTPPostsEmptyStartAndTokenWithoutAuthentication() async throws {
        let server = try await LoopbackHTTPServer.start { request in
            if request.path == "/cloud/index.php/login/v2" { return .init(body: Data(nextcloudStartJSON.utf8)) }
            return .init(body: Data(nextcloudCredentialsJSON.utf8))
        }
        defer { server.stop() }
        let base = server.url.deletingLastPathComponent()
        let client = try NextcloudAuthenticationClient(host: base.appendingPathComponent("cloud").absoluteString)
        _ = try await client.start()
        let poll = NextcloudAuthenticationSession(rawHost: base.absoluteString, token: "poll-secret",
            endpoint: base.appendingPathComponent("poll"), expectedEpoch: UUID())
        #expect(try await client.poll(poll).username == "returned-user")
        let requests = server.requests
        #expect(requests.map(\.path) == ["/cloud/index.php/login/v2", "/poll"])
        #expect(requests.map(\.body) == [Data(), Data("token=poll-secret".utf8)])
        #expect(requests.allSatisfy { $0.headers["authorization"] == nil })
    }
}

@Suite @MainActor
struct NextcloudAuthenticationFlowTests {
    private func fixture(_ transport: NextcloudTestTransport,
                         _ body: @MainActor (FeedLibraryStore, URL, NextcloudTestCredentials, SynchronizationAccounts) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NextcloudAuthentication-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: file, synchronizationClock: { Date(timeIntervalSince1970: 1_700_000_000) })
        let vault = NextcloudTestCredentials()
        let accounts = SynchronizationAccounts(store: store, credentials: vault, makeTransport: { transport })
        do { try await body(store, file, vault, accounts); try await store.close() }
        catch { try? await store.close(); throw error }
    }

    private func originalAccount() -> SynchronizationAccount {
        .init(backend: .gpodder, host: "https://old.example.test", username: "original", device: "phone")
    }

    @Test func browserAuthorizationPreservesOldStateUntilReturnedCredentialsCommitAndFullSync() async throws {
        let transport = NextcloudTestTransport([.json(nextcloudStartJSON), .json(nextcloudCredentialsJSON)], suspendAt: 1)
        try await fixture(transport) { store, file, vault, accounts in
            let old = originalAccount()
            try await accounts.connect(old, password: "old-secret", fullSync: true)
            try await store.setSynchronizationMobileAllowed(true)
            let request = try #require(await store.synchronizationState().request)
            let active = try await store.beginSynchronization(request)
            try await store.acknowledgeSynchronization(epoch: active.epoch, phase: .subscriptions, ids: [], timestamp: 71)
            try await store.acknowledgeSynchronization(epoch: active.epoch, phase: .episodes, ids: [], timestamp: 72)
            try await store.finishSynchronization(request, epoch: active.epoch, successful: true)
            _ = try await store.insert(.init(feed: .init(format: .rss, title: "Queued", episodes: []),
                source: "https://feed.test/rss", responseURL: URL(string: "https://feed.test/rss")!, validator: nil, permanentRedirectURL: nil))
            let before = try await store.synchronizationState(), queue = try await store.synchronizationQueue()
            #expect(queue.count == 1)
            var browsers: [URL] = []
            let flow = NextcloudAuthenticationFlow(accounts: accounts, openBrowser: { browsers.append($0); return true })
            let work = Task { await flow.start(host: "entered.example.test/subfolder") }
            await transport.waitUntilSuspended()
            #expect(flow.busy && flow.error == nil && flow.connectedEpoch == nil)
            #expect(flow.pendingSession?.rawHost == "entered.example.test/subfolder")
            #expect(flow.pendingSession?.expectedEpoch == before.epoch)
            #expect(browsers.map(\.absoluteString) == ["https://browser.example.test/authorize?state=fixture"])
            #expect(try await store.synchronizationState() == before)
            #expect(try await store.synchronizationQueue() == queue)
            #expect(vault.values == [old.credentialID: "old-secret"])
            await flow.start(host: "duplicate.test")
            #expect(await transport.requests.count == 2)
            await transport.resume()
            await work.value
            let state = try await store.synchronizationState(), account = try #require(state.account)
            #expect(account.backend == .nextcloud && account.host == "https://returned.example.test/cloud")
            #expect(account.username == "returned-user" && account.device.isEmpty)
            #expect(vault.values == [account.credentialID: "returned-secret"])
            #expect(state.epoch == flow.connectedEpoch && state.epoch != before.epoch)
            #expect(state.request?.notBefore == Date(timeIntervalSince1970: 1_700_000_000))
            #expect(state.allowMobile && state.request?.network == .connected && state.lastAttemptSuccessful)
            #expect(state.subscriptionTimestamp == 0 && state.episodeTimestamp == 0 && state.lastAttempt == nil)
            #expect(try await store.synchronizationQueue().isEmpty)
            #expect(!flow.busy && flow.error == nil && flow.pendingSession == nil)
            let reopened = try FeedLibraryStore(url: file)
            #expect(try await reopened.synchronizationState() == state)
            try await reopened.close()
            for secret in ["poll-secret", "returned-secret"] {
                #expect(try Data(contentsOf: file).range(of: Data(secret.utf8)) == nil)
                for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: file.path + suffix) {
                    #expect(try Data(contentsOf: URL(filePath: file.path + suffix)).range(of: Data(secret.utf8)) == nil)
                }
            }
        }
    }

    @Test func startFailurePreservesAccountAndAllowsFreshRetry() async throws {
        let transport = NextcloudTestTransport([.status(503), .json(nextcloudStartJSON), .json(nextcloudCredentialsJSON)])
        try await fixture(transport) { store, _, vault, accounts in
            let old = originalAccount(); try await accounts.connect(old, password: "old", fullSync: false)
            let before = try await store.synchronizationState()
            var opened = 0
            let flow = NextcloudAuthenticationFlow(accounts: accounts, openBrowser: { _ in opened += 1; return true })
            await flow.start(host: "cloud.test")
            #expect(flow.error == "Return code 503" && !flow.busy && flow.pendingSession == nil && opened == 0)
            #expect(try await store.synchronizationState() == before && vault.values == [old.credentialID: "old"])
            await flow.start(host: "cloud.test")
            #expect(flow.error == nil && flow.connectedEpoch != nil && opened == 1)
        }
    }

    @Test(arguments: [0, 1])
    func cancellationRejectsLateStartOrCredentialsWithoutChangingAccount(suspendAt: Int) async throws {
        let transport = NextcloudTestTransport([.json(nextcloudStartJSON), .json(nextcloudCredentialsJSON)], suspendAt: suspendAt)
        try await fixture(transport) { store, _, vault, accounts in
            let old = originalAccount(); try await accounts.connect(old, password: "old", fullSync: true)
            let before = try await store.synchronizationState()
            var opened = 0
            let flow = NextcloudAuthenticationFlow(accounts: accounts, openBrowser: { _ in opened += 1; return true })
            let work = Task { await flow.start(host: "cloud.test") }
            await transport.waitUntilSuspended()
            flow.cancel()
            await transport.resume(); await work.value
            #expect(try await store.synchronizationState() == before && vault.values == [old.credentialID: "old"])
            #expect(flow.connectedEpoch == nil && flow.pendingSession == nil && !flow.busy && flow.error == nil)
            #expect(opened == suspendAt)
            await flow.start(host: "again.test")
            #expect(await transport.requests.count == suspendAt + 1)
        }
    }

    @Test(arguments: [0, 1])
    func replacementAccountRejectsLateAuthorization(suspendAt: Int) async throws {
        let transport = NextcloudTestTransport([.json(nextcloudStartJSON), .json(nextcloudCredentialsJSON)], suspendAt: suspendAt)
        try await fixture(transport) { store, _, vault, accounts in
            var opened = 0
            let flow = NextcloudAuthenticationFlow(accounts: accounts, openBrowser: { _ in opened += 1; return true })
            let work = Task { await flow.start(host: "cloud.test") }
            await transport.waitUntilSuspended()
            let replacement = originalAccount(); try await accounts.connect(replacement, password: "new-selection", fullSync: true)
            let before = try await store.synchronizationState()
            await transport.resume(); await work.value
            #expect(try await store.synchronizationState() == before && vault.values == [replacement.credentialID: "new-selection"])
            #expect(flow.connectedEpoch == nil && flow.pendingSession == nil && !flow.busy && flow.error != nil)
            #expect(opened == suspendAt)
        }
    }

    @Test func recreationRestoresOpaquePollSessionWithoutOpeningBrowserAgain() async throws {
        let transport = NextcloudTestTransport([.json(nextcloudStartJSON), .json(nextcloudCredentialsJSON), .json(nextcloudCredentialsJSON)], suspendAt: 1)
        try await fixture(transport) { store, _, _, accounts in
            var opened = 0
            let flow = NextcloudAuthenticationFlow(accounts: accounts, openBrowser: { _ in opened += 1; return true })
            let work = Task { await flow.start(host: "cloud.test/base") }
            await transport.waitUntilSuspended()
            let saved = try #require(flow.pendingSession)
            let encoded = try JSONEncoder().encode(saved)
            let restored = try JSONDecoder().decode(NextcloudAuthenticationSession.self, from: encoded)
            #expect(restored == saved && !saved.description.contains("poll-secret"))
            flow.cancel(); await transport.resume(); await work.value
            let resumed = NextcloudAuthenticationFlow(accounts: accounts, openBrowser: { _ in opened += 1; return true })
            await resumed.resume(session: restored)
            #expect(opened == 1 && resumed.connectedEpoch != nil && resumed.pendingSession == nil)
            #expect(try await store.synchronizationState().account?.username == "returned-user")
            let requests = await transport.requests
            #expect(requests.map { $0.url!.path } == ["/base/index.php/login/v2", "/cloud/login/v2/poll", "/cloud/login/v2/poll"])
        }
    }

    @Test func restoredSessionForObsoleteEpochNeverPollsOrLaunchesBrowser() async throws {
        let transport = NextcloudTestTransport([])
        try await fixture(transport) { store, _, vault, accounts in
            let epoch = try await accounts.authenticationEpoch()
            let old = originalAccount(); try await accounts.connect(old, password: "replacement", fullSync: true)
            let before = try await store.synchronizationState()
            let session = NextcloudAuthenticationSession(rawHost: "cloud.test", token: "obsolete-token",
                endpoint: URL(string: "https://cloud.test/poll")!, expectedEpoch: epoch)
            let flow = NextcloudAuthenticationFlow(accounts: accounts, openBrowser: { _ in Issue.record("Stale session opened browser"); return true })
            await flow.resume(session: session)
            #expect(await transport.requests.isEmpty)
            #expect(flow.error != nil && flow.pendingSession == nil && flow.connectedEpoch == nil)
            #expect(try await store.synchronizationState() == before && vault.values == [old.credentialID: "replacement"])
        }
    }

    @Test func timeoutRestoresEditableStateAndPreservesCredentials() async throws {
        let transport = NextcloudTestTransport([.json(nextcloudStartJSON), .status(404)])
        let sleeper = NextcloudTestSleeper()
        try await fixture(transport) { store, _, vault, accounts in
            let old = originalAccount(); try await accounts.connect(old, password: "original", fullSync: true)
            let before = try await store.synchronizationState()
            let flow = NextcloudAuthenticationFlow(accounts: accounts, openBrowser: { _ in true }, sleep: { try await sleeper.sleep($0) })
            let work = Task { await flow.start(host: "cloud.test") }
            await sleeper.waitFor(.seconds(1)); await sleeper.waitFor(.seconds(300))
            await sleeper.release(.seconds(300)); await work.value
            #expect(flow.error == URLError(.timedOut).localizedDescription)
            #expect(!flow.busy && flow.pendingSession == nil && flow.connectedEpoch == nil)
            #expect(try await store.synchronizationState() == before && vault.values == [old.credentialID: "original"])
        }
    }

    @Test func failedCredentialWritePreservesOldAccountAndSanitizesError() async throws {
        let transport = NextcloudTestTransport([.json(nextcloudStartJSON), .json(nextcloudCredentialsJSON)])
        try await fixture(transport) { store, _, vault, accounts in
            let old = originalAccount(); try await accounts.connect(old, password: "original", fullSync: true)
            let before = try await store.synchronizationState()
            vault.failInsert = true
            let flow = NextcloudAuthenticationFlow(accounts: accounts, openBrowser: { _ in true })
            await flow.start(host: "cloud.test")
            #expect(flow.error == URLError(.unknown).localizedDescription && flow.connectedEpoch == nil)
            #expect(flow.pendingSession == nil && !flow.busy)
            #expect(try await store.synchronizationState() == before && vault.values == [old.credentialID: "original"])
        }
    }

    @Test func emptyHostAndUnavailableBrowserFailWithoutResettingAccount() async throws {
        let transport = NextcloudTestTransport([.json(nextcloudStartJSON)])
        try await fixture(transport) { store, _, _, accounts in
            let old = originalAccount(); try await accounts.connect(old, password: "original", fullSync: true)
            let before = try await store.synchronizationState()
            let flow = NextcloudAuthenticationFlow(accounts: accounts, openBrowser: { _ in false })
            await flow.start(host: "")
            #expect(flow.error == URLError(.badURL).localizedDescription && !flow.busy)
            #expect(await transport.requests.isEmpty)
            await flow.start(host: "cloud.test")
            #expect(flow.error == URLError(.unsupportedURL).localizedDescription && flow.pendingSession == nil)
            #expect(await transport.requests.count == 1)
            #expect(try await store.synchronizationState() == before)
        }
    }

    @Test func arbitraryTransportDetailsCannotLeakIntoError() async throws {
        let transport = NextcloudTestTransport([.secretError])
        try await fixture(transport) { _, _, _, accounts in
            let flow = NextcloudAuthenticationFlow(accounts: accounts, openBrowser: { _ in true })
            await flow.start(host: "cloud.test")
            #expect(flow.error == URLError(.unknown).localizedDescription)
            #expect(flow.pendingSession == nil && !flow.busy)
        }
    }
}

private actor NextcloudTestTransport: SynchronizationHTTPTransport {
    enum Reply: Sendable { case json(String), status(Int), secretError, holdUntilCancelled }
    private let replies: [Reply]
    private let suspendAt: Int?
    private(set) var requests: [URLRequest] = []
    private(set) var heldRequestCancelled = false
    private var suspended: CheckedContinuation<Void, Never>?
    private var suspensionObserver: CheckedContinuation<Void, Never>?

    init(_ replies: [Reply], suspendAt: Int? = nil) { self.replies = replies; self.suspendAt = suspendAt }
    func send(_ request: URLRequest) async throws -> SynchronizationHTTPResponse {
        let index = requests.count; requests.append(request)
        if index == suspendAt {
            await withCheckedContinuation { suspended = $0; suspensionObserver?.resume(); suspensionObserver = nil }
        }
        guard index < replies.count else { Issue.record("Unexpected Nextcloud request"); throw URLError(.badServerResponse) }
        switch replies[index] {
        case .json(let value): return .init(status: 200, body: Data(value.utf8))
        case .status(let code): return .init(status: code, body: Data())
        case .secretError: throw NSError(domain: "poll-secret", code: 1, userInfo: [NSLocalizedDescriptionKey: "returned-secret"])
        case .holdUntilCancelled:
            do { try await Task.sleep(for: .seconds(3600)) }
            catch { heldRequestCancelled = true; throw error }
            Issue.record("Held request unexpectedly completed"); throw URLError(.badServerResponse)
        }
    }
    func waitUntilSuspended() async {
        if suspended != nil { return }
        await withCheckedContinuation { suspensionObserver = $0 }
    }
    func waitForRequests(_ count: Int) async { while requests.count < count { await Task.yield() } }
    func resume() { suspended?.resume(); suspended = nil }
}

private actor NextcloudTestSleeper {
    private struct Wait { let id: UUID; let duration: Duration; let continuation: CheckedContinuation<Void, any Error> }
    private var waits: [Wait] = []
    private var history: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                history.append(duration); waits.append(.init(id: id, duration: duration, continuation: continuation))
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func waitFor(_ duration: Duration, occurrence: Int = 1) async {
        while count(duration) < occurrence { await Task.yield() }
    }
    func count(_ duration: Duration) -> Int { history.filter { $0 == duration }.count }
    func release(_ duration: Duration) {
        guard let index = waits.firstIndex(where: { $0.duration == duration }) else { Issue.record("No matching delay"); return }
        waits.remove(at: index).continuation.resume()
    }
    private func cancel(_ id: UUID) {
        guard let index = waits.firstIndex(where: { $0.id == id }) else { return }
        waits.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

private final class NextcloudTestCredentials: SynchronizationCredentialStore, Sendable {
    private struct State { var values: [UUID: String] = [:]; var failInsert = false }
    private let state = Mutex(State())
    var values: [UUID: String] { state.withLock { $0.values } }
    var failInsert: Bool {
        get { state.withLock { $0.failInsert } }
        set { state.withLock { $0.failInsert = newValue } }
    }
    func insert(_ password: String, id: UUID) throws {
        try state.withLock {
            if $0.failInsert { throw NSError(domain: "returned-secret", code: 1, userInfo: [NSLocalizedDescriptionKey: password]) }
            $0.values[id] = password
        }
    }
    func password(id: UUID) throws -> String {
        try state.withLock { guard let value = $0.values[id] else { throw SynchronizationCredentialError.missing }; return value }
    }
    func remove(id: UUID) throws { state.withLock { $0.values[id] = nil } }
}
