import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.timeLimit(.minutes(1))) struct PodcastProxyTests {
    @Test func plainHTTPUsesForwardProxyWithoutResolvingOriginOrSendingCredentialsPreemptively() async throws {
        let proxy = try await LoopbackHTTPServer.start { _ in .init() }
        defer { proxy.stop() }
        let transport = try URLSessionFeedTransport(proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!, username: "fixture-user", password: "fixture-secret"))
        let url = URL(string: "http://proxy-target.invalid/feed")!
        let response = try await transport.send(URLRequest(url: url))
        #expect(response.status == 200 && response.url == url)
        let request = try #require(proxy.requests.first)
        #expect(proxy.requests.count == 1)
        #expect(request.method == "GET" && request.path == url.absoluteString)
        #expect(request.headers["proxy-authorization"] == nil && request.headers["authorization"] == nil)
    }
    @Test func proxyBasicChallengeUsesOnlyProxyCredentialsAndStopsOnRejection() async throws {
        let expected = "Basic " + Data("fixture-user:fixture-secret".utf8).base64EncodedString()
        let proxy = try await LoopbackHTTPServer.start { request in
            if request.headers["proxy-authorization"] == expected { return .init() }
            return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"proxy-fixture\""])
        }
        defer { proxy.stop() }
        let configuration = PodcastProxy(kind: .http, host: "127.0.0.1", port: proxy.url.port!, username: "fixture-user", password: "fixture-secret")
        let transport = try URLSessionFeedTransport(proxy: configuration)
        let url = URL(string: "http://proxy-target.invalid/feed")!
        let response = try await transport.send(URLRequest(url: url))
        #expect(response.status == 200)
        #expect(proxy.requests.count == 2)
        #expect(proxy.requests.first?.headers["proxy-authorization"] == nil)
        #expect(proxy.requests.last?.headers["proxy-authorization"] == expected)
        #expect(proxy.requests.allSatisfy { $0.headers["authorization"] == nil })
        let rejecting = try await LoopbackHTTPServer.start { _ in .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"reject-fixture\""]) }
        defer { rejecting.stop() }
        var rejectedConfig = configuration; rejectedConfig.port = rejecting.url.port!
        let rejected = try URLSessionFeedTransport(proxy: rejectedConfig)
        await #expect(throws: (any Error).self) { try await rejected.send(URLRequest(url: url)) }
        #expect(rejecting.requests.count <= 2)
    }
    @Test func originChallengeCannotReceiveProxySecret() async throws {
        let proxy = try await LoopbackHTTPServer.start { _ in .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"origin-fixture\""]) }
        defer { proxy.stop() }
        let transport = try URLSessionFeedTransport(proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!, username: "fixture-user", password: "fixture-secret"))
        let response = try await transport.send(URLRequest(url: URL(string: "http://proxy-target.invalid/feed")!))
        #expect(response.status == 401)
        #expect(proxy.requests.count == 1)
        #expect(proxy.requests[0].headers["authorization"] == nil)
    }
    @Test func httpsCredentialsBelongToCONNECTHandshakeAndNeverAnOriginRequest() async throws {
        let expected = "Basic " + Data("fixture-user:fixture-secret".utf8).base64EncodedString()
        let proxy = try await LoopbackHTTPServer.start { request in
            if request.headers["proxy-authorization"] == expected { return .init(body: Data()) }
            return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"connect-fixture\""], body: Data())
        }
        defer { proxy.stop() }
        let transport = try URLSessionFeedTransport(proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!, username: "fixture-user", password: "fixture-secret"))
        // This fixture deliberately closes the accepted tunnel before TLS. It
        // proves proxy negotiation, not a successful HTTPS origin exchange.
        await #expect(throws: (any Error).self) {
            try await transport.send(URLRequest(url: URL(string: "https://proxy-target.invalid/feed")!))
        }
        try #require(!proxy.requests.isEmpty)
        #expect(proxy.requests.allSatisfy { $0.method == "CONNECT" && $0.path == "proxy-target.invalid:443" && $0.headers["authorization"] == nil })
        #expect(proxy.requests.contains { $0.headers["proxy-authorization"] == expected })
    }
    @Test func emptyHostResetAndDirectKeepSystemDefaultsWhileInvalidPortIsRejected() throws {
        for value in [PodcastProxy(), PodcastProxy(kind: .http, host: ""), PodcastProxy(kind: .direct, host: "saved.example", port: 80)] {
            let configuration = URLSessionConfiguration.ephemeral
            try value.apply(to: configuration)
            #expect(configuration.connectionProxyDictionary == nil)
        }
        #expect(PodcastProxy(kind: .http, host: "localhost").effectivePort == 8080)
        #expect(throws: (any Error).self) { try PodcastProxy(kind: .http, host: "localhost", port: 65536).apply(to: .ephemeral) }
    }
}
