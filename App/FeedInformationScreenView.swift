import UIKit
import NotTennaPodCore

/// Retained content for the information route. Asynchronous statistics resize
/// this instance; they never rebuild the route or restart their own load.
@MainActor
final class FeedInformationScreenView: UIView {
    let feedID: Int64
    let appBar: FeedAppBarView
    private var header: SubscribedFeedHeaderView { appBar.header }
    private let body: FeedInformationBodyView
    var onAction: ((FeedInformationBodyView.Action) -> Void)?
    var onSizeChange: (() -> Void)?
    var onSubscribe: (() -> Void)?
    var copyText: (String) -> Void = { UIPasteboard.general.string = $0 }

    init(feed: LibraryFeed, library: FeedLibraryStore?, readStatistics: @escaping FeedStatisticsLoader.Read) throws {
        feedID = feed.id
        appBar = FeedAppBarView(header: SubscribedFeedHeaderView(feed: feed, library: library, informationScreen: true), information: true)
        body = FeedInformationBodyView(feedID: feed.id,
            information: try Self.information(feed), sourceURL: feed.source, readStatistics: readStatistics)
        super.init(frame: .zero)
        accessibilityIdentifier = "feedInformationScreen"
        addSubview(body); addSubview(appBar)
        header.onAction = { [weak self] action in
            switch action {
            case .subscribe: self?.onSubscribe?()
            case .copyTitle(let value), .copyAuthor(let value): self?.copyText(value)
            default: break // List controls are invisible in the information variant.
            }
        }
        body.onAction = { [weak self] in self?.onAction?($0) }
        body.copyURL = { [weak self] in self?.copyText($0) }
        body.onSizeChange = { [weak self] in self?.setNeedsLayout(); self?.onSizeChange?() }
        body.loadStatistics()
    }
    required init?(coder: NSCoder) { fatalError() }
    static func information(_ feed: LibraryFeed) throws -> FeedInformation {
        try FeedInformation(feed: feed, websiteCallable: feed.metadata.link.flatMap(URL.init(string:)).map { UIApplication.shared.canOpenURL($0) } ?? false,
                            supportLabel: Appearance.text("support_podcast"))
    }
    func update(_ feed: LibraryFeed) throws {
        precondition(feed.id == feedID)
        header.update(feed: feed, hasFilter: false, keepUpdated: true)
        body.update(information: try Self.information(feed), sourceURL: feed.source)
    }
    func refreshStatistics() { body.loadStatistics() }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        body.windowWidth = window?.bounds.width ?? size.width
        return CGSize(width: size.width, height: header.sizeThatFits(size).height + body.sizeThatFits(size).height)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let height = header.sizeThatFits(bounds.size).height
        appBar.fullHeaderHeight = height
        appBar.frame = CGRect(x: 0, y: -appBar.toolbarHeight, width: bounds.width, height: height + appBar.toolbarHeight)
        body.frame = CGRect(x: 0, y: height, width: bounds.width, height: max(0, bounds.height - height))
    }
}
