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
    /// An accepted swipe's action, settled when the finger lifts (the episode, the action, and the model and library
    /// valid then). Calling it starts the action; its task ends when the action is over and the screen shows the result.
    typealias Accepted = @MainActor () -> Task<Void, Never>?
    private weak var row: UIView?
    private let background = UIView(), icon = UIImageView()
    private let configuration: (EpisodeSwipeDirection) -> Configuration?
    private let accept: (EpisodeSwipeDirection) -> Accepted?
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
    private var motion: EpisodeSwipeMotion?
    private var current: Configuration?
    private var generation = 0
    /// The part of the row's width the background shows, and on which side.
    private var exposed: (width: CGFloat, direction: EpisodeSwipeDirection) = (0, .left)
    /// The row is being swiped, slides, or is held out until its removal lands: a patch neither builds it again nor
    /// retires its action binding (`LibraryViewController.holdForSwipe`).
    private(set) var isActive = false
    /// A patch held back a change of the row while its swipe was active: the row catches up when the swipe ends.
    var heldBack = false
    var caughtUp: (() -> Void)?
    /// A removing swipe's row stays slid out until its removal lands, as Android's does; it comes back only if the action
    /// is over and the row is still in its list.
    private var heldOut = false
    var reduceMotion: () -> Bool = { UIAccessibility.isReduceMotionEnabled }
    init(row: UIView, configuration: @escaping (EpisodeSwipeDirection) -> Configuration?, accept: @escaping (EpisodeSwipeDirection) -> Accepted?) {
        self.row = row; self.configuration = configuration; self.accept = accept
        super.init()
        background.isUserInteractionEnabled = false; background.backgroundColor = Appearance.elevated
        background.isHidden = true; background.clipsToBounds = true; icon.contentMode = .scaleAspectFit; background.addSubview(icon)
        pan.delegate = self; row.addGestureRecognizer(pan)
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let row, !heldOut else { return false }
        let velocity = pan.velocity(in: row)
        // Even a disabled swipe is a drag, not a row tap. Recognize horizontal
        // movement to cancel the underlying button; nil configuration performs nothing.
        return abs(velocity.x) > abs(velocity.y)
    }
    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        guard !heldOut, let row, let container = row.superview else { return }
        let translation = recognizer.translation(in: container).x
        switch recognizer.state {
        case .began, .changed:
            let direction: EpisodeSwipeDirection = translation > 0 ? .right : .left
            guard let settings = configuration(direction) else { restore(); return }
            if recognizer.state == .began { row.layer.removeAllAnimations() }
            // A slide back still under way (a side without an action, then back) ends no longer: the swipe goes on.
            generation += 1; isActive = true
            current = settings
            let value = EpisodeSwipeMotion(translation: translation, width: row.bounds.width, removes: settings.removes)
            motion = value
            if background.superview !== container { container.insertSubview(background, belowSubview: row) }
            exposed = (min(row.bounds.width, abs(value.displacement)), direction)
            placeBackground()
            background.isHidden = false
            icon.image = UIImage(named: settings.icon)
            let actionColor = settings.color
            icon.tintColor = blend(Appearance.background, actionColor, fraction: settings.removes || value.reached ? 1 : 0.7)
            row.transform = CGAffineTransform(translationX: value.displacement, y: 0)
        case .ended:
            guard let value = motion, let settings = current else { restore(); return }
            let velocity = recognizer.velocity(in: container)
            guard value.commits(velocityX: velocity.x, velocityY: velocity.y, removes: settings.removes),
                  let action = accept(value.direction) else { restore(); return }
            let duration = animationDuration
            if settings.removes {
                // The row stays out until the removal lands (the row leaves its list), or comes back if it doesn't.
                heldOut = true; generation += 1; motion = nil; current = nil
                exposed = (row.bounds.width, value.direction)
                UIView.animate(withDuration: duration) { [self] in
                    row.transform = CGAffineTransform(translationX: value.direction == .right ? row.bounds.width : -row.bounds.width, y: 0)
                    placeBackground()
                }
                Self.run(after: duration) { [weak self] in
                    await action()?.value
                    self?.removalOver()
                }
            } else {
                restore()
                Self.run(after: duration) { _ = action() }
            }
        case .cancelled, .failed: restore()
        default: break
        }
    }
    /// The background is a sibling of the row in its list: it leaves with the row (removed, rebuilt or released), and
    /// the swipe ends there. An accepted action still runs.
    func rowWillLeave() {
        background.isHidden = true
        background.removeFromSuperview()
        generation += 1; motion = nil; current = nil
        heldOut = false; isActive = false; heldBack = false
    }
    /// The row moved in its list (a patch shifted it): the background moves with it.
    func rowMoved() {
        guard !background.isHidden, let row, background.superview === row.superview else { return }
        placeBackground()
    }
    /// The accepted removal is over and the screen shows its result: a row still in its list was not removed, and comes back.
    private func removalOver() {
        guard heldOut else { return }
        heldOut = false
        restore()
    }
    private func restore() {
        generation += 1; let token = generation
        motion = nil; current = nil
        guard isActive, let row else { return }
        let duration = animationDuration
        UIView.animate(withDuration: duration) { row.transform = .identity }
        Self.run(after: duration) { [weak self] in
            guard let self, token == generation else { return }
            background.isHidden = true
            isActive = false
            if heldBack { heldBack = false; caughtUp?() }
        }
    }
    private var animationDuration: TimeInterval { reduceMotion() ? 0 : 0.25 }
    /// Runs `body` once after `seconds`, on its own: neither the row, its window nor its animation decides whether it runs.
    private static func run(after seconds: TimeInterval, _ body: @escaping @MainActor () async -> Void) {
        Task { @MainActor in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            await body()
        }
    }
    private func placeBackground() {
        guard let row else { return }
        let width = row.bounds.width, height = row.bounds.height
        let origin = CGPoint(x: row.center.x - width/2, y: row.center.y - height/2)
        background.frame = CGRect(x: origin.x + (exposed.direction == .right ? 0 : width - exposed.width), y: origin.y,
                                  width: exposed.width, height: height)
        icon.frame = CGRect(x: exposed.direction == .right ? 16 : exposed.width - 40, y: (height-24)/2, width: 24, height: 24)
    }
    private func blend(_ from: UIColor, _ to: UIColor, fraction: CGFloat) -> UIColor {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        from.resolvedColor(with: row?.traitCollection ?? .current).getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        to.resolvedColor(with: row?.traitCollection ?? .current).getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(red: ar+(br-ar)*fraction, green: ag+(bg-ag)*fraction, blue: ab+(bb-ab)*fraction, alpha: 1)
    }
}
