import CFFmpegCodec
import Foundation
import Synchronization

/// Copied container facts for the local metadata router. Keep container/track
/// tags and timing separate: selection and Android duration/date conversion are
/// application policy, not an incidental FFmpeg best-stream decision.
struct CodecLocalMetadata: Equatable, Sendable {
    struct Stream: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case audio, video, other }
        let index: Int
        let kind: Kind
        let codec: String
        let tags: [String: String]
        let duration: Int64?
        let timeBaseNumerator, timeBaseDenominator: Int32
        let sampleRate, initialPaddingFrames: Int32
        let attachedPicture: Data?
    }
    let container: String
    let tags: [String: String]
    let durationMicroseconds: Int64?
    let durationEstimatedFromBitrate: Bool
    let streams: [Stream]
}

/// Synchronous metadata fallback for containers in the pinned codec build.
/// Run under LocalFolderDocuments.read; all native/file ownership ends here.
enum CodecLocalMetadataReader {
    enum Failure: Error, Equatable, Sendable {
        case notLocalFile, notRegularFile, invalidOffset, closed, allocation, native(Int32)
    }
    static func read(url: URL, checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> CodecLocalMetadata {
        try checkCancellation()
        guard url.isFileURL else { throw Failure.notLocalFile }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw Failure.notRegularFile }
        return try withoutActuallyEscaping(checkCancellation) { check in
            let input = try Input(url: url, check: check)
            defer { input.close() }
            let io = try FFmpegAVIOInput(input: input)
            return try withExtendedLifetime(io) {
                var context = avformat_alloc_context()
                guard let allocated = context else { throw Failure.allocation }
                defer { avformat_close_input(&context) }
                allocated.pointee.pb = io.context
                allocated.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
                allocated.pointee.interrupt_callback = AVIOInterruptCB(callback: { opaque in
                    guard let opaque else { return 1 }
                    return Unmanaged<Input>.fromOpaque(opaque).takeUnretainedValue().interrupted()
                }, opaque: Unmanaged.passUnretained(input).toOpaque())
                func checked(_ status: Int32) throws {
                    try input.checkFailure()
                    if let failure = io.failure { throw failure }
                    if status < 0 { throw Failure.native(status) }
                }
                // No URL is passed to the codec. All media reads use this owned,
                // bounded callback; sniffing does not depend on the filename.
                try checked(avformat_open_input(&context, nil, nil, nil))
                guard let context else { throw Failure.allocation }
                try checked(avformat_find_stream_info(context, nil))
                func tags(_ dictionary: OpaquePointer?) throws -> [String: String] {
                    var result: [String: String] = [:]
                    var cursor: UnsafeMutablePointer<AVDictionaryEntry>?
                    while let next = av_dict_get(dictionary, "", cursor, AV_DICT_IGNORE_SUFFIX) {
                        try input.checkFailure()
                        result[String(cString: next.pointee.key)] = String(cString: next.pointee.value)
                        cursor = next
                    }
                    return result
                }
                var streams: [CodecLocalMetadata.Stream] = []
                for index in 0..<Int(context.pointee.nb_streams) {
                    try input.checkFailure()
                    guard let stream = context.pointee.streams[index], let parameters = stream.pointee.codecpar else { continue }
                    let kind: CodecLocalMetadata.Stream.Kind = switch parameters.pointee.codec_type {
                    case AVMEDIA_TYPE_AUDIO: .audio
                    case AVMEDIA_TYPE_VIDEO: .video
                    default: .other
                    }
                    var picture: Data?
                    let attached = stream.pointee.attached_pic
                    if stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0,
                       attached.size > 0, let bytes = attached.data {
                        picture = Data(bytes: bytes, count: Int(attached.size))
                    }
                    let duration = stream.pointee.duration
                    streams.append(.init(index: index, kind: kind,
                        codec: String(cString: avcodec_get_name(parameters.pointee.codec_id)),
                        tags: try tags(stream.pointee.metadata), duration: duration >= 0 ? duration : nil,
                        timeBaseNumerator: stream.pointee.time_base.num, timeBaseDenominator: stream.pointee.time_base.den,
                        sampleRate: parameters.pointee.sample_rate, initialPaddingFrames: parameters.pointee.initial_padding,
                        attachedPicture: picture))
                }
                let duration = context.pointee.duration
                let result = CodecLocalMetadata(container: String(cString: context.pointee.iformat.pointee.name),
                    tags: try tags(context.pointee.metadata), durationMicroseconds: duration >= 0 ? duration : nil,
                    durationEstimatedFromBitrate: context.pointee.duration_estimation_method == AVFMT_DURATION_FROM_BITRATE,
                    streams: streams)
                try input.checkFailure()
                return result
            }
        }
    }

    private final class Input: MediaByteInput {
        private struct State { var file: FileHandle?; var failure: (any Error)? }
        private let state: Mutex<State>
        private let count: Int64
        private let check: @Sendable () throws -> Void
        let supportsRandomAccess = true
        var length: Int64? { count }
        init(url: URL, check: @escaping @Sendable () throws -> Void) throws {
            let file = try FileHandle(forReadingFrom: url)
            do {
                guard let count = Int64(exactly: try file.seekToEnd()) else { throw Failure.invalidOffset }
                self.count = count; self.check = check; state = Mutex(State(file: file))
                try check()
            } catch { try? file.close(); throw error }
        }
        func close() { state.withLock { try? $0.file?.close(); $0.file = nil } }
        func prepareForSeek() {}
        func cancel() { record(CancellationError()) }
        func checkFailure() throws {
            if let error = state.withLock({ $0.failure }) { throw error }
            try check()
        }
        func interrupted() -> Int32 {
            do { try checkFailure(); return 0 }
            catch { record(error); return 1 }
        }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            do {
                try checkFailure()
                guard offset >= 0, maximumCount > 0 else { throw Failure.invalidOffset }
                let bytes = try state.withLock { state -> Data in
                    guard let file = state.file else { throw Failure.closed }
                    try file.seek(toOffset: UInt64(offset))
                    return try file.read(upToCount: min(maximumCount, 65_536)) ?? Data()
                }
                try checkFailure()
                return bytes
            } catch { record(error); throw error }
        }
        private func record(_ error: any Error) { state.withLock { if $0.failure == nil { $0.failure = error } } }
    }
}
