import Foundation

/// FeedSettingsPreferenceFragment's confirmed per-feed speed/silence editor.
/// Global selection disables the controls but does not discard the open draft.
public struct FeedPlaybackSpeedDraft: Equatable, Sendable {
    public var usesGlobal: Bool
    public var skipsSilence: Bool
    public private(set) var progress: Int
    public private(set) var hasChangedSpeed = false

    public init(speed: Float, skipSilence: PlaybackSilencePreference) {
        usesGlobal = speed == PlaybackSpeed.useGlobal
        progress = PlaybackSpeed.sliderProgress(speed: usesGlobal ? 1 : speed)
        skipsSilence = !usesGlobal && skipSilence == .aggressive
    }
    public var sliderSpeed: Float { PlaybackSpeed.sliderSpeed(progress: progress) }
    public var savedSpeed: Float { usesGlobal ? PlaybackSpeed.useGlobal : sliderSpeed }
    public var savedSilence: PlaybackSilencePreference { usesGlobal ? .global : skipsSilence ? .aggressive : .off }
    public mutating func move(to progress: Int) {
        guard !usesGlobal else { return }
        self.progress = min(70, max(0, progress)); hasChangedSpeed = true
    }
    public mutating func step(_ amount: Int) { move(to: progress + amount) }
    public func label(locale: Locale = .current) -> String? {
        // updateSpeed initializes only the source slider. The adjacent label
        // remains empty until a step/drag invokes its progress listener.
        hasChangedSpeed ? String(format: "%.2fx", locale: locale, Double(sliderSpeed)) : nil
    }
}
