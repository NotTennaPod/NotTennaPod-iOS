import AVFoundation
import AudioToolbox
import CFFmpegCodec
import Foundation

/// Stereo playback of more than two decoded channels (5.1 is played as
/// stereo). Positions come from the source's actual
/// channel layout, never from the channel count when a layout exists:
///   Lo = k(L + c·C + c·Ls),  Ro = k(R + c·C + c·Rs),  c = 1/√2, LFE omitted,
/// back channels treated as surrounds, and each at c/√2 when side and back are
/// both present. k = 1 is provisional: derived from AOSP's stereo downmix
/// (system/media audio_utils ChannelMix.h, android-15/16: front at unity, centre
/// at 1/√2, no normalisation), not measured on Android; overloads clamp to full
/// scale, as the device output does. This downmix deliberately differs from that
/// matrix: LFE omitted (ChannelMix 0.5), side and back each 0.5 when both are
/// present (ChannelMix 1/√2 each), and an Int16 clamp at full scale where
/// ChannelMix clamps its float mix at ±√2. Other positions use ChannelMix's
/// coefficients; a position this matrix does not know contributes nothing, as
/// ChannelMix ignores positions it does not map. Only a stream with no channel
/// positions at all gets FFmpeg's default layout for its channel count (6 = L, R,
/// C, LFE, Ls, Rs); a count without a default is unsupported (nil).
struct PCMStereoDownmix: Equatable, Sendable {
    enum Speaker: Equatable, Sendable {
        case frontLeft, frontRight, frontCenter, lowFrequency, sideLeft, sideRight, backLeft, backRight, backCenter
        case frontLeftOfCenter, frontRightOfCenter, wideLeft, wideRight
        case topFrontLeft, topFrontCenter, topFrontRight, topCenter, topSideLeft, topSideRight
        case topBackLeft, topBackCenter, topBackRight
    }
    static let centre: Float = 0.70710678
    let inputChannels: Int
    /// Per input channel: its gain into the left and the right output.
    let gains: [(left: Float, right: Float)]

    static func == (a: Self, b: Self) -> Bool {
        a.inputChannels == b.inputChannels && a.gains.elementsEqual(b.gains) { $0.left == $1.left && $0.right == $1.right }
    }

    /// nil: a position this matrix does not know (no contribution).
    init(speakers: [Speaker?]) {
        let c = Self.centre
        // Side and back surrounds both present (two on a side) share it.
        let left: Float = speakers.filter { $0 == .sideLeft || $0 == .backLeft }.count > 1 ? c * c : c
        let right: Float = speakers.filter { $0 == .sideRight || $0 == .backRight }.count > 1 ? c * c : c
        inputChannels = speakers.count
        gains = speakers.map { speaker in
            switch speaker {
            case .frontLeft, .topFrontLeft: (1, 0)
            case .frontRight, .topFrontRight: (0, 1)
            case .frontCenter, .topFrontCenter: (c, c)
            case .lowFrequency: (0, 0)
            case .sideLeft, .backLeft: (left, 0)
            case .sideRight, .backRight: (0, right)
            case .backCenter: (0.5, 0.5)
            case .wideLeft, .topBackLeft: (c, 0)
            case .wideRight, .topBackRight: (0, c)
            case .topSideLeft: (0.6057043428, 0)
            case .topSideRight: (0, 0.6057043428)
            case .frontLeftOfCenter: (0.6057043428, 0.2508909536)
            case .frontRightOfCenter: (0.2508909536, 0.6057043428)
            case .topCenter: (0.3552343859, 0.3552343859)
            case .topBackCenter: (0.3543928915, 0.3543928915)
            case nil: (0, 0)
            }
        }
    }

    /// Interleaved input frames to interleaved stereo frames.
    func apply(_ samples: UnsafeBufferPointer<Int16>) -> [Int16] {
        let frames = samples.count / inputChannels
        var result = [Int16](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            var left: Float = 0, right: Float = 0
            for (channel, gain) in gains.enumerated() {
                let value = Float(samples[frame * inputChannels + channel])
                left += value * gain.left; right += value * gain.right
            }
            result[frame * 2] = Int16(max(-32768, min(32767, left.rounded())))
            result[frame * 2 + 1] = Int16(max(-32768, min(32767, right.rounded())))
        }
        return result
    }

    /// FFmpeg's layout positions; without any (an unspecified order), its
    /// default layout for the channel count.
    init?(ffmpeg layout: AVChannelLayout) {
        var layout = layout
        let count = Int(layout.nb_channels)
        guard count > 2 else { return nil }
        let speakers = layout.order == AV_CHANNEL_ORDER_UNSPEC ? []
            : (0..<count).map { Self.speaker(av_channel_layout_channel_from_index(&layout, UInt32($0))) }
        if speakers.contains(where: { $0 != nil }) { self.init(speakers: speakers); return }
        guard let fallback = Self.defaultSpeakers(count) else { return nil }
        self.init(speakers: fallback)
    }

    /// Core Audio channel labels (a decoder's output layout); without any
    /// positional label (none, or discrete), FFmpeg's default for the count.
    init?(labels: [AudioChannelLabel]?, channels: Int) {
        guard channels > 2 else { return nil }
        if let labels, labels.count == channels, Self.isPositional(labels) { self.init(speakers: labels.map(Self.speaker)); return }
        guard let fallback = Self.defaultSpeakers(channels) else { return nil }
        self.init(speakers: fallback)
    }

    /// At least one label names a position this matrix knows.
    static func isPositional(_ labels: [AudioChannelLabel]?) -> Bool { labels?.contains { speaker($0) != nil } == true }

    /// FFmpeg's default layout for a channel count, if it has one with positions.
    private static func defaultSpeakers(_ count: Int) -> [Speaker?]? {
        var layout = AVChannelLayout()
        av_channel_layout_default(&layout, Int32(count))
        defer { av_channel_layout_uninit(&layout) }
        let speakers = (0..<count).map { speaker(av_channel_layout_channel_from_index(&layout, UInt32($0))) }
        return layout.order == AV_CHANNEL_ORDER_NATIVE && speakers.contains { $0 != nil } ? speakers : nil
    }

    /// A Core Audio layout in any form (descriptions, bitmap or tag).
    init?(layout: AVAudioChannelLayout, channels: Int) {
        self.init(labels: Self.labels(layout), channels: channels)
    }

    static func labels(_ layout: AVAudioChannelLayout) -> [AudioChannelLabel]? {
        func descriptions(_ pointer: UnsafePointer<AudioChannelLayout>) -> [AudioChannelLabel] {
            let count = Int(pointer.pointee.mNumberChannelDescriptions)
            let first = UnsafeRawPointer(pointer).advanced(by: MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!)
                .assumingMemoryBound(to: AudioChannelDescription.self)
            return (0..<count).map { first[$0].mChannelLabel }
        }
        if layout.layoutTag == kAudioChannelLayoutTag_UseChannelDescriptions { return descriptions(layout.layout) }
        var bitmap = layout.layout.pointee.mChannelBitmap, tag = layout.layoutTag
        let byBitmap = tag == kAudioChannelLayoutTag_UseChannelBitmap
        let property = byBitmap ? kAudioFormatProperty_ChannelLayoutForBitmap : kAudioFormatProperty_ChannelLayoutForTag
        return withUnsafeMutableBytes(of: &bitmap) { bitmapBytes in
            withUnsafeMutableBytes(of: &tag) { tagBytes in
                let specifier = byBitmap ? bitmapBytes : tagBytes
                var size: UInt32 = 0
                guard AudioFormatGetPropertyInfo(property, UInt32(specifier.count), specifier.baseAddress, &size) == noErr,
                      size >= UInt32(MemoryLayout<AudioChannelLayout>.size) else { return nil }
                let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
                defer { raw.deallocate() }
                guard AudioFormatGetProperty(property, UInt32(specifier.count), specifier.baseAddress, &size, raw) == noErr else { return nil }
                return descriptions(raw.assumingMemoryBound(to: AudioChannelLayout.self))
            }
        }
    }

    private static func speaker(_ channel: AVChannel) -> Speaker? {
        switch channel {
        case AV_CHAN_FRONT_LEFT: .frontLeft
        case AV_CHAN_FRONT_RIGHT: .frontRight
        case AV_CHAN_FRONT_CENTER: .frontCenter
        case AV_CHAN_LOW_FREQUENCY, AV_CHAN_LOW_FREQUENCY_2: .lowFrequency
        case AV_CHAN_SIDE_LEFT, AV_CHAN_SURROUND_DIRECT_LEFT: .sideLeft
        case AV_CHAN_SIDE_RIGHT, AV_CHAN_SURROUND_DIRECT_RIGHT: .sideRight
        case AV_CHAN_BACK_LEFT: .backLeft
        case AV_CHAN_BACK_RIGHT: .backRight
        case AV_CHAN_BACK_CENTER: .backCenter
        case AV_CHAN_FRONT_LEFT_OF_CENTER: .frontLeftOfCenter
        case AV_CHAN_FRONT_RIGHT_OF_CENTER: .frontRightOfCenter
        case AV_CHAN_WIDE_LEFT: .wideLeft
        case AV_CHAN_WIDE_RIGHT: .wideRight
        case AV_CHAN_TOP_FRONT_LEFT, AV_CHAN_BOTTOM_FRONT_LEFT: .topFrontLeft
        case AV_CHAN_TOP_FRONT_CENTER, AV_CHAN_BOTTOM_FRONT_CENTER: .topFrontCenter
        case AV_CHAN_TOP_FRONT_RIGHT, AV_CHAN_BOTTOM_FRONT_RIGHT: .topFrontRight
        case AV_CHAN_TOP_CENTER: .topCenter
        case AV_CHAN_TOP_SIDE_LEFT: .topSideLeft
        case AV_CHAN_TOP_SIDE_RIGHT: .topSideRight
        case AV_CHAN_TOP_BACK_LEFT: .topBackLeft
        case AV_CHAN_TOP_BACK_CENTER: .topBackCenter
        case AV_CHAN_TOP_BACK_RIGHT: .topBackRight
        default: nil
        }
    }

    private static func speaker(_ label: AudioChannelLabel) -> Speaker? {
        switch label {
        case kAudioChannelLabel_Left: .frontLeft
        case kAudioChannelLabel_Right: .frontRight
        case kAudioChannelLabel_Center: .frontCenter
        case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2: .lowFrequency
        // Core Audio's surround labels: 5.1 layouts name one pair LeftSurround,
        // 7.1 adds RearSurround or SurroundDirect; any two on a side share.
        case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftSurroundDirect: .sideLeft
        case kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightSurroundDirect: .sideRight
        case kAudioChannelLabel_RearSurroundLeft: .backLeft
        case kAudioChannelLabel_RearSurroundRight: .backRight
        case kAudioChannelLabel_CenterSurround: .backCenter
        case kAudioChannelLabel_LeftCenter: .frontLeftOfCenter
        case kAudioChannelLabel_RightCenter: .frontRightOfCenter
        case kAudioChannelLabel_LeftWide: .wideLeft
        case kAudioChannelLabel_RightWide: .wideRight
        case kAudioChannelLabel_VerticalHeightLeft: .topFrontLeft
        case kAudioChannelLabel_VerticalHeightCenter: .topFrontCenter
        case kAudioChannelLabel_VerticalHeightRight: .topFrontRight
        case kAudioChannelLabel_TopCenterSurround: .topCenter
        case kAudioChannelLabel_TopBackLeft: .topBackLeft
        case kAudioChannelLabel_TopBackCenter: .topBackCenter
        case kAudioChannelLabel_TopBackRight: .topBackRight
        default: nil
        }
    }
}
