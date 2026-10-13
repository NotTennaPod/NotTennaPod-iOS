import UIKit
import OSLog
import NotTennaPodCore

/// The statistics fragment's view lifetime and asynchronous loading boundary.
/// The information body and detailed dialog each own an independent instance.
@MainActor
final class FeedStatisticsContentView: UIView {
    var onSizeChange: (() -> Void)?
    /// Diagnostics only: the source leaves its loading cards on read failure.
    var onFailure: ((String) -> Void)?
    private let feedID: Int64
    private let loader: FeedStatisticsLoader
    private let cards: FeedStatisticsCardsView

    init(feedID: Int64, detailed: Bool, read: @escaping FeedStatisticsLoader.Read) {
        self.feedID = feedID
        loader = FeedStatisticsLoader(read: read)
        cards = FeedStatisticsCardsView(detailed: detailed)
        super.init(frame: .zero)
        accessibilityIdentifier = "feedStatisticsContent"
        addSubview(cards)
        loader.onChange = { [weak self] state in self?.apply(state) }
    }
    convenience init(feedID: Int64, detailed: Bool, store: FeedLibraryStore) {
        self.init(feedID: feedID, detailed: detailed) { id, now, zone in
            try await store.statisticsSnapshot(feedID: id, now: now, timeZone: zone)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    @discardableResult
    func load(formatter: StatisticsTextFormatter = .init()) -> Task<Void, Never> {
        loader.load(feedID: feedID, formatter: formatter)
    }
    func cancel() { loader.cancel() }

    private func apply(_ state: FeedStatisticsLoader.State) {
        switch state {
        case .loaded(let snapshot, let formatter): cards.update(snapshot: snapshot, formatter: formatter)
        case .failed(_, let message):
            cards.update([:])
            if let onFailure { onFailure(message) }
            else { Logger(subsystem: "org.nottennapod.app", category: "Statistics").error("Statistics read failed: \(message)") }
        case .idle, .loading, .unavailable: cards.update([:])
        }
        invalidateIntrinsicContentSize(); setNeedsLayout(); onSizeChange?()
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize { cards.sizeThatFits(size) }
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: sizeThatFits(bounds.size).height)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        cards.semanticContentAttribute = effectiveUserInterfaceLayoutDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        cards.frame = bounds; cards.setNeedsLayout()
    }
}
