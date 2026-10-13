// Swift adaptation of Android Open Source Project's AdaptiveDynamicRangeCompression.
// Copyright (C) 2013 The Android Open Source Project. Licensed under Apache-2.0.
// See Licenses/Apache-2.0.txt and Android-Loudness.txt for attribution/provenance.
import Foundation

/// Render-thread-owned, linked-channel peak compressor. No lookahead or sample delay.
/// `configure`/`reset` start a fresh envelope (AOSP `Initialize`: format changes and discontinuities);
/// `setTarget` changes the target gain only and keeps the envelope (Android 16 `set_target_gain`).
/// An enabled enhancer compresses at every target, including 0 mB.
struct PodcastLoudnessCompressor {
    private var state: Float = 0
    private var gain: Float = 1
    private var attack: Float = 0
    private var release: Float = 0
    private var knee: Float = 0
    private(set) var amplitude: Float = 1
    private var boosting = false

    mutating func configure(_ setting: FeedVolumeAdaptation, sampleRate: Double, baseVolume: Float = 1) {
        reset(sampleRate: sampleRate)
        let effect = setting.effect(baseVolume: baseVolume)
        setAmplitude(effect.amplitude, boosting: effect.enhancerEnabled)
    }

    mutating func reset(sampleRate: Double) {
        state = 0; gain = 1
        attack = expf(-1 / (0.001 * Float(sampleRate)))
        release = expf(-1 / (0.015 * Float(sampleRate)))
    }

    /// Target gain of the enabled LoudnessEnhancer, in millibels (0 included); the envelope continues.
    mutating func setTarget(millibels: Int32) {
        setAmplitude(powf(10, Float(millibels) / 2000), boosting: true)
    }

    private mutating func setAmplitude(_ amplitude: Float, boosting: Bool) {
        self.amplitude = amplitude
        self.boosting = boosting
        // Source interpolates and clamps the five empirically chosen knee values.
        let decibels: Float
        if amplitude <= 2 { decibels = -8 }
        else if amplitude <= 4 { decibels = -8 - 0.5 * (amplitude - 2) }
        else { decibels = -9 - (min(5, amplitude) - 4) }
        knee = 0.1151292546497023 * decibels + 10.397177190355384
    }

    mutating func multiplier(peak: Float) -> Float {
        guard boosting else { return amplitude }
        let scaled = max(abs(peak) * amplitude * 32768, 0.032767)
        let overshoot = max(Self.fastLog(scaled) - knee, 0) * (Float(1) / 7 - 1)
        let previous = state
        let alpha = overshoot <= state ? attack : release
        state = alpha * state + (1 - alpha) * overshoot
        gain *= expf(state - previous)
        return amplitude * gain
    }

    func output(_ sample: Float, multiplier: Float) -> Float {
        let result = sample * multiplier
        return boosting ? min(32767 / Float(32768), max(-32767 / Float(32768), result)) : result
    }

    private static func fastLog(_ value: Float) -> Float {
        let bits = value.bitPattern
        let exponent = Int((bits >> 23) & 255) - 128
        let mantissa = Float(bitPattern: (bits & ~(255 << 23)) + (127 << 23))
        return (((-Float(1) / 3) * mantissa + 2) * mantissa - Float(2) / 3 + Float(exponent)) * 0.6931471805599453
    }
}

/// The sample side of Android's `applyVolumeAdaption` for one output: `v ≤ 1` turns the
/// LoudnessEnhancer off (`linear`: samples scaled by a gain; processed routes pass 1 because their
/// renderer attenuates), `v > 1` turns it on at `(int)(1000·(v−1))` mB (`boost`, 0 mB included,
/// which still compresses). One envelope continues
/// across target changes and is frozen while the enhancer is off, as on Android 16.
///
/// Join ramp: a change takes effect at the next frame processed after it and crossfades, over
/// `rampFrames` output frames (20 ms), from the previous processing (which keeps running) to the
/// new one, whose envelope starts from the previous one's state. Frame k of the ramp (k = 1...R)
/// is `k/R · new + (1 − k/R) · previous`, each path clamped as it would be alone, so a ramp never
/// exceeds both of its ends. A change made during a ramp starts when that ramp ends, from the
/// latest requested target (one ramp at a time, across packets). The first frame after `reset`
/// starts at the requested target with no ramp.
struct PodcastVolumeStage {
    enum Target: Equatable, Sendable {
        case linear(Float), boost(Int32)
        /// `attenuate`: false where a renderer applies the attenuation, so PCM never attenuates.
        init(_ effect: FeedVolumeAdaptation.Effect, attenuate: Bool) {
            self = effect.enhancerEnabled ? .boost(effect.gainMillibels) : .linear(attenuate ? effect.attenuation : 1)
        }
    }
    struct Gains {
        fileprivate let to: Float, from: Float, weight: Float
        fileprivate let toBoost: Bool, fromBoost: Bool, ramping: Bool
    }
    private struct Path {
        var target: Target
        var compressor: PodcastLoudnessCompressor
        var boosting: Bool { if case .boost = target { true } else { false } }
        mutating func multiplier(peak: Float) -> Float {
            switch target {
            case .linear(let gain): gain
            case .boost: compressor.multiplier(peak: peak)
            }
        }
    }
    static let rampSeconds = 0.02
    let rampFrames: Int
    private let sampleRate: Double
    private var to: Path
    private var from: Path?
    private var rampPosition = 0
    private(set) var requested: Target
    private var started = false

    init(target: Target, sampleRate: Double) {
        self.sampleRate = sampleRate
        rampFrames = max(1, Int((Self.rampSeconds * sampleRate).rounded()))
        requested = target
        to = Self.fresh(target, sampleRate: sampleRate)
    }

    /// Nothing to do to the samples: no ramp, enhancer off at unity gain.
    var isIdentity: Bool { from == nil && to.target == .linear(1) && requested == .linear(1) }
    var isRamping: Bool { from != nil || requested != to.target }

    mutating func setTarget(_ target: Target) {
        requested = target
        // Before the first frame there is no previous processing to join.
        if !started { to = Self.fresh(target, sampleRate: sampleRate) }
    }

    /// A discontinuity (new stream, format change): fresh envelope at the requested target, no ramp.
    mutating func reset() {
        to = Self.fresh(requested, sampleRate: sampleRate)
        from = nil; rampPosition = 0; started = false
    }

    /// Frames passed through unchanged while `isIdentity`.
    mutating func skip() { started = true }

    mutating func frame(peak: Float) -> Gains {
        started = true
        if from == nil && requested != to.target {
            var compressor = to.compressor
            if case .boost(let millibels) = requested { compressor.setTarget(millibels: millibels) }
            from = to
            to = Path(target: requested, compressor: compressor)
            rampPosition = 0
        }
        let target = to.multiplier(peak: peak)
        guard var previous = from else {
            return Gains(to: target, from: 0, weight: 1, toBoost: to.boosting, fromBoost: false, ramping: false)
        }
        let source = previous.multiplier(peak: peak)
        rampPosition += 1
        let weight = Float(rampPosition) / Float(rampFrames)
        let gains = Gains(to: target, from: source, weight: weight, toBoost: to.boosting, fromBoost: previous.boosting, ramping: true)
        if rampPosition >= rampFrames { from = nil; rampPosition = 0 } else { from = previous }
        return gains
    }

    func output(_ sample: Float, _ gains: Gains) -> Float {
        let target = Self.output(sample, gains.to, boost: gains.toBoost)
        guard gains.ramping else { return target }
        return gains.weight * target + (1 - gains.weight) * Self.output(sample, gains.from, boost: gains.fromBoost)
    }

    private static func output(_ sample: Float, _ multiplier: Float, boost: Bool) -> Float {
        let result = sample * multiplier
        return boost ? min(32767 / Float(32768), max(-32767 / Float(32768), result)) : result
    }

    private static func fresh(_ target: Target, sampleRate: Double) -> Path {
        var compressor = PodcastLoudnessCompressor()
        compressor.reset(sampleRate: sampleRate)
        if case .boost(let millibels) = target { compressor.setTarget(millibels: millibels) }
        return Path(target: target, compressor: compressor)
    }
}
