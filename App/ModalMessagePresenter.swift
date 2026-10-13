import UIKit

/// Retains asynchronous messages until the current presentation transition settles.
@MainActor
final class ModalMessagePresenter {
    private weak var owner: UIViewController?
    private var pending: [UIViewController] = []
    private var isPresenting = false
    private var isWaitingForTransition = false

    init(owner: UIViewController) { self.owner = owner }

    func present(_ message: UIViewController) {
        pending.append(message)
        resume()
    }

    /// Also called when the owner appears, so errors arriving before attachment survive.
    func resume() {
        guard !pending.isEmpty, !isPresenting, !isWaitingForTransition, let owner else { return }
        var presenter = owner
        while let next = presenter.presentedViewController { presenter = next }
        if let transition = presenter.transitionCoordinator {
            isWaitingForTransition = true
            transition.animate(alongsideTransition: nil) { [weak self] _ in
                // UIKit finishes updating the presentation chain after its transition callbacks.
                Task { @MainActor [weak self] in
                    self?.isWaitingForTransition = false
                    self?.resume()
                }
            }
            return
        }
        guard presenter.viewIfLoaded?.window != nil,
              !presenter.isBeingPresented, !presenter.isBeingDismissed else { return }
        let message = pending.removeFirst()
        isPresenting = true
        presenter.present(message, animated: true) { [weak self] in
            self?.isPresenting = false
            self?.resume()
        }
    }
}
