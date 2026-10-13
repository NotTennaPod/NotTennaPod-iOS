import UIKit
import NotTennaPodCore

/// Full-screen source selection composition; UIKit owns resize and accessibility,
/// the session owns the immutable document and accepted job.
@MainActor final class OPMLImportController: UIViewController {
    let session: OPMLImportSession
    var onFinished: (() -> Void)?
    var onNotice: ((String) -> Void)?
    private let toolbar = UIView(), list = UIScrollView()
    private let titleLabel = Appearance.label(Appearance.text("opml_import_label"), size: 20)
    private var rows: [OPMLSelectionRow] = []
    private lazy var back = Appearance.icon("abc_ic_ab_back_material", label: Appearance.text("toolbar_back_button_content_description")) { [weak self] in self?.close() }
    private lazy var overflow = Appearance.icon("dots_vertical", label: Appearance.text("overflow_more")) { [weak self] in self?.showSelectionMenu() }
    private let confirm = UIButton(type: .system), cancel = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)
    private var displayedDocument: OPMLDocument?
    private var errorShown: String?
    private var finishing = false
    init(session: OPMLImportSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = Appearance.background
        view.accessibilityIdentifier = "opmlImport"
        overflow.accessibilityIdentifier = "opmlOverflow"
        view.addSubview(toolbar); toolbar.addSubview(back); toolbar.addSubview(titleLabel); toolbar.addSubview(overflow)
        view.addSubview(list); list.contentInsetAdjustmentBehavior = .never
        for (button, key, id) in [(cancel, "cancel_label", "opmlCancel"), (confirm, "confirm_label", "opmlConfirm")] {
            button.setTitle(Appearance.text(key), for: .normal); button.tintColor = Appearance.accent
            button.accessibilityIdentifier = id; view.addSubview(button)
        }
        confirm.backgroundColor = Appearance.color(0xd9edf9, 0x254a66); confirm.layer.cornerRadius = 4
        cancel.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
        confirm.addAction(UIAction { [weak self] _ in self?.session.confirm() }, for: .touchUpInside)
        view.addSubview(spinner); spinner.color = Appearance.accent; spinner.hidesWhenStopped = true
        session.onChange = { [weak self] in self?.render() }
        render()
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); render() }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { session.close() }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaLayoutGuide.layoutFrame, rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let height: CGFloat = max(64, Appearance.font(20, compatibleWith: traitCollection).lineHeight + 32)
        toolbar.frame = CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: min(height, safe.height))
        let layout = ToolbarLayout(size: toolbar.bounds.size, hasNavigation: true, hasOverflow: true, rightToLeft: rtl)
        back.frame = layout.navigation; titleLabel.frame = layout.title; overflow.frame = layout.overflow
        titleLabel.font = Appearance.font(20, compatibleWith: traitCollection)
        let buttonHeight = max(48, Appearance.font(14, medium: true, compatibleWith: traitCollection).lineHeight + 24)
        for b in [cancel, confirm] { b.titleLabel?.font = Appearance.font(14, medium: true, compatibleWith: traitCollection) }
        let confirmWidth = min(safe.width / 2, max(88, confirm.intrinsicContentSize.width + 32))
        let cancelWidth = min(max(0, safe.width - confirmWidth - 24), max(88, cancel.intrinsicContentSize.width + 32))
        let x = rtl ? safe.minX + 8 : safe.maxX - 8 - confirmWidth
        confirm.frame = CGRect(x: x, y: safe.maxY - buttonHeight - 8, width: confirmWidth, height: buttonHeight)
        cancel.frame = CGRect(x: rtl ? confirm.frame.maxX + 16 : confirm.frame.minX - 16 - cancelWidth,
            y: confirm.frame.minY, width: cancelWidth, height: buttonHeight)
        list.frame = CGRect(x: safe.minX, y: toolbar.frame.maxY, width: safe.width,
            height: max(0, confirm.frame.minY - 8 - toolbar.frame.maxY))
        var y: CGFloat = 0
        for row in rows {
            let size = row.sizeThatFits(CGSize(width: safe.width, height: .greatestFiniteMagnitude))
            row.frame = CGRect(x: 0, y: y, width: safe.width, height: size.height); y += size.height + 1
        }
        list.contentSize = CGSize(width: safe.width, height: y)
        spinner.center = CGPoint(x: safe.midX, y: safe.midY)
    }
    private func render() {
        guard isViewLoaded, session.isPresented else { return }
        if displayedDocument != session.document {
            rows.forEach { $0.removeFromSuperview() }
            displayedDocument = session.document
            rows = session.document.entries.enumerated().map { index, entry in
                let row = OPMLSelectionRow(title: entry.title)
                row.accessibilityIdentifier = "opmlRow-\(index)"
                row.addAction(UIAction { [weak self] _ in self?.session.toggle(index) }, for: .touchUpInside)
                list.addSubview(row); return row
            }
        }
        let selecting = session.state == .selecting
        for (index, row) in rows.enumerated() { row.checked = session.selected.contains(index); row.isEnabled = selecting }
        overflow.isEnabled = selecting
        switch session.state {
        case .loading, .committing: spinner.startAnimating(); confirm.isEnabled = false
        case .selecting: spinner.stopAnimating(); confirm.isEnabled = true
        case .commitFailed(let message):
            spinner.stopAnimating(); confirm.isEnabled = true
            if errorShown != message { errorShown = message; onNotice?(message) }
        case .readFailed(let message):
            spinner.stopAnimating(); confirm.isEnabled = false
            if errorShown == nil, view.window != nil, presentedViewController == nil {
                errorShown = message
                let dialog = SourceMessageController(title: Appearance.text("error_label"), message: Appearance.text("opml_reader_error"), details: message,
                    positive: .init(title: Appearance.text("ok"), identifier: "opmlReadErrorOK", perform: { [weak self] in self?.close() }, performAfterDismiss: true))
                dialog.onCancelAfterDismiss = { [weak self] in self?.close() }
                present(dialog, animated: true)
            }
        case .completed:
            spinner.stopAnimating()
            guard !finishing else { return }; finishing = true
            let action = onFinished; session.close(); dismiss(animated: true, completion: action)
        case .closed: break
        }
        view.setNeedsLayout()
    }
    private func showSelectionMenu() {
        guard session.state == .selecting else { return }
        let all = !rows.isEmpty && session.selected.count == rows.count
        present(PopupMenuController(title: "", identifier: "opmlSelectionMenu", anchor: overflow, anchorFraction: .zero,
            actions: [(all ? "opmlDeselectAll" : "opmlSelectAll", Appearance.text(all ? "deselect_all_label" : "select_all_label"))], toolbarTrailing: true) { [weak self] _ in
                self?.session.selectAll(!all)
            }, animated: true)
    }
    func close() { guard !finishing else { return }; finishing = true; session.close(); dismiss(animated: true) }
    override func accessibilityPerformEscape() -> Bool { close(); return true }
    override var keyCommands: [UIKeyCommand]? { [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))] }
    @objc private func escape() { close() }
}

@MainActor private final class OPMLSelectionRow: UIControl {
    private let titleLabel: UILabel
    var checked = false { didSet { accessibilityTraits = checked ? [.button, .selected] : [.button]; setNeedsDisplay() } }
    init(title: String) {
        titleLabel = Appearance.label(title, size: 16)
        super.init(frame: .zero); addSubview(titleLabel); titleLabel.isUserInteractionEnabled = false
        isAccessibilityElement = true; accessibilityLabel = title; accessibilityTraits = .button
        isOpaque = false; backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        titleLabel.font = Appearance.font(16, compatibleWith: traitCollection)
        return CGSize(width: size.width, height: max(48, titleLabel.sizeThatFits(CGSize(width: max(0, size.width - 64), height: .greatestFiniteMagnitude)).height + 16))
    }
    override func layoutSubviews() {
        super.layoutSubviews(); let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        titleLabel.frame = CGRect(x: rtl ? 48 : 16, y: 0, width: max(0, bounds.width - 64), height: bounds.height)
    }
    override func draw(_ rect: CGRect) {
        if checked { Appearance.selected.withAlphaComponent(0.35).setFill(); UIBezierPath(rect: bounds).fill() }
        let x = effectiveUserInterfaceLayoutDirection == .rightToLeft ? 24 : bounds.width - 32
        let box = UIBezierPath(roundedRect: CGRect(x: x - 9, y: bounds.midY - 9, width: 18, height: 18), cornerRadius: 1)
        if checked {
            Appearance.accent.setFill(); box.fill(); UIColor.white.setStroke()
            let tick = UIBezierPath(); tick.move(to: CGPoint(x: x - 5, y: bounds.midY)); tick.addLine(to: CGPoint(x: x - 1, y: bounds.midY + 4)); tick.addLine(to: CGPoint(x: x + 6, y: bounds.midY - 4)); tick.lineWidth = 2; tick.stroke()
        } else { Appearance.secondary.setStroke(); box.lineWidth = 2; box.stroke() }
        Appearance.secondary.withAlphaComponent(0.15).setFill(); UIBezierPath(rect: CGRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5)).fill()
    }
}
