import UIKit
import NotTennaPodCore

/// The currently implemented feed preferences, in the source category order.
@MainActor
final class FeedSettingsView: UIView {
    enum Action { case rename, tags, playbackSpeed, autoSkip, volumeAdaptation, autoDelete, newEpisodes, autoDownload, downloadFilter, authentication, keepUpdated(Bool), notification(Bool) }
    var onAction: ((Action) -> Void)?
    private var feed: LibraryFeed
    private var rows: [UIView] = []
    private let deletionPreferences: PlaybackEndPreferences
    private let globalNewEpisodesAction: NewEpisodesAction
    private let globalAutoDownload: Bool
    /// A server library, where automatic download never forces the Inbox (PROTOCOL §9.10): the action's own summary shows.
    private let serverLibrary: Bool
    init(feed: LibraryFeed, deletionPreferences: PlaybackEndPreferences = .init(),
         globalNewEpisodesAction: NewEpisodesAction = .inbox, globalAutoDownload: Bool = false, serverLibrary: Bool = false) {
        self.feed = feed; self.deletionPreferences = deletionPreferences
        self.globalNewEpisodesAction = globalNewEpisodesAction; self.globalAutoDownload = globalAutoDownload
        self.serverLibrary = serverLibrary
        super.init(frame: .zero); build()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func build() {
        rows.forEach { $0.removeFromSuperview() }; rows.removeAll()
        accessibilityIdentifier = "feedSettingsScreen"
        func heading(_ key: String) {
            let label = Appearance.label(Appearance.text(key), size: 14)
            label.textColor = Appearance.accent; label.accessibilityTraits.insert(.header)
            rows.append(label); addSubview(label)
        }
        func row(_ title: String, summary: String?, icon: String, id: String,
                 selected: Bool? = nil, enabled: Bool = true, action: @escaping () -> Void) {
            let item = FeedSettingRow(title: Appearance.text(title), summary: summary.map(Appearance.text),
                                      icon: icon, selected: selected, enabled: enabled, action: action)
            item.accessibilityIdentifier = id; rows.append(item); addSubview(item)
        }
        heading("pref_display")
        row("rename_feed_label", summary: nil, icon: "ic_rename", id: "feedRename") { [weak self] in self?.onAction?(.rename) }
        row("feed_tags_label", summary: "feed_tags_summary", icon: "ic_tag", id: "feedSettingsTags") {
            [weak self] in self?.onAction?(.tags)
        }
        heading("playback_pref")
        row("playback_speed", summary: "pref_feed_playback_speed_sum", icon: "ic_playback_speed", id: "feedSettingsPlaybackSpeed") {
            [weak self] in self?.onAction?(.playbackSpeed)
        }
        row("pref_feed_skip", summary: "pref_feed_skip_sum", icon: "ic_skip_24dp", id: "feedSettingsAutoSkip") {
            [weak self] in self?.onAction?(.autoSkip)
        }
        row("feed_volume_adapdation", summary: String(format: Appearance.text("feed_volume_adaptation_summary"),
            Appearance.text(feed.volumeAdaptation.titleKey)), icon: "ic_volume_adaption", id: "feedSettingsVolume") {
            [weak self] in self?.onAction?(.volumeAdaptation)
        }
        heading("automation")
        row("keep_updated", summary: "keep_updated_summary", icon: "ic_refresh", id: "feedKeepUpdated",
            selected: feed.keepUpdated) { [weak self] in
                guard let self else { return }
                feed.keepUpdated.toggle(); onAction?(.keepUpdated(feed.keepUpdated)); build(); setNeedsLayout()
            }
        row("episode_notification", summary: "episode_notification_summary", icon: "ic_notifications", id: "feedNotification",
            selected: feed.showEpisodeNotification, enabled: feed.keepUpdated) { [weak self] in
                guard let self else { return }
                feed.showEpisodeNotification.toggle(); onAction?(.notification(feed.showEpisodeNotification)); build(); setNeedsLayout()
            }
        let globalDeletion = feed.source.isLocalFeedSource
            ? deletionPreferences.autoDeleteLocal : deletionPreferences.autoDelete
        let deletionSummary = feed.autoDelete == .global
            ? String(format: Appearance.text("global_default_with_value"), Appearance.text(globalDeletion ? "feed_auto_download_always" : "feed_auto_download_never"))
            : Appearance.text(feed.autoDelete.titleKey)
        row("pref_auto_delete_playback_title", summary: deletionSummary, icon: "ic_delete", id: "feedSettingsAutoDelete") {
            [weak self] in self?.onAction?(.autoDelete)
        }
        let newEpisodesSummary: String
        if !serverLibrary && feed.newEpisodeActionIsAutomatic(globalAutoDownload: globalAutoDownload) {
            newEpisodesSummary = Appearance.text("feed_new_episodes_action_summary_autodownload")
        } else if feed.newEpisodesAction == .global {
            newEpisodesSummary = String(format: Appearance.text("global_default_with_value"), Appearance.text(globalNewEpisodesAction.titleKey))
        } else { newEpisodesSummary = Appearance.text(feed.newEpisodesAction.titleKey) }
        row("pref_new_episodes_action_title", summary: newEpisodesSummary, icon: "ic_feed", id: "feedSettingsNewEpisodes") {
            [weak self] in self?.onAction?(.newEpisodes)
        }
        if !feed.source.isLocalFeedSource {
            let enabled = feed.newEpisodeActionIsAutomatic(globalAutoDownload: globalAutoDownload)
            let summary = feed.autoDownload == .global
                ? String(format: Appearance.text("global_default_with_value"), Appearance.text(enabled ? "enabled" : "disabled"))
                : Appearance.text(feed.autoDownload.titleKey)
            row("auto_download_label", summary: summary, icon: "ic_download", id: "feedSettingsAutoDownload") {
                [weak self] in self?.onAction?(.autoDownload)
            }
            if enabled {
                row("episode_filters_label", summary: "episode_filters_description", icon: "", id: "feedSettingsDownloadFilter") {
                    [weak self] in self?.onAction?(.downloadFilter)
                }
            }
        }
        heading("pref_advanced")
        if !feed.source.isLocalFeedSource {
            row("authentication_label", summary: "authentication_descr", icon: "ic_key", id: "feedAuthentication") {
                [weak self] in self?.onAction?(.authentication)
            }
        }
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: layout(width: size.width, apply: false)) }
    override func layoutSubviews() { super.layoutSubviews(); _ = layout(width: bounds.width, apply: true) }
    private func layout(width: CGFloat, apply: Bool) -> CGFloat {
        var y: CGFloat = 0
        for row in rows {
            let heading = row is UILabel
            let inset: CGFloat = heading ? 16 : 0
            let height = heading ? max(48, row.sizeThatFits(CGSize(width: max(0, width - 32), height: .greatestFiniteMagnitude)).height + 24)
                : row.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            if apply { row.frame = CGRect(x: inset, y: y, width: max(0, width - 2 * inset), height: height) }
            y += height
        }
        return y
    }
}

@MainActor
private final class FeedSettingRow: UIControl {
    private let title: UILabel, summary: UILabel, icon: UIImageView
    private let toggle: PreferenceSwitchView?
    private let textInset: CGFloat
    init(title: String, summary: String?, icon: String, selected: Bool?, enabled: Bool, action: @escaping () -> Void) {
        self.title = Appearance.label(title, size: 16)
        self.summary = Appearance.label(summary, size: 14)
        self.icon = UIImageView(image: icon.isEmpty ? nil : UIImage(named: icon))
        textInset = icon.isEmpty ? 16 : 72
        toggle = selected.map { value in let view = PreferenceSwitchView(); view.isOn = value; return view }
        super.init(frame: .zero)
        self.summary.textColor = Appearance.secondary; self.icon.tintColor = Appearance.secondary
        [self.title, self.summary, self.icon].forEach { $0.isUserInteractionEnabled = false; addSubview($0) }
        if let toggle { toggle.isUserInteractionEnabled = false; addSubview(toggle) }
        isEnabled = enabled; alpha = enabled ? 1 : 0.38
        isAccessibilityElement = true; accessibilityLabel = title; accessibilityHint = summary
        accessibilityTraits = .button
        if let selected { accessibilityValue = Appearance.text(selected ? "on" : "off") }
        addAction(UIAction { _ in action() }, for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = max(0, size.width - textInset - (toggle == nil ? 16 : 84))
        return CGSize(width: size.width, height: max(64, title.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            + (summary.text == nil ? 0 : summary.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height) + 32))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: rtl ? bounds.width - x - width : x, y: y, width: width, height: height)
        }
        let width = max(0, bounds.width - textInset - (toggle == nil ? 16 : 84))
        let t = title.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let s = summary.text == nil ? 0 : summary.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        title.frame = rect(textInset, (bounds.height - t - s) / 2, width, t)
        summary.frame = rect(textInset, title.frame.maxY, width, s)
        icon.frame = rect(16, (bounds.height - 24) / 2, 24, 24)
        toggle?.frame = rect(bounds.width - 68, (bounds.height - 32) / 2, 52, 32)
    }
}
