import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct UnknownDurationStreamingRecoveryTests {
    private var fixture: URL {
#if SWIFT_PACKAGE
        Bundle.module.url(forResource: "playback-unknown-duration", withExtension: "mp3", subdirectory: "Fixtures")!
#else
        Bundle(for: UnknownRecoveryFixtures.self).url(forResource: "playback-unknown-duration", withExtension: "mp3")!
#endif
    }

    @Test(arguments: [false, true]) func bufferedUnknownDurationReconnectsAfterConsumption(proxyConfigured: Bool) async throws {
        let audio = try Data(contentsOf: fixture)
        let login = FeedCredentials(username: "stream", password: "saved")
        let began = ContinuousClock.now
        let requests = Mutex<[(Duration, String?)]>([])
        let server = try await LoopbackHTTPServer.start { request in
            if proxyConfigured && request.headers["proxy-authorization"] != "Basic " + Data("proxy:saved".utf8).base64EncodedString() {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"recovery\""])
            }
            guard request.headers["authorization"] == login.authorization(utf8: false) else {
                return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"recovery\""])
            }
            let elapsed = began.duration(to: .now)
            requests.withLock { $0.append((elapsed, request.headers["range"])) }
            // Initial resource selection and the first native connection see a valid
            // half-file. A later live connection receives fresh media from its start.
            let body = elapsed < .seconds(12) ? Data(audio.prefix(audio.count / 2)) : audio
            let chunk = Data("\(String(body.count, radix: 16))\r\n".utf8) + body + Data("\r\n".utf8)
            return .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"], body: chunk, keepConnectionOpen: true)
        }
        defer { server.stop() }
        let configuration = proxyConfigured
            ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!, username: "proxy", password: "saved")
            : PodcastProxy()
        let client = Mutex(ProxyNetworkEnvironment.Client(configuration: configuration))
        let engine = AVPlayerPlaybackEngine(muted: true, credentials: { _ in login }, proxyClient: { client.withLock { $0 } })
        defer { engine.unload() }
        var failures: [String] = []
        var ended = false
        var resets: [PlaybackEngineReading] = []
        engine.onEvent = {
            if case .failed(_, let message) = $0 { failures.append(message) }
            if case .ended = $0 { ended = true }
            if case .timelineReset(let reading) = $0 { resets.append(reading) }
        }
        let url = proxyConfigured ? "http://live-recovery.invalid/media.mp3" : server.url.absoluteString
        let generation = UUID(), command = UUID()
        engine.load(episode: .init(id: 1, details: .init(identifier: "live-recovery", title: "Live recovery", media: .init(url: url, size: 0))),
                    generation: generation, positionMilliseconds: 0)
        engine.play(commandID: command)
        let deadline = ContinuousClock.now + .seconds(24)
        var highestPosition: Int32 = 0
        var reset = false
        var recovered = false
        var capturedConfiguration = false
        while failures.isEmpty, !ended, ContinuousClock.now < deadline {
            if let reading = engine.reading {
                #expect(reading.sample.durationMilliseconds == -1)
                let position = reading.sample.positionMilliseconds
                if highestPosition > 13000 && position < 2000 { reset = true }
                highestPosition = max(highestPosition, position)
                if reset && position >= 3000 { recovered = true; break }
                if position >= 1000 && !capturedConfiguration {
                    capturedConfiguration = true
                    // Later global proxy changes cannot redirect this admitted stream.
                    client.withLock { $0 = .init(configuration: .init(kind: .http, host: "unreachable.invalid", port: 1)) }
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(failures.isEmpty && !ended, "\(failures)")
        #expect(highestPosition >= 14000 && recovered, "Highest position \(highestPosition), reset \(reset)")
        // The live stream reconnected after the buffered audio was played out, not before.
        let reconnects = requests.withLock { $0.filter { $0.0 > .seconds(2) } }
        #expect(!reconnects.isEmpty)
        let firstReset = try #require(resets.first)
        #expect(firstReset.sample.positionMilliseconds >= 14000)
        engine.pause(commandID: UUID())
        #expect(engine.reading?.sample.status == .paused)
    }

    @Test(arguments: [false, true]) func pausedInterruptionRetainsIntentAndRetiresOnReplacement(replace: Bool) async throws {
        let audio = try Data(contentsOf: fixture)
        let attempts = Mutex(0)
        let began = ContinuousClock.now
        let server = try await LoopbackHTTPServer.start { _ in
            attempts.withLock { $0 += 1 }
            let body = began.duration(to: .now) < .seconds(12) ? Data(audio.prefix(audio.count / 2)) : audio
            return .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"],
                         body: Data("\(String(body.count, radix: 16))\r\n".utf8) + body + Data("\r\n".utf8), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let engine = AVPlayerPlaybackEngine(muted: true)
        defer { engine.unload() }
        var failures: [String] = []
        engine.onEvent = { if case .failed(_, let message) = $0 { failures.append(message) } }
        engine.load(episode: .init(id: 1, details: .init(identifier: "held-live", title: "Held live", media: .init(url: server.url.absoluteString, size: 0))),
                    generation: UUID(), positionMilliseconds: 0)
        engine.play(commandID: UUID())
        let deadline = ContinuousClock.now + .seconds(35)
        while engine.nativeRelay?.snapshot.deferredRequests != 1, failures.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let relay = try #require(engine.nativeRelay)
        #expect(failures.isEmpty && relay.snapshot.deferredRequests == 1)
        engine.pause(commandID: UUID())
        let pausedAt = engine.reading?.sample.positionMilliseconds ?? 0
        let admittedRequests = attempts.withLock { $0 }
        #expect(pausedAt >= 6000 && pausedAt < 10000)
        if replace {
            let generation = UUID()
            engine.load(episode: .init(id: 2, details: .init(identifier: "replacement", title: "Replacement",
                                      media: .init(url: fixture.absoluteString, size: Int64(audio.count)))),
                        generation: generation, positionMilliseconds: 0)
            engine.play(commandID: UUID())
            while (engine.reading?.sample.positionMilliseconds ?? 0) < 2000, failures.isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            // The replacement episode plays.
            #expect(engine.reading?.generation == generation)
            #expect((engine.reading?.sample.positionMilliseconds ?? 0) >= 2000)
        } else {
            // Cross the unpaused source's observed reconnect deadline with audio
            // still held by Pause. Wall time alone must not consume that buffer.
            let heldUntil = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < heldUntil { try await Task.sleep(for: .milliseconds(20)) }
            // Still paused at the same place; the pause did not silently consume audio.
            #expect(engine.reading?.sample.status == .paused)
            #expect(abs((engine.reading?.sample.positionMilliseconds ?? 0) - pausedAt) < 250)
            engine.play(commandID: UUID())
            while engine.nativeRelay === relay, failures.isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            while (engine.reading?.sample.positionMilliseconds ?? 0) < 2000, failures.isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            // Resuming reconnects to the live stream and playback continues.
            #expect(attempts.withLock { $0 } > admittedRequests)
            #expect((engine.reading?.sample.positionMilliseconds ?? 0) >= 2000)
        }
        #expect(failures.isEmpty, "\(failures)")
    }
}
private final class UnknownRecoveryFixtures: NSObject {}
