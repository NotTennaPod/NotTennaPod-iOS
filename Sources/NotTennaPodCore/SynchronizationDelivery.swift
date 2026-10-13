import Foundation

@MainActor public protocol SynchronizationNotificationPublishing: AnyObject, Sendable {
    func isAuthorized() async -> Bool
    func publishError(title: String, body: String) async throws
    func clearErrors() async
}

/// Shared status and side-effect recipient. Its foreground callback returns true
/// only when an attached, visible application scene accepted the message.
@MainActor public final class SynchronizationDelivery: SynchronizationWorkerEffects {
    public struct Snapshot: Equatable, Sendable {
        public let epoch: UUID
        public let status: SynchronizationStatus
    }
    public struct Text: Sendable {
        public let errorTitle: String
        public let errorPrefix: String
        public init(errorTitle: String, errorPrefix: String) { self.errorTitle = errorTitle; self.errorPrefix = errorPrefix }
    }
    public private(set) var status: Snapshot?
    private let store: FeedLibraryStore
    private let publisher: any SynchronizationNotificationPublishing
    private let text: Text
    private let foreground: @MainActor (String) -> Bool
    private let notificationsEnabled: @MainActor (UUID?) -> Bool
    private let episodesChanged: @MainActor ([Int64]) async throws -> Void
    private var listeners: [UUID: AsyncStream<Snapshot?>.Continuation] = [:]
    private var observation: Task<Void, Never>?
    private var tail: Task<Void, Never>?

    public init(store: FeedLibraryStore, publisher: any SynchronizationNotificationPublishing, text: Text,
                foreground: @escaping @MainActor (String) -> Bool,
                notificationsEnabled: @escaping @MainActor (_ account: UUID?) -> Bool = { _ in true },
                episodesChanged: @escaping @MainActor ([Int64]) async throws -> Void) {
        self.store = store; self.publisher = publisher; self.text = text
        self.foreground = foreground; self.notificationsEnabled = notificationsEnabled; self.episodesChanged = episodesChanged
        observation = Task { [weak self, store] in
            for await _ in await store.synchronizationChanges() {
                guard !Task.isCancelled else { return }
                let previous = self?.status
                guard let saved = try? await store.synchronizationState() else { continue }
                if let self, status == previous, let status, saved.epoch != status.epoch || saved.accountID == nil { publish(nil) }
            }
        }
    }
    deinit { observation?.cancel(); for listener in listeners.values { listener.finish() } }

    public func updates() -> AsyncStream<Snapshot?> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            listeners[id] = continuation; continuation.yield(status)
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.listeners[id] = nil } }
        }
    }

    /// Scheduling status precedes the worker/network wait. Admission metadata
    /// preserves source active-service semantics even if that service retires
    /// before the owner observes the new request. A delayed delivery cannot
    /// overwrite a replacement request or a newer account's phase.
    public func requestAccepted(_ request: SynchronizationRequest, epoch: UUID) async throws {
        let previous = tail
        let task = Task { [self] in
            await previous?.value
            try Task.checkCancellation()
            let saved = try await store.synchronizationState()
            try Task.checkCancellation()
            guard saved.epoch == epoch, saved.accountID != nil, saved.request == request else { throw CancellationError() }
            guard request.announcesStart == true, request.attempts == 0 else { return }
            publish(.init(epoch: epoch, status: .started))
        }
        tail = Task { _ = try? await task.value }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func handle(_ event: SynchronizationWorker.Event, epoch: UUID) async throws {
        let previous = tail
        let task = Task { [self] in
            await previous?.value
            try await requireCurrent(epoch)
            switch event {
            case .status(let value): publish(.init(epoch: epoch, status: value))
            case .episodesChanged(let ids): try await episodesChanged(ids)
            case .clearErrorNotifications: await publisher.clearErrors()
            case .reportError(let message):
                let body = text.errorPrefix + message
                // OS permission controls only system delivery, not an in-app
                // message (the source's supported OS versions behave this way).
                if foreground(body) { return }
                // Settings → Notifications → "Synchronization failed" gates only the system notification,
                // like Android 8+'s channel; the in-app message above is always shown.
                guard notificationsEnabled(try await store.synchronizationState().accountID) else { return }
                guard await publisher.isAuthorized() else { try await requireCurrent(epoch); return }
                try await requireCurrent(epoch)
                do {
                    try await publisher.publishError(title: text.errorTitle, body: body)
                    try await requireCurrent(epoch)
                } catch {
                    // A publish accepted during account replacement must not
                    // leave a stale error behind. Serialized delivery prevents
                    // this cleanup from deleting a newer account's publication.
                    if (try? await isCurrent(epoch)) != true || Task.isCancelled {
                        await publisher.clearErrors()
                        throw error
                    }
                    // Permission can be revoked between the check and OS add.
                    // Suppress that notification without failing the sync itself.
                    if await !publisher.isAuthorized() { try await requireCurrent(epoch); return }
                    throw error
                }
            }
            try await requireCurrent(epoch)
        }
        tail = Task { _ = try? await task.value }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func isCurrent(_ epoch: UUID) async throws -> Bool {
        let saved = try await store.synchronizationState()
        return saved.epoch == epoch && saved.accountID != nil
    }
    private func requireCurrent(_ epoch: UUID) async throws {
        try Task.checkCancellation()
        guard try await isCurrent(epoch) else { throw CancellationError() }
    }
    private func publish(_ value: Snapshot?) {
        guard status != value else { return }
        status = value
        for listener in listeners.values { listener.yield(value) }
    }
}
