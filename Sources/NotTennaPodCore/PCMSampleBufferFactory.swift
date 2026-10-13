import CoreAudio
import CoreMedia
import Foundation

/// Immutable, bounded packaging for Apple's sample-buffer receiver. Processing has already
/// happened upstream; timestamps describe the output PCM timeline at its natural sample rate.
public struct PCMSampleBufferFactory: Sendable {
    public enum Failure: Error, Equatable { case invalidFormat, invalidCapacity, invalidFrames, invalidTimestamp }
    public let sampleRate: Int
    public let channels: Int
    public let maximumFrames: Int
    public let formatDescription: CMAudioFormatDescription

    /// Playback presents mono or stereo: decoders downmix more than two channels with their
    /// speaker layout (`PCMStereoDownmix`). Larger counts here have no
    /// speaker meaning and keep discrete channel order.
    public init(sampleRate: Int, channels: Int, maximumFrames: Int = 65_536) throws {
        guard (1...768_000).contains(sampleRate), (1...32).contains(channels) else { throw Failure.invalidFormat }
        guard (1...65_536).contains(maximumFrames) else { throw Failure.invalidCapacity }
        self.sampleRate = sampleRate
        self.channels = channels
        self.maximumFrames = maximumFrames
        let tag = channels == 1 ? kAudioChannelLayoutTag_Mono : channels == 2
            ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        let layout = ManagedAudioChannelLayout(tag: tag)
        let description = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: UInt32(channels * 2), mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 2),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
        formatDescription = try CMAudioFormatDescription(audioStreamBasicDescription: description, layout: layout)
    }

    public func makeBuffer(_ samples: [Int16], outputStartFrame: Int64) throws -> CMReadySampleBuffer<CMReadOnlyDataBlockBuffer> {
        guard !samples.isEmpty, samples.count.isMultiple(of: channels), samples.count / channels <= maximumFrames else {
            throw Failure.invalidFrames
        }
        let frames = samples.count / channels
        guard outputStartFrame >= 0, !outputStartFrame.addingReportingOverflow(Int64(frames)).overflow else {
            throw Failure.invalidTimestamp
        }
        let data = samples.withUnsafeBytes { Data($0) }
        return CMReadySampleBuffer(audioDataBuffer: CMReadOnlyDataBlockBuffer(data), formatDescription: formatDescription,
            sampleCount: frames, presentationTimeStamp: CMTime(value: outputStartFrame, timescale: Int32(sampleRate)))
    }
}
