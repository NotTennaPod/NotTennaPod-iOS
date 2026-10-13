import UIKit

/// Original MediaRouter animation lists:31 frames,42ms each. Animate the source
/// alpha masks so template tint changes do not replace an in-flight sequence.
@MainActor final class CastButtonIndicator: UIView {
    private let iconMask = CALayer()
    private var phase: CastConnectionState.Phase?
    private static let animationKey = "castFrames"
    init(button: UIButton) {
        super.init(frame: .zero)
        button.setImage(nil, for: .normal)
        isUserInteractionEnabled = false
        translatesAutoresizingMaskIntoConstraints = false
        layer.mask = iconMask
        button.addSubview(self)
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: button.centerXAnchor),
            centerYAnchor.constraint(equalTo: button.centerYAnchor),
            widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalToConstant: 24)
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (view: CastButtonIndicator, _) in view.refreshImages() }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        iconMask.frame = bounds
        CATransaction.commit()
    }
    override func tintColorDidChange() { super.tintColorDidChange(); backgroundColor = tintColor }
    private func image(_ name: String) -> UIImage? { UIImage(named: name, in: .main, compatibleWith: traitCollection) }
    private func refreshImages() {
        guard let phase else { return }
        let base = image(phase == .connected ? "cast_connected" : "cast_device")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        iconMask.contents = base?.cgImage; iconMask.contentsScale = base?.scale ?? traitCollection.displayScale
        CATransaction.commit()
        backgroundColor = tintColor
        if let animation = iconMask.animation(forKey: Self.animationKey)?.copy() as? CAKeyframeAnimation {
            animation.values = frames(phase)
            iconMask.add(animation, forKey: Self.animationKey)
        }
    }
    private func frames(_ phase: CastConnectionState.Phase) -> [CGImage] {
        let sequence = phase == .connecting ? "connecting" : "connected"
        return (0..<31).compactMap { image(String(format: "cast_%@_%02d", sequence, $0))?.cgImage }
    }
    func update(_ next: CastConnectionState.Phase) {
        guard phase != next else { return }
        let previous = phase; phase = next
        iconMask.removeAnimation(forKey: Self.animationKey)
        refreshImages()
        guard next == .connecting || (next == .connected && previous != nil) else { return }
        let values = frames(next)
        guard values.count == 31 else { return }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = values
        // Discrete values each occupy an interval, including the final frame.
        animation.keyTimes = (0...31).map { NSNumber(value: Double($0) / 31) }
        animation.calculationMode = .discrete
        animation.duration = 31 * 0.042
        animation.repeatCount = next == .connecting ? .infinity : 1
        animation.beginTime = iconMask.convertTime(CACurrentMediaTime(), from: nil)
        iconMask.add(animation, forKey: Self.animationKey)
    }
}
