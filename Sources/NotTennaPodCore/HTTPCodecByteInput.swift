import Foundation

/// HTTP input for native decoder callbacks with disk or sliding-memory backing.
/// Construction is inert. Disk reads start sequentially; explicit seeks or missing
/// memory-window bytes enable validated range acquisition.
final class HTTPCodecByteInput: MediaByteLeaseSource {
    enum Failure: Error { case invalidReadAhead }
    /// Shared-cache callers retain media in span files; their network leg needs
    /// only a sliding memory window. Missing older bytes are reacquired by HTTP.
    enum Backing: Sendable {
        case disk
        case memory(capacity: Int, knownLength: Int64? = nil)
    }
    let cacheURL: URL
    let sourceFailure: PCMSourceFailure?
    let sourceRetry: PCMSourceRetry?
    private let worker: Worker
    var length: Int64? { worker.snapshot().length }
    /// Header-resolved total, including later requests; EOF alone never declares it.
    var declaredLength: Int64? { worker.snapshot().declaredLength }
    var initialDeclaredLength: Int64? { worker.snapshot().initialDeclaredLength }
    var supportsRandomAccess: Bool { worker.snapshot().supportsRandomAccess }
    var isWaitingForData: Bool { worker.isWaitingForData() }
    var httpRepresentation: HTTPMediaRepresentation? { worker.snapshot().representation }
    func prepareForSeek() { worker.prepareForSeek() }
    func allowDecoderRangeSeeks() { worker.allowDecoderRangeSeeks() }
    func prepareForIndexedSeek(to offset: Int64) { worker.prepareForIndexedSeek(to: offset) }
    struct Snapshot: Sendable {
        let received: Int64
        let length: Int64?
        let declaredLength: Int64?
        let initialDeclaredLength: Int64?
        let completed: Bool
        let cancelled: Bool
        let waitingReaders: Int
        let largestRead: Int
        let failure: String?
        let cleanupFailure: String?
        let activeTransfers: Int
        let cachedRanges: [Range<Int64>]
        let supportsRandomAccess: Bool
        let sequentialDemandLimit: Int64?
        let waitingForDemand: Bool
        let memoryBytes: Int
        let pendingRetry: Bool
        let representation: HTTPMediaRepresentation?
        let representationRejected: Bool
    }

    /// Read-ahead is for sources whose upstream owns network deadlines (the MP3
    /// relay). Disk-backed sequential readers reconstruct linearly. Memory-backed
    /// cache misses may reopen ranges when bytes have left their bounded window.
    init(url: URL, cacheDirectory: URL = .temporaryDirectory, sequentialReadAheadBytes: Int? = nil, backing: Backing = .disk,
         retry: PCMSourceRetry? = nil, expectedRepresentation: HTTPMediaRepresentation? = nil) throws {
        guard sequentialReadAheadBytes.map({ $0 >= 0 }) ?? true else { throw Failure.invalidReadAhead }
        guard expectedRepresentation?.length.map({ $0 >= 0 }) ?? true else { throw Failure.invalidReadAhead }
        if case let .memory(capacity, knownLength) = backing {
            guard let sequentialReadAheadBytes, capacity >= 65_536,
                  Int128(capacity) >= Int128(sequentialReadAheadBytes) + 65_536,
                  knownLength.map({ $0 >= 0 }) ?? true else { throw Failure.invalidReadAhead }
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else {
            throw PlaybackSourceError.invalidURL
        }
        cacheURL = cacheDirectory.appendingPathComponent("antennapod-codec-\(UUID()).cache")
        let sourceFailure = PCMSourceFailure()
        self.sourceFailure = sourceFailure
        self.sourceRetry = retry
        worker = Worker(url: url, cacheURL: cacheURL, sourceFailure: sourceFailure, sequentialReadAheadBytes: sequentialReadAheadBytes,
            backing: backing, retry: retry, expectedRepresentation: expectedRepresentation)
    }
    /// Reads through `relay`, a loopback relay iOS may reclaim while the app is suspended
    ///. With `reclaim`, the relay is retired when the app becomes eligible for
    /// suspension and reopened on the next demand; reading continues at the same cursor.
    /// A local connection failure rebuilds the relay at most once per epoch until bytes
    /// arrive, before the retry budget; upstream failures reported by the relay never do.
    convenience init(relay: NativeStreamingRelay, reclaim: StreamingRelayReclaim?, sequentialReadAheadBytes: Int? = nil,
                     backing: Backing = .disk, retry: PCMSourceRetry? = nil,
                     expectedRepresentation: HTTPMediaRepresentation? = nil) throws {
        try self.init(url: relay.url, sequentialReadAheadBytes: sequentialReadAheadBytes, backing: backing, retry: retry,
            expectedRepresentation: expectedRepresentation)
        worker.link(relay: relay, reclaim: reclaim)
    }
    deinit { worker.cancel() }
    func read(at offset: Int64, maximumCount: Int) throws -> Data { try worker.read(at: offset, maximumCount: maximumCount) }
    func checkFailure() throws { try worker.checkFailure() }
    func cancel() { worker.cancel() }
    func snapshot() -> Snapshot { worker.snapshot() }

    /// A demux generation may interrupt its reads without retiring the source/cache.
    /// The source owner must still cancel the source when the playback item is retired.
    func makeReadLease() -> any MediaByteInput { makePlaybackLease() }

    /// Reusable reader scope: that reader may replace its demux on seek. Cancelling
    /// the reader still leaves the playback item's cache owned by the caller.
    func makePlaybackLease() -> any MediaByteLeaseSource { ReadLease(owner: self) }

    /// Accessed only while the owning worker's condition is locked.
    private final class ReadCancellation: @unchecked Sendable { var cancelled = false; var waiting = false }

    private final class ReadLease: MediaByteLeaseSource {
        private let owner: HTTPCodecByteInput
        private let cancellation = ReadCancellation()
        init(owner: HTTPCodecByteInput) { self.owner = owner }
        deinit { owner.worker.cancelRead(cancellation) }
        var sourceFailure: PCMSourceFailure? { owner.sourceFailure }
        var sourceRetry: PCMSourceRetry? { owner.sourceRetry }
        var length: Int64? { owner.length }
        var declaredLength: Int64? { owner.declaredLength }
        var initialDeclaredLength: Int64? { owner.initialDeclaredLength }
        var httpRepresentation: HTTPMediaRepresentation? { owner.httpRepresentation }
        var supportsRandomAccess: Bool { owner.supportsRandomAccess }
        var isWaitingForData: Bool { owner.worker.isWaitingForData(cancellation: cancellation) }
        func prepareForSeek() { owner.worker.prepareForSeek(cancellation: cancellation) }
        func prepareForIndexedSeek(to offset: Int64) { owner.worker.prepareForIndexedSeek(to: offset, cancellation: cancellation) }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            try owner.worker.read(at: offset, maximumCount: maximumCount, cancellation: cancellation)
        }
        func checkFailure() throws { try owner.worker.checkFailure(cancellation: cancellation) }
        func cancel() { owner.worker.cancelRead(cancellation) }
        func makeReadLease() -> any MediaByteInput { owner.makeReadLease() }
    }

    /// All mutable state, including file access and condition predicates, is protected by
    /// condition. URLSession callbacks use a different queue from the blocked decoder.
    private final class Worker: NSObject, URLSessionDataDelegate, StreamingRelayReclaimParticipant, @unchecked Sendable {
        private let condition = NSCondition()
        private var url: URL
        private let cacheURL: URL
        private let sourceFailure: PCMSourceFailure
        private let sequentialReadAheadBytes: Int?
        private let memoryCapacity: Int?
        private var memory = Data()
        private var memoryStart: Int64 = 0
        private var requestedThrough: Int64 = 0
        private var demandWaiters = 0
        private var sequentialDemandLimit: Int64? {
            sequentialReadAheadBytes.map { Int64(clamping: Int128(requestedThrough) + Int128($0)) }
        }
        private var session: URLSession?
        private var file: FileHandle?
        private var started = false
        private var initialResponseAccepted = false
        private var coverage = HTTPMediaByteCoverage()
        private var rangeReads = false
        private var decoderRangeSeeksAllowed = false
        private var indexedReads = false
        private var rangeValidation = HTTPMediaRangeValidation.unvalidated
        private var representationRejected = false
        private let expectedRepresentation: HTTPMediaRepresentation?
        private struct Transfer {
            let task: URLSessionDataTask
            let requestedOffset: Int64
            var cursor: Int64
            var end: Int64?
            var accepted = false
            var isWholeBody = false
        }
        private var transfers: [Int: Transfer] = [:]
        private var rangeTaskID: Int?
        private var length: Int64?
        private var declaredLength: Int64?
        private var initialDeclaredLength: Int64?
        private var completed = false
        private var cancelled = false
        private var waitingReaders = 0
        private var largestRead = 0
        private var failure: (any Error)?
        private var cleanupFailure: String?
        private let retry: PCMSourceRetry?
        private var pendingLoad: (error: any Error, position: Int64)?
        private var retryTask: Task<Void, Never>?
        private var retryID: UUID?
        // The loopback relay this input reads through, which iOS may reclaim.
        private var relay: NativeStreamingRelay?
        private var relayGeneration: UInt64 = 0
        private var reclaim: StreamingRelayReclaim?
        /// The registry epoch last reconciled; an older notification changes nothing.
        private var lifecycleEpoch: UInt64 = 0
        /// Retired with the relay: no transfer starts until a demand reopens it.
        private var parked = false
        /// A relay replacement (resume or repair) in flight; only it starts the next transfer.
        private var relayChange: (id: UInt64, task: Task<Void, Never>)?
        private var relayChangeID: UInt64 = 0
        /// Where reading continues once the relay is back: the cursor of the retired transfer.
        private var resumeOffset: Int64?
        /// The epoch of the last local-failure repair, and whether bytes arrived since.
        private var repair: (epoch: UInt64, progressed: Bool)?
        private var relayUnavailable: Bool { parked || relayChange != nil }
        init(url: URL, cacheURL: URL, sourceFailure: PCMSourceFailure, sequentialReadAheadBytes: Int?, backing: Backing,
             retry: PCMSourceRetry?, expectedRepresentation: HTTPMediaRepresentation?) {
            self.url = url; self.cacheURL = cacheURL; self.sourceFailure = sourceFailure
            self.retry = retry
            self.expectedRepresentation = expectedRepresentation
            rangeValidation = expectedRepresentation?.validation ?? .unvalidated
            self.sequentialReadAheadBytes = sequentialReadAheadBytes
            switch backing {
            case .disk: memoryCapacity = nil
            case let .memory(capacity, knownLength):
                memoryCapacity = capacity; length = knownLength; declaredLength = knownLength
            }
            if let expected = expectedRepresentation?.length { length = expected; declaredLength = expected }
            initialDeclaredLength = declaredLength
        }

        func snapshot() -> Snapshot {
            condition.lock(); defer { condition.unlock() }
            return Snapshot(received: coverage.count, length: length, declaredLength: declaredLength,
                initialDeclaredLength: initialDeclaredLength,
                completed: completed, cancelled: cancelled,
                waitingReaders: waitingReaders, largestRead: largestRead,
                failure: failure?.localizedDescription, cleanupFailure: cleanupFailure,
                activeTransfers: transfers.count, cachedRanges: coverage.ranges,
                supportsRandomAccess: !cancelled && failure == nil && (completed || (rangeReads && initialResponseAccepted)),
                sequentialDemandLimit: sequentialDemandLimit, waitingForDemand: demandWaiters > 0, memoryBytes: memory.count,
                pendingRetry: pendingLoad != nil || retryTask != nil || retry?.requiresDeferredRestart == true,
                representation: initialResponseAccepted ? HTTPMediaRepresentation(length: declaredLength, validation: rangeValidation) : expectedRepresentation,
                representationRejected: representationRejected)
        }

        func isWaitingForData(cancellation: ReadCancellation? = nil) -> Bool {
            condition.lock(); defer { condition.unlock() }
            return cancellation.map { $0.waiting && !$0.cancelled } ?? (waitingReaders > 0 && !cancelled)
        }

        func read(at offset: Int64, maximumCount: Int, cancellation: ReadCancellation? = nil) throws -> Data {
            guard offset >= 0, (1...65_536).contains(maximumCount) else { throw URLError(.badURL) }
            condition.lock(); defer { condition.unlock() }
            if cancellation?.cancelled == true { throw CancellationError() }
            let requestedEnd = Int64(clamping: Int128(offset) + Int128(maximumCount))
            requestedThrough = memoryCapacity == nil ? max(requestedThrough, requestedEnd) : requestedEnd
            condition.broadcast()
            if !started, !cancelled, failure == nil { start(at: memoryCapacity == nil && !indexedReads ? 0 : offset) }
            while !cancelled, cancellation?.cancelled != true, failure == nil, (!completed || memoryCapacity != nil),
                  coverage.availableEnd(at: offset) == offset, length.map({ offset < $0 }) ?? true {
                if pendingLoad != nil, scheduleRetry() { throw PCMSourceRetry.RestartUnprepared() }
                if failure != nil { break }
                if retryTask == nil, retry?.requiresDeferredRestart != true { requestRemoteBytes(at: offset) }
                waitingReaders += 1
                cancellation?.waiting = true
                retry?.notifyReadWaitChanged()
                condition.wait()
                cancellation?.waiting = false
                waitingReaders -= 1
                retry?.notifyReadWaitChanged()
            }
            if cancelled || cancellation?.cancelled == true { throw CancellationError() }
            if let failure { throw failure }
            let availableEnd = coverage.availableEnd(at: offset)
            guard offset < availableEnd else { return Data() }
            let count = Int(min(Int64(maximumCount), availableEnd - offset))
            do {
                let data = try readStored(at: offset, count: count)
                largestRead = max(largestRead, count)
                return data
            } catch { fail(error); throw error }
        }

        func allowDecoderRangeSeeks() {
            condition.lock(); defer { condition.unlock() }
            decoderRangeSeeksAllowed = true
        }

        func prepareForSeek(cancellation: ReadCancellation? = nil) {
            condition.lock(); defer { condition.unlock() }
            guard !cancelled, cancellation?.cancelled != true, failure == nil else { return }
            // Sequential MP3 readers reconstruct from cached bytes and consume any
            // uncached prefix. A seek hint must not bypass their loading budget.
            guard sequentialReadAheadBytes == nil || decoderRangeSeeksAllowed else { return }
            rangeReads = true
        }

        func prepareForIndexedSeek(to offset: Int64, cancellation: ReadCancellation? = nil) {
            condition.lock(); defer { condition.unlock() }
            guard offset >= 0, !cancelled, cancellation?.cancelled != true, failure == nil else { return }
            // A verified source index authorizes a new byte origin. Preserve the
            // same bounded read-ahead window; do not download the skipped prefix.
            indexedReads = true; rangeReads = true; requestedThrough = offset
            if !transfers.isEmpty { completed = false }
            for transfer in transfers.values { transfer.task.cancel() }
            transfers.removeAll(); rangeTaskID = nil; resumeOffset = nil
            condition.broadcast()
        }

        func checkFailure(cancellation: ReadCancellation? = nil) throws {
            condition.lock(); defer { condition.unlock() }
            if cancelled || cancellation?.cancelled == true { throw CancellationError() }
            if let failure { throw failure }
        }

        func cancelRead(_ cancellation: ReadCancellation) {
            condition.lock(); defer { condition.unlock() }
            cancellation.cancelled = true
            condition.broadcast()
        }

        func cancel() {
            condition.lock()
            guard !cancelled else { condition.unlock(); return }
            cancelled = true
            session?.invalidateAndCancel(); session = nil
            transfers.removeAll(); rangeTaskID = nil
            cleanup()
            condition.broadcast()
            sourceFailure.finish()
            let reclaim = reclaim
            condition.unlock()
            reclaim?.unregister(self)
        }

        // MARK: Retire the relay when the app may be suspended, rebuild it on demand

        func link(relay: NativeStreamingRelay, reclaim: StreamingRelayReclaim?) {
            condition.lock()
            self.relay = relay; relayGeneration = relay.generation; self.reclaim = reclaim
            condition.unlock()
            reclaim?.register(self)
        }

        /// Reconciles with the registry's current lifecycle inside this input's transition, so
        /// a notification delayed behind a newer one (including one delivered at registration)
        /// cannot undo it. The relay is retired in the same transition, before a demand can
        /// reopen it.
        func reclaimLifecycleChanged() {
            condition.lock(); defer { condition.unlock() }
            guard let relay, let reclaim else { return }
            let lifecycle = reclaim.lifecycle
            guard lifecycle.epoch > lifecycleEpoch else { return }
            lifecycleEpoch = lifecycle.epoch
            if lifecycle.suspended { park(relay) }
            else if parked, relayChange == nil, !cancelled, failure == nil { startRelayChange(relay, replacing: nil, after: nil) }
        }

        /// Lock held. Cancels every transfer, including one held by back pressure, keeps the
        /// bytes already received and the cursor reading continues from, then retires the
        /// relay. Nothing (read-ahead, retries, housekeeping) reopens it until a demand.
        private func park(_ relay: NativeStreamingRelay) {
            // A resume or repair in flight is superseded; its result is ignored.
            relayChangeID &+= 1
            relayChange?.task.cancel(); relayChange = nil
            if !parked, !cancelled, failure == nil {
                parked = true
                let open = transfers.values.filter { transfer in (transfer.end ?? length).map { transfer.cursor < $0 } ?? true }
                if let cursor = open.map(\.cursor).min() { resumeOffset = cursor }
                for transfer in transfers.values { transfer.task.cancel() }
                transfers.removeAll(); rangeTaskID = nil
                condition.broadcast()
            }
            // The relay never calls back into this input, so retiring it here is safe.
            relay.retire()
            // A failure the retired listener reported belongs to a transfer that no longer exists.
            _ = retry?.takeRelayFailure()
        }

#if DEBUG
        func simulateSocketReclaim() {
            condition.lock(); let relay = relay; condition.unlock()
            relay?.simulateSocketReclaim()
        }
        var isRelayRetired: Bool {
            condition.lock(); let relay = relay; condition.unlock()
            return relay?.isRetired == true
        }
#endif

        /// Lock held. A new listener (never the old one's readiness); the retired transfer continues once it is up.
        private func startRelayChange(_ relay: NativeStreamingRelay, replacing stale: UInt64?, after error: URLError?) {
            relayChangeID &+= 1
            let id = relayChangeID
            relayChange = (id, Task { [weak self] in
                let result: Result<(url: URL, generation: UInt64), any Error>
                do { result = .success(try await relay.reopen(replacing: stale)) } catch { result = .failure(error) }
                self?.relayChanged(id: id, result: result, after: error)
            })
        }

        private func relayChanged(id: UInt64, result: Result<(url: URL, generation: UInt64), any Error>, after error: URLError?) {
            condition.lock(); defer { condition.unlock() }
            guard relayChange?.id == id, !cancelled, failure == nil else { return }
            relayChange = nil; parked = false
            defer { condition.broadcast() }
            if case .success(let opened) = result {
                url = opened.url; relayGeneration = opened.generation
                _ = retry?.takeRelayFailure()
            }
            guard let offset = resumeOffset else { return }
            resumeOffset = nil
            guard session != nil, transfers.isEmpty, pendingLoad == nil, retryTask == nil,
                  retry?.requiresDeferredRestart != true else { return }
            switch result {
            case .success:
                if declaredLength == nil, retry != nil {
                    // An open-ended response cannot continue at a byte offset. The retry
                    // policy decides, as after a dropped connection: a live stream starts a
                    // new period once its buffered audio is heard.
                    pendingLoad = (URLError(.networkConnectionLost), offset)
                } else if length.map({ offset < $0 }) ?? true {
                    beginTransfer(at: offset)
                }
            case .failure:
                // No listener: the retry budget decides, as for any failed request.
                let failure = StreamingRelayUnavailable(underlying: error ?? URLError(.cannotConnectToHost))
                if retry != nil { pendingLoad = (failure, offset) } else { fail(failure) }
            }
        }

        /// The loopback leg failed and the relay reported no upstream outcome: its
        /// listener or connection is gone (iOS reclaimed it), not the network.
        private static func isLocalConnectionFailure(_ error: any Error) -> Bool {
            let error = error as NSError
            if error.domain == NSPOSIXErrorDomain { return true }
            guard error.domain == NSURLErrorDomain || error.domain == "kCFErrorDomainCFNetwork" else { return false }
            return [URLError.cannotConnectToHost, .networkConnectionLost, .timedOut, .notConnectedToInternet,
                    .cannotFindHost, .badServerResponse, .zeroByteResource].map(\.rawValue).contains(error.code)
        }

        /// Lock held. A local connection failure rebuilds the relay before the retry budget,
        /// once per suspension/demand epoch until bytes arrive. Otherwise the failure is retried
        /// and reported as the relay being unavailable, never as a media problem.
        private func handleLocalFailure(_ error: any Error, cursor: Int64) -> (any Error)? {
            guard let relay, Self.isLocalConnectionFailure(error) else { return error }
            let local = (error as? URLError) ?? URLError(.cannotConnectToHost)
            if relayUnavailable {
                // Already being replaced: this transfer continues with the others.
                resumeOffset = min(resumeOffset ?? cursor, cursor)
                return nil
            }
            let epoch = reclaim?.epoch ?? 0
            guard repair.map({ $0.epoch != epoch || $0.progressed }) ?? true else {
                return StreamingRelayUnavailable(underlying: local)
            }
            repair = (epoch, false)
            resumeOffset = cursor
            startRelayChange(relay, replacing: relayGeneration, after: local)
            return nil
        }

        private func start(at position: Int64) {
            started = true
            do {
                if memoryCapacity == nil {
                    guard FileManager.default.createFile(atPath: cacheURL.path, contents: nil,
                        attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                    file = try FileHandle(forUpdating: cacheURL)
                }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                if sequentialReadAheadBytes != nil {
                    // Consumer-held time is not upstream read inactivity. The relay
                    // owns the actual network deadline; this leg is its local pipe.
                    configuration.timeoutIntervalForRequest = .greatestFiniteMagnitude
                    configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
                }
                let callbacks = OperationQueue(); callbacks.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: callbacks)
                self.session = session
                beginTransfer(at: position)
            } catch { fail(error) }
        }

        private func beginTransfer(at offset: Int64) {
            guard let session else { return }
            // A retired relay is reopened only by a demand or a repair, which continue here.
            if relayUnavailable { resumeOffset = offset; return }
            var request = URLRequest(url: url)
            if sequentialReadAheadBytes != nil { request.timeoutInterval = .greatestFiniteMagnitude }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if offset > 0 {
                request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
                request.setValue(rangeValidation.ifRange, forHTTPHeaderField: "If-Range")
            }
            let task = session.dataTask(with: request)
            transfers[task.taskIdentifier] = Transfer(task: task, requestedOffset: offset, cursor: offset)
            // An indexed rewind can request byte zero. Track it as the active
            // range too, so the header callback cannot wake a reader into
            // opening a duplicate request before the first body bytes arrive.
            if offset > 0 || indexedReads { rangeTaskID = task.taskIdentifier }
            task.resume()
        }

        private func requestRemoteBytes(at offset: Int64) {
            // A waiting reader (read-ahead included) never reopens a retired relay.
            guard !relayUnavailable else { return }
            if memoryCapacity != nil {
                guard length.map({ offset < $0 }) ?? true, coverage.availableEnd(at: offset) == offset else { return }
                if transfers.values.contains(where: { offset >= $0.cursor && ($0.end ?? length).map({ offset < $0 }) ?? true }) { return }
                // A prior callback may be parked beyond this rewind. Retire it
                // before starting the missing range on the same private queue.
                for transfer in transfers.values { transfer.task.cancel() }
                transfers.removeAll(); rangeTaskID = nil
                completed = false
                condition.broadcast()
                beginTransfer(at: offset)
                return
            }
            guard rangeReads, initialResponseAccepted, (offset > 0 || indexedReads), length.map({ offset < $0 }) ?? true,
                  coverage.availableEnd(at: offset) == offset else { return }
            if let rangeTaskID, let active = transfers[rangeTaskID] {
                if offset >= active.cursor, (active.end ?? length).map({ offset < $0 }) ?? true { return }
                transfers.removeValue(forKey: rangeTaskID)?.task.cancel()
                self.rangeTaskID = nil
            }
            beginTransfer(at: offset)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            condition.lock(); defer { condition.unlock() }
            guard !cancelled, failure == nil, var transfer = transfers[dataTask.taskIdentifier] else { completionHandler(.cancel); return }
            if let http = response as? HTTPURLResponse, http.statusCode == 416,
               let end = try? HTTPMediaRangeEnd(contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                   requestedOffset: transfer.requestedOffset) {
                do {
                    // An exact EOF declaration must still refer to this media
                    // representation. Ignore the error body's bytes entirely.
                    let etag = http.value(forHTTPHeaderField: "ETag")
                    if initialResponseAccepted || expectedRepresentation != nil {
                        do { try rangeValidation.validate(etag: etag, isFullResponse: false) }
                        catch { representationRejected = true; throw error }
                    }
                    if rangeValidation.ifRange == nil { rangeValidation = HTTPMediaRangeValidation(etag: etag) }
                    try learnLength(end.length)
                    declaredLength = end.length
                    if !initialResponseAccepted { initialDeclaredLength = end.length }
                    initialResponseAccepted = true
                    transfers.removeValue(forKey: dataTask.taskIdentifier)
                    if rangeTaskID == dataTask.taskIdentifier { rangeTaskID = nil }
                    completed = length == coverage.prefixEnd
                    // Removing the transfer first prevents its cancellation
                    // callback from converting a successful EOF into a failure.
                    completionHandler(.cancel)
                    if completed, memoryCapacity == nil {
                        for active in transfers.values { active.task.cancel() }
                        transfers.removeAll(); rangeTaskID = nil
                        session.finishTasksAndInvalidate(); self.session = nil
                    }
                    condition.broadcast()
                } catch { completionHandler(.cancel); fail(error) }
                return
            }
            guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode) else {
                completionHandler(.cancel)
                loadFailed(MediaDownloadError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0),
                    transfer: transfer, taskID: dataTask.taskIdentifier); return
            }
            guard http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
                completionHandler(.cancel); fail(URLError(.cannotDecodeContentData)); return
            }
            let isInitialResponse = !initialResponseAccepted
            do {
                let etag = http.value(forHTTPHeaderField: "ETag")
                if initialResponseAccepted || expectedRepresentation != nil {
                    do { try rangeValidation.validate(etag: etag, isFullResponse: http.statusCode == 200) }
                    catch { representationRejected = true; throw error }
                }
                if rangeValidation.ifRange == nil { rangeValidation = HTTPMediaRangeValidation(etag: etag) }
                if transfer.requestedOffset == 0 {
                    guard http.statusCode == 200 else { throw MediaDownloadError.invalidRange }
                    if memoryCapacity != nil {
                        if initialResponseAccepted {
                            // A prior live-response EOF is not a declaration about
                            // the next response and must not opt it into caching.
                            if declaredLength == nil { length = nil }
                        }
                        if response.expectedContentLength >= 0 {
                            try learnLength(response.expectedContentLength)
                            declaredLength = length
                        }
                        if !initialResponseAccepted { declaredLength = length }
                    } else {
                        if response.expectedContentLength >= 0 { try learnLength(response.expectedContentLength) }
                        declaredLength = length
                    }
                    initialResponseAccepted = true
                    transfer.end = length
                } else {
                    if http.statusCode == 206 {
                        let partial = try HTTPMediaPartialResponse(contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                            requestedOffset: transfer.requestedOffset, expectedTotal: nil,
                            contentLength: response.expectedContentLength)
                        if let total = partial.total, let length, total != length {
                            representationRejected = true
                            throw MediaDownloadError.invalidRange
                        }
                        transfer.cursor = partial.bytes.lowerBound
                        transfer.end = partial.bytes.upperBound
                        if let total = partial.total {
                            try learnLength(total)
                            declaredLength = total
                        }
                    } else {
                        if response.expectedContentLength >= 0 {
                            try learnLength(response.expectedContentLength)
                            declaredLength = length
                        }
                        transfer.cursor = 0
                        transfer.end = length
                    }
                }
            } catch { completionHandler(.cancel); fail(error); return }
            if !initialResponseAccepted {
                initialResponseAccepted = true
                declaredLength = length
            }
            if isInitialResponse { initialDeclaredLength = declaredLength }
            transfer.accepted = true
            transfer.isWholeBody = http.statusCode == 200
            transfers[dataTask.taskIdentifier] = transfer
            condition.broadcast()
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            condition.lock(); defer { condition.unlock() }
            guard !cancelled, failure == nil,
                  var transfer = transfers[dataTask.taskIdentifier], transfer.accepted else { return }
            do {
                guard Int64(data.count) <= Int64.max - transfer.cursor else { throw URLError(.dataLengthExceedsMaximum) }
                let end = transfer.cursor + Int64(data.count)
                if let limit = transfer.end, end > limit { throw URLError(.badServerResponse) }
                if let length, end > length { throw URLError(.badServerResponse) }
                // Validate the whole delivery before exposing any new bytes, as in
                // unrestricted mode; a later overlap mismatch cannot be hidden by
                // publishing an earlier slice first.
                for range in coverage.ranges {
                    var cursor = max(range.lowerBound, transfer.cursor)
                    let overlapEnd = min(range.upperBound, end)
                    while cursor < overlapEnd {
                        let count = Int(min(Int64(65_536), overlapEnd - cursor))
                        let previous = try readStored(at: cursor, count: count)
                        let index = Int(cursor - transfer.cursor)
                        guard previous == data[index..<(index + count)] else { throw URLError(.resourceUnavailable) }
                        cursor += Int64(count)
                    }
                }
                var offset = 0
                while offset < data.count {
                    while let limit = sequentialDemandLimit, transfer.cursor >= limit,
                          !cancelled, failure == nil, transfers[dataTask.taskIdentifier] != nil {
                        demandWaiters += 1
                        condition.wait()
                        demandWaiters -= 1
                    }
                    guard !cancelled, failure == nil, transfers[dataTask.taskIdentifier] != nil else { return }
                    let allowance = sequentialDemandLimit.map { max(0, $0 - transfer.cursor) } ?? Int64.max
                    let count = min(data.count - offset, 65_536, Int(clamping: allowance))
                    let next = transfer.cursor + Int64(count)
                    try store(data.subdata(in: offset..<(offset + count)), at: transfer.cursor)
                    if count > 0 { repair?.progressed = true }
                    transfer.cursor = next; offset += count
                    transfers[dataTask.taskIdentifier] = transfer
                    condition.broadcast()
                }
            } catch { fail(error) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            condition.lock(); defer { condition.unlock() }
            guard !cancelled, failure == nil, let transfer = transfers.removeValue(forKey: task.taskIdentifier) else { return }
            if rangeTaskID == task.taskIdentifier { rangeTaskID = nil }
            if let upstream = retry?.takeRelayFailure() {
                loadFailed(upstream, transfer: transfer, taskID: task.taskIdentifier); return
            }
            if let error {
                guard let error = handleLocalFailure(error, cursor: transfer.cursor) else { condition.broadcast(); return }
                loadFailed(error, transfer: transfer, taskID: task.taskIdentifier); return
            }
            if let end = transfer.end, end != transfer.cursor {
                loadFailed(MediaDownloadError.wrongSize(expected: end, received: transfer.cursor),
                    transfer: transfer, taskID: task.taskIdentifier); return
            }
            if transfer.isWholeBody {
                do { try learnLength(transfer.cursor) }
                catch { fail(error); return }
            }
            completed = length == coverage.prefixEnd
            if completed, memoryCapacity == nil {
                for active in transfers.values { active.task.cancel() }
                transfers.removeAll(); rangeTaskID = nil
                session.finishTasksAndInvalidate(); self.session = nil
            }
            condition.broadcast()
        }

        private func loadFailed(_ error: any Error, transfer: Transfer, taskID: Int) {
            guard retry != nil,
                  (try? PlaybackLoadRetryPolicy.retryDelayMilliseconds(errorCount: 1,
                    causes: PCMSourceRetry.causes(of: error))) != nil else { fail(error); return }
            transfers.removeValue(forKey: taskID)
            if rangeTaskID == taskID { rangeTaskID = nil }
            pendingLoad = (error, transfer.cursor)
            // Let the extractor consume and classify all received bytes before
            // deciding progress, duration and the position of the next attempt.
            condition.broadcast()
        }
        private func scheduleRetry() -> Bool {
            guard let pending = pendingLoad, let retry else { return false }
            do {
                guard let plan = try retry.plan(for: pending.error, lengthKnown: declaredLength != nil) else {
                    fail(pending.error); return false
                }
                if !retry.snapshot.prepared, let exhausted = retry.currentError { fail(exhausted); return false }
                pendingLoad = nil
                // A live period is replaced only after its consumer drains the
                // available audio. No retry timer or upstream request runs meanwhile.
                if plan.deferredUntilDrained { return false }
                let restartParser = plan.restartAtZero && coverage.count > 0
                if plan.restartAtZero {
                    // A first unprepared response may replace its bytes/tag.
                    // An inherited prepared period must keep its identity even
                    // when this new loading task has not admitted packets yet.
                    for transfer in transfers.values { transfer.task.cancel() }
                    transfers.removeAll(); rangeTaskID = nil
                    coverage = HTTPMediaByteCoverage(); memory = Data(); memoryStart = 0
                    try file?.truncate(atOffset: 0)
                    length = expectedRepresentation?.length; declaredLength = length; initialDeclaredLength = length; completed = false
                    initialResponseAccepted = false; rangeValidation = expectedRepresentation?.validation ?? .unvalidated
                    requestedThrough = 0; rangeReads = false; indexedReads = false
                }
                let id = UUID(); retryID = id
                let position = plan.restartAtZero ? 0 : pending.position
                retryTask = Task { [weak self] in
                    do { try await retry.sleep(plan.delayMilliseconds); try Task.checkCancellation() }
                    catch { return }
                    self?.resumeRetry(id: id, position: position)
                }
                return restartParser
            } catch { fail(error); return false }
        }
        private func resumeRetry(id: UUID, position: Int64) {
            condition.lock(); defer { condition.unlock() }
            guard retryID == id, !cancelled, failure == nil else { return }
            retryID = nil; retryTask = nil
            beginTransfer(at: position)
            condition.broadcast()
        }

        private func readStored(at position: Int64, count: Int) throws -> Data {
            if memoryCapacity != nil {
                let start = position - memoryStart
                guard start >= 0, start + Int64(count) <= memory.count else { throw CocoaError(.fileReadCorruptFile) }
                return memory.subdata(in: Int(start)..<(Int(start) + count))
            }
            guard let file else { throw CocoaError(.fileReadUnknown) }
            try file.seek(toOffset: UInt64(position))
            guard let bytes = try file.read(upToCount: count), bytes.count == count else { throw CocoaError(.fileReadCorruptFile) }
            return bytes
        }
        private func store(_ bytes: Data, at position: Int64) throws {
            if let memoryCapacity {
                if position != memoryStart + Int64(memory.count) { memory = Data(); memoryStart = position }
                memory.append(bytes)
                if memory.count > memoryCapacity {
                    let removed = memory.count - memoryCapacity
                    memory = Data(memory.dropFirst(removed)); memoryStart += Int64(removed)
                }
                coverage = HTTPMediaByteCoverage()
                coverage.insert(memoryStart..<(memoryStart + Int64(memory.count)))
            } else {
                guard let file else { throw CocoaError(.fileWriteUnknown) }
                try file.seek(toOffset: UInt64(position)); try file.write(contentsOf: bytes)
                coverage.insert(position..<(position + Int64(bytes.count)))
            }
        }

        /// A full response or an explicit Content-Range total can establish size.
        /// A completed partial response with total '*' cannot establish whole-file EOF.
        /// The original declared length remains a separate source-timeline fact.
        private func learnLength(_ value: Int64) throws {
            if let length, value >= 0, length != value { representationRejected = true }
            guard value >= 0, length.map({ $0 == value }) ?? true,
                  (coverage.ranges.last?.upperBound ?? 0) <= value else { throw URLError(.resourceUnavailable) }
            length = value
        }

        private func fail(_ error: any Error) {
            guard failure == nil, !cancelled else { return }
            failure = error
            session?.invalidateAndCancel(); session = nil
            transfers.removeAll(); rangeTaskID = nil
            cleanup()
            condition.broadcast()
            sourceFailure.fail(error)
        }
        private func cleanup() {
            retryTask?.cancel(); retryTask = nil; retryID = nil; pendingLoad = nil
            relayChange?.task.cancel(); relayChange = nil; resumeOffset = nil
            memory = Data()
            do { try file?.close() } catch { cleanupFailure = error.localizedDescription }
            file = nil
            do {
                if FileManager.default.fileExists(atPath: cacheURL.path) { try FileManager.default.removeItem(at: cacheURL) }
            } catch { cleanupFailure = error.localizedDescription }
        }
    }
}
