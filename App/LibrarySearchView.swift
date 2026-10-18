import UIKit
import NotTennaPodCore

/// SearchFragment's retained query, fixed scope row, horizontal feeds and episode list.
@MainActor final class LibrarySearchView: UIView, UITextFieldDelegate, UIScrollViewDelegate {
    let session: LibrarySearchSession
    let field = UITextField()
    /// A search opened with a submitted query (App Intent) shows its results without the keyboard.
    var focusOnAttach = true
    var emptyAreaTop: CGFloat = 0
    var willReplaceRows: ((UInt64) -> Void)?
    var makeRow: ((Int64, LibraryEpisode) -> EpisodeRowView?)?
    /// The height of a result's row before it is built; nil when its podcast is not loaded (no row).
    var rowHeight: ((Int64, LibraryEpisode, CGFloat) -> CGFloat?)?
    var openFeed: ((Int64) -> Void)?
    var feedContext: ((Int64, UIView, CGPoint) -> Void)?
    var searchOnline: ((String) -> Void)?
    var episodeContext: ((Int64, UIView, CGPoint) -> Void)?
    var selectionChanged: (() -> Void)?
    var selectedItems: (([Int64]) -> [EpisodeListItem])?
    var performSelection: ((EpisodeListAction, [Int64]) -> Void)?
    private(set) var selection = EpisodeListSelection()
    private let selectionBar = EpisodeSelectionBar()
    var displayedIDs: [Int64] { session.result.episodes.map(\.episode.id) }
    func startSelection(_ id: Int64) {
        field.resignFirstResponder(); selection.start(id); updateSelection(); selectionBar.resetScroll()
        UIAccessibility.post(notification: .announcement, argument: Appearance.text("multi_select_started_talkback"))
    }
    @discardableResult func endSelection() -> Bool {
        guard selection.active else { return false }
        selection.end(); updateSelection(); return true
    }
    @discardableResult func toggleSelection(_ id: Int64) -> Bool {
        guard selection.active else { return false }
        selection.toggle(id); updateSelection(); return true
    }
    func changeSelection(_ command: String) {
        switch command {
        case "select_toggle": selection.toggleAll(displayed: displayedIDs)
        case "select_all_above": selection.above(displayed: displayedIDs)
        case "select_all_below": selection.below(displayed: displayedIDs)
        default: return
        }
        updateSelection()
    }
    func updateSelection() {
        let ids = selection.selected(displayed: displayedIDs)
        let items = selectedItems?(ids) ?? []
        selectionBar.isHidden = !selection.active
        // FeedItemMenuHandler leaves the last menu intact for an empty selection.
        // Its buttons report No items selected without closing ActionMode.
        if !selection.active || !items.isEmpty {
            selectionBar.update(actions: EpisodeListMenu.actions(items, selection: true),
                hasMedia: items.count != 1 || items[0].episode.details.media != nil)
        }
        for (id, row) in list?.views ?? [:] { (row as? EpisodeRowView)?.setSelected(selection.ids.contains(id)) }
        field.isHidden = selection.active
        selectionChanged?(); setNeedsLayout()
    }
    private let online = UIButton(type: .system)
    private let onlineOutline = UIView()
    var onFailure: ((any Error) -> Void)?
    private let scope = UIView(), scopeTitle = UILabel(), scopeSurface = UIView()
    private var scopeClose: UIButton!
    private let feeds = UIScrollView(), episodes = UIScrollView()
    private let emptyIcon = UIImageView(image: UIImage(named: "ic_search")), emptyTitle = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    /// Result rows are built only near the screen, like the other episode lists: building all
    /// 300 at once stalled each result. The list is laid out again when results or the width change.
    private var list: LazyContentList?
    private var listWidth: CGFloat = -1
    private var hasRows = false
    private var cards: [UIButton] = []
    private var stripWasRTL = false
    private var pendingPosition: (index: Int, top: CGFloat)?
    private func readingPosition() -> (index: Int, top: CGFloat)? {
        guard let frames = list?.frames, let index = frames.firstIndex(where: { $0.maxY > episodes.contentOffset.y }) else { return nil }
        return (index, frames[index].minY - episodes.contentOffset.y)
    }

    init(session: LibrarySearchSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = Appearance.background
        field.accessibilityIdentifier = "librarySearchQuery"
        field.placeholder = Appearance.text("search_label")
        field.font = Appearance.font(18); field.textColor = Appearance.foreground
        field.tintColor = Appearance.accent; field.returnKeyType = .search
        field.autocorrectionType = .no; field.autocapitalizationType = .none
        field.clearButtonMode = .never; field.delegate = self
        let clear = Appearance.icon("ic_close", label: Appearance.text("search_clear_query")) { [weak self] in
            guard let self else { return }; field.text = ""; field.sendActions(for: .editingChanged)
        }
        clear.accessibilityIdentifier = "searchClearQuery"; clear.frame = CGRect(x: 0, y: 0, width: 48, height: 48)
        field.rightView = clear
        let searchIcon = UIImageView(image: UIImage(named: "ic_search"))
        searchIcon.tintColor = Appearance.foreground; searchIcon.contentMode = .scaleAspectFit
        searchIcon.frame = CGRect(x: 0, y: 12, width: 24, height: 24)
        let leading = UIView(frame: CGRect(x: 0, y: 0, width: 32, height: 48)); leading.addSubview(searchIcon)
        field.leftView = leading; field.leftViewMode = .always
        field.addAction(UIAction { [weak self] _ in
            guard let self else { return }; session.change(field.text ?? "")
        }, for: .editingChanged)
        scope.accessibilityIdentifier = "searchFeedScopeChip"
        scope.accessibilityLabel = session.feedTitle
        scopeSurface.backgroundColor = Appearance.background
        scopeSurface.layer.cornerRadius = 8; scopeSurface.layer.borderWidth = 1
        scopeSurface.layer.borderColor = Appearance.secondary.cgColor
        scopeSurface.isUserInteractionEnabled = false; scope.addSubview(scopeSurface)
        scopeTitle.text = session.feedTitle; scopeTitle.font = Appearance.font(14, medium: true)
        scopeTitle.textColor = Appearance.foreground; scopeTitle.lineBreakMode = .byTruncatingTail
        scope.addSubview(scopeTitle)
        scopeClose = Appearance.icon("ic_close", label: String(format: Appearance.text("search_remove_scope"), session.feedTitle)) { [weak self] in self?.session.clearScope() }
        scopeClose.accessibilityIdentifier = "searchFeedScope"
        scopeClose.configuration?.image = UIImage(named: "ic_close")
        scope.addSubview(scopeClose)
        online.setTitle(Appearance.text("search_online"), for: .normal)
        online.titleLabel?.font = Appearance.font(14, medium: true); online.titleLabel?.numberOfLines = 1
        onlineOutline.layer.cornerRadius = 20; onlineOutline.layer.borderWidth = 1
        onlineOutline.layer.borderColor = Appearance.secondary.cgColor; onlineOutline.isUserInteractionEnabled = false
        online.insertSubview(onlineOutline, at: 0)
        online.tintColor = Appearance.accent; online.accessibilityIdentifier = "searchOnline"
        online.addAction(UIAction { [weak self] _ in
            guard let self else { return }; endSelection(); field.resignFirstResponder(); searchOnline?(session.query)
        }, for: .touchUpInside)
        feeds.addSubview(online)
        episodes.accessibilityIdentifier = "searchEpisodeResults"
        feeds.accessibilityIdentifier = "searchFeedResults"
        episodes.delegate = self; episodes.keyboardDismissMode = .onDrag
        episodes.contentInsetAdjustmentBehavior = .never; feeds.contentInsetAdjustmentBehavior = .never
        emptyIcon.tintColor = Appearance.foreground; emptyIcon.contentMode = .scaleAspectFit
        emptyTitle.font = Appearance.font(16); emptyTitle.textColor = Appearance.foreground
        emptyTitle.textAlignment = .center; emptyTitle.numberOfLines = 0; emptyTitle.accessibilityIdentifier = "searchEmptyTitle"
        [scope, feeds, episodes, spinner, selectionBar].forEach(addSubview)
        selectionBar.isHidden = true
        selectionBar.perform = { [weak self] action in
            guard let self else { return }
            let ids = selection.selected(displayed: displayedIDs)
            guard !selection.ids.isEmpty else { performSelection?(action, []); return }
            endSelection(); performSelection?(action, ids)
        }
        episodes.addSubview(emptyIcon); episodes.addSubview(emptyTitle)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        session.onChange = { [weak self] in self?.updateResults() }
        session.onFailure = { [weak self] in self?.onFailure?($0) }
        updateResults()
    }
    required init?(coder: NSCoder) { fatalError() }
    func toolbarAttached(focus: Bool) {
        if field.text != session.query { field.text = session.query }
        if focus && focusOnAttach {
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, focusOnAttach, field.window != nil else { return }
                field.becomeFirstResponder()
            }
        }
    }
    func reload() { session.refresh() }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder(); session.submit(); return true
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { field.resignFirstResponder() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { if scrollView === episodes { list?.update(in: episodes) } }
    @objc private func keyboardChanged() { setNeedsLayout() }
    func rebuildRows() { updateResults() }
    private func updateResults() {
        pendingPosition = pendingPosition ?? readingPosition()
        willReplaceRows?(session.resultRevision)
        list?.views.values.forEach { $0.removeFromSuperview() }
        list = nil; listWidth = -1
        hasRows = session.result.episodes.contains { height(of: $0, width: 0) != nil }
        buildCards()
        field.rightViewMode = session.query.isEmpty ? .never : .always
        scope.isHidden = session.feedID == nil && !session.archived
        online.isHidden = session.feedID != nil
        feeds.isHidden = cards.isEmpty && online.isHidden
        let empty = !hasRows && !session.loading
        emptyIcon.isHidden = !empty; emptyTitle.isHidden = !empty
        emptyTitle.text = session.query.isEmpty ? Appearance.text("type_to_search")
            : String(format: Appearance.text("no_results_for_query"), session.query)
        if session.loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        // The rows near the screen exist at once, as before; the next layout places everything exactly.
        if bounds.width > 0 { layOutList(width: bounds.width); list?.update(in: episodes) }
        updateSelection()
        setNeedsLayout()
    }

    /// The results after a library change (`LibrarySearchSession.patch`): rows of episodes that left are removed, rows of
    /// episodes that joined are inserted at their place, and built rows `repaint` names are built again (the lists' rule);
    /// every other row keeps its view, and the first visible row stays where it was. Results going to or from empty are
    /// drawn again.
    func patchResults(from old: LibrarySearchResult, repaint: (Int64) -> Bool) {
        guard let list, listWidth == bounds.width, bounds.width > 0 else { updateResults(); return }
        var newIDs: [Int64] = [], heights: [Int64: CGFloat] = [:]
        for result in session.result.episodes {
            guard let height = height(of: result, width: listWidth) else { continue }
            newIDs.append(result.episode.id); heights[result.episode.id] = height
        }
        let oldIDs = list.ids
        if oldIDs.isEmpty != newIDs.isEmpty { updateResults(); return }
        let before = Dictionary(old.episodes.map { ($0.episode.id, $0) }, uniquingKeysWith: { first, _ in first })
        let stale = list.views.keys.filter(repaint)
        if oldIDs == newIDs, session.result == old, stale.isEmpty { return }
        // The first visible row and its offset, kept (item anchoring).
        let anchor = list.firstItem(below: episodes.contentOffset.y).map { ($0.id, $0.frame.minY - episodes.contentOffset.y) }
        if session.result.feeds != old.feeds {
            buildCards()
            feeds.isHidden = cards.isEmpty && online.isHidden
        }
        let change = LibraryViewController.collectionChange(oldIDs, newIDs)
        for removal in change.removed where list.contains(removal.id) { list.remove(removal.id) }
        for insertion in change.inserted { list.insert(insertion.id, height: heights[insertion.id] ?? 0, at: min(insertion.rank, list.count)) }
        let inserted = Set(change.inserted.map(\.id))
        for result in session.result.episodes where !inserted.contains(result.episode.id) && before[result.episode.id] != result {
            list.setHeight(heights[result.episode.id] ?? 0, of: result.episode.id, in: episodes)
        }
        for id in stale where list.contains(id) && !inserted.contains(id) {
            list.setHeight(heights[id] ?? 0, of: id, in: episodes)
            list.rebuild(id, in: episodes)
        }
        list.restoreViewOrder(in: episodes)
        if let (id, top) = anchor, let index = list.index(of: id) { pendingPosition = (index, top) }
        else if let (id, _) = anchor, let next = change.removed.first(where: { $0.id == id }).map({ min($0.rank, max(0, list.count - 1)) }) {
            pendingPosition = (next, 0)
        }
        updateSelection()
        setNeedsLayout()
    }

    /// The podcast results' cards.
    private func buildCards() {
        cards.forEach { $0.removeFromSuperview() }
        cards = session.result.feeds.map { feed in
            let card = UIButton(type: .custom)
            card.accessibilityIdentifier = "searchFeed-\(feed.id)"; card.accessibilityLabel = feed.title
            let artwork = EpisodeArtworkView(source: feed.metadata.imageURL, fallback: nil, title: feed.title)
            artwork.isUserInteractionEnabled = false; artwork.frame = CGRect(x: 0, y: 0, width: 96, height: 96)
            artwork.layer.cornerRadius = 16; artwork.clipsToBounds = true; card.addSubview(artwork)
            card.addAction(UIAction { [weak self] _ in self?.endSelection(); self?.field.resignFirstResponder(); self?.openFeed?(feed.id) }, for: .touchUpInside)
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(feedHeld(_:)))
            card.addGestureRecognizer(hold)
            card.accessibilityCustomActions = [UIAccessibilityCustomAction(name: Appearance.text("overflow_more"), actionHandler: { [weak self, weak card] _ in
                guard let self, let card else { return false }
                feedContext?(feed.id, card, CGPoint(x: 0.5, y: 0.5)); return true
            })]
            feeds.addSubview(card); return card
        }
    }
    private func makeListRow(_ id: Int64) -> UIView {
        guard let result = session.result.episodes.first(where: { $0.episode.id == id }),
              let row = makeRow?(result.feedID, result.episode) else { return UIView() }
        row.contextMenu = { [weak self] anchor, fraction in
            guard let self, !selection.active else { return }
            episodeContext?(id, anchor, fraction)
        }
        if selection.active { row.setSelected(selection.ids.contains(id)) }
        return row
    }
    /// Without a measuring owner (a standalone view), a row is built to measure it.
    private func height(of result: LibrarySearchResult.Episode, width: CGFloat) -> CGFloat? {
        if let rowHeight { return rowHeight(result.feedID, result.episode, width) }
        guard let row = makeRow?(result.feedID, result.episode) else { return nil }
        return width > 0 ? row.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height : 0
    }
    /// Measures and places every result row for this width; rows are built by `update(in:)`.
    private func layOutList(width: CGFloat) {
        list?.views.values.forEach { $0.removeFromSuperview() }
        let list = LazyContentList(top: 8) { [weak self] id in self?.makeListRow(id) ?? UIView() }
        list.fittedHeight = { view, width in view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height }
        list.resized = { [weak self] in self?.setNeedsLayout() }
        var ids: [Int64] = [], heights: [CGFloat] = []
        for result in session.result.episodes {
            guard let height = height(of: result, width: width) else { continue }
            ids.append(result.episode.id); heights.append(height)
        }
        list.append(ids, heights: heights, width: width)
        self.list = list; listWidth = width
    }
    @objc private func feedHeld(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let card = gesture.view as? UIButton,
              let index = cards.firstIndex(of: card), session.result.feeds.indices.contains(index) else { return }
        let point = gesture.location(in: card)
        feedContext?(session.result.feeds[index].id, card, CGPoint(x: point.x / max(1, card.bounds.width), y: point.y / max(1, card.bounds.height)))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let position = pendingPosition ?? readingPosition(); pendingPosition = nil
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let chipWidth = min(max(0, bounds.width - 20), scopeTitle.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 32)).width + 52)
        scope.frame = CGRect(x: rtl ? bounds.width - 10 - chipWidth : 10, y: 0, width: chipWidth, height: 48)
        scopeSurface.frame = scope.bounds.insetBy(dx: 0, dy: 8)
        scopeTitle.frame = CGRect(x: rtl ? 36 : 12, y: 8, width: max(0, chipWidth - 48), height: 32)
        scopeClose.frame = CGRect(x: rtl ? 0 : chipWidth - 36, y: 0, width: 36, height: 48)
        let top: CGFloat = scope.isHidden ? 0 : 48
        let bottom = max(0, min(bounds.height, keyboardLayoutGuide.layoutFrame.minY))
        // In a short selected viewport, reduce only the artwork strip dimensions
        // and let the action strip scroll vertically. Keep the source order and
        // bottom anchor, while retaining space to interact with an episode row.
        let preferredBar = selection.active ? selectionBar.preferredHeight : 0
        let stripHeight: CGFloat = feeds.isHidden ? 0 : (selection.active
            ? min(104, max(48, bottom - top - preferredBar - 48)) : 104)
        let cardSize = max(0, stripHeight - 8), cardStride = cardSize + 8
        let oldMaximum = max(0, feeds.contentSize.width - feeds.bounds.width)
        let leadingOffset = stripWasRTL ? oldMaximum - feeds.contentOffset.x : feeds.contentOffset.x
        feeds.frame = CGRect(x: 0, y: top, width: bounds.width, height: stripHeight)
        let onlineWidth = max(96, online.sizeThatFits(CGSize(width: bounds.width, height: 40)).width + 48)
        let stripWidth = max(bounds.width, CGFloat(cards.count) * cardStride + (online.isHidden ? 0 : onlineWidth + 8) + 24)
        for (i, card) in cards.enumerated() {
            let x = 16 + CGFloat(i) * cardStride
            card.frame = CGRect(x: rtl ? stripWidth - x - cardSize : x, y: 4, width: cardSize, height: cardSize)
            card.subviews.first?.frame = card.bounds
        }
        let onlineX = 16 + CGFloat(cards.count) * cardStride
        online.frame = CGRect(x: rtl ? stripWidth - onlineX - onlineWidth : onlineX, y: min(8, max(0, stripHeight - 48)), width: onlineWidth, height: min(48, stripHeight))
        onlineOutline.frame = online.bounds.insetBy(dx: 0, dy: 4)
        feeds.contentSize = CGSize(width: stripWidth, height: stripHeight)
        let maximum = max(0, stripWidth - feeds.bounds.width)
        let retainedLeading = min(maximum, max(0, leadingOffset))
        feeds.contentOffset.x = rtl ? maximum - retainedLeading : retainedLeading
        stripWasRTL = rtl
        let y = feeds.frame.maxY
        // keyboardLayoutGuide is local to this content view and follows the live window.
        episodes.frame = CGRect(x: 0, y: y, width: bounds.width, height: max(0, bottom - y))
        if list == nil || listWidth != bounds.width { layOutList(width: bounds.width) }
        var rowY: CGFloat = list?.bottom ?? 8
        if !hasRows {
            let textWidth = max(0, bounds.width - 80)
            let textHeight = emptyTitle.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
            // EmptyViewHandler centers icon, title and the retained blank message
            // in the entire source fragment, including its toolbar region.
            let emptyHeight = 32 + textHeight + Appearance.font(14).lineHeight
            let centered = (bounds.height + emptyAreaTop - emptyHeight) / 2 - y
            let top = max(16, min(centered, max(16, episodes.bounds.height - emptyHeight - 16)))
            emptyIcon.frame = CGRect(x: (bounds.width - 32) / 2, y: top, width: 32, height: 32)
            emptyTitle.frame = CGRect(x: 40, y: emptyIcon.frame.maxY, width: textWidth, height: textHeight)
            rowY = emptyTitle.frame.maxY + 16
        }
        let selectionHeight = selection.active ? min(preferredBar, max(0, bottom - y - 48)) : 0
        selectionBar.frame = CGRect(x: 0, y: max(0, bottom - selectionHeight), width: bounds.width, height: min(bottom, selectionHeight))
        rowY += selection.active ? max(112, selectionHeight) : 0
        episodes.verticalScrollIndicatorInsets.bottom = selection.active ? max(112, selectionHeight) : 0
        episodes.contentSize = CGSize(width: bounds.width, height: rowY)
        if let position, let frames = list?.frames, !frames.isEmpty {
            let index = min(position.index, frames.count - 1)
            episodes.contentOffset.y = min(max(0, frames[index].minY - position.top), max(0, rowY - episodes.bounds.height))
        }
        list?.update(in: episodes)
        spinner.center = CGPoint(x: bounds.midX, y: y + episodes.bounds.height / 2)
    }
}
