import UIKit
import UniformTypeIdentifiers
import NotTennaPodCore

/// Source `ImportExportPreferencesFragment.importDatabase` (IEPF:189–262): the "Database import"
/// warning with No / Confirm, the system picker for any file (`ACTION_OPEN_DOCUMENT`, `*/*`), the
/// "Please wait…" progress, then either "Import successful" / "Please press OK to restart AntennaPod"
/// (not cancelable; OK restarts) or "Import error" with the failure text.
@MainActor final class DatabaseImportFlow: NSObject, UIDocumentPickerDelegate {
    private weak var host: UIViewController?
    private let presentMessage: (UIViewController) -> Void
    private let perform: @MainActor (URL) async throws -> Void
    private let restart: () -> Void
    private(set) var picker: UIDocumentPickerViewController?
    private weak var progress: PleaseWaitController?
    private var running = false
    /// The import's result dialog is on screen: its outcome was seen (the pending notice is acknowledged).
    var outcomeShown: (() -> Void)?

    init(host: UIViewController, presentMessage: @escaping (UIViewController) -> Void,
         perform: @escaping @MainActor (URL) async throws -> Void, restart: @escaping () -> Void, outcomeShown: (() -> Void)? = nil) {
        self.host = host; self.presentMessage = presentMessage; self.perform = perform; self.restart = restart
        self.outcomeShown = outcomeShown
    }

    func begin() {
        guard !running else { return }
        let dialog = SourceMessageController(title: Appearance.text("database_import_label"),
            message: Appearance.text("database_import_warning"),
            positive: .init(title: Appearance.text("confirm_label"), identifier: "databaseImportConfirm",
                            perform: { [weak self] in self?.choose() }, performAfterDismiss: true),
            negative: .init(title: Appearance.text("no"), identifier: "databaseImportNo"))
        presentMessage(dialog)
    }

    private func choose() {
        guard let host, !running else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self; picker.allowsMultipleSelection = false
        self.picker = picker
        host.present(picker, animated: true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if controller === picker { picker = nil }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard controller === picker else { return }
        picker = nil
        guard let url = urls.first else { return }
        start(url, pickerDismissing: controller)
    }

    /// Entry for a chosen file (also the mounted tests' stand-in for the out-of-process picker).
    func start(_ url: URL, pickerDismissing: UIViewController? = nil) {
        guard !running else { return }
        running = true
        let show = { [weak self] in
            guard let self, running, let host, host.viewIfLoaded?.window != nil, host.presentedViewController == nil else { return }
            let controller = PleaseWaitController()
            progress = controller
            host.present(controller, animated: true)
        }
        if let pickerDismissing, pickerDismissing.presentingViewController != nil { pickerDismissing.dismiss(animated: true, completion: show) }
        else { show() }
        Task { [weak self] in
            do {
                try await self?.perform(url)
                self?.finish { self?.showSuccess() }
            } catch {
                self?.finish { self?.showError(error) }
            }
        }
    }

    private func finish(then next: @escaping () -> Void) {
        running = false
        guard let controller = progress, controller.presentingViewController != nil else { next(); return }
        progress = nil
        if controller.isBeingPresented, let transition = controller.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { _ in Task { @MainActor in controller.dismiss(animated: true, completion: next) } }
        } else {
            controller.dismiss(animated: true, completion: next)
        }
    }

    private func showSuccess() {
        let dialog = SourceMessageController(title: Appearance.text("successful_import_label"),
            message: Appearance.text("import_ok"),
            positive: .init(title: Appearance.text("ok"), identifier: "databaseImportRestart", perform: { [restart] in restart() }, performAfterDismiss: true))
        dialog.allowsImplicitCancellation = false
        dialog.onAppear = { [weak self] in self?.outcomeShown?() }
        presentMessage(dialog)
    }

    private func showError(_ error: Error) {
        let message: String
        if case .newerVersion = error as? AndroidDatabaseRestore.Failure { message = Appearance.text("import_no_downgrade") }
        // Background time ended before the commit: rolled back, nothing changed.
        else if error is DatabaseImportInterrupted { message = Appearance.text("database_import_interrupted") }
        else { message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        let dialog = SourceMessageController(title: Appearance.text("import_error_label"), message: message)
        dialog.onAppear = { [weak self] in self?.outcomeShown?() }
        presentMessage(dialog)
    }
}
