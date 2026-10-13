import Foundation

/// One subscription phase. Login, refresh waiting, episode exchange and scheduling
/// belong to the worker. Deletions use the app's durable teardown coordinator.
public struct SynchronizationSubscriptions: Sendable {
    private let store: FeedLibraryStore
    private let deletion: FeedDeletionCoordinator
    private let redirect: @Sendable (String) async throws -> String?

    public init(store: FeedLibraryStore, deletion: FeedDeletionCoordinator,
                redirects: SynchronizationRedirectChecker) {
        self.init(store: store, deletion: deletion, redirect: { try await redirects.destination(for: $0) })
    }

    init(store: FeedLibraryStore, deletion: FeedDeletionCoordinator,
         redirect: @escaping @Sendable (String) async throws -> String?) {
        self.store = store; self.deletion = deletion; self.redirect = redirect
    }

    public func run(provider: any SynchronizationProvider, epoch: UUID) async throws {
        let initial = try await store.synchronizationSubscriptionSnapshot(epoch: epoch)
        let changes = try await provider.subscriptionChanges(since: initial.timestamp)
        try Task.checkCancellation()
        for source in changes.added where source.hasPrefix("http") {
            guard try await store.acceptsSynchronizationSubscription(source, redirected: nil, epoch: epoch) else { continue }
            let destination = try await redirect(source)
            _ = try await store.addSynchronizationSubscription(source, redirected: destination, epoch: epoch)
        }
        for source in changes.removed {
            try Task.checkCancellation()
            try await deletion.deleteSynchronizationSubscription(source: source, epoch: epoch).value
        }
        let upload = try await store.synchronizationSubscriptionUpload(epoch: epoch, initial: initial, remote: changes)
        var timestamp = changes.timestamp
        if !upload.added.isEmpty || !upload.removed.isEmpty {
            do {
                timestamp = try await provider.uploadSubscriptions(added: upload.added, removed: upload.removed).timestamp
            } catch {
                // Preserve failed work. Original only prunes legacy conflicts for
                // service failures; cancellation must not mutate the saved queue.
                if error is SynchronizationError || (error is URLError && (error as? URLError)?.code != .cancelled) {
                    try await store.removeLegacySynchronizationConflicts(epoch: epoch, ids: upload.ids,
                                                                       local: initial.local)
                }
                throw error
            }
        }
        try await store.acknowledgeSynchronization(epoch: epoch, phase: .subscriptions, ids: upload.ids, timestamp: timestamp)
    }
}

/// RedirectChecker follows HEAD to completion and uses only the first hop. A
/// temporary exact HTTP -> HTTPS upgrade is also treated as permanent by source.
/// Like the source's shared AntennapodHttpClient, the app passes the proxied
/// transport and its User-Agent.
public struct SynchronizationRedirectChecker: Sendable {
    private let transport: any FeedHTTPTransport
    private let userAgent: String
    public init(transport: any FeedHTTPTransport = URLSessionFeedTransport(), userAgent: String = HTTPUserAgent.unversioned) {
        self.transport = transport; self.userAgent = userAgent
    }

    public func destination(for source: String) async throws -> String? {
        do {
            let transport = try transport.requestScope()
            var url = try FeedAddress.requestURL(source)
            var candidate: String?
            for hop in 0...20 {
                try Task.checkCancellation()
                guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
                components.user = nil; components.password = nil; components.fragment = nil
                guard let clean = components.url else { return nil }
                var request = URLRequest(url: clean, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                request.httpMethod = "HEAD"
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                let response = try await transport.send(request)
                try Task.checkCancellation()
                guard [300, 301, 302, 303, 307, 308].contains(response.status),
                      let location = response.header("Location"),
                      let next = URL(string: location, relativeTo: response.url)?.absoluteURL,
                      ["http", "https"].contains(next.scheme?.lowercased() ?? "") else { return candidate }
                if hop == 0, [301, 308].contains(response.status)
                    || next.absoluteString == response.url.absoluteString.replacingOccurrences(of: "http://", with: "https://") {
                    candidate = next.absoluteString
                }
                url = next
            }
            return nil // Source's failed redirect chain yields no permanent target.
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            return nil // HEAD I/O failure does not prevent adding the original URL.
        }
    }
}

struct SynchronizationSubscriptionSnapshot: Sendable {
    let timestamp: Int64
    let local: [String]
    let queuedIDs: Set<Int64>
}

struct SynchronizationSubscriptionUpload: Sendable {
    let ids: [Int64]
    let added, removed: [String]
}

extension FeedLibraryStore {
    func synchronizationSubscriptionSnapshot(epoch: UUID) throws -> SynchronizationSubscriptionSnapshot {
        try Task.checkCancellation()
        return try database.transaction(write: false) {
            let state = try requireSynchronization(epoch)
            return .init(timestamp: state.subscriptionTimestamp,
                         local: try loadFeeds().filter { $0.subscriptionState == .subscribed && !$0.source.isLocalFeedSource }
                            .sorted { $0.id < $1.id }.map(\.source),
                         queuedIDs: Set(try synchronizationQueue().map(\.id)))
        }
    }

    func acceptsSynchronizationSubscription(_ source: String, redirected: String?, epoch: UUID) throws -> Bool {
        try Task.checkCancellation()
        let state = try requireSynchronization(epoch)
        let local = try feeds().filter { $0.subscriptionState == .subscribed && !$0.source.isLocalFeedSource }.map(\.source)
        var removed = try synchronizationQueue().compactMap { if case .removed(let url) = $0.value { url } else { nil } }
        // A committed deletion is already a local removal, even if file teardown
        // is still running and has not queued its final subscription effect yet.
        removed += try pendingEffects(kinds: ["deleteFeed"]).compactMap {
            guard case .deleteFeed(let deletion) = $0.effect.kind, deletion.synchronize else { return nil }
            let sameAccount = deletion.synchronizationAccount.map { $0.id == state.accountID } ?? true
            return sameAccount ? deletion.source : nil
        }
        return [source, redirected].compactMap { $0 }.allSatisfy { candidate in
            !local.contains { FeedAddress.equivalent($0, candidate) } && !containsExact(removed, candidate)
        }
    }

    @discardableResult
    func addSynchronizationSubscription(_ source: String, redirected: String?, epoch: UUID) throws -> LibraryFeed? {
        // Actor isolation keeps eligibility/epoch checks and insert adjacent;
        // insert owns the atomic feed + outbox transaction.
        guard source.hasPrefix("http"), try acceptsSynchronizationSubscription(source, redirected: redirected, epoch: epoch) else { return nil }
        var options = FeedRefreshOptions()
        options.refreshAttempt = Date(timeIntervalSince1970: 0)
        return try insert(.init(feed: .init(format: .rss, title: "Unknown podcast", episodes: []), source: source,
                                responseURL: URL(string: source) ?? URL(string: "about:blank")!, validator: nil, permanentRedirectURL: nil),
                          options: options)
    }

    @discardableResult
    func requestSynchronizationFeedDeletion(source: String, epoch: UUID) throws -> Bool {
        try Task.checkCancellation()
        _ = try requireSynchronization(epoch)
        let added = try synchronizationQueue().compactMap { if case .added(let url) = $0.value { url } else { nil } }
        guard !containsExact(added, source),
              let feed = try feeds().filter({ $0.source.utf16.elementsEqual(source.utf16) }).max(by: { $0.id < $1.id }) else { return false }
        return try requestFeedDeletion(feedID: feed.id)
    }

    func synchronizationSubscriptionUpload(epoch: UUID, initial: SynchronizationSubscriptionSnapshot,
                                            remote: SynchronizationSubscriptionChanges) throws -> SynchronizationSubscriptionUpload {
        try Task.checkCancellation()
        return try database.transaction(write: false) {
            _ = try requireSynchronization(epoch)
            let queue = try synchronizationQueue()
            var ids: [Int64] = [], added = initial.timestamp == 0 ? initial.local : [], removed: [String] = []
            for change in queue {
                switch change.value {
                case .added(let url):
                    // First sync sends the pre-download subscription snapshot.
                    // A later local addition must survive for the following pass.
                    if initial.timestamp == 0 && !initial.queuedIDs.contains(change.id)
                        && !containsExact(initial.local, url) && !containsExact(remote.added, url) { continue }
                    if initial.timestamp != 0 { added.append(url) }
                    ids.append(change.id)
                case .removed(let url): removed.append(url); ids.append(change.id)
                case .episode: break
                }
            }
            added.removeAll { containsExact(remote.added, $0) }
            removed.removeAll { containsExact(remote.removed, $0) }
            return .init(ids: ids, added: added, removed: removed)
        }
    }

    func removeLegacySynchronizationConflicts(epoch: UUID, ids: [Int64], local: [String]) throws {
        try Task.checkCancellation()
        try database.transaction {
            _ = try requireSynchronization(epoch)
            let selected = Set(ids), queue = try synchronizationQueue()
            let removed = queue.compactMap { change -> String? in
                guard selected.contains(change.id), case .removed(let url) = change.value, !containsExact(local, url) else { return nil }
                return url
            }
            for change in queue where selected.contains(change.id) {
                let discard: Bool
                switch change.value {
                case .removed(let url): discard = containsExact(local, url)
                case .added(let url): discard = containsExact(removed, url)
                case .episode: discard = false
                }
                if discard { try database.execute("DELETE FROM synchronization_outbox WHERE id = ?", [.integer(change.id)]) }
            }
            try Task.checkCancellation()
        }
    }
}

private func containsExact(_ values: [String], _ value: String) -> Bool {
    values.contains { $0.utf16.elementsEqual(value.utf16) }
}
