import Foundation
import Testing
@testable import NotTennaPodCore

/// Recovery's phones (PROTOCOL §6.10): a server library on a device of its own, with that device's Keychain (a
/// `MemoryServerSecrets`: the device marker, each installation's token and transport nonce) and an engine that
/// detects copies, takes new installations and recovers after a restore. The engine's token is the one the Keychain
/// holds for the library's current installation, read at every request, as in the app.
final class DevicePhone: @unchecked Sendable {
    let name: String
    let libraryID: String
    let location: LibraryLocation
    let secrets: MemoryServerSecrets
    let vault: MemoryCredentialVault
    let transport: ProxyTransport
    let server: ExchangeServer
    private let box: StoreBox
    private(set) var engine: ServerSyncEngine
    let playing = PlayingFlag()
    /// A scene of the app is in the foreground (someone may be using it), and the transitions a test makes.
    let foreground = PlayingFlag()
    let eligibility = ServerPublicationEligibility()
    /// The engine's clock: a test moves it on (the recovery's waiting bound).
    let clock = ClockBox()
    var store: FeedLibraryStore { box.store }

    final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var offset: TimeInterval = 0
        var now: Date { lock.withLock { Date().addingTimeInterval(offset) } }
        func advance(_ seconds: TimeInterval) { lock.withLock { offset += seconds } }
    }

    static let device = ServerDevice(name: "NotTennaPod on iPhone", appVersion: "test")

    final class StoreBox: @unchecked Sendable {
        private let lock = NSLock()
        private var current: FeedLibraryStore
        init(_ store: FeedLibraryStore) { current = store }
        var store: FeedLibraryStore {
            get { lock.withLock { current } }
            set { lock.withLock { current = newValue } }
        }
    }

    private init(name: String, libraryID: String, location: LibraryLocation, secrets: MemoryServerSecrets, vault: MemoryCredentialVault,
                 server: ExchangeServer) throws {
        self.name = name; self.libraryID = libraryID; self.location = location; self.secrets = secrets; self.vault = vault
        self.server = server
        box = StoreBox(try FeedLibraryStore(url: location.database))
        let box = box
        transport = ProxyTransport(HTTPServerExchangeTransport(base: server.base, token: {
            guard let install = try await box.store.serverInstallationID() else { return nil }
            return try secrets.installation(library: libraryID, install: install)?.usableToken
        }))
        engine = try Self.engine(box.store, location: location, transport: transport, vault: vault, secrets: secrets, libraryID: libraryID,
                                 playing: playing, foreground: foreground, eligibility: eligibility, clock: clock)
    }

    private static func engine(_ store: FeedLibraryStore, location: LibraryLocation, transport: ProxyTransport, vault: MemoryCredentialVault,
                               secrets: MemoryServerSecrets, libraryID: String, playing: PlayingFlag, foreground: PlayingFlag,
                               eligibility: ServerPublicationEligibility, clock: ClockBox) throws -> ServerSyncEngine {
        try ServerSyncEngine(store: store, location: location, transport: transport, vault: vault, clock: { clock.now }, isPlaying: { playing.value },
                             isForeground: { foreground.value }, eligibility: eligibility,
                             installations: ServerInstallationKeychain(libraryID: libraryID, secrets: secrets, device: device))
    }

    /// A new phone (a device of its own): an installation signed in, its library provisioned and attached.
    static func attach(_ world: ExchangeWorld, name: String) async throws -> DevicePhone {
        let secrets = MemoryServerSecrets()
        let nonce = ContractIdentity.randomUUID()
        let installation = try await world.server.signIn(nonce: nonce)
        let token = installation.client.token ?? ""
        let libraryID = ContractIdentity.randomUUID()
        let root = world.root.appendingPathComponent("device-\(name)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let location = LibraryLocation(root: root, reference: .server(libraryID))
        try location.prepare()
        let provisioning = try FeedLibraryStore(url: location.database)
        try await provisioning.initializeServerLibrary(ServerLibraryIdentity(
            libraryID: libraryID, serverURL: world.server.base.absoluteString, serverID: "test", accountID: installation.accountID,
            namespace: installation.namespace, username: "alice", installID: installation.installID, deviceMarker: try secrets.deviceMarker()))
        try await provisioning.close()
        try secrets.saveInstallation(.init(transportNonce: nonce, token: token, device: device), library: libraryID, install: installation.installID)
        let client = ServerClient(address: ServerAddress(entered: world.server.base.absoluteString)!)
        let snapshot = try await ServerAttachSnapshotDownload(client: client, token: token, installID: installation.installID,
                                                              folder: location.staging!.appendingPathComponent("attach")).run()
        let vault = MemoryCredentialVault()
        let transport = ProxyTransport(HTTPServerExchangeTransport(base: world.server.base, token: { token }))
        try await ServerExchangeAttachApplier(vault: { vault }, transport: { _ in transport })
            .apply(snapshot, to: ServerAttachmentTarget(location: location, libraryID: libraryID, installID: installation.installID,
                                                        token: token, client: client))
        return try DevicePhone(name: name, libraryID: libraryID, location: location, secrets: secrets, vault: vault, server: world.server)
    }

    /// Where a copy's Keychain comes from.
    enum CopiedKeychain {
        /// Another device's: nothing of this one's (`ThisDeviceOnly`), the normal copy.
        case fresh
        /// This device's marker and tokens, which no device backup can make: two working libraries on one transport
        /// (PROTOCOL §6.10–c), never detected locally.
        case same
        /// This device's tokens under another marker (the marker lost): detected, with a working token (PROTOCOL §6.10).
        case tokens
    }

    /// A phone backup of this library restored onto another device (a copy, PROTOCOL §6.10): the folder as it is on disk now,
    /// copied while this library is closed.
    func copy(_ name: String, root: URL, keychain kind: CopiedKeychain = .fresh) async throws -> DevicePhone {
        await engine.close()
        try await store.close()
        let device = root.appendingPathComponent("device-\(name)-\(UUID().uuidString.prefix(8))")
        let target = LibraryLocation(root: device, reference: .server(libraryID))
        try FileManager.default.createDirectory(at: target.folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: location.folder, to: target.folder)
        try reopen()
        var keychain = MemoryServerSecrets()
        if kind != .fresh {
            keychain = MemoryServerSecrets(marker: kind == .same ? try secrets.deviceMarker() : nil)
            for install in try secrets.installIDs(of: libraryID) {
                if let item = try secrets.installation(library: libraryID, install: install) {
                    try keychain.saveInstallation(item, library: libraryID, install: install)
                }
            }
        }
        return try DevicePhone(name: name, libraryID: libraryID, location: target, secrets: keychain, vault: vault, server: server)
    }

    private func reopen() throws {
        box.store = try FeedLibraryStore(url: location.database)
        engine = try Self.engine(box.store, location: location, transport: transport, vault: vault, secrets: secrets, libraryID: libraryID,
                                 playing: playing, foreground: foreground, eligibility: eligibility, clock: clock)
    }

    /// Closes and reopens the store and engine (a relaunch).
    func relaunch() async throws {
        await engine.close()
        try await store.close()
        try reopen()
    }

    func close() async {
        await engine.close()
        try? await store.close()
    }

    /// "Sign in again" as `ServerAccounts.signInAgain` does it (PROTOCOL §15.4): the library's own installation, or while a
    /// transition is planned and the predecessor was replaced, its successor; the token saved under the installation
    /// that signed in.
    @discardableResult
    func signInAgain(password: String = "alice-password-1") async throws -> String {
        var targets = try StoreServerLibraryProvisioning().signInInstallations(of: location)
        let client = ServerClient(address: ServerAddress(entered: server.base.absoluteString)!)
        var index = 0
        while index < targets.count {
            let target = targets[index]
            index += 1
            let saved = try secrets.installation(library: libraryID, install: target.installID)?.transportNonce
            let nonce = target.transportNonce ?? saved ?? ContractIdentity.randomUUID()
            do {
                let answer = try await client.signIn(username: "alice", password: password, installID: target.installID,
                                                     transportNonce: nonce, device: Self.device)
                try secrets.saveInstallation(.init(transportNonce: nonce, token: answer.token, device: Self.device), library: libraryID,
                                             install: target.installID)
                try await engine.resume()
                return target.installID
            } catch let error as ServerClientError where error == .installationSuperseded || error == .installationConflict {
                if index == targets.count, let fresh = await engine.planNewInstallation(), !targets.contains(fresh) { targets.append(fresh) }
                if index == targets.count { throw error }
            }
        }
        throw HarnessError.server("nothing to sign in with")
    }

    /// A full exchange; fails the test on a pause or an unexpected error.
    @discardableResult
    func exchange(sourceLocation: SourceLocation = #_sourceLocation) async -> ServerExchangeReport {
        let report = await engine.exchange()
        #expect(report.error == nil, "\(name): \(report.error ?? "")", sourceLocation: sourceLocation)
        #expect(report.pause == nil, "\(name): paused \(String(describing: report.pause))", sourceLocation: sourceLocation)
        return report
    }

    func rows(_ sql: String) throws -> [[String?]] { try ServerLibraryFixture.read(location.database, sql) }
    func view() async throws -> SyncedView { try await store.syncedViewForTesting() }
    func installID() async throws -> String { try #require(try await store.serverInstallationID()) }
    func log() async throws -> [(time: Int64, kind: String, detail: String)] { try await engine.logEntries() }
}

/// Recovery's world: the exchange world's server and feeds, with phones on devices of their own.
extension ExchangeWorld {
    func device(_ name: String) async throws -> DevicePhone { try await DevicePhone.attach(self, name: name) }

    /// Exchanges every phone twice, then checks each equals a fresh attachment's view (nothing lost or applied twice).
    func converge(_ phones: [DevicePhone], _ label: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<2 { for phone in phones { await phone.exchange(sourceLocation: sourceLocation) } }
        let fresh = try await attach("fresh-\(label)")
        let expected = try await fresh.view()
        for phone in phones {
            let differences = try await phone.view().withoutTitles.differences(from: expected.withoutTitles)
            #expect(differences.isEmpty, "\(label): \(phone.name) differs from a fresh attach:\n\(differences.joined(separator: "\n"))",
                    sourceLocation: sourceLocation)
            #expect(try await phone.store.serverUnsentChanges() == 0, "\(label): \(phone.name) has nothing unsent", sourceLocation: sourceLocation)
        }
        await fresh.close()
    }

    /// The server's key bundle exported and a backup taken with the server stopped (PROTOCOL §11), then the server started again.
    func backUp() async throws -> URL {
        let keys = root.appendingPathComponent("keys.bundle"), backups = root.appendingPathComponent("backups-\(UUID().uuidString.prefix(8))")
        let passphrase = root.appendingPathComponent("passphrase")
        try Data("a test passphrase\n".utf8).write(to: passphrase)
        server.stop(keepingData: true)
        if !FileManager.default.fileExists(atPath: keys.path) {
            _ = try server.command(["keys", "export", "--data-dir", server.data.path, "--out", keys.path, "--passphrase-file", passphrase.path])
        }
        _ = try server.command(["backup", "--data-dir", server.data.path, "--out", backups.path])
        try await server.launch()
        return try #require(try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).first)
    }

    /// The server restored from `backup` with the server stopped (PROTOCOL §11): every token is gone, the epoch moves on.
    func restore(_ backup: URL) async throws {
        server.stop(keepingData: true)
        _ = try server.command(["restore", "--data-dir", server.data.path, "--from", backup.path, "--keys",
                                root.appendingPathComponent("keys.bundle").path, "--passphrase-file", root.appendingPathComponent("passphrase").path])
        try await server.launch()
    }
}
