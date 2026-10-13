import Foundation
import Synchronization

/// Bounded adaptation: Android runs episode downloads as WorkManager jobs that keep
/// going after the app leaves the foreground or its process dies. On iOS only a background `URLSession`
/// transfer runs while the app is suspended or was terminated by the system. This owner runs one
/// background download task per durable job; the job store stays the single owner of what the user sees
/// (queued/running, attempts, log rows, queue side effects).
///
/// Files of one transfer live beside the destination, in `background-transfers/`:
/// - `<name>.task.json`: the byte offset the task continues from (its `base`) and the identity it was
///   issued with, written before the task starts;
/// - `<name>.body` + `<name>.response.json`: a finished response, moved there synchronously when the
///   system hands it over (also after a relaunch), until the job's next attempt adopts it;
/// - `<name>.resume`: resume data from an interruption or a force-quit.
///
/// Before the first unlock after a restart iOS may deliver a finished transfer while protected files cannot be
/// created or read. The body is still moved inside the callback; its response record, which validation needs,
/// is kept in memory for that task (`Deferred`) and written by the job's next attempt once it can be. Such a transfer
/// is interrupted, never failed: nothing is deleted, no attempt is counted, the system's completion handler is
/// called as usual, and no background time is held while waiting. If the process ends first, the body has no record
/// and is never adopted: the next attempt resumes from the destination's verified bytes or starts again.
///
/// The destination itself holds only verified bytes: a finished body is appended (206) or replaces it
/// (200) only after status, range, identity and length were validated, so a truncated or mixed body is
/// never published. Requests a background session cannot reproduce (saved credentials or a configured
/// proxy) use the foreground engine instead (`MediaDownloadRouter`).
/// Which background transfers belong to a download job: the active download destinations of every library on
/// the device, and the media folders of libraries whose jobs could not be read (all their transfers are kept).
public struct BackgroundTransferOwnership: Sendable {
    public var destinations: [URL]
    public var protectedFolders: [URL]
    public init(destinations: [URL], protectedFolders: [URL] = []) {
        self.destinations = destinations; self.protectedFolders = protectedFolders
    }
}

public final class BackgroundMediaDownloads: NSObject, URLSessionDownloadDelegate, Sendable {
    public static let identifier = "org.nottennapod.app.media-downloads"
    /// One session per identifier and process; the app and its relaunches reattach to it.
    public static let shared = BackgroundMediaDownloads(identifier: identifier)

    struct TaskRecord: Codable, Equatable, Sendable {
        var destination: String
        var base: Int64
        var resource: URL?
        var entityTag: String?
        var total: Int64?
        /// The identity of the library the destination belongs to (PROTOCOL §15.4): a Keep at logout
        /// moves libraries' folders, and the record is found again by identity, never by an old path. A record
        /// without one, from a task started before libraries had identities, belongs to the library
        /// whose folder its path names.
        var library: String?

        /// The same request at the same destination; a missing library on either side names the folder's library.
        func sameTransfer(as other: TaskRecord) -> Bool {
            destination == other.destination && base == other.base && resource == other.resource && entityTag == other.entityTag
                && total == other.total && (library == nil || other.library == nil || library == other.library)
        }
    }

    struct ResponseRecord: Codable, Equatable, Sendable {
        var status: Int
        var url: URL?
        var headers: [String: String]
        /// The finished body this record was written for, stamped by `Files.write`: a body is adopted only with the
        /// record stamped for it, so the record a newer body replaces is never taken for that body, even when the
        /// process ended (or the old record could not be removed) between publishing the body and writing its record.
        var body: BodyStamp? = nil
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    /// A finished body file's identity (inode) and size: kept across renames and library moves; a newer body is
    /// another file.
    struct BodyStamp: Codable, Equatable, Sendable {
        var inode: UInt64
        var size: Int64
    }

    private struct Waiter {
        let token: UUID
        var taskID: Int?
        let continuation: CheckedContinuation<Void, any Error>
        let progress: @Sendable (MediaDownloadProgress) -> Void
        let base: Int64
        let capacity: @Sendable (URL) throws -> Int64
        let destination: URL
    }

    private struct State {
        /// A Keep at logout detaches the downloads: their workers stop waiting and their URLSession
        /// tasks keep running untouched, for the jobs' next attempts to adopt.
        var detaching = false
        /// The media folder → library identity of the libraries this process knows (the open library's).
        var libraries: [String: String] = [:]
        var session: URLSession?
        var waiters: [String: Waiter] = [:]
        /// Outcomes that arrived while nobody waited (a relaunch before the job's attempt starts).
        var unclaimed: [String: Result<Void, any Error>] = [:]
        /// Each task's own failure (its body or record could not be kept, too little space), delivered as its outcome.
        var failures: [Int: any Error] = [:]
        var checkedCapacity: Set<String> = []
        /// Tasks cancelled by `reconcile`: they belong to no download, so their late events are dropped.
        var discarded: Set<Int> = []
        var eventsCompletion: (@Sendable () -> Void)?
        /// Finished bodies whose response record could not be written yet, by task.
        var deferred: [Int: Deferred] = [:]
        /// Finished tasks whose body could not be moved (protected data unavailable): interrupted, not failed.
        var interrupted: Set<Int> = []
        /// The task whose finished body is in place at each destination (moved in this process), until it completes.
        var retained: [String: Int] = [:]
    }

    /// A finished body moved into place whose response record waits until protected data is available: tied to
    /// its task, to the transfer and library its record names, to the body file it moved and to the request it answered.
    struct Deferred: Sendable {
        let record: TaskRecord
        let request: URL?
        let body: Files.Identity?
        let response: ResponseRecord
    }

    /// What publishing a waiting record found.
    enum DeferredPublication {
        case published
        /// The destination's task record, library or body are no longer the ones that produced it: dropped, untouched.
        case superseded
        /// Its files cannot be reached now: kept for the next try.
        case unavailable(any Error)
        case failed(any Error)
    }

    /// The file operations whose refusal before the first unlock the app handles; host tests inject refusals.
    struct FileAccess: Sendable {
        var move: @Sendable (_ from: URL, _ to: URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
        /// The incoming body renamed over the retained one, in one step.
        var publish: @Sendable (_ incoming: URL, _ body: URL) throws -> Void = { incoming, body in
            guard Darwin.rename(incoming.path, body.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        var writeResponse: @Sendable (ResponseRecord, Files) throws -> Void = { try $1.write($0) }
    }

    public let sessionIdentifier: String
    private let state = Mutex(State())
    private let fileAccess: FileAccess
    /// The one owned-path resolution (PROTOCOL §15.4): a record's destination in its library's current folder. Installed by the
    /// app; without one, destinations are used as recorded.
    private let resolver = Mutex<(@Sendable (_ destination: String, _ library: String?) -> String)?>(nil)

    /// Installs the owned-path resolution every callback uses, under the move lock.
    public func setResolver(_ resolve: @escaping @Sendable (_ destination: String, _ library: String?) -> String) {
        resolver.withLock { $0 = resolve }
    }

    /// The library identity of a media folder this process downloads into (the open library's), so new task records
    /// name it.
    public func setLibrary(identity: String?, media: URL) {
        let key = media.standardizedFileURL.path
        state.withLock { state in
            state.libraries = [:]
            if let identity { state.libraries[key] = identity }
        }
    }

    /// Whether a live task described by `description` is the transfer `record` asks for: the same request once its
    /// destination is resolved onto the library's current folder. A record without a library names the library whose
    /// folder holds it.
    func adopts(_ description: String?, as record: TaskRecord) -> Bool {
        guard let live = Self.record(of: description).map(resolved) else { return false }
        return live.sameTransfer(as: record)
    }

    /// A record's current destination (the resolution function), and the record rewritten onto it.
    func resolved(_ record: TaskRecord) -> TaskRecord {
        guard let resolve = resolver.withLock({ $0 }) else { return record }
        var next = record
        next.destination = resolve(record.destination, record.library)
        return next
    }

    // MARK: - Keep at logout: detach and normalize (PROTOCOL §15.4)

    /// From here until `endDetach()`, a worker's cancellation stops its wait without cancelling its transfer or asking
    /// for resume data: the job is left for its next attempt, as after a process death.
    public func beginDetach() { state.withLock { $0.detaching = true } }
    public func endDetach() { state.withLock { $0.detaching = false } }

    /// After a Keep's renames: the sidecar `.task.json` records in a moved media folder name their current
    /// destination and their library. Under the move lock.
    public static func normalizeRecords(mediaFolder: URL, identity: String) {
        let folder = mediaFolder.appendingPathComponent("background-transfers", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasSuffix(".task.json") {
            let file = folder.appendingPathComponent(name)
            guard var record = (try? Data(contentsOf: file)).flatMap({ try? JSONDecoder().decode(TaskRecord.self, from: $0) }) else { continue }
            let destination = mediaFolder.appendingPathComponent(String(name.dropLast(".task.json".count))).standardizedFileURL.path
            guard record.destination != destination || record.library != identity else { continue }
            record.destination = destination
            record.library = identity
            try? JSONEncoder().encode(record).write(to: file, options: .atomic)
        }
    }

    /// When the session is activated, and after a Keep: every live task's description names its current destination
    /// (through the resolution function), so adoption and resume-data matching compare current paths.
    public func normalizeLiveTasks() async {
        let tasks = await activate().allTasks
        LibraryMoveLock.withLock {
            for task in tasks {
                guard let record = Self.record(of: task.taskDescription) else { continue }
                let current = resolved(record)
                if current != record { task.taskDescription = Self.describe(current) }
            }
        }
    }

    public convenience init(identifier: String) { self.init(identifier: identifier, fileAccess: FileAccess()) }

    init(identifier: String, fileAccess: FileAccess) {
        sessionIdentifier = identifier
        self.fileAccess = fileAccess
        super.init()
    }

    /// Recreates (reattaches) the session so events of transfers that finished while the app was not
    /// running are delivered. Called at launch and when the system relaunches the app for its events.
    @discardableResult public func activate() -> URLSession {
        state.withLock { state in
            if let session = state.session { return session }
            let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
            configuration.sessionSendsLaunchEvents = true
            configuration.isDiscretionary = false
            configuration.urlCache = nil
            configuration.urlCredentialStorage = nil
            configuration.httpCookieStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            // AntennapodHttpClient read timeout (AntennapodHttpClient.java:25–26, 74–76).
            configuration.timeoutIntervalForRequest = 30
            configuration.httpMaximumConnectionsPerHost = 8
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            state.session = session
            return session
        }
    }

    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`: the handler is called
    /// once the session has delivered every pending event.
    public func handleEvents(completion: @escaping @Sendable () -> Void) {
        expectEvents(completion)
        activate()
    }

    /// The completion handler `finishEvents` calls once (host tests set it without a session).
    func expectEvents(_ completion: @escaping @Sendable () -> Void) { state.withLock { $0.eventsCompletion = completion } }

    /// Test isolation only: ends this session and its tasks.
    public func invalidate() {
        let session = state.withLock { state -> URLSession? in
            defer { state.session = nil }
            return state.session
        }
        session?.invalidateAndCancel()
    }

    // MARK: - Reconciliation

    /// Cancels every transfer of this session that belongs to no current download.
    ///
    /// The system keeps a background session's tasks across launches (and, on the Simulator, even across
    /// an uninstall). A task whose download is not in the current library — the library was replaced by
    /// a database import, or the task was left from an earlier run — is never adopted, so it would keep
    /// its connection until the 7-day resource timeout; eight of them fill the per-host limit and every
    /// new download to that host waits forever. Android has no such state: an import ends the process
    /// (and its connections), and a restarted `EpisodeDownloadWorker` whose media no longer exists
    /// returns `Result.failure()` without a request (EpisodeDownloadWorker.java:58–62).
    ///
    /// Tasks of active downloads (`activeDestinations`, read after the task list) and of transfers this
    /// process is running are kept, so the job's next attempt adopts them and resume keeps working.
    /// Returns the number of cancelled tasks.
    @discardableResult
    public func reconcile(activeDestinations: @Sendable () async throws -> [URL]) async throws -> Int {
        try await reconcile(ownership: { .init(destinations: try await activeDestinations()) })
    }

    /// The same, with transfers of every library on the device (PROTOCOL §15.4): a transfer of an inactive
    /// library is never cancelled as an orphan.
    @discardableResult
    public func reconcile(ownership: @Sendable () async throws -> BackgroundTransferOwnership) async throws -> Int {
        let tasks: [any ReconciledTransfer] = await activate().allTasks
        return try await reconcile(listed: tasks, ownership: ownership)
    }

    func reconcile(_ tasks: [any ReconciledTransfer], activeDestinations: @Sendable () async throws -> [URL]) async throws -> Int {
        try await reconcile(listed: tasks, ownership: { .init(destinations: try await activeDestinations()) })
    }

    func reconcile(listed tasks: [any ReconciledTransfer], ownership: @Sendable () async throws -> BackgroundTransferOwnership) async throws -> Int {
        let live = tasks.filter { $0.state == .running || $0.state == .suspended }
        guard !live.isEmpty else { return 0 }
        // Listed before the libraries are read: a listed task's job, if any, already existed at the read.
        let owners = try await ownership()
        let keep = Set(owners.destinations.map { Files(destination: $0).key })
        let protected = owners.protectedFolders.map { Files(destination: $0).key + "/" }
        var cancelled = 0
        for task in live {
            let key = Self.record(of: task.taskDescription).map(resolved)?.destination
            let orphan = state.withLock { state -> Bool in
                // A waiter means this process started or adopted the key's transfer after the read.
                if let key, keep.contains(key) || state.waiters[key] != nil
                    || protected.contains(where: { key.hasPrefix($0) }) { return false }
                state.discarded.insert(task.taskIdentifier)
                return true
            }
            if orphan { task.cancel(); cancelled += 1 }
        }
        return cancelled
    }

    // MARK: - Transfer

    public func download(_ input: MediaDownloadRequest, userAgent: String,
                         capacity: @escaping @Sendable (URL) throws -> Int64 = MediaDownloadRouter.availableCapacity,
                         progress: @escaping @Sendable (MediaDownloadProgress) -> Void = { _ in }) async throws -> MediaDownloadResult {
        // Files that cannot be reached now (before the first unlock) interrupt the attempt instead of failing it; a
        // library database error stays one.
        do { return try await transferAndAssemble(input, userAgent: userAgent, capacity: capacity, progress: progress) }
        catch where !(error is FeedLibraryError) && SavedState.isUnavailable(error) { throw SavedStateUnavailable(error) }
    }

    private func transferAndAssemble(_ input: MediaDownloadRequest, userAgent: String,
                                     capacity: @escaping @Sendable (URL) throws -> Int64,
                                     progress: @escaping @Sendable (MediaDownloadProgress) -> Void) async throws -> MediaDownloadResult {
        try Task.checkCancellation()
        guard input.destination.isFileURL, let original = try? FeedAddress.requestURL(input.source),
              var components = URLComponents(url: original, resolvingAgainstBaseURL: false) else {
            throw MediaDownloadError.malformedURL
        }
        components.user = nil; components.password = nil; components.fragment = nil
        guard let url = components.url else { throw MediaDownloadError.malformedURL }
        let files = Files(destination: input.destination)
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        var representation = input.representation.flatMap { $0.isValid ? $0 : nil }
        var followUps = 0
        while followUps < 21 {
            followUps += 1
            try Task.checkCancellation()
            var offset = Self.size(of: input.destination)
            if representation == nil || representation?.total.map({ offset > $0 }) == true { offset = 0; representation = nil }
            // A finished response (possibly from before a relaunch) is used before anything new is requested.
            if try finishedResponse(files, request: url) == nil {
                try await transfer(url: url, input: input, files: files, offset: offset, representation: representation,
                                   userAgent: userAgent, capacity: capacity, progress: progress)
            }
            try Task.checkCancellation()
            switch try await Self.assemble(files: files, input: input, capacity: capacity) {
            case .finished(let result):
                progress(.init(received: result.size, expected: result.size))
                return result
            case .continueFrom(let identity):
                representation = identity
                followUps = 0 // Only verified byte progress resets the follow-up bound.
            case .restartFull:
                // The prefix stays untouched until a complete response is accepted.
                representation = nil
            }
        }
        throw MediaDownloadError.tooManyFollowUps
    }

    private func transfer(url: URL, input: MediaDownloadRequest, files: Files, offset: Int64,
                          representation: MediaDownloadRepresentation?, userAgent: String,
                          capacity: @escaping @Sendable (URL) throws -> Int64,
                          progress: @escaping @Sendable (MediaDownloadProgress) -> Void) async throws {
        let session = activate()
        let key = files.key
        let resume = offset > 0 && representation?.resource == url
        let library = state.withLock { $0.libraries[files.directory.deletingLastPathComponent().standardizedFileURL.path] }
        let record = TaskRecord(destination: key, base: resume ? offset : 0, resource: resume ? representation?.resource : nil,
                                entityTag: resume ? representation?.entityTag : nil, total: resume ? representation?.total : nil,
                                library: library)
        // A task finished while the app was not running is listed until its events are delivered. Its record is
        // resolved onto its library's current folder here, under the move lock, and an adopted task's description is
        // rewritten at once: adoption never depends on a later normalization.
        let tasks = await session.allTasks
        // A finished body still waiting for its record that the job's attempt did not adopt is superseded now, as is the
        // task that moved it: its completion leaves the destination's files to this transfer.
        dropDeferred(key: key)
        state.withLock { _ = $0.retained.removeValue(forKey: key) }
        let (live, adopted) = LibraryMoveLock.withLock { () -> ([URLSessionTask], URLSessionTask?) in
            let live = tasks.filter { Self.record(of: $0).map(resolved)?.destination == key && $0.state != .canceling }
            guard let task = live.first, adopts(task.taskDescription, as: record) else { return (live, nil) }
            task.taskDescription = Self.describe(record)
            return (live, task)
        }
        for task in live where task !== adopted { task.cancel() }
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let waiter = Waiter(token: token, taskID: adopted?.taskIdentifier, continuation: continuation, progress: progress,
                                    base: record.base, capacity: capacity, destination: input.destination)
                let early: Result<Void, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if adopted != nil, let outcome = state.unclaimed.removeValue(forKey: key) { return outcome }
                    state.unclaimed[key] = nil
                    state.checkedCapacity.remove(key)
                    state.waiters[key]?.continuation.resume(throwing: CancellationError())
                    state.waiters[key] = waiter
                    return nil
                }
                if let early { continuation.resume(with: early); return }
                if let adopted {
                    adopted.resume()
                    return
                }
                do {
                    let task: URLSessionDownloadTask
                    if let data = LibraryMoveLock.withLock({ files.resumeData(matching: record) }) {
                        task = session.downloadTask(withResumeData: data)
                    } else {
                        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                        let unmetered = input.networkConstraint == .unmetered
                        // UNMETERED: WorkManager's NET_CAPABILITY_NOT_METERED; on iOS neither an expensive
                        // (cellular, hotspot) nor a constrained (Low Data Mode) network.
                        request.allowsExpensiveNetworkAccess = !unmetered
                        request.allowsConstrainedNetworkAccess = !unmetered
                        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                        if url.scheme?.lowercased() == "http" { request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests") }
                        if resume, let tag = record.entityTag {
                            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
                            request.setValue(tag, forHTTPHeaderField: "If-Range")
                        }
                        task = session.downloadTask(with: request)
                    }
                    files.removeResumeData()
                    try files.write(record)
                    task.taskDescription = Self.describe(record)
                    state.withLock { state in
                        if state.waiters[key]?.token == token { state.waiters[key]?.taskID = task.taskIdentifier }
                    }
                    task.resume()
                } catch {
                    let removed = state.withLock { $0.waiters[key]?.token == token ? $0.waiters.removeValue(forKey: key) : nil }
                    removed?.continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            let (waiter, detached) = self.state.withLock { state in
                (state.waiters[key]?.token == token ? state.waiters.removeValue(forKey: key) : nil, state.detaching)
            }
            waiter?.continuation.resume(throwing: CancellationError())
            // Detached by a Keep: the transfer keeps running for the job's next attempt.
            guard !detached else { return }
            Task {
                for task in await session.allTasks where task.taskDescription == Self.describe(record) {
                    if let download = task as? URLSessionDownloadTask {
                        // Keep what was received for the next attempt (interruption, not failure).
                        // Written into the library's current folder, wherever a Keep moved it meanwhile.
                        if let data = await download.cancelByProducingResumeData() {
                            LibraryMoveLock.withLock {
                                let current = self.resolved(record)
                                guard Files.libraryFolderExists(current.destination) else { return }
                                try? Files(key: current.destination).writeResumeData(data)
                            }
                        }
                    } else { task.cancel() }
                }
            }
        }
    }

    // MARK: - Assembly

    enum Assembly: Sendable {
        case finished(MediaDownloadResult)
        case continueFrom(MediaDownloadRepresentation)
        case restartFull
    }

    /// Validates a finished response and publishes its bytes into the destination. Pure file work, so
    /// the host tests check every branch without a background session.
    static func assemble(files: Files, input: MediaDownloadRequest,
                         capacity: @Sendable (URL) throws -> Int64) async throws -> Assembly {
        // Sidecars that cannot be read now are kept for a later attempt; only missing or damaged ones restart. Read
        // under the move lock, so never mid-way through a finished body's handoff; the body they were written for is
        // opened there too and held: what is published is those bytes, even if a newer body replaces the file during
        // an await, and cleanup touches only that pair.
        let (finished, transfer, opened) = try LibraryMoveLock.withLock { () throws -> (ResponseRecord?, TaskRecord?, FileHandle?) in
            let response = try files.checkedFinishedResponse(), record = try files.checkedTaskRecord()
            guard response != nil, record != nil else { return (response, record, nil) }
            return (response, record, try FileHandle(forUpdating: files.body))
        }
        guard let response = finished, let record = transfer, let handle = opened, let stamp = response.body else {
            files.removeAll(); return .restartFull
        }
        defer { try? handle.close() }
        let body = HeldBody(files: files, handle: handle, stamp: stamp)
        // The finished files go once adopted or proved invalid; files that cannot be reached now stay, untouched, for a
        // later attempt.
        do {
            let assembly = try await adopt(body, response: response, record: record, input: input, capacity: capacity)
            body.removeFinished()
            return assembly
        } catch where SavedState.isUnavailable(error) {
            throw error
        } catch {
            body.removeFinished()
            throw error
        }
    }

    /// The finished body an assembly validated, held open from before its first await, and the stamp of the pair.
    struct HeldBody {
        let files: Files
        let handle: FileHandle
        let stamp: BodyStamp

        /// Whether the destination's finished files are still (or no longer, but not replaced by) this pair: a newer
        /// body or record in place belongs to a later transfer and is left alone.
        private func ownsFiles() -> Bool {
            let body = try? Files.stamp(of: files.body)
            let record = (try? SavedState.contents(of: files.responseFile))?.flatMap { try? JSONDecoder().decode(ResponseRecord.self, from: $0) }
            return (body == nil || body == stamp) && (record == nil || record?.body == stamp)
        }

        /// This pair's body and record, if they are still in place.
        func removeFinished() {
            LibraryMoveLock.withLock {
                if (try? Files.stamp(of: files.body)) == stamp { try? FileManager.default.removeItem(at: files.body) }
                let record = (try? SavedState.contents(of: files.responseFile))?.flatMap { try? JSONDecoder().decode(ResponseRecord.self, from: $0) }
                if record?.body == stamp { try? FileManager.default.removeItem(at: files.responseFile) }
            }
        }

        /// Everything of the transfer, unless a later transfer's files are in place now.
        func removeAll() {
            LibraryMoveLock.withLock { if ownsFiles() { files.removeAll() } }
        }
    }

    private static func adopt(_ held: HeldBody, response: ResponseRecord, record: TaskRecord, input: MediaDownloadRequest,
                              capacity: @Sendable (URL) throws -> Int64) async throws -> Assembly {
        let bodySize = held.stamp.size
        guard (200..<300).contains(response.status) else { held.removeAll(); throw MediaDownloadError.httpStatus(response.status) }
        let length = response.header("Content-Length").flatMap(Int64.init)
        if response.header("Content-Type")?.hasPrefix("text/") == true, (length ?? -1) < 100 * 1024 {
            held.removeAll(); throw MediaDownloadError.fileType
        }
        let encoding = response.header("Content-Encoding")?.lowercased()
        let identityEncoded = encoding == nil || encoding == "identity"
        if response.status == 206 {
            // The body continues the record's base (the system concatenates resumed parts).
            guard identityEncoded, let contentRange = response.header("Content-Range") else { held.removeAll(); return .restartFull }
            let total = try? totalOf(contentRange: contentRange)
            guard let total = total ?? nil else { held.removeAll(); return .restartFull }
            let base = record.base
            if base > 0 {
                guard let tag = record.entityTag, let resource = record.resource, response.header("ETag") == tag,
                      response.url == resource, record.total.map({ $0 == total }) ?? true,
                      size(of: input.destination) == base else { held.removeAll(); return .restartFull }
            }
            guard base + bodySize <= total else { held.removeAll(); throw MediaDownloadError.wrongSize(expected: total, received: base + bodySize) }
            let identity = base > 0 ? MediaDownloadRepresentation(resource: record.resource!, entityTag: record.entityTag!, total: total)
                : response.url.flatMap { url in response.header("ETag").map { MediaDownloadRepresentation(resource: url, entityTag: $0, total: total) } }
            let valid = identity.flatMap { $0.isValid ? $0 : nil }
            if base > 0 {
                let available = try capacity(input.destination)
                guard bodySize <= available else { throw MediaDownloadError.notEnoughSpace(required: bodySize, available: available) }
                try await input.acceptRepresentation?(valid)
                try append(held.handle, to: input.destination)
            } else {
                try await replace(input.destination, with: held) { try await input.acceptRepresentation?(valid) }
            }
            let size = size(of: input.destination)
            if size < total {
                guard let valid else { return .restartFull }
                return .continueFrom(valid)
            }
            guard size == total else { throw MediaDownloadError.wrongSize(expected: total, received: size) }
            held.removeAll()
            return .finished(MediaDownloadResult(destination: input.destination, size: size,
                validator: response.header("ETag") ?? response.header("Last-Modified"), representation: valid))
        }
        let expected = identityEncoded ? length : nil
        if let expected, expected != bodySize {
            held.removeAll(); throw MediaDownloadError.wrongSize(expected: expected, received: bodySize)
        }
        var identity: MediaDownloadRepresentation?
        if identityEncoded, let url = response.url, let tag = response.header("ETag") {
            let candidate = MediaDownloadRepresentation(resource: url, entityTag: tag, total: bodySize)
            identity = candidate.isValid ? candidate : nil
        }
        try await replace(input.destination, with: held) { try await input.acceptRepresentation?(identity) }
        let size = size(of: input.destination)
        held.removeAll()
        return .finished(MediaDownloadResult(destination: input.destination, size: size,
            validator: response.header("ETag") ?? response.header("Last-Modified"), representation: identity))
    }

    static func totalOf(contentRange: String) throws -> Int64? {
        let fields = contentRange.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 2, fields[0].lowercased() == "bytes" else { throw MediaDownloadError.invalidRange }
        let parts = fields[1].split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw MediaDownloadError.invalidRange }
        if parts[1] == "*" { return nil }
        guard let total = Int64(parts[1]), total >= 0 else { throw MediaDownloadError.invalidRange }
        return total
    }

    static func size(of file: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Appends the held body after the destination's verified bytes. Both files are open first (one that cannot be
    /// opened now changes nothing), and a failure part-way leaves only the verified bytes.
    private static func append(_ input: FileHandle, to destination: URL) throws {
        try input.seek(toOffset: 0)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let verified = try output.seekToEnd()
        do {
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try output.write(contentsOf: chunk) }
            try output.synchronize()
        } catch {
            try? output.truncate(atOffset: verified)
            throw error
        }
    }

    /// Keeps the destination's identity (the episode already points at it) while replacing its bytes.
    /// The old bytes are gone before the new identity is saved, so old bytes never carry a new identity.
    /// The finished body is then renamed over the (empty) destination path: the bytes are written once,
    /// not copied. `rename(2)` is atomic, so the path always holds either nothing or the whole body.
    /// Both files are open before anything changes: a body or destination that cannot be opened now leaves the
    /// verified destination and the finished files as they are. The body renamed into place is the one held, checked
    /// with no await in between; if a newer body replaced it meanwhile, the held bytes are copied instead and the newer
    /// body is left alone.
    private static func replace(_ destination: URL, with body: HeldBody,
                                accepting accept: () async throws -> Void) async throws {
        let source = body.handle
        if !(try SavedState.isPresent(destination)) { try Data().write(to: destination) }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.truncate(atOffset: 0)
        try output.synchronize()
        try await accept()
        // Durable before it becomes visible under the destination path (the copy fsyncs the destination).
        try source.synchronize()
        let renamed = LibraryMoveLock.withLock {
            (try? Files.stamp(of: body.files.body)) == body.stamp && Darwin.rename(body.files.body.path, destination.path) == 0
        }
        if !renamed {
            // Replaced meanwhile, or not on one volume (never for `background-transfers/`): copy the held bytes.
            try source.seek(toOffset: 0)
            while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty { try output.write(contentsOf: chunk) }
            try output.synchronize()
        }
    }

    static func describe(_ record: TaskRecord) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return String(decoding: (try? encoder.encode(record)) ?? Data(), as: UTF8.self)
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        finishDownloading(task: downloadTask.taskIdentifier, description: downloadTask.taskDescription,
                          request: downloadTask.originalRequest?.url, response: downloadTask.response as? HTTPURLResponse,
                          location: location)
    }

    /// `didFinishDownloadingTo`, on the task's identity and response (host tests call it directly).
    func finishDownloading(task: Int, description: String?, request: URL?, response: HTTPURLResponse?, location: URL) {
        guard !state.withLock({ $0.discarded.contains(task) }), let recorded = Self.record(of: description) else { return }
        // Under the move lock, in the library's current folder: never an old folder, never another library's.
        LibraryMoveLock.withLock {
            let record = resolved(recorded)
            let files = Files(key: record.destination)
            // The system deletes `location` when this returns, so the body is moved now (also after a relaunch): first
            // beside the destination's retained files, which stay until this body is in place.
            do {
                guard try Files.libraryFolderIsPresent(record.destination) else { throw CocoaError(.fileNoSuchFile) }
                if !(try SavedState.isPresent(files.directory)) {
                    try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: false)
                }
                try? FileManager.default.removeItem(at: files.incoming)
                try fileAccess.move(location, files.incoming)
            } catch where SavedState.isUnavailable(error) {
                // The move itself was refused before the first unlock: the attempt is interrupted and retried, and
                // nothing of this destination is deleted. The system removes its temporary body.
                state.withLock { _ = $0.interrupted.insert(task) }
                return
            } catch {
                // This task's own failure (no space, say), delivered as its outcome; an older completion stays.
                state.withLock { $0.failures[task] = error }
                return
            }
            // One rename publishes the new body over the retained one: if it fails, the older body, its record and a
            // record still waiting for it all stay.
            do { try fileAccess.publish(files.incoming, files.body) }
            catch {
                try? FileManager.default.removeItem(at: files.incoming)
                state.withLock { state in
                    if SavedState.isUnavailable(error) { state.interrupted.insert(task) } else { state.failures[task] = error }
                }
                return
            }
            // Published: the older body's record (on disk or waiting) no longer describes the body and goes. Its stamp
            // names the older body, so if it cannot be removed, or the process ends first, it is never adopted with this one.
            dropDeferred(key: record.destination)
            try? FileManager.default.removeItem(at: files.responseFile)
            let body = try? Files.identity(of: files.body)
            state.withLock { $0.retained[record.destination] = task }
            var headers: [String: String] = [:]
            for (name, value) in response?.allHeaderFields ?? [:] { headers["\(name)"] = "\(value)" }
            let finished = ResponseRecord(status: response?.statusCode ?? 0, url: response?.url, headers: headers)
            do { try fileAccess.writeResponse(finished, files) }
            catch where SavedState.isUnavailable(error) {
                // The record cannot be created yet: the body stays and the record waits for this task.
                state.withLock { $0.deferred[task] = Deferred(record: recorded, request: request, body: body, response: finished) }
            } catch {
                files.removeFinished()
                state.withLock { $0.failures[task] = error }
            }
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // Called for every few KB: find the waiting download by task, without decoding the
        // task's JSON description each time (a handful of waiters at most).
        let task = downloadTask.taskIdentifier
        let found = state.withLock { state -> (key: String, waiter: Waiter, firstCheck: Bool)? in
            guard let entry = state.waiters.first(where: { $0.value.taskID == task }) else { return nil }
            return (entry.key, entry.value, state.checkedCapacity.insert(entry.key).inserted)
        }
        guard let found else { return }
        let (key, waiter, firstCheck) = found
        let received = waiter.base + totalBytesWritten
        let expected = totalBytesExpectedToWrite >= 0 ? waiter.base + totalBytesExpectedToWrite : nil
        if firstCheck, let expected {
            // Source HttpDownloader checks free space against the announced length before writing.
            do {
                let available = try waiter.capacity(waiter.destination)
                if expected - received > available {
                    state.withLock { $0.failures[task] = MediaDownloadError.notEnoughSpace(required: expected - received, available: available) }
                    downloadTask.cancel()
                    return
                }
            } catch {
                state.withLock { $0.failures[task] = error }
                downloadTask.cancel()
                return
            }
        }
        waiter.progress(.init(received: received, expected: expected))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Eligible requests carry no credentials: a 401 completes as the server's response, as the
        // foreground engine reports it (fail fast, DownloadServiceInterface rules).
        completionHandler(.performDefaultHandling, nil)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        complete(task: task.taskIdentifier, description: task.taskDescription, error: error)
    }

    /// `didCompleteWithError`, on the task's identity (host tests call it directly).
    func complete(task: Int, description: String?, error: (any Error)?) {
        // A reconciled orphan leaves no resume data or outcome that a later download with the same path could adopt.
        if state.withLock({ $0.discarded.remove(task) != nil }) { return }
        guard let recorded = Self.record(of: description) else { return }
        let record = LibraryMoveLock.withLock { resolved(recorded) }
        let files = Files(key: record.destination)
        if let error, let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            // Interrupted (including a force-quit reported at the next launch): the next attempt resumes, in the
            // library's current folder.
            LibraryMoveLock.withLock { if Files.libraryFolderExists(record.destination) { try? files.writeResumeData(data) } }
        }
        // What this completion may conclude about the destination's finished files: a record that waited is written
        // through the one fenced publication; a finished body that cannot be checked now is not "no response"; files
        // another task has put in place since are not this completion's to judge or remove.
        enum Finding { case own, unavailable, superseded }
        let completedTransfer = error == nil
        let finding: Finding = LibraryMoveLock.withLock {
            if state.withLock({ $0.interrupted.remove(task) != nil }) { return .unavailable }
            if state.withLock({ $0.deferred[task] != nil }) {
                switch publishDeferred(task: task, files: files, request: nil) {
                case .published: break
                case .superseded: return .superseded
                case .unavailable: return .unavailable
                case .failed(let failure): state.withLock { $0.failures[task] = failure }
                }
            }
            guard completedTransfer else { return .own }
            // Its own operation failed (keeping its body or record): that failure is its outcome, never "superseded".
            if state.withLock({ $0.failures[task] != nil }) { return .own }
            guard state.withLock({ $0.retained[record.destination] == task }) else { return .superseded }
            do { _ = try files.checkedFinishedResponse(); return .own } catch { return SavedState.isUnavailable(error) ? .unavailable : .own }
        }
        let (outcome, waiter, ownsBody) = state.withLock { state -> (Result<Void, any Error>, Waiter?, Bool) in
            let current = state.waiters[record.destination].flatMap { $0.taskID == task ? $0 : nil }
            let ownsBody = state.retained[record.destination] == task
            if ownsBody { state.retained[record.destination] = nil }
            if finding == .superseded {
                // A stale callback: nothing of the successor's state (its failure, outcome or files) is touched.
                if current != nil { state.waiters[record.destination] = nil }
                return (.failure(CancellationError()), current, false)
            }
            let failure = state.failures.removeValue(forKey: task)
            let outcome: Result<Void, any Error>
            if let failure { outcome = .failure(failure) }
            else if finding == .unavailable { outcome = .failure(SavedStateUnavailable()) }
            else if let error { outcome = .failure((error as? URLError)?.code == .cancelled ? CancellationError() : error) }
            else { outcome = files.finishedResponse() == nil ? .failure(URLError(.badServerResponse)) : .success(()) }
            if current != nil { state.waiters[record.destination] = nil }
            else if state.waiters[record.destination] == nil {
                // Nobody waits yet (a relaunch): the job's next attempt adopts this outcome. An interruption leaves
                // none: the next attempt finds the body (and its record, once written) itself.
                if case .failure(let error) = outcome, error is CancellationError || error is SavedStateUnavailable {}
                else { state.unclaimed[record.destination] = outcome }
            }
            return (outcome, current, ownsBody)
        }
        // A failed transfer removes the destination's finished files only when they are its own body (a completed
        // transfer) or stale for the attempt that waits (a failed one): never another task's, never on an interruption.
        if case .failure(let failure) = outcome, finding == .own, !(failure is SavedStateUnavailable),
           error == nil ? ownsBody : waiter != nil {
            files.removeFinished()
        }
        waiter?.continuation.resume(with: outcome)
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) { finishEvents() }

    /// The system's completion handler, called once for the events it delivered, whether or not their records could
    /// be written: nothing waits for the first unlock.
    func finishEvents() {
        let completion = state.withLock { state -> (@Sendable () -> Void)? in
            defer { state.eventsCompletion = nil }
            return state.eventsCompletion
        }
        guard let completion else { return }
        DispatchQueue.main.async { completion() }
    }

    // MARK: - Deferred records

    /// The destination's finished response, its record first written from memory when it waited for protected data.
    /// Nil when a transfer is needed. Throws `SavedStateUnavailable` when the record still cannot be written, or the
    /// finished files cannot be read now: the attempt is interrupted, nothing is removed or requested.
    func finishedResponse(_ files: Files, request: URL) throws -> ResponseRecord? {
        try LibraryMoveLock.withLock {
            let waiting = state.withLock { $0.deferred }.filter { resolved($0.value.record).destination == files.key }.map(\.key).max()
            if let task = waiting {
                switch publishDeferred(task: task, files: files, request: request) {
                case .published, .superseded: break
                case .unavailable(let error): throw SavedStateUnavailable(error)
                case .failed(let error): throw error
                }
            }
            return try unavailableAsInterruption { try files.checkedFinishedResponse() }
        }
    }

    /// The one way a waiting record is written, from the task's completion or the job's next attempt, under the move
    /// lock: only while the destination's task record and its library, the finished body the task moved and, for an
    /// attempt, its request are still the ones that produced it. A superseded record is dropped without touching
    /// anything of its successor; files that cannot be reached now keep it for the next try.
    private func publishDeferred(task: Int, files: Files, request: URL?) -> DeferredPublication {
        guard let deferred = state.withLock({ $0.deferred[task] }) else { return .superseded }
        do {
            let current = resolved(deferred.record)
            var stored = try files.checkedTaskRecord()
            stored?.destination = files.key
            let body = try Files.identity(of: files.body)
            let owned = current.destination == files.key && stored.map { $0.sameTransfer(as: current) } == true
                && body != nil && body == deferred.body && (request == nil || deferred.request.map { $0 == request } ?? true)
            if owned { try fileAccess.writeResponse(deferred.response, files) }
            state.withLock { _ = $0.deferred.removeValue(forKey: task) }
            return owned ? .published : .superseded
        } catch where SavedState.isUnavailable(error) {
            return .unavailable(error)
        } catch {
            state.withLock { _ = $0.deferred.removeValue(forKey: task) }
            return .failed(error)
        }
    }

    /// Records waiting for `key` that a new transfer or a newer finished body supersedes.
    private func dropDeferred(key: String) {
        let waiting = state.withLock { $0.deferred }
        guard !waiting.isEmpty else { return }
        let superseded = waiting.filter { resolved($0.value.record).destination == key }.map(\.key)
        state.withLock { state in for task in superseded { state.deferred[task] = nil } }
    }

    private func unavailableAsInterruption<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch where SavedState.isUnavailable(error) { throw SavedStateUnavailable(error) }
    }

    /// Host tests: waits for `task`'s outcome at `destination`, as a running attempt does.
    func waitForOutcome(of task: Int, at destination: URL) async throws {
        let key = Files(destination: destination).key
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            state.withLock { $0.waiters[key] = Waiter(token: UUID(), taskID: task, continuation: continuation, progress: { _ in },
                                                      base: 0, capacity: { _ in .max }, destination: destination) }
        }
    }
    func isWaiting(at destination: URL) -> Bool { state.withLock { $0.waiters[Files(destination: destination).key] != nil } }

    /// What the deferred records hold, for host tests.
    var deferredTasks: Set<Int> { state.withLock { Set($0.deferred.keys) } }
    func unclaimedOutcome(_ key: String) -> Result<Void, any Error>? { state.withLock { $0.unclaimed[key] } }

    static func record(of description: String?) -> TaskRecord? {
        description.flatMap { try? JSONDecoder().decode(TaskRecord.self, from: Data($0.utf8)) }
    }

    private static func record(of task: URLSessionTask) -> TaskRecord? { record(of: task.taskDescription) }

    // MARK: - Files

    struct Files: Sendable {
        let key: String
        let directory: URL
        let name: String
        init(destination: URL) { self.init(key: destination.standardizedFileURL.path) }
        init(key: String) {
            self.key = key
            let destination = URL(fileURLWithPath: key)
            directory = destination.deletingLastPathComponent().appendingPathComponent("background-transfers", isDirectory: true)
            name = destination.lastPathComponent
        }
        var body: URL { directory.appendingPathComponent(name + ".body") }
        /// A finished body on its way in, beside the retained one until it replaces it.
        var incoming: URL { directory.appendingPathComponent(name + ".body.incoming") }

        /// A file's identity (device and inode): the body a waiting record belongs to, wherever its folder moved.
        struct Identity: Equatable, Sendable {
            let device: dev_t
            let inode: ino_t
        }

        /// Nil when the file is confirmed missing; thrown when it cannot be examined now.
        static func identity(of url: URL) throws -> Identity? {
            var info = stat()
            if stat(url.path, &info) == 0 { return Identity(device: info.st_dev, inode: info.st_ino) }
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        var responseFile: URL { directory.appendingPathComponent(name + ".response.json") }
        var recordFile: URL { directory.appendingPathComponent(name + ".task.json") }
        var resumeFile: URL { directory.appendingPathComponent(name + ".resume") }

        func write(_ record: TaskRecord) throws { try JSONEncoder().encode(record).write(to: recordFile, options: .atomic) }
        /// Writes `response` stamped for the body in place now.
        func write(_ response: ResponseRecord) throws {
            var stamped = response
            stamped.body = try Self.stamp(of: body)
            try JSONEncoder().encode(stamped).write(to: responseFile, options: .atomic)
        }
        /// A file's stamp: nil when it is confirmed missing; thrown when it cannot be examined now.
        static func stamp(of url: URL) throws -> BodyStamp? {
            var info = stat()
            if stat(url.path, &info) == 0 { return BodyStamp(inode: UInt64(info.st_ino), size: Int64(info.st_size)) }
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        func taskRecord() -> TaskRecord? { (try? Data(contentsOf: recordFile)).flatMap { try? JSONDecoder().decode(TaskRecord.self, from: $0) } }
        func finishedResponse() -> ResponseRecord? { try? checkedFinishedResponse() }
        /// The finished response: nil when the body or its record is missing (`ENOENT`), the record is damaged, or it was
        /// written for another body (a predecessor's record left beside a newer body); throws when either cannot be
        /// examined or read now, so it is never taken for missing.
        func checkedFinishedResponse() throws -> ResponseRecord? {
            guard let stamp = try Self.stamp(of: body), let data = try SavedState.contents(of: responseFile),
                  let response = try? JSONDecoder().decode(ResponseRecord.self, from: data) else { return nil }
            return response.body == stamp ? response : nil
        }
        /// The task record: nil when missing or damaged; throws when it cannot be read now.
        func checkedTaskRecord() throws -> TaskRecord? {
            try SavedState.contents(of: recordFile).flatMap { try? JSONDecoder().decode(TaskRecord.self, from: $0) }
        }
        func writeResumeData(_ data: Data) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: resumeFile, options: .atomic)
        }
        /// Whether the destination's library folder (its `media/`) is there: false only when it is confirmed missing;
        /// throws when it cannot be examined now. A late callback never recreates an old one.
        static func libraryFolderIsPresent(_ destination: String) throws -> Bool {
            let folder = URL(fileURLWithPath: destination).deletingLastPathComponent()
            var info = stat()
            if stat(folder.path, &info) == 0 { return info.st_mode & S_IFMT == S_IFDIR }
            let code = errno
            if code == ENOENT || code == ENOTDIR { return false }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        /// Whether the destination's library folder (its `media/`) exists: a late callback never recreates an old one.
        static func libraryFolderExists(_ destination: String) -> Bool {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: URL(fileURLWithPath: destination).deletingLastPathComponent().path, isDirectory: &directory)
                && directory.boolValue
        }
        /// Resume data continues a task issued with the same base and identity only. The stored record names the
        /// destination its file sits beside, wherever a Keep or a restored backup put the folder: it is compared as
        /// that, never by the path it was written with.
        func resumeData(matching record: TaskRecord) -> Data? {
            guard var stored = taskRecord() else { return nil }
            stored.destination = key
            guard stored.sameTransfer(as: record) else { return nil }
            return try? Data(contentsOf: resumeFile)
        }
        func removeResumeData() { try? FileManager.default.removeItem(at: resumeFile) }
        func removeFinished() {
            try? FileManager.default.removeItem(at: body)
            try? FileManager.default.removeItem(at: responseFile)
        }
        func removeAll() {
            removeFinished(); removeResumeData()
            try? FileManager.default.removeItem(at: incoming)
            try? FileManager.default.removeItem(at: recordFile)
        }
    }
}

/// A background-session task as `BackgroundMediaDownloads.reconcile` sees it (host tests inject their own).
protocol ReconciledTransfer: AnyObject {
    var taskIdentifier: Int { get }
    var taskDescription: String? { get }
    var state: URLSessionTask.State { get }
    func cancel()
}

extension URLSessionTask: ReconciledTransfer {}
