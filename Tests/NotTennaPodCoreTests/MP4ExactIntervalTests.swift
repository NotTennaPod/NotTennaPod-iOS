import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct MP4ExactIntervalTests {
    @Test(arguments: ["lc", "he", "hev2"], ["full", "progressive", "truncated", "cancelled"])
    func nativeIntervalPreservesFiniteAndProgressiveStartup(profile: String, scenario: String) async throws {
#if SWIFT_PACKAGE
        let fixture = try #require(Bundle.module.url(forResource: profile + "-tag-only.m4a", withExtension: nil, subdirectory: "Fixtures/MP4Gapless"))
#else
        let fixture = try #require(Bundle(for: MP4ExactFixtures.self).url(forResource: profile + "-tag-only.m4a", withExtension: nil, subdirectory: "MP4Gapless"))
#endif
        let bytes = try Data(contentsOf: fixture)
        let prefix = min(32768, bytes.count - 1)
        let full = scenario == "full"
        let released = Mutex(full)
        let server = try await LoopbackHTTPServer.start { _ in
            let complete = released.withLock { $0 }
            return .init(headers: ["Content-Type": "audio/mp4", "Content-Length": String(bytes.count)],
                  body: complete && scenario != "truncated" ? bytes : Data(bytes.prefix(prefix)),
                  keepConnectionOpen: !complete)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        let producer = NativeAudioPacketProducer(input: input,
            timeline: .init(durationMicroseconds: nil, seekable: true), format: .mp4)
        defer { producer.stop(); input.cancel() }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(15))
            producer.stop(); input.cancel()
        }
        defer { watchdog.cancel() }
        let first = Mutex(false)
        let preparation = Task {
            let decoder = try await NativeBufferedAudioDecoder.open(producer: producer)
            do {
                let packet = try #require(try await decoder.next())
                #expect(packet.presentationTime == .zero)
                first.withLock { $0 = true }
                return (decoder, packet.frameCount)
            } catch { await decoder.cancel(); throw error }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !first.withLock({ $0 }), ContinuousClock.now < deadline { await Task.yield() }
        // The final byte is deliberately withheld. Known total size does not
        // establish materialized input or authorize waiting for whole-file EOF.
        #expect(first.withLock { $0 }, "Exact MP4 startup waited for the unavailable suffix")
        if scenario == "cancelled" {
            preparation.cancel(); producer.stop(); input.cancel()
            let result = await preparation.result
            if case .success(let (decoder, _)) = result { await decoder.cancel() }
            await producer.waitForExit()
            #expect(producer.snapshot().cancelled && producer.snapshot().exited)
            return
        }
        if !full {
            released.withLock { $0 = true }
            let connections = server.requests.indices
            try #require(!connections.isEmpty)
            for connection in connections {
                do {
                    try await server.appendResponseBody(scenario == "truncated" ? Data() : Data(bytes.dropFirst(prefix)),
                        toConnectionAt: connection, isFinal: true)
                } catch {
                    // Indexed reads may have retired an earlier response. Future
                    // requests now see the released body; strict drainage below
                    // still rejects any live transfer that does not complete.
                    FileHandle.standardError.write(Data("MP4 fixture retired connection \(connection): \(error)\n".utf8))
                }
            }
        }
        do {
            let (decoder, firstCount) = try await preparation.value
            var count = firstCount
            do {
                while let packet = try await decoder.next() { count += packet.frameCount }
                #expect(scenario != "truncated", "Missing final input byte became successful EOF")
                // The whole episode decodes (within 50 ms of the native packet table's length).
                #expect(abs(count - (profile == "lc" ? 193472 : 194432)) <= 2400)
            } catch { #expect(scenario == "truncated") }
            await decoder.cancel()
        } catch { #expect(scenario == "truncated") }
        producer.stop(); await producer.waitForExit()
    }
}
private final class MP4ExactFixtures: NSObject {}
