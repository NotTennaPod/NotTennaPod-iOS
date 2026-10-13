import AudioToolbox
import Foundation

/// Layered AAC exposes a core format and richer playable SBR/PS formats.
/// Use AudioToolbox's supported format selection before choosing PCM geometry.
enum NativeAudioFormatSelection {
    static func stream(_ stream: AudioFileStreamID, fallback: AudioStreamBasicDescription) throws -> AudioStreamBasicDescription {
        try select(fallback: fallback, info: { size in
            AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_FormatList, &size, nil)
        }, read: { size, bytes in
            AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_FormatList, &size, bytes)
        })
    }
    static func file(_ file: AudioFileID, fallback: AudioStreamBasicDescription) throws -> AudioStreamBasicDescription {
        try select(fallback: fallback, info: { size in
            AudioFileGetPropertyInfo(file, kAudioFilePropertyFormatList, &size, nil)
        }, read: { size, bytes in
            AudioFileGetProperty(file, kAudioFilePropertyFormatList, &size, bytes)
        })
    }
    static func frames(_ count: Int64, from sourceRate: Double, to outputRate: Double) throws -> Int64 {
        guard count >= 0, sourceRate.isFinite, outputRate.isFinite,
              sourceRate > 0, outputRate > 0, sourceRate <= 768000, outputRate <= 768000,
              sourceRate.rounded(.towardZero) == sourceRate, outputRate.rounded(.towardZero) == outputRate,
              let result = Int64(exactly: Int128(count) * Int128(Int64(outputRate)) / Int128(Int64(sourceRate))) else {
            throw NativeAudioStreamParser.Failure.invalidFormat
        }
        return result
    }
    private static func select(fallback: AudioStreamBasicDescription,
                               info: (inout UInt32) -> OSStatus,
                               read: (inout UInt32, UnsafeMutableRawPointer) -> OSStatus) throws -> AudioStreamBasicDescription {
        guard fallback.mFormatID == kAudioFormatMPEG4AAC else { return fallback }
        var size: UInt32 = 0
        let status = info(&size)
        if status == kAudioFileUnsupportedPropertyError || status == kAudioFileStreamError_UnsupportedProperty { return fallback }
        guard status == noErr else { throw NativeAudioStreamParser.Failure.native(status) }
        let stride = MemoryLayout<AudioFormatListItem>.stride
        guard size > 0, size <= 65536, Int(size) % stride == 0 else { throw NativeAudioStreamParser.Failure.invalidFormat }
        var formats = [AudioFormatListItem](repeating: .init(), count: Int(size) / stride)
        let capacity = size
        let readStatus = formats.withUnsafeMutableBytes { read(&size, $0.baseAddress!) }
        guard readStatus == noErr else { throw NativeAudioStreamParser.Failure.native(readStatus) }
        guard size > 0, size <= capacity, Int(size) % stride == 0 else { throw NativeAudioStreamParser.Failure.invalidFormat }
        var selected: UInt32 = 0, indexSize = UInt32(MemoryLayout<UInt32>.size)
        let selectionStatus = formats.withUnsafeBytes {
            AudioFormatGetProperty(kAudioFormatProperty_FirstPlayableFormatFromList, size, $0.baseAddress!, &indexSize, &selected)
        }
        guard selectionStatus == noErr else { throw NativeAudioStreamParser.Failure.native(selectionStatus) }
        guard indexSize == MemoryLayout<UInt32>.size, selected < Int(size) / stride else { throw NativeAudioStreamParser.Failure.invalidFormat }
        return formats[Int(selected)].mASBD
    }
}
