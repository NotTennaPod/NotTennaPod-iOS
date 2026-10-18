import Foundation
import Security
import Synchronization
import Testing
@testable import NotTennaPodCore

/// "Keep using this library" at logout (PROTOCOL §15.4): the Keep transaction on a device with a standalone
/// library and a server library, uninterrupted, crashed and failed after every step, recovered (also under another
/// application root), twice in a row, and opened before publication.
@MainActor @Suite(.serialized) struct LibraryKeepTests {
    nonisolated static let now = Date(timeIntervalSince1970: 1_780_000_000)
    nonisolated static let source = "11111111-2222-4333-8444-555555555555"

    /// A device's files: the root folder (Application Support) with its libraries.
    struct Device {
        let root: URL
        let secrets: MemoryServerSecrets
        var source: LibraryLocation { LibraryLocation(root: root, reference: .server(LibraryKeepTests.source)) }
        var registry: LibraryRegistry { (try? LibraryRegistryFile(root: root).read()) ?? LibraryRegistry() }
        func keep(beforeStep: @escaping (LibraryKeep.Step) throws -> Void = { _ in }, files: LibraryKeep.KeepFiles = .init()) -> LibraryKeep {
            LibraryKeep(.init(root: root, secrets: secrets, clock: { LibraryKeepTests.now }, beforeStep: beforeStep, files: files))
        }
    }

    // MARK: - The device

    /// The standalone library ("Own": a downloaded episode, a favorite, the queue, its speeds, shownotes and policies)
    /// and the active server library S ("Server": a downloaded episode with a live transfer record, statistics units,
    /// a pinned removal selected in the player, a secret-only credential, pending account policies and its own speeds).
    func device() async throws -> Device {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keep-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The standalone library.
        let own = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let ownFeed = try await own.insert(ServerLibraryFixture.fetched("https://own.example/feed.xml", title: "Own", count: 3))
        let ownEpisodes = ownFeed.episodes.map(\.id).sorted()
        let ownMedia = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: ownMedia, withIntermediateDirectories: true)
        let ownFile = ownMedia.appendingPathComponent("own-1.media")
        try Data(repeating: 1, count: 1_000).write(to: ownFile)
        try await own.updateEpisode(id: ownEpisodes[0]) { episode in
            episode.userState.isDownloaded = true; episode.userState.localFileURL = ownFile.path
            episode.userState.downloadDate = LibraryKeepTests.now
        }
        try await own.setFavorite(episodeID: ownEpisodes[1], favorite: true)
        _ = try await own.enqueue([ownEpisodes[2], ownEpisodes[0]])
        try await own.close()
        var speeds = PlaybackSpeedPreferences()
        speeds.global = 1.25; speeds.feeds[ownFeed.id] = 1.5; speeds.currentEpisodeID = ownEpisodes[0]; speeds.temporary = 1.5
        try JSONEncoder().encode(speeds).write(to: root.appendingPathComponent("playback-speed-preferences.json"))
        try JSONEncoder().encode(ShownotesPosition(episodeID: ownEpisodes[0], offset: 42)).write(to: root.appendingPathComponent("shownotes-scroll.json"))
        var download = DownloadPreferences(); download.newEpisodesAction = .queue; download.enqueueLocation = .back; download.allowMobile = true
        try JSONEncoder().encode(download).write(to: root.appendingPathComponent("download-preferences.json"))
        try JSONEncoder().encode(QueueInteractionPreferences(keepSorted: false, keepSortedOrderName: "DATE_OLD_NEW"))
            .write(to: root.appendingPathComponent("queue-interaction.json"))

        // The server library S.
        let secrets = MemoryServerSecrets()
        let location = LibraryLocation(root: root, reference: .server(Self.source))
        let install = ContractIdentity.randomUUID()
        try await StoreServerLibraryProvisioning(feedVault: { MemoryCredentialVault() }).provision(location, ServerLibraryProvision(
            libraryID: Self.source, serverURL: "http://127.0.0.1:1", serverID: "server", accountID: ContractIdentity.randomUUID(),
            namespace: ContractIdentity.randomUUID(), username: "alice", installID: install, deviceMarker: "marker"))
        try secrets.saveInstallation(.init(transportNonce: "nonce", token: "token"), library: Self.source, install: install)
        let store = try FeedLibraryStore(url: location.database)
        _ = FeedAuthentication(store: store, vault: MemoryCredentialVault())
        let feed = try await store.insert(ServerLibraryFixture.fetched("https://server.example/feed.xml", title: "Server", count: 3))
        let removed = try await store.insert(ServerLibraryFixture.fetched("https://removed.example/feed.xml", title: "Removed", count: 2))
        let episodes = feed.episodes.map(\.id).sorted()
        try FileManager.default.createDirectory(at: location.media, withIntermediateDirectories: true)
        let file = location.media.appendingPathComponent("server-1.media")
        try Data(repeating: 2, count: 2_000).write(to: file)
        try await store.updateEpisode(id: episodes[0]) { episode in
            episode.userState.isDownloaded = true; episode.userState.localFileURL = file.path
            episode.userState.downloadDate = LibraryKeepTests.now
        }
        try await store.markEpisodePlayed(episodeID: episodes[0], played: true)
        _ = try await store.requestDownload(episodeID: episodes[1], directory: location.media)
        try await store.setFavorite(episodeID: episodes[2], favorite: true)
        _ = try await store.enqueue([episodes[1], episodes[2]])
        try await store.setServerAccountPolicy(.enqueueLocation(.front))
        try await store.setServerAccountPolicy(.sorting(keepSorted: true, order: .dateNewOld))
        // The server's refresh of this podcast fails (its refresh_status, as a projection shows it).
        try await store.setServerRefreshForTesting(ServerRefreshStatus(lastAttempt: LibraryKeepTests.now, label: "forbidden", code: 403),
                                                   feedID: feed.id)
        try await store.close()
        // A live background transfer's sidecar record, written under S's folder.
        let transfers = location.media.appendingPathComponent("background-transfers", isDirectory: true)
        try FileManager.default.createDirectory(at: transfers, withIntermediateDirectories: true)
        let record = BackgroundMediaDownloads.TaskRecord(destination: location.media.appendingPathComponent("episode-x.media").path, base: 0, library: Self.source)
        try JSONEncoder().encode(record).write(to: transfers.appendingPathComponent("episode-x.media.task.json"))
        // Server state the conversion turns into library data.
        let removedEpisode = removed.episodes[0].id
        func unit(_ id: String, played: Int64) -> String {
            "{\"duration_ms\":600000,\"history\":1760000000000,\"id\":\"\(id)\",\"last_played\":1760000000000,\"played\":true,\"played_ms\":\(played),\"position\":0}"
        }
        try RawLibrary.execute(location.database, """
            UPDATE episodes SET record = CAST(json_set(CAST(record AS TEXT), '$.userState.playedDurationMilliseconds', 90000, '$.userState.lastPlayedTimeMilliseconds', 1770000000000) AS BLOB) WHERE id = \(episodes[0]);
            INSERT INTO ntp_episodes(episode_id, local_id, podcast_id, kind, value) VALUES ('e:1', \(episodes[0]), 'p', 'g', '1');
            INSERT INTO ntp_statistics_units(episode_id, unit_id, record) VALUES ('e:1', 'imp/7', CAST('\(unit("imp/7", played: 300_000))' AS BLOB));
            INSERT INTO statistics_units(episode_id, unit_id, played_ms, last_played, history, duration_ms, played, position) VALUES (\(episodes[0]), 'imp/7', 300000, 1760000000000, 1760000000000, 600000, 1, 0);
            INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('episode', 'e:1', 'statistics_units', '{}', '["n1"]');
            INSERT INTO ntp_nodes(node_id, knowledge_clock) VALUES ('n1', 1);
            INSERT OR REPLACE INTO ntp_podcasts(podcast_id, feed_id, pinned_removal) VALUES ('p-removed', \(removed.id), 1);
            INSERT INTO playback_selection(id, episode_id) VALUES (1, \(removedEpisode));
            INSERT INTO ntp_secrets(secret_id, credential_id, origin, created_at) VALUES ('secret-1', '6F4C1C2E-0000-4000-8000-000000000001', 'local', 0);
            DELETE FROM ntp_observation_work;
            INSERT INTO ntp_observation_work(local_id, feed_id, batch_id, fetch_time, hash, fields) VALUES (\(episodes[0]), \(feed.id), 'batch', 0, 'hash', x'7B7D');
            INSERT INTO ntp_feed_merges(source_feed, survivor_feed) VALUES (\(removed.id), \(feed.id));
            """)
        #expect(try RawLibrary.rows(location.database, "SELECT count(*) FROM ntp_local_items").first?.first != "0", "the episodes' identities")
        var library = PlaybackLibraryData()
        library.speeds.feeds[feed.id] = 2.0; library.speeds.currentEpisodeID = removedEpisode; library.speeds.temporary = 2.0
        library.shownotes = .init(episodeID: removedEpisode, offset: 7)
        try JSONEncoder().encode(library).write(to: location.playbackLibraryFile!)
        var registry = LibraryRegistry()
        registry.libraries = [.init(id: Self.source, serverURL: "http://127.0.0.1:1", serverID: "server", accountID: ContractIdentity.randomUUID(),
                                    username: "alice", state: .active, createdAt: 0)]
        registry.active = .server(Self.source)
        try LibraryRegistryFile(root: root).write(registry)
        return Device(root: root, secrets: secrets)
    }

    /// A copy of a device under another application root (a device backup restored elsewhere).
    func copy(_ device: Device) throws -> Device {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Keep-\(UUID())", isDirectory: true)
        try FileManager.default.copyItem(at: device.root, to: root)
        let secrets = MemoryServerSecrets()
        for (key, value) in device.secrets.items {
            let parts = key.split(separator: "/").map(String.init)
            try secrets.saveInstallation(value, library: parts[0], install: parts[1])
        }
        return Device(root: root, secrets: secrets)
    }

    /// What a person could see or the device keeps, with the previous library's random ID and the root's path left out,
    /// so two devices that kept the same library compare equal.
    func state(_ device: Device) async throws -> [String: String] {
        var state: [String: String] = [:]
        let registry = device.registry
        let previous = registry.previous.map(\.id)
        func normalized(_ text: String) -> String {
            var text = text.replacingOccurrences(of: device.root.standardizedFileURL.path, with: "ROOT")
            for (index, id) in previous.enumerated() { text = text.replacingOccurrences(of: id, with: "P\(index)") }
            return text
        }
        state["registry.active"] = registry.active.name
        state["registry.libraries"] = registry.libraries.map { "\($0.id):\($0.state.rawValue)" }.joined(separator: ",")
        state["registry.previous"] = normalized(registry.previous.map { "\($0.id):\($0.identity):\($0.keptAt):\($0.state.rawValue)" }.joined(separator: ","))
        state["registry.conversions"] = registry.conversions.map(\.library).joined(separator: ",")
        state["registry.standalone"] = registry.standaloneIdentity ?? "-"
        // Files (Library Conversions and SQLite sidecars left out).
        var files: [String] = []
        for relative in (FileManager.default.subpaths(atPath: device.root.path) ?? []) {
            let url = device.root.appendingPathComponent(relative)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let path = normalized(url.standardizedFileURL.path)
            if path.hasSuffix("-wal") || path.hasSuffix("-shm") || path.contains("Library Conversions") { continue }
            files.append(path + (path.hasSuffix(".sqlite") || path.hasSuffix(".json") ? "" : ":\(values.fileSize ?? -1)"))
        }
        state["files"] = files.sorted().joined(separator: "\n")
        // Settings.
        for name in ["playback-speed-preferences.json", "shownotes-scroll.json", "download-preferences.json", "queue-interaction.json"] {
            let url = device.root.appendingPathComponent(name)
            state["settings." + name] = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
                .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) }.map { String(decoding: $0, as: UTF8.self) } ?? "-"
        }
        for previous in registry.previous {
            let location = PreviousLibraryLocation(root: device.root, id: previous.id)
            state["previous.\(normalized(previous.id)).description"] = (try? Data(contentsOf: location.descriptionFile))
                .flatMap { try? JSONDecoder().decode(PreviousLibraryDescription.self, from: $0) }
                .map { "\($0.identity) \($0.keptAt) \($0.policies) \($0.castTag ?? "-")" }
            state["previous.\(normalized(previous.id)).playback"] = (try? Data(contentsOf: location.playbackLibraryFile)).map { String(decoding: $0, as: UTF8.self) }
            state["previous.\(normalized(previous.id)).library"] = try await libraryState(location.database, readOnly: true, normalize: normalized)
        }
        state["root.library"] = try await libraryState(device.root.appendingPathComponent("library.sqlite"), readOnly: false, normalize: normalized)
        return state
    }

    /// A library as the screens show it: feeds, episodes, queue, statistics and units, its identity and server state.
    func libraryState(_ url: URL, readOnly: Bool, normalize: (String) -> String) async throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "-" }
        let store = readOnly ? try FeedLibraryStore(readingOnly: url) : try FeedLibraryStore(url: url)
        do {
            let text = try await describe(store, readOnly: readOnly, normalize: normalize)
            try await store.close()
            return text
        } catch {
            try? await store.close()
            throw error
        }
    }

    private func describe(_ store: FeedLibraryStore, readOnly: Bool, normalize: (String) -> String) async throws -> String {
        var lines: [String] = []
        let identity = try await store.libraryIdentity()
        lines.append("identity \(identity.identity) cast \(identity.castTag ?? "-") role \(identity.keepRole?.rawValue ?? "-")")
        lines.append("server \(await store.isServerLibrary)")
        let snapshot = try await store.snapshot()
        for feed in snapshot.feeds {
            lines.append("feed \(feed.id) \(feed.title ?? "") failed \(feed.refreshFailed) server-status \(feed.serverRefresh != nil)")
            for episode in feed.episodes {
                let state = episode.userState
                // A previous library is read only: its stored paths are resolved by readers that need them, never written.
                let file = readOnly ? (state.localFileURL.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "-")
                    : "\(state.localFileURL.map(normalize) ?? "-") exists \(state.localFileURL.map { FileManager.default.fileExists(atPath: $0) } ?? false)"
                lines.append("  episode \(episode.id) \(state.playState) fav \(state.isFavorite) played \(state.playedDurationMilliseconds) file \(file)")
            }
        }
        lines.append("queue \(snapshot.queue.map(\.id))")
        lines.append("units \(snapshot.statisticsUnits.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.map(\.unitID))" })")
        lines.append("statistics \(try await store.statistics(includeMarkedAsPlayed: true, now: LibraryKeepTests.now).feeds.map { "\($0.feedID):\($0.episodes):\($0.playedSeconds)" })")
        lines.append("jobs \(try await store.downloadJobs(activeOnly: true).map { normalize($0.destination.standardizedFileURL.path) })")
        return lines.joined(separator: "\n")
    }

    func remove(_ device: Device) { try? FileManager.default.removeItem(at: device.root) }

    func differences(_ actual: [String: String], _ expected: [String: String]) -> String {
        Set(actual.keys).union(expected.keys).sorted().filter { actual[$0] != expected[$0] }.map { key in
            "\(key):\n  got \(actual[key] ?? "nil")\n  expected \(expected[key] ?? "nil")"
        }.joined(separator: "\n")
    }

    // MARK: - The uninterrupted Keep

    @Test func keepMakesTheServerLibraryThisPhonesOwnAndKeepsTheOldOneAside() async throws {
        let template = try await device()
        defer { remove(template) }
        let device = try copy(template)
        defer { remove(device) }
        // Before: what the server library shows.
        let before = try await libraryState(device.source.database, readOnly: false) { $0.replacingOccurrences(of: device.root.standardizedFileURL.path, with: "ROOT") }
        let keep = device.keep()
        let manifest = try keep.request(source: Self.source)
        #expect(device.registry.library(Self.source)?.state == .keeping && device.registry.library(Self.source)?.operation == manifest.operation)
        #expect(keep.run(manifest) == .finished)
        let registry = device.registry
        #expect(registry.libraries.isEmpty && registry.conversions.isEmpty && registry.active == .standalone)
        #expect(registry.standaloneIdentity == Self.source)
        let previous = try #require(registry.previous.first)
        #expect(registry.previous.count == 1 && previous.keptAt == Int64(Self.now.timeIntervalSince1970 * 1_000))
        // The kept library is in the root folder, standalone, with S's identity and Cast tag, and shows what S showed.
        let root = device.root.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: root)
        #expect(await store.isServerLibrary == false)
        let identity = try await store.libraryIdentity()
        #expect(identity.identity == Self.source && identity.castTag == Self.source && identity.keepRole == .converted)
        let feeds = try await store.feeds()
        #expect(feeds.map(\.title) == ["Server"], "the pinned removal stays hidden")
        let downloaded = try #require(feeds[0].episodes.first { $0.userState.isDownloaded })
        #expect(downloaded.userState.localFileURL == device.root.appendingPathComponent("media/server-1.media").path)
        #expect(FileManager.default.fileExists(atPath: downloaded.userState.localFileURL!))
        #expect(try await store.statisticsLibrary().units[downloaded.id]?.map(\.unitID) == ["imp/7"])
        #expect(try await store.downloadJobs(activeOnly: true).first?.destination.deletingLastPathComponent().standardizedFileURL.path
                == device.root.appendingPathComponent("media").standardizedFileURL.path)
        #expect(try RawLibrary.rows(root, "SELECT count(*) FROM feed_credential_cleanup WHERE credential_id = '6F4C1C2E-0000-4000-8000-000000000001'").first?.first == "1")
        #expect(try RawLibrary.rows(root, "SELECT count(*) FROM ntp_library").first?.first == "0")
        #expect(try RawLibrary.rows(root, "SELECT count(*) FROM ntp_outbox").first?.first == "0")
        #expect(try RawLibrary.rows(root, "SELECT count(*) FROM ntp_local_items").first?.first == "0", "server state goes, the identities too")
        #expect(try RawLibrary.rows(root, "SELECT count(*) FROM ntp_observation_work").first?.first == "0", "and observations still to record")
        #expect(try RawLibrary.rows(root, "SELECT count(*) FROM ntp_feed_merges").first?.first == "0", "and merges' settings still to carry")
        try await store.close()
        // Nothing a person sees changed at conversion (the downloaded file's path names its new folder), but the server's
        // refresh status: a library that no longer syncs with a server shows none.
        let after = try await libraryState(root, readOnly: false) { $0.replacingOccurrences(of: device.root.standardizedFileURL.path, with: "ROOT") }
        #expect(before.contains("Server failed true server-status true"))
        #expect(after.replacingOccurrences(of: "role converted", with: "role -").replacingOccurrences(of: "server false", with: "server true")
                == before.replacingOccurrences(of: "ROOT/Server Libraries/\(Self.source)/media", with: "ROOT/media")
                    .replacingOccurrences(of: "Server failed true server-status true", with: "Server failed false server-status false"))
        // The previous library: the old library with its files, policies and speeds.
        let archive = PreviousLibraryLocation(root: device.root, id: previous.id)
        let old = try FeedLibraryStore(readingOnly: archive.database)
        #expect(try await old.feeds().map(\.title) == ["Own"])
        #expect(try await old.libraryIdentity().keepRole == .archived)
        try await old.close()
        #expect(FileManager.default.fileExists(atPath: archive.media.appendingPathComponent("own-1.media").path))
        let description = try JSONDecoder().decode(PreviousLibraryDescription.self, from: Data(contentsOf: archive.descriptionFile))
        #expect(description.policies.newEpisodesAction == .queue && description.policies.keepSortedOrderName == "DATE_OLD_NEW")
        let oldPlayback = try JSONDecoder().decode(PlaybackLibraryData.self, from: Data(contentsOf: archive.playbackLibraryFile))
        #expect(oldPlayback.speeds.feeds.values.contains(1.5) && oldPlayback.shownotes?.offset == 42)
        // The root settings: S's library-owned values replace the old ones; device values stay.
        let speeds = try JSONDecoder().decode(PlaybackSpeedPreferences.self, from: Data(contentsOf: device.root.appendingPathComponent("playback-speed-preferences.json")))
        #expect(speeds.global == 1.25 && speeds.feeds.values.sorted() == [2.0] && speeds.temporary == 2.0)
        let download = try JSONDecoder().decode(DownloadPreferences.self, from: Data(contentsOf: device.root.appendingPathComponent("download-preferences.json")))
        #expect(download.enqueueLocation == .front && download.allowMobile == true)
        let queue = try JSONDecoder().decode(QueueInteractionPreferences.self, from: Data(contentsOf: device.root.appendingPathComponent("queue-interaction.json")))
        #expect(queue.keepSorted && queue.keepSortedOrderName == QueueSortOrder.dateNewOld.rawValue)
        // S's folder, installation items and the manifest are gone; transfer records name their current folders.
        #expect(!FileManager.default.fileExists(atPath: device.source.folder.path))
        #expect(device.secrets.items.isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: LibraryKeep.conversionsFolder(root: device.root).path)) ?? []).isEmpty)
        let sidecar = device.root.appendingPathComponent("media/background-transfers/episode-x.media.task.json")
        let record = try JSONDecoder().decode(BackgroundMediaDownloads.TaskRecord.self, from: Data(contentsOf: sidecar))
        #expect(record.destination == device.root.appendingPathComponent("media/episode-x.media").standardizedFileURL.path && record.library == Self.source)
        #expect(LibraryTransferRouting.resolve(device.source.media.appendingPathComponent("episode-x.media").path, library: Self.source, root: device.root)
                == device.root.appendingPathComponent("media/episode-x.media").standardizedFileURL.path)
        #expect(LibraryTransferRouting.resolve(device.root.appendingPathComponent("media/own-1.media").path, library: description.identity, root: device.root)
                == archive.media.appendingPathComponent("own-1.media").standardizedFileURL.path)
        // A late callback with an unresolvable old path never recreates the old folder.
        #expect(!BackgroundMediaDownloads.Files.libraryFolderExists(device.source.media.appendingPathComponent("late.media").path))
        #expect(BackgroundMediaDownloads.Files.libraryFolderExists(device.root.appendingPathComponent("media/late.media").path))
    }

    // MARK: - Crashes and failures at every step

    /// A crash after every step, then recovery at the next graph start (and the same crash again during recovery):
    /// the result equals an uninterrupted Keep, under another application root too (a backup restored elsewhere).
    @Test(arguments: LibraryKeep.Step.allCases)
    func aCrashAtAnyStepRecoversToTheSameResult(_ crashAt: LibraryKeep.Step) async throws {
        let template = try await device()
        defer { remove(template) }
        let baseline = try copy(template)
        defer { remove(baseline) }
        let manifest = try baseline.keep().request(source: Self.source)
        #expect(baseline.keep().run(manifest) == .finished)
        let expected = try await state(baseline)
        #expect(expected["root.library"]?.contains("server-status true") == false, "a kept library shows no server refresh status")
        #expect(expected["root.library"]?.contains("Server failed false") == true)

        let device = try copy(template)
        defer { remove(device) }
        let crashed = device.keep { if $0 == crashAt { throw LibraryKeepInterruption() } }
        try crashed.run(crashed.request(source: Self.source)).assertInterrupted()
        // The same crash once more during recovery, then a recovery that finishes.
        if let pending = try crashed.unfinished() { _ = crashed.run(pending) }
        // A device backup taken now, restored under another root, finishes too.
        let restored = try copy(device)
        defer { remove(restored) }
        for target in [device, restored] {
            let keep = target.keep()
            if let pending = try keep.unfinished() { #expect(keep.run(pending) == .finished) }
            #expect(try keep.unfinished() == nil)
            let actual = try await state(target)
            #expect(actual == expected, "after a crash at \(crashAt.rawValue): \(differences(actual, expected))")
        }
    }

    /// A failure (a full disk) at every step: before the commit nothing changed and S stays the active library; after
    /// it the converted library opens where it is. A retry finishes with the same result.
    @Test(arguments: LibraryKeep.Step.allCases)
    func aFailureAtAnyStepLeavesBothLibrariesCompleteAndRetries(_ failAt: LibraryKeep.Step) async throws {
        let template = try await device()
        defer { remove(template) }
        let baseline = try copy(template)
        defer { remove(baseline) }
        _ = baseline.keep().run(try baseline.keep().request(source: Self.source))
        let expected = try await state(baseline)

        let device = try copy(template)
        defer { remove(device) }
        let failing = device.keep { if $0 == failAt { throw POSIXError(.ENOSPC) } }
        let outcome = failing.run(try failing.request(source: Self.source))
        let cleanup = failAt.rawValue.hasPrefix("cleanup")
        switch outcome {
        case .notCommitted(let failure):
            #expect(failure == .storage)
            // Nothing moved: S is the active library, keeping, and still a server library where it was.
            #expect(device.registry.active == .server(Self.source) && device.registry.keeping?.id == Self.source)
            #expect(try LibraryDatabaseInspection.identity(of: device.source.database)?.keepRole == nil)
            #expect(await (try FeedLibraryStore(readingOnly: device.source.database)).isServerLibrary)
            #expect(try keepConverted(device) == nil)
        case .notPublished(let failure):
            #expect(failure == .storage)
            // A failure after the registry published (the manifest's own last write) has nothing left to open.
            if failAt != .publishWrite { #expect(try keepConverted(device) != nil, "the converted library opens where it is") }
        case .cleanupPending:
            #expect(cleanup)
        case .finished:
            // After the commit a manifest write that fails is corrected from the database's mark.
            #expect(failAt == .convertWrite, "a failure at \(failAt.rawValue) went unnoticed")
        }
        let keep = device.keep()
        if let pending = try keep.unfinished() { #expect(keep.run(pending) == .finished) }
        let actual = try await state(device)
        #expect(actual == expected, "after a failure at \(failAt.rawValue): \(differences(actual, expected))")
    }

    func keepConverted(_ device: Device) throws -> LibraryLocation? {
        let keep = device.keep()
        guard let pending = try keep.unfinished() else { return nil }
        return try keep.convertedLibrary(pending)
    }

    // MARK: - Opening before publication

    /// After Keep the library no longer syncs with a server: a podcast whose server refresh failed shows no error, no
    /// notice and no server row in its details, after reopening and after a successful refresh. This device's own
    /// failure, its log and its times stay as they were until this device's own refresh succeeds.
    @Test func keepDropsTheServersRefreshStatusAndKeepsThisDevicesOwn() async throws {
        let device = try await device()
        defer { remove(device) }
        let server = try FeedLibraryStore(url: device.source.database)
        _ = FeedAuthentication(store: server, vault: MemoryCredentialVault())
        let failing = try #require(try await server.feeds().first { $0.metadata.title == "Server" })
        #expect(failing.refreshFailed && failing.serverRefresh != nil && !failing.lastUpdateFailed)
        let other = try await server.insert(ServerLibraryFixture.fetched("https://other.example/feed.xml", title: "Other", count: 1))
        try await server.setServerRefreshForTesting(ServerRefreshStatus(lastAttempt: Self.now, label: "parser_exception"), feedID: other.id)
        try await server.recordFailure(.unauthorized, feedID: failing.id, date: Self.now.addingTimeInterval(60))
        let before = try #require(try await server.feed(id: failing.id))
        let log = try #require(try await server.logs(feedID: failing.id).first)
        try await server.close()
        let keep = device.keep()
        #expect(keep.run(try keep.request(source: Self.source)) == .finished)
        let store = try FeedLibraryStore(url: device.root.appendingPathComponent("library.sqlite"))
        #expect(await !store.isServerLibrary)
        let words = ["ntp_refresh_by_server": "The server: %1$@", "ntp_refresh_by_device": "This device: %1$@"]
        func text(_ key: String) -> String { words[key] ?? key }
        // Only the server's failure: nothing shows.
        let kept = try #require(try await store.feed(id: other.id))
        #expect(kept.serverRefresh == nil && !kept.refreshFailed)
        let otherLog = try await store.logs(feedID: other.id).first
        #expect(FeedLogDetails.refreshFailure(latestLog: otherLog, feed: kept, text: text, date: { _ in "date" }) == nil)
        // This device's own failure stays, with its times and log, and its details have no server row.
        var own = try #require(try await store.feed(id: failing.id))
        #expect(own.serverRefresh == nil && own.refreshFailed && own.lastUpdateFailed)
        #expect(own.lastRefreshAttempt == before.lastRefreshAttempt && own.localRefreshAttempt == before.localRefreshAttempt)
        #expect(try await store.logs(feedID: failing.id).first == log)
        let details = try #require(FeedLogDetails.refreshFailure(latestLog: log, feed: own, text: text, date: { _ in "date" }))
        #expect(details.statusKey == "download_error_unauthorized" && details.origins.isEmpty && !details.clipboard.contains("The server"))
        // This device's refresh succeeds: no icon, no notice.
        struct Transport: FeedHTTPTransport {
            func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
                FeedHTTPResponse(url: request.url!, status: 200, body: ServerDiscoveryTests.rss(""))
            }
        }
        let service = FeedRefreshService(store: store, fetcher: FeedFetcher(transport: Transport()), clock: { Self.now.addingTimeInterval(120) })
        guard case .updated = try await service.refresh(feedID: failing.id) else { Issue.record("not refreshed"); return }
        own = try #require(try await store.feed(id: failing.id))
        #expect(!own.refreshFailed && own.serverRefresh == nil)
        let latest = try await store.logs(feedID: failing.id).first
        #expect(latest?.kind.isSuccessful == true)
        #expect(FeedLogDetails.refreshFailure(latestLog: latest, feed: own, text: text, date: { _ in "date" }) == nil)
        try await store.close()
    }

    /// The settings write fails after the commit: the converted library opens from where it is, plays its downloads and
    /// records changes (play, mark, queue, speeds, policies); the retry publishes those later values, not the capture,
    /// and the archive is never opened.
    /// The server library's device-local play time (what its rewind after a pause measures from) does not survive the
    /// Keep: it is gone from the kept episode, everything else stays as it was (the last-played
    /// date included), and a later pause and Play in the standalone library rewinds as any standalone library's does.
    @Test func keepDropsTheServerRewindTimeAndALaterPauseRewindsAsStandalone() async throws {
        typealias Hooks = ServerPlaybackHookTests
        let device = try await device()
        defer { remove(device) }
        let clock = Hooks.Clock()
        clock.date = Self.now
        let server = try FeedLibraryStore(url: device.source.database)
        _ = FeedAuthentication(store: server, vault: MemoryCredentialVault())
        let feed = try #require(try await server.feeds().first { $0.metadata.title == "Server" })
        let episode = try #require(feed.episodes.map(\.id).sorted().last)
        let engine = Hooks.Engine()
        let playback = PlaybackCoordinator(store: server, engine: engine, clock: { clock.date })
        try await playback.select(episodeID: episode, play: true)
        engine.ready()
        try await playback.awaitPendingOperations()
        clock.date += 30
        engine.advance(to: 30_000)
        try await playback.pause()
        await playback.retire().value
        let played = try #require(try await server.episode(id: episode)).userState
        #expect(played.playedHereMilliseconds != nil, "the server library keeps when this device last played")
        try await server.close()
        let keep = device.keep()
        #expect(keep.run(try keep.request(source: Self.source)) == .finished)
        let store = try FeedLibraryStore(url: device.root.appendingPathComponent("library.sqlite"))
        let kept = try #require(try await store.episode(id: episode)).userState
        #expect(kept.playedHereMilliseconds == nil, "gone with the server state")
        var unchanged = played
        unchanged.playedHereMilliseconds = nil
        #expect(kept == unchanged, "everything else as it was, the last-played date included")
        // Two hours later, played and paused in the standalone library; Play 30 s after the pause rewinds 0.8 s.
        clock.date += 7_200
        let standaloneEngine = Hooks.Engine()
        let standalone = PlaybackCoordinator(store: store, engine: standaloneEngine, clock: { clock.date })
        try await standalone.select(episodeID: episode, play: true)
        standaloneEngine.ready()
        try await standalone.awaitPendingOperations()
        clock.date += 20
        standaloneEngine.advance(to: 50_000)
        try await standalone.pause()
        clock.date += 30
        #expect(try await Hooks.rewind(standalone, standaloneEngine) == 800)
        #expect(try await store.episode(id: episode)?.userState.playedHereMilliseconds == nil)
        await standalone.retire().value
        try await store.close()
    }

    @Test func aConvertedLibraryOpensBeforePublicationAndKeepsLaterChanges() async throws {
        let device = try await device()
        defer { remove(device) }
        let failing = device.keep { if $0 == .settingsSpeeds { throw POSIXError(.ENOSPC) } }
        guard case .notPublished(.storage) = failing.run(try failing.request(source: Self.source)) else {
            Issue.record("the settings write did not fail"); return
        }
        let location = try #require(try keepConverted(device))
        #expect(location.database == device.root.appendingPathComponent("library.sqlite"), "the database moved before the settings write")
        #expect(try LibraryDatabaseInspection.identity(of: location.database)?.identity == Self.source)
        let store = try FeedLibraryStore(url: location.database, ownedRoot: location.ownedRoot)
        let feed = try #require(try await store.feeds().first)
        let downloaded = try #require(feed.episodes.first { $0.userState.isDownloaded })
        #expect(FileManager.default.fileExists(atPath: downloaded.userState.localFileURL ?? ""))
        try await store.markEpisodePlayed(episodeID: feed.episodes.last!.id, played: true)
        try await store.close()
        // Later changes are saved in the converted library's own files.
        let playback = try PlaybackLibraryFile(url: location.playbackLibraryFile!)
        try playback.update { $0.speeds.feeds[feed.id] = 2.5 }
        let policy = FileAccountPolicy(file: try #require(location.accountPoliciesFile))
        #expect(policy.enqueueLocation == .front)
        try policy.setEnqueueLocation(.afterCurrentlyPlaying)
        // The retry at the next safe point publishes those values.
        let keep = device.keep()
        #expect(keep.run(try #require(try keep.unfinished())) == .finished)
        let speeds = try JSONDecoder().decode(PlaybackSpeedPreferences.self, from: Data(contentsOf: device.root.appendingPathComponent("playback-speed-preferences.json")))
        #expect(speeds.feeds[feed.id] == 2.5)
        let download = try JSONDecoder().decode(DownloadPreferences.self, from: Data(contentsOf: device.root.appendingPathComponent("download-preferences.json")))
        #expect(download.enqueueLocation == .afterCurrentlyPlaying)
        let reopened = try FeedLibraryStore(url: device.root.appendingPathComponent("library.sqlite"))
        #expect(try await reopened.episode(id: feed.episodes.last!.id)?.userState.playState == .played)
        try await reopened.close()
    }

    // MARK: - A locked Keychain

    /// The Keychain is needed only for the cleanup: locked (or failing), the Keep still commits and publishes, the
    /// installation items stay for the next graph start, which removes them.
    @Test func aLockedKeychainNeverHoldsTheKeepAndItsItemsGoLater() async throws {
        let device = try await device()
        defer { remove(device) }
        let locked = LibraryKeep(.init(root: device.root, secrets: LockedSecrets(device.secrets), clock: { LibraryKeepTests.now }))
        #expect(locked.run(try locked.request(source: Self.source)) == .cleanupPending)
        #expect(device.registry.active == .standalone && device.registry.previous.count == 1)
        #expect(device.registry.conversions.count == 1, "the conversions entry names what is left")
        #expect(!device.secrets.items.isEmpty)
        let keep = device.keep()
        #expect(keep.run(try #require(try keep.unfinished())) == .finished)
        #expect(device.secrets.items.isEmpty && device.registry.conversions.isEmpty)
    }

    /// A secrets store whose Keychain is locked: nothing can be read or removed.
    final class LockedSecrets: ServerSecretStore, @unchecked Sendable {
        let wrapped: MemoryServerSecrets
        init(_ wrapped: MemoryServerSecrets) { self.wrapped = wrapped }
        func deviceMarker() throws -> String { throw ServerSecretStoreError.keychain(errSecInteractionNotAllowed) }
        func installation(library: String, install: String) throws -> ServerInstallationCredential? { throw ServerSecretStoreError.keychain(errSecInteractionNotAllowed) }
        func saveInstallation(_ credential: ServerInstallationCredential, library: String, install: String) throws { throw ServerSecretStoreError.keychain(errSecInteractionNotAllowed) }
        func removeInstallation(library: String, install: String) throws { throw ServerSecretStoreError.keychain(errSecInteractionNotAllowed) }
        func removeLibrary(_ library: String) throws { throw ServerSecretStoreError.keychain(errSecInteractionNotAllowed) }
        func installIDs(of library: String) throws -> [String] { throw ServerSecretStoreError.keychain(errSecInteractionNotAllowed) }
    }

    // MARK: - Recovery's registry rules

    @Test func anUnnamedRequestIsDiscardedAndAnUnnamedCommitIsFinished() async throws {
        let device = try await device()
        defer { remove(device) }
        // A manifest written, the registry write lost: a request that was never recorded is deleted.
        let keep = device.keep()
        let manifest = try keep.request(source: Self.source)
        try LibraryRegistryFile(root: device.root).update { registry in
            registry.libraries[0].state = .active; registry.libraries[0].operation = nil
        }
        #expect(try keep.unfinished() == nil)
        #expect(!FileManager.default.fileExists(atPath: keep.manifestFile(manifest.operation).path))
        // A committed manifest the registry no longer names (a restored registry) is written back and finished.
        let second = try keep.request(source: Self.source)
        let crashed = device.keep { if $0 == .publishCheckpoint { throw LibraryKeepInterruption() } }
        _ = crashed.run(second)
        try LibraryRegistryFile(root: device.root).update { registry in
            registry.libraries[0].state = .active; registry.libraries[0].operation = nil
        }
        let pending = try #require(try keep.unfinished())
        #expect(pending.operation == second.operation)
        #expect(keep.run(pending) == .finished)
        #expect(device.registry.previous.count == 1 && device.registry.libraries.isEmpty)
    }

    // MARK: - Two Keeps in a row

    /// A second Keep moves a library that was itself kept: two previous libraries, neither overwritten nor duplicated,
    /// the first kept library's Cast tag and units going with it.
    @Test func twoKeepsInARowKeepTwoPreviousLibraries() async throws {
        let device = try await device()
        defer { remove(device) }
        #expect(device.keep().run(try device.keep().request(source: Self.source)) == .finished)
        // Log in again: a first attachment with a new library.
        let second = "99999999-2222-4333-8444-555555555555"
        let location = LibraryLocation(root: device.root, reference: .server(second))
        try await StoreServerLibraryProvisioning(feedVault: { MemoryCredentialVault() }).provision(location, ServerLibraryProvision(
            libraryID: second, serverURL: "http://127.0.0.1:1", serverID: "server", accountID: ContractIdentity.randomUUID(),
            namespace: ContractIdentity.randomUUID(), username: "bob", installID: ContractIdentity.randomUUID(), deviceMarker: "marker"))
        try LibraryRegistryFile(root: device.root).update { registry in
            registry.libraries.append(.init(id: second, serverURL: "http://127.0.0.1:1", serverID: "server", accountID: ContractIdentity.randomUUID(),
                                            username: "bob", state: .active, createdAt: 0))
            registry.active = .server(second)
        }
        let later = LibraryKeep(.init(root: device.root, secrets: device.secrets, clock: { LibraryKeepTests.now.addingTimeInterval(3_600) }))
        #expect(later.run(try later.request(source: second)) == .finished)
        let registry = device.registry
        #expect(registry.previous.count == 2 && Set(registry.previous.map(\.id)).count == 2)
        #expect(registry.standaloneIdentity == second)
        let kept = try #require(registry.previous.first { $0.identity == Self.source })
        let first = PreviousLibraryLocation(root: device.root, id: kept.id)
        #expect(try LibraryDatabaseInspection.identity(of: first.database)?.castTag == Self.source)
        #expect(FileManager.default.fileExists(atPath: first.media.appendingPathComponent("server-1.media").path))
        let reader = try FeedLibraryStore(readingOnly: first.database)
        #expect(try await reader.statisticsLibrary().units.values.flatMap { $0 }.map(\.unitID) == ["imp/7"])
        try await reader.close()
        #expect(try LibraryDatabaseInspection.identity(of: device.root.appendingPathComponent("library.sqlite"))?.identity == second)
    }

    // MARK: - Cast across a Keep (PROTOCOL §15.4 "Cast")

    /// Media `S` loaded on a receiver carry `S`'s tag. After the Keep the converted library keeps that tag, so its
    /// receiver media stay its own and are adopted; another library's media and untagged media (the old standalone
    /// library's loads) are foreign to it. The previous library keeps no tag: `S`'s media are foreign there. The graph
    /// derives its Cast library from `library_identity` (`AppDelegate`) and compares tags exactly as here
    /// (`CastReceiverSessionController`, `CastPlaybackEngine`).
    @Test func receiverMediaOfTheKeptLibraryStayItsOwnAcrossTheKeep() async throws {
        let device = try await device()
        defer { remove(device) }
        let rootDatabase = device.root.appendingPathComponent("library.sqlite")
        func castLibrary(_ database: URL) throws -> LibraryReference { try #require(try LibraryDatabaseInspection.identity(of: database)).castLibrary }
        // Before: what each library's graph tags its loads with.
        let loadedByS = try castLibrary(device.source.database).castLibraryID
        let loadedByOwn = try castLibrary(rootDatabase).castLibraryID
        let loadedByOther = LibraryReference.server("99999999-2222-4333-8444-555555555555").castLibraryID
        #expect(loadedByS == Self.source && loadedByOwn == nil)
        #expect(device.keep().run(try device.keep().request(source: Self.source)) == .finished)
        // After: the converted library in the root folder.
        let kept = try castLibrary(rootDatabase)
        #expect(kept == .server(Self.source))
        #expect(loadedByS == kept.castLibraryID, "its receiver media are recognized")
        #expect(loadedByOther != kept.castLibraryID && loadedByOwn != kept.castLibraryID, "another library's and untagged media are foreign")
        // The previous library: untagged, like before.
        let previous = try #require(device.registry.previous.first)
        let archived = try castLibrary(PreviousLibraryLocation(root: device.root, id: previous.id).database)
        #expect(archived == .standalone && loadedByS != archived.castLibraryID)
    }

    // MARK: - Removal and graph start

    @Test func aPreviousLibraryIsMigratedFoundAndExported() async throws {
        let device = try await device()
        defer { remove(device) }
        #expect(device.keep().run(try device.keep().request(source: Self.source)) == .finished)
        let previous = try #require(device.registry.previous.first)
        // Its export is found by identity and read through the read-only reader.
        let source = try await LibraryExport.collect(identity: previous.identity, root: device.root, open: nil,
                                                     vault: MemoryCredentialVault(), gate: LibraryGate())
        #expect(source.feeds.map(\.title) == ["Own"])
        #expect(source.speeds.feeds.values.contains(1.5), "its own speeds, from its playback-library.json")
        // Graph start migrates nothing more and finds no Keep.
        #expect(LibraryGraphStart.migrateLibraries(root: device.root, gate: LibraryGate()).isEmpty)
        #expect(try LibraryGraphStart.converted(device.keep()) == nil)
    }
}

extension LibraryKeep.Outcome {
    func assertInterrupted(sourceLocation: SourceLocation = #_sourceLocation) {
        switch self {
        case .notCommitted(.interrupted), .notPublished(.interrupted), .cleanupPending: break
        default: Issue.record("expected an interruption, got \(self)", sourceLocation: sourceLocation)
        }
    }
}
