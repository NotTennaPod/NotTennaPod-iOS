import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

/// The volume stage of processed playback against `VolumeOracle`: the renderer must receive exactly the
/// commands the test made (recorded by the test, with the frames submitted and presented at the time), and
/// what is heard (renderer value in force at presentation × the PCM) must match Android's split run over them.
@MainActor @Suite(.serialized) struct VolumeControlledPCMTransportTests {
    /// Speech-like bursts, a loud sustained tone and quiet passages, stereo at 48 kHz.
    static let samples: [Int16] = (0..<48_000).flatMap { frame -> [Int16] in
        let t = Double(frame) / 48_000
        let level: Double
        switch frame {
        case ..<9_600: level = 0.03 * (1 + sin(2 * .pi * 3 * t))          // quiet speech-like
        case ..<24_000: level = 0.6                                          // loud sustained
        case ..<33_600: level = 0.2 * abs(sin(2 * .pi * 4 * t))            // syllables
        default: level = 0.005                                               // near silence
        }
        let left = level * sin(2 * .pi * 220 * t), right = level * sin(2 * .pi * 330 * t + 0.4)
        return [Int16(left * 32767), Int16(right * 32767)]
    }

    @MainActor private final class Harness {
        let backend = GainRecordingTransport()
        let output: VolumeControlledPCMTransport
        let factory: PCMSampleBufferFactory
        /// First frame of `samples` this output plays.
        let inputStart: Int
        /// Frames handed to the output; it processes each packet when handed over.
        private(set) var written: Int64 = 0
        /// Every command the test made, where it was made.
        private(set) var expected: [VolumeOracle.Expected]
        init(setting: FeedVolumeAdaptation = .off, baseVolume: Float = 1, frames: Int = 4096, inputStart: Int = 0) throws {
            self.inputStart = inputStart
            expected = [.init(v: setting.factor * baseVolume, processed: 0, presented: 0)]
            factory = try PCMSampleBufferFactory(sampleRate: 48000, channels: 2, maximumFrames: frames)
            output = try VolumeControlledPCMTransport(backend: backend, sampleRate: 48000, channels: 2, maximumFrames: frames,
                setting: setting, baseVolume: baseVolume)
        }
        var input: [Int16] { Array(VolumeControlledPCMTransportTests.samples[(inputStart * 2)...]) }
        func enqueue(_ frames: Int) async throws {
            let start = inputStart + Int(written)
            let buffer = try factory.makeBuffer(Array(VolumeControlledPCMTransportTests.samples[start * 2..<(start + frames) * 2]),
                outputStartFrame: written)
            written += Int64(frames)
            try await output.enqueue(buffer)
        }
        func set(_ setting: FeedVolumeAdaptation, baseVolume: Float = 1) throws {
            expected.append(.init(v: setting.factor * baseVolume, processed: written, presented: backend.presentedFrames))
            try output.setVolume(setting, baseVolume: baseVolume)
        }
        func expectHeard(_ label: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
            backend.expectHeard(input: input, expected: expected, frames: Int(written), label: label, sourceLocation: sourceLocation)
        }
    }

    @Test(arguments: FeedVolumeAdaptation.allCases, [false, true])
    func attenuationActsNowAndBoostAppliesToLaterAudio(setting: FeedVolumeAdaptation, playing: Bool) async throws {
        let harness = try Harness(setting: .heavyReduction, frames: 300)
        defer { harness.output.close() }
        for _ in 0..<2 { try await harness.enqueue(300) }
        harness.output.setPlaying(playing, at: .zero)
        harness.backend.advance(to: 137)
        let before = harness.backend.playingChanges.count
        try harness.set(setting)
        // Nothing stops, flushes, re-times or re-queues; the renderer takes min(1, v) at once.
        #expect(harness.backend.playingChanges.count == before && harness.backend.playing == playing)
        #expect(harness.backend.currentTime == CMTime(value: 137, timescale: 48000) && harness.backend.processedFrames == 600)
        #expect(harness.backend.rendererVolume == min(1, setting.factor))
        for _ in 0..<4 { try await harness.enqueue(300) }
        harness.expectHeard("\(setting)")
        // The queued audio is unchanged; a boost starts with the first frame processed after it.
        #expect(harness.backend.payload.prefix(1200) == VolumeControlledPCMTransportTests.samples.prefix(1200))
    }

    @Test(arguments: FeedVolumeAdaptation.allCases)
    func sleepFadeStepsFollowAndroidWithoutStoppingTheRenderer(setting: FeedVolumeAdaptation) async throws {
        let harness = try Harness(setting: setting)
        defer { harness.output.close() }
        harness.output.setPlaying(true, at: .zero)
        try await harness.enqueue(3600)
        // Android's steps, max(0.1, ms/10000) each second, then the restore after a cancel.
        for (step, scalar) in ((1...10).reversed().map { Float($0) / 10 } + [1]).enumerated() {
            try harness.set(setting, baseVolume: scalar)
            #expect(harness.output.baseVolume == scalar && harness.backend.rendererVolume == min(1, setting.factor * scalar))
            try await harness.enqueue(3600)
            harness.backend.advance(to: Int64(step + 1) * 3600 - 1000)
        }
        #expect(harness.backend.playingChanges.map(\.playing) == [true])
        harness.expectHeard("\(setting) fade")
    }

    /// Changes arriving faster than the 960-frame ramp, across short packets: boosts, the enhancer
    /// switching off and on again, reductions, reversals, and a boost lowered then raised before it is heard.
    @Test(arguments: [7, 100, 1000])
    func rampsJoinEveryChangeAcrossPacketsAndSupersedingCommands(packet: Int) async throws {
        let harness = try Harness(setting: .heavyBoost, frames: 1000)
        defer { harness.output.close() }
        harness.output.setPlaying(true, at: .zero)
        let script: [(FeedVolumeAdaptation, Float)] = [(.mediumBoost, 1), (.off, 1), (.heavyBoost, 1), (.heavyBoost, 0.5),
            (.heavyReduction, 1), (.heavyBoost, 1), (.lightBoost, 0.9), (.lightReduction, 1), (.heavyBoost, 0.3), (.heavyBoost, 1)]
        var next = 0
        while harness.written + Int64(packet) <= 44_000 {
            try await harness.enqueue(packet)
            if Int(harness.written) / 1500 > next, next < script.count * 2 {
                next += 1
                let (setting, base) = script[next % script.count]
                try harness.set(setting, baseVolume: base)
                if next % 3 == 0 { try harness.set(script[(next + 4) % script.count].0) } // superseded before heard
            }
            harness.backend.advance(to: max(0, harness.written - 2000))
        }
        harness.expectHeard("packets of \(packet)")
    }

    /// Heavy boost → heavy reduction → off before the boosted audio is heard: the queued boosted samples
    /// are heard again at up to their own processed level, later audio unboosted.
    @Test func loweredBoostIsHeardUntilItsQueuedAudioDrains() async throws {
        let harness = try Harness(setting: .heavyBoost)
        defer { harness.output.close() }
        harness.output.setPlaying(true, at: .zero)
        for _ in 0..<3 { try await harness.enqueue(4096) }
        try harness.set(.heavyReduction)
        harness.backend.advance(to: 2048)
        try await harness.enqueue(4096)
        try harness.set(.off)
        harness.backend.advance(to: 6000)
        for _ in 0..<2 { try await harness.enqueue(4096) }
        harness.expectHeard()
        let quiet = 0..<(9_600 * 2)
        let input = quiet.map { abs(Int(VolumeControlledPCMTransportTests.samples[$0])) }.max()!
        #expect(quiet.map { abs(Int(harness.backend.payload[$0])) }.max()! > 3 * input) // Queued while boosted.
    }

    /// Fade on loud sustained content with Heavy boost: targets fall, the compressor relaxes and the enhancer
    /// switches off between attenuation ticks. Each ramp stays within its two ends; no click, no burst.
    @Test func bypassJoinOnLoudSustainedContentStaysWithinItsEnds() async throws {
        let harness = try Harness(setting: .heavyBoost, inputStart: 9_600) // Start in the loud sustained tone.
        defer { harness.output.close() }
        harness.output.setPlaying(true, at: .zero)
        for scalar: Float in [1, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3] {
            try harness.set(.heavyBoost, baseVolume: scalar)
            try await harness.enqueue(1700)
        }
        harness.expectHeard()
        let payload = harness.backend.payload
        // v = 1.25 → 1.0 switches the enhancer off at frame 6 × 1700: the join ramp stays within its ends.
        let start = 6 * 1700, ramp = 960
        func peak(_ range: Range<Int>) -> Int { range.map { max(abs(Int(payload[$0 * 2])), abs(Int(payload[$0 * 2 + 1]))) }.max()! }
        let before = peak((start - 400)..<start), after = peak((start + ramp)..<(start + ramp + 400))
        for window in stride(from: start, to: start + ramp, by: 160) {
            #expect(peak(window..<(window + 160)) <= max(before, after) + 2)
        }
        #expect(after > before) // Android's own rise when the enhancer switches off, here joined by the ramp.
    }

    @Test func aChangeDuringAPendingEnqueueAppliesFromTheNextPacket() async throws {
        let harness = try Harness(setting: .off, frames: 600)
        defer { harness.output.close() }
        try await harness.enqueue(600)
        harness.backend.hold = true
        let pending = Task { try await harness.enqueue(600) }
        defer { pending.cancel() }
        try await wait { harness.backend.pending != nil }
        await #expect(throws: VolumeControlledPCMTransport.Failure.concurrentEnqueue) {
            try await harness.output.enqueue(harness.factory.makeBuffer([1, 2], outputStartFrame: 1200))
        }
        // The held packet was processed before this command: the boost starts with the next one.
        try harness.set(.heavyBoost)
        #expect(harness.backend.rendererVolume == 1 && harness.expected.last?.processed == 1200)
        harness.backend.release()
        try await pending.value
        try await harness.enqueue(600)
        harness.expectHeard()
        #expect(harness.backend.payload.prefix(2400) == VolumeControlledPCMTransportTests.samples.prefix(2400))
        #expect(harness.backend.playingChanges.isEmpty)
    }

    /// Commands arriving while a 960-frame join is still running, at and across packet boundaries: the
    /// enhancer switching off and on again mid-join, a pending target superseded before its join starts,
    /// a reduction and an enabled 0 mB target. Each running join completes; then the latest target joins.
    @Test(arguments: [64, 100, 333])
    func commandsDuringARunningJoinWaitForItThenTheLatestTargetJoins(packet: Int) async throws {
        let harness = try Harness(setting: .heavyBoost, frames: 333, inputStart: 9_000)
        defer { harness.output.close() }
        harness.output.setPlaying(true, at: .zero)
        // (frames processed before the command, setting, sleep volume): gaps far shorter than the join.
        let script: [(Int64, FeedVolumeAdaptation, Float)] = [
            (1_200, .off, 1), (1_500, .heavyBoost, 1), (1_700, .lightBoost, 1),        // off mid-join, on, superseded
            (3_400, .heavyReduction, 1), (3_500, .heavyBoost, 0.4001), (3_900, .off, 1), // 0 mB enabled mid-join
            (5_000, .mediumBoost, 0.9), (5_200, .mediumBoost, 0.55), (5_250, .heavyBoost, 1), (5_300, .heavyBoost, 0.8),
        ]
        var next = 0
        while harness.written + Int64(packet) <= 9_000 {
            while next < script.count, harness.written >= script[next].0 {
                try harness.set(script[next].1, baseVolume: script[next].2); next += 1
            }
            try await harness.enqueue(packet)
            harness.backend.advance(to: max(0, harness.written - 1_500))
        }
        #expect(next == script.count)
        harness.expectHeard("packets of \(packet)")
    }

    /// Android enables the enhancer whenever v > 1, even where (int)(1000·(v − 1)) is 0 mB: it still
    /// compresses. v = 1 bypasses; 1 mB is the first positive target. On a new output and across an
    /// existing envelope, on loud sustained content.
    @Test(arguments: [Float(0.4), 0.4001, 0.4006])
    func justAboveUnityStillCompressesOnANewOutput(baseVolume: Float) async throws {
        let effect = FeedVolumeAdaptation.heavyBoost.effect(baseVolume: baseVolume)
        #expect(effect.attenuation == 1 && effect.enhancerEnabled == (baseVolume > 0.4) && effect.gainMillibels == (baseVolume > 0.4005 ? 1 : 0))
        let harness = try Harness(setting: .heavyBoost, baseVolume: baseVolume, inputStart: 9_600)
        defer { harness.output.close() }
        for _ in 0..<3 { try await harness.enqueue(2_400) }
        harness.expectHeard("v = \(2.5 * baseVolume)")
        let settled = harness.backend.payload[(4_800 * 2)...].map { abs(Int($0)) }.max()!
        if baseVolume > 0.4 { #expect(settled < 15_000) } else { #expect(settled > 19_000) } // 0.6 FS input
    }

    @Test func justAboveUnityKeepsTheEnvelopeAndJoinsLikeAnyTarget() async throws {
        let harness = try Harness(setting: .heavyBoost, inputStart: 9_600)
        defer { harness.output.close() }
        harness.output.setPlaying(true, at: .zero)
        try await harness.enqueue(2_000)
        for base: Float in [0.4001, 0.4, 0.4001, 0.4006, 0.4, 1] {
            try harness.set(.heavyBoost, baseVolume: base)
            try await harness.enqueue(1_500)
            harness.backend.advance(to: harness.written - 1_000)
        }
        harness.expectHeard()
    }

    @Test func unityPassesBuffersThroughUntouched() async throws {
        let harness = try Harness(setting: .lightReduction)
        defer { harness.output.close() }
        try await harness.enqueue(4096); try await harness.enqueue(4096)
        #expect(harness.backend.payload == Array(VolumeControlledPCMTransportTests.samples.prefix(8192 * 2)))
        #expect(harness.backend.volumes.map(\.value) == [0.5])
    }

    @Test(arguments: [false, true])
    func failureOrCloseRetiresTheOutput(close: Bool) async throws {
        let harness = try Harness(setting: .heavyBoost)
        try await harness.enqueue(4096)
        var errors: [NSError] = []
        harness.output.onFailure = { errors.append($0 as NSError) }
        if close { harness.output.close() } else { harness.backend.onFailure?(URLError(.networkConnectionLost)) }
        #expect(harness.backend.closed && errors.count == (close ? 0 : 1))
        #expect(throws: VolumeControlledPCMTransport.Failure.closed) { try harness.output.setVolume(.off) }
        await #expect(throws: VolumeControlledPCMTransport.Failure.closed) { try await harness.enqueue(4096) }
    }

    @Test func rejectsDifferentPCMFormatAndKeepsPriorAudioIntact() async throws {
        let backend = GainRecordingTransport()
        let output = try VolumeControlledPCMTransport(backend: backend, sampleRate: 48000, channels: 2)
        defer { output.close() }
        let wrong = try PCMSampleBufferFactory(sampleRate: 44100, channels: 2)
        await #expect(throws: VolumeControlledPCMTransport.Failure.invalidPacket) {
            try await output.enqueue(wrong.makeBuffer(Array(Self.samples.prefix(1800)), outputStartFrame: 0))
        }
        #expect(backend.payload.isEmpty)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }
}
