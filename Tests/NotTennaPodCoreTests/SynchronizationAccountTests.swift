import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.timeLimit(.minutes(1)))
struct SynchronizationAccountTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func fixture(_ body: (FeedLibraryStore, URL, AccountTestCredentials, SynchronizationAccounts) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyncAccounts-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: file, synchronizationClock: { now })
        let vault = AccountTestCredentials(), accounts = SynchronizationAccounts(store: store, credentials: vault)
        do { try await body(store, file, vault, accounts); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    private func profile(_ backend: SynchronizationHTTPClient.Backend = .gpodder) -> SynchronizationAccount {
        .init(backend: backend, host: "https://sync.example.test/base", username: "sync-user", device: "phone")
    }

    @Test func connectedProfileSurvivesReopenWithoutPasswordInLibraryAndCapturesFullSyncPolicy() async throws {
        try await fixture { store, file, vault, accounts in
            try await store.setSynchronizationMobileAllowed(true)
            let account = profile(.nextcloud), secret = "fixture-secret-\(UUID())"
            try await accounts.connect(account, password: secret, fullSync: true)
            let state = try await store.synchronizationState()
            #expect(state.account == account && state.accountID == account.id)
            #expect(state.request?.notBefore == now && state.request?.network == .connected)
            #expect(state.subscriptionTimestamp == 0 && state.episodeTimestamp == 0)
            #expect(state.credentialCleanup == [] && state.lastHost == account.host)
            #expect(try vault.password(id: account.credentialID) == secret)
            let reopened = try FeedLibraryStore(url: file)
            #expect(try await reopened.synchronizationState() == state)
            try await reopened.close()
            let secretBytes = Data(secret.utf8)
            // The primary database must be readable for this privacy check to
            // count. Optional SQLite sidecars may be absent after checkpointing.
            #expect(try Data(contentsOf: file).range(of: secretBytes) == nil)
            for candidate in [URL(filePath: file.path + "-wal"), URL(filePath: file.path + "-shm")]
                where FileManager.default.fileExists(atPath: candidate.path) {
                #expect(try Data(contentsOf: candidate).range(of: secretBytes) == nil)
            }
        }
    }

    @Test func gpodderConnectionDefersSyncUntilFinishAndPasswordEditPreservesWork() async throws {
        try await fixture { store, _, vault, accounts in
            let account = profile()
            try await accounts.connect(account, password: "before", fullSync: false)
            #expect(try await store.synchronizationState().request == nil)
            let request = try #require(await store.requestSynchronization(immediately: true, now: now))
            let initial = try await store.beginSynchronization(request, now: now)
            try await store.acknowledgeSynchronization(epoch: initial.epoch, phase: .subscriptions, ids: [], timestamp: 123)
            _ = try await store.insert(.init(feed: .init(format: .rss, title: "Queued feed", episodes: []),
                source: "https://feed.example.test/rss", responseURL: URL(string: "https://feed.example.test/rss")!, validator: nil, permanentRedirectURL: nil))
            let queued = try await store.synchronizationQueue()
            #expect(queued.count == 1)
            let before = try await store.synchronizationState()
            try await accounts.changePassword("after")
            var expected = before
            let after = try await store.synchronizationState(), changed = try #require(after.account)
            expected.account = changed; expected.credentialCleanup = []
            #expect(after == expected)
            #expect(try await store.synchronizationQueue() == queued)
            #expect(changed.id == account.id && changed.credentialID != account.credentialID)
            // Only credential identity may change; do not derive the expected
            // account metadata from the password edit's actual result.
            #expect(changed.backend == account.backend && changed.host == account.host)
            #expect(changed.username == account.username && changed.device == account.device)
            #expect(try vault.password(id: changed.credentialID) == "after")
            #expect(throws: SynchronizationCredentialError.missing) { try vault.password(id: account.credentialID) }
            await store.releaseSynchronizationExecution(request)
        }
    }

    @Test func disconnectRetiresSecretsKeepsHostAndMobileAndInvalidatesOldWorker() async throws {
        try await fixture { store, _, vault, accounts in
            let account = profile()
            try await accounts.connect(account, password: "fixture", fullSync: true)
            try await store.setSynchronizationMobileAllowed(true)
            let request = try #require(await store.synchronizationState().request)
            let before = try await store.beginSynchronization(request)
            try await accounts.disconnect()
            let after = try await store.synchronizationState()
            #expect(after.account == nil && after.accountID == nil && after.request == nil)
            #expect(after.allowMobile && after.lastHost == account.host && after.epoch != before.epoch)
            #expect(vault.values.isEmpty)
            await #expect(throws: CancellationError.self) { try await accounts.provider(accountID: account.id) }
            await #expect(throws: CancellationError.self) { try await store.acknowledgeSynchronization(epoch: before.epoch, phase: .episodes, ids: [], timestamp: 9) }
            try await accounts.disconnect()
        }
    }

    @Test func failedSecretWritePreservesSelectedProfileAndRequest() async throws {
        try await fixture { store, _, vault, accounts in
            let original = profile(); try await accounts.connect(original, password: "original", fullSync: true)
            let before = try await store.synchronizationState()
            vault.failInsert = true
            await #expect(throws: SynchronizationCredentialError.keychain(-1)) { try await accounts.connect(profile(.nextcloud), password: "new", fullSync: true) }
            #expect(try await store.synchronizationState() == before)
            #expect(vault.values == [original.credentialID: "original"])
        }
    }

    @Test func failedDatabaseSelectionRemovesStagedSecretAndPreservesOldState() async throws {
        try await fixture { store, file, vault, accounts in
            let original = profile(); try await accounts.connect(original, password: "original", fullSync: true)
            let before = try await store.synchronizationState(), next = profile(.nextcloud)
            let db = try LibrarySQLite(url: file)
            try db.execute("CREATE TRIGGER reject_account BEFORE UPDATE ON synchronization_state WHEN CAST(NEW.record AS TEXT) LIKE '%\(next.id.uuidString)%' BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            await #expect(throws: FeedLibraryError.self) { try await accounts.connect(next, password: "new", fullSync: true) }
            #expect(try await store.synchronizationState() == before)
            #expect(vault.values == [original.credentialID: "original"])
            try db.close()
        }
    }

    @Test func cleanupFailuresAreDurableAndDoNotUndoSuccessfulAccountSwitch() async throws {
        try await fixture { store, file, vault, accounts in
            let original = profile(); try await accounts.connect(original, password: "original", fullSync: true)
            let oldRequest = try #require(await store.synchronizationState().request)
            let active = try await store.beginSynchronization(oldRequest, now: now)
            try await store.acknowledgeSynchronization(epoch: active.epoch, phase: .episodes, ids: [], timestamp: 123)
            try await store.finishSynchronization(oldRequest, epoch: active.epoch, successful: true)
            _ = try await store.insert(.init(feed: .init(format: .rss, title: "Queued feed", episodes: []),
                source: "https://feed.example.test/rss", responseURL: URL(string: "https://feed.example.test/rss")!, validator: nil, permanentRedirectURL: nil))
            #expect(try await store.synchronizationQueue().count == 1)
            vault.failRemove = true
            let next = profile(.nextcloud); try await accounts.connect(next, password: "new", fullSync: true)
            let switched = try await store.synchronizationState()
            #expect(switched.account == next && switched.lastAttemptSuccessful && switched.lastAttempt == nil)
            #expect(switched.subscriptionTimestamp == 0 && switched.episodeTimestamp == 0)
            #expect(try await store.synchronizationQueue().isEmpty)
            #expect(try await store.synchronizationState().credentialCleanup == [original.credentialID])
            await #expect(throws: SynchronizationCredentialError.keychain(-2)) { try await accounts.recoverCredentialCleanup() }
            vault.failRemove = false
            let reopened = try FeedLibraryStore(url: file)
            try await SynchronizationAccounts(store: reopened, credentials: vault).recoverCredentialCleanup()
            #expect(try await reopened.synchronizationState().credentialCleanup == [])
            #expect(vault.values == [next.credentialID: "new"])
            try await reopened.close()
            try await accounts.disconnect()
            #expect(try await store.synchronizationState().lastAttemptSuccessful)
        }
    }

    @Test func crashBetweenSecretInsertionAndSelectionRecoversOnlyStagedSecret() async throws {
        try await fixture { store, file, vault, accounts in
            let original = profile(); try await accounts.connect(original, password: "original", fullSync: false)
            let staged = UUID(), neverWritten = UUID()
            try await store.stageSynchronizationCredential(staged)
            try vault.insert("staged", id: staged)
            try await store.stageSynchronizationCredential(neverWritten)
            let reopened = try FeedLibraryStore(url: file)
            try await SynchronizationAccounts(store: reopened, credentials: vault).recoverCredentialCleanup()
            #expect(try await reopened.synchronizationState().account == original)
            #expect(vault.values == [original.credentialID: "original"])
            try await reopened.close()
        }
    }

    @Test func invalidHostAndDuplicateIdentityCannotReplaceOrDeleteActiveSecret() async throws {
        try await fixture { store, _, vault, accounts in
            let original = profile(); try await accounts.connect(original, password: "original", fullSync: false)
            let before = try await store.synchronizationState()
            await #expect(throws: SynchronizationCredentialError.corrupt) { try await accounts.connect(original, password: "overwrite", fullSync: true) }
            let invalid = SynchronizationAccount(backend: .gpodder, host: "https://user:secret@example.test", username: "x")
            await #expect(throws: SynchronizationError.invalidHost) { try await accounts.connect(invalid, password: "x", fullSync: true) }
            #expect(try await store.synchronizationState() == before)
            #expect(vault.values == [original.credentialID: "original"])
        }
    }

    @Test(arguments: [SynchronizationHTTPClient.Backend.gpodder, .nextcloud])
    func resolvedNativeProviderUsesSelectedCredentialsAndDeviceOnRealHTTP(backend: SynchronizationHTTPClient.Backend) async throws {
        let server = try await LoopbackHTTPServer.start { request in
            if request.path.contains("login.json") { return .init(body: Data()) }
            return .init(body: Data(#"{"add":[],"remove":[],"timestamp":17}"#.utf8))
        }
        defer { server.stop() }
        try await fixture { store, _, _, accounts in
            let account = SynchronizationAccount(backend: backend, host: server.url.deletingLastPathComponent().absoluteString, username: "fixture-user", device: "fixture_phone")
            try await accounts.connect(account, password: "fixture-password", fullSync: false)
            let provider = try await accounts.provider(accountID: account.id)
            try await provider.login()
            #expect(try await provider.subscriptionChanges(since: 0).timestamp == 17)
            let requests = server.requests
            let authenticated = try #require(requests.first)
            #expect(authenticated.headers["authorization"] == "Basic " + Data("fixture-user:fixture-password".utf8).base64EncodedString())
            if backend == .gpodder { #expect(requests.last?.path.contains("fixture_phone.json") == true) }
            else { #expect(requests.count == 1 && requests[0].path.contains("gpoddersync/subscriptions")) }
            #expect(try await store.synchronizationState().account == account)
        }
    }

    @Test func missingPasswordDoesNotSilentlyDisconnectOrClearPendingWork() async throws {
        try await fixture { store, _, vault, accounts in
            let account = profile()
            try await accounts.connect(account, password: "fixture", fullSync: true)
            let before = try await store.synchronizationState()
            try vault.remove(id: account.credentialID)
            await #expect(throws: SynchronizationCredentialError.missing) { try await accounts.provider(accountID: account.id) }
            #expect(try await store.synchronizationState() == before)
            try await accounts.changePassword("restored")
            _ = try await accounts.provider(accountID: account.id)
        }
    }

    @Test func cancelledAccountRequestDoesNotReplaceExistingConnection() async throws {
        try await fixture { store, _, vault, accounts in
            let original = profile(); try await accounts.connect(original, password: "original", fullSync: true)
            let before = try await store.synchronizationState()
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await accounts.connect(profile(.nextcloud), password: "new", fullSync: true)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.synchronizationState() == before)
            #expect(vault.values == [original.credentialID: "original"])
        }
    }

    @Test func overlappingPasswordEditsSerializeAndLeaveOnlyTheSelectedSecret() async throws {
        try await fixture { store, _, vault, accounts in
            let account = profile()
            try await accounts.connect(account, password: "original", fullSync: true)
            let before = try await store.synchronizationState()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<10 { group.addTask { try await accounts.changePassword("edit-\(index)") } }
                try await group.waitForAll()
            }
            let after = try await store.synchronizationState(), current = try #require(after.account)
            #expect(after.accountID == before.accountID && after.epoch == before.epoch && after.request == before.request)
            #expect(after.credentialCleanup == [])
            #expect(vault.values.count == 1 && vault.values[current.credentialID]?.hasPrefix("edit-") == true)
            _ = try await accounts.provider(accountID: account.id)
        }
    }

    @Test func oldSchemaStateDecodesAndMissingCredentialsAreExplicit() async throws {
        let original = #"{"epoch":"00000000-0000-0000-0000-000000000000","subscriptionTimestamp":12,"episodeTimestamp":34,"lastAttemptSuccessful":true,"allowMobile":true}"#
        let decoded = try JSONDecoder().decode(SynchronizationState.self, from: Data(original.utf8))
        #expect(decoded.account == nil && decoded.credentialCleanup == nil && decoded.subscriptionTimestamp == 12)
        try await fixture { store, _, _, accounts in
            let id = UUID(); try await store.selectSynchronizationAccount(id)
            await #expect(throws: SynchronizationCredentialError.missing) { try await accounts.provider(accountID: id) }
            await #expect(throws: SynchronizationCredentialError.missing) { try await accounts.changePassword("fixture") }
        }
    }
}

private final class AccountTestCredentials: SynchronizationCredentialStore, Sendable {
    private struct State { var values: [UUID: String] = [:]; var failInsert = false; var failRemove = false }
    private let state = Mutex(State())
    var values: [UUID: String] { state.withLock { $0.values } }
    var failInsert: Bool { get { state.withLock { $0.failInsert } } set { state.withLock { $0.failInsert = newValue } } }
    var failRemove: Bool { get { state.withLock { $0.failRemove } } set { state.withLock { $0.failRemove = newValue } } }
    func insert(_ password: String, id: UUID) throws {
        try state.withLock {
            if $0.failInsert { throw SynchronizationCredentialError.keychain(-1) }
            guard $0.values[id] == nil else { throw SynchronizationCredentialError.corrupt }
            $0.values[id] = password
        }
    }
    func password(id: UUID) throws -> String {
        try state.withLock { guard let value = $0.values[id] else { throw SynchronizationCredentialError.missing }; return value }
    }
    func remove(id: UUID) throws {
        try state.withLock { if $0.failRemove { throw SynchronizationCredentialError.keychain(-2) }; $0.values[id] = nil }
    }
}
