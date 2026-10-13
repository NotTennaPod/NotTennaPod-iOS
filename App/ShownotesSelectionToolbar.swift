import UIKit

/// A floating selection bar in the owning window. Hit testing passes through
/// everything except its controls, so WebKit continues to own range handles.
@MainActor final class ShownotesSelectionToolbar: UIView {
    struct Action {
        let id: String
        let title: String
        var requiresOverflow = false
        let perform: () -> Void
    }
    weak var source: ShownotesWebView?
    var fragments: [CGRect] = []
    private let panel = UIView()
    private let overflow = UIScrollView()
    private let more = UIButton(type: .system)
    private var buttons: [UIButton] = []
    private var actions: [Action] = []
    private var expanded = false
    private var displayLink: CADisplayLink?
    private let ticker = Ticker()

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        for view in [panel, overflow] {
            view.backgroundColor = Appearance.color(0xe3e2e9, 0x424242)
            view.layer.cornerRadius = 24
            view.layer.shadowColor = UIColor.black.cgColor
            view.layer.shadowOpacity = 0.18
            view.layer.shadowRadius = 3
            view.layer.shadowOffset = CGSize(width: 0, height: 2)
            addSubview(view)
        }
        panel.accessibilityIdentifier = "shownotesSelectionToolbar"
        overflow.accessibilityIdentifier = "shownotesSelectionOverflow"
        overflow.contentInsetAdjustmentBehavior = .never
        more.accessibilityIdentifier = "shownotesSelection-more"
        more.tintColor = Appearance.color(0x212121, 0xffffff)
        more.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            expanded.toggle(); setNeedsLayout()
        }, for: .touchUpInside)
        panel.addSubview(more)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: ShownotesSelectionToolbar, _) in view.setNeedsLayout() }
    }
    required init?(coder: NSCoder) { fatalError() }
    isolated deinit { displayLink?.invalidate() }

    func configure(_ actions: [Action]) {
        let unchanged = self.actions.map(\.id) == actions.map(\.id)
        self.actions = actions
        if unchanged {
            for (button, action) in zip(buttons, actions) { button.setTitle(action.title, for: .normal) }
            setNeedsLayout(); return
        }
        buttons.forEach { $0.removeFromSuperview() }
        buttons = actions.enumerated().map { index, action in
            let button = UIButton(type: .system)
            button.accessibilityIdentifier = "shownotesSelection-" + action.id
            button.setTitle(action.title, for: .normal)
            button.tintColor = Appearance.color(0x212121, 0xffffff)
            button.addAction(UIAction { [weak self] _ in self?.actions[index].perform() }, for: .touchUpInside)
            panel.addSubview(button)
            return button
        }
        expanded = false; setNeedsLayout()
    }
    func collapseOverflow() { expanded = false; setNeedsLayout() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate(); displayLink = nil
        if window != nil {
            ticker.owner = self
            let link = CADisplayLink(target: ticker, selector: #selector(Ticker.tick))
            link.add(to: .main, forMode: .common); displayLink = link
        }
    }
    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); setNeedsLayout() }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        (!panel.isHidden && panel.frame.contains(point)) || (!overflow.isHidden && overflow.frame.contains(point))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let source, source.window === window else { panel.isHidden = true; overflow.isHidden = true; return }
        var visible = source.bounds
        var ancestor: UIView? = source
        while let view = ancestor {
            if view.isHidden || view.alpha < 0.01 { visible = .null; break }
            if view.clipsToBounds { visible = visible.intersection(view.convert(view.bounds, to: source)) }
            ancestor = view.superview
        }
        visible = visible.intersection(convert(bounds, to: source))
        let ranges = fragments.map { $0.intersection(visible) }.filter { !$0.isNull && !$0.isEmpty }
        let safe = bounds.inset(by: safeAreaInsets).insetBy(dx: 16, dy: 8)
        guard let first = ranges.first, safe.width > 0, safe.height >= 48 else {
            panel.isHidden = true; overflow.isHidden = true; return
        }
        let anchor = source.convert(ranges.dropFirst().reduce(first) { $0.union($1) }, to: self)
        let font = Appearance.font(14, compatibleWith: traitCollection)
        let height = max(48, ceil(font.lineHeight) + 16)
        guard safe.height >= height else { panel.isHidden = true; overflow.isHidden = true; return }
        let widths = buttons.enumerated().map { index, button -> CGFloat in
            button.titleLabel?.font = font
            return max(48, ceil((button.title(for: .normal)! as NSString).size(withAttributes: [.font: font]).width) + (index == 0 ? 28 : 22))
        }
        let primaryCount = actions.firstIndex(where: \.requiresOverflow) ?? buttons.count
        var count = primaryCount
        var width = widths.prefix(count).reduce(0, +) + (count < buttons.count ? 48 : 0)
        if width > safe.width {
            count = 0; width = 48
            for item in widths.prefix(primaryCount) {
                guard width + item <= safe.width else { break }
                width += item; count += 1
            }
        }
        let hasOverflow = count < buttons.count
        width = min(width, safe.width)
        let x = min(max(safe.minX, anchor.midX - width / 2), safe.maxX - width)
        let above = anchor.minY - height - 8
        let y = above >= safe.minY ? above : min(safe.maxY - height, max(safe.minY, anchor.maxY + 8))
        panel.frame = CGRect(x: x, y: y, width: width, height: height)
        panel.isHidden = false
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        var edge: CGFloat = rtl ? width : 0
        for (index, button) in buttons.enumerated() {
            if index < count {
                if button.superview !== panel { panel.addSubview(button) }
                button.isHidden = expanded && hasOverflow
                button.contentHorizontalAlignment = .center
                button.frame = CGRect(x: rtl ? edge - widths[index] : edge, y: 0, width: widths[index], height: height)
                edge += rtl ? -widths[index] : widths[index]
            } else { button.isHidden = !(expanded && hasOverflow) }
        }
        more.isHidden = !hasOverflow
        more.accessibilityLabel = Appearance.text(expanded ? "shownotes_selection_close_overflow" : "floating_toolbar_open_overflow_description")
        more.setImage(UIImage(named: expanded ? "abc_ic_ab_back_material" : "dots_vertical"), for: .normal)
        more.frame = CGRect(x: rtl ? 0 : width - 48, y: 0, width: min(48, width), height: height)
        overflow.isHidden = !(expanded && hasOverflow)
        if expanded && hasOverflow {
            let remaining = Array(widths.dropFirst(count))
            let overflowWidth = min(safe.width, max(remaining.max() ?? 48, 48))
            let overflowHeight = CGFloat(remaining.count) * height
            let desiredX = rtl ? panel.frame.minX : panel.frame.maxX - overflowWidth
            let ox = min(max(safe.minX, desiredX), safe.maxX - overflowWidth)
            // Lay out the popup and its Close row as one bounded group. If a
            // short viewport cannot fit all rows, the remaining actions scroll.
            let popupHeight = min(overflowHeight, safe.height - height)
            let bottom = min(safe.maxY, max(panel.frame.maxY, safe.minY + popupHeight + height))
            panel.frame = CGRect(x: ox, y: bottom - height, width: overflowWidth, height: height)
            more.frame = CGRect(x: rtl ? overflowWidth - 48 : 0, y: 0, width: min(48, overflowWidth), height: height)
            overflow.frame = CGRect(x: ox, y: panel.frame.minY - popupHeight, width: overflowWidth, height: popupHeight)
            overflow.contentSize = CGSize(width: overflowWidth, height: overflowHeight)
            overflow.contentOffset.y = min(max(0, overflow.contentOffset.y), max(0, overflowHeight - popupHeight))
            for index in count..<buttons.count {
                let button = buttons[index]
                if button.superview !== overflow { overflow.addSubview(button) }
                button.contentHorizontalAlignment = .center
                button.frame = CGRect(x: 0, y: CGFloat(index - count) * height, width: overflowWidth, height: height)
            }
        }
    }
    @MainActor private final class Ticker: NSObject {
        weak var owner: ShownotesSelectionToolbar?
        @objc func tick() { owner?.setNeedsLayout() }
    }
}
