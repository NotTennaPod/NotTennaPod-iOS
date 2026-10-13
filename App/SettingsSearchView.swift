import UIKit
import NotTennaPodCore

/// lib.preferencesearch `searchpreference_searchbar.xml`: a 48-point card with 24-point corners holding the search
/// glyph (48-point box, 12-point padding, 8-point side margins), the text, then Clear and More (48-point boxes).
/// The Settings root shows it read-only (`searchpreference_preference.xml`, 8-point padding); the search page edits it.
@MainActor final class SettingsSearchCard: UIView {
    let icon = UIImageView(image: UIImage(named: "ic_search"))
    /// The editable field (search page) or nil (Settings root, where the hint is a label).
    let field: UITextField?
    let hint: UILabel?
    let clear: UIButton?
    let more: UIButton?

    /// CardView's default background: white on a light theme, #424242 on a dark one (Full black included).
    static var cardColor: UIColor { Appearance.color(0xffffff, 0x424242, black: 0x424242) }
    static var hintColor: UIColor { Appearance.color(0x757575, 0x9e9e9e) }

    init(editable: Bool, onClear: (() -> Void)? = nil, onMore: ((UIView) -> Void)? = nil) {
        if editable {
            let field = UITextField()
            field.font = Appearance.font(18)
            field.textColor = Appearance.foreground
            field.attributedPlaceholder = NSAttributedString(string: Appearance.text("preference_search_hint"),
                attributes: [.foregroundColor: Self.hintColor, .font: Appearance.font(18)])
            // inputType="textNoSuggestions"; the IME "Done" action hides the keyboard.
            field.autocorrectionType = .no; field.spellCheckingType = .no; field.autocapitalizationType = .none
            field.smartQuotesType = .no; field.smartDashesType = .no; field.inlinePredictionType = .no
            field.returnKeyType = .done
            field.accessibilityIdentifier = "settingsSearchField"
            self.field = field; hint = nil
            let clear = Appearance.icon("ic_close", label: Appearance.text("preference_search_clear_input")) { onClear?() }
            clear.accessibilityIdentifier = "settingsSearchClear"; clear.isHidden = true
            self.clear = clear
            let more = Appearance.icon("dots_vertical", label: Appearance.text("overflow_more")) {}
            more.accessibilityIdentifier = "settingsSearchMore"
            more.addAction(UIAction { [weak more] _ in if let more { onMore?(more) } }, for: .touchUpInside)
            self.more = more
        } else {
            let hint = Appearance.label(Appearance.text("preference_search_hint"), size: 18)
            hint.textColor = Self.hintColor; hint.numberOfLines = 1
            self.hint = hint; field = nil; clear = nil; more = nil
        }
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 48))
        backgroundColor = Self.cardColor
        layer.cornerRadius = 24
        // CardView's resting elevation.
        layer.shadowColor = UIColor.black.cgColor; layer.shadowOpacity = 0.18
        layer.shadowRadius = 2; layer.shadowOffset = CGSize(width: 0, height: 1)
        icon.tintColor = Appearance.foreground; icon.contentMode = .center
        icon.isAccessibilityElement = false
        [icon, field, hint, clear, more].compactMap { $0 }.forEach(addSubview)
        registerForTraitChanges([UITraitLayoutDirection.self]) { (card: SettingsSearchCard, _) in card.setNeedsLayout() }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let height = bounds.height
        func place(_ view: UIView, x: CGFloat, width: CGFloat) {
            view.frame = CGRect(x: rtl ? bounds.width - x - width : x, y: (height - 48) / 2, width: width, height: 48)
        }
        place(icon, x: 8, width: 48)
        var trailing = bounds.width
        if let more { trailing -= 48; place(more, x: trailing, width: 48) }
        if let clear, !clear.isHidden { trailing -= 48; place(clear, x: trailing, width: 48) }
        let textX: CGFloat = 8 + 48 + 8
        let textWidth = max(0, trailing - textX - (more == nil ? 16 : 0))
        if let field { place(field, x: textX, width: textWidth); field.textAlignment = rtl ? .right : .left }
        if let hint { place(hint, x: textX, width: textWidth); hint.textAlignment = rtl ? .right : .left }
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }
}

/// `SearchPreferenceFragment` (lib.preferencesearch 2.7.3) as AntennaPod configures it (MPF:127–153): the search
/// card, then the history (empty query) or up to ten results with title, summary and breadcrumbs, or "No results".
@MainActor final class SettingsSearchView: UIView, UITextFieldDelegate, UIScrollViewDelegate {
    let card: SettingsSearchCard
    var field: UITextField { card.field! }
    private let list = UIScrollView()
    private let noResults = Appearance.label(Appearance.text("preference_search_no_results"), size: 14)
    private var rows: [UIControl] = []
    private var items: [SettingsSearch.Item]
    let history: SettingsSearchHistoryStore
    private let locale: Locale
    /// Shown results, best first (empty while the query is empty).
    private(set) var results: [SettingsSearch.Item] = []
    var onSelect: ((SettingsSearch.Item) -> Void)?
    var onMore: ((UIView) -> Void)?
    var onFailure: ((any Error) -> Void)?

    init(items: [SettingsSearch.Item], history: SettingsSearchHistoryStore, locale: Locale = .current) {
        self.items = items; self.history = history; self.locale = locale
        var clearAction: (() -> Void)?, moreAction: ((UIView) -> Void)?
        card = SettingsSearchCard(editable: true, onClear: { clearAction?() }, onMore: { moreAction?($0) })
        super.init(frame: .zero)
        clearAction = { [weak self] in self?.setQuery("") }
        moreAction = { [weak self] anchor in self?.onMore?(anchor) }
        backgroundColor = Appearance.background
        accessibilityIdentifier = "settingsSearch"
        field.delegate = self
        field.addAction(UIAction { [weak self] _ in self?.update() }, for: .editingChanged)
        list.accessibilityIdentifier = "settingsSearchResults"
        list.contentInsetAdjustmentBehavior = .never; list.keyboardDismissMode = .onDrag
        list.alwaysBounceVertical = true
        noResults.textAlignment = .center; noResults.textColor = Appearance.foreground
        noResults.accessibilityIdentifier = "settingsSearchNoResults"
        addSubview(list); addSubview(noResults); addSubview(card)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `onResume`: the keyboard opens on the search field (also when coming back from a result's screen).
    func focus() {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, field.window != nil else { return }
            field.becomeFirstResponder()
        }
    }

    /// A history row and the Clear button set the query as typing would.
    func setQuery(_ query: String) {
        field.text = query
        if let end = field.position(from: field.endOfDocument, offset: 0) { field.selectedTextRange = field.textRange(from: end, to: end) }
        update()
    }

    /// The rows found change (a restored page's index built again once the synchronization account is read); the
    /// text typed stays and is searched again.
    func replaceItems(_ items: [SettingsSearch.Item]) {
        self.items = items
        update()
    }

    /// The rows the settings show, when they changed (a server row came or went, PROTOCOL §15.5); the text typed stays and is
    /// searched again. Unchanged rows leave the results as they are.
    func refreshItems(_ items: [SettingsSearch.Item]) {
        guard items != self.items else { return }
        replaceItems(items)
    }

    /// The More menu's "Clear history".
    func clearHistory() {
        field.text = ""
        do { try history.clear() } catch { onFailure?(error) }
        update()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool { textField.resignFirstResponder(); return true }
    @objc private func keyboardChanged() { setNeedsLayout() }

    /// `updateSearchResults`: an empty query shows the history; otherwise the search results. Either list,
    /// when empty, gives way to the "No results" text.
    func update() {
        let query = field.text ?? ""
        card.clear?.isHidden = query.isEmpty
        rows.forEach { $0.removeFromSuperview() }
        if query.isEmpty {
            results = []
            rows = history.terms.enumerated().map { historyRow($1, index: $0) }
        } else {
            results = SettingsSearch.search(query, in: items, locale: locale)
            rows = results.enumerated().map { resultRow($1, index: $0) }
        }
        rows.forEach(list.addSubview)
        let empty = rows.isEmpty
        noResults.isHidden = !empty; list.isHidden = empty
        list.contentOffset = .zero
        card.setNeedsLayout(); setNeedsLayout()
    }

    private func label(_ text: String?, size: CGFloat, alpha: CGFloat = 1) -> UILabel {
        let label = Appearance.label(text, size: size)
        label.textColor = Appearance.foreground.withAlphaComponent(alpha); label.numberOfLines = 0
        label.isUserInteractionEnabled = false
        return label
    }

    private func resultRow(_ item: SettingsSearch.Item, index: Int) -> UIControl {
        let row = SettingsSearchRow()
        row.labels = [label(item.title, size: 16), label(item.displaySummary, size: 14),
                      label(item.breadcrumbs.isEmpty ? nil : item.breadcrumbs, size: 14, alpha: 0.6)].filter { $0.text?.isEmpty == false }
        row.labels.forEach(row.addSubview)
        row.accessibilityIdentifier = "settingsSearchResult-\(index)"
        row.accessibilityLabel = item.title ?? item.displaySummary
        row.accessibilityValue = item.breadcrumbs
        row.accessibilityHint = item.title == nil ? nil : item.displaySummary
        row.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            field.resignFirstResponder()
            onSelect?(item)
        }, for: .touchUpInside)
        return row
    }

    private func historyRow(_ term: String, index: Int) -> UIControl {
        let row = SettingsSearchRow()
        let icon = UIImageView(image: UIImage(named: "ic_history")); icon.tintColor = Appearance.foreground
        icon.isAccessibilityElement = false
        row.icon = icon; row.addSubview(icon)
        row.labels = [label(term, size: 14)]; row.labels.forEach(row.addSubview)
        row.accessibilityIdentifier = "settingsSearchHistory-\(index)"
        row.accessibilityLabel = term
        row.addAction(UIAction { [weak self] _ in self?.setQuery(term) }, for: .touchUpInside)
        return row
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bottom = max(0, min(bounds.height, keyboardLayoutGuide.layoutFrame.minY))
        card.frame = CGRect(x: 8, y: 8, width: max(0, bounds.width - 16), height: 48)
        let top = card.frame.maxY
        list.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bottom - top))
        var y: CGFloat = 0
        for row in rows {
            let height = (row as? SettingsSearchRow)?.height(width: bounds.width) ?? 56
            row.frame = CGRect(x: 0, y: y, width: bounds.width, height: height); y += height
        }
        list.contentSize = CGSize(width: bounds.width, height: y)
        let textWidth = max(0, bounds.width - 96)
        let textHeight = noResults.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        noResults.frame = CGRect(x: 48, y: top + 48, width: textWidth, height: textHeight)
    }
}

/// A result (`searchpreference_list_item_result.xml`: 16-point padding; title 16, summary 14, breadcrumbs 14 at 60 %)
/// or a history row (`searchpreference_list_item_history.xml`: history glyph, 8 before and 24 after it, then the term).
@MainActor final class SettingsSearchRow: UIControl {
    var labels: [UILabel] = []
    var icon: UIImageView?
    private let pressed = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true; accessibilityTraits = .button
        pressed.backgroundColor = Appearance.foreground.withAlphaComponent(0.12)
        pressed.isUserInteractionEnabled = false; pressed.isHidden = true
        addSubview(pressed)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isHighlighted: Bool { didSet { pressed.isHidden = !isHighlighted } }

    private var textX: CGFloat { icon == nil ? 16 : 16 + 8 + 24 + 24 }

    func height(width: CGFloat) -> CGFloat {
        let textWidth = max(0, width - textX - 16)
        let text = labels.reduce(CGFloat(0)) { $0 + $1.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height }
        return ceil(max(text, icon == nil ? 0 : 24) + 32)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        pressed.frame = bounds
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let textWidth = max(0, bounds.width - textX - 16)
        let total = labels.reduce(CGFloat(0)) { $0 + $1.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height }
        var y = (bounds.height - total) / 2
        for label in labels {
            let h = label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
            label.frame = CGRect(x: rtl ? bounds.width - textX - textWidth : textX, y: y, width: textWidth, height: h)
            label.textAlignment = rtl ? .right : .left
            y += h
        }
        if let icon {
            let x: CGFloat = 16 + 8
            icon.frame = CGRect(x: rtl ? bounds.width - x - 24 : x, y: (bounds.height - 24) / 2, width: 24, height: 24)
        }
    }
}
