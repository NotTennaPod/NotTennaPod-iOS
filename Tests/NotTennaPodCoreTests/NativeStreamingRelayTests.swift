import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized) struct NativeStreamingRelayTests {
    private func fixture(_ name: String, extension ext: String, subdirectory: String? = nil) -> URL {
#if SWIFT_PACKAGE
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdirectory.map { "Fixtures/" + $0 } ?? "Fixtures")!
#else
        Bundle(for: NativeRelayFixtures.self).url(forResource: name, withExtension: ext, subdirectory: subdirectory)!
#endif
    }
    private func wait(_ predicate: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate(), sourceLocation: sourceLocation)
    }
    /// Through the app's AVPlayer engine, the route the app uses for these items. A raw
    /// AVPlayer-on-relay variant was removed: it repeated these
    /// proxy and credential assertions one layer down without exercising an app route.
    @Test(arguments: [false, true]) func nativePlaybackUsesProxyForPlaylistAndOpenEndedMedia(playlist: Bool) async throws {
        try await playbackCase(playlist: playlist, speed: 1)
    }
    @Test func selectedNativeProxyPlaylistPlaybackAtOneAndAHalfSpeed() async throws {
        try await playbackCase(playlist: true, speed: 1.5)
    }
    /// An open-ended (live) stream behind an authenticated proxy at 1.5×, through the route the
    /// app selects for it. AVPlayer refuses every rate above 1× for an item of indefinite
    /// duration (rate-change reason SetRateFailed),
    /// so the app plays identified progressive streams through its processed engine instead.
    /// The earlier AVPlayer-only and raw-framework variants of this case asserted a speed the
    /// platform never provides for that item and exercised no route the app uses for it.
    @Test func applicationRoutePlaysOpenEndedProxiedStreamAtOneAndAHalfSpeed() async throws {
        let audio = try Data(contentsOf: fixture("playback-30sec", extension: "mp3"))
        let prefix = audio.prefix(audio.count * 3 / 4)
        let chunked = Data("\(String(prefix.count, radix: 16))\r\n".utf8) + prefix + Data("\r\n".utf8)
        let login = FeedCredentials(username: "media", password: "fixture")
        let proxy = try await LoopbackHTTPServer.start { request in
            guard request.headers["proxy-authorization"] == "Basic " + Data("proxy:fixture".utf8).base64EncodedString() else {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"relay\""])
            }
            guard request.headers["authorization"] == login.authorization(utf8: false) else { return .init(status: 403) }
            return .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"], body: chunked, keepConnectionOpen: true)
        }
        defer { proxy.stop() }
        let configuration = PodcastProxy(kind: .http, host: "127.0.0.1", port: proxy.url.port!, username: "proxy", password: "fixture")
        let root = URL.temporaryDirectory.appendingPathComponent("relay-app-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = ApplicationStreamRoute.engine(cacheDirectory: root, credentials: login, proxy: configuration)
        defer { engine.unload() }
        var failures: [String] = []
        engine.onEvent = { if case .failed(_, let message) = $0 { failures.append(message) } }
        engine.load(episode: .init(id: 1, details: .init(identifier: "open-ended", title: "Open-ended",
            media: .init(url: "http://native-source.invalid/live", size: 0))), generation: UUID(), positionMilliseconds: 0)
        try engine.setSpeed(1.5, commandID: UUID())
        engine.play(commandID: UUID())
        try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > 500 || !failures.isEmpty }
        try #require(failures.isEmpty, "\(failures)")
        #expect(engine.reading?.speed == 1.5 && engine.reading?.sample.status == .playing)
        let speed = try await ApplicationStreamRoute.measuredSpeed(engine)
        #expect(abs(speed - 1.5) <= 1.5 * 0.05, "measured playback speed \(speed)")
        engine.pause(commandID: UUID())
        #expect(engine.reading?.sample.status == .paused)
        #expect(failures.isEmpty, "\(failures)")
        let authenticated = proxy.requests.filter { $0.headers["proxy-authorization"] != nil }
        #expect(!authenticated.isEmpty)
        #expect(authenticated.allSatisfy { $0.path.hasPrefix("http://native-source.invalid/") && $0.headers["authorization"] != nil })
    }
    private func playbackCase(playlist: Bool, speed: Float) async throws {
        let audio = try Data(contentsOf: fixture("playback-30sec", extension: "mp3"))
        let index = fixture("index", extension: "m3u8", subdirectory: "StreamingHLS")
        let hls = try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: index.deletingLastPathComponent(), includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        let prefix = audio.prefix(audio.count * 3 / 4)
        let chunked = Data("\(String(prefix.count, radix: 16))\r\n".utf8) + prefix + Data("\r\n".utf8)
        let login = FeedCredentials(username: "media", password: "fixture")
        let proxy = try await LoopbackHTTPServer.start { request in
            guard request.headers["proxy-authorization"] == "Basic " + Data("proxy:fixture".utf8).base64EncodedString() else {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"relay\""])
            }
            guard request.headers["authorization"] == login.authorization(utf8: false) else { return .init(status: 403) }
            if playlist {
                let component = URL(string: request.path)!.lastPathComponent
                if component == "root" {
                    let index = String(decoding: hls["index.m3u8"]!, as: UTF8.self)
                        .replacingOccurrences(of: "#EXTM3U\n", with: "#EXTM3U\n#EXT-X-DEFINE:QUERYPARAM=\"directory\"\n")
                        .replacingOccurrences(of: "\npart", with: "\n{$directory}/part")
                    return .init(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(index.utf8))
                }
                if let data = hls[component] { return .init(headers: ["Content-Type": "video/mp2t"], body: data) }
                return .init(status: 404)
            }
            return .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"], body: chunked, keepConnectionOpen: true)
        }
        defer { proxy.stop() }
        let configuration = PodcastProxy(kind: .http, host: "127.0.0.1", port: proxy.url.port!, username: "proxy", password: "fixture")
        let source = URL(string: "http://native-source.invalid/root?directory=segments")!
        let client = ProxyNetworkEnvironment.Client(configuration: configuration)
        let engine = AVPlayerPlaybackEngine(muted: true, credentials: { _ in login }, proxyClient: { client })
        defer { engine.unload() }
        var failures: [String] = []
        engine.onEvent = { if case .failed(_, let message) = $0 { failures.append(message) } }
        engine.load(episode: .init(id: 1, details: .init(identifier: "native-relay", title: "Native relay", media: .init(url: source.absoluteString, size: 0))), generation: UUID(), positionMilliseconds: 0)
        try engine.setSpeed(speed, commandID: UUID())
        engine.play(commandID: UUID())
        do {
            try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > 500 || !failures.isEmpty }
        } catch {
            print("Selected playback timeout: \(Self.diagnostics(engine.nativePlayer)) reading=\(String(describing: engine.reading))")
            throw error
        }
        #expect(failures.isEmpty, "\(failures)")
        #expect((engine.reading?.sample.positionMilliseconds ?? 0) > 500)
        engine.pause(commandID: UUID())
        #expect(engine.reading?.sample.status == .paused)
        let authenticated = proxy.requests.filter { $0.headers["proxy-authorization"] != nil }
        #expect(authenticated.allSatisfy { $0.path.hasPrefix("http://native-source.invalid/") && $0.headers["authorization"] != nil })
        if playlist { #expect(authenticated.contains { $0.path.hasSuffix(".ts") }) }
    }
    private static func diagnostics(_ player: AVPlayer?) -> String {
        guard let player, let item = player.currentItem else { return "no current item" }
        return "time=\(player.currentTime().seconds) rate=\(player.rate) defaultRate=\(player.defaultRate) " +
            "control=\(player.timeControlStatus.rawValue) reason=\(String(describing: player.reasonForWaitingToPlay)) " +
            "status=\(item.status.rawValue) duration=\(item.duration.seconds) fast=\(item.canPlayFastForward) " +
            "slow=\(item.canPlaySlowForward) ranges=\(item.loadedTimeRanges) seekable=\(item.seekableTimeRanges) " +
            "error=\(String(describing: item.error))"
    }
    @Test func playlistRedirectResolvesRelativeResourcesAtFinalURLAndStripsForeignLogin() async throws {
        let login = FeedCredentials(username: "private", password: "fixture")
        let proxy = try await LoopbackHTTPServer.start { request in
            if request.path == "http://original.invalid/start" {
                #expect(request.headers["authorization"] != nil)
                return .init(status: 302, headers: ["Location": "http://foreign.invalid/path/index.m3u8"])
            }
            #expect(request.headers["authorization"] == nil)
            if request.path.hasSuffix("index.m3u8") { return .init(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data("#EXTM3U\n#EXTINF:2,\npart.ts\n#EXT-X-ENDLIST\n".utf8)) }
            return .init(body: Data("foreign-media".utf8))
        }
        defer { proxy.stop() }
        let relay = try await NativeStreamingRelay.start(url: URL(string: "http://original.invalid/start")!, playlist: true,
            proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!), credentials: login)
        defer { relay.cancel() }
        let (data, _) = try await URLSession.shared.data(from: relay.url)
        let address = try #require(String(decoding: data, as: UTF8.self).components(separatedBy: "\n").first { $0.hasPrefix("http") })
        let (media, _) = try await URLSession.shared.data(from: URL(string: address)!)
        #expect(media == Data("foreign-media".utf8))
        #expect(proxy.requests.last?.path == "http://foreign.invalid/path/part.ts")
    }
    @Test func cancellationClosesListenerAndPendingUpstreamRequest() async throws {
        let proxy = try await LoopbackHTTPServer.start { _ in nil }
        defer { proxy.stop() }
        let relay = try await NativeStreamingRelay.start(url: URL(string: "http://held.invalid/audio")!, playlist: false,
            proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!))
        let pending = Task { try await URLSession.shared.data(from: relay.url) }
        try await wait { !proxy.requests.isEmpty }
        relay.cancel()
        await #expect(throws: (any Error).self) { _ = try await pending.value }
        await #expect(throws: (any Error).self) { _ = try await URLSession.shared.data(from: relay.url) }
    }
    @Test(arguments: [404, 416, 503]) func upstreamHTTPFailureRemainsRequestScopedAndPreservesResponse(status: Int) async throws {
        let failures = Mutex<[String]>([]), count = Mutex(0)
        let proxy = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["range"] == "bytes=256-511")
            #expect(request.headers["if-range"] == "\"episode-v1\"")
            let first = count.withLock { $0 += 1; return $0 == 1 }
            if first {
                var headers = ["Content-Type": "text/plain"]
                if status == 416 { headers["Content-Range"] = "bytes */128" }
                if status == 503 { headers["Retry-After"] = "2" }
                return .init(status: status, headers: headers, body: Data("upstream response".utf8))
            }
            return .init(status: 206, headers: ["Content-Range": "bytes 256-511/1024", "ETag": "\"episode-v1\""],
                         body: Data(repeating: 42, count: 256))
        }
        defer { proxy.stop() }
        let relay = try await NativeStreamingRelay.start(url: URL(string: "http://retry.invalid/segment")!, playlist: false,
            proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!),
            onFailure: { error in failures.withLock { $0.append(error.localizedDescription) } })
        defer { relay.cancel() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: relay.url)
        request.setValue("bytes=256-511", forHTTPHeaderField: "Range")
        request.setValue("\"episode-v1\"", forHTTPHeaderField: "If-Range")
        let (body, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == status && body == Data("upstream response".utf8))
        #expect(http.value(forHTTPHeaderField: "Content-Range") == (status == 416 ? "bytes */128" : nil))
        #expect(http.value(forHTTPHeaderField: "Retry-After") == (status == 503 ? "2" : nil))
        let (retry, retriedResponse) = try await session.data(for: request)
        let retried = try #require(retriedResponse as? HTTPURLResponse)
        #expect(retried.statusCode == 206 && retry == Data(repeating: 42, count: 256))
        #expect(retried.value(forHTTPHeaderField: "Content-Range") == "bytes 256-511/1024")
        #expect(retried.value(forHTTPHeaderField: "ETag") == "\"episode-v1\"")
        #expect(failures.withLock { $0.isEmpty })
        #expect(proxy.requests.count == 2)
    }
    @Test(arguments: [false, true]) func retiredNativeRequestCancelsUpstreamWithoutFailingPlayback(beforeHeaders: Bool) async throws {
        let requests = Mutex(0), failures = Mutex<[String]>([])
        let proxy = try await LoopbackHTTPServer.start { _ in
            let number = requests.withLock { $0 += 1; return $0 }
            if number > 1 { return .init(body: Data("replacement".utf8)) }
            if beforeHeaders { return nil }
            let prefix = Data(repeating: 65, count: 128 * 1024)
            return .init(headers: ["Transfer-Encoding": "chunked"],
                body: Data("\(String(prefix.count, radix: 16))\r\n".utf8) + prefix + Data("\r\n".utf8), keepConnectionOpen: true)
        }
        defer { proxy.stop() }
        let relay = try await NativeStreamingRelay.start(url: URL(string: "http://held.invalid/audio")!, playlist: false,
            proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!),
            onFailure: { error in failures.withLock { $0.append(error.localizedDescription) } })
        defer { relay.cancel() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let pending = Task { try await session.data(from: relay.url) }
        try await wait { requests.withLock { $0 == 1 } }
        pending.cancel()
        await #expect(throws: (any Error).self) { _ = try await pending.value }
        let (replacement, _) = try await session.data(from: relay.url)
        #expect(replacement == Data("replacement".utf8))
        #expect(failures.withLock { $0.isEmpty })
    }
    @Test func playlistVariablesAbsoluteAndAttributeReferencesKeepNativeTags() throws {
        let source = """
        #EXTM3U
        #EXT-X-DEFINE:NAME="folder",VALUE="audio"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Spoken, stereo",URI="{$folder}/alt.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=100000,AUDIO="audio"
        https://cdn.invalid/main.m3u8
        #EXT-X-KEY:METHOD=AES-128,URI="../key"
        #EXT-X-MAP:URI="init.mp4",BYTERANGE="128@0"
        """
        var addresses: [(String, Bool)] = []
        let result = try HLSRelayPlaylist.rewrite(Data(source.utf8), base: URL(string: "https://podcast.invalid/path/master.m3u8")!) { url, playlist, variables in
            addresses.append((url.absoluteString, playlist)); #expect(variables["folder"] == "audio")
            return URL(string: "http://127.0.0.1:9000/resource/\(addresses.count)")!
        }
        #expect(addresses.map(\.0) == ["https://podcast.invalid/path/audio/alt.m3u8", "https://cdn.invalid/main.m3u8", "https://podcast.invalid/key", "https://podcast.invalid/path/init.mp4"])
        #expect(addresses.map(\.1) == [true,true,false,false])
        #expect(String(decoding: result, as: UTF8.self).contains("NAME=\"Spoken, stereo\""))
        #expect(String(decoding: result, as: UTF8.self).contains("BYTERANGE=\"128@0\""))
    }
    @Test func livePlaylistRoutesStayStableAndOldSegmentsRemainAvailable() async throws {
        let sequence = Mutex(0)
        let proxy = try await LoopbackHTTPServer.start { request in
            let url = URL(string: request.path)!
            if url.path == "/index.m3u8" {
                let start = sequence.withLock { let value = $0; $0 += 1024; return value }
                let body = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:\(start)\n" +
                    (start..<(start + 1024)).map { "#EXTINF:2,\nsegment\($0).ts\n" }.joined()
                return .init(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(body.utf8))
            }
            return .init(body: Data(url.path.utf8))
        }
        defer { proxy.stop() }
        let relay = try await NativeStreamingRelay.start(url: URL(string: "http://live.invalid/index.m3u8")!, playlist: true,
            proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!))
        defer { relay.cancel() }
        let (first, _) = try await URLSession.shared.data(from: relay.url)
        let original = try #require(String(decoding: first, as: UTF8.self).components(separatedBy: "\n").first { $0.hasPrefix("http") })
        _ = try await URLSession.shared.data(from: relay.url)
        let (oldSegment, _) = try await URLSession.shared.data(from: URL(string: original)!)
        #expect(oldSegment == Data("/segment0.ts".utf8))
        sequence.withLock { $0 = 0 }
        let (repeated, _) = try await URLSession.shared.data(from: relay.url)
        #expect(repeated == first)
        var blockingReload = URLComponents(url: relay.url, resolvingAgainstBaseURL: false)!
        blockingReload.queryItems = [.init(name: "_HLS_msn", value: "2048"), .init(name: "_HLS_part", value: "3")]
        _ = try await URLSession.shared.data(from: blockingReload.url!)
        #expect(proxy.requests.last?.path == "http://live.invalid/index.m3u8?_HLS_msn=2048&_HLS_part=3")
    }
    @Test func changedOrForeignPlaybackRoutesCannotRequestUpstreamMedia() async throws {
        let failures = Mutex<[String]>([])
        let proxy = try await LoopbackHTTPServer.start { _ in .init(body: Data("authorized".utf8)) }
        defer { proxy.stop() }
        let relay = try await NativeStreamingRelay.start(url: URL(string: "http://private.invalid/audio")!, playlist: false,
            proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!),
            onFailure: { error in failures.withLock { $0.append(error.localizedDescription) } })
        defer { relay.cancel() }
        var changed = relay.url.deletingLastPathComponent()
        let foreignRoute = try NativeRelayRoute().encode(.init(url: URL(string: "http://other.invalid/audio")!, playlist: false, variables: [:]))
        changed.appendPathComponent(foreignRoute)
        await #expect(throws: (any Error).self) { _ = try await URLSession.shared.data(from: changed) }
        let pieces = relay.url.lastPathComponent.split(separator: ".")
        let forged = Data(#"{"url":"http://other.invalid/audio","playlist":false,"variables":{}}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
        changed = relay.url.deletingLastPathComponent().appendingPathComponent(forged + "." + pieces[1] + ".media")
        await #expect(throws: (any Error).self) { _ = try await URLSession.shared.data(from: changed) }
        #expect(proxy.requests.isEmpty)
        let (allowed, _) = try await URLSession.shared.data(from: relay.url)
        #expect(allowed == Data("authorized".utf8))
        #expect(failures.withLock { $0.isEmpty })
    }
    @Test func encryptedMultivariantHLSUsesProxyForRotatingKeysRangesAndSeek() async throws {
        let folder = fixture("master", extension: "m3u8", subdirectory: "StreamingHLSAES").deletingLastPathComponent()
        let contents = try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        let login = FeedCredentials(username: "publisher", password: "fixture")
        let proxy = try await LoopbackHTTPServer.start { request in
            guard request.headers["proxy-authorization"] == "Basic " + Data("proxy:fixture".utf8).base64EncodedString() else {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"encrypted-HLS\""])
            }
            let url = URL(string: request.path)!
            #expect(request.headers["authorization"] == (url.host == "master.invalid" ? login.authorization(utf8: false) : nil))
            let name = url.lastPathComponent == "alternate.m3u8" ? "variant.m3u8" : url.lastPathComponent
            guard let data = contents[name] else { return .init(status: 404) }
            var headers = ["Content-Type": name.hasSuffix("m3u8") ? "application/vnd.apple.mpegurl" : "application/octet-stream", "Accept-Ranges": "bytes"]
            if let range = request.headers["range"], range.hasPrefix("bytes=") {
                let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                guard parts.count == 2, let start = Int(parts[0]), start >= 0, start < data.count else { return .init(status: 416) }
                let end = min(Int(parts[1]) ?? (data.count - 1), data.count - 1)
                guard end >= start else { return .init(status: 416) }
                headers["Content-Range"] = "bytes \(start)-\(end)/\(data.count)"
                return .init(status: 206, headers: headers, body: data.subdata(in: start..<(end + 1)))
            }
            return .init(headers: headers, body: data)
        }
        defer { proxy.stop() }
        let client = ProxyNetworkEnvironment.Client(configuration: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!, username: "proxy", password: "fixture"))
        let engine = AVPlayerPlaybackEngine(muted: true, credentials: { _ in login }, proxyClient: { client })
        defer { engine.unload() }
        var failures: [String] = []
        engine.onEvent = { if case .failed(_, let message) = $0 { failures.append(message) } }
        engine.load(episode: .init(id: 1, details: .init(identifier: "encrypted-HLS", title: "Encrypted HLS", media: .init(url: "http://master.invalid/master.m3u8", size: 0))), generation: UUID(), positionMilliseconds: 0)
        engine.play(commandID: UUID())
        try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > 500 || !failures.isEmpty }
        try #require(failures.isEmpty, "\(failures)")
        engine.seek(to: 5000, commandID: UUID())
        try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > 5500 || !failures.isEmpty }
        #expect(failures.isEmpty, "\(failures)")
        #expect((engine.reading?.sample.positionMilliseconds ?? 0) > 5500)
        let delivered = proxy.requests.filter { $0.headers["proxy-authorization"] != nil }
        #expect(delivered.contains { $0.path.hasSuffix("/assets/key-a.bin") })
        #expect(delivered.contains { $0.path.hasSuffix("/assets/key-b.bin") })
        #expect(delivered.contains { $0.path.hasSuffix("/assets/media.bin") && $0.headers["range"] != nil })
        engine.pause(commandID: UUID())
        #expect(engine.reading?.sample.status == .paused)
    }
}
#if !SWIFT_PACKAGE
private final class NativeRelayFixtures: NSObject {}
#endif

/// The application's playback selection with only the audio-session driver injected: remote
/// progressive media that the app identifies (MP3, AAC, FLAC, Ogg, …), including open-ended
/// live streams, plays through the processed engine; playlists use AVPlayer.
@MainActor enum ApplicationStreamRoute {
    static func engine(cacheDirectory: URL, credentials: FeedCredentials?,
                       proxy: PodcastProxy = PodcastProxy()) -> ApplicationPlaybackEngine {
        let factories = PCMPlaybackFactory(cacheDirectory: cacheDirectory,
            makeTransport: { NativeSampleBufferTransport(muted: true) })
        let client = ProxyNetworkEnvironment.Client(configuration: proxy)
        let engine = ApplicationPlaybackEngine(muted: true, source: AVPlayerPlaybackEngine.mediaURL, localAccess: nil,
            credentials: { _ in credentials }, proxyClient: { client }, userAgent: "AntennaPod/test", factories: factories,
            makePCMEngine: { factory, url in
                PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), resolveFactory: { _, _ in factory }, source: { _ in url })
            })
        // The app's PlaybackCoordinator always binds listening statistics.
        engine.bindStatistics(lastPlayed: { _ in 0 }, synchronize: { _ in })
        return engine
    }

    /// Media seconds heard per wall-clock second over `window`, measured while audio is heard.
    static func measuredSpeed(_ engine: ApplicationPlaybackEngine, window: Duration = .seconds(2)) async throws -> Double {
        let start = ContinuousClock.now
        let first = try #require(engine.reading?.sample.positionMilliseconds)
        try await Task.sleep(for: window)
        let last = try #require(engine.reading?.sample.positionMilliseconds)
        let wall = ContinuousClock.now - start
        let seconds = Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18
        return Double(last - first) / 1000 / seconds
    }
}
