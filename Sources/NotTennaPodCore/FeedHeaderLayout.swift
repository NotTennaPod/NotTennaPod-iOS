import CoreGraphics

/// Feeditemlist_header.xml, excluding the parent's toolbar margin.
/// Child dimensions round independently, as in Android resource measurement.
public struct FeedHeaderLayout: Equatable, Sendable {
    public let hero, cover, actionStrip, info, filter, settings, title, author: CGRect
    public let failure, filtered, updatesDisabled: CGRect
    public let height: CGFloat

    public init(width: CGFloat, titleHeight: CGFloat, authorHeight: CGFloat,
                failureTextHeight: CGFloat? = nil, filteredTextHeight: CGFloat? = nil,
                updatesDisabledTextHeight: CGFloat? = nil, scale: CGFloat = 1, rightToLeft: Bool = false,
                configurationWidth: CGFloat? = nil, actionStripHeight: CGFloat = 48) {
        let density = max(1, scale)
        func dp(_ value: CGFloat) -> CGFloat { (value * density).rounded() / density }
        func mirror(_ value: CGRect) -> CGRect {
            rightToLeft ? CGRect(x: width - value.maxX, y: value.minY, width: value.width, height: value.height) : value
        }
        // Android w1000dp qualifies the whole window, not a narrower content pane
        // left beside a persistent drawer.
        let inset = dp((configurationWidth ?? width) >= 1000 ? 56 : 0)
        let available = max(0, width - 2 * inset)
        hero = CGRect(x: inset, y: 0, width: available, height: dp(156))
        actionStrip = CGRect(x: inset, y: hero.maxY - dp(actionStripHeight), width: available, height: dp(actionStripHeight))
        let coverFrame = CGRect(x: inset + dp(16), y: hero.maxY - dp(24) - dp(124), width: dp(124), height: dp(124))
        cover = mirror(coverFrame)
        let infoFrame = CGRect(x: inset + dp(148) - dp(4), y: actionStrip.midY - dp(24), width: dp(48), height: dp(48))
        info = mirror(infoFrame)
        filter = mirror(infoFrame.offsetBy(dx: dp(48), dy: 0))
        settings = mirror(infoFrame.offsetBy(dx: 2 * dp(48), dy: 0))
        let textX = coverFrame.maxX + dp(16)
        let textWidth = max(0, width - inset - dp(16) - textX)
        let t = max(0, dp(titleHeight)), a = max(0, dp(authorHeight))
        let textY = actionStrip.minY - dp(16) - t - a
        title = mirror(CGRect(x: textX, y: textY, width: textWidth, height: t))
        author = mirror(CGRect(x: textX, y: textY + t, width: textWidth, height: a))
        var y = hero.maxY
        if let failureTextHeight {
            failure = CGRect(x: inset + dp(16), y: y + dp(8), width: max(0, available - dp(32)),
                             height: max(0, dp(failureTextHeight)) + dp(16))
            y = failure.maxY + dp(8)
        } else { failure = .zero }
        if let filteredTextHeight {
            filtered = CGRect(x: inset, y: y, width: available, height: max(0, dp(filteredTextHeight)) + dp(4))
            y = filtered.maxY
        } else { filtered = .zero }
        if let updatesDisabledTextHeight {
            updatesDisabled = CGRect(x: inset, y: y, width: available, height: max(0, dp(updatesDisabledTextHeight)) + dp(4))
            y = updatesDisabled.maxY
        } else { updatesDisabled = .zero }
        height = y
    }
}

/// Active FeedItemlistFragment.refreshHeaderView visibility predicates.
/// The selected list renderer now shares subscribed and archived headers.
public struct FeedHeaderPresentation: Equatable, Sendable {
    public let failure, updatesDisabled, filtered, description, subscriptionNotice: Bool
    public let info, filter, settings, subscribe, restore: Bool

    public init(state: FeedSubscriptionState, failed: Bool, keepUpdated: Bool,
                hasFilter: Bool, hasInteracted: Bool) {
        let preview = state == .notSubscribed, archived = state == .archived
        failure = failed
        updatesDisabled = (!keepUpdated && !preview) || archived
        filtered = !preview && hasFilter
        description = preview
        subscriptionNotice = preview && hasInteracted
        info = !preview; filter = !preview && !archived; settings = filter
        subscribe = preview; restore = archived
    }
}
