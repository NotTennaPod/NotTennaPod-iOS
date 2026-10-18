import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite struct ProxyNetworkEnvironmentTests {
    @Test func savedSettingsRouteActualFeedFetchAndResetRetainsExistingSharedClientUntilConfirmedOK() async throws {
        let xml = Data("<rss version=\"2.0\"><channel><title>Proxy feed</title><link>https://example.com</link><description>Fixture</description></channel></rss>".utf8)
        let first = try await LoopbackHTTPServer.start { _ in .init(body: xml) }
        let second = try await LoopbackHTTPServer.start { _ in .init(body: xml) }
        defer { first.stop(); second.stop() }
        let a = PodcastProxy(kind: .http, host: "127.0.0.1", port: first.url.port!)
        let b = PodcastProxy(kind: .http, host: "127.0.0.1", port: second.url.port!)
        let environment = ProxyNetworkEnvironment(configuration: a)
        let fetcher = FeedFetcher(transport: environment)
        let request = FeedFetchRequest(source: "http://proxy-origin.invalid/feed")
        guard case .updated(let feed) = try await fetcher.fetch(request) else { Issue.record("Missing feed"); return }
        #expect(feed.feed.title == "Proxy feed")
        environment.update(b, reinitializeShared: false)
        _ = try await fetcher.fetch(request)
        #expect(first.requests.count == 2 && second.requests.isEmpty)
        let newBuilder = try environment.makeTransport()
        _ = try await newBuilder.send(URLRequest(url: URL(string: request.source)!))
        #expect(second.requests.count == 1)
        environment.update(b, reinitializeShared: true)
        _ = try await fetcher.fetch(request)
        #expect(first.requests.count == 2 && second.requests.count == 2)
    }
    @Test func confirmedOKCapturesClientBeforeLaterResetEvenWithoutAnInterveningRequest() async throws {
        let first = try await LoopbackHTTPServer.start { _ in .init(body: Data("first".utf8)) }
        defer { first.stop() }
        let environment = ProxyNetworkEnvironment(configuration: .init())
        let configured = PodcastProxy(kind: .http, host: "127.0.0.1", port: first.url.port!)
        environment.update(configured, reinitializeShared: true)
        environment.update(.init(kind: .http), reinitializeShared: false)
        #expect(environment.sharedConfiguration() == configured)
        let response = try await environment.send(URLRequest(url: URL(string: "http://proxy-origin.invalid/feed")!))
        #expect(response.body == Data("first".utf8) && first.requests.count == 1)
    }
    @Test func headTestFollowsRedirectsWithoutSavingAndRejectsStatusFailures() async throws {
        let proxy = try await LoopbackHTTPServer.start { request in
            if request.path.hasSuffix("/start") { return .init(status: 302, headers: ["Location": "http://other-origin.invalid/end"]) }
            return .init(status: request.path.hasSuffix("/fail") ? 503 : 204)
        }
        defer { proxy.stop() }
        let configuration = PodcastProxy(kind: .http, host: "127.0.0.1", port: proxy.url.port!)
        try await ProxyConnectionTest(endpoint: URL(string: "http://proxy-origin.invalid/start")!).run(configuration)
        #expect(proxy.requests.count == 2 && proxy.requests.allSatisfy { $0.method == "HEAD" })
        #expect(proxy.requests.last?.path == "http://other-origin.invalid/end")
        await #expect(throws: ProxyConnectionTest.Failure.self) {
            try await ProxyConnectionTest(endpoint: URL(string: "http://proxy-origin.invalid/fail")!).run(configuration)
        }
    }
}
