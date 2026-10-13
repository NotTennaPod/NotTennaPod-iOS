import UIKit
import NotTennaPodCore

/// OnlineFeedViewActivity.showFeedDiscoveryDialog: a list dialog titled "Subscriptions", one
/// single-line row per link ellipsized at the start, no buttons. A tap proceeds with that feed;
/// Back or a tap outside cancels.
@MainActor final class FeedChooserController: UIViewController {
    private let links: [DiscoveredFeedLink]
    private let onChoose: (DiscoveredFeedLink) -> Void
    private let onCancel: () -> Void
    private let panel = UIView(), heading: SourceDialogTitle, list = UIScrollView()
    private var rows: [UIButton] = []
    private var closing = false
    init(links: [DiscoveredFeedLink], choose: @escaping (DiscoveredFeedLink) -> Void, cancel: @escaping () -> Void) {
        self.links = links; onChoose = choose; onCancel = cancel
        heading = SourceDialogTitle(Appearance.text("subscriptions_label"))
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.32); view.accessibilityViewIsModal = true
        panel.backgroundColor = Appearance.surfaceVariant; panel.layer.cornerRadius = 28
        panel.accessibilityIdentifier = "feedChooser"
        heading.accessibilityIdentifier = "feedChooserTitle"; heading.accessibilityTraits.insert(.header)
        view.addSubview(panel); panel.addSubview(heading); panel.addSubview(list)
        rows = links.enumerated().map { index, link in
            let row = UIButton(type: .system)
            row.setTitle(link.label, for: .normal); row.tintColor = Appearance.foreground
            row.titleLabel?.numberOfLines = 1; row.titleLabel?.lineBreakMode = .byTruncatingHead
            row.accessibilityIdentifier = "feedChooserRow-\(index)"; row.accessibilityLabel = link.label
            row.addAction(UIAction { [weak self] _ in self?.finish { self?.onChoose(link) } }, for: .touchUpInside)
            list.addSubview(row); return row
        }
        let outside = UITapGestureRecognizer(target: self, action: #selector(outsideTap(_:)))
        outside.cancelsTouchesInView = false; view.addGestureRecognizer(outside)
    }
    private func finish(_ action: @escaping () -> Void) {
        guard !closing else { return }
        closing = true
        dismiss(animated: true, completion: action)
    }
    @objc private func outsideTap(_ gesture: UITapGestureRecognizer) {
        if !panel.frame.contains(gesture.location(in: view)) { finish(onCancel) }
    }
    override func accessibilityPerformEscape() -> Bool { finish(onCancel); return true }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let width = min(max(0, safe.width - 48), 560)
        let font = Appearance.font(16, compatibleWith: traitCollection)
        let rowHeight = max(48, ceil(font.lineHeight + 24))
        let titleHeight = heading.measuredSize(width: max(0, width - 48)).height
        let listHeight = min(CGFloat(rows.count) * rowHeight, max(rowHeight, safe.height - titleHeight - 80))
        let height = 24 + titleHeight + 16 + listHeight + 24
        panel.frame = CGRect(x: safe.minX + (safe.width - width) / 2, y: safe.minY + max(0, (safe.height - height) / 2), width: width, height: min(height, safe.height))
        heading.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        heading.frame = CGRect(x: 24, y: 24, width: max(0, width - 48), height: titleHeight)
        list.frame = CGRect(x: 0, y: heading.frame.maxY + 16, width: width, height: max(0, panel.bounds.height - heading.frame.maxY - 40))
        for (index, row) in rows.enumerated() {
            row.titleLabel?.font = font
            row.contentHorizontalAlignment = rtl ? .right : .left
            row.frame = CGRect(x: 24, y: CGFloat(index) * rowHeight, width: max(0, width - 48), height: rowHeight)
        }
        list.contentSize = CGSize(width: width, height: CGFloat(rows.count) * rowHeight)
    }
}
