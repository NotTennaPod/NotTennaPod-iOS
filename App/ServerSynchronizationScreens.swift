import UIKit
import NotTennaPodCore

/// The Synchronization log and Needs attention screens of server mode (PROTOCOL §15.5), opened from their rows
/// on the Synchronization page and from settings search. Their views live across renders, so a reload keeps the list's
/// place.
@MainActor final class ServerSyncScreensState {
    fileprivate var log: ServerSyncLogView?
    fileprivate var attention: ServerAttentionView?
    fileprivate var logRead: Task<Void, Never>?
    fileprivate var attentionRead: Task<Void, Never>?
}

extension LibraryViewController {
    /// The open server library, while the page is in server mode.
    private var openServerLibrary: (accounts: ServerAccounts, library: ServerLibrarySummary)? {
        guard let presentation = synchronizationSettings, let accounts = presentation.server, let page = presentation.serverPage,
              page.mode == .server, let library = page.library else { return nil }
        return (accounts, library)
    }

    /// Whether the log or Needs attention is the screen shown (they follow the exchange as the page does).
    var serverSyncScreenVisible: Bool {
        switch path.last { case .settings(.synchronizationLog)?, .settings(.synchronizationAttention)?: true; default: false }
    }

    // MARK: - Synchronization log

    /// A list, newest first, with Share in the toolbar.
    func renderServerSyncLog() {
        let state = serverSyncScreens
        let list = state.log ?? ServerSyncLogView()
        state.log = list
        content.isScrollEnabled = false
        list.frame = content.bounds; list.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.addSubview(list)
        let layout = toolbarLayout(hasOverflow: false, hasPrimaryAction: true)
        toolbar.subviews.first { $0.accessibilityIdentifier == "screenTitle" }?.frame = layout.title
        let share = Appearance.icon("ic_share", label: Appearance.text("share_label")) { [weak self] in self?.shareServerSyncLog() }
        share.accessibilityIdentifier = "serverSyncLogShare"; share.frame = layout.primaryAction
        toolbar.addSubview(share)
        let url = openServerLibrary.flatMap { LibraryLocation(root: $0.accounts.root, reference: .server($0.library.entry.id)).syncDatabase }
        state.logRead?.cancel()
        state.logRead = Task { [weak list] in
            let entries = await Task.detached(priority: .userInitiated) { url.flatMap { try? ServerSyncLog.entries(syncDatabase: $0) } ?? [] }.value
            guard !Task.isCancelled else { return }
            list?.update(entries)
        }
    }

    /// The log as a text file, through the share sheet: a header naming the app, the server address and the library
    /// (never what a server answered, such as the account's name), then every entry.
    private func shareServerSyncLog() {
        guard presentedViewController == nil, let open = openServerLibrary,
              let url = LibraryLocation(root: open.accounts.root, reference: .server(open.library.entry.id)).syncDatabase else { return }
        let info = Bundle.main.infoDictionary
        let version = "NotTennaPod \(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
        let header = ServerSyncLog.shareHeader(title: Appearance.text("ntp_server_log_title"), app: version, library: open.library.entry,
                                               serverLine: Appearance.text("ntp_server_log_share_server"),
                                               libraryLine: Appearance.text("ntp_server_log_share_library"))
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.dateFormat = "yyyy-MM-dd"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nottennapod-sync-log-\(stamp.string(from: Date())).txt")
        Task { [weak self] in
            let entries = await Task.detached(priority: .userInitiated) { (try? ServerSyncLog.entries(syncDatabase: url)) ?? [] }.value
            var labels: [String: String] = [:]
            for kind in Set(entries.map(\.kind)) { labels[kind] = ServerSyncLogText.label(kind) }
            let text = ServerSyncLog.shareText(entries, header: header, label: { labels[$0] ?? $0 })
            do { try Data(text.utf8).write(to: file, options: [.atomic, .completeFileProtection]) }
            catch { self?.showError(error); return }
            guard let self, presentedViewController == nil, serverSyncScreenVisible else { return }
            let activity = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            activity.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: file) }
            if let popover = activity.popoverPresentationController {
                let anchor = toolbar.subviews.first { $0.accessibilityIdentifier == "serverSyncLogShare" } ?? toolbar
                popover.sourceView = anchor; popover.sourceRect = anchor.bounds
            }
            present(activity, animated: true)
        }
    }

    // MARK: - Needs attention

    func renderServerAttention() {
        let state = serverSyncScreens
        let list = state.attention ?? ServerAttentionView()
        state.attention = list
        list.onSubscribeAgain = { [weak self] url in self?.openFeedPage(url, manual: false) }
        list.onShowLog = { [weak self] in self?.openSettingsPage(.synchronizationLog) }
        list.onDismiss = { [weak self] item in self?.dismissServerAttention(item) }
        list.onResize = { [weak self, weak list] in
            guard let self, let list, list.superview === content else { return }
            layoutServerAttention(list)
        }
        content.addSubview(list)
        layoutServerAttention(list)
        reloadServerAttention()
    }

    private func layoutServerAttention(_ list: ServerAttentionView) {
        let height = list.sizeThatFits(CGSize(width: content.bounds.width, height: .greatestFiniteMagnitude)).height
        list.frame = CGRect(x: 0, y: 0, width: content.bounds.width, height: max(height, content.bounds.height))
        content.contentSize = CGSize(width: content.bounds.width, height: list.frame.height)
    }

    private func reloadServerAttention() {
        guard let library else { return }
        let state = serverSyncScreens
        state.attentionRead?.cancel()
        state.attentionRead = Task { [weak self] in
            do {
                let items = try await library.serverAttentionItems()
                guard !Task.isCancelled else { return }
                state.attention?.update(items)
                // The page's row counts what the list shows (it goes once nothing is left).
                if let accounts = self?.openServerLibrary?.accounts, accounts.exchange.attentionItems != items.count {
                    var signals = accounts.exchange
                    signals.attentionItems = items.count
                    accounts.update(signals: signals)
                }
            } catch is CancellationError {
            } catch { self?.showError(error) }
        }
    }

    private func dismissServerAttention(_ item: ServerAttentionItem) {
        guard let library else { return }
        Task { [weak self] in
            do { try await library.dismissServerAttention(item) } catch { self?.showError(error) }
            self?.reloadServerAttention()
        }
    }
}

/// The words of the log's entries: what happened, as a person reads it (the detail is the engine's own line).
@MainActor enum ServerSyncLogText {
    static func label(_ kind: String) -> String {
        let key = "ntp_server_log_kind_\(kind)"
        let text = Appearance.text(key)
        return text == key ? kind : text
    }

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yMMMdjms")
        return formatter
    }()
}

/// The Synchronization log: one row per entry, newest first (what happened, the detail, the time), or Android's empty
/// view of a log (`EmptyViewHandler`: icon, title and message).
@MainActor final class ServerSyncLogView: UIView, UITableViewDataSource {
    let table = UITableView(frame: .zero, style: .plain)
    private let empty = UIView()
    private let emptyIcon = UIImageView(image: UIImage(named: "ic_history"))
    private let emptyTitle = Appearance.label(Appearance.text("ntp_server_log_empty_head"), size: 16)
    private let emptyMessage = Appearance.label(Appearance.text("ntp_server_log_empty"), size: 14)
    private(set) var entries: [ServerSyncLogEntry] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        table.accessibilityIdentifier = "serverSyncLogList"
        table.backgroundColor = .clear; table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension; table.estimatedRowHeight = 72
        table.dataSource = self
        table.register(ServerSyncLogCell.self, forCellReuseIdentifier: "entry")
        empty.accessibilityIdentifier = "serverSyncLogEmpty"
        emptyIcon.tintColor = Appearance.foreground; emptyIcon.contentMode = .scaleAspectFit
        emptyTitle.textAlignment = .center; emptyMessage.textAlignment = .center; emptyMessage.textColor = Appearance.secondary
        [emptyIcon, emptyTitle, emptyMessage].forEach(empty.addSubview)
        addSubview(table); addSubview(empty)
        empty.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ entries: [ServerSyncLogEntry]) {
        self.entries = entries
        empty.isHidden = !entries.isEmpty
        table.isHidden = entries.isEmpty
        table.reloadData()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        table.frame = bounds
        empty.frame = bounds
        let width = max(0, bounds.width - 80)
        for label in [emptyTitle, emptyMessage] { label.font = Appearance.font(label === emptyTitle ? 16 : 14, compatibleWith: traitCollection) }
        let titleHeight = ceil(emptyTitle.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        let messageHeight = ceil(emptyMessage.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        let y = max(0, (bounds.height - 32 - 8 - titleHeight - messageHeight) / 2)
        emptyIcon.frame = CGRect(x: (bounds.width - 32) / 2, y: y, width: 32, height: 32)
        emptyTitle.frame = CGRect(x: 40, y: emptyIcon.frame.maxY + 8, width: width, height: titleHeight)
        emptyMessage.frame = CGRect(x: 40, y: emptyTitle.frame.maxY, width: width, height: messageHeight)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { entries.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "entry", for: indexPath)
        (cell as? ServerSyncLogCell)?.update(entries[indexPath.row])
        return cell
    }
}

/// One entry: what happened (16 pt), the detail and the time (14 pt, secondary), in the reading direction.
@MainActor final class ServerSyncLogCell: UITableViewCell {
    private let title = Appearance.label(nil, size: 16), detail = Appearance.label(nil, size: 14), time = Appearance.label(nil, size: 14)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        title.font = Appearance.font(16, medium: true)
        detail.textColor = Appearance.secondary; time.textColor = Appearance.secondary
        for label in [title, detail, time] { label.textAlignment = .natural; label.adjustsFontForContentSizeCategory = true }
        let stack = UIStackView(arrangedSubviews: [title, detail, time])
        stack.axis = .vertical; stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        contentView.preservesSuperviewLayoutMargins = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityIdentifier = "serverSyncLogRow"
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ entry: ServerSyncLogEntry) {
        title.text = ServerSyncLogText.label(entry.kind)
        detail.text = entry.detail
        time.text = ServerSyncLogText.time.string(from: entry.date)
        accessibilityLabel = title.text
        accessibilityValue = [entry.detail, time.text ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    override func layoutSubviews() {
        // Wide windows keep the page's 24-point margin (the Synchronization page's rows).
        let inset: CGFloat = bounds.width >= 600 ? 24 : 16
        if contentView.directionalLayoutMargins.leading != inset {
            contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: inset, bottom: 12, trailing: inset)
        }
        super.layoutSubviews()
    }
}

/// The words of a "Needs attention" item: its title and what happened (PROTOCOL §15.5).
@MainActor enum ServerAttentionText {
    static func words(_ kind: ServerAttentionItem.Kind) -> (title: String, summary: String) {
        switch kind {
        case .staleSubscription(let url, let title):
            return (title ?? url ?? "", Appearance.text("ntp_server_attention_stale_sum"))
        case .refusedURL(let url, let podcast, let owner):
            let title = podcast ?? Appearance.text("ntp_server_attention_url_title")
            if let owner { return (title, String(format: Appearance.text("ntp_server_attention_url_sum"), url ?? "", owner)) }
            return (title, String(format: Appearance.text("ntp_server_attention_url_other_sum"), url ?? ""))
        case .refusedChanges(let count):
            return (Appearance.text("ntp_server_attention_rejected_title"), Appearance.plural("ntp_server_attention_rejected_sum", count))
        case .incompleteRecovery(let problems):
            return (Appearance.text("ntp_server_attention_recovery_title"),
                    problems > 0 ? Appearance.plural("ntp_server_attention_recovery_sum", problems)
                        : Appearance.text("ntp_server_attention_recovery_unknown_sum"))
        }
    }
}

/// Needs attention: each item with its title, what happened and its actions ("Subscribe again" or "Synchronization log",
/// and "Dismiss", the confirming action trailing as in a dialog), or "Nothing needs attention". Laid out as the page's
/// own rows are: the page's insets, text in the reading direction, actions at the trailing edge (stacked when they do
/// not fit side by side).
@MainActor final class ServerAttentionView: UIView {
    var onSubscribeAgain: ((String) -> Void)?
    var onShowLog: (() -> Void)?
    var onDismiss: ((ServerAttentionItem) -> Void)?
    var onResize: (() -> Void)?
    private(set) var items: [ServerAttentionItem] = []
    private struct Row {
        let text: UIView
        let title: UILabel
        let summary: UILabel
        /// Dismiss first, then the confirming action.
        let actions: [UIButton]
    }
    private var rows: [Row] = []
    private let empty = Appearance.label(Appearance.text("ntp_server_attention_empty"), size: 16)
    private var loaded = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "serverAttention"
        empty.textAlignment = .center; empty.textColor = Appearance.secondary
        empty.accessibilityIdentifier = "serverAttentionEmpty"; empty.isHidden = true
        addSubview(empty)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ items: [ServerAttentionItem]) {
        guard !loaded || items != self.items else { return }
        loaded = true
        self.items = items
        for row in rows { row.text.removeFromSuperview(); row.actions.forEach { $0.removeFromSuperview() } }
        rows = items.map(row)
        empty.isHidden = !items.isEmpty
        setNeedsLayout()
        onResize?()
    }

    private func row(_ item: ServerAttentionItem) -> Row {
        let words = ServerAttentionText.words(item.kind)
        let text = UIView()
        let title = Appearance.label(words.title, size: 16), summary = Appearance.label(words.summary, size: 14)
        summary.textColor = Appearance.secondary
        // As the page's rows: the text's own direction decides its alignment.
        for label in [title, summary] { label.textAlignment = .natural }
        text.addSubview(title); text.addSubview(summary)
        text.isAccessibilityElement = true
        text.accessibilityIdentifier = "ntp_server_attention_item-\(item.identifier)"
        text.accessibilityLabel = words.title; text.accessibilityValue = words.summary
        text.accessibilityTraits = .staticText
        var actions = [button("dismiss_label", identifier: "serverAttentionDismiss-\(item.identifier)") { [weak self] in self?.onDismiss?(item) }]
        switch item.kind {
        case .staleSubscription(let url?, _):
            actions.append(button("ntp_server_attention_subscribe_again", identifier: "serverAttentionSubscribe-\(item.identifier)") { [weak self] in
                self?.onSubscribeAgain?(url)
            })
        case .refusedChanges, .incompleteRecovery:
            actions.append(button("ntp_server_log_title", identifier: "serverAttentionLog-\(item.identifier)") { [weak self] in self?.onShowLog?() })
        case .staleSubscription, .refusedURL:
            break
        }
        addSubview(text)
        actions.forEach(addSubview)
        return Row(text: text, title: title, summary: summary, actions: actions)
    }

    /// The dialogs' own text-button style (as the kept libraries' "Log in" and "Remove library").
    private func button(_ key: String, identifier: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = Appearance.text(key)
        configuration.baseForegroundColor = Appearance.accent
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        let button = UIButton(configuration: configuration)
        button.configurationUpdateHandler = { button in
            let font = Appearance.font(14, medium: true, compatibleWith: button.traitCollection)
            button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var result = attributes; result.font = font; return result
            }
        }
        button.accessibilityIdentifier = identifier
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: arrange(width: size.width, apply: false)) }

    override func layoutSubviews() {
        super.layoutSubviews()
        arrange(width: bounds.width, apply: true)
        empty.font = Appearance.font(16, compatibleWith: traitCollection)
        let emptyWidth = max(0, bounds.width - 80)
        let emptyHeight = ceil(empty.sizeThatFits(CGSize(width: emptyWidth, height: .greatestFiniteMagnitude)).height)
        empty.frame = CGRect(x: 40, y: max(0, (bounds.height - emptyHeight) / 2), width: emptyWidth, height: emptyHeight)
    }

    /// The items top to bottom; returns the height they need.
    @discardableResult private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let inset: CGFloat = width >= 600 ? 24 : 16
        let textWidth = max(1, width - inset * 2)
        var y: CGFloat = 0
        for row in rows {
            row.title.font = Appearance.font(16, medium: true, compatibleWith: traitCollection)
            row.summary.font = Appearance.font(14, compatibleWith: traitCollection)
            let titleHeight = ceil(row.title.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
            let summaryHeight = ceil(row.summary.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
            y += 16
            if apply {
                row.text.frame = CGRect(x: inset, y: y, width: textWidth, height: titleHeight + 2 + summaryHeight)
                row.title.frame = CGRect(x: 0, y: 0, width: textWidth, height: titleHeight)
                row.summary.frame = CGRect(x: 0, y: titleHeight + 2, width: textWidth, height: summaryHeight)
            }
            y += titleHeight + 2 + summaryHeight + 4
            // The actions from the trailing edge: the confirming one last, as in a dialog; one per line when they do
            // not fit side by side.
            let sizes = row.actions.map { button in
                let fitting = button.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
                return CGSize(width: min(textWidth, ceil(fitting.width)), height: max(48, ceil(fitting.height)))
            }
            let together = sizes.reduce(0) { $0 + $1.width } + CGFloat(max(0, sizes.count - 1)) * 8 <= textWidth
            var trailing = width - inset
            for (button, size) in zip(row.actions, sizes).reversed() {
                if !together { trailing = width - inset }
                if apply { button.frame = CGRect(x: rtl ? width - trailing : trailing - size.width, y: y, width: size.width, height: size.height) }
                trailing -= size.width + 8
                if !together { y += size.height }
            }
            if together { y += sizes.map(\.height).max() ?? 0 }
        }
        return rows.isEmpty ? 0 : ceil(y + 8)
    }
}
