import AVFoundation
import Foundation
import Testing
import Synchronization
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct PausedHLSBufferingTests {
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(10)) }
        try #require(predicate())
    }
    @Test(arguments:[false,true]) func heldSegmentKeepsPausedSeekLoadingUntilReady(supersede: Bool) async throws {
#if SWIFT_PACKAGE
        let folder = try #require(Bundle.module.url(forResource:"index",withExtension:"m3u8",subdirectory:"Fixtures/StreamingHLS")).deletingLastPathComponent()
#else
        let folder = try #require(Bundle(for:PausedHLSFixture.self).url(forResource:"index",withExtension:"m3u8",subdirectory:"StreamingHLS")).deletingLastPathComponent()
#endif
        let contents = try Dictionary(uniqueKeysWithValues:FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).map { ($0.lastPathComponent,try Data(contentsOf:$0)) })
        let released = Mutex(false)
        let server = try await LoopbackHTTPServer.start { request in
            let name = String(request.path.split(separator:"/").last ?? "")
            if name == "part03.ts", !released.withLock({ $0 }) { return nil }
            guard let bytes = contents[name] else { return .init(status:404) }
            return .init(headers:["Content-Type":name.hasSuffix("m3u8") ? "application/vnd.apple.mpegurl" : "video/mp2t"],body:bytes)
        }
        defer { server.stop() }
        let url = server.url.deletingLastPathComponent().appendingPathComponent("index.m3u8")
        let episode = LibraryEpisode(id:1,details:.init(identifier:"hls-held",title:"Held HLS",media:.init(url:url.absoluteString,size:0)))
        let engine = AVPlayerPlaybackEngine(muted:true)
        defer { engine.unload() }
        var events: [PlaybackEngineReading] = [], failures: [String] = []
        engine.onEvent = { event in
            switch event {
            case .ready(let value), .stateChanged(let value): events.append(value)
            case .failed(_,let message): failures.append(message)
            default: break
            }
        }
        engine.load(episode:episode,generation:UUID(),positionMilliseconds:0)
        try await wait { engine.reading != nil || !failures.isEmpty }
        #expect(failures.isEmpty)
        engine.seek(to:6_500,commandID:UUID())
        if supersede {
            engine.seek(to:6_200,commandID:UUID())
            engine.seek(to:6_500,commandID:UUID())
        }
        let pause = UUID(); engine.pause(commandID:pause)
        try await wait { server.heldRequestPaths.contains("/part03.ts") }
        print("Held HLS diagnostic",String(describing:engine.reading),"time",String(describing:engine.nativePlayer?.currentTime().seconds),"bufferEmpty",String(describing:engine.nativePlayer?.currentItem?.isPlaybackBufferEmpty))
        #expect(engine.reading?.buffering == true)
        #expect(events.last?.buffering == true)
        #expect(engine.reading?.sample.status == .paused)
        #expect(engine.reading?.commandID == pause)
        released.withLock { $0 = true }
        try server.respond(toPath:"/part03.ts",with:.init(headers:["Content-Type":"video/mp2t"],body:try #require(contents["part03.ts"])))
        try await wait { engine.reading?.buffering == false && abs((engine.nativePlayer?.currentTime().seconds ?? 0)-6.5)<0.05 }
        #expect(engine.reading?.sample.status == .paused)
        #expect(engine.nativePlayer?.rate == 0)
        #expect(events.last?.buffering == false)
        #expect(failures.isEmpty)
        print("HLS completed requests",server.requests.map(\.path))
    }
}
#if !SWIFT_PACKAGE
private final class PausedHLSFixture: NSObject {}
#endif
