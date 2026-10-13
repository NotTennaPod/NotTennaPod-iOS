import AVFoundation
import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct AuthenticatedPlaybackTests {
    private let login = FeedCredentials(username: "private-listener", password: "fixture-secret")
    private var media: URL { fixture("playback-30sec", extension: "mp3") }
    private func fixture(_ name: String, extension ext: String, subdirectory: String? = nil) -> URL {
#if SWIFT_PACKAGE
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdirectory.map { "Fixtures/" + $0 } ?? "Fixtures")!
#else
        Bundle(for: AuthenticatedPlaybackFixtures.self).url(forResource: name, withExtension: ext, subdirectory: subdirectory)!
#endif
    }
    private func episode(_ url: URL, id: Int64 = 1) -> LibraryEpisode {
        .init(id: id, details: .init(identifier: "\(id)", title: "Private episode", media: .init(url: url.absoluteString, size: 0)))
    }
    private func wait(_ predicate: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await predicate(), sourceLocation: sourceLocation)
    }

    // AVPlayer cannot play an item of indefinite duration above 1× (SetRateFailed), and the app does not
    // select it for identified open-ended streams: that case at 1.5× is verified through the app's route below.
    @Test(arguments: [("progressive", Float(1)), ("progressive", 1.5), ("openEnded", 1), ("playlist", 1), ("playlist", 1.5)])
    func privateMediaPlaysThroughEachSelectedSource(mode: String, speed: Float) async throws {
        let data = try Data(contentsOf: media), login = login
        let index = fixture("index", extension: "m3u8", subdirectory: "StreamingHLS")
        let files = try FileManager.default.contentsOfDirectory(at: index.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        let hls = try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        let prefix = data.prefix(data.count * 3 / 4)
        let chunked = Data("\(String(prefix.count, radix: 16))\r\n".utf8) + prefix + Data("\r\n".utf8)
        let server = try await LoopbackHTTPServer.start { request in
            guard request.headers["authorization"] == login.authorization(utf8: false) else {
                return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"private-playback\""], body: Data())
            }
            if mode == "playlist" {
                let key = String(request.path.split(separator: "?")[0].split(separator: "/").last ?? "")
                if key == "feed" { return .init(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: hls["index.m3u8"]!) }
                if let segment = hls[key] { return .init(headers: ["Content-Type": "video/mp2t"], body: segment) }
                return .init(status: 404)
            }
            if mode == "openEnded" {
                return .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"], body: chunked, keepConnectionOpen: true)
            }
            return .init(headers: ["Content-Type": "audio/mpeg"], body: data)
        }
        defer { server.stop() }
        let engine = AVPlayerPlaybackEngine(muted: true, credentials: { _ in login })
        var failures: [String] = [], ready = 0
        engine.onEvent = {
            if case .failed(_, let message) = $0 { failures.append(message) }
            if case .ready = $0 { ready += 1 }
        }
        defer { engine.unload() }
        let generation = UUID()
        engine.load(episode: episode(server.url), generation: generation, positionMilliseconds: 0)
        try engine.setSpeed(speed, commandID: UUID())
        engine.play(commandID: UUID())
        do {
            try await wait { ready > 0 || !failures.isEmpty }
            try #require(failures.isEmpty, "\(failures)")
            try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > 500 || !failures.isEmpty }
        } catch {
            print("Authenticated stream \(mode): ready=\(ready), failures=\(failures), reading=\(String(describing: engine.reading)), native=\(String(describing: engine.nativePlayer?.currentItem?.status)), rate=\(String(describing: engine.nativePlayer?.rate)), requests=\(server.requests.map { ($0.path, $0.headers["authorization"] != nil) })")
            throw error
        }
        #expect(failures.isEmpty && ready == 1)
        #expect(engine.reading?.generation == generation && engine.reading?.speed == speed)
        engine.pause(commandID: UUID())
        #expect(engine.reading?.sample.status == .paused && engine.nativePlayer?.rate == 0)
        let authorized = server.requests.filter { $0.headers["authorization"] != nil }
        #expect(!authorized.isEmpty && authorized.allSatisfy { $0.headers["authorization"] == login.authorization(utf8: false) })
        if mode == "playlist" { #expect(authorized.contains { $0.path.hasSuffix(".ts") }) }
    }

    /// A private open-ended (live) stream at 1.5× through the route the app selects for it:
    /// it starts before the download ends, keeps the real speed, and pause/resume continue
    /// from where it stopped, with the saved login sent on every request.
    @Test func privateOpenEndedStreamPlaysAtOneAndAHalfSpeedThroughApplicationRoute() async throws {
        let data = try Data(contentsOf: media), login = login
        let prefix = data.prefix(data.count * 3 / 4)
        let chunked = Data("\(String(prefix.count, radix: 16))\r\n".utf8) + prefix + Data("\r\n".utf8)
        let server = try await LoopbackHTTPServer.start { request in
            guard request.headers["authorization"] == login.authorization(utf8: false) else {
                return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"private-playback\""], body: Data())
            }
            return .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"], body: chunked, keepConnectionOpen: true)
        }
        defer { server.stop() }
        let root = URL.temporaryDirectory.appendingPathComponent("private-live-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = ApplicationStreamRoute.engine(cacheDirectory: root, credentials: login)
        defer { engine.unload() }
        var failures: [String] = [], ready = 0
        engine.onEvent = {
            if case .failed(_, let message) = $0 { failures.append(message) }
            if case .ready = $0 { ready += 1 }
        }
        let generation = UUID()
        engine.load(episode: episode(server.url), generation: generation, positionMilliseconds: 0)
        try engine.setSpeed(1.5, commandID: UUID())
        engine.play(commandID: UUID())
        try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > 500 || !failures.isEmpty }
        try #require(failures.isEmpty, "\(failures)")
        #expect(ready == 1 && engine.reading?.generation == generation && engine.reading?.speed == 1.5)
        let speed = try await ApplicationStreamRoute.measuredSpeed(engine)
        #expect(abs(speed - 1.5) <= 1.5 * 0.05, "measured playback speed \(speed)")
        engine.pause(commandID: UUID())
        #expect(engine.reading?.sample.status == .paused)
        let stopped = try #require(engine.reading?.sample.positionMilliseconds)
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs((engine.reading?.sample.positionMilliseconds ?? 0) - stopped) <= 100)
        engine.play(commandID: UUID())
        try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) >= stopped + 1000 || !failures.isEmpty }
        #expect(failures.isEmpty, "\(failures)")
        let resumed = try #require(engine.reading?.sample.positionMilliseconds)
        #expect(resumed >= stopped + 1000 && resumed < stopped + 5000)
        let authorized = server.requests.filter { $0.headers["authorization"] != nil }
        #expect(!authorized.isEmpty && authorized.allSatisfy { $0.headers["authorization"] == login.authorization(utf8: false) })
    }

    @Test func cancelledCredentialLookupCannotReplaceTheNextLoadOrLosePendingCommands() async throws {
        let gate = PlaybackCredentialGate(), login = login
        let data = try Data(contentsOf: media)
        let server = try await LoopbackHTTPServer.start { request in
            guard request.headers["authorization"] == login.authorization(utf8: false) else { return .init(status: 401, body: Data()) }
            return .init(headers: ["Content-Type": "audio/mpeg"], body: data)
        }
        defer { server.stop() }
        let engine = AVPlayerPlaybackEngine(muted: true, credentials: { await gate.read($0.id) })
        var ready: [PlaybackEngineReading] = [], failures = 0
        engine.onEvent = { if case .ready(let reading) = $0 { ready.append(reading) }; if case .failed = $0 { failures += 1 } }
        defer { engine.unload() }
        engine.load(episode: episode(server.url, id: 1), generation: UUID(), positionMilliseconds: 0)
        try await wait { await gate.pending.contains(1) }
        #expect(server.requests.isEmpty && engine.nativePlayer == nil)
        let generation = UUID(), latestCommand = UUID()
        engine.load(episode: episode(server.url, id: 2), generation: generation, positionMilliseconds: 0)
        try await wait { await gate.pending.contains(2) }
        try engine.setSpeed(2, commandID: UUID())
        engine.play(commandID: UUID()); engine.pause(commandID: UUID())
        engine.seek(to: 3883, commandID: latestCommand)
        await gate.finish(1, login)
        await gate.finish(2, login)
        try await wait { !ready.isEmpty || failures > 0 }
        let reading = try #require(ready.first)
        #expect(ready.count == 1 && failures == 0 && reading.generation == generation)
        // The newer episode opens with the latest speed, pause and seek.
        #expect(reading.speed == 2 && reading.sample.status == .paused)
        #expect(abs(reading.sample.positionMilliseconds - 3883) <= 250)
        #expect(server.requests.count == 1)
    }

    @Test func credentialsAreNotSentToAnotherRedirectOrigin() async throws {
        let login = login
        let other = try await LoopbackHTTPServer.start { _ in
            .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"private-playback\""], body: Data())
        }
        defer { other.stop() }
        var destination = URLComponents(url: other.url, resolvingAgainstBaseURL: false)!
        destination.user = "redirect-fixture"; destination.password = "untrusted"
        let redirectedURL = destination.string!
        let origin = try await LoopbackHTTPServer.start { _ in .init(status: 302, headers: ["Location": redirectedURL], body: Data()) }
        defer { origin.stop() }
        let engine = AVPlayerPlaybackEngine(muted: true, credentials: { _ in login })
        var failed = false
        engine.onEvent = { if case .failed = $0 { failed = true } }
        defer { engine.unload() }
        engine.load(episode: episode(origin.url), generation: UUID(), positionMilliseconds: 0)
        try await wait { failed }
        #expect(origin.requests.first?.headers["authorization"] == login.authorization(utf8: false))
        #expect(!other.requests.isEmpty && other.requests.allSatisfy { $0.headers["authorization"] == nil })
    }

    @Test func sameOriginRedirectAndUncachedRangeKeepTheMediaLogin() async throws {
        let data = try Data(contentsOf: media)
        let prefix = data.prefix(data.count / 4), login = login
        let server = try await LoopbackHTTPServer.start { request in
            guard request.headers["authorization"] == login.authorization(utf8: false) else { return .init(status: 401, body: Data()) }
            if request.path == "/feed" { return .init(status: 302, headers: ["Location": "/private-audio"], body: Data()) }
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "ETag": "\"private-v1\"",
                    "Content-Range": "bytes \(offset)-\(data.count - 1)/\(data.count)"], body: data.dropFirst(offset))
            }
            return .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(data.count)", "ETag": "\"private-v1\""],
                         body: prefix, keepConnectionOpen: true)
        }
        defer { server.stop() }
        let engine = AVPlayerPlaybackEngine(muted: true, credentials: { _ in login })
        var failures = 0
        engine.onEvent = { if case .failed = $0 { failures += 1 } }
        defer { engine.unload() }
        engine.load(episode: episode(server.url), generation: UUID(), positionMilliseconds: 0)
        engine.play(commandID: UUID())
        try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > 300 || failures > 0 }
        try #require(failures == 0)
        engine.seek(to: 25_000, commandID: UUID())
        try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > 25_300 || failures > 0 }
        #expect(failures == 0)
        let requests = server.requests
        #expect(requests.allSatisfy { $0.headers["authorization"] == login.authorization(utf8: false) })
        #expect(requests.contains { $0.path == "/private-audio" && $0.headers["range"] != nil && $0.headers["if-range"] == "\"private-v1\"" })
    }

    @Test func nativePlaylistCannotAuthenticateASegmentOnAnotherOrigin() async throws {
        let login = login
        let other = try await LoopbackHTTPServer.start { _ in
            .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"private-playback\""], body: Data())
        }
        defer { other.stop() }
        let playlist = Data("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:2.005333,\n\(other.url.absoluteString)\n#EXT-X-ENDLIST\n".utf8)
        let origin = try await LoopbackHTTPServer.start { request in
            guard request.headers["authorization"] == login.authorization(utf8: false) else {
                return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"private-playback\""], body: Data())
            }
            return .init(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: playlist)
        }
        defer { origin.stop() }
        let engine = AVPlayerPlaybackEngine(muted: true, credentials: { _ in login })
        var failed = false
        engine.onEvent = { if case .failed = $0 { failed = true } }
        defer { engine.unload() }
        engine.load(episode: episode(origin.url), generation: UUID(), positionMilliseconds: 0)
        engine.play(commandID: UUID())
        do {
            try await wait { !other.requests.isEmpty }
            try await wait { failed }
        } catch {
            print("Foreign HLS segment: origin=\(origin.requests.map { ($0.path, $0.headers["authorization"] != nil) }), other=\(other.requests.map { ($0.path, $0.headers["authorization"] != nil) }), failed=\(failed), item=\(String(describing: engine.nativePlayer?.currentItem?.status.rawValue))")
            throw error
        }
        #expect(other.requests.allSatisfy { $0.headers["authorization"] == nil })
    }
}

private actor PlaybackCredentialGate {
    private var continuations: [Int64: CheckedContinuation<FeedCredentials?, Never>] = [:]
    var pending: Set<Int64> { Set(continuations.keys) }
    func read(_ id: Int64) async -> FeedCredentials? {
        await withCheckedContinuation { continuations[id] = $0 }
    }
    func finish(_ id: Int64, _ value: FeedCredentials?) { continuations.removeValue(forKey: id)?.resume(returning: value) }
}

#if !SWIFT_PACKAGE
private final class AuthenticatedPlaybackFixtures: NSObject {}
#endif
