import AVFoundation
import Foundation

/// Progressive HTTP source owned by one admitted playback load.
/// Construction is inert. The owner's admitted player must request bytes before HTTP starts.
final class ProgressiveHTTPMediaSource: Sendable {
    enum UnknownLengthHandling: Sendable { case waitForEOF, nativePlayback }
    enum NativeRoutingReason: Error { case unknownLength }

    let asset: AVURLAsset
    let cacheURL: URL
    private let worker: Worker

    struct Snapshot: Sendable {
        let received: Int64
        let expected: Int64?
        let completed: Bool
        let cancelled: Bool
        let pendingRequests: Int
        let largestRead: Int
        let failure: String?
        let requiresNativePlaylist: Bool
        let requiresNativePlayback: Bool
        let cleanupFailure: String?
        let cachedRanges: [Range<Int64>]
        let activeTransfers: Int
        let pendingRetries: Int
        let contentType: String?
    }

    init(url: URL, cacheDirectory: URL = FileManager.default.temporaryDirectory,
         unknownLengthHandling: UnknownLengthHandling = .waitForEOF,
         credentials: FeedCredentials? = nil, proxy: PodcastProxy = .init(),
         transientRetryLimit: Int = 3,
         userAgent: String = HTTPUserAgent.unversioned,
         onFailure: @escaping @Sendable (Error) -> Void = { _ in }) throws {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw PlaybackSourceError.invalidURL
        }
        cacheURL = cacheDirectory.appendingPathComponent("antennapod-stream-\(UUID().uuidString).cache")
        worker = Worker(url: url, cacheURL: cacheURL, unknownLengthHandling: unknownLengthHandling,
                        authentication: PlaybackHTTPAuthentication(url: url, credentials: credentials), proxy: proxy,
                        transientRetryLimit: max(0, transientRetryLimit), userAgent: userAgent, onFailure: onFailure)
        // Do not encode remote credentials or query parameters into the synthetic URL.
        asset = AVURLAsset(url: URL(string: "antennapod-stream://\(UUID().uuidString)/media")!)
        asset.resourceLoader.setDelegate(worker, queue: worker.queue)
    }

    deinit { worker.cancel() }
    func cancel() { worker.cancel() }
    func snapshot() async -> Snapshot { await worker.snapshot() }

    /// A selected player can keep retrying while its decoded audio remains usable.
    /// The owner must cancel the source when that buffer is exhausted. Raw consumers
    /// without this observer retain the bounded preparation/transfer policy.
    func observeRetryState(_ observer: @escaping @Sendable (Error?) -> Void) {
        worker.queue.async { self.worker.retryStateObserver = observer }
    }

    /// Mutable loader, session delegate and file state is confined to this serial queue.
    /// URLSession's serial delegate OperationQueue uses that same underlying queue.
    private final class Worker: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
        let queue = DispatchQueue(label: "AntennaPod.ProgressiveHTTPMediaSource")
        private let url: URL
        private let cacheURL: URL
        private let unknownLengthHandling: UnknownLengthHandling
        private let authentication: PlaybackHTTPAuthentication?
        private let onFailure: @Sendable (Error) -> Void
        private let proxy: PodcastProxy
        private let userAgent: String
        private let transientRetryLimit: Int
        private var plainSession: URLSession?
        private var secureSession: URLSession?
        private struct Transfer {
            var task: URLSessionDataTask
            var request: URLRequest
            var followUps = 0
            var proxyAuthenticationAttempted = false
            var requestedOffset: Int64
            var cursor: Int64
            var end: Int64?
            var accepted = false
            var credentialsAllowed = true
            var retryCount = 0
            var receivedAtStart: Int64 = 0
        }
        private var transfers: [ObjectIdentifier: Transfer] = [:]
        private var rangeTaskID: ObjectIdentifier?
        private var rangeValidation = HTTPMediaRangeValidation.unvalidated
        private var coverage = HTTPMediaByteCoverage()
        private var file: FileHandle?
        private var requests: [AVAssetResourceLoadingRequest] = []
        private var received: Int64 = 0
        private var expected: Int64?
        private var contentType: String?
        private var typeDetector: StreamingAudioTypeDetector?
        private var completed = false
        private var cancelled = false
        private var failure: Error?
        fileprivate var retryStateObserver: (@Sendable (Error?) -> Void)?
        private var retryThresholdExceeded = false
        private var cleanupFailure: String?
        private var largestRead = 0
        private static let blockSize = 65_536

        init(url: URL, cacheURL: URL, unknownLengthHandling: UnknownLengthHandling,
             authentication: PlaybackHTTPAuthentication?, proxy: PodcastProxy, transientRetryLimit: Int,
             userAgent: String, onFailure: @escaping @Sendable (Error) -> Void) {
            self.url = url; self.cacheURL = cacheURL; self.onFailure = onFailure
            self.unknownLengthHandling = unknownLengthHandling
            self.authentication = authentication
            self.proxy = proxy; self.userAgent = userAgent
            self.transientRetryLimit = transientRetryLimit
        }

        func snapshot() async -> Snapshot {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: Snapshot(received: self.received, expected: self.expected,
                        completed: self.completed, cancelled: self.cancelled, pendingRequests: self.requests.count,
                        largestRead: self.largestRead, failure: self.failure?.localizedDescription,
                        requiresNativePlaylist: (self.failure as? StreamingAudioTypeError) == .requiresNativePlaylist,
                        requiresNativePlayback: self.failure is NativeRoutingReason
                            || (self.failure as? StreamingAudioTypeError) == .requiresNativePlaylist,
                        cleanupFailure: self.cleanupFailure, cachedRanges: self.coverage.ranges,
                        activeTransfers: self.transfers.count,
                        pendingRetries: self.transfers.values.filter { $0.task.state == .suspended }.count,
                        contentType: self.contentType))
                }
            }
        }

        func cancel() {
            queue.async {
                guard !self.cancelled else { return }
                self.cancelled = true
                self.finishRequests(with: URLError(.cancelled))
                self.invalidateSessions()
                self.transfers.removeAll()
                self.rangeTaskID = nil
                self.cleanup()
            }
        }

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                            shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
            dispatchPrecondition(condition: .onQueue(queue))
            if cancelled || failure != nil {
                request.finishLoading(with: failure ?? URLError(.cancelled))
                return true
            }
            requests.append(request)
            if plainSession == nil, !completed { start() }
            satisfyRequests()
            if let offset = request.dataRequest?.requestedOffset { requestRemoteBytes(at: offset) }
            return true
        }

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
            dispatchPrecondition(condition: .onQueue(queue))
            requests.removeAll { $0 === request }
        }

        private func start() {
            do {
                guard FileManager.default.createFile(atPath: cacheURL.path, contents: nil,
                                                      attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                file = try FileHandle(forUpdating: cacheURL)
                let callbacks = OperationQueue()
                callbacks.maxConcurrentOperationCount = 1
                callbacks.underlyingQueue = queue
                func make(_ scheme: String) throws -> URLSession {
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.urlCache = nil; configuration.httpCookieStorage = nil
                    configuration.urlCredentialStorage = nil
                    // The selected Media3 media source uses an eight-second idle wait;
                    // the shared feed/HEAD client's thirty-second wait is a separate policy.
                    configuration.timeoutIntervalForRequest = 8
                    configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
                    configuration.waitsForConnectivity = false
                    try proxy.apply(to: configuration, scheme: scheme)
                    return URLSession(configuration: configuration, delegate: self, delegateQueue: callbacks)
                }
                plainSession = try make("http")
                secureSession = proxy.isConfigured ? try make("https") : plainSession
                beginTransfer(at: 0)
            } catch { fail(error) }
        }

        private func beginTransfer(at offset: Int64) {
            guard let session = session(for: url) else { return }
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(authentication?.authorization, forHTTPHeaderField: "Authorization")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if offset > 0 {
                request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
                request.setValue(rangeValidation.ifRange, forHTTPHeaderField: "If-Range")
            }
            let task = session.dataTask(with: request)
            transfers[ObjectIdentifier(task)] = Transfer(task: task, request: request, requestedOffset: offset,
                                                       cursor: offset, receivedAtStart: coverage.count)
            if offset > 0 { rangeTaskID = ObjectIdentifier(task) }
            task.resume()
        }

        private func session(for url: URL) -> URLSession? {
            url.scheme?.lowercased() == "https" ? secureSession : plainSession
        }
        private func invalidateSessions() {
            plainSession?.invalidateAndCancel()
            if secureSession !== plainSession { secureSession?.invalidateAndCancel() }
            plainSession = nil; secureSession = nil
        }
        private func restart(_ transfer: Transfer, request: URLRequest) {
            guard let target = request.url, let session = session(for: target), transfer.followUps < 20 else {
                fail(URLError(.httpTooManyRedirects)); return
            }
            let oldID = ObjectIdentifier(transfer.task)
            transfers.removeValue(forKey: oldID)
            transfer.task.cancel()
            var next = transfer
            next.request = request; next.followUps += 1
            next.task = session.dataTask(with: request)
            next.accepted = false
            let newID = ObjectIdentifier(next.task)
            transfers[newID] = next
            if rangeTaskID == oldID { rangeTaskID = newID }
            next.task.resume()
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            dispatchPrecondition(condition: .onQueue(queue))
            guard !cancelled, failure == nil, var transfer = transfers[ObjectIdentifier(task)],
                  let from = response.url, let to = request.url else { completionHandler(nil); return }
            var components = URLComponents(url: to, resolvingAgainstBaseURL: false)
            components?.user = nil; components?.password = nil; components?.fragment = nil
            guard let sanitized = components?.url, ["http", "https"].contains(sanitized.scheme?.lowercased() ?? "") else {
                completionHandler(nil); fail(URLError(.unsupportedURL)); return
            }
            var redirected = transfer.request
            redirected.url = sanitized
            transfer.credentialsAllowed = transfer.credentialsAllowed && HTTPOrigin.matches(from, to) && HTTPOrigin.matches(url, to)
            if !transfer.credentialsAllowed { redirected.setValue(nil, forHTTPHeaderField: "Authorization") }
            // A new session is required when crossing HTTP/HTTPS proxy mechanisms.
            // Never carry forward-proxy authorization inside the HTTPS origin tunnel.
            if sanitized.scheme?.lowercased() != "http" {
                redirected.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
            } else if transfer.proxyAuthenticationAttempted, let username = proxy.username, let password = proxy.password {
                // A later redirect back to HTTP uses the same already authenticated proxy.
                redirected.setValue(FeedCredentials(username: username, password: password).authorization(utf8: false),
                                    forHTTPHeaderField: "Proxy-Authorization")
            }
            completionHandler(nil)
            restart(transfer, request: redirected)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.isProxy() {
                if let credential = proxy.credential(for: challenge) { completionHandler(.useCredential, credential) }
                else { completionHandler(.rejectProtectionSpace, nil) }
            } else if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
            } else { completionHandler(.rejectProtectionSpace, nil) }
        }

        private func requestRemoteBytes(at offset: Int64) {
            guard !cancelled, failure == nil, !completed,
                  let expected, offset > coverage.prefixEnd, offset < expected,
                  coverage.availableEnd(at: offset) == offset else { return }
            if let rangeTaskID, let active = transfers[rangeTaskID] {
                if offset >= active.cursor, offset < (active.end ?? expected) { return }
                // A new seek can move before the active range. Retire its callbacks by task ID.
                transfers.removeValue(forKey: rangeTaskID)?.task.cancel()
                self.rangeTaskID = nil
            }
            beginTransfer(at: offset)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            dispatchPrecondition(condition: .onQueue(queue))
            guard !cancelled, failure == nil, var transfer = transfers[ObjectIdentifier(dataTask)] else {
                completionHandler(.cancel); return
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 407,
               !transfer.proxyAuthenticationAttempted, proxy.isConfigured, proxy.kind == .http,
               transfer.request.url?.scheme?.lowercased() == "http",
               let username = proxy.username, !username.isEmpty, let password = proxy.password {
                transfer.proxyAuthenticationAttempted = true
                var retry = transfer.request
                retry.setValue(FeedCredentials(username: username, password: password).authorization(utf8: false),
                               forHTTPHeaderField: "Proxy-Authorization")
                completionHandler(.cancel)
                restart(transfer, request: retry)
                return
            }
            guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode) else {
                // Retire this task before cancelling its response: the cancellation
                // callback must not fail or consume the replacement attempt.
                let id = ObjectIdentifier(dataTask)
                transfers.removeValue(forKey: id)
                if rangeTaskID == id { rangeTaskID = nil }
                completionHandler(.cancel)
                let error = MediaDownloadError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
                if !retryTransientFailure(error, transfer: transfer) { fail(error) }
                return
            }
            guard http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
                completionHandler(.cancel); fail(URLError(.cannotDecodeContentData)); return
            }
            do {
                let etag = http.value(forHTTPHeaderField: "ETag")
                if transfer.requestedOffset == 0 {
                    guard http.statusCode == 200 else { throw MediaDownloadError.invalidRange }
                    expected = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
                    // Native playback can start an open-ended response without EOF. Our
                    // byte-range loader must know the actual length before advertising it.
                    if expected == nil, unknownLengthHandling == .nativePlayback {
                        throw NativeRoutingReason.unknownLength
                    }
                    rangeValidation = HTTPMediaRangeValidation(etag: etag)
                    transfer.end = expected
                    typeDetector = try StreamingAudioTypeDetector()
                } else {
                    try rangeValidation.validate(etag: etag, isFullResponse: http.statusCode == 200)
                    guard let expected else { throw URLError(.resourceUnavailable) }
                    if http.statusCode == 206 {
                        let partial = try HTTPMediaPartialResponse(contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                            requestedOffset: transfer.requestedOffset, expectedTotal: expected,
                            contentLength: response.expectedContentLength)
                        transfer.cursor = partial.bytes.lowerBound
                        transfer.end = partial.bytes.upperBound
                    } else {
                        // A server may ignore Range. Check its length before writing; unknown
                        // response length is checked against the original total at EOF. The
                        // write path also compares every overlap with previously supplied bytes.
                        guard response.expectedContentLength < 0 || response.expectedContentLength == expected else {
                            throw URLError(.resourceUnavailable)
                        }
                        transfer.cursor = 0
                        transfer.end = expected
                    }
                }
            } catch { completionHandler(.cancel); fail(error); return }
            // MIME and filename hints can be absent or wrong. Publish content information
            // only after the native parser has identified bytes from the initial response.
            transfer.accepted = true
            transfers[ObjectIdentifier(dataTask)] = transfer
            completionHandler(.allow)
            satisfyRequests()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            dispatchPrecondition(condition: .onQueue(queue))
            guard !cancelled, failure == nil, let file,
                  var transfer = transfers[ObjectIdentifier(dataTask)], transfer.accepted else { return }
            do {
                guard Int64(data.count) <= Int64.max - transfer.cursor else { throw URLError(.dataLengthExceedsMaximum) }
                let end = transfer.cursor + Int64(data.count)
                if let limit = transfer.end, end > limit { throw URLError(.badServerResponse) }
                if transfer.requestedOffset == 0, let typeDetector {
                    try typeDetector.append(data)
                    if let type = typeDetector.typeIdentifier {
                        contentType = type
                        self.typeDetector = nil
                    }
                }
                // Validate overlaps before overwriting bytes previously supplied to AVPlayer.
                for range in coverage.ranges {
                    var cursor = max(range.lowerBound, transfer.cursor)
                    let overlapEnd = min(range.upperBound, end)
                    while cursor < overlapEnd {
                        let count = Int(min(Int64(Self.blockSize), overlapEnd - cursor))
                        try file.seek(toOffset: UInt64(cursor))
                        let previous = try file.read(upToCount: count)
                        let index = data.startIndex + Int(cursor - transfer.cursor)
                        guard previous == data[index..<(index + count)] else { throw URLError(.resourceUnavailable) }
                        cursor += Int64(count)
                    }
                }
                try file.seek(toOffset: UInt64(transfer.cursor))
                var offset = data.startIndex
                while offset < data.endIndex {
                    let end = min(data.endIndex, offset + Self.blockSize)
                    try file.write(contentsOf: data[offset..<end])
                    offset = end
                }
                let previouslyCovered = coverage.count
                coverage.insert(transfer.cursor..<end)
                if retryThresholdExceeded, contentType != nil, coverage.count > previouslyCovered {
                    retryThresholdExceeded = false
                    retryStateObserver?(nil)
                }
                transfer.cursor = end
                transfers[ObjectIdentifier(dataTask)] = transfer
                received = coverage.count
                satisfyRequests()
            } catch { fail(error) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            dispatchPrecondition(condition: .onQueue(queue))
            guard !cancelled, failure == nil, let transfer = transfers.removeValue(forKey: ObjectIdentifier(task)) else { return }
            if rangeTaskID == ObjectIdentifier(task) { rangeTaskID = nil }
            if let error {
                if retryTransientFailure(error, transfer: transfer) { return }
                fail(error); return
            }
            if let end = transfer.end, transfer.cursor != end {
                fail(MediaDownloadError.wrongSize(expected: end, received: transfer.cursor)); return
            }
            if transfer.requestedOffset == 0, let typeDetector {
                do { contentType = try typeDetector.finish(); self.typeDetector = nil }
                catch { fail(error); return }
            }
            if expected == nil { expected = transfer.cursor }
            completed = expected == coverage.prefixEnd
            if completed {
                // A complete validated replacement can make the older stalled GET redundant.
                for active in transfers.values { active.task.cancel() }
                transfers.removeAll()
                rangeTaskID = nil
                invalidateSessions()
            }
            satisfyRequests()
            if let offset = requests.reversed().compactMap({ $0.dataRequest?.currentOffset }).first(where: {
                $0 > coverage.prefixEnd && coverage.availableEnd(at: $0) == $0
            }) { requestRemoteBytes(at: offset) }
        }

        private func retryTransientFailure(_ error: Error, transfer: Transfer) -> Bool {
            let retryable: Bool
            if case MediaDownloadError.httpStatus(let status) = error {
                // Ordinary HTTP failures use the same bounded/deferred retry path
                // as interrupted transfers. An invalid position cannot recover by
                // repeating it; rejected proxy credentials retain their terminal
                // authentication boundary after the single challenge above.
                retryable = (400...599).contains(status) && status != 416 && status != 407
            } else if let error = error as? URLError {
                retryable = [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                             .cannotFindHost, .dnsLookupFailed].contains(error.code)
            } else { retryable = false }
            guard retryable, let target = transfer.request.url, let session = session(for: target) else { return false }
            let consecutive = transfer.retryCount + 1
            // Repeated/undecodable prefixes are not new media progress. Otherwise an
            // origin ignoring Range could reset the failure count forever.
            let madeProgress = contentType != nil && coverage.count > transfer.receivedAtStart
            let nextCount = madeProgress ? 1 : consecutive
            if nextCount > transientRetryLimit {
                guard let retryStateObserver else { return false }
                retryThresholdExceeded = true
                retryStateObserver(error)
            }
            var next = transfer
            // Until type/length is known, replay the prefix and retain overlap validation.
            // Otherwise resume the first unread byte, without throwing away decoded/cache data.
            let offset = expected != nil && contentType != nil ? transfer.cursor : 0
            next.requestedOffset = offset; next.cursor = offset; next.end = nil
            next.accepted = false; next.retryCount = nextCount; next.followUps = 0
            next.receivedAtStart = coverage.count
            next.request.setValue(offset > 0 ? "bytes=\(offset)-" : nil, forHTTPHeaderField: "Range")
            next.request.setValue(offset > 0 ? rangeValidation.ifRange : nil, forHTTPHeaderField: "If-Range")
            next.task = session.dataTask(with: next.request)
            let id = ObjectIdentifier(next.task)
            transfers[id] = next
            if offset > 0 { rangeTaskID = id }
            // Media3's retry delay is 0,1,2... seconds, capped at5. New media progress
            // resets the consecutive-failure count for subsequent attempts.
            let delay = min(consecutive - 1, 5)
            queue.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in
                guard let self, !cancelled, failure == nil, let pending = transfers[id] else { return }
                pending.task.resume()
            }
            satisfyRequests()
            return true
        }

        private func satisfyRequests() {
            dispatchPrecondition(condition: .onQueue(queue))
            guard !cancelled, failure == nil, let file else { return }
            do {
                requests.removeAll { $0.isCancelled || $0.isFinished }
                for request in requests {
                    if let information = request.contentInformationRequest {
                        // An unknown length is not zero. Defer content information until known.
                        guard let expected, let contentType else { continue }
                        if let allowed = information.allowedContentTypes, !allowed.contains(contentType) {
                            throw URLError(.cannotDecodeContentData)
                        }
                        information.contentType = contentType
                        information.contentLength = expected
                        // Only written intervals can be read, including verified remote ranges.
                        information.isByteRangeAccessSupported = true
                        information.isEntireLengthAvailableOnDemand = completed
                    }
                    guard let body = request.dataRequest else { request.finishLoading(); continue }
                    guard body.currentOffset >= 0, body.requestedOffset >= 0,
                          Int64(body.requestedLength) <= Int64.max - body.requestedOffset else {
                        request.finishLoading(with: URLError(.badURL)); continue
                    }
                    let requestedEnd = body.requestsAllDataToEndOfResource ? Int64.max
                        : body.requestedOffset + Int64(body.requestedLength)
                    let end = min(requestedEnd, expected ?? Int64.max)
                    var cursor = body.currentOffset
                    let availableEnd = min(coverage.availableEnd(at: cursor), end)
                    while cursor < availableEnd {
                        let count = Int(min(Int64(Self.blockSize), availableEnd - cursor))
                        try file.seek(toOffset: UInt64(cursor))
                        guard let bytes = try file.read(upToCount: count), bytes.count == count else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        largestRead = max(largestRead, count)
                        body.respond(with: bytes)
                        cursor += Int64(count)
                    }
                    if cursor >= end { request.finishLoading() }
                }
                requests.removeAll { $0.isCancelled || $0.isFinished }
            } catch { fail(error) }
        }

        private func finishRequests(with error: Error) {
            for request in requests where !request.isCancelled && !request.isFinished {
                request.finishLoading(with: error)
            }
            requests.removeAll()
        }

        private func fail(_ error: Error) {
            guard failure == nil, !cancelled else { return }
            failure = error
            finishRequests(with: error)
            invalidateSessions()
            transfers.removeAll()
            rangeTaskID = nil
            cleanup()
            // AVPlayer may report a successful seek and retain readyToPlay after a resource
            // request fails. The playback owner must receive the transport failure directly.
            onFailure(error)
        }

        private func cleanup() {
            typeDetector?.close()
            typeDetector = nil
            do { try file?.close() } catch { cleanupFailure = error.localizedDescription }
            file = nil
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                do { try FileManager.default.removeItem(at: cacheURL) }
                catch { cleanupFailure = error.localizedDescription }
            }
        }
    }
}
