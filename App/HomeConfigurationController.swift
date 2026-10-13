import UIKit
import NotTennaPodCore

/// Source `HomeSectionsSettingsDialog` / `ReorderDialog`: "Configure home screen" with a "Shown"
/// header, the visible sections, a "Hidden" header and the hidden sections. A section is hidden or shown
/// by dragging it across the "Hidden" header with its start-side handle; nothing moves above "Shown".
/// Reset (neutral), Cancel, OK.
@MainActor final class HomeConfigurationController: SourceMessageController {
    init(shown: [HomeSection], hidden: [HomeSection], onConfirm: @escaping ([HomeSection], [HomeSection]) -> Void, onReset: @escaping () -> Void) {
        let body = HomeConfigurationList(shown: shown, hidden: hidden)
        super.init(title: Appearance.text("configure_home"), message: "",
                   positive: .init(title: Appearance.text("ok"), identifier: "homeConfigureOK", perform: { onConfirm(body.shownSections, body.hiddenSections) }),
                   negative: .init(title: Appearance.text("cancel_label"), identifier: "homeConfigureCancel"),
                   neutral: .init(title: Appearance.text("reset"), identifier: "homeConfigureReset", perform: onReset),
                   customBody: body)
    }
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor final class HomeConfigurationList: UIView {
    private enum Entry: Hashable { case shownHeader, hiddenHeader, section(HomeSection) }
    private var entries: [Entry]
    private var rows: [Entry: UIView] = [:]
    private var dragging: HomeSection?
    private let rowHeight: CGFloat = 52, headerHeight: CGFloat = 48

    var shownSections: [HomeSection] { sections(before: true) }
    var hiddenSections: [HomeSection] { sections(before: false) }

    init(shown: [HomeSection], hidden: [HomeSection]) {
        entries = [.shownHeader] + shown.map(Entry.section) + [.hiddenHeader] + hidden.map(Entry.section)
        super.init(frame: .zero)
        accessibilityIdentifier = "homeConfigureList"
        for entry in entries { rows[entry] = makeRow(entry); addSubview(rows[entry]!) }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func sections(before: Bool) -> [HomeSection] {
        let split = entries.firstIndex(of: .hiddenHeader) ?? entries.count
        return (before ? entries[..<split] : entries[(split + 1)...]).compactMap { if case .section(let s) = $0 { s } else { nil } }
    }

    private func makeRow(_ entry: Entry) -> UIView {
        let row = UIView()
        switch entry {
        case .shownHeader, .hiddenHeader:
            // Source reorder_dialog_header: colorSurfaceVariant band with the category text.
            row.backgroundColor = Appearance.color(0xdce3e9, 0x40484c)
            let label = Appearance.label(Appearance.text(entry == .shownHeader ? "section_shown" : "section_hidden"), size: 16)
            label.textColor = Appearance.secondary; label.tag = 1
            label.accessibilityTraits.insert(.header)
            label.accessibilityIdentifier = entry == .shownHeader ? "homeConfigureShown" : "homeConfigureHidden"
            row.addSubview(label)
        case .section(let section):
            let handle = UIImageView(image: UIImage(named: "ic_drag_lighttheme")); handle.tintColor = Appearance.secondary
            handle.contentMode = .center; handle.isUserInteractionEnabled = true; handle.tag = 2
            handle.isAccessibilityElement = false
            let press = UILongPressGestureRecognizer(target: self, action: #selector(drag(_:))); press.minimumPressDuration = 0
            handle.addGestureRecognizer(press)
            let label = Appearance.label(Appearance.text(section.titleKey), size: 16); label.tag = 1
            [handle, label].forEach(row.addSubview)
            row.isAccessibilityElement = true
            row.accessibilityLabel = label.text
            row.accessibilityIdentifier = "homeConfigure-\(section.rawValue)"
            row.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: Appearance.text("home_configure_move_up")) { [weak self] _ in self?.move(section, by: -1) ?? false },
                UIAccessibilityCustomAction(name: Appearance.text("home_configure_move_down")) { [weak self] _ in self?.move(section, by: 1) ?? false },
            ]
        }
        let divider = UIView(); divider.backgroundColor = Appearance.color(0xc4c7c5, 0x444746); divider.tag = 3
        row.addSubview(divider)
        return row
    }

    /// Moving across the Hidden header hides/shows the section; index 0 (Shown header) is fixed.
    @discardableResult private func move(_ section: HomeSection, by offset: Int) -> Bool {
        guard let index = entries.firstIndex(of: .section(section)) else { return false }
        let target = index + offset
        guard target >= 1, target < entries.count else { return false }
        entries.swapAt(index, target)
        UIView.animate(withDuration: 0.15) { self.layoutRows() }
        updateAccessibilityValues()
        UIAccessibility.post(notification: .layoutChanged, argument: rows[.section(section)])
        return true
    }

    @objc private func drag(_ gesture: UILongPressGestureRecognizer) {
        guard let row = gesture.view?.superview, let entry = rows.first(where: { $0.value === row })?.key,
              case .section(let section) = entry, let scroll = superview as? UIScrollView ?? superview?.superview as? UIScrollView ?? nearestScroll() else { return }
        switch gesture.state {
        case .began:
            dragging = section; scroll.isScrollEnabled = false
            bringSubviewToFront(row); row.alpha = 0.9; row.backgroundColor = Appearance.selected
        case .changed:
            let y = gesture.location(in: self).y
            var target = 1
            var top: CGFloat = 0
            for (index, candidate) in entries.enumerated() {
                let height = height(of: candidate)
                if y >= top + height / 2 { target = index }
                top += height
            }
            target = max(1, min(entries.count - 1, target))
            if let index = entries.firstIndex(of: entry), index != target {
                entries.remove(at: index); entries.insert(entry, at: target)
                UIView.animate(withDuration: 0.12) { self.layoutRows(except: entry) }
            }
            row.center.y = max(height(of: .shownHeader) + rowHeight / 2, min(bounds.height - rowHeight / 2, y))
        default:
            dragging = nil; scroll.isScrollEnabled = true
            row.alpha = 1; row.backgroundColor = .clear
            UIView.animate(withDuration: 0.15) { self.layoutRows() }
            updateAccessibilityValues()
        }
    }

    private func nearestScroll() -> UIScrollView? {
        var view = superview
        while let current = view { if let scroll = current as? UIScrollView { return scroll }; view = current.superview }
        return nil
    }

    private func height(of entry: Entry) -> CGFloat { if case .section = entry { rowHeight } else { headerHeight } }
    private func updateAccessibilityValues() {
        for section in HomeSection.allCases {
            rows[.section(section)]?.accessibilityValue = Appearance.text(hiddenSections.contains(section) ? "section_hidden" : "section_shown")
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: entries.reduce(0) { $0 + height(of: $1) })
    }
    override func layoutSubviews() { super.layoutSubviews(); layoutRows(); updateAccessibilityValues() }

    private func layoutRows(except moving: Entry? = nil) {
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        var y: CGFloat = 0
        for entry in entries {
            let height = height(of: entry)
            guard let row = rows[entry] else { continue }
            if entry != moving { row.frame = CGRect(x: 0, y: y, width: bounds.width, height: height) }
            else { row.frame.size = CGSize(width: bounds.width, height: height) }
            for view in row.subviews {
                switch view.tag {
                case 1:
                    let x: CGFloat = { if case .section = entry { return 72 } else { return 24 } }()
                    view.frame = CGRect(x: rtl ? 0 : x, y: 0, width: max(0, bounds.width - x - 24), height: height)
                    if rtl { view.frame.origin.x = bounds.width - x - view.frame.width }
                    (view as? UILabel)?.textAlignment = .natural
                case 2: view.frame = CGRect(x: rtl ? bounds.width - 16 - 48 : 16, y: (height - 40) / 2, width: 48, height: 40)
                case 3: view.frame = CGRect(x: 0, y: height - 1, width: bounds.width, height: 1)
                default: break
                }
            }
            y += height
        }
    }
}
