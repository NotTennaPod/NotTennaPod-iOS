import Foundation
import Network
import Synchronization

public enum DownloadNetworkInterruption: Error, Sendable { case constraintsChanged }

public final class DownloadNetworkMonitor: @unchecked Sendable {
    public static let shared = DownloadNetworkMonitor()

    private struct Waiter {
        let constraint: DownloadNetworkConstraint
        let invalidatedAfter: UInt64?
        let continuation: CheckedContinuation<Void, any Error>
    }
    private struct State {
        var network: DownloadNetworkState?
        var waiters: [UUID: Waiter] = [:]
        var observers: [UUID: CheckedContinuation<DownloadNetworkState, any Error>] = [:]
        /// Every later path change (the server sync scheduler retries when the network returns).
        var listeners: [UUID: AsyncStream<DownloadNetworkState>.Continuation] = [:]
        var revision: UInt64 = 0
        var disconnectedRevision: UInt64 = 0
        /// The last update an UNMETERED job may not continue across: a metered or a Low Data network.
        var meteredRevision: UInt64 = 0
    }
    private enum OperationResult<Value: Sendable>: Sendable { case completed(Value), networkLost }
    private let monitor = NWPathMonitor()
    private let state = Mutex(State())

    public convenience init() { self.init(startMonitoring: true) }

    init(startMonitoring: Bool) {
        guard startMonitoring else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(Self.nativeState(status: path.status, isExpensive: path.isExpensive,
                                          usesCellular: path.usesInterfaceType(.cellular),
                                          usesWiFi: path.usesInterfaceType(.wifi), usesEthernet: path.usesInterfaceType(.wiredEthernet),
                                          isConstrained: path.isConstrained))
        }
        monitor.start(queue: DispatchQueue(label: "AntennaPod.DownloadNetwork"))
    }

    deinit { monitor.cancel() }

    static func nativeState(status: NWPath.Status, isExpensive: Bool, usesCellular: Bool, usesWiFi: Bool = false, usesEthernet: Bool = false,
                            isConstrained: Bool = false) -> DownloadNetworkState {
        // Android ConnectivityService.isActiveNetworkMetered returns true when
        // active capabilities are absent. An unsatisfied iOS path's expense flag
        // alone must not make the source's offline streaming warning disappear.
        .init(connected: status == .satisfied, metered: status != .satisfied || isExpensive,
              cellular: usesCellular, transport: usesWiFi ? .wifi : (usesEthernet ? .ethernet : .other), constrained: isConstrained)
    }

    public var current: DownloadNetworkState? { state.withLock { $0.network } }
    var pendingWaitCount: Int { state.withLock { $0.waiters.count } }
    var pendingObservationCount: Int { state.withLock { $0.observers.count } }

    public func observedState() async throws -> DownloadNetworkState {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<DownloadNetworkState, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if let network = state.network { return .success(network) }
                    state.observers[id] = continuation
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            self.state.withLock { $0.observers.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    /// Every path change from now on.
    public func changes() -> AsyncStream<DownloadNetworkState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<DownloadNetworkState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        state.withLock { $0.listeners[id] = continuation }
        continuation.onTermination = { [weak self] _ in _ = self?.state.withLock { $0.listeners.removeValue(forKey: id) } }
        return stream
    }

    public func waitUntilPermitted(_ constraint: DownloadNetworkConstraint) async throws {
        try await wait(constraint, invalidatedAfter: nil)
    }

    public func perform<Value: Sendable>(under constraint: DownloadNetworkConstraint,
                                         operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard let revision = state.withLock({ state -> UInt64? in
            guard let network = state.network, constraint.permits(network) else { return nil }
            return state.revision
        }) else { throw DownloadNetworkInterruption.constraintsChanged }
        do {
            return try await withThrowingTaskGroup(of: OperationResult<Value>.self) { group in
                defer { group.cancelAll() }
                group.addTask {
                    try Task.checkCancellation()
                    return .completed(try await operation())
                }
                group.addTask {
                    try await self.wait(constraint, invalidatedAfter: revision)
                    return .networkLost
                }
                switch try await group.next()! {
                case .completed(let value):
                    try Task.checkCancellation()
                    if self.invalidated(constraint, after: revision) { throw DownloadNetworkInterruption.constraintsChanged }
                    return value
                case .networkLost: throw DownloadNetworkInterruption.constraintsChanged
                }
            }
        } catch {
            try Task.checkCancellation()
            if invalidated(constraint, after: revision) { throw DownloadNetworkInterruption.constraintsChanged }
            throw error
        }
    }

    private func invalidated(_ constraint: DownloadNetworkConstraint, after revision: UInt64) -> Bool {
        state.withLock { Self.lossRevision(constraint, $0) > revision }
    }

    private static func lossRevision(_ constraint: DownloadNetworkConstraint, _ state: State) -> UInt64 {
        constraint == .connected ? state.disconnectedRevision : max(state.disconnectedRevision, state.meteredRevision)
    }

    private func wait(_ constraint: DownloadNetworkConstraint, invalidatedAfter: UInt64?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if let revision = invalidatedAfter {
                        if Self.lossRevision(constraint, state) > revision { return .success(()) }
                    } else if let network = state.network, constraint.permits(network) { return .success(()) }
                    state.waiters[id] = Waiter(constraint: constraint, invalidatedAfter: invalidatedAfter, continuation: continuation)
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let waiter = self.state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func update(_ network: DownloadNetworkState) {
        let ready = state.withLock { state in
            state.network = network
            state.revision += 1
            if !network.connected { state.disconnectedRevision = state.revision }
            if network.metered || network.constrained { state.meteredRevision = state.revision }
            let ready = state.waiters.filter { _, waiter in
                if let revision = waiter.invalidatedAfter { return Self.lossRevision(waiter.constraint, state) > revision }
                return waiter.constraint.permits(network)
            }
            for id in ready.keys { state.waiters[id] = nil }
            let observers = Array(state.observers.values)
            state.observers.removeAll()
            return (Array(ready.values), observers, Array(state.listeners.values))
        }
        for waiter in ready.0 { waiter.continuation.resume() }
        for observer in ready.1 { observer.resume(returning: network) }
        for listener in ready.2 { listener.yield(network) }
    }
}
