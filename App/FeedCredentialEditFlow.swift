import UIKit
import NotTennaPodCore

/// Feed settings save credentials before invoking the application-owned forced
/// refresh. Confirmed work survives dismissal and navigation away from settings.
@MainActor final class FeedCredentialEditFlow {
    private let read: () async throws -> FeedCredentials?
    private let save: (FeedCredentials) async throws -> Void
    private let requestRefresh: () async throws -> Void
    private let failed: (Error) -> Void
    private(set) var isBusy = false

    init(read: @escaping () async throws -> FeedCredentials?,
         save: @escaping (FeedCredentials) async throws -> Void,
         requestRefresh: @escaping () async throws -> Void, failed: @escaping (Error) -> Void) {
        self.read = read; self.save = save; self.requestRefresh = requestRefresh; self.failed = failed
    }
    convenience init(authentication: FeedAuthentication, feedID: Int64,
                     requestRefresh: @escaping () async throws -> FeedRefreshRequest,
                     failed: @escaping (Error) -> Void) {
        self.init(read: { try await authentication.credentials(feedID: feedID) },
                  save: { try await authentication.save($0, feedID: feedID) },
                  requestRefresh: { _ = try await requestRefresh() }, failed: failed)
    }

    func show(from presenter: UIViewController, canPresent: @escaping () -> Bool = { true }) {
        guard !isBusy, presenter.presentedViewController == nil else { return }
        isBusy = true
        Task { [weak presenter] in
            do {
                let credentials = try await read()
                isBusy = false
                guard let presenter, presenter.viewIfLoaded?.window != nil,
                      presenter.presentedViewController == nil, canPresent() else { return }
                let dialog = FeedAuthenticationController.make(purpose: .settings, credentials: credentials,
                    confirm: { self.commit($0) }, cancel: {})
                presenter.present(dialog, animated: true)
            } catch { isBusy = false; failed(error) }
        }
    }

    private func commit(_ credentials: FeedCredentials) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            do {
                try await save(credentials)
                try await requestRefresh()
                isBusy = false
            } catch { isBusy = false; failed(error) }
        }
    }
}
