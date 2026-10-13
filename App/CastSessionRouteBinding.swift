import Foundation
import NotTennaPodCore
import GoogleCast

/// Warm-session routing shares the existing coordinator engine. Cold/resumed
/// receiver selections require the application's database adoption owner, which
/// must be provided explicitly rather than overwriting receiver media by default.
@MainActor final class CastSessionRouteBinding {
    private let routes: RoutedPlaybackEngine
    private let prepareMedia: CastPlaybackEngine.PrepareMedia
    private let onRestoredSession: @MainActor (CastSessionSnapshot) -> Void
    private let onProblem: @MainActor (String) -> Void
    private let automaticallyPoll: Bool
    private var owned: (identity: CastSessionIdentity, engine: CastPlaybackEngine, suspended: Bool)?
    private var localTransfers: Set<CastSessionIdentity> = []
    private var pendingRestoration: CastSessionIdentity?
    private let retainDisconnectedMedia: @MainActor (CastSessionIdentity, CastPlaybackMedia) -> Void
    private var stoppingReceivers = Set<CastSessionIdentity>()

    /// The library whose loads this binding's engines own.
    private let library: LibraryReference

    init(routes: RoutedPlaybackEngine, automaticallyPoll: Bool = true, library: LibraryReference = .standalone,
         prepareMedia: @escaping CastPlaybackEngine.PrepareMedia,
         retainDisconnectedMedia: @escaping @MainActor (CastSessionIdentity, CastPlaybackMedia) -> Void = { _, media in media.close() },
         onRestoredSession: @escaping @MainActor (CastSessionSnapshot) -> Void,
         onProblem: @escaping @MainActor (String) -> Void) {
        self.routes = routes; self.prepareMedia = prepareMedia; self.automaticallyPoll = automaticallyPoll
        self.library = library
        self.retainDisconnectedMedia = retainDisconnectedMedia
        self.onRestoredSession = onRestoredSession; self.onProblem = onProblem
    }

    func setStoppingReceiver(_ identity: CastSessionIdentity, stopping: Bool) {
        if stopping { stoppingReceivers.insert(identity) } else { stoppingReceivers.remove(identity) }
    }
    private func detach(_ engine: CastPlaybackEngine, identity: CastSessionIdentity) {
        guard let media = engine.detachReceiverMedia() else { return }
        if stoppingReceivers.contains(identity) { media.close() }
        else { retainDisconnectedMedia(identity, media) }
    }
    func receive(_ event: CastSessionEvent) {
        switch event {
        case .connected(let snapshot, let resumed):
            if owned?.identity == snapshot.identity {
                if owned?.suspended == true, let client = snapshot.client {
                    owned?.suspended = false; owned?.engine.resumeConnection(client: client)
                }
                return
            }
            if resumed && !localTransfers.contains(snapshot.identity) {
                pendingRestoration = snapshot.identity
                owned?.engine.suspendConnection(); owned?.suspended = true
                onRestoredSession(snapshot); return
            }
            guard let client = snapshot.client else {
                onProblem(Appearance.text("cast_error_no_media_connection")); return
            }
            let engine = CastPlaybackEngine(client: client, automaticallyPoll: automaticallyPoll, library: library, prepareMedia: prepareMedia)
            install(engine: engine, identity: snapshot.identity)
        case .suspended(let snapshot, let reason):
            guard owned?.identity == snapshot.identity else { return }
            owned?.engine.suspendConnection()
            if reason == .appBackgrounded || reason == .appTerminated {
                owned?.suspended = true
            } else {
                // Match Media3's unavailable-session transfer. The engine is
                // already suspended, so retiring it sends no unreachable STOP.
                if let owned { detach(owned.engine, identity: snapshot.identity) }
                routes.setRemote(nil); owned = nil
            }
        case .ending(let snapshot):
            guard owned?.identity == snapshot.identity else { return }
            if let owned { detach(owned.engine, identity: snapshot.identity) }
            if let pendingRestoration, pendingRestoration != snapshot.identity { routes.unload() }
            routes.setRemote(nil); owned = nil
            localTransfers.remove(snapshot.identity)
        case .ended(let identity, let message):
            let recognized = owned?.identity == identity || localTransfers.contains(identity)
            if owned?.identity == identity {
                if let owned { detach(owned.engine, identity: identity) }
                if let pendingRestoration, pendingRestoration != identity { routes.unload() }
                routes.setRemote(nil); owned = nil
            }
            localTransfers.remove(identity); stoppingReceivers.remove(identity)
            if recognized, let message { onProblem(message) }
        case .startFailed(_, let message): onProblem(message)
        }
    }

    /// The coordinator invokes this after unloading its old episode; installing
    /// the route then cannot cast an intermediate local selection.
    func takeMediaForAdoption(_ status: CastRemoteSnapshot) -> CastPlaybackMedia? {
        owned?.engine.takeMediaForAdoption(status)
    }

    func install(engine: CastPlaybackEngine, identity: CastSessionIdentity, adopting: Bool = false) {
        pendingRestoration = nil
        engine.onReceiverItemChanged = { [weak self, weak engine] client, status in
            guard let self, let engine, self.owned?.engine === engine else { return }
            self.owned?.suspended = true
            self.onRestoredSession(.init(identity: identity, client: client, media: nil, status: status))
        }
        owned = (identity, engine, false)
        localTransfers.insert(identity)
        if adopting { routes.setRemoteForAdoption(engine) }
        else { routes.setRemote(engine) }
    }
}
