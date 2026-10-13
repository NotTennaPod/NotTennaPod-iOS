import Foundation

/// App/library owned. A row or snackbar may end its offer without owning the
/// source helper's independent two-second media check.
@MainActor public final class EpisodeSwipeCoordinator {
    public enum Message: String, Equatable, Sendable {
        case removedFromInbox = "removed_from_inbox_message"
        case markedAsPlayed = "marked_as_played_message"
        case markedAsUnplayed = "marked_as_unplayed_message"
        public var quantity: Int? { self == .removedFromInbox ? nil : 1 }
    }
    public struct Commit: Equatable, Sendable {
        public let operationID: UUID
        public let episodeID: Int64
        public let modelIdentity: UUID
        public let delta: EpisodeActionStateDelta
        /// Nil is a silent source recipient, not an invisible Undo offer.
        public let message: Message?
        public var actionTitleKey: String? { message == nil ? nil : "undo" }
    }
    public enum PerformResult: Equatable, Sendable { case committed(Commit), ineligible, invalidated, failed }
    public enum UndoResult: Equatable, Sendable { case restored, superseded, unavailable, notOffered, invalidated, failed }
    public enum FailureStage: Sendable { case mark, undo, release, cleanup }
    public enum CleanupResult: Equatable, Sendable { case deleted, stale, skipped, cancelled, failed }
    public enum Event: Sendable {
        /// Consumers patch only this exact current model/result binding.
        case committed(Commit)
        case undone(operationID: UUID, modelIdentity: UUID, result: EpisodeMarkUndoResult,
                    delta: EpisodeActionStateDelta?)
        case cleanupFinished(operationID: UUID, result: CleanupResult)
        /// Use the application's existing storage-error presentation policy.
        case failed(operationID: UUID?, stage: FailureStage, error: any Error)
    }
    public var onEvent: (@MainActor (Event) -> Void)?

    struct Clock: Sendable {
        var now: @MainActor @Sendable () -> ContinuousClock.Instant
        var sleep: @MainActor @Sendable (ContinuousClock.Instant) async throws -> Void
        static let continuous = Self(now: { .now }, sleep: { try await ContinuousClock().sleep(until: $0) })
    }
    struct Persistence: Sendable {
        var apply: @Sendable (Int64, EpisodeSwipeMark) async throws -> EpisodeMarkReceipt?
        var undo: @Sendable (EpisodeMarkReceipt) async throws -> EpisodeMarkUndoResult
        var release: @Sendable (EpisodeMarkReceipt) async throws -> Void
        init(store: FeedLibraryStore) {
            apply = { try await store.applySwipeMark(episodeID: $0, action: $1) }
            undo = { try await store.undoSwipeMark($0) }
            release = { try await store.releaseSwipeUndo($0) }
        }
    }
    private enum Phase { case waiting, submitted, finished }
    private final class Operation {
        let receipt: EpisodeMarkReceipt
        let model: EpisodeActionModel
        let target: EpisodeMediaDeletionTarget?
        var offersUndo: Bool
        var phase = Phase.waiting
        var timer: Task<Void, Never>?
        init(receipt: EpisodeMarkReceipt, model: EpisodeActionModel,
             target: EpisodeMediaDeletionTarget?, offersUndo: Bool) {
            self.receipt = receipt; self.model = model; self.target = target; self.offersUndo = offersUndo
        }
    }
    private let persistence: Persistence
    private let downloads: DownloadCoordinator
    private let clock: Clock
    private let delete: @MainActor (EpisodeMediaDeletionTarget) async throws -> EpisodeMediaDeletionOutcome
    private var operations: [UUID: Operation] = [:]
    private var mutations: [UUID: Task<Void, Never>] = [:]
    private var tail: Task<Void, Never>?
    private var active = true

    public convenience init(store: FeedLibraryStore, downloads: DownloadCoordinator,
        delete: @escaping @MainActor (EpisodeMediaDeletionTarget) async throws -> EpisodeMediaDeletionOutcome) {
        self.init(persistence: .init(store: store), downloads: downloads, clock: .continuous, delete: delete)
    }
    init(persistence: Persistence, downloads: DownloadCoordinator, clock: Clock,
         delete: @escaping @MainActor (EpisodeMediaDeletionTarget) async throws -> EpisodeMediaDeletionOutcome) {
        self.persistence = persistence; self.downloads = downloads; self.clock = clock; self.delete = delete
    }
    isolated deinit {
        for operation in operations.values where operation.phase == .waiting { operation.timer?.cancel() }
        for task in mutations.values { task.cancel() }
    }

    /// The caller captures target/model together and supplies the source filter's
    /// feedback flag. Capture/store/provider validation is not a fresh-ID lookup.
    public func perform(model: EpisodeActionModel, action: EpisodeSwipeMark,
                        target: EpisodeMediaDeletionTarget?, offersUndo: Bool) async -> PerformResult {
        guard active else { return .invalidated }
        let deadline = clock.now().advanced(by: .seconds(2))
        let captured = model.snapshot()
        guard valid(target, for: captured) else {
            onEvent?(.failed(operationID: nil, stage: .mark, error: FeedLibraryError.invalidMutation))
            return .failed
        }
        return await enqueue { [weak self] in
            guard let self, active else { return .invalidated }
            do {
                guard let receipt = try await persistence.apply(model.episodeID, action) else { return .ineligible }
                guard active else {
                    try? await persistence.release(receipt)
                    return .invalidated
                }
                // A caller's descriptor must identify the same accepted feed.
                // It still requires guarded destructive admission downstream.
                let operation = Operation(receipt: receipt, model: model, target: target, offersUndo: offersUndo)
                operations[receipt.operationID] = operation
                let delta = EpisodeActionStateDelta(playState: receipt.appliedState)
                model.applyCommittedState(delta)
                let message: Message = receipt.appliedState == .played ? .markedAsPlayed
                    : receipt.previousState == .new ? .removedFromInbox : .markedAsUnplayed
                let commit = Commit(operationID: receipt.operationID, episodeID: receipt.episodeID,
                    modelIdentity: model.identity, delta: delta, message: offersUndo ? message : nil)
                schedule(operation, deadline: deadline)
                onEvent?(.committed(commit))
                if !offersUndo { await release(operation) }
                return .committed(commit)
            } catch {
                guard active else { return .invalidated }
                onEvent?(.failed(operationID: nil, stage: .mark, error: error))
                return .failed
            }
        }.value
    }

    public func undo(operationID: UUID) async -> UndoResult {
        await beginUndo(operationID: operationID).value
    }

    /// Synchronous UI callbacks must cancel before returning to the run loop.
    /// The returned task owns only the serialized persistence/result phase.
    public func beginUndo(operationID: UUID) -> Task<UndoResult, Never> {
        guard active else { return Task { .invalidated } }
        guard let operation = operations[operationID], operation.offersUndo else { return Task { .notOffered } }
        operation.offersUndo = false
        // Source cancellation is independent of the database Future's success.
        // No await precedes cancellation, including a queued earlier mutation.
        cancelWaiting(operation)
        return enqueue { [weak self] in
            guard let self, active else { return .invalidated }
            do {
                let result = try await persistence.undo(operation.receipt)
                guard active else { return .invalidated }
                let delta = result == .restored ? EpisodeActionStateDelta(playState: operation.receipt.previousState) : nil
                if let delta { operation.model.applyCommittedState(delta) }
                onEvent?(.undone(operationID: operationID, modelIdentity: operation.model.identity, result: result, delta: delta))
                removeIfFinished(operation)
                switch result {
                case .restored: return .restored
                case .superseded: return .superseded
                case .unavailable: return .unavailable
                }
            } catch {
                guard active else { return .invalidated }
                onEvent?(.failed(operationID: operationID, stage: .undo, error: error))
                // The offer is consumed even if the database retained its guard.
                // Release is best effort and never retries state restoration.
                await release(operation)
                removeIfFinished(operation)
                return .failed
            }
        }
    }

    /// Snackbar expiry/replacement/dismissal ends the offer, not its media task.
    public func endOffer(operationID: UUID) async {
        guard active, let operation = operations[operationID], operation.offersUndo else { return }
        operation.offersUndo = false
        await enqueue { [weak self] in
            guard let self, active else { return }
            await release(operation)
            removeIfFinished(operation)
        }.value
    }

    /// Only library-graph teardown, never ordinary navigation/backgrounding.
    /// Submitted destructive work belongs to its captured-target owner already.
    public func invalidateLibrary() {
        guard active else { return }
        active = false
        let receipts = operations.values.map(\.receipt)
        for operation in operations.values where operation.phase == .waiting { operation.timer?.cancel() }
        for task in mutations.values { task.cancel() }
        operations.removeAll()
        let persistence = persistence
        Task { for receipt in receipts { try? await persistence.release(receipt) } }
    }

    private func schedule(_ operation: Operation, deadline: ContinuousClock.Instant) {
        let id = operation.receipt.operationID, clock = clock
        let timer = downloads.deleteAfterMark(model: operation.model, wait: { try await clock.sleep(deadline) }) { [weak self] _, _ in
            guard let self, active, let current = operations[id], current === operation, current.phase == .waiting else {
                throw CancellationError()
            }
            // This is the source Handler's fire/admission boundary. Undo cannot
            // cancel the submitted callback across its following await.
            current.phase = .submitted
            guard let target = current.target, target.feedID == current.receipt.feedID else {
                finish(current, result: .stale)
                throw CancellationError()
            }
            do {
                let result = try await delete(target)
                guard active else { throw CancellationError() }
                finish(current, result: result == .deleted ? .deleted : .stale)
                if result == .stale { throw CancellationError() }
            } catch is CancellationError where current.phase == .finished || !active {
                throw CancellationError()
            } catch {
                if active {
                    onEvent?(.failed(operationID: id, stage: .cleanup, error: error))
                    finish(current, result: .failed)
                }
                // The recipient reported the actual failure above. Do not also
                // publish DownloadCoordinator's generic storage error/success.
                throw CancellationError()
            }
        }
        operation.timer = timer
        Task { [weak self, weak operation] in
            await timer.value
            guard let self, active, let operation, operation.phase == .waiting else { return }
            finish(operation, result: .skipped)
        }
    }

    private func cancelWaiting(_ operation: Operation) {
        guard operation.phase == .waiting else { return }
        operation.timer?.cancel()
        finish(operation, result: .cancelled)
    }
    private func finish(_ operation: Operation, result: CleanupResult) {
        operation.phase = .finished
        onEvent?(.cleanupFinished(operationID: operation.receipt.operationID, result: result))
        removeIfFinished(operation)
    }
    private func removeIfFinished(_ operation: Operation) {
        if !operation.offersUndo && operation.phase == .finished { operations[operation.receipt.operationID] = nil }
    }
    private func release(_ operation: Operation) async {
        do { try await persistence.release(operation.receipt) }
        catch { if active { onEvent?(.failed(operationID: operation.receipt.operationID, stage: .release, error: error)) } }
    }

    /// Serialize accepted state/model deltas like the source writer queue. Timer
    /// callbacks and offer cancellation remain independent of this queue.
    private func enqueue<Value: Sendable>(_ body: @escaping @MainActor () async -> Value) -> Task<Value, Never> {
        let previous = tail, id = UUID()
        let task = Task { await previous?.value; return await body() }
        let monitor = Task { [weak self] in
            await withTaskCancellationHandler { _ = await task.value } onCancel: { task.cancel() }
            self?.mutations[id] = nil
        }
        mutations[id] = monitor; tail = monitor
        return task
    }

    private func valid(_ target: EpisodeMediaDeletionTarget?, for item: EpisodeListItem) -> Bool {
        guard let media = item.episode.details.media else { return target == nil }
        guard let target, target.episodeID == item.episode.id, target.feedID > 0 else { return false }
        switch target.media {
        case .remote(let mediaURL, let originalFile):
            return !item.local && !target.source.isLocalFeedSource
                && exactlyEqual(mediaURL, media.url) && exactlyEqual(originalFile, item.episode.userState.localFileURL)
        case .local(let reference):
            return item.local && reference.folder.feedID == target.feedID
                && exactlyEqual(target.source, LibraryFeed.localSourcePrefix + reference.folder.directoryIdentity)
                && exactlyEqual(reference.identity, media.url) && exactlyEqual(reference.filename, item.episode.details.link)
                && reference.size == media.size
        }
    }
}
