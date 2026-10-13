import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

struct PCMSampleBufferFactoryTests {
    @Test(arguments: [8000, 44100, 48000, 96000], [1, 2, 6, 32])
    func sampleBytesChannelsAndRationalTimestampsArePreserved(rate: Int, channels: Int) throws {
        let factory = try PCMSampleBufferFactory(sampleRate: rate, channels: channels)
        let input = (0..<257 * channels).map { Int16(truncatingIfNeeded: $0 * 997 - 32768) }
        let packet = try factory.makeBuffer(input, outputStartFrame: 3001)
        #expect(packet.sampleCount == 257)
        #expect(packet.totalSampleSize == input.count * 2)
        #expect(packet.presentationTimeStamp == CMTime(value: 3001, timescale: Int32(rate)))
        #expect(packet.outputPresentationTimeStamp == packet.presentationTimeStamp)
        #expect(packet.duration == CMTime(value: 257, timescale: Int32(rate)))
        #expect(packet.outputDuration == packet.duration)
        let expectedBytes = input.withUnsafeBytes { Data($0) }
        let actualBytes = try #require(packet.content.withContiguousStorageIfAvailable { Data($0) })
        #expect(actualBytes == expectedBytes)
        // Independent native conversion back into PCM verifies the format description,
        // sample sizing and channel order, not just the backing byte array.
        let tag = channels == 1 ? kAudioChannelLayoutTag_Mono : channels == 2
            ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        let layout = try #require(AVAudioChannelLayout(layoutTag: tag))
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate), interleaved: true, channelLayout: layout)
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 257))
        output.frameLength = 257
        try packet.copyPCMData(fromRange: 0..<257, into: output.mutableAudioBufferList)
        let actual = Array(UnsafeBufferPointer(start: output.int16ChannelData![0], count: input.count))
        #expect(actual == input)
    }

    @Test func processedPacketsKeepContiguousOutputTimeAndAudibleContent() async throws {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let stream = try LocalPCMPlaybackStream(url: url, skipSilence: true, speed: 1.5, maximumOutputFrames: 127)
        let factory = try PCMSampleBufferFactory(sampleRate: stream.sampleRate, channels: stream.channels, maximumFrames: 127)
        var renderedBytes = Data()
        var time = CMTime.zero
        while let packet = try await stream.nextPacket() {
            let buffer = try factory.makeBuffer(packet.samples, outputStartFrame: packet.outputStartFrame)
            #expect(buffer.presentationTimeStamp == time)
            time = time + buffer.duration
            let bytes = try #require(buffer.content.withContiguousStorageIfAvailable { Data($0) })
            renderedBytes.append(bytes)
        }
        var silence = try SilenceSkippingProcessor(sampleRate: 48000, channels: 2)
        let shortened = try silence.process(input) + silence.finish()
        var speed = try PCMSpeedProcessor(sampleRate: 48000, channels: 2, speed: 1.5)
        let expected = try speed.process(shortened) + speed.finish()
        // Gap-free timestamps (checked per packet above) and the same audible result as
        // processing the whole input at once; sample identity is not required.
        PCMTestFixture.expectAudiblyEquivalent(renderedBytes, expected.withUnsafeBytes { Data($0) })
        #expect(abs(time.seconds - Double(expected.count / 2) / 48000) <= 0.05)
    }
}
