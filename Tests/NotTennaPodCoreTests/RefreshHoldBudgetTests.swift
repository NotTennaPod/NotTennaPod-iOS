import Foundation
import Testing
@testable import NotTennaPodCore

/// What a refresh does while it holds the store: records decoded, statements, VM steps and pages
/// inside its write transaction, for feeds of 1,300 and 4,234 items, in a server and a standalone library, refreshed
/// for the first time after the subscription (its first observation), unchanged, and with one new item. The counters are
/// the gates. Two times are printed as samples, never as bounds (a Debug build on a shared Mac): how long the awaited
/// `applyRefresh` call took (the actor hop and queueing included, not the write lock's hold alone), and the longest
/// playback save among those whose own call overlapped the refresh call on a copy of the library.
@Suite(.serialized)
struct RefreshHoldBudgetTests {
    struct Measured: CustomStringConvertible {
        var label: String, work: StoreWork, awaited: Duration
        /// Of `work.recordsDecoded`, the episode records.
        var episodes = 0
        /// Saves whose call overlapped the refresh call, and the longest of them (nil: none overlapped).
        var overlapping: Int, longestOverlapping: Duration?
        var description: String {
            "\(label): \(work), \(episodes) episodes decoded; refresh call awaited \(RefreshHoldBudgetTests.ms(awaited)); "
                + (longestOverlapping.map { "\(overlapping) playback saves overlapped it, the longest \(RefreshHoldBudgetTests.ms($0))" }
                   ?? "no playback save overlapped it")
        }
    }

    /// Playback saves every 5 ms on `episode` around `refresh`, which starts only once a save has completed: each save's
    /// call interval, and the refresh call's.
    static func savesAround(_ store: FeedLibraryStore, episode: Int64, _ refresh: () async throws -> Void) async throws
        -> (overlapping: Int, longest: Duration?) {
        let session = try await store.beginPlayback(episodeID: episode)
        let stop = PlayingFlag(), first = PlayingFlag()
        let clock = ContinuousClock()
        let saver = Task { () -> [(ContinuousClock.Instant, ContinuousClock.Instant)] in
            var intervals: [(ContinuousClock.Instant, ContinuousClock.Instant)] = [], position: Int32 = 0
            while !stop.value {
                position += 5_000
                let started = clock.now
                _ = try? await store.recordPlayback(sessionID: session.id, sample: PlaybackSample(positionMilliseconds: position,
                    durationMilliseconds: 3_600_000, status: .playing))
                intervals.append((started, clock.now))
                first.value = true
                try? await Task.sleep(for: .milliseconds(5))
            }
            return intervals
        }
        while !first.value { await Task.yield() }
        let started = clock.now
        try await refresh()
        let ended = clock.now
        stop.value = true
        let overlapping = await saver.value.filter { $0.0 < ended && $0.1 > started }
        return (overlapping.count, overlapping.map { $0.0.duration(to: $0.1) }.max())
    }

    static func ms(_ duration: Duration) -> String { String(format: "%.1f ms", FeedLibraryStore.milliseconds(duration)) }

    /// One refresh of `fetched`, its work counted alone (its observations drained afterwards), then again on a copy of the
    /// library made before it, with playback saving every 5 ms around it, for the sampled times. `cold`: counted instead on
    /// a copy opened afresh (nothing decoded before it, as after a relaunch); the library itself is not refreshed.
    static func refresh(_ fixture: ServerLibraryFixture, _ fetched: FetchedFeed, feedID: Int64, day: Double, label: String,
                        playing: Int64, cold: Bool = false) async throws -> Measured {
        var source = fetched
        if await fixture.store.serverContext != nil { source.catalog = ServerCatalogRecords.interim(source.feed) }
        let options = FeedRefreshOptions(now: ServerLibraryFixture.now.addingTimeInterval(day * 86_400))
        // A copy of the library as it is now, refreshed again below with playback saves alongside, for the times.
        let copy = try await fixture.copy()
        defer { Task { await copy.close() } }
        let counted = cold ? try await fixture.copy() : fixture
        defer { if cold { Task { await counted.close() } } }
        let before = await counted.store.work, episodes = await counted.store.episodeRecordsDecoded
        let clock = ContinuousClock(), started = clock.now
        let result = try await counted.store.applyRefresh(source, feedID: feedID, options: options)
        let awaited = started.duration(to: clock.now)
        let work = await counted.store.work - before
        let decoded = await counted.store.episodeRecordsDecoded - episodes
        // Its observations drain afterwards in bounded transactions of their own, as the refresh service runs them.
        if let catalog = source.catalog {
            try await FeedLibraryStore.drainObservations(counted.store, feedID: feedID, catalog: catalog, items: result.serverItems)
        }
        let saves = try await Self.savesAround(copy.store, episode: playing) {
            _ = try await copy.store.applyRefresh(source, feedID: feedID, options: options)
        }
        let measured = Measured(label: label, work: work, awaited: awaited, episodes: decoded, overlapping: saves.overlapping,
                                longestOverlapping: saves.longest)
        print("REFRESH_HOLD \(measured); load \(ProcessInfo.processInfo.loadAverageDescription)")
        return measured
    }

    static func sequence(count: Int, server: Bool) async throws -> [Measured] {
        let fixture = try await ServerLibraryFixture(server: server)
        defer { Task { await fixture.close() } }
        let feedID: Int64, playing: Int64
        let other = ServerLibraryFixture.fetched("https://example.test/other.xml", title: "Other")
        if server {
            let registered = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(count: count))
            feedID = registered.feed.id
            // The podcast's first canonical metadata has arrived: observations no longer wait for it (PROTOCOL §9.4).
            try await fixture.store.executeForTesting("INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('podcast', ?, 'metadata', ?, '[]')",
                                                      [.text(registered.podcast), .blob(try (["title": "Show"] as ContractJSON).canonicalData())])
            playing = try #require(try await fixture.subscribeRegistered(other).feed.episodes.first?.id)
        } else {
            feedID = try await fixture.store.insert(ServerLibraryFixture.fetched(count: count)).id
            playing = try #require(try await fixture.store.insert(other).episodes.first?.id)
        }
        let kind = server ? "server" : "standalone"
        return [
            try await refresh(fixture, ServerLibraryFixture.fetched(count: count), feedID: feedID, day: 30_000,
                              label: "\(kind) \(count) first refresh", playing: playing),
            try await refresh(fixture, ServerLibraryFixture.fetched(count: count), feedID: feedID, day: 30_001,
                              label: "\(kind) \(count) unchanged", playing: playing),
            try await refresh(fixture, ServerLibraryFixture.fetched(count: count), feedID: feedID, day: 30_001.5,
                              label: "\(kind) \(count) unchanged, reopened", playing: playing, cold: true),
            try await refresh(fixture, ServerLibraryFixture.fetched(count: count + 1), feedID: feedID, day: 30_002,
                              label: "\(kind) \(count) one new", playing: playing),
        ]
    }

    /// The gates. The refresh's own work, before the additions below: an unchanged server refresh of 4,234 items ran 28
    /// statements and 161,390 VM steps. Added since, and gated here: the change capture (14 statements a transaction,
    /// 16 with a queue or release change, and its triggers' steps), the held podcast's binding check (a statement a
    /// binding), the derived keys and counts (a header write's eligibility check; a new episode's key and counts rows),
    /// and the refresh memo (its keyed reads, the header read, the fixed-point check's read of the feed's local
    /// identities, its triggers on each observation the recorder notes), and the fact-size bound (the advertised bounds
    /// read once by a refresh that records facts). A standalone library's first refresh after subscribing proves the
    /// memo and later unchanged ones apply it; a server library's first refresh notes its observations, the unchanged
    /// one proves the memo, and the reopened one (a library opened afresh, nothing decoded) applies it.
    @Test(arguments: [1_300, 4_234], [true, false])
    func aRefreshHoldsTheStoreForWorkProportionalToWhatChanged(count: Int, server: Bool) async throws {
        let measured = try await Self.sequence(count: count, server: server)
        let (first, unchanged, reopened, oneNew) = (measured[0].work, measured[1].work, measured[2].work, measured[3].work)
        for entry in measured { #expect(entry.work.commits == 1, "\(entry)") }
        // An unchanged refresh of a library opened afresh applies the memo: no episode decoded.
        #expect(measured[2].episodes == 0, "\(measured[2])")
        if server {
            // The header (the memo check, and the capture's read of it) and on a merge the last log entry; a merge also
            // reads the feed's stored episodes (nothing decoded is kept between refreshes; a changed refresh of a feed
            // is proportional to that feed). The memo applied decodes none.
            #expect([first, unchanged, oneNew].allSatisfy { $0.recordsDecoded <= count + 3 } && reopened.recordsDecoded <= 2, "\(measured)")
            // The refresh's own 39, capture 14, binding check 1, memo 15, the fact-size bound read 1; an observation
            // list statement per 70 items.
            #expect(first.statements <= 70 + (count + 69) / 70, "\(measured[0])")
            // The refresh's own 137 a item, memo triggers on each noted observation (21), the identities read (10) and
            // the feed's episodes read (about 9); constants: capture, derived keys, memo.
            #expect(first.steps <= 180 * Int64(count) + 5_000, "\(measured[0])")
            // The refresh's own 28, capture 14, binding check 1, the memo's proof 14.
            #expect(unchanged.statements <= 57, "\(measured[1])")
            // The refresh's own 38 a item, the memo proof's identities read (10) and the feed's episodes read (about
            // 9); constants: capture, derived keys, binding check, memo.
            #expect(unchanged.steps <= 58 * Int64(count) + 4_400, "\(measured[1])")
            // The memo applied on a library opened afresh: keyed reads, the header write and the capture, and as the opening's
            // first write the memo's trigger check and the playback restart export; flat in the feed's size.
            #expect(reopened.statements <= 40 && reopened.steps <= 2_800, "\(measured[2])")
            // The refresh's own 69, capture with its queue and release statements 16, binding check twice 2, memo 13,
            // the fact-size bound read 1.
            #expect(oneNew.statements <= 101, "\(measured[3])")
            // The refresh's own 38 a item and the feed's episodes read (about 9); constants: capture, the key and
            // counts rows, binding checks, memo.
            #expect(oneNew.steps <= 48 * Int64(count) + 5_800, "\(measured[3])")
        } else {
            // The refresh's own 5, 6 and 11, capture 14 each, memo (its proof 7, applied 1, a merge 7): flat.
            #expect(first.statements <= 26 && unchanged.statements <= 21 && reopened.statements <= 21 && oneNew.statements <= 32, "\(measured)")
            // Flat: the refresh's own work, the capture's statements and triggers, the derived eligibility check (and a
            // new episode's key and counts rows), the memo's reads. A merge (the first refresh, one new) reads the
            // feed's stored episodes: about 7 steps each.
            #expect(first.steps <= 7 * Int64(count) + 1_450 && unchanged.steps <= 1_375 && reopened.steps <= 1_375
                    && oneNew.steps <= 7 * Int64(count) + 2_570, "\(measured)")
            // The header (the memo check); a merge with a new episode also reads the feed's last log entry.
            // A merge also decodes the feed's stored episodes (proportional to the changed feed only).
            #expect(first.recordsDecoded <= count + 2 && unchanged.recordsDecoded <= 1 && reopened.recordsDecoded <= 1
                    && oneNew.recordsDecoded <= count + 2,
                    "\(measured)")
        }
    }
}

extension ServerLibraryFixture {
    /// A copy of this library (`VACUUM INTO`: the same rows), opened as its own store, for a second run of the same step.
    func copy() async throws -> ServerLibraryFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ServerLibrary-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("library.sqlite")
        try await store.executeForTesting("VACUUM INTO '\(url.path)'")
        return try ServerLibraryFixture(directory: directory, url: url, identity: identity)
    }

    init(directory: URL, url: URL, identity: ServerLibraryIdentity) throws {
        self.directory = directory
        self.url = url
        self.identity = identity
        store = try FeedLibraryStore(url: url)
        _ = FeedAuthentication(store: store, vault: vault)
    }
}
