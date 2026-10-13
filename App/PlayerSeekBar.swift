import UIKit
import NotTennaPodCore

@MainActor
final class PlayerSeekBar: UIControl {
    var value: Float = 0 {
        didSet {
            let quantized = PlayerSeekLayout.quantize(value)
            if value != quantized { value = quantized }
            // Playback ticks repeat the same value; repaint only what moved.
            guard value != oldValue else { return }
            accessibilityValue = "\(Int(value / 5))%"
            setNeedsDisplay()
            setNeedsLayout()
        }
    }
    override var isEnabled: Bool { didSet { updateThumb() } }
    /// Relative chapter starts, in source order. Unknown duration/no chapters is empty.
    /// Do not sort or clamp: the source renderer uses the supplied boundaries verbatim.
    var chapterFractions: [Float] = [] { didSet { if chapterFractions != oldValue { setNeedsDisplay() } } }
    var secondaryValue: Float = 0 {
        didSet {
            let quantized = PlayerSeekLayout.quantize(secondaryValue)
            if secondaryValue != quantized { secondaryValue = quantized }
            if secondaryValue != oldValue { setNeedsDisplay() }
        }
    }
    override var isHighlighted: Bool { didSet { updateThumb(); setNeedsDisplay() } }
    typealias HighlightScheduler = (_ delay: Duration, _ reset: @escaping @MainActor @Sendable () -> Void) -> Void
    private let scheduleChapterHighlightReset: HighlightScheduler
    private var chapterHighlightActive = false
    private let thumb = UIImageView()
    private var touchOffset: CGFloat = 0

    init(scheduleChapterHighlightReset: @escaping HighlightScheduler = { delay, reset in
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            reset()
        }
    }) {
        self.scheduleChapterHighlightReset = scheduleChapterHighlightReset
        super.init(frame: .zero)
        semanticContentAttribute = .forceLeftToRight
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityValue = "0%"
        thumb.isUserInteractionEnabled = false
        thumb.tintColor = Appearance.accent
        addSubview(thumb)
        updateThumb()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var geometry: PlayerSeekLayout {
        PlayerSeekLayout(bounds: bounds, value: value, scale: traitCollection.displayScale)
    }

    private func updateThumb() {
        thumb.image = UIImage(named: !isEnabled ? "seek_thumb_disabled" : isHighlighted ? "seek_thumb_pressed" : "seek_thumb_normal")
        thumb.tintColor = isEnabled ? Appearance.accent : Appearance.foreground.withAlphaComponent(0.26)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let center = geometry.thumbCenter
        let size = thumb.image?.size ?? CGSize(width: 18, height: 18)
        thumb.frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    func highlightCurrentChapter() {
        chapterHighlightActive = true
        setNeedsDisplay()
        // The source posts a reset for every request; a subsequent highlight does not
        // extend an already pending reset. The callback does not retain the control.
        scheduleChapterHighlightReset(.seconds(1)) { [weak self] in
            self?.chapterHighlightActive = false
            self?.setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let layout = geometry
        let track = layout.track
        let background = Appearance.surfaceVariant
            .resolvedColor(with: traitCollection).withAlphaComponent(128.0 / 255).cgColor
        let primary = Appearance.accent.resolvedColor(with: traitCollection).cgColor
        let progress = Float(value / 500) * Float(track.width)
        let secondary = Float(secondaryValue / 500) * Float(track.width)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)

        // Core Graphics standardizes negative rectangle widths. Android Canvas skips
        // them, so reject reversed/nonfinite rectangles without changing marker order.
        func fill(_ left: Float, _ right: Float, expanded: Bool = false, color: CGColor) {
            guard left.isFinite, right.isFinite, right > left else { return }
            let height: CGFloat = expanded ? 4 : 3
            context.setFillColor(color)
            context.fill(CGRect(x: track.minX + CGFloat(left), y: bounds.midY - height / 2,
                                width: CGFloat(right - left), height: height))
        }
        guard !chapterFractions.isEmpty else {
            fill(0, Float(track.width), color: background)
            fill(0, secondary, color: background)
            fill(0, progress, color: primary)
            return
        }
        let dividers = [Float(0)] + chapterFractions + [Float(1)]
        var current = 1
        for index in 1..<dividers.count {
            let right = dividers[index] * Float(track.width) - 1.2
            let left = dividers[index - 1] * Float(track.width)
            let currentRight = dividers[current] * Float(track.width) - 1.2
            let currentLeft = dividers[current - 1] * Float(track.width)
            fill(left, right, color: background)
            if secondary > 0, secondary < Float(track.width) {
                if right < secondary { fill(left, right, color: background) }
                else if secondary > left { fill(left, secondary, color: background) }
            }
            if right < progress {
                current = index + 1
                fill(left, right, color: primary)
            } else if chapterHighlightActive || isHighlighted {
                fill(currentLeft, currentRight, expanded: true, color: background)
                fill(currentLeft, progress, expanded: true, color: primary)
            } else {
                fill(currentLeft, progress, color: primary)
            }
        }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled else { return false }
        let point = touch.location(in: self)
        let offset = geometry.thumbCenter.x - point.x
        touchOffset = abs(offset) <= thumb.bounds.width / 2 ? offset : 0
        isHighlighted = true
        track(touch)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        track(touch)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch { track(touch) }
        isHighlighted = false
        sendActions(for: .editingDidEnd)
    }

    override func cancelTracking(with event: UIEvent?) {
        isHighlighted = false
        sendActions(for: .editingDidEnd)
    }

    private func track(_ touch: UITouch) {
        value = geometry.value(at: touch.location(in: self).x + touchOffset)
        sendActions(for: .valueChanged)
    }

    override func accessibilityIncrement() { adjust(by: 25) }
    override func accessibilityDecrement() { adjust(by: -25) }
    private func adjust(by amount: Float) {
        guard isEnabled else { return }
        let next = PlayerSeekLayout.quantize(value + amount)
        guard next != value else { return }
        value = next
        sendActions(for: .valueChanged)
        sendActions(for: .editingDidEnd)
    }
}
