import UIKit
import NotTennaPodCore

/// EditUrlSettingsDialog's two-stage presentation. The app scheduler is injected
/// explicitly: persistence precedes enqueueing, which precedes the visible URL.
@MainActor
final class FeedURLEditFlow {
    typealias Save = @Sendable (String, String) async throws -> Void
    private let save: Save
    private let requestForcedRefresh: () -> Void
    private let didUpdateURL: (String) -> Void
    private let failed: (any Error) -> Void
    private let makeCountdown: () -> FeedURLConfirmationCountdown
    private(set) var original: String
    private(set) var isSaving = false

    init(original: String, save: @escaping Save, requestForcedRefresh: @escaping () -> Void,
         didUpdateURL: @escaping (String) -> Void, failed: @escaping (any Error) -> Void,
         makeCountdown: @escaping () -> FeedURLConfirmationCountdown = { .init() }) {
        self.original = original; self.save = save; self.requestForcedRefresh = requestForcedRefresh
        self.didUpdateURL = didUpdateURL; self.failed = failed; self.makeCountdown = makeCountdown
    }
    convenience init(feed: LibraryFeed, store: FeedLibraryStore, enqueueForcedRefresh: @escaping (Int64) -> Void,
                     didUpdateURL: @escaping (String) -> Void, failed: @escaping (any Error) -> Void) {
        self.init(original: feed.source, save: { original, updated in
            try await store.updateFeedDownloadURL(original: original, updated: updated)
        }, requestForcedRefresh: { enqueueForcedRefresh(feed.id) }, didUpdateURL: didUpdateURL, failed: failed)
    }

    @discardableResult
    func show(from presenter: UIViewController) -> SourceMessageController? {
        guard !isSaving else { return nil }
        let input = FeedURLEditInputView(value: original)
        let dialog = SourceMessageController(title: Appearance.text("edit_url_menu"), message: "",
            positive: .init(title: Appearance.text("ok"), identifier: "editFeedURLNext", perform: { [weak presenter] in
                guard let presenter, presenter.viewIfLoaded?.window != nil else { return }
                let updated = input.value
                let warning = FeedURLConfirmationController(countdown: self.makeCountdown()) {
                    self.commit(updated)
                }
                presenter.present(warning, animated: true)
            }, performAfterDismiss: true),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "editFeedURLCancel"), customBody: input)
        dialog.avoidsKeyboard = true
        input.onSizeChange = { [weak dialog] in dialog?.viewIfLoaded?.setNeedsLayout() }
        input.onSelectionChange = { [weak dialog, weak input] in
            guard let input else { return }; dialog?.revealTextPosition(input.textView)
        }
        presenter.present(dialog, animated: true)
        return dialog
    }
    private func commit(_ updated: String) {
        guard !isSaving else { return }
        isSaving = true
        let old = original
        // Confirmation authorizes the write independently of dialog dismissal.
        // Callers capture their UI weakly; do not cancel a saved edit merely
        // because its dialog or information screen goes away.
        Task {
            do {
                try await save(old, updated)
                original = updated
                requestForcedRefresh()
                isSaving = false
                didUpdateURL(updated)
            } catch { isSaving = false; failed(error) }
        }
    }
}

@MainActor
final class FeedURLConfirmationController: SourceMessageController {
    private let countdown: FeedURLConfirmationCountdown
    private var started = false
    init(countdown: FeedURLConfirmationCountdown = .init(), confirm: @escaping () -> Void) {
        self.countdown = countdown
        super.init(title: Appearance.text("edit_url_menu"), message: Appearance.text("edit_url_confirmation_msg"),
            positive: .init(title: Appearance.text("ok"), identifier: "editFeedURLConfirm", perform: confirm, isEnabled: false),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "editFeedURLCancel"))
        countdown.onChange = { [weak self] state in
            self?.updateAction(identifier: "editFeedURLConfirm", title: state.title(ok: Appearance.text("ok")), isEnabled: state.canConfirm)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !started { started = true; countdown.start() }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if presentingViewController == nil || isBeingDismissed { countdown.cancel() }
    }
}

/// Original edit_text_dialog.xml: outlined, multiline input, 16-point outer
/// padding, five-point collapsed-label space, eight-point bottom field margin.
@MainActor
final class FeedURLEditInputView: UIView, UITextViewDelegate, SourceMessageBodyViewport {
    var minimumMessageViewportHeight: CGFloat { ceil(textView.font?.lineHeight ?? 0) + 8 }
    var onSizeChange: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    let textView = UITextView()
    var value: String { textView.text }
    private var configuredCategory: UIContentSizeCategory?
    private var configuredDirection: UIUserInterfaceLayoutDirection?
    init(value: String) {
        super.init(frame: .zero)
        accessibilityIdentifier = "editFeedURLBody"
        textView.accessibilityIdentifier = "editFeedURLInput"
        textView.accessibilityLabel = Appearance.text("edit_url_menu")
        textView.isScrollEnabled = false; textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 17, left: 16, bottom: 17, right: 16)
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardType = .default; textView.returnKeyType = .default
        textView.autocapitalizationType = .none; textView.autocorrectionType = .no
        textView.smartQuotesType = .no; textView.smartDashesType = .no
        textView.layer.cornerRadius = 4; textView.delegate = self
        addSubview(textView); textView.text = value
        refreshTypography(); textView.selectedRange = NSRange(location: 0, length: 0)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) { (view: FeedURLEditInputView, _) in
            view.refreshTypography(); view.setNeedsLayout(); view.onSizeChange?()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    private func refreshTypography() {
        refreshBorder()
        let category = traitCollection.preferredContentSizeCategory, direction = effectiveUserInterfaceLayoutDirection
        guard configuredCategory != category || configuredDirection != direction else { return }
        configuredCategory = category; configuredDirection = direction
        let selection = textView.selectedRange
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: "Roboto-Regular", size: 16)!, compatibleWith: traitCollection)
        textView.font = font; textView.textColor = Appearance.foreground
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = direction == .rightToLeft ? .right : .left
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Appearance.foreground,
            .kern: 0.15 * font.pointSize / 16, .paragraphStyle: paragraph]
        textView.attributedText = NSAttributedString(string: textView.text ?? "", attributes: attributes)
        textView.typingAttributes = attributes; textView.selectedRange = selection
    }
    private func refreshBorder() {
        textView.layer.borderWidth = textView.isFirstResponder ? 2 : 1
        textView.layer.borderColor = (textView.isFirstResponder ? Appearance.accent : Appearance.foreground.withAlphaComponent(0.38)).resolvedColor(with: traitCollection).cgColor
    }
    func textViewDidChange(_ textView: UITextView) { invalidateIntrinsicContentSize(); onSizeChange?(); onSelectionChange?() }
    func textViewDidChangeSelection(_ textView: UITextView) { onSelectionChange?() }
    func textViewDidBeginEditing(_ textView: UITextView) { refreshBorder() }
    func textViewDidEndEditing(_ textView: UITextView) { refreshBorder() }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        refreshTypography()
        let measured = textView.sizeThatFits(CGSize(width: max(0, size.width - 32), height: .greatestFiniteMagnitude)).height
        return CGSize(width: size.width, height: 16 + 5 + max(56, ceil(measured)) + 8 + 16)
    }
    override func layoutSubviews() {
        super.layoutSubviews(); refreshTypography()
        textView.frame = CGRect(x: min(16, bounds.width / 2), y: 21, width: max(0, bounds.width - 32), height: max(0, bounds.height - 45))
    }
}
