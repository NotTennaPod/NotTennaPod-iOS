import Foundation

/// Metadata only. Passwords/app tokens are held separately under credentialID.
public struct SynchronizationAccount: Codable, Equatable, Sendable {
    public let id: UUID
    public let backend: SynchronizationHTTPClient.Backend
    public let host: String
    public let username: String
    public let device: String
    public let credentialID: UUID

    public init(backend: SynchronizationHTTPClient.Backend, host: String, username: String, device: String = "") {
        id = UUID(); credentialID = UUID()
        self.backend = backend; self.host = host; self.username = username; self.device = device
    }
    private init(replacing account: Self) {
        id = account.id; backend = account.backend; host = account.host
        username = account.username; device = account.device; credentialID = UUID()
    }
    func replacingCredential() -> Self { .init(replacing: self) }
}

public enum SynchronizationCredentialError: Error, Equatable, Sendable {
    case missing, corrupt, keychain(Int32)
}

/// Immutable entries: a new credential gets a new identity before selection.
public protocol SynchronizationCredentialStore: Sendable {
    func insert(_ password: String, id: UUID) throws
    func password(id: UUID) throws -> String
    func remove(id: UUID) throws
}

/// Serializes account mutations across asynchronous library commits. Worker
/// resolution may run concurrently and validates its profile after reading.
public actor SynchronizationAccounts {
    private let store: FeedLibraryStore
    private let credentials: any SynchronizationCredentialStore
    private let userAgent: String
    private let makeTransport: @Sendable () throws -> any SynchronizationHTTPTransport
    private var tail: Task<Void, Never>?

    public init(store: FeedLibraryStore, credentials: any SynchronizationCredentialStore = KeychainSynchronizationCredentials(),
                userAgent: String = HTTPUserAgent.unversioned,
                makeTransport: @escaping @Sendable () throws -> any SynchronizationHTTPTransport = { URLSessionSynchronizationTransport() }) {
        self.store = store; self.credentials = credentials; self.userAgent = userAgent; self.makeTransport = makeTransport
    }

    /// Call after authentication/device selection. Nextcloud requests full sync
    /// here; gpodder's finish button requests immediate sync separately.
    @discardableResult
    public func connect(_ account: SynchronizationAccount, password: String, fullSync: Bool,
                        expectedEpoch: UUID? = nil) async throws -> UUID {
        let store = store, credentials = credentials, userAgent = userAgent
        return try await serial {
            _ = try SynchronizationHTTPClient(backend: account.backend, host: account.host,
                username: account.username, password: password, device: account.device, userAgent: userAgent)
            try await store.stageSynchronizationCredential(account.credentialID, expectedEpoch: expectedEpoch)
            let epoch: UUID
            do {
                try credentials.insert(password, id: account.credentialID)
                epoch = try await store.installSynchronizationAccount(account, fullSync: fullSync, expectedEpoch: expectedEpoch)
            } catch {
                try? await Self.cleanup(store, credentials)
                throw error
            }
            // Selection is already committed. A deletion failure is retained in
            // the durable journal and must not report that login failed.
            try? await Self.cleanup(store, credentials)
            return epoch
        }
    }

    public func authenticationEpoch() async throws -> UUID {
        try await store.synchronizationState().epoch
    }

    /// Host confirmation is a durable boundary, even if the later dialog is cancelled.
    /// The transaction fences a delayed host confirmation against a replacement account.
    public func prepareGpodderAuthentication(host: String, expectedEpoch: UUID) async throws -> UUID {
        let store = store, credentials = credentials
        return try await serial {
            // Source Host Proceed commits every nonempty draft. Address validation
            // belongs to Login, after this durable clear/reset boundary.
            guard !host.isEmpty else { throw SynchronizationError.invalidHost }
            let epoch = try await store.resetSynchronizationForAuthentication(host: host, expectedEpoch: expectedEpoch)
            try? await Self.cleanup(store, credentials)
            return epoch
        }
    }

    /// Uses the same configured transport (including proxy policy) as the worker.
    public func gpodderAuthenticationClient(host: String, username: String, password: String) throws -> SynchronizationHTTPClient {
        try SynchronizationHTTPClient(backend: .gpodder, host: host, username: username,
            password: password, userAgent: userAgent, transport: makeTransport())
    }

    /// Login Flow v2 shares the worker's configured transport, but does not
    /// change the selected account until browser authorization has succeeded.
    public func nextcloudAuthenticationClient(host: String) throws -> NextcloudAuthenticationClient {
        try NextcloudAuthenticationClient(host: host, userAgent: userAgent, transport: makeTransport())
    }

    public func changePassword(_ password: String, expectedAccountID: UUID? = nil) async throws {
        let store = store, credentials = credentials
        try await serial {
            let state = try await store.synchronizationState()
            if let expectedAccountID, state.accountID != expectedAccountID { throw CancellationError() }
            guard let previous = state.account, previous.id == state.accountID else { throw SynchronizationCredentialError.missing }
            let account = previous.replacingCredential()
            try await store.stageSynchronizationCredential(account.credentialID)
            do {
                try credentials.insert(password, id: account.credentialID)
                try await store.replaceSynchronizationCredential(account, previous: previous)
            } catch {
                try? await Self.cleanup(store, credentials)
                throw error
            }
            try? await Self.cleanup(store, credentials)
        }
    }

    public func disconnect(expectedAccountID: UUID? = nil) async throws {
        let store = store, credentials = credentials
        try await serial {
            try await store.selectSynchronizationAccount(nil, expectedAccountID: expectedAccountID)
            try? await Self.cleanup(store, credentials)
        }
    }

    /// Retry at startup/activation. Missing entries are successful removals;
    /// locked/unavailable Keychain leaves the journal available for a later try.
    public func recoverCredentialCleanup() async throws {
        let store = store, credentials = credentials
        try await serial { try await Self.cleanup(store, credentials) }
    }

    public func provider(accountID: UUID) async throws -> SynchronizationHTTPClient {
        let before = try await store.synchronizationState()
        guard before.accountID == accountID else { throw CancellationError() }
        guard let account = before.account, account.id == accountID else { throw SynchronizationCredentialError.missing }
        let password = try credentials.password(id: account.credentialID)
        let after = try await store.synchronizationState()
        guard after.account == account, after.accountID == accountID, after.epoch == before.epoch else { throw CancellationError() }
        try Task.checkCancellation()
        return try SynchronizationHTTPClient(backend: account.backend, host: account.host, username: account.username,
            password: password, device: account.device, userAgent: userAgent, transport: makeTransport())
    }

    private static func cleanup(_ store: FeedLibraryStore, _ credentials: any SynchronizationCredentialStore) async throws {
        for id in try await store.synchronizationState().credentialCleanup ?? [] {
            try Task.checkCancellation()
            try credentials.remove(id: id)
            try await store.acknowledgeSynchronizationCredentialCleanup(id)
        }
    }

    private func serial<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { await previous?.value; try Task.checkCancellation(); return try await body() }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

extension FeedLibraryStore {
    func stageSynchronizationCredential(_ id: UUID, expectedEpoch: UUID? = nil) throws {
        try Task.checkCancellation()
        try database.transaction {
            var state = try synchronizationState()
            if let expectedEpoch, state.epoch != expectedEpoch { throw CancellationError() }
            guard state.account?.credentialID != id, !(state.credentialCleanup ?? []).contains(id) else { throw SynchronizationCredentialError.corrupt }
            state.credentialCleanup = (state.credentialCleanup ?? []) + [id]
            try saveSynchronizationState(state)
        }
    }

    @discardableResult
    func installSynchronizationAccount(_ account: SynchronizationAccount, fullSync: Bool, expectedEpoch: UUID? = nil) throws -> UUID {
        try Task.checkCancellation()
        let epoch = try database.transaction {
            var state = try synchronizationState()
            if let expectedEpoch, state.epoch != expectedEpoch { throw CancellationError() }
            guard (state.credentialCleanup ?? []).contains(account.credentialID) else { throw SynchronizationCredentialError.corrupt }
            var retired = (state.credentialCleanup ?? []).filter { $0 != account.credentialID }
            if let old = state.account?.credentialID { retired.append(old) }
            let mobile = state.allowMobile, lastHost = account.host, previousSuccess = state.lastAttemptSuccessful
            state = SynchronizationState()
            state.accountID = account.id; state.account = account; state.epoch = UUID()
            state.allowMobile = mobile; state.lastHost = lastHost; state.credentialCleanup = retired
            state.lastAttemptSuccessful = previousSuccess
            if fullSync { state.request = .init(notBefore: synchronizationClock(), allowMobile: mobile) }
            try database.execute("DELETE FROM synchronization_outbox")
            try saveSynchronizationState(state)
            try Task.checkCancellation()
            return state.epoch
        }
        synchronizationExecution = nil
        return epoch
    }

    func resetSynchronizationForAuthentication(host: String, expectedEpoch: UUID) throws -> UUID {
        try Task.checkCancellation()
        let epoch = try database.transaction {
            let previous = try synchronizationState()
            guard previous.epoch == expectedEpoch else { throw CancellationError() }
            var state = SynchronizationState()
            state.epoch = UUID(); state.lastHost = host
            state.allowMobile = previous.allowMobile; state.lastAttemptSuccessful = previous.lastAttemptSuccessful
            state.credentialCleanup = previous.credentialCleanup ?? []
            if let id = previous.account?.credentialID { state.credentialCleanup?.append(id) }
            try database.execute("DELETE FROM synchronization_outbox")
            try saveSynchronizationState(state)
            try Task.checkCancellation()
            return state.epoch
        }
        synchronizationExecution = nil
        return epoch
    }

    func replaceSynchronizationCredential(_ account: SynchronizationAccount, previous: SynchronizationAccount) throws {
        try Task.checkCancellation()
        try database.transaction {
            var state = try synchronizationState()
            guard state.account == previous, state.accountID == previous.id else { throw CancellationError() }
            guard (state.credentialCleanup ?? []).contains(account.credentialID) else { throw SynchronizationCredentialError.corrupt }
            state.credentialCleanup = (state.credentialCleanup ?? []).filter { $0 != account.credentialID } + [previous.credentialID]
            state.account = account
            try saveSynchronizationState(state)
            try Task.checkCancellation()
        }
    }

    func acknowledgeSynchronizationCredentialCleanup(_ id: UUID) throws {
        try database.transaction {
            var state = try synchronizationState()
            guard state.account?.credentialID != id else { throw SynchronizationCredentialError.corrupt }
            state.credentialCleanup = (state.credentialCleanup ?? []).filter { $0 != id }
            try saveSynchronizationState(state)
        }
    }
}
