import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized)
struct MediaStreamingTimeoutTests {
    private var fixture: URL {
#if SWIFT_PACKAGE
        Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures")!
#else
        Bundle(for: MediaTimeoutFixtures.self).url(forResource: "playback-30sec", withExtension: "mp3")!
#endif
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    @Test(arguments: [false, true], [false, true])
    func stalledMediaFailsAfterEightSecondsAndReleasesItsRequest(relay: Bool, headersReceived: Bool) async throws {
        let bytes = try Data(contentsOf: fixture)
        let began = Mutex<ContinuousClock.Instant?>(nil)
        let failures = Mutex<[(NSError, ContinuousClock.Instant)]>([])
        let disconnected = Mutex(0)
        let proxy = try await LoopbackHTTPServer.start(onClientDisconnect: { disconnected.withLock { $0 += 1 } }) { _ in
            began.withLock { if $0 == nil { $0 = .now } }
            if !headersReceived { return nil }
            return .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(bytes.count)"],
                         body: bytes.prefix(bytes.count / 2), keepConnectionOpen: true)
        }
        defer { proxy.stop() }
        let configuration = PodcastProxy(kind: .http, host: "127.0.0.1", port: proxy.url.port!)
        let remote = URL(string: "http://timeout.invalid/media")!
        let onFailure: @Sendable (Error) -> Void = { error in failures.withLock { $0.append((error as NSError, .now)) } }
        if relay {
            let source = try await NativeStreamingRelay.start(url: remote, playlist: false, proxy: configuration, onFailure: onFailure)
            defer { source.cancel() }
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let request = Task { try await session.data(from: source.url) }
            defer { request.cancel() }
            try await wait { !failures.withLock { $0.isEmpty } }
            await #expect(throws: (any Error).self) { _ = try await request.value }
        } else {
            // Like the original raw DataSource probe, isolate one request's idle timer.
            // Default selected-player recovery is tested separately with retries enabled.
            let source = try ProgressiveHTTPMediaSource(url: remote, proxy: configuration, transientRetryLimit: 0, onFailure: onFailure)
            let player = AVPlayer(playerItem: AVPlayerItem(asset: source.asset))
            player.isMuted = true
            defer { player.replaceCurrentItem(with: nil); source.cancel() }
            try await wait { !failures.withLock { $0.isEmpty } }
            let state = await source.snapshot()
            #expect(state.failure != nil && state.activeTransfers == 0 && state.pendingRequests == 0)
            #expect(!FileManager.default.fileExists(atPath: source.cacheURL.path))
        }
        let start = try #require(began.withLock { $0 })
        let failure = try #require(failures.withLock { $0.first })
        let elapsed = start.duration(to: failure.1)
        #expect(failure.0.domain == NSURLErrorDomain && failure.0.code == URLError.timedOut.rawValue)
        #expect(elapsed >= .milliseconds(7500) && elapsed < .seconds(12), "Observed media timeout: \(elapsed)")
        try await wait { disconnected.withLock { $0 > 0 } }
        print("Media timeout relay=\(relay) headers=\(headersReceived): \(elapsed)")
    }

    @Test func mediaProgressResetsInactivityRatherThanLimitingTotalDuration() async throws {
        let chunk = Data(repeating: 42, count: 8192)
        let proxy = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": "\(3 * chunk.count)"], body: chunk, keepConnectionOpen: true)
        }
        defer { proxy.stop() }
        let relay = try await NativeStreamingRelay.start(url: URL(string: "http://progress.invalid/media")!, playlist: false,
            proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!))
        defer { relay.cancel() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let response = Task { try await session.bytes(from: relay.url) }
        defer { response.cancel() }
        let (bytes, _) = try await response.value
        var iterator = bytes.makeAsyncIterator()
        var received = Data()
        for _ in 0..<chunk.count { received.append(try #require(try await iterator.next())) }
        let start = ContinuousClock.now
        // These intervals exercise the actual idle timer, not scheduler synchronization.
        for _ in 0..<2 {
            try await Task.sleep(for: .seconds(5))
            try await proxy.appendResponseBody(chunk)
            for _ in 0..<chunk.count { received.append(try #require(try await iterator.next())) }
        }
        #expect(try await iterator.next() == nil)
        #expect(received == chunk + chunk + chunk)
        #expect(start.duration(to: .now) >= .seconds(10))
    }
}
private final class MediaTimeoutFixtures: NSObject {}
