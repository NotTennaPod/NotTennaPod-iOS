import UIKit
import NotTennaPodCore

/// DownloadLogFragment's bottom sheet, with history owned by the library rather
/// than by this screen's lifetime. Results can arrive while details are open.
@MainActor final class DownloadLogController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
    private let library: FeedLibraryStore
    private let retry: (DownloadLogEntry) async throws -> Void
    private let openFeed: (Int64) -> Void
    private let failed: (any Error) -> Void
    private let panel = UIView(), toolbar = UIView()
    private let heading = Appearance.label(Appearance.text("downloads_log_label"), size: 24)
    private let table = UITableView(frame: .zero, style: .plain)
    private let empty = UIView()
    private let emptyIcon = UIImageView(image: UIImage(named: "ic_download"))
    private let emptyTitle = Appearance.label(Appearance.text("no_log_downloads_head_label"), size: 16)
    private let emptyMessage = Appearance.label(Appearance.text("no_log_downloads_label"), size: 14)
    private lazy var clear = Appearance.icon("ic_delete", label: Appearance.text("clear_history_label")) { [weak self] in self?.clearHistory() }
    private var entries: [DownloadLogEntry] = []
    private var retried: Set<DownloadLogEntry.ID> = []
    private var changes: Task<Void, Never>?
    /// The log is read at most once a second while the sheet shows, never while it is hidden, and once after the last
    /// change (downloads and refreshes change it many times a second).
    private(set) lazy var logRefresh = PacedRefresh { [weak self] in await self?.readLog() }
    private var sheetHidden = false
    private var motion = DownloadLogSheetMotion()
    private var listOffset: CGFloat = -8
    private var adjustingList = false
    private var layingOut = false
    private lazy var panelPan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
    private var notice: UILabel?
    private var noticeTask: Task<Void, Never>?
    init(library: FeedLibraryStore, retry: @escaping (DownloadLogEntry) async throws -> Void,
         openFeed: @escaping (Int64) -> Void, failed: @escaping (any Error) -> Void) {
        self.library = library; self.retry = retry; self.openFeed = openFeed; self.failed = failed
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { changes?.cancel(); noticeTask?.cancel() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.32)
        view.clipsToBounds = true
        view.accessibilityViewIsModal = true
        panel.backgroundColor = Appearance.surfaceVariant
        panel.layer.cornerRadius = 28; panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        panel.clipsToBounds = true; panel.accessibilityIdentifier = "downloadLogSheet"
        view.addSubview(panel); panel.addSubview(toolbar); panel.addSubview(table); panel.addSubview(empty)
        toolbar.addSubview(heading); toolbar.addSubview(clear)
        clear.accessibilityIdentifier = "downloadLogClear"
        heading.accessibilityTraits.insert(.header)
        table.accessibilityIdentifier = "downloadLogList"
        table.backgroundColor = .clear; table.separatorStyle = .none
        table.contentInsetAdjustmentBehavior = .never
        table.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        table.dataSource = self; table.delegate = self
        table.register(DownloadLogCell.self, forCellReuseIdentifier: "log")
        [emptyIcon, emptyTitle, emptyMessage].forEach(empty.addSubview)
        empty.accessibilityIdentifier = "downloadLogEmpty"
        emptyIcon.tintColor = Appearance.foreground; emptyIcon.contentMode = .scaleAspectFit
        emptyTitle.textAlignment = .center; emptyMessage.textAlignment = .center; emptyMessage.textColor = Appearance.secondary
        let outside = UITapGestureRecognizer(target: self, action: #selector(outsideTap(_:)))
        outside.cancelsTouchesInView = false; view.addGestureRecognizer(outside)
        panelPan.delegate = self; panel.addGestureRecognizer(panelPan)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: DownloadLogController, _) in
            controller.table.reloadData(); controller.view.setNeedsLayout()
        }
        logRefresh.isActive = { [weak self] in
            guard let self else { return false }
            return !sheetHidden && UIApplication.shared.applicationState != .background
        }
        NotificationCenter.default.addObserver(self, selector: #selector(sceneReturned), name: UIApplication.didBecomeActiveNotification, object: nil)
        changes = Task { [weak self, library] in
            for await _ in await library.downloadLogChanges() {
                guard !Task.isCancelled, let self else { return }
                logRefresh.changed()
            }
        }
    }

    private func readLog() async {
        do {
            let entries = try await library.downloadLog()
            self.entries = entries
            // Source adapter's view is rebound whenever the history reloads.
            retried = []
            table.reloadData(); view.setNeedsLayout()
        } catch { failed(error) }
    }

    @objc private func sceneReturned() { logRefresh.activate() }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sheetHidden = false
        logRefresh.activate()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        sheetHidden = true
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layingOut = true
        defer { layingOut = false }
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let width = min(640, safe.width)
        let desired = max(300, 64 + 16 + entries.reduce(CGFloat(0)) { $0 + DownloadLogCell.height($1, width: width, traits: traitCollection) })
        let available = view.bounds.height
        let height = min(available, desired + view.safeAreaInsets.bottom)
        let peek = max(56, available - width * 9 / 16) + view.safeAreaInsets.bottom
        motion.resize(height: height, visible: min(height, peek))
        // The source sheet retains its full list viewport below the window while
        // collapsed. Clipping belongs to the containing view, not to a new row size.
        panel.frame = CGRect(x: safe.midX - width / 2, y: view.bounds.maxY - height + motion.offset, width: width, height: height)
        let topInset = max(0, safe.minY - panel.frame.minY)
        panel.layer.cornerRadius = panel.frame.minY <= view.bounds.minY ? 0 : 28
        toolbar.frame = CGRect(x: 0, y: topInset, width: width, height: 64)
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        clear.frame = CGRect(x: rtl ? 0 : width - 48, y: 8, width: 48, height: 48)
        heading.frame = CGRect(x: rtl ? 56 : 16, y: 0, width: max(0, width - 72), height: 64)
        heading.textAlignment = rtl ? .right : .left
        table.frame = CGRect(x: 0, y: toolbar.frame.maxY, width: width, height: max(0, height - toolbar.frame.maxY - view.safeAreaInsets.bottom))
        empty.frame = CGRect(x: 0, y: 0, width: width, height: max(0, height - view.safeAreaInsets.bottom))
        // The original empty view is centered in the sheet's whole content,
        // including the toolbar, with 40-point horizontal padding and no gaps.
        empty.isUserInteractionEnabled = false
        let textWidth = max(0, width - 80)
        let titleHeight = emptyTitle.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height + 3 * emptyTitle.font.pointSize / 16
        let messageHeight = emptyMessage.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height + 3 * emptyMessage.font.pointSize / 14
        let total = 32 + titleHeight + messageHeight
        let top = max(0, (empty.bounds.height - total) / 2)
        emptyIcon.frame = CGRect(x: (width - 32) / 2, y: top, width: 32, height: 32)
        emptyTitle.frame = CGRect(x: 40, y: top + 32, width: textWidth, height: titleHeight)
        emptyMessage.frame = CGRect(x: 40, y: emptyTitle.frame.maxY, width: textWidth, height: messageHeight)
        empty.isHidden = !entries.isEmpty; table.isHidden = entries.isEmpty
        if let notice {
            let w = max(0, width - 48)
            let h = notice.sizeThatFits(CGSize(width: max(1, w - 32), height: .greatestFiniteMagnitude)).height + 24
            notice.frame = CGRect(x: safe.midX - w / 2, y: safe.maxY - h - 24, width: w, height: h)
        }
    }
    @objc private func outsideTap(_ gesture: UITapGestureRecognizer) {
        if !panel.frame.contains(gesture.location(in: view)) { dismiss(animated: true) }
    }
    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        let dy = gesture.translation(in: view).y
        switch gesture.state {
        case .began: motion.begin(); gesture.setTranslation(.zero, in: view)
        case .changed:
            motion.move(by: dy); gesture.setTranslation(.zero, in: view)
            view.setNeedsLayout(); view.layoutIfNeeded()
        case .ended, .cancelled:
            settle(velocity: gesture.velocity(in: view), nested: false, cancelled: gesture.state == .cancelled)
        default: break
        }
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panelPan else { return true }
        let point = gestureRecognizer.location(in: panel)
        // The table's native pan owns list touches, including deceleration and
        // accessibility scrolling. Its delegate hands only sheet movement over.
        return table.isHidden || !table.frame.contains(point)
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        motion.begin(); listOffset = scrollView.contentOffset.y
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !adjustingList else { return }
        defer { listOffset = scrollView.contentOffset.y }
        guard !layingOut, scrollView.isDragging, motion.isDragging else { return }
        let top = -scrollView.adjustedContentInset.top
        let delta = scrollView.contentOffset.y - listOffset
        var corrected = scrollView.contentOffset.y
        if delta > 0, motion.offset > 0 {
            corrected += motion.move(by: -delta)
        } else if delta < 0, corrected < top {
            motion.move(by: top - corrected); corrected = top
        }
        adjustingList = true
        scrollView.contentOffset.y = corrected
        view.setNeedsLayout(); view.layoutIfNeeded()
        adjustingList = false
    }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                  targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        if motion.moved || motion.offset > 0 {
            if motion.offset > 0 { targetContentOffset.pointee = scrollView.contentOffset }
            settle(velocity: scrollView.panGestureRecognizer.velocity(in: view), nested: true)
        } else { _ = motion.finish(velocity: 0, nested: true) }
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if motion.isDragging { settle(velocity: .zero, nested: true, cancelled: true) }
    }
    private func settle(velocity: CGPoint, nested: Bool, cancelled: Bool = false) {
        let stop = motion.finish(velocity: velocity.y, horizontalVelocity: velocity.x, nested: nested, cancelled: cancelled)
        view.setNeedsLayout()
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
            self.view.layoutIfNeeded()
        } completion: { [weak self] _ in
            guard let self else { return }
            if stop == .hidden, motion.stop == .hidden, !motion.isDragging { dismiss(animated: false) }
        }
    }
    override func accessibilityPerformEscape() -> Bool { dismiss(animated: true); return true }
    override var keyCommands: [UIKeyCommand]? { [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close))] }
    @objc private func close() { dismiss(animated: true) }
    private func clearHistory() {
        Task { [library, failed] in do { try await library.clearDownloadLog() } catch { failed(error) } }
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { entries.count }
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        DownloadLogCell.height(entries[indexPath.row], width: tableView.bounds.width, traits: traitCollection)
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "log", for: indexPath) as! DownloadLogCell
        let entry = entries[indexPath.row]
        cell.update(entry, retryVisible: entry.canRetry(in: entries) && !retried.contains(entry.id)) { [weak self, weak cell] in
            guard let self else { return }
            retried.insert(entry.id); cell?.hideRetry()
            Task { [weak self, retry, failed] in
                do {
                    try await retry(entry)
                    if entry.episodeID != nil { self?.showDownloadNotice() }
                } catch { failed(error) }
            }
        }
        return cell
    }
    private func showDownloadNotice() {
        noticeTask?.cancel(); notice?.removeFromSuperview()
        let label = Appearance.label(Appearance.text("status_downloading_label"), size: 14)
        label.textAlignment = .center; label.backgroundColor = Appearance.navigation
        label.layer.cornerRadius = 20; label.clipsToBounds = true
        label.accessibilityIdentifier = "applicationNotice"
        view.addSubview(label); notice = label; view.setNeedsLayout()
        UIAccessibility.post(notification: .announcement, argument: label.text)
        noticeTask = Task { [weak self, weak label] in
            do { try await Task.sleep(for: .milliseconds(3500)) } catch { return }
            label?.removeFromSuperview(); self?.notice = nil
        }
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        let entry = entries[indexPath.row]
        Task { [weak self, library] in
            do {
                let feed = try await library.listedFeedHeader(id: entry.feedID)
                let episode: LibraryEpisode?
                if let id = entry.episodeID { episode = try await library.episode(id: id) } else { episode = nil }
                let details = FeedLogDetails(entry: entry, feed: feed, episode: episode, text: Appearance.text)
                guard let self else { return }
                let dialog = FeedLogDetailsDialog.make(details, open: { [weak self] in
                    guard let self, let id = details.feedID else { return }
                    dismiss(animated: true) { [openFeed] in openFeed(id) }
                })
                present(dialog, animated: true)
            } catch { self?.failed(error) }
        }
    }
}

@MainActor private final class DownloadLogCell: UITableViewCell {
    private let icon = UIImageView(), title = Appearance.label(nil, size: 16)
    private let status = Appearance.label(nil, size: 14), reason = Appearance.label(nil, size: 14)
    private let hint = Appearance.label(Appearance.text("download_error_tap_for_details"), size: 14)
    private let retryButton = Appearance.icon("ic_refresh", label: Appearance.text("refresh_label")) {}
    private let retryRing = DownloadRingView()
    private var entry: DownloadLogEntry?
    private var retry: (() -> Void)?
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        [icon, title, status, reason, hint, retryButton].forEach(contentView.addSubview)
        retryRing.isUserInteractionEnabled = false; retryRing.accessibilityIdentifier = "downloadLogRetryRing"
        retryRing.update(0, indeterminate: false); retryButton.addSubview(retryRing)
        icon.accessibilityIdentifier = "downloadLogIcon"
        title.accessibilityIdentifier = "downloadLogTitle"; status.accessibilityIdentifier = "downloadLogStatus"
        reason.accessibilityIdentifier = "downloadLogReason"; hint.accessibilityIdentifier = "downloadLogHint"
        title.numberOfLines = 1; title.lineBreakMode = .byTruncatingTail
        status.textColor = Appearance.secondary; status.numberOfLines = 1; status.lineBreakMode = .byTruncatingTail
        hint.textColor = Appearance.secondary
        reason.textColor = Appearance.color(0xcf1800, 0xcf1800)
        retryButton.addAction(UIAction { [weak self] _ in self?.retry?() }, for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ entry: DownloadLogEntry, retryVisible: Bool, retry: @escaping () -> Void) {
        self.entry = entry; self.retry = retry
        title.text = entry.title ?? Appearance.text("download_log_title_unknown")
        let relative = RelativeDateTimeFormatter(); relative.unitsStyle = .full
        let elapsed = Date().timeIntervalSince(entry.date)
        let time: String
        if elapsed >= 0 && elapsed < 60 { time = Appearance.text("download_log_zero_minutes") }
        else if abs(elapsed) < 3600 { time = relative.localizedString(from: DateComponents(minute: -Int(elapsed / 60))) }
        else if abs(elapsed) < 86400 { time = relative.localizedString(from: DateComponents(hour: -Int(elapsed / 3600))) }
        else if abs(elapsed) < 604800 { time = relative.localizedString(from: DateComponents(day: -Int(elapsed / 86400))) }
        else { let formatter = DateFormatter(); formatter.setLocalizedDateFormatFromTemplate("MMMdyyyy"); time = formatter.string(from: entry.date) }
        status.text = (entry.typeLabelKey.map(Appearance.text) ?? "") + " · " + time
        reason.text = Appearance.text(entry.statusKey)
        reason.isHidden = entry.isSuccessful; hint.isHidden = entry.isSuccessful
        icon.image = UIImage(named: entry.isSuccessful ? "ic_check" : entry.isInformational ? "ic_info" : "ic_error")
        icon.tintColor = Appearance.foreground
        retryButton.isHidden = !retryVisible
        retryButton.accessibilityIdentifier = "downloadLogRetry-\(entry.isMedia ? "media" : "feed")-\(entry.episodeID ?? entry.feedID)"
        accessibilityIdentifier = "downloadLogRow"
        setNeedsLayout()
    }
    func hideRetry() { retryButton.isHidden = true }
    static func height(_ entry: DownloadLogEntry, width: CGFloat, traits: UITraitCollection) -> CGFloat {
        let main = Appearance.font(16, compatibleWith: traits).lineHeight + 3 * Appearance.font(16, compatibleWith: traits).pointSize / 16
        let small = Appearance.font(14, compatibleWith: traits)
        let textWidth = max(1, width - 84)
        let reason = (Appearance.text(entry.statusKey) as NSString).boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: small], context: nil).height
        return max(48, 22 + ceil(main) + ceil(small.lineHeight + 3 * small.pointSize / 14) + (entry.isSuccessful ? 0 : ceil(reason + 3 * small.pointSize / 14) + ceil(small.lineHeight + 3 * small.pointSize / 14)))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let entry else { return }
        let width = contentView.bounds.width, textWidth = max(0, width - 84)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rtl ? width - x - w : x, y: y, width: w, height: h)
        }
        title.font = Appearance.font(16, compatibleWith: traitCollection)
        [status, reason, hint].forEach { $0.font = Appearance.font(14, compatibleWith: traitCollection) }
        let main = ceil(title.font.lineHeight + 3 * title.font.pointSize / 16), small = ceil(status.font.lineHeight + 3 * status.font.pointSize / 14)
        icon.frame = frame(16, 11 + (main - 16) / 2, 16, 16)
        title.frame = frame(36, 11, max(0, textWidth - 20), main)
        status.frame = frame(16, title.frame.maxY, textWidth, small)
        let reasonHeight = entry.isSuccessful ? 0 : ceil(reason.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height + 3 * reason.font.pointSize / 14)
        reason.frame = frame(16, status.frame.maxY, textWidth, reasonHeight)
        hint.frame = frame(16, reason.frame.maxY, textWidth, small)
        retryButton.frame = frame(width - 60, (bounds.height - 48) / 2, 48, 48)
        retryRing.frame = CGRect(x: 4, y: 4, width: 40, height: 40)
    }
}
