import AVFoundation
import Foundation
import Testing
@testable import NotTennaPodCore

/// Independent expected PCM for AAC: Apple's sequential file decode, cut at `target`
/// (frames). Used by PlaybackProcessedSelectionTests. The former seek diagnostics in
/// this file were removed: they decoded
/// through the former NativeRemotePCMDecoder (never used by the app), or repeated
/// NativeAudioIndexedPacketTests/NativeAACProfileTests exactly.
struct PCNativeAACOracle {
    func sequential(_ url: URL, target: Int64) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        let channels = Int(file.processingFormat.channelCount)
        var result = [Int16]()
        while file.framePosition < file.length {
            let first = file.framePosition
            try file.read(into: buffer, frameCount: UInt32(min(4096, file.length - first)))
            try #require(buffer.frameLength > 0)
            let skip = Int(min(Int64(buffer.frameLength), max(0, target - first)))
            result += UnsafeBufferPointer(start: buffer.int16ChannelData![0] + skip * channels, count: (Int(buffer.frameLength) - skip) * channels)
        }
        return result
    }
}
