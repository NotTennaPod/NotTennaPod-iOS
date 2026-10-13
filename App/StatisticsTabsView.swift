import UIKit
import NotTennaPodCore

/// The Statistics tab bar and pager (`pager_fragment.xml`: a `TabLayout` under the toolbar over a
/// `ViewPager2`). iOS has neither; this is a bounded adaptation: a top strip of equal-width
/// tabs with an indicator, same labels and order, over a horizontally paged container. Tap and swipe
/// both switch; in RTL the tabs and the swipe direction mirror (Subscriptions is right-most).
@MainActor
final class StatisticsPagerView: UIView, UIScrollViewDelegate {
    /// A settled selection by the person (tap or swipe); not called for programmatic `select`.
    var onSelect: ((Int) -> Void)?
    private(set) var selected = 0
    let strip = UIView()
    private var tabs: [UIButton] = []
    private let indicator = UIView()
    let pages = UIScrollView()
    private(set) var pageViews: [UIScrollView] = []
    private var contents: [UIView?]
    private var spinners: [UIActivityIndicatorView] = []
    private var animatingTo: Int?
    /// The page last reported through `onSelect` or set programmatically.
    private var reported = 0
    private var laidOutSize = CGSize.zero
    static let stripHeight: CGFloat = 48

    init(titles: [String], identifiers: [String]) {
        contents = Array(repeating: nil, count: titles.count)
        super.init(frame: .zero)
        accessibilityIdentifier = "statisticsPager"
        strip.backgroundColor = Appearance.background
        strip.accessibilityTraits = .tabBar
        strip.accessibilityIdentifier = "statisticsTabs"
        for (index, title) in titles.enumerated() {
            let tab = UIButton(type: .custom)
            var configuration = UIButton.Configuration.plain()
            configuration.title = title
            configuration.titleLineBreakMode = .byTruncatingTail
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes; attributes.font = Appearance.font(14, medium: true); return attributes
            }
            tab.configuration = configuration
            tab.accessibilityIdentifier = "statisticsTab-" + identifiers[index]
            tab.addAction(UIAction { [weak self] _ in self?.tap(index) }, for: .touchUpInside)
            tabs.append(tab); strip.addSubview(tab)
        }
        indicator.backgroundColor = Appearance.accent
        indicator.layer.cornerRadius = 1.5
        indicator.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        strip.addSubview(indicator)
        pages.isPagingEnabled = true
        pages.showsHorizontalScrollIndicator = false
        pages.bounces = false
        pages.scrollsToTop = false
        pages.contentInsetAdjustmentBehavior = .never
        pages.delegate = self
        pages.accessibilityIdentifier = "statisticsPages"
        for index in titles.indices {
            let page = UIScrollView()
            page.contentInsetAdjustmentBehavior = .never
            page.alwaysBounceVertical = true
            page.accessibilityIdentifier = "statisticsPage-" + identifiers[index]
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.accessibilityIdentifier = index == 0 ? "statisticsLoading" : "statisticsLoading-" + identifiers[index]
            spinner.startAnimating()
            page.addSubview(spinner)
            pageViews.append(page); spinners.append(spinner); pages.addSubview(page)
        }
        addSubview(pages); addSubview(strip)
        updateTabs()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var rightToLeft: Bool { effectiveUserInterfaceLayoutDirection == .rightToLeft }
    private func position(of index: Int) -> Int { rightToLeft ? pageViews.count - 1 - index : index }

    /// Replaces a page's content, keeping its vertical scroll position. nil shows the loading indicator.
    func setContent(_ view: UIView?, forPage index: Int) {
        contents[index]?.removeFromSuperview()
        contents[index] = view
        if let view { pageViews[index].addSubview(view) }
        spinners[index].isHidden = view != nil
        layoutPage(index)
    }

    func content(ofPage index: Int) -> UIView? { contents[index] }

    /// Programmatic selection (restoring the screen's tab); no `onSelect`.
    func select(_ index: Int, animated: Bool) {
        guard pageViews.indices.contains(index) else { return }
        selected = index
        if !animated { reported = index }
        updateTabs()
        let target = CGPoint(x: CGFloat(position(of: index)) * pages.bounds.width, y: 0)
        if animated, pages.bounds.width > 0, pages.contentOffset != target {
            animatingTo = index
            pages.setContentOffset(target, animated: true)
        } else if !pages.isDragging && !pages.isDecelerating {
            animatingTo = nil
            pages.contentOffset = target
            updateIndicator()
        }
    }

    /// A new Statistics screen: first tab, pages scrolled to the top, no content.
    func reset() {
        for index in pageViews.indices {
            setContent(nil, forPage: index)
            pageViews[index].contentOffset = .zero
        }
        select(0, animated: false)
    }

    private func tap(_ index: Int) {
        guard index != selected || pages.isDecelerating else { return }
        select(index, animated: true)
        if animatingTo == nil, reported != index { reported = index; onSelect?(index) }
    }

    private func updateTabs() {
        for (index, tab) in tabs.enumerated() {
            let isSelected = index == selected
            tab.configuration?.baseForegroundColor = isSelected ? Appearance.accent : Appearance.secondary
            tab.accessibilityTraits = isSelected ? [.button, .selected] : .button
        }
        for (index, page) in pageViews.enumerated() { page.accessibilityElementsHidden = index != selected }
    }

    private func updateIndicator() {
        let width = bounds.width / CGFloat(max(1, tabs.count))
        let fraction = pages.bounds.width > 0 ? pages.contentOffset.x / pages.bounds.width : CGFloat(position(of: selected))
        let label = tabs[selected].titleLabel?.intrinsicContentSize.width ?? width
        let indicatorWidth = min(width - 16, max(label, 24))
        indicator.frame = CGRect(x: fraction * width + (width - indicatorWidth) / 2, y: Self.stripHeight - 3, width: indicatorWidth, height: 3)
    }

    private func layoutPage(_ index: Int) {
        let page = pageViews[index]
        let size = page.bounds.size
        guard size.width > 0 else { return }
        if let content = contents[index] {
            let height = content.sizeThatFits(CGSize(width: size.width, height: .greatestFiniteMagnitude)).height
            content.frame = CGRect(x: 0, y: 0, width: size.width, height: height)
            page.contentSize = CGSize(width: size.width, height: max(size.height, height))
            let maxOffset = max(0, page.contentSize.height - size.height)
            if page.contentOffset.y > maxOffset { page.contentOffset.y = maxOffset }
        } else {
            page.contentSize = size
            page.contentOffset = .zero
        }
        spinners[index].center = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width, count = CGFloat(tabs.count)
        strip.frame = CGRect(x: 0, y: 0, width: width, height: Self.stripHeight)
        for (index, tab) in tabs.enumerated() {
            tab.frame = CGRect(x: CGFloat(position(of: index)) * width / count, y: 0, width: width / count, height: Self.stripHeight)
        }
        let pageSize = CGSize(width: width, height: max(0, bounds.height - Self.stripHeight))
        pages.frame = CGRect(x: 0, y: Self.stripHeight, width: width, height: pageSize.height)
        pages.contentSize = CGSize(width: width * count, height: pageSize.height)
        for index in pageViews.indices {
            pageViews[index].frame = CGRect(origin: CGPoint(x: CGFloat(position(of: index)) * width, y: 0), size: pageSize)
            layoutPage(index)
        }
        if laidOutSize != bounds.size || (!pages.isDragging && !pages.isDecelerating && animatingTo == nil) {
            laidOutSize = bounds.size
            animatingTo = nil
            pages.contentOffset = CGPoint(x: CGFloat(position(of: selected)) * width, y: 0)
        }
        updateIndicator()
    }

    // MARK: UIScrollViewDelegate (horizontal pages only)

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pages else { return }
        updateIndicator()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { settle() } }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settle() }

    /// ViewPager2 reports the page once the scroll is idle; the menu follows the settled page.
    private func settle() {
        guard pages.bounds.width > 0 else { return }
        animatingTo = nil
        let slot = Int((pages.contentOffset.x / pages.bounds.width).rounded())
        let index = min(max(0, rightToLeft ? pageViews.count - 1 - slot : slot), pageViews.count - 1)
        selected = index
        updateTabs(); updateIndicator()
        if reported != index { reported = index; onSelect?(index) }
    }
}

/// Years page (`YearStatisticsListAdapter`, `statistics_listitem_barchart.xml`,
/// `statistics_year_listitem.xml`): bar chart, caption and divider, then one row per year with
/// listening, newest first. Rows are not actionable.
@MainActor
final class YearsStatisticsView: UIView {
    let snapshot: YearsStatisticsSnapshot
    let chart: YearsBarChartView
    private let caption = Appearance.label(Appearance.text("statistics_years_barchart_description"), size: 14)
    private let divider = UIView()
    private var rows: [(UIView, UILabel, UILabel)] = []

    init(snapshot: YearsStatisticsSnapshot, formatter: StatisticsTextFormatter) {
        self.snapshot = snapshot
        chart = YearsBarChartView(months: snapshot.chartMonths)
        super.init(frame: .zero)
        accessibilityIdentifier = "yearsStatistics"
        caption.textAlignment = .center
        caption.accessibilityIdentifier = "yearsStatisticsCaption"
        divider.backgroundColor = Appearance.secondary.withAlphaComponent(0.2)
        [chart, caption, divider].forEach(addSubview)
        for item in snapshot.years {
            let row = UIView()
            let year = Appearance.label(String(item.year), size: 16)
            year.numberOfLines = 1
            let hours = Appearance.label(formatter.duration(seconds: item.playedMilliseconds / 1000, hoursLabel: Appearance.text("time_hours")), size: 14)
            hours.numberOfLines = 1; hours.textColor = Appearance.secondary.withAlphaComponent(0.8)
            row.isAccessibilityElement = true
            row.accessibilityLabel = [year.text, hours.text].compactMap { $0 }.joined(separator: ", ")
            row.accessibilityIdentifier = "yearStatistics-\(item.year)"
            [year, hours].forEach(row.addSubview)
            rows.append((row, year, hours)); addSubview(row)
        }
    }
    required init?(coder: NSCoder) { fatalError() }


    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: compose(width: size.width, apply: false)) }
    override func layoutSubviews() { super.layoutSubviews(); _ = compose(width: bounds.width, apply: true) }

    private func compose(width: CGFloat, apply: Bool) -> CGFloat {
        let inner = max(0, width - 32)
        // list_vertical_padding 8, header padding 16, chart 200.
        var y: CGFloat = 8 + 16
        if apply { chart.frame = CGRect(x: 16, y: y, width: inner, height: 200) }
        y += 200
        let captionHeight = caption.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
        if apply { caption.frame = CGRect(x: 16, y: y, width: inner, height: captionHeight) }
        y += captionHeight + 16
        if apply { divider.frame = CGRect(x: 16, y: y, width: inner, height: 1) }
        y += 1 + 16
        for (row, year, hours) in rows {
            let yearHeight = year.font.lineHeight, hoursHeight = hours.font.lineHeight
            let height = 16 + yearHeight + hoursHeight + 8
            if apply {
                row.frame = CGRect(x: 0, y: y, width: width, height: height)
                year.frame = CGRect(x: 16, y: 16, width: inner, height: yearHeight)
                hours.frame = CGRect(x: 16, y: 16 + yearHeight, width: inner, height: hoursHeight)
                year.textAlignment = .natural; hours.textAlignment = .natural
            }
            y += height
        }
        return y + 8
    }
}

/// `BarChartView` drawn from the shared geometry. Not mirrored in RTL (Android draws on an unmirrored
/// canvas). Decorative for VoiceOver: the caption and year rows carry the information.
@MainActor
final class YearsBarChartView: UIView {
    let months: [MonthlyListening]
    static let purple = UIColor(red: 0x9c / 255, green: 0x27 / 255, blue: 0xb0 / 255, alpha: 1)

    init(months: [MonthlyListening]) {
        self.months = months
        super.init(frame: .zero)
        backgroundColor = .clear; contentMode = .redraw
        isAccessibilityElement = false
        accessibilityIdentifier = "yearsStatisticsChart"
    }
    required init?(coder: NSCoder) { fatalError() }

    var layout: YearsBarChartLayout { YearsBarChartLayout(months: months, width: Float(bounds.width), height: Float(bounds.height)) }

    override func draw(_ rect: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let layout = layout
        for bar in layout.bars {
            (bar.purple ? Self.purple : Appearance.accent).setFill()
            UIRectFill(CGRect(x: CGFloat(bar.left), y: CGFloat(bar.top), width: CGFloat(bar.right - bar.left),
                              height: CGFloat(layout.barAreaHeight - bar.top)))
        }
        let font = UIFont(name: "Roboto-Regular", size: CGFloat(layout.textSize)) ?? .systemFont(ofSize: CGFloat(layout.textSize))
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Appearance.secondary]
        func text(_ value: String, x: Float, baseline: Float) {
            (value as NSString).draw(at: CGPoint(x: CGFloat(x), y: CGFloat(baseline) - font.ascender), withAttributes: attributes)
        }
        let hairline = 1 / max(1, traitCollection.displayScale)
        Appearance.secondary.setStroke()
        for separator in layout.separators {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: CGFloat(separator.x), y: bounds.height))
            path.addLine(to: CGPoint(x: CGFloat(separator.x), y: CGFloat(layout.barAreaHeight)))
            path.lineWidth = hairline; path.stroke()
        }
        for label in layout.yearLabels { text(label.text, x: label.x, baseline: label.baseline) }
        for line in layout.gridLines {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 0, y: CGFloat(line.y)))
            path.addLine(to: CGPoint(x: bounds.width, y: CGFloat(line.y)))
            path.lineWidth = hairline
            // DashPathEffect(10 px on, 10 px off).
            let dash = 10 / max(1, traitCollection.displayScale)
            path.setLineDash([dash, dash], count: 2, phase: 0)
            path.stroke()
            text(line.label, x: 0, baseline: line.textBaseline)
        }
    }
}
