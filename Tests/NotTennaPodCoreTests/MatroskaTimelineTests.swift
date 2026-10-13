import Foundation
import Testing
@testable import NotTennaPodCore

struct MatroskaTimelineTests {
    @Test func primaryTrackMatchesOriginalJavaAcrossTypesDefaultsAndDeclarationOrder() throws {
        struct Track: Decodable { let number, type: UInt64; let isDefault: Bool }
        struct Case: Decodable { let tracks: [Track]; let primaryTrack: Int64 }
        struct Oracle: Decodable { let reference, media3: String; let cases: [Case] }
        let url = try #require(Bundle.module.url(forResource: "matroska-tracks-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        #expect(oracle.reference == "f8c641887e4677237b01b6e942ff8fe20fc8beec" && oracle.media3 == "1.10.0")
        try #require(oracle.cases.count == 1374)
        for (index, item) in oracle.cases.enumerated() {
            let tracks = item.tracks.reduce(into: Data()) { bytes, value in
                let codec = value.type == 1 ? "V_VP9" : value.type == 2 ? "A_OPUS" : "S_TEXT/UTF8"
                bytes.append(track(value.number, type: value.type, isDefault: value.isDefault, codec: Data(codec.utf8)))
            }
            let cues = item.tracks.reduce(into: Data()) { $0.append(cue(0, track: $1.number)) }
            let timeline = try parse(file(tracks: tracks, cues: cues))
            #expect(timeline.primaryTrack == item.primaryTrack && timeline.isSeekable,
                    Comment(rawValue: "Original Java primary-track case \(index)"))
        }
    }

    private func integer(_ value: UInt64, width: Int = 8) -> Data {
        Data((0..<width).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private func element(_ id: UInt64, _ body: Data, unknown: Bool = false) -> Data {
        let idWidth = max(1, (64 - id.leadingZeroBitCount + 7) / 8)
        // Fixed eight-byte sizes make generated SeekHead offsets independent of values.
        return integer(id, width: idWidth) + integer(unknown ? 0x01FF_FFFF_FFFF_FFFF : UInt64(body.count) | (1 << 56)) + body
    }
    private func uint(_ id: UInt64, _ value: UInt64) -> Data { element(id, integer(value)) }
    private func track(_ number: UInt64, type: UInt64 = 2, isDefault: Bool? = nil, codec: Data = Data("A_OPUS".utf8)) -> Data {
        element(0xAE, uint(0xD7, number) + uint(0x83, type) + element(0x86, codec)
            + (isDefault.map { uint(0x88, $0 ? 1 : 0) } ?? Data()))
    }
    private func cue(_ time: UInt64, track: UInt64 = 1, cluster: UInt64 = 50, relative: UInt64 = 3) -> Data {
        element(0xBB, uint(0xB3, time) + element(0xB7,
            uint(0xF7, track) + uint(0xF1, cluster) + uint(0xF0, relative)))
    }
    private func file(tracks: Data? = nil, duration: Double? = 8008, scale: UInt64? = nil,
                      cues: Data? = nil, placement: Int = 0, unknownSegment: Bool = false) -> Data {
        let info = element(0x1549A966, (duration.map { element(0x4489, integer($0.bitPattern)) } ?? Data())
            + (scale.map { uint(0x2AD7B1, $0) } ?? Data()))
        let tracks = element(0x1654AE6B, tracks ?? track(1))
        let cues = element(0x1C53BB6B, cues ?? cue(0))
        let cluster = element(0x1F43B675, Data(repeating: 0xAA, count: 4096))
        func head(_ offset: UInt64) -> Data {
            element(0x114D9B74, element(0x4DBB, element(0x53AB, integer(0x1C53BB6B, width: 4)) + uint(0x53AC, offset)))
        }
        let seekHead = placement == 0 ? head(UInt64(head(0).count + info.count + tracks.count + cluster.count)) : Data()
        let payload = placement == 2 ? info + tracks + cues + cluster : seekHead + info + tracks + cluster + cues
        return element(0x1A45DFA3, Data()) + element(0x18538067, payload, unknown: unknownSegment)
    }
    private func parse(_ data: Data, fragment: Int = 4096) throws -> MatroskaTimeline {
        try MatroskaTimeline.read { offset, count in
            guard offset < data.count else { return Data() }
            return Data(data[Int(offset)..<min(data.count, Int(offset) + min(count, fragment))])
        }
    }

    @Test(arguments: [1, 7, 4096])
    func originalFixtureUsesDeclaredCuesWithoutReadingClusterPayload(fragment: Int) throws {
        let data = try Data(contentsOf: #require(Bundle.module.url(forResource: "tone-opus.webm", withExtension: nil,
            subdirectory: "Fixtures/StreamingFormats")))
        var offsets: [Int64] = []
        let value = try MatroskaTimeline.read { offset, count in
            offsets.append(offset)
            guard offset < data.count else { return Data() }
            return Data(data[Int(offset)..<min(data.count, Int(offset) + min(count, fragment))])
        }
        #expect(value.durationMicroseconds == 8_008_000 && value.primaryTrack == 1 && value.isSeekable)
        #expect(value.declaredCueOffset == 86250)
        // Independently decoded retained fixture EBML: CueTime, Segment-relative
        // CueClusterPosition and CueRelativePosition. Segment content begins at 48.
        #expect(value.cues[1] == [.init(timeMicroseconds: 0, clusterOffset: 438, relativeOffset: 3),
            .init(timeMicroseconds: 4_981_000, clusterOffset: 51927, relativeOffset: 4)])
        #expect(offsets.allSatisfy { $0 < 450 || $0 >= 86250 })
    }

    @Test(arguments: [0, 1, 2], [false, true])
    func declaredAbsentAndInlineCuesRetainUnknownSegmentSemantics(placement: Int, unknown: Bool) throws {
        let value = try parse(file(placement: placement, unknownSegment: unknown))
        #expect(value.durationMicroseconds == 8_008_000)
        #expect(value.isSeekable == (placement != 1))
        #expect((value.declaredCueOffset != nil) == (placement == 0))
        #expect(value.cues.isEmpty == (placement == 1))
    }

    @Test func durationIsTruncatedBeforeScalingAndMissingDurationPreventsSeeking() throws {
        let value = try parse(file(duration: 2.99, scale: 2_000_000))
        #expect(value.durationMicroseconds == 4000)
        let absent = try parse(file(duration: nil))
        #expect(absent.durationMicroseconds == nil && !absent.cues.isEmpty && !absent.isSeekable)
        let empty = try parse(file(cues: Data()))
        #expect(empty.durationMicroseconds == 8_008_000 && !empty.isSeekable)
    }

    @Test func primaryTrackUsesSortedNumbersDefaultsAndVideoPriority() throws {
        let cues = cue(0, track: 2) + cue(0, track: 7) + cue(0, track: 9)
        let cases: [(Data, Int64)] = [
            (track(9, isDefault: false) + track(2, isDefault: false), 2),
            (track(9) + track(2), 9),
            (track(9) + track(7, type: 1, isDefault: false, codec: Data("V_VP9".utf8)), 7),
            (track(9, type: 1, codec: Data("V_VP9".utf8)) + track(7, type: 1, codec: Data("V_VP9".utf8)), 9),
            (track(2) + track(99, codec: Data("UNSUPPORTED".utf8)), 2),
            (track(2, codec: Data("A_OPUS".utf8) + Data(repeating: 0, count: 8192)), 2)
        ]
        for (tracks, expected) in cases {
            let value = try parse(file(tracks: tracks, cues: cues))
            #expect(value.primaryTrack == expected && value.isSeekable)
        }
        let secondaryOnly = try parse(file(tracks: track(9) + track(2), cues: cue(0, track: 2)))
        #expect(secondaryOnly.primaryTrack == 9 && !secondaryOnly.isSeekable)
    }

    @Test func cueOrderingDuplicateFieldsAndIncompleteEntriesMatchSource() throws {
        let duplicate = element(0xBB, uint(0xB3, 2) + element(0xB7, uint(0xF7, 1)
            + uint(0xF1, 40) + uint(0xF1, 99) + uint(0xF0, 7) + uint(0xF0, 8)))
        let missingTime = element(0xBB, element(0xB7, uint(0xF7, 1) + uint(0xF1, 88)) + uint(0xB3, 1))
        let missingCluster = element(0xBB, uint(0xB3, 1) + element(0xB7, uint(0xF7, 1)))
        let value = try parse(file(cues: cue(3, cluster: 60) + duplicate + cue(2, cluster: 50) + missingTime + missingCluster))
        let points = try #require(value.cues[1])
        #expect(points.map(\.timeMicroseconds) == [2000, 2000, 3000])
        // Both generated root headers use four-byte IDs plus eight-byte sizes.
        #expect(points.map(\.clusterOffset) == [64, 74, 84])
        #expect(points[0].relativeOffset == 7)
    }

    @Test func truncationMalformedHeadersReadErrorsAndCancellationAreVisible() throws {
        #expect(throws: MatroskaTimeline.Failure.malformed) { try parse(Data([0])) }
        #expect(throws: MatroskaTimeline.Failure.truncated) { try parse(Data([0x1A, 0x45])) }
        let invalidChild = element(0x18538067, Data([0xAE, 0xFE]))
        #expect(throws: MatroskaTimeline.Failure.malformed) { try parse(invalidChild) }
        enum ReadFailure: Error { case unavailable }
        #expect(throws: ReadFailure.unavailable) { try MatroskaTimeline.read { _, _ in throw ReadFailure.unavailable } }
        var reads = 0
        #expect(throws: CancellationError.self) {
            try MatroskaTimeline.read(bytes: { _, _ in reads += 1; return Data() },
                checkCancellation: { throw CancellationError() })
        }
        #expect(reads == 0)
    }
}
