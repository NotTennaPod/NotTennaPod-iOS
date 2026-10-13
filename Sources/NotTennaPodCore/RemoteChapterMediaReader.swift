import Foundation

/// Each metadata/artwork operation owns its network lifetime. The existing relay
/// preserves configured proxy, redirects, authentication and User-Agent behavior;
/// bounded byte reads run on the same kind of executor used by audio readers.
public struct RemoteChapterMediaReader: Sendable {
    private let proxy: PodcastProxy
    private let credentials: FeedCredentials?
    private let userAgent: String

    public init(proxy: PodcastProxy, credentials: FeedCredentials? = nil, userAgent: String = HTTPUserAgent.unversioned) {
        self.proxy = proxy; self.credentials = credentials; self.userAgent = userAgent
    }

    public func read(url: URL) async throws -> [ParsedChapter]? {
        try await withInput(url: url) { try EmbeddedChapterReader.read(input: $0) }
    }

    public func artwork(_ reference: EmbeddedChapterImage, url: URL) async throws -> Data {
        try await withInput(url: url) { try reference.read(input: $0) }
    }

    private func withInput<Value: Sendable>(url: URL,
        _ body: @escaping @Sendable (any MediaByteInput) throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let failure = PCMSourceFailure()
        let relay = try await NativeStreamingRelay.start(url: url, playlist: false, proxy: proxy,
            credentials: credentials, userAgent: userAgent, onFailure: { failure.fail($0) })
        defer { relay.cancel() }
        try Task.checkCancellation()
        let input = try HTTPCodecByteInput(url: relay.url, sequentialReadAheadBytes: 65_536)
        defer { input.cancel() }
        let lease = input.makeReadLease()
        defer { lease.cancel() }
        let reader = Reader()
        return try await withTaskCancellationHandler {
            do {
                let result = try await reader.run { try body(lease) }
                try Task.checkCancellation(); try failure.check()
                return result
            } catch {
                try Task.checkCancellation(); try failure.check()
                throw error
            }
        } onCancel: { lease.cancel(); input.cancel(); relay.cancel() }
    }

    private actor Reader {
        nonisolated private let executor = BlockingReadExecutor()
        nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
        func run<Value: Sendable>(_ body: @Sendable () throws -> Value) throws -> Value { try body() }
    }
}
