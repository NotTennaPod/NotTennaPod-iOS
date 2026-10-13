import UIKit
import NotTennaPodCore

/// The scroll content of feedinfo.xml. The parent owns the source header,
/// toolbar, collapsing scroll interaction and navigation. Width is the content
/// viewport; source resource qualification uses the whole window width.
@MainActor
final class FeedInformationBodyView: UIView {
    enum Action: Equatable { case allPodcasts, detailedStatistics, fundingURL(String) }
    var onAction: ((Action) -> Void)?
    var onSizeChange: (() -> Void)?
    var copyURL: (String) -> Void = { UIPasteboard.general.string = $0 }
    var windowWidth: CGFloat? { didSet { invalidateIntrinsicContentSize(); setNeedsLayout() } }
    private let statisticsHeading = Appearance.label(nil, size: 16)
    private let allPodcasts = UIButton(type: .custom)
    private let statistics: FeedStatisticsContentView
    private let statisticsTap = UIControl()
    private let supportHeading = Appearance.label(nil, size: 16)
    private let funding = FeedInformationTextView(kind: .funding)
    private let descriptionHeading = Appearance.label(nil, size: 16)
    private let descriptionText = FeedInformationTextView(kind: .description)
    private let urlHeading = Appearance.label(nil, size: 16)
    private let urlButton = FeedInformationURLButton()
    private var information: FeedInformation
    private var sourceURL: String

    init(feedID: Int64, information: FeedInformation, sourceURL: String, readStatistics: @escaping FeedStatisticsLoader.Read) {
        self.information = information; self.sourceURL = sourceURL
        statistics = FeedStatisticsContentView(feedID: feedID, detailed: false, read: readStatistics)
        super.init(frame: .zero)
        accessibilityIdentifier = "feedInformationBody"
        for (label, key, id) in [(statisticsHeading, "statistics_label", "statisticsHeadingLabel"),
                                  (supportHeading, "support_funding_label", "supportHeadingLabel"),
                                  (descriptionHeading, "description_label", "descriptionHeadingLabel"),
                                  (urlHeading, "url_label", "urlHeadingLabel")] {
            label.text = Appearance.text(key); label.accessibilityIdentifier = id
            label.accessibilityTraits.insert(.header)
        }
        allPodcasts.accessibilityIdentifier = "statisticsButton"
        allPodcasts.setTitle(Appearance.text("statistics_view_all"), for: .normal)
        allPodcasts.setTitleColor(Appearance.accent, for: .normal)
        allPodcasts.addAction(UIAction { [weak self] _ in self?.onAction?(.allPodcasts) }, for: .touchUpInside)
        statisticsTap.accessibilityIdentifier = "statisticsFragmentContainer"
        statisticsTap.addSubview(statistics)
        // A recognizer observes touches in the cards without hiding their text
        // from accessibility or adding a transparent hit-testing overlay.
        statisticsTap.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showStatistics)))
        statisticsTap.addAction(UIAction { [weak self] _ in self?.onAction?(.detailedStatistics) }, for: .touchUpInside)
        statisticsTap.accessibilityCustomActions = [UIAccessibilityCustomAction(name: Appearance.text("statistics_label")) { [weak self] _ in
            guard let self else { return false }; self.onAction?(.detailedStatistics); return self.onAction != nil
        }]
        statistics.onSizeChange = { [weak self] in self?.sizeChanged() }
        funding.openLink = { [weak self] in self?.onAction?(.fundingURL($0)) }
        urlButton.addAction(UIAction { [weak self] _ in guard let self else { return }; self.copyURL(self.sourceURL) }, for: .touchUpInside)
        [statisticsHeading, allPodcasts, statisticsTap, supportHeading, funding, descriptionHeading, descriptionText, urlHeading, urlButton].forEach(addSubview)
        update(information: information, sourceURL: sourceURL)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: FeedInformationBodyView, _) in view.sizeChanged() }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func showStatistics() { onAction?(.detailedStatistics) }
    private func sizeChanged() { invalidateIntrinsicContentSize(); setNeedsLayout(); onSizeChange?() }
    func update(information: FeedInformation, sourceURL: String) {
        self.information = information; self.sourceURL = sourceURL
        [statisticsHeading, allPodcasts, statisticsTap].forEach { $0.isHidden = !information.showsStatistics }
        [supportHeading, funding].forEach { $0.isHidden = !information.showsFunding }
        funding.update(information.funding); descriptionText.update(information.description); urlButton.update(sourceURL)
        if !information.showsStatistics { statistics.cancel() }
        sizeChanged()
    }
    @discardableResult func loadStatistics(formatter: StatisticsTextFormatter = .init()) -> Task<Void, Never>? {
        information.showsStatistics ? statistics.load(formatter: formatter) : nil
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: max(0, size.width), height: compose(width: max(0, size.width), apply: false)) }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: sizeThatFits(bounds.size).height) }
    override func layoutSubviews() { super.layoutSubviews(); _ = compose(width: bounds.width, apply: true) }

    private func compose(width: CGFloat, apply: Bool) -> CGFloat {
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let direction: UISemanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        [statistics, funding, descriptionText, urlButton].forEach { $0.semanticContentAttribute = direction }
        let inset = min(width / 2, 8 + ((windowWidth ?? window?.bounds.width ?? width) >= 1000 ? 56 : 0))
        let inner = max(0, width - 2 * inset), textInset = min(8, inner / 2), textWidth = max(0, inner - 2 * textInset)
        var y: CGFloat = 0
        for label in [statisticsHeading, supportHeading, descriptionHeading, urlHeading] {
            let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: "Roboto-Medium", size: 16)!, compatibleWith: traitCollection)
            label.font = font
            let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = 24 * font.pointSize / 16; paragraph.maximumLineHeight = paragraph.minimumLineHeight
            paragraph.alignment = rtl ? .right : .left
            label.attributedText = NSAttributedString(string: label.text ?? "", attributes: [.paragraphStyle: paragraph, .kern: 0.15 * font.pointSize / 16])
        }
        func frame(_ view: UIView, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
            if apply { view.frame = CGRect(x: rtl ? self.bounds.width - x - width : x, y: y, width: width, height: height) }
        }
        func measure(_ view: UIView, _ width: CGFloat) -> CGFloat { ceil(view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height) }
        if information.showsStatistics {
            y += 16
            let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: "Roboto-Medium", size: 14)!, compatibleWith: traitCollection)
            allPodcasts.titleLabel?.numberOfLines = 0
            allPodcasts.titleLabel?.font = font
            allPodcasts.setAttributedTitle(NSAttributedString(string: Appearance.text("statistics_view_all"), attributes: [.font: font, .kern: 1.25 * font.pointSize / 14, .foregroundColor: Appearance.accent]), for: .normal)
            let natural = allPodcasts.titleLabel?.sizeThatFits(CGSize(width: max(0, textWidth - 16), height: .greatestFiniteMagnitude)) ?? .zero
            let buttonWidth = min(textWidth, ceil(natural.width) + 16)
            let headingWidth = max(0, textWidth - buttonWidth)
            let headingHeight = measure(statisticsHeading, headingWidth), buttonHeight = ceil(natural.height) + 20
            let height = max(headingHeight, buttonHeight)
            frame(statisticsHeading, x: inset + textInset, y: y + (height - headingHeight) / 2, width: headingWidth, height: headingHeight)
            frame(allPodcasts, x: inset + textInset + headingWidth, y: y + (height - buttonHeight) / 2, width: buttonWidth, height: buttonHeight)
            y += height
            let cardsInset = min(4, inner / 2), cardsWidth = max(0, inner - 2 * cardsInset)
            let cardsHeight = measure(statistics, cardsWidth)
            frame(statisticsTap, x: inset, y: y, width: inner, height: cardsHeight)
            if apply { statistics.frame = CGRect(x: cardsInset, y: 0, width: cardsWidth, height: cardsHeight); statistics.setNeedsLayout() }
            y += cardsHeight
        }
        func section(_ heading: UILabel, _ content: UIView, gap: CGFloat) {
            y += 16
            let height = measure(heading, textWidth)
            frame(heading, x: inset + textInset, y: y, width: textWidth, height: height)
            y += height + gap
            let contentHeight = measure(content, textWidth)
            frame(content, x: inset + textInset, y: y, width: textWidth, height: contentHeight)
            y += contentHeight
        }
        if information.showsFunding { section(supportHeading, funding, gap: 4) }
        section(descriptionHeading, descriptionText, gap: 4)
        y += 16
        let headingHeight = measure(urlHeading, textWidth)
        frame(urlHeading, x: inset + textInset, y: y, width: textWidth, height: headingHeight); y += headingHeight
        let urlSize = urlButton.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude))
        frame(urlButton, x: inset, y: y, width: urlSize.width, height: urlSize.height)
        return y + urlSize.height + 8
    }
}

@MainActor
private final class FeedInformationURLButton: UIControl {
    private let label = Appearance.label(nil, size: 14)
    private let icon = UIImageView(image: UIImage(named: "ic_paperclip"))
    private var value = ""
    init() {
        super.init(frame: .zero)
        accessibilityIdentifier = "urlLabel"; isAccessibilityElement = true; accessibilityTraits = .button
        label.numberOfLines = 4; label.lineBreakMode = .byClipping
        icon.tintColor = Appearance.foreground; icon.contentMode = .scaleAspectFit
        [label, icon].forEach { $0.isUserInteractionEnabled = false; addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ value: String) { self.value = value; accessibilityLabel = value; setNeedsLayout() }
    private func typography() {
        label.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: "Roboto-Regular", size: 14)!, compatibleWith: traitCollection)
        let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = 20 * label.font.pointSize / 14; paragraph.maximumLineHeight = paragraph.minimumLineHeight
        paragraph.alignment = effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left
        label.attributedText = NSAttributedString(string: value, attributes: [.paragraphStyle: paragraph, .kern: 0.25 * label.font.pointSize / 14])
    }
    override var isHighlighted: Bool { didSet { backgroundColor = isHighlighted ? Appearance.selected : .clear } }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        typography()
        let text = label.sizeThatFits(CGSize(width: max(0, size.width - 32), height: .greatestFiniteMagnitude))
        return CGSize(width: min(max(0, size.width), ceil(text.width) + 32), height: max(12, ceil(text.height)) + 8)
    }
    override func layoutSubviews() {
        super.layoutSubviews(); typography()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let inset = min(8, bounds.width / 2), iconWidth = min(12, max(0, bounds.width - 2 * inset))
        label.frame = CGRect(x: rtl ? inset + iconWidth + 4 : inset, y: 4, width: max(0, bounds.width - 2 * inset - iconWidth - 4), height: max(0, bounds.height - 8))
        icon.frame = CGRect(x: rtl ? inset : bounds.width - inset - iconWidth, y: (bounds.height - 12) / 2, width: iconWidth, height: 12)
    }
}
