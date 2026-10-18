import Foundation
import Testing
@testable import NotTennaPodCore

/// Agreement tests against the real server: scripted actions on phone A, pushed and
/// pulled through the real engine; after every prefix a new phone B attaches through the real attach applier, and B's
/// synced rows must equal A's. A's own rows must not change when its facts come back as the server's records.
@Suite(.serialized) struct ServerExchangeAgreementTests {
    static func fetched(_ url: String, title: String, prefix: String, count: Int) -> FetchedFeed {
        let items = (1...count).map { number in
            ParsedEpisode(identifier: "\(prefix)-\(number)", title: "\(title) \(number)",
                          publicationDate: Date(timeIntervalSince1970: 1_760_000_000 + Double(number) * 86_400),
                          media: ParsedMedia(url: "https://media.example/\(prefix)-\(number).mp3", size: 1_000, durationMilliseconds: 0))
        }
        return FetchedFeed(feed: ParsedFeed(format: .rss, title: title, link: "https://example.com/", episodes: items), source: url,
                           responseURL: URL(string: url)!, validator: nil, permanentRedirectURL: nil)
    }

    /// Exchanges until the server's own fetch of `feedID`'s podcast has reached this phone (its catalog metadata),
    /// so a later attach sees every episode. Waits for the condition, never a fixed time.
    static func waitForCatalog(_ phone: ExchangePhone, feedID: Int64, deadline: Duration = .seconds(60)) async throws {
        let clock = ContinuousClock(), end = clock.now.advanced(by: deadline)
        var requested = false
        while clock.now < end {
            await phone.exchange()
            if let podcast = try await phone.store.podcastOfFeedForTesting(feedID) {
                if try phone.rows("SELECT count(*) FROM ntp_records WHERE entity = 'podcast' AND id = '\(podcast)' AND field_group = 'metadata'") == [["1"]] {
                    return
                }
                // Ask for the server's fetch now, as pull to refresh does (PROTOCOL §9), instead of waiting for its schedule.
                if !requested { _ = try? await phone.transport.server.send("POST", "v1/refresh", body: ["podcast_id": .string(podcast)]); requested = true }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HarnessError.server("the server's fetch of feed \(feedID) never arrived")
    }

    /// B, attached now, shows what A shows; and A's view is what it was before its facts came back.
    static func expectAgreement(_ world: ExchangeWorld, _ a: ExchangePhone, _ label: String,
                                sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let before = try await a.view()
        await a.exchange(sourceLocation: sourceLocation)
        await a.exchange(sourceLocation: sourceLocation)
        let after = try await a.view()
        let unsent = try await a.store.serverUnsentChanges()
        #expect(unsent == 0, "\(label): \(unsent) changes unsent", sourceLocation: sourceLocation)
        // Titles may change when the server's canonical metadata arrives (PROTOCOL §6.8); everything else must not.
        let changed = before.withoutTitles.differences(from: after.withoutTitles)
        #expect(changed.isEmpty, "\(label): A's own view changed when its facts came back:\n\(changed.joined(separator: "\n"))",
                sourceLocation: sourceLocation)
        let b = try await world.attach("B-\(label)")
        let other = try await b.view()
        if ProcessInfo.processInfo.environment["NTP_AGREEMENT_TRACE"] != nil { print("== \(label)\nA:\n\(after)\nB:\n\(other)") }
        let differences = after.differences(from: other)
        #expect(differences.isEmpty, "\(label): B differs from A:\n\(differences.joined(separator: "\n"))", sourceLocation: sourceLocation)
        #expect(!after.episodes.isEmpty, "\(label): nothing compared", sourceLocation: sourceLocation)
        await b.close()
    }
}

extension ServerExchangeAgreementTests {
    /// Every row of PROTOCOL §15.2 that recording records, in the recording agreement script, with a new
    /// phone attached after every prefix ("for every prefix of action sequences").
    @Test func everyPrefixOfTheRecordedActionsAgrees() async throws {
        try await ExchangeWorld.run { world in
            let a = try await world.attach("A")
            let store = a.store
            // Subscriptions: subscribe, a preview registered by its first synced action, then subscribed.
            let one = try await store.insert(Self.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            try await Self.waitForCatalog(a, feedID: one.id)
            try await Self.expectAgreement(world, a, "subscribe")
            let preview = try await store.preparePreview(Self.fetched(world.url("two.xml"), title: "Two", prefix: "two", count: 3))
            try await store.setFavorite(episodeID: try #require(preview.episodes.first).id, favorite: true)
            try await Self.waitForCatalog(a, feedID: preview.id)
            try await Self.expectAgreement(world, a, "preview")
            #expect(try await store.subscribePreview(feedID: preview.id))
            try await Self.expectAgreement(world, a, "subscribed preview")
            let ids = one.episodes.map(\.id).sorted()

            // Episode state: marks, swipes and Undo, reset, favorites, Inbox.
            try await store.markEpisodesPlayed(episodeIDs: [ids[0], ids[1]], played: true)
            try await Self.expectAgreement(world, a, "marked played")
            try await store.markEpisodePlayed(episodeID: ids[2], played: true, resetPosition: false)
            try await store.markEpisodePlayed(episodeID: ids[1], played: false)
            try await Self.expectAgreement(world, a, "marked unplayed")
            let receipt = try #require(try await store.applySwipeMark(episodeID: ids[3], action: .togglePlayed))
            #expect(try await store.undoSwipeMark(receipt) == .restored)
            _ = try await store.applySwipeMark(episodeID: ids[2], action: .togglePlayed)
            try await Self.expectAgreement(world, a, "swipes")
            try await store.resetPlaybackPosition(episodeID: ids[0])
            try await store.setFavorite(episodeIDs: [ids[3], ids[4]], favorite: true)
            try await store.setFavorite(episodeID: ids[4], favorite: false)
            try await Self.expectAgreement(world, a, "favorites")

            // Queue: adds at every location, removal and Undo, moves, the sort sheet, Keep sorted, clear.
            _ = try await store.enqueue([ids[0], ids[1]])
            _ = try await store.enqueue([ids[2]], location: .front)
            _ = try await store.enqueue([ids[3]], location: .afterCurrentlyPlaying, playing: .episode(ids[2]))
            try await Self.expectAgreement(world, a, "queue adds")
            let removal = try #require(try await store.removeFromQueueWithUndo(ids[1]).receipt)
            #expect(try await store.undoQueueRemoval(removal).status == .restored)
            _ = try await store.performQueueMove(.item(ids[0], finalIndex: 3), expected: try await store.queue().map(QueueEpisodeIdentity.init))
            _ = try await store.performQueueMove(.boundary([ids[1], ids[3]], .top), expected: try await store.queue().map(QueueEpisodeIdentity.init))
            try await Self.expectAgreement(world, a, "queue moves")
            _ = try await store.reorderQueue(.episodeTitleZA)
            store.setQueueInsertionSettings(.init(keepSortedOrder: .episodeTitleAZ))
            try await store.setServerAccountPolicy(.sorting(keepSorted: true, order: .episodeTitleAZ))
            _ = try await store.enqueue([ids[4]])
            try await Self.expectAgreement(world, a, "keep sorted")
            store.setQueueInsertionSettings(.init())
            try await store.setServerAccountPolicy(.sorting(keepSorted: false, order: .episodeTitleAZ))
            _ = try await store.removeFromQueue([ids[2]])
            let downloads = world.root.appendingPathComponent("downloads-\(UUID())")
            _ = try await store.requestDownload(episodeID: ids[2], directory: downloads, enqueue: true)
            let job = try #require(try await store.downloadJobs().first { $0.episodeID == ids[2] })
            _ = try await store.cancelDownload(id: job.id)
            try await Self.expectAgreement(world, a, "download queue")
            _ = try await store.clearQueue()
            try await Self.expectAgreement(world, a, "cleared")

            // Podcast policies, credentials, URL edits; account policies.
            try await store.updatePreferences(feedID: one.id) { $0.subscriptionState = .archived }
            try await store.applyBulk(.keepUpdated(false), feedIDs: [one.id, preview.id])
            try await store.updatePreferences(feedID: preview.id) { $0.newEpisodesAction = .nothing }
            try await Self.expectAgreement(world, a, "archived and policies")
            let authentication = FeedAuthentication(store: store, vault: a.vault)
            try await authentication.save(.init(username: "alice", password: "s3cret"), feedID: one.id)
            #expect(try await store.updateFeedDownloadURL(original: world.url("one.xml"), updated: world.url("one-moved.xml")) == [one.id])
            try await store.setServerAccountPolicy(.newEpisodesAction(.queue))
            try await store.setServerAccountPolicy(.enqueueLocation(.front))
            try await Self.expectAgreement(world, a, "credentials and URL")
            let b = try await world.attach("B-credentials")
            if let podcast = try await b.store.podcastOfFeedForTesting(try #require(try await b.store.feeds().first { $0.title == "One" }).id),
               let feed = try await b.store.feedOfPodcastForTesting(podcast) {
                let fetched = try await FeedAuthentication(store: b.store, vault: b.vault).credentials(feedID: feed)
                #expect(fetched == FeedCredentials(username: "alice", password: "s3cret"), "the fetched secret is the library's credential")
            }
            await b.close()
            try await store.updatePreferences(feedID: one.id) { $0.subscriptionState = .subscribed }
            try await authentication.save(.init(username: "", password: ""), feedID: one.id)
            try await Self.expectAgreement(world, a, "restored and cleared")

            // Unsubscribe.
            #expect(try await store.requestFeedDeletion(feedID: preview.id))
            try await Self.expectAgreement(world, a, "unsubscribed")
            let outcomes = try a.rows("SELECT count(*) FROM ntp_outbox")
            #expect(outcomes == [["0"]], "every fact retired")
            let log = try await a.engine.logEntries()
            #expect(!log.contains { $0.kind == "outcome" && $0.detail.contains("rejected") }, "nothing rejected: \(log.filter { $0.kind == "outcome" })")
        }
    }
}
