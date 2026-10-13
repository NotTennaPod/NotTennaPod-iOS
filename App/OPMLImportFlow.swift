import UIKit
import UniformTypeIdentifiers
import NotTennaPodCore

/// Picker and cold/warm document opens share one generation-fenced recipient.
@MainActor final class OPMLImportFlow: NSObject, UIDocumentPickerDelegate {
    private weak var host: UIViewController?
    private weak var picker: UIDocumentPickerViewController?
    private weak var screen: OPMLImportController?
    private let makeSession: () -> OPMLImportSession
    private let finished: () -> Void
    private let notice: (String) -> Void
    private var generation = UUID()
    private var pending: URL?
    init(host: UIViewController, makeSession: @escaping () -> OPMLImportSession,
         finished: @escaping () -> Void, notice: @escaping (String) -> Void) {
        self.host = host; self.makeSession = makeSession; self.finished = finished; self.notice = notice
    }
    func chooseDocument() {
        generation = UUID(); pending = nil
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: false)
        picker.allowsMultipleSelection = false; picker.delegate = self; self.picker = picker
        host?.present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard controller === picker else { return }
        picker = nil; let token = generation
        guard urls.count == 1, let url = urls.first else { return }
        controller.dismiss(animated: true) { [weak self] in
            guard let self, self.generation == token else { return }; self.open(url)
        }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard controller === picker else { return }; picker = nil; generation = UUID()
    }
    func open(_ url: URL) {
        generation = UUID(); pending = url; picker = nil
        screen?.session.close() // accepted work remains independently owned
        presentPendingDocument()
    }
    func presentPendingDocument() {
        guard pending != nil, let host else { return }
        // A fullscreen presentation may detach the covered host's view. Its
        // visible presented controller still establishes an active recipient;
        // an entirely detached hierarchy keeps a cold document pending.
        var recipient: UIViewController? = host
        while let current = recipient, current.viewIfLoaded?.window == nil {
            recipient = current.presentedViewController
        }
        guard recipient != nil else { return }
        let token = generation
        let show = { [weak self] in
            guard let self, self.generation == token, let url = self.pending, let host = self.host else { return }
            self.pending = nil
            let session = self.makeSession()
            // The controller and byte read must share the same session instance.
            self.present(session: session, url: url, host: host)
        }
        if let presented = host.presentedViewController { presented.dismiss(animated: false, completion: show) }
        else { show() }
    }
    private func present(session: OPMLImportSession, url: URL, host: UIViewController) {
        let controller = OPMLImportController(session: session); screen = controller
        controller.onFinished = finished; controller.onNotice = notice
        host.present(controller, animated: true) { session.load(url) }
    }
}
