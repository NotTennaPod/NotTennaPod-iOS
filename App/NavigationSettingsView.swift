import UIKit
import NotTennaPodCore

/// The source preference ordering is retained while feature groups acquire their bindings.
/// Navigation, preferred streaming and time-display controls are connected here; other settings remain tracked gaps.
@MainActor final class NavigationSettingsView: UIView {
    var onNavigate: ((SettingsPage) -> Void)?
    var onMessage: ((String) -> Void)?
    var onFailure: ((any Error) -> Void)?
    var onPreferenceAction: ((String) -> Void)?
    var onChange: (() -> Void)?
    /// A saved Theme, Full black or Use episode cover change, to apply to every window and screen.
    var onInterfaceChange: ((InterfacePreferences) -> Void)?
    private let interface: InterfacePreferenceStore?
    /// Theme cards in source order (Automatic, Light, Dark), laid out leading to trailing.
    private var themeCards: [UIView] = []
    private let downloads: DownloadPreferenceStore?
    /// The enqueue location's source (PROTOCOL §15.4).
    private let accountPolicy: AccountPolicy
    private let automatic: AutomaticDownloadPreferenceStore?
    private let navigation: NavigationPreferenceStore?
    private let timeDisplay: TimeDisplayPreferenceStore?
    private let playbackQueue: PlaybackQueuePreferenceStore?
    private let playbackHardware: PlaybackHardwarePreferenceStore?
    private let page: SettingsPage
    private struct PlaybackRow {
        let control: UIControl
        let title: UILabel
        let summary: UILabel
        let category: Bool
    }
    private var playbackRows: [PlaybackRow] = []
    private struct Entry: Decodable {
        let kind: String
        let title: String?
        let summary: String?
        let key: String?
        let icon: String?
        let defaultValue: String?
        /// Literal text of a code-created row (the Settings root notice); never localized.
        var text: String? = nil
    }
    /// Settings root views laid out leading-to-trailing; mirrored for right-to-left layout.
    private var rootLayout: [(view: UIView, frame: CGRect)] = []

    init(navigation: NavigationPreferenceStore?, timeDisplay: TimeDisplayPreferenceStore?, page: SettingsPage, width: CGFloat,
         downloads: DownloadPreferenceStore? = nil, accountPolicy: AccountPolicy? = nil, automatic: AutomaticDownloadPreferenceStore? = nil,
         playbackQueue: PlaybackQueuePreferenceStore? = nil, playbackHardware: PlaybackHardwarePreferenceStore? = nil,
         interface: InterfacePreferenceStore? = nil) {
        self.interface = interface
        self.playbackQueue = playbackQueue
        self.playbackHardware = playbackHardware
        self.downloads = downloads; self.automatic = automatic
        self.accountPolicy = accountPolicy ?? .standalone(download: downloads, queue: nil)
        self.navigation = navigation; self.timeDisplay = timeDisplay; self.page = page
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 0))
        build()
        registerForTraitChanges([UITraitLayoutDirection.self]) { (view: NavigationSettingsView, _) in
            view.setNeedsLayout()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        layoutPlaybackRows()
        layoutRootDirection()
        layoutThemeCards()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutPlaybackRows()
        layoutRootDirection()
        layoutThemeCards()
    }

    /// `theme_preference.xml` is a horizontal LinearLayout: Automatic, Light, Dark from the leading edge (RTL mirrors).
    private func layoutThemeCards() {
        guard let region = themeCards.first?.superview else { return }
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let width = (region.bounds.width - 40) / 3
        for (index, card) in themeCards.enumerated() {
            let leading = 12 + CGFloat(index) * (width + 8)
            card.frame.origin.x = rtl ? region.bounds.width - leading - width : leading
        }
    }

    /// Android preference rows put the icon at the leading edge and the text after it (also in RTL).
    private func layoutRootDirection() {
        guard !rootLayout.isEmpty else { return }
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        for item in rootLayout {
            let width = item.view.superview?.bounds.width ?? bounds.width
            item.view.frame = rtl ? CGRect(x: width - item.frame.maxX, y: item.frame.minY,
                                           width: item.frame.width, height: item.frame.height) : item.frame
            (item.view as? UILabel)?.textAlignment = rtl ? .right : .left
        }
    }

    private func layoutPlaybackRows() {
        guard !playbackRows.isEmpty else { return }
        // AppCompat's preference padding is 16dp, overridden to 24dp in
        // values-sw600dp-v13. Use this window's smallest dimension, not device
        // class or landscape width. Before attachment only the view width is known.
        let smallestDimension = window.map { min($0.bounds.width, $0.bounds.height) } ?? bounds.width
        let inset: CGFloat = smallestDimension >= 600 ? 24 : 16
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        var y: CGFloat = 0
        for item in playbackRows {
            let indicator = item.control.subviews.compactMap { $0 as? PreferenceSwitchView }.first
            let widgetWidth: CGFloat = indicator == nil ? 0 : 52 + 16
            let textWidth = max(0, bounds.width - inset * 2 - widgetWidth)
            let titleHeight = item.title.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
            let summaryHeight = item.summary.text == nil ? 0 : item.summary.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
            let height = item.category ? max(48, titleHeight + 24) : max(64, titleHeight + summaryHeight + 32)
            item.control.frame = CGRect(x: 0, y: y, width: bounds.width, height: height)
            let textX = inset + (rtl ? widgetWidth : 0)
            item.title.textAlignment = rtl ? .right : .left
            item.summary.textAlignment = rtl ? .right : .left
            item.title.frame = CGRect(x: textX, y: item.category ? height - titleHeight - 8 : (height - titleHeight - summaryHeight) / 2,
                                      width: textWidth, height: titleHeight)
            item.summary.frame = CGRect(x: textX, y: item.title.frame.maxY, width: textWidth, height: summaryHeight)
            indicator?.frame = CGRect(x: rtl ? inset : bounds.width - inset - 52, y: (height - 32) / 2, width: 52, height: 32)
            y += height
        }
        frame.size.height = y + 16
    }

    private func build() {
        guard let url = Bundle.main.url(forResource: "NavigationPreferenceCatalogue", withExtension: "json"),
              let data = try? Data(contentsOf: url), let catalogue = try? JSONDecoder().decode([String: [Entry]].self, from: data) else { return }
        let main = page == .main
        let interface = page == .userInterface
        let swipes = page == .swipeActions
        let section: String? = switch page {
        case .downloads: "downloads"
        case .automaticDownload: "autodownload"
        case .autoDeletion: "autodeletion"
        case .playback: "playback"
        default: nil
        }
        guard main || interface || swipes || section != nil else { return }
        let entries = swipes ? SwipeActionsSettingsRow.allCases
            .map { Entry(kind: "Preference", title: $0.titleKey, summary: nil, key: $0.key, icon: nil, defaultValue: nil) }
            : main ? Self.rootEntries : catalogue[section ?? "interface"] ?? []
        var y: CGFloat = 0
        for entry in entries {
            // Active Android 3.12.1 fragment removes these legacy notification controls
            // on the current reference OS (API 36), despite their presence in XML.
            if entry.key == "prefExpandNotify" || entry.key == "prefPersistNotify" { continue }
            // PlaybackPreferencesFragment hides these reconnect rows on API 31+.
            if section == "playback", ["prefUnpauseOnHeadsetReconnect", "prefUnpauseOnBluetoothReconnect"].contains(entry.key ?? "") { continue }
            // Dynamic colors is hidden (iOS apps cannot read the wallpaper), as Android hides it below API 31;
            // Choose data folder is hidden (iOS apps cannot choose storage).
            if ["prefTintedColors", "prefChooseDataDir"].contains(entry.key ?? "") { continue }
            if entry.kind == "ThemePreference" {
                let region = themePreview(width: bounds.width)
                region.frame.origin.y = y; addSubview(region); y += region.bounds.height
                continue
            }
            if entry.kind == "SearchPreference" {
                // `searchpreference_preference.xml`: the search card inside 8-point padding; a tap opens the
                // search page (`SearchPreference.onClick`). The card mirrors itself in right-to-left layout.
                let row = UIControl(frame: CGRect(x: 0, y: y, width: bounds.width, height: 64))
                let card = SettingsSearchCard(editable: false)
                card.frame = CGRect(x: 8, y: 8, width: max(0, bounds.width - 16), height: 48)
                card.isUserInteractionEnabled = false
                row.autoresizingMask = .flexibleWidth; card.autoresizingMask = .flexibleWidth
                row.addSubview(card)
                row.isAccessibilityElement = true
                row.accessibilityLabel = Appearance.text("preference_search_hint")
                row.accessibilityTraits = .button
                row.accessibilityIdentifier = entry.key
                row.addAction(UIAction { [weak self] _ in self?.onPreferenceAction?("searchPreference") }, for: .touchUpInside)
                addSubview(row); y += 64
                continue
            }
            if entry.kind == "Notice", let text = entry.text {
                let row = noticeRow(text, width: bounds.width)
                row.frame.origin.y = y; addSubview(row); y += row.bounds.height
                continue
            }
            guard let titleKey = entry.title else { continue }
            let category = entry.kind == "PreferenceCategory"
            let toggle = entry.kind == "SwitchPreferenceCompat"
            let left: CGFloat = main && !category ? 72 : 16
            let right: CGFloat = toggle ? 84 : 16
            let title = Appearance.label(Appearance.text(titleKey), size: category ? 14 : 16)
            if section != nil && !category { title.font = Appearance.font(16, medium: true) }
            if category { title.textColor = Appearance.accent }
            var summaryText = entry.summary.map(Appearance.text)
            if entry.key == "prefEnqueueLocation" {
                // PlaybackPreferencesFragment.buildEnqueueLocationPreference: "Add episodes to: <choice>".
                summaryText = String(format: Appearance.text("pref_enqueue_location_sum"),
                                     Appearance.text(accountPolicy.enqueueLocation.titleKey))
            }
            let summary = Appearance.label(summaryText, size: 14)
            summary.textColor = Appearance.secondary
            if section != nil && !category {
                // Source preference text boxes include font padding: approximately 22/20 pt.
                // Preserve their line rhythm with native paragraph metrics at each local width.
                for (label, lineHeight) in [(title, CGFloat(22)), (summary, CGFloat(20))] {
                    if let text = label.text {
                        let paragraph = NSMutableParagraphStyle()
                        paragraph.minimumLineHeight = lineHeight; paragraph.maximumLineHeight = lineHeight
                        label.attributedText = NSAttributedString(string: text, attributes: [.paragraphStyle: paragraph])
                    }
                }
            }
            let textWidth = max(0, bounds.width - left - right)
            let titleHeight = title.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
            let summaryHeight = summary.text == nil ? 0 : summary.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
            let height = category ? max(48, titleHeight + 24) : max(64, titleHeight + summaryHeight + 32)
            let row = UIControl(frame: CGRect(x: 0, y: y, width: bounds.width, height: height))
            title.frame = CGRect(x: left, y: category ? height - titleHeight - 8 : (height - titleHeight - summaryHeight) / 2,
                                 width: textWidth, height: titleHeight)
            summary.frame = CGRect(x: left, y: title.frame.maxY, width: textWidth, height: summaryHeight)
            row.addSubview(title); row.addSubview(summary)
            if let iconName = entry.icon {
                let icon = UIImageView(image: UIImage(named: iconName)); icon.tintColor = Appearance.secondary
                icon.frame = CGRect(x: 16, y: (height - 24) / 2, width: 24, height: 24)
                row.addSubview(icon)
                if main { rootLayout.append((icon, icon.frame)) }
            }
            if main { rootLayout += [(title, title.frame), (summary, summary.frame)] }
            row.isAccessibilityElement = !category
            row.accessibilityLabel = title.text
            row.accessibilityHint = summary.text
            row.accessibilityIdentifier = entry.key
            row.accessibilityTraits = .button
            if toggle {
                let key = entry.key ?? ""
                let enabled = (key != "prefBackButtonOpensDrawer" || navigation?.value.bottomNavigation == false)
                    && (!["prefAutoDeleteLocal", "prefFavoriteKeepsEpisode"].contains(key) || downloads?.value.autoDelete == true)
                let on = value(for: key, fallback: entry.defaultValue == "true")
                let image = PreferenceSwitchView(); image.isOpaque = false; image.backgroundColor = .clear; image.isOn = on
                image.frame = CGRect(x: bounds.width - 68, y: (height - 32) / 2, width: 52, height: 32)
                image.isUserInteractionEnabled = false
                row.addSubview(image)
                row.accessibilityValue = on ? Appearance.text("on") : Appearance.text("off")
                row.isEnabled = enabled
                if section != nil { image.preferenceEnabled = enabled }
                else { row.alpha = enabled ? 1 : 0.38 }
                if !enabled { row.accessibilityTraits.insert(.notEnabled) }
                row.addAction(UIAction { [weak self, weak image, weak row] _ in
                    guard let self else { return }
                    if key == "prefAutoDeleteLocal", downloads?.value.autoDeleteLocal != true { onPreferenceAction?(key); return }
                    do {
                        if try self.toggle(key) {
                            let newValue = self.value(for: key, fallback: on)
                            image?.isOn = newValue; row?.accessibilityValue = newValue ? Appearance.text("on") : Appearance.text("off")
                            if Self.downloadKeys.contains(key) { onChange?() }
                        }
                    } catch { self.onFailure?(error) }
                }, for: .touchUpInside)
            } else if !category {
                row.addAction(UIAction { [weak self] _ in
                    if let key = entry.key, let page = Self.subpages[key] { self?.onNavigate?(page) }
                    else if let key = entry.key { self?.onPreferenceAction?(key) }
                }, for: .touchUpInside)
            }
            addSubview(row); y += height
            if section == "playback" { playbackRows.append(.init(control: row, title: title, summary: summary, category: category)) }
        }
        frame.size.height = y + 16
        layoutPlaybackRows()
    }

    /// The Settings root: the unofficial-package composition of Android's MainPreferencesFragment.
    /// Rows that open another settings page, by preference key.
    private static let subpages: [String: SettingsPage] = [
        "prefScreenInterface": .userInterface, "prefScreenDownloads": .downloads, "prefScreenPlayback": .playback,
        "prefScreenImportExport": .importExport, "prefAutoDownloadSettings": .automaticDownload,
        "prefAutoDeleteScreen": .autoDeletion, "prefSwipe": .swipeActions, "prefAbout": .about,
    ]

    private static var rootEntries: [Entry] {
        SettingsRootComposition.application.map { row in
            let kind = switch row.kind {
            case .search: "SearchPreference"
            case .preference: "Preference"
            case .category: "PreferenceCategory"
            case .notice: "Notice"
            }
            return Entry(kind: kind, title: row.titleKey, summary: row.summaryKey, key: row.key, icon: row.icon,
                         defaultValue: nil, text: row.text)
        }
    }

    /// Android's spin-off notice (MPF:47–55): a titleless preference row with a red circled "i" and
    /// the hard-coded English text in the secondary text colour, up to 10 lines, no divider.
    /// Android's row shows a ripple but has no click listener; on iOS it is static text instead
    /// (bounded adaptation): no highlight, not a button, icon decorative.
    private func noticeRow(_ text: String, width: CGFloat) -> UIView {
        let left: CGFloat = 72, right: CGFloat = 16
        let label = Appearance.label(text, size: 14)
        label.textColor = Appearance.secondary
        label.numberOfLines = 10
        let textWidth = max(0, width - left - right)
        let textHeight = label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        let height = max(64, textHeight + 32)
        let row = UIView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        label.frame = CGRect(x: left, y: (height - textHeight) / 2, width: textWidth, height: textHeight)
        let red = SettingsRootComposition.noticeColor
        let icon = UIImageView(image: UIImage(named: SettingsRootComposition.noticeIcon))
        icon.tintColor = Appearance.color(red, red)
        icon.isAccessibilityElement = false
        icon.accessibilityIdentifier = "settingsNoticeIcon"
        icon.frame = CGRect(x: 16, y: (height - 24) / 2, width: 24, height: 24)
        row.addSubview(label); row.addSubview(icon)
        row.isAccessibilityElement = true
        row.accessibilityLabel = text
        row.accessibilityTraits = .staticText
        row.accessibilityIdentifier = "settingsSpinOffNotice"
        rootLayout += [(label, label.frame), (icon, icon.frame)]
        return row
    }

    private func value(for key: String, fallback: Bool) -> Bool {
        switch key {
        case "prefPauseOnHeadsetDisconnect": playbackHardware?.value.pauseOnDisconnect ?? true
        case "prefFollowQueue": playbackQueue?.value.followQueue ?? true
        case "prefSkipKeepsEpisode": playbackQueue?.value.skipKeepsEpisode ?? true
        case "prefDownloadsButtonAction": downloads?.value.buttonActionPlay ?? false
        case "prefDeleteRemovesFromQueue": downloads?.value.deleteRemovesFromQueue ?? false
        case "prefEnqueueDownloaded": downloads?.value.enqueue ?? true
        case "prefAutoDelete": downloads?.value.autoDelete ?? false
        case "prefAutoDeleteLocal": downloads?.value.autoDeleteLocal ?? false
        case "prefFavoriteKeepsEpisode": downloads?.value.favoriteKeepsEpisode ?? true
        case "prefEnableAutoDl": automatic?.value.global ?? false
        case "prefEnableAutoDlQueue": automatic?.value.queue ?? false
        case "prefEnableAutoDownloadOnBattery": automatic?.value.onBattery ?? true
        case "prefBottomNavigation": navigation?.value.bottomNavigation ?? true
        case "prefBackButtonOpensDrawer": navigation?.value.backButtonOpensDrawer ?? false
        case "prefStreamOverDownload": navigation?.value.streamOverDownload ?? false
        case "showTimeLeft": timeDisplay?.value.showRemainingTime ?? false
        case "prefPlaybackTimeRespectsSpeed": timeDisplay?.value.timeRespectsSpeed ?? false
        case "prefThemeBlack": interface?.value.blackTheme ?? false
        case "prefEpisodeCover": interface?.value.useEpisodeCover ?? true
        default: fallback
        }
    }
    private func toggle(_ key: String) throws -> Bool {
        if let playbackHardware, key == "prefPauseOnHeadsetDisconnect" {
            var value = playbackHardware.value; value.pauseOnDisconnect.toggle()
            try playbackHardware.update(value)
            return true
        }
        if let playbackQueue, ["prefFollowQueue", "prefSkipKeepsEpisode"].contains(key) {
            var value = playbackQueue.value
            if key == "prefFollowQueue" { value.followQueue.toggle() }
            else { value.skipKeepsEpisode.toggle() }
            try playbackQueue.update(value)
            return true
        }
        if let downloads, key == "prefEnqueueDownloaded" {
            var value = downloads.value; value.enqueue.toggle()
            try downloads.update(value); return true
        }
        if let downloads, Self.downloadKeys.prefix(5).contains(key) {
            var value = downloads.value
            switch key {
            case "prefDownloadsButtonAction": value.buttonActionPlay = !(value.buttonActionPlay ?? false)
            case "prefDeleteRemovesFromQueue": value.deleteRemovesFromQueue.toggle()
            case "prefAutoDelete": value.autoDelete = !(value.autoDelete ?? false)
            case "prefAutoDeleteLocal": value.autoDeleteLocal = !(value.autoDeleteLocal ?? false)
            case "prefFavoriteKeepsEpisode": value.favoriteKeepsEpisode = !(value.favoriteKeepsEpisode ?? true)
            default: break
            }
            try downloads.update(value); return true
        }
        if let automatic, ["prefEnableAutoDl", "prefEnableAutoDlQueue", "prefEnableAutoDownloadOnBattery"].contains(key) {
            var value = automatic.value
            switch key { case "prefEnableAutoDl": value.global.toggle(); case "prefEnableAutoDlQueue": value.queue.toggle(); default: value.onBattery.toggle() }
            try automatic.update(value); return true
        }
        if let navigation, key == "prefStreamOverDownload" {
            var value = navigation.value
            value.chooseStreamOverDownload(!value.streamOverDownload)
            try navigation.update(value)
            return true
        }
        if let navigation, key == "prefBottomNavigation" || key == "prefBackButtonOpensDrawer" {
            var value = navigation.value
            if key == "prefBottomNavigation" { value.bottomNavigation.toggle() } else { value.backButtonOpensDrawer.toggle() }
            try navigation.update(value)
            if key == "prefBottomNavigation" && !value.bottomNavigation {
                onMessage?(Appearance.text("bottom_navigation_deprecation_warning"))
            }
            return true
        }
        if let timeDisplay, key == "showTimeLeft" || key == "prefPlaybackTimeRespectsSpeed" {
            var value = timeDisplay.value
            if key == "showTimeLeft" { value.showRemainingTime.toggle() } else { value.timeRespectsSpeed.toggle() }
            try timeDisplay.update(value); return true
        }
        if let interface, key == "prefThemeBlack" || key == "prefEpisodeCover" {
            var value = interface.value
            if key == "prefThemeBlack" { value.blackTheme.toggle() } else { value.useEpisodeCover.toggle() }
            try interface.update(value)
            onInterfaceChange?(value)
            return true
        }
        return false
    }
    private static let downloadKeys = ["prefDownloadsButtonAction", "prefDeleteRemovesFromQueue", "prefAutoDelete", "prefAutoDeleteLocal", "prefFavoriteKeepsEpisode", "prefEnableAutoDl", "prefEnableAutoDlQueue", "prefEnableAutoDownloadOnBattery"]
    /// `ThemePreference`: three cards, Automatic, Light and Dark. The active one has the surface
    /// colour at 32 dp elevation, the others at 1 dp (`ThemePreference.java:33–38`); a tap saves and applies at once.
    private func themePreview(width: CGFloat) -> UIView {
        let region = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 0))
        let cardWidth = max(0, (width - 40) / 3)
        var height: CGFloat = 0
        let active = interface?.value.theme ?? .system
        let themes: [(ThemePreference, String, String, String)] = [
            (.system, "system", "pref_theme_title_automatic", "themeSystemCard"),
            (.light, "light", "pref_theme_title_light", "themeLightCard"),
            (.dark, "dark", "pref_theme_title_dark", "themeDarkCard")]
        themeCards = []
        for (index, (theme, variant, titleKey, identifier)) in themes.enumerated() {
            let card = UIControl()
            card.backgroundColor = Self.elevatedSurface(overlay: theme == active ? 0.1773 : 0.0512)
            card.layer.cornerRadius = 16
            let image = UIImageView(image: UIImage(named: "theme_preview_" + variant)); image.contentMode = .scaleAspectFit
            image.isUserInteractionEnabled = false
            let imageWidth = max(0, cardWidth - 32)
            let aspect = image.image.map { $0.size.height / $0.size.width } ?? 1
            let imageHeight = min(200, imageWidth * aspect)
            image.frame = CGRect(x: 16, y: 16, width: imageWidth, height: imageHeight)
            let label = Appearance.label(Appearance.text(titleKey), size: 14)
            label.textAlignment = .center
            let labelHeight = label.sizeThatFits(CGSize(width: imageWidth, height: .greatestFiniteMagnitude)).height
            label.frame = CGRect(x: 16, y: image.frame.maxY + 4, width: imageWidth, height: labelHeight)
            card.frame = CGRect(x: 12 + CGFloat(index) * (cardWidth + 8), y: 12, width: cardWidth, height: label.frame.maxY + 16)
            card.addSubview(image); card.addSubview(label); region.addSubview(card)
            card.isAccessibilityElement = true
            card.accessibilityLabel = label.text
            card.accessibilityTraits = theme == active ? [.button, .selected] : .button
            card.accessibilityIdentifier = identifier
            card.addAction(UIAction { [weak self] _ in
                guard let self, let interface else { return }
                var value = interface.value; value.theme = theme
                do { try interface.update(value); onInterfaceChange?(value) } catch { onFailure?(error) }
            }, for: .touchUpInside)
            themeCards.append(card)
            height = max(height, card.frame.maxY + 12)
        }
        region.frame.size.height = height
        return region
    }

    /// Material `SurfaceColors.getColorForElevation`: the primary colour composited over the surface.
    private static func elevatedSurface(overlay: CGFloat) -> UIColor {
        UIColor { traits in
            var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            Appearance.background.resolvedColor(with: traits).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            Appearance.accent.resolvedColor(with: traits).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
            return UIColor(red: r1 + (r2 - r1) * overlay, green: g1 + (g2 - g1) * overlay, blue: b1 + (b2 - b1) * overlay, alpha: 1)
        }
    }
}

@MainActor final class PreferenceSwitchView: UIView {
    var isOn = false { didSet { setNeedsDisplay() } }
    /// Material preference widget states; nil preserves existing non-preference consumers.
    var preferenceEnabled: Bool? { didSet { setNeedsDisplay() } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isOpaque = false
    }
    override func draw(_ rect: CGRect) {
        let track = UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: 16)
        var fill = isOn ? Appearance.accent : Appearance.navigation
        var stroke = isOn ? Appearance.accent : Appearance.secondary
        var thumbColor = isOn ? UIColor.white : Appearance.secondary
        if let enabled = preferenceEnabled {
            let surface = Appearance.surfaceVariant
            fill = isOn ? Appearance.accent : surface
            thumbColor = isOn ? Appearance.color(0xffffff, 0x000000) : Appearance.secondary
            if !enabled {
                fill = (isOn ? Appearance.foreground : surface).withAlphaComponent(31.0/255)
                stroke = Appearance.foreground.withAlphaComponent(31.0/255)
                thumbColor = isOn ? Appearance.background : Appearance.foreground.withAlphaComponent(97.0/255)
            }
        }
        fill.setFill(); track.fill()
        if preferenceEnabled != false || !isOn { stroke.setStroke(); track.lineWidth = 2; track.stroke() }
        let size: CGFloat = isOn ? 24 : 16
        let x: CGFloat = isOn ? 26 : 8
        let thumb = UIBezierPath(ovalIn: CGRect(x: x, y: (bounds.height - size) / 2, width: size, height: size))
        thumbColor.setFill(); thumb.fill()
    }
}
