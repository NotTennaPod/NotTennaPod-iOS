import UIKit
import NotTennaPodCore

/// A discarded controller discards its draft; the shared owner stores only OK.
@MainActor final class StatisticsFilterController: SourceMessageController {
    let body: StatisticsFilterBody
    private let preferences: StatisticsPreferenceStore
    init(preferences: StatisticsPreferenceStore, oldestMilliseconds: Int64,
         formatter: StatisticsTextFormatter, applied: @escaping () -> Void) throws {
        self.preferences = preferences
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = formatter.timeZone
        let options = try StatisticsPeriodOptions(oldestMilliseconds: oldestMilliseconds,
            nowMilliseconds: Int64(formatter.now.timeIntervalSince1970 * 1000),
            calendar: calendar, locale: formatter.locale)
        let body = StatisticsFilterBody(draft: .init(preferences: preferences.value, options: options))
        self.body = body
        super.init(title: Appearance.text("filter"), message: "",
            positive: .init(title: Appearance.text("ok"), identifier: "statisticsFilterOK", perform: { body.confirm?() }, dismisses: false), customBody: body)
        body.choose = { [weak self] from, anchor in
            guard let self else { return }
            let values = from ? self.body.draft.options.from : self.body.draft.options.to
            let selected = from ? self.body.draft.fromIndex : self.body.draft.toIndex
            present(StatisticsMonthController(anchor: anchor, values: values.map(StatisticsFilterBody.label), selected: selected) { [weak self] index in
                guard let self else { return }
                if from { self.body.draft.selectFrom(index) } else { self.body.draft.selectTo(index) }
                self.body.refresh()
            }, animated: false)
        }
        onApplied = applied
        body.confirm = { [weak self] in self?.confirm() }
    }
    private var committed = false
    private var onApplied: (() -> Void)?
    required init?(coder: NSCoder) { fatalError() }
    func confirm() {
        guard !committed, let value = body.draft.confirmedPreferences() else { return }
        do {
            try preferences.update(value)
            committed = true
            dismiss(animated: true, completion: onApplied)
        } catch {
            present(SourceMessageController(title: Appearance.text("error_label"), message: error.localizedDescription), animated: true)
        }
    }
}

@MainActor final class StatisticsFilterBody: UIView {
    var draft: StatisticsPeriodDraft
    var choose: ((Bool, UIButton) -> Void)?
    var confirm: (() -> Void)?
    private let check = StatisticsCheckbox()
    private let dates = UIView()
    private let from = Appearance.label(Appearance.text("statistics_from"), size: 14)
    private let to = Appearance.label(Appearance.text("statistics_to"), size: 14)
    private let fromButton = StatisticsMonthButton(type: .custom), toButton = StatisticsMonthButton(type: .custom)
    private let past = UIButton(type: .custom), all = UIButton(type: .custom)
    private let notice = Appearance.label(Appearance.text("statistics_speed_not_counted"), size: 14)
    init(draft: StatisticsPeriodDraft) {
        self.draft = draft; super.init(frame: .zero)
        accessibilityIdentifier = "statisticsFilterBody"
        [check, dates, notice].forEach(addSubview)
        [from, to, fromButton, toButton, past, all].forEach(dates.addSubview)
        check.setTitle(Appearance.text("statistics_include_marked"), for: .normal)
        check.titleLabel?.numberOfLines = 0; check.accessibilityIdentifier = "statisticsIncludeMarked"
        check.addAction(UIAction { [weak self] _ in
            guard let self else { return }; self.draft.includeMarkedAsPlayed.toggle(); refresh()
        }, for: .touchUpInside)
        for (button, id, isFrom) in [(fromButton, "statisticsFrom", true), (toButton, "statisticsTo", false)] {
            button.accessibilityIdentifier = id
            button.accessibilityLabel = Appearance.text(isFrom ? "statistics_from" : "statistics_to")
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let button else { return }; self?.choose?(isFrom, button)
            }, for: .touchUpInside)
        }
        for (button, key, id) in [(past, "statistics_filter_past_year", "statisticsPastYear"), (all, "statistics_filter_all_time", "statisticsAllTime")] {
            button.setTitle(Appearance.text(key), for: .normal); button.setTitleColor(Appearance.accent, for: .normal)
            button.titleLabel?.numberOfLines = 0; button.titleLabel?.textAlignment = .center
            button.accessibilityIdentifier = id; button.layer.cornerRadius = 4; button.layer.borderWidth = 1
            button.layer.borderColor = Appearance.secondary.cgColor
        }
        past.addAction(UIAction { [weak self] _ in self?.draft.selectPastYear(); self?.refresh() }, for: .touchUpInside)
        all.addAction(UIAction { [weak self] _ in self?.draft.selectAllTime(); self?.refresh() }, for: .touchUpInside)
        notice.numberOfLines = 0; notice.textColor = Appearance.secondary
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    static func label(_ option: StatisticsPeriodOption) -> String {
        switch option.label { case .month(let value): value; case .today: Appearance.text("statistics_today") }
    }
    func refresh() {
        check.checked = draft.includeMarkedAsPlayed
        dates.alpha = draft.datesEnabled ? 1 : 0.5
        [fromButton, toButton, past, all].forEach { $0.isEnabled = draft.datesEnabled }
        fromButton.setTitle(draft.fromIndex.map { Self.label(draft.options.from[$0]) } ?? "", for: .normal)
        toButton.setTitle(draft.toIndex.map { Self.label(draft.options.to[$0]) } ?? "", for: .normal)
        fromButton.accessibilityValue = fromButton.title(for: .normal); toButton.accessibilityValue = toButton.title(for: .normal)
        setNeedsLayout()
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize { .init(width: size.width, height: layout(width: size.width, apply: false)) }
    override func layoutSubviews() { super.layoutSubviews(); _ = layout(width: bounds.width, apply: true) }
    private func layout(width: CGFloat, apply: Bool) -> CGFloat {
        let inner = max(0, width - 32), half = inner / 2
        [check, fromButton, toButton].forEach { $0.titleLabel?.font = Appearance.font(16, compatibleWith: traitCollection) }
        [past, all].forEach { $0.titleLabel?.font = Appearance.font(14, medium: true, compatibleWith: traitCollection) }
        [from, to, notice].forEach { $0.font = Appearance.font(14, compatibleWith: traitCollection) }
        let checkHeight = max(48, (check.titleLabel?.sizeThatFits(.init(width: max(0, inner - 36), height: .greatestFiniteMagnitude)).height ?? 0) + 16)
        let labelHeight = max(from.font.lineHeight, to.font.lineHeight) + 8
        let spinnerHeight = max(48, (fromButton.titleLabel?.font.lineHeight ?? 0) + 16)
        let presetHeight = max(40, max(past.titleLabel?.sizeThatFits(.init(width: max(0, half - 24), height: .greatestFiniteMagnitude)).height ?? 0,
            all.titleLabel?.sizeThatFits(.init(width: max(0, half - 24), height: .greatestFiniteMagnitude)).height ?? 0) + 16)
        let dateHeight = labelHeight + spinnerHeight + presetHeight + 8
        let noticeHeight = notice.sizeThatFits(.init(width: inner, height: .greatestFiniteMagnitude)).height
        if apply {
            let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
            func column(_ second: Bool) -> CGFloat { second != rtl ? half : 0 }
            check.frame = .init(x: 16, y: 16, width: inner, height: checkHeight)
            dates.frame = .init(x: 16, y: check.frame.maxY + 8, width: inner, height: dateHeight)
            from.frame = .init(x: column(false) + 4, y: 0, width: max(0, half - 8), height: labelHeight)
            to.frame = .init(x: column(true) + 4, y: 0, width: max(0, half - 8), height: labelHeight)
            fromButton.frame = .init(x: column(false), y: labelHeight, width: half, height: spinnerHeight)
            toButton.frame = .init(x: column(true), y: labelHeight, width: half, height: spinnerHeight)
            past.frame = .init(x: column(false) + (rtl ? 4 : 0), y: labelHeight + spinnerHeight + 4, width: max(0, half - 4), height: presetHeight)
            all.frame = .init(x: column(true) + (rtl ? 0 : 4), y: past.frame.minY, width: max(0, half - 4), height: presetHeight)
            notice.frame = .init(x: 16, y: dates.frame.maxY + 16, width: inner, height: noticeHeight)
        }
        return 16 + checkHeight + 8 + dateHeight + 16 + noticeHeight + 16
    }
}

@MainActor private final class StatisticsMonthController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private weak var anchor: UIView?
    private let values: [String], selected: Int?
    private let choose: (Int) -> Void
    private let table = UITableView(frame: .zero, style: .plain)
    private let panel = UIView()
    init(anchor: UIView, values: [String], selected: Int?, choose: @escaping (Int) -> Void) {
        self.anchor = anchor; self.values = values; self.selected = selected; self.choose = choose
        super.init(nibName: nil, bundle: nil); modalPresentationStyle = .overFullScreen
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .clear; view.accessibilityViewIsModal = true
        view.semanticContentAttribute = anchor?.effectiveUserInterfaceLayoutDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        let outside = UIControl(); outside.frame = view.bounds; outside.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        outside.addAction(UIAction { [weak self] _ in self?.dismiss(animated: false) }, for: .touchUpInside); view.addSubview(outside)
        table.dataSource = self; table.delegate = self; table.separatorStyle = .none
        table.backgroundColor = Appearance.background; table.layer.cornerRadius = 2
        panel.layer.shadowOpacity = 0.2; panel.layer.shadowRadius = 6; panel.layer.shadowOffset = .init(width: 0, height: 2)
        panel.backgroundColor = Appearance.background; panel.layer.cornerRadius = 2
        view.addSubview(panel); panel.addSubview(table)
        table.accessibilityIdentifier = "statisticsMonthChoices"
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let anchor, anchor.window === view.window else { return }
        let rect = anchor.convert(anchor.bounds, to: view), safe = view.bounds.inset(by: view.safeAreaInsets)
        let below = max(0, safe.maxY - rect.minY - 8)
        let above = max(0, rect.maxY - safe.minY - 8)
        let contentHeight = CGFloat(values.count) * rowHeight
        let opensBelow = contentHeight <= below || below >= above
        let height = min(contentHeight, opensBelow ? below : above)
        let font = Appearance.font(16, compatibleWith: traitCollection)
        let textWidth = values.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let width = min(ceil(textWidth) + 32, safe.width)
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let x = rtl ? rect.maxX - width : rect.minX
        panel.frame = CGRect(x: min(max(x, safe.minX), safe.maxX - width),
            y: opensBelow ? rect.minY : rect.maxY - height, width: width, height: height)
        table.frame = panel.bounds
        if let selected, table.indexPathsForVisibleRows?.contains(IndexPath(row: selected, section: 0)) != true {
            table.scrollToRow(at: .init(row: selected, section: 0), at: .middle, animated: false)
        }
    }
    private var rowHeight: CGFloat { max(48, Appearance.font(16, compatibleWith: traitCollection).lineHeight + 16) }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { values.count }
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { rowHeight }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = values[indexPath.row]; cell.textLabel?.font = Appearance.font(16)
        cell.textLabel?.textColor = Appearance.foreground; cell.backgroundColor = Appearance.background
        cell.accessibilityIdentifier = "statisticsMonth-\(indexPath.row)"
        if indexPath.row == selected { cell.accessibilityTraits.insert(.selected) }
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        choose(indexPath.row); dismiss(animated: false)
    }
    override func accessibilityPerformEscape() -> Bool { dismiss(animated: false); return true }
}

@MainActor private final class StatisticsMonthButton: UIButton {
    override func titleRect(forContentRect rect: CGRect) -> CGRect {
        CGRect(x: effectiveUserInterfaceLayoutDirection == .rightToLeft ? 32 : 8, y: 0, width: max(0, rect.width - 40), height: rect.height)
    }
    override init(frame: CGRect) { super.init(frame: frame); contentHorizontalAlignment = .leading; setTitleColor(Appearance.foreground, for: .normal); contentMode = .redraw }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: CGRect) {
        super.draw(rect)
        let x: CGFloat = effectiveUserInterfaceLayoutDirection == .rightToLeft ? 16 : bounds.width - 16
        let path = UIBezierPath(); path.move(to: .init(x: x - 5, y: bounds.midY - 2.5)); path.addLine(to: .init(x: x + 5, y: bounds.midY - 2.5)); path.addLine(to: .init(x: x, y: bounds.midY + 2.5)); path.close()
        Appearance.secondary.setFill(); path.fill()
    }
}

@MainActor private final class StatisticsCheckbox: UIButton {
    var checked = false { didSet { accessibilityValue = checked ? Appearance.text("on") : Appearance.text("off"); accessibilityTraits = checked ? [.button, .selected] : .button; setNeedsDisplay() } }
    init() { super.init(frame: .zero); contentHorizontalAlignment = .leading; setTitleColor(Appearance.foreground, for: .normal); contentMode = .redraw }
    required init?(coder: NSCoder) { fatalError() }
    override func titleRect(forContentRect rect: CGRect) -> CGRect {
        .init(x: effectiveUserInterfaceLayoutDirection == .rightToLeft ? 0 : 36, y: 0, width: max(0, rect.width - 36), height: rect.height)
    }
    override func draw(_ rect: CGRect) {
        super.draw(rect)
        let x: CGFloat = effectiveUserInterfaceLayoutDirection == .rightToLeft ? bounds.width - 28 : 8
        let box = UIBezierPath(roundedRect: .init(x: x, y: bounds.midY - 9, width: 18, height: 18), cornerRadius: 1)
        (checked ? Appearance.accent : Appearance.secondary).setStroke(); box.lineWidth = 2; box.stroke()
        if checked {
            Appearance.accent.setFill(); box.fill(); UIColor.white.setStroke()
            let path = UIBezierPath(); path.move(to: .init(x: x + 3, y: bounds.midY)); path.addLine(to: .init(x: x + 7, y: bounds.midY + 4)); path.addLine(to: .init(x: x + 15, y: bounds.midY - 5)); path.lineWidth = 2; path.stroke()
        }
    }
}
