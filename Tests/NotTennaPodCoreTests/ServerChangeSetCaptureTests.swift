import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// The change sets over real exchanges with the pinned server: two phones and the server's own fetches make long seeded sequences of
/// every operation family (queue, marks, favorites, Inbox, history, statistics, listening and adoption, downloads,
/// podcast policies, unsubscribing and subscribing again, catalog changes, shadow publication, pin release, relaunch,
/// Force full synchronization). After every write transaction on either phone the capture oracle checks the delivered
/// set; after every step the sync engine's told sets are checked against its committed sets; periodically and at the end
/// (3) the incremental library is rebuilt from its base records and must not change, and (2) both phones converge with a
/// fresh attach (the server's truth).
@Suite(.serialized) struct ServerChangeSetCaptureTests {
    typealias Agreement = ServerExchangeAgreementTests

    /// SplitMix64: one seed, one sequence, on every machine.
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ bound: Int) -> Int { bound <= 1 ? 0 : Int(next() % UInt64(bound)) }
        mutating func pick<T>(_ items: [T]) -> T? { items.isEmpty ? nil : items[below(items.count)] }
        mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
    }

    final class Side: @unchecked Sendable {
        let name: String
        let phone: ExchangePhone
        var oracle = ChangeSetOracle()
        var log = CommitLog()
        var player: StorePlayer
        var swipe: EpisodeMarkReceipt?
        /// The swiped episode and the play state it showed before the swipe (what its Undo restores).
        var swiped: (wire: String, previous: Int)?

        var history: EpisodeHistoryRemovalReceipt?
        /// The reference's device-only positions (PROTOCOL §8): episodes this phone's paused, not playing player moved; the
        /// position stays on the device, so the server's views are not compared for it.
        var devicePositions: [String: Int32] = [:]
        /// The reference's device-measured durations: an episode this phone's player saved a sample of (the media's
        /// duration as the engine measured it) shows that duration, which reaches the server only with listening facts.
        var deviceDurations: [String: Int32] = [:]
        var store: FeedLibraryStore { phone.store }

        init(_ phone: ExchangePhone) {
            self.phone = phone; name = phone.name
            player = StorePlayer(phone.store, realTime: ())
        }

        func install() async {
            oracle = ChangeSetOracle()
            await phone.store.installChangeOracleForTesting(oracle)
            log = await phone.store.recordCommitsForTesting()
            await phone.engine.recordPublishedChangesForTesting()
        }
    }

    enum Op: String, CaseIterable {
        case markPlayed, markUnplayed, favorite, enqueue, move, dequeue, clearQueue, sortQueue, swipe, swipeUndo, inbox,
             historyRemove, historyUndo, historyClear, statisticsReset, download, cancelDownload, downloadFinish, downloadDelete, listen, seek, switchEpisode,
             adopt, archive, keepUpdated, newEpisodes, unsubscribe, resubscribe, catalogNewEpisode, catalogEdit, exchange,
             pullOnly, shadowExchange, releasePins, relaunch, forceFull, crash, guidChange, restore, stagingAndRemoval
    }

    /// The fixture feeds: 18 episodes by default; `NTP_CHANGESET_EPISODES` (for example 2000, the routine S variant) scales
    /// them, in the same proportions.
    static let feeds: [String: ExchangeWorld.Feed] = {
        let total = Int(ProcessInfo.processInfo.environment["NTP_CHANGESET_EPISODES"] ?? "") ?? 18
        func share(_ base: Int) -> Int { max(1, total * base / 18) }
        return ["/one.xml": ("One", "one", share(6)), "/two.xml": ("Two", "two", share(4)), "/three.xml": ("Three", "three", share(3)),
                "/four.xml": ("Four", "four", share(5))]
    }()
    /// The seeds: six by default; `NTP_CHANGESET_SEEDS` (for example 12, the S variant) more.
    static let seeds: [UInt64] = Array(1...UInt64(Int(ProcessInfo.processInfo.environment["NTP_CHANGESET_SEEDS"] ?? "") ?? 6))

    final class Run: @unchecked Sendable {
        let world: ExchangeWorld
        let a: Side, b: Side
        var random: Random
        var feeds = ServerChangeSetCaptureTests.feeds
        var coverage: [String: Int] = [:]
        var problems: [String] = []
        var steps = 0
        /// Every operation performed, for a failure's report.
        var trace: [String] = []
        /// The episode the last operation picked.
        var picked: Int64?
        /// Rebuild differences while this phone's own facts were pending (reported, not gating).
        var observations: [String] = []
        /// The server's read API, the semantic oracle's truth.
        var reader: ServerReadOracle?
        var semanticChecks = 0
        /// The reference phones: each phone's expected registers and downloads, from the actions alone.
        let reference = ReferencePhones()
        /// The named crash points the mandatory prefix reaches, in order (a later crash picks one at random).
        var crashQueue: [String] = []
        /// Items whose GUID the publisher changed (title, date and enclosure kept), by feed path.
        var movedItems: [String: Set<Int>] = [:]
        /// The server's backup, taken once the phones are set up (the restore family restores it).
        var backup: URL?
        /// Intermediate shown-ahead states that are neither a row's earlier state nor the commit's (reported, the seed goes on).
        var stagingFindings: [String] = []

        init(world: ExchangeWorld, a: Side, b: Side, seed: UInt64) {
            self.world = world; self.a = a; self.b = b; random = Random(state: seed)
        }

        var sides: [Side] { [a, b] }

        func episodes(_ side: Side) async throws -> [Int64] {
            try await side.store.feeds().flatMap { $0.episodes.map(\.id) }.sorted()
        }

        func note(_ label: String) { coverage[label, default: 0] += 1 }

        /// The engine's paths an exchange took (the coverage manifest: each must be reached).
        func notePaths(_ report: ServerExchangeReport) {
            let direct = report.units.filter { !$0.published }.count
            if direct > 0 { coverage["path direct unit", default: 0] += direct }
            if report.publishedUnits > 0 { coverage["path shadow publication", default: 0] += report.publishedUnits }
            if report.stagingBatches > 0 { coverage["path staging", default: 0] += report.stagingBatches }
            if report.shownAhead > 0 { coverage["path shown ahead", default: 0] += report.shownAhead }
            if report.removalBatches > 0 { coverage["path hidden removal", default: 0] += report.removalBatches }
        }

        /// One operation on one phone. Returns false when it did not apply (nothing to act on).
        func perform(_ op: Op, on side: Side) async throws -> Bool {
            let store = side.store
            let ids = try await episodes(side)
            guard let episode = random.pick(ids) else { return op == .resubscribe ? try await resubscribe(side) : false }
            picked = episode
            switch op {
            case .markPlayed, .markUnplayed: try await mark(side, episode, played: op == .markPlayed)
            case .favorite: try await favorite(side, episode, random.chance(60))
            case .enqueue:
                let count = 1 + random.below(3)
                let chosen = (0..<count).compactMap { _ in random.pick(ids) }
                try await enqueue(side, Array(Set(chosen)).sorted(), location: random.chance(50) ? .back : .front)
            case .move:
                let queue = try await store.queue()
                guard queue.count >= 2, let item = random.pick(queue) else { return false }
                _ = try await store.performQueueMove(.item(item.id, finalIndex: random.below(queue.count)), expected: queue.map(QueueEpisodeIdentity.init))
            case .dequeue:
                guard let item = random.pick(try await store.queue()) else { return false }
                try await dequeue(side, item.id)
            case .clearQueue: try await clearQueue(side)
            case .sortQueue: _ = try await store.reorderQueue(random.pick(QueueSortOrder.allCases) ?? .dateOldNew)
            case .swipe: try await swipe(side, episode)
            case .swipeUndo: return try await undoSwipe(side)
            case .inbox: try await dismiss(side, episode)
            case .historyRemove:
                // An episode the history shows, when there is one (its Undo is then reachable).
                let shown = try await store.feeds().flatMap(\.episodes).filter { $0.userState.lastPlayedHistoryMilliseconds != nil }.map(\.id)
                side.history = try await store.removeFromPlaybackHistoryWithUndo(random.pick(shown) ?? episode)
            case .historyUndo:
                guard let receipt = side.history else { return false }
                side.history = nil
                _ = try await store.undoHistoryRemoval(receipt)
            case .historyClear: _ = try await store.clearPlaybackHistory()
            case .statisticsReset: try await store.resetPlayedDurationStatistics()
            case .download:
                let enqueue = random.chance(50)
                let queued = Set(try await store.queue().map(\.id))
                _ = try await store.requestDownload(episodeID: episode, directory: world.root.appendingPathComponent("downloads-\(side.name)"),
                                                    enqueue: enqueue)
                if let wire = try await wire(side, episode) {
                    reference.requestDownload(wire, side: side.name)
                    // Its queue add (an episode not queued yet, with media to download) has the add's fixed effect: NEW
                    // becomes unplayed.
                    if enqueue && !queued.contains(episode), try await shown(side, episode)?.isDownloaded == false {
                        reference.dismiss(wire, side: side.name); reference.queued(wire, true, side: side.name)
                    }
                }
            case .cancelDownload:
                guard let job = random.pick(try await store.downloadJobs()) else { return false }
                // Cancelling a download its request queued takes the episode out of the queue again (Android's
                // `DownloadServiceInterface.cancel` with enqueue on download): a removal of a queued episode.
                let queued = try await store.queue().contains { $0.id == job.episodeID }
                let enqueuedByDownload = try await store.downloadJobs(activeOnly: false).contains { $0.source == job.source && $0.enqueuedByDownload }
                _ = try await store.cancelDownload(id: job.id)
                if let wire = try await wire(side, job.episodeID) {
                    reference.cancelTransfer(wire, side: side.name)
                    if queued && enqueuedByDownload && job.state.isActive { reference.queued(wire, false, side: side.name) }
                }
            case .downloadFinish:
                // A transfer that finishes: its file attached and the job completed (the episode downloaded). Without an
                // active transfer, the person first downloads the picked episode.
                if try await store.downloadJobs().allSatisfy({ !$0.state.isActive }) {
                    _ = try await store.requestDownload(episodeID: episode, directory: world.root.appendingPathComponent("downloads-\(side.name)"), enqueue: false)
                    if let wire = try await wire(side, episode) { reference.requestDownload(wire, side: side.name) }
                }
                guard let job = random.pick(try await store.downloadJobs().filter { $0.state.isActive }),
                      let attempt = try await store.beginDownloadAttempt(id: job.id) else { return false }
                let wire = try await wire(side, job.episodeID)
                try FileManager.default.createDirectory(at: attempt.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 0x41, count: 2_000).write(to: attempt.destination)
                guard try await store.attachDownloadFile(id: job.id, attempt: attempt.attempts),
                      try await store.completeDownload(id: job.id, attempt: attempt.attempts) else {
                    // A transfer that did not finish: the reference stops following it.
                    if let wire { reference.exclude(wires: [wire]) }
                    return false
                }
                try await store.noteDownloadedSizeForTesting(episode: job.episodeID)
                if let wire { reference.finishDownload(wire, side: side.name) }
            case .downloadDelete:
                let downloaded = try await store.feeds().flatMap(\.episodes).filter(\.userState.isDownloaded).map(\.id)
                guard let target = random.pick(downloaded) else { return false }
                let removes = random.chance(50), queued = try await store.queue().contains { $0.id == target }
                try await store.requestMediaDeletion(episodeID: target, deleteRemovesFromQueue: removes)
                if let wire = try await wire(side, target) {
                    reference.deleteDownload(wire, side: side.name)
                    if removes && queued { reference.queued(wire, false, side: side.name) }
                }
            case .listen:
                if side.player.episodeID != episode || random.chance(30) { try await side.player.load(episode) }
                try await side.player.play()
                // An intentional Play records the position as listening: it is the server's now, not the device's alone.
                if let wire = try await store.wireEpisodeForTesting(episode) { side.devicePositions[wire] = nil }
                // The engine plays up to the media's end at most (its natural end is a separate event).
                let room = Int((side.player.duration - side.player.position) / 1_000) - 1
                let seconds = min(5 + random.below(70), room), every = random.chance(50) ? 5 : 30
                if seconds > 0 { try await side.player.listen(seconds, every: every) }
                if random.chance(80) { try await side.player.pause() }
            case .seek:
                guard let current = side.player.episodeID else { return false }
                let paused = !side.player.playing
                try await side.player.seek(to: Int32(random.below(500)) * 1_000)
                // The reference: a paused seek's position is the device's own (PROTOCOL §8) until a Play here or the server's
                // record moves it.
                if paused, let wire = try await store.wireEpisodeForTesting(current) { side.devicePositions[wire] = side.player.position }
                if random.chance(50) { try await side.player.pause() }
            case .switchEpisode:
                guard side.player.episodeID != nil else { return false }
                // A natural end only from a loaded, playing engine, at the media's end; otherwise the person switches away.
                if random.chance(50) { try await side.player.load(episode) }
                else if random.chance(50), side.player.playing, side.player.engineLoaded { _ = try await side.player.end(.ended, at: side.player.duration) }
                else { _ = try await side.player.end(.switched) }
            case .adopt:
                let current = side.player.episodeID
                if try await side.player.adopt() != nil, let current, let wire = try await store.wireEpisodeForTesting(current) { side.devicePositions[wire] = nil }
            case .archive:
                guard let feed = random.pick(try await store.feeds()) else { return false }
                try await store.updatePreferences(feedID: feed.id) { $0.subscriptionState = $0.subscriptionState == .archived ? .subscribed : .archived }
            case .keepUpdated:
                guard let feed = random.pick(try await store.feeds()) else { return false }
                try await store.updatePreferences(feedID: feed.id) { $0.keepUpdated.toggle() }
            case .newEpisodes:
                guard let feed = random.pick(try await store.feeds()) else { return false }
                try await store.updatePreferences(feedID: feed.id) { $0.newEpisodesAction = [.global, .inbox, .queue, .nothing][self.random.below(4)] }
            case .unsubscribe:
                let feeds = try await store.feeds().filter { $0.subscriptionState != .notSubscribed }
                guard feeds.count > 1, let feed = random.pick(feeds) else { return false }
                if side.player.episodeID.map({ id in feed.episodes.contains { $0.id == id } }) == true { _ = try await side.player.end(.switched) }
                // An unsubscribed podcast's episodes leave the reference (a later subscription is not this one's history).
                for item in feed.episodes { if let wire = try await wire(side, item.id) { reference.exclude(wires: [wire]) } }
                _ = try await store.requestFeedDeletion(feedID: feed.id)
            case .resubscribe: return try await resubscribe(side)
            case .catalogNewEpisode, .catalogEdit:
                guard let path = random.pick(Array(feeds.keys).sorted()), var feed = feeds[path] else { return false }
                if op == .catalogNewEpisode { feed.count += 1 } else { feed.title += "+" }
                feeds[path] = feed
                world.setFeed(path, feed)
                serve(path)
                guard let local = try await store.feeds().first(where: { $0.source.hasSuffix(path) }),
                      let podcast = try await store.podcastOfFeedForTesting(local.id) else { return true }
                _ = try? await side.phone.transport.server.send("POST", "v1/refresh", body: ["podcast_id": .string(podcast)])
            case .exchange: notePaths(await side.phone.exchange()); try await observe(side)
            case .pullOnly: notePaths(await side.phone.run([.pull, .apply])); try await observe(side, pushed: false)
            case .shadowExchange:
                await side.phone.engine.setBudgets(direct: 0)
                notePaths(await side.phone.exchange())
                await side.phone.engine.setBudgets(direct: 250)
                try await observe(side)
            case .releasePins:
                if side.player.episodeID != nil, random.chance(50) { try await side.player.load(episode) }
                try await releasePins(side, "a release")
            case .relaunch:
                ChangeOracleRegistry.verify(side.store, side.name)
                try check(side, "before relaunch")
                try await side.phone.relaunch()
                side.player = try await StorePlayer.restored(side.phone.store)
                await side.install()
            case .forceFull:
                await side.phone.engine.requestFullSynchronization()
                let report = await side.phone.engine.forceFullSynchronization()
                notePaths(report)
                // Counted only when a full reprojection was published, not on an exchange without an error.
                if report.reprojected { note("path full publication") }
                try await observe(side)
            case .crash: try await crash(on: side, episode: episode)
            case .guidChange: return try await changeGUID(side)
            case .restore: return try await restoreAndRecover()
            case .stagingAndRemoval: return try await stagingAndRemoval()
            }
            return true
        }

        func resubscribe(_ side: Side) async throws -> Bool {
            let subscribed = Set(try await side.store.feeds().filter { $0.subscriptionState != .notSubscribed }.map(\.source))
            guard let path = random.pick(feeds.keys.sorted().filter { path in !subscribed.contains { $0.hasSuffix(path) } }),
                  let feed = feeds[path] else { return false }
            _ = try await side.store.subscribeForTesting(Agreement.fetched(world.url(String(path.dropFirst())), title: feed.title, prefix: feed.prefix, count: feed.count))
            return true
        }

        /// The semantic oracle at a quiescent point.
        func checkSemantics(final: Bool) async throws {
            guard let reader else { return }
            // The comparison is at one head: the server's own work (a requested refresh) may commit after the phones'
            // exchanges; they exchange again until both stand at the read API's head.
            for _ in 0..<6 {
                let head = try await reader.send("GET", "v1/read/summary")["head"]?["seq"]?.integerValue
                var behind = false
                for side in sides {
                    let cursor = try side.phone.rows("SELECT cursor FROM ntp_library WHERE id = 1").first?.first.flatMap { $0 }.flatMap { try? SyncCursor(encoded: $0) }
                    if cursor?.seq != head { behind = true }
                }
                guard behind else { break }
                for side in sides {
                    await side.phone.exchange(); try await observe(side)
                    try await verify("an exchange to the read API's head of \(side.name) after step \(steps)")
                }
            }
            for side in sides {
                var excluded = Set<String>()
                if !final, let selected = try await side.store.playbackSelectionEpisodeID(), let wire = try await side.store.wireEpisodeForTesting(selected) {
                    excluded.insert(wire)
                }
                let found = try await reader.differences(side.phone, devicePositions: &side.devicePositions, deviceDurations: &side.deviceDurations, excluded: excluded)
                semanticChecks += 1
                if !found.isEmpty {
                    let report = "\(side.name) differs from the server's read API after step \(steps): \(found.prefix(6).joined(separator: "; "))\ntrace: \(trace.suffix(30).joined(separator: ", "))"
                    problems.append(report)
                    throw CaptureFailure()
                }
            }
        }

        /// The oracle's verdict on every transaction so far.
        func check(_ side: Side, _ label: String) throws {
            if !side.oracle.mismatches.isEmpty {
                problems.append("\(side.name) after \(label) (step \(steps)):\n\(side.oracle.report)")
                throw CaptureFailure()
            }
        }

        /// What the engine told equals what its steps committed: the same keys, never an empty set.
        func checkPublication(_ side: Side, _ label: String) async {
            let told = await side.phone.engine.takePublishedChangesForTesting()
            let committed = side.log.take().commits.filter { $0.origin == .sync }.compactMap(\.set)
            if told.contains(where: \.isEmpty) { problems.append("\(side.name) \(label): an empty set was told") }
            let toldKeys = told.reduce(into: Set<String>()) { $0.formUnion(Self.keys($1)) }
            let committedKeys = committed.reduce(into: Set<String>()) { $0.formUnion(Self.keys($1)) }
            if toldKeys != committedKeys {
                problems.append("\(side.name) \(label): told \(toldKeys.subtracting(committedKeys).sorted()) more and \(committedKeys.subtracting(toldKeys).sorted()) fewer than committed")
            }
            if !committed.isEmpty { note("told") }
        }

        static func keys(_ set: LibraryChangeSet) -> Set<String> {
            var keys = Set<String>()
            for key in set.feeds.keys { keys.insert("feed \(key)") }
            for key in set.episodes.keys { keys.insert("episode \(key)") }
            for key in set.statistics.keys { keys.insert("statistics \(key)") }
            for key in set.downloads.keys { keys.insert("download \(key)") }
            for key in set.undo.keys { keys.insert("undo \(key)") }
            for key in set.localFolders.keys { keys.insert("folder \(key)") }
            if let queue = set.queue {
                for key in queue.added { keys.insert("queue+ \(key)") }
                for key in queue.removed { keys.insert("queue- \(key)") }
                for key in queue.relinked { keys.insert("queue~ \(key)") }
            }
            return keys
        }
    }

    struct CaptureFailure: Error {}

    /// Rebuild differences set aside as the known refresh-status and local-completion gaps (reported, not fixed here).
    static let knownStatusGaps = Mutex(0)
    static let knownCompletionGaps = Mutex(0)
    static let knownRegistrationGaps = Mutex(0)
    static let knownDownloadSizes = Mutex(0)
    static let totalCoverage = Mutex<[String: Int]>([:])

    /// The incremental library rebuilt from its own base records (Force full synchronization's reprojection, on a copy)
    /// must show exactly what it shows: the visible model before and after are compared.
    static func rebuildDifferences(_ phone: ExchangePhone) async throws -> [String] {
        try await rebuildDifferences(phone.store, ownedRoot: phone.location.ownedRoot, archive: phone.location.syncDatabase)
    }

    static func rebuildDifferences(_ live: FeedLibraryStore, ownedRoot: URL, archive: URL?) async throws -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Rebuild-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("library.sqlite")
        try await live.databaseForTesting { db in try db.execute("VACUUM main INTO ?", [.text(copy.path)]) }
        let livePins = try ServerLibraryFixture.read(copy, "SELECT n.local_id, p.fields FROM ntp_deferred_pins p JOIN ntp_episodes n ON n.episode_id = p.episode_id")
        var cache: [Data: Data] = [:]
        func feedRecords() throws -> [Int64: String] {
            var result: [Int64: String] = [:]
            for row in try ServerLibraryFixture.read(copy, "SELECT id, CAST(record AS TEXT), title FROM feeds") {
                result[Int64(row[0]!)!] = (row[1] ?? "").dropLast() + ",\"__title\":\(row[2].map { "\"\($0)\"" } ?? "null")}"
            }
            return result
        }
        func records() throws -> [Int64: String] {
            var result: [Int64: String] = [:]
            for row in try ServerLibraryFixture.read(copy, "SELECT id, CAST(record AS TEXT) FROM episodes") { result[Int64(row[0]!)!] = row[1] ?? "" }
            return result
        }
        func image() throws -> ChangeSetOracle.Model {
            let reader = try LibrarySQLite(readingOnly: copy); defer { try? reader.close() }
            return try ChangeSetOracle.read(reader, cache: &cache)
        }
        // The before image is the live step's own state, read from the copy before anything opens it.
        let before = try image()
        let recordsBefore = try records(), feedsBefore = try feedRecords()
        let store = try FeedLibraryStore(url: copy, ownedRoot: ownedRoot)
        do {
            // Opening the copy is a relaunch, and its restart export runs first, as at a real relaunch (PROTOCOL §8.2). The
            // reference accounts for it on its own: an export turns the open session's saves into facts and changes nothing a
            // person sees, so the opened, flushed copy still shows exactly the live state.
            try await store.flushServerPlayback()
            let opened = ChangeSetOracle.difference(before.semantic, try image().semantic)
            if !opened.isEmpty {
                try await store.close()
                return ["opening and flushing the copy changed what it shows: feeds \(opened.feeds), episodes \(opened.episodes), statistics \(opened.statistics), downloads \(opened.downloads), undo \(opened.undo), folders \(opened.folders), queue \(opened.queue)"]
            }
            guard let head = try await store.serverExchangeState().cursor else { try await store.close(); return [] }
            let records = try ServerLibraryFixture.read(copy, "SELECT entity, id, field_group, CAST(value AS TEXT), provenance FROM ntp_records")
            let items: [ContractJSON] = try records.map { row in
                let provenance = try row[4].map { try ContractJSON.decode(Array($0.utf8)) } ?? []
                return ["record": ["entity": .string(row[0]!), "id": .string(row[1]!), "field_group": .string(row[2]!),
                                   "value": try ContractJSON.decode(Array(row[3]!.utf8)), "provenance": provenance]]
            }
            let page = directory.appendingPathComponent("page.json")
            try ContractJSON.object(["items": .array(items)]).canonicalData().write(to: page)
            let snapshot = ServerAttachSnapshot(head: head.encoded, installWatermark: 0, itemCount: items.count, podcastCount: 0, pages: [page])
            let staged = directory.appendingPathComponent("full.sqlite")
            try ServerFullReprojection.stageBase(snapshot, into: staged)
            let ids = try await store.reserveServerLocalIDs(feeds: 64, episodes: 512)
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            // The history the phone's archive holds, as Force full synchronization reads it.
            let history = try archive.map { try ServerArchiveReader(url: $0) }
            let build = try ServerFullReprojection.build(database: copy, file: staged, history: history, now: now,
                                                         feedIDs: ids.feeds, episodeIDs: ids.episodes, touches: try await store.serverTouchWatermark())
            _ = try await store.publishFullReprojection(build, head: head, now: now, crash: nil, history: history)
            try await store.close()
        } catch { try? await store.close(); throw error }
        let after = try { () throws -> ChangeSetOracle.Model in
            let reader = try LibrarySQLite(readingOnly: copy); defer { try? reader.close() }
            return try ChangeSetOracle.read(reader, cache: &cache)
        }()
        // The complete visible model: every feed and episode record field (metadata, details, dates, titles, refresh
        // status), statistics with their units, downloads, Undo guards, folders and the queue.
        var difference = ChangeSetOracle.difference(before.semantic, after.semantic)
        func json(_ data: Data?) -> NSMutableDictionary? {
            data.flatMap { (try? JSONSerialization.jsonObject(with: $0, options: [.mutableContainers])) as? NSMutableDictionary }
        }
        // The named exceptions excuse single fields, each validated: a field set aside must hold exactly what its named
        // source gives, field by field; everything else stays compared (measured duration, the publication-date column and
        // its record, user state, statistics units).
        let livePath = try await live.databaseForTesting { $0.fileURL?.path } ?? ""
        let parses = OwnParses.parses(of: livePath)
        let registeredHere = Set(try ServerLibraryFixture.read(copy, "SELECT DISTINCT feed_id FROM ntp_registrations WHERE feed_id IS NOT NULL").compactMap { $0[0].flatMap(Int64.init) })
        let pendingFeeds = Set(try ServerLibraryFixture.read(copy, "SELECT feed_id FROM ntp_registrations WHERE state = 'pending' AND feed_id IS NOT NULL").compactMap { $0[0].flatMap(Int64.init) })
        func source(_ data: Data?) -> String? { (json(data)?["source"] as? String).map { ContractURL.normalize(ContractURL.stripUserinfo($0)) } }
        let downloadedSizes = OwnParses.downloadedSizes(of: livePath)
        /// The rows this phone stored from its own parse of a live feed (nil: none known, nothing excused).
        func ownParse(_ feed: Int64) async throws -> OwnParses.Image? {
            guard registeredHere.contains(feed), let address = source(before.feedRows[feed]?.record) else { return nil }
            return parses[address]
        }
        // The parse's permission expires record by record: the canonical metadata records of each registered feed's
        // podcast and episodes, as the live library holds them at this check; one seen to change since the first seen is
        // the canonical projection's from then on.
        var superseded: [Int64: Set<String>] = [:]
        var wireOf: [Int64: String] = [:]
        for row in try ServerLibraryFixture.read(copy, "SELECT local_id, episode_id FROM ntp_episodes WHERE local_id IS NOT NULL") {
            if let local = row[0].flatMap(Int64.init), let wire = row[1], wireOf[local] == nil { wireOf[local] = wire }
        }
        for feed in registeredHere {
            guard let address = source(before.feedRows[feed]?.record), parses[address] != nil,
                  let podcast = try ServerLibraryFixture.read(copy, "SELECT podcast_id FROM ntp_podcasts WHERE feed_id = \(feed)").first?.first ?? nil else { continue }
            var records: [String: String] = [:]
            for row in try ServerLibraryFixture.read(copy, "SELECT CAST(value AS TEXT) FROM ntp_records WHERE entity = 'podcast' AND id = '\(podcast)' AND field_group = 'metadata'") {
                records["podcast"] = row[0] ?? ""
            }
            for row in try ServerLibraryFixture.read(copy, "SELECT r.id, CAST(r.value AS TEXT) FROM ntp_records r JOIN ntp_episodes n ON n.episode_id = r.id WHERE r.entity = 'episode' AND r.field_group = 'metadata' AND n.podcast_id = '\(podcast)'") {
                if let wire = row[0] { records[wire] = row[1] ?? "" }
            }
            superseded[feed] = OwnParses.superseded(records, address: address, library: livePath)
        }
        /// Whether the parse still supplies `key` ("podcast", or an episode's wire) of `feed`.
        func parseSupplies(_ feed: Int64, _ key: String?) -> Bool { key.map { !(superseded[feed]?.contains($0) ?? false) } ?? false }
        func equal(_ a: Any?, _ b: Any?) -> Bool {
            switch (a, b) {
            case (nil, nil): true
            case (let x?, let y?): (x as AnyObject).isEqual(y)
            default: false
            }
        }
        // Named exception "own parse" (counted): a podcast this phone registered keeps its own parse's header (the feed's
        // metadata and title) and shows no server refresh status until those records next change, while a rebuild applies
        // the stored canonical metadata and status at once (PROTOCOL §6.8). Only a feed with this phone's registration and a
        // known saved parse; only its metadata, title and refresh status; each equal to that parse (the status not shown).
        for (id, change) in difference.feeds where change == .changed {
            guard let parse = try await ownParse(id), parseSupplies(id, "podcast"),
                  let old = json(before.feedRows[id]?.record), let new = json(after.feedRows[id]?.record) else { continue }
            var excused = true
            for key in Set((old.allKeys + new.allKeys).compactMap { $0 as? String }) where !equal(old[key], new[key]) {
                switch key {
                case "metadata": excused = excused && equal(old[key], parse.feed[key])
                case "serverRefresh": excused = excused && old[key] == nil
                default: excused = false
                }
            }
            let titles = before.feedRows[id].map { ChangeSetOracle.bytes($0.title) } == after.feedRows[id].map { ChangeSetOracle.bytes($0.title) }
                || before.feedRows[id].map { ChangeSetOracle.bytes($0.title) } == ChangeSetOracle.bytes(parse.title.map(LibrarySQLValue.text) ?? .null)
            if excused, titles { difference.feeds[id] = nil; knownStatusGaps.withLock { $0 += 1 } }
        }
        // Pending registration: a feed the full projection adds for the address of a feed whose registration is pending, or
        // of one being removed (the podcast registered again, or removed, while its facts are unsent); nothing of it is live.
        do {
            let removing = Set(try ServerLibraryFixture.read(copy, "SELECT feed_id FROM ntp_hidden_feeds").compactMap { $0[0].flatMap(Int64.init) })
            var addresses = Set((pendingFeeds.union(removing)).compactMap { source(before.feedRows[$0]?.record) ?? source(after.feedRows[$0]?.record) })
            for row in try ServerLibraryFixture.read(copy, "SELECT feed_url FROM ntp_registrations WHERE state = 'pending'") {
                if let url = row[0] { addresses.insert(ContractURL.normalize(ContractURL.stripUserinfo(url))) }
            }
            var added = Set<Int64>()
            for (id, change) in difference.feeds where change == .added {
                if let address = source(after.feedRows[id]?.record), addresses.contains(address) { added.insert(id) }
            }
            for id in added { difference.feeds[id] = nil }
            for (id, change) in difference.episodes where change.change == .added && added.contains(change.feed ?? -1) { difference.episodes[id] = nil }
            for (id, change) in difference.statistics where change.change == .added && added.contains(change.feed ?? -1) { difference.statistics[id] = nil }
            if !added.isEmpty { knownRegistrationGaps.withLock { $0 += 1 } }
        }
        // Named exception "pending registration" for a live feed (counted, reported as a full-projection gap): while this
        // phone's registration of the feed is pending, a full projection matches it by its address to the podcast it
        // registers again and shows that podcast's earlier records; the live library shows the new subscription until the
        // server resolves it (PROTOCOL §15.2). Each user-state or feed field set aside must equal what this phone stored for
        // the new subscription from its own parse.
        for (id, change) in difference.feeds where change == .changed && pendingFeeds.contains(id) {
            guard let parse = try await ownParse(id), let old = json(before.feedRows[id]?.record), let new = json(after.feedRows[id]?.record) else { continue }
            // The person's own pending policy changes of the new subscription (kept on its local feed until it resolves).
            var pendingPolicies: [String: Any] = [:]
            for row in try ServerLibraryFixture.read(copy, "SELECT property, CAST(value AS TEXT) FROM ntp_overlays WHERE entity = 'podcast' AND id = 'local-feed:\(id)' AND kind = 'register' ORDER BY clock") {
                guard let property = row[0], let text = row[1], let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else { continue }
                pendingPolicies[property] = value
            }
            func ownPending(_ key: String, _ value: Any?) -> Bool {
                switch key {
                // Keep updated: the person's pending change, or the parse's unset value, whose meaning is on (a preference
                // edit writes the default out).
                case "keepUpdatedValue": (pendingPolicies["keep_updated"] as? Bool ?? (parse.feed[key] == nil ? true : nil)).map { $0 == (value as? NSNumber)?.boolValue } ?? false
                case "newEpisodesAction": (pendingPolicies["new_episodes_action"] as? String).map { ServerProjector.action($0).rawValue == (value as? NSNumber)?.intValue } ?? false
                default: false
                }
            }
            let excused = Set((old.allKeys + new.allKeys).compactMap { $0 as? String }).filter { !equal(old[$0], new[$0]) }
                .allSatisfy { key in key != "id" && key != "lastRefreshAttempt"
                    && (equal(old[key], parse.feed[key]) || (key == "serverRefresh" && old[key] == nil) || ownPending(key, old[key])) }
            if excused { difference.feeds[id] = nil; knownRegistrationGaps.withLock { $0 += 1 } }
        }
        // Named exception "superseded own claim" (counted, reported as a pending-state gap): this phone's pending end or
        // checkpoint under a claim that no longer owns the episode's position (another device's claim arrived since the
        // load) still shows what this phone decided (played at 0 for a completion, its own listening position), while the
        // projection of those pending facts shows the record's owner; they agree once the facts' receipts arrive. Only the
        // play state and position of an episode with such a pending completion or session position overlay.
        func supersededOwnClaim(_ id: Int64) throws -> Bool {
            guard let owner = try ServerLibraryFixture.read(copy, "SELECT json_extract(CAST(r.value AS TEXT), '$.claim_id') FROM ntp_records r JOIN ntp_episodes n ON n.episode_id = r.id WHERE n.local_id = \(id) AND r.entity = 'episode' AND r.field_group = 'position'").first?.first
            else { return false }
            let pending = try ServerLibraryFixture.read(copy, "SELECT coalesce(json_extract(CAST(o.value AS TEXT), '$.claim'), '') FROM ntp_overlays o JOIN ntp_episodes n ON n.episode_id = o.id WHERE n.local_id = \(id) AND o.kind IN ('completion', 'session_position')")
            return pending.contains(where: { $0.first ?? nil != owner })
        }
        // Per episode: each differing field is excused only by a named source it matches: "own parse" (a detail field equal
        // to what this phone stored from its own parse, a measured duration never), "pending registration" (as for the
        // feed), "downloaded size" (a media size equal to the file a download of this phone finished with: a finished
        // download sets the size to its file's, as Android does, which the metadata record's feed size replaces in a full
        // projection at once and in the live library at the record's next change), "superseded own claim" (above).
        let measured = Set(try ServerLibraryFixture.read(copy, "SELECT n.local_id FROM ntp_records r JOIN ntp_episodes n ON n.episode_id = r.id WHERE r.entity = 'episode' AND r.field_group = 'measured_duration'").compactMap { $0[0].flatMap(Int64.init) })
        for (id, change) in difference.episodes where change.change == .changed {
            guard let feed = before.episodes[id]?.feed, after.episodes[id]?.feed == feed,
                  let old = json(before.episodeRows[id]?.record), let new = json(after.episodeRows[id]?.record),
                  before.statisticsUnits[id] == after.statisticsUnits[id] else { continue }
            // The publication-date column always agrees with its record's date, on both sides.
            func columnAgrees(_ row: (pubdate: LibrarySQLValue, record: Data)?, _ image: NSDictionary) -> Bool {
                guard case .integer(let column)? = row?.pubdate, let date = (image["details"] as? NSDictionary)?["publicationDate"] as? Double else { return false }
                return column == Int64(Date(timeIntervalSinceReferenceDate: date).timeIntervalSince1970 * 1_000)
            }
            guard columnAgrees(before.episodeRows[id], old), columnAgrees(after.episodeRows[id], new) else { continue }
            let parse = try await ownParse(feed)
            let identifier = (old["details"] as? NSDictionary)?["identifier"] as? String
            let parsed = identifier.flatMap { parse?.episodes[$0] }
            // The parse supplies this episode's details only until its canonical record next changes (while the
            // registration is pending, the new subscription shows its own parse).
            let supplied = pendingFeeds.contains(feed) || parseSupplies(feed, wireOf[id])
            var reasons = Set<String>()
            var excused = true
            for key in Set((old.allKeys + new.allKeys).compactMap { $0 as? String }) where !equal(old[key], new[key]) {
                switch key {
                case "details":
                    let live = old[key] as? NSDictionary ?? [:], rebuilt = new[key] as? NSDictionary ?? [:], own = supplied ? parsed?["details"] as? NSDictionary : nil
                    for field in Set((live.allKeys + rebuilt.allKeys).compactMap { $0 as? String }) where !equal(live[field], rebuilt[field]) {
                        if field == "media" {
                            let a = live[field] as? NSDictionary ?? [:], b = rebuilt[field] as? NSDictionary ?? [:], o = own?[field] as? NSDictionary
                            for sub in Set((a.allKeys + b.allKeys).compactMap { $0 as? String }) where !equal(a[sub], b[sub]) {
                                if sub == "size", let file = downloadedSizes[id], (a[sub] as? NSNumber)?.int64Value == file { reasons.insert("downloaded size"); continue }
                                // A measured duration is canonical, never the parse's; while the registration is pending the
                                // rebuild's is the earlier generation's (the new subscription shows its own parse).
                                if ["url", "size", "mimeType"].contains(sub) || (sub == "durationMilliseconds" && (!measured.contains(id) || pendingFeeds.contains(feed))),
                                   let o, equal(a[sub], o[sub]) { reasons.insert(pendingFeeds.contains(feed) ? "pending registration" : "own parse"); continue }
                                excused = false
                            }
                        } else if ["title", "description", "link", "publicationDate", "imageURL", "paymentLink", "chapterURL",
                                   "socialInteractionURL", "transcript", "chapters"].contains(field), let own, equal(live[field], own[field]) {
                            reasons.insert("own parse")
                        } else { excused = false }
                    }
                case "userState":
                    let live = old[key] as? NSDictionary ?? [:], rebuilt = new[key] as? NSDictionary ?? [:]
                    for field in Set((live.allKeys + rebuilt.allKeys).compactMap { $0 as? String }) where !equal(live[field], rebuilt[field]) {
                        if pendingFeeds.contains(feed), let fresh = parsed?["userState"] as? NSDictionary, equal(live[field], fresh[field]) {
                            reasons.insert("pending registration"); continue
                        }
                        if ["playState", "positionMilliseconds"].contains(field), try supersededOwnClaim(id) { reasons.insert("superseded own claim"); continue }
                        excused = false
                    }
                default: excused = false
                }
            }
            guard excused, !reasons.isEmpty else { continue }
            difference.episodes[id] = nil
            if difference.statistics[id]?.change == .changed { difference.statistics[id] = nil }
            for reason in reasons {
                switch reason {
                case "own parse": knownStatusGaps.withLock { $0 += 1 }
                case "downloaded size": knownDownloadSizes.withLock { $0 += 1 }
                case "pending registration": knownRegistrationGaps.withLock { $0 += 1 }
                default: knownCompletionGaps.withLock { $0 += 1 }
                }
            }
        }
        guard !difference.isEmpty else { return [] }
        let recordsAfter = try records()
        var details: [String] = []
        let feedsAfter = try feedRecords()
        if !difference.feeds.isEmpty {
            details.append("feeds now: \(try ServerLibraryFixture.read(copy, "SELECT id, json_extract(CAST(record AS TEXT), '$.source'), json_extract(CAST(record AS TEXT), '$.subscriptionState') FROM feeds"))")
            details.append("hidden: \(try ServerLibraryFixture.read(copy, "SELECT * FROM ntp_hidden_feeds")), registrations: \(try ServerLibraryFixture.read(copy, "SELECT feed_id, state, podcast_id, feed_url FROM ntp_registrations")), podcasts: \(try ServerLibraryFixture.read(copy, "SELECT podcast_id, feed_id, live_generation, pinned_removal FROM ntp_podcasts"))")
            details.append("live feeds: \(feedsBefore.keys.sorted()) pending podcast overlays: \(try ServerLibraryFixture.read(copy, "SELECT id, property, kind, CAST(value AS TEXT) FROM ntp_overlays WHERE entity = 'podcast'"))")
        }
        for id in difference.feeds.keys.sorted() {
            let oldBytes = Array((feedsBefore[id] ?? "").utf8), newBytes = Array((feedsAfter[id] ?? "").utf8)
            if let first = zip(oldBytes, newBytes).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset
                ?? (oldBytes.count != newBytes.count ? min(oldBytes.count, newBytes.count) : nil) {
                func window(_ bytes: [UInt8]) -> String { String(decoding: bytes[max(0, first - 80)..<min(bytes.count, first + 80)], as: UTF8.self) }
                details.append("feed \(id) at \(first): \(window(oldBytes)) → \(window(newBytes))")
            }
            if let a = json(before.feedRows[id]?.record), let b = json(after.feedRows[id]?.record) {
                for key in Set((a.allKeys + b.allKeys).compactMap { $0 as? String }).sorted() where !equal(a[key], b[key]) {
                    let own = parses[source(before.feedRows[id]?.record) ?? ""]?.feed[key]
                    var note = ""
                    if let live = a[key] as? NSDictionary, let parsed = own as? NSDictionary {
                        note = " differs from the own parse in " + Set((live.allKeys + parsed.allKeys).compactMap { $0 as? String }).filter { !equal(live[$0], parsed[$0]) }.sorted()
                            .map { "\($0)=\(String(describing: live[$0]).prefix(60))/\(String(describing: parsed[$0]).prefix(60))" }.joined(separator: ",")
                    }
                    details.append("feed \(id) \(key): \(String(describing: a[key]).prefix(120)) → \(String(describing: b[key]).prefix(120)) (own parse: \(String(describing: own).prefix(120)))\(note)")
                }
            }
            let old = try? ContractJSON.decode(Array((feedsBefore[id] ?? "").utf8)), new = try? ContractJSON.decode(Array((feedsAfter[id] ?? "").utf8))
            for key in Set(old?.objectValue?.members.map(\.name) ?? []).union(new?.objectValue?.members.map(\.name) ?? []).sorted() where old?[key] != new?[key] {
                details.append("feed \(id) \(key): \(String(describing: old?[key])) → \(String(describing: new?[key]))")
            }
        }
        for id in difference.episodes.keys.sorted() {
            let old = (try? ContractJSON.decode(Array((recordsBefore[id] ?? "").utf8))), new = (try? ContractJSON.decode(Array((recordsAfter[id] ?? "").utf8)))
            let overlays = try ServerLibraryFixture.read(copy, "SELECT o.clock, substr(o.op_id, 1, 4), o.property, o.kind, CAST(o.value AS TEXT) FROM ntp_overlays o JOIN ntp_episodes n ON n.episode_id = o.id WHERE n.local_id = \(id) ORDER BY o.clock, o.op_id, o.property").map { $0.map { $0 ?? "-" }.joined(separator: " ") }
            let sessions = try ServerLibraryFixture.read(copy, "SELECT state, json_extract(CAST(record AS TEXT), '$.startRecorded'), json_extract(CAST(record AS TEXT), '$.end.completed') FROM ntp_sessions WHERE episode_id = \(id)")
            if ProcessInfo.processInfo.environment["NTP_REBUILD_DETAIL"] != nil {
                print("REBUILD-DETAIL episode \(id) sessions \(sessions) overlays:\n" + overlays.joined(separator: "\n"))
            }
            let selection = try ServerLibraryFixture.read(copy, "SELECT episode_id FROM playback_selection")
            let pins = try ServerLibraryFixture.read(copy, "SELECT p.fields FROM ntp_deferred_pins p JOIN ntp_episodes n ON n.episode_id = p.episode_id WHERE n.local_id = \(id)")
            let records = try ServerLibraryFixture.read(copy, "SELECT r.field_group, CAST(r.value AS TEXT) FROM ntp_records r JOIN ntp_episodes n ON n.episode_id = r.id WHERE n.local_id = \(id) AND r.field_group IN ('position', 'play_state', 'last_played')")
            details.append("episode \(id): selection \(selection), pins \(pins) (live \(livePins.filter { $0[0] == String(id) })), overlays \(overlays), records \(records)")
            for key in Set(old?.objectValue?.members.map(\.name) ?? []).union(new?.objectValue?.members.map(\.name) ?? []).sorted()
            where key != "userState" && key != "details" && old?[key] != new?[key] {
                details.append("episode \(id) \(key): \(String(describing: old?[key])) → \(String(describing: new?[key]))")
            }
            if before.episodeRows[id].map({ ChangeSetOracle.bytes($0.pubdate) }) != after.episodeRows[id].map({ ChangeSetOracle.bytes($0.pubdate) }) {
                details.append("episode \(id) pubdate column: \(String(describing: before.episodeRows[id]?.pubdate)) → \(String(describing: after.episodeRows[id]?.pubdate))")
            }
            if before.statisticsUnits[id] != after.statisticsUnits[id] { details.append("episode \(id) statistics units differ") }
            for part in ["userState", "details"] {
                for key in Set(old?[part]?.objectValue?.members.map(\.name) ?? []).union(new?[part]?.objectValue?.members.map(\.name) ?? []).sorted()
                where old?[part]?[key] != new?[part]?[key] {
                    details.append("episode \(id) \(part).\(key): \(String(describing: old?[part]?[key])) → \(String(describing: new?[part]?[key]))")
                }
            }
        }
        return details + ["feeds \(difference.feeds)", "episodes \(difference.episodes)", "statistics \(difference.statistics)",
                "downloads \(difference.downloads)", "undo \(difference.undo)", "folders \(difference.folders)", "queue \(difference.queue)"]
    }

    /// One seeded run: every operation family once on each phone (the mandatory prefix), then `steps` random operations.
    static func run(seed: UInt64, steps: Int, quiesceEvery: Int = 15) async throws -> Run {
        var outcome: Run?
        do { try await ExchangeWorld.run(feeds: Self.feeds) { world in
            // The import family: the account starts from an Android database a person exported from a phone without a
            // server and imported on the web (PROTOCOL §11.5); the phones' first attachments adopt it.
            let reader = try await ServerReadOracle(world.server)
            try await reader.importLibrary(try await Self.importedLibrary(world))
            let a = Side(try await world.attach("A", recoverable: true)), b = Side(try await world.attach("B", recoverable: true))
            await a.install(); await b.install()
            let run = Run(world: world, a: a, b: b, seed: seed)
            run.reader = reader
            outcome = run
            try await run.adoptImport()
            // Both phones subscribe, and the server's own fetches arrive.
            for path in ["one.xml", "two.xml"] {
                let feed = Self.feeds["/" + path]!
                let local = try await a.store.subscribeForTesting(Agreement.fetched(world.url(path), title: feed.title, prefix: feed.prefix, count: feed.count))
                try await Agreement.waitForCatalog(a.phone, feedID: local.id)
            }
            let local = try await b.store.subscribeForTesting(Agreement.fetched(world.url("three.xml"), title: "Three", prefix: "three", count: Self.feeds["/three.xml"]!.count))
            try await Agreement.waitForCatalog(b.phone, feedID: local.id)
            for _ in 0..<2 { await a.phone.exchange(); await b.phone.exchange() }
            for side in run.sides { try await run.observe(side) }
            try await run.startQueue(imported: ["four-3"])
            // The backup the restore family returns the server to: the prefix's changes after it are what recovery restores.
            run.backup = try await world.backUp()
            var plan: [(Op, Side)] = []
            for op in Op.allCases where ![.relaunch, .forceFull, .crash, .restore, .stagingAndRemoval].contains(op) { plan.append((op, a)); plan.append((op, b)) }
            plan += [(.exchange, a), (.exchange, b), (.relaunch, a), (.forceFull, a), (.exchange, b)]
            // Three named crash points per seed, so the six seeds reach every one (PROTOCOL §16 scenarios 2 and 29).
            let points = ServerExchangeCrashTests.points
            run.crashQueue = (0..<3).map { points[(Int(seed) * 3 + $0) % points.count] }
            plan += [(.crash, a), (.crash, b), (.crash, a), (.restore, a), (.stagingAndRemoval, a)]
            for _ in 0..<steps {
                let op = run.random.pick(Op.allCases.filter { ![.restore, .stagingAndRemoval].contains($0) && ($0 != .relaunch || run.random.chance(10)) })!
                plan.append((op, run.random.chance(60) ? a : b))
            }
            for (op, side) in plan {
                run.steps += 1
                let playing = side.player.episodeID
                let performed = try await run.perform(op, on: side)
                // The reference: every episode the player saved a sample of shows the engine's measured duration.
                for episode in [playing, side.player.episodeID].compactMap({ $0 }) where [.listen, .seek, .switchEpisode, .releasePins, .adopt].contains(op) {
                    if let wire = try await side.store.wireEpisodeForTesting(episode) {
                        side.deviceDurations[wire] = side.player.duration
                        // The player's own effects on the play state and the queue (a start, a completion, a skip) are not
                        // modelled: unknown.
                        run.reference.playState(wire, nil, side: side.name)
                        run.reference.queued(wire, nil, side: side.name)
                    }
                }
                if performed { run.note(op.rawValue); run.trace.append("\(run.steps) \(op.rawValue) \(side.name) e\(run.picked ?? 0) p\(side.player.episodeID ?? 0)") }
                // The app releases the pins when the player leaves an episode (its scheduler's `playerLeftEpisode`).
                if side.player.episodeID != playing { try await run.releasePins(side, "the player left an episode") }
                try await run.verify("\(op.rawValue) on \(side.name)")
                if run.steps % quiesceEvery == 0 {
                    // A quiescent point (every fact retired) now and then: the semantic oracle compares each phone with the
                    // server's read API (the player's own episode, whose session may hold unexported listening, left out).
                    // Every quiescing exchange is verified like a step.
                    for _ in 0..<2 {
                        for side in run.sides {
                            await side.phone.exchange(); try await run.observe(side)
                            try await run.verify("a quiescing exchange of \(side.name) after step \(run.steps)")
                        }
                    }
                    try await run.checkSemantics(final: false)
                }
            }
            // Quiescent: both players leave their episodes (what waited for them applies), both phones exchange until
            // nothing is unsent, then they match the incremental rebuild and a fresh attach.
            for side in run.sides {
                if let current = side.player.episodeID, let wire = try await run.wire(side, current) {
                    run.reference.playState(wire, nil, side: side.name); run.reference.queued(wire, nil, side: side.name)
                }
                // A natural end only from a loaded, playing engine; otherwise the person switches away.
                if side.player.playing, side.player.engineLoaded { _ = try? await side.player.end(.ended, at: side.player.duration) }
                else { _ = try? await side.player.end(.switched) }
                // A player still showing an episode (a switch keeps it selected) closes it: its reset leaves the player.
                if let selected = try await side.store.playbackSelectionEpisodeID() { try await run.resetPosition(side, selected) }
                try await run.releasePins(side, "leaving at the end")
            }
            try await run.verify("the players left")
            for _ in 0..<2 {
                for side in run.sides {
                    await side.phone.exchange(); try await run.observe(side)
                    try await run.verify("a final exchange of \(side.name)")
                }
            }
            let fresh = try await world.attach("fresh")
            let expected = try await fresh.view()
            for side in run.sides {
                // The reference keeps the device-only positions (PROTOCOL §8) on the phone: the server never had them.
                var view = try await side.phone.view().withoutTitles
                for (wire, position) in side.devicePositions where view.episodes[wire]?.position == position {
                    if let theirs = expected.episodes[wire] { view.episodes[wire]?.position = theirs.position }
                }
                let differences = view.differences(from: expected.withoutTitles)
                guard !differences.isEmpty else { continue }
                var detail: [String] = []
                for podcast in Set(differences.compactMap { $0.hasPrefix("podcast ") ? String($0.dropFirst(8).prefix(12)) : nil }) {
                    detail += try side.phone.rows("SELECT podcast_id, feed_id, live_generation, pinned_removal FROM ntp_podcasts WHERE podcast_id LIKE '\(podcast)%'").map { "\($0)" }
                    detail += try side.phone.rows("SELECT field_group, CAST(value AS TEXT) FROM ntp_records WHERE entity = 'podcast' AND id LIKE '\(podcast)%'").map { "\($0)" }
                }
                run.problems.append("\(side.name) differs from a fresh attach: \(differences.prefix(4).joined(separator: "; "))\n\(detail.joined(separator: "\n"))\ntrace: \(run.trace.joined(separator: ", "))")
            }
            await fresh.close()
            for side in run.sides { try run.check(side, "convergence"); await run.checkPublication(side, "convergence") }
            try await run.checkSemantics(final: true)
            // The enclosure family reached the server's identity decisions: a changed GUID is an alias of the episode it
            // was (the podcast's identity rules), and a merged episode redirects to its survivor.
            for side in run.sides {
                if try side.phone.rows("SELECT count(*) FROM ntp_records WHERE entity = 'podcast' AND field_group = 'identity_rules' AND CAST(value AS TEXT) LIKE '%-r\"%'") != [["0"]] {
                    run.note("family guid change")
                }
                if let merged = try side.phone.rows("SELECT count(*) FROM ntp_episodes WHERE merged_into IS NOT NULL").first?.first ?? nil, merged != "0" {
                    run.coverage["episode merges", default: 0] += Int(merged) ?? 0
                }
            }
            let differences = try await Self.rebuildDifferences(a.phone)
            if !differences.isEmpty { run.problems.append("final rebuild: \(differences.joined(separator: "; "))") }
            for side in run.sides {
                for (name, count) in side.oracle.coverage { run.coverage["relation \(name)", default: 0] += count }
            }
        } } catch is CaptureFailure {}
        return outcome!
    }

    @Test(arguments: Self.seeds) func everyTransactionOfASeededSequenceMatchesTheOracle(seed: UInt64) async throws {
        if let only = ProcessInfo.processInfo.environment["NTP_CHANGESET_SEED"].flatMap(UInt64.init), only != seed { return }
        let steps = Int(ProcessInfo.processInfo.environment["NTP_CHANGESET_STEPS"] ?? "") ?? 60
        let run = try await Self.run(seed: seed, steps: steps)
        #expect(run.problems.isEmpty, "\(run.problems.prefix(6).joined(separator: "\n"))")
        if !run.stagingFindings.isEmpty {
            print("CHANGESET seed \(seed): STAGING FINDING (\(run.stagingFindings.count)) \(run.stagingFindings.prefix(2).joined(separator: "; "))")
            withKnownIssue("a shadow publication shows a new podcast's row before staging it, without its metadata") {
                Issue.record(Comment(rawValue: run.stagingFindings.joined(separator: "; ")))
            }
        }
        for observation in run.observations { print("CHANGESET-PENDING seed \(seed) \(observation.prefix(400))") }
        print("CHANGESET seed \(seed): reference \(run.reference.compared) registers compared, \(run.reference.undecided) undecided, \(run.reference.downloadsCompared) downloads compared")
        print("CHANGESET seed \(seed): \(run.steps) steps, \(run.observations.count) pending-state rebuild differences, known status gaps \(Self.knownStatusGaps.withLock { $0 }), superseded own claims \(Self.knownCompletionGaps.withLock { $0 }), pending registrations \(Self.knownRegistrationGaps.withLock { $0 }), downloaded sizes \(Self.knownDownloadSizes.withLock { $0 }), semantic checks \(run.semanticChecks), coverage \(run.coverage.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        // Coverage: every relation and the engine's told sets were exercised (the rarer ones over all seeds).
        for relation in ["feed", "episode", "statistics", "queue"] {
            #expect((run.coverage["relation \(relation)"] ?? 0) > 0, "relation \(relation) never changed")
        }
        let total = Self.totalCoverage.withLock { total in
            for (key, count) in run.coverage { total[key, default: 0] += count }
            total["seeds", default: 0] += 1
            return total
        }
        if total["seeds"] == Self.seeds.count {
            // The coverage manifest: every relation, operation family and engine path was reached across the seeds.
            for relation in ["download", "undo"] { #expect((total["relation \(relation)"] ?? 0) > 0, "relation \(relation) never changed in any seed") }
            for op in Op.allCases where op != .relaunch { #expect((total[op.rawValue] ?? 0) > 0, "operation \(op.rawValue) never applied") }
            // (Staging, shown ahead and hidden removal are reached by the mandatory prefix's large podcast and rename.)
            for path in ["path direct unit", "path shadow publication", "path full publication"] {
                #expect((total[path] ?? 0) > 0, "\(path) never reached")
            }
            // The generator families and every named crash point, each counted only where it was observed: the import
            // published and adopted, a GUID change served and fetched, a crash that happened at its point.
            for family in ["family import", "family guid change", "family restore recovery", "family failed finish", "family receipt replacement", "reference",
                           "path staging", "path shown ahead", "shown ahead checked", "path hidden removal"]
                + ServerExchangeCrashTests.points.map({ "crash \($0)" }) {
                #expect((total[family] ?? 0) > 0, "\(family) never reached")
            }
            print("CHANGESET coverage manifest: \(total.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        }
        #expect((run.coverage["told"] ?? 0) > 0 && (run.coverage["rebuild"] ?? 0) > 0)
    }
}

/// The semantic oracle's independent truth: the Go server's read API (PROTOCOL §12) through a web session of the
/// account. At a quiescent point every phone's synced fields (play state, favorite, position, last played, history, queue
/// membership and order, subscription state) must equal the server's views, except what the protocol keeps on the
/// device (a paused, never-played position; the player's own episode while a session is open).
final class ServerReadOracle: @unchecked Sendable {
    let base: URL
    private var cookie: String?

    init(_ server: ExchangeServer) async throws {
        base = server.base
        _ = try await send("POST", "v1/auth/web", ["username": "alice", "password": "alice-password-1"])
        _ = try await send("POST", "v1/installations", ["install_id": .string(ContractIdentity.randomUUID()),
            "instance_nonce": .string(ContractIdentity.randomUUID()), "name": "Reference", "app_version": "1.0", "capabilities": ["queue"]])
    }

    @discardableResult func send(_ method: String, _ path: String, _ body: ContractJSON? = nil) async throws -> ContractJSON {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue(base.absoluteString, forHTTPHeaderField: "Origin")
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try body.canonicalData()
        }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let http = response as? HTTPURLResponse
        if let set = http?.value(forHTTPHeaderField: "Set-Cookie"), let pair = set.split(separator: ";").first { cookie = String(pair) }
        guard (200..<300).contains(http?.statusCode ?? 0) else { throw HarnessError.http(http?.statusCode ?? 0, String(decoding: data, as: UTF8.self)) }
        return try ContractJSON.decode(data)
    }

    /// Every item of a paged list view.
    func list(_ path: String) async throws -> [ContractJSON] {
        var items: [ContractJSON] = []
        var token: String?
        repeat {
            let page = try await send("GET", path + (token.map { "?page_token=\($0)" } ?? ""))
            items += page["items"]?.arrayValue ?? []
            token = page["next_page_token"]?.stringValue
        } while token != nil
        return items
    }

    /// The differences between a phone and the server's read API at a quiescent point: the podcasts (subscribed and
    /// archived) and their episodes in both directions, every episode's canonical fields (play state, favorite, position,
    /// last played, history, played time, duration, size, title, publication date, statistics units), the subscription
    /// states and the queue's order. Set aside only: a position the reference holds as this phone's own (`devicePositions`,
    /// the exact value), a duration the player measured (`deviceDurations`, the exact value), and, for `excluded` episodes
    /// (the player's own while a session may hold unexported listening), positions, listening times, played time and
    /// duration; detail fields equal to this phone's own saved parse of a feed it registered; a size equal to a
    /// download this phone finished. A device position the server now shows too is resolved (removed).
    func differences(_ phone: ExchangePhone, devicePositions: inout [String: Int32], excluded: Set<String>) async throws -> [String] {
        var durations: [String: Int32] = [:]
        return try await differences(phone, devicePositions: &devicePositions, deviceDurations: &durations, excluded: excluded)
    }

    func differences(_ phone: ExchangePhone, devicePositions: inout [String: Int32], deviceDurations: inout [String: Int32],
                     excluded: Set<String>) async throws -> [String] {
        var found: [String] = []
        let path = try await phone.store.databaseForTesting { $0.fileURL?.path } ?? phone.location.database.path
        let parses = OwnParses.parses(of: path), downloads = OwnParses.downloadedSizes(of: path)
        // The phone's podcasts and episodes, as its screens show them.
        let hidden = Set(try phone.rows("SELECT feed_id FROM ntp_hidden_feeds UNION SELECT feed_id FROM pinned_feed_removals").compactMap { $0[0].flatMap(Int64.init) })
        let pending = Set(try phone.rows("SELECT feed_id FROM ntp_registrations WHERE state = 'pending' AND feed_id IS NOT NULL").compactMap { $0[0].flatMap(Int64.init) })
        let registered = Set(try phone.rows("SELECT DISTINCT feed_id FROM ntp_registrations WHERE feed_id IS NOT NULL").compactMap { $0[0].flatMap(Int64.init) })
        var podcastOf: [Int64: String] = [:], local: [String: (feed: Int64, state: String, source: String, record: NSDictionary)] = [:]
        for row in try phone.rows("SELECT p.podcast_id, p.feed_id, CAST(f.record AS TEXT) FROM ntp_podcasts p JOIN feeds f ON f.id = p.feed_id WHERE p.pinned_removal = 0") {
            guard let podcast = row[0], let feed = row[1].flatMap(Int64.init), !hidden.contains(feed), !pending.contains(feed) else { continue }
            let record = OwnParses.json(row[2])
            let state = switch (record["subscriptionState"] as? NSNumber)?.intValue ?? 0 { case 0: "subscribed"; case 2: "archived"; default: "not_subscribed" }
            podcastOf[feed] = podcast
            local[podcast] = (feed, state, OwnParses.address(record["source"] as? String ?? ""), record)
        }
        var episodes: [String: (feed: Int64, record: NSDictionary, pubdate: Int64)] = [:]
        for row in try phone.rows("SELECT n.episode_id, e.feed_id, CAST(e.record AS TEXT), e.pubdate FROM episodes e JOIN ntp_episodes n ON n.local_id = e.id WHERE e.id NOT IN (SELECT episode_id FROM ntp_hidden_episodes)") {
            guard let wire = row[0], let feed = row[1].flatMap(Int64.init), podcastOf[feed] != nil else { continue }
            episodes[wire] = (feed, OwnParses.json(row[2]), row[3].flatMap(Int64.init) ?? 0)
        }
        var units: [String: Set<String>] = [:], unitRecords: [String: [String: String]] = [:]
        for row in try phone.rows("SELECT episode_id, unit_id, CAST(record AS TEXT) FROM ntp_statistics_units") {
            if let wire = row[0], let unit = row[1] { units[wire, default: []].insert(unit); unitRecords[wire, default: [:]][unit] = row[2] ?? "" }
        }
        // The library's own statistics rows (what its statistics screens read), by local episode.
        var libraryUnits: [Int64: [String: [Int64?]]] = [:]
        for row in try phone.rows("SELECT episode_id, unit_id, played_ms, last_played, history, duration_ms, played, position FROM statistics_units") {
            guard let episode = row[0].flatMap(Int64.init), let unit = row[1] else { continue }
            libraryUnits[episode, default: [:]][unit] = row[2...].map { $0.flatMap(Int64.init) }
        }
        /// Text values as a person reads them: nil, null and empty are the same (no value).
        func text(_ value: Any?) -> String? {
            switch value {
            case let string as String: string.isEmpty ? nil : string
            case let number as NSNumber: number.stringValue
            default: nil
            }
        }
        // The server's podcasts, subscribed and archived, and their episodes.
        var remote: [String: String] = [:]
        for state in ["subscribed", "archived"] {
            for item in try await list("v1/read/subscriptions?state=\(state)") { if let id = item["podcast_id"]?.stringValue { remote[id] = state } }
        }
        for (podcast, state) in remote.sorted(by: { $0.key < $1.key }) where local[podcast] == nil {
            found.append("\(phone.name) lacks the server's \(state) podcast \(podcast.prefix(10))")
        }
        for (podcast, mine) in local.sorted(by: { $0.key < $1.key }) where mine.state != "not_subscribed" {
            guard let theirs = remote[podcast] else { found.append("\(phone.name) shows podcast \(podcast.prefix(10)) the server does not"); continue }
            if theirs != mine.state { found.append("\(phone.name) podcast \(podcast.prefix(10)) \(mine.state) vs \(theirs)") }
            // Every metadata field of the podcast's canonical record; a feed this phone registered may show its own parse
            // until that record next changes.
            let metadata = try await send("GET", "v1/read/podcasts/\(podcast)")["podcast"]?["records"]?["metadata"]?["value"]
            if let metadata, metadata != .null {
                let shown = mine.record["metadata"] as? NSDictionary ?? [:]
                let parse = registered.contains(mine.feed) && !OwnParses.supersededKeys(address: mine.source, library: path).contains("podcast")
                    ? parses[mine.source]?.feed["metadata"] as? NSDictionary : nil
                for (field, key) in [("title", "title"), ("description", "description"), ("author", "author"), ("language", "language"),
                                     ("link", "link"), ("imageURL", "image_url")] {
                    let value = text(shown[field])
                    guard value != metadata[key]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) else { continue }
                    if let parse, value == text(parse[field]) { continue }
                    found.append("\(phone.name) podcast \(podcast.prefix(10)) \(field) \(String(describing: value)) vs \(String(describing: metadata[key]?.stringValue))")
                }
                let funding = (shown["funding"] as? [NSDictionary] ?? []).map { "\(text($0["url"]) ?? "")|\(text($0["content"]) ?? "")" }
                let theirs = (metadata["funding"]?.arrayValue ?? []).map { "\($0["url"]?.stringValue ?? "")|\($0["content"]?.stringValue ?? "")" }
                if funding != theirs, parse.map({ ($0["funding"] as? [NSDictionary] ?? []).map { "\(text($0["url"]) ?? "")|\(text($0["content"]) ?? "")" } }) != funding {
                    found.append("\(phone.name) podcast \(podcast.prefix(10)) funding \(funding) vs \(theirs)")
                }
            }
            let serverEpisodes = Set(try await list("v1/read/podcasts/\(podcast)/episodes").compactMap { $0["episode_id"]?.stringValue })
            let phoneEpisodes = Set(episodes.filter { $0.value.feed == mine.feed }.keys)
            for wire in serverEpisodes.subtracting(phoneEpisodes).sorted() { found.append("\(phone.name) lacks the server's episode \(wire.prefix(10))") }
            for wire in phoneEpisodes.subtracting(serverEpisodes).sorted() { found.append("\(phone.name) shows episode \(wire.prefix(10)) the server does not") }
        }
        func number(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
        for (wire, episode) in episodes.sorted(by: { $0.key < $1.key }) {
            guard let podcast = podcastOf[episode.feed], remote[podcast] != nil else { continue }
            let response: ContractJSON
            do { response = try await send("GET", "v1/read/episodes/\(wire)") } catch HarnessError.http(404, _) {
                found.append("\(phone.name) shows episode \(wire.prefix(10)) the server cannot read"); continue
            }
            let server = response["episode"] ?? .null
            let state = episode.record["userState"] as? NSDictionary ?? [:], details = episode.record["details"] as? NSDictionary ?? [:]
            let media = details["media"] as? NSDictionary ?? [:]
            let own = registered.contains(episode.feed) && !OwnParses.supersededKeys(address: local[podcast]?.source ?? "", library: path).contains(wire)
                ? (details["identifier"] as? String).flatMap { identifier in parses[local[podcast]?.source ?? ""]?.episodes[identifier]?["details"] as? NSDictionary }
                : nil
            let label = "\(phone.name) \(wire.prefix(10))"
            func check(_ name: String, _ mine: Int64?, _ theirs: Int64?, ownValue: Int64?? = nil, also: Int64? = nil) {
                guard (mine ?? 0) != (theirs ?? 0) else { return }
                if let ownValue, mine == ownValue { return }
                if let also, mine == also { return }
                found.append("\(label) \(name) \(String(describing: mine)) vs \(String(describing: theirs))")
            }
            let playState = number(state["playState"]) ?? 0
            let expected: Int64 = switch server["play_state"]?.stringValue { case "played": 1; case "new": -1; default: 0 }
            if playState != expected { found.append("\(label) play state \(playState) vs \(expected)") }
            if (state["isFavorite"] as? Bool ?? false) != (server["favorite"]?.boolValue ?? false) { found.append("\(label) favorite") }
            let records = server["records"]
            // A feed size of 0 is unknown: the last known size stays, as Android's update keeps it (only a known size
            // replaces it), so only a known canonical size is compared.
            if let size = server["size"]?.integerValue, size > 0 {
                check("size", number(media["size"]), size, ownValue: own.map { number(($0["media"] as? NSDictionary)?["size"]) },
                      also: downloads[Int64(truncating: episode.record["id"] as? NSNumber ?? 0)])
            }
            if (details["title"] as? String) != server["title"]?.stringValue, own == nil || (details["title"] as? String) != (own?["title"] as? String) {
                let phoneRecord = OwnParses.json(try phone.rows("SELECT CAST(value AS TEXT) FROM ntp_records WHERE entity = 'episode' AND id = '\(wire)' AND field_group = 'metadata'").first?.first ?? nil)
                found.append("\(label) title \(String(describing: details["title"])) vs \(String(describing: server["title"]?.stringValue)) (phone record \(String(describing: phoneRecord["title"])) \(String(describing: phoneRecord["revision"])), server record \(records?["metadata"]?["value"]?["title"]?.canonicalText ?? "-") \(records?["metadata"]?["value"]?["revision"]?.canonicalText ?? "-"), own parse \(own != nil), server head \(response["head"]?["seq"]?.canonicalText ?? "-"), phone cursor \(try phone.rows("SELECT cursor FROM ntp_library WHERE id = 1").first?.first.flatMap { $0 }.flatMap { try? SyncCursor(encoded: $0) }.map { "\($0.seq)" } ?? "-"), podcast \(podcast.prefix(10)))")
            }
            check("publication date", episode.pubdate, server["pub_date"]?.integerValue,
                  ownValue: own.map { (($0["publicationDate"] as? NSNumber)?.doubleValue).map { Int64(Date(timeIntervalSinceReferenceDate: $0).timeIntervalSince1970 * 1_000) } })
            let serverUnitList = records?["statistics_units"]?["value"]?["units"]?.arrayValue ?? []
            let serverUnits = Set(serverUnitList.compactMap { $0["id"]?.stringValue })
            if serverUnits != units[wire] ?? [] { found.append("\(label) statistics units \(units[wire]?.count ?? 0) vs \(serverUnits.count)") }
            // Each unit's contents: the stored record, and the library's statistics row built from it.
            let localID = (episode.record["id"] as? NSNumber)?.int64Value ?? 0
            var wanted: [String: [Int64?]] = [:]
            for unit in serverUnitList {
                guard let id = unit["id"]?.stringValue else { continue }
                if let stored = unitRecords[wire]?[id], stored != String(decoding: try unit.canonicalData(), as: UTF8.self) {
                    found.append("\(label) statistics unit \(id.prefix(8)) record \(stored.prefix(120)) vs \(unit.canonicalText.prefix(120))")
                }
                wanted[id] = [unit["played_ms"]?.integerValue ?? 0, unit["last_played"]?.integerValue ?? 0, unit["history"]?.integerValue,
                              unit["duration_ms"]?.integerValue ?? 0, (unit["played"]?.boolValue ?? false) ? 1 : 0, unit["position"]?.integerValue ?? 0]
            }
            if (libraryUnits[localID] ?? [:]) != wanted {
                found.append("\(label) library statistics units \(libraryUnits[localID] ?? [:]) vs \(wanted)")
            }
            // Every metadata field of the episode's canonical record (the title, size and date are checked above); its own
            // parse while it supplies them.
            if let metadata = server["metadata"], metadata != .null {
                let transcript = details["transcript"] as? NSDictionary
                let fields: [(String, String?, String?, Any?)] = [
                    ("description", text(details["description"]), metadata["description"]?.stringValue, own?["description"]),
                    ("link", text(details["link"]), metadata["link"]?.stringValue, own?["link"]),
                    ("image", text(details["imageURL"]), metadata["image_url"]?.stringValue, own?["imageURL"]),
                    ("payment link", text(details["paymentLink"]), metadata["payment_link"]?.stringValue, own?["paymentLink"]),
                    ("chapter URL", text(details["chapterURL"]), metadata["chapter_url"]?.stringValue, own?["chapterURL"]),
                    ("social interaction", text(details["socialInteractionURL"]), metadata["social_interact_url"]?.stringValue, own?["socialInteractionURL"]),
                    ("transcript", text(transcript?["url"]), metadata["transcript_url"]?.stringValue, (own?["transcript"] as? NSDictionary)?["url"]),
                    ("media type", text(media["mimeType"]), metadata["media"]?["mime_type"]?.stringValue, (own?["media"] as? NSDictionary)?["mimeType"]),
                ]
                for (name, mine, theirs, ownValue) in fields where mine != theirs.flatMap({ $0.isEmpty ? nil : $0 }) {
                    // An unknown media type keeps the last known one, as an unknown size does (Android's update).
                    if name == "media type", theirs == nil { continue }
                    if own != nil, mine == text(ownValue) { continue }
                    found.append("\(label) \(name) \(String(describing: mine)) vs \(String(describing: theirs))")
                }
                let chapters = (details["chapters"] as? [NSDictionary] ?? []).map { "\(($0["startMilliseconds"] as? NSNumber)?.int64Value ?? 0)|\(text($0["title"]) ?? "")" }
                let serverChapters = (metadata["chapters"]?.arrayValue ?? []).map { chapter in
                    "\(chapter["start"]?.stringValue.flatMap { Int64($0) } ?? chapter["start"]?.integerValue ?? 0)|\(chapter["title"]?.stringValue ?? "")"
                }
                if chapters != serverChapters, own.map({ ($0["chapters"] as? [NSDictionary] ?? []).count }) != chapters.count {
                    found.append("\(label) chapters \(chapters.count) vs \(serverChapters.count)")
                }
            }
            guard !excluded.contains(wire) else { continue }
            check("played time", number(state["playedDurationMilliseconds"]), records?["played_time"]?["value"]?["played_ms"]?.integerValue)
            let measured = records?["measured_duration"] != nil
            let duration = number(media["durationMilliseconds"])
            if duration == server["duration_ms"]?.integerValue { deviceDurations[wire] = nil }
            check("duration", duration, server["duration_ms"]?.integerValue,
                  ownValue: measured ? nil : own.map { number(($0["media"] as? NSDictionary)?["durationMilliseconds"]) },
                  also: deviceDurations[wire].map(Int64.init))
            let position = number(state["positionMilliseconds"]) ?? 0, theirs = server["position"]?.integerValue ?? 0
            if position == theirs { devicePositions[wire] = nil }
            else if devicePositions[wire].map(Int64.init) != position { found.append("\(label) position \(position) vs \(theirs)") }
            check("last played", number(state["lastPlayedTimeMilliseconds"]), server["last_played"]?.integerValue)
            check("history", number(state["lastPlayedHistoryMilliseconds"]), server["history"]?.integerValue)
        }
        let queue = try await list("v1/read/queue").compactMap { $0["episode_id"]?.stringValue }
        let view = try await phone.view()
        if queue != view.queue { found.append("\(phone.name) queue \(view.queue.map { $0.prefix(8) }) vs \(queue.map { $0.prefix(8) })") }
        return found
    }
}

/// This phone's own saved parses and local facts, the reference the named rebuild exceptions validate against: the
/// rows each phone stored when it subscribed (by its library file and the feed's address), and the sizes of the files
/// its downloads finished with (by episode).
enum OwnParses {
    struct Image: @unchecked Sendable {
        var title: String?
        var feed: NSDictionary
        /// Each episode's stored record, by its identifier.
        var episodes: [String: NSDictionary]
    }

    private static let registry = Mutex<[String: [String: Image]]>([:])
    private static let downloads = Mutex<[String: [Int64: Int64]]>([:])
    /// Per library and parse: the first canonical metadata record seen after the parse (the podcast's, and each
    /// episode's by wire), and the records seen to change since. A parse supplies a record's fields only until the
    /// canonical record next changes (PROTOCOL §6.8); from then on the canonical projection shows it.
    private static let canonical = Mutex<[String: [String: (first: [String: String], superseded: Set<String>)]]>([:])

    static func address(_ url: String) -> String { ContractURL.normalize(ContractURL.stripUserinfo(url)) }

    static func note(_ image: Image, address: String, library path: String) {
        registry.withLock { $0[path, default: [:]][address] = image }
        canonical.withLock { $0[path, default: [:]][address] = ([:], []) }
    }

    /// The keys of a parse whose canonical record was seen to change (the parse no longer supplies them).
    static func supersededKeys(address: String, library path: String) -> Set<String> {
        canonical.withLock { $0[path]?[address]?.superseded ?? [] }
    }

    /// Takes in the canonical metadata records a library holds now for a parse's podcast ("podcast") and episodes (their
    /// wires); returns the keys whose record changed since the first one seen: the parse no longer supplies them.
    static func superseded(_ records: [String: String], address: String, library path: String) -> Set<String> {
        canonical.withLock { all in
            var state = all[path]?[address] ?? ([:], [])
            for (key, value) in records {
                if let first = state.first[key] { if first != value { state.superseded.insert(key) } } else { state.first[key] = value }
            }
            all[path, default: [:]][address] = state
            return state.superseded
        }
    }

    static func parses(of path: String) -> [String: Image] { registry.withLock { $0[path] ?? [:] } }

    static func noteDownload(size: Int64, episode: Int64, library path: String) {
        downloads.withLock { $0[path, default: [:]][episode] = size }
    }

    static func downloadedSizes(of path: String) -> [Int64: Int64] { downloads.withLock { $0[path] ?? [:] } }

    static func json(_ text: String?) -> NSDictionary {
        (text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? NSDictionary) ?? [:]
    }
}

extension FeedLibraryStore {
    /// Subscribes with `fetched` as the person does, and keeps the rows this phone stored from its own parse.
    func subscribeForTesting(_ fetched: FetchedFeed) throws -> LibraryFeed {
        let feed = try insert(fetched)
        if let path = database.fileURL?.path {
            let header = try database.rows("SELECT title, CAST(record AS TEXT) FROM feeds WHERE id = ?", [.integer(feed.id)]).first
            var episodes: [String: NSDictionary] = [:]
            for row in try database.rows("SELECT CAST(record AS TEXT) FROM episodes WHERE feed_id = ?", [.integer(feed.id)]) {
                let record = OwnParses.json(row[0].text)
                if let identifier = (record["details"] as? NSDictionary)?["identifier"] as? String { episodes[identifier] = record }
            }
            OwnParses.note(.init(title: header?[0].text, feed: OwnParses.json(header?[1].text), episodes: episodes),
                           address: OwnParses.address(fetched.source), library: path)
        }
        return feed
    }

    /// A finished download's file size, noted as this phone's own fact.
    func noteDownloadedSizeForTesting(episode: Int64) throws {
        guard let path = database.fileURL?.path, let size = try loadEpisode(episode)?.details.media?.size else { return }
        OwnParses.noteDownload(size: size, episode: episode, library: path)
    }
}
