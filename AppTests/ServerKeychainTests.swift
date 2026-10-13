import Foundation
import Security
import Testing
@testable import NotTennaPodCore

/// The server-mode Keychain items (PROTOCOL §15.4) in the real data-protection Keychain: the device marker and each
/// installation's token and transport nonce, as non-synchronizable `AfterFirstUnlockThisDeviceOnly` generic passwords
/// under their own services. Every item a test makes is removed again.
@Suite(.serialized) struct ServerKeychainTests {
    private func attributes(service: String, account: String) -> [String: Any]? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? [String: Any]
    }

    private func deleteMarker(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: KeychainServerSecrets.deviceService,
                       kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true] as CFDictionary)
    }

    @Test func theDeviceMarkerIsMadeOnceAndStaysOnThisDevice() throws {
        let account = "UITests-\(UUID().uuidString)"
        defer { deleteMarker(account) }
        let secrets = KeychainServerSecrets(markerAccount: account)
        let marker = try secrets.deviceMarker()
        #expect(ContractIdentity.isUUID(marker))
        #expect(try secrets.deviceMarker() == marker, "kept across reads")
        let otherAccount = "UITests-\(UUID().uuidString)"
        defer { deleteMarker(otherAccount) }
        #expect(try KeychainServerSecrets(markerAccount: otherAccount).deviceMarker() != marker, "each test library has its own")
        let item = try #require(attributes(service: "org.nottennapod.app.server.device", account: account))
        #expect(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect((item[kSecAttrSynchronizable as String] as? Bool ?? false) == false)
    }

    @Test func installationsAreKeptPerLibraryAndInstallationAndRemovedWithTheirLibrary() throws {
        let secrets = KeychainServerSecrets(markerAccount: "UITests-\(UUID().uuidString)")
        let library = ContractIdentity.randomUUID(), other = ContractIdentity.randomUUID()
        let first = ContractIdentity.randomUUID(), successor = ContractIdentity.randomUUID()
        defer { try? secrets.removeLibrary(library); try? secrets.removeLibrary(other) }
        let device = ServerDevice(name: "NotTennaPod on iPhone", appVersion: "1.0 (1)")
        try secrets.saveInstallation(.init(transportNonce: "n1", token: "ntp1_a", device: device), library: library, install: first)
        try secrets.saveInstallation(.init(transportNonce: "n2", token: "ntp1_b"), library: library, install: successor)
        try secrets.saveInstallation(.init(transportNonce: "n3", token: "ntp1_c"), library: other, install: first)
        // A successor's token never replaces its predecessor's (PROTOCOL §15.4).
        #expect(try secrets.installation(library: library, install: first) == .init(transportNonce: "n1", token: "ntp1_a", device: device))
        #expect(try secrets.installation(library: library, install: successor)?.token == "ntp1_b")
        #expect(try secrets.installIDs(of: library) == [first, successor].sorted())
        let item = try #require(attributes(service: "org.nottennapod.app.server.token", account: "\(library)/\(first)"))
        #expect(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        // Logout keeps the nonce and forgets the token; an update keeps the item's protection.
        try secrets.saveInstallation(.init(transportNonce: "n1"), library: library, install: first)
        #expect(try secrets.installation(library: library, install: first) == .init(transportNonce: "n1"))
        #expect(try secrets.installation(library: library, install: first)?.usableToken == nil)
        // Removing a library removes only its own items.
        try secrets.removeLibrary(library)
        #expect(try secrets.installIDs(of: library).isEmpty)
        #expect(try secrets.installation(library: other, install: first)?.token == "ntp1_c")
        try secrets.removeInstallation(library: other, install: first)
        #expect(try secrets.installation(library: other, install: first) == nil)
    }
}
