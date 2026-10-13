#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// An Android 3.12.1 backup restored on iOS and exported again,
/// and the same library after a person's edits on iOS, gives Android back exactly the user state
/// Android would hold. The verdict comes from the independent Python oracle
/// `TestSupport/BackupChecker/check_edit_roundtrip.py`, which never reads Swift code:
/// it applies each scenario step to the Android file the way Android 3.12.1 writes it (cited per
/// step) and compares both files under Android's read semantics (`normalize.py`).
///
/// The iOS side uses the app's own paths: `AndroidDatabaseRestore.read` + `installRestoredLibrary`
/// + Keychain credential save + restore journal (AppDelegate.importDatabase / applyRestoreJournal),
/// each edit through the store call its control makes, and `AndroidDatabaseBackup.data` (the manual
/// and automatic export payload).
@MainActor @Suite(.serialized) struct AndroidBackupRoundTripOracleTests {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../..").standardized
    static let fixtures = repository.appendingPathComponent("TestSupport/Data/database-restore")
    static let tools = repository.appendingPathComponent("TestSupport/BackupChecker")
    static let scenario = fixtures.appendingPathComponent("gap-data/edit-scenario.json")

    struct Scenario: Decodable { let source: String; let steps: [Step] }
    /// One user action; field names follow the scenario file (Android enum names for choices).
    struct Step: Decodable {
        let action: String
        var episode: Int64?, feed: Int64?, index: Int?
        var position: Int32?, duration: Int32?, at: Int64?, sampleAt: Int64?, endAt: Int64?, bytes: Int?
        var customTitle: String?, autoDownload: String?, keepUpdated: Bool?, autoDelete: String?
        var newEpisodesAction: String?, volumeAdaptation: String?, skipIntro: Int32?, skipEnding: Int32?
        var episodeNotification: Bool?, includeFilter: String?, excludeFilter: String?, minimalDuration: Int?
        var values: [String]?, order: String?, speed: Float?, skipSilence: String?
        var username: String?, password: String?, tags: [String]?
    }

    /// The restored library as the app holds it after Database import and the restart.
    struct Library {
        let store: FeedLibraryStore
        let authentication: FeedAuthentication
        let speeds: PlaybackSpeedPreferenceStore
        let directory: URL
    }

    func temp() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GAP-DATA-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// AppDelegate.importDatabase (staging, install, credentials) then applyRestoreJournal.
    func restore(_ backup: URL, in directory: URL) async throws -> Library {
        let restored = try AndroidDatabaseRestore.read(backup, staging: directory.appendingPathComponent("staging", isDirectory: true))
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let authentication = FeedAuthentication(store: store, vault: OracleVault())
        try await store.installRestoredLibrary(restored, carrying: try await store.restoreCarryOver())
        for (feedID, value) in restored.credentials.sorted(by: { $0.key < $1.key }) { try await authentication.save(value, feedID: feedID) }
        let speeds = try PlaybackSpeedPreferenceStore(file: directory.appendingPathComponent("speed.json"))
        let journal = try #require(try await store.pendingRestoreJournal())
        try speeds.restore(feeds: journal.feedSpeeds, silence: journal.feedSilence)
        try await store.clearRestoreJournal()
        return Library(store: store, authentication: authentication, speeds: speeds, directory: directory)
    }

    /// The Database export payload (LibraryViewController.databaseExportFlow, AutomaticDatabaseExport).
    func export(_ library: Library) async throws -> URL {
        let authentication = library.authentication
        let data = try await AndroidDatabaseBackup.data(library: library.store, speeds: library.speeds.value) {
            try await authentication.credentials(feedID: $0)
        }
        let url = library.directory.appendingPathComponent("AntennaPodBackup.db")
        try data.write(to: url)
        return url
    }

    /// Runs the independent oracle; its printed per-field diff is the failure message.
    func oracle(android: URL, ios: URL, scenario: URL?) throws -> (status: Int32, output: String) {
        try python("check_edit_roundtrip.py", [android.path, ios.path] + (scenario.map { ["--scenario", $0.path] } ?? []))
    }

    /// One of the Python tools, with the macOS system Python 3 (Xcode toolchain).
    func python(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-B", Self.tools.appendingPathComponent(tool).path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    struct MissingScenarioValue: Error, CustomStringConvertible { let description: String }
    /// A scenario field or lookup the step needs; missing values fail the test with their name.
    func need<T>(_ value: T?) throws -> T {
        guard let value else { throw MissingScenarioValue(description: "scenario value missing: \(T.self)") }
        return value
    }

    private func date(_ milliseconds: Int64?) throws -> Date {
        Date(timeIntervalSince1970: Double(try need(milliseconds)) / 1000)
    }

    /// Each step through the store call the app's control makes (cited per case).
    func perform(_ step: Step, on library: Library) async throws {
        let store = library.store
        switch step.action {
        case "removeFromInbox": // Episode menu Remove from inbox (LibraryViewController+EpisodeActions:370)
            try await store.removeEpisodeFromInbox(episodeID: try need(step.episode))
        case "markPlayed", "markUnplayed": // Episode menu Mark as played/unplayed (EpisodeActions:380)
            try await store.markEpisodePlayed(episodeID: try need(step.episode), played: step.action == "markPlayed")
        case "addFavorite", "removeFavorite": // Episode menu favorites (EpisodeActions:377)
            try await store.setFavorite(episodeID: try need(step.episode), favorite: step.action == "addFavorite")
        case "moveInQueue": // Queue drag (LibraryViewController+Queue:131)
            let captured = try await store.queue().map(QueueEpisodeIdentity.init)
            let result = try await store.performQueueMove(.item(try need(step.episode), finalIndex: try need(step.index)), expected: captured)
            #expect(result.status == .moved)
        case "removeFromQueue": // Episode menu Remove from queue (EpisodeActions:374)
            _ = try await store.removeFromQueue([try need(step.episode)])
        case "addToQueue": // Episode menu Add to queue (EpisodeActions:375)
            _ = try await store.enqueueUsingSettings([try need(step.episode)])
        case "playToEnd": // PlaybackCoordinator: start, last saved sample, natural end
            let session = try await store.beginPlayback(episodeID: try need(step.episode))
            _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: try need(step.position),
                durationMilliseconds: try need(step.duration), status: .playing), now: try date(step.sampleAt))
            #expect(try await store.endPlayback(sessionID: session.id, reason: .ended, now: try date(step.endAt))?.markedPlayed == true)
        case "playAndPause": // PlaybackCoordinator: start, pause saves the position
            let session = try await store.beginPlayback(episodeID: try need(step.episode))
            _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: try need(step.position),
                durationMilliseconds: try need(step.duration), status: .paused), now: try date(step.at))
        case "download": // DownloadCoordinator.request (Enqueue downloaded on, back) and a finished transfer
            let now = try date(step.at)
            let folder = library.directory.appendingPathComponent("media", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let job = try need(try await store.requestDownload(episodeID: try need(step.episode), directory: folder,
                                                                    enqueue: true, location: .back, now: now))
            let attempt = try need(try await store.beginDownloadAttempt(id: job.id, now: now))
            try Data(repeating: 0x41, count: try need(step.bytes)).write(to: attempt.destination)
            #expect(try await store.attachDownloadFile(id: job.id, attempt: attempt.attempts))
            #expect(try await store.completeDownload(id: job.id, attempt: attempt.attempts, now: now))
        case "feedPreferences": // Feed settings rows (LibraryViewController+FeedSettings writeFeedPreference)
            let autoDownload = try need(Self.autoDownload[try need(step.autoDownload)])
            let autoDelete = try need(Self.autoDelete[try need(step.autoDelete)])
            let action = try need(Self.newEpisodes[try need(step.newEpisodesAction)])
            let volume = try need(Self.volume[try need(step.volumeAdaptation)])
            let skip = FeedSkipPreferences(introSeconds: try need(step.skipIntro), endingSeconds: try need(step.skipEnding))
            let filter = AutomaticDownloadFilter(include: try need(step.includeFilter), exclude: try need(step.excludeFilter),
                                                 minimumDurationSeconds: try need(step.minimalDuration))
            let title = step.customTitle, keep = try need(step.keepUpdated), notify = try need(step.episodeNotification)
            try await store.updatePreferences(feedID: try need(step.feed)) {
                $0.customTitle = title; $0.autoDownload = autoDownload; $0.keepUpdated = keep; $0.autoDelete = autoDelete
                $0.newEpisodesAction = action; $0.volumeAdaptation = volume; $0.skip = skip
                $0.showEpisodeNotification = notify; $0.automaticDownloadFilter = filter
            }
        case "episodeFilter": // Feed episode filter dialog (FeedFilterEditor)
            try await store.setEpisodeFilter(feedID: try need(step.feed), filter: FeedEpisodeFilter(values: try need(step.values)))
        case "sortOrder": // Feed sort dialog
            try await store.setFeedEpisodeSortOrder(feedID: try need(step.feed), order: try need(Self.sort[try need(step.order)]))
        case "playbackSpeed": // Feed settings playback speed (FeedSettings:42)
            try library.speeds.setFeed(try need(step.feed), speed: try need(step.speed),
                                       skipSilence: try need(Self.silence[try need(step.skipSilence)]))
        case "credentials": // Feed settings authentication
            try await library.authentication.save(.init(username: step.username, password: step.password), feedID: try need(step.feed))
        case "tags": // Tag dialog (FeedSettings:205)
            let tags = try need(step.tags)
            try await store.updatePreferences(feedID: try need(step.feed)) { $0.tags = tags }
        case "archive": // Remove podcast dialog Archive (LibraryViewController+Feed:245)
            try await store.updatePreferences(feedID: try need(step.feed)) { $0.subscriptionState = .archived }
        case "subscribePreview": // Preview Subscribe (LibraryViewController+AddPodcast:427)
            #expect(try await store.subscribePreview(feedID: try need(step.feed)))
        case "restoreArchived": // Archived feed header Restore (LibraryViewController+Feed:74)
            try await store.updatePreferences(feedID: try need(step.feed)) { $0.subscriptionState = .subscribed }
        case "removeAllFromInbox": // Inbox menu Remove all from inbox (LibraryViewController+EpisodeLists:106)
            _ = try await store.removeAllFromInbox()
        default:
            Issue.record("unknown scenario action \(step.action)")
        }
    }

    // Android enum names (model/feed/*.java) to the iOS choices a person picks, by meaning.
    static let autoDownload: [String: FeedAutoDownload] = ["DISABLED": .disabled, "GLOBAL": .global, "ENABLED": .enabled]
    static let autoDelete: [String: FeedAutoDelete] = ["GLOBAL": .global, "ALWAYS": .always, "NEVER": .never]
    static let newEpisodes: [String: NewEpisodesAction] = ["GLOBAL": .global, "ADD_TO_INBOX": .inbox, "NOTHING": .nothing, "ADD_TO_QUEUE": .queue]
    static let volume: [String: FeedVolumeAdaptation] = ["OFF": .off, "LIGHT_REDUCTION": .lightReduction, "HEAVY_REDUCTION": .heavyReduction,
                                                         "LIGHT_BOOST": .lightBoost, "MEDIUM_BOOST": .mediumBoost, "HEAVY_BOOST": .heavyBoost]
    static let silence: [String: PlaybackSilencePreference] = ["OFF": .off, "GLOBAL": .global, "AGGRESSIVE": .aggressive]
    static let sort: [String: FeedEpisodeSortOrder] = ["DATE_OLD_NEW": .dateOldest, "DATE_NEW_OLD": .dateNewest,
        "EPISODE_TITLE_A_Z": .titleAscending, "EPISODE_TITLE_Z_A": .titleDescending, "DURATION_SHORT_LONG": .durationShortest,
        "DURATION_LONG_SHORT": .durationLongest, "EPISODE_FILENAME_A_Z": .filenameAscending, "EPISODE_FILENAME_Z_A": .filenameDescending,
        "SIZE_SMALL_LARGE": .sizeSmallest, "SIZE_LARGE_SMALL": .sizeLargest, "GLOBAL_DEFAULT": .global]

    /// Restore -> export, unedited: every real Android 3.12.1 library comes back field for field
    /// (subscriptions and their settings, tags, credentials, played/new flags, positions, history,
    /// statistics, favorites, queue order, chapters, download log). Replaces the earlier row-count check.
    @Test(arguments: ["first-journey-downloaded.db", "emulator-parity-library.db", "authentication-preview-library.db",
                      "archived-credentials-library.db"])
    func restoredLibraryExportsTheSameAndroidState(_ name: String) async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let android = Self.fixtures.appendingPathComponent("android-3.12.1/\(name)")
        let library = try await restore(android, in: directory)
        let exported = try await export(library)
        try await library.store.close()
        let result = try oracle(android: android, ios: exported, scenario: nil)
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("EQUAL"))
    }

    /// An older Android backup (0.8 … 3.8.0) imported on iOS and exported gives the state Android 3.12.1's
    /// own Database import produced from the same file on the emulator (`android-3.12.1-upgraded/`).
    @Test(arguments: ["v1-0.8", "v8-0.9.5.1", "v12-0.9.8.3", "v14-1.0", "v15-1.2", "v1030002-1.3", "v1040013-1.4.1.4",
                      "v1050004-1.5.0.8", "v1060596-1.7.0", "v1070401-1.8.0", "v1090001-2.0.1", "v2030000-2.3.0",
                      "v2060000-2.6.1", "v3040000-3.4.0", "v3050000-3.5.0", "v3080000-3.8.0"])
    func olderBackupExportsWhatAndroidUpgradeHolds(_ name: String) async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let library = try await restore(Self.fixtures.appendingPathComponent("older-versions/\(name).db"), in: directory)
        let exported = try await export(library)
        try await library.store.close()
        let result = try oracle(android: Self.fixtures.appendingPathComponent("android-3.12.1-upgraded/\(name).db"), ios: exported, scenario: nil)
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("EQUAL"))
    }

    /// Restore -> a person's edits on iOS -> export: Android gets exactly the state its own writers
    /// would have produced for the same actions (played/new flags, positions, favorites, queue order,
    /// feed settings, speed and silence, credentials, tags, download, statistics and history,
    /// archive and preview subscribe).
    @Test func editedLibraryExportsWhatAndroidWouldHold() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let scenario = try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: Self.scenario))
        #expect(scenario.steps.count >= 20)
        let android = Self.fixtures.appendingPathComponent(scenario.source)
        let library = try await restore(android, in: directory)
        for step in scenario.steps { try await perform(step, on: library) }
        let exported = try await export(library)
        try await library.store.close()
        let result = try oracle(android: android, ios: exported, scenario: Self.scenario)
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("steps: \(scenario.steps.count);") && result.output.contains("EQUAL"))
    }
}

/// The drawer Queue/Inbox/Subscriptions counters, the bottom
/// navigation Inbox badge and the per-feed counters follow Android's counting rules — NEW episodes of
/// archived and not-subscribed (preview) feeds never count — before and after mark played, remove from
/// inbox, archive (unsubscribe), restore and preview subscribe. Android's numbers come from
/// `navigation_counters.py`, which runs the SQL text of DBReader/PodDBAdapter on the Android file.
@MainActor @Suite(.serialized) struct NavigationCountersOracleTests {
    let shared = AndroidBackupRoundTripOracleTests()
    static let actions = AndroidBackupRoundTripOracleTests.fixtures.appendingPathComponent("gap-data/counter-actions.json")
    static let expected = AndroidBackupRoundTripOracleTests.fixtures.appendingPathComponent("gap-data/counter-expected.json")
    static let settings: [String: FeedCounter] = ["SHOW_NEW": .showNew, "SHOW_UNPLAYED": .showUnplayed, "SHOW_DOWNLOADED": .showDownloaded,
                                                 "SHOW_DOWNLOADED_UNPLAYED": .showDownloadedUnplayed, "SHOW_NONE": .showNone]

    private func json(_ data: Data) throws -> [String: Any] { try shared.need(try JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func states(_ object: [String: Any]) throws -> [[String: Any]] { try shared.need(object["states"] as? [[String: Any]]) }

    /// The recorded oracle the view and UI tests read is what the Android SQL gives today.
    @Test func recordedCountersAreCurrent() throws {
        let source = AndroidBackupRoundTripOracleTests.fixtures.appendingPathComponent("gap-data/counter-states.db")
        let result = try shared.python("navigation_counters.py", [source.path, "--scenario", Self.actions.path])
        #expect(result.status == 0, "\(result.output)")
        let live = try json(Data(result.output.utf8)), recorded = try json(Data(contentsOf: Self.expected))
        #expect(NSDictionary(dictionary: live) == NSDictionary(dictionary: recorded), "regenerate counter-expected.json")
    }

    /// Restore the Android library, then after every action: the iOS counters equal Android's for the
    /// same state, and Android reading the iOS export would count the same.
    @Test func countersMatchAndroidAfterEveryAction() async throws {
        let directory = try shared.temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let scenario = try JSONDecoder().decode(AndroidBackupRoundTripOracleTests.Scenario.self, from: Data(contentsOf: Self.actions))
        let expected = try states(try json(Data(contentsOf: Self.expected)))
        try #require(expected.count == scenario.steps.count + 1)
        let library = try await shared.restore(AndroidBackupRoundTripOracleTests.fixtures.appendingPathComponent(scenario.source), in: directory)
        for (index, oracle) in expected.enumerated() {
            if index > 0 { try await shared.perform(scenario.steps[index - 1], on: library) }
            let stage = index == 0 ? "restored" : "after \(scenario.steps[index - 1].action)"
            let snapshot = try await library.store.snapshot()
            let entry = try shared.need(oracle["subscriptions_entry"] as? [String: Int])
            let perFeed = try shared.need(oracle["feed_counters"] as? [String: [String: Int]])
            for (name, setting) in Self.settings {
                let counters = NavigationCounters(feeds: snapshot.feeds, queueLength: snapshot.queue.count, counter: setting)
                #expect(counters.inbox == oracle["inbox"] as? Int, "\(stage): Inbox row and badge")
                #expect(counters.queue == oracle["queue"] as? Int, "\(stage): Queue row")
                #expect(counters.subscriptions == entry[name], "\(stage): Subscriptions row, \(name)")
                let feeds = Dictionary(uniqueKeysWithValues: (perFeed[name] ?? [:]).map { (Int64($0.key)!, $0.value) })
                #expect(SubscriptionListQueries.counters(snapshot.feeds, setting) == feeds, "\(stage): feed counters, \(name)")
            }
            // Android reading the exported library shows the same numbers.
            let exported = try await shared.export(library)
            let readBack = try shared.python("navigation_counters.py", [exported.path])
            #expect(readBack.status == 0, "\(readBack.output)")
            var android = try states(try json(Data(readBack.output.utf8)))[0]; android["after"] = nil
            var recorded = oracle; recorded["after"] = nil
            #expect(NSDictionary(dictionary: android) == NSDictionary(dictionary: recorded), "\(stage): Android counts of the iOS export")
            try FileManager.default.removeItem(at: exported)
        }
        try await library.store.close()
    }
}

/// In-memory Keychain stand-in (the app uses KeychainSynchronizationCredentials).
private final class OracleVault: SynchronizationCredentialStore, Sendable {
    private let values = Mutex<[UUID: String]>([:])
    func insert(_ password: String, id: UUID) throws { values.withLock { $0[id] = password } }
    func password(id: UUID) throws -> String {
        guard let value = values.withLock({ $0[id] }) else { throw CocoaError(.fileNoSuchFile) }
        return value
    }
    func remove(id: UUID) throws { _ = values.withLock { $0.removeValue(forKey: id) } }
}
#endif
