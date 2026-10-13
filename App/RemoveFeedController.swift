import UIKit
import NotTennaPodCore

/// Source remove_feed_dialog.xml: bottom sheet, two-stage unsubscribe and an
/// independent archive/restore action. Accepted work outlives presentation.
/// One or several feeds (`RemoveFeedDialog(List<Feed>)`), processed in order with
/// "… podcast %1$d of %2$d…" progress.
@MainActor
final class RemoveFeedController: UIViewController {
    private let feeds: [LibraryFeed]
    private let remove: (LibraryFeed) async throws -> Void
    private let archive: (LibraryFeed, FeedSubscriptionState) async throws -> Void
    private let finished: () async -> Void
    private let failed: (any Error) -> Void
    /// Restore replaces Archive only when every feed is archived.
    private var allArchived: Bool { feeds.allSatisfy { $0.subscriptionState == .archived } }
    private let panel = UIView(), scroll = UIScrollView()
    private let heading = Appearance.label(Appearance.text("remove_archive_feed_label"), size: 24)
    private let selection: UILabel
    private let explanationDelete = Appearance.label(Appearance.text("feed_delete_explanation_delete"), size: 14)
    private let explanationArchive = Appearance.label(Appearance.text("feed_delete_explanation_archive"), size: 14)
    private let cancel = RemoveFeedButton(), unsubscribe = RemoveFeedButton(), alternative = RemoveFeedButton()
    private let progress = UIActivityIndicatorView(style: .medium)
    private var confirmed = false, working = false
    private var removeWeight: CGFloat = 1
    private var link: CADisplayLink?
    private var animationStart: CFTimeInterval = 0
    convenience init(feed: LibraryFeed, remove: @escaping () async throws -> Void,
                     archive: @escaping (FeedSubscriptionState) async throws -> Void, failed: @escaping (any Error) -> Void) {
        self.init(feeds: [feed], remove: { _ in try await remove() }, archive: { _, state in try await archive(state) },
                  finished: {}, failed: failed)
    }
    init(feeds: [LibraryFeed], remove: @escaping (LibraryFeed) async throws -> Void,
         archive: @escaping (LibraryFeed, FeedSubscriptionState) async throws -> Void,
         finished: @escaping () async -> Void, failed: @escaping (any Error) -> Void) {
        self.feeds = feeds; self.remove = remove; self.archive = archive; self.finished = finished; self.failed = failed
        selection = Appearance.label(feeds.count == 1 ? feeds[0].title
            : Appearance.plural("num_subscriptions", feeds.count), size: 14)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.32)
        view.accessibilityViewIsModal = true
        panel.backgroundColor = Appearance.surfaceVariant
        panel.layer.cornerRadius = 28; panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        panel.clipsToBounds = true; panel.accessibilityIdentifier = "removeFeedSheet"
        view.addSubview(panel); panel.addSubview(scroll)
        scroll.contentInsetAdjustmentBehavior = .never
        [heading, selection, explanationDelete, explanationArchive, cancel, unsubscribe, alternative, progress].forEach(scroll.addSubview)
        explanationArchive.isHidden = allArchived
        heading.accessibilityTraits.insert(.header)
        func button(_ button: UIButton, _ key: String, _ id: String) {
            button.setTitle(Appearance.text(key), for: .normal)
            button.titleLabel?.font = Appearance.font(14, medium: true)
            button.setTitleColor(Appearance.accent, for: .normal)
            button.accessibilityIdentifier = id
        }
        button(cancel, "cancel_label", "removeFeedCancel")
        button(unsubscribe, "remove_feed_label", "removeFeedNext")
        button(alternative, allArchived ? "restore_archive_label" : "archive_feed_label_verb", "archiveFeed")
        alternative.fill = Appearance.accent; alternative.outlined = false; alternative.setTitleColor(.white, for: .normal)
        cancel.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        unsubscribe.addAction(UIAction { [weak self] _ in self?.removePressed() }, for: .touchUpInside)
        alternative.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let state: FeedSubscriptionState = allArchived ? .subscribed : .archived
            begin(key: state == .archived ? "archiving_podcast_progress" : "restoring_podcast_progress") { feed in try await self.archive(feed, state) }
        }, for: .touchUpInside)
        let outside = UITapGestureRecognizer(target: self, action: #selector(outsideTap(_:)))
        outside.cancelsTouchesInView = false; view.addGestureRecognizer(outside)
    }
    @objc private func outsideTap(_ gesture: UITapGestureRecognizer) {
        if !panel.frame.contains(gesture.location(in: view)) { dismiss(animated: true) }
    }
    override func accessibilityPerformEscape() -> Bool {
        dismiss(animated: true); return true
    }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelFromKeyboard))]
    }
    @objc private func cancelFromKeyboard() { dismiss(animated: true) }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); link?.invalidate(); link = nil }
    private func removePressed() {
        guard !working else { return }
        if confirmed { begin(key: "deleting_podcast_progress") { [remove] feed in try await remove(feed) }; return }
        confirmed = true
        unsubscribe.accessibilityIdentifier = "removeFeedConfirm"
        unsubscribe.fill = Appearance.color(0xb3261e, 0xf2b8b5)
        unsubscribe.setTitleColor(Appearance.color(0xffffff, 0x601410), for: .normal)
        animationStart = CACurrentMediaTime()
        link = CADisplayLink(target: self, selector: #selector(animateConfirmation(_:))); link?.add(to: .main, forMode: .common)
    }
    @objc private func animateConfirmation(_ sender: CADisplayLink) {
        let fraction = min(1, max(0, (sender.timestamp - animationStart) / 0.4))
        let t = fraction - 1
        removeWeight = 1 + CGFloat(t * t * (4 * t + 3) + 1) // OvershootInterpolator(3)
        view.setNeedsLayout(); view.layoutIfNeeded()
        if fraction == 1 { sender.invalidate(); link = nil }
    }
    private func begin(key: String, action: @escaping (LibraryFeed) async throws -> Void) {
        guard !working else { return }
        working = true; link?.invalidate(); link = nil
        [cancel, unsubscribe, alternative].forEach { $0.isHidden = true }
        progress.startAnimating(); view.setNeedsLayout()
        let feeds = feeds
        Task {
            do {
                for (index, feed) in feeds.enumerated() {
                    selection.text = String(format: Appearance.text(key), index + 1, feeds.count)
                    view.setNeedsLayout()
                    try await action(feed)
                }
                await finished()
                dismiss(animated: true)
            } catch { await finished(); dismiss(animated: true) { self.failed(error) } }
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let width = safe.width, textWidth = max(0, width - 48)
        var y: CGFloat = 24
        for (label, gap) in [(heading, CGFloat(16)), (selection, 8), (explanationDelete, 8), (explanationArchive, 16)] where !label.isHidden {
            let title = label === heading
            let font = Appearance.font(title ? 24 : 14, compatibleWith: traitCollection)
            label.font = font; label.adjustsFontForContentSizeCategory = false
            let scale = font.pointSize / (title ? 24 : 14)
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = (title ? 32 : 20) * scale
            paragraph.maximumLineHeight = paragraph.minimumLineHeight
            label.attributedText = NSAttributedString(string: label.text ?? "", attributes: [
                .font: font, .paragraphStyle: paragraph, .kern: (title ? 0 : 0.25) * scale])
            let height = label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
            label.frame = CGRect(x: 24, y: y, width: textWidth, height: height); y += height + gap
        }
        if working { progress.frame = CGRect(x: 24, y: y, width: textWidth, height: 48) }
        else {
            let unit = max(0, textWidth - 16) / (2 + removeWeight)
            var x: CGFloat = 24
            for (button, weight) in [(cancel, CGFloat(1)), (unsubscribe, removeWeight), (alternative, 1)] {
                let w = unit * weight
                button.frame = CGRect(x: view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? width - x - w : x, y: y, width: w, height: 48)
                x += w + 8
            }
        }
        y += 48 + 8 + view.safeAreaInsets.bottom
        panel.frame = CGRect(x: safe.minX, y: max(safe.minY, view.bounds.maxY - y), width: width, height: min(y, view.bounds.maxY - safe.minY))
        scroll.frame = panel.bounds; scroll.contentSize = CGSize(width: width, height: y)
    }
}

/// Material3 keeps a 48-point touch target around its inset, pill-shaped surface.
@MainActor private final class RemoveFeedButton: UIButton {
    var fill: UIColor = .clear { didSet { setNeedsLayout() } }
    var outlined = true { didSet { setNeedsLayout() } }
    private let surface = CAShapeLayer()
    init() {
        super.init(frame: .zero)
        layer.insertSublayer(surface, at: 0)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (button: RemoveFeedButton, _) in button.setNeedsLayout() }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isHighlighted: Bool { didSet { setNeedsLayout() } }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rect = bounds.insetBy(dx: outlined ? 0.5 : 0, dy: outlined ? 4.5 : 4)
        surface.path = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2).cgPath
        surface.lineWidth = outlined ? 1 : 0
        surface.strokeColor = Appearance.secondary.resolvedColor(with: traitCollection).cgColor
        surface.fillColor = (isHighlighted ? fill.withAlphaComponent(0.8) : fill).resolvedColor(with: traitCollection).cgColor
    }
}
