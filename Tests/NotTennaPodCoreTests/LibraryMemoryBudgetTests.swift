import Darwin
import Foundation
import Testing
@testable import NotTennaPodCore

/// Nothing library-sized and decoded stays resident: the store keeps no decoded episode between reads, the
/// screens' library holds list projections (no show notes, no chapters), statistics read projections, and an episode's
/// page reads its notes by key.
@Suite(.serialized)
struct LibraryMemoryBudgetTests {
    /// The decoded text an episode holds: its details' strings, its show notes and its chapters.
    static func textBytes(_ episode: LibraryEpisode) -> (notes: Int, rest: Int) {
        let details = episode.details
        let notes = (details.description?.utf8.count ?? 0)
            + (details.chapters ?? []).reduce(0) { $0 + ($1.title?.utf8.count ?? 0) + ($1.link?.utf8.count ?? 0) + ($1.imageURL?.utf8.count ?? 0) + 24 }
        let strings = [details.identifier, details.title, details.link, details.imageURL, details.paymentLink, details.chapterURL,
                       details.socialInteractionURL, details.transcript?.url, details.media?.url, details.media?.mimeType, episode.userState.localFileURL]
        return (notes, strings.reduce(0) { $0 + ($1?.utf8.count ?? 0) })
    }

    /// The process's physical footprint (what iOS counts against the app).
    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    /// No stored property of the store holds a decoded feed or episode (a whole-library cache restored).
    @Test func theStoreHoldsNoDecodedLibrary() async throws {
        let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await EpisodeListKeysTests.restoredLibrary(in: directory, episodes: 600, feeds: 8)
        let store = try FeedLibraryStore(url: url)
        _ = try await store.snapshot(); _ = try await store.screenSnapshot(); _ = try await store.statisticsLibrary()
        let first = try #require(try await store.feedHeaders().first)
        _ = try await store.applyRefresh(EpisodeListKeysTests.fetched(first.source, count: 3), feedID: first.id, options: .init(now: EpisodeListKeysTests.now))
        let held = Mirror(reflecting: store).children.compactMap { child -> String? in
            let type = String(reflecting: type(of: child.value))
            return type.contains("LibraryFeed") || type.contains("LibraryEpisode") || type.contains("FeedLibrarySnapshot") ? (child.label ?? type) : nil
        }
        #expect(held.isEmpty, "the store keeps decoded episodes in \(held)")
        // A whole-library read is decoded afresh each time: nothing kept from the previous one (a cache would decode none).
        let episodes = try await store.snapshot().feeds.reduce(0) { $0 + $1.episodes.count }
        let decoded = await store.episodeRecordsDecoded
        _ = try await store.snapshot()
        #expect(await store.episodeRecordsDecoded - decoded >= episodes, "the second read reused decoded episodes")
        try await store.close()
    }

    /// The screens' library holds no show notes or chapters, at its open and after patches; statistics read
    /// none; an episode's page reads them by key.
    @Test func theScreensLibraryHoldsNoShowNotes() async throws {
        let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await EpisodeListKeysTests.restoredLibrary(in: directory, episodes: 2_000, feeds: 40)
        let store = try FeedLibraryStore(url: url)
        let open = try await store.screenSnapshot()
        #expect(open.projected)
        var mirror = LibraryScreenMirror(open)
        func notes(_ feeds: [LibraryFeed]) -> Int { feeds.flatMap(\.episodes).reduce(0) { $0 + Self.textBytes($1).notes } }
        let full = try await store.snapshot()
        #expect(notes(full.feeds) > 100_000, "the library has show notes")
        #expect(notes(mirror.feeds) == 0 && mirror.queue.allSatisfy { Self.textBytes($0).notes == 0 })
        // The same episodes otherwise: each is its stored episode's projection.
        #expect(mirror.feeds.flatMap(\.episodes) == full.feeds.flatMap(\.episodes).map(\.listProjection))
        #expect(mirror.queue == full.queue.map(\.listProjection))
        // Patched: a changed episode and a podcast read whole again stay projections.
        let changed = try #require(full.feeds.flatMap(\.episodes).first)
        try await store.markEpisodePlayed(episodeID: changed.id, played: true)
        var request = LibraryMirrorRequest()
        request.episodes = [changed.id]; request.resetFeeds = [full.feeds[1].id]; request.feeds = [full.feeds[1].id]; request.queue = true
        mirror.apply(try await store.mirrorRead(request))
        #expect(notes(mirror.feeds) == 0)
        #expect(try await store.statisticsLibrary().feeds.flatMap(\.episodes).allSatisfy { Self.textBytes($0).notes == 0 })
        #expect(try await store.statisticsFeeds().flatMap(\.episodes).allSatisfy { Self.textBytes($0).notes == 0 })
        // The page's read by key has them.
        let detail = try await store.readers().detail
        #expect(try detail.episode(id: changed.id)?.details.description == (try await store.episode(id: changed.id))?.details.description)
        try await store.close()
    }

    /// What stays resident at power-user scale (`NTP_SCALE=1`): the screens' library's decoded text per episode (no show
    /// notes), its share of the whole records, and the process footprint the open adds, at 10,000, 54,000 and 100,000.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NTP_SCALE"] == "1"))
    func residentMemoryAtPowerUserScale() async throws {
        for (episodes, feeds) in [(10_000, 120), (54_000, 120), (100_000, 500)] {
            let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
            let url = try await EpisodeListKeysTests.restoredLibrary(in: directory, episodes: episodes, feeds: feeds)
            let store = try FeedLibraryStore(url: url)
            try await store.waitForDerivedData()
            // Live heap bytes (the allocator's in-use total): what stays allocated, without the reads' transient decoding
            // the footprint keeps as high water.
            func settled() -> Int64 {
                var statistics = malloc_statistics_t()
                malloc_zone_statistics(nil, &statistics)
                return Int64(statistics.size_in_use)
            }
            var base = settled()
            var mirror: LibraryScreenMirror? = LibraryScreenMirror(try await store.screenSnapshot())
            let projected = settled() - base
            let text = mirror!.feeds.flatMap(\.episodes).reduce((0, 0)) { let bytes = Self.textBytes($1); return ($0.0 + bytes.notes, $0.1 + bytes.rest) }
            mirror = nil
            // The same library held as whole records (what the screens and the store's cache would hold without
            // projections).
            base = settled()
            var whole: LibraryScreenMirror? = LibraryScreenMirror(LibraryScreenSnapshot(snapshot: try await store.snapshot()))
            let wholeFootprint = settled() - base
            let wholeText = whole!.feeds.flatMap(\.episodes).reduce((0, 0)) { let bytes = Self.textBytes($1); return ($0.0 + bytes.notes, $0.1 + bytes.rest) }
            whole = nil
            print("MEMORY \(episodes) episodes: screens' library \(projected / 1_048_576) MB live heap (\(projected / Int64(episodes)) B an episode), "
                  + "list text \(text.1 / 1_048_576) MB, show notes \(text.0); as whole records \(wholeFootprint / 1_048_576) MB "
                  + "(\(wholeFootprint / Int64(episodes)) B an episode), show notes \(wholeText.0 / 1_048_576) MB")
            #expect(text.0 == 0, "no show notes resident")
            // The projection keeps only list text: under a third of the whole records' text.
            #expect(text.1 * 3 < wholeText.0 + wholeText.1, "\(text) vs \(wholeText)")
            // What stays is the per-episode structure of the screens' library, now without show notes:
            // at most 60 % of the whole records it held before (measured: 11 / 82 / 152 MB against 25 / 157 / 291 MB at 10,000 /
            // 54,000 / 100,000 episodes), about 1.6 KB an episode.
            #expect(projected * 5 <= wholeFootprint * 3, "\(projected) vs \(wholeFootprint)")
            #expect(projected <= Int64(episodes) * 1_700, "\(projected) bytes for \(episodes) episodes")
            try await store.close()
        }
    }
}
