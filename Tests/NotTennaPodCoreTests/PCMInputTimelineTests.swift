import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

struct PCMInputTimelineTests {
    @Test func matchesOriginalJavaAcrossTimestampAndDrainBoundaries() throws {
        struct Oracle: Decodable {
            struct Operation: Decodable {
                let reset: Bool?
                let rate: Int
                let pts: Int64?
                let frames: Int?
                let force: Bool?
                let canDrain: Bool?
                let accepted: Bool?
                let drained: Bool?
                let anchor: Int64?
                let submitted: Int64?
            }
            let operations: [Operation]
        }
#if SWIFT_PACKAGE
        let url = try #require(Bundle.module.url(forResource: "pcm-input-timeline", withExtension: "json", subdirectory: "Fixtures"))
#else
        let url = try #require(Bundle(for: InputTimelineFixtures.self).url(forResource: "pcm-input-timeline", withExtension: "json"))
#endif
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        var timeline = try PCMInputTimeline(sampleRate: 48_000)
        var attempts = 0
        for op in oracle.operations {
            if op.reset == true { timeline = try PCMInputTimeline(sampleRate: op.rate); continue }
            let pts = try #require(op.pts)
            let force = try #require(op.force as Bool?)
            let before = timeline.submittedFrames
            let decision = try timeline.boundary(presentationMicroseconds: pts, discontinuity: force)
            #expect(decision.requiresDrain == op.drained)
            #expect(timeline.submittedFrames == before)
            let accept = !decision.requiresDrain || op.canDrain == true
            #expect(accept == op.accepted)
            if accept {
                try timeline.submit(presentationMicroseconds: pts, frames: #require(op.frames), discontinuity: force)
            }
            #expect(timeline.anchorMicroseconds == op.anchor)
            #expect(timeline.submittedFrames == op.submitted)
            attempts += 1
        }
        #expect(attempts == 592)
    }
}

/// Deterministic raw decoder boundaries for testing transport/processor ordering.
actor TimestampPCMDecoder: PCMDecoding {
    nonisolated let sampleRate = 48_000
    nonisolated let channels = 1
    nonisolated let startFrame: Int64
    nonisolated let startTime: CMTime
    private var packets: [NativePCMDecoder.Packet]
    private var cancelled = false

    init(_ packets: [NativePCMDecoder.Packet]) {
        self.packets = packets
        startTime = packets.first?.presentationTime ?? .zero
        startFrame = CMTimeConvertScale(startTime, timescale: 48_000, method: .roundTowardZero).value
    }
    func next() throws -> NativePCMDecoder.Packet? {
        guard !cancelled else { throw NativePCMDecoder.Failure.cancelled }
        return packets.isEmpty ? nil : packets.removeFirst()
    }
    func cancel() { cancelled = true; packets.removeAll() }
}

struct PCMDiscontinuityTests {
    private func processed(_ samples: [Int16], speed: Float, silence: Bool) throws -> [Int16] {
        var skipper = silence ? try SilenceSkippingProcessor(sampleRate: 48_000, channels: 1) : nil
        var sonic = speed == 1 ? nil : try PCMSpeedProcessor(sampleRate: 48_000, channels: 1, speed: speed)
        let input = try skipper?.process(samples) ?? samples
        var result = try sonic?.process(input) ?? input
        let tail = skipper?.finish() ?? []
        result += try sonic?.process(tail) ?? tail
        result += sonic?.finish() ?? []
        return result
    }

    @Test(arguments: [Float(0.5), 1, 1.5, 4], [false, true])
    func discontinuityDrainsBothProcessorsBeforeNewTimestamp(speed: Float, silence: Bool) async throws {
        // Short silence tail exercises buffered silence, while the varying signal exercises Sonic.
        let old = (0..<3500).map { Int16(($0 * 97) % 20000 - 10000) } + [Int16](repeating: 0, count: 1500)
        let new = [Int16](repeating: 0, count: 1500) + (0..<3500).map { Int16(($0 * 103) % 20000 - 10000) }
        let decoder = TimestampPCMDecoder([
            .init(samples: old, sampleRate: 48_000, channels: 1, presentationTime: CMTime(value: 1, timescale: 1_000_000)),
            .init(samples: new, sampleRate: 48_000, channels: 1, presentationTime: CMTime(value: 1_000_001, timescale: 1_000_000))
        ])
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: silence, speed: speed, maximumOutputFrames: 127)
        var packets: [LocalPCMPlaybackStream.Packet] = []
        while let packet = try await stream.nextPacket() { packets.append(packet) }
        let first = try #require(packets.first)
        let changed = try #require(packets.first { $0.segment.id != first.segment.id })
        let before = packets.filter { $0.segment.id == first.segment.id }
        let after = packets.filter { $0.segment.id == changed.segment.id }
        #expect(before.count + after.count == packets.count)
        #expect(try before.flatMap(\.samples) == processed(old, speed: speed, silence: silence))
        #expect(try after.flatMap(\.samples) == processed(new, speed: speed, silence: silence))
        #expect(first.segment.mediaStartMicroseconds == 1)
        #expect(changed.segment.mediaStartMicroseconds == 1_000_001)
        #expect(changed.outputStartFrame == Int64(before.reduce(0) { $0 + $1.samples.count }))
        #expect(changed.segment.parameters == first.segment.parameters)
    }

    @Test func forcedDiscontinuityAndParameterChangeShareOneDrain() async throws {
        let samples = [Int16](repeating: 6000, count: 4096)
        let decoder = TimestampPCMDecoder([
            .init(samples: samples, sampleRate: 48_000, channels: 1, presentationTime: .zero),
            .init(samples: samples, sampleRate: 48_000, channels: 1,
                  presentationTime: CMTime(value: 90_001, timescale: 1_000_000), discontinuity: true)
        ])
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: false, speed: 0.5, maximumOutputFrames: 127)
        let first = try #require(await stream.nextPacket())
        try await stream.setParameters(speed: 2, skipSilence: true)
        var packets = [first]
        while let packet = try await stream.nextPacket() { packets.append(packet) }
        let after = packets.filter { $0.segment.id != first.segment.id }
        #expect(Set(packets.map { $0.segment.id }).count == 2)
        #expect(try packets.filter { $0.segment.id == first.segment.id }.flatMap(\.samples) == processed(samples, speed: 0.5, silence: false))
        #expect(try after.flatMap(\.samples) == processed(samples, speed: 2, silence: true))
        #expect(try #require(after.first).segment.mediaStartMicroseconds == 90_001)
    }

    @Test @MainActor func shownPositionFollowsTimestampJumpWhenItIsHeard() async throws {
        let decoder = TimestampPCMDecoder([
            .init(samples: [Int16](repeating: 6000, count: 4800), sampleRate: 48_000, channels: 1,
                  presentationTime: CMTime(value: 1, timescale: 1_000_000)),
            .init(samples: [Int16](repeating: 6000, count: 4800), sampleRate: 48_000, channels: 1,
                  presentationTime: CMTime(value: 1_000_001, timescale: 1_000_000))
        ])
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: false, maximumOutputFrames: 65_536)
        let transport = SampleBufferPCMOutputTests.Transport()
        let session = try SampleBufferPlaybackSession(stream: stream, transport: transport, maximumQueuedBuffers: 4)
        defer { session.close() }
        func near(_ expected: Int64) throws -> Bool { abs(try #require(try session.mediaMicroseconds) - expected) <= 1_000 }
        try await session.prepare()
        #expect(try near(1))
        try session.play()
        transport.advance(4799)
        #expect(try near(99_980))
        transport.advance(4800)
        #expect(try near(1_000_001))
        transport.advance(9600)
        #expect(try near(1_100_001))
        #expect(session.state == .ended)
    }

    @Test @MainActor func nativeOutputPositionFollowsTimestampJumpWithoutLosingAudio() async throws {
        let decoder = TimestampPCMDecoder([
            .init(samples: [Int16](repeating: 6000, count: 4800), sampleRate: 48_000, channels: 1,
                  presentationTime: CMTime(value: 1, timescale: 1_000_000)),
            .init(samples: [Int16](repeating: -6000, count: 4800), sampleRate: 48_000, channels: 1,
                  presentationTime: CMTime(value: 1_000_001, timescale: 1_000_000))
        ])
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: false, maximumOutputFrames: 65_536)
        let session = try NativePCMPlaybackSession(stream: stream, mode: .offline, maximumQueuedBuffers: 4)
        defer { session.close() }
        func near(_ expected: Int64) throws -> Bool { abs(try #require(try session.renderedMediaMicroseconds) - expected) <= 1_000 }
        try await session.prepare()
        #expect(try near(1))
        try session.play()
        let old = try session.renderOffline(frames: 4799)
        #expect(old == [Float](repeating: 6000.0 / 32768, count: 4799))
        #expect(try near(99_980))
        _ = try session.renderOffline(frames: 1)
        #expect(try near(1_000_001))
        let new = try session.renderOffline(frames: 4800)
        #expect(new == [Float](repeating: -6000.0 / 32768, count: 4800))
        #expect(try near(1_100_001))
    }

    @Test func invalidPacketAfterBufferedAudioMakesStreamTerminal() async throws {
        let decoder = TimestampPCMDecoder([
            .init(samples: [Int16](repeating: 6000, count: 4096), sampleRate: 48_000, channels: 1, presentationTime: .zero),
            .init(samples: [Int16](repeating: 6000, count: 10), sampleRate: 48_000, channels: 1, presentationTime: .invalid)
        ])
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: false, speed: 0.5, maximumOutputFrames: 65_536)
        await #expect(throws: LocalPCMPlaybackStream.Failure.invalidInput) { try await stream.nextPacket() }
    }
}

private final class InputTimelineFixtures: NSObject {}
