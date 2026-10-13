import UIKit
import NotTennaPodCore

@MainActor final class OnlineSearchView: UIView, UITextFieldDelegate, UIScrollViewDelegate {
    let session: OnlineSearchSession
    let field = UITextField()
    var openFeed: ((String) -> Void)?
    var emptyAreaTop: CGFloat = 0
    private let scroll = UIScrollView(), message = UILabel()
    private let footer = OnlineSearchAttribution()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var retry: UIButton!
    private var rows: [OnlineSearchRow] = []
    private var initialFocus: Bool
    private var pendingPosition: (index: Int, top: CGFloat)?
    init(session: OnlineSearchSession, query: String? = nil) {
        self.session = session; initialFocus = query == nil
        super.init(frame: .zero)
        backgroundColor = Appearance.background
        field.text = query; field.accessibilityIdentifier = "onlineSearchQuery"
        field.placeholder = Appearance.text("search_podcast_hint")
        field.font = Appearance.font(18); field.textColor = Appearance.foreground
        field.tintColor = Appearance.accent; field.returnKeyType = .search
        field.autocorrectionType = .no; field.autocapitalizationType = .none; field.delegate = self
        let icon = UIImageView(image: UIImage(named: "ic_search")); icon.tintColor = Appearance.foreground
        icon.contentMode = .scaleAspectFit; icon.frame = CGRect(x: 0, y: 12, width: 24, height: 24)
        let leading = UIView(frame: CGRect(x: 0, y: 0, width: 32, height: 48)); leading.addSubview(icon)
        field.leftView = leading; field.leftViewMode = .always
        let clear = Appearance.icon("ic_close", label: Appearance.text("search_clear_query")) { [weak self] in
            self?.field.text = ""; self?.field.sendActions(for: .editingChanged)
        }
        clear.accessibilityIdentifier = "onlineSearchClear"; clear.frame = CGRect(x: 0, y: 0, width: 48, height: 48)
        field.rightView = clear; field.rightViewMode = .never
        field.addAction(UIAction { [weak self] _ in self?.updateClear() }, for: .editingChanged)
        updateClear()
        scroll.accessibilityIdentifier = "onlineSearchResults"; scroll.delegate = self
        scroll.contentInsetAdjustmentBehavior = .never; scroll.keyboardDismissMode = .onDrag
        footer.text = String(format: Appearance.text("search_powered_by"), session.provider.name)
        footer.numberOfLines = 0
        footer.font = Appearance.font(12); footer.textColor = Appearance.secondary; footer.backgroundColor = Appearance.background
        footer.accessibilityIdentifier = "onlineSearchProvider"
        message.font = Appearance.font(14); message.textColor = Appearance.secondary; message.numberOfLines = 0; message.textAlignment = .center
        message.accessibilityIdentifier = "onlineSearchMessage"
        retry = UIButton(type: .system); retry.setTitle(Appearance.text("retry_label"), for: .normal)
        retry.titleLabel?.font = Appearance.font(14, medium: true); retry.tintColor = Appearance.accent
        retry.accessibilityIdentifier = "onlineSearchRetry"
        retry.addAction(UIAction { [weak self] _ in self?.session.retry() }, for: .touchUpInside)
        addSubview(scroll); addSubview(footer); scroll.addSubview(message); scroll.addSubview(retry); scroll.addSubview(spinner)
        session.onChange = { [weak self] in self?.updateResults() }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: OnlineSearchView, _) in
            view.pendingPosition = view.pendingPosition ?? view.readingPosition()
            view.refreshFonts()
        }
        refreshFonts()
        if let query { session.submit(query) } else { updateResults() }
    }
    required init?(coder: NSCoder) { fatalError() }
    func toolbarAttached() {
        guard initialFocus else { return }; initialFocus = false
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, field.window != nil else { return }; field.becomeFirstResponder()
        }
    }
    private func refreshFonts() {
        field.font = Appearance.font(18, compatibleWith: traitCollection)
        message.font = Appearance.font(14, compatibleWith: traitCollection)
        footer.font = Appearance.font(12, compatibleWith: traitCollection)
        retry.titleLabel?.font = Appearance.font(14, medium: true, compatibleWith: traitCollection)
        rows.forEach { $0.refreshFonts(traitCollection) }
        setNeedsLayout()
    }
    private func updateClear() { field.rightViewMode = (field.text ?? "").isEmpty ? .never : .always }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        // SearchView submits only a query with non-whitespace text.
        guard !(textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        textField.resignFirstResponder(); session.submit(textField.text ?? ""); return true
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { field.resignFirstResponder() }
    @objc private func keyboardChanged() { setNeedsLayout() }
    private func readingPosition() -> (index: Int, top: CGFloat)? {
        guard let index = rows.firstIndex(where: { $0.frame.maxY > scroll.contentOffset.y }) else { return nil }
        return (index, rows[index].frame.minY - scroll.contentOffset.y)
    }
    private func updateResults() {
        rows.forEach { $0.removeFromSuperview() }; rows = []; pendingPosition = nil
        scroll.contentOffset = .zero; spinner.stopAnimating(); message.isHidden = true; retry.isHidden = true
        switch session.state {
        case .idle: break
        case .loading: spinner.startAnimating()
        case .failure(let error): message.text = error; message.isHidden = false; retry.isHidden = false
        case .results(let results):
            message.text = String(format: Appearance.text("no_results_for_query"), session.submittedQuery)
            message.isHidden = !results.isEmpty
            rows = results.enumerated().map { index, result in
                let row = OnlineSearchRow(result: result)
                row.accessibilityIdentifier = "onlineSearchResult-\(index)"
                row.addAction(UIAction { [weak self] _ in
                    self?.field.resignFirstResponder(); self?.openFeed?(result.feedURL)
                }, for: .touchUpInside)
                row.refreshFonts(traitCollection); scroll.addSubview(row); return row
            }
        }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let position = pendingPosition ?? readingPosition(); pendingPosition = nil
        let bottom = max(0, min(bounds.height, keyboardLayoutGuide.layoutFrame.minY))
        scroll.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bottom)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        footer.textAlignment = rtl ? .left : .right
        let footerSize = footer.sizeThatFits(CGSize(width: max(0, bounds.width), height: .greatestFiniteMagnitude))
        footer.frame = CGRect(x: rtl ? 0 : max(0, bounds.width - footerSize.width), y: max(0, bottom - footerSize.height), width: min(bounds.width, footerSize.width), height: footerSize.height)
        let columns = max(1, Int((bounds.width + 8) / 408))
        let width = max(0, (bounds.width - CGFloat(columns - 1) * 8) / CGFloat(columns))
        var y: CGFloat = 8
        for start in stride(from: 0, to: rows.count, by: columns) {
            let end = min(rows.count, start + columns)
            let height = rows[start..<end].map { $0.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height }.max() ?? 72
            for index in start..<end {
                let column = index - start, x = CGFloat(column) * (width + 8)
                rows[index].frame = CGRect(x: rtl ? bounds.width - x - width : x, y: y, width: width, height: rows[index].sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            }
            y += height + 8
        }
        if rows.isEmpty {
            let messageWidth = max(0, bounds.width - 32)
            let height = message.sizeThatFits(CGSize(width: messageWidth, height: .greatestFiniteMagnitude)).height
            let center = max(0, (bottom + emptyAreaTop) / 2)
            let extra: CGFloat = retry.isHidden ? 0 : 64
            let top = max(16, min(center - height / 2, bottom - height - extra - footerSize.height - 16))
            message.frame = CGRect(x: 16, y: top, width: messageWidth, height: height)
            retry.frame = CGRect(x: max(0, (bounds.width - 112) / 2), y: message.frame.maxY + 16, width: min(112, bounds.width), height: 48)
            spinner.center = CGPoint(x: bounds.midX, y: center)
            y = message.isHidden ? bottom : message.frame.maxY + extra + footerSize.height + 16
        }
        scroll.contentSize = CGSize(width: bounds.width, height: max(bottom, y))
        if let position, rows.indices.contains(position.index) {
            scroll.contentOffset.y = min(max(0, rows[position.index].frame.minY - position.top), max(0, y - bottom))
        }
    }
}

@MainActor final class OnlineSearchRow: UIButton {
    private let artwork: EpisodeArtworkView
    private let title = UILabel(), author = UILabel()
    init(result: PodcastSearchResult) {
        artwork = EpisodeArtworkView(source: result.imageURL, fallback: nil, title: nil)
        super.init(frame: .zero)
        accessibilityLabel = [result.title, result.subtitle].compactMap { $0 }.joined(separator: ", ")
        title.text = result.title; title.font = Appearance.font(16); title.textColor = Appearance.foreground
        title.numberOfLines = 2; title.lineBreakMode = .byTruncatingTail
        author.text = result.subtitle; author.font = Appearance.font(14); author.textColor = Appearance.secondary
        author.numberOfLines = 2; author.lineBreakMode = .byTruncatingMiddle; author.isHidden = result.subtitle == nil
        artwork.backgroundColor = UIColor(white: 191.0 / 255, alpha: 1)
        artwork.layer.cornerRadius = 4; artwork.clipsToBounds = true
        [artwork, title, author].forEach { $0.isUserInteractionEnabled = false; addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }
    func refreshFonts(_ traits: UITraitCollection) {
        title.font = Appearance.font(16, compatibleWith: traits)
        author.font = Appearance.font(14, compatibleWith: traits)
        setNeedsLayout()
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = max(0, size.width - 104)
        let height = title.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            + (author.isHidden ? 0 : author.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        return CGSize(width: size.width, height: max(56, height) + 16)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        artwork.frame = CGRect(x: rtl ? max(0, bounds.width - 72) : 16, y: 8, width: 56, height: 56)
        let width = max(0, bounds.width - 104)
        let titleHeight = title.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let authorHeight = author.isHidden ? 0 : author.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let top = (bounds.height - titleHeight - authorHeight) / 2
        title.frame = CGRect(x: rtl ? 16 : 88, y: top, width: width, height: titleHeight)
        author.frame = CGRect(x: title.frame.minX, y: title.frame.maxY, width: width, height: authorHeight)
    }
}

@MainActor final class OnlineSearchAttribution: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 4, dy: 4)) }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let text = super.sizeThatFits(CGSize(width: max(0, size.width - 8), height: size.height))
        return CGSize(width: text.width + 8, height: text.height + 8)
    }
}
