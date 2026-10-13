import Foundation
import Testing
@testable import NotTennaPodCore

/// Push and pull against the real server (PROTOCOL §6.4): framing, lost answers, verification,
/// waiting, pauses and backoff. Nothing is ever dropped.
@Suite(.serialized, .timeLimit(.minutes(30))) struct ServerExchangePushPullTests {
    typealias Agreement = ServerExchangeAgreementTests

    struct InjectedCrash: Error {}

    /// A crash hook that throws once at `point`.
    static func crashOnce(at point: String) -> @Sendable (String) throws -> Void {
        let fired = PlayingFlag()
        return { name in
            guard name == point, !fired.value else { return }
            fired.value = true
            throw InjectedCrash()
        }
    }

    static func subscribed(_ world: ExchangeWorld, _ phone: ExchangePhone, _ path: String = "one.xml", title: String = "One",
                           prefix: String = "one", count: Int = 5) async throws -> LibraryFeed {
        let feed = try await phone.store.insert(Agreement.fetched(world.url(path), title: title, prefix: prefix, count: count))
        try await Agreement.waitForCatalog(phone, feedID: feed.id)
        return feed
    }

    @Test func anOwedQueueAddReachesTheServerThroughThePush() async throws {
        try await ExchangeWorld.run { world in
            let a = try await world.attach("A")
            let one = try await Self.subscribed(world, a)
            let id = try #require(one.episodes.map(\.id).min())
            // A play load whose recording fails owes its queue add.
            await a.store.injectRecorderFailure(after: 1)
            _ = try await a.store.beginPlayback(episodeID: id)
            await a.store.injectRecorderFailure(after: nil)
            #expect(try a.rows("SELECT count(*) FROM ntp_owed") == [["1"]])
            await a.run([.push])
            #expect(try a.rows("SELECT count(*) FROM ntp_owed") == [["0"]], "the push recorded what was owed first")
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox WHERE type = 'queue.add' AND receipt IS NOT NULL") == [["1"]],
                    "and sent it in the same push")
            await a.exchange()
            let b = try await world.attach("B")
            let wire = try #require(try await a.store.wireEpisodeForTesting(id))
            #expect(try await b.view().queue == [wire])
        }
    }

    @Test func aFactOverTheUnframedBoundIsFramedAndSurvivesARestartMidway() async throws {
        let long = String(repeating: "A long title for a framed fact. ", count: 40)
        try await ExchangeWorld.run(feeds: ["/big.xml": (long, "big", 500)]) { world in
            let a = try await world.attach("A")
            let big = try await Self.subscribed(world, a, "big.xml", title: long, prefix: "big", count: 500)
            let ids = big.episodes.map(\.id).sorted()
            _ = try await a.store.enqueue(ids)
            let entry = try #require(try a.rows("SELECT install_seq, length(fact) FROM ntp_outbox WHERE type = 'queue.add'").first)
            let size = Int(entry[1] ?? "0") ?? 0
            #expect(size > 256 << 10, "a maximum-size queue add (\(size) bytes) is over the unframed bound")
            // A crash right after the framing is chosen, before any part is sent: the transaction ID is kept.
            await a.engine.setCrashPoint(Self.crashOnce(at: "push.framed"))
            #expect(await a.engine.run([.push]).error == "InjectedCrash()")
            let framing = try #require(try a.rows("SELECT CAST(framing AS TEXT) FROM ntp_outbox WHERE install_seq = \(entry[0]!)").first?.first ?? nil)
            try await a.relaunch()
            // A crash after the first part was stored and recorded: the next launch continues with the next part.
            await a.engine.setCrashPoint(Self.crashOnce(at: "push.recorded"))
            #expect(await a.engine.run([.push]).error == "InjectedCrash()")
            let afterFirst = try #require(try a.rows("SELECT CAST(framing AS TEXT) FROM ntp_outbox WHERE install_seq = \(entry[0]!)").first?.first ?? nil)
            let stored = try ServerFraming.decoded(afterFirst)
            #expect(stored.transactionID == (try ServerFraming.decoded(framing)).transactionID, "never reframed")
            #expect(stored.present == [0])
            try await a.relaunch()
            await a.exchange()
            // The queue add's parts, by its transaction (other facts, a first population's observations among them, may
            // be pushed in the same exchanges): each sent once, in order, one per request, part 0 not again after the
            // relaunch.
            let transaction = stored.transactionID
            let requests = a.transport.requests.filter { $0.path == "v1/push" }.map { $0.body?["operations"]?.arrayValue ?? [] }
            let carrying = requests.filter { operations in operations.contains { $0["part"]?["transaction_id"]?.stringValue == transaction } }
            #expect(carrying.allSatisfy { $0.count == 1 }, "one part per request")
            let parts = carrying.compactMap { $0.first?["part"] }
            #expect(parts.count == Int(ceil(Double(size) / Double(256 << 10))), "one part per request: \(parts.count)")
            #expect(parts.compactMap { $0["part_index"]?.integerValue } == Array(0..<Int64(parts.count)), "in order, each once")
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox") == [["0"]])
            let b = try await world.attach("B")
            let expected = try await a.view().queue
            #expect(expected.count == 500)
            #expect(try await b.view().queue == expected)
        }
    }

    /// Scenario 2: the server restarts in the middle of a push (its answer is lost); the phone retries; nothing is
    /// applied twice or lost.
    @Test func aLostPushAnswerIsRetriedWithoutApplyingTwice() async throws {
        try await ExchangeWorld.run { world in
            let a = try await world.attach("A")
            let one = try await Self.subscribed(world, a)
            let ids = one.episodes.map(\.id).sorted()
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            try await a.store.markEpisodePlayed(episodeID: ids[1], played: true)
            let lose = PlayingFlag()
            lose.value = true
            a.transport.handler = { method, path, body, server in
                let answer = try await server.send(method, path, body: body)
                if path == "v1/push", lose.value { lose.value = false; throw ServerExchangeError.unreachable }
                return answer
            }
            let report = await a.engine.run([.push])
            #expect(report.retryAfter != nil, "the lost answer backs off")
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox WHERE receipt IS NULL") == [["2"]], "nothing acknowledged yet")
            a.transport.handler = nil
            await a.exchange()
            let duplicates = a.transport.requests.filter { $0.path == "v1/push" }.count
            #expect(duplicates >= 2)
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox") == [["0"]])
            // The server holds each fact once: a fresh attach shows the state, and its archive has each op once.
            let b = try await world.attach("B")
            #expect(try await b.view() == (try await a.view()))
        }
    }

    @Test func aPullThatFailsVerificationIsDiscardedAndPulledAgain() async throws {
        try await ExchangeWorld.run { world in
            let a = try await world.attach("A")
            let c = try await world.attach("C")
            let one = try await Self.subscribed(world, c)
            try await c.store.setFavorite(episodeID: try #require(one.episodes.map(\.id).min()), favorite: true)
            await c.exchange()
            let tamper = PlayingFlag()
            tamper.value = true
            a.transport.handler = { method, path, body, server in
                let answer = try await server.send(method, path, body: body)
                guard path == "v1/pull", tamper.value, case .object(var page) = answer, var items = page["items"]?.arrayValue,
                      let index = items.firstIndex(where: { $0["commit"] != nil }), case .object(var commit) = items[index]["commit"]! else { return answer }
                tamper.value = false
                commit["seq"] = .integer((commit["seq"]?.integerValue ?? 0) + 1)
                items[index] = ["commit": .object(commit)]
                page["items"] = .array(items)
                return .object(page)
            }
            let before = try await a.view()
            #expect(before.podcasts.isEmpty)
            await a.exchange()
            let log = try await a.engine.logEntries()
            #expect(log.contains { $0.kind == "pull" && $0.detail.hasPrefix("discarded") }, "the altered view was discarded")
            #expect(try await a.view() == (try await c.view()), "and the second pull applied the account")
        }
    }

    @Test func aFactWaitingForDependenciesKeepsItsPlaceAndNothingIsDropped() async throws {
        try await ExchangeWorld.run { world in
            let a = try await world.attach("A")
            let one = try await Self.subscribed(world, a)
            let ids = one.episodes.map(\.id).sorted()
            guard let ref = try await a.store.episodeRefForTesting(ids[0]) else { Issue.record("no reference"); return }
            // A fact that depends on a node the server does not have (another device's, not yet uploaded).
            try await a.store.appendFactForTesting(type: "favorite.set", targets: [ref.target], payload: ["episode": ref.ref, "on": true],
                                                   dependencies: [ContractIdentity.randomUUID()])
            try await a.store.setFavorite(episodeID: ids[1], favorite: true)
            let report = await a.engine.run([.push])
            #expect(report.waitingForDependencies)
            #expect(report.retryAfter != nil)
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox WHERE waiting IS NOT NULL") == [["1"]])
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox WHERE receipt IS NULL") == [["2"]], "the later fact waits behind it, kept")
        }
    }

    /// Scenario 26: an operation the server does not know pauses pushing without losing it; pulls continue.
    @Test func anUnknownOperationPausesPushingWhilePullsContinue() async throws {
        try await ExchangeWorld.run { world in
            let a = try await world.attach("A")
            let c = try await world.attach("C")
            let one = try await Self.subscribed(world, c)
            try await a.store.appendFactForTesting(type: "episode.future_operation", targets: [], payload: [:])
            let report = await a.engine.run([.push])
            #expect(report.pause == .versionUnsupported)
            try await c.store.setFavorite(episodeID: try #require(one.episodes.map(\.id).min()), favorite: true)
            await c.exchange()
            let pulled = await a.engine.run([.pull, .apply])
            #expect(pulled.appliedUnits > 0, "pulls continue")
            #expect(try await a.view() == (try await c.view()))
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox WHERE type = 'episode.future_operation'") == [["1"]], "kept")
            let again = await a.engine.run([.push])
            #expect(again.pause == .versionUnsupported, "pushing stays paused until it is resumed")
        }
    }

    @Test func answersThatPauseSyncKeepEverything() async throws {
        try await ExchangeWorld.run { world in
            let a = try await world.attach("A")
            let one = try await Self.subscribed(world, a)
            try await a.store.setFavorite(episodeID: try #require(one.episodes.map(\.id).min()), favorite: true)
            // A cursor of another history: the server was restored.
            let cursor = try SyncCursor(encoded: try #require(try a.rows("SELECT cursor FROM ntp_library").first?.first ?? nil))
            let forged = try SyncCursor(logID: cursor.logID, epoch: cursor.epoch, seq: cursor.seq, digest: String(repeating: "0", count: 64))
            a.transport.handler = { method, path, body, server in
                guard case .object(var object) = body, object["cursor"] != nil else { return try await server.send(method, path, body: body) }
                object["cursor"] = .string(forged.encoded)
                return try await server.send(method, path, body: .object(object))
            }
            #expect(await a.engine.exchange().pause == .lineageMismatch)
            try await a.engine.resume()
            let unknown = try SyncCursor(logID: ContractIdentity.randomUUID(), epoch: cursor.epoch, seq: cursor.seq, digest: cursor.digest)
            a.transport.handler = { method, path, body, server in
                guard case .object(var object) = body, object["cursor"] != nil else { return try await server.send(method, path, body: body) }
                object["cursor"] = .string(unknown.encoded)
                return try await server.send(method, path, body: .object(object))
            }
            #expect(await a.engine.exchange().pause == .lineageUnknown)
            let causes = try await a.engine.logEntries().filter { $0.kind == "paused" }.map(\.detail)
            #expect(causes.contains("lineage_mismatch") && causes.contains("lineage_unknown"), "\(causes)")
            try await a.engine.resume()
            a.transport.handler = { _, _, _, _ in throw ServerExchangeError.server(status: 401, code: "unauthorized", retryAfter: nil) }
            #expect(await a.engine.exchange().pause == .signIn)
            #expect(try a.rows("SELECT pause_reason FROM ntp_library") == [["sign_in"]])
            #expect(try await a.store.serverUnsentChanges() == 1, "the unsent change is kept")
            a.transport.handler = nil
            #expect(await a.engine.exchange().pause == .signIn, "paused until the person signs in again")
            try await a.engine.resume()
            await a.exchange()
            #expect(try await a.store.serverUnsentChanges() == 0)
        }
    }

    @Test func transientFailuresBackOffAndOversizedRequestsShrink() async throws {
        try await ExchangeWorld.run { world in
            let a = try await world.attach("A")
            let one = try await Self.subscribed(world, a)
            a.transport.handler = { _, _, _, _ in throw ServerExchangeError.unreachable }
            let unreachable = await a.engine.exchange()
            #expect((1.5...2.5).contains(unreachable.retryAfter ?? 0), "first retry about 2 s: \(String(describing: unreachable.retryAfter))")
            let second = await a.engine.exchange()
            #expect((3.0...5.0).contains(second.retryAfter ?? 0), "then doubling: \(String(describing: second.retryAfter))")
            a.transport.handler = { _, _, _, _ in throw ServerExchangeError.server(status: 503, code: "server_busy", retryAfter: 30) }
            #expect(await a.engine.exchange().retryAfter == 30)
            // A request the server finds too large is sent in smaller pieces (PROTOCOL §6.4).
            for id in one.episodes.map(\.id) { try await a.store.setFavorite(episodeID: id, favorite: true) }
            a.transport.handler = { method, path, body, server in
                if path == "v1/push", (body?["operations"]?.arrayValue?.count ?? 0) > 1 {
                    throw ServerExchangeError.server(status: 413, code: "payload_too_large", retryAfter: nil)
                }
                return try await server.send(method, path, body: body)
            }
            let sent = a.transport.requests.count
            await a.exchange()
            #expect(try await a.store.serverUnsentChanges() == 0)
            // Retired because the server took them one at a time, not dropped: every favorite reaches another phone.
            let single = a.transport.requests.dropFirst(sent).filter { $0.path == "v1/push" && $0.body?["operations"]?.arrayValue?.count == 1 }
            #expect(single.count >= one.episodes.count, "single-operation pushes: \(single.count)")
            let b = try await world.attach("B")
            let favorites = try await b.view().episodes.values.filter(\.favorite).count
            #expect(favorites == one.episodes.count, "favorites on a second phone: \(favorites)")
        }
    }

    /// A refused (`rejected`) local fact retires like any other: its overlay goes and the server's value returns.
    @Test func aRejectedFactRetiresAndTheServersValueReturns() async throws {
        try await ExchangeWorld.run { world in
            let a = try await world.attach("A")
            let one = try await Self.subscribed(world, a)
            let id = try #require(one.episodes.map(\.id).min())
            guard let ref = try await a.store.episodeRefForTesting(id) else { Issue.record("no reference"); return }
            try await a.store.projectForTesting(id) { $0.userState.isFavorite = true }
            try await a.store.appendFactForTesting(type: "favorite.set", targets: [ref.target], payload: ["episode": ref.ref, "on": "yes"],
                                                   overlays: [ServerOverlay(entity: "episode", id: ref.target.id, property: "favorite", kind: .register, value: true)])
            await a.exchange()
            #expect(try await a.store.episode(id: id)?.userState.isFavorite == false, "the server's value returned")
            #expect(try a.rows("SELECT kind FROM ntp_attention") == [["rejected"]])
            let log = try await a.engine.logEntries()
            #expect(log.contains { $0.kind == "outcome" && $0.detail.hasPrefix("favorite.set rejected") })
        }
    }
}

extension ServerFraming {
    static func decoded(_ text: String) throws -> ServerFraming {
        try JSONDecoder().decode(ServerFraming.self, from: Data(base64Encoded: text) ?? Data(text.utf8))
    }
}
