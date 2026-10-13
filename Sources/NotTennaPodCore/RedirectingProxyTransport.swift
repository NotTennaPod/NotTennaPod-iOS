import Foundation

/// Redirect handling remains outside the native session so every hop selects
/// the appropriate forward HTTP or HTTPS CONNECT configuration. Origin secrets
/// cannot be restored after a cross-origin hop, including a return to the origin.
public struct RedirectingProxyTransport: FeedHTTPTransport {
    private let transport: any FeedHTTPTransport
    public init(transport: any FeedHTTPTransport) { self.transport = transport }
    public func send(_ input: URLRequest) async throws -> FeedHTTPResponse {
        try await send(input, limit: nil)
    }

    public func send(_ input: URLRequest, bodyLimit: Int) async throws -> FeedHTTPResponse {
        try await send(input, limit: bodyLimit)
    }

    private func send(_ input: URLRequest, limit: Int?) async throws -> FeedHTTPResponse {
        let transport = try transport.requestScope()
        var request = input
        for count in 0...20 {
            try Task.checkCancellation()
            let response: FeedHTTPResponse
            if let limit { response = try await transport.send(request, bodyLimit: limit) } else { response = try await transport.send(request) }
            guard [301, 302, 303, 307, 308].contains(response.status),
                  let location = response.header("Location"),
                  let target = URL(string: location, relativeTo: response.url)?.absoluteURL,
                  ["http", "https"].contains(target.scheme?.lowercased() ?? "") else { return response }
            guard count < 20 else { throw URLError(.httpTooManyRedirects) }
            guard var parts = URLComponents(url: target, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
            parts.user = nil; parts.password = nil; parts.fragment = nil
            guard let next = parts.url else { throw URLError(.badURL) }
            if !HTTPOrigin.matches(response.url, next) { request.setValue(nil, forHTTPHeaderField: "Authorization") }
            if (response.status == 303 && request.httpMethod != "HEAD") ||
                ([301, 302].contains(response.status) && request.httpMethod == "POST") {
                request.httpMethod = "GET"; request.httpBody = nil; request.httpBodyStream = nil
                for field in ["Content-Type", "Content-Length", "Transfer-Encoding"] { request.setValue(nil, forHTTPHeaderField: field) }
            }
            request.url = next
        }
        throw URLError(.httpTooManyRedirects)
    }
}
