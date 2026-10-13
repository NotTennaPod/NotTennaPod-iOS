import Foundation

/// Feed credentials belong to the stored feed, including its unsubscribed preview.
/// SQLite owns only opaque references. Immutable Keychain entries are staged before
/// selection so interruption and feed deletion leave recoverable cleanup work.
public actor FeedAuthentication {
    private let store: FeedLibraryStore
    private let vault: any SynchronizationCredentialStore
    /// Retired credentials are deleted from the Keychain only under the library gate held exclusively, so an export
    /// collecting its source never finds a credential its feed still named gone (PROTOCOL §11.5).
    private let gate: LibraryGate?
    /// A database import's journal: told each Keychain item this store is about to create, before it is written.
    private let created: (@Sendable (UUID) async throws -> Void)?
    private var tail: Task<Void, Never>?
    /// The Keychain store, for an export that reads its library's credentials by ID under the library gate (PROTOCOL §11.5).
    public nonisolated var credentialStore: any SynchronizationCredentialStore { vault }

    public init(store: FeedLibraryStore, vault: any SynchronizationCredentialStore =
                KeychainSynchronizationCredentials(service: "org.nottennapod.app.feeds"), gate: LibraryGate? = nil,
                created: (@Sendable (UUID) async throws -> Void)? = nil) {
        self.store = store; self.vault = vault; self.gate = gate; self.created = created
        store.adoptCredentialVault(vault)
    }

    public func preparePreview(_ fetched: FetchedFeed, credentials: FeedCredentials, now: Date = Date()) async throws -> LibraryFeed {
        let store = store, vault = vault, gate = gate, created = created
        return try await serial {
            let id = try await Self.stage(credentials, store: store, vault: vault, gate: gate, created: created)
            do {
                let feed = try await store.preparePreview(fetched, now: now, stagedCredentialID: id)
                try? await Self.cleanup(store, vault, gate: gate)
                return feed
            } catch {
                try? await Self.cleanup(store, vault, gate: gate)
                throw error
            }
        }
    }

    public func save(_ credentials: FeedCredentials, feedID: Int64) async throws {
        let store = store, vault = vault, gate = gate, created = created
        try await serial {
            let id = try await Self.stage(credentials, store: store, vault: vault, gate: gate, created: created)
            // In a server library empty credentials are recorded as cleared (`podcast.set_credentials {clear}`).
            let cleared = (credentials.username ?? "").isEmpty && (credentials.password ?? "").isEmpty
            do { try await store.installFeedCredential(id, feedID: feedID, cleared: cleared) }
            catch { try? await Self.cleanup(store, vault, gate: gate); throw error }
            try? await Self.cleanup(store, vault, gate: gate)
        }
    }

    public func credentials(feedID: Int64) async throws -> FeedCredentials? {
        let store = store, vault = vault
        return try await serial {
            guard let id = try await store.feedCredentialID(feedID: feedID) else { return nil }
            let bytes = Data(try vault.password(id: id).utf8)
            let result = try JSONDecoder().decode(FeedCredentials.self, from: bytes)
            guard try await store.feedCredentialID(feedID: feedID) == id else { throw CancellationError() }
            try Task.checkCancellation()
            return result
        }
    }

    /// A staged restore that failed before becoming the live library: remove every Keychain entry it
    /// installed, since the staged library file is deleted and could never retire them.
    public func discardAllCredentials() async throws {
        let store = store, vault = vault
        try await serial {
            for id in try await store.allFeedCredentialIDs() { try vault.remove(id: id) }
            try await store.forgetAllFeedCredentials()
        }
    }

    public func recoverCredentialCleanup() async throws {
        let store = store, vault = vault, gate = gate
        try await serial { try await Self.cleanup(store, vault, gate: gate) }
    }

    private static func stage(_ credentials: FeedCredentials, store: FeedLibraryStore, vault: any SynchronizationCredentialStore,
                              gate: LibraryGate?, created: (@Sendable (UUID) async throws -> Void)?) async throws -> UUID {
        let id = UUID(), value = String(decoding: try JSONEncoder().encode(credentials), as: UTF8.self)
        try await store.stageFeedCredential(id)
        do { try Task.checkCancellation(); try await created?(id); try vault.insert(value, id: id) }
        catch { try? await cleanup(store, vault, gate: gate); throw error }
        return id
    }

    private static func cleanup(_ store: FeedLibraryStore, _ vault: any SynchronizationCredentialStore, gate: LibraryGate?) async throws {
        let pending = try await store.feedCredentialCleanup()
        guard !pending.isEmpty else { return }
        if let gate { await gate.acquireExclusive() }
        defer { gate?.releaseExclusive() }
        for id in pending {
            try Task.checkCancellation()
            try vault.remove(id: id)
            try await store.acknowledgeFeedCredentialCleanup(id)
        }
    }

    private func serial<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { await previous?.value; try Task.checkCancellation(); return try await operation() }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

extension FeedLibraryStore {
    func stageFeedCredential(_ id: UUID) throws {
        try Task.checkCancellation()
        try database.execute("INSERT INTO feed_credential_cleanup VALUES (?)", [.text(id.uuidString)])
    }

    func feedCredentialID(feedID: Int64) throws -> UUID? {
        guard let value = try database.rows("SELECT credential_id FROM feed_credentials WHERE feed_id = ?", [.integer(feedID)]).first?.first else { return nil }
        guard case .text(let text) = value, let id = UUID(uuidString: text) else { throw FeedLibraryError.corruptRecord }
        return id
    }

    func installFeedCredential(_ id: UUID, feedID: Int64, cleared: Bool = false) throws {
        try write(.credentials(cleared: cleared)) { try installFeedCredentialRecord(id, feedID: feedID) }
    }

    /// Caller owns the transaction, allowing preview and credential selection to commit together.
    func installFeedCredentialRecord(_ id: UUID, feedID: Int64) throws {
        try Task.checkCancellation()
        guard try database.scalar("SELECT count(*) FROM feeds WHERE id = ?", [.integer(feedID)]) == 1 else { throw FeedLibraryError.missingFeed(feedID) }
        guard try database.scalar("SELECT count(*) FROM feed_credential_cleanup WHERE credential_id = ?", [.text(id.uuidString)]) == 1 else { throw FeedLibraryError.invalidMutation }
        try captureCredentialWrite(feedID: feedID, credential: id)
        try database.execute("DELETE FROM feed_credentials WHERE feed_id = ?", [.integer(feedID)])
        try database.execute("INSERT INTO feed_credentials VALUES (?, ?)", [.integer(feedID), .text(id.uuidString)])
        try database.execute("DELETE FROM feed_credential_cleanup WHERE credential_id = ?", [.text(id.uuidString)])
        try Task.checkCancellation()
    }

    func allFeedCredentialIDs() throws -> [UUID] {
        // A server library's secrets keep superseded and URL credentials for the library's life (PROTOCOL §15.4): they are the
        // library's too. A standalone library has none.
        try database.rows("SELECT credential_id FROM feed_credentials UNION SELECT credential_id FROM feed_credential_cleanup UNION SELECT credential_id FROM ntp_secrets").map {
            guard case .text(let text) = $0[0], let id = UUID(uuidString: text) else { throw FeedLibraryError.corruptRecord }
            return id
        }
    }

    func forgetAllFeedCredentials() throws {
        try write(.local) {
            try database.execute("DELETE FROM feed_credentials")
            try database.execute("DELETE FROM feed_credential_cleanup")
            try database.execute("DELETE FROM ntp_secrets")
        }
    }

    func feedCredentialCleanup() throws -> [UUID] {
        try database.rows("SELECT credential_id FROM feed_credential_cleanup").map {
            guard case .text(let text) = $0[0], let id = UUID(uuidString: text) else { throw FeedLibraryError.corruptRecord }
            return id
        }
    }

    func acknowledgeFeedCredentialCleanup(_ id: UUID) throws {
        try database.execute("DELETE FROM feed_credential_cleanup WHERE credential_id = ?", [.text(id.uuidString)])
    }
}
