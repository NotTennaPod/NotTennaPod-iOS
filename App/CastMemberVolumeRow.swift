import UIKit

@MainActor final class CastMemberVolumeRow: UIView {
    private let name = Appearance.label(nil, size: 14)
    private let icon = UIImageView(image: UIImage(named: "cast_audio"))
    private let slider = CastReceiverVolumeSlider()
    private var retiring = false
    private var member: CastGroupMember
    var landscape = false
    var needsInitialPlacement = true
    init(member: CastGroupMember, begin: @escaping () -> Void, end: @escaping () -> Void, change: @escaping (Float) -> Void, relayout: @escaping () -> Void) {
        self.member = member
        super.init(frame: .zero)
        accessibilityIdentifier = "castMember-" + member.id
        for child in [name, icon, slider] { addSubview(child) }
        name.textColor = .white; name.numberOfLines = 1; name.lineBreakMode = .byTruncatingTail
        icon.tintColor = .white
        slider.accessibilityIdentifier = "castMemberVolume-" + member.id
        slider.addAction(UIAction { [weak self] _ in
            guard let self, !retiring, self.member.hasVariableVolume else { return }
            change(slider.value)
        }, for: .valueChanged)
        slider.addAction(UIAction { [weak self] _ in
            guard let self, !retiring else { return }; begin()
        }, for: .editingDidBegin)
        slider.addAction(UIAction { [weak self] _ in
            guard let self, !retiring else { return }; end()
        }, for: .editingDidEnd)
        name.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (_: UILabel, _) in relayout() }
        render(member)
    }
    required init?(coder: NSCoder) { fatalError() }
    func height(landscape: Bool) -> CGFloat {
        name.font = Appearance.font(14, compatibleWith: name.traitCollection)
        return max(landscape ? 61 : 68, ceil(name.font.lineHeight) + (landscape ? 42 : 48))
    }
    func render(_ next: CastGroupMember) {
        member = next; name.text = next.name
        slider.accessibilityLabel = next.name + ", " + Appearance.text("mr_controller_volume_slider")
        slider.isEnabled = next.hasVariableVolume
        if !next.hasVariableVolume { cancelInteraction() }
        slider.value = next.hasVariableVolume ? (next.muted ? 0 : next.volume) : 1
    }
    func updateVolume(_ next: CastGroupMember) { slider.value = next.muted ? 0 : next.volume }
    private func cancelInteraction() {
        let wasRetiring = retiring; retiring = true
        slider.cancelTracking(with: nil)
        retiring = wasRetiring
    }
    func retire() { retiring = true; cancelInteraction() }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rtl ? bounds.width - x - w : x, y: y, width: w, height: h)
        }
        let nameHeight = max(20, ceil(name.font.lineHeight)), iconSize: CGFloat = landscape ? 18 : 24
        name.frame = frame(24, 0, max(0, bounds.width - 84), nameHeight)
        name.textAlignment = rtl ? .right : .left
        icon.frame = frame(24, nameHeight + 8, iconSize, iconSize)
        // Original horizontal row is icon+8+8 high; its40-point slider is
        // centered in that row (three points above its top in landscape).
        slider.frame = frame(24 + iconSize, nameHeight + (iconSize + 16 - 40) / 2, max(0, bounds.width - 84 - iconSize), 40)
        slider.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
    }
}

/// Unmodified Android xxxhdpi frames displayed in the original24-point icon box.
@MainActor final class CastGroupChevron: UIView {
    private let iconMask = CALayer()
    private var expanded: Bool?
    init(button: UIButton) {
        super.init(frame: .zero); isUserInteractionEnabled = false
        translatesAutoresizingMaskIntoConstraints = false; layer.mask = iconMask; backgroundColor = .white
        button.addSubview(self)
        NSLayoutConstraint.activate([centerXAnchor.constraint(equalTo: button.centerXAnchor), centerYAnchor.constraint(equalTo: button.centerYAnchor), widthAnchor.constraint(equalToConstant: 24), heightAnchor.constraint(equalToConstant: 24)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() { super.layoutSubviews(); CATransaction.begin(); CATransaction.setDisableActions(true); iconMask.frame = bounds; CATransaction.commit() }
    func update(expanded: Bool) {
        guard self.expanded != expanded else { return }
        let animate = self.expanded != nil; self.expanded = expanded
        let sequence = expanded ? "expand" : "collapse"
        let frames = (0..<16).compactMap { UIImage(named: String(format: "cast_group_%@_%02d", sequence, $0))?.cgImage }
        guard frames.count == 16 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true); iconMask.contents = frames.last; CATransaction.commit()
        iconMask.removeAnimation(forKey: "groupFrames")
        if animate {
            let animation = CAKeyframeAnimation(keyPath: "contents"); animation.values = frames
            animation.keyTimes = (0...16).map { NSNumber(value: Double($0) / 16) }
            animation.calculationMode = .discrete; animation.duration = 16 * 0.013
            iconMask.add(animation, forKey: "groupFrames")
        }
    }
}
