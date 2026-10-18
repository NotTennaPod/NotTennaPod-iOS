import Foundation
import Testing
@testable import NotTennaPodCore

/// Automatic download selects from keys: its candidates, cache count, cleanup order and settled releases equal
/// the frozen whole-library selection (`AutomaticDownloadReference` over `snapshot()`), and a pass reads no record but those
/// of the episodes it cleans.
@MainActor @Suite
struct AutomaticDownloadKeyedTests {
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// A random library: podcasts in every subscription state and download setting, with filters; episodes with and
    /// without media and dates (ties included), in every state; some queued.
    static func randomLibrary(_ store: FeedLibraryStore, seed: UInt64) async throws {
        var random = Generator(state: seed)
        let titles = ["Deep dive", "News", "ad break", "Interview", "", "Bonus deep dive"]
        for feedIndex in 0..<Int.random(in: 2...5, using: &random) {
            let local = Int.random(in: 0..<6, using: &random) == 0
            let source = local ? LibraryFeed.localSourcePrefix + "folder\(seed)-\(feedIndex)" : "https://example.org/\(seed)/\(feedIndex)"
            var items: [ParsedEpisode] = []
            for index in 0..<Int.random(in: 0...12, using: &random) {
                let date: Date? = switch Int.random(in: 0..<8, using: &random) {
                case 0: nil
                case 1: Date(timeIntervalSince1970: 1_600_000_000)
                default: Date(timeIntervalSince1970: 1_600_000_000 + Double(Int.random(in: 0..<500, using: &random)) * 3_600)
                }
                let media: ParsedMedia? = Int.random(in: 0..<6, using: &random) == 0 ? nil
                    : .init(url: "https://example.org/\(seed)/\(feedIndex)/\(index).mp3", size: 100,
                            durationMilliseconds: Int32([0, 30_000, 90_000, 3_600_000].randomElement(using: &random)!))
                items.append(.init(identifier: "\(seed)-\(feedIndex)-\(index)", title: titles.randomElement(using: &random),
                                   publicationDate: date, media: media))
            }
            var options = FeedRefreshOptions(now: now)
            options.isLocalFeed = local
            let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Podcast \(feedIndex)", episodes: items), source: source,
                                                    responseURL: URL(string: "https://example.org/feed")!, validator: nil),
                                              options: options)
            let state = [FeedSubscriptionState.subscribed, .subscribed, .archived, .notSubscribed].randomElement(using: &random)!
            let download = [FeedAutoDownload.enabled, .global, .disabled].randomElement(using: &random)!
            let filter = [AutomaticDownloadFilter(), .init(include: "deep"), .init(exclude: "ad"), .init(minimumDurationSeconds: 60)]
                .randomElement(using: &random)!
            try await store.updatePreferences(feedID: feed.id) {
                $0.subscriptionState = state; $0.autoDownload = download; $0.automaticDownloadFilter = filter
            }
            for episode in feed.episodes {
                let play = EpisodePlayState.allCases.randomElement(using: &random)!
                let downloaded = Int.random(in: 0..<3, using: &random) == 0
                let favorite = Int.random(in: 0..<5, using: &random) == 0
                let automatic = Int.random(in: 0..<6, using: &random) != 0
                let history: Int64? = [nil, 0, -5, 1_699_990_000_000, 1_699_000_000_000, 1_600_000_000_000].randomElement(using: &random)!
                try await store.updateEpisode(id: episode.id) {
                    $0.userState.playState = play; $0.userState.isDownloaded = downloaded; $0.userState.isFavorite = favorite
                    $0.userState.autoDownloadEnabled = automatic; $0.userState.lastPlayedHistoryMilliseconds = history
                    if downloaded { $0.userState.localFileURL = "/tmp/\(episode.id).mp3" }
                }
                if Int.random(in: 0..<4, using: &random) == 0, episode.details.media != nil { _ = try await store.enqueue([episode.id]) }
            }
        }
    }

    static func withStore(_ body: (FeedLibraryStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AutomaticDownloadKeyed-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        do { try await body(store); try await store.close() } catch { try? await store.close(); throw error }
    }

    /// 200 random libraries: every selection from keys equals the frozen whole-library one, under every preference that
    /// changes it, with and without releases.
    @Test func keyedSelectionEqualsTheFrozenReference() async throws {
        var compared = 0
        for seed in UInt64(1)...200 {
            try await Self.withStore { store in
                try await Self.randomLibrary(store, seed: seed)
                #expect(store.derivedReady)
                let snapshot = try await store.snapshot()
                let all = Set(snapshot.feeds.flatMap(\.episodes).map(\.id))
                var random = Generator(state: seed &* 31)
                let releases = Set(all.filter { _ in Bool.random(using: &random) })
                for release in [nil, releases] {
                    let library = try await store.automaticDownloadLibrary(releases: release)
                    for global in [false, true] {
                        for queue in [false, true] {
                            var preferences = AutomaticDownloadPreferences(); preferences.global = global; preferences.queue = queue
                            let expected = AutomaticDownloadReference.candidates(feeds: snapshot.feeds, queue: snapshot.queue,
                                                                                 preferences: preferences, releases: release).map(\.id)
                            let keyed = AutomaticDownloadPolicy.candidates(library, preferences: preferences, releases: release).map(\.id)
                            #expect(keyed == expected, "seed \(seed), global \(global), queue \(queue), releases \(release != nil)")
                            compared += 1
                        }
                    }
                    let downloaded = snapshot.feeds.lazy.filter { $0.subscriptionState == .subscribed }
                        .reduce(0) { $0 + $1.episodes.count { $0.details.media != nil && $0.userState.isDownloaded } }
                    #expect(AutomaticDownloadPolicy.downloadedCount(library) == downloaded, "seed \(seed)")
                    for policy in [-3, -2, -1, 0, 1, 24, 10_000] {
                        let expected = AutomaticDownloadReference.cleanupCandidates(feeds: snapshot.feeds, queuedIDs: Set(snapshot.queue.map(\.id)),
                                                                                    policy: policy, now: Self.now).map(\.id)
                        let keyed = AutomaticDownloadPolicy.cleanupCandidates(library, queuedIDs: Set(library.queue), policy: policy, now: Self.now).map(\.id)
                        #expect(keyed == expected, "seed \(seed), cleanup \(policy)")
                    }
                    if let release {
                        #expect(AutomaticDownloadPolicy.settledReleases(library, releases: release)
                                == AutomaticDownloadReference.settledReleases(feeds: snapshot.feeds, releases: release), "seed \(seed)")
                    }
                    // The keys read are only those a pass can act on.
                    let population = Set(snapshot.feeds.flatMap(\.episodes).filter {
                        release?.contains($0.id) ?? ($0.userState.playState == .new) || $0.userState.isDownloaded
                    }.map(\.id)).union(snapshot.queue.map(\.id))
                    #expect(Set(library.episodes.map(\.id)) == population, "seed \(seed)")
                }
            }
        }
        #expect(compared == 200 * 2 * 4)
    }

    /// A pass after a queue change reads no whole library and decodes only the episodes it cleans; the same pass before
    /// the derived keys are complete reads the library as before.
    @Test func aPassReadsKeysAndDecodesOnlyWhatItCleans() async throws {
        try await Self.withStore { store in
            var items: [ParsedEpisode] = []
            for index in 0..<40 {
                items.append(.init(identifier: "e\(index)", title: "Episode \(index)", publicationDate: Date(timeIntervalSince1970: 1_600_000_000 + Double(index) * 60),
                                   media: .init(url: "https://example.org/\(index).mp3", size: 100, durationMilliseconds: 60_000)))
            }
            let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Show", episodes: items), source: "https://example.org/show",
                                                    responseURL: URL(string: "https://example.org/show")!, validator: nil))
            try await store.updatePreferences(feedID: feed.id) { $0.autoDownload = .enabled }
            let ids = feed.episodes.map(\.id)
            // Three downloaded and played (the oldest), two NEW, the rest unplayed.
            for id in ids.suffix(3) {
                try await store.updateEpisode(id: id) {
                    $0.userState.isDownloaded = true; $0.userState.localFileURL = "/tmp/\(id).mp3"; $0.userState.playState = .played
                }
            }
            for id in ids.prefix(2) { try await store.updateEpisode(id: id) { $0.userState.playState = .new } }
            var preferences = AutomaticDownloadPreferences(); preferences.cacheSize = 3; preferences.cleanup = -1
            let selected = preferences
            var cleaned: [Int64] = [], downloaded: [Int64] = []
            let coordinator = AutomaticDownloadCoordinator(store: store, preferences: { selected },
                environment: { .init(connection: .wifi(metered: false), allowMobile: false, charging: true) },
                cleanup: { episode in
                    cleaned.append(episode.id)
                    try await store.updateEpisode(id: episode.id) { $0.userState.isDownloaded = false; $0.userState.localFileURL = nil }
                },
                download: { downloaded.append($0) })
            _ = try await store.enqueue([ids[10]])
            let reads = await store.snapshotReads, decoded = await store.episodeRecordsDecoded
            try await coordinator.run()
            #expect(await store.snapshotReads == reads)
            // Two cleaned for the two NEW: each read once to clean, again to count it as freed, and once by its own write.
            #expect(cleaned.count == 2)
            #expect(await store.episodeRecordsDecoded - decoded == 3 * cleaned.count)
            #expect(downloaded == Array(ids.prefix(2)))
        }
    }
}
