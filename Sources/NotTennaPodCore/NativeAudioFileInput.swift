import AudioToolbox
import Darwin
import Foundation

/// Read-only content access without a filename hint. The AudioFile and any
/// ExtAudioFile wrapper must close before releasing this callback owner.
final class NativeAudioFileInput {
    private let file: FileHandle?
    private let input: (any MediaByteInput)?
    private let indexedReads: Bool
    private var lastReadEnd: Int64?
    private(set) var failure: (any Error)?
    private(set) var bytesRead: Int64 = 0
    private let length: Int64
    /// Tag frames AudioFile is shown as padding (`ID3FrameFlood`); local files only.
    private var floodedFrames: Range<Int64>?
    private(set) var audioFile: AudioFileID!

    init(url: URL) throws {
        guard url.isFileURL else { throw NativePCMDecoder.Failure.notLocal }
        let file = try FileHandle(forReadingFrom: url)
        self.file = file
        input = nil
        indexedReads = false
        var info = stat()
        guard fstat(file.fileDescriptor, &info) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        length = info.st_size
        floodedFrames = ID3FrameFlood.floodedFrames(fileDescriptor: file.fileDescriptor, length: info.st_size)
        try open()
    }

    /// Random-access native files require an actual extent. Unknown-length
    /// streaming must use an incremental reader, never a fabricated file size.
    init(input: any MediaByteInput, indexedReads: Bool = false) throws {
        guard let length = input.length, length > 0 else { throw NativePCMDecoder.Failure.invalidFormat }
        self.input = input
        self.indexedReads = indexedReads
        file = nil
        self.length = length
        try open()
    }

    private func open() throws {
        let status = AudioFileOpenWithCallbacks(Unmanaged.passUnretained(self).toOpaque(), { context, offset, count, buffer, actual in
            guard offset >= 0 else { return kAudio_ParamError }
            let owner = Unmanaged<NativeAudioFileInput>.fromOpaque(context).takeUnretainedValue()
            actual.pointee = 0
            if let file = owner.file {
                var readCount: Int
                repeat { readCount = pread(file.fileDescriptor, buffer, Int(count), offset) } while readCount < 0 && errno == EINTR
                guard readCount >= 0 else { return kAudioFileUnspecifiedError }
                ID3FrameFlood.mask(owner.floodedFrames, buffer: buffer, offset: offset, count: readCount)
                actual.pointee = UInt32(readCount)
                owner.bytesRead = Int64(clamping: Int128(owner.bytesRead) + Int128(readCount))
                return noErr
            }
            guard let input = owner.input else { return kAudioFileUnspecifiedError }
            do {
                try input.checkFailure()
                // Native AudioFile owns the verified index and supplies actual
                // byte origins, including MP4 where PacketToByte is unavailable.
                // Retire a held sequential transfer only at a discontinuous
                // callback; contiguous packet reads keep normal bounded loading.
                if owner.indexedReads && owner.lastReadEnd != offset {
                    input.prepareForIndexedSeek(to: offset)
                }
                // A native callback may request more than the byte-input contract.
                // Fill it with bounded reads and stop only at its actual EOF.
                while actual.pointee < count {
                    let position = offset.addingReportingOverflow(Int64(actual.pointee))
                    guard !position.overflow else { return kAudio_ParamError }
                    let remaining = min(Int64(count - actual.pointee), max(0, owner.length - position.partialValue))
                    guard remaining > 0 else { break }
                    let data = try input.read(at: position.partialValue, maximumCount: Int(min(65_536, remaining)))
                    guard !data.isEmpty else { throw MediaDownloadError.wrongSize(expected: owner.length, received: position.partialValue) }
                    guard data.count <= remaining else { return kAudio_ParamError }
                    data.withUnsafeBytes { bytes in
                        buffer.advanced(by: Int(actual.pointee)).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
                    }
                    actual.pointee += UInt32(data.count)
                    owner.bytesRead = Int64(clamping: Int128(owner.bytesRead) + Int128(data.count))
                }
                owner.lastReadEnd = offset + Int64(actual.pointee)
                return noErr
            } catch {
                owner.failure = error
                return kAudioFileUnspecifiedError
            }
        }, nil, { context in
            return Unmanaged<NativeAudioFileInput>.fromOpaque(context).takeUnretainedValue().length
        }, nil, 0, &audioFile)
        if let failure { throw failure }
        try Self.check(status)
        guard audioFile != nil else { throw NativePCMDecoder.Failure.invalidFormat }
    }
    func close() {
        if let audioFile { AudioFileClose(audioFile); self.audioFile = nil }
        try? file?.close()
    }
    deinit { close() }

    func fileType() throws -> AudioFileTypeID {
        var result: AudioFileTypeID = 0, size = UInt32(MemoryLayout<AudioFileTypeID>.size)
        try Self.check(AudioFileGetProperty(audioFile, kAudioFilePropertyFileFormat, &size, &result))
        return result
    }
    func strings(_ property: AudioFilePropertyID) throws -> [String] {
        var type = try fileType(), values: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        let status = AudioFileGetGlobalInfo(property, UInt32(MemoryLayout<AudioFileTypeID>.size), &type, &size, &values)
        let result = values?.takeRetainedValue() as? [String]
        try Self.check(status)
        return result ?? []
    }
    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
