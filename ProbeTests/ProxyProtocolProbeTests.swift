import Foundation
import Testing
@testable import NotTennaPodCore

/// Deliberately outside the ordinary suites: this uses the source's real public
/// TLS endpoint through the owned loopback protocol fixture. Start the fixture
/// (`Tools/test-fixtures.sh start`) before selecting this probe.
@Suite(.serialized, .timeLimit(.minutes(2))) struct ProxyProtocolProbeTests {
    @Test(arguments: [PodcastProxy.Kind.http, .socks])
    func authenticatedProxyCompletesSourceHTTPSHeadWithNormalTrustValidation(kind: PodcastProxy.Kind) async throws {
        let proxy = PodcastProxy(kind: kind, host: "127.0.0.1", port: kind == .http ? 18790 : 18791,
                                 username: "fixture-user", password: "fixture-secret")
        try await ProxyConnectionTest().run(proxy)
        let transport = try URLSessionFeedTransport(proxy: proxy)
        var request = URLRequest(url: URL(string: "https://www.example.com")!)
        request.httpMethod = "HEAD"
        let response = try await transport.send(request)
        #expect((200..<300).contains(response.status))
        #expect(response.url.scheme == "https" && response.body.isEmpty)
    }
}
