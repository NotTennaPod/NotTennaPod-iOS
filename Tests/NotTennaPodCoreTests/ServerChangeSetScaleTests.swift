import Foundation
import Testing
@testable import NotTennaPodCore

/// The change sets at power-user scale (`NTP_SCALE=1`): the deterministic 500-podcast, 50,000-episode Android library
/// (`LargeAndroidLibrary`), restored through the real restore, then a seeded sequence of the person's actions; the capture
/// oracle reads the whole visible model before and after every write transaction and must agree with every delivered set,
/// and the capture's own work per action stays bounded by what the action changed.
@Suite(.serialized) struct ServerChangeSetScaleTests {
    static let enabled = ProcessInfo.processInfo.environment["NTP_SCALE"] != nil

    @Test(.enabled(if: enabled)) func aLargeLibrarysTransactionsMatchTheOracle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChangeSetScale-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = directory.appendingPathComponent("Antennapod.db")
        let summary = try LargeAndroidLibrary.write(to: backup)
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let restoreStart = ContinuousClock.now
        let library = try AndroidDatabaseRestore.read(backup, staging: directory.appendingPathComponent("staging"))
        try await store.installRestoredLibrary(library, carrying: try await store.restoreCarryOver())
        print("SCALE restore of \(summary.episodes.count) episodes in \(summary.feedIDs.count) podcasts: \(ContinuousClock.now - restoreStart)")
        let oracle = ChangeSetOracle()
        await store.installChangeOracleForTesting(oracle)
        let log = await store.recordCommitsForTesting()
        var random = ServerChangeSetCaptureTests.Random(state: 0x5CA1E)
        let feeds = try await store.feeds()
        let episodes = feeds.flatMap { $0.episodes.map(\.id) }
        #expect(episodes.count >= 45_000, "power-user scale: \(episodes.count) episodes")
        var swipe: EpisodeMarkReceipt?, history: EpisodeHistoryRemovalReceipt?
        let player = StorePlayer(store)
        var worst: [String: ServerChangeSetBudgetTests.Work] = [:]
        var problems: [String] = []
        let steps = Int(ProcessInfo.processInfo.environment["NTP_CHANGESET_STEPS"] ?? "") ?? 150
        let started = ContinuousClock.now
        for step in 0..<steps {
            let episode = random.pick(episodes)!
            let kinds = ["played", "unplayed", "favorite", "enqueue", "move", "dequeue", "sort", "swipe", "undo", "inbox", "historyRemove",
                         "historyUndo", "download", "cancel", "listen", "end", "archive", "keepUpdated", "refresh"]
            let kind = step < kinds.count ? kinds[step] : random.pick(kinds)!
            let queueLength = try await store.queue().count
            let before = await store.workForTesting()
            switch kind {
            case "played": try await store.markEpisodePlayed(episodeID: episode, played: true)
            case "unplayed": try await store.markEpisodePlayed(episodeID: episode, played: false)
            case "favorite": try await store.setFavorite(episodeID: episode, favorite: random.chance(50))
            case "enqueue": _ = try await store.enqueue([episode], location: random.chance(50) ? .back : .front)
            case "move":
                let queue = try await store.queue()
                if queue.count > 1, let item = random.pick(queue) {
                    _ = try await store.performQueueMove(.item(item.id, finalIndex: random.below(queue.count)), expected: queue.map(QueueEpisodeIdentity.init))
                }
            case "dequeue": if let item = random.pick(try await store.queue()) { _ = try await store.removeFromQueue([item.id]) }
            case "sort": _ = try await store.reorderQueue(random.pick(QueueSortOrder.allCases)!)
            case "swipe": swipe = try await store.applySwipeMark(episodeID: episode, action: .togglePlayed)
            case "undo": if let receipt = swipe { swipe = nil; _ = try await store.undoSwipeMark(receipt) }
            case "inbox": try await store.removeEpisodeFromInbox(episodeID: episode)
            case "historyRemove": history = try await store.removeFromPlaybackHistoryWithUndo(random.pick(summary.historyOrder) ?? episode)
            case "historyUndo": if let receipt = history { history = nil; _ = try await store.undoHistoryRemoval(receipt) }
            case "download": _ = try await store.requestDownload(episodeID: episode, directory: directory, enqueue: random.chance(50))
            case "cancel": if let job = random.pick(try await store.downloadJobs()) { _ = try await store.cancelDownload(id: job.id) }
            case "listen":
                if player.episodeID != episode { try await player.load(episode) }
                try await player.play(); try await player.listen(15); try await player.pause()
            case "end": if player.episodeID != nil { _ = try await player.end(.switched) }
            case "archive":
                if let feed = random.pick(feeds) { try await store.updatePreferences(feedID: feed.id) { $0.subscriptionState = $0.subscriptionState == .archived ? .subscribed : .archived } }
            case "keepUpdated": if let feed = random.pick(feeds) { try await store.updatePreferences(feedID: feed.id) { $0.keepUpdated.toggle() } }
            default:
                // A refresh of one podcast bringing one new episode.
                if let feed = random.pick(feeds) {
                    let fetched = ServerExchangeAgreementTests.fetched(feed.source, title: "Scale \(step)", prefix: "scale-new-\(step)", count: 1)
                    _ = try await store.applyRefresh(fetched, feedID: feed.id)
                }
            }
            let work = await store.workForTesting() - before
            if (worst[kind]?.captureRows ?? -1) < work.captureRows { worst[kind] = work }
            // Bounded by what the action changed: a few rows per key, plus the whole visible queue (twice: its order before
            // and after) when it wrote the queue (queue capture is proportional to the queue's length).
            if work.captureRows > 64 + 2 * Int64(queueLength + 1) || work.digests > 64 {
                problems.append("step \(step) \(kind) with a queue of \(queueLength): \(work)")
            }
            #expect(oracle.mismatches.isEmpty, "step \(step) \(kind): \(oracle.report)")
            if !oracle.mismatches.isEmpty { break }
        }
        let sets = log.sets
        print("SCALE \(steps) actions on \(episodes.count) episodes: \(oracle.transactions) transactions checked, \(oracle.visibleTransactions) visible, "
              + "\(sets.count) sets, largest \(sets.map(\.keyCount).max() ?? 0) keys, in \(ContinuousClock.now - started)")
        for (kind, work) in worst.sorted(by: { $0.key < $1.key }) {
            print("SCALE worst \(kind): capture \(work.captureRows) rows written, \(work.drainRows) read, \(work.digests) digest inputs")
        }
        #expect(problems.isEmpty, "\(problems.prefix(8).joined(separator: "\n"))")
        try await store.close()
    }
}
