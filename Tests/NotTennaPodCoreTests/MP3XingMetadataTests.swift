import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct MP3XingMetadataTests {
    @Test(arguments: [1, 7, 137, 4096])
    func fragmentedHeadersAndLargeID3BodiesPreserveDeclaredPadding(chunkSize: Int) throws {
        // MPEG2 mono header,144kbps/22050Hz:470-byte frame. Counts mirror
        // source generation (0.7 seconds =15435 samples) and its LAME fields.
        let frame = makeFrame(flags: 15)
        var body = Data(repeating: 0, count: 16_384)
        body.replaceSubrange(71..<75, with: Data("Xing".utf8))
        let tag = Data([0x49, 0x44, 0x33, 4, 0, 0, 0, 1, 0, 0]) + body
        var probe = MP3XingMetadata()
        let input = tag + tag + frame
        for offset in stride(from: 0, to: input.count, by: chunkSize) {
            probe.append(input.subdata(in: offset..<min(input.count, offset + chunkSize)))
        }
        let padding = try #require(probe.padding)
        #expect(probe.isFinished)
        #expect(padding.sampleRate == 22050 && padding.channels == 1)
        #expect(padding.encodedFrames == 16704 && padding.leading == 576 && padding.trailing == 693)
        probe.append(Data(repeating: 255, count: 32768))
        #expect(probe.padding?.leading == 576)
    }

    @Test(arguments: [UInt32(1), 3, 5, 9, 15])
    func optionalXingFieldsLocateEncoderExtension(flags: UInt32) throws {
        var probe = MP3XingMetadata()
        probe.append(makeFrame(flags: flags))
        #expect(probe.padding?.leading == 576 && probe.padding?.trailing == 693)
    }

    @Test func absentMalformedOrIncompleteMetadataCannotInventPadding() {
        var incomplete = MP3XingMetadata()
        incomplete.append(makeFrame(flags: 15).prefix(160))
        #expect(incomplete.padding == nil && !incomplete.isFinished)
        var malformed = MP3XingMetadata()
        var frame = makeFrame(flags: 15)
        // Declares one packet but padding exceeds its576 samples.
        frame.replaceSubrange(21..<25, with: Data([0, 0, 0, 1]))
        malformed.append(frame)
        #expect(malformed.padding == nil && malformed.isFinished)
        var absent = MP3XingMetadata()
        frame = makeFrame(flags: 15)
        frame.replaceSubrange(13..<17, with: Data([0, 0, 0, 0]))
        absent.append(frame)
        #expect(absent.padding == nil && absent.isFinished)
        var id3 = MP3XingMetadata()
        id3.append(Data([0x49, 0x44, 0x33, 4, 0, 0, 255, 0, 0, 0]) + frame)
        #expect(id3.padding == nil && id3.isFinished)
    }

    @Test(arguments: [UInt32(1), 3, 15], [1, 4096])
    func infoFrameCountIsExplicitAndBounded(flags: UInt32, chunk: Int) throws {
        var frame = makeFrame(flags: flags)
        frame.replaceSubrange(13..<17, with: Data("Info".utf8))
        var probe = MP3XingMetadata()
        for offset in stride(from: 0, to: frame.count, by: chunk) {
            probe.append(frame.subdata(in: offset..<min(offset + chunk, frame.count)))
        }
        let count = try #require(probe.infoFrames)
        #expect(count.encodedFrames == 29 * 576 && count.sampleRate == 22050 && count.channels == 1)
    }

    @Test(arguments: 0..<5)
    func missingOrInvalidInfoCountCannotReplaceNativeMetadata(scenario: Int) {
        var frame = makeFrame(flags: 15)
        frame.replaceSubrange(13..<17, with: Data("Info".utf8))
        switch scenario {
        case 0: frame[20] &= 0xfe
        case 1: frame.replaceSubrange(21..<25, with: Data(repeating: 0, count: 4))
        case 2: frame.replaceSubrange(21..<25, with: Data([128, 0, 0, 0]))
        case 3: frame.replaceSubrange(13..<17, with: Data("Xing".utf8))
        default: frame = Data(frame.prefix(24))
        }
        var probe = MP3XingMetadata(); probe.append(frame)
        #expect(probe.infoFrames == nil)
    }

    private func makeFrame(flags: UInt32) -> Data {
        var data = Data(repeating: 0, count: 470)
        data.replaceSubrange(0..<4, with: Data([0xff, 0xf3, 0xd0, 0xc0]))
        data.replaceSubrange(13..<17, with: Data("Xing".utf8))
        data[20] = UInt8(flags)
        var position = 21
        if flags & 1 != 0 { data[position + 3] = 29; position += 4 }
        if flags & 2 != 0 { position += 4 }
        if flags & 4 != 0 { position += 100 }
        if flags & 8 != 0 { position += 4 }
        position += 21
        data[position] = 0x24; data[position + 1] = 0x02; data[position + 2] = 0xb5
        return data
    }
}
