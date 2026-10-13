import Foundation

/// Each synchronization provider retains its account-local cookie/session
/// lifetime while using the shared client's configuration captured at creation.
public struct ProxySynchronizationTransport: SynchronizationHTTPTransport {
    private let transport: RedirectingProxyTransport
    public init(proxy: PodcastProxy) throws {
        transport = RedirectingProxyTransport(transport: try URLSessionFeedTransport(proxy: proxy))
    }
    public func send(_ request: URLRequest) async throws -> SynchronizationHTTPResponse {
        let response = try await transport.send(request)
        return .init(status: response.status, body: response.body)
    }
}
