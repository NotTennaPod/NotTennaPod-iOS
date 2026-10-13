import UIKit
import NotTennaPodCore

/// What the Backup & restore host supplies. Snackbar placement, share presentation and the
/// modal-message queue stay owned by the host's existing conventions.
@MainActor protocol DocumentExportHost: UIViewController {
    func presentExportMessage(_ message: UIViewController)
    /// Shows source `Export successful` with a `Share` action. Returns false when it cannot be shown.
    func showExportSuccess(share: @escaping (_ anchor: CGRect) -> Void, dismissed: @escaping () -> Void) -> Bool
    func presentExportShare(_ activity: UIActivityViewController, anchor: CGRect)
}

/// Settings → Backup & restore → OPML export. One attempt owns the UI at a time; every begun write
/// settles independently. Leaving the screen or backgrounding the scene detaches pending UI (source
/// `onStop` disposes the observer), so no late progress, error or success appears afterwards.
@MainActor final class DocumentExportFlow: NSObject {
    typealias MakeOperation = @MainActor () throws -> DocumentExportOperation
    private weak var host: (any DocumentExportHost)?
    private let makeOperation: MakeOperation
    /// Retained until each write settles, whether or not its UI is still attached.
    private var operations: [ObjectIdentifier: DocumentExportOperation] = [:]
    private var attached: DocumentExportOperation?
    private weak var progress: PleaseWaitController?

    init(host: any DocumentExportHost, makeOperation: @escaping MakeOperation) {
        self.host = host; self.makeOperation = makeOperation
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(sceneEnteredBackground(_:)),
            name: UIScene.didEnterBackgroundNotification, object: nil)
    }

    private weak var newest: DocumentExportOperation?
    /// Most recently started attempt, for mounted tests that deliver a picker result.
    var pendingOperationForTesting: DocumentExportOperation? { newest }

    func begin() {
        guard let host else { return }
        let operation: DocumentExportOperation
        do { operation = try makeOperation() }
        catch { showError(error); return }
        operations[ObjectIdentifier(operation)] = operation
        newest = operation
        operation.onEvent = { [weak self, weak operation] event in
            guard let self, let operation else { return }
            handle(event, from: operation)
        }
        host.present(operation.picker, animated: true)
    }

    /// Route departure or scene stop. Begun writes continue; their feedback is suppressed.
    func detachInterface() {
        guard let operation = attached else { return }
        attached = nil
        if operation.phase == .ready { operation.release() }
        if let progress { dismissProgress(progress, animated: false) }
        progress = nil
    }

    @objc private func sceneEnteredBackground(_ note: Notification) {
        guard let scene = note.object as? UIScene, scene === host?.viewIfLoaded?.window?.windowScene else { return }
        detachInterface()
    }

    private func handle(_ event: DocumentExportOperation.Event, from operation: DocumentExportOperation) {
        switch event {
        case .cancelled:
            operations[ObjectIdentifier(operation)] = nil
        case .writing:
            // A newer destination supersedes an older attempt's pending feedback, not its write.
            if attached !== operation { detachInterface(); attached = operation }
            presentProgress(for: operation)
        case .succeeded:
            operations[ObjectIdentifier(operation)] = nil
            guard attached === operation else { operation.release(); return }
            finishProgress { [weak self] in self?.showSuccess(for: operation) }
        case .failed(let error):
            operations[ObjectIdentifier(operation)] = nil
            // A failure nobody sees (its feedback was detached) is reported at the next launch instead.
            guard attached === operation || operation.destination == nil else { return }
            if attached === operation { attached = nil }
            // Resolved only once the dialog is on screen, not when it is merely queued.
            finishProgress { [weak self] in self?.showError(error, shown: { operation.failureShown() }) }
        }
    }

    private func presentProgress(for operation: DocumentExportOperation) {
        let show = { [weak self, weak operation] in
            guard let self, let operation, attached === operation, operation.phase == .writing,
                  let host, host.viewIfLoaded?.window != nil, host.presentedViewController == nil else { return }
            let controller = PleaseWaitController()
            controller.onHidden = { [weak self, weak controller] in
                if self?.progress === controller { self?.progress = nil }
            }
            progress = controller
            host.present(controller, animated: true)
        }
        // The system picker may still be dismissing when it reports the destination.
        if let picker = host?.presentedViewController as? UIDocumentPickerViewController, picker === operation.picker {
            picker.dismiss(animated: true, completion: show)
        } else if let transition = host?.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { _ in show() }
        } else { show() }
    }

    private func finishProgress(then next: @escaping () -> Void) {
        guard let controller = progress else { next(); return }
        progress = nil
        dismissProgress(controller, animated: true, then: next)
    }

    /// UIKit ignores a dismissal requested while the dialog is still being presented; wait for
    /// that transition so a fast write or early detach can never leave progress stuck on screen.
    private func dismissProgress(_ controller: PleaseWaitController, animated: Bool, then next: (() -> Void)? = nil) {
        controller.onHidden = nil
        guard controller.presentingViewController != nil else { next?(); return }
        if controller.isBeingPresented, let transition = controller.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { [weak self] _ in
                Task { @MainActor in self?.dismissProgress(controller, animated: animated, then: next) }
            }
            return
        }
        controller.dismiss(animated: animated) { next?() }
    }

    private func showSuccess(for operation: DocumentExportOperation) {
        guard attached === operation, let host else { operation.release(); return }
        attached = nil
        // The success offer owns the finished attempt until it is dismissed or shared; nothing
        // else retains it once its write settled.
        var shared = false
        let shown = host.showExportSuccess(share: { [weak host] anchor in
            guard let host, let activity = operation.makeShare() else { return }
            shared = true
            host.presentExportShare(activity, anchor: anchor)
        }, dismissed: {
            if !shared { operation.release() }
        })
        if !shown { operation.release() }
    }

    private func showError(_ error: any Error, shown: (() -> Void)? = nil) {
        guard let host else { return }
        // Source MaterialAlertDialog: title, underlying message, OK dismisses. Retry = export again.
        let dialog = SourceMessageController(title: Appearance.text("export_error_label"), message: error.localizedDescription)
        dialog.view.accessibilityIdentifier = "opmlExportError"
        dialog.onAppear = shown
        host.presentExportMessage(dialog)
    }
}
