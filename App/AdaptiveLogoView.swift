import UIKit
import NotTennaPodCore

@MainActor
final class AdaptiveLogoView: UIView {
    private let background = UIImageView()
    private let foreground = UIImageView()

    init() {
        super.init(frame: .zero)
#if DEBUG
        let variant = "debug"
#else
        let variant = "main"
#endif
        background.image = UIImage(named: "Logo-\(variant)-background")
        foreground.image = UIImage(named: "Logo-\(variant)-foreground")
        clipsToBounds = true
        addSubview(background)
        addSubview(foreground)
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        background.frame = bounds.insetBy(dx: -bounds.width / 4, dy: -bounds.height / 4)
        foreground.frame = background.frame
    }
}
