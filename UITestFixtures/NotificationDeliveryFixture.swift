#if DEBUG
import UIKit
import UserNotifications
import NotTennaPodCore

/// Runs the production new-episode pipeline (refresh delivery, text, artwork, native requests) against a
/// UUID-isolated library and a recording notification center, then shows what was posted in a small panel.
/// Tapping a panel row takes the same route as tapping the notification (`destination` → `routeNotification`).
/// No system permission is needed: the iOS 27.0 iPhone Simulator never shows that prompt. How iOS itself
/// presents the group and delivers the tap is Apple's behaviour and is checked on a real device.
@MainActor final class NotificationDeliveryFixture: UIViewController {
    private let app: AppDelegate
    private let publish = UIButton(type: .system)
    private let status = UILabel()
    /// Outlives this controller, which is replaced by the library screen after publishing.
    private static var panel: NotificationPanelWindow?
    init(app: AppDelegate) { self.app = app; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        publish.setTitle("Publish fixture notifications", for: .normal)
        publish.accessibilityIdentifier = "publishFixtureNotifications"
        status.accessibilityIdentifier = "notificationFixtureStatus"; status.numberOfLines = 0
        view.addSubview(publish); view.addSubview(status)
        publish.addAction(UIAction { [weak self] _ in self?.run() }, for: .touchUpInside)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaLayoutGuide.layoutFrame
        publish.frame = CGRect(x: safe.minX + 16, y: safe.minY + 30, width: max(0, safe.width - 32), height: 56)
        status.frame = CGRect(x: safe.minX + 16, y: publish.frame.maxY + 16, width: max(0, safe.width - 32), height: 160)
    }
    private func run() {
        publish.isEnabled = false
        Task {
            do {
                guard let store = app.library, let window = view.window, let scene = window.windowScene else { return }
                let center = RecordingNotificationCenter()
                var feeds: [LibraryFeed] = []
                for title in ["Notification Alpha", "Notification Beta"] {
                    let fetcher = FeedFetcher(transport: NotificationFixtureTransport(title: title))
                    guard case .updated(let fetched) = try await fetcher.fetch(.init(source: "https://example.org/" + title.replacingOccurrences(of: " ", with: "-"))) else { return }
                    let feed = try await store.insert(fetched)
                    try await store.updatePreferences(feedID: feed.id) { $0.showEpisodeNotification = true }
                    try await store.updateEpisode(id: feed.episodes[0].id) { $0.userState.playState = .unplayed }
                    feeds.append(try await store.feed(id: feed.id)!)
                }
                let request = FeedRefreshRequest(feedID: nil, enqueuedAt: Date())
                try await store.enqueueManualRefresh(request)
                let publisher = NativeEpisodeNotifications(center: center)
                let delivery = EpisodeNotificationDelivery(store: store, publisher: publisher,
                    text: NewEpisodeNotificationContent.text, artwork: { try await NewEpisodeNotificationContent.artwork($0, store: store) })
                try await delivery.prepare(requestID: request.id)
                for feed in feeds {
                    try await store.updateEpisode(id: feed.episodes[0].id) { $0.userState.playState = .new }
                    try await delivery.refreshed(feed, requestID: request.id)
                }
                status.text = "Published \(center.current.count) notifications"
                window.rootViewController = LibraryViewController(library: store, startupError: nil, downloads: app.downloads,
                    playback: app.playback, timeDisplayPreferences: app.timeDisplayPreferences,
                    navigationPreferences: app.navigationPreferences, speedPreferences: app.speedPreferences,
                    mobileNetworkPreferences: app.mobileNetworkPreferences, usage: app.usage, feedDeletion: app.feedDeletion)
                let panel = NotificationPanelWindow(windowScene: scene, requests: center.current) { [weak app] request in
                    guard let destination = NativeEpisodeNotifications.destination(identifier: request.identifier,
                        category: request.content.categoryIdentifier, userInfo: request.content.userInfo) else { return }
                    app?.routeNotification(destination)
                }
                panel.isHidden = false
                Self.panel = panel
            } catch { status.text = String(describing: error); publish.isEnabled = true }
        }
    }
}

/// Records what the adapter posts; a later request with the same identifier replaces the earlier one, as in iOS.
@MainActor private final class RecordingNotificationCenter: EpisodeNotificationCenter {
    private(set) var current: [UNNotificationRequest] = []
    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func pendingIdentifiers() async -> [String] { current.map(\.identifier) }
    func deliveredIdentifiers() async -> [String] { [] }
    func post(_ request: UNNotificationRequest) async throws {
        if let index = current.firstIndex(where: { $0.identifier == request.identifier }) { current[index] = request }
        else { current.append(request) }
    }
}

/// A stand-in for Notification Center: one group per thread identifier, one row per notification. It never
/// becomes the key window, so routing acts on the app's own window exactly as after a real notification tap.
@MainActor private final class NotificationPanelWindow: UIWindow {
    override var canBecomeKey: Bool { false }
    init(windowScene: UIWindowScene, requests: [UNNotificationRequest], open: @escaping (UNNotificationRequest) -> Void) {
        super.init(windowScene: windowScene)
        windowLevel = .alert + 1
        backgroundColor = .clear
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for thread in requests.map(\.content.threadIdentifier).reduce(into: [String](), { if !$0.contains($1) { $0.append($1) } }) {
            let group = UIStackView(); group.axis = .vertical; group.spacing = 2
            group.backgroundColor = .secondarySystemBackground; group.layer.cornerRadius = 10
            group.isAccessibilityElement = false
            group.accessibilityIdentifier = "fixtureNotificationGroup.\(thread)"
            for request in requests where request.content.threadIdentifier == thread {
                let row = UIButton(type: .system)
                var configuration = UIButton.Configuration.plain()
                configuration.title = request.content.title
                configuration.subtitle = request.content.body.isEmpty ? nil : request.content.body
                configuration.contentInsets = .init(top: 4, leading: 10, bottom: 4, trailing: 10)
                row.configuration = configuration
                row.contentHorizontalAlignment = .leading
                row.accessibilityIdentifier = "fixtureNotification.\(request.identifier)"
                row.accessibilityLabel = [request.content.title, request.content.body].filter { !$0.isEmpty }.joined(separator: ", ")
                row.accessibilityValue = request.content.attachments.isEmpty ? "no artwork" : "artwork"
                row.addAction(UIAction { _ in open(request) }, for: .touchUpInside)
                group.addArrangedSubview(row)
            }
            stack.addArrangedSubview(group)
        }
        let host = UIViewController(); host.view.backgroundColor = .clear
        host.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
        rootViewController = host
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Touches outside the rows reach the app underneath.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        return view === rootViewController?.view || view === self ? nil : view
    }
}

private struct NotificationFixtureTransport: FeedHTTPTransport {
    let title: String
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
        let rss = "<rss version=\"2.0\"><channel><title>\(title)</title><link>https://example.org/</link><description>Fixture</description><item><guid>\(title)</guid><title>Episode for \(title)</title></item></channel></rss>"
        return FeedHTTPResponse(url: request.url!, status: 200, headers: ["Content-Type": "application/rss+xml"], body: Data(rss.utf8))
    }
}
#endif
