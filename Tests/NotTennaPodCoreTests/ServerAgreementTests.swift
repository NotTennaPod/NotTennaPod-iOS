import Foundation
import Testing
@testable import NotTennaPodCore

/// Single-device agreement tests against the real server: scripted actions on a phone
/// server library, pushed; the server's records, read by a second installation's attach snapshot, must show
/// what the phone's own local effects show. Every receipt must be accepted (never `rejected`).
@MainActor @Suite(.serialized) struct ServerAgreementTests {
    nonisolated static func rss(title: String, prefix: String, count: Int) -> String {
        let items = (1...count).map { number in
            let date = Date(timeIntervalSince1970: 1_760_000_000 + Double(number) * 86_400)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            return "<item><title>\(title) \(number)</title><guid>\(prefix)-\(number)</guid><pubDate>\(formatter.string(from: date))</pubDate>"
                + "<enclosure url=\"https://media.example/\(prefix)-\(number).mp3\" length=\"1000\" type=\"audio/mpeg\"/></item>"
        }.joined()
        return "<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>\(title)</title><link>https://example.com/</link>\(items)</channel></rss>"
    }

    static func fetched(_ url: String, title: String, prefix: String, count: Int) -> FetchedFeed {
        let items = (1...count).map { number in
            ParsedEpisode(identifier: "\(prefix)-\(number)", title: "\(title) \(number)",
                          publicationDate: Date(timeIntervalSince1970: 1_760_000_000 + Double(number) * 86_400),
                          media: ParsedMedia(url: "https://media.example/\(prefix)-\(number).mp3", size: 1_000, durationMilliseconds: 0))
        }
        return FetchedFeed(feed: ParsedFeed(format: .rss, title: title, episodes: items), source: url, responseURL: URL(string: url)!,
                           validator: nil, permanentRedirectURL: nil)
    }

    final class World {
        let server: NTPServerProcess
        let feeds: LoopbackHTTPServer
        let phone: AgreementPhone
        init(server: NTPServerProcess, feeds: LoopbackHTTPServer, phone: AgreementPhone) { self.server = server; self.feeds = feeds; self.phone = phone }
        var store: FeedLibraryStore { phone.fixture.store }
        var fixture: ServerLibraryFixture { phone.fixture }
        func url(_ path: String) -> String { "http://127.0.0.1:\(feeds.url.port!)/\(path)" }
    }

    private func world(_ body: (World) async throws -> Void) async throws {
        let server = try await NTPServerProcess.start()
        let feeds = try await LoopbackHTTPServer.start { request in
            let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
            switch path {
            case "/one.xml", "/one-moved.xml": return .init(headers: ["Content-Type": "application/rss+xml"], body: Data(Self.rss(title: "One", prefix: "one", count: 5).utf8))
            case "/two.xml": return .init(headers: ["Content-Type": "application/rss+xml"], body: Data(Self.rss(title: "Two", prefix: "two", count: 3).utf8))
            case "/three.xml": return .init(headers: ["Content-Type": "application/rss+xml"], body: Data(Self.rss(title: "Three", prefix: "three", count: 3).utf8))
            default: return .init(status: 404, body: Data())
            }
        }
        do {
            try await NTPInstallation.setUp(server)
            let installation = try await NTPInstallation.signIn(server)
            let fixture = try await ServerLibraryFixture(accountID: installation.accountID, namespace: installation.namespace, installID: installation.installID)
            let head = try await installation.attachSnapshot().head
            let world = World(server: server, feeds: feeds, phone: AgreementPhone(fixture: fixture, installation: installation, cursor: head, vault: fixture.vault))
            try await body(world)
            await fixture.close()
        } catch { feeds.stop(); server.stop(); throw error }
        feeds.stop(); server.stop()
    }

    /// The server's records, read by another installation of the account.
    private func serverRecords(_ world: World) async throws -> [String: ContractJSON] {
        let other = try await NTPInstallation.signIn(world.server)
        return try await other.attachSnapshot().records
    }

    /// The phone's local effects equal the server's records for every podcast and episode the phone named.
    private func expectAgreement(_ world: World, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await world.phone.exchange()
        let rejected = world.phone.outcomes.filter { $0.value.hasPrefix("rejected") }
        #expect(rejected.isEmpty, "\(label): rejected \(rejected)", sourceLocation: sourceLocation)
        let records = try await serverRecords(world)
        let store = world.store
        let state = try await store.syncedStateForTesting()
        let queue = try await store.queue().map(\.id)
        func record(_ entity: String, _ id: String, _ group: String) -> ContractJSON? { records["\(entity)/\(id)/\(group)"] }
        for row in try world.fixture.rows("SELECT podcast_id, feed_id FROM ntp_podcasts") {
            guard let podcast = row[0], let feedText = row[1], let feedID = Int64(feedText) else { continue }
            let subscription = record("podcast", podcast, "subscription")?["state"]?.stringValue
            guard let local = state.feeds[feedID] else {
                #expect(subscription == "removed", "\(label): feed \(feedID) left locally; server \(String(describing: subscription))", sourceLocation: sourceLocation)
                continue
            }
            let expected = switch local.subscription { case .subscribed: "subscribed"; case .archived: "archived"; case .notSubscribed: "not_subscribed" }
            #expect(subscription == expected, "\(label): podcast \(feedID) subscription", sourceLocation: sourceLocation)
            let policy = record("podcast", podcast, "policy")
            #expect(policy?["keep_updated"]?.boolValue == local.keepUpdated, "\(label): podcast \(feedID) keep updated", sourceLocation: sourceLocation)
            #expect(policy?["new_episodes_action"] == FeedLibraryStore.wire(local.newEpisodesAction), "\(label): podcast \(feedID) action", sourceLocation: sourceLocation)
            #expect(record("podcast", podcast, "identity")?["refresh_url"]?.stringValue == ContractURL.stripUserinfo(local.source), "\(label): podcast \(feedID) URL", sourceLocation: sourceLocation)
            if !ContractURL.hasUserinfo(local.source) {
                let credential = state.credentials[feedID]
                let secret = credential.flatMap { try? world.fixture.rows("SELECT secret_id FROM ntp_secrets WHERE credential_id = '\($0)'").first?.first ?? nil }
                #expect(record("podcast", podcast, "credentials")?["secret_id"]?.stringValue == secret, "\(label): podcast \(feedID) credentials", sourceLocation: sourceLocation)
            }
        }
        let podcasts = try world.fixture.rows("SELECT count(*) FROM ntp_podcasts WHERE feed_id IS NOT NULL")
        #expect(podcasts != [["0"]], "\(label): no podcast compared", sourceLocation: sourceLocation)
        var compared = 0
        var serverQueue: [(key: QueueKey, local: Int64)] = []
        for row in try world.fixture.rows("SELECT episode_id, local_id FROM ntp_episodes") {
            guard let episode = row[0], let localText = row[1], let localID = Int64(localText), let local = state.episodes[localID] else { continue }
            compared += 1
            let playState = record("episode", episode, "play_state")?["play_state"]?.stringValue ?? "unplayed"
            #expect(playState == FeedLibraryStore.wire(local.playState).stringValue, "\(label): episode \(localID) play state", sourceLocation: sourceLocation)
            #expect((record("episode", episode, "favorite")?["on"]?.boolValue ?? false) == local.favorite, "\(label): episode \(localID) favorite", sourceLocation: sourceLocation)
            #expect((record("episode", episode, "position")?["position"]?.integerValue ?? 0) == Int64(local.position), "\(label): episode \(localID) position", sourceLocation: sourceLocation)
            let inQueue = record("episode", episode, "queue_membership")?["in_queue"]?.boolValue ?? false
            #expect(inQueue == queue.contains(localID), "\(label): episode \(localID) queue membership", sourceLocation: sourceLocation)
            if inQueue, let wire = record("episode", episode, "queue_position")?["key"]?.stringValue { serverQueue.append((try QueueKey(wire: wire), localID)) }
        }
        #expect(compared > 0, "\(label): no episode compared", sourceLocation: sourceLocation)
        if ProcessInfo.processInfo.environment["NTP_AGREEMENT_TRACE"] != nil {
            print("agreement \(label): \(records.count) records, \(compared) episodes, outcomes \(Dictionary(grouping: world.phone.outcomes.values, by: { $0 }).mapValues(\.count))")
        }
        let deviceOnly = try await store.deviceOnlyEpisodesForTesting()
        let synced = queue.filter { !deviceOnly.contains($0) }
        // The order agrees. Keys are this phone's predictions (PROTOCOL §7.6): the server keeps them when they give
        // the replay's order and otherwise publishes its own, which this stand-in phone never applies.
        #expect(serverQueue.sorted { $0.key < $1.key }.map(\.local) == synced, "\(label): queue order", sourceLocation: sourceLocation)
        let account = world.phone.installation.accountID
        if let policies = try await store.serverAccountPolicies() {
            if let discovery = record("account", account, "discovery_policy") {
                #expect(discovery["new_episodes_action"] == policies.newEpisodesAction.map(FeedLibraryStore.wire), "\(label): account action", sourceLocation: sourceLocation)
            }
            if let queuePolicy = record("account", account, "queue_policy") {
                #expect(queuePolicy["enqueue_location"] == FeedLibraryStore.wire(policies.enqueueLocation), "\(label): enqueue location", sourceLocation: sourceLocation)
                #expect(queuePolicy["keep_sorted"]?.boolValue == policies.keepSorted, "\(label): keep sorted", sourceLocation: sourceLocation)
                #expect(queuePolicy["sort_order"] == FeedLibraryStore.wire(policies.keepSortedOrder), "\(label): sort order", sourceLocation: sourceLocation)
            }
        }
    }

    @Test func everyRecordedRowAgreesWithTheServer() async throws {
        try await world { world in
            let store = world.store
            // Subscriptions (PROTOCOL §15.2): subscribe, a preview registered by its first synced action, then subscribed.
            let one = try await store.insert(Self.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            let preview = try await store.preparePreview(Self.fetched(world.url("two.xml"), title: "Two", prefix: "two", count: 3))
            let previewItem = try #require(preview.episodes.first)
            try await store.setFavorite(episodeID: previewItem.id, favorite: true)
            try await expectAgreement(world, "subscriptions")
            #expect(try await store.subscribePreview(feedID: preview.id))
            try await expectAgreement(world, "subscribed preview")
            let ids = one.episodes.map(\.id).sorted()

            // Episode state: marks, swipes and Undo, reset, favorites, Inbox.
            try await store.markEpisodesPlayed(episodeIDs: [ids[0], ids[1]], played: true)
            try await store.markEpisodePlayed(episodeID: ids[2], played: true, resetPosition: false)
            try await store.markEpisodePlayed(episodeID: ids[1], played: false)
            let receipt = try #require(try await store.applySwipeMark(episodeID: ids[3], action: .togglePlayed))
            #expect(try await store.undoSwipeMark(receipt) == .restored)
            _ = try await store.applySwipeMark(episodeID: ids[2], action: .togglePlayed)
            try await store.resetPlaybackPosition(episodeID: ids[0])
            try await store.setFavorite(episodeIDs: [ids[3], ids[4]], favorite: true)
            try await store.setFavorite(episodeID: ids[4], favorite: false)
            try await store.projectForTesting(ids[4]) { $0.userState.playState = .new }
            try await store.removeEpisodesFromInbox(episodeIDs: [ids[4]])
            try await expectAgreement(world, "episode state")

            // Queue: adds at every location, removal and Undo, moves, the sort sheet, Keep sorted, clear.
            _ = try await store.enqueue([ids[0], ids[1]])
            _ = try await store.enqueue([ids[2]], location: .front)
            _ = try await store.enqueue([ids[3]], location: .afterCurrentlyPlaying, playing: .episode(ids[2]))
            let removal = try #require(try await store.removeFromQueueWithUndo(ids[1]).receipt)
            #expect(try await store.undoQueueRemoval(removal).status == .restored)
            _ = try await store.performQueueMove(.item(ids[0], finalIndex: 3), expected: try await store.queue().map(QueueEpisodeIdentity.init))
            _ = try await store.performQueueMove(.boundary([ids[1], ids[3]], .top), expected: try await store.queue().map(QueueEpisodeIdentity.init))
            try await expectAgreement(world, "queue edits")
            _ = try await store.reorderQueue(.episodeTitleZA)
            store.setQueueInsertionSettings(.init(keepSortedOrder: .episodeTitleAZ))
            try await store.setServerAccountPolicy(.sorting(keepSorted: true, order: .episodeTitleAZ))
            _ = try await store.enqueue([ids[4]])
            try await expectAgreement(world, "keep sorted")
            store.setQueueInsertionSettings(.init())
            try await store.setServerAccountPolicy(.sorting(keepSorted: false, order: .episodeTitleAZ))
            _ = try await store.removeFromQueue([ids[2]])
            _ = try await store.requestDownload(episodeID: ids[2], directory: world.fixture.directory, enqueue: true)
            let job = try #require(try await store.downloadJobs().first { $0.episodeID == ids[2] })
            _ = try await store.cancelDownload(id: job.id)
            try await expectAgreement(world, "download queue")
            _ = try await store.clearQueue()
            try await expectAgreement(world, "cleared")

            // Podcast policies, credentials, URL edits; account policies.
            try await store.updatePreferences(feedID: one.id) { $0.subscriptionState = .archived }
            try await store.applyBulk(.keepUpdated(false), feedIDs: [one.id, preview.id])
            try await store.updatePreferences(feedID: preview.id) { $0.newEpisodesAction = .nothing }
            let authentication = FeedAuthentication(store: store, vault: world.phone.vault)
            try await authentication.save(.init(username: "alice", password: "s3cret"), feedID: one.id)
            #expect(try await store.updateFeedDownloadURL(original: world.url("one.xml"), updated: world.url("one-moved.xml")) == [one.id])
            try await store.setServerAccountPolicy(.newEpisodesAction(.queue))
            try await store.setServerAccountPolicy(.enqueueLocation(.front))
            try await expectAgreement(world, "policies")
            try await store.updatePreferences(feedID: one.id) { $0.subscriptionState = .subscribed }
            try await authentication.save(.init(username: "", password: ""), feedID: one.id)
            try await expectAgreement(world, "restored and cleared")

            // History and statistics cuts are accepted (history and played time come from sessions).
            try await store.projectForTesting(ids[0]) { $0.userState.lastPlayedHistoryMilliseconds = 1_000 }
            let history = try #require(try await store.removeFromPlaybackHistoryWithUndo(ids[0]))
            #expect(try await store.undoHistoryRemoval(history).status == .restored)
            _ = try await store.clearPlaybackHistory()
            try await store.resetPlayedDurationStatistics()

            // Unsubscribe.
            #expect(try await store.requestFeedDeletion(feedID: preview.id))
            try await expectAgreement(world, "unsubscribed")
            #expect(world.phone.outcomes.count == (try world.fixture.outboxCount()))
            #expect(world.phone.outcomes.values.allSatisfy { !$0.hasPrefix("rejected") && !$0.hasPrefix("not_applied") })
        }
    }

    @Test func draftsAndDeferredCutsMaterializeOntoTheServersResolution() async throws {
        try await world { world in
            let store = world.store
            let one = try await store.insert(Self.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            let ids = one.episodes.map(\.id).sorted()
            // Before the registration resolves: everything about the podcast is a draft on its chain.
            try await store.markEpisodePlayed(episodeID: ids[0], played: true)
            _ = try await store.enqueue([ids[1], ids[2]])
            try await store.setFavorite(episodeID: ids[3], favorite: true)
            _ = try await store.clearPlaybackHistory()
            try await store.updatePreferences(feedID: one.id) { $0.keepUpdated = false }
            #expect(try world.fixture.drafts().count == 5)
            try await expectAgreement(world, "materialized")
            #expect(try world.fixture.drafts().isEmpty)
            // A second subscription made later: the main author's facts never wait for its drafts.
            let three = try await store.insert(Self.fetched(world.url("three.xml"), title: "Three", prefix: "three", count: 3))
            _ = try await store.enqueue(three.episodes.map(\.id))
            try await store.markEpisodePlayed(episodeID: ids[4], played: true)
            try await world.phone.push()
            #expect(try world.fixture.drafts().count == 1)
            try await expectAgreement(world, "second registration")
        }
    }
}

/// The queue replay's places on a registration's chain (PROTOCOL §7.6): a draft anchored to its own podcast's
/// episode names it by its placeholder, which materializes onto the server's resolution.
extension ServerAgreementTests {
    @Test func aDraftPlacedAfterItsOwnPodcastsEpisodeMaterializesAndAgrees() async throws {
        try await world { world in
            let store = world.store
            let one = try await store.insert(Self.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            let ids = one.episodes.map(\.id).sorted()
            _ = try await store.enqueue([ids[1], ids[2]])
            _ = try await store.enqueue([ids[0]], location: .random, randomIndex: { _ in 1 })
            _ = try await store.performQueueMove(.item(ids[2], finalIndex: 0), expected: try await store.queue().map(QueueEpisodeIdentity.init))
            let anchored = try world.fixture.drafts().filter { $0.template["payload"]?["place"]?["after"]?["ntp_local_episode"] != nil }
            #expect(anchored.count == 1, "the random add names ids[1] by its placeholder")
            #expect(try await store.queue().map(\.id) == [ids[2], ids[1], ids[0]])
            try await expectAgreement(world, "drafts with places")
            #expect(try world.fixture.drafts().isEmpty)
        }
    }
}

/// Agreement cases for recording; each failed before its fix.
extension ServerAgreementTests {
    @Test func aKeepSortedAddAcrossPodcastsAgrees() async throws {
        try await world { world in
            let store = world.store
            let one = try await store.insert(Self.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            let two = try await store.insert(Self.fetched(world.url("two.xml"), title: "Two", prefix: "two", count: 3))
            try await world.phone.exchange()
            let a = one.episodes.map(\.id).sorted(), b = two.episodes.map(\.id).sorted()
            _ = try await store.enqueue([a[4], a[0]])
            try await expectAgreement(world, "before cross-podcast sort")
            // Keep sorted across podcasts: the add names only its member and place; the server sorts every podcast's
            // members at that place with the canonical comparator, as the phone did (PROTOCOL §7.6).
            store.setQueueInsertionSettings(.init(keepSortedOrder: .episodeTitleAZ))
            try await store.setServerAccountPolicy(.sorting(keepSorted: true, order: .episodeTitleAZ))
            _ = try await store.enqueue([b[0]])
            try await expectAgreement(world, "cross-podcast sort")
            // A pending podcast's add under Keep sorted (a draft until its registration resolves): the server sorts it in.
            let three = try await store.insert(Self.fetched(world.url("three.xml"), title: "Three", prefix: "three", count: 3))
            _ = try await store.enqueue([three.episodes.map(\.id).sorted()[0], b[2]])
            try await expectAgreement(world, "cross-podcast sort with a pending podcast")
        }
    }

    @Test func anActionAfterMaterializationKeepsCausalOrder() async throws {
        try await world { world in
            let store = world.store
            let one = try await store.insert(Self.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            let id = one.episodes[0].id
            try await store.setFavorite(episodeID: id, favorite: true)  // a draft
            try await world.phone.push()  // the registration only
            try await world.phone.pull()  // the draft materializes, not yet pushed
            // A slow phone clock, injected through the seam's action clock (no system setting changes).
            try await store.favoriteForTesting(id, on: false, at: Date().addingTimeInterval(-60))
            try await expectAgreement(world, "action after materialization")
        }
    }

    @Test func aSubscriptionURLsUserinfoReachesTheServerAsItsCredentials() async throws {
        try await world { world in
            let store = world.store
            let url = world.url("one.xml").replacingOccurrences(of: "http://", with: "http://alice:s%3Acret@")
            let preview = try await store.preparePreview(Self.fetched(url, title: "One", prefix: "one", count: 5))
            #expect(try await store.subscribePreview(feedID: preview.id))
            try await store.setFavorite(episodeID: preview.episodes[0].id, favorite: true)
            try await expectAgreement(world, "URL credentials")
            let records = try await NTPInstallation.signIn(world.server).attachSnapshot().records
            let podcast = try #require(try world.fixture.rows("SELECT podcast_id FROM ntp_podcasts WHERE feed_id = \(preview.id)").first?.first ?? nil)
            let secret = try #require(records["podcast/\(podcast)/credentials"]?["secret_id"]?.stringValue)
            let value = try await world.phone.installation.client.send("GET", "v1/secrets/\(secret)")
            #expect(value["username"]?.stringValue == "alice" && value["password"]?.stringValue == "s:cret")
            #expect(records["podcast/\(podcast)/identity"]?["refresh_url"]?.stringValue == world.url("one.xml"))
        }
    }
}

/// Agreement cases for owed facts.
extension ServerAgreementTests {
    @Test func pendingMembersReSortedByARegisteredAddAgree() async throws {
        try await world { world in
            let store = world.store
            let two = try await store.insert(Self.fetched(world.url("two.xml"), title: "Two", prefix: "two", count: 3))
            try await world.phone.exchange()
            let one = try await store.insert(Self.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            let ids = one.episodes.map(\.id).sorted()
            _ = try await store.enqueue([ids[4], ids[0]])  // the pending podcast's draft
            store.setQueueInsertionSettings(.init(keepSortedOrder: .episodeTitleAZ))
            try await store.setServerAccountPolicy(.sorting(keepSorted: true, order: .episodeTitleAZ))
            _ = try await store.enqueue([two.episodes.map(\.id).sorted()[0]])
            try await expectAgreement(world, "pending members re-sorted by a registered add")
        }
    }

    @Test func anOwedAddBeforeAnExplicitSortAgrees() async throws {
        try await world { world in
            let store = world.store
            let one = try await store.insert(Self.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            try await world.phone.exchange()
            let ids = one.episodes.map(\.id).sorted()
            _ = try await store.enqueue([ids[4], ids[0]])
            try await expectAgreement(world, "initial unsorted queue")
            await store.injectRecorderFailure(after: 1)
            _ = try await store.beginPlayback(episodeID: ids[2])
            await store.injectRecorderFailure(after: nil)
            _ = try await store.reorderQueue(.episodeTitleAZ)
            try await expectAgreement(world, "sort after owed queue add")
        }
    }

    @Test func clockBoundariesAgree() async throws {
        for offset: TimeInterval in [-3600, 3600] {
            try await world { world in
                let store = world.store
                let preview = try await store.preparePreview(Self.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
                let id = preview.episodes[0].id
                try await store.favoriteForTesting(id, on: true, at: Date().addingTimeInterval(-offset))
                _ = try await store.subscribePreview(feedID: preview.id)
                try await store.favoriteForTesting(id, on: false, at: Date().addingTimeInterval(offset))
                try await world.phone.exchange()
                try await store.favoriteForTesting(id, on: true, at: Date().addingTimeInterval(-offset))
                try await expectAgreement(world, "clock boundaries offset \(offset)")
            }
        }
    }

    @Test func everyRegisteredKeepSortedOrderAgrees() async throws {
        try await world { world in
            let store = world.store
            let one = try await store.insert(Self.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            let two = try await store.insert(Self.fetched(world.url("two.xml"), title: "Two", prefix: "two", count: 3))
            try await world.phone.exchange()
            let a = one.episodes.map(\.id).sorted(), b = two.episodes.map(\.id).sorted()
            // The server sorts at the add's place with the values it recorded: they must give the phone's order.
            for order in QueueSortOrder.allCases where order != .random {
                store.setQueueInsertionSettings(.init())
                try await store.setServerAccountPolicy(.sorting(keepSorted: false, order: order))
                _ = try await store.clearQueue()
                _ = try await store.enqueue([a[4], b[2], a[0]])
                store.setQueueInsertionSettings(.init(keepSortedOrder: order))
                try await store.setServerAccountPolicy(.sorting(keepSorted: true, order: order))
                _ = try await store.enqueue([b[0]])
                try await expectAgreement(world, "registered keep sorted \(order)")
            }
        }
    }
}

// An owed play-load add is replayed with the queue policy of the moment it happened, not the current Keep sorted
// setting, so turning Keep sorted off before recovery loses nothing.
extension ServerAgreementTests {
    @Test func owedSortedAddKeepsItsPolicyWhenKeepSortedIsTurnedOff() async throws {
        try await world { w in
            let s = w.store
            let one = try await s.insert(Self.fetched(w.url("one.xml"), title: "One", prefix: "one", count: 5))
            try await w.phone.exchange()
            let a = one.episodes.map(\.id).sorted()
            _ = try await s.enqueue([a[4], a[0]])
            try await expectAgreement(w, "initial unsorted queue")
            s.setQueueInsertionSettings(.init(keepSortedOrder: .episodeTitleAZ))
            try await s.setServerAccountPolicy(.sorting(keepSorted: true, order: .episodeTitleAZ))
            await s.injectRecorderFailure(after: 1)
            _ = try await s.beginPlayback(episodeID: a[2])
            await s.injectRecorderFailure(after: nil)
            #expect(try await s.queue().map(\.id) == [a[0], a[2], a[4]])
            // The settings screen updates this setting before its recorded policy write and sort.
            s.setQueueInsertionSettings(.init())
            try await s.setServerAccountPolicy(.sorting(keepSorted: false, order: .episodeTitleAZ))
            _ = try await s.reorderQueue(.episodeTitleAZ)
            try await expectAgreement(w, "owed sorted add then Keep sorted off")
        }
    }

    @Test func owedSortedAddAfterADiscoveredDurationKeepsItsPolicy() async throws {
        try await world { w in
            let s = w.store
            let one = try await s.insert(Self.fetched(w.url("one.xml"), title: "One", prefix: "one", count: 5))
            try await w.phone.exchange()
            let a = one.episodes.map(\.id).sorted()
            s.setQueueInsertionSettings(.init(keepSortedOrder: .durationShortLong))
            try await s.setServerAccountPolicy(.sorting(keepSorted: true, order: .durationShortLong))
            // Every duration is unknown (0), so this is sorted as inserted.
            _ = try await s.enqueue([a[4], a[0]])
            try await expectAgreement(w, "duration-sorted queue before playback measures a duration")
            let session = try await s.beginPlayback(episodeID: a[4])
            _ = try await s.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 0, durationMilliseconds: 600_000, status: .paused))
            _ = try await s.endPlayback(sessionID: session.id, reason: .switched)
            await s.injectRecorderFailure(after: 1)
            _ = try await s.beginPlayback(episodeID: a[2])
            await s.injectRecorderFailure(after: nil)
            // Sorts use the server's values (PROTOCOL §7.6): this phone's measurement is not one until its sessions export it
            //, so the sorted load sorts as the server will, every duration still unknown.
            #expect(try await s.queue().map(\.id) == [a[4], a[0], a[2]])
            s.setQueueInsertionSettings(.init())
            try await s.setServerAccountPolicy(.sorting(keepSorted: false, order: .durationShortLong))
            _ = try await s.reorderQueue(.durationShortLong)
            try await expectAgreement(w, "measured duration; owed sorted add then Keep sorted off")
        }
    }
}

// An owed Keep sorted add replays in bounded steps (the add, then the members it re-sorted, shown with
// it); the server's queue still reads like the phone's, the server sorting at the add's place.
extension ServerAgreementTests {
    @Test func owedSortedAddReplayedInSeveralStepsAgrees() async throws {
        try await world { w in
            let s = w.store
            let one = try await s.insert(Self.fetched(w.url("one.xml"), title: "One", prefix: "one", count: 5))
            let two = try await s.insert(Self.fetched(w.url("two.xml"), title: "Two", prefix: "two", count: 3))
            let three = try await s.insert(Self.fetched(w.url("three.xml"), title: "Three", prefix: "three", count: 3))
            try await w.phone.exchange()
            let a = one.episodes.map(\.id).sorted(), b = two.episodes.map(\.id).sorted(), c = three.episodes.map(\.id).sorted()
            _ = try await s.enqueue(a + b + [c[0], c[1]])
            try await expectAgreement(w, "ten members in insertion order")
            s.setQueueInsertionSettings(.init(keepSortedOrder: .episodeTitleZA))
            try await s.setServerAccountPolicy(.sorting(keepSorted: true, order: .episodeTitleZA))
            await s.injectRecorderFailure(after: 1)
            _ = try await s.beginPlayback(episodeID: c[2])
            await s.injectRecorderFailure(after: nil)
            #expect(try w.fixture.rows("SELECT count(*) FROM ntp_owed").first?.first.flatMap { $0.flatMap(Int.init) } ?? 0 > FeedLibraryStore.owedReplayStepMembers,
                    "the debt takes more than one replay step")
            try await expectAgreement(w, "owed Keep sorted add over several replay steps")
            #expect(try w.fixture.rows("SELECT count(*) FROM ntp_owed") == [["0"]])
        }
    }
}
