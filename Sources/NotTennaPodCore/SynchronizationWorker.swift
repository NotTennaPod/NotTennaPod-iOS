import Foundation

public enum SynchronizationStatus: Equatable, Sendable {
    case started, subscriptions, waitingForRefresh, downloadingEpisodes, uploadingEpisodes, uploadingPlayed, success, error
}

/// Required application delivery; the recipient applies notification preferences
/// and foreground-message versus system-notification routing. No empty default.
public protocol SynchronizationWorkerEffects: Sendable {
    func handle(_ event: SynchronizationWorker.Event, epoch: UUID) async throws
}

/// Executes one accepted request. The lifetime owner supplies the not-before
/// scheduling, replacement and retries; this worker owns network constraints and
/// source phase ordering. A newer queued request survives this run's completion.
public struct SynchronizationWorker: Sendable {
    public enum Event: Equatable, Sendable {
        case status(SynchronizationStatus)
        case episodesChanged([Int64])
        case clearErrorNotifications
        case reportError(message: String)
    }
    public enum Outcome: Equatable, Sendable { case success, waitingForRefresh, noProvider, retry, failed }
    private let store: FeedLibraryStore
    private let subscriptions: SynchronizationSubscriptions
    private let provider: @Sendable (UUID) async throws -> any SynchronizationProvider
    private let waitForRefresh: @Sendable () async throws -> Void
    private let requestRefresh: @Sendable () async throws -> Void
    private let effects: any SynchronizationWorkerEffects
    private let network: DownloadNetworkMonitor
    private let clock: @Sendable () -> Date
    private let smartMarkAsPlayedSeconds: @Sendable () async throws -> Int32

    public init(store: FeedLibraryStore, subscriptions: SynchronizationSubscriptions,
                refresh: ManualFeedRefreshCoordinator,
                provider: @escaping @Sendable (UUID) async throws -> any SynchronizationProvider,
                effects: any SynchronizationWorkerEffects,
                network: DownloadNetworkMonitor = .shared,
                clock: @escaping @Sendable () -> Date = { Date() },
                smartMarkAsPlayedSeconds: @escaping @Sendable () async throws -> Int32) {
        self.init(store: store, subscriptions: subscriptions, provider: provider,
                  waitForRefresh: { try await refresh.waitUntilIdle() },
                  requestRefresh: { _ = try await refresh.runOnce(feedID: nil).value },
                  effects: effects, network: network, clock: clock, smartMarkAsPlayedSeconds: smartMarkAsPlayedSeconds)
    }

    init(store: FeedLibraryStore, subscriptions: SynchronizationSubscriptions,
         provider: @escaping @Sendable (UUID) async throws -> any SynchronizationProvider,
         waitForRefresh: @escaping @Sendable () async throws -> Void,
         requestRefresh: @escaping @Sendable () async throws -> Void,
         effects: any SynchronizationWorkerEffects,
         network: DownloadNetworkMonitor,
         clock: @escaping @Sendable () -> Date = { Date() },
         smartMarkAsPlayedSeconds: @escaping @Sendable () async throws -> Int32 = { 30 }) {
        self.store = store; self.subscriptions = subscriptions; self.provider = provider
        self.waitForRefresh = waitForRefresh; self.requestRefresh = requestRefresh
        self.effects = effects; self.network = network; self.clock = clock
        self.smartMarkAsPlayedSeconds = smartMarkAsPlayedSeconds
    }

    public func run(_ request: SynchronizationRequest) async throws -> Outcome {
        try await network.waitUntilPermitted(request.network)
        return try await network.perform(under: request.network) { try await attempt(request) }
    }

    private func attempt(_ request: SynchronizationRequest) async throws -> Outcome {
        let initial = try await store.beginSynchronization(request, now: clock())
        do {
            let result = try await execute(request, initial: initial)
            await store.releaseSynchronizationExecution(request)
            return result
        } catch {
            await store.releaseSynchronizationExecution(request)
            throw error
        }
    }

    private func execute(_ request: SynchronizationRequest, initial: SynchronizationState) async throws -> Outcome {
        let epoch = initial.epoch
        guard let account = initial.accountID else {
            try await store.finishSynchronization(request, epoch: epoch, successful: nil, now: clock(), releaseExecution: false)
            return .noProvider
        }
        do {
            let provider = try await provider(account)
            try await requireCurrent(epoch)
            try await provider.login()
            try await emit(.status(.subscriptions), epoch: epoch)
            try await subscriptions.run(provider: provider, epoch: epoch)
            try await emit(.status(.waitingForRefresh), epoch: epoch)
            try await waitForRefresh()
            try await requireCurrent(epoch)
            if try await store.needsSynchronizationFeedRefresh(epoch: epoch) {
                try await emit(.status(.waitingForRefresh), epoch: epoch)
                try await requestRefresh()
                try await requireCurrent(epoch)
                // Source returns before logout/success. Refresh completion requests
                // the next synchronization pass, which can now match episodes.
                try await store.finishSynchronization(request, epoch: epoch, successful: nil, now: clock(), releaseExecution: false)
                return .waitingForRefresh
            }
            try await emit(.status(.downloadingEpisodes), epoch: epoch)
            let timestamp = try await store.requireSynchronization(epoch).episodeTimestamp
            let changes = try await provider.episodeChanges(since: timestamp)
            try await requireCurrent(epoch)
            let seconds = try await smartMarkAsPlayedSeconds()
            let changed = try await store.applySynchronizationEpisodes(changes.actions, epoch: epoch, smartMarkAsPlayedSeconds: seconds)
            if !changed.isEmpty { try await emit(.episodesChanged(changed), epoch: epoch) }
            try await emit(.status(.uploadingEpisodes), epoch: epoch)
            if timestamp == 0 { try await emit(.status(.uploadingPlayed), epoch: epoch) }
            let upload = try await store.synchronizationEpisodeUpload(epoch: epoch, now: clock())
            var newTimestamp = changes.timestamp
            if !upload.actions.isEmpty {
                guard let receipt = try await provider.uploadEpisodeActions(upload.actions) else { throw SynchronizationError.invalidResponse }
                newTimestamp = receipt.timestamp
            }
            try await requireCurrent(epoch)
            try await store.acknowledgeSynchronization(epoch: epoch, phase: .episodes, ids: upload.ids, timestamp: newTimestamp)
            try await provider.logout()
            try await emit(.clearErrorNotifications, epoch: epoch)
            try await emit(.status(.success), epoch: epoch)
            try await store.finishSynchronization(request, epoch: epoch, successful: true, now: clock(), releaseExecution: false)
            return .success
        } catch {
            if Self.isCancellation(error) { throw error }
            try await requireCurrent(epoch)
            let retry = Self.isServiceFailure(error)
            try await store.finishSynchronization(request, epoch: epoch, successful: false, retry: retry, now: clock(), releaseExecution: false)
            try await emit(.status(.error), epoch: epoch)
            if !retry || request.attempts % 3 == 2 {
                try await emit(.reportError(message: String(describing: error)), epoch: epoch)
            }
            return retry ? .retry : .failed
        }
    }

    private func emit(_ event: Event, epoch: UUID) async throws {
        try await requireCurrent(epoch)
        try await effects.handle(event, epoch: epoch)
        try await requireCurrent(epoch)
    }
    private func requireCurrent(_ epoch: UUID) async throws {
        try Task.checkCancellation()
        guard try await store.synchronizationState().epoch == epoch else { throw CancellationError() }
    }
    private static func isCancellation(_ error: any Error) -> Bool {
        Task.isCancelled || error is CancellationError || error is DownloadNetworkInterruption || (error as? URLError)?.code == .cancelled
    }
    private static func isServiceFailure(_ error: any Error) -> Bool {
        if error is URLError { return true }
        if let credentialError = error as? SynchronizationCredentialError {
            switch credentialError {
            case .missing, .keychain: return true
            case .corrupt: return false
            }
        }
        guard let error = error as? SynchronizationError else { return false }
        switch error {
        case .notLoggedIn, .authentication, .httpStatus, .invalidResponse: return true
        case .invalidHost, .invalidAction, .unsupportedOperation: return false
        }
    }
}

extension FeedLibraryStore {
    func needsSynchronizationFeedRefresh(epoch: UUID) throws -> Bool {
        try database.transaction(write: false) {
            _ = try requireSynchronization(epoch)
            // Source getFeedList includes every state; preserve that selection.
            return try loadFeedHeaders().contains {
                $0.keepUpdated && ($0.lastRefreshAttempt == nil || $0.lastRefreshAttempt == Date(timeIntervalSince1970: 0))
            }
        }
    }
}
