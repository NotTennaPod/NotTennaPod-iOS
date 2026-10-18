import Foundation
import Testing
@testable import NotTennaPodCore

@Suite struct PlaybackURLResolverTests {
    @Test func sharedProxyResolvesHEADWithoutMediaCredentialsAndRetainsResultAcrossProxyReplacement() async throws {
        let second = try await LoopbackHTTPServer.start { _ in .init(status: 503) }
        let first = try await LoopbackHTTPServer.start { request in
            if request.path.hasSuffix("/start") { return .init(status: 302, headers: ["Location": "http://resolved.invalid/media"]) }
            return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"media\""])
        }
        defer { first.stop(); second.stop() }
        let environment = ProxyNetworkEnvironment(configuration: .init(kind: .http, host: "127.0.0.1", port: first.url.port!))
        let resolver = PlaybackURLResolver(transport: environment, userAgent: "AntennaPod/fixture")
        let original = URL(string: "http://original.invalid/start")!
        let result = try await resolver.resolve(original)
        #expect(result.absoluteString == "http://resolved.invalid/media")
        #expect(first.requests.count == 2)
        #expect(first.requests.allSatisfy { $0.method == "HEAD" && $0.headers["authorization"] == nil && $0.headers["user-agent"] == "AntennaPod/fixture" })
        environment.update(.init(kind: .http, host: "127.0.0.1", port: second.url.port!), reinitializeShared: true)
        #expect(try await resolver.resolve(original) == result)
        #expect(second.requests.isEmpty)
        let another = URL(string: "http://original.invalid/another")!
        #expect(try await resolver.resolve(another) == another)
        #expect(second.requests.count == 1 && second.requests.first?.method == "HEAD")
    }

    @Test func failedLookupFallsBackAndCachesOriginalButNewFactoryTriesAgain() async throws {
        let transport = ResolverFailureTransport()
        let url = URL(string: "https://original.invalid/audio")!
        let resolver = PlaybackURLResolver(transport: transport)
        #expect(try await resolver.resolve(url) == url)
        #expect(try await resolver.resolve(url) == url)
        #expect(await transport.count == 1)
        #expect(try await PlaybackURLResolver(transport: transport).resolve(url) == url)
        #expect(await transport.count == 2)
    }

    @Test func cancellationDoesNotPublishFallbackOrPoisonRetryCache() async throws {
        let transport = ResolverCancellationTransport()
        let resolver = PlaybackURLResolver(transport: transport)
        let url = URL(string: "https://original.invalid/audio")!
        await #expect(throws: CancellationError.self) { try await resolver.resolve(url) }
        #expect(try await resolver.resolve(url).absoluteString == "https://resolved.invalid/audio")
        #expect(await transport.count == 2)
    }

    @Test func localFilesNeverMakeAResolutionRequest() async throws {
        let transport = ResolverFailureTransport()
        let resolver = PlaybackURLResolver(transport: transport)
        let url = URL(fileURLWithPath: "/owned-fixture/audio.mp3")
        #expect(try await resolver.resolve(url) == url)
        #expect(await transport.count == 0)
    }
}

private actor ResolverFailureTransport: FeedHTTPTransport {
    var count = 0
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse { count += 1; throw URLError(.cannotConnectToHost) }
}
private actor ResolverCancellationTransport: FeedHTTPTransport {
    var count = 0
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
        count += 1
        if count == 1 { throw URLError(.cancelled) }
        return .init(url: URL(string: "https://resolved.invalid/audio")!, status: 200)
    }
}
