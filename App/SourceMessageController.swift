import UIKit
import NotTennaPodCore

/// Custom bodies with controls taller than the source48-point minimum provide
/// the viewport needed to expose one complete editing/control target.
@MainActor protocol SourceMessageBodyViewport: AnyObject {
    var minimumMessageViewportHeight: CGFloat { get }
}

@MainActor protocol SourceMessageEditingBody: AnyObject {
    var editingControl: UIView? { get }
    func messageBodyDidScroll()
}

/// Material message composition for source warnings and playback errors.
@MainActor class SourceMessageController: UIViewController, UIScrollViewDelegate {
    struct Action {
        let title: String
        let identifier: String
        var perform: (() -> Void)? = nil
        var performAfterDismiss = false
        var isEnabled = true
        var dismisses = true
        var titleColor: UIColor? = nil
    }
    /// Opt in for source-verified dialogs without changing unrelated surfaces.
    var showsSourceElevation = false {
        didSet { viewIfLoaded?.setNeedsLayout() }
    }
    /// A nested Nextcloud message owns the single window dim while covering its
    /// presenter, including the presenter's rounded surface and elevation.
    var replacesPresentingMessageDim = false
    private weak var dimReplacement: SourceMessageController?
    private weak var dimPresenter: SourceMessageController?
    private var presenterBackdropColor: UIColor?
    private let elevation = SourceSingleChoiceShadow()
    var avoidsKeyboard = false
    var allowsImplicitCancellation = true
    private var isClosing = false
    private let panel = UIView()
    private let contentScroll = ControlCancellingScrollView()
    private let scroll = UIScrollView()
    private var ordinaryOffsets: (body: CGPoint, actions: CGPoint)?
    private var editingGeometry: [CGRect]?
    private let actionScroll = ControlCancellingScrollView()
    private let message: UILabel
    private var messageTextCategory: UIContentSizeCategory?
    /// The dialog is on screen (once): what it says was seen (the pending notices are acknowledged by it).
    var onAppear: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCancelAfterDismiss: (() -> Void)?
    private let customBody: UIView?
    private let heading: SourceDialogTitle?
    private let actions: [Action?]
    private var buttons: [UIButton?] = []
    convenience init(title: String? = nil, message: String, details: String? = nil, onConfirm: (() -> Void)? = nil) {
        self.init(title: title, message: message, details: details,
                  positive: .init(title: Appearance.text("ok"), identifier: "sourceMessageOK", perform: onConfirm))
    }
    init(title: String? = nil, message: String, details: String? = nil,
         positive: Action, negative: Action? = nil, neutral: Action? = nil, customBody: UIView? = nil) {
        self.customBody = customBody
        self.message = Appearance.label(message, size: 14)
        self.message.textColor = Appearance.secondary
        self.message.adjustsFontForContentSizeCategory = false
        heading = title.flatMap { $0.isEmpty ? nil : SourceDialogTitle($0) }
        actions = [positive, negative, neutral]
        let value = NSMutableAttributedString(string: message + (details.map { "\n\n" + $0 } ?? ""))
        // Material3 BodyMedium: 14sp, 20sp line height and 0.01785714em tracking.
        let paragraph = NSMutableParagraphStyle()
        let scale = self.message.font.pointSize / 14
        paragraph.minimumLineHeight = 20 * scale
        paragraph.maximumLineHeight = 20 * scale
        value.addAttributes([.paragraphStyle: paragraph, .kern: 0.25 * scale],
                            range: NSRange(location: 0, length: value.length))
        if details != nil {
            value.addAttribute(.foregroundColor, value: UIColor(red: 136 / 255, green: 136 / 255,
                blue: 136 / 255, alpha: 136 / 255), range: NSRange(location: (message as NSString).length,
                    length: value.length - (message as NSString).length))
        }
        self.message.attributedText = value
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.32)
        view.accessibilityViewIsModal = true
        panel.backgroundColor = Appearance.surfaceVariant
        panel.layer.cornerRadius = 28
        view.addSubview(elevation); view.addSubview(panel); panel.addSubview(contentScroll)
        // Keyboard avoidance reads keyboardLayoutGuide in viewDidLayoutSubviews. UIKit re-lays out a view
        // for keyboard changes only when a constraint depends on the guide, so pin an invisible anchor to it;
        // without this the dialog keeps its position and the keyboard covers its buttons. Installed for every
        // dialog because `avoidsKeyboard` may be set after the view loads.
        do {
            let keyboardAnchor = UIView(); keyboardAnchor.isHidden = true; keyboardAnchor.isUserInteractionEnabled = false
            keyboardAnchor.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(keyboardAnchor)
            NSLayoutConstraint.activate([keyboardAnchor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                                         keyboardAnchor.widthAnchor.constraint(equalToConstant: 0),
                                         keyboardAnchor.heightAnchor.constraint(equalToConstant: 0),
                                         keyboardAnchor.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)])
        }
        elevation.isHidden = !showsSourceElevation
        contentScroll.addSubview(scroll); scroll.addSubview(customBody ?? message)
        contentScroll.addSubview(actionScroll)
        // The physical panel is already laid out inside this controller's safe
        // area. Automatic scroll insets would apply those same insets twice.
        contentScroll.contentInsetAdjustmentBehavior = .never
        contentScroll.accessibilityIdentifier = "sourceMessageContent"
        actionScroll.contentInsetAdjustmentBehavior = .never
        actionScroll.accessibilityIdentifier = "sourceMessageActions"
        if let heading {
            contentScroll.addSubview(heading)
            heading.accessibilityIdentifier = "sourceMessageTitle"
            heading.accessibilityTraits.insert(.header)
        }
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.accessibilityIdentifier = "sourceMessageBody"
        scroll.delegate = self; contentScroll.delegate = self
        message.accessibilityIdentifier = "sourceMessage"
        buttons = actions.map { action in
            guard let action else { return nil }
            let button = UIButton(type: .custom)
            button.setTitle(action.title, for: .normal); button.setTitleColor(action.titleColor ?? Appearance.accent, for: .normal)
            button.titleLabel?.font = Appearance.font(14, medium: true)
            button.titleLabel?.adjustsFontForContentSizeCategory = false
            // A title too long for one line wraps when the buttons stack, as an Android button's text does.
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.lineBreakMode = .byWordWrapping
            button.titleLabel?.textAlignment = .center
            if let label = button.titleLabel { observeTextSize(of: label) }
            button.accessibilityIdentifier = action.identifier
            button.isEnabled = action.isEnabled
            button.setTitleColor(Appearance.foreground.withAlphaComponent(0.38), for: .disabled)
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let self, !isClosing, button?.isEnabled == true else { return }
                if !action.dismisses { action.perform?(); return }
                isClosing = true
                buttons.compactMap { $0 }.forEach { $0.isEnabled = false }
                if action.performAfterDismiss { dismiss(animated: true, completion: action.perform) }
                else { action.perform?(); dismiss(animated: true) }
            }, for: .touchUpInside)
            actionScroll.addSubview(button)
            return button
        }
        observeTextSize(of: message)
        // A view-local override need not change the controller's traits. Track
        // the consumer hierarchy, and measure inherited traits after attachment.
        view.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: UIView, _) in
            self?.view.setNeedsLayout()
        }
        let outside = UITapGestureRecognizer(target: self, action: #selector(outside(_:)))
        outside.cancelsTouchesInView = false; view.addGestureRecognizer(outside)
    }
    private func observeTextSize(of label: UILabel) {
        label.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: UILabel, _) in
            self?.view.setNeedsLayout()
        }
    }
    private func refreshTypography() {
        let traits = message.traitCollection
        if messageTextCategory != traits.preferredContentSizeCategory {
            let font = Appearance.font(14, compatibleWith: traits)
            let value = NSMutableAttributedString(attributedString: message.attributedText ?? NSAttributedString())
            let paragraph = NSMutableParagraphStyle()
            let scale = font.pointSize / 14
            paragraph.minimumLineHeight = 20 * scale
            paragraph.maximumLineHeight = 20 * scale
            value.addAttributes([.font: font, .paragraphStyle: paragraph, .kern: 0.25 * scale],
                                range: NSRange(location: 0, length: value.length))
            message.font = font
            message.attributedText = value
            messageTextCategory = traits.preferredContentSizeCategory
        }
        for button in buttons.compactMap({ $0 }) {
            guard let label = button.titleLabel else { continue }
            let font = Appearance.font(14, medium: true, compatibleWith: label.traitCollection)
            if label.font != font { label.font = font }
        }
    }
    /// A button title's one-line width: the wrapping title label's own intrinsic size depends on its last layout.
    static func titleWidth(_ button: UIButton) -> CGFloat {
        guard let label = button.titleLabel, let text = button.title(for: .normal) ?? label.text, let font = label.font else { return 0 }
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        refreshTypography()
        var safe = view.bounds.inset(by: view.safeAreaInsets)
        // CGRect.height standardizes negative extents. Inspect the raw size so
        // collapsed bounds cannot become a positive viewport behind safe insets.
        guard safe.size.width > 0, safe.size.height > 48 else { panel.isHidden = true; elevation.isHidden = true; return }
        let proposal = SourceDialogLayout.preferredContentWidth(in: safe, configurationSize: view.bounds.size)
        let actionWidths = buttons.compactMap { button -> CGFloat? in
            guard let button, !button.isHidden else { return nil }
            return max(64, Self.titleWidth(button) + 24)
        }
        let actionWidth = actionWidths.reduce(48, +) + CGFloat(max(0, actionWidths.count - 1)) * 8
        let widths = buttons.map { $0?.isHidden == true ? nil : $0.map(Self.titleWidth) }
        func measureActions(width: CGFloat) -> SourceMessageActionsLayout {
            // A stacked button is at most the panel's width less its margins and the button's padding.
            let available = max(0, width - 48 - 24)
            let wrapped = buttons.map { button -> CGFloat? in
                guard let button, !button.isHidden, let label = button.titleLabel,
                      Self.titleWidth(button) > available + 0.5 else { return nil }
                return ceil(label.sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude)).height) + 20
            }
            return SourceMessageActionsLayout(width: width, positiveTextWidth: widths[0] ?? 0,
                negativeTextWidth: widths[1], neutralTextWidth: widths[2],
                rightToLeft: view.effectiveUserInterfaceLayoutDirection == .rightToLeft,
                buttonHeight: (buttons.compactMap { $0?.titleLabel?.font.lineHeight }.max() ?? 0) + 20,
                stackedHeights: wrapped)
        }
        let proposedActions = measureActions(width: proposal)
        let titleWidth = heading.map {
            $0.measuredSize(width: max(0, proposal - 48)).width + 48
        } ?? 0
        let bodyWidth = customBody.map {
            $0.sizeThatFits(CGSize(width: proposal, height: max(0, safe.height - 48 - proposedActions.minimumHeight))).width
        } ?? (message.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,
                                         height: CGFloat.greatestFiniteMagnitude)).width + 48)
        let desired = min(proposal, max(bodyWidth, titleWidth, actionWidth))
        let width = SourceDialogLayout.width(in: safe, configurationSize: view.bounds.size,
                                             desiredContentWidth: desired)
        if avoidsKeyboard {
            let keyboardTop = view.keyboardLayoutGuide.layoutFrame.minY
            if keyboardTop > 0 { safe.size.height = max(0, min(safe.maxY, keyboardTop) - safe.minY) }
        }
        // Transient collapsed geometry must not discard retained reading state.
        guard width > 0, safe.size.height > 48 else { panel.isHidden = true; elevation.isHidden = true; return }
        panel.isHidden = false
        let previousBodyAnchor: CGFloat? = ordinaryOffsets != nil
            && contentScroll.contentOffset.y >= scroll.frame.minY
            && contentScroll.contentOffset.y < scroll.frame.maxY
            ? contentScroll.contentOffset.y - scroll.frame.minY : nil
        let textHeight = customBody?.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            ?? message.sizeThatFits(CGSize(width: max(0, width - 48), height: .greatestFiniteMagnitude)).height
        heading?.semanticContentAttribute = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? .forceRightToLeft : .forceLeftToRight
        let titleTextHeight = heading.map { $0.measuredSize(width: max(0, width - 48)).height }
        let messageTop: CGFloat = customBody == nil && heading == nil ? 18 : 0
        let actions = measureActions(width: width)
        let minimumBodyHeight = customBody.map {
            max(48, ($0 as? any SourceMessageBodyViewport)?.minimumMessageViewportHeight ?? 48)
        } ?? (ceil(20 * message.font.pointSize / 14) + messageTop)
        let viewport = SourceMessageViewportLayout(available: safe, titleTextHeight: titleTextHeight,
            bodyHeight: textHeight, customBody: customBody != nil, footerHeight: actions.height,
            minimumFooterHeight: actions.minimumHeight, minimumBodyHeight: minimumBodyHeight,
            minimumActionHeight: actions.positive.height, panelWidth: width)
        let layout = viewport.content
        let enteringOverflow = viewport.scrollsWholeContent && ordinaryOffsets == nil
        let leavingOverflow = !viewport.scrollsWholeContent && ordinaryOffsets != nil
        if enteringOverflow { ordinaryOffsets = (scroll.contentOffset, actionScroll.contentOffset) }
        let bodyOffset = previousBodyAnchor.map { CGPoint(x: 0, y: $0) }
            ?? ordinaryOffsets?.body ?? scroll.contentOffset
        let actionOffset = ordinaryOffsets?.actions ?? actionScroll.contentOffset
        panel.frame = viewport.panel
        elevation.frame = viewport.panel
        elevation.isHidden = !showsSourceElevation
        elevation.setNeedsLayout(); elevation.layoutIfNeeded()
        let outerOffset = (enteringOverflow && bodyOffset.y > 0) || previousBodyAnchor != nil
            ? CGPoint(x: 0, y: layout.body.minY + bodyOffset.y) : contentScroll.contentOffset
        configure(contentScroll, frame: CGRect(origin: .zero, size: viewport.panel.size),
                  contentHeight: layout.panel.height, enabled: viewport.scrollsWholeContent,
                  restoring: viewport.scrollsWholeContent ? outerOffset : .zero)
        let titleBottomPadding: CGFloat = customBody == nil ? 16 : 0
        heading?.frame = CGRect(x: 24, y: 18, width: max(0, width - 48),
                                height: max(0, layout.title.height - 18 - titleBottomPadding))
        if let customBody {
            // Scroll-view descendants do not reliably inherit an explicitly
            // forced container direction. Use the dialog's resolved direction.
            customBody.semanticContentAttribute = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
                ? .forceRightToLeft : .forceLeftToRight
            customBody.frame = CGRect(x: 0, y: messageTop, width: width, height: textHeight)
            customBody.setNeedsLayout()
        }
        else { message.frame = CGRect(x: 24, y: messageTop, width: max(0, width - 48), height: textHeight) }
        configure(scroll, frame: layout.body, contentHeight: textHeight + messageTop,
                  enabled: !viewport.scrollsWholeContent,
                  restoring: viewport.scrollsWholeContent ? .zero : bodyOffset)
        configure(actionScroll, frame: layout.footer, contentHeight: actions.height,
                  enabled: !viewport.scrollsWholeContent && actions.height > layout.footer.height,
                  restoring: viewport.scrollsWholeContent ? .zero : actionOffset)
        if leavingOverflow { ordinaryOffsets = nil }
        for (button, frame) in zip(buttons, [actions.positive, actions.negative, actions.neutral]) {
            if let button, let frame { button.frame = frame }
        }
        if leavingOverflow, let customBody, let textView = editingTextView(in: customBody) {
            customBody.layoutIfNeeded()
            revealCaret(in: textView)
        }
        if let body = customBody as? any SourceMessageEditingBody, let control = body.editingControl {
            customBody?.layoutIfNeeded()
            let geometry = [view.keyboardLayoutGuide.layoutFrame, scroll.frame, contentScroll.frame, control.convert(control.bounds, to: customBody)]
            if editingGeometry != geometry {
                editingGeometry = geometry
                let target = contentScroll.isScrollEnabled ? contentScroll : scroll
                let rect = control.convert(control.bounds, to: target)
                var offset = target.contentOffset.y
                if rect.maxY > target.bounds.maxY { offset = rect.maxY - target.bounds.height }
                if rect.minY < offset { offset = rect.minY }
                // Resolve against the just-computed viewport/content extent;
                // UIKit's scrollRectToVisible can retain the pre-layout offset.
                target.setContentOffset(CGPoint(x: target.contentOffset.x,
                    y: min(max(0, offset), max(0, target.contentSize.height - target.bounds.height))), animated: false)
            }
        } else { editingGeometry = nil }
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        transitionPresenterDim(replacing: true)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        replacePresenterDim(true)
        reportSeenIfVisible()
    }

    /// `onAppear` runs once the dialog is on screen in a scene a person sees (foreground and active); a dialog that
    /// appeared in a scene that is not active reports when that scene becomes active, if it is still on screen.
    private var activationObserver: NSObjectProtocol?
    private func reportSeenIfVisible() {
        guard onAppear != nil, let scene = view.window?.windowScene else { return }
        guard scene.activationState == .foregroundActive else {
            guard activationObserver == nil else { return }
            activationObserver = NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: scene,
                                                                        queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportSeenIfVisible() }
            }
            return
        }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver); self.activationObserver = nil }
        let appeared = onAppear
        onAppear = nil
        appeared?()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        transitionPresenterDim(replacing: false)
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        replacePresenterDim(false)
    }
    private func transitionPresenterDim(replacing: Bool) {
        guard replacesPresentingMessageDim else { return }
        // Join UIKit's own presentation/dismissal, including cancellation. No
        // scene-global view lookup or panel-shaped mask is needed, and the full
        // retained surface and shadow receive the new message's ordinary dim.
        guard let coordinator = transitionCoordinator,
              coordinator.animate(alongsideTransition: { [weak self] _ in
                  self?.replacePresenterDim(replacing)
              }, completion: { [weak self] context in
                  self?.replacePresenterDim(context.isCancelled ? !replacing : replacing)
              }) else {
            replacePresenterDim(replacing)
            return
        }
    }
    private func replacePresenterDim(_ replacing: Bool) {
        if replacing {
            guard replacesPresentingMessageDim,
                  let presenter = presentingViewController as? SourceMessageController,
                  let window = viewIfLoaded?.window, presenter.viewIfLoaded?.window === window,
                  presenter.dimReplacement == nil || presenter.dimReplacement === self else { return }
            if dimPresenter == nil {
                dimPresenter = presenter
                presenterBackdropColor = presenter.view.backgroundColor
            }
            presenter.dimReplacement = self
            presenter.view.backgroundColor = .clear
        } else if let presenter = dimPresenter {
            if presenter.dimReplacement === self {
                presenter.view.backgroundColor = presenterBackdropColor
                presenter.dimReplacement = nil
            }
            dimPresenter = nil
            presenterBackdropColor = nil
        }
    }
    private func configure(_ scroller: UIScrollView, frame: CGRect, contentHeight: CGFloat,
                           enabled: Bool, restoring offset: CGPoint) {
        let previousMaximum = max(0, scroller.contentSize.height - scroller.bounds.height)
        scroller.frame = frame
        scroller.contentSize = CGSize(width: frame.width, height: contentHeight)
        scroller.isScrollEnabled = enabled
        let maximum = max(0, contentHeight - frame.height)
        let clamped = CGPoint(x: 0, y: min(max(0, offset.y), maximum))
        // Avoid interrupting an active pan/bounce on an otherwise identical
        // layout. Explicit mode transitions restore their saved positions.
        if (previousMaximum != maximum || offset != scroller.contentOffset), scroller.contentOffset != clamped {
            scroller.setContentOffset(clamped, animated: false)
        }
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        (customBody as? any SourceMessageEditingBody)?.messageBodyDidScroll()
    }
    func revealTextPosition(_ textView: UITextView) {
        guard avoidsKeyboard, textView.selectedTextRange != nil else { return }
        view.setNeedsLayout(); view.layoutIfNeeded()
        customBody?.layoutIfNeeded()
        revealCaret(in: textView)
    }
    private func editingTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView, textView.isFirstResponder { return textView }
        return view.subviews.lazy.compactMap { self.editingTextView(in: $0) }.first
    }
    private func revealCaret(in textView: UITextView) {
        guard let selection = textView.selectedTextRange else { return }
        let caret = textView.caretRect(for: selection.end).insetBy(dx: -4, dy: -4)
        let target = contentScroll.isScrollEnabled ? contentScroll : scroll
        target.scrollRectToVisible(textView.convert(caret, to: target), animated: false)
    }
    func updateAction(identifier: String, title: String, isEnabled: Bool, isHidden: Bool = false) {
        guard !isClosing else { return }
        loadViewIfNeeded()
        guard let button = buttons.compactMap({ $0 }).first(where: { $0.accessibilityIdentifier == identifier }) else { return }
        button.setTitle(title, for: .normal); button.isEnabled = isEnabled; button.isHidden = isHidden
        view.setNeedsLayout()
    }
    func updateTitle(_ title: String) {
        heading?.updateText(title)
        viewIfLoaded?.setNeedsLayout()
    }
    @objc private func outside(_ gesture: UITapGestureRecognizer) {
        if !panel.frame.contains(gesture.location(in: view)) { cancelMessage() }
    }
    private func cancelMessage() {
        guard allowsImplicitCancellation else { return }
        guard !isClosing else { return }
        isClosing = true; onCancel?(); dismiss(animated: true, completion: onCancelAfterDismiss)
    }
    override func accessibilityPerformEscape() -> Bool {
        guard allowsImplicitCancellation else { return false }
        cancelMessage(); return true
    }
}

/// As in Android's scrolling dialog, a drag that starts on a button scrolls the content; a tap still reaches the button.
private final class ControlCancellingScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl ? true : super.touchesShouldCancel(in: view)
    }
}
