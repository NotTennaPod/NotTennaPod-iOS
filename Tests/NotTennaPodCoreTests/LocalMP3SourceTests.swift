import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized) struct LocalMP3SourceTests {
    nonisolated static let cases: [(String, Int64)] = [
        ("playback-30sec", 30_040_793), ("info", 30_040_816),
        ("playback-unknown-duration", 29_900_000),
        ("playback-indexed-vbri-3", 30_023_979), ("playback-indexed-vbri-9", 30_023_979),
        ("playback-indexed-mllt-stereo-v3", 30_024_000), ("playback-indexed-mllt-stereo-v4", 30_024_000)]
    private func fixture(_ name: String) throws -> URL {
#if SWIFT_PACKAGE
        return try #require(Bundle.module.url(forResource: name, withExtension: "mp3", subdirectory: "Fixtures"))
#else
        return try #require(Bundle(for: LocalMP3Fixtures.self).url(forResource: name, withExtension: "mp3"))
#endif
    }
    private func bytes(_ name: String) throws -> Data {
        var data = try Data(contentsOf: fixture(name == "info" ? "playback-30sec" : name))
        if name == "info" { data.replaceSubrange(21..<25, with: Data("Info".utf8)) }
        return data
    }
    private func reference(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var result = [Int16]()
        // Preserve the last full native read: VBRI's estimated file length can
        // precede its final MPEG frame.
        while file.framePosition < file.length {
            try file.read(into: buffer)
            try #require(buffer.frameLength > 0)
            result += UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength * file.processingFormat.channelCount))
        }
        return result
    }
    private func drain(_ decoder: NativeMP3SourceDecoder) async throws -> [Int16] {
        var result = [Int16]()
        while let packet = try await decoder.next() {
            #expect(packet.presentationTime == decoder.startTime + CMTime(value: Int64(result.count / decoder.channels), timescale: Int32(decoder.sampleRate)))
            result += packet.samples
        }
        return result
    }
    private func peak(_ samples: [Int16]) -> Int { samples.lazy.map { abs(Int($0)) }.max() ?? 0 }
    /// User-visible audio outcome: the decoded span has the expected length (no audible
    /// loss or padding beyond 50 ms) and is not silent. Sample-exact decoder identity is not required.
    private func expectAudio(_ actual: [Int16], frames expectedFrames: Int, reference: [Int16], channels: Int, sampleRate: Int,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        let frames = actual.count / max(channels, 1)
        #expect(abs(frames - expectedFrames) <= sampleRate / 20, "decoded \(frames) frames, expected \(expectedFrames)", sourceLocation: sourceLocation)
        #expect(peak(actual) * 2 >= peak(reference), "decoded audio is silent or much quieter than the file", sourceLocation: sourceLocation)
    }
    private func durationClose(_ actual: Int64?, _ expected: Int64) -> Bool {
        actual.map { abs($0 - expected) <= 50_000 } ?? false
    }

    @Test(arguments: cases)
    func retainedFilePreservesMetadataAudioAndSeekRecovery(scenario: (String, Int64)) async throws {
        let (name, duration) = scenario
        let root = URL.temporaryDirectory.appendingPathComponent("local-mp3-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A misleading extension does not change how the download is recognised; the
        // playback below is the same for any name, so it runs once.
        let misleading = root.appendingPathComponent("wrong.m4a")
        try bytes(name).write(to: misleading)
        #expect(try await LocalAudioBytes.openIdentified(url: misleading)?.format == .mp3)
        let url = root.appendingPathComponent("download")
        try bytes(name).write(to: url)
        // Info differs only in its metadata marker; all MPEG audio and padding
        // match Xing. The native Info file length has the confirmed estimate.
        let expected = try reference(name == "info" ? fixture("playback-30sec") : url)
        let captured = try #require(try await LocalAudioBytes.openIdentified(url: url))
        #expect(captured.format == .mp3)
        let source = NativeMP3PlaybackSource(localURL: url, file: captured.file)
        try FileManager.default.removeItem(at: url)
        try Data("Replacement before first MP3 decoder".utf8).write(to: url)
        let initial = try await source.makeDecoder(prepareSourceTimeline: true)
        #expect(durationClose(initial.bufferState?.snapshot.durationMicroseconds, duration) && initial.sourceSeekable == true)
        let channels = initial.channels, rate = initial.sampleRate, totalFrames = expected.count / max(channels, 1)
        let full = try await drain(initial)
        expectAudio(full, frames: totalFrames, reference: expected, channels: channels, sampleRate: rate)
        await initial.cancel()
        // Seeking must land within 0.25 s of the target and play the rest of the file,
        // including after a seek beyond the end.
        for target: Int64 in [20000, 2000, 60000, 0] {
            let decoder = try await source.makeDecoder(start: CMTime(value: target, timescale: 1000), prepareSourceTimeline: true)
            #expect(decoder.sourceSeekable == true && durationClose(decoder.bufferState?.snapshot.durationMicroseconds, duration))
            let actual = try await drain(decoder)
            if target == 60000 {
                #expect(actual.isEmpty)
            } else {
                #expect(abs(decoder.startTime.seconds - Double(target) / 1000) <= 0.25)
                let remaining = totalFrames - Int(decoder.startTime.seconds * Double(rate))
                expectAudio(actual, frames: remaining, reference: expected, channels: channels, sampleRate: rate)
            }
            await decoder.cancel()
        }
        let network = await source.networkSnapshot, cacheURL = await source.cacheURL
        #expect(network == nil && cacheURL == nil)
    }

    @Test(arguments: [1149, 1151])
    func inconsistentInfoDeclarationCannotBecomeSuccessfulEOF(packets: Int) async throws {
        let url = URL.temporaryDirectory.appendingPathComponent("invalid-info-\(UUID()).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        var media = try bytes("info")
        media.replaceSubrange(29..<33, with: (0..<4).reversed().map { UInt8((packets >> ($0 * 8)) & 255) })
        try media.write(to: url)
        let captured = try #require(try await LocalAudioBytes.openIdentified(url: url))
        let source = NativeMP3PlaybackSource(localURL: url, file: captured.file)
        let decoder = try await source.makeDecoder(prepareSourceTimeline: true)
        await #expect(throws: NativeMP3PCMDecoder.Failure.incompleteStream) { try await drain(decoder) }
        await decoder.cancel()
    }

    @Test(arguments: [false, true])
    func remoteInfoPreservesCompleteAudioAndRetainedSeek(proxyEnabled: Bool) async throws {
        let media = try bytes("info")
        let credentials = FeedCredentials(username: "info", password: "saved")
        let auth = "Basic " + Data("proxy:saved".utf8).base64EncodedString()
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            if proxyEnabled && request.headers["proxy-authorization"] != auth {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"info\""])
            }
            let start = request.headers["range"].flatMap { Int($0.dropFirst(6).dropLast()) } ?? 0
            return .init(status: start == 0 ? 200 : 206,
                headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(media.count - start)",
                    "Content-Range": "bytes \(start)-\(media.count - 1)/\(media.count)"], body: Data(media.dropFirst(start)))
        }
        defer { server.stop() }
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!, username: "proxy", password: "saved") : PodcastProxy()
        let remote = proxyEnabled ? URL(string: "http://info.invalid/episode.mp3")! : server.url
        let source = NativeMP3PlaybackSource(url: remote, proxy: proxy, credentials: credentials)
        let expected = try reference(fixture("playback-30sec"))
        for target: Int64 in [0, 20000, 2000] {
            let decoder = try await source.makeDecoder(start: CMTime(value: target, timescale: 1000), prepareSourceTimeline: true)
            #expect(durationClose(decoder.bufferState?.snapshot.durationMicroseconds, 30_040_816) && decoder.sourceSeekable == true)
            let actual = try await drain(decoder)
            #expect(abs(decoder.startTime.seconds - Double(target) / 1000) <= 0.25)
            let rate = decoder.sampleRate, channels = decoder.channels
            let remaining = expected.count / max(channels, 1) - Int(decoder.startTime.seconds * Double(rate))
            expectAudio(actual, frames: remaining, reference: expected, channels: channels, sampleRate: rate)
            await decoder.cancel()
        }
        #expect(!server.requests.isEmpty)
    }

    @Test(arguments: ["playback-30sec", "playback-unknown-duration", "playback-indexed-mllt-stereo-v3"])
    func defaultFactoryRetainsMP3BeforeSessionAndCompletesWithoutCache(name: String) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("selected-mp3-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("episode.media"), cache = root.appendingPathComponent("cache")
        try bytes(name).write(to: url)
        let expected = try reference(url)
        var outputs: [SampleBufferPCMOutputTests.Transport] = []
        let owner = PCMPlaybackFactory(cacheDirectory: cache, makeTransport: {
            let output = SampleBufferPCMOutputTests.Transport(); outputs.append(output); return output
        })
        let factory = try await owner.make(.local(url))
        #expect(factory.providesSourceDuration && outputs.isEmpty)
        try FileManager.default.removeItem(at: url)
        let session = try await factory.make(positionMilliseconds: 0, parameters: .init(speed: 1, skipSilence: false))
        defer { session.close() }
        try await session.prepare(); try session.play()
        let output = try #require(outputs.last)
        let deadline = ContinuousClock.now + .seconds(10)
        while session.state != .ended, session.failure == nil, ContinuousClock.now < deadline {
            if output.playing { output.currentTime = output.end; output.onTimeChanged?() }
            await Task.yield()
        }
        #expect(session.state == .ended && session.failure == nil && session.sourceSeekable == true)
        var actual = Data()
        for buffer in output.buffers { actual.append(try #require(buffer.content.withContiguousStorageIfAvailable { Data($0) })) }
        let samples = actual.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let file = try AVAudioFile(forReading: fixture(name))
        let channels = Int(file.processingFormat.channelCount), rate = Int(file.processingFormat.sampleRate)
        // The whole episode reaches the output (within 50 ms) and is audible.
        expectAudio(samples, frames: expected.count / channels, reference: expected, channels: channels, sampleRate: rate)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test(arguments: ["playback-indexed-vbr-stereo", "playback-indexed-mllt-stereo-v4", "playback-indexed-vbri-9"])
    func selectedMP3NativeProcessedTailRecoversAfterSeek(name: String) async throws {
        let cache = URL.temporaryDirectory.appendingPathComponent("local-mp3-native-unused-\(UUID())")
        defer { try? FileManager.default.removeItem(at: cache) }
        let owner = PCMPlaybackFactory(cacheDirectory: cache, makeTransport: { NativeSampleBufferTransport(muted: true) })
        let factory = try await owner.make(.local(fixture(name)))
        for start: Int64 in [29000, 29500] {
            let session = try await factory.make(positionMilliseconds: start, parameters: .init(speed: 1.5, skipSilence: true, volume: .heavyBoost))
            defer { session.close() }
            try await session.prepare(); try session.play()
            let deadline = ContinuousClock.now + .seconds(10)
            while session.state != .ended, session.failure == nil, ContinuousClock.now < deadline { await Task.yield() }
            #expect(session.state == .ended && session.failure == nil)
            #expect(session.writtenFrames > 0 && session.presentedFrames == session.writtenFrames)
        }
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }
}
private final class LocalMP3Fixtures: NSObject {}
