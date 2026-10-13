import UIKit
import UniformTypeIdentifiers

/// System-owned directory selection; application navigation starts only for a
/// selection from the current picker. Cancellation leaves the library untouched.
@MainActor
final class LocalFolderPicker: NSObject, UIDocumentPickerDelegate {
    private weak var current: UIDocumentPickerViewController?
    private var selection: ((URL) -> Void)?

    func makeController(onSelection: @escaping (URL) -> Void) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        current = picker; selection = onSelection
        return picker
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard controller === current else { return }
        let action = selection
        current = nil; selection = nil
        guard urls.count == 1, let url = urls.first else { return }
        action?(url)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard controller === current else { return }
        current = nil; selection = nil
    }
}
