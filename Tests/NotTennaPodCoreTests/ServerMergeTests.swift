import Foundation
import Testing
@testable import NotTennaPodCore

/// Merges the server decided, applied here (PROTOCOL §9.7), with commits made by the
/// test: the merged row's download moves to the survivor, the player keeps its episode until it leaves it, a survivor
/// without a row here takes the merged row, the discovery ledger follows, and a podcast merge keeps the downloads and
/// device-only settings.
@Suite struct ServerMergeTests {
    typealias Applier = ServerProjectionUnitTests.Applier
    typealias Fixture = ServerLibraryFixture

    static func identity(_ episode: String, podcast: String, guid: String, mergedInto: String? = nil) -> ServerRecord {
        var value: ContractObject = ["podcast_id": .string(podcast), "occurrence": ["k": "rss-guid", "v": .string(guid), "guid": .string(guid)]]
        if let mergedInto { value["merged_into"] = .string(mergedInto) }
        return ServerRecord(entity: "episode", id: episode, fieldGroup: "identity", value: .object(value))
    }

    static func playState(_ episode: String, _ generation: String, _ state: String) -> ServerRecord {
        ServerRecord(entity: "episode", id: episode, fieldGroup: "play_state", value: ["generation_id": .string(generation), "play_state": .string(state)])
    }

    /// A registered podcast whose facts the server acknowledged, and its episodes' wire IDs by GUID.
    static func registered(_ fixture: Fixture, _ fetched: FetchedFeed = Fixture.fetched()) async throws
        -> (feed: LibraryFeed, podcast: String, generation: String, wire: [String: String]) {
        let registered = try await fixture.subscribeRegistered(fetched)
        var wire: [String: String] = [:]
        for episode in registered.feed.episodes {
            let guid = episode.details.identifier ?? ""
            wire[guid] = try fixture.expectedEpisodeID(podcast: registered.podcast, guid: guid)
        }
        return (registered.feed, registered.podcast, registered.generation, wire)
    }

    /// The feed-deletion coordinator's file cleanup, as the app runs it after a unit.
    @MainActor static func cleanUp(_ store: FeedLibraryStore) async throws {
        let deletion = FeedDeletionCoordinator(store: store, retirePlayback: { _ in }, retireDownloads: { _ in })
        try await deletion.resume().value
    }

    private func local(_ fixture: Fixture, _ guid: String) async throws -> LibraryEpisode? {
        try await fixture.store.feeds().flatMap(\.episodes).first { $0.details.identifier == guid }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await Fixture()
        do { try await body(fixture); await fixture.close() } catch { await fixture.close(); throw error }
    }

    @Test func aMergedRowGoesAndItsDownloadMovesToTheSurvivor() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let (feed, podcast, generation, wire) = try await Self.registered(fixture)
            let old = try #require(try await local(fixture, "guid-1")), moved = try #require(try await local(fixture, "guid-2"))
            let file = fixture.directory.appendingPathComponent("moved.mp3")
            try Data([1, 2, 3]).write(to: file)
            try await store.projectForTesting(moved.id) {
                $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path; $0.userState.downloadDate = Fixture.now
            }
            try await store.executeForTesting("INSERT INTO ntp_ledger(generation_id, occurrence, entry_id, state, notified, record) VALUES (?, ?, NULL, 'done', 1, NULL)",
                                              [.text(generation), .text(wire["guid-2"]!)])
            try await store.retireEverythingForTesting()
            let applier = try await Applier(fixture)
            try await applier.apply([Self.identity(wire["guid-1"]!, podcast: podcast, guid: "guid-1"),
                                     Self.identity(wire["guid-2"]!, podcast: podcast, guid: "guid-2", mergedInto: wire["guid-1"]!),
                                     Self.playState(wire["guid-1"]!, generation, "played")])
            #expect(try await store.episode(id: moved.id) == nil, "the merged row goes")
            let survivor = try #require(try await store.episode(id: old.id))
            #expect(survivor.userState.isDownloaded && survivor.userState.localFileURL == file.path, "its download is the survivor's")
            #expect(survivor.userState.playState == .played)
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(try fixture.rows("SELECT occurrence, state FROM ntp_ledger") == [[wire["guid-1"]!, "done"]], "the ledger follows, done stays done")
            // The removal's file cleanup keeps a file the survivor names.
            try await Self.cleanUp(store)
            #expect(FileManager.default.fileExists(atPath: file.path))
            _ = feed
        }
    }

    /// An episode merge keeps the merged row's active download (waiting or transferring) as the
    /// survivor's: the same job, destination and progress, never cancelled or its partial file deleted; completing it
    /// gives the survivor the download.
    @Test(arguments: [false, true]) func aMergeKeepsAnActiveDownload(_ transferring: Bool) async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let (_, podcast, generation, wire) = try await Self.registered(fixture)
            let survivor = try #require(try await local(fixture, "guid-1")), merged = try #require(try await local(fixture, "guid-2"))
            let media = fixture.directory.appendingPathComponent("media", isDirectory: true)
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            let job = try #require(try await store.requestDownload(episodeID: merged.id, directory: media, enqueue: false))
            var attempt = 0
            if transferring {
                attempt = try #require(try await store.beginDownloadAttempt(id: job.id)).attempts
                try Data([7, 7]).write(to: job.destination)
                #expect(try await store.attachDownloadFile(id: job.id, attempt: attempt))
            }
            try await store.retireEverythingForTesting()
            try await Applier(fixture).apply([Self.identity(wire["guid-1"]!, podcast: podcast, guid: "guid-1"),
                                              Self.identity(wire["guid-2"]!, podcast: podcast, guid: "guid-2", mergedInto: wire["guid-1"]!),
                                              Self.playState(wire["guid-1"]!, generation, "unplayed")])
            try await Self.cleanUp(store)
            #expect(try await store.episode(id: merged.id) == nil, "the merged row goes")
            let jobs = try await store.downloadJobs(activeOnly: true)
            #expect(jobs.map(\.id) == [job.id] && jobs.first?.episodeID == survivor.id, "the same job, now the survivor's")
            #expect(jobs.first?.state == (transferring ? .transferring : .waiting))
            guard transferring else { return }
            #expect(FileManager.default.fileExists(atPath: job.destination.path), "its partial file stays")
            try Data([7, 7, 7]).write(to: job.destination)
            #expect(try await store.completeDownload(id: job.id, attempt: attempt))
            let kept = try #require(try await store.episode(id: survivor.id))
            #expect(kept.userState.isDownloaded && kept.userState.localFileURL == job.destination.path, "the survivor has the download")
        }
    }

    /// Two episodes downloading merge into one survivor in one unit. The survivor takes one
    /// download, its job and file; the other job is retired through the cleanup (its partial file deleted); completion
    /// and a relaunch keep one owner and one job.
    @Test(arguments: [false, true]) func twoMergingDownloadsKeepOneOwnerAndOneJob(_ transferring: Bool) async throws {
        let fixture = try await Fixture()
        do {
            let store = fixture.store
            let (_, podcast, generation, wire) = try await Self.registered(fixture)
            let survivor = try #require(try await local(fixture, "guid-1"))
            let media = fixture.directory.appendingPathComponent("media", isDirectory: true)
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            var jobs: [(job: LibraryDownloadJob, attempt: Int)] = []
            for guid in ["guid-2", "guid-3"] {
                let episode = try #require(try await local(fixture, guid))
                let job = try #require(try await store.requestDownload(episodeID: episode.id, directory: media, enqueue: false))
                var attempt = 0
                if transferring {
                    attempt = try #require(try await store.beginDownloadAttempt(id: job.id)).attempts
                    try Data([1]).write(to: job.destination)
                    #expect(try await store.attachDownloadFile(id: job.id, attempt: attempt))
                }
                jobs.append((job, attempt))
            }
            try await store.retireEverythingForTesting()
            try await Applier(fixture).apply([Self.identity(wire["guid-1"]!, podcast: podcast, guid: "guid-1"),
                                              Self.identity(wire["guid-2"]!, podcast: podcast, guid: "guid-2", mergedInto: wire["guid-1"]!),
                                              Self.identity(wire["guid-3"]!, podcast: podcast, guid: "guid-3", mergedInto: wire["guid-1"]!),
                                              Self.playState(wire["guid-1"]!, generation, "unplayed")])
            try await Self.cleanUp(store)
            let active = try await store.downloadJobs(activeOnly: true)
            #expect(active.count == 1 && active.first?.episodeID == survivor.id, "one job, the survivor's: \(active.count)")
            let kept = try #require(jobs.first { $0.job.id == active.first?.id }), retired = try #require(jobs.first { $0.job.id != active.first?.id })
            if transferring {
                #expect(try await store.episode(id: survivor.id)?.userState.localFileURL == kept.job.destination.path)
                #expect(!FileManager.default.fileExists(atPath: retired.job.destination.path), "the other partial file goes")
            }
            // A relaunch keeps one owner and one job; completing it gives the survivor its file.
            try await store.close()
            let reopened = try FeedLibraryStore(url: fixture.url)
            #expect(try await reopened.downloadJobs(activeOnly: true).map(\.id) == [kept.job.id])
            guard transferring else { try await reopened.close(); try? FileManager.default.removeItem(at: fixture.directory); return }
            try Data([1, 1]).write(to: kept.job.destination)
            #expect(try await reopened.completeDownload(id: kept.job.id, attempt: kept.attempt))
            let downloaded = try #require(try await reopened.episode(id: survivor.id))
            #expect(downloaded.userState.isDownloaded && downloaded.userState.localFileURL == kept.job.destination.path)
            #expect(try await reopened.downloadJobs(activeOnly: true).isEmpty)
            try await reopened.close()
            try? FileManager.default.removeItem(at: fixture.directory)
        } catch { await fixture.close(); throw error }
    }

    /// Mixed: one merged row is downloading, another merged later in the same unit has the file.
    /// The survivor keeps the finished download; the running job is retired with its row.
    @Test func aFinishedDownloadWinsOverOneStillRunningInOneUnit() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let (_, podcast, generation, wire) = try await Self.registered(fixture)
            let survivor = try #require(try await local(fixture, "guid-1"))
            let media = fixture.directory.appendingPathComponent("media", isDirectory: true)
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            // guid-2 (merged first, by episode ID order) is downloading; guid-3 has its file. Which merges first depends on
            // the wire IDs, so both orders are made by choosing which row downloads.
            let first = [wire["guid-2"]!, wire["guid-3"]!].min { $0.utf8.lexicographicallyPrecedes($1.utf8) } == wire["guid-2"]! ? "guid-2" : "guid-3"
            let second = first == "guid-2" ? "guid-3" : "guid-2"
            let running = try #require(try await local(fixture, first)), finished = try #require(try await local(fixture, second))
            let job = try #require(try await store.requestDownload(episodeID: running.id, directory: media, enqueue: false))
            let file = media.appendingPathComponent("finished.mp3")
            try Data([9]).write(to: file)
            try await store.projectForTesting(finished.id) { $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path }
            try await store.retireEverythingForTesting()
            try await Applier(fixture).apply([Self.identity(wire["guid-1"]!, podcast: podcast, guid: "guid-1"),
                                              Self.identity(wire["guid-2"]!, podcast: podcast, guid: "guid-2", mergedInto: wire["guid-1"]!),
                                              Self.identity(wire["guid-3"]!, podcast: podcast, guid: "guid-3", mergedInto: wire["guid-1"]!),
                                              Self.playState(wire["guid-1"]!, generation, "unplayed")])
            try await Self.cleanUp(store)
            let kept = try #require(try await store.episode(id: survivor.id))
            #expect(kept.userState.isDownloaded && kept.userState.localFileURL == file.path)
            #expect(try await store.downloadJobs(activeOnly: true).isEmpty, "the running job is retired")
            #expect(FileManager.default.fileExists(atPath: file.path))
            _ = job
        }
    }

    /// The podcast-merge variant. The merged podcast's feed goes after its episodes merge (whole;
    /// held for the player as a pinned removal and deleted when the player leaves it; or, large, hidden and deleted in
    /// bounded transactions); its cleanup never cancels the download that moved to the survivor, nor deletes its partial
    /// file, though they share an address (here also with an episode of the merged feed that stays to the end).
    @Test(arguments: ["whole", "pinned", "hidden"]) func aPodcastMergeKeepsAMovedDownload(_ removal: String) async throws {
        try await withFixture { fixture in
            let store = fixture.store
            // The same media addresses in both feeds; the large merged feed repeats the first address at its end.
            var old = Fixture.fetched("https://example.test/old.xml", title: "Show", count: removal == "hidden" ? FeedLibraryStore.removalBatch + 10 : 4)
            if removal == "hidden" {
                let first = old.feed.episodes[0].media?.url
                old.feed.episodes[old.feed.episodes.count - 1].media?.url = first
            }
            let source = try await Self.registered(fixture, old)
            let target = try await Self.registered(fixture, Fixture.fetched("https://example.test/new.xml", title: "Show", guidPrefix: "new-"))
            let downloading = try #require(try await local(fixture, "guid-1")), survivor = try #require(try await local(fixture, "new-1"))
            let media = fixture.directory.appendingPathComponent("media", isDirectory: true)
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            let job = try #require(try await store.requestDownload(episodeID: downloading.id, directory: media, enqueue: false))
            let attempt = try #require(try await store.beginDownloadAttempt(id: job.id)).attempts
            try Data([4, 4]).write(to: job.destination)
            #expect(try await store.attachDownloadFile(id: job.id, attempt: attempt))
            if removal == "pinned" { _ = try await store.beginPlayback(episodeID: try #require(try await local(fixture, "guid-2")).id) }
            try await store.retireEverythingForTesting()
            // The first population's observations were applied (nothing of this library's discovery
            // work is pending: a merge waits for that).
            try await store.executeForTesting("DELETE FROM ntp_observation_work")
            var records: [ServerRecord] = [ServerRecord(entity: "podcast", id: source.podcast, fieldGroup: "subscription",
                                                        value: ["state": "merged", "merged_into": .string(target.podcast)])]
            for n in 1...4 {
                records.append(Self.identity(target.wire["new-\(n)"]!, podcast: target.podcast, guid: "new-\(n)"))
                records.append(Self.identity(source.wire["guid-\(n)"]!, podcast: source.podcast, guid: "guid-\(n)", mergedInto: target.wire["new-\(n)"]!))
            }
            try await Applier(fixture).apply(records)
            try await Self.cleanUp(store)
            func kept() async throws {
                let jobs = try await store.downloadJobs(activeOnly: true)
                #expect(jobs.map(\.id) == [job.id] && jobs.first?.episodeID == survivor.id && jobs.first?.state == .transferring,
                        "the same job goes on as the survivor's")
                #expect(FileManager.default.fileExists(atPath: job.destination.path), "its partial file stays")
            }
            try await kept()
            func feedRows() throws -> String? { try fixture.rows("SELECT count(*) FROM feeds WHERE id = \(source.feed.id)").first?.first ?? nil }
            switch removal {
            case "pinned":
                #expect(try feedRows() == "1", "held for the player")
                try await store.executeForTesting("DELETE FROM playback_session")
                try await store.executeForTesting("DELETE FROM playback_selection")
                #expect(try await store.releaseServerPins())
            case "hidden":
                #expect(try await store.hasHiddenRemovals())
                while try await store.deleteHiddenRemovalBatch().remaining {}
            default: break
            }
            try await Self.cleanUp(store)
            #expect(try feedRows() == "0", "the merged feed is gone")
            try await kept()
            try Data([4, 4, 4]).write(to: job.destination)
            #expect(try await store.completeDownload(id: job.id, attempt: attempt))
            #expect(try await store.episode(id: survivor.id)?.userState.isDownloaded == true)
        }
    }

    @Test func thePlayersEpisodeStaysUntilThePlayerLeavesIt() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let (_, podcast, generation, wire) = try await Self.registered(fixture)
            let merged = try #require(try await local(fixture, "guid-2"))
            _ = try await store.beginPlayback(episodeID: merged.id)
            try await store.retireEverythingForTesting()
            let applier = try await Applier(fixture)
            try await applier.apply([Self.identity(wire["guid-1"]!, podcast: podcast, guid: "guid-1"),
                                     Self.identity(wire["guid-2"]!, podcast: podcast, guid: "guid-2", mergedInto: wire["guid-1"]!),
                                     Self.playState(wire["guid-1"]!, generation, "unplayed")])
            #expect(try await store.episode(id: merged.id) != nil, "a merge never interrupts playback")
            #expect(try await store.releaseServerPins() == false, "still held")
            try await store.executeForTesting("DELETE FROM playback_session")
            try await store.executeForTesting("DELETE FROM playback_selection")
            #expect(try await store.releaseServerPins())
            #expect(try await store.episode(id: merged.id) == nil, "gone once the player left it")
        }
    }

    @Test func aSurvivorWithoutARowHereTakesTheMergedRow() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let (_, podcast, generation, wire) = try await Self.registered(fixture)
            let row = try #require(try await local(fixture, "guid-3"))
            try await store.retireEverythingForTesting()
            let survivor = try fixture.expectedEpisodeID(podcast: podcast, guid: "older-guid")
            let applier = try await Applier(fixture)
            try await applier.apply([Self.identity(survivor, podcast: podcast, guid: "older-guid"),
                                     Self.identity(wire["guid-3"]!, podcast: podcast, guid: "guid-3", mergedInto: survivor),
                                     ServerRecord(entity: "episode", id: survivor, fieldGroup: "favorite", value: ["generation_id": .string(generation), "on": true])])
            #expect(try fixture.wireID(row.id) == survivor, "the row is the survivor's now")
            #expect(try await store.episode(id: row.id)?.userState.isFavorite == true)
            #expect(try await store.feeds().flatMap(\.episodes).count == 4, "no new row")
        }
    }

    @Test func aPodcastMergedIntoOneThisLibraryShowsKeepsDownloadsAndSettings() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let source = try await Self.registered(fixture, Fixture.fetched("https://example.test/old.xml", title: "Old"))
            let target = try await Self.registered(fixture, Fixture.fetched("https://example.test/new.xml", title: "New", guidPrefix: "new-"))
            try await store.updatePreferences(feedID: source.feed.id) {
                $0.tags = ["News"]; $0.autoDownload = .enabled
                $0.volumeAdaptation = .lightBoost; $0.skip = FeedSkipPreferences(introSeconds: 30, endingSeconds: 10)
            }
            let downloaded = try #require(try await local(fixture, "guid-1"))
            let file = fixture.directory.appendingPathComponent("old-1.mp3")
            try Data([9]).write(to: file)
            try await store.projectForTesting(downloaded.id) { $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path }
            try await store.retireEverythingForTesting()
            let applier = try await Applier(fixture)
            var records: [ServerRecord] = [ServerRecord(entity: "podcast", id: source.podcast, fieldGroup: "subscription",
                                                        value: ["state": "merged", "merged_into": .string(target.podcast)])]
            for n in 1...4 {
                records.append(Self.identity(target.wire["new-\(n)"]!, podcast: target.podcast, guid: "new-\(n)"))
                records.append(Self.identity(source.wire["guid-\(n)"]!, podcast: source.podcast, guid: "guid-\(n)", mergedInto: target.wire["new-\(n)"]!))
            }
            try await applier.apply(records)
            #expect(try await store.feed(id: source.feed.id) == nil, "the merged podcast leaves")
            let survivor = try #require(try await store.feed(id: target.feed.id))
            #expect(survivor.tags == ["News"] && survivor.autoDownload == .enabled, "the survivor had no device settings of its own")
            #expect(survivor.volumeAdaptation == .lightBoost && survivor.skipPreferences == FeedSkipPreferences(introSeconds: 30, endingSeconds: 10))
            let kept = try #require(survivor.episodes.first { $0.details.identifier == "new-1" })
            #expect(kept.userState.isDownloaded && kept.userState.localFileURL == file.path)
            try await Self.cleanUp(store)
            #expect(FileManager.default.fileExists(atPath: file.path), "the moved download is never deleted")
        }
    }

    /// Per-feed speed and skip silence live in the library's playback file, outside the database: a podcast merge
    /// lists the pair with the merge, and the app gives the survivor the source's when it has neither of its own, then
    /// finishes the pair only after the file is saved, so a crash in between redoes the same copy.
    @MainActor @Test func aPodcastMergeCarriesPerFeedSpeedAndSkipSilence() async throws {
        let fixture = try await Fixture()
        do {
            let store = fixture.store
            var pairs: [(source: (feed: LibraryFeed, podcast: String, generation: String, wire: [String: String]),
                         target: (feed: LibraryFeed, podcast: String, generation: String, wire: [String: String]))] = []
            for name in ["a", "b"] {
                pairs.append((try await Self.registered(fixture, Fixture.fetched("https://example.test/\(name)-old.xml", title: "\(name) old", guidPrefix: "\(name)-")),
                              try await Self.registered(fixture, Fixture.fetched("https://example.test/\(name)-new.xml", title: "\(name) new", guidPrefix: "\(name)-new-"))))
            }
            let root = fixture.directory.appendingPathComponent("playback-speed-preferences.json")
            let libraryFile = fixture.directory.appendingPathComponent("playback-library.json")
            var speeds = try PlaybackSpeedPreferenceStore(file: root, library: try PlaybackLibraryFile(url: libraryFile))
            try speeds.setFeed(pairs[0].source.feed.id, speed: 1.75, skipSilence: .aggressive)
            try speeds.setFeed(pairs[1].source.feed.id, speed: 2, skipSilence: .aggressive)
            try speeds.setFeed(pairs[1].target.feed.id, speed: 1.25)
            try await store.retireEverythingForTesting()
            var records: [ServerRecord] = []
            for ((source, target), name) in zip(pairs, ["a", "b"]) {
                records.append(ServerRecord(entity: "podcast", id: source.podcast, fieldGroup: "subscription",
                                            value: ["state": "merged", "merged_into": .string(target.podcast)]))
                for n in 1...4 {
                    let survivor = try #require(target.wire["\(name)-new-\(n)"]), merged = try #require(source.wire["\(name)-\(n)"])
                    records.append(Self.identity(survivor, podcast: target.podcast, guid: "\(name)-new-\(n)"))
                    records.append(Self.identity(merged, podcast: source.podcast, guid: "\(name)-\(n)", mergedInto: survivor))
                }
            }
            try await Applier(fixture).apply(records)
            #expect(try await store.serverFeedMerges() == pairs.map { ServerFeedMerge(source: $0.source.feed.id, survivor: $0.target.feed.id) })
            // The copy is saved, then the process ends before the pair is finished: the next run copies again, the same.
            try speeds.adoptFeedSettings(from: pairs[0].source.feed.id, to: pairs[0].target.feed.id)
            speeds = try PlaybackSpeedPreferenceStore(file: root, library: try PlaybackLibraryFile(url: libraryFile))
            try await speeds.carryServerFeedMerges(from: store)
            #expect(try await store.serverFeedMerges().isEmpty)
            let saved = try PlaybackSpeedPreferenceStore(file: root, library: try PlaybackLibraryFile(url: libraryFile)).value
            #expect(saved.feeds[pairs[0].target.feed.id] == 1.75 && saved.silence.feeds[pairs[0].target.feed.id] == .aggressive,
                    "the survivor had neither of its own")
            #expect(saved.feeds[pairs[1].target.feed.id] == 1.25 && saved.silence.feeds[pairs[1].target.feed.id] == nil, "a survivor's own speed stays")
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    @Test func aPodcastMergedIntoOneThisLibraryDoesNotShowTakesItsFeed() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let source = try await Self.registered(fixture, Fixture.fetched("https://example.test/old.xml", title: "Old"))
            try await store.retireEverythingForTesting()
            let survivor = try ContractIdentity.podcastID(namespace: fixture.identity.namespace, creatingOpID: ContractIdentity.randomUUID())
            let generation = try ContractIdentity.generationID(namespace: fixture.identity.namespace, podcastID: survivor, creatingOpID: ContractIdentity.randomUUID())
            let applier = try await Applier(fixture)
            var records: [ServerRecord] = [
                ServerRecord(entity: "podcast", id: source.podcast, fieldGroup: "subscription", value: ["state": "merged", "merged_into": .string(survivor)]),
                ServerRecord(entity: "podcast", id: survivor, fieldGroup: "subscription", value: ["state": "subscribed", "generation_id": .string(generation)]),
                ServerRecord(entity: "podcast", id: survivor, fieldGroup: "identity", value: [
                    "refresh_url": "https://example.test/new.xml",
                    "aliases": [["url": "https://example.test/new.xml", "normalized": "https://example.test/new.xml"]]]),
            ]
            var survivors: [String: String] = [:]
            for n in 1...4 {
                let episode = try ContractIdentity.episodeID(namespace: fixture.identity.namespace, podcastID: survivor, kind: "rss-guid", value: "guid-\(n)")
                survivors["guid-\(n)"] = episode
                records.append(Self.identity(episode, podcast: survivor, guid: "guid-\(n)"))
                records.append(Self.identity(source.wire["guid-\(n)"]!, podcast: source.podcast, guid: "guid-\(n)", mergedInto: episode))
            }
            try await applier.apply(records)
            #expect(try await store.podcastOfFeedForTesting(source.feed.id) == survivor, "the feed is the survivor's")
            let feed = try #require(try await store.feed(id: source.feed.id))
            #expect(feed.episodes.count == 4, "its rows stay, as the survivor's")
            for episode in feed.episodes { #expect(try fixture.wireID(episode.id) == survivors[episode.details.identifier ?? ""]) }
        }
    }
}
