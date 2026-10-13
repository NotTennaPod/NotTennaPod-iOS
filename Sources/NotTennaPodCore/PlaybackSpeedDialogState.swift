import Foundation

/// VariableSpeedDialog owns its unrounded preset list; the slider owns a quantized rate.
public struct PlaybackSpeedDialogState: Equatable, Sendable {
    public private(set) var displayedSpeed: Float
    public private(set) var selection: PlaybackSpeedPresetSelection
    public var progress: Int { PlaybackSpeed.sliderProgress(speed: displayedSpeed) }
    public var currentSliderSpeed: Float { PlaybackSpeed.sliderSpeed(progress: progress) }
    public init(speed: Float, presets: [Float]) {
        displayedSpeed = speed; selection = .init(presets: presets)
    }
    public mutating func receive(speed: Float) { displayedSpeed = speed }
    @discardableResult public mutating func move(to progress: Int) -> Float {
        displayedSpeed = PlaybackSpeed.sliderSpeed(progress: progress)
        return displayedSpeed
    }
    @discardableResult public mutating func step(_ increment: Int) -> Float { move(to: progress + increment) }
    @discardableResult public mutating func addCurrent() throws -> Bool { try selection.add(currentSliderSpeed) }
    public mutating func remove(_ speed: Float) { selection.remove(speed) }
    public static func text(_ speed: Float, locale: Locale = .current) -> String {
        String(format: "%.2f", locale: locale, Double(speed))
    }
}
