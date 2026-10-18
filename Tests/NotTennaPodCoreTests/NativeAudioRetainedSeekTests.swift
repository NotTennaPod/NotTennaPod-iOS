import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct NativeAudioRetainedSeekTests {
    static let names = ["tone.wav", "tone.aac", "tone.m4a", "tone.flac"]
    private func fixture(_ name: String) throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
#else
        try #require(Bundle(for: RetainedNativeFixtures.self).url(forResource: name, withExtension: nil))
#endif
    }
    private func kind(_ name: String) -> NativeAudioSourceTimeline.Format {
        name.hasSuffix("wav") ? .wav : name.hasSuffix("aac") ? .adts : name.hasSuffix("m4a") ? .mp4 : .flac
    }
    private func baseline(_ name: String) throws -> (samples: [Int16], rate: Int, channels: Int) {
        let file = try AVAudioFile(forReading: fixture(name), commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var result: [Int16] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, file.length - file.framePosition)))
            try #require(buffer.frameLength > 0)
            result += Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * Int(file.processingFormat.channelCount)))
        }
        return (result, Int(file.processingFormat.sampleRate), Int(file.processingFormat.channelCount))
    }
    private func collect(_ decoder: NativeBufferedAudioDecoder) async throws -> [Int16] {
        var result: [Int16] = []
        while let packet = try await decoder.next() {
            #expect(packet.presentationTime == CMTime(value: decoder.startFrame + Int64(result.count / decoder.channels), timescale: Int32(decoder.sampleRate)))
            result += packet.samples
        }
        return result
    }
    private func wait(_ predicate: @Sendable () -> Bool) async throws {
        let limit = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < limit {
            if predicate() { return }
            await Task.yield()
        }
        try #require(predicate())
    }

    @Test(arguments: names)
    func seeksInLoadedAudioLandOnTargetAndPlayRemainingAudio(name: String) async throws {
        let data = try Data(contentsOf: fixture(name)), source = Input(data)
        let timeline = try await NativeAudioSourceTimeline.read(input: Input(data), format: kind(name))
        let producer = NativeAudioPacketProducer(input: source, timeline: timeline, format: kind(name))
        defer { producer.stop() }
        try await wait { producer.snapshot().exited }
        try producer.sourceFailure.check()
        let expected = try baseline(name)
        let lossless = name.hasSuffix("wav") || name.hasSuffix("flac")
        let totalFrames = expected.samples.count / expected.channels
        let targets = [Int64(0), Int64(expected.rate * 4 + 17), Int64(1), Int64(totalFrames - 157), Int64(expected.rate * 10)]
        for target in targets {
            let time = CMTime(value: target, timescale: Int32(expected.rate))
            let microseconds = CMTimeConvertScale(time, timescale: 1000000, method: .roundTowardZero).value
            try #require(producer.seek(to: microseconds), "\(name): seek to loaded target \(target) was refused")
            let decoder = try await NativeBufferedAudioDecoder.open(producer: producer, ownsProducer: false, start: time)
            #expect(abs(decoder.startFrame - target) <= Int64(expected.rate / 4))
            #expect(decoder.channels == expected.channels && decoder.sampleRate == expected.rate)
            let actual = try await collect(decoder)
            let tail = Array(expected.samples.dropFirst(min(Int(decoder.startFrame), totalFrames) * expected.channels))
            let matches = lossless ? actual == tail
                : AudibleMatch.matches(actual, tail, channels: expected.channels, sampleRate: expected.rate)
            #expect(matches, "\(name) target=\(target): seek tail differs")
            await decoder.cancel()
        }
    }

    private final class Input: MediaByteInput {
        let bytes: Data
        private let stopped = Mutex(false)
        init(_ bytes: Data) { self.bytes = bytes }
        var length: Int64? { Int64(bytes.count) }
        var supportsRandomAccess: Bool { true }
        var cancelled: Bool { stopped.withLock { $0 } }
        func prepareForSeek() {}
        func checkFailure() throws { if cancelled { throw CancellationError() } }
        func cancel() { stopped.withLock { $0 = true } }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            try checkFailure()
            guard offset < bytes.count else { return Data() }
            return bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + maximumCount))
        }
    }
}
private final class RetainedNativeFixtures: NSObject {}
