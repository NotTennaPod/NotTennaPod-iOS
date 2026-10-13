import Foundation
import Security

/// The service namespace is app-owned; account names are opaque UUIDs. No
/// internet-password matching, shared cookies or iCloud synchronization occurs.
public struct KeychainSynchronizationCredentials: SynchronizationCredentialStore {
    private let service: String
    public init(service: String = "org.nottennapod.app.synchronization") { self.service = service }

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString, kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }
    public func insert(_ password: String, id: UUID) throws {
        var attributes = query(id)
        attributes[kSecValueData as String] = Data(password.utf8)
        // Allows background synchronization after the first unlock, including
        // encrypted device migration without placing tokens in library backups.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw SynchronizationCredentialError.keychain(status) }
    }
    public func password(id: UUID) throws -> String {
        var attributes = query(id)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { throw SynchronizationCredentialError.missing }
        guard status == errSecSuccess else { throw SynchronizationCredentialError.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw SynchronizationCredentialError.corrupt }
        return value
    }
    public func remove(id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SynchronizationCredentialError.keychain(status) }
    }
}
