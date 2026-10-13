import UIKit
import UniformTypeIdentifiers

/// Share Extension. Android's `OnlineFeedViewActivity` receives
/// SEND `text/plain` as one `EXTRA_TEXT`; here the share sheet's web link (Safari) or text is handed,
/// unchanged, to AntennaPod, which takes its first link, prepares it and shows
/// the podcast preview. There is no UI of its own.
final class ShareViewController: UIViewController {
    private var handled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !handled else { return }
        handled = true
        Task { @MainActor [self] in
            let shared = await sharedItems()
            let text = ShareHandoff.sharedText(url: shared.url, text: shared.text)
            guard let link = ShareHandoff.url(text: text) else { finish(); return }
            openContainingApp(link) { [weak self] _ in self?.finish() }
        }
    }

    private func finish() { extensionContext?.completeRequest(returningItems: nil) }

    /// The first web URL and the first text among the shared attachments.
    private func sharedItems() async -> (url: URL?, text: String?) {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var url: URL?, text: String?
        for provider in providers {
            if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) {
                if let value = item as? URL, !value.isFileURL { url = value }
                else if let value = item as? String, let parsed = URL(string: value), !parsed.isFileURL { url = parsed }
            } else if text == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) {
                if let value = item as? String { text = value }
                else if let value = item as? Data { text = String(data: value, encoding: .utf8) }
                else if let value = item as? URL { url = url ?? (value.isFileURL ? nil : value) }
            }
        }
        return (url, text)
    }

    /// A share extension has no public way to bring its app forward; the responder chain ends at the
    /// extension process's UIApplication, whose `open` hands the link to the system.
    private func openContainingApp(_ link: URL, completion: @escaping @MainActor (Bool) -> Void) {
        var responder: UIResponder? = self
        while let current = responder {
            // `open(_:options:completionHandler:)` is unavailable to extension code at compile time, so it
            // is called through its selector.
            let selector = NSSelectorFromString("openURL:options:completionHandler:")
            if let application = current as? UIApplication, application.responds(to: selector) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, @escaping @convention(block) (Bool) -> Void) -> Void
                let open = unsafeBitCast(application.method(for: selector), to: Open.self)
                open(application, selector, link as NSURL, NSDictionary(), { opened in
                    Task { @MainActor in completion(opened) }
                })
                return
            }
            responder = current.next
        }
        if let context = extensionContext {
            context.open(link) { opened in Task { @MainActor in completion(opened) } }
        } else { completion(false) }
    }
}
