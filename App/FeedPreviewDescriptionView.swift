import UIKit

/// Preview-only descriptionContainer from feeditemlist_header.xml.
@MainActor final class FeedPreviewDescriptionView: UIView {
    var openInformation: (() -> Void)?
    private let notice = EpisodeSubscriptionNotice()
    private let heading = Appearance.label(Appearance.text("description_label"), size: 16)
    private let body = Appearance.label(nil, size: 14)
    private let episodes = Appearance.label(Appearance.text("preview_episodes"), size: 16)
    private let descriptionButton = UIButton(type: .custom)
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Appearance.background
        [notice, heading, body, episodes, descriptionButton].forEach(addSubview)
        heading.font = Appearance.font(16, medium: true); episodes.font = Appearance.font(16, medium: true)
        body.numberOfLines = 3; body.lineBreakMode = .byTruncatingTail
        body.isAccessibilityElement = false
        descriptionButton.accessibilityIdentifier = "previewDescription"
        descriptionButton.addAction(UIAction { [weak self] _ in self?.openInformation?() }, for: .touchUpInside)
        notice.isUserInteractionEnabled = false; notice.accessibilityTraits = .staticText
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(text: String, hasInteracted: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 20; paragraph.maximumLineHeight = 20
        paragraph.lineBreakMode = .byTruncatingTail
        body.attributedText = NSAttributedString(string: text, attributes: [.paragraphStyle: paragraph])
        descriptionButton.accessibilityLabel = text
        notice.isHidden = !hasInteracted; setNeedsLayout()
    }
    private func measure(_ width: CGFloat, apply: Bool) -> CGFloat {
        let inset = min(16, width / 2), available = max(0, width - 2 * inset)
        var y: CGFloat = 16
        func place(_ view: UIView, gap: CGFloat) {
            let size = view.sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude))
            if apply { view.frame = CGRect(x: inset, y: y, width: min(available, size.width), height: size.height) }
            y += size.height + gap
        }
        if !notice.isHidden { place(notice, gap: 8) }
        place(heading, gap: 4); place(body, gap: 16); place(episodes, gap: 4)
        if apply { descriptionButton.frame = body.frame }
        return y
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: measure(size.width, apply: false)) }
    override func layoutSubviews() { super.layoutSubviews(); _ = measure(bounds.width, apply: true) }
}
