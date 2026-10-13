import UIKit
import NotTennaPodCore

/// Advances real scroll offsets each display frame, so retargeting and dragging
/// begin at the delivered position instead of a UIView animation's final model value.
@MainActor final class TranscriptScrollAnimator {
    @MainActor private final class Tick: NSObject {
        weak var owner: TranscriptScrollAnimator?
        @objc func fire(_ link: CADisplayLink) { owner?.advance(to: link.timestamp) }
    }
    private var link: CADisplayLink?
    private var animation: TranscriptScrollAnimation?
    private var update: ((CGFloat) -> Void)?
    private var start: CFTimeInterval = 0
    var isRunning: Bool { link != nil }
    isolated deinit { link?.invalidate() }

    func run(_ animation: TranscriptScrollAnimation, update: @escaping (CGFloat) -> Void) {
        cancel()
        if UIAccessibility.isReduceMotionEnabled { update(animation.targetOffset); return }
        self.animation = animation; self.update = update; start = CACurrentMediaTime()
        update(animation.initialOffset)
        if animation.value(at: 0).finished { update(animation.targetOffset); self.animation = nil; self.update = nil; return }
        let tick = Tick(); tick.owner = self
        let link = CADisplayLink(target: tick, selector: #selector(Tick.fire(_:)))
        self.link = link; link.add(to: .main, forMode: .common)
    }
    func cancel() { link?.invalidate(); link = nil; animation = nil; update = nil }
    private func advance(to timestamp: CFTimeInterval) {
        guard let animation else { return }
        let value = animation.value(at: timestamp - start)
        update?(value.offset)
        if value.finished { cancel() }
    }
}
