import Foundation

public enum FeedVolumeAdaptation: Int, Codable, CaseIterable, Sendable {
    case off = 0, lightReduction = 1, heavyReduction = 2, lightBoost = 3, mediumBoost = 4, heavyBoost = 5

    public static let displayOrder: [Self] = [.heavyReduction, .lightReduction, .off, .lightBoost, .mediumBoost, .heavyBoost]
    public var titleKey: String {
        switch self {
        case .off: "feed_volume_reduction_off"
        case .lightReduction: "feed_volume_reduction_light"
        case .heavyReduction: "feed_volume_reduction_heavy"
        case .lightBoost: "feed_volume_boost_light"
        case .mediumBoost: "feed_volume_boost_medium"
        case .heavyBoost: "feed_volume_boost_heavy"
        }
    }
    public var factor: Float {
        switch self {
        case .off: 1
        case .lightReduction: 0.5
        case .heavyReduction: 0.2
        case .lightBoost: 1.5
        case .mediumBoost: 2
        case .heavyBoost: 2.5
        }
    }
    /// Source applies attenuation directly, but boost through a millibel enhancer, enabled whenever
    /// the volume exceeds 1, even where its integer target truncates to 0 mB.
    public func effect(baseVolume: Float = 1) -> Effect {
        let volume = max(0, min(1, baseVolume)) * factor
        return volume <= 1 ? Effect(attenuation: volume, enhancerEnabled: false, gainMillibels: 0)
            : Effect(attenuation: 1, enhancerEnabled: true, gainMillibels: Int32(1000 * (volume - 1)))
    }
    public struct Effect: Equatable, Sendable {
        public let attenuation: Float
        /// Android's `LoudnessEnhancer.setEnabled(v > 1)`, independent of the truncated target.
        public let enhancerEnabled: Bool
        public let gainMillibels: Int32
        public var amplitude: Float { attenuation * powf(10, Float(gainMillibels) / 2000) }
    }
}

@MainActor public protocol PlaybackVolumeControlling: PlaybackEngine {
    func setVolumeAdaptation(_ setting: FeedVolumeAdaptation) throws
    func setSleepTimerVolume(_ volume: Float) throws
}

public extension PlaybackVolumeControlling {
    func setSleepTimerVolume(_ volume: Float) throws {
        guard volume == 1 else { throw PlaybackVolumeError.unsupportedEngine }
    }
}

public enum PlaybackVolumeError: Error, Equatable, Sendable {
    case unsupportedEngine, tapCreation(Int32), unsupportedFormat
}
