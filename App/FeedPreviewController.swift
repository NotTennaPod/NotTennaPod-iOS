import UIKit
import NotTennaPodCore

@MainActor
final class FeedPreviewController: UIViewController {
    private(set) var contentController: UIViewController
    var onClose: (() -> Void)?
    private let card = UIView()
    private let shadow = UIView()
    private let recoveredBySearch: Bool
    private var recoveryShown = false
    private var recoveryNotice: UIView?
    private var recoveryLabel: UILabel?
    private var recoveryIcon: AdaptiveLogoView?
    private var noticeTask: Task<Void, Never>?

    init(content: UIViewController, recoveredBySearch: Bool = false) {
        contentController = content
        self.recoveredBySearch = recoveredBySearch
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError() }
    func replaceContent(_ content: UIViewController) {
        loadViewIfNeeded()
        contentController.willMove(toParent: nil); contentController.view.removeFromSuperview(); contentController.removeFromParent()
        contentController = content
        addChild(content); card.addSubview(content.view); content.didMove(toParent: self)
        view.setNeedsLayout()
    }
    func close() { onClose?(); dismiss(animated: true) }
    deinit { noticeTask?.cancel() }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        showRecoveryNoticeIfNeeded(recoveredBySearch)
    }
    func showRecoveryNoticeIfNeeded(_ recoveredBySearch: Bool) {
        guard recoveredBySearch, !recoveryShown else { return }
        recoveryShown = true
        let notice = UIView(), label = Appearance.label(Appearance.text("no_feed_url_podcast_found_by_search"), size: 14)
        notice.isUserInteractionEnabled = false
        notice.backgroundColor = Appearance.navigation; notice.layer.cornerRadius = 20
        label.textAlignment = .natural; label.numberOfLines = 2; label.lineBreakMode = .byTruncatingTail
        label.accessibilityIdentifier = "feedRecoveryNotice"
        let icon = AdaptiveLogoView(); notice.addSubview(icon); recoveryIcon = icon
        notice.addSubview(label); view.addSubview(notice)
        recoveryNotice = notice; recoveryLabel = label
        view.setNeedsLayout(); view.layoutIfNeeded()
        UIAccessibility.post(notification: .announcement, argument: label.text)
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(3500)) } catch { return }
            self?.removeRecoveryNotice()
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated); noticeTask?.cancel(); removeRecoveryNotice()
    }
    private func removeRecoveryNotice() { recoveryNotice?.removeFromSuperview(); recoveryNotice = nil; recoveryLabel = nil; recoveryIcon = nil }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let area = view.safeAreaLayoutGuide.layoutFrame
        card.frame = area.insetBy(dx: min(16, area.width / 4), dy: min(56, area.height / 4))
        shadow.frame = card.frame
        shadow.layer.shadowPath = UIBezierPath(roundedRect: shadow.bounds, cornerRadius: 8).cgPath
        contentController.view.frame = card.bounds
        guard let notice = recoveryNotice, let label = recoveryLabel else { return }
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let width = min(600, max(0, safe.width - min(48, safe.width / 5)))
        let padding = min(16, width / 4)
        let iconSize = min(24, max(0, width - 2 * padding))
        let gap = min(12, max(0, width - 2 * padding - iconSize))
        let textWidth = max(0, width - 2 * padding - iconSize - gap)
        label.font = Appearance.font(14, compatibleWith: traitCollection)
        let wanted = max(iconSize, label.sizeThatFits(CGSize(width: max(1, textWidth), height: .greatestFiniteMagnitude)).height) + 24
        let height = min(max(0, safe.height), wanted)
        notice.frame = CGRect(x: safe.midX - width / 2, y: max(safe.minY, safe.maxY - height - 24), width: width, height: height)
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let visibleIcon = min(iconSize, height)
        recoveryIcon?.frame = CGRect(x: rtl ? width - padding - iconSize : padding, y: (height - visibleIcon) / 2, width: iconSize, height: visibleIcon)
        let verticalPadding = min(12, height / 2)
        label.frame = CGRect(x: rtl ? padding : padding + iconSize + gap, y: verticalPadding, width: textWidth, height: max(0, height - 2 * verticalPadding))
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        // Material3 translucent activity scrim (m3_comp_scrim_container_opacity).
        view.backgroundColor = UIColor.black.withAlphaComponent(0.32)
        view.accessibilityViewIsModal = true
        let outside = UIControl()
        outside.translatesAutoresizingMaskIntoConstraints = false
        outside.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
        view.addSubview(outside)
        NSLayoutConstraint.activate([
            outside.leadingAnchor.constraint(equalTo: view.leadingAnchor), outside.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            outside.topAnchor.constraint(equalTo: view.topAnchor), outside.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        shadow.isUserInteractionEnabled = false
        shadow.layer.shadowColor = UIColor.black.cgColor; shadow.layer.shadowOpacity = 0.24
        shadow.layer.shadowRadius = 8; shadow.layer.shadowOffset = CGSize(width: 0, height: 4)
        view.addSubview(shadow)
        card.backgroundColor = Appearance.background; card.layer.cornerRadius = 8; card.clipsToBounds = true
        card.accessibilityIdentifier = "feedPreviewCard"; view.addSubview(card)
        addChild(contentController); card.addSubview(contentController.view); contentController.didMove(toParent: self)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: FeedPreviewController, _) in controller.view.setNeedsLayout() }
    }
    override func accessibilityPerformEscape() -> Bool {
        if contentController.accessibilityPerformEscape() { return true }
        close(); return true
    }
}

@MainActor final class FeedPreviewLoadingController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = Appearance.background
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.accessibilityIdentifier = "feedPreviewLoading"
        spinner.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(spinner)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        spinner.startAnimating()
    }
}
