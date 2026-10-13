import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import UserNotifications
@testable import NotTennaPodCore

@MainActor @Suite(.timeLimit(.minutes(1)))
struct EpisodeNotificationDeliveryTests {
    final class Publisher: EpisodeNotificationPublishing {
        var authorized = true
        var existing = Set<String>()
        var posts: [EpisodeNotificationPublication] = []
        var fail = Set<String>()
        var beforeAuthorization: (() async -> Void)?
        func isAuthorized() async -> Bool { await beforeAuthorization?(); return authorized }
        func existingIdentifiers() async -> Set<String> { existing }
        func publish(_ publication: EpisodeNotificationPublication) async throws {
            if fail.contains(publication.identifier) { throw CocoaError(.fileWriteUnknown) }
            posts.append(publication); existing.insert(publication.identifier)
        }
    }
    actor Gate {
        var waiter: CheckedContinuation<Data?, Never>?
        var entered: Bool { waiter != nil }
        func hold() async -> Data? { await withCheckedContinuation { waiter = $0 } }
        func release() { waiter?.resume(returning: Data([1])); waiter = nil }
    }
    private let text = EpisodeNotificationDelivery.Text(title: { $0 == 1 ? "New episode" : "New episodes" },
        message: { "\($1): \($0)" }, summary: "Your subscriptions have new episodes.")
    private func run(_ body: (FeedLibraryStore, LibraryFeed, FeedRefreshRequest, Publisher) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotificationDelivery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let fetched = FetchedFeed(feed: .init(format: .rss, title: "Podcast", episodes: [ParsedEpisode(identifier: "one")]),
            source: "https://example.org/feed", responseURL: URL(string: "https://example.org/feed")!, validator: nil, permanentRedirectURL: nil)
        let inserted = try await store.insert(fetched)
        try await store.updatePreferences(feedID: inserted.id) { $0.showEpisodeNotification = true }
        let feed = try #require(try await store.feed(id: inserted.id))
        let request = FeedRefreshRequest(feedID: feed.id, enqueuedAt: Date())
        try await store.enqueueManualRefresh(request)
        do { try await body(store, feed, request, Publisher()); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    private func prepare(_ delivery: EpisodeNotificationDelivery, _ store: FeedLibraryStore,
                         _ feed: LibraryFeed, _ request: FeedRefreshRequest) async throws {
        let id = try #require(feed.episodes.first?.id)
        try await store.updateEpisode(id: id) { $0.userState.playState = .unplayed }
        try await delivery.prepare(requestID: request.id)
        try await store.updateEpisode(id: id) { $0.userState.playState = .new }
    }
    @Test func postsQuietChildrenAndOnlyAlertsForAnAbsentSummary() async throws {
        try await run { store, feed, request, publisher in
            let delivery = EpisodeNotificationDelivery(store: store, publisher: publisher, text: text, artwork: { _ in Data([7]) })
            try await prepare(delivery, store, feed, request)
            try await delivery.refreshed(feed, requestID: request.id)
            try await delivery.refreshed(feed, requestID: request.id)
            #expect(publisher.posts.map(\.alerts) == [false, true, false, false])
            #expect(publisher.posts[0].destination == .feed(feed.id))
            #expect(publisher.posts[0].body == "Podcast: 1" && publisher.posts[0].artwork == Data([7]))
            #expect(publisher.posts[1].destination == .inbox)
            publisher.existing.remove(EpisodeNotificationPublication.summaryID)
            try await delivery.refreshed(feed, requestID: request.id)
            #expect(publisher.posts.last?.alerts == true)
        }
    }
    @Test func permissionDenialNeverLoadsArtworkOrPosts() async throws {
        try await run { store, feed, request, publisher in
            publisher.authorized = false
            let delivery = EpisodeNotificationDelivery(store: store, publisher: publisher, text: text, artwork: { _ in
                Issue.record("Artwork should not load without permission"); return nil
            })
            try await prepare(delivery, store, feed, request)
            try await delivery.refreshed(feed, requestID: request.id)
            #expect(publisher.posts.isEmpty)
        }
    }
    @Test func replacementDuringArtworkRejectsLateCompletion() async throws {
        try await run { store, feed, request, publisher in
            let gate = Gate()
            let delivery = EpisodeNotificationDelivery(store: store, publisher: publisher, text: text, artwork: { _ in await gate.hold() })
            try await prepare(delivery, store, feed, request)
            let task = Task { try await delivery.refreshed(feed, requestID: request.id) }
            while await !gate.entered { await Task.yield() }
            try await store.enqueueManualRefresh(.init(feedID: nil, enqueuedAt: Date()))
            await gate.release()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(publisher.posts.isEmpty)
        }
    }
    @Test func permissionRevokedDuringArtworkSuppressesDelivery() async throws {
        try await run { store, feed, request, publisher in
            let gate = Gate()
            let delivery = EpisodeNotificationDelivery(store: store, publisher: publisher, text: text, artwork: { _ in await gate.hold() })
            try await prepare(delivery, store, feed, request)
            let task = Task { try await delivery.refreshed(feed, requestID: request.id) }
            while await !gate.entered { await Task.yield() }
            publisher.authorized = false; await gate.release(); try await task.value
            #expect(publisher.posts.isEmpty)
        }
    }
    @Test func failedArtworkStillPostsAndFailedSummaryCanRetryQuietly() async throws {
        try await run { store, feed, request, publisher in
            let delivery = EpisodeNotificationDelivery(store: store, publisher: publisher, text: text, artwork: { _ in throw CocoaError(.fileReadUnknown) })
            try await prepare(delivery, store, feed, request)
            publisher.fail = [EpisodeNotificationPublication.summaryID]
            await #expect(throws: (any Error).self) { try await delivery.refreshed(feed, requestID: request.id) }
            #expect(publisher.posts.count == 1 && publisher.posts[0].artwork == nil)
            publisher.fail = []
            try await delivery.refreshed(feed, requestID: request.id)
            // Recover only the failed summary; the accepted child is durably complete.
            #expect(publisher.posts.map(\.alerts) == [false, true])
        }
    }
    @Test func cancellingBlockedPublicationDoesNotPublishAndNextCommandRecovers() async throws {
        try await run { store, feed, request, publisher in
            let gate = Gate()
            let delivery = EpisodeNotificationDelivery(store: store, publisher: publisher, text: text, artwork: { _ in await gate.hold() })
            try await prepare(delivery, store, feed, request)
            let cancelled = Task { try await delivery.refreshed(feed, requestID: request.id) }
            while await !gate.entered { await Task.yield() }
            cancelled.cancel(); await gate.release()
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            #expect(publisher.posts.isEmpty)
            let next = Task { try await delivery.refreshed(feed, requestID: request.id) }
            while await !gate.entered { await Task.yield() }
            await gate.release(); try await next.value
            #expect(publisher.posts.count == 2 && publisher.posts[1].alerts)
        }
    }
    @Test func concurrentCompletionsShareOneSummaryAlert() async throws {
        try await run { store, feed, request, publisher in
            let delivery = EpisodeNotificationDelivery(store: store, publisher: publisher, text: text, artwork: { _ in nil })
            try await prepare(delivery, store, feed, request)
            async let first: Void = delivery.refreshed(feed, requestID: request.id)
            async let second: Void = delivery.refreshed(feed, requestID: request.id)
            _ = try await (first, second)
            #expect(publisher.posts.filter(\.alerts).count == 1)
            #expect(publisher.posts.count == 4)
        }
    }
    @Test func recreatedRecipientRecoversFailedChildBeforeFreshBaseline() async throws {
        try await run { store, feed, request, publisher in
            let original = EpisodeNotificationDelivery(store: store, publisher: publisher, text: text, artwork: { _ in nil })
            try await prepare(original, store, feed, request)
            publisher.fail = [EpisodeNotificationPublication.feedID(feed.id)]
            await #expect(throws: (any Error).self) { try await original.refreshed(feed, requestID: request.id) }
            #expect(try await store.pendingEpisodeNotifications(requestID: request.id).count == 1)
            publisher.fail = []
            let recovered = EpisodeNotificationDelivery(store: store, publisher: publisher, text: text, artwork: { _ in nil })
            try await recovered.prepare(requestID: request.id)
            #expect(publisher.posts.map(\.destination) == [.feed(feed.id), .inbox])
            #expect(publisher.posts.first?.body == "Podcast: 1")
            #expect(try await store.pendingEpisodeNotifications(requestID: request.id).isEmpty)
            // New worker attempt still captures fresh counts: no repeat without an increase.
            try await recovered.refreshed(feed, requestID: request.id)
            #expect(publisher.posts.count == 2)
        }
    }
    @Test func recreatedRecipientRetriesOnlyFailedSummaryEvenAfterEpisodeRead() async throws {
        try await run { store, feed, request, publisher in
            let delivery = EpisodeNotificationDelivery(store: store, publisher: publisher, text: text, artwork: { _ in nil })
            try await prepare(delivery, store, feed, request)
            publisher.fail = [EpisodeNotificationPublication.summaryID]
            await #expect(throws: (any Error).self) { try await delivery.refreshed(feed, requestID: request.id) }
            #expect(try await store.pendingEpisodeNotifications(requestID: request.id).first?.childPublished == true)
            try await store.updateEpisode(id: feed.episodes[0].id) { $0.userState.playState = .played }
            publisher.fail = []
            let recovered = EpisodeNotificationDelivery(store: store, publisher: publisher, text: text, artwork: { _ in
                Issue.record("Accepted child must not reload artwork"); return nil
            })
            try await recovered.prepare(requestID: request.id)
            #expect(publisher.posts.map(\.destination) == [.feed(feed.id), .inbox])
            #expect(try await store.pendingEpisodeNotifications(requestID: request.id).isEmpty)
        }
    }
    @Test func deniedPermissionAcknowledgesWorkAndDoesNotReplayAfterEnabling() async throws {
        try await run { store, feed, request, publisher in
            let delivery = EpisodeNotificationDelivery(store: store, publisher: publisher, text: text, artwork: { _ in nil })
            try await prepare(delivery, store, feed, request)
            publisher.authorized = false
            try await delivery.refreshed(feed, requestID: request.id)
            #expect(try await store.pendingEpisodeNotifications(requestID: request.id).isEmpty)
            publisher.authorized = true
            try await delivery.prepare(requestID: request.id)
            try await delivery.refreshed(feed, requestID: request.id)
            #expect(publisher.posts.isEmpty)
        }
    }
    @Test func deletingFeedWhileArtworkLoadsPreventsStaleFeedAndSummary() async throws {
        try await run { store, feed, request, publisher in
            let gate = Gate()
            let delivery = EpisodeNotificationDelivery(store: store, publisher: publisher, text: text, artwork: { _ in await gate.hold() })
            try await prepare(delivery, store, feed, request)
            let task = Task { try await delivery.refreshed(feed, requestID: request.id) }
            while await !gate.entered { await Task.yield() }
            _ = try await store.requestFeedDeletion(feedID: feed.id)
            await gate.release(); try await task.value
            #expect(publisher.posts.isEmpty)
            #expect(try await store.pendingEpisodeNotifications(requestID: request.id).isEmpty)
        }
    }

    /// Stands in for the system center: the adapter's own work (what it posts, what it reads back, permission)
    /// is checked without the system permission prompt. How iOS draws the group is Apple's behaviour and needs a check
    /// on a real device.
    final class RecordingCenter: EpisodeNotificationCenter {
        var status = UNAuthorizationStatus.authorized
        var pending: [String] = []
        var delivered: [String] = []
        var posted: [UNNotificationRequest] = []
        var attachmentFilesPresent: [Bool] = []
        func authorizationStatus() async -> UNAuthorizationStatus { status }
        func pendingIdentifiers() async -> [String] { pending }
        func deliveredIdentifiers() async -> [String] { delivered }
        func post(_ request: UNNotificationRequest) async throws {
            // The system copies the attachment file when it accepts the request; it must exist at that moment.
            attachmentFilesPresent += request.content.attachments.map { FileManager.default.fileExists(atPath: $0.url.path) }
            posted.append(request); pending.append(request.identifier)
        }
    }
    private static func png() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func nativeAdapterPostsGroupedFeedAndSummaryNotificationsThatRouteToFeedAndInbox() async throws {
        let artwork = try Self.png()
        try await run { store, feed, request, _ in
            let center = RecordingCenter()
            let delivery = EpisodeNotificationDelivery(store: store, publisher: NativeEpisodeNotifications(center: center),
                text: text, artwork: { _ in artwork })
            try await prepare(delivery, store, feed, request)
            try await delivery.refreshed(feed, requestID: request.id)
            // One notification for the podcast and one summary, grouped together like Android's EPISODES group.
            #expect(center.posted.map(\.identifier) == [EpisodeNotificationPublication.feedID(feed.id), EpisodeNotificationPublication.summaryID])
            #expect(center.posted.allSatisfy { $0.content.threadIdentifier == EpisodeNotificationPublication.group })
            let child = center.posted[0].content, summary = center.posted[1].content
            #expect(child.title == "New episode" && child.body == "Podcast: 1")
            #expect(child.attachments.count == 1 && center.attachmentFilesPresent == [true], "The podcast cover is shown")
            #expect(child.sound == nil && summary.sound != nil, "Only the summary alerts")
            #expect(summary.title == "Your subscriptions have new episodes.")
            // Tapping each one opens the podcast or the Inbox.
            let routes = center.posted.map { NativeEpisodeNotifications.destination(identifier: $0.identifier,
                category: $0.content.categoryIdentifier, userInfo: $0.content.userInfo) }
            #expect(routes == [.feed(feed.id), .inbox])

            // A summary still shown in Notification Center is not alerted again.
            center.pending = []; center.delivered = [EpisodeNotificationPublication.summaryID]
            try await delivery.refreshed(feed, requestID: request.id)
            #expect(center.posted.count == 4 && center.posted[3].content.sound == nil)

            // Without permission nothing is posted.
            center.status = .denied
            try await delivery.refreshed(feed, requestID: request.id)
            #expect(center.posted.count == 4)
        }
    }
}
