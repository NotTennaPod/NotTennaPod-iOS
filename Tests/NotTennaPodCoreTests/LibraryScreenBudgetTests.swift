import Foundation
import Testing
@testable import NotTennaPodCore

/// The screens' work per routine change, counted, as permanent regression gates: no whole-library read
/// (`snapshot()`), records decoded only for what the change set named, patch work and list moves bounded by what changed,
/// and the read's page lookups flat across library sizes.
///
/// Always: a 2,000-episode library with absolute bounds. `NTP_SCALE=1`: 10,000, 54,000 and 100,000 episodes, each event's
/// work at 54k and 100k within 1.1 × its 10k value + 16.
@Suite(.serialized) struct LibraryScreenBudgetTests {
    typealias World = LibraryScreenModelEquivalenceTests.World

    struct Work: Equatable, CustomStringConvertible {
        var snapshots = 0
        var recordsDecoded = 0
        var named = 0
        var resets = 0
        var mirrorWork = 0
        var listMoved = 0
        var listDirectory = 0
        var pages: Int64 = 0
        var description: String {
            "snapshots \(snapshots), decoded \(recordsDecoded) of \(named) named, resets \(resets), patch work \(mirrorWork), list moves \(listMoved), directory \(listDirectory), pages \(pages)"
        }
    }

    /// A restored library of about `episodes` episodes, with one small podcast of its own for the refresh events.
    static func world(episodes: Int, feeds: Int) async throws -> World {
        let directory = try EpisodeListKeysTests.directory()
        let url = try await EpisodeListKeysTests.restoredLibrary(in: directory, episodes: episodes, feeds: feeds)
        let store = try FeedLibraryStore(url: url)
        let world = try await World(directory: directory, store: store, server: false, seed: 0xB0D6E7)
        world.capacity = 256
        try await world.subscribe(number: 900, count: 60)
        try await world.open()
        return world
    }

    /// The routine events, each performed once on `world` and measured from the change sets it delivered to the patched
    /// screen model.
    static func measure(_ world: World) async throws -> [String: Work] {
        var results: [String: Work] = [:]
        let small = try #require(world.sources.first { $0.value.source.hasSuffix("screen900.xml") }?.key)
        let episodes = world.mirror.feeds.filter { $0.id != small }.flatMap(\.episodes)
        let target = try #require(episodes.first { $0.details.media != nil && $0.userState.playState != .new }).id
        // An Inbox member (made one first, outside the measurement, when the library has none).
        let subscribed = world.mirror.feeds.filter { $0.subscriptionState == .subscribed && $0.id != small }.flatMap(\.episodes)
        let inboxMember: Int64
        if let member = subscribed.first(where: { $0.userState.playState == .new && $0.id != target }) { inboxMember = member.id } else {
            inboxMember = try #require(subscribed.first { $0.id != target }).id
            try await world.store.updateEpisode(id: inboxMember) { $0.userState.playState = .new }
            try await world.patch()
        }
        let events: [(String, () async throws -> Void)] = [
            ("own position save", {
                try await world.player.load(target); try await world.player.play()
                try await world.player.listen(10, every: 5); try await world.player.pause()
            }),
            ("played mark", { try await world.store.markEpisodePlayed(episodeID: target, played: true) }),
            ("favorite toggle", { try await world.store.setFavorite(episodeID: target, favorite: true) }),
            ("inbox dismiss", { try await world.store.removeEpisodeFromInbox(episodeID: inboxMember) }),
            ("queue add", { _ = try await world.store.enqueue([target], location: .front) }),
            ("queue move", {
                let queue = try await world.store.queue()
                _ = try await world.store.performQueueMove(.item(target, finalIndex: queue.count - 1), expected: queue.map(QueueEpisodeIdentity.init))
            }),
            ("queue remove", { _ = try await world.store.removeFromQueue([target]) }),
            ("download start", { _ = try await world.store.requestDownload(episodeID: target, directory: world.directory.appendingPathComponent("downloads"), enqueue: false) }),
            ("download complete", {
                let job = try #require(try await world.store.downloadJobs().first { $0.episodeID == target })
                let attempt = try #require(try await world.store.beginDownloadAttempt(id: job.id))
                try FileManager.default.createDirectory(at: attempt.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 1, count: 10).write(to: attempt.destination)
                _ = try await world.store.attachDownloadFile(id: job.id, attempt: attempt.attempts)
                _ = try await world.store.completeDownload(id: job.id, attempt: attempt.attempts)
            }),
            ("download delete", { try await world.store.requestMediaDeletion(episodeID: target) }),
            ("history removal", { _ = try await world.store.removeFromPlaybackHistoryWithUndo(target) }),
            ("one-new-episode refresh", {
                var source = try #require(world.sources[small]); source.count += 1; world.sources[small] = source
                _ = try await world.store.applyRefresh(EpisodeListKeysTests.fetched(source.source, title: source.title, count: source.count, offset: source.offset),
                                                       feedID: small, options: .init(now: EpisodeListKeysTests.now))
            }),
            ("unchanged refresh", {
                let source = try #require(world.sources[small])
                _ = try await world.store.applyRefresh(EpisodeListKeysTests.fetched(source.source, title: source.title, count: source.count, offset: source.offset),
                                                       feedID: small, options: .init(now: EpisodeListKeysTests.now.addingTimeInterval(60)))
            }),
        ]
        for (name, event) in events {
            let snapshots = await world.store.snapshotReads
            try await event()
            let sets = try await world.drain().filter { $0.sequence > world.mirror.sequence }
            let request = world.mirror.request(for: sets)
            let pages = await world.store.work.pages
            let read = try await world.store.mirrorRead(request)
            let readPages = await world.store.work.pages - pages
            let work = world.mirror.work
            let delta = world.mirror.apply(read)
            var moved = 0, directory = 0
            for index in world.indexes.indices {
                world.indexes[index].metrics = .init()
                _ = world.indexes[index].apply(delta, mirror: world.mirror)
                moved = max(moved, world.indexes[index].metrics.elementsMoved)
                directory = max(directory, world.indexes[index].metrics.directoryVisited)
            }
            results[name] = Work(snapshots: await world.store.snapshotReads - snapshots, recordsDecoded: read.recordsDecoded,
                                 named: request.episodes.count + request.feeds.count, resets: request.resetFeeds.count,
                                 mirrorWork: world.mirror.work - work, listMoved: moved, listDirectory: directory, pages: readPages)
            try await world.check(name)
        }
        #expect(world.problems.isEmpty, "\(world.problems)")
        return results
    }

    static func expectAbsolute(_ results: [String: Work], episodes: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        for (name, work) in results.sorted(by: { $0.key < $1.key }) {
            #expect(work.snapshots == 0, "\(name): no whole-library read", sourceLocation: sourceLocation)
            #expect(work.resets == 0, "\(name): no feed read whole", sourceLocation: sourceLocation)
            #expect(work.recordsDecoded <= work.named, "\(name): decodes only what was named (\(work))", sourceLocation: sourceLocation)
            #expect(work.named <= 8, "\(name): a routine change names a few keys (\(work))", sourceLocation: sourceLocation)
            // Patch work: the named episodes, plus the small podcast's own episodes for a refresh (its feed changed).
            #expect(work.mirrorWork <= 4 * work.named + 70, "\(name): patch work (\(work))", sourceLocation: sourceLocation)
            #expect(work.listMoved <= 2 * 256 + 16, "\(name): list moves (\(work))", sourceLocation: sourceLocation)
            #expect(work.listDirectory <= 4 * (episodes / 64 + 16), "\(name): directory (\(work))", sourceLocation: sourceLocation)
        }
    }

    @Test func routineChangesStayWithinTheirBudgets() async throws {
        let world = try await Self.world(episodes: 2_000, feeds: 40)
        let results = try await Self.measure(world)
        Self.expectAbsolute(results, episodes: 2_000)
        print("Screen budgets 2k:\n" + results.sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value)" }.joined(separator: "\n"))
        await world.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NTP_SCALE"] == "1"))
    func routineChangesAreFlatAtPowerUserScale() async throws {
        var bySize: [Int: [String: Work]] = [:]
        for (episodes, feeds) in [(10_000, 120), (54_000, 120), (100_000, 500)] {
            let world = try await Self.world(episodes: episodes, feeds: feeds)
            let results = try await Self.measure(world)
            Self.expectAbsolute(results, episodes: episodes)
            bySize[episodes] = results
            print("Screen budgets \(episodes):\n" + results.sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value)" }.joined(separator: "\n"))
            await world.close()
        }
        let base = try #require(bySize[10_000])
        for size in [54_000, 100_000] {
            for (name, work) in try #require(bySize[size]) {
                let small = try #require(base[name])
                #expect(work.recordsDecoded <= small.recordsDecoded + 2, "\(name) at \(size): decodes flat")
                #expect(work.mirrorWork <= small.mirrorWork * 11 / 10 + 16, "\(name) at \(size): patch work flat (\(work) vs \(small))")
                #expect(work.pages <= small.pages * 11 / 10 + 16, "\(name) at \(size): read pages flat (\(work) vs \(small))")
                #expect(work.listMoved <= 2 * 256 + 16, "\(name) at \(size): list moves bounded")
            }
        }
    }
}
