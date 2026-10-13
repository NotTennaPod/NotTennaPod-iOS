import AudioToolbox
import Foundation
import Synchronization

/// Native facts for the local metadata router. Duration is deliberately not a
/// final episode duration: Android's format-specific metadata rules differ from
/// both Apple's estimate and its valid-frame timeline. See the capability matrix.
public struct NativeLocalAudioMetadata: Equatable, Sendable {
    public struct Format: Equatable, Sendable {
        public let id: UInt32
        public let sampleRate: Double
    }
    public struct PacketTable: Equatable, Sendable {
        public let validFrames: Int64
        public let primingFrames, remainderFrames: Int32
    }
    public enum Property: String, Hashable, Sendable {
        case info, artwork, estimatedDuration, format, packetTable, container
    }
    public let title, recordedDate: String?
    public let artwork: Data?
    public let estimatedDurationSeconds: Double?
    public let format: Format?
    public let packetTable: PacketTable?
    public let container: UInt32?
    /// Preserve native property failures for the router; unavailable is not the
    /// same as a successfully read empty field, especially for embedded artwork.
    public let unavailableProperties: [Property: Int32]
}

/// Must run inside owned/coordinated access on a dedicated I/O queue. All native
/// handles and callbacks finish before returning; no detached asset task escapes.
public enum NativeLocalAudioMetadataReader {
    public enum Failure: Error, Equatable, Sendable {
        case notLocalFile, notRegularFile, invalidOffset, closed, nativeOpen(Int32)
    }

    public static func read(url: URL, checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> NativeLocalAudioMetadata {
        try checkCancellation()
        guard url.isFileURL else { throw Failure.notLocalFile }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw Failure.notRegularFile }
        // A tag AudioFile cannot open in reasonable time is read on the FFmpeg path instead.
        if let probe = try? FileHandle(forReadingFrom: url) {
            defer { try? probe.close() }
            if let length = try? probe.seekToEnd(),
               ID3FrameFlood.floodedFrames(fileDescriptor: probe.fileDescriptor, length: Int64(clamping: length)) != nil {
                throw Failure.nativeOpen(kAudioFileUnsupportedFileTypeError)
            }
        }
        return try withoutActuallyEscaping(checkCancellation) { check in
            let input = try Input(url: url, check: check)
            defer { input.close() }
            var handle: AudioFileID?
            // The owner remains alive through AudioFileClose, including its last
            // possible callback. A read error is retained across C status mapping.
            let status = AudioFileOpenWithCallbacks(Unmanaged.passUnretained(input).toOpaque(),
                { opaque, offset, count, bytes, actual in
                    let input = Unmanaged<Input>.fromOpaque(opaque).takeUnretainedValue()
                    return input.read(offset: offset, count: count, bytes: bytes, actual: actual)
                }, nil, { opaque in
                    Unmanaged<Input>.fromOpaque(opaque).takeUnretainedValue().size()
                }, nil, 0, &handle)
            defer { if let handle { AudioFileClose(handle) } }
            try input.checkFailure()
            guard status == noErr, let handle else { throw Failure.nativeOpen(status) }

            var failures: [NativeLocalAudioMetadata.Property: Int32] = [:]
            func property<Value>(_ key: AudioFilePropertyID, _ name: NativeLocalAudioMetadata.Property,
                                 _ value: inout Value) throws -> Bool {
                try input.checkFailure()
                var size = UInt32(MemoryLayout<Value>.size)
                let status = withUnsafeMutablePointer(to: &value) {
                    AudioFileGetProperty(handle, key, &size, $0)
                }
                try input.checkFailure()
                if status != noErr { failures[name] = status }
                return status == noErr
            }

            var dictionary: Unmanaged<CFDictionary>?
            // Release even if a property call fails after setting an out-value.
            defer { dictionary?.release() }
            let hasInfo = try property(kAudioFilePropertyInfoDictionary, .info, &dictionary)
            let info = hasInfo ? dictionary?.takeUnretainedValue() as? [String: Any] : nil
            var picture: Unmanaged<CFData>?
            defer { picture?.release() }
            let hasPicture = try property(kAudioFilePropertyAlbumArtwork, .artwork, &picture)
            var duration = Float64(0)
            let hasDuration = try property(kAudioFilePropertyEstimatedDuration, .estimatedDuration, &duration)
            var format = AudioStreamBasicDescription()
            let hasFormat = try property(kAudioFilePropertyDataFormat, .format, &format)
            var table = AudioFilePacketTableInfo()
            let hasTable = try property(kAudioFilePropertyPacketTableInfo, .packetTable, &table)
            var container: UInt32 = 0
            let hasContainer = try property(kAudioFilePropertyFileFormat, .container, &container)
            let result = NativeLocalAudioMetadata(title: info?[kAFInfoDictionary_Title] as? String,
                recordedDate: info?[kAFInfoDictionary_RecordedDate] as? String,
                artwork: hasPicture ? picture?.takeUnretainedValue() as Data? : nil,
                estimatedDurationSeconds: hasDuration && duration.isFinite && duration >= 0 ? duration : nil,
                format: hasFormat ? .init(id: format.mFormatID, sampleRate: format.mSampleRate) : nil,
                packetTable: hasTable ? .init(validFrames: table.mNumberValidFrames,
                    primingFrames: table.mPrimingFrames, remainderFrames: table.mRemainderFrames) : nil,
                container: hasContainer ? container : nil, unavailableProperties: failures)
            try input.checkFailure()
            return result
        }
    }

    /// Callback state is synchronized even if the native implementation changes
    /// which thread performs a read. No file or native handle escapes the reader.
    private final class Input: Sendable {
        private struct State { var file: FileHandle?; var failure: (any Error)? }
        private let state: Mutex<State>
        private let length: Int64
        private let check: @Sendable () throws -> Void
        init(url: URL, check: @escaping @Sendable () throws -> Void) throws {
            let file = try FileHandle(forReadingFrom: url)
            do {
                guard let length = Int64(exactly: try file.seekToEnd()) else { throw Failure.invalidOffset }
                self.length = length; self.check = check
                state = Mutex(State(file: file))
                try check()
            } catch { try? file.close(); throw error }
        }
        func close() { state.withLock { try? $0.file?.close(); $0.file = nil } }
        func checkFailure() throws {
            if let error = state.withLock({ $0.failure }) { throw error }
            try check()
        }
        func size() -> Int64 {
            do { try checkFailure(); return length }
            catch { record(error); return 0 }
        }
        func read(offset: Int64, count: UInt32, bytes: UnsafeMutableRawPointer,
                  actual: UnsafeMutablePointer<UInt32>) -> OSStatus {
            actual.pointee = 0
            do {
                try checkFailure()
                guard offset >= 0, !offset.addingReportingOverflow(Int64(count)).overflow else { throw Failure.invalidOffset }
                while actual.pointee < count {
                    try checkFailure()
                    let amount = min(Int(count - actual.pointee), 65_536)
                    let data = try state.withLock { state -> Data in
                        guard let file = state.file else { throw Failure.closed }
                        try file.seek(toOffset: UInt64(offset) + UInt64(actual.pointee))
                        return try file.read(upToCount: amount) ?? Data()
                    }
                    guard !data.isEmpty else { break }
                    data.copyBytes(to: bytes.advanced(by: Int(actual.pointee)).assumingMemoryBound(to: UInt8.self), count: data.count)
                    actual.pointee += UInt32(data.count)
                }
                try checkFailure()
                return noErr
            } catch { record(error); return kAudioFileUnspecifiedError }
        }
        private func record(_ error: any Error) { state.withLock { if $0.failure == nil { $0.failure = error } } }
    }
}
