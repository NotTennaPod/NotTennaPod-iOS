import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct NativeLocalAudioSourceTests {
    static let files = ["StreamingFormats/tone.wav", "StreamingFormats/tone.aac", "StreamingFormats/tone.flac",
        "FLACVariants/variable.flac", "FLACVariants/variable-table.flac"]
    private func fixture(_ path: String) throws -> URL {
        let parts = path.split(separator: "/").map(String.init)
#if SWIFT_PACKAGE
        return try #require(Bundle.module.url(forResource: parts.last!, withExtension: nil, subdirectory: "Fixtures/" + parts.dropLast().joined(separator: "/")))
#else
        let directory = parts.first == "FLACVariants" ? parts.first : nil
        return try #require(Bundle(for: LocalSourceFixtures.self).url(forResource: parts.last!, withExtension: nil, subdirectory: directory))
#endif
    }
    private struct Audio {
        let samples: [Int16], time: CMTime, rate: Int, channels: Int
    }
    private func drain(_ decoder: NativeAudioSourceDecoder) async throws -> Audio {
        var samples = [Int16]()
        #expect(decoder.sourceSeekable == true)
        while let packet = try await decoder.next() {
            #expect(packet.presentationTime == decoder.startTime + CMTime(value: Int64(samples.count / decoder.channels), timescale: Int32(decoder.sampleRate)))
            samples += packet.samples
        }
        let audio = Audio(samples: samples, time: decoder.startTime, rate: decoder.sampleRate, channels: decoder.channels)
        await decoder.cancel()
        return audio
    }
    private func pcm(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var samples = [Int16]()
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: UInt32(min(4096, file.length - file.framePosition)))
            try #require(buffer.frameLength > 0)
            samples += UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * Int(file.processingFormat.channelCount))
        }
        return samples
    }

    @Test(arguments: files, ["download.media", "incorrect.mp3", "episode"])
    func downloadedFilePlaysLikeStreamAndSeeksCorrectly(path: String, filename: String) async throws {
        let input = try fixture(path), data = try Data(contentsOf: input)
        let root = URL.temporaryDirectory.appendingPathComponent("local-formats-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(filename)
        try data.write(to: url)
        let server = try await LoopbackHTTPServer.start { request in
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                return .init(status: 206, headers: ["ETag": "\"local-formats\"", "Content-Range": "bytes \(offset)-\(data.count - 1)/\(data.count)"], body: Data(data.dropFirst(offset)))
            }
            return .init(headers: ["ETag": "\"local-formats\""], body: data)
        }
        defer { server.stop() }
        let cache = try SharedStreamingCache(directory: root.appendingPathComponent("cache"))
        let remote = try await PCMRemoteInput.open(url: server.url, proxy: PodcastProxy(), credentials: nil, cache: cache)
        defer { remote.input.cancel(); remote.relay.cancel() }
        let network = try NativeAudioPlaybackSource(remote: remote, url: server.url, proxy: PodcastProxy(), credentials: nil, cache: cache, maximumFrames: 1024)
        let local = try NativeLocalAudioSource(url: url, maximumFrames: 1024)
        for (index, microseconds) in [Int64(4_000_354), 0, 4_000_354].enumerated() {
            let target = CMTime(value: microseconds, timescale: 1_000_000)
            let decoder = try await local.makeDecoder(start: target, processStartupTrim: true)
            let expectedDecoder = try await network.makeDecoder(start: target)
            #expect(decoder.sourceDurationMilliseconds == expectedDecoder.sourceDurationMilliseconds)
            let actual = try await drain(decoder), expected = try await drain(expectedDecoder)
            #expect(abs(CMTimeGetSeconds(actual.time) - CMTimeGetSeconds(target)) <= 0.25)
            #expect(abs(CMTimeGetSeconds(actual.time) - CMTimeGetSeconds(expected.time)) <= 0.25)
            #expect(actual.rate == expected.rate && actual.channels == expected.channels)
            #expect(!actual.samples.isEmpty)
            if path.hasSuffix(".aac") {
                #expect(AudibleMatch.matches(actual.samples, expected.samples, channels: actual.channels, sampleRate: actual.rate))
            } else {
                // Lossless: exactly the source audio from the reported start.
                let source = try pcm(path.contains("variable") ? fixture("StreamingFormats/tone.flac") : input)
                let start = CMTimeConvertScale(actual.time, timescale: Int32(actual.rate), method: .roundTowardZero).value
                #expect(actual.samples == Array(source.dropFirst(Int(start) * actual.channels)))
            }
            if index == 0 {
                try FileManager.default.removeItem(at: url)
                try Data("Unrelated replacement at the original path".utf8).write(to: url)
                // The cold seek loaded only the suffix. Returning to zero must
                // reopen production against the retained descriptor, not path.
            }
        }
        let fresh = try NativeLocalAudioSource(url: url)
        await #expect(throws: (any Error).self) { try await fresh.makeDecoder() }
    }

    @Test func longADTSSeekLandsNearTargetLikeAndroid() async throws {
        let url = try fixture("LongNativeFormats/long.aac")
        let source = try NativeLocalAudioSource(url: url)
        let target = CMTime(value: 360000354, timescale: 1_000_000)
        let decoder = try await source.makeDecoder(start: target)
        #expect(abs(CMTimeGetSeconds(decoder.startTime) - 360.000354) <= 0.25)
        #expect(abs((decoder.sourceDurationMilliseconds ?? 0) - 369448) <= 100)
        let audio = try await drain(decoder)
        // Like Android's CBR byte seek, playback resumes from the frame at the
        // mapped byte offset; the audio heard is that suffix of the file.
        let root = URL.temporaryDirectory.appendingPathComponent("local-adts-suffix-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suffix = root.appendingPathComponent("suffix.aac")
        try Data(Data(contentsOf: url).dropFirst(3003804)).write(to: suffix)
        #expect(AudibleMatch.matches(audio.samples, try pcm(suffix), channels: audio.channels, sampleRate: audio.rate))
    }

    @Test(arguments: [Int64(369448128), 370000000])
    func localADTSIncompleteFinalAccessUnitEndsNormally(time: Int64) async throws {
        let source = try NativeLocalAudioSource(url: fixture("LongNativeFormats/long.aac"))
        let decoder = try await source.makeDecoder(start: CMTime(value: time, timescale: 1_000_000))
        #expect(abs(CMTimeGetSeconds(decoder.startTime) - Double(time) / 1_000_000) <= 0.25)
        #expect(abs((decoder.sourceDurationMilliseconds ?? 0) - 369448) <= 100)
        #expect(try await drain(decoder).samples.isEmpty)
    }

    @MainActor @Test(arguments: files)
    func nativeFactoryPlaysProcessedTailAndRecoversAfterSeek(path: String) async throws {
        let factory = try PCMRecoveryFactory(nativeSourceURL: fixture(path), makeTransport: { NativeSampleBufferTransport(muted: true) })
        #expect(factory.providesSourceDuration)
        for start: Int64 in [7000, 7500] {
            let session = try await factory.make(positionMilliseconds: start, parameters: .init(speed: 1.5, skipSilence: true, volume: .heavyBoost))
            defer { session.close() }
            try await session.prepare(); try session.play()
            let deadline = ContinuousClock.now + .seconds(10)
            while session.state != .ended, session.failure == nil, ContinuousClock.now < deadline { await Task.yield() }
            #expect(session.state == .ended && session.failure == nil)
            #expect(session.writtenFrames > 0 && session.presentedFrames == session.writtenFrames)
            #expect(session.sourceSeekable == true && (session.sourceDurationMilliseconds ?? 0) >= 8000)
            session.close()
        }
    }

    @MainActor @Test(arguments: ["playback-30sec.mp3", "StreamingFormats/tone-vorbis.ogg", "StreamingFormats/tone-opus.webm"])
    func unsupportedNativeSourceDoesNotCreateTransport(path: String) async throws {
        var outputs = 0
        let factory = try PCMRecoveryFactory(nativeSourceURL: fixture(path), makeTransport: { outputs += 1; return SampleBufferPCMOutputTests.Transport() })
        await #expect(throws: (any Error).self) { try await factory.make(positionMilliseconds: 0, parameters: .init(speed: 1, skipSilence: false)) }
        #expect(outputs == 0)
    }
}
private final class LocalSourceFixtures: NSObject {}
