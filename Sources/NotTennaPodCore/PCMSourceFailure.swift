import Foundation

/// One terminal source error, observable without pulling another decoded packet.
/// Each subscriber gets its own bounded stream, including an error recorded before subscribing.
final class PCMSourceFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: (any Error)?
    private var finished = false
    private var subscribers: [UUID: AsyncStream<any Error>.Continuation] = [:]

    var error: (any Error)? { lock.withLock { storedError } }
    var subscriberCount: Int { lock.withLock { subscribers.count } }
    func check() throws { if let error { throw error } }

    func events() -> AsyncStream<any Error> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in self?.remove(id) }
        let terminal = lock.withLock { () -> (Bool, (any Error)?) in
            if !finished { subscribers[id] = continuation }
            return (finished, storedError)
        }
        if terminal.0 {
            if let error = terminal.1 { continuation.yield(error) }
            continuation.finish()
        }
        return stream
    }

    func fail(_ error: any Error) { finish(error: error) }
    func finish() { finish(error: nil) }

    private func finish(error: (any Error)?) {
        let continuations = lock.withLock { () -> [AsyncStream<any Error>.Continuation] in
            guard !finished else { return [] }
            finished = true
            storedError = error
            let active = Array(subscribers.values)
            subscribers.removeAll()
            return active
        }
        // Finishing may invoke onTermination synchronously; never do it under the lock.
        for continuation in continuations {
            if let error { continuation.yield(error) }
            continuation.finish()
        }
    }

    private func remove(_ id: UUID) { lock.withLock { _ = subscribers.removeValue(forKey: id) } }
}
