import Foundation
import Testing
@testable import NotTennaPodCore

/// Recovery after a server restore (PROTOCOL §6.11) without repeated work, against the pinned server: the inventory is
/// sent in requests that fit the server's body limit, and a `payload_too_large` answer makes a smaller request of the
/// same entries at once (no backoff); the recovery's full snapshot is not downloaded while a large library plays, and a
/// download that playback interrupted before its switch is kept and published at the pause without downloading again.
@Suite(.serialized) struct ServerRecoveryResumeTests {
    typealias Copies = ServerCopiesTests
    typealias Recovery = ServerRecoveryTests
    typealias Publication = ServerRecoveryPublicationTests

    /// The inventory requests B sent: accepted bodies and refused sizes.
    final class InventoryLog: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [ContractJSON] = []
        private var refusedSizes: [Int] = []
        private var sentSizes: [Int] = []
        let limit: Int
        init(limit: Int) { self.limit = limit }

        func handler() -> ProxyTransport.Handler {
            { [self] method, path, body, server in
                guard path == "v1/sync/recovery/inventory", let body else { return try await server.send(method, path, body: body) }
                let size = try body.canonicalData().count
                lock.withLock { sentSizes.append(size) }
                if size > limit {
                    lock.withLock { refusedSizes.append(size) }
                    throw ServerExchangeError.server(status: 413, code: "payload_too_large", retryAfter: nil)
                }
                lock.withLock { bodies.append(body) }
                return try await server.send(method, path, body: body)
            }
        }

        var accepted: [ContractJSON] { lock.withLock { bodies } }
        var refused: [Int] { lock.withLock { refusedSizes } }
        var sizes: [Int] { lock.withLock { sentSizes } }
    }

    /// A server whose body limit is lower than this library's whole inventory (as the deployed 64 KiB limit is lower
    /// than a power user's 2,000-entry pages): the recovery finishes in one exchange, every request fits, a refused one
    /// is followed at once by a smaller one, and every entry is inventoried exactly once.
    @Test func theInventoryIsSentInRequestsThatFitTheServer() async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Copies.subscribed(world)
            let b = try await world.device("B")
            let onB = try await ids.asyncMap { try await Recovery.same($0, from: a, on: b) }
            let backup = try await world.backUp()
            for round in 0..<12 {
                for id in onB { try await b.store.setFavorite(episodeID: id, favorite: round % 2 == 0) }
            }
            await b.exchange()
            await a.close()
            try await world.restore(backup)
            #expect(await b.engine.exchange().pause == .signIn)
            try await b.signInAgain()
            let log = InventoryLog(limit: 6 << 10)
            b.transport.handler = log.handler()
            let report = await b.exchange()
            #expect(report.retryAfter == nil && report.recovery == nil, "finished in one exchange: \(report)")
            #expect(!log.refused.isEmpty, "this library's inventory did not fit one request at first")
            #expect(log.accepted.count >= 2)
            #expect(try log.accepted.allSatisfy { try $0.canonicalData().count <= log.limit })
            let keys = log.accepted.flatMap { body in
                (body["entries"]?.arrayValue ?? []).map { "\($0["kind"]?.stringValue ?? "")/\($0["op_id"]?.stringValue ?? $0["decision_id"]?.stringValue ?? "")" }
            }
            #expect(keys.count == Set(keys).count, "every entry inventoried exactly once")
            #expect(keys.count > 60)
            let recovery = try await Recovery.recovery(b)
            #expect(recovery?.finished == true && recovery?.complete == true)
        }
    }

    /// Full snapshot requests (pages), and the recovery's one-item openings.
    final class PageLog: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0, opened = 0
        var afterLastPage: (@Sendable () -> Void)?
        func handler() -> ProxyTransport.Handler {
            { [self] method, path, body, server in
                let page = path == "v1/snapshot" && body?["limit"]?.integerValue != 1
                if page { lock.withLock { count += 1 } }
                if path == "v1/snapshot", body?["limit"]?.integerValue == 1 { lock.withLock { opened += 1 } }
                let answer = try await server.send(method, path, body: body)
                if page, answer["has_more"]?.boolValue == false { afterLastPage?() }
                return answer
            }
        }
        var pages: Int { lock.withLock { count } }
        var openings: Int { lock.withLock { opened } }
        func reset() { lock.withLock { count = 0; opened = 0 } }
    }

    /// Playback starts as B's recovery finishes downloading the server's library: the switch waits for the pause with
    /// the download kept. Exchanges while playing and after a relaunch download nothing again; the pause publishes it.
    @Test func aDownloadPlaybackInterruptedIsKeptAndPublishedAtThePause() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, _) = try await Publication.unpulled(world)
            await b.engine.setSnapshotTesting(pageLimit: 3, stagingWhilePlaying: 0)
            let log = PageLog()
            let playing = b.playing
            log.afterLastPage = { playing.value = true }
            b.transport.handler = log.handler()
            let waiting = await b.engine.exchange()
            #expect(waiting.waitingForPause && waiting.error == nil, "\(waiting)")
            #expect(log.pages >= 2)
            let spool = try #require(b.location.staging).appendingPathComponent("recovery")
            #expect(ServerSnapshotSpool.manifest(in: spool)?.complete == true, "the download is kept")
            log.reset()
            let staged = Staged()
            await b.engine.setCrashPoint { if $0 == "full.staged" { staged.add() } }
            let again = await b.engine.exchange()
            #expect(again.waitingForPause && log.pages == 0, "nothing downloaded again while playing")
            #expect(log.openings == 0 && staged.count == 0, "nor opened or staged again: \(log.openings) openings, \(staged.count) stagings")
            await b.engine.setCrashPoint(nil)
            try await b.relaunch()
            await b.engine.setSnapshotTesting(stagingWhilePlaying: 0)
            b.playing.value = false
            let report = await b.engine.exchange()
            #expect(report.error == nil && !report.waitingForPause, "\(report)")
            #expect(log.pages == 0, "published from the kept download")
            #expect(try await Recovery.recovery(b)?.caughtUp == true)
            #expect(!FileManager.default.fileExists(atPath: spool.path))
            try await world.converge([a, b], "kept-recovery")
        }
    }

    /// A phone behind the server (its own library small, the server's larger) recovers while playing: the switch waits
    /// because of the incoming library's size, and later exchanges and a relaunch honour that wait without opening the
    /// server's view or staging again.
    @Test func aLargerIncomingRecoveryDoesNotRepeatWhilePlaying() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, _) = try await Publication.unpulled(world)
            let feed = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("two.xml"), title: "Two", prefix: "two", count: 3))
            try await Copies.waitForCatalog(a, feedID: feed.id)
            let local = try await b.store.serverRecordCount()
            await b.engine.setSnapshotTesting(pageLimit: 3, stagingWhilePlaying: local)
            let log = PageLog()
            let playing = b.playing
            log.afterLastPage = { playing.value = true }
            b.transport.handler = log.handler()
            let waiting = await b.engine.exchange()
            #expect(waiting.waitingForPause && waiting.error == nil, "\(waiting)")
            let spool = try #require(b.location.staging).appendingPathComponent("recovery")
            #expect(ServerSnapshotSpool.manifest(in: spool)?.complete == true)
            #expect((ServerSnapshotSpool.manifest(in: spool)?.records ?? 0) > local, "the incoming library is the larger one")
            log.reset()
            let staged = Staged()
            await b.engine.setCrashPoint { if $0 == "full.staged" { staged.add() } }
            #expect(await b.engine.exchange().waitingForPause)
            #expect(log.openings == 0 && log.pages == 0 && staged.count == 0, "\(log.openings) openings, \(staged.count) stagings")
            try await b.relaunch()
            await b.engine.setSnapshotTesting(stagingWhilePlaying: local)
            await b.engine.setCrashPoint { if $0 == "full.staged" { staged.add() } }
            #expect(await b.engine.exchange().waitingForPause)
            #expect(log.openings == 0 && log.pages == 0 && staged.count == 0, "after a relaunch too")
            b.playing.value = false
            let report = await b.engine.exchange()
            #expect(report.error == nil && !report.waitingForPause, "\(report)")
            #expect(try await Recovery.recovery(b)?.caughtUp == true)
        }
    }

    /// While a large library plays, the recovery's full download does not start; the pause runs it.
    @Test func theFullDownloadWaitsForThePauseWhileALargeLibraryPlays() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, _) = try await Publication.unpulled(world)
            await b.engine.setSnapshotTesting(stagingWhilePlaying: 0)
            let log = PageLog()
            b.transport.handler = log.handler()
            b.playing.value = true
            let waiting = await b.engine.exchange()
            #expect(waiting.waitingForPause && log.pages == 0, "\(waiting)")
            log.reset()
            #expect(await b.engine.exchange().waitingForPause && log.openings == 0 && log.pages == 0, "the server is not asked again while playing")
            b.playing.value = false
            let report = await b.engine.exchange()
            #expect(report.error == nil && log.pages >= 1)
            #expect(try await Recovery.recovery(b)?.caughtUp == true)
            try await world.converge([a, b], "after-pause")
        }
    }

    final class Staged: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }
}
