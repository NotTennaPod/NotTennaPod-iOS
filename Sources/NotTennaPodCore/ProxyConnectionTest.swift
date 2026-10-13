import Foundation

/// The dialog's HEAD probe has its own transport; testing never changes the
/// saved configuration or the requests already owned by the application.
public struct ProxyConnectionTest: Sendable {
    private let endpoint: URL
    private let makeTransport: @Sendable (PodcastProxy) throws -> any FeedHTTPTransport
    public init(endpoint: URL = URL(string: "https://www.example.com")!,
                makeTransport: @escaping @Sendable (PodcastProxy) throws -> any FeedHTTPTransport = { try URLSessionFeedTransport(proxy: $0) }) {
        self.endpoint = endpoint; self.makeTransport = makeTransport
    }
    public func run(_ proxy: PodcastProxy) async throws {
        let transport = try makeTransport(proxy)
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "HEAD"
        request.setValue(HTTPUserAgent.proxyTest, forHTTPHeaderField: "User-Agent")
        for redirect in 0...20 {
            try Task.checkCancellation()
            let response = try await transport.send(request)
            if (200..<300).contains(response.status) { return }
            guard [300, 301, 302, 303, 307, 308].contains(response.status), let location = response.header("Location"),
                  let url = URL(string: location, relativeTo: response.url)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw Failure.status(response.status)
            }
            guard redirect < 20 else { throw URLError(.httpTooManyRedirects) }
            request.url = url
        }
    }
    public enum Failure: Error, LocalizedError { case status(Int)
        public var errorDescription: String? {
            switch self { case .status(let code): HTTPURLResponse.localizedString(forStatusCode: code) }
        }
    }
}
