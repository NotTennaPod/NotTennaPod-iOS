import Foundation
import Testing
@testable import NotTennaPodCore

/// "Needs attention" (PROTOCOL §15.5): each kind is recorded by the unit that retires the
/// refused fact (an incomplete recovery by the recovery, inserted here as it records it), listed
/// with what a person needs to act, counted on the page as the list shows it, and cleared when
/// resolved or dismissed.
@Suite(.serialized, .timeLimit(.minutes(10))) struct ServerAttentionTests {
    typealias Agreement = ServerExchangeAgreementTests

    /// A podcast another device removed before this phone's subscription reached the server (`stale_subscribe`): the
    /// item names it and its feed URL for "Subscribe again"; subscribing again resolves it, and the new subscription
    /// carries what the phone knows now, so the server takes it.
    @Test func aStaleSubscriptionIsListedAndResolvedBySubscribingAgain() async throws {
        try await ExchangeWorld.run { world in
            let a = try await world.attach("A")
            // B never saw the podcast: its subscription carries no observation.
            let b = try await world.attach("B")
            let feed = try await a.store.insert(Agreement.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 3))
            try await Agreement.waitForCatalog(a, feedID: feed.id)
            #expect(try await a.store.requestFeedDeletion(feedID: feed.id))
            await a.exchange()

            let mine = try await b.store.insert(Agreement.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 3))
            await b.exchange(); await b.exchange()
            let log = try await b.engine.logEntries()
            #expect(log.contains { $0.kind == "outcome" && $0.detail == "podcast.subscribe not_applied stale_subscribe" }, "\(log)")
            let items = try await b.store.serverAttentionItems()
            #expect(items.map(\.kind) == [.staleSubscription(feedURL: world.url("one.xml"), title: "One")], "\(items)")
            #expect(await b.engine.storedState().attentionItems == 1)
            #expect(try await b.store.feed(id: mine.id) == nil, "the podcast the account removed leaves this phone")

            // "Subscribe again": the item is resolved at once and the server takes the new subscription.
            let again = try await b.store.insert(Agreement.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 3))
            #expect(try await b.store.serverAttentionItems().isEmpty)
            #expect(await b.engine.storedState().attentionItems == 0)
            await b.exchange(); await b.exchange()
            #expect(try await b.store.serverAttentionItems().isEmpty, "no new refusal")
            #expect(try await b.store.feed(id: again.id)?.subscriptionState == .subscribed)
            await a.exchange()
            #expect(try await a.view().podcasts.values.contains { $0.subscription == .subscribed }, "subscribed in the account again")
        }
    }

    /// The same refusal, then subscribed again on another device: the item resolves without this phone acting.
    @Test func aStaleSubscriptionSubscribedAgainElsewhereResolves() async throws {
        try await ExchangeWorld.run { world in
            let a = try await world.attach("A"), b = try await world.attach("B")
            let feed = try await a.store.insert(Agreement.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 3))
            try await Agreement.waitForCatalog(a, feedID: feed.id)
            #expect(try await a.store.requestFeedDeletion(feedID: feed.id))
            await a.exchange()
            _ = try await b.store.insert(Agreement.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 3))
            await b.exchange(); await b.exchange()
            #expect(try await b.store.serverAttentionItems().count == 1)
            _ = try await a.store.insert(Agreement.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 3))
            await a.exchange()
            await b.exchange()
            #expect(try await b.store.serverAttentionItems().isEmpty)
        }
    }

    /// A feed URL edit refused because the URL is another podcast's (`alias_conflict`): the item names the podcast that
    /// was edited, the URL and its owner; Dismiss clears it.
    @Test func aRefusedURLEditNamesBothPodcastsUntilDismissed() async throws {
        try await ExchangeWorld.run { world in
            let a = try await world.attach("A")
            let p = try await a.store.insert(Agreement.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 2))
            try await Agreement.waitForCatalog(a, feedID: p.id)
            let q = try await a.store.insert(Agreement.fetched(world.url("two.xml"), title: "Two", prefix: "two", count: 2))
            try await Agreement.waitForCatalog(a, feedID: q.id)
            _ = try await a.store.updateFeedDownloadURL(original: world.url("one.xml"), updated: world.url("two.xml"))
            await a.exchange(); await a.exchange()
            let items = try await a.store.serverAttentionItems()
            #expect(items.map(\.kind) == [.refusedURL(url: world.url("two.xml"), podcastTitle: "One", ownerTitle: "Two")], "\(items)")
            try await a.store.dismissServerAttention(try #require(items.first))
            #expect(try await a.store.serverAttentionItems().isEmpty)
            #expect(await a.engine.storedState().attentionItems == 0)
        }
    }

    /// Changes the server refused are one item, "Some changes were refused by the server", however many; the log lists
    /// each, and Dismiss clears them all.
    @Test func refusedChangesAreOneItemUntilDismissed() async throws {
        try await ExchangeWorld.run { world in
            let a = try await world.attach("A")
            let feed = try await a.store.insert(Agreement.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 3))
            try await Agreement.waitForCatalog(a, feedID: feed.id)
            for id in feed.episodes.map(\.id).sorted().prefix(2) {
                let ref = try #require(try await a.store.episodeRefForTesting(id))
                try await a.store.appendFactForTesting(type: "favorite.set", targets: [ref.target], payload: ["episode": ref.ref, "on": "yes"])
            }
            await a.exchange(); await a.exchange()
            #expect(try a.rows("SELECT kind FROM ntp_attention") == [["rejected"], ["rejected"]])
            let items = try await a.store.serverAttentionItems()
            #expect(items.map(\.kind) == [.refusedChanges(count: 2)] && items.first?.identifier == "rejected" && items.first?.ids.count == 2)
            #expect(await a.engine.storedState().attentionItems == 1, "the page counts the item, not the refusals")
            #expect(try await a.engine.logEntries().filter { $0.kind == "outcome" && $0.detail.hasPrefix("favorite.set rejected") }.count == 2)
            try await a.store.dismissServerAttention(try #require(items.first))
            #expect(try await a.store.serverAttentionItems().isEmpty)
            #expect(try await a.engine.logEntries().filter { $0.kind == "outcome" }.count == 2, "the log keeps them")
        }
    }

    /// An incomplete recovery, as the recovery records it (`recovery_incomplete {recovery_id,
    /// problems}`), with the other items newest first; an unknown kind is neither listed nor
    /// counted.
    @Test func anIncompleteRecoveryIsListedWithTheOthersNewestFirst() async throws {
        let fixture = try await ServerLibraryFixture()
        func insert(_ id: String, _ kind: String, _ record: ContractJSON, at time: Int64) async throws {
            try await fixture.store.executeForTesting("INSERT INTO ntp_attention(id, kind, record, created_at) VALUES (?, ?, ?, ?)",
                                                      [.text(id), .text(kind), .blob(try record.canonicalData()), .integer(time)])
        }
        try await insert("r-1", "recovery_incomplete", ["recovery_id": "r-1", "problems": 3], at: 3_000)
        try await insert("x-1", "rejected", ["op_id": "x-1", "type": "favorite.set", "reason": "invalid"], at: 1_000)
        try await insert("s-1", "stale_subscribe", ["op_id": "s-1", "type": "podcast.subscribe", "reason": "stale_subscribe",
                                                     "feed_url": "https://example.test/feed.xml", "title": "Show"], at: 2_000)
        try await insert("f-1", "future_kind", [:], at: 4_000)
        let items = try await fixture.store.serverAttentionItems()
        #expect(items.map(\.kind) == [.incompleteRecovery(problems: 3), .staleSubscription(feedURL: "https://example.test/feed.xml", title: "Show"),
                                      .refusedChanges(count: 1)])
        #expect(items.map(\.identifier) == ["r-1", "s-1", "rejected"])
        #expect(try await fixture.store.serverAttentionCount() == 3)
        try await fixture.store.dismissServerAttention(items[0])
        #expect(try await fixture.store.serverAttentionItems().map(\.identifier) == ["s-1", "rejected"])
        await fixture.close()
    }
}
