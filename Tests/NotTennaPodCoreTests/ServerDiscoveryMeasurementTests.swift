import Foundation
import Testing
@testable import NotTennaPodCore

/// How long a server library's refresh holds the store (PROTOCOL §9 bounded units while audio plays): a
/// 20,000-episode feed observed for the first time (its refresh, then its observations in bounded transactions),
/// refreshed unchanged, and with one new episode, while another episode's playback is saved every 5 ms. Set
/// `NTP_DISCOVERY_MEASURE` to run (`NTP_DISCOVERY_MEASURE=2000` sets the feed's size); it prints the times and checks
/// nothing about them.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NTP_DISCOVERY_MEASURE"] != nil))
struct ServerDiscoveryMeasurementTests {
    /// The longest of a series of durations, from any task.
    final class Longest: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Duration.zero, total = Duration.zero, count = 0
        func note(_ duration: Duration) { lock.withLock { value = max(value, duration); total += duration; count += 1 } }
        var summary: (longest: Duration, total: Duration, count: Int) { lock.withLock { (value, total, count) } }
    }

    /// Playback saves every 5 ms on `episode` while `body` runs: the longest a save waited.
    static func savesDuring(_ store: FeedLibraryStore, episode: Int64, _ body: () async throws -> Void) async throws -> (longest: Duration, saves: Int) {
        let session = try await store.beginPlayback(episodeID: episode)
        let stop = PlayingFlag()
        let saver = Task { () -> (Duration, Int) in
            var longest = Duration.zero, count = 0, position: Int32 = 0
            let clock = ContinuousClock()
            while !stop.value {
                position += 5_000
                let started = clock.now
                _ = try? await store.recordPlayback(sessionID: session.id, sample: PlaybackSample(positionMilliseconds: position,
                    durationMilliseconds: 3_600_000, status: .playing))
                longest = max(longest, started.duration(to: clock.now))
                count += 1
                try? await Task.sleep(for: .milliseconds(5))
            }
            return (longest, count)
        }
        try await body()
        stop.value = true
        return await saver.value
    }

    static func ms(_ duration: Duration) -> String { String(format: "%.1f ms", FeedLibraryStore.milliseconds(duration)) }

    @Test func aLargeFeedsRefresh() async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let count = Int(ProcessInfo.processInfo.environment["NTP_DISCOVERY_MEASURE"] ?? "") ?? 20_000
        func feed(_ items: Int) -> FetchedFeed {
            ServerLibraryFixture.fetched(count: items)
        }
        let registered = try await fixture.subscribeRegistered(feed(count))
        try await fixture.store.executeForTesting("INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('podcast', ?, 'metadata', ?, '[]')",
                                                  [.text(registered.podcast), .blob(try (["title": "Show"] as ContractJSON).canonicalData())])
        // The episode playing meanwhile, in another podcast.
        let playing = try #require(try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/other.xml", title: "Other")).feed.episodes.first?.id)
        let clock = ContinuousClock()
        func measure(_ label: String, _ source: FetchedFeed, day: Double) async throws {
            // The record-level parse is made with the fetch, outside the store (the parity parse's, here the app's).
            var fetched = source
            let mapping = clock.now
            let catalog = ServerCatalogRecords.interim(fetched.feed)
            fetched.catalog = catalog
            print("NTP_DISCOVERY_MEASURE   its record-level parse, off the store: \(mapping.duration(to: clock.now))")
            var refresh = Duration.zero
            var refreshed: FeedRefreshResult?
            let drain = Longest()
            let started = clock.now
            let refreshSaves = try await Self.savesDuring(fixture.store, episode: playing) {
                refreshed = try await fixture.store.applyRefresh(fetched, feedID: registered.feed.id,
                                                                 options: .init(now: ServerLibraryFixture.now.addingTimeInterval(day * 86_400)))
                refresh = started.duration(to: clock.now)
            }
            let drainSaves = try await Self.savesDuring(fixture.store, episode: playing) {
                try await FeedLibraryStore.drainObservations(fixture.store, feedID: registered.feed.id, catalog: catalog,
                                                             items: refreshed?.serverItems ?? [:]) { drain.note($0) }
            }
            let elapsed = started.duration(to: clock.now)
            let transactions = drain.summary
            let listed = try fixture.rows("SELECT count(*) FROM ntp_observation_work WHERE feed_id = \(registered.feed.id)")[0][0] ?? "?"
            print("NTP_DISCOVERY_MEASURE \(label): \(elapsed) in all (outbox \(try fixture.outboxCount())); refresh transaction \(Self.ms(refresh)), "
                  + "\(refreshSaves.saves) playback saves meanwhile, longest wait \(Self.ms(refreshSaves.longest)); "
                  + "\(transactions.count) observation transactions, longest \(Self.ms(transactions.longest)), together \(Self.ms(transactions.total)), "
                  + "\(drainSaves.saves) playback saves meanwhile, longest wait \(Self.ms(drainSaves.longest)); listed after: \(listed); "
                  + "load \(ProcessInfo.processInfo.loadAverageDescription)")
        }
        try await measure("first observation of \(count)", feed(count), day: 30_000)
        try await measure("unchanged \(count)", feed(count), day: 30_001)
        try await measure("one new of \(count + 1)", feed(count + 1), day: 30_002)
        // The same in a standalone library, for comparison.
        let standalone = try await ServerLibraryFixture(server: false)
        defer { Task { await standalone.close() } }
        let inserted = try await standalone.store.insert(feed(count))
        let other = try #require(try await standalone.store.insert(ServerLibraryFixture.fetched("https://example.test/other.xml", title: "Other")).episodes.first?.id)
        for (label, items, day) in [("standalone unchanged", count, 30_001.0), ("standalone one new", count + 1, 30_002.0)] {
            let started = clock.now
            let saves = try await Self.savesDuring(standalone.store, episode: other) {
                _ = try await standalone.store.applyRefresh(feed(items), feedID: inserted.id,
                                                            options: .init(now: ServerLibraryFixture.now.addingTimeInterval(day * 86_400)))
            }
            print("NTP_DISCOVERY_MEASURE \(label) of \(items): \(started.duration(to: clock.now)); \(saves.saves) playback saves, longest wait \(Self.ms(saves.longest))")
        }
    }
}
