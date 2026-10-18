import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite struct RemoteChapterMediaReaderTests {
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
    /// A streamed episode's chapter picture is fetched from its offset, not by downloading the audio before it.
    @Test(arguments: [true, false]) func embeddedPictureIsReadByRangeAtItsOffset(honorsRange: Bool) async throws {
        let picture = Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let prefix = 4 * 1024 * 1024
        let file = Data(count: prefix) + picture + Data(count: 100_000)
        let served = Mutex(0)
        let proxy = try await LoopbackHTTPServer.start { request in
            let start = request.headers["range"].flatMap { $0.hasPrefix("bytes=") ? Int($0.dropFirst(6).prefix { $0 != "-" }) : nil }
            guard honorsRange, let start, start < file.count else {
                served.withLock { $0 += file.count }
                return .init(headers: ["Content-Type": "audio/mpeg"], body: file)
            }
            served.withLock { $0 += file.count - start }
            return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "Content-Range": "bytes \(start)-\(file.count - 1)/\(file.count)"],
                         body: file[start...])
        }
        defer { proxy.stop() }
        let reader = RemoteChapterMediaReader(proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!))
        let reference = EmbeddedChapterImage(offset: Int64(prefix), length: picture.count)
        #expect(try await reader.artwork(reference, url: URL(string: "http://chapter-media.invalid/episode.mp3")!) == picture)
        if honorsRange {
            #expect(proxy.requests.first?.headers["range"] == "bytes=\(prefix)-\(prefix + picture.count - 1)")
            #expect(served.withLock { $0 } < 1_000_000, "the audio before the picture is not downloaded")
        }
    }
    /// A server that ignores Range sends the audio before the picture: within the picture budget the picture is cut
    /// from it; beyond the budget nothing past the budget is read, whether the length is declared, absent or streamed.
    @Test func ignoredRangeIsBoundedByThePictureBudget() async throws {
        let picture = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        let late = Data(count: 6 * 1024 * 1024) + picture, early = Data(count: 1024 * 1024) + picture
        let proxy = try await LoopbackHTTPServer.start { request in
            switch URL(string: request.path)?.path {
            case "/late.mp3": .init(headers: ["Content-Type": "audio/mpeg"], body: late)
            case "/late-no-length.mp3": .init(headers: ["Content-Type": "audio/mpeg"], body: late, includeAutomaticContentLength: false)
            case "/early.mp3": .init(headers: ["Content-Type": "audio/mpeg"], body: early)
            case "/short.mp3": .init(headers: ["Content-Type": "audio/mpeg"], body: Data(count: 1024 * 1024 + 1000))
            default: .init(status: 404)
            }
        }
        defer { proxy.stop() }
        let reader = RemoteChapterMediaReader(proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!))
        let budget = 5 * 1024 * 1024
        for path in ["late.mp3", "late-no-length.mp3"] {
            await #expect(throws: FeedBodyLimitExceeded.self, "\(path)") {
                _ = try await reader.artwork(EmbeddedChapterImage(offset: Int64(late.count - picture.count), length: picture.count),
                                             url: URL(string: "http://chapter-media.invalid/\(path)")!, budget: budget)
            }
        }
        let reference = EmbeddedChapterImage(offset: 1024 * 1024, length: picture.count)
        #expect(try await reader.artwork(reference, url: URL(string: "http://chapter-media.invalid/early.mp3")!, budget: budget) == picture)
        // A response that ends before the picture gives no picture.
        await #expect(throws: (any Error).self) {
            _ = try await reader.artwork(reference, url: URL(string: "http://chapter-media.invalid/short.mp3")!, budget: budget)
        }
        // One request each: nothing is retried.
        #expect(proxy.requests.count == 4)
    }
    /// A server that ignores Range for a long episode: a picture early in the file is read up to its end and the
    /// transfer is cancelled there, whatever the response's declared length (none, or far over the budget), with the
    /// Wi-Fi and the cellular budget alike.
    static let longEpisodeCases: [(Bool, Int)] = [(true, 50 << 20), (false, 50 << 20), (true, 5 << 20), (false, 5 << 20)]
    @Test(arguments: longEpisodeCases)
    func ignoredRangeReadsOnlyUpToAnEarlyPicture(declaresLength: Bool, budget: Int) async throws {
        let picture = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 5) })
        let offset = 1024 * 1024 + 1000
        let file = Data(count: offset) + picture + Data(count: 60 * 1024 * 1024)
        // Paced writes keep each delivered chunk small, so the bytes taken have a fixed bound.
        let response = LoopbackHTTPServer.Response(headers: ["Content-Type": "audio/mpeg"], body: file, includeAutomaticContentLength: declaresLength,
                                                   pace: 16_384)
        let (disconnected, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let proxy = try await LoopbackHTTPServer.start(onClientDisconnect: { signal.yield(()) }) { _ in response }
        defer { proxy.stop(); signal.finish() }
        let reader = RemoteChapterMediaReader(proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!))
        let url = URL(string: "http://chapter-media.invalid/long-\(declaresLength)-\(budget).mp3")!
        let read = try await reader.artworkTransfer(EmbeddedChapterImage(offset: Int64(offset), length: picture.count), url: url, budget: budget)
        #expect(read.picture == picture)
        let end = offset + picture.count
        #expect(read.received >= end && read.received <= end + 128 * 1024, "received \(read.received) for a picture ending at \(end)")
        // The phone closed the transfer: the 61 MB response was never completely sent.
        for await _ in disconnected { break }
        #expect(proxy.sentResponseCount == 0)
        #expect(proxy.requests.count == 1)
    }
    /// A same-origin redirect that sets a cookie the destination requires: the cookie is kept for the rest of that
    /// one request, as on the ordinary picture path.
    @Test func redirectCookieIsKeptForThePicture() async throws {
        let picture = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 3 &+ 1) })
        let file = Data(count: 1000) + picture
        let proxy = try await LoopbackHTTPServer.start { request in
            switch URL(string: request.path)?.path {
            case "/start.mp3": return .init(status: 302, headers: ["Location": "/gated.mp3", "Set-Cookie": "gate=open; Path=/"], body: Data())
            case "/gated.mp3":
                guard request.headers["cookie"]?.contains("gate=open") == true else { return .init(status: 403, body: Data()) }
                return .init(headers: ["Content-Type": "audio/mpeg"], body: file)
            default: return .init(status: 404, body: Data())
            }
        }
        defer { proxy.stop() }
        let reader = RemoteChapterMediaReader(proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!))
        #expect(try await reader.artwork(EmbeddedChapterImage(offset: 1000, length: picture.count),
                                         url: URL(string: "http://chapter-media.invalid/start.mp3")!) == picture)
    }
    /// A saved username with an empty password is sent to the origin, as feeds send it; a cross-origin redirect
    /// drops it.
    @Test func emptyPasswordReachesTheOriginAndCrossOriginRedirectDropsIt() async throws {
        let picture = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 5 &+ 2) })
        let file = Data(count: 1000) + picture
        let credentials = FeedCredentials(username: "listener", password: "")
        let proxy = try await LoopbackHTTPServer.start { request in
            switch request.path {
            case "http://chapter-media.invalid/private.mp3":
                guard request.headers["authorization"] == credentials.authorization(utf8: false) else { return .init(status: 401, body: Data()) }
                return .init(headers: ["Content-Type": "audio/mpeg"], body: file)
            case "http://chapter-media.invalid/moved.mp3":
                return .init(status: 302, headers: ["Location": "http://chapter-cdn.invalid/public.mp3"], body: Data())
            case "http://chapter-cdn.invalid/public.mp3":
                guard request.headers["authorization"] == nil else { return .init(status: 400, body: Data()) }
                return .init(headers: ["Content-Type": "audio/mpeg"], body: file)
            default: return .init(status: 404, body: Data())
            }
        }
        defer { proxy.stop() }
        let reader = RemoteChapterMediaReader(proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!), credentials: credentials)
        let reference = EmbeddedChapterImage(offset: 1000, length: picture.count)
        #expect(try await reader.artwork(reference, url: URL(string: "http://chapter-media.invalid/private.mp3")!) == picture)
        #expect(try await reader.artwork(reference, url: URL(string: "http://chapter-media.invalid/moved.mp3")!) == picture)
        #expect(proxy.requests.first { $0.path.hasSuffix("/moved.mp3") }?.headers["authorization"] == credentials.authorization(utf8: false))
    }
    /// With Range ignored, a picture ending one byte inside the budget loads even though the audio after it arrives in
    /// the same chunk.
    @Test func pictureEndingJustInsideTheBudgetLoads() async throws {
        let budget = 2 * 1024 * 1024
        let picture = Data((0..<131_072).map { UInt8(truncatingIfNeeded: $0 &* 9 &+ 4) })
        let offset = budget - 1 - picture.count
        let file = Data(count: offset) + picture + Data(count: 1024 * 1024)
        let proxy = try await LoopbackHTTPServer.start { _ in .init(headers: ["Content-Type": "audio/mpeg"], body: file) }
        defer { proxy.stop() }
        let reader = RemoteChapterMediaReader(proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!))
        #expect(try await reader.artwork(EmbeddedChapterImage(offset: Int64(offset), length: picture.count),
                                         url: URL(string: "http://chapter-media.invalid/edge.mp3")!, budget: budget) == picture)
    }
    /// A proxy that asks for its login does not use up one of the 20 redirects a picture may follow.
    @Test func proxyChallengeDoesNotUseARedirect() async throws {
        let picture = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        let file = Data(count: 1000) + picture
        let login = "Basic " + Data("proxy:secret".utf8).base64EncodedString()
        let proxy = try await LoopbackHTTPServer.start { request in
            guard request.headers["proxy-authorization"] == login else {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"proxy\""], body: Data())
            }
            let path = URL(string: request.path)?.path ?? ""
            if path.hasPrefix("/hop-"), let hop = Int(path.dropFirst(5).prefix { $0.isNumber }) {
                return .init(status: 302, headers: ["Location": hop == 19 ? "/final.mp3" : "/hop-\(hop + 1).mp3"], body: Data())
            }
            return path == "/final.mp3" ? .init(headers: ["Content-Type": "audio/mpeg"], body: file) : .init(status: 404, body: Data())
        }
        defer { proxy.stop() }
        let reader = RemoteChapterMediaReader(proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!,
                                                           username: "proxy", password: "secret"))
        #expect(try await reader.artwork(EmbeddedChapterImage(offset: 1000, length: picture.count),
                                         url: URL(string: "http://chapter-media.invalid/hop-0.mp3")!) == picture)
    }
    /// Streamed without a length past the budget: reading stops near the budget instead of taking the whole file.
    @Test func ignoredRangeStreamStopsNearTheBudget() async throws {
        let chunk = Data(count: 1024 * 1024)
        let proxy = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg"], body: chunk, keepConnectionOpen: true, includeAutomaticContentLength: false)
        }
        defer { proxy.stop() }
        let reader = RemoteChapterMediaReader(proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!))
        let url = URL(string: "http://chapter-media.invalid/endless.mp3")!
        let finished = Mutex(false)
        let load = Task {
            defer { finished.withLock { $0 = true } }
            return try await reader.artwork(EmbeddedChapterImage(offset: 30 * 1024 * 1024, length: 100_000), url: url, budget: 5 * 1024 * 1024)
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while proxy.requests.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        var sent = 1
        while sent < 40, !finished.withLock({ $0 }) {
            do { try await proxy.appendResponseBody(chunk, toLatestRequestFor: url.absoluteString, isFinal: false) } catch { break }
            sent += 1
        }
        if !finished.withLock({ $0 }) { try? await proxy.appendResponseBody(Data(), toLatestRequestFor: url.absoluteString, isFinal: true) }
        let result = await load.result
        #expect(throws: FeedBodyLimitExceeded.self) { _ = try result.get() }
        #expect(sent <= 20, "sent \(sent) MB before the phone stopped reading")
        #expect(proxy.requests.count == 1)
    }
    /// A connection lost in the middle of a chapter picture gives no picture, never a partial one.
    @Test func interruptedEmbeddedPictureFailsWithoutAPartialPicture() async throws {
        let picture = Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) })
        let file = Data(count: 200_000) + picture
        let proxy = try await LoopbackHTTPServer.start { request in
            let start = request.headers["range"].flatMap { $0.hasPrefix("bytes=") ? Int($0.dropFirst(6).prefix { $0 != "-" }) : nil } ?? 0
            return .init(status: start == 0 ? 200 : 206, headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(file.count - start)",
                "Content-Range": "bytes \(start)-\(file.count - 1)/\(file.count)"], body: file[start..<(start + 1000)])
        }
        defer { proxy.stop() }
        let reader = RemoteChapterMediaReader(proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!))
        await #expect(throws: (any Error).self) {
            _ = try await reader.artwork(EmbeddedChapterImage(offset: 200_000, length: picture.count), url: URL(string: "http://chapter-media.invalid/cut.mp3")!)
        }
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
