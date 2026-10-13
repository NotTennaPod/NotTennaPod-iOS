import CoreGraphics

public struct ShellLayout: Equatable, Sendable {
    public let toolbar: CGRect
    public let content: CGRect
    public let navigation: CGRect
    public let bottomInset: CGRect
    public let miniPlayer: CGRect
    public let information: CGRect

    /// Strip kept below the mini player and bottom navigation, painted in the navigation colour. Android reserves
    /// the navigation-bar inset there (`bottom_padding`, MainActivity:403): 24 dp with gesture navigation on the
    /// reference device, with the gesture handle drawn in it below the labels. The iPhone home-indicator inset is
    /// 34 pt; keep Android's 24, which still clears the home indicator (the bottom ~13 pt), so the indicator never
    /// crosses the navigation labels or the mini player.
    public static let bottomStripMaximum: Double = 24

    public init(size: CGSize, topInset: Double, bottomInset: Double, playerVisible: Bool = false, bottomNavigation: Bool = true, informationHeight: Double = 0) {
        let width = max(0, size.width)
        let height = max(0, size.height)
        let top = min(height, max(0, topInset))
        let bottom = min(height - top, max(0, min(bottomInset, Self.bottomStripMaximum)))
        let available = height - top - bottom
        let navigationHeight = bottomNavigation ? min(64, available) : 0
        let toolbarHeight = min(64, available - navigationHeight)
        toolbar = CGRect(x: 0, y: top, width: width, height: toolbarHeight)
        navigation = CGRect(x: 0, y: height - bottom - navigationHeight, width: width, height: navigationHeight)
        let playerHeight = playerVisible ? min(64, max(0, navigation.minY - toolbar.maxY)) : 0
        miniPlayer = CGRect(x: 0, y: navigation.minY - playerHeight, width: width, height: playerHeight)
        // queue_fragment.xml: -12dp top margin and 8dp bottom margin below the toolbar.
        let infoTop = max(toolbar.minY, toolbar.maxY - 12)
        let infoHeight = min(max(0, informationHeight), max(0, miniPlayer.minY - infoTop))
        information = CGRect(x: 0, y: infoTop, width: width, height: infoHeight)
        let contentTop = informationHeight > 0 ? min(miniPlayer.minY, max(toolbar.maxY, information.maxY + 8)) : toolbar.maxY
        content = CGRect(x: 0, y: contentTop, width: width, height: max(0, miniPlayer.minY - contentTop))
        self.bottomInset = CGRect(x: 0, y: height - bottom, width: width, height: bottom)
    }

    public func navigationItem(at index: Int, count: Int, rightToLeft: Bool = false) -> CGRect? {
        guard count > 0, index >= 0, index < count else { return nil }
        let visualIndex = rightToLeft ? count - 1 - index : index
        let width = navigation.width / Double(count)
        return CGRect(x: Double(visualIndex) * width, y: navigation.minY, width: width, height: navigation.height)
    }
}
