import UIKit

/// TimeRangeDialog saves its draft on every dismissal, including outside/Back.
@MainActor final class SleepTimerTimeRangeController: SourceMessageController {
    let dial: SleepTimerTimeRangeDial
    var from: Int { dial.from }
    var to: Int { dial.to }
    private let onDismissRange: (Int, Int) -> Void
    private var delivered = false

    init(from: Int, to: Int, onDismiss: @escaping (Int, Int) -> Void) {
        dial = SleepTimerTimeRangeDial(from: from, to: to)
        onDismissRange = onDismiss
        super.init(message: "", positive: .init(title: Appearance.text("ok"), identifier: "sleepTimerTimeRangeOK"), customBody: dial)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        super.dismiss(animated: flag) { [self] in
            deliver(); completion?()
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Also cover dismissal by the presenting owner, which need not call our override.
        if isBeingDismissed || presentingViewController == nil { deliver() }
    }
    private func deliver() {
        guard !delivered else { return }
        delivered = true; onDismissRange(from, to)
    }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapeRange))]
    }
    @objc private func escapeRange() { _ = accessibilityPerformEscape() }
}

/// A clockwise 24-hour clock. Clock geometry intentionally does not mirror in RTL.
@MainActor final class SleepTimerTimeRangeDial: UIControl {
    private(set) var from: Int
    private(set) var to: Int
    private var touching = 0
    private lazy var fromElement = Endpoint(owner: self, start: true)
    private lazy var toElement = Endpoint(owner: self, start: false)
    init(from: Int, to: Int) {
        self.from = ((from % 24) + 24) % 24; self.to = ((to % 24) + 24) % 24
        super.init(frame: .zero)
        backgroundColor = .clear; isOpaque = false
        accessibilityIdentifier = "sleepTimerTimeRangeDial"
        isAccessibilityElement = false; accessibilityElements = [fromElement, toElement]
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = max(0, min(size.width, size.height))
        return CGSize(width: width, height: width)
    }
    func point(hour: CGFloat, radius: CGFloat? = nil) -> CGPoint {
        let size = min(bounds.width, bounds.height), angle = hour / 24 * 2 * .pi
        let radius = radius ?? size * 0.4
        return CGPoint(x: bounds.midX + radius * sin(angle), y: bounds.midY - radius * cos(angle))
    }
    private func angle(at point: CGPoint) -> CGFloat {
        let degrees = atan2(point.x - bounds.midX, bounds.midY - point.y) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }
    @discardableResult func beginDrag(at point: CGPoint) -> Bool {
        let angle = angle(at: point)
        func near(_ hour: Int) -> Bool {
            let distance = abs(angle - CGFloat(hour) * 15)
            return distance < 15 || distance > 345
        }
        touching = near(from) ? 1 : near(to) ? 2 : 0
        return touching != 0
    }
    func moveDrag(to point: CGPoint) {
        guard touching != 0 else { return }
        let hour = min(23, Int(angle(at: point) / 15))
        if from == to { touching = (hour - to + 24) % 24 < 12 ? 1 : 2 }
        let previous = (from, to)
        if touching == 1 { from = hour } else { to = hour }
        // Touch moves arrive every frame; repaint only when an end moves to another hour.
        if (from, to) != previous { changed() }
    }
    func endDrag() { touching = 0 }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        beginDrag(at: touch.location(in: self))
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        moveDrag(to: touch.location(in: self)); return touching != 0
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) { endDrag() }
    override func cancelTracking(with event: UIEvent?) { endDrag() }
    private func changed() {
        setNeedsDisplay(); setNeedsLayout(); sendActions(for: .valueChanged)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        for (element, hour) in [(fromElement, from), (toElement, to)] {
            let center = point(hour: CGFloat(hour)), side = max(44, bounds.width * 0.1)
            element.accessibilityFrameInContainerSpace = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        }
    }
    private var uses24HourTime: Bool {
        !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? true)
    }
    private func hourText(_ hour: Int) -> String {
        if uses24HourTime { return String(format: "%02d:00", locale: Locale.current, hour) }
        return String(format: "%02d:00 %@", locale: Locale.current, hour % 12, hour >= 12 ? "PM" : "AM")
    }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let size = min(bounds.width, bounds.height)
        guard size > 0 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY), radius = size * 0.4
        let muted = Appearance.foreground.withAlphaComponent(120 / 255)
        context.setLineCap(.round); context.setStrokeColor(muted.cgColor); context.setLineWidth(size * 0.005)
        context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        func text(_ value: String, at point: CGPoint, size: CGFloat, color: UIColor) {
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont(name: "Roboto-Regular", size: size) ?? UIFont.systemFont(ofSize: size), .foregroundColor: color]
            let measured = (value as NSString).size(withAttributes: attributes)
            (value as NSString).draw(at: CGPoint(x: point.x - measured.width / 2, y: point.y - measured.height / 2), withAttributes: attributes)
        }
        for hour in 0..<24 {
            context.setLineWidth(size * (hour % 6 == 0 ? 0.01 : 0.005))
            context.move(to: point(hour: CGFloat(hour), radius: size * 0.33))
            context.addLine(to: point(hour: CGFloat(hour), radius: size * 0.31)); context.strokePath()
            if hour % 6 == 0 { text(String(hour), at: point(hour: CGFloat(hour), radius: size * 0.25), size: size * 0.04, color: muted) }
        }
        let start = CGFloat(from) / 24 * 2 * .pi - .pi / 2
        let sweep = from == to ? 2 * CGFloat.pi : CGFloat((to - from + 24) % 24) / 24 * 2 * .pi
        context.setStrokeColor(Appearance.accent.cgColor); context.setLineWidth(size / 60)
        context.addArc(center: center, radius: radius, startAngle: start, endAngle: start + sweep, clockwise: false); context.strokePath()
        context.setFillColor(Appearance.accent.cgColor)
        for hour in [from, to] {
            let point = point(hour: CGFloat(hour)), radius = size * 0.05
            context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
        if from == to { text(Appearance.text("sleep_timer_always"), at: center, size: size * 0.06, color: Appearance.foreground) }
        else if uses24HourTime { text(hourText(from) + " - " + hourText(to), at: center, size: size * 0.06, color: Appearance.foreground) }
        else {
            for (index, line) in [hourText(from), "-", hourText(to)].enumerated() {
                text(line, at: CGPoint(x: center.x, y: center.y + CGFloat(index - 1) * size * 0.06), size: size * 0.06, color: Appearance.foreground)
            }
        }
    }
    @MainActor private final class Endpoint: UIAccessibilityElement {
        weak var owner: SleepTimerTimeRangeDial?
        let start: Bool
        init(owner: SleepTimerTimeRangeDial, start: Bool) {
            self.owner = owner; self.start = start
            super.init(accessibilityContainer: owner)
            accessibilityIdentifier = start ? "sleepTimerTimeRangeFrom" : "sleepTimerTimeRangeTo"
            accessibilityLabel = Appearance.text(start ? "sleep_timer_range_from" : "sleep_timer_range_to")
            accessibilityTraits = [.adjustable]
        }
        override var accessibilityValue: String? {
            get { owner.map { $0.hourText(start ? $0.from : $0.to) } }
            set { }
        }
        override func accessibilityIncrement() { adjust(1) }
        override func accessibilityDecrement() { adjust(-1) }
        private func adjust(_ delta: Int) {
            guard let owner else { return }
            if start { owner.from = (owner.from + delta + 24) % 24 }
            else { owner.to = (owner.to + delta + 24) % 24 }
            owner.changed()
        }
    }
}
