import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.timeLimit(.minutes(1)))
struct AutomaticDownloadTests {
    private func episode(_ id: Int64, new: Bool = true, downloaded: Bool = false, date: Double? = nil) -> LibraryEpisode {
        var item = LibraryEpisode(id: id, details: .init(identifier: String(id), title: "News \(id)",
            publicationDate: Date(timeIntervalSince1970: date ?? Double(id)),
            media: .init(url: "https://example.org/\(id).mp3", size: 100, durationMilliseconds: 60_000)))
        item.userState.playState = new ? .new : .unplayed
        item.userState.isDownloaded = downloaded
        return item
    }
    private func feed(_ id: Int64, episodes: [LibraryEpisode], state: FeedSubscriptionState = .subscribed) -> LibraryFeed {
        var feed = LibraryFeed(id: id, source: "https://example.org/\(id)", metadata: .init(format: .rss), episodes: episodes)
        feed.subscriptionState = state; return feed
    }
    @Test func filtersAndCapacityMatchExecutedOriginalJavaAndPreventItsNegativeSliceCrash() throws {
        struct Filter: Decodable { let include, exclude, title, locale: String; let duration: Int32?; let minimum: Int; let expected: Bool }
        struct Capacity: Decodable { let candidates, downloaded, active, deleted, cache: Int; let result: String }
        struct Fixture: Decodable { let filters: [Filter]; let capacities: [Capacity] }
        let url = try #require(Bundle.module.url(forResource: "automatic-download", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.filters.count == 624 && fixture.capacities.count == 94)
        for row in fixture.filters {
            var item = episode(1); item.details.title = row.title
            if let duration = row.duration { item.details.media?.durationMilliseconds = duration } else { item.details.media = nil }
            let actual = AutomaticDownloadFilter(include: row.include, exclude: row.exclude, minimumDurationSeconds: row.minimum)
                .includes(item, locale: Locale(identifier: row.locale))
            #expect(actual == row.expected, "\(row.include) / \(row.exclude) / \(row.title) / \(row.minimum) / \(row.locale)")
        }
        var prevented = 0
        for row in fixture.capacities {
            let count = AutomaticDownloadPolicy.downloadCount(candidates: row.candidates, downloaded: row.downloaded,
                active: row.active, deleted: row.deleted, cacheSize: row.cache)
            if row.result.hasPrefix("ok:") { #expect(count == Int(row.result.dropFirst(3))) }
            else {
                #expect(row.cache - (row.downloaded + row.active - row.deleted) < 0)
                #expect(count == 0); prevented += 1
            }
        }
        #expect(prevented == 42)
    }
    @Test func candidatesUseSubscribedNewestFirstThenUniqueQueueAndQueueBypassesFeedFilter() {
        var a = feed(1, episodes: [episode(1), episode(5), episode(3)])
        a.autoDownload = .enabled; a.automaticDownloadFilter = .init(include: "5")
        var b = feed(2, episodes: [episode(2), episode(6)], state: .archived); b.autoDownload = .enabled
        var c = feed(3, episodes: [episode(4)]); c.autoDownload = .disabled
        var prefs = AutomaticDownloadPreferences(); prefs.queue = true
        let queue = [a.episodes[0], b.episodes[0], a.episodes[1], c.episodes[0], a.episodes[0]]
        #expect(AutomaticDownloadPolicy.candidates(feeds: [a,b,c], queue: queue, preferences: prefs).map(\.id) == [5,1,2,4])
        prefs.queue = false
        #expect(AutomaticDownloadPolicy.candidates(feeds: [a,b,c], queue: queue, preferences: prefs).map(\.id) == [5])
        a.autoDownload = .global
        #expect(AutomaticDownloadPolicy.candidates(feeds: [a], queue: [], preferences: prefs).isEmpty)
        prefs.global = true
        #expect(AutomaticDownloadPolicy.candidates(feeds: [a], queue: [], preferences: prefs).map(\.id) == [5])
    }
    @Test func candidatesExcludeDisabledDownloadedMissingMediaAndLocalEpisodesAfterQueueMerge() {
        var items = (1...5).map { episode(Int64($0)) }
        items[0].userState.autoDownloadEnabled = false; items[1].userState.isDownloaded = true; items[2].details.media = nil
        let remote = feed(1, episodes: Array(items.prefix(4)))
        var local = feed(2, episodes: [items[4]]); local.source = "antennapod_local:folder"
        var prefs = AutomaticDownloadPreferences(); prefs.global = true; prefs.queue = true
        #expect(AutomaticDownloadPolicy.candidates(feeds: [remote, local], queue: items, preferences: prefs).map(\.id) == [4])
    }
    @Test func networkPowerAndDefaultsPreserveSeparateAutomaticAdmission() {
        let defaults = AutomaticDownloadPreferences()
        #expect(!defaults.global && !defaults.queue && defaults.onBattery && defaults.cacheSize == 20 && defaults.cleanup == -2)
        for charging in [false,true] { for battery in [false,true] { for mobile in [false,true] {
            var prefs = defaults; prefs.onBattery = battery
            for (connection, network) in [(AutomaticDownloadPolicy.Connection.unavailable,false),(.wifi(metered:true),false),
                (.wifi(metered:false),true),(.ethernet,true),(.other(restricted:true),mobile),(.other(restricted:false),true)] {
                #expect(AutomaticDownloadPolicy.permitted(connection: connection, allowMobile: mobile, charging: charging, preferences: prefs) == (network && (charging || battery)))
            }
        } } }
        let meteredWifi = DownloadNetworkMonitor.nativeState(status: .satisfied, isExpensive: true, usesCellular: false, usesWiFi: true)
        #expect(meteredWifi.automaticDownloadConnection == .wifi(metered: true))
        let wired = DownloadNetworkMonitor.nativeState(status: .satisfied, isExpensive: true, usesCellular: false, usesEthernet: true)
        #expect(wired.automaticDownloadConnection == .ethernet)
    }
    @Test func cleanupProtectsFavoritesQueueAndPlaybackAgeWithSourceOrdering() {
        let now = Date(timeIntervalSince1970: 100_000)
        var items = (1...6).map { episode(Int64($0), new: false, downloaded: true) }
        for i in items.indices { items[i].userState.playState = .played; items[i].userState.lastPlayedHistoryMilliseconds = Int64(90_000 + i * 1000) * 1000 }
        items[1].userState.isFavorite = true
        items[3].userState.playState = .unplayed
        items[4].userState.lastPlayedHistoryMilliseconds = nil
        items[5].userState.lastPlayedHistoryMilliseconds = 96_400_000 // exactly one hour, excluded
        let subscribed = feed(1, episodes: items), archived = feed(2, episodes: [episode(9, downloaded: true)], state: .archived)
        func ids(_ policy: Int) -> [Int64] { AutomaticDownloadPolicy.cleanupCandidates(feeds: [subscribed,archived], queuedIDs: [3], policy: policy, now: now).map(\.id) }
        #expect(ids(-2).isEmpty)
        #expect(ids(-3) == [1,3,4,5,6])
        #expect(ids(-1) == [1,4,5,6])
        #expect(ids(1) == [1])
        #expect(AutomaticDownloadPolicy.cleanupCount(downloaded: 8, candidates: 4, cacheSize: 10) == 2)
        #expect(AutomaticDownloadPolicy.cleanupCount(downloaded: 8, candidates: 4, cacheSize: -1) == 0)
    }
    private func storeFixture(_ body: (FeedLibraryStore, URL, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AutomaticDownload-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library.sqlite"), store = try FeedLibraryStore(url: file)
        do { try await body(store, file, root); try await store.close() } catch { try? await store.close(); throw error }
    }
    private func insert(_ store: FeedLibraryStore) async throws -> LibraryFeed {
        let metadata = ParsedFeed(format: .rss, title: "Show", episodes: (1...3).map { episode(Int64($0)).details })
        let result = try await store.insert(.init(feed: metadata, source: "https://example.org/feed", responseURL: URL(string: "https://example.org/feed")!, validator: nil, permanentRedirectURL: nil))
        try await store.updatePreferences(feedID: result.id) { $0.autoDownload = .enabled }
        for episode in result.episodes { try await store.updateEpisode(id: episode.id) { $0.userState.playState = .new } }
        return try #require(try await store.feed(id: result.id))
    }
    @Test func filterPersistencePreservesLegacyDefaultsAndGlobalPreferencesSurviveReopen() async throws {
        try await storeFixture { store, file, root in
            let feed = try await insert(store)
            let filter = AutomaticDownloadFilter(include: "\"deep dive\"", exclude: "ad", minimumDurationSeconds: 120)
            try await store.updatePreferences(feedID: feed.id) { $0.automaticDownloadFilter = filter }
            try await store.updatePreferences(feedID: feed.id) { $0.customTitle = "Renamed" }
            let reopened = try FeedLibraryStore(url: file)
            #expect(try await reopened.feed(id: feed.id)?.automaticDownloadFilter == filter)
            try await reopened.close()
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(feed)) as? [String:Any])
            json.removeValue(forKey: "automaticDownloadFilterValue")
            let legacy = try JSONDecoder().decode(LibraryFeed.self, from: JSONSerialization.data(withJSONObject: json))
            #expect(legacy.automaticDownloadFilter == .init())
            let prefsFile = root.appendingPathComponent("auto.json")
            let prefs = try AutomaticDownloadPreferenceStore(file: prefsFile)
            var value = prefs.value; value.global = true; value.cacheSize = -1
            try prefs.update(value)
            #expect(try AutomaticDownloadPreferenceStore(file: prefsFile).value == value)
            var invalid = value; invalid.cacheSize = -5
            #expect(throws: FeedLibraryError.self) { try prefs.update(invalid) }
            #expect(prefs.value == value)
        }
    }
    @Test func blockedAdmissionAndUnchangedCleanupDoNotStartDownloads() async throws {
        try await storeFixture { store, _, _ in
            let feed = try await insert(store)
            try await store.updateEpisode(id: feed.episodes[0].id) { $0.userState.isDownloaded = true }
            var prefs = AutomaticDownloadPreferences(); prefs.cacheSize = 1; prefs.cleanup = -1
            let selected = prefs
            var cleanupCalls = 0, downloadCalls = 0
            let blocked = AutomaticDownloadCoordinator(store: store, preferences: { selected },
                environment: { .init(connection: .wifi(metered: true), allowMobile: true, charging: true) },
                cleanup: { _ in cleanupCalls += 1 }, download: { _ in downloadCalls += 1 })
            try await blocked.run()
            #expect(cleanupCalls == 0 && downloadCalls == 0)
            let admitted = AutomaticDownloadCoordinator(store: store, preferences: { selected },
                environment: { .init(connection: .ethernet, allowMobile: false, charging: false) },
                cleanup: { _ in cleanupCalls += 1 }, download: { _ in downloadCalls += 1 })
            try await admitted.run()
            #expect(cleanupCalls == 1 && downloadCalls == 0) // Callback did not remove the file/state.
        }
    }
    /// With automatic download off everywhere and cleanup "never" (the defaults) a pass can neither
    /// select nor delete anything; it ends without walking the library, with the same result.
    @Test func passWithAutomaticDownloadOffAndNoCleanupChangesNothing() async throws {
        try await storeFixture { store, _, _ in
            let feed = try await insert(store)
            try await store.updateEpisode(id: feed.episodes[0].id) { $0.userState.isDownloaded = true }
            var prefs = AutomaticDownloadPreferences(); prefs.cacheSize = 0
            let selected = prefs
            var calls = 0
            let coordinator = AutomaticDownloadCoordinator(store: store, preferences: { selected },
                environment: { .init(connection: .ethernet, allowMobile: false, charging: true) },
                cleanup: { _ in calls += 1 }, download: { _ in calls += 1 })
            try await coordinator.run()
            #expect(calls == 0 && prefs.cleanup == -2 && !prefs.global && !prefs.queue)
            var enabled = prefs; enabled.global = true
            let all = enabled
            let selecting = AutomaticDownloadCoordinator(store: store, preferences: { all },
                environment: { .init(connection: .ethernet, allowMobile: false, charging: true) },
                cleanup: { _ in calls += 1 }, download: { _ in calls += 1 })
            try await selecting.run()
            #expect(calls == 0, "cache size 0 leaves no room; still nothing to clean with cleanup never")
        }
    }

    @Test func cancellationSerializesTriggersAndLaterRunRecovers() async throws {
        try await storeFixture { store, _, _ in
            _ = try await insert(store)
            var continuation: CheckedContinuation<Void,Never>?
            var admissions = 0, downloaded: [Int64] = []
            let coordinator = AutomaticDownloadCoordinator(store: store, preferences: { .init() }, environment: {
                admissions += 1
                if admissions == 1 { await withCheckedContinuation { continuation = $0 } }
                return .init(connection: .ethernet, allowMobile: false, charging: true)
            }, cleanup: { _ in Issue.record("No cleanup expected") }, download: { downloaded.append($0) })
            let first = Task { try await coordinator.run() }
            while continuation == nil { await Task.yield() }
            let second = Task { try await coordinator.run() }
            first.cancel()
            #expect(admissions == 1)
            continuation?.resume(); continuation = nil
            await #expect(throws: CancellationError.self) { try await first.value }
            try await second.value
            #expect(admissions == 2 && downloaded.count == 3)
        }
    }
    @Test func automaticJobAdmissionRechecksDisabledFlagAndLocalFeedBeforeQueueMutation() async throws {
        try await storeFixture { store, _, root in
            let feed = try await insert(store)
            let episode = feed.episodes[0]
            try await store.updateEpisode(id: episode.id) { $0.userState.autoDownloadEnabled = false }
            #expect(try await store.requestDownload(episodeID: episode.id, directory: root, automatic: true) == nil)
            #expect(try await store.queue().isEmpty)
            let local = try await store.registerLocalFolder(title: "Folder", directoryIdentity: "fixture:folder", bookmark: Data([1]))
            let scanned = try await store.applyLocalFolderScan(.init(format: .rss, episodes: [
                .init(identifier: "file", title: "file", link: "file.mp3", media: .init(url: "document:file", size: 100))
            ]), context: local)
            let localEpisode = try #require(scanned.feed.episodes.first)
            try await store.updateEpisode(id: localEpisode.id) { $0.userState.autoDownloadEnabled = true }
            #expect(try await store.requestDownload(episodeID: localEpisode.id, directory: root, automatic: true) == nil)
            #expect(try await store.queue().isEmpty)
            #expect(try await store.downloadJobs().isEmpty)
        }
    }

    @Test func coordinatorDeletesRealFileThenEnqueuesRealDownloadJobsWithoutManualPrompt() async throws {
        try await storeFixture { store, _, root in
            let feed = try await insert(store)
            let ordered = feed.episodes.sorted { $0.id < $1.id }
            let old = ordered[0]
            let media = root.appendingPathComponent("old.mp3"); try Data([1,2,3]).write(to: media)
            try await store.updateEpisode(id: old.id) { $0.userState.isDownloaded = true; $0.userState.localFileURL = media.path; $0.userState.playState = .played }
            let network = DownloadNetworkMonitor(startMonitoring: false)
            // Hold transfers offline: the source auto-download job only enqueues.
            network.update(.init(connected: false, metered: true, cellular: false))
            let downloads = DownloadCoordinator(store: store, directory: root.appendingPathComponent("downloads"), network: network)
            let playback = PlaybackCoordinator(store: store, engine: AVPlayerPlaybackEngine(muted: true))
            var prefs = AutomaticDownloadPreferences(); prefs.cacheSize = 2; prefs.cleanup = -1
            let selected = prefs
            let coordinator = AutomaticDownloadCoordinator(store: store, preferences: { selected },
                environment: { .init(connection: .wifi(metered: false), allowMobile: false, charging: false) },
                cleanup: { try await downloads.deleteDownloadedMedia(episodeID: $0.id, playback: playback) },
                download: { try await downloads.requestAutomatic(episodeID: $0) })
            try await coordinator.run()
            #expect(!FileManager.default.fileExists(atPath: media.path))
            #expect(try await store.episode(id: old.id)?.userState.isDownloaded == false)
            let jobs = try await store.downloadJobs()
            #expect(jobs.count == 2 && jobs.allSatisfy { $0.networkConstraint == .unmetered })
            #expect(try await store.queue().map(\.id) == jobs.map(\.episodeID))
            try await coordinator.run() // Serial repetition must not duplicate jobs.
            #expect(try await store.downloadJobs().count == 2)
            await downloads.stop()
        }
    }

    @Test func legacyQueueSignalMigratesAndStaleAcknowledgementCannotEraseNewRequest() async throws {
        try await storeFixture { store, file, _ in
            let feed = try await insert(store)
            _ = try await store.enqueue([feed.episodes[0].id])
            try await store.close()
            let old = try LibrarySQLite(url: file)
            try restoreRefreshSchemaEleven(old)
            try old.execute("ALTER TABLE queue_work DROP COLUMN token")
            try old.execute("DROP TABLE synchronization_state"); try old.execute("DROP TABLE synchronization_outbox"); try old.execute("DROP TABLE feed_credentials"); try old.execute("DROP TABLE feed_credential_cleanup"); try old.execute("PRAGMA user_version = 8")
            try old.close()
            let migrated = try FeedLibraryStore(url: file)
            let original = try #require(try await migrated.automaticDownloadRequest())
            #expect(try await migrated.queue().count == 1)
            try await migrated.requestAutomaticDownload()
            let replacement = try #require(try await migrated.automaticDownloadRequest())
            #expect(replacement != original)
            #expect(try await migrated.finishAutomaticDownloadRequest(original) == false)
            try await migrated.close()
            let reopened = try FeedLibraryStore(url: file)
            #expect(try await reopened.automaticDownloadRequest() == replacement)
            #expect(try await reopened.finishAutomaticDownloadRequest(replacement))
            #expect(try await reopened.automaticDownloadRequest() == nil)
            try await reopened.close()
        }
    }

    @Test func requestReturnsBeforeSelectionAndSuspendedOwnerRecoversOnResume() async throws {
        try await storeFixture { store, _, _ in
            _ = try await insert(store)
            var gate: CheckedContinuation<Void,Never>?
            var calls = 0, selected: [Int64] = []
            let owner = AutomaticDownloadCoordinator(store: store, preferences: { .init() }, environment: {
                calls += 1
                await withCheckedContinuation { gate = $0 }
                return .init(connection: .ethernet, allowMobile: false, charging: true)
            }, cleanup: { _ in Issue.record("Unexpected cleanup") }, download: { selected.append($0) })
            // Durable acceptance does not require a running execution lease.
            try await owner.request()
            #expect(calls == 0 && selected.isEmpty)
            #expect(try await store.queueAutoDownloadRequested())
            owner.resume()
            while gate == nil { await Task.yield() }
            // Repeated scene activation cannot create a second execution.
            owner.resume(); owner.resume()
            #expect(calls == 1 && selected.isEmpty)
            gate?.resume(); gate = nil
            while owner.state == .running { await Task.yield() }
            #expect(owner.state == .idle && selected.count == 3)
            #expect(try await store.queueAutoDownloadRequested() == false)
            owner.suspend()
        }
    }

    @Test func queueChangesDuringSelectionAreObservedWithoutScreenReloadAndDoNotLoop() async throws {
        try await storeFixture { store, _, root in
            let feed = try await insert(store), ids = feed.episodes.map(\.id)
            try await store.updatePreferences(feedID: feed.id) { $0.autoDownload = .disabled }
            var prefs = AutomaticDownloadPreferences(); prefs.queue = true
            let selected = prefs
            var gate: CheckedContinuation<Void,Never>?
            var calls: [Int64] = []
            var passes = 0
            let owner = AutomaticDownloadCoordinator(store: store, preferences: { selected }, environment: {
                passes += 1
                return .init(connection: .ethernet, allowMobile: false, charging: true)
            }, cleanup: { _ in Issue.record("Unexpected cleanup") }, download: { id in
                calls.append(id)
                _ = try await store.requestDownload(episodeID: id, directory: root, automatic: true)
                if calls.count == 1 { await withCheckedContinuation { gate = $0 } }
            })
            owner.resume()
            _ = try await store.enqueue([ids[0]])
            while gate == nil { await Task.yield() }
            let first = try #require(try await store.automaticDownloadRequest())
            _ = try await store.enqueue([ids[1]])
            #expect(try await store.automaticDownloadRequest() != first)
            gate?.resume(); gate = nil
            while owner.state == .running { await Task.yield() }
            // Both queued episodes are downloaded once, in queue order, and
            // the extra queue change causes one more pass, not a loop.
            #expect(owner.state == .idle && passes == 2)
            #expect(try await store.downloadJobs().map(\.episodeID) == [ids[0], ids[1]])
            #expect(try await store.queue().map(\.id) == [ids[0], ids[1]])
            #expect(try await store.queueAutoDownloadRequested() == false)
            owner.suspend()
        }
    }

    @Test func ownedFailureRetainsWorkAndExplicitResumeRetriesWithoutDuplicateCompletedJobs() async throws {
        try await storeFixture { store, _, root in
            _ = try await insert(store)
            var fail = true, calls = 0
            let owner = AutomaticDownloadCoordinator(store: store, preferences: { .init() },
                environment: { .init(connection: .ethernet, allowMobile: false, charging: true) },
                cleanup: { _ in Issue.record("Unexpected cleanup") }, download: { id in
                    calls += 1
                    if calls == 2 && fail { throw FeedLibraryError.invalidMutation }
                    _ = try await store.requestDownload(episodeID: id, directory: root, enqueue: false, automatic: true)
                })
            try await owner.request()
            owner.resume()
            while owner.state == .running { await Task.yield() }
            guard case .failed = owner.state else { Issue.record("Expected retained failure"); owner.suspend(); return }
            let saved = try #require(try await store.automaticDownloadRequest())
            #expect(calls == 2)
            #expect(try await store.downloadJobs().count == 1)
            // An unrelated read does not retry or acknowledge failed selection.
            #expect(try await store.automaticDownloadRequest() == saved)
            fail = false
            owner.resume()
            while owner.state == .running { await Task.yield() }
            #expect(owner.state == .idle && calls == 5)
            #expect(try await store.downloadJobs().count == 3)
            #expect(try await store.automaticDownloadRequest() == nil)
            owner.suspend()
        }
    }

    @Test func newerAcceptedTriggerStillRunsWhenEarlierSelectionFails() async throws {
        try await storeFixture { store, _, _ in
            _ = try await insert(store)
            var gate: CheckedContinuation<Void,Never>?
            var passes = 0, downloads = 0
            let owner = AutomaticDownloadCoordinator(store: store, preferences: { .init() }, environment: {
                passes += 1
                if passes == 1 {
                    await withCheckedContinuation { gate = $0 }
                    throw FeedLibraryError.invalidMutation
                }
                return .init(connection: .ethernet, allowMobile: false, charging: true)
            }, cleanup: { _ in Issue.record("Unexpected cleanup") }, download: { _ in downloads += 1 })
            try await owner.request(); owner.resume()
            while gate == nil { await Task.yield() }
            // Acceptance returns while the preceding execution is still held.
            try await owner.request()
            #expect(passes == 1 && downloads == 0)
            gate?.resume(); gate = nil
            while owner.state == .running { await Task.yield() }
            #expect(owner.state == .idle && passes == 2 && downloads == 3)
            #expect(try await store.automaticDownloadRequest() == nil)
            owner.suspend()
        }
    }

    @Test func suspendedInFlightSelectionCannotAcknowledgeOrOverlapItsReplacement() async throws {
        try await storeFixture { store, _, _ in
            _ = try await insert(store)
            var gate: CheckedContinuation<Void,Never>?
            var passes = 0, downloads = 0
            let owner = AutomaticDownloadCoordinator(store: store, preferences: { .init() }, environment: {
                passes += 1
                if passes == 1 { await withCheckedContinuation { gate = $0 } }
                return .init(connection: .ethernet, allowMobile: false, charging: true)
            }, cleanup: { _ in Issue.record("Unexpected cleanup") }, download: { _ in downloads += 1 })
            try await owner.request(); owner.resume()
            while gate == nil { await Task.yield() }
            owner.suspend()
            #expect(owner.state == .suspended)
            #expect(try await store.queueAutoDownloadRequested())
            owner.resume()
            #expect(passes == 1)
            gate?.resume(); gate = nil
            while owner.state == .running { await Task.yield() }
            #expect(owner.state == .idle && passes == 2 && downloads == 3)
            #expect(try await store.automaticDownloadRequest() == nil)
            owner.suspend()
        }
    }

    @Test func blockedNetworkAcknowledgesAttemptAndNewTriggerUsesCurrentConditions() async throws {
        try await storeFixture { store, _, _ in
            _ = try await insert(store)
            final class Network { var connected = false }
            let network = Network()
            var downloads = 0
            let owner = AutomaticDownloadCoordinator(store: store, preferences: { .init() }, environment: {
                .init(connection: network.connected ? .ethernet : .unavailable, allowMobile: false, charging: true)
            }, cleanup: { _ in Issue.record("Unexpected cleanup") }, download: { _ in downloads += 1 })
            try await owner.request(); owner.resume()
            while owner.state == .running { await Task.yield() }
            #expect(downloads == 0 && owner.state == .idle)
            #expect(try await store.automaticDownloadRequest() == nil)
            network.connected = true
            try await owner.request()
            while owner.state == .running { await Task.yield() }
            #expect(downloads == 3 && owner.state == .idle)
            owner.suspend()
        }
    }
}
