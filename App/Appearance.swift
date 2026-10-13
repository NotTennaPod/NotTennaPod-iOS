import UIKit
import NotTennaPodCore

@MainActor
enum Appearance {
    /// Retained supplementary content may be offscreen during measurement.
    /// Resolve its explicit text-size overrides against its logical container,
    /// without replacing UIKit inheritance or mutating any view overrides.
    static func textMetricsTraits(inheriting traits: UITraitCollection, through views: [UIView]) -> UITraitCollection {
        var category = traits.preferredContentSizeCategory
        for view in views where view.traitOverrides.contains(UITraitPreferredContentSizeCategory.self) {
            category = view.traitOverrides.preferredContentSizeCategory
        }
        return traits.modifyingTraits { $0.preferredContentSizeCategory = category }
    }
    static func text(_ key: String) -> String { NSLocalizedString(key, comment: "") }
    /// Source %d count text does not request thousands grouping. The current
    /// app resources are English; broader resource/number locales remain a gate.
    /// A plural from Localizable.stringsdict, in the form the current language's rules pick for `count`.
    static func plural(_ key: String, _ count: Int) -> String { String.localizedStringWithFormat(text(key), count) }
    static func quantity(_ key: String, count: Int64) -> String {
        String(format: text(key), count)
    }
    static func durationDescription(_ key: String, milliseconds: Int32) -> String {
        let duration = PlayerTimePresentation.spokenDuration(milliseconds) { unit, count in
            String.localizedStringWithFormat(text(unit), count)
        }
        return String(format: text(key), duration)
    }
    /// `black` is the Full black value of the roles `Theme.AntennaPod.TrueBlack` overrides;
    /// every other role keeps its dark value under Full black.
    static func color(_ light: UInt32, _ dark: UInt32, black: UInt32? = nil) -> UIColor {
        UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? (traits[FullBlackThemeTrait.self] ? black ?? dark : dark) : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
    /// `colorBackground`/`colorSurface`/`background_color`.
    static var background: UIColor { color(0xf9fcff, 0x21272b, black: 0x000000) }
    /// `background_elevated` (swipe-action backgrounds).
    static var elevated: UIColor { color(0xefeeee, 0x2d3337, black: 0x000000) }
    static var navigation: UIColor { color(0xebeef3, 0x1c2024) }
    static var selected: UIColor { color(0xc8d8de, 0x3c4e68) }
    static var foreground: UIColor { color(0x000000, 0xffffff) }
    static var secondary: UIColor { color(0x444444, 0xcccccc) }
    static var accent: UIColor { color(0x0078c2, 0x3d8bff) }
    /// Source `color_surface_variant_{light,dark}`: dialog panels, field hints, the selected drawer row.
    static var surfaceVariant: UIColor { color(0xd3dce0, 0x2f3b4f) }

    static func font(_ size: CGFloat, bold: Bool = false, medium: Bool = false,
                     compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        let name = bold ? "Roboto-Bold" : (medium ? "Roboto-Medium" : "Roboto-Regular")
        guard let font = UIFont(name: name, size: size) else { preconditionFailure("Required bundled font unavailable: \(name)") }
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: font, compatibleWith: traits)
    }

    static func label(_ text: String?, size: CGFloat, bold: Bool = false) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font(size, bold: bold)
        label.textColor = foreground
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    static func icon(_ name: String, label: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .custom)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(named: name)
        button.configuration = configuration
        button.tintColor = foreground
        button.accessibilityLabel = label
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    static func title(for destination: NavigationDestination) -> String {
        text(key(for: destination))
    }

    static func key(for destination: NavigationDestination) -> String {
        switch destination {
        case .home: "home_label"
        case .queue: "queue_label"
        case .inbox: "inbox_label"
        case .subscriptions, .subscriptionList: "subscriptions_label"
        case .episodes: "episodes_label"
        case .downloads: "downloads_label"
        case .history: "playback_history_label"
        case .favorites: "favorite_episodes_label"
        case .statistics: "statistics_label"
        case .addPodcast: "add_feed_label"
        }
    }

    static func icon(for destination: NavigationDestination) -> String {
        switch destination {
        case .home: "ic_home"
        case .queue: "ic_playlist_play"
        case .inbox: "ic_inbox"
        case .subscriptions, .subscriptionList: "ic_subscriptions"
        case .episodes: "ic_feed"
        case .downloads: "ic_download"
        case .history: "ic_history"
        case .favorites: "ic_star"
        case .statistics: "ic_chart_box"
        case .addPodcast: "ic_add"
        }
    }
}
