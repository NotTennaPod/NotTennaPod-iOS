import Foundation
import Security

public protocol ProxyPreferencePersistence: Sendable {
    func load() throws -> PodcastProxy?
    func save(_ configuration: PodcastProxy) throws
}

/// Atomically stores the complete configuration in the app's Keychain namespace;
/// the password is never copied into a preferences JSON file or diagnostic log.
public struct KeychainProxyPreferences: ProxyPreferencePersistence {
    private let account: String
    public init(account: String = "default") { self.account = account }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "org.nottennapod.app.proxy", kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: true]
    }
    public func load() throws -> PodcastProxy? {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SynchronizationCredentialError.keychain(status) }
        guard let data = result as? Data else { throw SynchronizationCredentialError.corrupt }
        return try JSONDecoder().decode(PodcastProxy.self, from: data)
    }
    public func save(_ configuration: PodcastProxy) throws {
        let data = try JSONEncoder().encode(configuration)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let inserted = SecItemAdd(attributes as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw SynchronizationCredentialError.keychain(inserted) }
        } else if status != errSecSuccess { throw SynchronizationCredentialError.keychain(status) }
    }
}

@MainActor public final class ProxyPreferenceStore {
    public private(set) var value: PodcastProxy
    private let persistence: any ProxyPreferencePersistence
    /// Source Reset updates stored/new-builder configuration; confirmed OK also
    /// reinitializes the shared client. Recipients choose their matching lifetime.
    public var onChange: ((PodcastProxy, Bool) -> Void)?
    public init(persistence: any ProxyPreferencePersistence = KeychainProxyPreferences()) throws {
        self.persistence = persistence; value = try persistence.load() ?? .init()
    }
    public func update(_ value: PodcastProxy, reinitializeShared: Bool) throws {
        try persistence.save(value)
        self.value = value
        onChange?(value, reinitializeShared)
    }
}
