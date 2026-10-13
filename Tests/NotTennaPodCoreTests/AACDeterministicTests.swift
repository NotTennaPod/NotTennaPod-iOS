import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct AACDeterministicTests {
    /// A seek into the middle or the last packet of an AAC file (ADTS and MP4) lands within
    /// 0.25 s of the requested position and plays the rest of the file audibly, without gaps.
    /// Sample-identity with a sequential decode is not required.
    @Test(arguments: ["tone.aac", "tone.m4a"], ["middle", "tail"])
    func seekedPlaybackLandsAtTargetAndPlaysRemainder(name: String, point: String) async throws {
        let url = try AACSeekOracle.fixture(name, directory: "AACDeterministic")
        let bytes = try Data(contentsOf: url)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let rate = file.processingFormat.sampleRate
        #expect(file.processingFormat.channelCount == 1)
        let target: Int64 = point == "middle" ? 192017 : file.length - 157
        let remaining = Double(file.length - target)
        let tolerance = rate * 0.05
        let format: NativeAudioSourceTimeline.Format = name == "tone.aac" ? .adts : .mp4
        let timeline = try await NativeAudioSourceTimeline.read(input: Input(bytes), format: format)
        let producer = NativeAudioPacketProducer(input: Input(bytes), timeline: timeline, format: format)
        defer { producer.stop() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !producer.snapshot().exited && ContinuousClock.now < deadline { await Task.yield() }
        try #require(producer.snapshot().exited)
        try producer.sourceFailure.check()
        let time = CMTime(value: target, timescale: Int32(rate))
        let micros = CMTimeConvertScale(time, timescale: 1000000, method: .roundTowardZero).value
        try #require(producer.seek(to: micros))
        let decoder = try await NativeBufferedAudioDecoder.open(producer: producer, ownsProducer: false, start: time)
        #expect(abs(Double(decoder.startFrame - target)) <= rate * 0.25)
        var retained: [Int16] = []
        while let packet = try await decoder.next() {
            #expect(packet.presentationTime == CMTime(value: decoder.startFrame + Int64(retained.count / decoder.channels), timescale: Int32(rate)))
            retained += packet.samples
        }
        #expect(abs(Double(retained.count / decoder.channels) - remaining) <= tolerance)
        #expect(retained.contains { abs(Int($0)) > 64 }, "seeked audio is silent")
        await decoder.cancel()
        producer.stop(); await producer.waitForExit()

        let local = try NativePCMDecoder(url: url, start: time)
        var positionedFile: [Int16] = []
        var first: CMTime?
        while let packet = try await local.next() {
            if first == nil { first = packet.presentationTime }
            positionedFile += packet.samples
        }
        #expect(abs((first ?? .invalid).seconds - time.seconds) <= 0.25)
        #expect(abs(Double(positionedFile.count) - remaining) <= tolerance)
        #expect(positionedFile.contains { abs(Int($0)) > 64 }, "seeked audio is silent")
        await local.cancel()
    }

    private final class Input: MediaByteInput {
        let data: Data
        private let cancelled = Mutex(false)
        init(_ data: Data) { self.data = data }
        var length: Int64? { Int64(data.count) }
        var supportsRandomAccess: Bool { true }
        func prepareForSeek() {}
        func cancel() { cancelled.withLock { $0 = true } }
        func checkFailure() throws { if cancelled.withLock({ $0 }) { throw CancellationError() } }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            try checkFailure()
            guard offset < data.count else { return Data() }
            return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + maximumCount))
        }
    }
}
