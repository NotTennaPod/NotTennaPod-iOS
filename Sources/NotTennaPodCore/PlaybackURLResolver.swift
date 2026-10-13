import Foundation

/// The active Android media factory resolves redirects with a shared-client HEAD,
/// then retains the result for that factory's lifetime, independently of media bytes.
public actor PlaybackURLResolver {
    private let transport: RedirectingProxyTransport
    private let userAgent: String
    private var resolved: [URL: URL] = [:]

    public init(transport: any FeedHTTPTransport, userAgent: String = HTTPUserAgent.unversioned) {
        self.transport = RedirectingProxyTransport(transport: transport)
        self.userAgent = userAgent
    }

    public func resolve(_ url: URL) async throws -> URL {
        try Task.checkCancellation()
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return url }
        if let cached = resolved[url] { return cached }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let result: URL
        do {
            let response = try await transport.send(request)
            // RedirectChecker returns the final request URL even for an HTTP error.
            result = response.url
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            // A failed redirect lookup must not prevent the media loader trying the original.
            result = url
        }
        try Task.checkCancellation()
        if resolved[url] == nil { resolved[url] = result }
        return result
    }
}
