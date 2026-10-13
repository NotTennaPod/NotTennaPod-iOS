import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct PlaybackRequestContextTests {
    private let userAgent = "AntennaPod/PC-I2-captured"
    private func fixture(_ name: String, directory: String) throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/" + directory))
#else
        try #require(Bundle(for: RequestContextFixtures.self).url(forResource: name, withExtension: nil,
            subdirectory: directory == "StreamingFormats" ? nil : directory))
#endif
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    @Test(arguments: [false, true])
    func nativeUncachedSeekRetainsUserAgentLoginAndProxy(proxyEnabled: Bool) async throws {
        let media = try Data(contentsOf: fixture("tone.wav", directory: "StreamingFormats"))
        let login = FeedCredentials(username: "native-context", password: "captured")
        let proxyAuthorization = "Basic " + Data("proxy:captured".utf8).base64EncodedString()
        let server = try await LoopbackHTTPServer.start { request in
            if proxyEnabled && request.headers["proxy-authorization"] != proxyAuthorization {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"context\""])
            }
            #expect(request.headers["authorization"] == login.authorization(utf8: false))
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                return .init(status: 206, headers: ["ETag": "\"same\"", "Content-Range": "bytes \(offset)-\(media.count - 1)/\(media.count)"], body: Data(media.dropFirst(offset)))
            }
            return .init(headers: ["Content-Type": "audio/wav", "Content-Length": String(media.count), "ETag": "\"same\""],
                body: Data(media.prefix(131072)), keepConnectionOpen: true)
        }
        print("PC_I2_LOOPBACK native proxy=\(proxyEnabled) \(server.url)")
        defer { server.stop(); print("PC_I2_LOOPBACK stopped native \(server.url)") }
        let directory = URL.temporaryDirectory.appendingPathComponent("playback-native-context-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!, username: "proxy", password: "captured") : .init()
        let url = proxyEnabled ? URL(string: "http://native-context.invalid/audio")! : server.url
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: login, cache: cache, userAgent: userAgent)
        defer { remote.input.cancel(); remote.relay.cancel() }
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: login, cache: cache)
        let first = try await source.makeDecoder()
        let replacement = try await source.makeDecoder(start: CMTime(value: 6, timescale: 1), admission: .exactFrame)
        // Seek lands at 6 s (within 250 ms; the tone is 48 kHz).
        #expect(abs(replacement.startFrame - 288000) <= 12_000)
        #expect(try await replacement.next() != nil)
        await first.cancel(); await replacement.cancel()
        let accepted = server.requests.filter { !proxyEnabled || $0.headers["proxy-authorization"] == proxyAuthorization }
        try #require(accepted.count == 2)
        // The uncached seek is a validated range request carrying the same login/proxy/user agent.
        #expect(accepted[0].headers["range"] == nil && accepted[1].headers["range"] != nil)
        #expect(accepted[1].headers["if-range"] == "\"same\"")
        #expect(accepted.allSatisfy { $0.headers["user-agent"] == userAgent })
    }

    @Test(arguments: [false, true])
    func encryptedHLSRequestsKeepUserAgentAcrossForeignPlaylistAndProxy(proxyEnabled: Bool) async throws {
        try await encryptedHLS(proxyEnabled: proxyEnabled, initialStatus: nil)
    }

    @Test(arguments: [false, true])
    func transientHTTPStatusBeforePlaylistIdentificationRecovers(proxyEnabled: Bool) async throws {
        try await encryptedHLS(proxyEnabled: proxyEnabled, initialStatus: 503)
    }

    private func encryptedHLS(proxyEnabled: Bool, initialStatus: Int?) async throws {
        let folder = try fixture("master.m3u8", directory: "StreamingHLSAES").deletingLastPathComponent()
        let files = try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        let login = FeedCredentials(username: "context", password: "captured")
        let proxyAuthorization = "Basic " + Data("proxy:captured".utf8).base64EncodedString()
        let foreign = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == nil)
            return Self.hlsResponse(request, files: files)
        }
        defer { foreign.stop(); print("PC_I2_LOOPBACK stopped foreign \(foreign.url)") }
        let foreignBase = foreign.url.deletingLastPathComponent().absoluteString
        let master = String(decoding: files["master.m3u8"]!, as: UTF8.self)
            .replacingOccurrences(of: "http://cdn.invalid/", with: proxyEnabled ? "http://foreign-context.invalid/" : foreignBase)
        let rejectedInitialRequest = Mutex(false)
        let origin = try await LoopbackHTTPServer.start { request in
            if proxyEnabled && request.headers["proxy-authorization"] != proxyAuthorization {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"hls-context\""])
            }
            let path = URL(string: request.path)!
            let isForeign = path.host == "foreign-context.invalid"
            if isForeign {
                #expect(request.headers["authorization"] == nil)
                return Self.hlsResponse(request, files: files)
            }
            guard request.headers["authorization"] == login.authorization(utf8: false) else {
                return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"hls-context\""])
            }
            if let initialStatus, rejectedInitialRequest.withLock({ rejected in
                if rejected { return false }; rejected = true; return true
            }) { return .init(status: initialStatus) }
            if path.path == "/feed" {
                return .init(status: 302, headers: ["Location": "/master.m3u8"], body: Data())
            }
            return .init(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(master.utf8))
        }
        print("PC_I2_LOOPBACK hls proxy=\(proxyEnabled) origin=\(origin.url) foreign=\(foreign.url)")
        defer { origin.stop(); print("PC_I2_LOOPBACK stopped hls \(origin.url)") }
        let configuration = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: origin.url.port!, username: "proxy", password: "captured") : .init()
        let client = ProxyNetworkEnvironment.Client(configuration: configuration)
        let url = proxyEnabled ? URL(string: "http://origin-context.invalid/feed")! : origin.url
        let engine = AVPlayerPlaybackEngine(muted: true, credentials: { _ in login }, proxyClient: { client }, userAgent: userAgent)
        defer { engine.unload() }
        var failures: [String] = []
        engine.onEvent = { if case .failed(_, let message) = $0 { failures.append(message) } }
        engine.load(episode: .init(id: 1, details: .init(identifier: "context", title: "Request context", media: .init(url: url.absoluteString, size: 0))),
            generation: UUID(), positionMilliseconds: 0)
        engine.play(commandID: UUID())
        try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > 500 || !failures.isEmpty }
        try #require(failures.isEmpty, "\(failures)")
        engine.seek(to: 5000, commandID: UUID())
        try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > 5500 || !failures.isEmpty }
        #expect(failures.isEmpty && (engine.reading?.sample.positionMilliseconds ?? 0) > 5500)
        #expect((engine.nativeRelay != nil) == proxyEnabled)
        #expect(rejectedInitialRequest.withLock { $0 } == (initialStatus != nil))
        let requests = proxyEnabled ? origin.requests.filter { $0.headers["proxy-authorization"] == proxyAuthorization } : origin.requests + foreign.requests
        #expect(requests.allSatisfy { $0.headers["user-agent"] == userAgent })
        for suffix in ["master.m3u8", "key-a.bin", "key-b.bin", "media.bin"] {
            #expect(requests.contains { URL(string: $0.path)?.lastPathComponent == suffix }, "Missing \(suffix)")
        }
        #expect(requests.contains { ["variant.m3u8", "alternate.m3u8"].contains(URL(string: $0.path)?.lastPathComponent ?? "") })
        #expect(requests.contains { $0.path.contains("media.bin") && $0.headers["range"] != nil })
        engine.pause(commandID: UUID())
        #expect(engine.reading?.sample.status == .paused)
    }

    @Test(arguments: [404, 429, 503, 416, 407])
    func unpreparedHTTPFailuresHaveBoundedRetriesAndKeepTypedStatus(status: Int) async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(status: status) }
        print("PC_I2_LOOPBACK status=\(status) \(server.url)")
        defer { server.stop(); print("PC_I2_LOOPBACK stopped status \(server.url)") }
        let failures = Mutex<[Int]>([])
        let source = try ProgressiveHTTPMediaSource(url: server.url, onFailure: { error in
            if case MediaDownloadError.httpStatus(let code) = error { failures.withLock { $0.append(code) } }
        })
        let player = AVPlayer(playerItem: AVPlayerItem(asset: source.asset))
        player.isMuted = true
        defer { player.replaceCurrentItem(with: nil); source.cancel() }
        try await wait { failures.withLock { !$0.isEmpty } }
        #expect(failures.withLock { $0 } == [status])
        #expect(server.requests.count == ([416, 407].contains(status) ? 1 : 4))
        let state = await source.snapshot()
        #expect(!state.completed && state.activeTransfers == 0 && state.pendingRetries == 0)
        #expect(!FileManager.default.fileExists(atPath: source.cacheURL.path))
    }

    @Test(arguments: [false, true])
    func HTTPFailureAfterPreparationPreservesBufferedPlaybackAndRecovery(recovers: Bool) async throws {
#if SWIFT_PACKAGE
        let url = try #require(Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures"))
#else
        let url = try #require(Bundle(for: RequestContextFixtures.self).url(forResource: "playback-30sec", withExtension: "mp3"))
#endif
        let audio = try Data(contentsOf: url)
        let rangeAttempts = Mutex(0)
        let server = try await LoopbackHTTPServer.start { request in
            guard let range = request.headers["range"], let offset = Int(range.dropFirst(6).split(separator: "-")[0]) else {
                return .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": String(audio.count), "ETag": "\"http-recovery\""],
                    body: audio.prefix(audio.count / 2))
            }
            #expect(request.headers["if-range"] == "\"http-recovery\"")
            let count = rangeAttempts.withLock { $0 += 1; return $0 }
            if !recovers || count <= 4 { return .init(status: 503) }
            return .init(status: 206, headers: ["ETag": "\"http-recovery\"", "Content-Range": "bytes \(offset)-\(audio.count - 1)/\(audio.count)"], body: Data(audio.dropFirst(offset)))
        }
        print("PC_I2_LOOPBACK prepared503 \(server.url)")
        defer { server.stop(); print("PC_I2_LOOPBACK stopped prepared503 \(server.url)") }
        let engine = AVPlayerPlaybackEngine(muted: true, userAgent: userAgent)
        defer { engine.unload() }
        var failures: [String] = [], ended = false
        engine.onEvent = {
            if case .failed(_, let message) = $0 { failures.append(message) }
            if case .ended = $0 { ended = true }
        }
        engine.load(episode: .init(id: 1, details: .init(identifier: "http-recovery", title: "HTTP recovery",
            media: .init(url: server.url.absoluteString, size: Int64(audio.count)))), generation: UUID(), positionMilliseconds: 0)
        engine.play(commandID: UUID())
        let source = try #require(engine.httpSource)
        try await wait { rangeAttempts.withLock { $0 } >= 4 || !failures.isEmpty }
        try #require(failures.isEmpty && !ended)
        #expect((engine.reading?.sample.positionMilliseconds ?? 0) > 1000)
        if recovers {
            engine.pause(commandID: UUID())
            let pausedAt = engine.reading?.sample.positionMilliseconds ?? 0
            let deadline = ContinuousClock.now + .seconds(10)
            while !(await source.snapshot().completed), failures.isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await source.snapshot().completed)
            #expect(try Data(contentsOf: source.cacheURL) == audio)
            #expect(failures.isEmpty && !ended && engine.reading?.sample.status == .paused)
            #expect(abs((engine.reading?.sample.positionMilliseconds ?? 0) - pausedAt) < 100)
            #expect(server.requests.allSatisfy { $0.headers["user-agent"] == userAgent })
            engine.seek(to: 17000, commandID: UUID())
            engine.play(commandID: UUID())
            try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > 17500 || !failures.isEmpty }
            #expect(failures.isEmpty && (engine.reading?.sample.positionMilliseconds ?? 0) > 17500)
        } else {
            let deadline = ContinuousClock.now + .seconds(16)
            while failures.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            let position = engine.reading?.sample.positionMilliseconds ?? 0
            #expect(position >= 14000 && position < 16000, "HTTP error at playback position \(position)")
            #expect(failures.count == 1 && !ended && engine.httpSource == nil)
        }
        engine.unload()
        let state = await source.snapshot()
        #expect(state.cancelled && state.activeTransfers == 0 && state.pendingRequests == 0 && state.pendingRetries == 0)
        #expect(!FileManager.default.fileExists(atPath: source.cacheURL.path))
    }

    nonisolated private static func hlsResponse(_ request: LoopbackHTTPServer.Request, files: [String: Data]) -> LoopbackHTTPServer.Response {
        let requested = URL(string: request.path)!.lastPathComponent
        let name = requested == "alternate.m3u8" ? "variant.m3u8" : requested
        guard let data = files[name] else { return .init(status: 404) }
        var headers = ["Content-Type": name.hasSuffix("m3u8") ? "application/vnd.apple.mpegurl" : "application/octet-stream", "Accept-Ranges": "bytes"]
        if let range = request.headers["range"], range.hasPrefix("bytes=") {
            let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, let start = Int(parts[0]), (0..<data.count).contains(start) else { return .init(status: 416) }
            let end = min(Int(parts[1]) ?? data.count - 1, data.count - 1)
            guard end >= start else { return .init(status: 416) }
            headers["Content-Range"] = "bytes \(start)-\(end)/\(data.count)"
            return .init(status: 206, headers: headers, body: Data(data[start...end]))
        }
        return .init(headers: headers, body: data)
    }
}
private final class RequestContextFixtures: NSObject {}
