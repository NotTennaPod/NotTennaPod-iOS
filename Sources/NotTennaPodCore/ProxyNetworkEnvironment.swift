import Foundation
import Synchronization

/// Shared HTTP ownership survives screens. Reset changes future builders;
/// confirmed OK replaces the shared transport without cancelling active work.
public final class ProxyNetworkEnvironment: FeedHTTPTransport, Sendable {
    public struct Client: Equatable, Sendable {
        public let configuration: PodcastProxy
        public let identity: UUID
        public init(configuration: PodcastProxy, identity: UUID = UUID()) {
            self.configuration = configuration; self.identity = identity
        }
    }
    private struct State: Sendable {
        var configuration: PodcastProxy
        var client: Client?
        var shared: (any FeedHTTPTransport)?
    }
    private let state: Mutex<State>
    private let build: @Sendable (PodcastProxy) throws -> any FeedHTTPTransport
    public init(configuration: PodcastProxy,
                build: @escaping @Sendable (PodcastProxy) throws -> any FeedHTTPTransport = { try URLSessionFeedTransport(proxy: $0) }) {
        state = Mutex(State(configuration: configuration)); self.build = build
    }
    public func update(_ configuration: PodcastProxy, reinitializeShared: Bool) {
        state.withLock {
            $0.configuration = configuration
            if reinitializeShared { $0.client = Client(configuration: configuration); $0.shared = nil }
        }
    }
    /// Snapshot the source shared-client lifetime even when its first recipient
    /// streams to disk rather than fetching an in-memory feed response.
    public func sharedConfiguration() -> PodcastProxy { sharedClient().configuration }
    public func sharedClient() -> Client {
        state.withLock {
            if let value = $0.client { return value }
            let value = Client(configuration: $0.configuration)
            $0.client = value
            return value
        }
    }
    public func newClientConfiguration() -> PodcastProxy { state.withLock { $0.configuration } }
    public func makeTransport() throws -> any FeedHTTPTransport {
        try build(state.withLock { $0.configuration })
    }
    public func requestScope() throws -> any FeedHTTPTransport {
        try state.withLock { state in
            if let shared = state.shared { return shared }
            let client = state.client ?? Client(configuration: state.configuration)
            let configuration = client.configuration
            let transport = try build(configuration)
            state.client = client
            state.shared = transport
            return transport
        }
    }
    public func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
        try await requestScope().send(request)
    }

    public func send(_ request: URLRequest, bodyLimit: Int) async throws -> FeedHTTPResponse {
        try await requestScope().send(request, bodyLimit: bodyLimit)
    }

    public func send(_ request: URLRequest, bodyLimit: Int, completeAfter: @escaping @Sendable (Int) -> Int?) async throws -> FeedHTTPResponse {
        try await requestScope().send(request, bodyLimit: bodyLimit, completeAfter: completeAfter)
    }

    /// The caller's budget itself reaches the shared client's session delegate.
    public func send(_ request: URLRequest, budget: FeedTransferBudget, completeAfter: (@Sendable (Int) -> Int?)?) async throws -> FeedHTTPResponse {
        try await requestScope().send(request, budget: budget, completeAfter: completeAfter)
    }
}
