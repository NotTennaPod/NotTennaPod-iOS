import Foundation

public enum EpisodeNotificationDestination: Equatable, Sendable {
    case feed(Int64), inbox
}

/// Content independent of OS rendering. Only the summary may alert, and only
/// when its stable identifier is absent from both pending and delivered items.
public struct EpisodeNotificationPublication: Equatable, Sendable {
    public static let group = "de.danoeh.antennapod.EPISODES"
    public static let summaryID = "new-episodes.summary"
    public static func feedID(_ id: Int64) -> String { "new-episodes.feed.\(id)" }
    public let identifier: String
    public let title: String
    public let body: String
    public let destination: EpisodeNotificationDestination
    public let alerts: Bool
    public let artwork: Data?

    public init(identifier: String, title: String, body: String, destination: EpisodeNotificationDestination,
                alerts: Bool, artwork: Data? = nil) {
        self.identifier = identifier; self.title = title; self.body = body
        self.destination = destination; self.alerts = alerts; self.artwork = artwork
    }
}

@MainActor public protocol EpisodeNotificationPublishing: Sendable {
    func isAuthorized() async -> Bool
    func existingIdentifiers() async -> Set<String>
    /// Acceptance is the publication boundary. A later request replacement does
    /// not retract a notification that was valid when submitted to the OS.
    func publish(_ publication: EpisodeNotificationPublication) async throws
}

@MainActor
public final class EpisodeNotificationDelivery {
    public struct Text: Sendable {
        public var title: @Sendable (Int) -> String
        public var message: @Sendable (Int, String) -> String
        public var summary: String
        public init(title: @escaping @Sendable (Int) -> String,
                    message: @escaping @Sendable (Int, String) -> String, summary: String) {
            self.title = title; self.message = message; self.summary = summary
        }
    }
    private let store: FeedLibraryStore
    private let publisher: any EpisodeNotificationPublishing
    private let text: Text
    private let artwork: @Sendable (NewEpisodeNotification) async throws -> Data?
    private var baselines: [Int64: NewEpisodeNotificationBaseline] = [:]
    private var tail: Task<Void, Never>?

    public init(store: FeedLibraryStore, publisher: any EpisodeNotificationPublishing, text: Text,
                artwork: @escaping @Sendable (NewEpisodeNotification) async throws -> Data?) {
        self.store = store; self.publisher = publisher; self.text = text; self.artwork = artwork
    }
    public func prepare(requestID: UUID) async throws {
        try await serial {
            // Retry committed work before taking the source's new-attempt counts.
            for pending in try await self.store.pendingEpisodeNotifications(requestID: requestID) {
                try await self.deliver(pending)
            }
            let snapshot = try await self.store.beginEpisodeNotificationAttempt(requestID: requestID)
            try await self.requireCurrent(requestID)
            guard let request = try await self.store.refreshRequest(id: requestID) else { throw CancellationError() }
            self.baselines[request.slot] = snapshot
        }
    }
    public func refreshed(_ feed: LibraryFeed, requestID: UUID) async throws {
        try await serial {
            try await self.requireCurrent(requestID)
            guard let baseline = self.baselines.values.first(where: { $0.requestID == requestID }) else { throw CancellationError() }
            guard let pending = try await self.store.stageEpisodeNotification(feed, baseline: baseline) else { return }
            try await self.deliver(pending)
        }
    }
    private func deliver(_ pending: PendingEpisodeNotification) async throws {
        guard try await store.pendingEpisodeNotification(pending) else { return }
        if !pending.childPublished {
            guard let candidate = try await store.episodeNotificationCandidate(pending) else {
                try await store.acknowledgeEpisodeNotification(pending); return
            }
            guard await publisher.isAuthorized() else {
                try await store.acknowledgeEpisodeNotification(pending); return
            }
            guard try await store.pendingEpisodeNotification(pending) else { return }
            let image: Data?
            do { image = try await artwork(candidate) }
            catch is CancellationError { throw CancellationError() }
            catch { image = nil } // Source still posts when icon loading fails.
            guard try await store.pendingEpisodeNotification(pending) else { return }
            let child = EpisodeNotificationPublication(identifier: EpisodeNotificationPublication.feedID(candidate.feedID),
                title: text.title(candidate.count), message: text.message(candidate.count, candidate.title ?? "null"),
                feedID: candidate.feedID, artwork: image)
            // Permission can change while artwork is outstanding; never request it here.
            guard await publisher.isAuthorized() else {
                try await store.acknowledgeEpisodeNotification(pending); return
            }
            guard try await store.pendingEpisodeNotification(pending) else { return }
            try await publisher.publish(child)
            // A crash before this write may repeat the quiet child, never an alert.
            guard try await store.markEpisodeNotificationChildPublished(pending) else { return }
        }
        let existing = await publisher.existingIdentifiers()
        guard try await store.pendingEpisodeNotification(pending) else { return }
        guard await publisher.isAuthorized() else {
            try await store.acknowledgeEpisodeNotification(pending); return
        }
        guard try await store.pendingEpisodeNotification(pending) else { return }
        try await publisher.publish(.init(identifier: EpisodeNotificationPublication.summaryID,
            title: text.summary, body: "", destination: .inbox,
            alerts: !existing.contains(EpisodeNotificationPublication.summaryID)))
        try await store.acknowledgeEpisodeNotification(pending)
    }
    /// A server library's new-episode notifications (PROTOCOL §9.9): once per release of its discovery
    /// ledger, whoever found it (this phone's refresh, another device, the server), for podcasts whose notifications are
    /// on, as AntennaPod presents them (a quiet per-podcast notification, the summary alerting once). A podcast whose
    /// notifications are off, or a phone that does not allow them, marks its releases notified: nothing is shown later.
    /// A standalone library has no ledger and does nothing here.
    public func deliverServerReleases(lifetime: ServerReleaseLifetime? = nil) async throws {
        try await serial {
            // Nothing is published once the library's sync stopped.
            @MainActor func live() throws {
                try Task.checkCancellation()
                if lifetime?.isOver == true { throw CancellationError() }
            }
            for release in try await self.store.serverReleaseNotifications() {
                try live()
                try Task.checkCancellation()
                guard release.count > 0, await self.publisher.isAuthorized() else {
                    try await self.store.markServerReleasesNotified(release.keys); continue
                }
                let image: Data?
                do { image = try await self.artwork(NewEpisodeNotification(feedID: release.feedID, title: release.title, imageURL: release.imageURL,
                                                                           count: release.count)) }
                catch is CancellationError { throw CancellationError() }
                catch { image = nil }
                guard await self.publisher.isAuthorized() else { try await self.store.markServerReleasesNotified(release.keys); continue }
                // What changed while the artwork loaded decides: a cancelled delivery publishes
                // nothing; the podcast's releases are read again, and only what is eligible now is published and marked.
                try live()
                guard let current = try await self.store.serverReleaseNotifications().first(where: { $0.feedID == release.feedID }) else { continue }
                guard current.count > 0 else { try await self.store.markServerReleasesNotified(current.keys); continue }
                try live()
                // The same identifiers as a refresh's: a repeat after a crash replaces the quiet child, never alerts again.
                try await self.publisher.publish(EpisodeNotificationPublication(identifier: EpisodeNotificationPublication.feedID(current.feedID),
                    title: self.text.title(current.count), message: self.text.message(current.count, current.title ?? "null"),
                    feedID: current.feedID, artwork: image))
                let existing = await self.publisher.existingIdentifiers()
                try live()
                try await self.publisher.publish(.init(identifier: EpisodeNotificationPublication.summaryID, title: self.text.summary, body: "",
                    destination: .inbox, alerts: !existing.contains(EpisodeNotificationPublication.summaryID)))
                try await self.store.markServerReleasesNotified(current.keys)
            }
        }
    }

    private func requireCurrent(_ requestID: UUID) async throws {
        try Task.checkCancellation()
        guard try await store.refreshRequest(id: requestID) != nil else { throw CancellationError() }
        try Task.checkCancellation()
    }
    private func serial(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = tail
        let task = Task { await previous?.value; try Task.checkCancellation(); try await operation() }
        tail = Task { _ = try? await task.value }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

private extension EpisodeNotificationPublication {
    init(identifier: String, title: String, message: String, feedID: Int64, artwork: Data?) {
        self.init(identifier: identifier, title: title, body: message, destination: .feed(feedID), alerts: false, artwork: artwork)
    }
}

/// Whether an open server library's release notifications may still be published: over once its sync stops.
@MainActor public final class ServerReleaseLifetime {
    public private(set) var isOver = false
    public init() {}
    func end() { isOver = true }
}

/// The one owner of an open server library's deliveries of owed new-episode notifications (PROTOCOL §9.9): one
/// delivery at a time, wakes during it (launch, foreground, exchanges, releases) coalesced into one more; `stop()`
/// ends the library's lifetime, so nothing more is published, cancels the delivery and waits for it, and later wakes
/// do nothing.
@MainActor public final class ServerReleaseDeliveryOwner {
    private let delivery: EpisodeNotificationDelivery
    private let failed: @MainActor (any Error) -> Void
    private let lifetime = ServerReleaseLifetime()
    private var running: Task<Void, Never>?
    private var again = false

    public init(delivery: EpisodeNotificationDelivery, failed: @escaping @MainActor (any Error) -> Void) {
        self.delivery = delivery; self.failed = failed
    }

    public var isStopped: Bool { lifetime.isOver }

    public func wake() {
        guard !lifetime.isOver else { return }
        guard running == nil else { again = true; return }
        running = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        repeat {
            again = false
            do { try await delivery.deliverServerReleases(lifetime: lifetime) }
            catch is CancellationError { break }
            catch { failed(error) }
        } while again && !lifetime.isOver && !Task.isCancelled
        running = nil
    }

    /// Waits for the running delivery, if any (and those its wakes asked for).
    public func settled() async { while let task = running { await task.value } }

    public func stop() async {
        lifetime.end()
        again = false
        running?.cancel()
        await settled()
    }
}

