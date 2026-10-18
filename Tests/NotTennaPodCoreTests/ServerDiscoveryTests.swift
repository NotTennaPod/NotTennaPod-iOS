import Foundation
import Testing
@testable import NotTennaPodCore

/// Discovery in a server library (PROTOCOL §9): episode identity with the podcast's rules, the server's
/// first-item rule, observations and proposals recorded with the refresh that files them, queue filings with their
/// bundles, gained media, probable GUID changes, a reused GUID seen first here, and the discovery ledger.
struct ServerDiscoveryTests {
    typealias Fixture = ServerLibraryFixture

    struct Item {
        var guid: String?
        var title: String
        var day: Double?
        var media: String?
        /// `media` nil: the GUID's enclosure; `noMedia`: none.
        init(_ guid: String?, _ title: String, day: Double?, media: String? = nil, noMedia: Bool = false) {
            self.guid = guid; self.title = title; self.day = day
            self.media = noMedia ? nil : media ?? guid.map { "https://media.example.test/\($0).mp3" }
        }
    }

    static func date(_ day: Double) -> Date { Fixture.now.addingTimeInterval(day * 86_400) }
    static func ms(_ day: Double) -> Int64 { Int64(date(day).timeIntervalSince1970 * 1_000) }

    static func fetched(_ items: [Item], source: String = "https://example.test/feed.xml", title: String = "Show") -> FetchedFeed {
        let episodes = items.map { item in
            ParsedEpisode(identifier: item.guid, title: item.title, publicationDate: item.day.map(date),
                          media: item.media.map { ParsedMedia(url: $0, size: 1_000, durationMilliseconds: 600_000) })
        }
        return FetchedFeed(feed: ParsedFeed(format: .rss, title: title, link: "https://example.test/", episodes: episodes), source: source,
                           responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil)
    }

    static let base = [Item("g1", "One", day: 1), Item("g2", "Two", day: 2), Item("g3", "Three", day: 3)]

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await Fixture()
        do { try await body(fixture); await fixture.close() } catch { await fixture.close(); throw error }
    }

    /// A registered podcast whose first canonical metadata arrived (observations no longer wait, PROTOCOL §9.4).
    private func registered(_ fixture: Fixture, _ items: [Item] = base, action: NewEpisodesAction = .global) async throws
        -> (feed: LibraryFeed, podcast: String, generation: String) {
        let result = try await fixture.subscribeRegistered(Self.fetched(items))
        if action != .global { try await fixture.store.updatePreferences(feedID: result.feed.id) { $0.newEpisodesAction = action } }
        try await fixture.store.executeForTesting("INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('podcast', ?, 'metadata', ?, '[]')",
                                                  [.text(result.podcast), .blob(try (["title": "Show", "revision": .string(ContractIdentity.randomUUID())] as ContractJSON).canonicalData())])
        return result
    }

    private func refresh(_ fixture: Fixture, _ feed: LibraryFeed, _ items: [Item], day: Double = 10, global: NewEpisodesAction = .inbox,
                         autoDownload: Bool = false) async throws -> FeedRefreshResult {
        var options = FeedRefreshOptions(now: Self.date(day))
        options.globalNewEpisodesAction = global
        options.globalAutoDownload = autoDownload
        return try await fixture.store.applyRefresh(Self.fetched(items), feedID: feed.id, options: options)
    }

    private func episode(_ fixture: Fixture, guid: String) async throws -> LibraryEpisode {
        try #require(try await fixture.store.feeds().flatMap(\.episodes).first { $0.details.identifier == guid })
    }

    // MARK: Identity (PROTOCOL §9.7)

    @Test func theDerivationFollowsThePublishedRules() throws {
        let namespace = ContractIdentity.randomUUID()
        let podcast = try ContractIdentity.podcastID(namespace: namespace, creatingOpID: ContractIdentity.randomUUID())
        func id(_ kind: String, _ value: String) throws -> String { try ContractIdentity.episodeID(namespace: namespace, podcastID: podcast, kind: kind, value: value) }
        let original = try id("rss-guid", "g"), later = try id("rss-guid+enclosure", "g\u{1F}https://h/b.mp3"), alias = try id("rss-guid", "old")
        let rules = ServerIdentityRules([
            "disputed_guids": [["guid": "g", "releases": [
                ["episode_id": .string(original), "publication_time": 1_000_000_000_000, "enclosures": ["https://h/a.mp3"]],
                ["episode_id": .string(later), "publication_time": .integer(1_000_000_000_000 + 30 * 86_400_000), "enclosures": ["https://h/b.mp3"]]]]],
            "disputed_enclosures": ["https://h/shared.mp3"],
            "aliases": [["kind": "guid", "value": "new", "episode_id": .string(alias)],
                        ["kind": "enclosure", "value": "https://h/shared.mp3", "episode_id": .string(alias)],
                        ["kind": "enclosure", "value": "https://h/moved.mp3", "episode_id": .string(alias)]],
        ])
        func derive(_ guid: String?, _ enclosure: String?, _ time: Int64?) throws -> (String, ServerEpisodeKey)? {
            try ServerEpisodeIdentity.derive(ServerItemEvidence(guid: guid, enclosureURL: enclosure, publicationTime: time, title: nil, atom: false),
                                             rules: rules, namespace: namespace, podcast: podcast).map { ($0.episodeID, $0.key) }
        }
        // A disputed GUID: the release within 7 days of the item's date; near none with an enclosure, rule 3.
        #expect(try derive("g", "https://h/c.mp3", 1_000_000_000_000 + 3 * 86_400_000)?.0 == original)
        #expect(try derive("g", "https://h/c.mp3", 1_000_000_000_000 + 28 * 86_400_000)?.0 == later)
        let far = try #require(try derive("g", "https://h/c.mp3", 1_000_000_000_000 + 90 * 86_400_000))
        #expect(far.1 == ServerEpisodeKey(kind: "rss-guid+enclosure", value: "g\u{1F}https://h/c.mp3"))
        #expect(far.0 == (try id("rss-guid+enclosure", "g\u{1F}https://h/c.mp3")))
        // Undated: the release listing its enclosure if exactly one does, else the plain GUID.
        #expect(try derive("g", "https://H/b.mp3", nil)?.0 == later)
        #expect(try derive("g", "https://h/z.mp3", nil)?.0 == original)
        // An undisputed GUID's lookup alias; its occurrence names the plain derivation.
        let aliased = try #require(try derive("new", "https://h/x.mp3", 1))
        #expect(aliased.0 == alias && aliased.1 == ServerEpisodeKey(kind: "rss-guid", value: "new"))
        // Without a GUID: the enclosure's alias, never a disputed enclosure's.
        #expect(try derive(nil, "https://h/moved.mp3", 1)?.0 == alias)
        #expect(try derive(nil, "https://h/shared.mp3", 1)?.0 == (try id("enclosure", "https://h/shared.mp3")))
        #expect(try derive(nil, nil, 1) == nil)
    }

    @Test func aReusedGUIDIsANewOccurrenceOnlyForAnotherEnclosureMoreThanSevenDaysAway() {
        let day: Int64 = 86_400_000
        let locals = [ServerEpisodeIdentity.LocalItem(localID: 1, key: .init(kind: "rss-guid", value: "g"), guid: "g", enclosure: "https://h/a.mp3", publicationTime: 0)]
        func occurrence(_ enclosure: String?, _ time: Int64?) -> ServerEpisodeIdentity.LocalOccurrence? {
            ServerEpisodeIdentity.localOccurrence(of: .init(guid: "g", enclosureURL: enclosure, publicationTime: time, title: nil, atom: false), among: locals)
        }
        #expect(occurrence("https://h/b.mp3", 6 * day) == .existing(1), "within 7 days: the same release (signed URLs, dynamic ads)")
        #expect(occurrence("https://h/a.mp3", 30 * day) == nil, "the same enclosure re-dated: the plain episode")
        #expect(occurrence("https://h/b.mp3", 30 * day) == .reused(.init(kind: "rss-guid+enclosure", value: "g\u{1F}https://h/b.mp3")))
        #expect(occurrence("https://h/b.mp3", nil) == nil, "a missing date never splits")
        #expect(occurrence("https://h/a.mp3", nil) == .existing(1))
    }

    @Test func probableGUIDChangesMatchOneToOneByTitleAndDate() {
        let t: Int64 = 1_700_000_000_000
        let vanished: [(title: String?, publicationTime: Int64?)] = [("A", t), ("B", t + 1_000), ("Same", t + 5_000), ("Same", t + 5_000)]
        let items: [(guid: String?, title: String?, publicationTime: Int64?, isNew: Bool)] = [
            ("n1", "A", t + 400, true), ("n2", "B", t + 1_000, true), ("n3", "Same", t + 5_000, true), ("n4", "", t, true), ("n5", "A", nil, true),
        ]
        #expect(ServerEpisodeIdentity.probableGUIDChanges(items: items, vanished: vanished) == [0, 1],
                "A and B match to the second (n5 has no date); two old Same are ambiguous; empty titles never match")
        #expect(ServerEpisodeIdentity.probableGUIDChanges(items: [("n1", "A", t + 1_000, true)], vanished: [("A", t)]) == [], "another second")
        #expect(ServerEpisodeIdentity.probableGUIDChanges(items: [("n1", "A", t, false)], vanished: [("A", t)]) == [], "an item the replica knows")
        #expect(ServerEpisodeIdentity.probableGUIDChanges(items: [("n1", "A", t, true), ("n1", "A", t, true)], vanished: [("A", t)]) == [],
                "a GUID repeated in the fetch is a reused GUID, not a change")
    }

    // MARK: Refresh records (PROTOCOL §9.4)

    @Test func aRefreshObservesWhatChangedAndProposesItsReleasesWithTheirFiling() async throws {
        try await withFixture { fixture in
            let (feed, podcast, generation) = try await registered(fixture)
            let before = try fixture.outboxCount()
            // g4 is new and dated after the newest before the batch; g0 is backfill (older); g2's title changed.
            let items = Self.base.map { $0.guid == "g2" ? Item("g2", "Two, corrected", day: 2) : $0 } + [Item("g4", "Four", day: 4), Item("g0", "Zero", day: 0)]
            _ = try await refresh(fixture, feed, items)
            let facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["catalog.observe", "discovery.propose"])
            let observe = facts[0].payload
            #expect(observe["podcast_id"] == .string(podcast) && observe["parser_version"] == "ntp-ios/1")
            #expect(observe["feed"] != nil, "first observation of the feed record")
            let observed = (observe["items"]?.arrayValue ?? []).compactMap { $0["fields"]?["title"]?.stringValue }
            #expect(Set(observed) == ["One", "Two, corrected", "Three", "Four", "Zero"], "every record new to this replica's observations")
            #expect(facts[0].targets.allSatisfy { $0["generation"] == nil }, "observations name no generation")
            let propose = facts[1].payload
            let four = try await episode(fixture, guid: "g4")
            #expect(propose["episode"]?["episode_id"] == .string(try #require(try fixture.wireID(four.id))))
            #expect(propose["generation_id"] == .string(generation) && propose["action"] == "inbox")
            #expect(propose["pub_date"] == .integer(Self.ms(4)) && propose["newest_before_batch"] == .integer(Self.ms(3)))
            #expect(propose["batch_id"] == observe["batch_id"])
            #expect(facts[1].dependencies.contains(facts[0].opID), "proposals follow their batch's observations")
            #expect(four.userState.playState == .new, "the release is filed at once")
            #expect(try await episode(fixture, guid: "g0").userState.playState == .unplayed, "backfill is never filed")
            #expect(try fixture.overlays(opID: facts[1].opID).map { [$0[2], $0[3], $0[4]] } == [["play_state", "register", "\"new\""]])
            #expect(try fixture.rows("SELECT state, notified, entry_id FROM ntp_ledger") == [["pending", "0", facts[1].opID]])
            // The same parse again records nothing; a changed record only itself.
            let count = try fixture.outboxCount()
            _ = try await refresh(fixture, feed, items, day: 11)
            #expect(try fixture.outboxCount() == count)
            _ = try await refresh(fixture, feed, items.map { $0.guid == "g3" ? Item("g3", "Three!", day: 3) : $0 }, day: 12)
            let again = try fixture.newFacts(after: count)
            #expect(again.map(\.type) == ["catalog.observe"])
            #expect(again[0].payload["feed"] == nil && again[0].payload["items"]?.arrayValue?.count == 1)
        }
    }

    @Test func repeatedItemsKeepTheFirstPerEpisodeAndAutoDownloadNeverForcesTheInbox() async throws {
        try await withFixture { fixture in
            let (feed, _, _) = try await registered(fixture, action: .nothing)
            try await fixture.store.updatePreferences(feedID: feed.id) { $0.autoDownload = .enabled }
            let before = try fixture.outboxCount()
            _ = try await refresh(fixture, feed, Self.base + [Item("g4", "Four", day: 4), Item("g4", "Four again", day: 5, media: "https://media.example.test/other.mp3")])
            let fours = try await fixture.store.feeds().flatMap(\.episodes).filter { $0.details.identifier == "g4" }
            #expect(fours.count == 1 && fours.first?.details.title == "Four", "the first item per derived episode wins")
            #expect(fours.first?.userState.playState == .unplayed, "automatic download does not file into the Inbox")
            let facts = try fixture.newFacts(after: before)
            #expect(facts.last?.type == "discovery.propose" && facts.last?.payload["action"] == "nothing")
            #expect(try fixture.overlays(opID: facts.last!.opID).isEmpty)
            #expect(try await fixture.store.serverReleaseCandidates() == [fours[0].id], "the release is the automatic download's candidate")
        }
    }

    @Test func aQueueReleaseIsProposedWithTheBundleItsFilingResolved() async throws {
        try await withFixture { fixture in
            let (feed, _, _) = try await registered(fixture, action: .queue)
            let ids = feed.episodes.map(\.id).sorted()
            _ = try await fixture.store.enqueue([ids[0]])
            let before = try fixture.outboxCount()
            _ = try await refresh(fixture, feed, Self.base + [Item("g4", "Four", day: 4)])
            #expect(try fixture.newFacts(after: before).map(\.type) == ["catalog.observe"], "a queue release is proposed when it is filed")
            #expect(try fixture.rows("SELECT state, entry_id FROM ntp_ledger") == [["pending", nil]])
            let count = try fixture.outboxCount()
            _ = try await fixture.store.consumeFeedRefreshQueueEffects(location: .back)
            let facts = try fixture.newFacts(after: count)
            #expect(facts.map(\.type) == ["discovery.propose"])
            let four = try await episode(fixture, guid: "g4")
            let bundle = try #require(facts[0].payload["queue_bundle"])
            let key = try #require(try fixture.queueKeys().first { $0.episode == four.id })
            #expect(bundle == ["key": .string(key.key.wire), "position_id": .string(key.positionID), "place": ["kind": "end"]])
            #expect(facts[0].payload["action"] == "queue")
            #expect(try fixture.rows("SELECT entry_id FROM ntp_ledger") == [[facts[0].opID]])
            #expect(try await fixture.store.queue().map(\.id) == [ids[0], four.id])
            #expect(try fixture.queueOrderMatchesKeys())
        }
    }

    @Test func anItemGainingMediaIsFiledOnlyIfNobodyActedOnIt() async throws {
        try await withFixture { fixture in
            let items = Self.base + [Item("g4", "Four", day: 4, noMedia: true), Item("g5", "Five", day: 5, noMedia: true)]
            let (feed, _, _) = try await registered(fixture, items)
            // The phone observes both without media (its catalog-only evidence), then one is played.
            _ = try await refresh(fixture, feed, items)
            let five = try await episode(fixture, guid: "g5")
            try await fixture.store.markEpisodePlayed(episodeID: five.id, played: true)
            let before = try fixture.outboxCount()
            _ = try await refresh(fixture, feed, Self.base + [Item("g4", "Four", day: 4), Item("g5", "Five", day: 5), Item("g6", "Six", day: 6)], day: 12)
            #expect(try await episode(fixture, guid: "g4").userState.playState == .new, "gained media files an untouched episode")
            #expect(try await episode(fixture, guid: "g5").userState.playState == .played, "never played → new (AntennaPod's defect is not reproduced)")
            let proposals = try fixture.newFacts(after: before).filter { $0.type == "discovery.propose" }
            #expect(proposals.count == 2)
            let gained = try #require(proposals.first { $0.payload["gained_media"] != nil })
            let observation = try #require(try fixture.rows("SELECT catalog_node FROM ntp_observed WHERE id = 'local-episode:\(try await episode(fixture, guid: "g4").id)'").first?.first ?? nil)
            #expect(gained.payload["gained_media"] == ["catalog_only_observation": .string(observation)])
        }
    }

    /// Gained media never overrides an explicit state. An episode marked played and then explicitly
    /// unplayed (its facts pending, or acknowledged into the records), or one whose queue membership someone set, is
    /// not filed or proposed when its enclosure arrives; one nobody touched still is.
    @Test(arguments: ["pending", "acknowledged", "queue record"]) func gainedMediaRespectsAnExplicitState(_ evidence: String) async throws {
        try await withFixture { fixture in
            let items = Self.base + [Item("g4", "Four", day: 4, noMedia: true), Item("g5", "Five", day: 5, noMedia: true)]
            let (feed, podcast, generation) = try await registered(fixture, items)
            _ = try await refresh(fixture, feed, items)
            let four = try await episode(fixture, guid: "g4")
            let wire = try #require(try fixture.wireID(four.id))
            switch evidence {
            case "queue record":
                try await fixture.store.executeForTesting("INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('episode', ?, 'queue_membership', ?, '[]')",
                                                          [.text(wire), .blob(try (["generation_id": .string(generation), "in_queue": false] as ContractJSON).canonicalData())])
            default:
                try await fixture.store.markEpisodePlayed(episodeID: four.id, played: true)
                try await fixture.store.markEpisodePlayed(episodeID: four.id, played: false)
                if evidence == "acknowledged" {
                    try await fixture.store.retireEverythingForTesting()
                    try await fixture.store.executeForTesting("INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('episode', ?, 'play_state', ?, '[]')",
                                                              [.text(wire), .blob(try (["generation_id": .string(generation), "play_state": "unplayed"] as ContractJSON).canonicalData())])
                }
            }
            #expect(try await episode(fixture, guid: "g4").userState.playState == .unplayed)
            let before = try fixture.outboxCount()
            _ = try await refresh(fixture, feed, Self.base + [Item("g4", "Four", day: 4), Item("g5", "Five", day: 5)], day: 12)
            #expect(try await episode(fixture, guid: "g4").userState.playState == .unplayed, "an explicit state stands")
            #expect(try await episode(fixture, guid: "g5").userState.playState == .new, "an untouched one is filed")
            let proposals = try fixture.newFacts(after: before).filter { $0.type == "discovery.propose" }
            #expect(proposals.compactMap { $0.payload["episode"]?["episode_id"]?.stringValue } == [try #require(try fixture.wireID(try await episode(fixture, guid: "g5").id))])
            #expect(try fixture.rows("SELECT occurrence FROM ntp_ledger WHERE occurrence = '\(wire)'").isEmpty)
            _ = podcast
        }
    }

    /// Two occurrences of one GUID new in the same fetch (other enclosures, 16 days apart) are two
    /// episodes, in either order: the earliest release keeps the GUID's identity, the later one `rss-guid+enclosure`,
    /// as the server partitions them (PROTOCOL §9.7); both are observed with their own occurrence and proposed.
    @Test(arguments: [false, true]) func twoNewReusedOccurrencesInOneFetchStayDistinct(_ laterFirst: Bool) async throws {
        try await withFixture { fixture in
            let (feed, podcast, _) = try await registered(fixture)
            var reused = [Item("reused", "Early", day: 4, media: "https://media.example.test/early.mp3"),
                          Item("reused", "Late", day: 20, media: "https://media.example.test/late.mp3")]
            if laterFirst { reused.reverse() }
            let before = try fixture.outboxCount()
            _ = try await refresh(fixture, feed, Self.base + reused, day: 21)
            let rows = try await fixture.store.feeds().flatMap(\.episodes).filter { $0.details.identifier == "reused" }
            #expect(rows.count == 2)
            let early = try #require(rows.first { $0.details.title == "Early" }), late = try #require(rows.first { $0.details.title == "Late" })
            let namespace = fixture.identity.namespace
            #expect(try fixture.wireID(early.id) == (try ContractIdentity.episodeID(namespace: namespace, podcastID: podcast, kind: .rssGUID, value: "reused")))
            let lateValue = ContractIdentity.guidEnclosureValue(guid: "reused", normalizedEnclosure: ContractURL.normalize("https://media.example.test/late.mp3"))
            #expect(try fixture.wireID(late.id) == (try ContractIdentity.episodeID(namespace: namespace, podcastID: podcast, kind: .rssGUIDEnclosure, value: lateValue)))
            let facts = try fixture.newFacts(after: before)
            let occurrences = facts.filter { $0.type == "catalog.observe" }.flatMap { $0.payload["items"]?.arrayValue ?? [] }
                .compactMap { $0["episode"]?["occurrence"] }.filter { $0["guid"] == "reused" }
            #expect(Set(occurrences.compactMap { $0["k"]?.stringValue }) == ["rss-guid", "rss-guid+enclosure"])
            #expect(facts.filter { $0.type == "discovery.propose" }.count == 2)
        }
    }

    /// The same in a subscription's first population: both occurrences are kept, with the same identities.
    @Test func aFirstPopulationKeepsTwoReusedOccurrences() async throws {
        try await withFixture { fixture in
            let feed = try await fixture.store.insert(Self.fetched(Self.base + [Item("reused", "Late", day: 20, media: "https://media.example.test/late.mp3"),
                                                                                Item("reused", "Early", day: 4, media: "https://media.example.test/early.mp3")]))
            #expect(feed.episodes.filter { $0.details.identifier == "reused" }.count == 2)
            let keys = try fixture.rows("SELECT i.kind FROM ntp_local_items i JOIN episodes e ON e.id = i.local_id WHERE i.guid = 'reused' ORDER BY i.publication_time")
            #expect(keys == [["rss-guid"], ["rss-guid+enclosure"]])
        }
    }

    /// The phone observed its parse, then canonical metadata that differs arrived (episode and
    /// podcast). A later refresh with the same parse keeps showing the canonical metadata and records nothing; a parse
    /// that changed shows itself and is observed.
    @Test func anUnchangedOwnParseNeverUndoesCanonicalMetadata() async throws {
        try await withFixture { fixture in
            let (feed, podcast, _) = try await registered(fixture)
            _ = try await refresh(fixture, feed, Self.base)
            let two = try await episode(fixture, guid: "g2")
            let wire = try #require(try fixture.wireID(two.id))
            let parse = ServerCatalogRecords.interim(Self.fetched(Self.base).feed)
            guard case .object(var episodeFields) = parse.items[1].fields, case .object(var podcastFields) = parse.feedFields else { return }
            episodeFields["title"] = "Two (canonical)"; episodeFields["revision"] = .string(ContractIdentity.randomUUID())
            podcastFields["title"] = "Canonical Show"; podcastFields["revision"] = .string(ContractIdentity.randomUUID())
            try await fixture.store.retireEverythingForTesting()
            try await ServerProjectionUnitTests.Applier(fixture).apply([
                ServerRecord(entity: "episode", id: wire, fieldGroup: "metadata", value: .object(episodeFields)),
                ServerRecord(entity: "podcast", id: podcast, fieldGroup: "metadata", value: .object(podcastFields))])
            #expect(try await episode(fixture, guid: "g2").details.title == "Two (canonical)")
            #expect(try await fixture.store.feed(id: feed.id)?.metadata.title == "Canonical Show")
            let count = try fixture.outboxCount()
            _ = try await refresh(fixture, feed, Self.base, day: 11)
            #expect(try await episode(fixture, guid: "g2").details.title == "Two (canonical)", "the canonical record stays shown")
            #expect(try await fixture.store.feed(id: feed.id)?.metadata.title == "Canonical Show")
            #expect(try fixture.outboxCount() == count, "nothing to observe")
            // A parse that changed is shown until the server answers, and observed.
            _ = try await refresh(fixture, feed, Self.base.map { $0.guid == "g2" ? Item("g2", "Two, again", day: 2) : $0 }, day: 12)
            #expect(try await episode(fixture, guid: "g2").details.title == "Two, again")
            #expect(try fixture.newFacts(after: count).map(\.type) == ["catalog.observe"])
        }
    }

    /// A GUID rotating two enclosures (days 4, 20, 40, 60 with A, B, A, B) is four releases. The
    /// fourth would take the second's `rss-guid+enclosure`, so the server gives it a persisted ID of its own; until it
    /// does, the phone keeps it as a fourth episode, unmapped, observes and proposes it with its own occurrence (never
    /// in one fact with the second), and files it apart. In either item order.
    @Test(arguments: [false, true]) func rotatingEnclosuresKeepEveryRelease(_ reversed: Bool) async throws {
        try await withFixture { fixture in
            let (feed, podcast, _) = try await registered(fixture)
            var rotating = Self.rotating
            if reversed { rotating.reverse() }
            let before = try fixture.outboxCount()
            _ = try await refresh(fixture, feed, Self.base + rotating, day: 61)
            try await checkRotating(fixture, podcast: podcast, facts: try fixture.newFacts(after: before), proposals: 4)
        }
    }

    /// The server's releases permute the phone's assignment (day 20 takes an `e0:` ID, day 60 the
    /// B-derived ID day 20 had). Each release keeps its own ledger entry (day 60's done and notified, day 20's not), and a
    /// pending favorite stays on the episode it was made on, whether that row moves or was provisional.
    @Test(arguments: ["moving", "provisional"]) func resolvingRotationKeepsEachReleasesLedgerAndPendingState(_ favorite: String) async throws {
        try await withFixture { fixture in
            let (feed, podcast, generation) = try await registered(fixture)
            _ = try await refresh(fixture, feed, Self.base + Self.rotating, day: 61)
            func row(_ title: String) async throws -> Int64 {
                try #require(try await fixture.store.feeds().flatMap(\.episodes).first { $0.details.title == title }).id
            }
            let day20 = try await row("Rot 20"), day60 = try await row("Rot 60")
            let namespace = fixture.identity.namespace
            func composite(_ slot: String) throws -> String {
                try ContractIdentity.episodeID(namespace: namespace, podcastID: podcast, kind: .rssGUIDEnclosure,
                                               value: ContractIdentity.guidEnclosureValue(guid: "rot", normalizedEnclosure: ContractURL.normalize("https://media.example.test/\(slot).mp3")))
            }
            let plain = try ContractIdentity.episodeID(namespace: namespace, podcastID: podcast, kind: .rssGUID, value: "rot")
            let b = try composite("slot-b"), a = try composite("slot-a")
            #expect(try fixture.wireID(day20) == b && fixture.wireID(day60) == nil)
            try await fixture.store.executeForTesting("UPDATE ntp_ledger SET state = 'done', notified = 1 WHERE occurrence = ?", [.text("local-episode:\(day60)")])
            try await fixture.store.setFavorite(episodeID: favorite == "moving" ? day20 : day60, favorite: true)
            // The server's releases: day 20 has its persisted ID, day 60 the B-derived one.
            let e0 = "e0:" + ContractIdentity.randomUUID().lowercased()
            func release(_ id: String, _ day: Double, _ slot: String) -> ContractJSON {
                ["episode_id": .string(id), "publication_time": .integer(Self.ms(day)), "enclosures": [.string(ContractURL.normalize("https://media.example.test/\(slot).mp3"))]]
            }
            let rules: ContractJSON = ["aliases": [], "disputed_enclosures": [], "disputed_guids": [["guid": "rot", "releases": [
                release(plain, 4, "slot-a"), release(e0, 20, "slot-b"), release(a, 40, "slot-a"), release(b, 60, "slot-b")]]]]
            let occurrence: ContractJSON = ["k": "rss-guid", "v": "rot", "guid": "rot", "enclosure_url": "https://media.example.test/slot-b.mp3",
                                            "publication_time": .integer(Self.ms(20))]
            try await ServerProjectionUnitTests.Applier(fixture).apply([
                ServerRecord(entity: "podcast", id: podcast, fieldGroup: "identity_rules", value: rules),
                ServerRecord(entity: "episode", id: e0, fieldGroup: "identity", value: ["podcast_id": .string(podcast), "occurrence": occurrence])])
            #expect(try fixture.wireID(day20) == e0 && fixture.wireID(day60) == b, "each row the release of its date")
            let ledger = try fixture.rows("SELECT occurrence, state, notified FROM ntp_ledger WHERE generation_id = '\(generation)' ORDER BY occurrence")
            #expect(ledger.count == 4 && ledger.filter { $0[0]?.hasPrefix("local-episode:") == true }.isEmpty, "\(ledger)")
            #expect(ledger.first { $0[0] == e0 }.map { [$0[1], $0[2]] } == [["pending", "0"]].first, "day 20's follow-ups are still owed")
            #expect(ledger.first { $0[0] == b }.map { [$0[1], $0[2]] } == [["done", "1"]].first, "day 60's stay done")
            let twenty = try #require(try await fixture.store.episode(id: day20)), sixty = try #require(try await fixture.store.episode(id: day60))
            #expect(twenty.userState.isFavorite == (favorite == "moving") && sixty.userState.isFavorite == (favorite == "provisional"),
                    "the pending favorite stays on its episode")
        }
    }

    /// The rotating releases come in while the subscription's registration is pending. Its
    /// resolution moves every release's ledger entry to the resolved generation (the provisional one keeping its local
    /// episode, done and notified as it was) and keeps the provisional release's pending favorite its own.
    @Test func aRegistrationsResolutionKeepsAProvisionalReleasesLedgerAndOverlay() async throws {
        try await withFixture { fixture in
            let feed = try await fixture.store.insert(Self.fetched(Self.base))
            _ = try await refresh(fixture, feed, Self.base + Self.rotating, day: 61)
            let sixty = try #require(try await fixture.store.feeds().flatMap(\.episodes).first { $0.details.title == "Rot 60" }).id
            try await fixture.store.setFavorite(episodeID: sixty, favorite: true)
            try await fixture.store.executeForTesting("UPDATE ntp_ledger SET state = 'done', notified = 1 WHERE occurrence = ?", [.text("local-episode:\(sixty)")])
            #expect(try fixture.rows("SELECT count(*) FROM ntp_ledger") == [["4"]])
            let op = try fixture.registrationOp(feedID: feed.id)
            let ids = try fixture.created(op)
            try await fixture.store.resolveRegistration(opID: op, .init(podcastID: ids.podcast, generationID: ids.generation, mode: "created", decisionID: nil))
            let ledger = try fixture.rows("SELECT occurrence, state, notified FROM ntp_ledger WHERE generation_id = '\(ids.generation)' ORDER BY occurrence")
            #expect(ledger.count == 4, "\(ledger)")
            #expect(ledger.first { $0[0] == "local-episode:\(sixty)" }.map { [$0[1], $0[2]] } == [["done", "1"]].first, "kept by its local episode")
            #expect(try fixture.rows("SELECT id FROM ntp_overlays WHERE property = 'favorite'") == [["local-episode:\(sixty)"]], "its own overlay")
            #expect(try fixture.wireID(sixty) == nil)
        }
    }

    /// The same in a first population, either order: four episodes, each with its own identity evidence kept.
    @Test(arguments: [false, true]) func aFirstPopulationKeepsEveryRotatingRelease(_ reversed: Bool) async throws {
        try await withFixture { fixture in
            var rotating = Self.rotating
            if reversed { rotating.reverse() }
            let feed = try await fixture.store.insert(Self.fetched(Self.base + rotating))
            #expect(feed.episodes.filter { $0.details.identifier == "rot" }.count == 4)
            let keys = try fixture.rows("SELECT kind FROM ntp_local_items WHERE guid = 'rot' ORDER BY publication_time")
            #expect(keys == [["rss-guid"], ["rss-guid+enclosure"], ["rss-guid+enclosure"], ["rss-guid+enclosure"]])
        }
    }

    static let rotating = [Item("rot", "Rot 4", day: 4, media: "https://media.example.test/slot-a.mp3"),
                           Item("rot", "Rot 20", day: 20, media: "https://media.example.test/slot-b.mp3"),
                           Item("rot", "Rot 40", day: 40, media: "https://media.example.test/slot-a.mp3"),
                           Item("rot", "Rot 60", day: 60, media: "https://media.example.test/slot-b.mp3")]

    private func checkRotating(_ fixture: Fixture, podcast: String, facts: [Fixture.Fact], proposals: Int) async throws {
        let rows = try await fixture.store.feeds().flatMap(\.episodes).filter { $0.details.identifier == "rot" }
        #expect(rows.count == 4, "four releases, four episodes")
        let byTitle = Dictionary(rows.map { ($0.details.title ?? "", $0.id) }, uniquingKeysWith: { a, _ in a })
        let namespace = fixture.identity.namespace
        func composite(_ slot: String) throws -> String {
            try ContractIdentity.episodeID(namespace: namespace, podcastID: podcast, kind: .rssGUIDEnclosure,
                                           value: ContractIdentity.guidEnclosureValue(guid: "rot", normalizedEnclosure: ContractURL.normalize("https://media.example.test/\(slot).mp3")))
        }
        #expect(try fixture.wireID(try #require(byTitle["Rot 4"])) == (try ContractIdentity.episodeID(namespace: namespace, podcastID: podcast, kind: .rssGUID, value: "rot")))
        #expect(try fixture.wireID(try #require(byTitle["Rot 20"])) == (try composite("slot-b")))
        #expect(try fixture.wireID(try #require(byTitle["Rot 40"])) == (try composite("slot-a")))
        #expect(try fixture.wireID(try #require(byTitle["Rot 60"])) == nil, "the server's own ID resolves it")
        let observations = facts.filter { $0.type == "catalog.observe" }
        for fact in observations {
            let ids = (fact.payload["items"]?.arrayValue ?? []).compactMap { $0["episode"]?["episode_id"]?.stringValue }
            #expect(Set(ids).count == ids.count, "no episode twice in one observation")
        }
        let occurrences = observations.flatMap { $0.payload["items"]?.arrayValue ?? [] }.compactMap { $0["episode"]?["occurrence"] }.filter { $0["guid"] == "rot" }
        #expect(Set(occurrences.compactMap { $0["publication_time"]?.integerValue }) == Set([4.0, 20, 40, 60].map(Self.ms)), "every occurrence observed")
        #expect(facts.filter { $0.type == "discovery.propose" && $0.payload["episode"]?["occurrence"]?["guid"] == "rot" }.count == proposals)
        #expect(try fixture.rows("SELECT count(*) FROM ntp_ledger").first?.first == "\(proposals)", "each release its own ledger entry")
    }

    @Test func aHostingMoveIsObservedButNeitherProposedNorFiled() async throws {
        try await withFixture { fixture in
            let (feed, _, _) = try await registered(fixture)
            let before = try fixture.outboxCount()
            let moved = Self.base.map { Item("new-" + $0.guid!, $0.title, day: $0.day, media: "https://new-host.example/\($0.guid!).mp3") }
            _ = try await refresh(fixture, feed, moved)
            let facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["catalog.observe"])
            let episodes = try await fixture.store.feeds().flatMap(\.episodes)
            #expect(episodes.count == 6, "the new rows show until the server's merge arrives")
            #expect(episodes.allSatisfy { $0.userState.playState != .new })
            #expect(try fixture.rows("SELECT count(*) FROM ntp_ledger") == [["0"]])
        }
    }

    @Test func aReusedGUIDSeenFirstHereKeepsTheOldEpisodeAndItsState() async throws {
        try await withFixture { fixture in
            let (feed, podcast, _) = try await registered(fixture)
            let one = try await episode(fixture, guid: "g1")
            try await fixture.store.markEpisodePlayed(episodeID: one.id, played: true)
            // The bulletin reuses g1 for new media 30 days later.
            _ = try await refresh(fixture, feed, Self.base.map { $0.guid == "g1" ? Item("g1", "One (new)", day: 31, media: "https://media.example.test/g1-b.mp3") : $0 },
                                  day: 32)
            let rows = try await fixture.store.feeds().flatMap(\.episodes).filter { $0.details.identifier == "g1" }
            #expect(rows.count == 2)
            let kept = try #require(rows.first { $0.id == one.id }), later = try #require(rows.first { $0.id != one.id })
            #expect(kept.userState.playState == .played && kept.details.media?.url == "https://media.example.test/g1.mp3")
            #expect(later.userState.playState == .new, "a new release, filed")
            let key = ServerEpisodeKey(kind: "rss-guid+enclosure", value: "g1\u{1F}https://media.example.test/g1-b.mp3")
            #expect(try fixture.wireID(later.id) == (try ServerEpisodeIdentity.id(key, namespace: fixture.identity.namespace, podcast: podcast)))
            #expect(try fixture.rows("SELECT kind FROM ntp_local_items WHERE local_id = \(later.id)") == [["rss-guid+enclosure"]])
            // The next refresh finds each occurrence its own episode.
            let count = try fixture.outboxCount()
            _ = try await refresh(fixture, feed, Self.base.map { $0.guid == "g1" ? Item("g1", "One (new)", day: 31, media: "https://media.example.test/g1-b.mp3") : $0 },
                                  day: 33)
            #expect(try await fixture.store.feeds().flatMap(\.episodes).count == 4)
            #expect(try fixture.outboxCount() == count)
        }
    }

    // MARK: The parity parse

    private struct Transport: FeedHTTPTransport {
        let body: Data
        func send(_ request: URLRequest) async throws -> FeedHTTPResponse { FeedHTTPResponse(url: request.url!, status: 200, body: body) }
    }

    static func rfc822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    static func rss(_ extra: String) -> Data {
        let items = (1...3).map { n in
            "<item><guid>g\(n)</guid><title>\(["One", "Two", "Three"][n - 1])</title><pubDate>\(Self.rfc822(date(Double(n))))</pubDate>"
                + "<enclosure url=\"https://media.example.test/g\(n).mp3\" length=\"1000\" type=\"audio/mpeg\"/></item>"
        }.joined()
        return Data("<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>Show</title><link>https://example.test/</link>\(items)\(extra)</channel></rss>".utf8)
    }

    @Test func aServerLibrarysRefreshParsesAndObservesWithTheParityParse() async throws {
        try await withFixture { fixture in
            let (feed, _, _) = try await registered(fixture)
            let before = try fixture.outboxCount()
            // Android cuts the title at the `<` (TagSoup); the app's own parser keeps it.
            let extra = "<item><guid>g4</guid><title>Tom &amp; Jerry &lt;3</title><pubDate>\(Self.rfc822(Self.date(4)))</pubDate>"
                + "<enclosure url=\"https://media.example.test/g4.mp3\" length=\"1000\" type=\"audio/mpeg\"/></item>"
            let body = Self.rss(extra)
            let service = FeedRefreshService(store: fixture.store, fetcher: FeedFetcher(transport: Transport(body: body)), clock: { Self.date(10) })
            guard case .updated = try await service.refresh(feedID: feed.id, force: true) else { Issue.record("not updated"); return }
            let parity = try ParityFeedParser.parse(body, source: feed.source, now: Self.ms(10))
            let four = try await episode(fixture, guid: "g4")
            let appTitle = try FeedParser().parse(body, now: Self.date(10)).episodes[3].title
            #expect(four.details.title == parity.items[3].title && four.details.title != appTitle, "the row shows the parity parse")
            let observe = try #require(try fixture.newFacts(after: before).first { $0.type == "catalog.observe" })
            let observed = try #require(observe.payload["items"]?.arrayValue?.first { $0["episode"]?["occurrence"]?["guid"] == "g4" })
            #expect(observed["fields"] == .object(parity.items[3].episodeFields))
            #expect(observe.payload["feed"]?["fields"] == .object(parity.podcastFields))
        }
    }

    /// A feed the parity parse refuses without a detail (a mismatched tag): the Download log and its details say where
    /// the document stops being well-formed XML, never the parse's internal label, in the stored log, the dialog's
    /// technical detail and the clipboard; the refusal stands.
    @Test func aRefusalWithoutADetailSaysWhereTheFeedBreaksNeverItsCode() async throws {
        try await withFixture { fixture in
            let (feed, _, _) = try await registered(fixture)
            let body = Data("<?xml version=\"1.0\"?>\n<rss version=\"2.0\"><channel><title>Show</title>\n<item><title>One</item>\n</channel></rss>".utf8)
            #expect(throws: ParityParseError.parserException) { try ParityFeedParser.parse(body, source: feed.source, now: Self.ms(10)) }
            let service = FeedRefreshService(store: fixture.store, fetcher: FeedFetcher(transport: Transport(body: body)), clock: { Self.date(10) })
            guard case .failed(let error) = try await service.refresh(feedID: feed.id, force: true) else { Issue.record("not refused"); return }
            guard case .parsing(.malformedXML(let line, let column)) = error else { Issue.record("\(error)"); return }
            let log = try #require(try await fixture.store.logs(feedID: feed.id).first)
            let details = FeedLogDetails(log: log, feed: try await fixture.store.feed(id: feed.id), text: { $0 })
            #expect(details.statusKey == "download_error_parser_exception")
            #expect(details.technical == "Malformed XML at line \(line), column \(column).", "\(details.technical)")
            #expect(!details.technical.contains("parser_exception") && !(log.detail ?? "").contains("parser_exception"))
            #expect(details.clipboard.contains(details.technical))
            #expect(try await fixture.store.feed(id: feed.id)?.lastUpdateFailed == true, "the refusal stands")
        }
    }

    /// A refusal the app's parser cannot place (it reads the bytes) says so plainly; one with a detail keeps it.
    @Test func aRefusalTheAppsParserCannotPlaceIsWordedPlainly() throws {
        let readable = ParityParseError.parserException.readable(body: Self.rss(""))
        #expect(readable.detail == ParityParseError.unreadableFeed && readable.error == .parsing(.limitExceeded(ParityParseError.unreadableFeed)))
        let detailed = ParityParseError(label: "parser_exception", detail: "Feed has no title").readable(body: Data())
        #expect(detailed.detail == "Feed has no title" && detailed.error == .missingFeedTitle)
        let website = ParityParseError(label: "unsupported_type_html", detail: "Server returned html").readable(body: Data())
        #expect(website.detail == "Server returned html" && website.error == .websiteInsteadOfFeed)
    }

    // MARK: Pending registrations (PROTOCOL §15.2)

    @Test func anOutageSubscriptionRecordsItsDiscoveryAsDraftsAndMaterializesThem() async throws {
        try await withFixture { fixture in
            let feed = try await fixture.store.insert(Self.fetched(Self.base))
            #expect(try fixture.drafts().isEmpty, "the first population is never proposed or drafted")
            _ = try await refresh(fixture, feed, Self.base + [Item("g4", "Four", day: 4)])
            #expect(try await episode(fixture, guid: "g4").userState.playState == .new, "behaves fully as subscribed")
            let drafts = try fixture.drafts()
            #expect(drafts.map(\.type) == ["catalog.observe", "discovery.propose"])
            let op = try fixture.registrationOp(feedID: feed.id)
            #expect(try fixture.rows("SELECT generation_id, occurrence FROM ntp_ledger") == [["registration:\(op)", "local-episode:\(try await episode(fixture, guid: "g4").id)"]])
            let ids = try fixture.created(op)
            try await fixture.store.resolveRegistration(opID: op, .init(podcastID: ids.podcast, generationID: ids.generation, mode: "created", decisionID: nil))
            let facts = try fixture.outbox().filter { $0.type == "catalog.observe" || $0.type == "discovery.propose" }
            #expect(facts.map(\.type) == ["catalog.observe", "discovery.propose"])
            #expect(facts[0].payload["podcast_id"] == .string(ids.podcast))
            #expect(facts[0].targets.allSatisfy { $0["generation"] == nil })
            #expect(facts[1].payload["podcast_id"] == .string(ids.podcast) && facts[1].payload["generation_id"] == .string(ids.generation))
            let four = try await episode(fixture, guid: "g4")
            let wire = try #require(try fixture.wireID(four.id))
            #expect(facts[1].payload["episode"]?["episode_id"] == .string(wire))
            #expect(try fixture.rows("SELECT generation_id, occurrence FROM ntp_ledger") == [[ids.generation, wire]])
        }
    }

    /// PROTOCOL §9.4: observations are chunked within the fact bounds (at most 200 items a fact), the feed record with the first.
    @Test func largeObservationsAreChunked() async throws {
        try await withFixture { fixture in
            let feed = try await fixture.store.insert(Self.fetched(Self.base))
            let more = (4...453).map { Item("g\($0)", "Item \($0)", day: Double($0)) }
            _ = try await refresh(fixture, feed, Self.base + more, day: 500)
            let observations = try fixture.drafts().filter { $0.type == "catalog.observe" }
            #expect(observations.map { $0.template["payload"]?["items"]?.arrayValue?.count ?? 0 } == [200, 200, 53])
            #expect(observations.map { $0.template["payload"]?["feed"] != nil } == [true, false, false])
            #expect(Set(observations.compactMap { $0.template["payload"]?["batch_id"]?.stringValue }).count == 1)
            #expect(try fixture.drafts().filter { $0.type == "discovery.propose" }.count == 450)
        }
    }

    // MARK: Bounded observations (PROTOCOL §9.4 under PROTOCOL §6.8)

    /// 450 backfill items (older than the newest before the batch: observed, never proposed) and one release.
    static let large = base + (1...450).map { Item("b\($0)", "Back \($0)", day: -Double($0)) } + [Item("g4", "Four", day: 4)]

    private func observations(_ facts: [Fixture.Fact]) -> [[String]] {
        facts.filter { $0.type == "catalog.observe" }.map { ($0.payload["items"]?.arrayValue ?? []).compactMap { $0["fields"]?["title"]?.stringValue } }
    }

    /// A large batch's refresh observes only its releases and lists the rest; bounded transactions record them, 200
    /// to a fact, each complete on its own (its rows go with it), with the refresh's batch.
    @Test func aLargeBatchsObservationsAreRecordedInBoundedTransactions() async throws {
        try await withFixture { fixture in
            let (feed, _, _) = try await registered(fixture)
            let before = try fixture.outboxCount()
            let result = try await refresh(fixture, feed, Self.large)
            let inline = try fixture.newFacts(after: before)
            #expect(inline.map(\.type) == ["catalog.observe", "discovery.propose"])
            #expect(observations(inline) == [["Four"]], "the refresh's own transaction observes only its releases")
            #expect(try fixture.rows("SELECT count(*) FROM ntp_observation_work") == [["453"]])
            let listed = try fixture.outboxCount()
            // One bounded transaction: 200 recorded and unlisted together.
            let parse = ServerCatalogRecords.interim(Self.fetched(Self.large).feed)
            var inputs: [Int64: ServerCatalogParse.Item] = [:]
            for (local, index) in result.serverItems { inputs[local] = parse.items[index] }
            #expect(try await fixture.store.recordDeferredObservations(feedID: feed.id, inputs: inputs))
            #expect(observations(try fixture.newFacts(after: listed)).map(\.count) == [200])
            #expect(try fixture.rows("SELECT count(*) FROM ntp_observation_work") == [["253"]])
            // The refresh's drain records the rest with its parse.
            try await FeedLibraryStore.drainObservations(fixture.store, feedID: feed.id, catalog: parse, items: result.serverItems)
            let facts = try fixture.newFacts(after: listed)
            #expect(observations(facts).map(\.count) == [200, 200, 53])
            #expect(Set(observations(facts).joined()) == Set(Self.large.map(\.title)).subtracting(["Four"]))
            #expect(facts.allSatisfy { $0.payload["batch_id"] == inline[0].payload["batch_id"] && $0.payload["feed"] == nil })
            #expect(try fixture.rows("SELECT count(*) FROM ntp_observation_work") == [["0"]])
            // Every hash is noted: the same parse again records nothing.
            let count = try fixture.outboxCount()
            _ = try await refresh(fixture, feed, Self.large, day: 11)
            #expect(try fixture.outboxCount() == count)
        }
    }

    /// Observation facts stay within the unframed fact bound (PROTOCOL §6.4 256 KiB): their chunks count each item's
    /// whole entry (its record, and the episode reference with its occurrence, which repeats the title), so long titles
    /// never make every observation a framed fact, in the refresh's own transaction or in the bounded ones after it.
    @Test func observationFactsStayWithinTheUnframedBound() async throws {
        try await withFixture { fixture in
            let (feed, _, _) = try await registered(fixture)
            let long = String(repeating: "A long title for a framed fact. ", count: 40)
            let few = (1...150).map { Item("l\($0)", "\(long) \($0)", day: -Double($0)) }
            let many = (151...600).map { Item("l\($0)", "\(long) \($0)", day: -Double($0)) }
            let before = try fixture.outboxCount()
            _ = try await refresh(fixture, feed, Self.base + few)
            _ = try await refresh(fixture, feed, Self.base + few + many, day: 11)
            while try await fixture.store.recordDeferredObservations(feedID: nil) {}
            let facts = try fixture.newFacts(after: before).filter { $0.type == "catalog.observe" }
            #expect(Set(observations(facts).joined()).count == 603, "every item observed")
            let sizes = try fixture.rows("SELECT length(fact) FROM ntp_outbox WHERE type = 'catalog.observe'").compactMap { $0[0].flatMap { Int($0) } }
            #expect(!sizes.isEmpty && sizes.allSatisfy { $0 <= 256 << 10 }, "\(sizes)")
        }
    }

    /// What a process death left listed is recorded after a relaunch (before its next push), as the
    /// refresh parsed it, whatever the rows show since: canonical metadata projected onto a listed episode between two
    /// chunks never replaces or drops its observation; one whose canonical record equals the parse is noted, not sent.
    @Test func aRelaunchRecordsWhatTheLastProcessLeftListedAsItWasParsed() async throws {
        let fixture = try await Fixture()
        do {
            let (feed, podcast, _) = try await registered(fixture)
            _ = try await refresh(fixture, feed, Self.large)
            let listed = try fixture.outboxCount()
            #expect(try await fixture.store.recordDeferredObservations(feedID: feed.id), "one chunk, more left")
            // Canonical metadata arrives for two listed episodes: one differs from the parse, one equals it.
            let parse = ServerCatalogRecords.interim(Self.fetched(Self.large).feed)
            var records: [ServerRecord] = []
            for (guid, title) in [("b300", "Back 300 (canonical)"), ("b301", "Back 301")] {
                let wire = try #require(try fixture.wireID(try await episode(fixture, guid: guid).id))
                guard case .object(var fields)? = parse.items.first(where: { $0.evidence.guid == guid })?.fields else { return }
                fields["title"] = .string(title); fields["revision"] = .string(ContractIdentity.randomUUID())
                records.append(ServerRecord(entity: "episode", id: wire, fieldGroup: "metadata", value: .object(fields)))
            }
            try await ServerProjectionUnitTests.Applier(fixture).apply(records)
            #expect(try await episode(fixture, guid: "b300").details.title == "Back 300 (canonical)")
            try await fixture.store.close()
            let reopened = try FeedLibraryStore(url: fixture.url)
            while try await reopened.recordDeferredObservations(feedID: nil) {}
            let facts = try fixture.newFacts(after: listed)
            #expect(observations(facts).map(\.count) == [200, 199, 53], "the one equal to its canonical record is not sent")
            let observed = facts.flatMap { $0.payload["items"]?.arrayValue ?? [] }
            #expect(observed.allSatisfy { item in parse.items.contains { $0.fields == item["fields"] && $0.evidence.guid == item["episode"]?["occurrence"]?["guid"]?.stringValue } },
                    "each as the refresh parsed it")
            #expect(observations(facts).joined().contains("Back 300"), "the parse that differs from the canonical record is sent")
            #expect(!observations(facts).joined().contains("Back 301"), "one equal to it is noted")
            #expect(try fixture.rows("SELECT count(*) FROM ntp_observation_work") == [["0"]])
            // Every parse is noted: the same parse again records nothing.
            let count = try fixture.outboxCount()
            var options = FeedRefreshOptions(now: Self.date(11))
            options.globalNewEpisodesAction = .inbox
            _ = try await reopened.applyRefresh(Self.fetched(Self.large), feedID: feed.id, options: options)
            #expect(try fixture.outboxCount() == count)
            _ = podcast
            try await reopened.close()
        } catch { await fixture.close(); throw error }
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    /// First population: the first canonical metadata (podcast and episode) arrives before the
    /// listed first population is recorded, then the app relaunches and the next refresh is a 304. The parse's podcast
    /// and episode records are observed as they were parsed, where they differ from the canonical ones.
    @Test func aFirstPopulationsObservationSurvivesCanonicalProjectionARelaunchAndA304() async throws {
        let fixture = try await Fixture()
        do {
            let (feed, podcast, _) = try await fixture.subscribeRegistered(Self.fetched(Self.base))
            let wire = try fixture.expectedEpisodeID(podcast: podcast, guid: "g2")
            let parse = ServerCatalogRecords.interim(Self.fetched(Self.base).feed)
            guard case .object(var episodeFields) = parse.items[1].fields, case .object(var podcastFields) = parse.feedFields else { return }
            episodeFields["title"] = "Canonical Two"; episodeFields["revision"] = .string(ContractIdentity.randomUUID())
            podcastFields["title"] = "Canonical show"; podcastFields["revision"] = .string(ContractIdentity.randomUUID())
            try await fixture.store.retireEverythingForTesting()
            try await ServerProjectionUnitTests.Applier(fixture).apply([
                ServerMergeTests.identity(wire, podcast: podcast, guid: "g2"),
                ServerRecord(entity: "episode", id: wire, fieldGroup: "metadata", value: .object(episodeFields)),
                ServerRecord(entity: "podcast", id: podcast, fieldGroup: "metadata", value: .object(podcastFields))])
            #expect(try await episode(fixture, guid: "g2").details.title == "Canonical Two")
            #expect(try await fixture.store.feed(id: feed.id)?.metadata.title == "Canonical show")
            try await fixture.store.close()
            let reopened = try FeedLibraryStore(url: fixture.url)
            let before = try fixture.outboxCount()
            let service = FeedRefreshService(store: reopened, fetcher: FeedFetcher(transport: NotModified()), clock: { Self.date(1) })
            guard case .unchanged = try await service.refresh(feedID: feed.id) else { Issue.record("not a 304"); try await reopened.close(); return }
            let facts = try fixture.newFacts(after: before).filter { $0.type == "catalog.observe" }
            #expect(facts.compactMap { $0.payload["feed"]?["fields"]?["title"]?.stringValue } == ["Show"], "the parse's podcast record")
            #expect(observations(facts).joined().contains("Two"), "the parse's episode record")
            #expect(!observations(facts).joined().contains("Canonical Two"))
            #expect(try fixture.rows("SELECT count(*) FROM ntp_observation_work") == [["0"]])
            try await reopened.close()
        } catch { await fixture.close(); throw error }
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    /// A library holding the earlier, never shipped `ntp_observation_work` (keyed by `local_id`,
    /// without the parse), empty or with rows, opens: the table is recreated (the next refresh observes again), and
    /// observations are listed and recorded as before.
    @Test(arguments: [false, true]) func aLibraryWithTheEarlierObservationTableOpens(_ populated: Bool) async throws {
        let fixture = try await Fixture()
        do {
            let (feed, podcast, _) = try await fixture.subscribeRegistered(Self.fetched(Self.base))
            try await fixture.store.executeForTesting("DROP TABLE ntp_observation_work")
            try await fixture.store.executeForTesting("CREATE TABLE ntp_observation_work (local_id INTEGER PRIMARY KEY REFERENCES episodes(id) ON DELETE CASCADE, feed_id INTEGER NOT NULL, batch_id TEXT NOT NULL, fetch_time INTEGER NOT NULL, hash TEXT NOT NULL)")
            if populated {
                for episode in feed.episodes {
                    try await fixture.store.executeForTesting("INSERT INTO ntp_observation_work(local_id, feed_id, batch_id, fetch_time, hash) VALUES (?, ?, 'b', 0, 'h')",
                                                              [.integer(episode.id), .integer(feed.id)])
                }
            }
            try await fixture.store.close()
            let reopened = try FeedLibraryStore(url: fixture.url)
            #expect(try fixture.rows("SELECT count(*) FROM ntp_observation_work") == [["0"]], "recreated")
            try await reopened.executeForTesting("INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('podcast', ?, 'metadata', ?, '[]')",
                                                 [.text(podcast), .blob(try (["title": "Show"] as ContractJSON).canonicalData())])
            let before = try fixture.outboxCount()
            var options = FeedRefreshOptions(now: Self.date(10))
            options.globalNewEpisodesAction = .inbox
            _ = try await reopened.applyRefresh(Self.fetched(Self.large), feedID: feed.id, options: options)
            #expect(try fixture.rows("SELECT count(*) FROM ntp_observation_work WHERE local_id IS NOT NULL") == [["453"]])
            while try await reopened.recordDeferredObservations(feedID: nil) {}
            #expect(observations(try fixture.newFacts(after: before)).joined().count == 454)
            try await reopened.close()
        } catch { await fixture.close(); throw error }
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    /// While an earlier registration of the feed (a preview's, registered by a favorite) still holds
    /// drafts, the podcast's facts join that chain, so its listed observations wait, never drained as if done: the
    /// drain reports nothing to do, keeps them, and push and pull go on. Once that registration resolves they are
    /// recorded.
    @Test func listedObservationsWaitWhileAnEarlierRegistrationHoldsDrafts() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let preview = try await store.preparePreview(Self.fetched(Self.base), now: Fixture.now)
            let ids = preview.episodes.map(\.id).sorted()
            try await store.setFavorite(episodeID: ids[0], favorite: true)
            let register = try fixture.registrationOp(feedID: preview.id)
            #expect(try await store.subscribePreview(feedID: preview.id))
            let subscribe = try fixture.registrationOp(feedID: preview.id)
            let created = try fixture.created(register)
            try await store.resolveRegistration(opID: subscribe, .init(podcastID: created.podcast, generationID: created.generation, mode: "joined", decisionID: nil))
            try await store.executeForTesting("INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('podcast', ?, 'metadata', ?, '[]')",
                                              [.text(created.podcast), .blob(try (["title": "Show"] as ContractJSON).canonicalData())])
            let listed = try fixture.rows("SELECT count(*) FROM ntp_observation_work")
            #expect(listed != [["0"]])
            let before = try fixture.outboxCount(), drafts = try fixture.drafts().count
            #expect(try await store.recordDeferredObservations(feedID: nil) == false, "nothing it can record yet")
            #expect(try await store.recordDeferredObservations(feedID: preview.id) == false)
            try await FeedLibraryStore.drainObservations(store, feedID: preview.id, catalog: nil, items: [:])
            #expect(try fixture.rows("SELECT count(*) FROM ntp_observation_work") == listed, "kept")
            #expect(try fixture.outboxCount() == before && fixture.drafts().count == drafts)
            try await store.resolveRegistration(opID: register, .init(podcastID: created.podcast, generationID: created.generation, mode: "created", decisionID: nil))
            while try await store.recordDeferredObservations(feedID: nil) {}
            #expect(try fixture.rows("SELECT count(*) FROM ntp_observation_work") == [["0"]])
            #expect(try fixture.outbox().contains { $0.type == "catalog.observe" })
        }
    }

    // MARK: First populations (PROTOCOL §15.2)

    private struct NotModified: FeedHTTPTransport {
        func send(_ request: URLRequest) async throws -> FeedHTTPResponse { FeedHTTPResponse(url: request.url!, status: 304, body: Data()) }
    }

    /// A subscription's first population is observed once the podcast's first canonical metadata arrives or its wait
    /// ends, never proposed or filed: here the server never fetched the feed, the wait ends, and the next refresh is a
    /// 304.
    @Test func aFirstPopulationIsObservedWhenItsWaitEndsEvenAfterAConditionalRefresh() async throws {
        try await withFixture { fixture in
            let (feed, podcast, _) = try await fixture.subscribeRegistered(Self.fetched(Self.base))
            let service = FeedRefreshService(store: fixture.store, fetcher: FeedFetcher(transport: NotModified()), clock: { Self.date(1) })
            let before = try fixture.outboxCount()
            guard case .unchanged = try await service.refresh(feedID: feed.id) else { Issue.record("not a 304"); return }
            #expect(try fixture.outboxCount() == before, "the first population waits for the first canonical metadata")
            try await fixture.store.executeForTesting("UPDATE ntp_registrations SET created_at = created_at - ?", [.integer(Int64(11 * 60_000))])
            guard case .unchanged = try await service.refresh(feedID: feed.id) else { Issue.record("not a 304"); return }
            let facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["catalog.observe"], "observed, never proposed")
            #expect(facts.first?.payload["podcast_id"] == .string(podcast) && facts.first?.payload["feed"] != nil)
            #expect(Set((facts.first?.payload["items"]?.arrayValue ?? []).compactMap { $0["fields"]?["title"]?.stringValue }) == ["One", "Two", "Three"])
            #expect(try fixture.rows("SELECT count(*) FROM ntp_ledger") == [["0"]])
            #expect(try fixture.rows("SELECT count(*) FROM ntp_observation_work") == [["0"]])
        }
    }

    /// The first canonical metadata ends the wait: the next push records the first population (and a batch's
    /// observations that waited with it).
    @Test func aFirstPopulationIsObservedWhenTheFirstCanonicalMetadataArrives() async throws {
        try await withFixture { fixture in
            let (feed, podcast, _) = try await fixture.subscribeRegistered(Self.fetched(Self.base))
            // A refresh while waiting: its release is observed and proposed, the rest waits.
            _ = try await refresh(fixture, feed, Self.base.map { $0.guid == "g2" ? Item("g2", "Two, corrected", day: 2) : $0 } + [Item("g4", "Four", day: 4)])
            let before = try fixture.outboxCount()
            #expect(try await fixture.store.recordDeferredObservations(feedID: nil) == false, "still waiting")
            #expect(try fixture.outboxCount() == before)
            try await fixture.store.executeForTesting("INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('podcast', ?, 'metadata', ?, '[]')",
                                                      [.text(podcast), .blob(try (["title": "Show", "revision": .string(ContractIdentity.randomUUID())] as ContractJSON).canonicalData())])
            while try await fixture.store.recordDeferredObservations(feedID: nil) {}
            let facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["catalog.observe"])
            #expect(Set((facts.first?.payload["items"]?.arrayValue ?? []).compactMap { $0["fields"]?["title"]?.stringValue }) == ["One", "Two, corrected", "Three"])
            #expect(try fixture.rows("SELECT count(*) FROM ntp_observation_work") == [["0"]])
        }
    }

    // MARK: The ledger (PROTOCOL §9.9)

    @Test func theLedgerDrivesDownloadsAndNotificationsOncePerRelease() async throws {
        try await withFixture { fixture in
            let (feed, _, _) = try await registered(fixture)
            try await fixture.store.updatePreferences(feedID: feed.id) { $0.showEpisodeNotification = true }
            _ = try await refresh(fixture, feed, Self.base + [Item("g4", "Four", day: 4), Item("g5", "Five", day: 5)])
            let notifications = try await fixture.store.serverReleaseNotifications()
            #expect(notifications.map(\.count) == [2] && notifications.first?.title == "Show")
            try await fixture.store.markServerReleasesNotified(notifications.flatMap(\.keys))
            #expect(try await fixture.store.serverReleaseNotifications().isEmpty)
            let candidates = try #require(try await fixture.store.serverReleaseCandidates())
            #expect(candidates.count == 2)
            try await fixture.store.finishServerReleases(candidates)
            #expect(try await fixture.store.serverReleaseCandidates() == [])
        }
    }

    /// PROTOCOL §9.10, §9.9: the automatic download takes a release whose action is not the Inbox, once; a release the network
    /// blocks stays pending, one nobody will download (played) is done; NEW episodes alone are no candidates.
    @MainActor @Test func theAutomaticDownloadTakesReleasesOnce() async throws {
        let fixture = try await Fixture()
        do {
            let (feed, _, _) = try await registered(fixture, action: .nothing)
            try await fixture.store.updatePreferences(feedID: feed.id) { $0.autoDownload = .enabled }
            let one = try await episode(fixture, guid: "g1")
            try await fixture.store.projectForTesting(one.id) { $0.userState.playState = .new }
            _ = try await refresh(fixture, feed, Self.base + [Item("g4", "Four", day: 4), Item("g5", "Five", day: 5)])
            let five = try await episode(fixture, guid: "g5")
            try await fixture.store.markEpisodePlayed(episodeID: five.id, played: true)
            var downloads: [Int64] = []
            var preferences = AutomaticDownloadPreferences(); preferences.cacheSize = -1
            let selected = preferences
            let blocked = AutomaticDownloadCoordinator(store: fixture.store, preferences: { selected },
                environment: { .init(connection: .wifi(metered: true), allowMobile: false, charging: true) },
                cleanup: { _ in }, download: { downloads.append($0) })
            try await blocked.run()
            #expect(downloads.isEmpty)
            #expect(try await fixture.store.serverReleaseCandidates()?.count == 2, "a blocked attempt keeps its releases pending")
            let admitted = AutomaticDownloadCoordinator(store: fixture.store, preferences: { selected },
                environment: { .init(connection: .ethernet, allowMobile: false, charging: true) },
                cleanup: { _ in }, download: { downloads.append($0) })
            try await admitted.run()
            let four = try await episode(fixture, guid: "g4").id
            #expect(downloads == [four], "the release, not the NEW episode or the played one")
            #expect(try await fixture.store.serverReleaseCandidates() == [])
            try await admitted.run()
            #expect(downloads.count == 1, "once")
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    @MainActor @Test func releaseNotificationsAreDeliveredOnceAsAntennaPodShowsThem() async throws {
        let fixture = try await Fixture()
        do {
            let (feed, _, _) = try await registered(fixture)
            try await fixture.store.updatePreferences(feedID: feed.id) { $0.showEpisodeNotification = true }
            let publisher = EpisodeNotificationDeliveryTests.Publisher()
            let delivery = EpisodeNotificationDelivery(store: fixture.store, publisher: publisher,
                text: .init(title: { "\($0) new" }, message: { "\($0) in \($1)" }, summary: "summary"), artwork: { _ in nil })
            _ = try await refresh(fixture, feed, Self.base + [Item("g4", "Four", day: 4)])
            try await delivery.deliverServerReleases()
            #expect(publisher.posts.map(\.identifier) == [EpisodeNotificationPublication.feedID(feed.id), EpisodeNotificationPublication.summaryID])
            #expect(publisher.posts.map(\.alerts) == [false, true] && publisher.posts[0].title == "1 new")
            try await delivery.deliverServerReleases()
            #expect(publisher.posts.count == 2, "once per release")
            // Notifications off: a later release is only marked.
            try await fixture.store.updatePreferences(feedID: feed.id) { $0.showEpisodeNotification = false }
            _ = try await refresh(fixture, feed, Self.base + [Item("g4", "Four", day: 4), Item("g5", "Five", day: 5)], day: 12)
            try await delivery.deliverServerReleases()
            let left = try await fixture.store.serverReleaseNotifications()
            #expect(publisher.posts.count == 2 && left.isEmpty)
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    /// What changes while a release notification's artwork loads decides it: notifications
    /// turned off then publish nothing (the releases are marked, as for a podcast whose notifications are off), and a
    /// cancelled delivery publishes nothing and leaves the releases for the next delivery.
    @MainActor @Test(arguments: [false, true]) func aReleaseNotificationIsCheckedAgainAfterItsArtwork(_ cancel: Bool) async throws {
        let fixture = try await Fixture()
        do {
            let (feed, _, _) = try await registered(fixture)
            try await fixture.store.updatePreferences(feedID: feed.id) { $0.showEpisodeNotification = true }
            let publisher = EpisodeNotificationDeliveryTests.Publisher()
            let gate = EpisodeNotificationDeliveryTests.Gate()
            let delivery = EpisodeNotificationDelivery(store: fixture.store, publisher: publisher,
                text: .init(title: { "\($0) new" }, message: { "\($0) in \($1)" }, summary: "summary"), artwork: { _ in await gate.hold() })
            _ = try await refresh(fixture, feed, Self.base + [Item("g4", "Four", day: 4)])
            let task = Task { try await delivery.deliverServerReleases() }
            while !(await gate.entered) { await Task.yield() }
            if cancel { task.cancel() } else { try await fixture.store.updatePreferences(feedID: feed.id) { $0.showEpisodeNotification = false } }
            await gate.release()
            _ = await task.result
            #expect(publisher.posts.isEmpty, "nothing published")
            let left = try await fixture.store.serverReleaseNotifications()
            #expect(cancel ? left.flatMap(\.keys).count == 1 : left.isEmpty, cancel ? "kept for the next delivery" : "marked")
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    /// A release whose notification failed to publish (or whose app ended before it) stays owed,
    /// and the next delivery, which a later exchange, the launch or the foreground starts, publishes it once.
    @MainActor @Test func anOwedReleaseNotificationIsDeliveredByTheNextDelivery() async throws {
        let fixture = try await Fixture()
        do {
            let (feed, _, _) = try await registered(fixture)
            try await fixture.store.updatePreferences(feedID: feed.id) { $0.showEpisodeNotification = true }
            let publisher = EpisodeNotificationDeliveryTests.Publisher()
            publisher.fail = [EpisodeNotificationPublication.feedID(feed.id)]
            let delivery = EpisodeNotificationDelivery(store: fixture.store, publisher: publisher,
                text: .init(title: { "\($0) new" }, message: { "\($0) in \($1)" }, summary: "summary"), artwork: { _ in nil })
            _ = try await refresh(fixture, feed, Self.base + [Item("g4", "Four", day: 4)])
            await #expect(throws: (any Error).self) { try await delivery.deliverServerReleases() }
            #expect(try await fixture.store.serverReleaseNotifications().map(\.count) == [1], "still owed")
            publisher.fail = []
            try await delivery.deliverServerReleases()
            try await delivery.deliverServerReleases()
            #expect(publisher.posts.map(\.identifier) == [EpisodeNotificationPublication.feedID(feed.id), EpisodeNotificationPublication.summaryID])
            #expect(try await fixture.store.serverReleaseNotifications().isEmpty)
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    /// The library's owed-notification deliveries have one owner. Wakes while one runs (launch,
    /// foreground, exchanges) coalesce into it; stopping the library's sync stops it, publishes nothing more, settles
    /// before it returns, and takes no new wakes.
    @MainActor @Test func stoppingALibrarysSyncStopsEveryReleaseNotificationDelivery() async throws {
        let fixture = try await Fixture()
        do {
            let (feed, _, _) = try await registered(fixture)
            try await fixture.store.updatePreferences(feedID: feed.id) { $0.showEpisodeNotification = true }
            let publisher = EpisodeNotificationDeliveryTests.Publisher()
            let gate = EpisodeNotificationDeliveryTests.Gate()
            let artworks = DeliveryCounter()
            let delivery = EpisodeNotificationDelivery(store: fixture.store, publisher: publisher,
                text: .init(title: { "\($0) new" }, message: { "\($0) in \($1)" }, summary: "summary"),
                artwork: { _ in artworks.increment(); return await gate.hold() })
            let owner = ServerReleaseDeliveryOwner(delivery: delivery, failed: { _ in })
            _ = try await refresh(fixture, feed, Self.base + [Item("g4", "Four", day: 4)])
            owner.wake()
            while !(await gate.entered) { await Task.yield() }
            owner.wake(); owner.wake(); owner.wake()
            let stopping = Task { await owner.stop() }
            while !owner.isStopped { await Task.yield() }
            owner.wake()
            await gate.release()
            await stopping.value
            #expect(publisher.posts.isEmpty, "nothing published after the stop")
            #expect(artworks.value == 1, "one delivery at a time, none after the stop")
            #expect(try await fixture.store.serverReleaseNotifications().flatMap(\.keys).count == 1, "still owed")
            // A new owner (the library's sync started again) delivers it once, however many wakes.
            let next = ServerReleaseDeliveryOwner(delivery: EpisodeNotificationDelivery(store: fixture.store, publisher: publisher,
                text: .init(title: { "\($0) new" }, message: { "\($0) in \($1)" }, summary: "summary"), artwork: { _ in nil }), failed: { _ in })
            next.wake(); next.wake(); next.wake()
            await next.settled()
            #expect(publisher.posts.map(\.identifier) == [EpisodeNotificationPublication.feedID(feed.id), EpisodeNotificationPublication.summaryID])
            await next.stop()
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    @Test func aStandaloneLibraryHasNoLedger() async throws {
        let fixture = try await Fixture(server: false)
        do {
            _ = try await fixture.store.insert(Self.fetched(Self.base))
            #expect(try await fixture.store.serverReleaseCandidates() == nil)
            #expect(try await fixture.store.serverReleaseNotifications().isEmpty)
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }
}

extension FeedLibraryStore {
    func executeForTesting(_ sql: String, _ values: [LibrarySQLValue] = []) throws {
        try database.transaction { try database.execute(sql, values) }
    }
}

/// A count across tasks.
private final class DeliveryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

// MARK: - Observations within the fact bound (PROTOCOL §6.13)

extension ServerDiscoveryTests {
    /// Under the bound the server advertises, an item too large with its occurrence (over half the bound) is not observed,
    /// nor a podcast record too large for a fact with its items; the other items are observed, and the log says so.
    @Test(arguments: [false, true]) func anItemOrPodcastRecordTooLargeIsNotObservedWhileTheOthersAre(feedHeader: Bool) async throws {
        try await withFixture { fixture in
            let (feed, _, _) = try await registered(fixture)
            await fixture.store.setServerFactBoundForTesting(8_000)
            _ = await fixture.store.takeServerDiagnostics()
            let before = try fixture.outboxCount()
            let long = String(repeating: "and so on ", count: 400)
            // Two changed records: the second's title is too large (the item case), or the podcast's title is (the header case).
            let items = [Item("g1", "One", day: 1), Item("g2", feedHeader ? "Two!" : "Two " + long, day: 2), Item("g3", "Three!", day: 3)]
            var options = FeedRefreshOptions(now: Self.date(10))
            options.globalNewEpisodesAction = .inbox
            _ = try await fixture.store.applyRefresh(Self.fetched(items, title: feedHeader ? "Show " + long : "Show"), feedID: feed.id, options: options)
            let facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["catalog.observe"])
            let observed = (facts.first?.payload["items"]?.arrayValue ?? []).compactMap { $0["fields"]?["title"]?.stringValue }
            #expect(Set(observed) == (feedHeader ? ["One", "Two!", "Three!"] : ["One", "Three!"]), "\(observed)")
            #expect((facts.first?.payload["feed"] == nil) == feedHeader, "the podcast record is observed only when it fits")
            let lines = await fixture.store.takeServerDiagnostics().filter { $0.kind == "too_large" }.map(\.detail)
            #expect(lines.count == 1 && lines[0].hasPrefix("catalog.observe") && lines[0].hasSuffix("not observed"), "\(lines)")
        }
    }
}
