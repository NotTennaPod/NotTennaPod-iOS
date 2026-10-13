import Foundation
import Testing
@testable import NotTennaPodCore

/// PROTOCOL §16's discovery scenarios against the pinned server (PROTOCOL §9): phones refresh a
/// loopback feed server with the parity parse, propose and file their releases, and converge with each other and
/// with the server's own fetches, in the arrival orders and across the crash points each scenario names.
@Suite(.serialized, .timeLimit(.minutes(30))) struct ServerDiscoveryScenarioTests {
    typealias Agreement = ServerExchangeAgreementTests
    typealias Concurrency = ServerExchangeConcurrencyTests

    struct Item {
        var guid: String?
        var title: String
        var day: Double?
        var enclosure: String?
        var duration: String? = nil
    }

    static let epoch = Date(timeIntervalSince1970: 1_760_000_000)
    static func date(_ day: Double) -> Date { epoch.addingTimeInterval(day * 86_400) }

    static func rfc822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    static func document(_ title: String, _ items: [Item]) -> Data {
        let body = items.map { item in
            var xml = "<item><title>\(item.title)</title>"
            if let guid = item.guid { xml += "<guid>\(guid)</guid>" }
            if let day = item.day { xml += "<pubDate>\(rfc822(date(day)))</pubDate>" }
            if let enclosure = item.enclosure { xml += "<enclosure url=\"\(enclosure)\" length=\"1000\" type=\"audio/mpeg\"/>" }
            if let duration = item.duration { xml += "<itunes:duration>\(duration)</itunes:duration>" }
            return xml + "</item>"
        }.joined()
        return Data("""
            <?xml version="1.0"?><rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>\
            <title>\(title)</title><link>https://example.com/</link>\(body)</channel></rss>
            """.utf8)
    }

    static func items(_ prefix: String, _ days: ClosedRange<Int>) -> [Item] {
        days.map { Item(guid: "\(prefix)-\($0)", title: "\(prefix) \($0)", day: Double($0), enclosure: "https://media.example/\(prefix)-\($0).mp3") }
    }

    /// The publisher serves `items` at `path`.
    static func serve(_ world: ExchangeWorld, _ path: String, _ title: String, _ items: [Item]) {
        world.setResponse(path, .init(headers: ["Content-Type": "application/rss+xml"], body: document(title, items)))
    }

    /// A subscription as the app makes it: the feed fetched with the app's parser, then inserted (`podcast.subscribe`),
    /// and the server's own first fetch waited for.
    static func subscribe(_ phone: ExchangePhone, _ url: String) async throws -> LibraryFeed {
        guard case .updated(let fetched) = try await FeedFetcher().fetch(FeedFetchRequest(source: url)) else { throw HarnessError.server("no feed at \(url)") }
        let feed = try await phone.store.insert(fetched)
        try await Agreement.waitForCatalog(phone, feedID: feed.id)
        return feed
    }

    /// A refresh as the app runs it: fetched and parsed (the parity parse in a server library), merged, then a queue
    /// filing consumed.
    @discardableResult
    static func refresh(_ phone: ExchangePhone, _ feedID: Int64, consume: Bool = true) async throws -> FeedRefreshService.Outcome {
        let outcome = try await FeedRefreshService(store: phone.store).refresh(feedID: feedID, force: true)
        if consume { _ = try await phone.store.consumeFeedRefreshQueueEffects(location: .back) }
        return outcome
    }

    static func local(_ phone: ExchangePhone, guid: String) async throws -> LibraryEpisode? {
        try await phone.store.feeds().flatMap(\.episodes).first { $0.details.identifier == guid }
    }

    /// Exchanges until `condition` holds (the server's own fetch is asynchronous): waits for it, never a fixed time.
    static func exchange(until condition: @escaping () async throws -> Bool, _ phones: [ExchangePhone], label: String,
                         deadline: Duration = .seconds(60)) async throws {
        let clock = ContinuousClock(), end = clock.now.advanced(by: deadline)
        while clock.now < end {
            for phone in phones { await phone.exchange() }
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HarnessError.server("\(label): the condition never held")
    }

    /// Asks the server to fetch the podcast now (as pull to refresh does, PROTOCOL §9).
    static func serverRefresh(_ phone: ExchangePhone, podcast: String) async throws {
        _ = try await phone.transport.server.send("POST", "v1/refresh", body: ["podcast_id": .string(podcast)])
    }

    static func admission(_ phone: ExchangePhone, _ episode: String) throws -> ContractJSON? {
        guard let text = try phone.rows("SELECT CAST(value AS TEXT) FROM ntp_records WHERE entity = 'episode' AND id = '\(episode)' AND field_group = 'admission'").first?.first ?? nil else { return nil }
        return try ContractJSON.decode(text)
    }

    static func outcomes(_ phone: ExchangePhone, _ type: String) async throws -> [String] {
        try await phone.engine.logEntries().filter { $0.kind == "outcome" && $0.detail.hasPrefix(type) }.map(\.detail)
    }

    static func ledger(_ phone: ExchangePhone) throws -> [[String?]] {
        try phone.rows("SELECT occurrence, state, notified FROM ntp_ledger ORDER BY occurrence")
    }

    // MARK: - 14: two phones and the server discover the same episode

    /// 14. Two phones discover the same new episode while the server is away (and the server does too): it is filed
    /// once, as the first admitted proposal says, and an explicit action on either phone survives. Every arrival order,
    /// and A's push stored by the server while A's app ends before it reads the answer.
    @Test(arguments: ["A", "C", "server", "A-crash"]) func scenario14OneEpisodeDiscoveredThreeTimesIsFiledOnce(_ first: String) async throws {
        try await ExchangeWorld.run { world in
            Self.serve(world, "/s14.xml", "S14", Self.items("s14", 1...3))
            let a = try await world.attach("A")
            let feed = try await Self.subscribe(a, world.url("s14.xml"))
            let podcast = try #require(try await a.store.podcastOfFeedForTesting(feed.id))
            let c = try await world.attach("C")
            let cFeed = try await Concurrency.feed(of: podcast, on: c)
            world.server.stop(keepingData: true)
            Self.serve(world, "/s14.xml", "S14", Self.items("s14", 1...4))
            try await Self.refresh(a, feed.id)
            try await Self.refresh(c, cFeed)
            #expect(try await Self.local(a, guid: "s14-4")?.userState.playState == .new, "filed at once, offline")
            let cFour = try #require(try await Self.local(c, guid: "s14-4"))
            #expect(cFour.userState.playState == .new)
            try await c.store.markEpisodePlayed(episodeID: cFour.id, played: true)
            try await world.server.launch()
            let aFour = try #require(try await Self.local(a, guid: "s14-4"))
            let wire = try #require(try await a.store.wireEpisodeForTesting(aFour.id))
            #expect(try await c.store.wireEpisodeForTesting(cFour.id) == wire, "both phones derive the same episode")
            switch first {
            case "server":
                try await Self.serverRefresh(a, podcast: podcast)
                try await Self.exchange(until: { try Self.admission(a, wire) != nil }, [a], label: "server admission")
            case "C": await c.exchange(); await a.exchange()
            case "A-crash":
                await a.engine.setCrashPoint(ServerExchangePushPullTests.crashOnce(at: "push.response"))
                #expect(await a.engine.exchange().error == "InjectedCrash()")
                try await a.relaunch()
                await a.exchange(); await c.exchange()
            default: await a.exchange(); await c.exchange()
            }
            try await Concurrency.converge(world, [a, c], "s14-\(first)")
            let admission = try #require(try Self.admission(a, wire))
            let proposals = (try await Self.outcomes(a, "discovery.propose")) + (try await Self.outcomes(c, "discovery.propose"))
            switch first {
            case "server":
                #expect(admission["proposal_id"] == .null, "the server's own discovery was first")
                #expect(proposals.filter { $0.hasSuffix("already_admitted") }.count == 2)
            default:
                #expect(admission["proposal_id"] != .null)
                #expect(proposals.filter { $0.hasSuffix("already_admitted") }.count == 1, "the later proposal never re-files: \(proposals)")
            }
            for phone in [a, c] {
                #expect(try await Self.local(phone, guid: "s14-4")?.userState.playState == .played, "C's explicit action survives on \(phone.name)")
                #expect(try Self.ledger(phone).filter { $0[0] == wire }.count == 1, "one release on \(phone.name)")
            }
        }
    }

    // MARK: - 15: the queue action

    /// 15. A podcast whose new-episodes action is "queue" files a new episode into the queue at the account's enqueue
    /// location, once, also when the app ended between the refresh and its filing (the effect keeps the evidence).
    @Test func scenario15AQueueFilingIsMadeOnce() async throws {
        try await ExchangeWorld.run { world in
            Self.serve(world, "/s15.xml", "S15", Self.items("s15", 1...3))
            let a = try await world.attach("A")
            let feed = try await Self.subscribe(a, world.url("s15.xml"))
            let podcast = try #require(try await a.store.podcastOfFeedForTesting(feed.id))
            try await a.store.updatePreferences(feedID: feed.id) { $0.newEpisodesAction = .queue }
            let one = try #require(try await Self.local(a, guid: "s15-1"))
            _ = try await a.store.enqueue([one.id])
            await a.exchange()
            let c = try await world.attach("C")
            let cFeed = try await Concurrency.feed(of: podcast, on: c)
            #expect(try await c.store.feed(id: cFeed)?.newEpisodesAction == .queue)
            Self.serve(world, "/s15.xml", "S15", Self.items("s15", 1...4))
            // A's app ends between the refresh's commit and its queue filing.
            try await Self.refresh(a, feed.id, consume: false)
            try await a.relaunch()
            _ = try await a.store.consumeFeedRefreshQueueEffects(location: .back)
            try await Self.refresh(c, cFeed)
            let four = try #require(try await Self.local(a, guid: "s15-4"))
            #expect(try await a.store.queue().map(\.id) == [one.id, four.id], "filed at the back")
            await a.exchange(); await c.exchange()
            try await Concurrency.converge(world, [a, c], "s15")
            let wire = try #require(try await a.store.wireEpisodeForTesting(four.id))
            #expect(try Self.admission(a, wire)?["action"] == "queue")
            for phone in [a, c] {
                let queue = try await phone.view().queue
                #expect(queue.filter { $0 == wire }.count == 1 && queue.last == wire, "\(phone.name): once, at the back")
            }
            #expect(try await Self.outcomes(c, "discovery.propose").contains { $0.hasSuffix("already_admitted") })
        }
    }

    // MARK: - 16, 17a, 38: first population, backfill, gained media, releases found elsewhere

    /// 16, 17a and 38. A subscription's first population (a feed of 200) files nothing and makes no release; an old
    /// episode added later (backfill) neither; an item that gains its audio later is filed once; a release the server
    /// found reaches a phone's ledger (download and notification) once, and a phone attaching later sees it as seen.
    @Test func scenario16And38FirstPopulationAndBackfillAreNoReleases() async throws {
        try await ExchangeWorld.run { world in
            Self.serve(world, "/s16.xml", "S16", Self.items("s16", 100...299))
            let a = try await world.attach("A")
            let feed = try await Self.subscribe(a, world.url("s16.xml"))
            let podcast = try #require(try await a.store.podcastOfFeedForTesting(feed.id))
            #expect(try await a.store.feeds().flatMap(\.episodes).allSatisfy { $0.userState.playState != .new })
            // Backfill: an old episode appears; and an item without its audio yet.
            var items = Self.items("s16", 100...299) + [Item(guid: "s16-old", title: "old", day: 1, enclosure: "https://media.example/old.mp3"),
                                                        Item(guid: "s16-late", title: "late", day: 300, enclosure: nil)]
            Self.serve(world, "/s16.xml", "S16", items)
            try await Self.refresh(a, feed.id)
            #expect(try await Self.local(a, guid: "s16-old")?.userState.playState == .unplayed, "backfill is never filed")
            #expect(try await Self.local(a, guid: "s16-late")?.userState.playState == .unplayed, "an item without audio is catalog-only")
            #expect(try Self.ledger(a).isEmpty)
            await a.exchange()
            // The audio arrives: filed once, here and nowhere twice.
            items[items.count - 1].enclosure = "https://media.example/late.mp3"
            Self.serve(world, "/s16.xml", "S16", items)
            try await Self.refresh(a, feed.id)
            let late = try #require(try await Self.local(a, guid: "s16-late"))
            #expect(late.userState.playState == .new, "gained media is a release")
            await a.exchange()
            let lateWire = try #require(try await a.store.wireEpisodeForTesting(late.id))
            #expect(try await Self.outcomes(a, "discovery.propose").isEmpty, "admitted (only refusals are logged)")
            #expect(try Self.admission(a, lateWire)?["action"] == "inbox")
            // A release the server finds itself reaches A once; a phone attaching afterwards sees it as seen.
            items.append(Item(guid: "s16-new", title: "new", day: 301, enclosure: "https://media.example/new.mp3"))
            Self.serve(world, "/s16.xml", "S16", items)
            try await Self.serverRefresh(a, podcast: podcast)
            try await Self.exchange(until: { try await Self.local(a, guid: "s16-new") != nil }, [a], label: "server release")
            let found = try #require(try await Self.local(a, guid: "s16-new"))
            let wire = try #require(try await a.store.wireEpisodeForTesting(found.id))
            #expect(try Self.ledger(a).filter { $0[0] == wire } == [[wire, "pending", "0"]], "a release found by the server")
            #expect(try await a.store.serverReleaseNotifications().flatMap(\.keys).count == 2)
            let c = try await world.attach("C")
            #expect(try Self.ledger(c).allSatisfy { $0[1] == "done" && $0[2] == "1" }, "an attach snapshot's admissions are seen")
            #expect(try await c.store.feeds().flatMap(\.episodes).filter { $0.userState.playState == .new }.count == 2)
        }
    }

    /// A large batch's observations (PROTOCOL §9.4 in PROTOCOL §6.8 bounded transactions) that a process death left listed after its
    /// refresh committed are recorded before the next push, and reach the server.
    @Test func aLargeBatchsObservationsLeftListedReachTheServerWithTheNextPush() async throws {
        try await ExchangeWorld.run { world in
            Self.serve(world, "/large.xml", "Large", Self.items("large", 300...302))
            let a = try await world.attach("A")
            let feed = try await Self.subscribe(a, world.url("large.xml"))
            Self.serve(world, "/large.xml", "Large", Self.items("large", 1...250) + Self.items("large", 300...302))
            // The refresh commits; the process ends before its observations are drained.
            guard case .updated(let fetched) = try await FeedFetcher().fetch(FeedFetchRequest(source: world.url("large.xml"), force: true, parity: true)) else {
                throw HarnessError.server("no feed")
            }
            _ = try await a.store.applyRefresh(fetched, feedID: feed.id, options: .init(now: Date()))
            #expect(try a.rows("SELECT count(*) FROM ntp_observation_work") != [["0"]])
            let one = try #require(try await Self.local(a, guid: "large-1"))
            await a.exchange()
            #expect(try a.rows("SELECT count(*) FROM ntp_observation_work") == [["0"]])
            #expect(try await Self.outcomes(a, "catalog.observe").isEmpty, "accepted (only refusals are logged)")
            let wire = try #require(try await a.store.wireEpisodeForTesting(one.id))
            try await Self.exchange(until: { try a.rows("SELECT count(*) FROM ntp_records WHERE entity = 'episode' AND id = '\(wire)' AND field_group = 'metadata'") == [["1"]] },
                                    [a], label: "the observed backfill's canonical record")
        }
    }

    /// A still files new episodes to the queue while B, first, changed the action; both find the same
    /// release and B's proposal is admitted. A's losing queue filing leaves A's queue (its prediction is withdrawn like a
    /// refused add's), also after a relaunch, and both phones converge.
    @Test(arguments: ["nothing", "inbox"]) func aLosingQueueFilingLeavesTheQueue(_ winner: String) async throws {
        try await ExchangeWorld.run { world in
            Self.serve(world, "/lq.xml", "LQ", Self.items("lq", 1...3))
            let a = try await world.attach("A")
            let feed = try await Self.subscribe(a, world.url("lq.xml"))
            let podcast = try #require(try await a.store.podcastOfFeedForTesting(feed.id))
            try await a.store.updatePreferences(feedID: feed.id) { $0.newEpisodesAction = .queue }
            await a.exchange()
            let b = try await world.attach("B")
            let bFeed = try await Concurrency.feed(of: podcast, on: b)
            // While A is offline, B changes the action and finds the release first.
            try await b.store.updatePreferences(feedID: bFeed) { $0.newEpisodesAction = winner == "nothing" ? .nothing : .inbox }
            Self.serve(world, "/lq.xml", "LQ", Self.items("lq", 1...4))
            try await Self.refresh(b, bFeed)
            await b.exchange()
            try await Self.refresh(a, feed.id)
            let release = try #require(try await Self.local(a, guid: "lq-4"))
            #expect(try await a.store.queue().map(\.id) == [release.id], "A files it to its queue")
            await a.exchange()
            #expect(try await Self.outcomes(a, "discovery.propose").contains { $0.contains("not_applied") }, "B's proposal won")
            #expect(try await a.store.queue().isEmpty, "the losing filing leaves the queue")
            #expect(try await Self.local(a, guid: "lq-4")?.userState.playState == (winner == "inbox" ? .new : .unplayed))
            try await a.relaunch()
            await a.exchange()
            #expect(try await a.store.queue().isEmpty, "and stays out after a relaunch")
            try await Concurrency.converge(world, [a, b], "losing-queue-\(winner)")
        }
    }

    /// Against the server: the server cannot fetch a feed a phone subscribed to; once the podcast's
    /// wait for its first canonical metadata ends, the phone's first population is observed (never proposed), so its
    /// episodes reach another phone.
    @Test func aFirstPopulationTheServerCannotFetchReachesOtherPhones() async throws {
        try await ExchangeWorld.run { world in
            Self.serve(world, "/fp.xml", "FP", Self.items("fp", 1...3))
            let a = try await world.attach("A")
            guard case .updated(let fetched) = try await FeedFetcher().fetch(FeedFetchRequest(source: world.url("fp.xml"), force: true, parity: true)) else {
                throw HarnessError.server("no feed")
            }
            world.setResponse("/fp.xml", .init(status: 404, headers: [:], body: Data()))
            let feed = try await a.store.insert(fetched)
            await a.exchange()
            let podcast = try #require(try await a.store.podcastOfFeedForTesting(feed.id))
            #expect(try a.rows("SELECT count(*), count(local_id) FROM ntp_observation_work") == [["4", "3"]], "the podcast and its episodes wait")
            try await a.store.executeForTesting("UPDATE ntp_registrations SET created_at = created_at - ?", [.integer(Int64(11 * 60_000))])
            await a.exchange()
            #expect(try a.rows("SELECT count(*) FROM ntp_observation_work") == [["0"]])
            #expect(try await Self.outcomes(a, "catalog.observe").isEmpty, "accepted")
            let c = try await world.attach("C")
            try await Self.exchange(until: {
                guard let feed = try await c.store.feedOfPodcastForTesting(podcast) else { return false }
                return try await c.store.feed(id: feed)?.episodes.count == 3
            }, [c], label: "the first population on another phone")
            #expect(try Self.ledger(a).isEmpty && Self.ledger(c).isEmpty, "never a release")
        }
    }

    // MARK: - 17, 18: bulletins and GUID changes

    /// 17 (bulletin). A feed reusing `/latest.mp3` with a new GUID and the same title every few hours makes a new
    /// episode each time, never inheriting the previous one's played state.
    @Test func scenario17ABulletinMakesANewEpisodeEachTime() async throws {
        try await ExchangeWorld.run { world in
            let latest = "https://media.example/latest.mp3"
            Self.serve(world, "/news.xml", "News", [Item(guid: "b1", title: "News", day: 10, enclosure: latest)])
            let a = try await world.attach("A")
            let feed = try await Self.subscribe(a, world.url("news.xml"))
            let first = try #require(try await Self.local(a, guid: "b1"))
            try await a.store.markEpisodePlayed(episodeID: first.id, played: true)
            Self.serve(world, "/news.xml", "News", [Item(guid: "b2", title: "News", day: 10.25, enclosure: latest)])
            try await Self.refresh(a, feed.id)
            let second = try #require(try await Self.local(a, guid: "b2"))
            #expect(second.id != first.id && second.userState.playState == .new, "a new episode, filed, not played")
            #expect(try await a.store.episode(id: first.id)?.userState.playState == .played)
            let c = try await world.attach("C")
            try await Concurrency.converge(world, [a, c], "bulletin")
        }
    }

    /// 17 (hosting move) and 18. Every GUID and enclosure changes but titles and dates stay: the phone files nothing
    /// (a probable GUID change) and the server's merge keeps the listening state and the download; where the rule does
    /// not hold (a changed title) the episodes stay separate. The phone first or the server first.
    @Test(arguments: [true, false]) func scenario17And18AHostingMoveKeepsTheListeningState(_ phoneFirst: Bool) async throws {
        try await ExchangeWorld.run { world in
            Self.serve(world, "/host.xml", "Host", Self.items("old", 1...3))
            let a = try await world.attach("A")
            let feed = try await Self.subscribe(a, world.url("host.xml"))
            let podcast = try #require(try await a.store.podcastOfFeedForTesting(feed.id))
            let one = try #require(try await Self.local(a, guid: "old-1")), two = try #require(try await Self.local(a, guid: "old-2"))
            try await a.store.markEpisodePlayed(episodeID: one.id, played: true)
            try await a.store.setFavorite(episodeID: two.id, favorite: true)
            let file = world.root.appendingPathComponent("old-2.mp3")
            try Data([4, 2]).write(to: file)
            try await a.store.projectForTesting(two.id) { $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path }
            await a.exchange()
            let c = try await world.attach("C")
            // The move: new GUIDs and media URLs; the third episode's title changed too (no merge for it, 18).
            let moved = (1...3).map { n in
                Item(guid: "new-\(n)", title: n == 3 ? "old 3 (remastered)" : "old \(n)", day: Double(n), enclosure: "https://new-host.example/\(n).mp3")
            }
            Self.serve(world, "/host.xml", "Host", moved)
            if phoneFirst {
                try await Self.refresh(a, feed.id)
                #expect(try await a.store.feeds().flatMap(\.episodes).filter { $0.userState.playState == .new }.map(\.details.identifier) == ["new-3"],
                        "the moved episodes are not filed; the changed one is a new release")
                await a.exchange()
            }
            try await Self.serverRefresh(a, podcast: podcast)
            try await Self.exchange(until: {
                try a.rows("SELECT count(*) FROM ntp_records WHERE entity = 'podcast' AND id = '\(podcast)' AND field_group = 'identity_rules'") == [["1"]]
            }, [a], label: "the server's GUID-change aliases")
            try await Self.refresh(a, feed.id)
            await a.exchange()
            let episodes = try await a.store.feeds().flatMap(\.episodes)
            #expect(episodes.count == 4, "the three old ones (two of them merged with their moves), and the changed one beside its old one: \(episodes.map(\.details.identifier))")
            #expect(try await a.store.episode(id: one.id)?.userState.playState == .played, "listening state kept")
            let kept = try #require(try await a.store.episode(id: two.id))
            #expect(kept.userState.isFavorite && kept.userState.localFileURL == file.path, "favorite and download kept")
            #expect(FileManager.default.fileExists(atPath: file.path))
            try await Concurrency.converge(world, [a, c], "hosting-move-\(phoneFirst)")
        }
    }

    // MARK: - 19: a permanent redirect

    /// 19. A feed moves with a permanent redirect: the phone fetches the new URL and records nothing; the podcast keeps
    /// its ID, aliases and state; no duplicate subscription appears.
    @Test func scenario19APermanentRedirectKeepsThePodcast() async throws {
        try await ExchangeWorld.run { world in
            Self.serve(world, "/r.xml", "Redirected", Self.items("r", 1...3))
            let a = try await world.attach("A")
            let feed = try await Self.subscribe(a, world.url("r.xml"))
            let podcast = try #require(try await a.store.podcastOfFeedForTesting(feed.id))
            try await a.store.setFavorite(episodeID: try #require(try await Self.local(a, guid: "r-1")).id, favorite: true)
            await a.exchange()
            let c = try await world.attach("C")
            world.setResponse("/r.xml", .init(status: 301, headers: ["Location": world.url("r-moved.xml")], body: Data()))
            Self.serve(world, "/r-moved.xml", "Redirected", Self.items("r", 1...4))
            let before = try a.rows("SELECT count(*) FROM ntp_outbox")
            try await Self.refresh(a, feed.id)
            #expect(try await a.store.feed(id: feed.id)?.source == world.url("r-moved.xml"), "the phone fetches the new URL")
            #expect(try a.rows("SELECT type FROM ntp_outbox WHERE type = 'podcast.change_url'").isEmpty, "a redirect records no fact")
            _ = before
            // Pull to refresh asks the server too (PROTOCOL §9), without waiting for it.
            await a.engine.requestServerRefresh(feedID: feed.id)
            #expect(a.transport.requests.contains { $0.path == "v1/refresh" && $0.body == ["podcast_id": .string(podcast)] })
            try await Self.exchange(until: {
                let text = try a.rows("SELECT CAST(value AS TEXT) FROM ntp_records WHERE entity = 'podcast' AND id = '\(podcast)' AND field_group = 'identity'").first?.first ?? nil
                return text?.contains("r-moved.xml") == true
            }, [a, c], label: "the server's move")
            try await Concurrency.converge(world, [a, c], "redirect")
            for phone in [a, c] {
                let view = try await phone.view()
                #expect(view.podcasts.count == 1 && view.podcasts[podcast] != nil, "\(phone.name): one podcast, the same ID")
                #expect(view.podcasts[podcast]?.source == ContractURL.normalize(world.url("r-moved.xml")))
            }
        }
    }

    // MARK: - 34, 46: reused GUIDs and identity evidence

    /// 34. Two offline phones meet a reused GUID's new occurrence before any dispute is known, and act on both
    /// occurrences; after both synchronize, each release keeps its own state, on every device.
    @Test func scenario34AReusedGUIDSeenOfflineKeepsEachReleasesState() async throws {
        try await ExchangeWorld.run { world in
            let first = Item(guid: "rg", title: "Weekly", day: 1, enclosure: "https://media.example/r1.mp3")
            Self.serve(world, "/s34.xml", "S34", [first] + Self.items("s34", 2...3))
            let a = try await world.attach("A")
            let feed = try await Self.subscribe(a, world.url("s34.xml"))
            let podcast = try #require(try await a.store.podcastOfFeedForTesting(feed.id))
            let c = try await world.attach("C")
            let cFeed = try await Concurrency.feed(of: podcast, on: c)
            world.server.stop(keepingData: true)
            // The publisher reuses the GUID 39 days later for new media.
            Self.serve(world, "/s34.xml", "S34", [Item(guid: "rg", title: "Weekly", day: 40, enclosure: "https://media.example/r2.mp3")] + Self.items("s34", 2...3))
            try await Self.refresh(a, feed.id)
            try await Self.refresh(c, cFeed)
            let aRows = try await a.store.feeds().flatMap(\.episodes).filter { $0.details.identifier == "rg" }
            let cRows = try await c.store.feeds().flatMap(\.episodes).filter { $0.details.identifier == "rg" }
            #expect(aRows.count == 2 && cRows.count == 2, "the old occurrence is kept, the new one is its own episode")
            let aNew = try #require(aRows.first { $0.details.media?.url == "https://media.example/r2.mp3" })
            let cOld = try #require(cRows.first { $0.details.media?.url == "https://media.example/r1.mp3" })
            let cNew = try #require(cRows.first { $0.details.media?.url == "https://media.example/r2.mp3" })
            #expect(try await a.store.wireEpisodeForTesting(aNew.id) == (try await c.store.wireEpisodeForTesting(cNew.id)), "both derive rss-guid+enclosure")
            try await a.store.setFavorite(episodeID: aNew.id, favorite: true)
            try await c.store.markEpisodePlayed(episodeID: cOld.id, played: true)
            _ = try await c.store.enqueue([cNew.id])
            try await world.server.launch()
            await a.exchange(); await c.exchange()
            try await Concurrency.converge(world, [a, c], "reused-guid")
            let oldWire = try #require(try await c.store.wireEpisodeForTesting(cOld.id)), newWire = try #require(try await c.store.wireEpisodeForTesting(cNew.id))
            for phone in [a, c] {
                let view = try await phone.view()
                #expect(view.episodes[oldWire]?.playState == .played && view.episodes[oldWire]?.favorite == false, "\(phone.name): the old release")
                #expect(view.episodes[newWire]?.favorite == true && view.episodes[newWire]?.playState != .played, "\(phone.name): the new release")
                #expect(view.queue == [newWire])
            }
        }
    }

    /// 34, second half (PROTOCOL §9.7, §3.3). A podcast removed here is the survivor of a merge with a live podcast (its feed
    /// moved onto the removed one's URL): the podcast lives on with the source's live generation and state; a late fact
    /// an offline phone made on the removed podcast's closed generation is refused (`generation_closed`) without
    /// suppressing the live source's state, and every device converges.
    @Test func scenario34ARemovedSurvivorMergedWithALiveSourceRefusesLateClosedGenerationFacts() async throws {
        try await ExchangeWorld.run { world in
            let items = Self.items("s34m", 1...3)
            Self.serve(world, "/s34-p.xml", "Merged", items)
            Self.serve(world, "/s34-q.xml", "Merged", items)
            let a = try await world.attach("A")
            let pFeed = try await Self.subscribe(a, world.url("s34-p.xml"))
            let p = try #require(try await a.store.podcastOfFeedForTesting(pFeed.id))
            let c = try await world.attach("C")
            let qFeed = try await Self.subscribe(a, world.url("s34-q.xml"))
            let q = try #require(try await a.store.podcastOfFeedForTesting(qFeed.id))
            func subscription(_ phone: ExchangePhone, _ podcast: String) throws -> ContractJSON? {
                guard let text = try phone.rows("SELECT CAST(value AS TEXT) FROM ntp_records WHERE entity = 'podcast' AND id = '\(podcast)' AND field_group = 'subscription'").first?.first ?? nil else { return nil }
                return try ContractJSON.decode(text)
            }
            let qGeneration = try #require(try subscription(a, q)?["generation_id"]?.stringValue)
            // The live source's state: a favorite on A.
            let qOne = try #require(try await a.store.feed(id: qFeed.id)?.episodes.first { $0.details.identifier == "s34m-1" })
            try await a.store.setFavorite(episodeID: qOne.id, favorite: true)
            // C, offline, marks P's copy played on P's generation.
            let cP = try await Concurrency.feed(of: p, on: c)
            let cOne = try #require(try await c.store.feed(id: cP)?.episodes.first { $0.details.identifier == "s34m-1" })
            try await c.store.markEpisodePlayed(episodeID: cOne.id, played: true)
            // A removes P (its generation closes), then Q's feed moves onto P's URL: the server merges Q into P, created first.
            _ = try await a.store.requestFeedDeletion(feedID: pFeed.id)
            try await Self.cleanUp(a.store)
            await a.exchange()
            world.setResponse("/s34-q.xml", .init(status: 301, headers: ["Location": world.url("s34-p.xml")], body: Data()))
            try await Self.serverRefresh(a, podcast: q)
            try await Self.exchange(until: { try subscription(a, q)?["state"] == "merged" }, [a], label: "the podcast merge")
            #expect(try subscription(a, p)?["state"] == "subscribed" && subscription(a, p)?["generation_id"] == .string(qGeneration),
                    "the removed survivor lives on with the source's live generation")
            // C's late fact names P's closed generation: refused, and the live source's state stands.
            await c.exchange()
            let refused = try await Self.outcomes(c, "episode.mark_played")
            #expect(refused.contains { $0.contains("generation_closed") }, "\(refused)")
            try await Self.cleanUp(c.store)
            try await Concurrency.converge(world, [a, c], "removed-survivor-merge")
            let aOne = try #require(try await Self.local(a, guid: "s34m-1"))
            let one = try #require(try await a.store.wireEpisodeForTesting(aOne.id))
            for phone in [a, c] {
                let view = try await phone.view()
                #expect(view.podcasts.keys.sorted() == [p], "\(phone.name): one podcast, the survivor")
                #expect(view.podcasts[p]?.subscription == .subscribed, "\(phone.name): live")
                #expect(view.episodes[one]?.favorite == true && view.episodes[one]?.playState != .played,
                        "\(phone.name): the live source's state, never the closed generation's late fact")
                #expect(try await phone.store.feeds().count == 1)
            }
        }
    }

    /// Against the server: a phone alone sees two new occurrences of one GUID in a fetch (the server cannot
    /// fetch); both are episodes here, with the identities the server's dispute gives them once it has the
    /// phone's evidence, so the phone converges with a fresh attach.
    @Test func twoNewReusedOccurrencesInOneFetchAgreeWithTheServer() async throws {
        try await ExchangeWorld.run { world in
            Self.serve(world, "/rg2.xml", "RG2", Self.items("rg2", 1...3))
            let a = try await world.attach("A")
            let feed = try await Self.subscribe(a, world.url("rg2.xml"))
            world.server.stop(keepingData: true)
            Self.serve(world, "/rg2.xml", "RG2", [Item(guid: "rg", title: "Late", day: 20, enclosure: "https://media.example/rg-late.mp3"),
                                                   Item(guid: "rg", title: "Early", day: 4, enclosure: "https://media.example/rg-early.mp3")]
                       + Self.items("rg2", 1...3))
            try await Self.refresh(a, feed.id)
            #expect(try await a.store.feeds().flatMap(\.episodes).filter { $0.details.identifier == "rg" }.count == 2)
            try await world.server.launch()
            await a.exchange()
            try await Concurrency.converge(world, [a], "two-reused-occurrences")
        }
    }

    /// Against the server, across resolution: a phone alone sees a GUID rotate two enclosures (days
    /// 4, 20, 40, 60: A, B, A, B). It keeps four episodes and sends every occurrence; the server's dispute (whose
    /// assignment, its persisted ID included, follows the order its evidence arrived in) then decides each release's
    /// episode, and every row of the phone becomes the release of its own date, its state intact, converging with a
    /// fresh attach.
    @Test func rotatingEnclosuresKeepEveryReleaseAcrossTheServersMapping() async throws {
        try await ExchangeWorld.run { world in
            Self.serve(world, "/rot.xml", "ROT", Self.items("rot", 1...3))
            let a = try await world.attach("A")
            let feed = try await Self.subscribe(a, world.url("rot.xml"))
            let podcast = try #require(try await a.store.podcastOfFeedForTesting(feed.id))
            world.server.stop(keepingData: true)
            let rotating = [(4.0, "a"), (20, "b"), (40, "a"), (60, "b")].map { day, slot in
                Item(guid: "rg", title: "Rot \(Int(day))", day: day, enclosure: "https://media.example/rot-\(slot).mp3")
            }
            Self.serve(world, "/rot.xml", "ROT", rotating.reversed() + Self.items("rot", 1...3))
            try await Self.refresh(a, feed.id)
            let rows = try await a.store.feeds().flatMap(\.episodes).filter { $0.details.identifier == "rg" }
            #expect(rows.count == 4 && rows.allSatisfy { $0.userState.playState == .new }, "four releases, each filed")
            // Contrasting device state: day 60's follow-ups done, day 20's owed; a pending favorite on
            // day 20 (mapped, and moved by the server's releases) and on day 60 (provisional).
            let favorite = try #require(rows.first { $0.details.title == "Rot 60" })
            let twenty = try #require(rows.first { $0.details.title == "Rot 20" })
            try await a.store.executeForTesting("UPDATE ntp_ledger SET state = 'done', notified = 1 WHERE occurrence = ?", [.text("local-episode:\(favorite.id)")])
            #expect(try a.rows("SELECT count(*) FROM ntp_ledger WHERE state = 'done'") == [["1"]])
            try await a.store.setFavorite(episodeID: favorite.id, favorite: true)
            try await a.store.setFavorite(episodeID: twenty.id, favorite: true)
            try await world.server.launch()
            func rules() throws -> ServerIdentityRules? {
                guard let text = try a.rows("SELECT CAST(value AS TEXT) FROM ntp_records WHERE entity = 'podcast' AND id = '\(podcast)' AND field_group = 'identity_rules'").first?.first ?? nil else { return nil }
                let parsed = ServerIdentityRules(try ContractJSON.decode(text))
                return parsed.disputedGUIDs["rg"]?.count == 4 ? parsed : nil
            }
            try await Self.exchange(until: { try rules() != nil }, [a], label: "the server's releases")
            await a.exchange()
            let releases = try #require(try rules()?.disputedGUIDs["rg"])
            #expect(releases.contains { $0.episodeID.hasPrefix("e0:") }, "the colliding release has the server's persisted ID")
            for row in try await a.store.feeds().flatMap(\.episodes).filter({ $0.details.identifier == "rg" }) {
                let time = Int64((try #require(row.details.publicationDate).timeIntervalSince1970 * 1_000).rounded(.down))
                let release = try #require(releases.first { $0.publicationTime == time })
                #expect(try await a.store.wireEpisodeForTesting(row.id) == release.episodeID, "\(row.details.title ?? ""): the release of its date")
            }
            try await Concurrency.converge(world, [a], "rotating-enclosures")
            for row in try await a.store.feeds().flatMap(\.episodes).filter({ $0.details.identifier == "rg" }) {
                let wire = try #require(try await a.store.wireEpisodeForTesting(row.id))
                let entry = try a.rows("SELECT state, notified FROM ntp_ledger WHERE occurrence = '\(wire)'")
                #expect(entry == [row.id == favorite.id ? ["done", "1"] : ["pending", "0"]], "\(row.details.title ?? ""): its own follow-ups")
                #expect(row.userState.isFavorite == (row.id == favorite.id || row.id == twenty.id), "\(row.details.title ?? ""): its own favorite")
            }
            #expect(try a.rows("SELECT count(*) FROM ntp_ledger WHERE occurrence LIKE 'local-episode:%'") == [["0"]])
        }
    }

    /// The phone first sees only a GUID's later occurrence (day 30) and downloads it; the publisher
    /// then lists an older occurrence of the GUID with another enclosure, and the server's dispute gives the older one
    /// the GUID's identity and the later one `rss-guid+enclosure`. The phone's row, its file and state, become the later
    /// release's; the older release gets a row of its own, without the file; every device converges.
    @Test func aRetrospectiveDisputeKeepsTheFileOnItsRelease() async throws {
        try await ExchangeWorld.run { world in
            let later = Item(guid: "rd", title: "Later", day: 30, enclosure: "https://media.example/rd-later.mp3")
            Self.serve(world, "/rd.xml", "RD", Self.items("rd", 1...3) + [later])
            let a = try await world.attach("A")
            let feed = try await Self.subscribe(a, world.url("rd.xml"))
            let podcast = try #require(try await a.store.podcastOfFeedForTesting(feed.id))
            let row = try #require(try await Self.local(a, guid: "rd"))
            let file = world.root.appendingPathComponent("rd-later.media")
            try Data([3, 0]).write(to: file)
            try await a.store.projectForTesting(row.id) { $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path }
            await a.exchange()
            Self.serve(world, "/rd.xml", "RD", Self.items("rd", 1...3) + [later, Item(guid: "rd", title: "Older", day: 1, enclosure: "https://media.example/rd-older.mp3")])
            try await Self.serverRefresh(a, podcast: podcast)
            try await Self.exchange(until: {
                let rules = try a.rows("SELECT CAST(value AS TEXT) FROM ntp_records WHERE entity = 'podcast' AND id = '\(podcast)' AND field_group = 'identity_rules'").first?.first ?? nil
                return rules?.contains("disputed_guids") == true
            }, [a], label: "the dispute")
            await a.exchange()
            let rows = try await a.store.feeds().flatMap(\.episodes).filter { $0.details.identifier == "rd" }
            #expect(rows.count == 2)
            let namespace = try #require(try a.rows("SELECT namespace FROM ntp_library").first?.first ?? nil)
            let plain = try ContractIdentity.episodeID(namespace: namespace, podcastID: podcast, kind: .rssGUID, value: "rd")
            let kept = try #require(try await a.store.episode(id: row.id))
            #expect(try await a.store.wireEpisodeForTesting(row.id) != plain, "the downloaded row is the later release")
            #expect(kept.details.title == "Later" && kept.userState.isDownloaded && kept.userState.localFileURL == file.path)
            let older = try #require(rows.first { $0.id != row.id })
            #expect(try await a.store.wireEpisodeForTesting(older.id) == plain)
            #expect(older.details.title == "Older" && !older.userState.isDownloaded && older.userState.localFileURL == nil, "no file of another release")
            try await Concurrency.converge(world, [a], "retrospective-dispute")
        }
    }

    /// 46. The same GUID and date at two signed URLs (20 and 23 minutes) stays one episode; a GUID re-dated or undated
    /// with another URL never splits; a missing title or date never merges.
    @Test func scenario46IdentityEvidenceNeverSplitsOrMergesWithoutTheRule() async throws {
        try await ExchangeWorld.run { world in
            let base = [Item(guid: "sg", title: "Signed", day: 5, enclosure: "https://cdn.example/a.mp3?sig=1", duration: "20:00"),
                        Item(guid: "ud", title: "Undated", day: nil, enclosure: "https://cdn.example/u1.mp3"),
                        Item(guid: "nt", title: "", day: 6, enclosure: "https://cdn.example/nt.mp3")]
            Self.serve(world, "/s46.xml", "S46", base)
            let a = try await world.attach("A")
            let feed = try await Self.subscribe(a, world.url("s46.xml"))
            Self.serve(world, "/s46.xml", "S46", [
                Item(guid: "sg", title: "Signed", day: 5, enclosure: "https://cdn.example/a.mp3?sig=2", duration: "23:00"),
                Item(guid: "ud", title: "Undated", day: nil, enclosure: "https://cdn.example/u2.mp3"),
                Item(guid: "nt2", title: "", day: 6, enclosure: "https://cdn.example/nt2.mp3")])
            try await Self.refresh(a, feed.id)
            let rows = try await a.store.feeds().flatMap(\.episodes)
            #expect(rows.filter { $0.details.identifier == "sg" }.count == 1, "a signed URL is the same release")
            #expect(rows.filter { $0.details.identifier == "ud" }.count == 1, "a missing date never splits")
            #expect(rows.filter { $0.details.identifier == "nt2" }.count == 1 && rows.filter { $0.details.identifier == "nt" }.count == 1,
                    "a missing title never merges")
            await a.exchange()
            let c = try await world.attach("C")
            try await Concurrency.converge(world, [a, c], "evidence")
        }
    }

    // MARK: - 45: feed URL conflicts

    /// 45. Changing P's URL to Q's alias is refused (`alias_conflict`): the URL goes back, the refusal is a "needs
    /// attention" item naming Q, and both podcasts keep their identity and state, unmerged. Two phones racing to claim
    /// one unowned URL: the first wins, the second goes back.
    @Test func scenario45AURLConflictIsExplicitAndMergesNothing() async throws {
        try await ExchangeWorld.run { world in
            Self.serve(world, "/p.xml", "Pea", Self.items("p", 1...2))
            Self.serve(world, "/q.xml", "Queue", Self.items("q", 1...2))
            Self.serve(world, "/u.xml", "Unowned", Self.items("u", 1...2))
            let a = try await world.attach("A")
            let p = try await Self.subscribe(a, world.url("p.xml")), q = try await Self.subscribe(a, world.url("q.xml"))
            let pPodcast = try #require(try await a.store.podcastOfFeedForTesting(p.id)), qPodcast = try #require(try await a.store.podcastOfFeedForTesting(q.id))
            try await a.store.setFavorite(episodeID: try #require(try await Self.local(a, guid: "p-1")).id, favorite: true)
            _ = try await a.store.updateFeedDownloadURL(original: world.url("p.xml"), updated: world.url("q.xml"))
            await a.exchange(); await a.exchange()
            #expect(try await a.store.feed(id: p.id)?.source == world.url("p.xml"), "the refused URL goes back")
            let attention = try a.rows("SELECT kind, CAST(record AS TEXT) FROM ntp_attention")
            #expect(attention.count == 1 && attention[0][0] == "alias_conflict")
            let record = try ContractJSON.decode(try #require(attention[0][1] ?? nil))
            #expect(record["owner_podcast"] == .string(qPodcast) && record["owner_title"] == "Queue", "names the owner: \(record)")
            #expect(try await Self.outcomes(a, "podcast.change_url") == ["podcast.change_url not_applied alias_conflict"])
            // The race for an unowned URL.
            let c = try await world.attach("C")
            let cQ = try await Concurrency.feed(of: qPodcast, on: c)
            _ = try await a.store.updateFeedDownloadURL(original: world.url("p.xml"), updated: world.url("u.xml"))
            _ = try await c.store.updateFeedDownloadURL(original: world.url("q.xml"), updated: world.url("u.xml"))
            await a.exchange(); await c.exchange()
            #expect(try await c.store.feed(id: cQ)?.source == world.url("q.xml"), "the second claim goes back")
            try await Concurrency.converge(world, [a, c], "url-race")
            for phone in [a, c] {
                let view = try await phone.view()
                #expect(view.podcasts.count == 2, "\(phone.name): no implicit merge")
                #expect(view.podcasts[pPodcast]?.source == ContractURL.normalize(world.url("u.xml")))
                #expect(view.podcasts[qPodcast]?.source == ContractURL.normalize(world.url("q.xml")))
            }
        }
    }

    // MARK: - named case

    ///: a pending `keep_updated` change of A's and a remote "new episodes" change of C's: A shows both, and A's
    /// refresh files its release by the action it shows (C's queue), proposed with its bundle and admitted once.
    @Test func aPendingKeepUpdatedChangeAndARemoteActionChangeFileByTheShownAction() async throws {
        try await ExchangeWorld.run { world in
            Self.serve(world, "/n.xml", "Named", Self.items("n", 1...3))
            let a = try await world.attach("A")
            let feed = try await Self.subscribe(a, world.url("n.xml"))
            let podcast = try #require(try await a.store.podcastOfFeedForTesting(feed.id))
            let c = try await world.attach("C")
            try await a.store.updatePreferences(feedID: feed.id) { $0.keepUpdated = false }
            try await c.store.updatePreferences(feedID: try await Concurrency.feed(of: podcast, on: c)) { $0.newEpisodesAction = .queue }
            await c.exchange()
            await a.run([.pull, .apply])
            let shown = try #require(try await a.store.feed(id: feed.id))
            #expect(shown.keepUpdated == false && shown.newEpisodesAction == .queue)
            Self.serve(world, "/n.xml", "Named", Self.items("n", 1...4))
            try await Self.refresh(a, feed.id)
            let four = try #require(try await Self.local(a, guid: "n-4"))
            #expect(try await a.store.queue().map(\.id) == [four.id], "filed by the remote action")
            try await Concurrency.converge(world, [a, c], "named")
            let wire = try #require(try await a.store.wireEpisodeForTesting(four.id))
            #expect(try Self.admission(a, wire)?["action"] == "queue")
            #expect(try await c.view().queue == [wire])
        }
    }

    // MARK: - 19 and 34: a move onto another podcast's URL

    /// A feed whose permanent redirect lands on another subscribed podcast's URL: the server merges it into the podcast
    /// created first (PROTOCOL §9.7); every phone shows one podcast, with the merged one's state, download and device settings,
    /// and nothing is played or lost.
    @Test func aRedirectOntoAnotherPodcastsURLMergesThem() async throws {
        try await ExchangeWorld.run { world in
            let items = Self.items("pm", 1...3)
            Self.serve(world, "/pm-a.xml", "Merge", items)
            Self.serve(world, "/pm-b.xml", "Merge", items)
            let a = try await world.attach("A")
            let survivorFeed = try await Self.subscribe(a, world.url("pm-a.xml"))
            let sourceFeed = try await Self.subscribe(a, world.url("pm-b.xml"))
            let survivor = try #require(try await a.store.podcastOfFeedForTesting(survivorFeed.id))
            let source = try #require(try await a.store.podcastOfFeedForTesting(sourceFeed.id))
            let sourceEpisodes = try #require(try await a.store.feed(id: sourceFeed.id)).episodes
            let liked = try #require(sourceEpisodes.first { $0.details.identifier == "pm-1" })
            let saved = try #require(sourceEpisodes.first { $0.details.identifier == "pm-2" })
            try await a.store.setFavorite(episodeID: liked.id, favorite: true)
            try await a.store.updatePreferences(feedID: sourceFeed.id) { $0.tags = ["Moved"] }
            let file = world.root.appendingPathComponent("pm-2.mp3")
            try Data([5]).write(to: file)
            try await a.store.projectForTesting(saved.id) { $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path }
            await a.exchange()
            let c = try await world.attach("C")
            world.setResponse("/pm-b.xml", .init(status: 301, headers: ["Location": world.url("pm-a.xml")], body: Data()))
            try await Self.serverRefresh(a, podcast: source)
            try await Self.exchange(until: {
                let text = try a.rows("SELECT CAST(value AS TEXT) FROM ntp_records WHERE entity = 'podcast' AND id = '\(source)' AND field_group = 'subscription'").first?.first ?? nil
                return text?.contains("merged") == true
            }, [a, c], label: "the podcast merge")
            try await Self.cleanUp(a.store)
            #expect(try await a.store.feed(id: sourceFeed.id) == nil, "the merged podcast leaves")
            let kept = try #require(try await a.store.feed(id: survivorFeed.id))
            #expect(kept.episodes.count == 3)
            #expect(kept.tags == ["Moved"], "the survivor had no device settings of its own")
            #expect(kept.episodes.first { $0.details.identifier == "pm-1" }?.userState.isFavorite == true, "the merged state")
            #expect(kept.episodes.first { $0.details.identifier == "pm-2" }?.userState.localFileURL == file.path, "the download moved")
            #expect(FileManager.default.fileExists(atPath: file.path))
            try await Concurrency.converge(world, [a, c], "podcast-merge")
            for phone in [a, c] {
                let view = try await phone.view()
                #expect(view.podcasts.keys.sorted() == [survivor], "\(phone.name): one podcast")
            }
        }
    }

    /// A release of the later-created of two live podcasts was downloaded and notified here; the
    /// podcasts then merge (its feed moved onto the other's URL) and the server routes the admission to the survivor's
    /// live generation. The release's finished work stays finished: no second download candidate, no second notification.
    @Test func aLivePodcastMergeKeepsFinishedReleaseWork() async throws {
        try await ExchangeWorld.run { world in
            let items = Self.items("lm", 1...3)
            Self.serve(world, "/lm-a.xml", "LM", items)
            Self.serve(world, "/lm-b.xml", "LM", items)
            let a = try await world.attach("A")
            let target = try await Self.subscribe(a, world.url("lm-a.xml"))
            let source = try await Self.subscribe(a, world.url("lm-b.xml"))
            let sourcePodcast = try #require(try await a.store.podcastOfFeedForTesting(source.id))
            for feed in [target.id, source.id] { try await a.store.updatePreferences(feedID: feed) { $0.showEpisodeNotification = true } }
            await a.exchange()
            Self.serve(world, "/lm-b.xml", "LM", items + Self.items("lm", 4...4))
            try await Self.refresh(a, source.id)
            await a.exchange()
            let release = try #require(try await Self.local(a, guid: "lm-4"))
            #expect(try await a.store.serverReleaseCandidates() == [release.id])
            try await a.store.finishServerReleases([release.id])
            try await a.store.markServerReleasesNotified(try await a.store.serverReleaseNotifications().flatMap(\.keys))
            // The source moves onto the target's URL, whose feed lists the release too: the podcasts merge.
            Self.serve(world, "/lm-a.xml", "LM", items + Self.items("lm", 4...4))
            world.setResponse("/lm-b.xml", .init(status: 301, headers: ["Location": world.url("lm-a.xml")], body: Data()))
            try await Self.serverRefresh(a, podcast: sourcePodcast)
            try await Self.exchange(until: {
                let text = try a.rows("SELECT CAST(value AS TEXT) FROM ntp_records WHERE entity = 'podcast' AND id = '\(sourcePodcast)' AND field_group = 'subscription'").first?.first ?? nil
                return text?.contains("merged") == true
            }, [a], label: "the podcast merge")
            await a.exchange()
            try await Self.cleanUp(a.store)
            #expect(try await a.store.serverReleaseCandidates()?.isEmpty == true, "no second download")
            #expect(try await a.store.serverReleaseNotifications().allSatisfy { $0.count == 0 }, "no second notification")
            let ledger = try Self.ledger(a)
            #expect(ledger.filter { $0[1] != "done" || $0[2] != "1" }.isEmpty, "\(ledger)")
        }
    }

    @MainActor static func cleanUp(_ store: FeedLibraryStore) async throws {
        let deletion = FeedDeletionCoordinator(store: store, retirePlayback: { _ in }, retireDownloads: { _ in })
        try await deletion.resume().value
    }
}
