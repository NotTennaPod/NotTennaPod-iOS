import UIKit
import NotTennaPodCore

/// Original 40-point circle, 2.5-point black ring and 10×5 arrow. Its position
/// belongs to the current episode viewport, outside the scrolling content.
@MainActor final class FeedRefreshIndicator: UIView {
    @MainActor private final class Tick: NSObject {
        weak var view: FeedRefreshIndicator?
        @objc func step() { view?.drawRunningFrame() }
    }
    private let ring = CAShapeLayer(), arrow = CAShapeLayer(), pullMask = CAShapeLayer()
    private let tick = Tick()
    private var displayLink: CADisplayLink?
    private var epoch: CFTimeInterval = 0
    private var running = false
    private var lastPull: FeedPullRefresh.Geometry?
    private var spinner = FeedRefreshSpinner()

    override init(frame: CGRect) {
        super.init(frame: frame)
        tick.view = self
        isUserInteractionEnabled = false
        backgroundColor = UIColor(white: 250 / 255, alpha: 1)
        layer.cornerRadius = 20
        layer.shadowColor = UIColor.black.cgColor; layer.shadowOpacity = 0.25
        layer.shadowRadius = 2; layer.shadowOffset = CGSize(width: 0, height: 2)
        ring.strokeColor = UIColor.black.cgColor; ring.fillColor = UIColor.clear.cgColor
        ring.lineWidth = 2.5
        arrow.fillColor = UIColor.black.cgColor
        layer.addSublayer(ring); layer.addSublayer(arrow)
        isAccessibilityElement = true; accessibilityIdentifier = "feedRefreshProgress"
        accessibilityLabel = Appearance.text("feed_refresh_title")
    }
    required init?(coder: NSCoder) { fatalError() }
    isolated deinit { displayLink?.invalidate() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { displayLink?.invalidate(); displayLink = nil }
        else if running { startClock() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if running { drawRunningFrame() }
        else if let lastPull { drawPull(lastPull) }
    }
    func setRunning(_ value: Bool) {
        layer.mask = nil; isHidden = !value
        if !value {
            running = false; lastPull = nil
            displayLink?.invalidate(); displayLink = nil
            return
        }
        if !running {
            spinner = FeedRefreshSpinner(finishing: lastPull)
            epoch = CACurrentMediaTime(); running = true; lastPull = nil
        }
        startClock(); drawRunningFrame()
    }
    private func startClock() {
        guard window != nil, displayLink == nil, !UIAccessibility.isReduceMotionEnabled else { return }
        let link = CADisplayLink(target: tick, selector: #selector(Tick.step))
        link.add(to: .main, forMode: .common); displayLink = link
    }
    private func drawRunningFrame() {
        let frame = spinner.frame(at: UIAccessibility.isReduceMotionEnabled ? 0.333 : CACurrentMediaTime() - epoch)
        draw(start: frame.start, end: frame.end, arrowScale: frame.arrowScale, opacity: 1)
    }
    func setPull(_ geometry: FeedPullRefresh.Geometry) {
        running = false; displayLink?.invalidate(); displayLink = nil
        lastPull = geometry; isHidden = false
        drawPull(geometry)
        pullMask.path = UIBezierPath(rect: CGRect(x: -4, y: max(-4, -geometry.offset), width: 48, height: 48)).cgPath
        layer.mask = pullMask
    }
    private func drawPull(_ geometry: FeedPullRefresh.Geometry) {
        draw(start: geometry.rotation, end: geometry.rotation + geometry.endTrim,
             arrowScale: geometry.arrowScale, opacity: geometry.opacity)
    }
    private func draw(start: Double, end: Double, arrowScale: Double, opacity: Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.frame = bounds; arrow.frame = bounds
        ring.opacity = Float(opacity); arrow.opacity = Float(opacity)
        let center = CGPoint(x: bounds.midX, y: bounds.midY), radius = 8.75
        let angle = start.truncatingRemainder(dividingBy: 1) * 2 * .pi
        let endAngle = angle + (end - start) * 2 * .pi
        ring.path = UIBezierPath(arcCenter: center, radius: radius, startAngle: angle, endAngle: endAngle, clockwise: true).cgPath
        let path = UIBezierPath()
        path.move(to: CGPoint(x: center.x + radius - 5 * arrowScale, y: center.y + 1.25))
        path.addLine(to: CGPoint(x: center.x + radius + 5 * arrowScale, y: center.y + 1.25))
        path.addLine(to: CGPoint(x: center.x + radius, y: center.y + 1.25 + 5 * arrowScale))
        path.close()
        var transform = CGAffineTransform(translationX: center.x, y: center.y)
        transform = transform.rotated(by: endAngle).translatedBy(x: -center.x, y: -center.y)
        path.apply(transform)
        arrow.path = path.cgPath; arrow.isHidden = arrowScale == 0
        CATransaction.commit()
    }
}
