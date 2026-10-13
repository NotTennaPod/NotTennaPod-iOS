import Foundation

/// Application-owned choices from ShownotesWebView.onCreateContextMenu.
/// Keep the selected destination intact for Copy/Share and later dispatch.
public struct ShownotesLinkMenu: Equatable, Sendable {
    public enum Action: String, Equatable, Sendable {
        case openInBrowser = "open_in_browser_label"
        case copyURL = "copy_url_label"
        case shareURL = "share_url_label"
        case goToPosition = "go_to_position_label"
    }
    public let destination: String
    public let positionMilliseconds: Int32?
    public let actions: [Action]
    public init(destination: String, canOpenInBrowser: Bool) {
        self.destination = destination
        positionMilliseconds = ShownotesFormatter.timecodeMilliseconds(for: destination)
        if positionMilliseconds != nil { actions = [.goToPosition] }
        else { actions = (canOpenInBrowser ? [.openInBrowser] : []) + [.copyURL, .shareURL] }
    }
    /// Android WebView EMAIL_TYPE supplies the decoded mailto payload, including query.
    public static func emailClipboardText(for destination: String) -> String? {
        guard destination.lowercased().hasPrefix("mailto:") else { return nil }
        let payload = String(destination.dropFirst(7))
        return payload.removingPercentEncoding ?? payload
    }
    public func title(locale: Locale = .current) -> String {
        positionMilliseconds.map { EpisodeRowPresentation.time($0, locale: locale) } ?? destination
    }
}
