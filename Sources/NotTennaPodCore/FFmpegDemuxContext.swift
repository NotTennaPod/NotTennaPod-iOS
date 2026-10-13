import CFFmpegCodec
import CoreMedia
import Foundation

/// One exclusive owner opens/reads/seeks this context. It owns no decoder state.
/// The reader or independent producer owns it; do not mark this mutable context Sendable.
final class FFmpegDemuxContext {
    private var byteIO: FFmpegAVIOInput?
    private var format: UnsafeMutablePointer<AVFormatContext>?
    private(set) var streamIndex: Int32 = -1
    private(set) var timeBase = AVRational(num: 0, den: 1)
    private(set) var containerName = ""
    private(set) var configuration: FFmpegStreamConfiguration?
    private(set) var configurations: [Int32: FFmpegStreamConfiguration] = [:]
    private(set) var mediaMetadata: FFmpegMediaMetadata?
    private var selectedStreamIndices = Set<Int32>()
    var inputPosition: Int64? {
        guard let io = format?.pointee.pb else { return nil }
        let position = avio_tell(io)
        return position >= 0 ? position : nil
    }

    init(url: URL?, byteInput: (any MediaByteInput)? = nil,
         mediaSelection: FFmpegMediaSelection? = nil) throws {
        guard (url != nil) != (byteInput != nil), url?.isFileURL ?? true else {
            throw FFmpegAudioReader.Failure.invalidFormat
        }
        do {
            if let byteInput {
                let io = try FFmpegAVIOInput(input: byteInput)
                byteIO = io
                format = avformat_alloc_context()
                guard let format else { throw FFmpegAudioReader.Failure.allocation }
                format.pointee.pb = io.context
                format.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
            }
            try check(avformat_open_input(&format, url?.path, nil, nil))
            guard let format else { throw FFmpegAudioReader.Failure.allocation }
            try check(avformat_find_stream_info(format, nil))
            guard format.pointee.nb_streams <= 128 else { throw FFmpegAudioReader.Failure.invalidCapacity }
            let audio = mediaSelection?.includeAudio != false
                ? av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, mediaSelection?.audioTrackID ?? -1, -1, nil, 0) : -1
            var video = mediaSelection?.includeVideo == true
                ? av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, mediaSelection?.videoTrackID ?? -1, -1, nil, 0) : -1
            // Album art is metadata, not a timed video presentation track.
            if video >= 0, let candidate = format.pointee.streams[Int(video)],
               candidate.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0 {
                video = -1
                for index in 0..<Int(format.pointee.nb_streams) {
                    guard let stream = format.pointee.streams[index], let params = stream.pointee.codecpar,
                          params.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
                          stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC == 0 else { continue }
                    let playable = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, Int32(index), -1, nil, 0)
                    if playable >= 0 { video = playable; break }
                }
            }
            if let requested = mediaSelection?.audioTrackID, audio != requested { throw FFmpegAudioReader.Failure.invalidFormat }
            if let requested = mediaSelection?.videoTrackID, video != requested { throw FFmpegAudioReader.Failure.invalidFormat }
            streamIndex = audio >= 0 ? audio : video
            try check(streamIndex)
            selectedStreamIndices = Set([audio, video].filter { $0 >= 0 })
            guard let stream = format.pointee.streams[Int(streamIndex)], let parameters = stream.pointee.codecpar else {
                throw FFmpegAudioReader.Failure.invalidFormat
            }
            timeBase = stream.pointee.time_base
            guard timeBase.num > 0, timeBase.den > 0 else { throw FFmpegAudioReader.Failure.invalidFormat }
            containerName = String(cString: format.pointee.iformat.pointee.name)
            let duration = format.pointee.duration
            let sourceDuration = duration >= 0 && format.pointee.duration_estimation_method != AVFMT_DURATION_FROM_BITRATE
                ? duration : nil
            configuration = try FFmpegStreamConfiguration(copying: parameters, timeBase: timeBase,
                containerName: containerName, durationMicroseconds: sourceDuration)
            var tracks: [FFmpegMediaMetadata.Track] = []
            var starts: [CMTime] = []
            for index in 0..<Int(format.pointee.nb_streams) {
                guard let item = format.pointee.streams[index], let params = item.pointee.codecpar else { continue }
                let value = params.pointee, scale = item.pointee.time_base
                guard scale.num > 0, scale.den > 0 else { continue }
                let kind: FFmpegMediaMetadata.Track.Kind = value.codec_type == AVMEDIA_TYPE_AUDIO ? .audio
                    : value.codec_type == AVMEDIA_TYPE_VIDEO && item.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC == 0 ? .video : .other
                if kind != .other, item.pointee.start_time != Int64.min {
                    starts.append(CMTimeMultiplyByRatio(CMTime(value: item.pointee.start_time, timescale: scale.den), multiplier: scale.num, divisor: 1))
                }
                var layout = value.ch_layout
                var layoutText = [CChar](repeating: 0, count: 256)
                if kind == .audio { av_channel_layout_describe(&layout, &layoutText, layoutText.count) }
                let language = av_dict_get(item.pointee.metadata, "language", nil, 0).map { String(cString: $0.pointee.value) }
                let title = av_dict_get(item.pointee.metadata, "title", nil, 0).map { String(cString: $0.pointee.value) }
                let aspect = av_guess_sample_aspect_ratio(format, item, nil)
                let duration = item.pointee.duration
                let durationTime: CMTime? = duration >= 0 && duration != Int64.min
                    ? CMTimeMultiplyByRatio(CMTime(value: duration, timescale: scale.den), multiplier: scale.num, divisor: 1) : nil
                var rotation = 0.0
                if let side = av_packet_side_data_get(value.coded_side_data, value.nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX),
                   side.pointee.size >= 9 * MemoryLayout<Int32>.size {
                    rotation = av_display_rotation_get(UnsafeRawPointer(side.pointee.data).assumingMemoryBound(to: Int32.self))
                    if !rotation.isFinite { rotation = 0 }
                }
                tracks.append(.init(id: Int32(index), kind: kind, codec: String(cString: avcodec_get_name(value.codec_id)),
                    language: language, timeBase: CMTime(value: Int64(scale.num), timescale: scale.den), duration: durationTime,
                    sampleRate: Int(value.sample_rate), channels: Int(value.ch_layout.nb_channels),
                    channelLayout: String(decoding: layoutText.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), width: Int(value.width), height: Int(value.height),
                    pixelAspectRatio: aspect.den > 0 && aspect.num > 0 ? Double(aspect.num) / Double(aspect.den) : 1,
                    rotationDegrees: rotation, decodable: avcodec_find_decoder(value.codec_id) != nil, title: title))
                if selectedStreamIndices.contains(Int32(index)) {
                    configurations[Int32(index)] = try FFmpegStreamConfiguration(copying: params, timeBase: scale,
                        containerName: containerName, durationMicroseconds: sourceDuration,
                        nominalFrameRate: av_guess_frame_rate(format, item, nil))
                }
            }
            mediaMetadata = FFmpegMediaMetadata(timelineOrigin: max(.zero, starts.min() ?? .zero), containerName: containerName, tracks: tracks, selectedAudioTrackID: audio >= 0 ? audio : nil,
                selectedVideoTrackID: video >= 0 ? video : nil,
                duration: sourceDuration.map { CMTime(value: $0, timescale: 1_000_000) },
                sourceSeekable: byteInput?.supportsRandomAccess ?? true)
        } catch { close(); throw error }
    }

    deinit { close() }

    func seekBackward(to timestamp: Int64) throws {
        guard let format else { throw FFmpegAudioReader.Failure.invalidFormat }
        try check(av_seek_frame(format, streamIndex, timestamp, AVSEEK_FLAG_BACKWARD))
    }

    /// Publish the selected declared cluster through FFmpeg's supported index API,
    /// then let its format-specific seek reset parser state. A raw byte seek does
    /// not reset Matroska's private packet/cluster state. Index timestamps must use
    /// the demuxer's codec-delay-adjusted clock to retain the cluster's first packet.
    func seek(to point: MatroskaTimeline.SeekPoint) throws {
        guard let format, let configuration, point.clusterOffset > 0, point.timeMicroseconds >= 0,
              containerName.split(separator: ",").contains("matroska"), configuration.sampleRate > 0,
              let stream = format.pointee.streams[Int(streamIndex)] else { throw FFmpegAudioReader.Failure.invalidSeek }
        let cueTime = av_rescale_q_rnd(point.timeMicroseconds, AVRational(num: 1, den: 1_000_000), timeBase, AV_ROUND_DOWN)
        let delay = av_rescale_q(Int64(max(0, configuration.initialPadding)),
            AVRational(num: 1, den: configuration.sampleRate), timeBase)
        let (timestamp, overflow) = cueTime.subtractingReportingOverflow(delay)
        guard !overflow else { throw FFmpegAudioReader.Failure.invalidSeek }
        try check(av_add_index_entry(stream, point.clusterOffset, timestamp, 0, 0, AVINDEX_KEYFRAME))
        try seekBackward(to: timestamp)
        if inputPosition != point.clusterOffset {
            // The first format seek may parse deferred Cues and replace an equal-
            // timestamp index entry. Restore the source-selected cluster after
            // that one-time parse rather than accepting FFmpeg's duplicate policy.
            try check(av_add_index_entry(stream, point.clusterOffset, timestamp, 0, 0, AVINDEX_KEYFRAME))
            try seekBackward(to: timestamp)
        }
        guard inputPosition == point.clusterOffset else { throw FFmpegAudioReader.Failure.invalidSeek }
    }

    func next() throws -> FFmpegEncodedPacket? {
        guard let format else { throw FFmpegAudioReader.Failure.invalidFormat }
        var packet = av_packet_alloc()
        guard packet != nil else { throw FFmpegAudioReader.Failure.allocation }
        defer { av_packet_free(&packet) }
        while true {
            try Task.checkCancellation()
            let result = av_read_frame(format, packet)
            if let failure = byteIO?.failure { throw failure }
            if result == apCodecEOF() { return nil }
            try check(result)
            guard selectedStreamIndices.contains(packet!.pointee.stream_index) else { av_packet_unref(packet); continue }
            let owned = FFmpegEncodedPacket(taking: packet!)
            packet = nil
            return owned
        }
    }

    private func check(_ result: Int32) throws {
        if let failure = byteIO?.failure { throw failure }
        if result < 0 { throw FFmpegAudioReader.Failure.decoding(result) }
    }

    private func close() {
        avformat_close_input(&format)
        byteIO = nil
    }
}

/// Copied codec parameters, including extradata and channel layout. The immutable
/// descriptor outlives format/AVIO ownership and can create independent codec contexts.
final class FFmpegStreamConfiguration: @unchecked Sendable {
    private var parameters: UnsafeMutablePointer<AVCodecParameters>?
    let timeBase: AVRational
    let containerName: String
    let durationMicroseconds: Int64?
    let nominalFrameRate: AVRational
    var codecID: AVCodecID { parameters!.pointee.codec_id }
    var initialPadding: Int32 { parameters!.pointee.initial_padding }
    var sampleRate: Int32 { parameters!.pointee.sample_rate }
    var seekPreroll: Int32 { parameters!.pointee.seek_preroll }
    var frameSize: Int32 { parameters!.pointee.frame_size }
    var blockAlign: Int32 { parameters!.pointee.block_align }
    var samplesPerBlock: Int32 { av_get_audio_frame_duration2(parameters, blockAlign) }
    var usesIMAByteClock: Bool { codecID == AV_CODEC_ID_ADPCM_IMA_WAV && containerName == "wav" }

    init(copying source: UnsafePointer<AVCodecParameters>, timeBase: AVRational, containerName: String,
         durationMicroseconds: Int64? = nil, nominalFrameRate: AVRational = AVRational(num: 0, den: 1)) throws {
        self.timeBase = timeBase
        self.containerName = containerName
        self.durationMicroseconds = durationMicroseconds
        self.nominalFrameRate = nominalFrameRate
        parameters = avcodec_parameters_alloc()
        guard let parameters else { throw FFmpegAudioReader.Failure.allocation }
        let result = avcodec_parameters_copy(parameters, source)
        if result < 0 {
            avcodec_parameters_free(&self.parameters)
            throw FFmpegAudioReader.Failure.decoding(result)
        }
    }
    deinit { avcodec_parameters_free(&parameters) }

    /// Ownership of a successfully opened context transfers to the caller. No format,
    /// packet or another decoder's mutable state is shared by this operation.
    func makeCodecContext(manualSkip: Bool) throws -> UnsafeMutablePointer<AVCodecContext> {
        guard let codec = avcodec_find_decoder(codecID) else { throw FFmpegAudioReader.Failure.invalidFormat }
        var context = avcodec_alloc_context3(codec)
        guard let opened = context else { throw FFmpegAudioReader.Failure.allocation }
        do {
            let copied = avcodec_parameters_to_context(opened, parameters)
            if copied < 0 { throw FFmpegAudioReader.Failure.decoding(copied) }
            opened.pointee.pkt_timebase = timeBase
            if manualSkip { opened.pointee.flags2 |= AV_CODEC_FLAG2_SKIP_MANUAL }
            let result = avcodec_open2(opened, codec, nil)
            if result < 0 { throw FFmpegAudioReader.Failure.decoding(result) }
            return opened
        } catch { avcodec_free_context(&context); throw error }
    }
}

/// Immutable, reference-counted native packet ownership. Neither the demuxer nor decoder
/// mutates this packet after transfer. FFmpeg send_packet takes its own read-only data ref.
final class FFmpegEncodedPacket: @unchecked Sendable {
    private var packet: UnsafeMutablePointer<AVPacket>?
    init(taking packet: UnsafeMutablePointer<AVPacket>) { self.packet = packet }
    deinit { av_packet_free(&packet) }

    var presentationTimestamp: Int64 { packet!.pointee.pts }
    var streamIndex: Int32 { packet!.pointee.stream_index }
    var decodingTimestamp: Int64 { packet!.pointee.dts }
    var duration: Int64 { packet!.pointee.duration }
    var bytePosition: Int64 { packet!.pointee.pos }
    var encodedByteCount: Int { Int(packet!.pointee.size) }
    var isKeyframe: Bool { packet!.pointee.flags & AV_PKT_FLAG_KEY != 0 }
    var firstByte: UInt8? { encodedByteCount > 0 ? packet!.pointee.data?[0] : nil }
    var secondByte: UInt8? { encodedByteCount > 1 ? packet!.pointee.data?[1] : nil }

    /// The caller exclusively owns the codec context. The packet remains reusable for
    /// another fresh decoder or retained back-buffer read, including all side data.
    func send(to context: UnsafeMutablePointer<AVCodecContext>) -> Int32 { avcodec_send_packet(context, packet) }

    struct Snapshot: Equatable, Sendable {
        struct SideData: Equatable, Sendable { let kind: Int; let bytes: Data }
        let pts, dts, duration, position: Int64
        let flags: Int32
        let payload: Data
        let sideData: [SideData]
    }
    func snapshot() -> Snapshot {
        let value = packet!.pointee
        let sideData = (0..<Int(value.side_data_elems)).map { index in
            let side = value.side_data[index]
            return Snapshot.SideData(kind: Int(side.type.rawValue), bytes: Data(bytes: side.data, count: side.size))
        }
        return Snapshot(pts: value.pts, dts: value.dts, duration: value.duration, position: value.pos,
            flags: value.flags, payload: value.size > 0 ? Data(bytes: value.data!, count: Int(value.size)) : Data(), sideData: sideData)
    }
}
