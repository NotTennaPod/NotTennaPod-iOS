import UIKit
import NotTennaPodCore

/// Source feed_statistics.xml composition. Text is supplied by the statistics
/// formatter; this view also preserves the original ellipsis loading state.
@MainActor
final class FeedStatisticsCardsView: UIView {
    typealias Card = FeedStatisticsCardText.ID
    typealias Content = FeedStatisticsCardText.Text
    let detailed: Bool
    private var cards: [Card: StatisticsCardView] = [:]
    private var rows: [[Card]] {
        var result: [[Card]] = [[.playbackTime, .episodesStarted, .spaceDownloaded]]
        if detailed { result.append([.durationTotal, .episodesTotal, .episodesDownloaded]) }
        result.append([.expectedNextEpisode, .episodeSchedule])
        return result
    }

    init(detailed: Bool, contents: [Card: Content] = [:]) {
        self.detailed = detailed
        super.init(frame: .zero)
        for id in rows.flatMap({ $0 }) {
            let card = StatisticsCardView()
            card.accessibilityIdentifier = "statistics.\(id.rawValue)"
            card.backgroundColor = detailed ? Appearance.background : Appearance.navigation
            cards[id] = card
            addSubview(card)
        }
        update(contents)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: FeedStatisticsCardsView, _) in
            view.cards.values.forEach { $0.refreshTypography() }
            view.invalidateIntrinsicContentSize(); view.setNeedsLayout()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    static func contents(snapshot: FeedStatisticsSnapshot, formatter: StatisticsTextFormatter) -> [Card: Content] {
        FeedStatisticsCardText(snapshot: snapshot, formatter: formatter, text: Appearance.text,
            quantity: { key, count in Appearance.quantity(key, count: count) }).values
    }

    func update(snapshot: FeedStatisticsSnapshot, formatter: StatisticsTextFormatter) {
        update(Self.contents(snapshot: snapshot, formatter: formatter))
    }

    func update(_ contents: [Card: Content]) {
        for (id, card) in cards { card.update(contents[id] ?? Content(value: "…", subtitle: "")) }
        invalidateIntrinsicContentSize(); setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: max(0, size.width), height: frames(width: max(0, size.width)).height)
    }
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: sizeThatFits(bounds.size).height)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let layout = frames(width: bounds.width)
        for (id, frame) in layout.frames {
            guard let card = cards[id] else { continue }
            card.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            card.frame = frame
            card.setNeedsLayout()
        }
        // Keep traversal in source order when visual coordinates are mirrored.
        accessibilityElements = rows.flatMap { $0 }.compactMap { cards[$0] }
    }

    private func frames(width: CGFloat) -> (frames: [Card: CGRect], height: CGFloat) {
        let width = max(0, width)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        var result: [Card: CGRect] = [:], y: CGFloat = 0
        for row in rows {
            let slot = width / CGFloat(row.count), cardWidth = max(0, slot - 8)
            let height = row.compactMap { cards[$0]?.sizeThatFits(CGSize(width: cardWidth, height: .greatestFiniteMagnitude)).height }.max() ?? 0
            for (index, id) in row.enumerated() {
                let leading = CGFloat(index) * slot + min(4, slot / 2)
                result[id] = CGRect(x: rtl ? width - leading - cardWidth : leading, y: y + 4,
                                    width: cardWidth, height: height)
            }
            y += height + 8
        }
        return (result, y)
    }
}

@MainActor
private final class StatisticsCardView: UIView {
    private let value = Appearance.label(nil, size: 14)
    private let subtitle = Appearance.label(nil, size: 12)
    private var content = FeedStatisticsCardsView.Content(value: "…", subtitle: "")
    private var configuredCategory: UIContentSizeCategory?
    private var configuredDirection: UIUserInterfaceLayoutDirection?

    init() {
        super.init(frame: .zero)
        addSubview(value); addSubview(subtitle)
        value.accessibilityIdentifier = "statisticsValue"
        subtitle.accessibilityIdentifier = "statisticsSubtitle"
        subtitle.textColor = Appearance.secondary
        isAccessibilityElement = false
        accessibilityElements = [value, subtitle]
        refreshTypography()
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ content: FeedStatisticsCardsView.Content) {
        self.content = content
        configuredCategory = nil
        refreshTypography()
        setNeedsLayout()
    }
    func refreshTypography() {
        let category = traitCollection.preferredContentSizeCategory
        let direction = effectiveUserInterfaceLayoutDirection
        guard configuredCategory != category || configuredDirection != direction else { return }
        configuredCategory = category; configuredDirection = direction
        // Measurement can occur outside UIKit's current-trait drawing scope.
        // Resolve against this view explicitly so measurement and drawing agree.
        value.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: UIFont(name: "Roboto-Medium", size: 14)!, compatibleWith: traitCollection)
        subtitle.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: UIFont(name: "Roboto-Regular", size: 12)!, compatibleWith: traitCollection)
        for (label, text, line, tracking, base) in [(value, content.value, 20.0, 0.1, 14.0),
                                                   (subtitle, content.subtitle, 16.0, 0.4, 12.0)] {
            let scale = label.font.pointSize / base
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = line * scale; paragraph.maximumLineHeight = line * scale
            paragraph.alignment = effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left
            label.attributedText = NSAttributedString(string: text, attributes: [.paragraphStyle: paragraph, .kern: tracking * scale])
        }
    }
    private func heights(width: CGFloat) -> (CGFloat, CGFloat) {
        let available = CGSize(width: max(0, width - 16), height: .greatestFiniteMagnitude)
        return (max(20 * value.font.pointSize / 14, ceil(value.sizeThatFits(available).height)),
                max(16 * subtitle.font.pointSize / 12, ceil(subtitle.sizeThatFits(available).height)))
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        refreshTypography()
        let (first, second) = heights(width: size.width)
        return CGSize(width: max(0, size.width), height: first + second + 16)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        refreshTypography()
        let (first, second) = heights(width: bounds.width)
        value.frame = CGRect(x: min(8, bounds.width / 2), y: 8, width: max(0, bounds.width - 16), height: first)
        subtitle.frame = CGRect(x: value.frame.minX, y: value.frame.maxY, width: value.frame.width, height: second)
    }
}

@MainActor
enum FeedStatisticsDialog {
    static func make(feedID: Int64, title: String?, read: @escaping FeedStatisticsLoader.Read,
                     formatter: StatisticsTextFormatter = .init(),
                     openPodcast: @escaping () -> Void) -> SourceMessageController {
        let content = FeedStatisticsContentView(feedID: feedID, detailed: true, read: read)
        let dialog = SourceMessageController(title: title, message: "",
            positive: .init(title: Appearance.text("ok"), identifier: "statisticsOK"),
            neutral: .init(title: Appearance.text("open_podcast"), identifier: "statisticsOpenPodcast",
                           perform: openPodcast, performAfterDismiss: true),
            customBody: StatisticsDialogBody(content: content))
        content.onSizeChange = { [weak dialog] in dialog?.viewIfLoaded?.setNeedsLayout() }
        content.load(formatter: formatter)
        return dialog
    }

    static func make(feedID: Int64, title: String?, store: FeedLibraryStore,
                     formatter: StatisticsTextFormatter = .init(),
                     openPodcast: @escaping () -> Void) -> SourceMessageController {
        make(feedID: feedID, title: title, read: { id, now, zone in
            try await store.statisticsSnapshot(feedID: id, now: now, timeZone: zone)
        }, formatter: formatter, openPodcast: openPodcast)
    }
    static func make(snapshot: FeedStatisticsSnapshot, formatter: StatisticsTextFormatter,
                     openPodcast: @escaping () -> Void) -> SourceMessageController {
        make(title: snapshot.title, contents: FeedStatisticsCardsView.contents(snapshot: snapshot, formatter: formatter),
             openPodcast: openPodcast)
    }
    static func make(title: String?, contents: [FeedStatisticsCardsView.Card: FeedStatisticsCardsView.Content],
                     openPodcast: @escaping () -> Void) -> SourceMessageController {
        SourceMessageController(title: title, message: "",
            positive: .init(title: Appearance.text("ok"), identifier: "statisticsOK"),
            neutral: .init(title: Appearance.text("open_podcast"), identifier: "statisticsOpenPodcast",
                           perform: openPodcast, performAfterDismiss: true),
            customBody: StatisticsDialogBody(contents: contents))
    }
}

@MainActor
private final class StatisticsDialogBody: UIView {
    let cards: UIView
    convenience init(contents: [FeedStatisticsCardsView.Card: FeedStatisticsCardsView.Content]) {
        self.init(content: FeedStatisticsCardsView(detailed: true, contents: contents))
    }
    init(content: UIView) {
        cards = content
        super.init(frame: .zero)
        accessibilityIdentifier = "statisticsDialogBody"
        addSubview(cards)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: 32 + cards.sizeThatFits(CGSize(width: max(0, size.width - 32), height: size.height)).height)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        cards.semanticContentAttribute = effectiveUserInterfaceLayoutDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        cards.frame = bounds.insetBy(dx: min(16, bounds.width / 2), dy: 16)
    }
}
