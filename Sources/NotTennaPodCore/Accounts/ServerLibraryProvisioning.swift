import Foundation

/// A first attachment's new library (PROTOCOL §15.4).
public struct ServerLibraryProvision: Equatable, Sendable {
    public var libraryID: String
    public var serverURL: String
    public var serverID: String
    public var accountID: String
    public var namespace: String
    public var username: String
    public var installID: String
    public var deviceMarker: String

    public init(libraryID: String, serverURL: String, serverID: String, accountID: String, namespace: String,
                username: String, installID: String, deviceMarker: String) {
        self.libraryID = libraryID; self.serverURL = serverURL; self.serverID = serverID; self.accountID = accountID
        self.namespace = namespace; self.username = username; self.installID = installID; self.deviceMarker = deviceMarker
    }
}

/// An installation "Sign in again" may sign in with (PROTOCOL §15.4).
public struct ServerSignInInstallation: Equatable, Sendable {
    public var installID: String
    /// The nonce a planned transition chose; nil: the installation's own, from the Keychain.
    public var transportNonce: String?
    public init(installID: String, transportNonce: String? = nil) { self.installID = installID; self.transportNonce = transportNonce }
}

/// What the account service reads and writes in a server library's database (`ntp_library` and its outbox), kept
/// behind one seam so tests can count unsent changes without a recorder.
public protocol ServerLibraryProvisioning: Sendable {
    /// Creates the library's database as a server library (schema 19, its `ntp_library` row and main author), or
    /// leaves one an earlier attempt created. Never touches the live library.
    func provision(_ location: LibraryLocation, _ provision: ServerLibraryProvision) async throws
    /// The installation the library's `ntp_library` names; nil when the library has no database or row yet.
    func installID(of location: LibraryLocation) throws -> String?
    /// The installations "Sign in again" signs in with, in order, each with the transport nonce a planned transition
    /// chose for it (nil: the one the Keychain holds): the library's own; and while an installation transition is
    /// planned, its successor `T'`, first when the predecessor can no longer authorize one (PROTOCOL §6.10).
    func signInInstallations(of location: LibraryLocation) throws -> [ServerSignInInstallation]
    /// Changes that have not reached the server: unreceipted outbox entries and drafts.
    func unsentChanges(of location: LibraryLocation) throws -> Int
    /// Removes the library's feed credentials from the Keychain (`FeedAuthentication.discardAllCredentials` on that
    /// library), before its folder is deleted. The library is not open.
    func discardFeedCredentials(of location: LibraryLocation) async throws
}

/// The app's provisioning: the library's own `FeedLibraryStore` for writes, short read-only connections for reads.
public struct StoreServerLibraryProvisioning: ServerLibraryProvisioning {
    private let feedVault: @Sendable () -> any SynchronizationCredentialStore

    public init(feedVault: @escaping @Sendable () -> any SynchronizationCredentialStore = {
        KeychainSynchronizationCredentials(service: "org.nottennapod.app.feeds")
    }) {
        self.feedVault = feedVault
    }

    public func provision(_ location: LibraryLocation, _ provision: ServerLibraryProvision) async throws {
        try location.prepare()
        let store = try FeedLibraryStore(url: location.database)
        do {
            if await !store.isServerLibrary {
                try await store.initializeServerLibrary(ServerLibraryIdentity(
                    libraryID: provision.libraryID, serverURL: provision.serverURL, serverID: provision.serverID,
                    accountID: provision.accountID, namespace: provision.namespace, username: provision.username,
                    installID: provision.installID, deviceMarker: provision.deviceMarker))
            }
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    public func installID(of location: LibraryLocation) throws -> String? {
        try read(location) { connection in
            guard try hasTable("ntp_library", connection) else { return nil }
            guard case .text(let id)? = try connection.rows("SELECT install_id FROM ntp_library WHERE id = 1").first?.first else { return nil }
            return id
        }
    }

    public func signInInstallations(of location: LibraryLocation) throws -> [ServerSignInInstallation] {
        try read(location) { connection -> [ServerSignInInstallation]? in
            guard try hasTable("ntp_library", connection),
                  let row = try connection.rows("SELECT install_id, transition FROM ntp_library WHERE id = 1").first, let install = row[0].text else { return nil }
            let own = ServerSignInInstallation(installID: install)
            guard let data = row[1].data, let plan = try? JSONDecoder().decode(ServerInstallationTransition.self, from: data) else { return [own] }
            let successor = ServerSignInInstallation(installID: plan.installID, transportNonce: plan.transportNonce)
            return plan.signInWithSuccessor ? [successor] : [own, successor]
        } ?? []
    }

    public func unsentChanges(of location: LibraryLocation) throws -> Int {
        try read(location) { connection in
            var count: Int64 = 0
            if try hasTable("ntp_outbox", connection) { count += try connection.scalar("SELECT count(*) FROM ntp_outbox WHERE receipt IS NULL") }
            if try hasTable("ntp_drafts", connection) { count += try connection.scalar("SELECT count(*) FROM ntp_drafts") }
            // Facts parked behind changes another device may restore (PROTOCOL §6.11) are not sent yet either.
            if try hasTable("ntp_retained", connection) {
                count += try connection.scalar("SELECT count(*) FROM ntp_retained WHERE CAST(lineage AS TEXT) LIKE '%\"parked\"%'")
            }
            return Int(count)
        } ?? 0
    }

    public func discardFeedCredentials(of location: LibraryLocation) async throws {
        guard !LibraryLocation.isAbsent(location.database) else { return }
        // Credentials kept for recovery after their feed retired them are listed only in `ntp_secrets` (PROTOCOL §15.4).
        let retained: [UUID] = try read(location) { connection in
            guard try hasTable("ntp_secrets", connection) else { return [] }
            return try connection.rows("SELECT credential_id FROM ntp_secrets").compactMap { row in
                guard case .text(let text)? = row.first else { return nil }
                return UUID(uuidString: text)
            }
        } ?? []
        let vault = feedVault()
        let store = try FeedLibraryStore(url: location.database)
        do {
            try await FeedAuthentication(store: store, vault: vault).discardAllCredentials()
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
        for id in retained { try vault.remove(id: id) }
    }

    private func read<T>(_ location: LibraryLocation, _ body: (LibrarySQLite) throws -> T?) throws -> T? {
        guard !LibraryLocation.isAbsent(location.database) else { return nil }
        let connection = try LibrarySQLite(readingOnly: location.database)
        defer { try? connection.close() }
        return try connection.transaction(write: false) { try body(connection) }
    }

    private func hasTable(_ name: String, _ connection: LibrarySQLite) throws -> Bool {
        try connection.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(name)]) == 1
    }
}
