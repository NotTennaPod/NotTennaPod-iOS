import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Real TLS and proxy handshakes; requires the explicitly started owned protocol fixture.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct ProxyStreamingProtocolProbeTests {
    @Test(arguments: [PodcastProxy.Kind.http, .socks])
    func nativeRelayUsesAuthenticatedTLSProxyAndPreservesMediaBytes(kind: PodcastProxy.Kind) async throws {
        let configuration = PodcastProxy(kind: kind, host: "127.0.0.1", port: kind == .http ? 18790 : 18791,
            username: "fixture-user", password: "fixture-secret")
        let address = kind == .http ? "http://proxy-redirect.invalid/audio" :
            "https://raw.githubusercontent.com/AntennaPod/AntennaPod/f8c641887e4677237b01b6e942ff8fe20fc8beec/app/src/androidTest/assets/30sec.mp3"
        let failures = Mutex<[String]>([])
        let relay = try await NativeStreamingRelay.start(url: URL(string: address)!, playlist: false, proxy: configuration,
            onFailure: { error in failures.withLock { $0.append(error.localizedDescription) } })
        defer { relay.cancel() }
        let (bytes, _) = try await URLSession.shared.data(from: relay.url)
        let expected = try Data(contentsOf: Bundle(for: ProxyStreamingProtocolFixtures.self).url(forResource: "playback-30sec", withExtension: "mp3")!)
        #expect(bytes == expected)
        let item = AVPlayerItem(asset: AVURLAsset(url: relay.url,
            options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidCrossSiteReference.rawValue]))
        let player = AVPlayer(playerItem: item); player.isMuted = true
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        await player.seek(to: CMTime(value: 3883, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        let deadline = ContinuousClock.now + .seconds(40)
        while player.currentTime().seconds < 4.4, item.status != .failed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(item.status == .readyToPlay, "\(String(describing: item.error))")
        #expect(player.currentTime().seconds >= 4.4)
        #expect(failures.withLock { $0.isEmpty })
    }
    @Test(arguments: [PodcastProxy.Kind.http, .socks])
    func authenticatedTLSProxyCarriesNativeAudioBytesAndSeeks(kind: PodcastProxy.Kind) async throws {
        let configuration = PodcastProxy(kind: kind, host: "127.0.0.1", port: kind == .http ? 18790 : 18791,
            username: "fixture-user", password: "fixture-secret")
        let client = ProxyNetworkEnvironment.Client(configuration: configuration)
        // HTTP starts in an authenticated forward proxy, then changes to a native TLS CONNECT session.
        let address = kind == .http ? "http://proxy-redirect.invalid/audio" :
            "https://raw.githubusercontent.com/AntennaPod/AntennaPod/f8c641887e4677237b01b6e942ff8fe20fc8beec/app/src/androidTest/assets/30sec.mp3"
        let engine = AVPlayerPlaybackEngine(muted: true, proxyClient: { client })
        defer { engine.unload() }
        var failures: [String] = []
        engine.onEvent = { if case .failed(_, let error) = $0 { failures.append(error) } }
        let episode = LibraryEpisode(id: 1, details: .init(identifier: "proxy-tls", title: "Proxy TLS audio", media: .init(url: address, size: 0)))
        engine.load(episode: episode, generation: UUID(), positionMilliseconds: 0)
        engine.seek(to: 3883, commandID: UUID()); engine.play(commandID: UUID())
        let deadline = ContinuousClock.now + .seconds(40)
        while (engine.reading?.sample.positionMilliseconds ?? 0) < 4400, failures.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(failures.isEmpty, "\(failures)")
        #expect((engine.reading?.sample.positionMilliseconds ?? 0) >= 4400)
        let source = try #require(engine.httpSource)
        let snapshot = await source.snapshot()
        #expect(snapshot.received > 0 && snapshot.failure == nil)
        let expected = try Data(contentsOf: Bundle(for: ProxyStreamingProtocolFixtures.self).url(forResource: "playback-30sec", withExtension: "mp3")!)
        let received = try Data(contentsOf: source.cacheURL)
        #expect(received == expected.prefix(received.count))
    }
}
private final class ProxyStreamingProtocolFixtures: NSObject {}
