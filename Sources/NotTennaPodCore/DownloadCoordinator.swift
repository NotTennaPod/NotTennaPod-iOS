import Foundation
import Synchronization

@MainActor
public final class DownloadCoordinator {
    private final class TransferProgress: Sendable {
        let value = Mutex<MediaDownloadProgress?>(nil)
    }
    /// Set while polling sleeps because no job transfers; the next progress report wakes it.
    private final class PollWake: Sendable {
        let dormant = Mutex(false)
        func take() -> Bool { dormant.withLock { value in defer { value = false }; return value } }
    }
    private let pollWake = PollWake()
    public enum Event: Sendable {
        case stateChanged, libraryChanged
        /// Every failed attempt, retried or not, once it is recorded (one message per attempt).
        case attemptFailed(DownloadFailureReport)
        case storageError
    }
    public private(set) var jobs: [LibraryDownloadJob] = []
    /// Jobs parked because saved state they need could not be reached (before the first unlock): waiting, not work
    /// that needs the process (`hasProcessWork`), and started again once by `resumeParked()`.
    public private(set) var parkedForAccess: Set<Int64> = []
    /// Counts the events that may bring access back (unlock, scene activation), whether or not a job was parked
    /// then: an attempt denied before the latest one gets one more attempt once it unwinds, instead of parking.
    private final class AccessEvents: Sendable { let count = Mutex(0) }
    /// The access-event count when an attempt was denied.
    private final class Denial: Sendable { let at = Mutex<Int?>(nil) }
    private let accessEvents = AccessEvents()
    /// Host tests: runs when an attempt denied access has unwound, just before it would park.
    var beforeParking: (@MainActor () async -> Void)?
    public private(set) var progress: [Int64: MediaDownloadProgress] = [:]
    private let store: FeedLibraryStore
    private let directory: URL
    private let worker: MediaDownloadWorker
    private let network: DownloadNetworkMonitor
    private let preferences: @MainActor () -> DownloadPreferences
    private let clock: @Sendable () -> Date
    private let credentials: @Sendable (Int64) async throws -> FeedCredentials?
    private var policy = DownloadActionPolicy()
    private var tasks: [Int64: Task<Void, Never>] = [:]
    private var progressBuffers: [Int64: TransferProgress] = [:]
    private var listeners: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var startup: Task<[LibraryDownloadJob], any Error>?
    private var ready = false
    private var stopsInProgress = 0
    private var generation: UInt64 = 0
    private var stopping: Bool { stopsInProgress > 0 }
    private var polling: Task<Void, Never>?
    var isPolling: Bool { polling != nil }

    public init(store: FeedLibraryStore, directory: URL, transfer: any MediaTransferring = MediaDownloadTransfer(),
                network: DownloadNetworkMonitor = .shared,
                transcriptLoader: TranscriptLoader? = nil,
                preferences: @escaping @MainActor () -> DownloadPreferences = { .init() },
                credentials: @escaping @Sendable (Int64) async throws -> FeedCredentials? = { _ in nil },
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.directory = directory
        self.network = network
        self.preferences = preferences
        self.clock = clock
        self.credentials = credentials
        worker = MediaDownloadWorker(store: store, transfer: transfer, clock: clock, network: network, transcriptLoader: transcriptLoader)
    }

    deinit { polling?.cancel(); for task in tasks.values { task.cancel() } }

    public func events() -> AsyncStream<Event> {
        let id = UUID()
        return AsyncStream { continuation in
            listeners[id] = continuation
            continuation.yield(.stateChanged)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.listeners[id] = nil }
            }
        }
    }

    public func start() async throws {
        guard !stopping else { throw FeedLibraryError.invalidMutation }
        let generation = generation
        if !ready {
            if startup == nil {
                startup = Task { [worker, store, directory] in
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try await worker.recoverStoppedForegroundWork()
                    return try await store.downloadJobs(activeOnly: false)
                }
            }
            do {
                let restored = try await startup!.value
                guard generation == self.generation, !stopping else { throw CancellationError() }
                if !ready { jobs = restored; ready = true }
                startup = nil
            } catch {
                if generation == self.generation { startup = nil }
                throw error
            }
        }
        for job in jobs where job.state.isActive { launch(job.id) }
        publish(.stateChanged)
    }

    public func stop() async {
        stopsInProgress += 1
        generation &+= 1
        polling?.cancel()
        polling = nil
        if let startup { _ = try? await startup.value; self.startup = nil }
        let active = Array(tasks.values)
        for task in active { task.cancel() }
        for task in active { await task.value }
        stopsInProgress -= 1
    }

    /// Whether any active job needs the process now: a job parked for access does not, so background time held for
    /// downloads is released while it waits.
    public var hasProcessWork: Bool { jobs.contains { $0.state.isActive && !parkedForAccess.contains($0.id) } }

    /// Protected data became available or a scene became active: each job parked for access gets one new attempt.
    public func resumeParked() {
        accessEvents.count.withLock { $0 += 1 }
        for job in jobs where parkedForAccess.contains(job.id) && job.state.isActive && tasks[job.id] == nil { launch(job.id) }
        parkedForAccess.formIntersection(jobs.filter(\.state.isActive).map(\.id))
    }

    public func activeJob(source: String?) -> LibraryDownloadJob? {
        guard let source else { return nil }
        return jobs.first { $0.state.isActive && $0.source.utf16.elementsEqual(source.utf16) }
    }

    public func request(episodeID: Int64) async throws -> DownloadActionPolicy.Decision {
        try await start()
        let generation = generation
        guard let episode = try await store.episode(id: episodeID) else { throw FeedLibraryError.missingEpisode(episodeID) }
        try await refresh()
        guard generation == self.generation, !stopping else { throw CancellationError() }
        let network = network.current
        let choice = policy.decision(hasMedia: episode.details.media != nil, downloaded: episode.userState.isDownloaded,
                                     downloading: activeJob(source: episode.details.media?.url) != nil,
                                     allowMobile: preferences().allowMobile,
                                     restrictedNetwork: network?.restricted ?? true, vpnOverWiFi: network?.vpnOverWiFi ?? false,
                                     nowMilliseconds: timestamp())
        if case .request(let ignore, _) = choice { try await enqueue(episodeID, ignoreConstraints: ignore) }
        return choice
    }

    public func confirm(episodeID: Int64, choice: DownloadActionPolicy.Choice) async throws -> DownloadActionPolicy.Decision {
        try await start()
        let decision = policy.confirm(choice, nowMilliseconds: timestamp())
        if case .request(let ignore, _) = decision { try await enqueue(episodeID, ignoreConstraints: ignore) }
        return decision
    }

    /// Automatic admission has already checked network/power. Source uses the
    /// ordinary download service constraints, without manual bypass/confirmation.
    public func requestAutomatic(episodeID: Int64) async throws {
        try await start()
        try await enqueue(episodeID, ignoreConstraints: false, automatic: true)
    }

    /// Multi select calls the ordinary service directly, without the row-button
    /// double-tap admission policy. It remains a manual, constrained download.
    public func requestBatch(episodeID: Int64) async throws {
        try await start()
        try await enqueue(episodeID, ignoreConstraints: false)
    }

    public var deletionRemovesFromQueue: Bool { preferences().deleteRemovesFromQueue }

    public func cancel(episodeID: Int64) async throws {
        try await start()
        guard let episode = try await store.episode(id: episodeID) else { throw FeedLibraryError.missingEpisode(episodeID) }
        try await refresh()
        guard let job = activeJob(source: episode.details.media?.url) else { return }
        _ = try await worker.cancel(id: job.id, callerEpisodeID: episodeID,
                                    deleteRemovesFromQueue: preferences().deleteRemovesFromQueue)
        try await refresh()
        publish(.libraryChanged)
    }

    public func retireDeletedJobs(_ ids: Set<Int64>) async throws {
        try await worker.retireDeletedJobs(ids)
        let pending = ids.compactMap { tasks[$0] }
        for task in pending { task.cancel() }
        for task in pending { await task.value }
        try await refresh()
        publish(.libraryChanged)
    }

    /// Drain journaled playback deletions even when no download job is active.
    public func completePlaybackFileEffects() async throws {
        try await worker.cleanCancelledFiles()
        try await refresh()
        publish(.libraryChanged)
    }

    public func deleteDownloadedMedia(episodeID: Int64, playback: PlaybackCoordinator) async throws {
        try await start()
        try await playback.deleteDownloadedMedia(episodeID: episodeID,
            deleteRemovesFromQueue: preferences().deleteRemovesFromQueue)
        try await worker.cleanCancelledFiles()
        try await refresh()
        publish(.libraryChanged)
    }

    public func deleteDownloadedMedia(target: EpisodeMediaDeletionTarget,
        playback: PlaybackCoordinator) async throws -> EpisodeMediaDeletionOutcome {
        try await start()
        let outcome = try await playback.deleteDownloadedMedia(target: target,
            deleteRemovesFromQueue: preferences().deleteRemovesFromQueue)
        guard outcome == .deleted else { return outcome }
        try await worker.cleanCancelledFiles()
        try await refresh()
        publish(.libraryChanged)
        return outcome
    }

    @discardableResult public func deleteAfterMark(model: EpisodeActionModel,
        target: EpisodeMediaDeletionTarget?,
        wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(2)) },
        delete: @escaping @MainActor (EpisodeMediaDeletionTarget) async throws -> EpisodeMediaDeletionOutcome) -> Task<Void, Never> {
        Task { [self, model] in
            do {
                try await wait(); try Task.checkCancellation()
                guard preferences().deletesAfterMark(model.snapshot()) else { return }
                // Missing registration/capture is not a medialess episode. An
                // eligible cleanup must surface that failure instead of silently
                // pretending that there was no artifact to delete.
                guard let target else { throw FeedLibraryError.invalidMutation }
                if try await delete(target) == .deleted { publish(.libraryChanged) }
            } catch is CancellationError { }
            catch { publish(.storageError) }
        }
    }

    /// Source markReadWithUndo waits two seconds and reads global settings then.
    /// The app owner outlives the initiating screen; Downloads has no Undo snackbar.
    @discardableResult public func deleteAfterMark(_ item: EpisodeListItem,
        wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(2)) },
        delete: @escaping @MainActor (Int64, Bool) async throws -> Void) -> Task<Void, Never> {
        // Compatibility for callers not yet integrated with presentation lifetimes.
        // This intentionally freezes a value; it is not equivalent to a bound model.
        deleteAfterMark(model: EpisodeActionModel(item: item), wait: wait, delete: delete)
    }

    @discardableResult public func deleteAfterMark(model: EpisodeActionModel,
        wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(2)) },
        delete: @escaping @MainActor (Int64, Bool) async throws -> Void) -> Task<Void, Never> {
        Task { [self, model] in
            do {
                try await wait(); try Task.checkCancellation()
                let item = model.snapshot()
                guard preferences().deletesAfterMark(item) else { return }
                try await delete(item.episode.id, item.local)
                publish(.libraryChanged)
            } catch is CancellationError { }
            catch { publish(.storageError) }
        }
    }

    public func refresh() async throws {
        let current = try await store.downloadJobs(activeOnly: false)
        if jobs != current { jobs = current; publish(.stateChanged) }
    }

    /// The poll reads only active rows (job history grows with every download ever made) and
    /// rereads everything only when an active job changed, so `jobs` stays complete.
    private func refreshActive() async throws {
        let active = try await store.downloadJobs(activeOnly: true)
        if active != jobs.filter({ $0.state.isActive }) { try await refresh() }
    }

    private func enqueue(_ episodeID: Int64, ignoreConstraints: Bool, automatic: Bool = false) async throws {
        let generation = generation
        let preferences = preferences()
        if let job = try await store.requestDownload(episodeID: episodeID, directory: directory, enqueue: preferences.enqueue,
                                                     location: preferences.enqueueLocation,
                                                     networkConstraint: .init(ignoreConstraints: ignoreConstraints, allowMobile: preferences.allowMobile),
                                                     automatic: automatic, now: clock()) {
            try await refresh()
            guard generation == self.generation, !stopping else { throw CancellationError() }
            launch(job.id)
            publish(.libraryChanged)
        }
    }

    private func launch(_ id: Int64) {
        guard !stopping, tasks[id] == nil else { return }
        parkedForAccess.remove(id)
        let buffer = TransferProgress()
        progressBuffers[id] = buffer
        let wakePolling: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.startPolling() }
        }
        let denial = Denial()
        tasks[id] = Task { [weak self, worker, store, credentials, pollWake, accessEvents] in
            do {
                guard let job = try await store.downloadJob(id: id) else { throw FeedLibraryError.invalidMutation }
                let login = try await credentials(job.episodeID)
                let outcome = try await worker.run(id: id, credentials: login, progress: { value in
                    buffer.value.withLock { $0 = value }
                    if pollWake.take() { wakePolling() }
                },
                    attemptFailed: { [weak self] job, failure in
                        // The request title: the episode title, or the download URL without one.
                        let title = (try? await store.episode(id: job.episodeID))??.details.title
                        let report = DownloadFailureReport(jobID: job.id, episodeID: job.episodeID, title: title ?? job.source,
                                                           failure: failure, retrying: job.state != .failed)
                        await self?.publish(.attemptFailed(report))
                    }, accessDenied: { denial.at.withLock { $0 = accessEvents.count.withLock { $0 } } })
                guard let self else { return }
                try await self.refresh()
                self.finish(id)
                // Parked once its task is gone, so `resumeParked` can start it again; but an attempt denied before an
                // access event that arrived while it unwound gets one more attempt now (no polling, no loop: the next
                // denial parks unless yet another event came).
                if outcome == .waitingForAccess {
                    await self.beforeParking?()
                    if let denied = denial.at.withLock({ $0 }), denied < accessEvents.count.withLock({ $0 }) { self.launch(id) }
                    else { self.parkedForAccess.insert(id) }
                }
            } catch {
                guard let self else { return }
                self.publish(.storageError)
                self.finish(id)
            }
        }
        startPolling()
    }

    /// 1 Hz while a transfer runs. Jobs that only wait (for Wi-Fi or a retry time) change nothing
    /// a person sees until bytes flow, so polling stops and their first progress report restarts it.
    private func startPolling() {
        guard polling == nil, !stopping, !tasks.isEmpty else { return }
        pollWake.dormant.withLock { $0 = false }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, !self.tasks.isEmpty else { return }
                do { try await self.refreshActive() } catch { self.publish(.storageError) }
                let latest = self.progressBuffers.compactMapValues { $0.value.withLock { $0 } }
                let moved = self.progress != latest
                if moved { self.progress = latest; self.publish(.stateChanged) }
                if !moved, !Task.isCancelled, !self.jobs.contains(where: { $0.state == .transferring }) {
                    self.pollWake.dormant.withLock { $0 = true }
                    self.polling = nil
                    return
                }
            }
        }
    }

    private func finish(_ id: Int64) {
        tasks[id] = nil
        progress[id] = nil
        progressBuffers[id] = nil
        if tasks.isEmpty { polling?.cancel(); polling = nil }
        publish(.libraryChanged)
    }

    private func timestamp() -> Int64 { Int64(clock().timeIntervalSince1970 * 1000) }
    private func publish(_ event: Event) { for listener in listeners.values { listener.yield(event) } }
}
