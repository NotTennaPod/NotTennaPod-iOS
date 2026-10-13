import XCTest
import Security
@testable import NotTennaPodCore

final class SynchronizationKeychainTests: XCTestCase {
    func testImmutableSecretSurvivesNewAdapterAndIsolatedNamespaces() throws {
        let service = "org.nottennapod.app.tests.\(UUID())", id = UUID()
        let first = KeychainSynchronizationCredentials(service: service)
        let second = KeychainSynchronizationCredentials(service: service + ".other")
        defer { try? first.remove(id: id); try? second.remove(id: id) }
        try first.insert("fixture-ü🔑", id: id)
        XCTAssertThrowsError(try first.insert("must-not-overwrite", id: id)) {
            XCTAssertEqual($0 as? SynchronizationCredentialError, .keychain(errSecDuplicateItem))
        }
        XCTAssertEqual(try KeychainSynchronizationCredentials(service: service).password(id: id), "fixture-ü🔑")
        XCTAssertThrowsError(try second.password(id: id)) { XCTAssertEqual($0 as? SynchronizationCredentialError, .missing) }
        try second.insert("other", id: id)
        try first.remove(id: id)
        try first.remove(id: id)
        XCTAssertThrowsError(try first.password(id: id)) { XCTAssertEqual($0 as? SynchronizationCredentialError, .missing) }
        XCTAssertEqual(try second.password(id: id), "other")
    }

    func testBackgroundAccessibilityAndNoCloudSynchronization() throws {
        let service = "org.nottennapod.app.tests.\(UUID())", id = UUID()
        let vault = KeychainSynchronizationCredentials(service: service)
        defer { try? vault.remove(id: id) }
        try vault.insert("", id: id)
        XCTAssertEqual(try vault.password(id: id), "")
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString,
            kSecReturnAttributes as String: true, kSecUseDataProtectionKeychain as String: true]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlock as String)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testCorruptSecretIsReportedWithoutFallbackOrMutation() throws {
        let service = "org.nottennapod.app.tests.\(UUID())", id = UUID()
        let vault = KeychainSynchronizationCredentials(service: service)
        defer { try? vault.remove(id: id) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString,
            kSecUseDataProtectionKeychain as String: true, kSecValueData as String: Data([0xff, 0xfe])]
        XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)
        XCTAssertThrowsError(try vault.password(id: id)) { XCTAssertEqual($0 as? SynchronizationCredentialError, .corrupt) }
        XCTAssertThrowsError(try vault.insert("replace", id: id)) { XCTAssertEqual($0 as? SynchronizationCredentialError, .keychain(errSecDuplicateItem)) }
    }

    func testRealKeychainAccountPasswordChangeAndLogout() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyncKeychain-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let vault = KeychainSynchronizationCredentials(service: "org.nottennapod.app.tests.\(UUID())")
        let store = try FeedLibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        let accounts = SynchronizationAccounts(store: store, credentials: vault)
        let profile = SynchronizationAccount(backend: .gpodder, host: "https://example.test", username: "fixture", device: "phone")
        var changed: SynchronizationAccount?
        defer { try? vault.remove(id: profile.credentialID); if let changed { try? vault.remove(id: changed.credentialID) } }
        do {
            try await accounts.connect(profile, password: "first", fullSync: true)
            let before = try await store.synchronizationState()
            try await accounts.changePassword("second")
            let after = try await store.synchronizationState()
            changed = try XCTUnwrap(after.account)
            XCTAssertEqual(after.request, before.request)
            XCTAssertEqual(after.epoch, before.epoch)
            XCTAssertEqual(try vault.password(id: changed!.credentialID), "second")
            XCTAssertThrowsError(try vault.password(id: profile.credentialID))
            _ = try await accounts.provider(accountID: profile.id)
            try await accounts.disconnect()
            let disconnected = try await store.synchronizationState()
            XCTAssertNil(disconnected.accountID)
            XCTAssertEqual(disconnected.credentialCleanup, [])
            XCTAssertThrowsError(try vault.password(id: changed!.credentialID))
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
}
