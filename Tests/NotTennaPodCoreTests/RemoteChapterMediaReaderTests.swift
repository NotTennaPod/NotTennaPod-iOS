import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.timeLimit(.minutes(1))) struct RemoteChapterMediaReaderTests {
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/EmbeddedChapters"))
    }
    @Test func metadataAndArtworkUseConfiguredProxyAndCapturedCredentials() async throws {
        let file = try fixture("original-auphonic.mp3"), data = try Data(contentsOf: file)
        let credentials = FeedCredentials(username: "chapter", password: "fixture")
        let proxy = try await LoopbackHTTPServer.start { request in
            guard request.headers["authorization"] == credentials.authorization(utf8: false),
                  request.headers["user-agent"] == "AntennaPod/chapter-test" else { return .init(status: 403) }
            return .init(headers: ["Content-Type": "audio/mpeg"], body: data)
        }
        defer { proxy.stop() }
        let source = URL(string: "http://chapter-media.invalid/episode.mp3")!
        let reader = RemoteChapterMediaReader(proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!),
            credentials: credentials, userAgent: "AntennaPod/chapter-test")
        let chapters = try #require(try await reader.read(url: source))
        #expect(chapters == (try EmbeddedChapterReader.read(url: file)))
        let image = try #require(chapters[0].imageURL.flatMap(EmbeddedChapterImage.init(url:)))
        #expect(try await reader.artwork(image, url: source) == image.read(url: file))
        #expect(proxy.requests.count == 2)
        #expect(proxy.requests.allSatisfy { $0.path == source.absoluteString })
    }
    @Test func chunkedUnknownLengthMediaStillFindsChapters() async throws {
        let file = try fixture("original-auphonic.opus"), data = try Data(contentsOf: file)
        let chunked = Data("\(String(data.count, radix: 16))\r\n".utf8) + data + Data("\r\n0\r\n\r\n".utf8)
        let proxy = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Transfer-Encoding": "chunked", "Content-Type": "audio/ogg"], body: chunked, includeAutomaticContentLength: false)
        }
        defer { proxy.stop() }
        let reader = RemoteChapterMediaReader(proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!))
        #expect(try await reader.read(url: URL(string: "http://chapter-media.invalid/live.opus")!) == EmbeddedChapterReader.read(url: file))
        #expect(proxy.requests.count == 1)
    }
    @Test func crossOriginRedirectDropsOriginCredentials() async throws {
        let data = try Data(contentsOf: fixture("nero-ordinary.m4a"))
        let credentials = FeedCredentials(username: "chapter", password: "fixture")
        let proxy = try await LoopbackHTTPServer.start { request in
            if request.path == "http://chapter-media.invalid/start" {
                return .init(status: 302, headers: ["Location": "http://chapter-cdn.invalid/final"])
            }
            guard request.path == "http://chapter-cdn.invalid/final", request.headers["authorization"] == nil else { return .init(status: 403) }
            return .init(headers: ["Content-Type": "audio/mp4"], body: data)
        }
        defer { proxy.stop() }
        let reader = RemoteChapterMediaReader(proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!), credentials: credentials)
        #expect(try await reader.read(url: URL(string: "http://chapter-media.invalid/start")!)?.count == 3)
        #expect(proxy.requests.map(\.path) == ["http://chapter-media.invalid/start", "http://chapter-cdn.invalid/final"])
        #expect(proxy.requests.first?.headers["authorization"] == credentials.authorization(utf8: false))
    }
    @Test func cancellationClosesHeldUpstreamReadAndAllowsRetry() async throws {
        let (started, startSignal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (disconnected, disconnectSignal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let proxy = try await LoopbackHTTPServer.start(onClientDisconnect: {
            disconnectSignal.yield(()); disconnectSignal.finish()
        }) { _ in
            startSignal.yield(()); startSignal.finish()
            return .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "100000"],
                         body: Data("ID".utf8), keepConnectionOpen: true)
        }
        defer { proxy.stop(); startSignal.finish(); disconnectSignal.finish() }
        let reader = RemoteChapterMediaReader(proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!))
        let task = Task { try await reader.read(url: URL(string: "http://chapter-media.invalid/held")!) }
        defer { task.cancel() }
        for await _ in started { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        for await _ in disconnected { break }
        #expect(proxy.requests.count == 1)
        let file = try fixture("id3-v3-ordered.mp3"), data = try Data(contentsOf: file)
        let retry = try await LoopbackHTTPServer.start { _ in .init(body: data) }
        defer { retry.stop() }
        let retryReader = RemoteChapterMediaReader(proxy: .init(kind: .http, host: "127.0.0.1", port: retry.url.port!))
        #expect(try await retryReader.read(url: URL(string: "http://chapter-media.invalid/held")!)?.count == 3)
    }
}
