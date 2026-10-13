import UIKit
import NotTennaPodCore

/// Source BodyMedium text. Funding links must not enable text selection; the
/// description allows selection but does not automatically turn URLs into links.
@MainActor
final class FeedInformationTextView: UITextView {
    enum Kind { case funding, description }
    let kind: Kind
    var openLink: ((String) -> Void)?
    private(set) var links: [FeedInformationLinks.Link] = []
    private var sourceText = ""
    private var configuredCategory: UIContentSizeCategory?
    private var configuredDirection: UIUserInterfaceLayoutDirection?

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero, textContainer: nil)
        isEditable = false; isSelectable = kind == .description
        isScrollEnabled = false; backgroundColor = .clear
        textContainerInset = .zero; textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = kind == .funding ? 8 : 0
        textContainer.lineBreakMode = .byClipping
        dataDetectorTypes = []
        accessibilityIdentifier = kind == .funding ? "supportUrl" : "descriptionLabel"
        if kind == .funding {
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        }
        update("")
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ value: String) {
        sourceText = value
        links = kind == .funding ? FeedInformationLinks.matches(in: value) : []
        configuredCategory = nil
        refreshTypography()
        accessibilityCustomActions = links.map { link in
            UIAccessibilityCustomAction(name: (value as NSString).substring(with: link.range)) { [weak self] _ in
                guard let self else { return false }
                self.openLink?(link.url); return self.openLink != nil
            }
        }
        invalidateIntrinsicContentSize()
    }
    private func refreshTypography() {
        let category = traitCollection.preferredContentSizeCategory, direction = effectiveUserInterfaceLayoutDirection
        guard configuredCategory != category || configuredDirection != direction else { return }
        configuredCategory = category; configuredDirection = direction
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: UIFont(name: "Roboto-Regular", size: 14)!, compatibleWith: traitCollection)
        self.font = font
        let scale = font.pointSize / 14
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 20 * scale; paragraph.maximumLineHeight = 20 * scale
        paragraph.alignment = direction == .rightToLeft ? .right : .left
        let styled = NSMutableAttributedString(string: sourceText, attributes: [
            .font: font, .foregroundColor: Appearance.foreground, .kern: 0.25 * scale, .paragraphStyle: paragraph])
        for link in links {
            styled.addAttributes([.foregroundColor: Appearance.accent, .underlineStyle: NSUnderlineStyle.single.rawValue], range: link.range)
        }
        attributedText = styled
        accessibilityLabel = sourceText
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        refreshTypography()
        let measured = super.sizeThatFits(size)
        let line = 20 * (font?.pointSize ?? 14) / 14
        return CGSize(width: size.width, height: max(line, ceil(measured.height)))
    }
    override func layoutSubviews() { refreshTypography(); super.layoutSubviews() }

    /// Use public UITextInput geometry, leaving UIKit's native text engine and
    /// description selection intact. Nearest-position alone would open links
    /// when tapping whitespace; require a visible character rect as well.
    func link(at point: CGPoint) -> FeedInformationLinks.Link? {
        guard kind == .funding, bounds.contains(point), let position = closestPosition(to: point) else { return nil }
        let offset = offset(from: beginningOfDocument, to: position)
        for index in [offset, offset - 1] where index >= 0 && index < sourceText.utf16.count {
            guard let link = links.first(where: { NSLocationInRange(index, $0.range) }),
                  let start = self.position(from: beginningOfDocument, offset: index),
                  let end = self.position(from: start, offset: 1),
                  let range = textRange(from: start, to: end) else { continue }
            let rect = firstRect(for: range)
            if !rect.isNull && !rect.isInfinite && rect.contains(point) { return link }
        }
        return nil
    }
    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let link = link(at: recognizer.location(in: self)) else { return }
        openLink?(link.url)
    }
}
