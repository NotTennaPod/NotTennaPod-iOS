import UIKit

// Geometry and timing adapted from AOSP's Material progress drawables (2014/2016),
// Apache-2.0. See Licenses/Apache-2.0.txt and NOTICE.md.
@MainActor final class PlayerLoadingIndicator: UIView {
    @MainActor private final class Tick: NSObject {
        weak var owner: PlayerLoadingIndicator?
        @objc func step() { owner?.renderCurrentFrame() }
    }
    private let arc = CAShapeLayer()
    private let tick = Tick()
    private(set) var clock: CADisplayLink?
    private var epoch: CFTimeInterval = 0
    private(set) var isAnimating = false
    /// The spinner's player page is out of sight (collapsed to the mini player): its frame clock pauses and
    /// resumes at the current phase.
    var outOfSight = false {
        didSet {
            guard outOfSight != oldValue else { return }
            clock?.isPaused = outOfSight
            if !outOfSight { renderCurrentFrame() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        tick.owner = self
        isHidden = true
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "playerLoading"
        arc.fillColor = UIColor.clear.cgColor
        arc.lineCap = .square
        layer.addSublayer(arc)
        NotificationCenter.default.addObserver(self, selector: #selector(motionChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: PlayerLoadingIndicator, _) in
            view.renderCurrentFrame()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    isolated deinit { clock?.invalidate() }

    func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true; isHidden = false; epoch = CACurrentMediaTime()
        startClock(); renderCurrentFrame()
    }
    func stopAnimating() {
        isAnimating = false; isHidden = true
        clock?.invalidate(); clock = nil
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { clock?.invalidate(); clock = nil }
        else { startClock(); renderCurrentFrame() }
    }
    override func layoutSubviews() { super.layoutSubviews(); renderCurrentFrame() }
    @objc private func motionChanged() {
        clock?.invalidate(); clock = nil
        startClock(); renderCurrentFrame()
    }
    private func startClock() {
        guard isAnimating, window != nil, clock == nil, !UIAccessibility.isReduceMotionEnabled else { return }
        let link = CADisplayLink(target: tick, selector: #selector(Tick.step))
        link.isPaused = outOfSight
        link.add(to: .main, forMode: .common); clock = link
    }
    private func renderCurrentFrame() {
        render(at: CACurrentMediaTime() - epoch, reducedMotion: UIAccessibility.isReduceMotionEnabled)
    }

    /// Source has independent 1333ms trim/offset and 4444ms two-turn rotation clocks.
    static func angles(at elapsed: TimeInterval) -> (start: Double, end: Double) {
        let elapsed = max(0, elapsed)
        let phase = elapsed.truncatingRemainder(dividingBy: 1.333) / 1.333
        let rotation = elapsed.truncatingRemainder(dividingBy: 4.444) / 4.444 * 2
        let offset = phase * 0.25 + rotation
        return ((trim(phase - 0.5) * 0.75 + offset) * 2 * .pi - .pi / 2,
                (trim(phase) * 0.75 + offset) * 2 * .pi - .pi / 2)
    }
    // Android PathInterpolator uses Path.approximate(0.002), not the analytic cubic.
    // These vertices are runtime-verified from C0.2,0 0.1,1 0.5,1.
    private static let trimVertices: [(Double, Double)] = [
        (0, 0),
        (0.0178955085576, 0.00286865234375),
        (0.0341796875, 0.01123046875),
        (0.0489990264177, 0.0247192382812),
        (0.0625, 0.04296875),
        (0.0748291015625, 0.0656127929688),
        (0.0861328169703, 0.09228515625),
        (0.10625000298, 0.15625),
        (0.1240234375, 0.23193359375),
        (0.140625, 0.31640625),
        (0.175000011921, 0.5),
        (0.19511719048, 0.59326171875),
        (0.21875, 0.68359375),
        (0.2470703125, 0.76806640625),
        (0.28125, 0.84375),
        (0.322460949421, 0.90771484375),
        (0.346069335938, 0.934387207031),
        (0.371874988079, 0.95703125),
        (0.400024414062, 0.975280761719),
        (0.4306640625, 0.98876953125),
        (0.463940441608, 0.997131347656),
        (0.5, 1),
    ]
    static func trim(_ x: Double) -> Double {
        if x <= 0 { return 0 }; if x >= 0.5 { return 1 }
        for index in 1..<trimVertices.count where x <= trimVertices[index].0 {
            let left = trimVertices[index - 1], right = trimVertices[index]
            return left.1 + (right.1 - left.1) * (x - left.0) / (right.0 - left.0)
        }
        return 1
    }
    func render(at elapsed: TimeInterval, reducedMotion: Bool) {
        let side = min(bounds.width, bounds.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        arc.frame = bounds
        arc.strokeColor = Appearance.accent.resolvedColor(with: traitCollection).cgColor
        arc.fillColor = UIColor.clear.cgColor
        if reducedMotion {
            let path = Self.staticPath()
            path.apply(CGAffineTransform(scaleX: side / 24, y: side / 24))
            path.apply(CGAffineTransform(translationX: (bounds.width - side) / 2, y: (bounds.height - side) / 2))
            arc.path = path.cgPath; arc.lineWidth = 0
            arc.fillColor = arc.strokeColor
        } else {
            let angles = Self.angles(at: elapsed)
            arc.lineWidth = side / 12
            // The source's 48-unit viewport has radius18 and a four-unit square-cap stroke.
            arc.path = angles.end > angles.start ? UIBezierPath(arcCenter: CGPoint(x: bounds.width / 2, y: bounds.height / 2),
                radius: side * 18 / 48, startAngle: angles.start, endAngle: angles.end, clockwise: true).cgPath : nil
        }
        CATransaction.commit()
    }
    private static func staticPath() -> UIBezierPath {
        let p = UIBezierPath()
        p.move(to: .init(x:17.65,y:6.35))
        p.addCurve(to:.init(x:12,y:4),controlPoint1:.init(x:16.2,y:4.9),controlPoint2:.init(x:14.21,y:4))
        p.addCurve(to:.init(x:4.01,y:12),controlPoint1:.init(x:7.58,y:4),controlPoint2:.init(x:4.01,y:7.58))
        p.addCurve(to:.init(x:12,y:20),controlPoint1:.init(x:4.01,y:16.42),controlPoint2:.init(x:7.58,y:20))
        p.addCurve(to:.init(x:19.73,y:14),controlPoint1:.init(x:15.73,y:20),controlPoint2:.init(x:18.84,y:17.45))
        p.addLine(to:.init(x:17.65,y:14))
        p.addCurve(to:.init(x:12,y:18),controlPoint1:.init(x:16.83,y:16.33),controlPoint2:.init(x:14.61,y:18))
        p.addCurve(to:.init(x:6,y:12),controlPoint1:.init(x:8.69,y:18),controlPoint2:.init(x:6,y:15.31))
        p.addCurve(to:.init(x:12,y:6),controlPoint1:.init(x:6,y:8.69),controlPoint2:.init(x:8.69,y:6))
        p.addCurve(to:.init(x:16.22,y:7.78),controlPoint1:.init(x:13.66,y:6),controlPoint2:.init(x:15.1,y:6.69))
        p.addLine(to:.init(x:13,y:11)); p.addLine(to:.init(x:20,y:11)); p.addLine(to:.init(x:20,y:4))
        p.close(); return p
    }
}
