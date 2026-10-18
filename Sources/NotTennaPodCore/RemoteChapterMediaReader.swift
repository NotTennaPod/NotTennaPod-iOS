import Foundation
import Synchronization

/// A streamed episode's chapter list needs more bytes than its budget allows on this network: on a restricted network
/// it waits for an unrestricted one; on an unrestricted one this session has no embedded chapters within limits.
public struct ChapterMediaBudgetExceeded: Error, Equatable, Sendable {
    public let restricted: Bool
    public init(restricted: Bool) { self.restricted = restricted }
}

/// The file changed between the requests of one chapter read (its validator, total length or bytes no longer match).
/// Not a result: a later load reads again.
public struct ChapterMediaChanged: Error, Equatable, Sendable { public init() {} }

/// Each metadata/artwork operation owns its network lifetime, through the configured proxy client with its redirect,
/// cookie and origin-credential rules and the User-Agent. A chapter list is read by bounded requests
/// (`BoundedChapterByteInput`); the audio relay is not used. Byte reads run on the same kind of executor used by audio
/// readers.
public struct RemoteChapterMediaReader: Sendable {
    private let proxy: PodcastProxy
    private let credentials: FeedCredentials?
    private let userAgent: String

    public init(proxy: PodcastProxy, credentials: FeedCredentials? = nil, userAgent: String = HTTPUserAgent.unversioned) {
        self.proxy = proxy; self.credentials = credentials; self.userAgent = userAgent
    }

    /// On the unrestricted streamed-media budget.
    public func read(url: URL) async throws -> [ParsedChapter]? {
        try await read(url: url, allowance: .init(bytes: AuxiliaryNetworkAdmission.streamedMediaByteLimit, restricted: false, pathLocked: false))
    }

    /// The chapter list in the media at `url`, taking at most `allowance.bytes` body bytes over all its requests.
    /// Past them: `ChapterMediaBudgetExceeded`.
    public func read(url: URL, allowance: AuxiliaryNetworkAdmission.Allowance) async throws -> [ParsedChapter]? {
        try await readTransfer(url: url, allowance: allowance).chapters
    }

    /// The chapters and the body bytes their requests took (tests).
    func readTransfer(url: URL, allowance: AuxiliaryNetworkAdmission.Allowance, budget supplied: FeedTransferBudget? = nil,
                      blockCacheBytes: Int = BoundedChapterByteInput.cacheBytes) async throws -> (chapters: [ParsedChapter]?, consumed: Int) {
        try Task.checkCancellation()
        let budget = supplied ?? FeedTransferBudget(limit: allowance.bytes)
        let input = BoundedChapterByteInput(url: url, transport: RedirectingProxyTransport(transport: try URLSessionFeedTransport(proxy: proxy)),
            credentials: credentials, userAgent: userAgent, budget: budget, allowance: allowance, cacheBytes: blockCacheBytes)
        defer { input.cancel() }
        let reader = Reader()
        let chapters = try await withTaskCancellationHandler {
            do {
                let result = try await reader.run { try EmbeddedChapterReader.read(input: input) }
                try Task.checkCancellation(); try input.checkFailure()
                guard budget.consumed <= budget.limit else { throw ChapterMediaBudgetExceeded(restricted: allowance.restricted) }
                return result
            } catch {
                try Task.checkCancellation(); try input.checkFailure()
                throw error
            }
        } onCancel: { input.cancel() }
        return (chapters, budget.consumed)
    }

    /// Only the picture's bytes are requested (Android's ChapterImageModelLoader range), through the configured
    /// proxy client with its redirect, cookie and origin-credential rules, as other pictures. At most `budget` bytes
    /// are read (the picture limit for the current network, `FeedBodyLimitExceeded` past it). A server that ignores
    /// Range sends the file from its start: it is read only up to the picture's end, when that fits the budget, and
    /// the transfer stops there, whatever the response's length.
    public func artwork(_ reference: EmbeddedChapterImage, url: URL, budget: Int = MobileImageAccess.byteLimit) async throws -> Data {
        try await artworkTransfer(reference, url: url, budget: budget).picture
    }

    /// The picture and the body bytes taken for it (the picture, and with Range ignored the audio before it).
    func artworkTransfer(_ reference: EmbeddedChapterImage, url: URL, budget: Int) async throws -> (picture: Data, received: Int) {
        try Task.checkCancellation()
        guard reference.length > 0 else { return (Data(), 0) }
        let length = reference.length, end = reference.offset + Int64(length)
        var request = URLRequest(url: url)
        request.setValue("bytes=\(reference.offset)-\(end - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let credentials { request.setValue(credentials.authorization(utf8: false), forHTTPHeaderField: "Authorization") }
        let transport = RedirectingProxyTransport(transport: try URLSessionFeedTransport(proxy: proxy))
        // A part ends at the picture's length; a whole response at the picture's end.
        let prefix = end > Int64(Int.max) ? Int.max : Int(end)
        let response = try await transport.send(request, bodyLimit: budget) { status in
            status == 206 ? length : status == 200 ? prefix : nil
        }
        try Task.checkCancellation()
        let body = response.body
        switch response.status {
        case 206:
            // "bytes <first>-<last>/<total>": the part must start at the picture.
            guard let range = response.header("Content-Range"), range.lowercased().hasPrefix("bytes "),
                  Int64(range.dropFirst(6).prefix { $0 != "-" }) == reference.offset, body.count >= length else {
                throw MediaDownloadError.invalidRange
            }
            return (Data(body.prefix(length)), body.count)
        case 200:
            guard Int64(body.count) >= end else {
                throw MediaDownloadError.wrongSize(expected: end, received: Int64(body.count))
            }
            let start = body.startIndex + Int(reference.offset)
            return (Data(body[start..<(start + length)]), body.count)
        default: throw MediaDownloadError.httpStatus(response.status)
        }
    }

    private actor Reader {
        nonisolated private let executor = BlockingReadExecutor()
        nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
        func run<Value: Sendable>(_ body: @Sendable () throws -> Value) throws -> Value { try body() }
    }
}

/// A streamed file's bytes for the chapter parser, within one budget for the whole read (`FeedTransferBudget`, shared
/// by every request, redirect and proxy-login retry).
/// - The first request asks for `bytes=0-65535` and completes at that many bytes, or fewer when less of the budget is
///   left, whether the server answers 206 or a whole 200.
/// - **Ranged** (206 from 0): the total comes from Content-Range, so skipped bytes cost nothing; each miss fetches one
///   aligned 64 KiB block, with `If-Range` when there is a strong ETag or a Last-Modified date (none is invented;
///   without one, a replacement of the same length is not detected, so there is no consistency guarantee).
///   Blocks are kept in a small LRU cache; a re-fetched block is charged again. A 200 where a part was asked for, a
///   changed total or a misplaced part means the file changed: `ChapterMediaChanged`.
/// - **Prefix** (Range ignored): the input keeps the prefix it has received. A read past it re-requests from the start,
///   growing geometrically, and is refused before any request when the bytes it needs cannot fit what is left.
///   The declared length gives the file's length; it is checked only when a response reaches the end.
/// - Failures are sticky: `read` and `checkFailure` keep throwing them, so the parser cannot turn a limit or a change
///   into "no chapters". The input never cancels itself to signal one. `cancel()` wakes a blocked read at once.
final class BoundedChapterByteInput: MediaByteInput, @unchecked Sendable {
    static let blockSize = 65_536
    static let cacheBytes = 1_048_576

    private enum Mode { case unknown, ranged, prefix }
    private struct State {
        var mode = Mode.unknown
        var length: Int64?
        var validator: String?
        var blocks: [Int64: Data] = [:]
        var recent: [Int64] = []
        var prefix = Data()
        /// The completion count of the latest prefix request: growth follows what was asked for, not the rest of a
        /// large delivered chunk that came with it.
        var asked: Int64 = 0
        var complete = false
        var failure: (any Error)?
        var cancelled = false
        var pending: Pending?
    }
    /// One blocking request: its result, and the task sending it.
    private final class Pending: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        let result = Mutex<Result<FeedHTTPResponse, any Error>?>(nil)
        let task = Mutex<Task<Void, Never>?>(nil)
        func finish(_ value: Result<FeedHTTPResponse, any Error>) {
            let first = result.withLock { stored -> Bool in
                guard stored == nil else { return false }
                stored = value; return true
            }
            if first { semaphore.signal() }
        }
    }

    private let state = Mutex(State())
    private let url: URL
    private let transport: RedirectingProxyTransport
    private let credentials: FeedCredentials?
    private let userAgent: String
    private let budget: FeedTransferBudget
    private let allowance: AuxiliaryNetworkAdmission.Allowance
    private let capacity: Int

    init(url: URL, transport: RedirectingProxyTransport, credentials: FeedCredentials?, userAgent: String,
         budget: FeedTransferBudget, allowance: AuxiliaryNetworkAdmission.Allowance, cacheBytes: Int = BoundedChapterByteInput.cacheBytes) {
        self.url = url; self.transport = transport; self.credentials = credentials; self.userAgent = userAgent
        self.budget = budget; self.allowance = allowance; capacity = max(1, cacheBytes / Self.blockSize)
    }

    var length: Int64? { state.withLock { $0.length } }
    var supportsRandomAccess: Bool { false }
    func prepareForSeek() {}

    func checkFailure() throws {
        let (cancelled, failure) = state.withLock { ($0.cancelled, $0.failure) }
        if cancelled { throw CancellationError() }
        if let failure { throw failure }
    }

    func cancel() {
        let pending = state.withLock { state -> Pending? in state.cancelled = true; return state.pending }
        pending?.task.withLock { $0 }?.cancel()
        pending?.finish(.failure(CancellationError()))
    }

    func read(at offset: Int64, maximumCount: Int) throws -> Data {
        try checkFailure()
        guard offset >= 0, maximumCount > 0 else { return Data() }
        do {
            if state.withLock({ $0.mode }) == .unknown { try first() }
            return state.withLock({ $0.mode }) == .ranged ? try ranged(offset, maximumCount) : try prefixed(offset, maximumCount)
        } catch {
            if state.withLock({ $0.cancelled }) || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            let sticky: any Error = error is FeedBodyLimitExceeded ? ChapterMediaBudgetExceeded(restricted: allowance.restricted) : error
            state.withLock { if $0.failure == nil { $0.failure = sticky } }
            try checkFailure()
            throw sticky
        }
    }

    // MARK: Requests

    private func first() throws {
        guard budget.remaining > 0 else { throw FeedBodyLimitExceeded() }
        var request = base()
        request.setValue("bytes=0-\(Self.blockSize - 1)", forHTTPHeaderField: "Range")
        // The count is taken when the response arrives, after any redirect pages and proxy-login bodies were charged.
        let budget = budget, asked = Mutex(Self.blockSize)
        let response = try fetch(request) { status in
            guard status == 200 || status == 206 else { return nil }
            let count = max(1, min(Self.blockSize, budget.remaining))
            asked.withLock { $0 = count }
            return count
        }
        let count = asked.withLock { $0 }
        let body = response.body
        switch response.status {
        case 206:
            let range = try Self.contentRange(response)
            guard range.start == 0, !body.isEmpty, Int64(body.count) <= range.end - range.start + 1 else { throw MediaDownloadError.invalidRange }
            // Without a total, a part shorter than the block asked for ends at the end of the file.
            let length = range.total ?? (range.end < Int64(Self.blockSize - 1) && Int64(body.count) == range.end + 1 ? range.end + 1 : nil)
            state.withLock {
                $0.mode = .ranged; $0.length = length; $0.validator = Self.validator(response)
                $0.blocks[0] = body; $0.recent = [0]
            }
        case 200:
            let declared = Self.declaredLength(response)
            if body.count < count, let declared, declared != Int64(body.count) {
                throw MediaDownloadError.wrongSize(expected: declared, received: Int64(body.count))
            }
            state.withLock {
                $0.mode = .prefix; $0.prefix = body; $0.asked = Int64(count); $0.validator = Self.validator(response)
                // A response ending before the completion count reached the end of the file.
                if body.count < count { $0.complete = true; $0.length = Int64(body.count) } else { $0.length = declared }
            }
        default: throw MediaDownloadError.httpStatus(response.status)
        }
    }

    private func ranged(_ offset: Int64, _ maximumCount: Int) throws -> Data {
        let (length, validator) = state.withLock { ($0.length, $0.validator) }
        if let length, offset >= length { return Data() }
        let size = Int64(Self.blockSize), index = offset / size, start = index * size
        if let block = cached(index), offset - start < Int64(block.count) { return Self.slice(block, from: Int(offset - start), maximumCount) }
        guard start <= Int64.max - size else { return Data() }
        let blockLength = length.map { min(size, $0 - start) } ?? size
        // Refused before the request: the block cannot fit what is left.
        guard blockLength > 0, blockLength <= Int64(budget.remaining) else { throw FeedBodyLimitExceeded() }
        var request = base()
        request.setValue("bytes=\(start)-\(start + blockLength - 1)", forHTTPHeaderField: "Range")
        if let validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        // A 200 means the whole (changed) file: one byte is enough to know.
        let response = try fetch(request) { $0 == 206 ? Int(blockLength) : $0 == 200 ? 1 : nil }
        switch response.status {
        case 206:
            let range = try Self.contentRange(response)
            // Only an advertised total that differs from the known (or learned) length is a change; "*" is not.
            if let length, let total = range.total, total != length { throw ChapterMediaChanged() }
            // The part must start at the block and its body match it; only without a known length may it end early,
            // at the end of the file, which it then tells.
            let full = range.end == start + blockLength - 1
            guard range.start == start, range.end <= start + blockLength - 1, Int64(response.body.count) == range.end - start + 1,
                  full || length == nil else {
                throw MediaDownloadError.invalidRange
            }
            if length == nil {
                if let total = range.total { state.withLock { $0.length = total } }
                else if !full { state.withLock { $0.length = range.end + 1 } }
            }
            store(index, response.body)
            return Self.slice(response.body, from: Int(offset - start), maximumCount)
        case 200: throw ChapterMediaChanged()
        case 416 where length == nil: return Data()
        default: throw MediaDownloadError.httpStatus(response.status)
        }
    }

    private func prefixed(_ offset: Int64, _ maximumCount: Int) throws -> Data {
        let (length, prefix, complete, validator, asked) = state.withLock { ($0.length, $0.prefix, $0.complete, $0.validator, $0.asked) }
        if let length, offset >= length { return Data() }
        let held = Int64(prefix.count)
        if offset < held { return Self.slice(prefix, from: Int(offset), maximumCount) }
        if complete { return Data() }
        var needEnd = offset > Int64.max - Int64(maximumCount) ? Int64.max : offset + Int64(maximumCount)
        if let length { needEnd = min(needEnd, length) }
        let remaining = Int64(budget.remaining)
        // Refused before the request: the whole prefix is sent again, and the part needed cannot fit what is left.
        guard needEnd <= remaining else { throw FeedBodyLimitExceeded() }
        // One block past what is needed, and at least four times what was asked for last: the prefixes asked for again
        // stay within about a third of the final one. This bounds the requested prefixes, not the bytes delivered (a
        // delivered chunk may run past what was asked for; it is charged, and a read over its budget is the limit).
        let ahead = needEnd > Int64.max - Int64(Self.blockSize) ? Int64.max : needEnd + Int64(Self.blockSize)
        let target = Int(min(remaining, max(ahead, asked > Int64.max / 4 ? Int64.max : 4 * asked)))
        let response = try fetch(base()) { $0 == 200 ? target : nil }
        guard response.status == 200 else {
            if response.status == 206 { throw ChapterMediaChanged() }
            throw MediaDownloadError.httpStatus(response.status)
        }
        let body = response.body
        guard body.count >= prefix.count, body.prefix(prefix.count) == prefix,
              validator == nil || Self.validator(response) == validator else { throw ChapterMediaChanged() }
        if body.count < target, let length, length != Int64(body.count) {
            throw MediaDownloadError.wrongSize(expected: length, received: Int64(body.count))
        }
        state.withLock {
            $0.prefix = body; $0.asked = Int64(target)
            if body.count < target { $0.complete = true; $0.length = Int64(body.count) }
        }
        return Int64(body.count) > offset ? Self.slice(body, from: Int(offset), maximumCount) : Data()
    }

    /// One request, waited for on the reading thread. `cancel()` wakes the wait at once and cancels the transfer.
    private func fetch(_ request: URLRequest, completeAfter: @escaping @Sendable (Int) -> Int?) throws -> FeedHTTPResponse {
        let pending = Pending(), transport = transport, budget = budget
        let task = Task.detached {
            do { pending.finish(.success(try await transport.send(request, budget: budget, completeAfter: completeAfter))) }
            catch { pending.finish(.failure(error)) }
        }
        pending.task.withLock { $0 = task }
        let cancelled = state.withLock { state -> Bool in
            if state.cancelled { return true }
            state.pending = pending; return false
        }
        if cancelled { task.cancel(); throw CancellationError() }
        pending.semaphore.wait()
        state.withLock { $0.pending = nil }
        try checkFailure()
        guard let result = pending.result.withLock({ $0 }) else { throw CancellationError() }
        let response = try result.get()
        // The chunk that completed this response may have taken the read past its budget (only the bytes it needed
        // had to fit): a read over its budget is the limit, never a result. Already delivered bytes are not undone.
        guard budget.consumed <= budget.limit else { throw FeedBodyLimitExceeded() }
        return response
    }

    private func base() -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let credentials { request.setValue(credentials.authorization(utf8: false), forHTTPHeaderField: "Authorization") }
        allowance.constrain(&request)
        return request
    }

    // MARK: Blocks

    private func cached(_ index: Int64) -> Data? {
        state.withLock { state in
            guard let block = state.blocks[index] else { return nil }
            state.recent.removeAll { $0 == index }; state.recent.append(index)
            return block
        }
    }

    private func store(_ index: Int64, _ block: Data) {
        state.withLock { state in
            state.blocks[index] = block
            state.recent.removeAll { $0 == index }; state.recent.append(index)
            while state.recent.count > capacity { state.blocks[state.recent.removeFirst()] = nil }
        }
    }

    // MARK: Headers

    private static func slice(_ data: Data, from index: Int, _ maximumCount: Int) -> Data {
        guard index >= 0, index < data.count else { return Data() }
        let start = data.startIndex + index
        return Data(data[start..<(start + min(maximumCount, data.count - index))])
    }

    /// "bytes <first>-<last>/<total>"; the total may be "*".
    private static func contentRange(_ response: FeedHTTPResponse) throws -> (start: Int64, end: Int64, total: Int64?) {
        guard let value = response.header("Content-Range")?.trimmingCharacters(in: .whitespaces), value.lowercased().hasPrefix("bytes ") else {
            throw MediaDownloadError.invalidRange
        }
        let parts = value.dropFirst(6).split(separator: "/", maxSplits: 1)
        let bounds = parts.first?.split(separator: "-", maxSplits: 1) ?? []
        guard parts.count == 2, bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), start >= 0, end >= start else {
            throw MediaDownloadError.invalidRange
        }
        if parts[1] == "*" { return (start, end, nil) }
        guard let total = Int64(parts[1]), total > end else { throw MediaDownloadError.invalidRange }
        return (start, end, total)
    }

    private static func declaredLength(_ response: FeedHTTPResponse) -> Int64? {
        response.header("Content-Length").flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 >= 0 ? $0 : nil }
    }

    /// A strong ETag, else Last-Modified; a weak ETag cannot validate a range.
    private static func validator(_ response: FeedHTTPResponse) -> String? {
        if let tag = response.header("ETag"), !tag.hasPrefix("W/"), !tag.isEmpty { return tag }
        return response.header("Last-Modified").flatMap { $0.isEmpty ? nil : $0 }
    }
}
