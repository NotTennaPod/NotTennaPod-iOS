import Foundation
import Network
import Synchronization

/// Ask the OS which local endpoint routes to an already-known receiver. This
/// opens a UDP flow without sending application data or scanning the network.
public enum ReceiverNetworkRoute {
    public static func endpoint(address: String, port: UInt16) async throws -> NativeRelayEndpoint {
        _ = try NativeRelayEndpoint.receiver(address: address)
        guard port > 0 else { throw URLError(.badURL) }
        let probe = Probe(address: address, port: port)
        return try await withThrowingTaskGroup(of: NativeRelayEndpoint.self) { group in
            group.addTask { try await probe.run() }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private final class Probe: @unchecked Sendable {
        private struct State {
            var finished = false
            var continuation: CheckedContinuation<NativeRelayEndpoint, Error>?
        }
        private let state = Mutex(State())
        private let connection: NWConnection
        init(address: String, port: UInt16) {
            connection = NWConnection(host: .init(address), port: .init(rawValue: port)!, using: .udp)
        }
        func run() async throws -> NativeRelayEndpoint {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    let start = state.withLock { value in
                        guard !value.finished else { return false }
                        value.continuation = continuation; return true
                    }
                    guard start else { continuation.resume(throwing: CancellationError()); return }
                    connection.stateUpdateHandler = { [weak self] status in
                        guard let self else { return }
                        switch status {
                        case .ready:
                            do {
                                guard case .hostPort(let host, _) = self.connection.currentPath?.localEndpoint else {
                                    throw URLError(.cannotConnectToHost)
                                }
                                self.finish(.success(try .receiver(address: host.debugDescription)))
                            } catch { self.finish(.failure(error)) }
                        case .waiting(let error), .failed(let error): self.finish(.failure(error))
                        case .cancelled: self.finish(.failure(CancellationError()))
                        default: break
                        }
                    }
                    connection.start(queue: .global(qos: .userInitiated))
                }
            } onCancel: { self.finish(.failure(CancellationError())) }
        }
        private func finish(_ result: Result<NativeRelayEndpoint, Error>) {
            let continuation = state.withLock { value in
                guard !value.finished else { return Optional<CheckedContinuation<NativeRelayEndpoint, Error>>.none }
                value.finished = true
                let continuation = value.continuation; value.continuation = nil; return continuation
            }
            connection.cancel()
            continuation?.resume(with: result)
        }
    }
}
