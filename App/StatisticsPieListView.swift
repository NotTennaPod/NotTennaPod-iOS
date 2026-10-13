import UIKit
import NotTennaPodCore

/// The semicircle-chart statistics page (`StatisticsListAdapter`): header with chart, total and
/// caption, then one row per podcast with a chip in its slice colour. Subscriptions and
/// Downloads (`DownloadStatisticsListAdapter`) share it, as on Android.
@MainActor
final class StatisticsPieListView: UIView {
    struct Row {
        let feedID: Int64
        let title: String?
        let imageURL: String?
        let value: Float
        let detail: String
    }
    enum Source: Equatable {
        case subscriptions(SubscriptionStatisticsSnapshot)
        case downloads(DownloadStatisticsSnapshot)
    }
    /// The snapshot this page shows; an identical reload keeps the mounted view.
    var source: Source?
    var openFeedStatistics: ((Int64) -> Void)?
    private let chart: StatisticsPieView
    private let total = Appearance.label(nil, size: 28)
    private let caption = Appearance.label(nil, size: 14)
    private let divider = UIView()
    private var rows: [UIControl] = []
    private var rowLabels: [(UILabel, UILabel, UILabel, EpisodeArtworkView)] = []

    convenience init(feeds: [LibraryFeed], library: FeedLibraryStore?, formatter: StatisticsTextFormatter = .init()) throws {
        try self.init(snapshot: SubscriptionStatisticsSnapshot(feeds: feeds,
            request: .init(preferences: .init(), formatter: formatter)))
    }

    convenience init(snapshot: SubscriptionStatisticsSnapshot) {
        let formatter = snapshot.request.formatter
        let values = snapshot.rows.map(\.statistics)
        let shares = StatisticsPieShares(values: values.map { Float($0.playedSeconds) })
        // Java's float-to-long conversion saturates; Swift's conversion traps
        // when accumulated imported history exceeds Int64's range.
        let totalSeconds = shares.sum >= Float(Int64.max) ? Int64.max
            : shares.sum <= Float(Int64.min) ? Int64.min : Int64(shares.sum)
        let period = StatisticsPeriodCaption(preferences: snapshot.request.preferences,
            oldestMilliseconds: snapshot.statistics.oldestPlaybackMilliseconds, formatter: formatter)
        let caption = snapshot.request.preferences.includeMarkedAsPlayed ? Appearance.text("statistics_counting_total")
            : String(format: Appearance.text("statistics_counting_range"), period.from, period.to)
        self.init(identifier: "subscriptionStatistics", prefix: "statistics",
                  total: formatter.duration(seconds: totalSeconds, hoursLabel: Appearance.text("time_hours")), caption: caption,
                  rows: zip(snapshot.rows, values).map { row, value in
                      Row(feedID: value.feedID, title: row.title, imageURL: row.imageURL, value: Float(value.playedSeconds),
                          detail: formatter.duration(seconds: value.playedSeconds, hoursLabel: Appearance.text("time_hours")))
                  })
    }

    /// Downloads page (`DownloadStatisticsListAdapter`): header = total size of downloaded episodes,
    /// rows = "<size> • <n episode(s)>". The header uses the exact byte sum; Android's float sum
    /// formats identically.
    convenience init(downloads snapshot: DownloadStatisticsSnapshot, formatter: StatisticsTextFormatter) {
        self.init(identifier: "downloadStatistics", prefix: "downloadStatistics",
                  total: formatter.fileSize(bytes: snapshot.totalBytes),
                  caption: Appearance.quantity("total_size_downloaded_podcasts", count: snapshot.totalEpisodes),
                  rows: snapshot.rows.map { row in
                      Row(feedID: row.feedID, title: row.title, imageURL: row.imageURL, value: Float(row.bytes),
                          detail: formatter.fileSize(bytes: row.bytes) + " \u{2022} " + Appearance.quantity("num_episodes", count: row.downloadedEpisodes))
                  })
    }

    /// `prefix` keeps each page's identifiers distinct while all pages are mounted in the pager.
    init(identifier: String, prefix: String, total totalText: String, caption captionText: String, rows values: [Row]) {
        chart = StatisticsPieView(values: values.map(\.value))
        super.init(frame: .zero)
        accessibilityIdentifier = identifier
        total.text = totalText
        total.accessibilityIdentifier = prefix + "Total"
        total.textAlignment = .center; caption.textAlignment = .center; caption.numberOfLines = 3
        caption.accessibilityIdentifier = prefix + "Caption"
        chart.accessibilityIdentifier = prefix + "Chart"
        caption.text = captionText
        divider.backgroundColor = Appearance.secondary.withAlphaComponent(0.2)
        [chart, total, caption, divider].forEach(addSubview)
        for (index, value) in values.enumerated() {
            let row = UIControl()
            row.accessibilityIdentifier = prefix + "Feed-\(value.feedID)"
            row.addAction(UIAction { [weak self] _ in self?.openFeedStatistics?(value.feedID) }, for: .touchUpInside)
            let artwork = EpisodeArtworkView(source: value.imageURL, fallback: nil, title: nil)
            let title = Appearance.label(value.title, size: 16)
            title.numberOfLines = 1; title.lineBreakMode = .byTruncatingTail
            let chip = Appearance.label("\u{2B24}", size: 13); chip.textColor = chart.color(index)
            chip.accessibilityIdentifier = prefix + "Chip-\(value.feedID)"
            let detail = Appearance.label(value.detail, size: 14)
            detail.textColor = Appearance.secondary; detail.numberOfLines = 1
            row.isAccessibilityElement = true; row.accessibilityTraits = .button
            row.accessibilityLabel = [value.title, detail.text].compactMap { $0 }.joined(separator: ", ")
            [artwork, title, chip, detail].forEach { $0.isUserInteractionEnabled = false; row.addSubview($0) }
            rows.append(row); rowLabels.append((title, chip, detail, artwork)); addSubview(row)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: compose(width: size.width, apply: false)) }
    override func layoutSubviews() { super.layoutSubviews(); _ = compose(width: bounds.width, apply: true) }
    private func compose(width: CGFloat, apply: Bool) -> CGFloat {
        let chartWidth = min(460, max(0, width - 48)), chartHeight = chartWidth / 2
        let captionHeight = caption.sizeThatFits(CGSize(width: max(0, width - 32), height: .greatestFiniteMagnitude)).height
        let totalHeight = total.sizeThatFits(CGSize(width: max(0, width - 32), height: .greatestFiniteMagnitude)).height
        let headerHeight = max(chartHeight + 48, totalHeight + captionHeight + 68)
        if apply {
            chart.frame = CGRect(x: (width - chartWidth) / 2, y: 32, width: chartWidth, height: chartHeight)
            caption.frame = CGRect(x: 16, y: headerHeight - 32 - captionHeight, width: max(0, width - 32), height: captionHeight)
            total.frame = CGRect(x: 16, y: caption.frame.minY - totalHeight - 4, width: max(0, width - 32), height: totalHeight)
            divider.frame = CGRect(x: 16, y: headerHeight, width: max(0, width - 32), height: 1)
        }
        var y = headerHeight + 17
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rtl ? width - x - w : x, y: y, width: w, height: h)
        }
        for (row, labels) in zip(rows, rowLabels) {
            let (title, chip, detail, artwork) = labels
            let t = title.font.lineHeight, d = max(chip.font.lineHeight, detail.font.lineHeight)
            let height = max(40, t + d) + 16
            if apply {
                row.frame = CGRect(x: 0, y: y, width: width, height: height)
                artwork.frame = frame(16, (height - 40) / 2, 40, 40)
                title.frame = frame(72, 8, max(0, width - 88), t)
                let chipWidth = chip.sizeThatFits(CGSize(width: 30, height: d)).width
                chip.frame = frame(72, 8 + t, chipWidth, d)
                detail.frame = frame(76 + chipWidth, 8 + t, max(0, width - 92 - chipWidth), d)
            }
            y += height
        }
        return y + 16
    }
}

@MainActor
private final class StatisticsPieView: UIView {
    private let shares: StatisticsPieShares
    init(values: [Float]) { shares = StatisticsPieShares(values: values); super.init(frame: .zero); backgroundColor = .clear; contentMode = .redraw }
    required init?(coder: NSCoder) { fatalError() }
    var values: [Float] { shares.values }
    func fraction(_ index: Int) -> CGFloat { CGFloat(shares.fraction(index)) }
    func color(_ index: Int) -> UIColor { Self.color(shares.color(index)) }
    static func color(_ value: UInt32) -> UIColor {
        UIColor(red: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    override func draw(_ rect: CGRect) {
        let stroke = bounds.height / 30, radius = bounds.height - stroke
        guard radius > 0 else { return }
        func arc(_ start: CGFloat, _ sweep: CGFloat, _ color: UIColor) {
            let path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: stroke + radius), radius: radius,
                startAngle: start * .pi / 180, endAngle: (start + sweep) * .pi / 180, clockwise: true)
            path.lineWidth = stroke; path.lineCapStyle = .round; color.setStroke(); path.stroke()
        }
        var start: CGFloat = 180
        for index in values.indices {
            guard shares.isLargeEnoughToDisplay(index) else { break }
            let padding: CGFloat = index == 0 ? 1.5 : 3
            let sweep = 177 * fraction(index)
            arc(start + padding, sweep - padding, color(index)); start += sweep
        }
        let sweep = 360 - start - 1.5
        if sweep > 3 { arc(start + 3, sweep - 3, Self.color(StatisticsPieShares.gray)) }
    }
}
