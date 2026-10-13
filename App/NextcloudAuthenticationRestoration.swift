import Foundation
import CryptoKit
import NotTennaPodCore

/// Scene identity is ordinary restoration metadata. The polling token lives
/// only in a separate Keychain namespace, never in an activity or library backup.
@MainActor final class NextcloudAuthenticationRestoration {
    private let credentials: any SynchronizationCredentialStore
    private let id: UUID
    private var lastSaved: NextcloudAuthenticationSession?

    init(sceneID: String, namespace: String,
         credentials: (any SynchronizationCredentialStore)? = nil) {
        self.credentials = credentials ?? KeychainSynchronizationCredentials(
            service: "org.nottennapod.app.nextcloud.authorization." + namespace)
        let digest = Array(SHA256.hash(data: Data(sceneID.utf8)))
        id = digest.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress!) as UUID }
    }

    func load() throws -> NextcloudAuthenticationSession? {
        do {
            let encoded = try credentials.password(id: id)
            let session = try JSONDecoder().decode(NextcloudAuthenticationSession.self, from: Data(encoded.utf8))
            lastSaved = session
            return session
        } catch SynchronizationCredentialError.missing { return nil }
    }

    func update(_ session: NextcloudAuthenticationSession?) throws {
        // nil must remove a record even in a newly created owner that has not
        // loaded it (for example after an account replacement or scene discard).
        guard session == nil || session != lastSaved else { return }
        let encoded = try session.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try credentials.remove(id: id)
        lastSaved = nil
        if let encoded { try credentials.insert(encoded, id: id); lastSaved = session }
    }

    func clear() throws {
        try credentials.remove(id: id)
        lastSaved = nil
    }
}
