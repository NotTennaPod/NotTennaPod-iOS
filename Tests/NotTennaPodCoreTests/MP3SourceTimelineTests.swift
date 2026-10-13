import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct MP3SourceTimelineTests {
    private func fixture(_ name: String) throws -> Data {
#if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: name, withExtension: "mp3", subdirectory: "Fixtures")!
#else
        let url = Bundle(for: MP3TimelineFixtures.self).url(forResource: name, withExtension: "mp3")!
#endif
        return try Data(contentsOf: url)
    }
    private func frame(_ data: Data, chunk: Int = 137) throws -> MP3XingMetadata.SourceFrame {
        var metadata = MP3XingMetadata(retainSourceFrame: true)
        for offset in stride(from: 0, to: data.count, by: chunk) {
            metadata.append(data.subdata(in: offset..<min(data.count, offset + chunk)))
        }
        let captured = metadata.takeSourceFrame()
        return try #require(captured)
    }
    /// Durations and seek times only need to be right to a human: within 50 ms for a
    /// displayed duration, within 0.25 s for a seek point.
    private func near(_ actual: Int64?, _ expected: Int64?, within tolerance: Int64 = 50_000) -> Bool {
        switch (actual, expected) {
        case (nil, nil): true
        case let (a?, e?): abs(a - e) <= tolerance
        default: false
        }
    }

    // Generated from the original Java methods.
    private static let seekOracle: [[Int64]] = [
        [0, 0, 0, 0, 45, -1, -1, 0],
        [0, 1, 44, 0, 45, 26000, 149, 0],
        [0, 100000, 45, 78000, 357, 104000, 461, 0],
        [0, 104482, 149, 104000, 461, 130000, 565, 26000],
        [0, 208964, 416, 208000, 877, 234000, 981, 92750],
        [0, 299999, 417, 286000, 1189, 312000, 1293, 93000],
        [0, 300000, 418, 286000, 1189, 312000, 1293, 93250],
        [0, 313446, 617, 312000, 1293, 338000, 1397, 143000],
        [0, 500000, 1017, 494000, 2021, 520000, 2125, 243000],
        [0, 1000000, 90056, 988000, 3997, 1014000, 4101, 22502750],
        [0, 10000000, 90065, 9984000, 39981, 10010000, 40085, 22505000],
        [0, 22500000, 119599, 22490000, 90005, 22516000, 90109, 29888500],
        [0, 29900000, 119645, 29874000, 119541, -1, -1, 29900000],
        [0, 30040793, 120016, 29874000, 119541, -1, -1, 29992750],
        [0, 60000000, 125000, 29874000, 119541, -1, -1, 31238750],
        [1, 0, 0, 0, 417, -1, -1, 0],
        [1, 1, 44, 1, 417, -1, -1, 0],
        [1, 100000, 45, 100000, 417, -1, -1, 0],
        [1, 104482, 149, 104482, 417, -1, -1, 0],
        [1, 208964, 416, 208964, 652, -1, -1, 0],
        [1, 299999, 417, 299999, 936, -1, -1, 0],
        [1, 300000, 418, 300000, 936, -1, -1, 133922],
        [1, 313446, 617, 313446, 999, -1, -1, 197680],
        [1, 500000, 1017, 500000, 1872, -1, -1, 317359],
        [1, 1000000, 90056, 1000000, 4059, -1, -1, 22539832],
        [1, 10000000, 90065, 10000000, 39786, -1, -1, 22541754],
        [1, 22500000, 119599, 22500000, 89870, -1, -1, 29951511],
        [1, 29900000, 119645, 29900000, 119358, -1, -1, 29961336],
        [1, 30040793, 120016, 30040793, 120016, -1, -1, 30040579],
        [1, 60000000, 125000, 30040793, 120016, -1, -1, 31105128],
        [2, 0, 0, 0, 417, -1, -1, 0],
        [2, 1, 44, 0, 417, 104482, 617, 0],
        [2, 100000, 45, 0, 417, 104482, 617, 0],
        [2, 104482, 149, 104482, 617, -1, -1, 0],
        [2, 208964, 416, 208964, 1017, -1, -1, 0],
        [2, 299999, 417, 208964, 1017, -1, -1, 0],
        [2, 300000, 418, 208964, 1017, -1, -1, 0],
        [2, 313446, 617, 208964, 1017, -1, -1, 104482],
        [2, 500000, 1017, 208964, 1017, -1, -1, 208964],
        [2, 1000000, 90056, 208964, 1017, -1, -1, 208964],
        [2, 10000000, 90065, 208964, 1017, -1, -1, 208964],
        [2, 22500000, 119599, 208964, 1017, -1, -1, 208964],
        [2, 29900000, 119645, 208964, 1017, -1, -1, 208964],
        [2, 30040793, 120016, 208964, 1017, -1, -1, 208964],
        [2, 60000000, 125000, 208964, 1017, -1, -1, 208964],
    ]
    @Test(arguments: 0..<45)
    func byteMappingMatchesOriginalJava(caseIndex: Int) throws {
        let row = Self.seekOracle[caseIndex]
        let data: Data
        if row[0] == 0 { data = Data(repeating: 0, count: 45) + (try fixture("playback-unknown-duration")) }
        else if row[0] == 1 { data = try fixture("playback-30sec") }
        else {
            var header = Data(try fixture("playback-30sec").prefix(417))
            header.replaceSubrange(21..<25, with: Data(repeating: 0, count: 4))
            header.replaceSubrange(36..<40, with: Data("VBRI".utf8))
            header.replaceSubrange(50..<54, with: Data([0, 0, 0, 12]))
            header.replaceSubrange(54..<65, with: Data([0, 3, 0, 2, 0, 1, 0, 4, 100, 200, 50]))
            data = header
        }
        let header = try frame(data)
        let first = row[0] == 0 ? Data(data.dropFirst(45)) : Data(data.dropFirst(header.bytes.count))
        let timeline = try MP3SourceTimeline(frame: header, firstAudioBytes: first, declaredLength: Int64(data.count))
        let map = try #require(timeline.byteIndex)
        // Seek points agree with Android's within 0.25 s (1000 bytes is 0.25 s at these fixtures' 32 kbps).
        let points = map.points(at: row[1])
        #expect(near(points.first.timeMicroseconds, row[3], within: 250_000) && near(points.first.bytePosition, row[4], within: 1000))
        #expect(near(points.second?.timeMicroseconds, row[5] == -1 ? nil : row[5], within: 250_000))
        #expect(near(points.second?.bytePosition, row[6] == -1 ? nil : row[6], within: 1000))
        #expect(near(map.time(at: row[2]), row[7], within: 250_000))
    }

    @Test func invalidXingIndexKeepsSafeSequentialFallback() throws {
        var data = try fixture("playback-30sec")
        data[60] = 0 // A backwards table entry cannot locate a monotonic timeline.
        let header = try frame(data)
        let timeline = try MP3SourceTimeline(frame: header, firstAudioBytes: Data(data.dropFirst(417)), declaredLength: nil)
        #expect(timeline.seekable && timeline.byteIndex == nil)
        let bounded = MP3SeekIndex.constant(start: Int64.max - 50, end: .max, bitrate: 32_000, frameSize: 104)
        #expect(bounded.points(at: .max).first.bytePosition == Int64.max - 50)
        #expect(bounded.points(at: .max).second == nil)
    }

    @Test(arguments: ["playback-30sec", "playback-vbr-stereo", "playback-vbr-low-rate"], [false, true])
    func xingTimelineDoesNotUseTrimmedAudioOrRequireHTTPSize(name: String, knownLength: Bool) throws {
        let data = try fixture(name), header = try frame(data)
        let expected: Int64 = name == "playback-30sec" ? 30_040_793 : name == "playback-vbr-stereo" ? 743_979 : 757_505
        let result = try MP3SourceTimeline(frame: header, firstAudioBytes: Data(data.dropFirst(header.bytes.count)),
            declaredLength: knownLength ? Int64(data.count) : nil)
        #expect(near(result.durationMicroseconds, expected) && result.seekable)
    }

    @Test(arguments: [false, true])
    func plainCBRUsesOriginalDeclaredLength(knownLength: Bool) throws {
        let data = try fixture("playback-unknown-duration"), header = try frame(data)
        #expect(header.bitrate == 32_000 && header.offset == 0)
        let result = try MP3SourceTimeline(frame: header, firstAudioBytes: data,
            declaredLength: knownLength ? 119_600 : nil)
        #expect(result.seekable == knownLength)
        #expect(near(result.durationMicroseconds, knownLength ? 29_900_000 : nil))
    }

    @Test(arguments: [false, true], [false, true])
    func infoAndMissingXingTableUseEnabledAverageBitrateFallback(info: Bool, knownLength: Bool) throws {
        var data = try fixture("playback-30sec")
        if info { data.replaceSubrange(21..<25, with: Data("Info".utf8)) }
        else { data[28] = 3 } // Frames and byte size, no table.
        let header = try frame(data)
        let result = try MP3SourceTimeline(frame: header, firstAudioBytes: Data(data.dropFirst(417)),
            declaredLength: knownLength ? Int64(data.count + 9000) : nil)
        // Source chooses metadata byte size over HTTP trailing bytes (the extra 9000 bytes would add ~2 s).
        #expect(result.seekable && near(result.durationMicroseconds, 30_040_816))
    }

    @Test(arguments: [false, true])
    func missingByteSizeAndTableFallsBackToAudioHeader(knownLength: Bool) throws {
        var data = try fixture("playback-30sec")
        data[28] = 1 // Frame count only: no byte size, no table.
        let header = try frame(data)
        let result = try MP3SourceTimeline(frame: header, firstAudioBytes: Data(data.dropFirst(417)),
            declaredLength: knownLength ? Int64(data.count) : nil)
        #expect(result.seekable == knownLength)
        // Known size uses enhanced CBR; unknown size uses the first actual audio
        // frame's32kbps bitrate, with unknown duration and no seek map.
        #expect(near(result.durationMicroseconds, knownLength ? 30_040_816 : nil))
    }

    @Test(arguments: [1, 137, 4096])
    func leadingTagsAndJunkAreExcludedFromCBRDuration(chunk: Int) throws {
        let audio = try fixture("playback-unknown-duration")
        let body = Data(repeating: 0, count: 16_384)
        let tag = Data([0x49, 0x44, 0x33, 4, 0, 0, 0, 1, 0, 0]) + body
        let data = tag + tag + Data(repeating: 0, count: 5) + audio
        let header = try frame(data, chunk: chunk)
        #expect(header.offset == 32_793)
        let result = try MP3SourceTimeline(frame: header, firstAudioBytes: audio, declaredLength: Int64(data.count))
        #expect(near(result.durationMicroseconds, 29_900_000) && result.seekable)
    }

    @Test func vbriTableProvidesDurationAndMalformedTableIsRejected() throws {
        var data = Data(try fixture("playback-30sec").prefix(417))
        data.replaceSubrange(21..<25, with: Data(repeating: 0, count: 4))
        data.replaceSubrange(36..<40, with: Data("VBRI".utf8))
        data.replaceSubrange(50..<54, with: Data([0, 0, 0, 12]))
        data.replaceSubrange(54..<62, with: Data([0, 2, 0, 1, 0, 2, 0, 6]))
        let result = try MP3SourceTimeline(frame: frame(data), firstAudioBytes: data, declaredLength: nil)
        #expect(result.seekable && near(result.durationMicroseconds, 313_446))
        data.replaceSubrange(54..<56, with: Data([0xff, 0xff]))
        let malformed = try frame(data)
        #expect(throws: MP3SourceTimeline.Failure.invalidMetadata) {
            try MP3SourceTimeline(frame: malformed, firstAudioBytes: data, declaredLength: nil)
        }
    }
}
private final class MP3TimelineFixtures: NSObject {}
