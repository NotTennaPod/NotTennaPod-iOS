#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Exports of every library (PROTOCOL §11.5): statistics units as stock Android rows, one immutable
/// source collected under the shared library gate, from the chosen library by identity.
@Suite(.serialized) struct LibraryExportTests {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized
    static let tools = repository.appendingPathComponent("TestSupport/BackupChecker")
    static let now = Date(timeIntervalSince1970: 1_780_000_000)

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryExport-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Stock AntennaPod 3.12.1's statistics of an exported file (`android_statistics.py`, never Swift code).
    func android(_ file: URL, from: Int64 = 0, to: Int64 = .max) throws -> ContractJSON {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", Self.tools.appendingPathComponent("android_statistics.py").path, file.path,
                             "--from", String(from), "--to", String(to), "--now", String(Int64(Self.now.timeIntervalSince1970 * 1000))]
        let pipe = Pipe(), errors = Pipe()
        process.standardOutput = pipe; process.standardError = errors
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
        return try ContractJSON.decode(output)
    }

    /// A standalone library whose first episode carries two statistics units (equal and zero last-played dates),
    /// is queued, a favorite and has chapters.
    struct Library {
        let directory: URL
        let url: URL
        let store: FeedLibraryStore
        let feed: LibraryFeed
        let episodes: [Int64]
    }

    func library() async throws -> Library {
        let directory = try folder()
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let feed = try await store.insert(ServerLibraryFixture.fetched(count: 3))
        let episodes = feed.episodes.map(\.id).sorted()
        let played = Int64(1_775_000_000_000)
        try await store.updateEpisode(id: episodes[0]) { episode in
            episode.userState.playState = .played
            episode.userState.playedDurationMilliseconds = 30_000
            episode.userState.lastPlayedTimeMilliseconds = played
            episode.userState.lastPlayedHistoryMilliseconds = played
            episode.details.chapters = [ParsedChapter(startMilliseconds: 0, title: "Intro"), ParsedChapter(startMilliseconds: 1_000, title: "Two")]
        }
        try await store.setFavorite(episodeID: episodes[0], favorite: true)
        _ = try await store.enqueue([episodes[0], episodes[2]])
        // An equal last-played date (the episode's own row must still win the reimport tie) and a never-played row.
        try RawLibrary.insertUnit(url, episode: episodes[0], unit: "imp/11", played: 200_000, lastPlayed: played, history: played,
                                  duration: 600_000, isPlayed: false, position: 5_000)
        try RawLibrary.insertUnit(url, episode: episodes[0], unit: "imp/12", played: 0, lastPlayed: 0, duration: 600_000, isPlayed: true)
        return Library(directory: directory, url: url, store: store, feed: feed, episodes: episodes)
    }

    @Test func unitsBecomeStockRowsThatStockAndroidCountsLikeThePhone() async throws {
        let library = try await library()
        defer { try? FileManager.default.removeItem(at: library.directory) }
        let identity = try await library.store.libraryIdentity().identity
        let source = try await LibraryExport.collect(identity: identity, root: library.directory,
            open: .init(store: library.store, identity: identity, speeds: .init()), vault: MemoryCredentialVault(), gate: LibraryGate())
        let file = library.directory.appendingPathComponent("export.db")
        try source.databaseData().write(to: file)
        // For a check on the Android 3.12.1 emulator: `NTP_INTEROP_OUT=<file>` keeps a copy of this export.
        if let out = ProcessInfo.processInfo.environment["NTP_INTEROP_OUT"] {
            try? FileManager.default.removeItem(atPath: out)
            try FileManager.default.copyItem(at: file, to: URL(fileURLWithPath: out))
        }
        let stock = try android(file)

        // Statistics: every per-podcast value and every month, with "include marked as played" off and on.
        let input = try await library.store.statisticsLibrary()
        for (key, marked) in [("feeds", false), ("feeds_marked", true)] {
            let phone = try #require(try LibraryStatistics(feeds: input.feeds, units: input.units, includeMarkedAsPlayed: marked, now: Self.now).feeds.first)
            let row = try #require(stock[key]?.arrayValue?.first)
            #expect(row["num_episodes"]?.integerValue == phone.episodes)
            #expect(row["episodes_started"]?.integerValue == phone.episodesStarted)
            #expect((row["played_time"]?.integerValue ?? -1) / 1000 == phone.playedSeconds)
            #expect((row["total_time"]?.integerValue ?? -1) / 1000 == phone.totalSeconds)
            #expect(((row["num_recent_unplayed"]?.integerValue ?? 0) > 0) == phone.hasRecentUnplayed)
        }
        #expect(stock["feeds"]?.arrayValue?.first?["num_episodes"]?.integerValue == 5)
        let years = YearsStatisticsSnapshot(feeds: input.feeds, units: input.units)
        #expect(stock["months"]?.arrayValue?.map { [$0["year"]?.integerValue, $0["month"]?.integerValue, $0["played"]?.integerValue] }
                == years.monthly.map { [Int64($0.year), Int64($0.month), $0.playedMilliseconds] })

        // IDs: units above every local episode ID, the episode's own item above its units', its media keeping its ID.
        let rows = try #require(stock["episodes"]?.arrayValue)
        let first = library.episodes[0], maxLocal = library.episodes.max()!
        let own = try #require(rows.first { $0["media"]?.integerValue == first })
        let ownItem = try #require(own["item"]?.integerValue)
        let units = rows.filter { ($0["media"]?.integerValue ?? 0) > maxLocal }
        #expect(units.count == 2)
        #expect(units.allSatisfy { ($0["item"]?.integerValue ?? 0) > maxLocal && ($0["item"]?.integerValue ?? .max) < ownItem })
        #expect(units.allSatisfy { $0["guid"]?.stringValue == own["guid"]?.stringValue && $0["title"]?.stringValue == own["title"]?.stringValue })
        #expect(Set(units.compactMap { $0["read"]?.integerValue }) == [0, 1])
        #expect(units.contains { $0["played"]?.integerValue == 200_000 && $0["position"]?.integerValue == 5_000 && $0["history"]?.integerValue == own["last_played"]?.integerValue })
        // Every reference to the episode names its own item; nothing dangles; unit rows are in no queue or favorites.
        let references = try #require(stock["references"])
        #expect(references["queue"]?.arrayValue?.first?.integerValue == ownItem)
        #expect(references["queue"]?.arrayValue?.last?.integerValue == library.episodes[2])
        #expect(references["favorites"]?.arrayValue?.compactMap(\.integerValue) == [ownItem])
        #expect(references["chapters"]?.arrayValue?.compactMap(\.integerValue) == [ownItem])
        #expect(references["dangling"]?.integerValue == 0)
        #expect(stock["tables"]?.arrayValue?.compactMap(\.stringValue).contains { $0.hasPrefix("ntp_") || $0 == "statistics_units" } == false)
        try await library.store.close()
    }

    /// The reimport rule (the server's import, `S/internal/ops/import.go:318-327`): the most recently played row is the state row, on
    /// a tie the higher item ID. The episode's own row wins every tie the export writes.
    @Test func theEpisodesOwnRowWinsEveryReimportTie() async throws {
        let library = try await library()
        defer { try? FileManager.default.removeItem(at: library.directory) }
        let file = library.directory.appendingPathComponent("export.db")
        try await AndroidDatabaseBackup.data(library: library.store, speeds: .init(), credentials: { _ in nil }).write(to: file)
        let rows = try #require(try android(file)["episodes"]?.arrayValue).filter { $0["guid"]?.stringValue == "guid-1" }
        let state = rows.max { left, right in
            let l = left["last_played"]?.integerValue ?? 0, r = right["last_played"]?.integerValue ?? 0
            return l == r ? (left["item"]?.integerValue ?? 0) < (right["item"]?.integerValue ?? 0) : l < r
        }
        #expect(state?["media"]?.integerValue == library.episodes[0])
        try await library.store.close()
    }

    /// A standalone library (kept at logout, or a previous library) exports exact values, never refused,
    /// even when a unit was played later than its episode (a wrong clock); a server library refuses such a file.
    @Test func theLastPlayedCheckAppliesToServerLibrariesOnly() async throws {
        let library = try await library()
        defer { try? FileManager.default.removeItem(at: library.directory) }
        try RawLibrary.insertUnit(library.url, episode: library.episodes[1], unit: "imp/20", played: 1_000, lastPlayed: 4_000_000_000_000, duration: 1_000)
        let contents = try await library.store.exportContents()
        let standalone = LibraryExportSource(contents: contents, speeds: .init(), credentials: [:])
        let file = library.directory.appendingPathComponent("skew.db")
        try standalone.databaseData().write(to: file)
        #expect(try android(file)["episodes"]?.arrayValue?.contains { $0["last_played"]?.integerValue == 4_000_000_000_000 } == true)
        var server = contents
        server.serverLibrary = true
        #expect(throws: AndroidDatabaseBackup.Failure.unitAfterEpisode(episodeID: library.episodes[1])) {
            try LibraryExportSource(contents: server, speeds: .init(), credentials: [:]).databaseData()
        }
        try await library.store.close()
    }

    /// A refused server-library file shows the existing export error with no wording of
    /// its own, and the server library's sync log records the cause and the episode's ID, never a payload. A
    /// standalone library has no sync log to write to.
    @Test func aRefusedServerLibraryExportIsRecordedInItsSyncLog() async throws {
        let fixture = try await ServerLibraryFixture()
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (feed, _, _) = try await fixture.subscribeRegistered()
        let episode = try #require(feed.episodes.map(\.id).min())
        try RawLibrary.insertUnit(fixture.url, episode: episode, unit: "imp/20", played: 1_000, lastPlayed: 4_000_000_000_000, duration: 1_000)
        let identity = fixture.identity.libraryID
        let syncLog = try #require(LibraryLocation(root: root, reference: .server(identity)).syncDatabase)
        _ = try ServerArchive(url: syncLog)
        let before = try ServerArchive(url: syncLog).logEntries().count
        let source = try await LibraryExport.collect(identity: identity, root: root,
            open: .init(store: fixture.store, identity: identity, speeds: .init()), vault: MemoryCredentialVault(), gate: LibraryGate())
        #expect(source.syncLog == syncLog)
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        do {
            _ = try source.databaseData(now: now)
            Issue.record("the file was not refused")
        } catch {
            #expect(error as? AndroidDatabaseBackup.Failure == .unitAfterEpisode(episodeID: episode))
            #expect(error.localizedDescription.isEmpty)
            // The automatic backup reports the same empty detail, so only its existing label shows.
            #expect(AutomaticDatabaseExport.Failure.other(error.localizedDescription).errorDescription == "")
        }
        let entries = try ServerArchive(url: syncLog).logEntries()
        #expect(entries.count == before + 1)
        let entry = try #require(entries.first)
        #expect(entry.kind == "export")
        #expect(entry.time == 1_780_000_000_000)
        #expect(entry.detail.contains("episode \(episode) "))
        #expect(!entry.detail.contains("imp/20") && !entry.detail.contains("4000000000000") && !entry.detail.contains("Show"))
        await fixture.close()

        // A standalone library: no sync log, and nothing is created for it.
        let standalone = try await library()
        defer { try? FileManager.default.removeItem(at: standalone.directory) }
        let ownIdentity = try await standalone.store.libraryIdentity().identity
        let own = try await LibraryExport.collect(identity: ownIdentity, root: standalone.directory,
            open: .init(store: standalone.store, identity: ownIdentity, speeds: .init()), vault: MemoryCredentialVault(), gate: LibraryGate())
        #expect(own.syncLog == nil)
        try await standalone.store.close()
    }

    /// The log entry goes only into a server library's existing sync log: a missing file is never created.
    @Test func theSyncLogHookNeverCreatesAFile() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Server Libraries/x/sync.sqlite")
        ServerArchive.append(to: url, kind: "export", now: Date(), detail: "refused")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    /// An inactive library is read through the read-only reader, found by its identity; its credentials and per-feed
    /// speeds come from that library, never from the open one.
    @Test func anInactiveLibraryExportsItsOwnRowsCredentialsAndSpeeds() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        // The library in the root folder: inactive, with a credential and a per-feed speed of its own.
        let vault = MemoryCredentialVault()
        let standalone = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let feed = try await standalone.insert(ServerLibraryFixture.fetched(title: "Own"))
        try await FeedAuthentication(store: standalone, vault: vault).save(.init(username: "own", password: "secret"), feedID: feed.id)
        let identity = try await standalone.libraryIdentity().identity
        try await standalone.close()
        var speeds = PlaybackSpeedPreferences()
        speeds.feeds[feed.id] = 1.75
        try JSONEncoder().encode(speeds).write(to: root.appendingPathComponent("playback-speed-preferences.json"))
        // The open library: a server library whose feed has the same local ID and other values.
        let server = LibraryLocation(root: root, reference: .server(ContractIdentity.randomUUID()))
        try server.prepare()
        let open = try FeedLibraryStore(url: server.database)
        _ = try await open.insert(ServerLibraryFixture.fetched(title: "Server"))
        let openIdentity = try await open.libraryIdentity().identity
        var openSpeeds = PlaybackSpeedPreferences()
        openSpeeds.feeds[feed.id] = 2.5
        let source = try await LibraryExport.collect(identity: identity, root: root,
            open: .init(store: open, identity: openIdentity, speeds: openSpeeds), vault: vault, gate: LibraryGate())
        #expect(source.feeds.map(\.title) == ["Own"])
        #expect(source.credentials[feed.id] == FeedCredentials(username: "own", password: "secret"))
        #expect(source.speeds.feeds[feed.id] == 1.75)
        // The open library is read through its open store.
        let own = try await LibraryExport.collect(identity: openIdentity, root: root,
            open: .init(store: open, identity: openIdentity, speeds: openSpeeds), vault: vault, gate: LibraryGate())
        #expect(own.feeds.map(\.title) == ["Server"] && own.speeds.feeds[feed.id] == 2.5)
        // A library that no longer exists ends the export with the export error.
        await #expect(throws: LibraryExportError.libraryNotFound) {
            try await LibraryExport.collect(identity: ContractIdentity.randomUUID(), root: root, open: nil, vault: vault, gate: LibraryGate())
        }
        try await open.close()
    }

    /// The source collection holds the gate; an exclusive holder (Keep, removal) waits for it, and an
    /// export waits for an exclusive holder.
    @Test func sourceCollectionAndExclusiveHoldersExcludeEachOther() async throws {
        let gate = LibraryGate()
        await gate.acquireExclusive()
        let library = try await library()
        defer { try? FileManager.default.removeItem(at: library.directory) }
        let identity = try await library.store.libraryIdentity().identity
        let finished = Mutex(false)
        let export = Task {
            let source = try await LibraryExport.collect(identity: identity, root: library.directory,
                open: .init(store: library.store, identity: identity, speeds: .init()), vault: MemoryCredentialVault(), gate: gate)
            finished.withLock { $0 = true }
            return source
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(finished.withLock { $0 } == false)
        gate.releaseExclusive()
        _ = try await export.value
        #expect(!gate.isHeld)
        // Shared holders admit no exclusive holder until they release.
        await gate.acquireShared()
        #expect(!gate.tryAcquireExclusive())
        let exclusive = Task { await gate.acquireExclusive(); gate.releaseExclusive() }
        for _ in 0..<50 { await Task.yield() }
        gate.releaseShared()
        await exclusive.value
        try await library.store.close()
    }
}
#endif
