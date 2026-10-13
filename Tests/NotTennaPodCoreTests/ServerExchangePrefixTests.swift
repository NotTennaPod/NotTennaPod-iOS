import Foundation
import Testing
@testable import NotTennaPodCore

/// The displayed state after every prefix of an exchange (PROTOCOL §6.8): while concurrent remote
/// changes arrive commit by commit, A — with unsent local facts — shows exactly the base at its cursor plus its own
/// pending facts. After its push, its pull and every single unit, A equals an observer B at the same cursor in every
/// field A has no pending fact about, and shows its own values in the fields it has; no prefix shows a state that
/// never existed. In the end every phone agrees with a fresh attach.
@Suite(.serialized, .timeLimit(.minutes(30))) struct ServerExchangePrefixTests {
    typealias Concurrency = ServerExchangeConcurrencyTests

    /// The fields A's unretired facts show over (`ntp_overlays`), as places in the synced view.
    struct Masks {
        var episodes: [String: Set<String>] = [:]
        var podcasts: [String: Set<String>] = [:]
        var queue = false
        var policies = false

        init(_ phone: ExchangePhone) async throws {
            for row in try phone.rows("SELECT entity, id, property, kind FROM ntp_overlays") {
                guard let entity = row[0], var id = row[1], let property = row[2], let kind = row[3] else { continue }
                if id.hasPrefix("local-episode:"), let local = Int64(id.dropFirst("local-episode:".count)),
                   let wire = try await phone.store.wireEpisodeForTesting(local) { id = wire }
                switch (entity, property) {
                case ("episode", "queue_membership"), ("episode", "queue_position"): queue = true
                case ("episode", _):
                    var fields = Set([property])
                    if kind == "dismiss" { fields.insert("play_state") }
                    if ["activity", "history_mark", "history_cut", "history_restore"].contains(kind) { fields.formUnion(["history", "last_played"]) }
                    if kind == "completion" { fields.formUnion(["play_state", "position"]); queue = true }
                    episodes[id, default: []].formUnion(fields)
                case ("podcast", _): podcasts[id, default: []].insert(property)
                case ("account", "history"): episodes["*", default: []].formUnion(["history"])
                case ("account", "played_time"), ("account", "played_time_base"): episodes["*", default: []].insert("played_time")
                case ("account", _): policies = true
                default: break
                }
            }
        }

        /// The view with the masked fields cleared.
        func apply(_ view: SyncedView) -> SyncedView {
            var view = view.withoutTitles
            for (id, var episode) in view.episodes {
                let fields = (episodes[id] ?? []).union(episodes["*"] ?? [])
                if fields.contains("favorite") { episode.favorite = false }
                if fields.contains("play_state") { episode.playState = .unplayed }
                if fields.contains("position") { episode.position = 0 }
                if fields.contains("history") { episode.history = nil }
                if fields.contains("last_played") { episode.lastPlayed = 0 }
                if fields.contains("played_time") { episode.playedTime = 0 }
                view.episodes[id] = episode
            }
            for (id, var podcast) in view.podcasts {
                let fields = podcasts[id] ?? []
                if fields.contains("keep_updated") { podcast.keepUpdated = true }
                if fields.contains("new_episodes_action") { podcast.newEpisodesAction = .global }
                if fields.contains("subscription") { podcast.subscription = .subscribed }
                if fields.contains("refresh_url") { podcast.source = "" }
                if fields.contains("credentials") { podcast.credentials = nil }
                view.podcasts[id] = podcast
            }
            if queue { view.queue = [] }
            if policies { view.policies = nil }
            return view
        }

        /// The masked fields only: A's own values there must be the values it showed when it acted.
        func onlyMasked(_ view: SyncedView) -> [String] {
            var values: [String] = []
            for (id, fields) in episodes.sorted(by: { $0.key < $1.key }) where id != "*" {
                guard let episode = view.episodes[id] else { values.append("\(id): gone"); continue }
                for field in fields.sorted() {
                    switch field {
                    case "favorite": values.append("\(id) favorite \(episode.favorite)")
                    case "play_state": values.append("\(id) play state \(episode.playState)")
                    case "position": values.append("\(id) position \(episode.position)")
                    default: break
                    }
                }
            }
            for (id, fields) in podcasts.sorted(by: { $0.key < $1.key }) {
                guard let podcast = view.podcasts[id] else { continue }
                if fields.contains("keep_updated") { values.append("\(id) keep updated \(podcast.keepUpdated)") }
                if fields.contains("new_episodes_action") { values.append("\(id) action \(podcast.newEpisodesAction)") }
            }
            return values
        }
    }

    /// A's state at this prefix against B's at the same cursor.
    static func expectPrefix(_ a: ExchangePhone, _ b: ExchangePhone, shown: SyncedView, first: String? = nil, _ label: String,
                             sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let cursorA = try a.rows("SELECT seq FROM ntp_library"), cursorB = try b.rows("SELECT seq FROM ntp_library")
        #expect(cursorA == cursorB, "\(label): the observer is at A's cursor", sourceLocation: sourceLocation)
        let masks = try await Masks(a)
        let viewA = try await a.view(), viewB = try await b.view()
        let differences = masks.apply(viewA).differences(from: masks.apply(viewB))
        #expect(differences.isEmpty, "\(label): A differs from the base where it has no pending fact:\n\(differences.joined(separator: "\n"))",
                sourceLocation: sourceLocation)
        let own = masks.onlyMasked(viewA), acted = masks.onlyMasked(shown)
        #expect(own == acted, "\(label): A's pending facts no longer show as acted:\n\(own)\nvs\n\(acted)", sourceLocation: sourceLocation)
        // A's pending add at the front stays first while other devices' queue changes arrive around it.
        if let first, masks.queue { #expect(viewA.queue.first == first, "\(label): \(viewA.queue)", sourceLocation: sourceLocation) }
    }

    @Test func everyPrefixShowsTheBaseAtItsCursorPlusThePendingFacts() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, feed, ids, podcast) = try await Concurrency.twoPhones(world)
            _ = try await a.store.enqueue([ids[0], ids[1]])
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            await a.exchange()
            let b = try await world.attach("B")
            await c.exchange()
            let onC = try await ids.asyncMap { try await Concurrency.same($0, from: a, on: c) }
            // C's concurrent changes, one commit each: some on what A changes, some elsewhere.
            try await c.store.setFavorite(episodeID: onC[0], favorite: false); await c.exchange()
            try await c.store.markEpisodePlayed(episodeID: onC[3], played: true); await c.exchange()
            _ = try await c.store.enqueue([onC[2]]); await c.exchange()
            try await c.store.updatePreferences(feedID: try await Concurrency.feed(of: podcast, on: c)) { $0.newEpisodesAction = .queue }; await c.exchange()
            var listening = RemoteSession(store: c.store, episode: onC[4])
            try await listening.start(at: 0)
            try await listening.checkpoint(position: 50_000, contribution: 50_000)
            await c.exchange()
            try await c.store.setFavorite(episodeID: onC[1], favorite: true); await c.exchange()
            // A's own unsent actions, on the same episodes and the same podcast: A changes its mind about the favorite
            // C removed meanwhile.
            try await a.store.setFavorite(episodeID: ids[0], favorite: false)
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            try await a.store.markEpisodePlayed(episodeID: ids[1], played: true, resetPosition: false)
            try await a.store.updatePreferences(feedID: feed.id) { $0.keepUpdated = false }
            _ = try await a.store.enqueue([ids[4]], location: .front)
            let shown = try await a.view()
            let front = try #require(try await a.store.wireEpisodeForTesting(ids[4]))
            try await Self.expectPrefix(a, b, shown: shown, first: front, "before")
            // The exchange, one step at a time; B follows the same commits.
            await a.run([.push])
            try await Self.expectPrefix(a, b, shown: shown, first: front, "pushed")
            await a.run([.pull])
            await b.run([.pull])
            try await Self.expectPrefix(a, b, shown: shown, first: front, "pulled")
            var units = 0
            while true {
                let report = await a.run([.applyOne])
                guard report.appliedUnits == 1 else { break }
                units += 1
                #expect(await b.run([.applyOne]).appliedUnits == 1)
                try await Self.expectPrefix(a, b, shown: shown, first: front, "unit \(units)")
            }
            #expect(units >= 6, "every concurrent commit and A's own applied one by one: \(units)")
            #expect(try a.rows("SELECT count(*) FROM ntp_overlays") == [["0"]], "every fact retired")
            try await Concurrency.converge(world, [a, b, c], "prefixes")
            let after = try await a.view()
            let wire0 = try #require(try await a.store.wireEpisodeForTesting(ids[0]))
            #expect(after.episodes[wire0]?.favorite == true, "A's later favorite wins over C's earlier removal")
            #expect(after.podcasts[podcast]?.keepUpdated == false && after.podcasts[podcast]?.newEpisodesAction == .queue)
        }
    }
}
