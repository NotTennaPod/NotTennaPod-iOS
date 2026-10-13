import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

struct PlaybackVideoProcessingTests {
    actor Decoder: PCMDecoding {
        nonisolated let sampleRate = 48000, channels = 1
        nonisolated let startFrame: Int64
        private var offset = 0
        private let input: [Int16]
        init(input: [Int16], start: Int64 = 0) { self.input = input; startFrame = start }
        func next() -> NativePCMDecoder.Packet? {
            guard offset < input.count else { return nil }
            let end = min(input.count, offset + 4096)
            defer { offset = end }
            return .init(samples: Array(input[offset..<end]), sampleRate: sampleRate, channels: channels,
                presentationTime: CMTime(value: startFrame + Int64(offset), timescale: 48000))
        }
        func cancel() {}
    }
    private func fixture() -> [Int16] {
        (0..<96000).map { frame in
            if (12000..<84000).contains(frame) { return 0 }
            return Int16((sin(Double(frame) * 2 * .pi * 440 / 48000) * 12000).rounded())
        }
    }

    @Test(arguments: [Float(0.5), 1, 1.5, 4], [127, 4096])
    func committedSpansConserveInputOutputAndLocateActualRemovedSilence(speed: Float, packetSize: Int) async throws {
        let input = fixture()
        let stream = try LocalPCMPlaybackStream(decoder: Decoder(input: input, start: 240000),
            skipSilence: true, speed: speed, maximumOutputFrames: packetSize)
        try await stream.enableVideoTimeline()
        var map = try PlaybackVideoTimeline(maximumSpans: 20000)
        var pcm: [Int16] = []
        while let packet = try await stream.nextPacket() {
            pcm += packet.samples
            for span in packet.videoTimelineSpans {
                do { try map.append(span) }
                catch {
                    print("MAP_GAP speed=\(speed) packet=\(packetSize) previous=\(String(describing: map.spans.last)) next=\(span)")
                    throw error
                }
            }
        }
        for span in await stream.takeFinalVideoTimelineSpans() { try map.append(span) }
        let source = try #require(map.sourceRange)
        let output = try #require(map.presentationRange)
        #expect(source.start == CMTime(value: 5, timescale: 1))
        #expect(source.end == CMTime(value: 7, timescale: 1))
        #expect(output.start == .zero && output.end == CMTime(value: Int64(pcm.count), timescale: 48000))
        #expect(try map.sourceTime(at: output.end) == source.end)
        let removed = map.spans.filter { $0.presentation.duration == .zero }
        #expect(!removed.isEmpty)
        for span in removed {
            let lower = Int(CMTimeConvertScale(span.source.start - source.start, timescale: 48000, method: .roundTowardZero).value)
            let upper = Int(CMTimeConvertScale(span.source.end - source.start, timescale: 48000, method: .roundAwayFromZero).value)
            #expect(input[lower..<upper].allSatisfy { abs(Int($0)) <= 1024 })
        }
        // Independent waveform markers away from transition windows: both retained
        // tone sections still have audible-scale PCM around their mapped source time.
        for sourceSeconds in [5.1, 6.9] {
            let at = try map.presentationTime(at: CMTime(seconds: sourceSeconds, preferredTimescale: 48000))
            let center = Int(CMTimeConvertScale(at, timescale: 48000, method: .roundTowardZero).value)
            let samples = pcm[max(0, center - 120)..<min(pcm.count, center + 120)]
            #expect(samples.contains { abs(Int($0)) > 4000 })
        }
    }

    @Test func UIAndRecoveryClockUseCommittedCutsRatherThanFutureSkippedCounters() throws {
        func range(_ start: Int64, _ duration: Int64) -> CMTimeRange {
            CMTimeRange(start: CMTime(value: start, timescale: 1), duration: CMTime(value: duration, timescale: 1))
        }
        var map = try PlaybackVideoTimeline()
        try map.append(.init(source: range(0, 1), presentation: range(0, 1)))
        try map.append(.init(source: range(1, 2), presentation: range(1, 0)))
        try map.append(.init(source: range(3, 1), presentation: range(1, 1)))
        var clock = try PCMPlaybackClock(sampleRate: 48000, mediaMicroseconds: 0, speed: 1)
        try clock.enqueueCheckpoint(outputFrame: 48000, mediaMicroseconds: 3_000_000, speed: 1)
        let progress = try PCMProcessingProgress(speed: 1, channels: 1, inputFrames: 96000,
            pendingInputFrames: 0, outputFrames: 96000, skippedFrames: 96000, speedProcessingActive: false)
        #expect(try clock.position(presentedFrames: 24000, writtenFrames: 96000, progress: progress,
            committedTimeline: map) == 500_000)
        #expect(try clock.position(presentedFrames: 72000, writtenFrames: 96000, progress: progress,
            committedTimeline: map) == 3_500_000)
        #expect(clock.pendingCheckpointCount == 0)
        #expect(try clock.recoveryPosition(presentedFrames: 36000, writtenFrames: 96000, progress: progress,
            committedTimeline: map) == 750_000)
    }

    @Test func compositionPreservesLiteralCutsAcrossDelayedSpeedConsumption() throws {
        var composer = PCMVideoSpanComposer(sourceAnchor: .zero, outputAnchor: 0, sampleRate: 1000)
        composer.appendSilence([.init(input: 0..<100, output: 0..<100),
            .init(input: 100..<500, output: 100..<100), .init(input: 500..<600, output: 100..<200)])
        let first = composer.consumeSpeed([.init(input: 0..<50, output: 0..<25)])
        let second = composer.consumeSpeed([.init(input: 50..<200, output: 25..<100)])
        var map = try PlaybackVideoTimeline()
        for span in first + second { try map.append(span) }
        #expect(map.spans.map { $0.source.duration.seconds } == [0.05, 0.05, 0.4, 0.1])
        #expect(try map.sourceTime(at: CMTime(value: 50, timescale: 1000)) == CMTime(value: 500, timescale: 1000))
        #expect(map.presentationRange?.duration == CMTime(value: 100, timescale: 1000))
    }
}
