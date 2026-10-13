import AVFoundation
import Foundation

/// Decoded PCM of a later raw ADTS segment in the presentation's format, so
/// everything downstream keeps one format:
/// a two-channel segment in a mono presentation is mixed to mono, a mono one is
/// copied to both channels, and another sample rate is resampled by Apple's
/// converter, which is drained when the segment ends. A higher-rate segment loses
/// what lies above half the presentation's rate. Caller-confined.
final class NativeAudioSegmentNormalizer {
    private let channels: Int, outputChannels: Int
    private let resampler: AVAudioConverter?
    private let ratio: Double

    init(sampleRate: Int, channels: Int, outputSampleRate: Int, outputChannels: Int) throws {
        guard sampleRate > 0, outputSampleRate > 0, (1...2).contains(channels), (1...2).contains(outputChannels) else {
            throw NativeAudioStreamParser.Failure.invalidFormat
        }
        self.channels = channels; self.outputChannels = outputChannels
        ratio = Double(outputSampleRate) / Double(sampleRate)
        if sampleRate == outputSampleRate { resampler = nil; return }
        guard let input = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate),
                  channels: AVAudioChannelCount(outputChannels), interleaved: true),
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(outputSampleRate),
                  channels: AVAudioChannelCount(outputChannels), interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else { throw NativeAudioStreamParser.Failure.invalidFormat }
        resampler = converter
    }

    func process(_ samples: [Int16]) throws -> [Int16] { try resample(mixed(samples), ending: false) }
    func finish() throws -> [Int16] { try resample([], ending: true) }

    private func mixed(_ samples: [Int16]) -> [Int16] {
        if channels == outputChannels { return samples }
        if outputChannels == 2 {
            return [Int16](unsafeUninitializedCapacity: samples.count * 2) { buffer, count in
                for (index, sample) in samples.enumerated() { buffer[2 * index] = sample; buffer[2 * index + 1] = sample }
                count = samples.count * 2
            }
        }
        return [Int16](unsafeUninitializedCapacity: samples.count / 2) { buffer, count in
            for index in 0..<(samples.count / 2) {
                buffer[index] = Int16((Int32(samples[2 * index]) + Int32(samples[2 * index + 1])) >> 1)
            }
            count = samples.count / 2
        }
    }

    private func resample(_ samples: [Int16], ending: Bool) throws -> [Int16] {
        guard let resampler else { return samples }
        var pending: AVAudioPCMBuffer?
        if !samples.isEmpty {
            let frames = samples.count / outputChannels
            guard let buffer = AVAudioPCMBuffer(pcmFormat: resampler.inputFormat, frameCapacity: AVAudioFrameCount(frames)),
                  let data = buffer.int16ChannelData?[0] else { throw NativeAudioStreamParser.Failure.invalidCapacity }
            buffer.frameLength = AVAudioFrameCount(frames)
            samples.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: samples.count) }
            pending = buffer
        }
        var result: [Int16] = []
        let capacity = AVAudioFrameCount(Double(samples.count / outputChannels) * ratio) + 4096
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: resampler.outputFormat, frameCapacity: capacity) else {
                throw NativeAudioStreamParser.Failure.invalidCapacity
            }
            var error: NSError?
            let status = resampler.convert(to: output, error: &error) { _, state in
                if let buffer = pending { pending = nil; state.pointee = .haveData; return buffer }
                state.pointee = ending ? .endOfStream : .noDataNow
                return nil
            }
            if let error { throw error }
            if output.frameLength > 0, let data = output.int16ChannelData?[0] {
                result += UnsafeBufferPointer(start: data, count: Int(output.frameLength) * outputChannels)
            }
            switch status {
            case .haveData: continue
            case .inputRanDry, .endOfStream: return result
            case .error: throw NativeAudioStreamParser.Failure.invalidFormat
            @unknown default: throw NativeAudioStreamParser.Failure.invalidFormat
            }
        }
    }
}
