import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct ProgressiveStreamingRecoveryTests {
    private var fixture: URL {
#if SWIFT_PACKAGE
        Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures")!
#else
        Bundle(for: StreamingRecoveryFixtures.self).url(forResource: "playback-30sec", withExtension: "mp3")!
#endif
    }
    @Test(arguments: [false, true]) func bufferedPlaybackRecoversAfterTimedOutTransfer(proxyConfigured: Bool) async throws {
        let audio = try Data(contentsOf: fixture)
        let prefix = audio.prefix(audio.count / 2)
        let start = Mutex<ContinuousClock.Instant?>(nil)
        let resumed = Mutex<[Int]>([])
        let server = try await LoopbackHTTPServer.start { request in
            let elapsed = start.withLock { value in
                if value == nil { value = .now; return Duration.zero }
                return value!.duration(to: .now)
            }
            if elapsed == .zero {
                return .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(audio.count)", "ETag": "\"recovery\""],
                             body: prefix, keepConnectionOpen: true)
            }
            // A decoder may probe another range before the initial request times out.
            // Such a probe must not make this recovery test pass without the timeout.
            guard elapsed >= .milliseconds(7500),
                  let range = request.headers["range"], range.hasPrefix("bytes="),
                  let offset = Int(range.dropFirst(6).split(separator: "-")[0]),
                  offset >= prefix.count, offset < audio.count else { return nil }
            #expect(request.headers["if-range"] == "\"recovery\"")
            resumed.withLock { $0.append(offset) }
            return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "Content-Range": "bytes \(offset)-\(audio.count - 1)/\(audio.count)",
                                               "ETag": "\"recovery\""], body: audio[offset...])
        }
        defer { server.stop() }
        let client = ProxyNetworkEnvironment.Client(configuration: .init(kind: .http, host: "127.0.0.1", port: server.url.port!))
        let engine: AVPlayerPlaybackEngine
        if proxyConfigured { engine = AVPlayerPlaybackEngine(muted: true, proxyClient: { client }) }
        else { engine = AVPlayerPlaybackEngine(muted: true) }
        defer { engine.unload() }
        var failures: [String] = []
        engine.onEvent = { if case .failed(_, let message) = $0 { failures.append(message) } }
        let url = proxyConfigured ? "http://recovery.invalid/media.mp3" : server.url.absoluteString
        engine.load(episode: .init(id: 1, details: .init(identifier: "recovery", title: "Recovery", media: .init(url: url, size: Int64(audio.count)))),
                    generation: UUID(), positionMilliseconds: 0)
        engine.play(commandID: UUID())
        let deadline = ContinuousClock.now + .seconds(18)
        while (engine.reading?.sample.positionMilliseconds ?? 0) < 11000, failures.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(failures.isEmpty, "\(failures)")
        #expect((engine.reading?.sample.positionMilliseconds ?? 0) >= 11000)
        #expect(resumed.withLock { !$0.isEmpty })
        let source = try #require(engine.httpSource)
        let state = await source.snapshot()
        #expect(state.completed && state.failure == nil && state.received == Int64(audio.count))
        #expect(try Data(contentsOf: source.cacheURL) == audio)
        engine.pause(commandID: UUID())
        #expect(engine.reading?.sample.status == .paused)
    }

    @Test(arguments: [false, true]) func exhaustedRetriesKeepBufferedAudioUntilItIsConsumed(proxyConfigured: Bool) async throws {
        let audio = try Data(contentsOf: fixture)
        let prefix = audio.prefix(audio.count / 2)
        let server = try await LoopbackHTTPServer.start { request in
            let offset = request.headers["range"].flatMap { Int($0.dropFirst(6).split(separator: "-")[0]) } ?? 0
            if offset == 0 {
                return .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(audio.count)", "ETag": "\"exhaustion\""], body: prefix)
            }
            return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(audio.count - offset)",
                "Content-Range": "bytes \(offset)-\(audio.count - 1)/\(audio.count)", "ETag": "\"exhaustion\""], body: Data())
        }
        defer { server.stop() }
        let client = ProxyNetworkEnvironment.Client(configuration: .init(kind: .http, host: "127.0.0.1", port: server.url.port!))
        let engine: AVPlayerPlaybackEngine
        if proxyConfigured { engine = AVPlayerPlaybackEngine(muted: true, proxyClient: { client }) }
        else { engine = AVPlayerPlaybackEngine(muted: true) }
        defer { engine.unload() }
        var failures = 0
        var ended = false
        engine.onEvent = { event in
            if case .failed = event { failures += 1 }
            if case .ended = event { ended = true }
        }
        let url = proxyConfigured ? "http://exhaustion.invalid/media.mp3" : server.url.absoluteString
        engine.load(episode: .init(id: 1, details: .init(identifier: "buffered-exhaustion", title: "Buffered exhaustion",
                    media: .init(url: url, size: Int64(audio.count)))), generation: UUID(), positionMilliseconds: 0)
        engine.play(commandID: UUID())
        let source = try #require(engine.httpSource)
        let deadline = ContinuousClock.now + .seconds(22)
        var playedBeyondThreshold = false
        while failures == 0, ContinuousClock.now < deadline {
            if server.requests.count >= 4, (engine.reading?.sample.positionMilliseconds ?? 0) >= 7000 {
                playedBeyondThreshold = true
                #expect(FileManager.default.fileExists(atPath: source.cacheURL.path))
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let position = engine.reading?.sample.positionMilliseconds ?? 0
        #expect(playedBeyondThreshold)
        #expect(position >= 14000 && position < 16000, "Error at playback position \(position)")
        #expect(failures == 1 && !ended && engine.httpSource == nil)
        let state = await source.snapshot()
        #expect(state.cancelled && state.activeTransfers == 0 && state.pendingRetries == 0)
        #expect(!FileManager.default.fileExists(atPath: source.cacheURL.path))
    }

    @Test func recoveryAfterRetryThresholdClearsDeferredFailureAndPreservesPause() async throws {
        let audio = try Data(contentsOf: fixture)
        let prefix = audio.prefix(audio.count / 2)
        let attempts = Mutex(0)
        let server = try await LoopbackHTTPServer.start { request in
            let count = attempts.withLock { $0 += 1; return $0 }
            let offset = request.headers["range"].flatMap { Int($0.dropFirst(6).split(separator: "-")[0]) } ?? 0
            if offset == 0 {
                return .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(audio.count)", "ETag": "\"late-recovery\""], body: prefix)
            }
            return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(audio.count - offset)",
                "Content-Range": "bytes \(offset)-\(audio.count - 1)/\(audio.count)", "ETag": "\"late-recovery\""],
                body: count >= 5 ? audio[offset...] : Data())
        }
        defer { server.stop() }
        let client = ProxyNetworkEnvironment.Client(configuration: .init(kind: .http, host: "127.0.0.1", port: server.url.port!))
        let engine = AVPlayerPlaybackEngine(muted: true, proxyClient: { client })
        defer { engine.unload() }
        var failures: [String] = []
        engine.onEvent = { if case .failed(_, let message) = $0 { failures.append(message) } }
        engine.load(episode: .init(id: 1, details: .init(identifier: "late-recovery", title: "Late recovery",
                    media: .init(url: "http://late-recovery.invalid/media.mp3", size: Int64(audio.count)))),
                    generation: UUID(), positionMilliseconds: 0)
        engine.play(commandID: UUID())
        let source = try #require(engine.httpSource)
        let deadline = ContinuousClock.now + .seconds(25)
        while attempts.withLock({ $0 }) < 4, failures.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        engine.pause(commandID: UUID())
        let pausedAt = engine.reading?.sample.positionMilliseconds ?? 0
        while !(await source.snapshot().completed), failures.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(failures.isEmpty && attempts.withLock { $0 } >= 5)
        #expect(engine.reading?.sample.status == .paused)
        #expect(abs((engine.reading?.sample.positionMilliseconds ?? 0) - pausedAt) < 100)
        #expect(try Data(contentsOf: source.cacheURL) == audio)
        engine.play(commandID: UUID())
        while (engine.reading?.sample.positionMilliseconds ?? 0) < 17000, failures.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(failures.isEmpty, "\(failures)")
        #expect((engine.reading?.sample.positionMilliseconds ?? 0) >= 17000)
        #expect(await source.snapshot().completed)
        engine.unload()
        let state = await source.snapshot()
        #expect(state.cancelled && state.activeTransfers == 0 && state.pendingRequests == 0)
        #expect(!FileManager.default.fileExists(atPath: source.cacheURL.path))
    }

    @Test func repeatedHeaderTimeoutsEventuallyFailAndReleasePreparation() async throws {
        let server = try await LoopbackHTTPServer.start { _ in nil }
        defer { server.stop() }
        let engine = AVPlayerPlaybackEngine(muted: true)
        defer { engine.unload() }
        var failures = 0
        engine.onEvent = { if case .failed = $0 { failures += 1 } }
        engine.load(episode: .init(id: 1, details: .init(identifier: "retry-exhaustion", title: "Unavailable",
                    media: .init(url: server.url.absoluteString, size: 0))), generation: UUID(), positionMilliseconds: 0)
        engine.play(commandID: UUID())
        let source = try #require(engine.httpSource)
        let deadline = ContinuousClock.now + .seconds(42)
        while failures == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        // An unresponsive server ends in one visible error after bounded retries, not a hang.
        #expect(failures == 1 && engine.httpSource == nil)
        #expect(server.requests.count == 4)
        let state = await source.snapshot()
        #expect(state.activeTransfers == 0 && state.pendingRetries == 0 && state.pendingRequests == 0)
        #expect(!FileManager.default.fileExists(atPath: source.cacheURL.path))
    }

    @Test func replayedValidPrefixDoesNotResetRetryBudget() async throws {
        let audio = try Data(contentsOf: fixture)
        let server = try await LoopbackHTTPServer.start { _ in
            // Ignore Range and repeatedly close after exactly the same valid prefix.
            .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(audio.count)", "ETag": "\"repeated\""],
                  body: audio.prefix(audio.count / 2))
        }
        defer { server.stop() }
        // This case isolates the raw source's bounded retry contract. The selected
        // player intentionally defers an exhausted error while decoded audio remains.
        let failures = Mutex(0)
        let source = try ProgressiveHTTPMediaSource(url: server.url, onFailure: { _ in failures.withLock { $0 += 1 } })
        let player = AVPlayer(playerItem: AVPlayerItem(asset: source.asset))
        player.isMuted = true
        defer { player.replaceCurrentItem(with: nil); source.cancel() }
        // The retries are spaced by wall-clock backoff; allow for a loaded machine.
        let deadline = ContinuousClock.now + .seconds(30)
        while failures.withLock({ $0 }) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(failures.withLock { $0 } == 1 && server.requests.count == 4, "failures \(failures.withLock { $0 }), requests \(server.requests.count)")
        let state = await source.snapshot()
        #expect(!state.completed && state.activeTransfers == 0 && state.pendingRetries == 0)
        #expect(!FileManager.default.fileExists(atPath: source.cacheURL.path))
    }
}
private final class StreamingRecoveryFixtures: NSObject {}
