#if DEBUG
import UIKit
import NotTennaPodCore

/// Real stored history and production sheet, isolated by the required test UUID.
/// Only setup is synthetic; gestures and clearing go through production UI.
@MainActor final class DownloadLogGestureFixture: UIViewController {
    private let library: FeedLibraryStore
    private let open = UIButton(type: .system)
    init(library: FeedLibraryStore) { self.library = library; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        open.setTitle("Open history", for: .normal); open.accessibilityIdentifier = "fixtureOpenHistory"
        open.isEnabled = false; view.addSubview(open)
        open.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            present(DownloadLogController(library: library, retry: { _ in }, openFeed: { _ in }, failed: { preconditionFailure("Fixture error: \($0)") }), animated: false)
        }, for: .touchUpInside)
        Task {
            do {
                for index in 0..<50 {
                    let source = "https://example.test/gesture-history/\(index)"
                    let fetcher = FeedFetcher(transport: DownloadLogGestureTransport(index: index))
                    guard case .updated(let fetched) = try await fetcher.fetch(.init(source: source)) else { preconditionFailure("Missing fixture feed") }
                    let feed = try await library.insert(fetched)
                    try await library.recordFailure(.notFound(status: 404), feedID: feed.id, date: Date().addingTimeInterval(Double(-index)))
                }
                open.isEnabled = true
            } catch { preconditionFailure("Fixture setup: \(error)") }
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        open.frame = CGRect(x: view.safeAreaInsets.left + 20, y: view.safeAreaInsets.top + 20, width: 180, height: 48)
    }
}
private struct DownloadLogGestureTransport: FeedHTTPTransport {
    let index: Int
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
        .init(url: request.url!, status: 200, body: Data("<rss version=\"2.0\"><channel><title>History episode \(index)</title></channel></rss>".utf8))
    }
}
#endif
