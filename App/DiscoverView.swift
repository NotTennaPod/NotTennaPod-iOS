import UIKit
import NotTennaPodCore

/// DiscoveryFragment body (`fragment_online_search.xml`): up to 25 result rows, the spinner, the
/// state text with Retry, and "Suggestions by Apple Podcasts" at the bottom end.
@MainActor final class DiscoverView: UIView {
    let session: TopListSession
    var onSelect: ((PodcastSearchResult) -> Void)?
    var emptyAreaTop: CGFloat = 0
    private let scroll = UIScrollView(), message = UILabel(), spinner = UIActivityIndicatorView(style: .medium)
    private let retry = UIButton(type: .system)
    private let footer = OnlineSearchAttribution()
    private var rows: [OnlineSearchRow] = []
    init(session: TopListSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = Appearance.background
        accessibilityIdentifier = "discoverScreen"
        scroll.accessibilityIdentifier = "discoverResults"; scroll.contentInsetAdjustmentBehavior = .never
        message.numberOfLines = 0; message.textAlignment = .center; message.textColor = Appearance.secondary
        message.accessibilityIdentifier = "discoverMessage"
        retry.setTitle(Appearance.text("retry_label"), for: .normal); retry.tintColor = Appearance.accent
        retry.accessibilityIdentifier = "discoverRetry"
        footer.text = Appearance.text("discover_powered_by_itunes"); footer.numberOfLines = 0
        footer.textColor = Appearance.secondary; footer.backgroundColor = Appearance.background
        footer.accessibilityIdentifier = "discoverAttribution"
        addSubview(scroll); addSubview(footer); scroll.addSubview(message); scroll.addSubview(retry); scroll.addSubview(spinner)
        refreshFonts()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: DiscoverView, _) in
            view.refreshFonts(); view.setNeedsLayout()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    var onRetry: (() -> Void)? {
        didSet {
            retry.removeTarget(nil, action: nil, for: .allEvents)
            retry.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
        }
    }
    private func refreshFonts() {
        message.font = Appearance.font(14, compatibleWith: traitCollection)
        footer.font = Appearance.font(12, compatibleWith: traitCollection)
        retry.titleLabel?.font = Appearance.font(14, medium: true, compatibleWith: traitCollection)
        rows.forEach { $0.refreshFonts(traitCollection) }
    }
    func update() {
        rows.forEach { $0.removeFromSuperview() }; rows = []
        spinner.stopAnimating(); message.isHidden = true; retry.isHidden = true
        switch session.state {
        case .loading: spinner.startAnimating()
        case .loaded(let results):
            rows = results.enumerated().map { index, result in
                let row = OnlineSearchRow(result: result)
                row.accessibilityIdentifier = "discoverResult-\(index)"
                row.addAction(UIAction { [weak self] _ in self?.onSelect?(result) }, for: .touchUpInside)
                row.refreshFonts(traitCollection); scroll.addSubview(row); return row
            }
        case .empty: message.text = Appearance.text("search_status_no_results"); message.isHidden = false
        case .failed(let text): message.text = text; message.isHidden = false; retry.isHidden = false
        case .hidden: message.text = Appearance.text("discover_is_hidden"); message.isHidden = false
        }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        scroll.frame = bounds
        footer.textAlignment = rtl ? .left : .right
        let footerSize = footer.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        footer.frame = CGRect(x: rtl ? 0 : max(0, bounds.width - footerSize.width), y: max(0, bounds.height - footerSize.height),
                              width: min(bounds.width, footerSize.width), height: footerSize.height)
        let columns = max(1, Int((bounds.width + 8) / 408))
        let width = max(0, (bounds.width - CGFloat(columns - 1) * 8) / CGFloat(columns))
        var y: CGFloat = 8
        for start in stride(from: 0, to: rows.count, by: columns) {
            let end = min(rows.count, start + columns)
            let height = rows[start..<end].map { $0.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height }.max() ?? 72
            for index in start..<end {
                let x = CGFloat(index - start) * (width + 8)
                rows[index].frame = CGRect(x: rtl ? bounds.width - x - width : x, y: y, width: width,
                                           height: rows[index].sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            }
            y += height + 8
        }
        let center = max(0, (bounds.height + emptyAreaTop) / 2)
        if !message.isHidden {
            let textWidth = max(0, bounds.width - 32)
            let height = message.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
            let top = max(16, min(center - height / 2, bounds.height - height - (retry.isHidden ? 0 : 64) - footerSize.height - 16))
            message.frame = CGRect(x: 16, y: top, width: textWidth, height: height)
            let retryWidth = min(bounds.width, retry.intrinsicContentSize.width + 32)
            retry.frame = CGRect(x: (bounds.width - retryWidth) / 2, y: message.frame.maxY + 16, width: retryWidth, height: 48)
            y = max(y, retry.isHidden ? message.frame.maxY : retry.frame.maxY)
        }
        spinner.center = CGPoint(x: bounds.midX, y: center)
        scroll.contentSize = CGSize(width: bounds.width, height: max(bounds.height, y + footerSize.height))
    }
}
