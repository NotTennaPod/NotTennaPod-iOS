import Foundation
import Security
import Synchronization

/// One installation's secrets (PROTOCOL §15.4): its device token and transport nonce, and the device
/// description the token was last registered with (for `PUT /v1/installations/self` after an app update).
/// Logging out removes the token and keeps the nonce, so signing in again resumes the same installation.
public struct ServerInstallationCredential: Codable, Equatable, Sendable {
    public var transportNonce: String
    public var token: String?
    public var device: ServerDevice?
    /// The server refused the token (401 or 403): sync pauses until the person signs in again.
    public var rejected: Bool

    public init(transportNonce: String, token: String? = nil, device: ServerDevice? = nil, rejected: Bool = false) {
        self.transportNonce = transportNonce; self.token = token; self.device = device; self.rejected = rejected
    }

    /// A token the next request may use.
    public var usableToken: String? { rejected ? nil : token }

    private enum CodingKeys: String, CodingKey {
        case token, device, rejected
        case transportNonce = "transport_nonce"
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        transportNonce = try values.decode(String.self, forKey: .transportNonce)
        token = try values.decodeIfPresent(String.self, forKey: .token)
        device = try values.decodeIfPresent(ServerDevice.self, forKey: .device)
        rejected = try values.decodeIfPresent(Bool.self, forKey: .rejected) ?? false
    }
}

/// Where the device marker and the installations' credentials live. The Keychain in the app; memory in tests.
public protocol ServerSecretStore: Sendable {
    /// The device marker (PROTOCOL §15.4): made on first use of server mode; never sent.
    func deviceMarker() throws -> String
    func installation(library: String, install: String) throws -> ServerInstallationCredential?
    func saveInstallation(_ credential: ServerInstallationCredential, library: String, install: String) throws
    func removeInstallation(library: String, install: String) throws
    /// Every installation item of a library (its tokens and nonces), for removal.
    func removeLibrary(_ library: String) throws
    /// The installations of a library that have items.
    func installIDs(of library: String) throws -> [String]
}

public enum ServerSecretStoreError: Error, Equatable, Sendable {
    case keychain(OSStatus)
    case corrupt
}

/// The Keychain items of PROTOCOL §15.4: generic passwords in the data-protection Keychain, never synchronized,
/// `AfterFirstUnlockThisDeviceOnly`, so a backup restored onto another device carries neither the marker nor any
/// installation's token or nonce.
public struct KeychainServerSecrets: ServerSecretStore {
    public static let deviceService = "org.nottennapod.app.server.device"
    public static let tokenService = "org.nottennapod.app.server.token"
    /// `default`, or `UITests-<id>` for a DEBUG test library.
    private let markerAccount: String

    public init(markerAccount: String = "default") { self.markerAccount = markerAccount }

    private func query(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: true]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    private func read(service: String, account: String) throws -> Data? {
        var attributes = query(service: service, account: account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ServerSecretStoreError.keychain(status) }
        guard let data = result as? Data else { throw ServerSecretStoreError.corrupt }
        return data
    }

    private func write(_ data: Data, service: String, account: String) throws {
        let match = query(service: service, account: account)
        let update = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw ServerSecretStoreError.keychain(update) }
        var attributes = match
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw ServerSecretStoreError.keychain(status) }
    }

    private func delete(service: String, account: String) throws {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ServerSecretStoreError.keychain(status) }
    }

    public func deviceMarker() throws -> String {
        if let data = try read(service: Self.deviceService, account: markerAccount) {
            let marker = String(decoding: data, as: UTF8.self)
            guard ContractIdentity.isUUID(marker) else { throw ServerSecretStoreError.corrupt }
            return marker
        }
        let marker = ContractIdentity.randomUUID()
        try write(Data(marker.utf8), service: Self.deviceService, account: markerAccount)
        return marker
    }

    public func installation(library: String, install: String) throws -> ServerInstallationCredential? {
        guard let data = try read(service: Self.tokenService, account: library + "/" + install) else { return nil }
        do { return try JSONDecoder().decode(ServerInstallationCredential.self, from: data) }
        catch { throw ServerSecretStoreError.corrupt }
    }

    public func saveInstallation(_ credential: ServerInstallationCredential, library: String, install: String) throws {
        try write(JSONEncoder().encode(credential), service: Self.tokenService, account: library + "/" + install)
    }

    public func removeInstallation(library: String, install: String) throws {
        try delete(service: Self.tokenService, account: library + "/" + install)
    }

    public func removeLibrary(_ library: String) throws {
        for account in try accounts() where account.hasPrefix(library + "/") {
            try delete(service: Self.tokenService, account: account)
        }
    }

    public func installIDs(of library: String) throws -> [String] {
        try accounts().filter { $0.hasPrefix(library + "/") }.map { String($0.dropFirst(library.count + 1)) }.sorted()
    }

    private func accounts() throws -> [String] {
        var attributes = query(service: Self.tokenService, account: nil)
        attributes[kSecReturnAttributes as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw ServerSecretStoreError.keychain(status) }
        return (result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// An in-memory store for tests.
public final class MemoryServerSecrets: ServerSecretStore {
    private struct State { var marker: String?; var items: [String: ServerInstallationCredential] = [:] }
    private let state: Mutex<State>
    /// `marker`: a device marker already made (a test's second library of the same device).
    public init(marker: String? = nil) { state = Mutex(State(marker: marker)) }

    public var items: [String: ServerInstallationCredential] { state.withLock { $0.items } }
    public func deviceMarker() throws -> String {
        state.withLock { state in
            if let marker = state.marker { return marker }
            let marker = ContractIdentity.randomUUID(); state.marker = marker; return marker
        }
    }
    public func installation(library: String, install: String) throws -> ServerInstallationCredential? {
        state.withLock { $0.items[library + "/" + install] }
    }
    public func saveInstallation(_ credential: ServerInstallationCredential, library: String, install: String) throws {
        state.withLock { $0.items[library + "/" + install] = credential }
    }
    public func removeInstallation(library: String, install: String) throws {
        _ = state.withLock { $0.items.removeValue(forKey: library + "/" + install) }
    }
    public func removeLibrary(_ library: String) throws {
        state.withLock { state in state.items = state.items.filter { !$0.key.hasPrefix(library + "/") } }
    }
    public func installIDs(of library: String) throws -> [String] {
        state.withLock { $0.items.keys.filter { $0.hasPrefix(library + "/") }.map { String($0.dropFirst(library.count + 1)) }.sorted() }
    }
}
