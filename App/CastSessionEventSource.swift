import Foundation
import GoogleCast

struct CastSessionIdentity: Hashable {
    let deviceID: String
    let sessionID: String
}

/// Capture value metadata synchronously, especially at willEnd, before the SDK
/// clears its receiver queue. Client ownership is separate from library lookup.
@MainActor struct CastSessionSnapshot {
    let identity: CastSessionIdentity
    let client: (any CastMediaClient)?
    let media: CastMediaItemCodec.Item?
    let status: CastRemoteSnapshot?
    var receiverAddress: CastReceiverAddress? = nil
}

@MainActor enum CastSessionEvent {
    case connected(CastSessionSnapshot, resumed: Bool)
    case ending(CastSessionSnapshot)
    case ended(CastSessionIdentity, message: String?)
    case suspended(CastSessionSnapshot, reason: GCKConnectionSuspendReason)
    case startFailed(CastSessionIdentity, message: String)
}

/// Only Cast-specific delegate methods are implemented: implementing both the
/// generic and Cast variants would risk delivering a transition twice.
@MainActor final class CastSessionEventSource: NSObject, @preconcurrency GCKSessionManagerListener {
    private let manager: GCKSessionManager
    private let onEvent: @MainActor (CastSessionEvent) -> Void
    private var clients: [ObjectIdentifier: GoogleCastMediaClient] = [:]
    private var sessionClients: [CastSessionIdentity: ObjectIdentifier] = [:]

    init(manager: GCKSessionManager, onEvent: @escaping @MainActor (CastSessionEvent) -> Void) {
        self.manager = manager; self.onEvent = onEvent
        super.init()
        manager.add(self)
    }
    isolated deinit { manager.remove(self) }

    /// Invoke after application playback/library ownership is installed. An
    /// existing receiver requires adoption, not a new local-to-remote LOAD.
    func deliverExistingSession() {
        if let session = manager.currentCastSession, session.connectionState == .connected {
            onEvent(.connected(capture(session), resumed: true))
        }
    }

    private func identity(_ session: GCKCastSession) -> CastSessionIdentity {
        .init(deviceID: session.device.uniqueID,
              sessionID: session.sessionID ?? "unstarted-\(ObjectIdentifier(session))")
    }
    private func capture(_ session: GCKCastSession) -> CastSessionSnapshot {
        let client: GoogleCastMediaClient?
        if let remote = session.remoteMediaClient {
            let key = ObjectIdentifier(remote)
            sessionClients[identity(session)] = key
            if let existing = clients[key] { client = existing }
            else {
                let created = GoogleCastMediaClient(remote)
                clients[key] = created; client = created
            }
        } else { client = nil }
        return .init(identity: identity(session), client: client,
            media: session.remoteMediaClient?.mediaStatus?.mediaInformation.map(CastMediaItemCodec.decode),
            status: client?.snapshot, receiverAddress: session.device.networkAddress.ipAddress.map {
                .init(address: $0, port: session.device.servicePort)
            })
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        onEvent(.connected(capture(session), resumed: false))
    }
    func sessionManager(_ sessionManager: GCKSessionManager, didResumeCastSession session: GCKCastSession) {
        onEvent(.connected(capture(session), resumed: true))
    }
    func sessionManager(_ sessionManager: GCKSessionManager, willEnd session: GCKCastSession) {
        onEvent(.ending(capture(session)))
    }
    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        onEvent(.ended(identity(session), message: error?.localizedDescription))
        if let key = sessionClients.removeValue(forKey: identity(session)) { clients[key] = nil }
    }
    func sessionManager(_ sessionManager: GCKSessionManager, didSuspend session: GCKCastSession,
                        with reason: GCKConnectionSuspendReason) {
        onEvent(.suspended(capture(session), reason: reason))
    }
    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKCastSession, withError error: Error) {
        onEvent(.startFailed(identity(session), message: error.localizedDescription))
    }
}
