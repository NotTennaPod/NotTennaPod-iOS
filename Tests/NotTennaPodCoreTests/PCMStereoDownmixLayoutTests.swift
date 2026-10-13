import CFFmpegCodec
import Foundation
import Testing
@testable import NotTennaPodCore

/// FFmpeg channel layouts in the stereo downmix. SwiftPM only: these use the codec module
/// directly, which the app's test target does not import.
@Suite struct PCMStereoDownmixLayoutTests {
    private func gains(_ downmix: PCMStereoDownmix) -> [(Float, Float)] { downmix.gains.map { ($0.left, $0.right) } }
    private func layout(_ name: String) throws -> AVChannelLayout {
        var layout = AVChannelLayout()
        try #require(av_channel_layout_from_string(&layout, name) == 0)
        return layout
    }

    @Test func matrixFollowsTheLayoutWithSideAndBackSharing() throws {
        let c = Float(SurroundDownmixTests.c)
        for (name, expected) in [("5.1", [(1, 0), (0, 1), (c, c), (0, 0), (c, 0), (0, c)]),
                                 ("5.1(side)", [(1, 0), (0, 1), (c, c), (0, 0), (c, 0), (0, c)]),
                                 ("7.1", [(1, 0), (0, 1), (c, c), (0, 0), (c * c, 0), (0, c * c), (c * c, 0), (0, c * c)])] as [(String, [(Float, Float)])] {
            var value = try layout(name)
            defer { av_channel_layout_uninit(&value) }
            #expect(SurroundDownmixTests.same(gains(try #require(PCMStereoDownmix(ffmpeg: value))), expected), "\(name)")
        }
        // Mono and stereo are not downmixed.
        for name in ["mono", "stereo"] {
            var value = try layout(name)
            defer { av_channel_layout_uninit(&value) }
            #expect(PCMStereoDownmix(ffmpeg: value) == nil)
        }
    }

    @Test func partlyKnownLayoutKeepsItsPositionsAndOnlyAnUnspecifiedOneGetsTheDefault() throws {
        // [FR, FL, FC, LFE, SL, unknown]: right-only content stays right; the unknown channel is silent.
        var custom = AVChannelLayout()
        try #require(av_channel_layout_custom_init(&custom, 6) == 0)
        defer { av_channel_layout_uninit(&custom) }
        for (index, channel) in [AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_CENTER,
                                 AV_CHAN_LOW_FREQUENCY, AV_CHAN_SIDE_LEFT, AV_CHAN_UNKNOWN].enumerated() {
            custom.u.map[index].id = channel
        }
        try #require(av_channel_layout_check(&custom) == 1)
        let partial = try #require(PCMStereoDownmix(ffmpeg: custom))
        #expect([Int16]([10_000, 0, 0, 0, 0, 0]).withUnsafeBufferPointer { partial.apply($0) } == [0, 10_000])
        #expect([Int16]([0, 0, 0, 0, 0, 10_000]).withUnsafeBufferPointer { partial.apply($0) } == [0, 0])
        // No position at all (custom, every channel unknown; or an unspecified order): FFmpeg's default for the count.
        var standard = try layout("5.1")
        defer { av_channel_layout_uninit(&standard) }
        let expected = gains(try #require(PCMStereoDownmix(ffmpeg: standard)))
        var unknown = AVChannelLayout()
        try #require(av_channel_layout_custom_init(&unknown, 6) == 0)
        defer { av_channel_layout_uninit(&unknown) }
        #expect(SurroundDownmixTests.same(gains(try #require(PCMStereoDownmix(ffmpeg: unknown))), expected))
        var unspecified = AVChannelLayout(order: AV_CHANNEL_ORDER_UNSPEC, nb_channels: 6, u: .init(mask: 0), opaque: nil)
        #expect(SurroundDownmixTests.same(gains(try #require(PCMStereoDownmix(ffmpeg: unspecified))), expected))
        _ = withUnsafeMutablePointer(to: &unspecified) { $0 }
    }

    @Test func countWithoutAPositionOrADefaultLayoutIsUnsupported() throws {
        var unknown = AVChannelLayout()
        try #require(av_channel_layout_custom_init(&unknown, 9) == 0)
        defer { av_channel_layout_uninit(&unknown) }
        #expect(PCMStereoDownmix(ffmpeg: unknown) == nil)
    }
}
