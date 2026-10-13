import UIKit

/// Classic AndroidX chooser composition, independently sized from the app's
/// Material message dialogs. Selection/session ownership stays in the model.
@MainActor final class CastDeviceChooserController: UIViewController {
    let chooser: CastDeviceChooser
    private let shadow = UIView(), panel = UIView(), content = UIScrollView(), list = UIScrollView()
    private let heading = Appearance.label(nil, size: 20)
    private let searching = Appearance.label(Appearance.text("mr_chooser_looking_for_devices"), size: 14)
    private let hint = Appearance.label(nil, size: 14)
    private let wifi = UIImageView(image: UIImage(named: "cast_wifi"))
    private let learn = UIButton(type: .custom), ok = UIButton(type: .custom)
    private let progress = CastChooserProgress()
    private var rows: [String: CastChooserRow] = [:]
    private var closing = false
    private let openHelp: (URL) -> Void
    // This controls the device noun only, never geometry. A foldable remains a
    // phone when unfolded; a narrow iPad window remains a tablet.
    private let tabletDescription: Bool

    init(chooser: CastDeviceChooser, tabletDescription: Bool, openHelp: @escaping (URL) -> Void) {
        self.chooser = chooser; self.tabletDescription = tabletDescription; self.openHelp = openHelp
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.32)
        view.accessibilityViewIsModal = true
        panel.backgroundColor = Appearance.color(0xfafafa, 0x424242)
        panel.layer.cornerRadius = 2; panel.clipsToBounds = true
        panel.accessibilityIdentifier = "castChooserPanel"
        shadow.layer.shadowColor = UIColor.black.cgColor
        shadow.layer.shadowOpacity = 0.24; shadow.layer.shadowRadius = 16
        shadow.layer.shadowOffset = CGSize(width: 0, height: 14)
        view.addSubview(shadow); view.addSubview(panel); panel.addSubview(content)
        // The dialog already consumes this controller's physical safe area.
        // Automatic insets would count those edges twice inside its scroll views.
        content.contentInsetAdjustmentBehavior = .never
        list.contentInsetAdjustmentBehavior = .never
        content.accessibilityIdentifier = "castChooserContent"
        list.accessibilityIdentifier = "castChooserDevices"
        for child in [heading, searching, hint, wifi, learn, ok, progress, list] { content.addSubview(child) }
        heading.accessibilityIdentifier = "castChooserTitle"; heading.accessibilityTraits.insert(.header)
        heading.numberOfLines = 1; heading.lineBreakMode = .byTruncatingTail
        searching.accessibilityIdentifier = "castChooserSearching"
        hint.accessibilityIdentifier = "castChooserHint"
        hint.text = Appearance.text(tabletDescription ? "mr_chooser_wifi_warning_description_tablet" : "mr_chooser_wifi_warning_description_phone")
        wifi.tintColor = Appearance.foreground
        wifi.isAccessibilityElement = true; wifi.accessibilityLabel = Appearance.text("ic_media_route_learn_more_accessibility")
        wifi.accessibilityIdentifier = "castChooserWiFi"
        learn.accessibilityIdentifier = "castChooserHelp"; learn.accessibilityTraits = .link
        learn.contentHorizontalAlignment = .leading
        learn.titleLabel?.numberOfLines = 0; learn.titleLabel?.lineBreakMode = .byWordWrapping
        learn.addAction(UIAction { [weak self] _ in
            guard let self, !closing else { return }
            openHelp(URL(string: "https://support.google.com/chromecast/?p=trouble-finding-devices")!)
        }, for: .touchUpInside)
        ok.setTitle(Appearance.text("ok"), for: .normal)
        // Captured reference renders white on #fafafa (contrast1.04:1). Keep
        // the action and composition while preventing that visibility defect.
        ok.setTitleColor(Appearance.color(0x0078c2, 0xffffff), for: .normal)
        ok.accessibilityIdentifier = "castChooserOK"
        ok.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
        for label in [heading, searching, hint] {
            label.adjustsFontForContentSizeCategory = false
            label.textColor = Appearance.color(0x212121, 0xffffff)
        }
        for consumer in [heading, searching, hint, learn.titleLabel!, ok.titleLabel!] {
            consumer.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: UILabel, _) in
                self?.view.setNeedsLayout()
            }
        }
        view.registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitLayoutDirection.self]) { [weak self] (_: UIView, _) in
            self?.view.setNeedsLayout()
        }
        let outside = UITapGestureRecognizer(target: self, action: #selector(outside(_:)))
        outside.cancelsTouchesInView = false; view.addGestureRecognizer(outside)
        chooser.onChange = { [weak self] in self?.render() }
        chooser.onSelected = { [weak self] in self?.close() }
        render()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !closing { chooser.start() }
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); chooser.stop() }
    override func viewSafeAreaInsetsDidChange() { super.viewSafeAreaInsetsDidChange(); view.setNeedsLayout() }
    private func render() {
        heading.text = Appearance.text(chooser.phase == .noDevices ? "mr_chooser_zero_routes_found_title" : "mr_chooser_title")
        searching.isHidden = chooser.phase != .searching
        hint.isHidden = chooser.phase != .wifiHint && chooser.phase != .noDevices
        wifi.isHidden = hint.isHidden
        learn.isHidden = chooser.phase != .noDevices
        ok.isHidden = chooser.phase != .noDevices
        progress.isHidden = chooser.phase != .searching && chooser.phase != .wifiHint
        list.isHidden = chooser.phase != .routes
        let ids = Set(chooser.devices.map(\.id))
        for id in Array(rows.keys) where !ids.contains(id) { rows.removeValue(forKey: id)?.removeFromSuperview() }
        for device in chooser.devices {
            let row: CastChooserRow
            if let existing = rows[device.id] { row = existing }
            else {
                row = CastChooserRow()
                row.onMetricsChanged = { [weak self] in self?.view.setNeedsLayout() }
                row.addAction(UIAction { [weak self] _ in self?.chooser.select(id: device.id) }, for: .touchUpInside)
                rows[device.id] = row; list.addSubview(row)
            }
            row.configure(device, selecting: chooser.selecting.contains(device.id))
        }
        // UIKit traversal follows the sorted route order even after a rename.
        list.accessibilityElements = chooser.devices.compactMap { rows[$0.id] }
        view.setNeedsLayout()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        guard safe.size.width > 48, safe.size.height > 48 else { panel.isHidden = true; shadow.isHidden = true; return }
        panel.isHidden = false; shadow.isHidden = false
        let size = view.bounds.size
        let short = min(size.width, size.height), portrait = size.width < size.height
        let desired: CGFloat = short >= 720 ? size.width * (portrait ? 0.7 : 0.5)
            : short >= 600 ? size.width * (portrait ? 0.9 : 0.6) : 320
        let panelWidth = min(desired, safe.size.width - 48)
        // At an exceptionally narrow extent retain a readable hint column and
        // expose the whole composition through horizontal scrolling.
        let width = max(192, panelWidth), inner = width - 48
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        func frame(_ leading: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rtl ? width - leading - w : leading, y: y, width: w, height: h)
        }
        for (label, size) in [(heading, CGFloat(20)), (searching, 14), (hint, 14)] {
            label.font = Appearance.font(size, medium: label === heading, compatibleWith: label.traitCollection)
            label.textAlignment = rtl ? .right : .left
        }
        let helpFont = Appearance.font(14, compatibleWith: learn.titleLabel?.traitCollection)
        learn.setAttributedTitle(NSAttributedString(string: Appearance.text("mr_chooser_wifi_learn_more"), attributes: [
            .font: helpFont, .foregroundColor: Appearance.accent, .underlineStyle: NSUnderlineStyle.single.rawValue
        ]), for: .normal)
        learn.contentHorizontalAlignment = rtl ? .right : .left
        ok.titleLabel?.font = Appearance.font(14, medium: true, compatibleWith: ok.titleLabel?.traitCollection)
        let titleHeight = ceil(max(27, heading.font.lineHeight + 3))
        heading.frame = frame(24, 24, inner, titleHeight)
        var y = 24 + titleHeight + 12
        if chooser.phase == .routes {
            var rowY: CGFloat = 0
            for device in chooser.devices {
                guard let row = rows[device.id] else { continue }
                row.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                let h = row.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
                row.frame = CGRect(x: 0, y: rowY, width: inner, height: h); rowY += h
            }
            let available = safe.height - 48 - y - 24
            // Keep the title anchored while the list scrolls. At an extremely
            // short extent the complete composition scrolls to retain access.
            let height = min(rowY, max(min(rowY, 57), available))
            configure(list, frame: frame(24, y, inner, height), height: rowY)
            y += height
        } else if chooser.phase == .searching {
            let h = ceil(max(20, searching.font.lineHeight + 3))
            searching.frame = frame(24, y, inner, h); y += h
        } else {
            let descriptionWidth = max(0, inner - 80)
            let h = ceil(hint.sizeThatFits(CGSize(width: descriptionWidth, height: .greatestFiniteMagnitude)).height + 2)
            hint.frame = frame(104, y, descriptionWidth, h)
            wifi.frame = frame(40, y + 16, 24, 24)
            let linkTextHeight = learn.titleLabel?.sizeThatFits(CGSize(width: descriptionWidth, height: .greatestFiniteMagnitude)).height ?? helpFont.lineHeight
            let linkHeight = ceil(max(20, linkTextHeight + 3))
            learn.frame = frame(104, y + h + 8, descriptionWidth, linkHeight)
            y += max(56, h + 8 + linkHeight) // INVISIBLE link retains its slot during the hint.
            if chooser.phase == .noDevices {
                let h = max(48, ceil((ok.titleLabel?.font.lineHeight ?? 0) + 20))
                let w = min(inner, max(66, (ok.titleLabel?.intrinsicContentSize.width ?? 0) + 40))
                ok.frame = frame(width - 24 - w, y, w, h); y += h
            }
        }
        if !progress.isHidden {
            progress.frame = frame(24, y + 4, inner, 16); y += 20
        }
        y += 24
        let height = min(y, safe.height - 48)
        panel.frame = CGRect(x: safe.midX - panelWidth / 2, y: safe.midY - height / 2, width: panelWidth, height: height)
        shadow.frame = panel.frame
        shadow.layer.shadowPath = UIBezierPath(roundedRect: shadow.bounds, cornerRadius: 2).cgPath
        configure(content, frame: CGRect(origin: .zero, size: panel.bounds.size), height: y, contentWidth: width)
    }
    private func configure(_ scroll: UIScrollView, frame: CGRect, height: CGFloat, contentWidth: CGFloat? = nil) {
        let old = scroll.contentOffset
        scroll.frame = frame; scroll.contentSize = CGSize(width: contentWidth ?? frame.width, height: height)
        scroll.isScrollEnabled = height > frame.height || scroll.contentSize.width > frame.width
        let offset = CGPoint(x: min(max(0, old.x), max(0, scroll.contentSize.width - frame.width)), y: min(max(0, old.y), max(0, height - frame.height)))
        if offset != old { scroll.contentOffset = offset }
    }
    @objc private func outside(_ gesture: UITapGestureRecognizer) {
        if !panel.frame.contains(gesture.location(in: view)) { close() }
    }
    private func close() {
        guard !closing else { return }
        closing = true; chooser.stop(); dismiss(animated: true)
    }
    override func accessibilityPerformEscape() -> Bool { close(); return true }
}

@MainActor private final class CastChooserRow: UIControl {
    var onMetricsChanged: (() -> Void)?
    private let icon = UIImageView(), spinner = UIActivityIndicatorView(style: .medium)
    private let name = Appearance.label(nil, size: 16), detail = Appearance.label(nil, size: 14)
    override init(frame: CGRect) {
        super.init(frame: frame)
        for child in [icon, spinner, name, detail] { addSubview(child) }
        name.numberOfLines = 1; detail.numberOfLines = 1
        name.adjustsFontForContentSizeCategory = false; detail.adjustsFontForContentSizeCategory = false
        name.textColor = Appearance.color(0x212121, 0xffffff)
        detail.textColor = Appearance.color(0x757575, 0xb3b3b3)
        icon.tintColor = Appearance.foreground
        spinner.color = Appearance.accent
        isAccessibilityElement = true; accessibilityTraits = .button
        name.accessibilityIdentifier = "castDeviceName"; detail.accessibilityIdentifier = "castDeviceDescription"
        for label in [name, detail] {
            label.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: UILabel, _) in
                self?.onMetricsChanged?()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(_ device: CastDiscoveredDevice, selecting: Bool) {
        name.text = device.name; detail.text = device.connectionDescription
        detail.isHidden = device.connectionDescription?.isEmpty != false
        icon.image = UIImage(named: device.icon.rawValue); icon.isHidden = selecting
        if selecting { spinner.startAnimating() } else { spinner.stopAnimating() }
        accessibilityIdentifier = "castDevice.\(device.id)"
        accessibilityLabel = [device.name, detail.isHidden ? nil : device.connectionDescription].compactMap { $0 }.joined(separator: ", ")
        accessibilityValue = selecting ? Appearance.text("mr_cast_connecting") : nil
        setNeedsLayout()
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        name.font = Appearance.font(16, compatibleWith: name.traitCollection)
        detail.font = Appearance.font(14, compatibleWith: detail.traitCollection)
        return CGSize(width: size.width, height: 25 + max(32, ceil(name.font.lineHeight))
            + (detail.isHidden ? 0 : max(24, ceil(detail.font.lineHeight))))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let textWidth = max(0, bounds.width - 96), titleHeight = max(32, ceil(name.font.lineHeight))
        icon.frame = CGRect(x: rtl ? bounds.width - 48 : 24, y: bounds.midY - 12, width: 24, height: 24)
        spinner.frame = icon.frame
        name.frame = CGRect(x: rtl ? 24 : 72, y: 12, width: textWidth, height: titleHeight)
        detail.frame = CGRect(x: name.frame.minX, y: name.frame.maxY, width: textWidth, height: max(24, ceil(detail.font.lineHeight)))
        name.textAlignment = rtl ? .right : .left; detail.textAlignment = name.textAlignment
    }
}

@MainActor private final class CastChooserProgress: UIView {
    private let segment = CALayer()
    override init(frame: CGRect) { super.init(frame: frame); layer.addSublayer(segment); isAccessibilityElement = false }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundColor = .clear; clipsToBounds = true
        layer.sublayers?.filter { $0 !== segment }.forEach { $0.removeFromSuperlayer() }
        let track = CALayer(); track.backgroundColor = Appearance.accent.withAlphaComponent(0.3).resolvedColor(with: traitCollection).cgColor
        track.frame = CGRect(x: 0, y: 6.5, width: bounds.width, height: 3); layer.insertSublayer(track, below: segment)
        segment.backgroundColor = Appearance.accent.resolvedColor(with: traitCollection).cgColor
        segment.frame = CGRect(x: 0, y: 6.5, width: bounds.width * 0.4, height: 3)
        segment.removeAllAnimations()
        if !UIAccessibility.isReduceMotionEnabled {
            let animation = CABasicAnimation(keyPath: "position.x")
            animation.fromValue = -segment.bounds.width / 2; animation.toValue = bounds.width + segment.bounds.width / 2
            animation.duration = 1.8; animation.repeatCount = .infinity
            segment.add(animation, forKey: "search")
        }
    }
}
