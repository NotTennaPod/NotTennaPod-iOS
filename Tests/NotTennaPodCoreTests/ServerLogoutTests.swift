import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Logout's two choices and its cut-off (PROTOCOL §15.4), the page's states for a Keep at logout and previous libraries
/// (PROTOCOL §15.5), and the removal of a previous library. No server: the sign-out goes to a transport the test holds.
@MainActor @Suite(.serialized) struct ServerLogoutTests {
    /// Records every request; sign-outs wait until the test lets them go.
    final class Transport: SynchronizationHTTPTransport, @unchecked Sendable {
        private let state = Mutex<(requests: [URLRequest], gates: [CheckedContinuation<Void, Never>], open: Bool)>(([], [], false))
        var requests: [URLRequest] { state.withLock { $0.requests } }
        func release() {
            let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.open = true
                defer { state.gates.removeAll() }
                return state.gates
            }
            for gate in waiting { gate.resume() }
        }
        func send(_ request: URLRequest) async throws -> SynchronizationHTTPResponse {
            await withCheckedContinuation { continuation in
                let open = state.withLock { state -> Bool in
                    state.requests.append(request)
                    if !state.open { state.gates.append(continuation) }
                    return state.open
                }
                if open { continuation.resume() }
            }
            return SynchronizationHTTPResponse(status: 204, body: Data())
        }
    }

    /// The Keychain items, whose writes fail while `locked` (a locked or failing Keychain); reads still work.
    final class FailingSaves: ServerSecretStore {
        let base: MemoryServerSecrets
        let locked = Mutex(false)
        init(_ base: MemoryServerSecrets) { self.base = base }
        func deviceMarker() throws -> String { try base.deviceMarker() }
        func installation(library: String, install: String) throws -> ServerInstallationCredential? {
            try base.installation(library: library, install: install)
        }
        func saveInstallation(_ credential: ServerInstallationCredential, library: String, install: String) throws {
            if locked.withLock({ $0 }) { throw ServerSecretStoreError.keychain(-25308) }
            try base.saveInstallation(credential, library: library, install: install)
        }
        func removeInstallation(library: String, install: String) throws { try base.removeInstallation(library: library, install: install) }
        func removeLibrary(_ library: String) throws { try base.removeLibrary(library) }
        func installIDs(of library: String) throws -> [String] { try base.installIDs(of: library) }
    }

    @MainActor final class World {
        let root: URL
        let id = ContractIdentity.randomUUID()
        let install = ContractIdentity.randomUUID()
        let secrets = MemoryServerSecrets()
        lazy var saves = FailingSaves(secrets)
        let transport = Transport()
        var events: [String] = []
        var accounts: ServerAccounts!
        var dependencies: ServerAccounts.Dependencies!
        var open: LibraryReference

        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Logout-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try await FeedLibraryStore(url: root.appendingPathComponent("library.sqlite")).close()
            let location = LibraryLocation(root: root, reference: .server(id))
            try await StoreServerLibraryProvisioning(feedVault: { MemoryCredentialVault() }).provision(location, ServerLibraryProvision(
                libraryID: id, serverURL: "http://127.0.0.1:1", serverID: "server", accountID: ContractIdentity.randomUUID(),
                namespace: ContractIdentity.randomUUID(), username: "alice", installID: install, deviceMarker: "marker"))
            try secrets.saveInstallation(.init(transportNonce: "nonce-1", token: "token-1"), library: id, install: install)
            var registry = LibraryRegistry()
            registry.libraries = [.init(id: id, serverURL: "http://127.0.0.1:1", serverID: "server", accountID: ContractIdentity.randomUUID(),
                                        username: "alice", state: .active, createdAt: 0)]
            registry.active = .server(id)
            try LibraryRegistryFile(root: root).write(registry)
            open = .server(id)
            let transport = transport
            var dependencies = ServerAccounts.Dependencies(root: root, openLibrary: { [unowned self] in open },
                requestSwitch: { [unowned self] target, reason, _ in
                    events.append("switch \(target.name) \(reason.rawValue)")
                    try LibraryRegistryFile(root: root).update { try $0.recordSwitch(to: target, reason: reason, at: 1) }
                }, secrets: saves, makeClient: { ServerClient(address: $0, transport: transport) },
                provisioning: StoreServerLibraryProvisioning(feedVault: { MemoryCredentialVault() }),
                device: ServerDevice(name: "NotTennaPod on iPhone", appVersion: "test"))
            dependencies.stopSync = { [unowned self] in
                // Sync stops after the choice is recorded and before the token is removed (PROTOCOL §15.4–3).
                let registry = (try? LibraryRegistryFile(root: root).read()) ?? LibraryRegistry()
                let token = (try? secrets.installation(library: id, install: install))?.token
                events.append("stop sync, state \(registry.library(id)?.state.rawValue ?? "-"), token \(token ?? "-")")
            }
            dependencies.attemptKeep = { [unowned self] in events.append("attempt keep") }
            dependencies.gate = LibraryGate()
            self.dependencies = dependencies
            accounts = ServerAccounts(dependencies)
        }

        /// A new launch: the account service reads what it kept on disk.
        func relaunch() { accounts = ServerAccounts(dependencies) }

        var registry: LibraryRegistry { (try? LibraryRegistryFile(root: root).read()) ?? LibraryRegistry() }
        var credential: ServerInstallationCredential? { try? secrets.installation(library: id, install: install) }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func keepRecordsTheChoiceStopsSyncAndRemovesTheTokenBeforeSigningOut() async throws {
        let world = try await World()
        defer { world.cleanUp() }
        try await world.accounts.logout(.keep, scene: nil)
        // 1. The manifest, then the registry: keeping with the operation.
        let entry = try #require(world.registry.library(world.id))
        #expect(entry.state == .keeping)
        let operation = try #require(entry.operation)
        #expect(FileManager.default.fileExists(atPath: LibraryKeep.conversionsFolder(root: world.root)
            .appendingPathComponent(operation).appendingPathComponent(LibraryKeep.manifestName).path))
        // 2. Sync stopped with the choice recorded and the token still there; 3. then the token is gone, the nonce kept.
        #expect(world.events == ["stop sync, state keeping, token token-1", "attempt keep"])
        #expect(world.credential?.token == nil && world.credential?.transportNonce == "nonce-1")
        // 4. The background sign-out carries that token and no other; nothing waited for it.
        for task in world.accounts.signOuts { _ = task }
        while world.transport.requests.isEmpty { await Task.yield() }
        #expect(world.transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer token-1"])
        world.transport.release()
        for task in world.accounts.signOuts { await task.value }
        // The page: logged out, keeping; the provider choice waits for the Keep.
        let page = world.accounts.page(otherProvider: false)
        #expect(page.mode == .none && page.condition == .keeping && page.providerChoiceBlocked)
    }

    @Test func goBackRecordsTheSwitchInTheSameWriteAndKeepsTheInstallation() async throws {
        let world = try await World()
        defer { world.cleanUp() }
        try await world.accounts.logout(.goBack, scene: nil)
        #expect(world.events.first == "stop sync, state inactive, token token-1")
        #expect(world.events.last == "switch standalone logout")
        #expect(world.registry.library(world.id)?.state == .inactive)
        #expect(world.registry.pendingSwitch?.to == .standalone)
        #expect(world.credential?.token == nil && world.credential?.transportNonce == "nonce-1")
        world.transport.release()
        for task in world.accounts.signOuts { await task.value }
    }

    /// Go back, a delayed sign-out, a successful resume storing a new token, then the old sign-out task
    /// completing: the new token stays and the transport nonce is kept.
    @Test func aDelayedSignOutNeverErasesALaterLogin() async throws {
        let world = try await World()
        defer { world.cleanUp() }
        try await world.accounts.logout(.goBack, scene: nil)
        while world.transport.requests.isEmpty { await Task.yield() }
        // The resume stores its token while the old sign-out still waits.
        try world.secrets.saveInstallation(.init(transportNonce: "nonce-1", token: "token-2"), library: world.id, install: world.install)
        world.transport.release()
        for task in world.accounts.signOuts { await task.value }
        #expect(world.credential?.token == "token-2" && world.credential?.transportNonce == "nonce-1")
        #expect(world.transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer token-1"])
    }

    /// A token the cut-off could not remove is recorded on disk by its digest, never in clear, and a
    /// later launch removes it once the Keychain can be written; until then the record stays. (Every graph start, so
    /// every launch, calls the retry: `ServerAccounts.graphStarted`.)
    @Test func aFailedTokenRemovalIsRecordedAndRetriedAtLaunch() async throws {
        let world = try await World()
        defer { world.cleanUp() }
        world.saves.locked.withLock { $0 = true }
        try await world.accounts.logout(.goBack, scene: nil)
        #expect(world.credential?.token == "token-1")
        let file = world.root.appendingPathComponent(ServerTokenRemovals.fileName)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains(ServerTokenRemovals.digest("token-1")) && !text.contains("token-1"))
        // The sign-out still carries the captured token.
        while world.transport.requests.isEmpty { await Task.yield() }
        #expect(world.transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer token-1"])
        world.transport.release()
        for task in world.accounts.signOuts { await task.value }
        // Still failing at the next launch: the token and the record stay.
        world.relaunch()
        world.accounts.retryTokenRemovals()
        #expect(world.credential?.token == "token-1" && FileManager.default.fileExists(atPath: file.path))
        // The launch after: removed, the transport nonce kept, the record gone.
        world.saves.locked.withLock { $0 = false }
        world.relaunch()
        world.accounts.retryTokenRemovals()
        #expect(world.credential?.token == nil && world.credential?.transportNonce == "nonce-1")
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// A login made after the failed removal stores its own token; the retry at the next launch sees
    /// another token in the item and ends the record without touching it.
    @Test func aRetriedRemovalNeverTouchesALaterLogin() async throws {
        let world = try await World()
        defer { world.cleanUp() }
        world.saves.locked.withLock { $0 = true }
        try await world.accounts.logout(.goBack, scene: nil)
        world.transport.release()
        for task in world.accounts.signOuts { await task.value }
        // The resume stores its token (a Keychain write that works again).
        world.saves.locked.withLock { $0 = false }
        try world.saves.saveInstallation(.init(transportNonce: "nonce-1", token: "token-2"), library: world.id, install: world.install)
        world.relaunch()
        world.accounts.retryTokenRemovals()
        #expect(world.credential?.token == "token-2" && world.credential?.transportNonce == "nonce-1")
        #expect(!FileManager.default.fileExists(atPath: world.root.appendingPathComponent(ServerTokenRemovals.fileName).path))
    }

    /// The cut-off's fence (PROTOCOL §15.4): a response that arrives after the exchange was stopped is discarded, so the
    /// engine writes nothing of it and the change stays unconfirmed.
    @Test func aResponseArrivingAfterTheStopIsDiscarded() async throws {
        final class Answering: SynchronizationHTTPTransport, @unchecked Sendable {
            /// The held answer and whoever waits for the request to arrive, under one lock.
            let state = Mutex<(answer: CheckedContinuation<Void, Never>?, waiter: CheckedContinuation<Void, Never>?, arrived: Bool)>((nil, nil, false))
            func send(_ request: URLRequest) async throws -> SynchronizationHTTPResponse {
                // The server accepted the push; its answer is on its way when the exchange stops.
                await withCheckedContinuation { continuation in
                    let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                        state.answer = continuation; state.arrived = true
                        defer { state.waiter = nil }
                        return state.waiter
                    }
                    waiter?.resume()
                }
                return SynchronizationHTTPResponse(status: 200, body: Data(#"{"results":[{"install_seq":1,"status":"accepted","receipt":{"outcome":"applied"}}]}"#.utf8))
            }
            func waitForRequest() async {
                await withCheckedContinuation { continuation in
                    let arrived = state.withLock { state -> Bool in
                        if !state.arrived { state.waiter = continuation }
                        return state.arrived
                    }
                    if arrived { continuation.resume() }
                }
            }
            func answer() { state.withLock { state in defer { state.answer = nil }; return state.answer }?.resume() }
        }
        let answering = Answering()
        let transport = HTTPServerExchangeTransport(base: URL(string: "http://127.0.0.1:1")!, transport: answering, token: { "token" })
        let push = Task { try await transport.push(["operations": []]) }
        await answering.waitForRequest()
        push.cancel()
        answering.answer()
        await #expect(throws: CancellationError.self) { _ = try await push.value }
    }

    @Test func thePageNamesWhatTheKeepWaitsForAndListsPreviousLibraries() throws {
        var registry = LibraryRegistry()
        let id = ContractIdentity.randomUUID()
        registry.libraries = [.init(id: id, serverURL: "http://h", serverID: "s", accountID: ContractIdentity.randomUUID(), username: "a",
                                    state: .keeping, operation: ContractIdentity.randomUUID(), createdAt: 0)]
        registry.active = .server(id)
        registry.previous = [.init(id: ContractIdentity.randomUUID(), identity: "b", keptAt: 2_000),
                             .init(id: ContractIdentity.randomUUID(), identity: "a", keptAt: 1_000)]
        let waiting = ServerSynchronizationPage.make(registry: registry, open: .server(id), otherProvider: false, summaries: [:])
        #expect(waiting.condition == .keeping && waiting.providerChoiceBlocked && waiting.showsOrdinaryRows)
        #expect(waiting.rows == [.status] + registry.previous.sorted { $0.keptAt < $1.keptAt }.map { .previousLibrary($0.id) })
        #expect(ServerSynchronizationPage.make(registry: registry, open: .server(id), otherProvider: false, summaries: [:], castBlocks: true).condition == .keepingCast)
        #expect(ServerSynchronizationPage.make(registry: registry, open: .server(id), otherProvider: false, summaries: [:],
                                               keepFailure: .storage).condition == .keepStalled(.storage))
        // After the Keep: no provider, the previous libraries, oldest first.
        registry.libraries = []; registry.active = .standalone
        let after = ServerSynchronizationPage.make(registry: registry, open: .standalone, otherProvider: false, summaries: [:])
        #expect(after.condition == nil && !after.providerChoiceBlocked)
        #expect(after.previousLibraries.map(\.identity) == ["a", "b"])
        // Logged out, switch pending, while Cast holds media; ready, waiting for Cast.
        registry.libraries = [.init(id: id, serverURL: "http://h", serverID: "s", accountID: ContractIdentity.randomUUID(), username: "a",
                                    state: .inactive, createdAt: 0)]
        #expect(ServerSynchronizationPage.make(registry: registry, open: .server(id), otherProvider: false, summaries: [:], castBlocks: true).condition == .loggedOutCast)
        registry.libraries[0].state = .ready
        #expect(ServerSynchronizationPage.make(registry: registry, open: .standalone, otherProvider: false, summaries: [:], castBlocks: true).condition == .readyCast)
    }

    @Test func removingAPreviousLibraryDeletesItsCredentialsAndFolderUnderTheGate() async throws {
        let world = try await World()
        defer { world.cleanUp() }
        let previous = PreviousLibraryLocation(root: world.root, id: ContractIdentity.randomUUID())
        try FileManager.default.createDirectory(at: previous.folder, withIntermediateDirectories: true)
        let store = try FeedLibraryStore(url: previous.database)
        let vault = MemoryCredentialVault()
        let feed = try await store.insert(ServerLibraryFixture.fetched())
        try await FeedAuthentication(store: store, vault: vault).save(.init(username: "u", password: "p"), feedID: feed.id)
        let credential = try #require(try await store.feedCredentialID(feedID: feed.id))
        try await store.close()
        try LibraryRegistryFile(root: world.root).update { $0.previous = [.init(id: previous.id, identity: "x", keptAt: 1)] }
        var dependencies = ServerAccounts.Dependencies(root: world.root, openLibrary: { .standalone }, requestSwitch: { _, _, _ in },
            secrets: world.secrets, makeClient: { ServerClient(address: $0) }, device: ServerDevice(name: "n", appVersion: "t"))
        dependencies.feedVault = { vault }
        let gate = LibraryGate()
        dependencies.gate = gate
        let accounts = ServerAccounts(dependencies)
        // An export still collecting holds the gate: the removal waits for it.
        await gate.acquireShared()
        let removal = Task { try await accounts.removePreviousLibrary(previous.id) }
        for _ in 0..<50 { await Task.yield() }
        #expect(FileManager.default.fileExists(atPath: previous.folder.path))
        gate.releaseShared()
        try await removal.value
        #expect(!FileManager.default.fileExists(atPath: previous.folder.path))
        #expect(!vault.contains(credential))
        #expect((try LibraryRegistryFile(root: world.root).read()).previous.isEmpty)
    }
}
