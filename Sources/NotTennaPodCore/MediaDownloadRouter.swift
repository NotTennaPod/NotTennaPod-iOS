import Foundation
import Synchronization

/// Chooses the transfer engine per request. The background session is used when it reproduces the
/// request exactly: no feed or URL credentials (Latin-1-then-UTF-8 Basic retries and cross-origin
/// `Authorization` removal need per-hop control) and no configured proxy (every download
/// must use it). Everything else runs on the verified foreground engine, which
/// keeps running with granted background time and pauses cleanly when that time ends.
public final class MediaDownloadRouter: MediaTransferring, Sendable {
    public static let availableCapacity: @Sendable (URL) throws -> Int64 = { destination in
        let values = try destination.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values.volumeAvailableCapacityForImportantUsage { return capacity }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: destination.deletingLastPathComponent().path)
        return (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }

    private struct Gate {
        var paused = false
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
        var running: [UUID: Task<MediaDownloadResult, any Error>] = [:]
        var stopped: Set<UUID> = []
    }

    private let foreground: any MediaTransferring
    private let background: BackgroundMediaDownloads?
    private let userAgent: String
    private let proxyConfigured: @Sendable () -> Bool
    private let gate = Mutex(Gate())

    public init(foreground: any MediaTransferring, background: BackgroundMediaDownloads?, userAgent: String,
                proxyConfigured: @escaping @Sendable () -> Bool) {
        self.foreground = foreground; self.background = background
        self.userAgent = userAgent; self.proxyConfigured = proxyConfigured
    }

    public static func usesBackgroundSession(_ input: MediaDownloadRequest, proxyConfigured: Bool) -> Bool {
        guard !proxyConfigured else { return false }
        if let credentials = input.credentials, credentials.username?.isEmpty == false || credentials.password?.isEmpty == false {
            return false
        }
        guard let url = try? FeedAddress.requestURL(input.source),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return true }
        return components.user == nil && components.password == nil
    }

    public func download(_ input: MediaDownloadRequest,
                         progress: @escaping @Sendable (MediaDownloadProgress) -> Void) async throws -> MediaDownloadResult {
        if let background, Self.usesBackgroundSession(input, proxyConfigured: proxyConfigured()) {
            return try await background.download(input, userAgent: userAgent, progress: progress)
        }
        return try await runForeground(input, progress: progress)
    }

    /// Background time ended: foreground-engine transfers stop as an interruption (partial file kept, no
    /// attempt counted) and new ones wait until `resumeForegroundTransfers`.
    public func pauseForegroundTransfers() {
        let running = gate.withLock { gate -> [Task<MediaDownloadResult, any Error>] in
            gate.paused = true
            gate.stopped.formUnion(gate.running.keys)
            return Array(gate.running.values)
        }
        for task in running { task.cancel() }
    }

    public func resumeForegroundTransfers() {
        let waiters = gate.withLock { gate -> [CheckedContinuation<Void, any Error>] in
            gate.paused = false
            defer { gate.waiters.removeAll() }
            return Array(gate.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }

    private func runForeground(_ input: MediaDownloadRequest,
                               progress: @escaping @Sendable (MediaDownloadProgress) -> Void) async throws -> MediaDownloadResult {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let ready: Result<Void, any Error>? = gate.withLock { gate in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    guard gate.paused else { return .success(()) }
                    gate.waiters[id] = continuation
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            self.gate.withLock { $0.waiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
        let foreground = foreground
        let task = Task { try await foreground.download(input, progress: progress) }
        let registered = gate.withLock { gate -> Bool in
            guard !gate.paused else { return false }
            gate.running[id] = task
            return true
        }
        guard registered else { task.cancel(); _ = try? await task.value; throw DownloadNetworkInterruption.constraintsChanged }
        defer { gate.withLock { gate in gate.running[id] = nil; gate.stopped.remove(id) } }
        do {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            if !Task.isCancelled, gate.withLock({ $0.stopped.contains(id) }) { throw DownloadNetworkInterruption.constraintsChanged }
            throw error
        }
    }
}
