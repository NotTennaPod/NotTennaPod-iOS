import Foundation

/// Request-private delegate delivery with one retained framework chunk and bounded
/// outgoing slices. Only active consumer header/body waits have an idle deadline.
final class NativeRelayBody: Sendable {
    let response: HTTPURLResponse
    private let worker: Worker
    static let maximumChunkBytes = 65_536
    struct Snapshot: Sendable {
        let bufferedBytes, largestBufferedBytes, largestReturnedBytes: Int
        let consumerPaused, waitingConsumer, completed, cancelled: Bool
    }

    static func open(request: URLRequest, configuration: URLSessionConfiguration,
                     delegate: RelaySessionDelegate) async throws -> NativeRelayBody {
        let worker = Worker(configuration: configuration, delegate: delegate)
        worker.start(request)
        do {
            let response = try await withTaskCancellationHandler {
                try await worker.response()
            } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            return NativeRelayBody(response: response, worker: worker)
        } catch { worker.cancel(); throw error }
    }
    private init(response: HTTPURLResponse, worker: Worker) { self.response = response; self.worker = worker }
    deinit { worker.cancel() }
    func next() async throws -> Data? {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            let chunk = try await worker.next()
            try Task.checkCancellation()
            return chunk
        } onCancel: { worker.cancel() }
    }
    func cancel() { worker.cancel() }
    var snapshot: Snapshot { worker.snapshot() }

    private final class Worker: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let condition = NSCondition()
        private let configuration: URLSessionConfiguration
        private let policy: RelaySessionDelegate
        private let inactivitySeconds: TimeInterval
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var idleTask: Task<Void, Never>?
        private var idleID: UUID?
        private var headers: HTTPURLResponse?
        private var responseWaiter: CheckedContinuation<HTTPURLResponse, any Error>?
        private var bodyWaiter: CheckedContinuation<Data?, any Error>?
        private var buffer: Data?
        private var offset = 0
        private var largestBuffered = 0, largestReturned = 0
        private var completed = false, cancelled = false
        private var error: (any Error)?

        init(configuration: URLSessionConfiguration, delegate: RelaySessionDelegate) {
            inactivitySeconds = configuration.timeoutIntervalForRequest
            let copy = configuration.copy() as! URLSessionConfiguration
            copy.timeoutIntervalForRequest = .greatestFiniteMagnitude
            self.configuration = copy; policy = delegate
        }
        func start(_ request: URLRequest) {
            condition.lock(); defer { condition.unlock() }
            let callbacks = OperationQueue()
            callbacks.name = "AntennaPod.RelayBody"
            callbacks.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: callbacks)
            var request = request
            request.timeoutInterval = .greatestFiniteMagnitude
            let task = session.dataTask(with: request)
            self.session = session; self.task = task
            armIdleDeadline()
            task.resume()
        }
        func response() async throws -> HTTPURLResponse {
            try await withCheckedThrowingContinuation { continuation in
                condition.lock()
                let result: Result<HTTPURLResponse, any Error>?
                if cancelled { result = .failure(CancellationError()) }
                else if let headers { result = .success(headers) }
                else if let error { result = .failure(error) }
                else if completed { result = .failure(URLError(.badServerResponse)) }
                else { responseWaiter = continuation; result = nil }
                condition.unlock()
                if let result { continuation.resume(with: result) }
            }
        }
        func next() async throws -> Data? {
            try await withCheckedThrowingContinuation { continuation in
                condition.lock()
                let result: Result<Data?, any Error>?
                if cancelled { result = .failure(CancellationError()) }
                else if bodyWaiter != nil { result = .failure(URLError(.resourceUnavailable)) }
                else if let chunk = takeChunk() { result = .success(chunk) }
                else if let error { result = .failure(error) }
                else if completed { result = .success(nil) }
                else {
                    bodyWaiter = continuation; result = nil
                    armIdleDeadline()
                }
                condition.unlock()
                if let result { continuation.resume(with: result) }
            }
        }
        private func takeChunk() -> Data? {
            guard let buffer else { return nil }
            let end = min(buffer.count, offset + NativeRelayBody.maximumChunkBytes)
            let chunk = buffer.subdata(in: offset..<end)
            offset = end
            largestReturned = max(largestReturned, chunk.count)
            if offset == buffer.count { self.buffer = nil; offset = 0; condition.broadcast() }
            return chunk
        }
        func cancel() {
            condition.lock()
            guard !cancelled else { condition.unlock(); return }
            cancelled = true; buffer = nil; offset = 0
            disarmIdleDeadline()
            let session = self.session, task = self.task
            self.session = nil; self.task = nil
            let response = responseWaiter, body = bodyWaiter
            responseWaiter = nil; bodyWaiter = nil
            condition.broadcast(); condition.unlock()
            task?.cancel(); session?.invalidateAndCancel()
            response?.resume(throwing: CancellationError()); body?.resume(throwing: CancellationError())
        }
        private func armIdleDeadline() {
            disarmIdleDeadline()
            let id = UUID(); idleID = id
            let deadline = ContinuousClock.now + .seconds(inactivitySeconds)
            idleTask = Task { [weak self] in
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                self?.expireIdleDeadline(id)
            }
        }
        private func disarmIdleDeadline() {
            idleTask?.cancel(); idleTask = nil; idleID = nil
        }
        private func expireIdleDeadline(_ id: UUID) {
            condition.lock()
            guard idleID == id, !cancelled, !completed else { condition.unlock(); return }
            let failure = URLError(.timedOut)
            completed = true; error = failure
            disarmIdleDeadline()
            let session = self.session, task = self.task
            self.session = nil; self.task = nil
            let response = responseWaiter, body = bodyWaiter
            responseWaiter = nil; bodyWaiter = nil
            condition.broadcast(); condition.unlock()
            task?.cancel(); session?.invalidateAndCancel()
            response?.resume(throwing: failure); body?.resume(throwing: failure)
        }
        func snapshot() -> Snapshot {
            condition.lock(); defer { condition.unlock() }
            return Snapshot(bufferedBytes: (buffer?.count ?? 0) - offset,
                largestBufferedBytes: largestBuffered, largestReturnedBytes: largestReturned,
                consumerPaused: headers != nil && bodyWaiter == nil && !completed && !cancelled,
                waitingConsumer: bodyWaiter != nil, completed: completed, cancelled: cancelled)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            condition.lock()
            guard !cancelled, !completed, let http = response as? HTTPURLResponse else {
                condition.unlock(); completionHandler(.cancel); return
            }
            headers = http
            disarmIdleDeadline()
            let waiter = responseWaiter; responseWaiter = nil
            condition.unlock()
            waiter?.resume(returning: http)
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard !data.isEmpty else { return }
            condition.lock()
            guard !cancelled, !completed else { condition.unlock(); return }
            buffer = data; offset = 0; largestBuffered = max(largestBuffered, data.count)
            disarmIdleDeadline()
            let waiter = bodyWaiter; bodyWaiter = nil
            let chunk = waiter == nil ? nil : takeChunk()
            condition.unlock()
            waiter?.resume(returning: chunk)
            // This callback is synchronous and has a request-private serial queue.
            // Keep the current delivery until the consumer drains it. Do not suspend
            // URLSessionTask: repeated chunked responses lose completion after that
            // suspend/resume on the tested runtime. No cooperative task blocks here.
            condition.lock()
            while buffer != nil && !cancelled && !completed { condition.wait() }
            condition.unlock()
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            condition.lock()
            guard !cancelled, !completed else { condition.unlock(); return }
            completed = true; self.error = error
            disarmIdleDeadline()
            self.session = nil; self.task = nil
            let response = responseWaiter, body = bodyWaiter
            responseWaiter = nil; bodyWaiter = nil
            condition.unlock()
            session.finishTasksAndInvalidate()
            response?.resume(throwing: error ?? URLError(.badServerResponse))
            if let error { body?.resume(throwing: error) } else { body?.resume(returning: nil) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response,
                newRequest: request, completionHandler: completionHandler)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            policy.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
        }
    }
}
