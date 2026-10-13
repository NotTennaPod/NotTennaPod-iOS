import UIKit
import NotTennaPodCore

/// FloatingSelectMenu's horizontal icon/title strip. The parent reserves its
/// height in list content, so the final row can scroll clear of the overlay.
@MainActor final class EpisodeSelectionBar: UIView, UIScrollViewDelegate {
    var moveQueue: ((QueueBoundary) -> Void)?
    var perform: ((EpisodeListAction) -> Void)?
    private let card = UIView(), scroll = UIScrollView()
    private var buttons: [UIButton] = []
    private var labels: [UILabel] = [], images: [UIImageView] = []
    private var signature: [String] = []
    private var wasRTL = false
    private let fade = CAGradientLayer()
    private func labelSize(_ label: UILabel) -> CGSize {
        let font = Appearance.font(12, compatibleWith: traitCollection), scale = font.pointSize / 12
        label.font = font
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        paragraph.minimumLineHeight = 16 * scale; paragraph.maximumLineHeight = 16 * scale
        paragraph.lineBreakMode = .byTruncatingTail
        label.attributedText = NSAttributedString(string: label.text ?? "", attributes: [.font: font, .paragraphStyle: paragraph, .kern: 0.4 * scale])
        let width = min(96, max(72, label.intrinsicContentSize.width))
        let height = max(16 * scale, label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        return CGSize(width: width, height: height)
    }
    var preferredHeight: CGFloat { 16 + 12 + 28 + 8 + (labels.map { labelSize($0).height }.max() ?? 16) + 8 }
    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "episodeSelectionActions"
        card.backgroundColor = Appearance.color(0xdbecf7, 0x243344); card.layer.cornerRadius = 8
        card.layer.shadowOpacity = 0.18; card.layer.shadowRadius = 2; card.layer.shadowOffset = CGSize(width: 0, height: 2)
        addSubview(card); card.addSubview(scroll)
        scroll.delegate = self; fade.startPoint = CGPoint(x: 0, y: 0.5); fade.endPoint = CGPoint(x: 1, y: 0.5)
        scroll.layer.mask = fade
        scroll.showsHorizontalScrollIndicator = false; scroll.contentInsetAdjustmentBehavior = .never
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(actions: [EpisodeListAction], hasMedia: Bool, queueMoves: [QueueBoundary] = []) {
        let next = actions.map { $0.rawValue + $0.titleKey(hasMedia: hasMedia) } + queueMoves.map { "queue-" + $0.rawValue }
        guard signature != next else { return }; signature = next
        buttons.forEach { $0.removeFromSuperview() }; buttons = []; labels = []; images = []
        for action in actions {
            let button = UIButton(type: .custom), label = UILabel(), image = UIImageView(image: UIImage(named: action.icon))
            label.text = Appearance.text(action.titleKey(hasMedia: hasMedia)); label.numberOfLines = 2
            label.textAlignment = .center; label.textColor = Appearance.foreground; label.lineBreakMode = .byTruncatingTail
            image.tintColor = Appearance.foreground; image.contentMode = .scaleAspectFit
            image.isUserInteractionEnabled = false; label.isUserInteractionEnabled = false
            button.accessibilityLabel = label.text; button.accessibilityIdentifier = "episodeBulk-" + action.rawValue
            button.addAction(UIAction { [weak self] _ in self?.perform?(action) }, for: .touchUpInside)
            button.addSubview(image); button.addSubview(label); scroll.addSubview(button)
            buttons.append(button); labels.append(label); images.append(image)
        }
        for boundary in queueMoves {
            let button = UIButton(type: .custom), label = UILabel()
            let image = UIImageView(image: UIImage(named: boundary == .top ? "ic_arrow_full_up" : "ic_arrow_full_down"))
            label.text = Appearance.text(boundary == .top ? "move_to_top_label" : "move_to_bottom_label")
            label.numberOfLines = 2; label.textAlignment = .center; label.textColor = Appearance.foreground
            image.tintColor = Appearance.foreground; image.contentMode = .scaleAspectFit
            image.isUserInteractionEnabled = false; label.isUserInteractionEnabled = false
            button.accessibilityLabel = label.text; button.accessibilityIdentifier = "queueBulk-" + boundary.rawValue
            button.addAction(UIAction { [weak self] _ in self?.moveQueue?(boundary) }, for: .touchUpInside)
            button.addSubview(image); button.addSubview(label); scroll.addSubview(button)
            buttons.append(button); labels.append(label); images.append(image)
        }
        setNeedsLayout()
    }
    /// Subscriptions actions (`nav_feed_action_speeddial.xml`): the same strip with feed actions.
    var performFeedAction: ((FeedBulkAction) -> Void)?
    func update(feedActions: [FeedBulkAction]) {
        let next = feedActions.map { "feed-" + $0.rawValue }
        guard signature != next else { return }; signature = next
        buttons.forEach { $0.removeFromSuperview() }; buttons = []; labels = []; images = []
        for action in feedActions {
            let button = UIButton(type: .custom), label = UILabel(), image = UIImageView(image: UIImage(named: action.icon))
            label.text = Appearance.text(action.titleKey); label.numberOfLines = 2
            label.textAlignment = .center; label.textColor = Appearance.foreground; label.lineBreakMode = .byTruncatingTail
            image.tintColor = Appearance.foreground; image.contentMode = .scaleAspectFit
            image.isUserInteractionEnabled = false; label.isUserInteractionEnabled = false
            button.accessibilityLabel = label.text; button.accessibilityIdentifier = "feedBulk-" + action.rawValue
            button.addAction(UIAction { [weak self] _ in self?.performFeedAction?(action) }, for: .touchUpInside)
            button.addSubview(image); button.addSubview(label); scroll.addSubview(button)
            buttons.append(button); labels.append(label); images.append(image)
        }
        setNeedsLayout()
    }
    func resetScroll() { scroll.contentOffset.x = wasRTL ? max(0, scroll.contentSize.width - scroll.bounds.width) : 0 }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let oldMaximum = max(0, scroll.contentSize.width - scroll.bounds.width)
        let offset = wasRTL ? oldMaximum - scroll.contentOffset.x : scroll.contentOffset.x
        let inset = min(16, bounds.width / 2)
        card.frame = CGRect(x: inset, y: 0, width: max(0, bounds.width - inset * 2), height: max(0, bounds.height - 16))
        scroll.frame = card.bounds
        let contentHeight = max(scroll.bounds.height, preferredHeight - 16)
        var widths: [CGFloat] = []
        for label in labels {
            widths.append(labelSize(label).width + 8)
        }
        let total = max(scroll.bounds.width, widths.reduce(16, +))
        var x: CGFloat = 8
        for i in buttons.indices {
            let width = widths[i]
            buttons[i].frame = CGRect(x: rtl ? total - x - width : x, y: 0, width: width, height: contentHeight)
            images[i].frame = CGRect(x: (width - 28) / 2, y: 12, width: 28, height: 28)
            labels[i].frame = CGRect(x: 4, y: 48, width: width - 8, height: labelSize(labels[i]).height)
            x += width
        }
        scroll.contentSize = CGSize(width: total, height: contentHeight)
        let maximum = max(0, total - scroll.bounds.width), retained = min(maximum, max(0, offset))
        scroll.contentOffset.x = rtl ? maximum - retained : retained; wasRTL = rtl
        updateFade()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateFade() }
    private func updateFade() {
        let width = max(1, scroll.bounds.width), edge = min(0.5, 48 / width)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fade.frame = scroll.bounds
        fade.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        fade.colors = [(scroll.contentOffset.x > 0.5 ? UIColor.clear : .black).cgColor, UIColor.black.cgColor, UIColor.black.cgColor,
            (scroll.contentOffset.x + width < scroll.contentSize.width - 0.5 ? UIColor.clear : .black).cgColor]
        CATransaction.commit()
    }
}
