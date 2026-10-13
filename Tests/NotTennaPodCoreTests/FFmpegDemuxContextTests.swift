import CFFmpegCodec
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct FFmpegDemuxContextTests {
    private static let names = ["tone-vorbis.ogg", "tone-opus.ogg", "tone-opus.webm"]
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
    }

    @Test(arguments: names)
    func queueOwnsCompletePacketsAfterDemuxCloseAndDecoderSend(name: String) throws {
        var demux: FFmpegDemuxContext? = try FFmpegDemuxContext(url: fixture(name))
        weak var observedDemux = demux
        let configuration = try #require(demux?.configuration)

        var queue = EncodedAudioQueue<FFmpegEncodedPacket>()
        var expected: [FFmpegEncodedPacket.Snapshot] = []
        weak var firstPacket: FFmpegEncodedPacket?
        while let packet = try demux?.next() {
            if expected.isEmpty { firstPacket = packet }
            expected.append(packet.snapshot())
            let time = av_rescale_q(packet.presentationTimestamp, try #require(demux).timeBase,
                AVRational(num: 1, den: 1_000_000))
            try queue.append(packet, encodedByteCount: packet.encodedByteCount,
                timestampMicroseconds: time, isKeyframe: packet.isKeyframe)
        }
        try #require(!expected.isEmpty)
        if name.contains("opus") { #expect(expected.contains { !$0.sideData.isEmpty }) }
        demux = nil
        #expect(observedDemux == nil && firstPacket != nil)
        // Construct the decoder only after closing the format: its extradata/channel
        // layout must also have independent ownership, not just the queued packets.
        var context: UnsafeMutablePointer<AVCodecContext>? = try configuration.makeCodecContext(manualSkip: false)
        var frame = av_frame_alloc()
        defer { av_frame_free(&frame); avcodec_free_context(&context) }
        let decoder = try #require(context), output = try #require(frame)
        var decodedFrames = 0
        func receive() throws {
            while true {
                let result = avcodec_receive_frame(decoder, output)
                if result == apCodecAgain() || result == apCodecEOF() { return }
                try #require(result == 0)
                decodedFrames += Int(output.pointee.nb_samples)
                av_frame_unref(output)
            }
        }
        for snapshot in expected {
            let packet = try #require(queue.next()?.packet)
            #expect(packet.snapshot() == snapshot)
            try #require(packet.send(to: decoder) == 0)
            try receive()
            #expect(packet.snapshot() == snapshot) // Includes native side-data bytes and flags.
        }
        try #require(avcodec_send_packet(decoder, nil) == 0)
        try receive()
        #expect(abs(decodedFrames - 384_000) <= 2400) // Eight seconds, complete to within 50 ms.
        #expect(queue.unreadCount == 0 && queue.retainedCount == expected.count)
        queue.reset()
        #expect(firstPacket == nil)
    }
}
