import Foundation
import Testing
@testable import NotTennaPodCore

@Suite struct FeedVolumeAdaptationTests {
    @Test func sourceDisplayOrderAndMillibelMappingIncludingFade() {
        #expect(FeedVolumeAdaptation.displayOrder.map(\.rawValue) == [2, 1, 0, 3, 4, 5])
        #expect(FeedVolumeAdaptation.allCases.map { $0.effect().gainMillibels } == [0, 0, 0, 500, 1000, 1500])
        #expect(FeedVolumeAdaptation.heavyReduction.effect().attenuation == 0.2)
        #expect(FeedVolumeAdaptation.lightReduction.effect().attenuation == 0.5)
        #expect(FeedVolumeAdaptation.heavyBoost.effect(baseVolume: 0.2).attenuation == 0.5)
        #expect(FeedVolumeAdaptation.heavyBoost.effect(baseVolume: 0.2).gainMillibels == 0)
        #expect(FeedVolumeAdaptation.heavyBoost.effect(baseVolume: 0.6).gainMillibels == 500)
    }
    /// Feeds saved before the setting existed read as Off. Persistence of a chosen setting is covered by
    /// FeedLibraryStoreTests.playbackStateMeasuredDurationAndPreferencesSurviveRefreshAndReopen.
    @Test func olderHeadersDefaultToOff() throws {
        let older = try JSONEncoder().encode(LibraryFeed(id: 1, source: "fixture", metadata: .init(format: .rss), episodes: []))
        #expect(!String(decoding: older, as: UTF8.self).contains("volumeAdaptationValue"))
        #expect(try JSONDecoder().decode(LibraryFeed.self, from: older).volumeAdaptation == .off)
    }
    @Test func compressorMatchesAOSPWithConfirmedInterpolationDefectCorrected() throws {
        struct Corpus: Decodable { let samples: [[Double]] }
        let url = try #require(Bundle.module.url(forResource: "loudness-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        #expect(corpus.samples.count == 3072)
        for rate in [44100, 48000] {
            for (setting, gain) in [(FeedVolumeAdaptation.lightBoost, 500), (.mediumBoost, 1000), (.heavyBoost, 1500)] {
                var processor = PodcastLoudnessCompressor(); processor.configure(setting, sampleRate: Double(rate))
                let expected = corpus.samples.filter { $0[0] == 1 && $0[1] == Double(rate) && $0[2] == Double(gain) }
                #expect(expected.count == 256)
                for frame in 0..<4096 {
                    let level: Float = frame < 512 ? 0.01 : frame < 1536 ? 0.8 : frame < 3072 ? 0.1 : 0.001
                    let left = Float((frame * 37 % 127) - 63) / 64 * level
                    let right = Float((frame * 73 % 127) - 63) / 64 * level
                    let multiplier = processor.multiplier(peak: max(abs(left), abs(right)))
                    let outputs = [processor.output(left, multiplier: multiplier), processor.output(right, multiplier: multiplier)]
                    #expect(outputs.allSatisfy { $0.isFinite && abs($0) < 1 })
                    if frame % 16 == 0 {
                        let row = expected[frame / 16]
                        // Within 2 % of Android's output level (about 0.2 dB): inaudible.
                        func differs(_ actual: Float, _ expected: Double) -> Bool {
                            abs(Double(actual) - expected) > max(0.002, 0.02 * abs(expected))
                        }
                        if differs(outputs[0], row[4]) || differs(outputs[1], row[5]) {
                            Issue.record("rate=\(rate) gain=\(gain) frame=\(frame) actual=\(outputs) expected=\(row[4...5])")
                            break
                        }
                    }
                }
            }
        }
    }
    @Test func mediumBoostDoesNotDependOnPreviousSettings() {
        for previous in FeedVolumeAdaptation.allCases {
            var reused = PodcastLoudnessCompressor(); reused.configure(previous, sampleRate: 48000)
            for _ in 0..<64 { _ = reused.multiplier(peak: 0.8) }
            reused.configure(.mediumBoost, sampleRate: 48000)
            var fresh = PodcastLoudnessCompressor(); fresh.configure(.mediumBoost, sampleRate: 48000)
            for _ in 0..<128 { #expect(reused.multiplier(peak: 0.8) == fresh.multiplier(peak: 0.8)) }
        }
    }

    /// Android enables the enhancer whenever v > 1, then truncates its target: v = 1.00025 is on at 0 mB.
    @Test func enhancerIsOnAboveUnityEvenAtAZeroMillibelTarget() {
        let unity = FeedVolumeAdaptation.heavyBoost.effect(baseVolume: 0.4)
        let zero = FeedVolumeAdaptation.heavyBoost.effect(baseVolume: 0.4001)
        let first = FeedVolumeAdaptation.heavyBoost.effect(baseVolume: 0.4006)
        #expect(!unity.enhancerEnabled && unity.attenuation == 1 && unity.gainMillibels == 0)
        #expect(zero.enhancerEnabled && zero.attenuation == 1 && zero.gainMillibels == 0)
        #expect(first.enhancerEnabled && first.gainMillibels == 1)
        #expect(!FeedVolumeAdaptation.off.effect().enhancerEnabled && FeedVolumeAdaptation.lightBoost.effect().enhancerEnabled)
        var enabled = PodcastLoudnessCompressor(); enabled.configure(.heavyBoost, sampleRate: 48000, baseVolume: 0.4001)
        var bypassed = PodcastLoudnessCompressor(); bypassed.configure(.heavyBoost, sampleRate: 48000, baseVolume: 0.4)
        var reference = VolumeOracle.Compressor(sampleRate: 48000); reference.setTargetGain(1)
        var output: Float = 0, frame: [Float] = [0.6]
        for _ in 0..<4800 {
            output = enabled.output(0.6, multiplier: enabled.multiplier(peak: 0.6))
            frame = [0.6]; reference.compress(&frame, inputAmplification: 32768)
        }
        #expect(abs(output - frame[0]) < 1e-5 && output < 0.45) // Compressed, as AOSP at an enabled 0 mB target.
        #expect(bypassed.output(0.6, multiplier: bypassed.multiplier(peak: 0.6)) == 0.6)
    }

    /// Android 16's `set_target_gain`: a new target changes the knee and input gain only. On loud sustained
    /// content the envelope already holds the level down, so the next frame does not burst or clip.
    @Test func targetChangeKeepsTheEnvelopeWhileResetStartsAfresh() {
        var kept = PodcastLoudnessCompressor(); kept.configure(.heavyBoost, sampleRate: 48000)
        for _ in 0..<4800 { _ = kept.multiplier(peak: 0.6) }
        var reset = kept
        kept.setTarget(millibels: 1250)
        reset.configure(.heavyBoost, sampleRate: 48000, baseVolume: 0.9)
        #expect(kept.amplitude == reset.amplitude)
        let continued = kept.output(0.6, multiplier: kept.multiplier(peak: 0.6))
        let restarted = reset.output(0.6, multiplier: reset.multiplier(peak: 0.6))
        #expect(continued < 0.6 && restarted == 32767 / Float(32768)) // The reset clips; the kept envelope does not.
        var reference = VolumeOracle.Compressor(sampleRate: 48000)
        reference.setTargetGain(powf(10, 0.75))
        var frame: [Float] = [0.6]
        for _ in 0..<4800 { frame = [0.6]; reference.compress(&frame, inputAmplification: powf(10, 0.75) * 32768) }
        reference.setTargetGain(powf(10, 0.625))
        frame = [0.6]; reference.compress(&frame, inputAmplification: powf(10, 0.625) * 32768)
        #expect(abs(frame[0] - continued) < 1e-5)
    }

    @Test func resetClearsPreviousEnvelopeAndReductionDoesNotCompress() {
        var processor = PodcastLoudnessCompressor(); processor.configure(.heavyBoost, sampleRate: 48000)
        for _ in 0..<2048 { _ = processor.multiplier(peak: 0.8) }
        processor.configure(.lightReduction, sampleRate: 48000)
        #expect(processor.output(0.8, multiplier: processor.multiplier(peak: 0.8)) == 0.4)
        processor.configure(.off, sampleRate: 48000)
        #expect(processor.output(-0.8, multiplier: processor.multiplier(peak: 0.8)) == -0.8)
        processor.configure(.heavyBoost, sampleRate: 48000)
        var fresh = PodcastLoudnessCompressor(); fresh.configure(.heavyBoost, sampleRate: 48000)
        #expect(processor.multiplier(peak: 0.01) == fresh.multiplier(peak: 0.01))
    }
}
