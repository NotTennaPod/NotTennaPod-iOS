import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Real Android 3.12.1 backups restore into the native library. Fixtures are databases written
/// by the Android 3.12.1 app (`TestSupport/Data/database-restore/android-3.12.1/`); expected
/// values were read from them with the sqlite3 CLI, not from the Swift reader. The complete
/// field-by-field oracle is the independent round-trip checker in `TestSupport/BackupChecker`.
@Suite(.serialized) struct AndroidDatabaseRestoreTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../TestSupport/Data/database-restore/android-3.12.1").standardized

    private func temp() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M16-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func restore(_ name: String, in directory: URL) async throws -> (AndroidDatabaseRestore.Library, FeedLibraryStore) {
        let library = try AndroidDatabaseRestore.read(Self.fixtures.appendingPathComponent(name), staging: directory.appendingPathComponent("staging"))
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try await store.installRestoredLibrary(library, carrying: try await store.restoreCarryOver())
        return (library, store)
    }

    @Test func downloadedAndroidEpisodeRestoresListeningStateAsNotDownloaded() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let (library, store) = try await restore("first-journey-downloaded.db", in: directory)
        #expect(library.sourceVersion == 3_110_000)
        let snapshot = try await store.snapshot()
        let feed = try #require(snapshot.feeds.first)
        #expect(snapshot.feeds.map(\.id) == [1] && feed.metadata.title == "Parity Listening Lab")
        #expect(feed.validator == "Sat, 12 Sep 2026 22:12:32 GMT")
        #expect(feed.lastRefreshAttempt == Date(timeIntervalSince1970: 1_789_251_211.280))
        let one = try #require(feed.episodes.first { $0.id == 1 }), two = try #require(feed.episodes.first { $0.id == 2 })
        #expect(one.userState.playState == .played && one.userState.positionMilliseconds == 3_883)
        #expect(one.userState.playedDurationMilliseconds == 33_930 && one.userState.lastPlayedTimeMilliseconds == 1_789_251_404_017)
        #expect(one.userState.lastPlayedHistoryMilliseconds == 1_789_251_404_017 && one.details.media?.durationMilliseconds == 30_040)
        #expect(!one.userState.isDownloaded && one.userState.localFileURL == nil, "D1-R: Android path never exists on iOS")
        #expect(two.userState.playState == .unplayed && two.userState.playedDurationMilliseconds == 0, "NULL played_duration reads 0")
        #expect(two.userState.lastPlayedHistoryMilliseconds == nil)
        #expect(snapshot.queue.map(\.id) == [1])
        let log = try await store.downloadLog()
        #expect(log.count == 1 && log[0].isMedia && log[0].episodeID == 1 && log[0].isSuccessful)
        #expect(log[0].title == "Second episode: queue and resume" && log[0].statusKey == "download_successful")
        try await store.close()
    }

    @Test func emulatorLibraryKeepsIdsQueueOrderPreferencesAndLog() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let (library, store) = try await restore("emulator-parity-library.db", in: directory)
        let snapshot = try await store.snapshot()
        #expect(snapshot.feeds.map(\.id).sorted() == [1, 2, 3, 4, 5, 8, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19])
        #expect(snapshot.feeds.reduce(0) { $0 + $1.episodes.count } == 58)
        #expect(snapshot.feeds.flatMap(\.episodes).filter { $0.userState.playState == .new }.count == 1)
        #expect(snapshot.feeds.flatMap(\.episodes).filter { $0.userState.playState == .played }.count == 4)
        #expect(snapshot.queue.map(\.id) == [20, 21, 22, 23, 24, 25, 26, 27, 90])
        func feed(_ id: Int64) throws -> LibraryFeed { try #require(snapshot.feeds.first { $0.id == id }) }
        #expect(try feed(1).episodeSortOrderCode == 11 && feed(1).autoDownload == .global && feed(1).tags == ["#root"])
        #expect(try feed(8).subscriptionState == .notSubscribed)
        #expect(try feed(13).autoDownload == .enabled && feed(13).automaticDownloadFilter == .init(exclude: "\"Skip\" ", minimumDurationSeconds: 0))
        #expect(try feed(17).tags == [], "Empty tag string reads as #root, stored as the native empty set")
        #expect(library.feedSpeeds.isEmpty && library.feedSilence.isEmpty, "-1.0 / GLOBAL are absent overrides")
        let log = try await store.downloadLog()
        #expect(log.count == 58)
        #expect(log.filter(\.isMedia).count == 3)
        #expect(Dictionary(grouping: log, by: \.statusKey).mapValues(\.count) == [
            "download_successful": 1, "download_error_io_error": 13, "download_error_unknown_host": 34,
            "download_error_blocked": 8, "download_error_not_found": 2])
        // New ids continue after the restored ones.
        let next = try await store.idCounters()
        #expect(next.feed == 19 && next.episode == snapshot.feeds.flatMap(\.episodes).map(\.id).max())
        try await store.close()
    }

    @Test func credentialsArchivedAndPreviewFeedsRestore() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let (library, store) = try await restore("archived-credentials-library.db", in: directory)
        let snapshot = try await store.snapshot()
        #expect(snapshot.feeds.first { $0.id == 3 }?.subscriptionState == .archived)
        #expect(snapshot.feeds.first { $0.id == 4 }?.subscriptionState == .notSubscribed)
        #expect(Set(library.credentials.keys) == [1, 2, 3, 4])
        #expect(library.credentials[1] == .init(username: "retained-user", password: "retained-password"))
        #expect(snapshot.feeds.flatMap(\.episodes).filter(\.userState.isFavorite).count == 1)
        try await store.close()
    }

    // Restore → export → Android state, field by field: AndroidBackupRoundTripOracleTests,
    // which runs the independent Python oracle on all four real Android libraries.

    /// Oracle harness (runner-only): import every `.db` in M16_ORACLE_INPUT and write the database re-export
    /// (or the rejection text) to M16_ORACLE_OUTPUT for `TestSupport/BackupChecker`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["M16_ORACLE_INPUT"] != nil))
    func oracleHarnessExportsEveryInput() async throws {
        let environment = ProcessInfo.processInfo.environment
        let input = URL(fileURLWithPath: try #require(environment["M16_ORACLE_INPUT"]))
        let output = URL(fileURLWithPath: try #require(environment["M16_ORACLE_OUTPUT"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: input.path).filter { $0.hasSuffix(".db") }.sorted()
        #expect(!names.isEmpty)
        for name in names {
            let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
            let target = output.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            let result = output.appendingPathComponent(name + ".result.txt")
            do {
                let library = try AndroidDatabaseRestore.read(input.appendingPathComponent(name), staging: directory.appendingPathComponent("s"))
                let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
                try await store.installRestoredLibrary(library, carrying: try await store.restoreCarryOver())
                let snapshot = try await store.snapshot()
                var speeds = PlaybackSpeedPreferences()
                speeds.feeds = library.feedSpeeds; speeds.silence.feeds = library.feedSilence
                let feedOf = Dictionary(uniqueKeysWithValues: snapshot.feeds.flatMap { feed in feed.episodes.map { ($0.id, feed.id) } })
                try AndroidDatabaseBackup.write(.init(feeds: snapshot.feeds,
                    queue: snapshot.queue.map { .init(episodeID: $0.id, feedID: feedOf[$0.id]!) },
                    downloadLog: try await store.downloadLog(), credentials: library.credentials, speeds: speeds), to: target)
                try await store.close()
                try "imported version \(library.sourceVersion) skipped \(library.skipped.sorted { $0.key < $1.key })\n".write(to: result, atomically: true, encoding: .utf8)
            } catch {
                try "rejected \(error)\n".write(to: result, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Older Android versions (generated from historical DDL; Android 3.12.1's own import produced
    /// `android-3.12.1-upgraded/`, which the Python oracle compares field by field).
    @Test(arguments: ["v1-0.8", "v8-0.9.5.1", "v12-0.9.8.3", "v14-1.0", "v15-1.2", "v1030002-1.3", "v1040013-1.4.1.4",
                      "v1050004-1.5.0.8", "v1060596-1.7.0", "v1070401-1.8.0", "v1090001-2.0.1", "v2030000-2.3.0",
                      "v2060000-2.6.1", "v3040000-3.4.0", "v3050000-3.5.0", "v3080000-3.8.0"])
    func olderVersionImportsLikeAndroidUpgrade(_ name: String) async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let root = Self.fixtures.deletingLastPathComponent()
        let old = try AndroidDatabaseRestore.read(root.appendingPathComponent("older-versions/\(name).db"), staging: directory.appendingPathComponent("a"))
        let upgraded = try AndroidDatabaseRestore.read(root.appendingPathComponent("android-3.12.1-upgraded/\(name).db"), staging: directory.appendingPathComponent("b"))
        #expect(old.sourceVersion == Int64(name.dropFirst().prefix { $0 != "-" }))
        #expect(upgraded.sourceVersion == 3_110_000)
        #expect(old.feeds == upgraded.feeds, "Swift upgrade equals Android's own upgrade")
        #expect(old.queue == upgraded.queue && old.credentials == upgraded.credentials)
        #expect(old.downloadLog.map(\.completion) == upgraded.downloadLog.map(\.completion))
    }

    @Test func invalidFilesAreRejectedWithSourceStyleMessages() throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        func attempt(_ data: Data) -> AndroidDatabaseRestore.Failure? {
            let file = directory.appendingPathComponent("input-\(UUID()).db")
            try? data.write(to: file)
            do { _ = try AndroidDatabaseRestore.read(file, staging: directory.appendingPathComponent("s-\(UUID())")); return nil }
            catch { return error as? AndroidDatabaseRestore.Failure }
        }
        #expect(attempt(Data()) == .invalid("file is not a database"))
        #expect(attempt(Data("<opml/>".utf8)) == .invalid("file is not a database"))
        let real = try Data(contentsOf: Self.fixtures.appendingPathComponent("first-journey-downloaded.db"))
        var newer = real; newer.replaceSubrange(60..<64, with: [0x00, 0x2F, 0x74, 0x79])  // 3110009
        #expect(attempt(newer) == .newerVersion(3_110_009))
        var zero = real; zero.replaceSubrange(60..<64, with: [0, 0, 0, 0])
        #expect(attempt(zero) == .invalid("Unsupported database version: 0"))
        let truncated = real.prefix(real.count / 2)
        guard case .invalid = attempt(Data(truncated)) else { Issue.record("Truncated file must be rejected"); return }
        // A 3.12.1-versioned file without FeedMedia.
        let missing = directory.appendingPathComponent("missing.db")
        try real.write(to: missing)
        let db = try BackupSQLite(url: missing, create: false, writable: true)
        try db.execute("DROP TABLE FeedMedia"); try db.close()
        #expect(attempt(try Data(contentsOf: missing)) == .invalid("no such table: FeedMedia"))
    }

    @Test func carryOverKeepsSynchronizationAndRetiresOldCredentialsOnlyWhenAsked() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let old = try FeedLibraryStore(url: directory.appendingPathComponent("old.sqlite"))
        try await old.stageFeedCredential(UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!)
        let carry = try await old.restoreCarryOver()
        #expect(carry.credentialIDs == [UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!])
        let library = try AndroidDatabaseRestore.read(Self.fixtures.appendingPathComponent("first-journey-downloaded.db"), staging: directory.appendingPathComponent("s"))
        let fresh = try FeedLibraryStore(url: directory.appendingPathComponent("new.sqlite"))
        try await fresh.installRestoredLibrary(library, carrying: carry)
        #expect(try await fresh.feedCredentialCleanup().isEmpty, "Nothing retires before the swap")
        try await fresh.retireReplacedCredentials(carry.credentialIDs)
        #expect(try await fresh.feedCredentialCleanup() == carry.credentialIDs)
        await #expect(throws: FeedLibraryError.invalidMutation) { try await fresh.installRestoredLibrary(library, carrying: carry) }
        try await old.close(); try await fresh.close()
    }

    @Test func clearingTheLogAlsoClearsRestoredRows() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let (_, store) = try await restore("emulator-parity-library.db", in: directory)
        #expect(try await store.downloadLog().count == 58)
        try await store.clearDownloadLog()
        #expect(try await store.downloadLog().isEmpty)
        try await store.close()
    }

    /// A failure at any swap step leaves the old library exactly as it was.
    @Test(arguments: 0..<3) func failedReplacementRollsBackAtEveryStep(_ failingMove: Int) async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let live = directory.appendingPathComponent("library.sqlite")
        let old = try FeedLibraryStore(url: live)
        try await old.stageFeedCredential(UUID())  // any live row to recognise the old library
        try await old.close()
        let before = try Data(contentsOf: live)
        let (_, staged) = try await restore("first-journey-downloaded.db", in: directory.appendingPathComponent("staged", isDirectory: true))
        try await staged.close()
        let stagedURL = directory.appendingPathComponent("staged/library.sqlite")
        let count = Mutex(0)
        await #expect(throws: CocoaError.self) {
            try await LibraryReplacement.replace(live: live, with: stagedURL, move: { from, to in
                let n = count.withLock { value in defer { value += 1 }; return value }
                if n == failingMove { throw CocoaError(.fileWriteUnknown) }
                try FileManager.default.moveItem(at: from, to: to)
            })
        }
        #expect(try Data(contentsOf: live) == before, "Old library returns unchanged")
        #expect(!FileManager.default.fileExists(atPath: live.path + ".pre-restore"))
        let reopened = try FeedLibraryStore(url: live)
        #expect(try await reopened.snapshot().feeds.isEmpty)
        try await reopened.close()
    }

    @MainActor @Test func successfulReplacementServesTheRestoredLibraryAndAppliesJournalOnce() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let live = directory.appendingPathComponent("library.sqlite")
        try await FeedLibraryStore(url: live).close()
        let staging = directory.appendingPathComponent("staged", isDirectory: true)
        let library = try AndroidDatabaseRestore.read(Self.fixtures.appendingPathComponent("first-journey-downloaded.db"), staging: staging.appendingPathComponent("s"))
        var edited = library; edited.feedSpeeds = [1: 1.75]; edited.feedSilence = [1: .aggressive]
        let staged = try FeedLibraryStore(url: staging.appendingPathComponent("library.sqlite"))
        try await staged.installRestoredLibrary(edited, carrying: try await staged.restoreCarryOver())
        try await staged.close()
        try await LibraryReplacement.replace(live: live, with: staging.appendingPathComponent("library.sqlite"))
        #expect(!FileManager.default.fileExists(atPath: live.path + ".pre-restore"))
        let store = try FeedLibraryStore(url: live)
        #expect(try await store.snapshot().feeds.map(\.id) == [1])
        #expect(try await store.pendingRestoreJournal() == .init(feedSpeeds: [1: 1.75], feedSilence: [1: .aggressive]))
        let speeds = try PlaybackSpeedPreferenceStore(file: directory.appendingPathComponent("speeds.json"))
        try speeds.activate(episodeID: 99, resolvedSpeed: 2)
        let journal = try #require(try await store.pendingRestoreJournal())
        try speeds.restore(feeds: journal.feedSpeeds, silence: journal.feedSilence)
        try await store.clearRestoreJournal()
        #expect(speeds.value.feeds == [1: 1.75] && speeds.value.silence.feeds == [1: .aggressive])
        #expect(speeds.value.currentEpisodeID == nil && speeds.value.temporary == PlaybackSpeed.useGlobal, "D4")
        #expect(try await store.pendingRestoreJournal() == nil)
        try await store.close()
    }

    @Test func interruptedReplacementRecoversAtLaunch() throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let live = directory.appendingPathComponent("library.sqlite"), backup = URL(fileURLWithPath: live.path + ".pre-restore")
        // Killed after moving the old library aside: it returns.
        try Data("old".utf8).write(to: backup)
        try LibraryReplacement.recoverInterrupted(live: live)
        #expect(try Data(contentsOf: live) == Data("old".utf8) && !FileManager.default.fileExists(atPath: backup.path))
        // Killed after the new library arrived: it stays, the old copy goes.
        try Data("new".utf8).write(to: live, options: .atomic); try Data("old".utf8).write(to: backup)
        try LibraryReplacement.recoverInterrupted(live: live)
        #expect(try Data(contentsOf: live) == Data("new".utf8) && !FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func failedStagingRemovesEveryStagedCredential() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let vault = RestoreVault()
        let staged = try FeedLibraryStore(url: directory.appendingPathComponent("staged.sqlite"))
        let library = try AndroidDatabaseRestore.read(Self.fixtures.appendingPathComponent("archived-credentials-library.db"), staging: directory.appendingPathComponent("s"))
        try await staged.installRestoredLibrary(library, carrying: try await staged.restoreCarryOver())
        let authentication = FeedAuthentication(store: staged, vault: vault)
        for (feedID, value) in library.credentials { try await authentication.save(value, feedID: feedID) }
        #expect(vault.count == 4)
        #expect(try await authentication.credentials(feedID: 1) == .init(username: "retained-user", password: "retained-password"))
        try await authentication.discardAllCredentials()
        #expect(vault.count == 0)
        #expect(try await staged.feedCredentialID(feedID: 1) == nil)
        try await staged.close()
    }

    /// The import stops every owner and closes the replaced store; any late playback,
    /// queue, download-log or refresh write from the old graph then fails instead of landing anywhere.
    @Test func lateWritesFromTheStoppedGraphFailOnTheClosedStore() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let (_, old) = try await restore("first-journey-downloaded.db", in: directory)
        try await old.close()
        try await old.close() // A second close (two owners shutting down) is harmless.
        await #expect(throws: FeedLibraryError.closed) { _ = try await old.enqueue([2]) }
        await #expect(throws: FeedLibraryError.closed) { _ = try await old.feeds() }
        await #expect(throws: FeedLibraryError.closed) { try await old.updateEpisode(id: 1) { $0.userState.positionMilliseconds = 1 } }
        await #expect(throws: FeedLibraryError.closed) { try await old.clearDownloadLog() }
        await #expect(throws: FeedLibraryError.closed) { _ = try await old.snapshot() }
        let reopened = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        #expect(try await reopened.snapshot().feeds.first?.episodes.first { $0.id == 1 }?.userState.positionMilliseconds == 3_883)
        try await reopened.close()
    }

    @Test func fundingParseFollowsFeedFunding() {
        #expect(AndroidDatabaseRestore.funding(nil) == [] && AndroidDatabaseRestore.funding("  ") == [])
        #expect(AndroidDatabaseRestore.funding("https://a") == [.init(url: "https://a", content: "")])
        #expect(AndroidDatabaseRestore.funding("https://a\u{1F}A\u{1E}null\u{1F}B\u{1E}") ==
                [.init(url: "https://a", content: "A"), .init(url: "null", content: "B")])
        #expect(AndroidDatabaseRestore.funding(" \u{1F}X\u{1E}https://b\u{1F} ") == [.init(url: "https://b", content: "")])
    }
}

private final class RestoreVault: SynchronizationCredentialStore, Sendable {
    private let values = Mutex<[UUID: String]>([:])
    var count: Int { values.withLock { $0.count } }
    func insert(_ password: String, id: UUID) throws { values.withLock { $0[id] = password } }
    func password(id: UUID) throws -> String {
        guard let value = values.withLock({ $0[id] }) else { throw CocoaError(.fileNoSuchFile) }
        return value
    }
    func remove(id: UUID) throws { _ = values.withLock { $0.removeValue(forKey: id) } }
}
