import UIKit
import NotTennaPodCore

@MainActor final class EpisodeRowSwipe: NSObject, UIGestureRecognizerDelegate {
    @MainActor struct Configuration {
        let action: DownloadsSwipeAction?
        let inboxAction: SwipeAction?
        let removes: Bool
        init(action: DownloadsSwipeAction?, removes: Bool) {
            self.action = action; inboxAction = nil; self.removes = removes
        }
        init(inboxAction: SwipeAction, removes: Bool) {
            action = nil; self.inboxAction = inboxAction; self.removes = removes
        }
        var icon: String { inboxAction?.icon ?? action?.icon ?? "ic_settings" }
        var color: UIColor { inboxAction?.swipeColor ?? action?.swipeColor ?? Appearance.color(0x25365a, 0xcdd9e4) }
    }
    private weak var row: UIView?
    private let background = UIView(), icon = UIImageView()
    private let configuration: (EpisodeSwipeDirection) -> Configuration?
    private let perform: (EpisodeSwipeDirection) -> Void
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
    private var motion: EpisodeSwipeMotion?
    private var current: Configuration?
    private var generation = 0
    init(row: UIView, configuration: @escaping (EpisodeSwipeDirection) -> Configuration?, perform: @escaping (EpisodeSwipeDirection) -> Void) {
        self.row = row; self.configuration = configuration; self.perform = perform
        super.init()
        background.isUserInteractionEnabled = false; background.backgroundColor = Appearance.elevated
        background.isHidden = true; background.clipsToBounds = true; icon.contentMode = .scaleAspectFit; background.addSubview(icon)
        pan.delegate = self; row.addGestureRecognizer(pan)
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let row else { return false }
        let velocity = pan.velocity(in: row)
        // Even a disabled swipe is a drag, not a row tap. Recognize horizontal
        // movement to cancel the underlying button; nil configuration performs nothing.
        return abs(velocity.x) > abs(velocity.y)
    }
    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        guard let row, let container = row.superview else { return }
        let translation = recognizer.translation(in: container).x
        switch recognizer.state {
        case .began, .changed:
            let direction: EpisodeSwipeDirection = translation > 0 ? .right : .left
            guard let settings = configuration(direction) else { restore(); return }
            if recognizer.state == .began { generation += 1; row.layer.removeAllAnimations() }
            current = settings
            let value = EpisodeSwipeMotion(translation: translation, width: row.bounds.width, removes: settings.removes)
            motion = value
            if background.superview !== container { container.insertSubview(background, belowSubview: row) }
            let exposed = min(row.bounds.width, abs(value.displacement))
            let origin = CGPoint(x: row.center.x - row.bounds.width/2, y: row.center.y - row.bounds.height/2)
            background.frame = CGRect(x: origin.x + (direction == .right ? 0 : row.bounds.width - exposed), y: origin.y, width: exposed, height: row.bounds.height)
            background.isHidden = false
            icon.image = UIImage(named: settings.icon)
            let actionColor = settings.color
            icon.tintColor = blend(Appearance.background, actionColor, fraction: settings.removes || value.reached ? 1 : 0.7)
            icon.frame = CGRect(x: direction == .right ? 16 : background.bounds.width-40, y: (row.bounds.height-24)/2, width: 24, height: 24)
            row.transform = CGAffineTransform(translationX: value.displacement, y: 0)
        case .ended:
            guard let value = motion, let settings = current else { restore(); return }
            let velocity = recognizer.velocity(in: container)
            let commits = value.commits(velocityX: velocity.x, velocityY: velocity.y, removes: settings.removes)
            if commits && settings.removes {
                generation += 1; let token = generation
                UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25, animations: {
                    row.transform = CGAffineTransform(translationX: value.direction == .right ? row.bounds.width : -row.bounds.width, y: 0)
                }, completion: { [weak self, weak row] _ in
                    guard let self, token == generation, row?.window != nil else { return }
                    restore(); perform(value.direction)
                })
            } else { restore(action: commits ? value.direction : nil) }
        case .cancelled, .failed: restore()
        default: break
        }
    }
    private func restore(action: EpisodeSwipeDirection? = nil) {
        generation += 1; let token = generation
        motion = nil; current = nil
        guard let row else { return }
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25, animations: { row.transform = .identity }, completion: { [weak self] _ in
            guard let self, token == generation else { return }
            background.isHidden = true
            if let action, self.row?.window != nil { perform(action) }
        })
    }
    private func blend(_ from: UIColor, _ to: UIColor, fraction: CGFloat) -> UIColor {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        from.resolvedColor(with: row?.traitCollection ?? .current).getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        to.resolvedColor(with: row?.traitCollection ?? .current).getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(red: ar+(br-ar)*fraction, green: ag+(bg-ag)*fraction, blue: ab+(bb-ab)*fraction, alpha: 1)
    }
}
