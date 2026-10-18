import Foundation
import NotTennaPodCore
import GoogleCast

@MainActor final class CastReceiverSessionController {
    enum Unresolved: Equatable { case unavailableStatus, invalidMediaID, missingEpisode, failed(String) }
    private(set) var unresolved: Unresolved?
    private let player: PlaybackCoordinator
    private let routes: RoutedPlaybackEngine
    private let prepareMedia: CastPlaybackEngine.PrepareMedia
    private let mediaAccess: CastMediaAccessOwner?
    private var addressIdentity: CastSessionIdentity?
    private let automaticallyPoll: Bool
    private let onProblem: @MainActor (String) -> Void
    /// Receiver media is adopted only when this library loaded it (local IDs repeat across libraries).
    private let library: LibraryReference
    private var revision = UUID()
    private var restoration: Task<Void, Never>?
    private var restoringIdentity: CastSessionIdentity?
    private lazy var binding = CastSessionRouteBinding(routes: routes, automaticallyPoll: automaticallyPoll, library: library,
        prepareMedia: prepareMedia, retainDisconnectedMedia: { [weak self] identity, media in
            guard let access = self?.mediaAccess else { media.close(); return }
            access.retainDisconnected(media, identity: identity)
        }, onRestoredSession: { [weak self] in self?.restore($0) }, onProblem: onProblem)

    init(player: PlaybackCoordinator, routes: RoutedPlaybackEngine, automaticallyPoll: Bool = true,
         mediaAccess: CastMediaAccessOwner? = nil, library: LibraryReference = .standalone,
         prepareMedia: @escaping CastPlaybackEngine.PrepareMedia, onProblem: @escaping @MainActor (String) -> Void) {
        self.player = player; self.routes = routes; self.automaticallyPoll = automaticallyPoll
        self.prepareMedia = prepareMedia; self.onProblem = onProblem; self.mediaAccess = mediaAccess
        self.library = library
    }

    /// A receiver status query for a connected session is in flight; its media may be adopted when it answers.
    var isRestoring: Bool { restoringIdentity != nil }
    isolated deinit { restoration?.cancel() }

    func setStoppingReceiver(_ identity: CastSessionIdentity, stopping: Bool) {
        binding.setStoppingReceiver(identity, stopping: stopping)
    }

    func receive(_ event: CastSessionEvent) {
        switch event {
        case .connected(let snapshot, _):
            addressIdentity = snapshot.identity; mediaAccess?.setReceiver(snapshot.receiverAddress)
        case .ended(let identity, _), .startFailed(let identity, _):
            if addressIdentity == identity { addressIdentity = nil; mediaAccess?.setReceiver(nil) }
        default: break
        }
        let identity: CastSessionIdentity
        let connected: Bool
        switch event {
        case .connected(let snapshot, _): identity = snapshot.identity; connected = true
        case .ending(let snapshot), .suspended(let snapshot, _): identity = snapshot.identity; connected = false
        case .ended(let id, _), .startFailed(let id, _): identity = id; connected = false
        }
        if connected, restoringIdentity == identity { return }
        if connected || restoringIdentity == nil || restoringIdentity == identity {
            revision = UUID(); restoration?.cancel(); restoration = nil; restoringIdentity = nil
        }
        binding.receive(event)
    }

    private func restore(_ snapshot: CastSessionSnapshot) {
        revision = UUID(); let revision = revision
        restoration?.cancel(); unresolved = nil
        restoringIdentity = snapshot.identity
        let interaction = player.interactionRevision
        guard let client = snapshot.client else { unresolved = .unavailableStatus; restoringIdentity = nil; return }
        let query = CastReceiverStatusQuery(client: client)
        restoration = Task { [weak self, client] in
            defer { if self?.revision == revision { self?.restoringIdentity = nil } }
            do {
                guard let status = try await query.run() else {
                    if self?.revision == revision { self?.unresolved = .unavailableStatus }; return
                }
                guard let self, self.revision == revision, !Task.isCancelled,
                      self.player.interactionRevision == interaction else { return }
                // Restored again when the receiver's item changes, or when the same item's state becomes usable (a
                // first `unknown` or `idle` report is not adoptable): the whole restoration, library check included,
                // runs again.
                var usable = Self.usable(status)
                let recheck: @MainActor () -> Void = { [weak self, weak client] in
                    guard let self, let client, self.revision == revision, self.player.interactionRevision == interaction,
                          let latest = client.snapshot else { return }
                    let becameUsable = !usable && Self.usable(latest)
                    usable = Self.usable(latest)
                    if latest.mediaID != status.mediaID || latest.loadID != status.loadID
                        || latest.mediaSessionID != status.mediaSessionID || becameUsable {
                        self.restore(.init(identity: snapshot.identity, client: client, media: nil, status: latest))
                    }
                }
                client.onStatus = recheck
                // A change reported while the status was being read is not missed.
                recheck()
                guard self.revision == revision else { return }
                if status.state == .idle, status.mediaID == nil, status.idleReason != .finished {
                    // Only a confirmed empty receiver prepares saved selection.
                    try await self.player.restore()
                    guard self.revision == revision, self.player.interactionRevision == interaction else { return }
                    try await self.player.stop()
                    guard self.revision == revision else { return }
                    let engine = CastPlaybackEngine(client: client, automaticallyPoll: self.automaticallyPoll,
                        library: self.library, prepareMedia: self.prepareMedia)
                    self.binding.install(engine: engine, identity: snapshot.identity)
                    if let episode = self.player.episode { try await self.player.select(episodeID: episode.id, play: false) }
                    return
                }
                // Media another library loaded is foreign here: its media ID names an episode of that library.
                guard let id = status.mediaID.flatMap(Int64.init), status.libraryID == self.library.castLibraryID else {
                    self.unresolved = .invalidMediaID; return
                }
                let current: @MainActor () -> Bool = { [weak self] in
                    guard let self, self.revision == revision, self.player.interactionRevision == interaction,
                          let latest = client.snapshot else { return false }
                    return latest.mediaID == status.mediaID && latest.loadID == status.loadID
                        && latest.mediaSessionID == status.mediaSessionID
                        && latest.state != .idle && latest.state != .unknown
                }
                var admittedMedia: CastPlaybackMedia?
                var ownsPreparation = false
                defer { if ownsPreparation { admittedMedia?.close() } }
                if let access = self.mediaAccess {
                    admittedMedia = try await access.authorizedMedia(episodeID: id, contentURL: status.contentURL)
                    if admittedMedia == nil {
                        do { admittedMedia = try await access.prepare(episodeID: id) }
                        catch is CastRelayStreamingDenied {
                            try await self.confirmRelay(episodeID: id, client: client, identity: snapshot.identity,
                                                        revision: revision, current: current)
                            return
                        }
                        ownsPreparation = true
                    }
                    guard current(), !Task.isCancelled else { throw CancellationError() }
                }
                let admitted = admittedMedia
                try await self.player.adoptExternalPlayback(episodeID: id, state: {
                    guard current(), let latest = client.snapshot else { throw CancellationError() }
                    return .init(sample: .init(positionMilliseconds: latest.positionMilliseconds,
                        durationMilliseconds: latest.durationMilliseconds, seekable: latest.seekable,
                        status: latest.state == .paused ? .paused : .playing), buffering: latest.state == .buffering || latest.state == .loading,
                        speed: latest.speed > 0 && latest.speed.isFinite ? latest.speed : 1)
                }, activateEngine: {
                    guard current(), let status = client.snapshot else { throw CancellationError() }
                    let transferred = self.binding.takeMediaForAdoption(status)
                    let lease = admitted ?? transferred
                    if let transferred, let admitted, transferred !== admitted { transferred.close() }
                    ownsPreparation = false
                    let engine = CastPlaybackEngine(client: client, automaticallyPoll: self.automaticallyPoll,
                        adoptionMedia: lease, library: self.library, prepareMedia: self.prepareMedia)
                    self.binding.install(engine: engine, identity: snapshot.identity, adopting: true)
                }, isCurrent: current)
            } catch is CancellationError {
                // Superseded connection or user selection owns the next state.
            } catch FeedLibraryError.missingEpisode {
                if self?.revision == revision { self?.unresolved = .missingEpisode }
            } catch {
                if self?.revision == revision { self?.unresolved = .failed(error.localizedDescription) }
            }
        }
    }

    /// The receiver's item needs a new relay that this network does not admit (no lease survived, and Streaming is off
    /// on a restricted network). It cannot be adopted: select its episode at the receiver's position on a new route,
    /// which asks Once/Always, and either resumes where the receiver was. Only once the player has settled its current
    /// item, and only if this restoration is still current and no person's command came meanwhile, is the receiver's
    /// stale item stopped and the route installed; otherwise a newer selection wins and the receiver is left alone.
    private func confirmRelay(episodeID: Int64, client: any CastMediaClient, identity: CastSessionIdentity, revision: UUID,
                              current: @escaping @MainActor () -> Bool) async throws {
        guard current(), !Task.isCancelled, let latest = client.snapshot else { throw CancellationError() }
        let position = Int64(latest.positionMilliseconds)
        let valid: @MainActor () -> Bool = { [weak self] in self?.revision == revision && current() }
        try await player.selectOnRoute(episodeID: episodeID, positionMilliseconds: position, activateRoute: { [weak self] in
            guard let self, valid() else { throw CancellationError() }
            // Stopping the item changes the receiver's status; this restoration's rechecks end here.
            client.onStatus = nil
            client.send(.stop) { _ in }.cancel()
            let engine = CastPlaybackEngine(client: client, automaticallyPoll: self.automaticallyPoll, library: self.library,
                                            prepareMedia: self.prepareMedia)
            self.binding.install(engine: engine, identity: identity)
        }, isCurrent: valid)
    }

    func awaitRestoration() async { await restoration?.value }

    /// A receiver state an item can be adopted in (not `idle`, not `unknown`).
    private static func usable(_ status: CastRemoteSnapshot) -> Bool { status.state != .idle && status.state != .unknown }
}

/// Cancellation retires tracking and resumes the waiter even though cancelling
/// an SDK request does not guarantee that the receiver stops executing it.
@MainActor private final class CastReceiverStatusQuery {
    private let client: any CastMediaClient
    private var continuation: CheckedContinuation<CastRemoteSnapshot?, Error>?
    private var request: (any CastRequestCancellation)?
    init(client: any CastMediaClient) { self.client = client }
    func run() async throws -> CastRemoteSnapshot? {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let request = client.send(.status) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .completed: self.finish(.success(self.client.snapshot))
                    case .superseded: self.finish(.failure(CancellationError()))
                    case .failed(let message): self.finish(.failure(NSError(domain: "CastReceiverStatus", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: message])))
                    }
                }
                if self.continuation != nil { self.request = request } else { request.cancel() }
            }
        } onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } }
    }
    private func finish(_ result: Result<CastRemoteSnapshot?, Error>) {
        let continuation = continuation; self.continuation = nil
        request?.cancel(); request = nil
        continuation?.resume(with: result)
    }
}
