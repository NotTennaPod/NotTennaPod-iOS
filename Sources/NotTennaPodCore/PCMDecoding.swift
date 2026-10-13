import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

/// Exact frames are a decoder-level contract. Source playback follows the
/// renderer's whole-output-buffer admission before any presentation splitting.
enum NativeAudioSeekAdmission: Sendable {
    case exactFrame, wholeBuffer

    func admit(_ packet: NativePCMDecoder.Packet, at target: CMTime) -> NativePCMDecoder.Packet? {
        if self == .wholeBuffer { return packet.presentationTime < target ? nil : packet }
        let frame = CMTimeConvertScale(target, timescale: Int32(packet.sampleRate), method: .roundTowardZero).value
        let begin = CMTimeConvertScale(packet.presentationTime, timescale: Int32(packet.sampleRate), method: .roundTowardZero).value
        let skip = min(Int64(packet.frameCount), max(0, frame - begin))
        guard skip < packet.frameCount else { return nil }
        guard skip > 0 else { return packet }
        return NativePCMDecoder.Packet(samples: Array(packet.samples.dropFirst(Int(skip) * packet.channels)),
            sampleRate: packet.sampleRate, channels: packet.channels,
            presentationTime: CMTime(value: begin + skip, timescale: Int32(packet.sampleRate)),
            startsDecodedBuffer: packet.startsDecodedBuffer, discontinuity: packet.discontinuity,
            uneditedTime: packet.uneditedTime.map { $0 + CMTime(value: skip, timescale: Int32(packet.sampleRate)) })
    }
}

/// Internal decoding boundary also allows deterministic lifecycle/control interleavings in tests.
protocol PCMDecoding: Actor {
    nonisolated var sourceStartupTrim: PCMStartupTrim? { get }
    nonisolated var bufferState: PCMBufferState? { get }
    nonisolated var sourceFailure: PCMSourceFailure? { get }
    nonisolated var sourceDurationMilliseconds: Int64? { get }
    nonisolated var sourceSeekable: Bool? { get }
    nonisolated var sampleRate: Int { get }
    nonisolated var channels: Int { get }
    nonisolated var startFrame: Int64 { get }
    nonisolated var startTime: CMTime { get }
    func next() async throws -> NativePCMDecoder.Packet?
    func updatePlayback(_ state: PCMPlaybackLoadState) async throws
    func cancel() async
}

extension PCMDecoding {
    nonisolated var sourceStartupTrim: PCMStartupTrim? { nil }
    nonisolated var sourceDurationMilliseconds: Int64? { bufferState?.snapshot.durationMicroseconds.map { $0 / 1000 } }
    nonisolated var sourceSeekable: Bool? { bufferState?.snapshot.sourceSeekable }
    nonisolated var bufferState: PCMBufferState? { nil }
    func updatePlayback(_ state: PCMPlaybackLoadState) async throws {}
    nonisolated var sourceFailure: PCMSourceFailure? { nil }
    nonisolated var startTime: CMTime { CMTime(value: startFrame, timescale: Int32(sampleRate)) }
}
