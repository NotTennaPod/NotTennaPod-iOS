import Foundation
import Synchronization
import Testing
import UserNotifications
@testable import NotTennaPodCore

/// Settings → Notifications and download-failure delivery. Expected values come from the Android oracle
/// `TestSupport/Data/notifications-settings/expected/notifications.json` (its `ios` layer applies the
/// iOS adaptation and defect preventions), never from the Swift code. No test needs notification
/// permission: the notification center is a recording double, and what is checked is what the app hands over.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)))
struct NotificationsTests {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized
    static func json(_ path: String) -> [String: Any] {
        // The oracle records Android's surrogate-splitting truncation as a lone `\ud83c` escape, which
        // Foundation rejects. Only Android-layer messages contain it; the iOS layer checked here does not.
        guard let text = try? String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8) else { return [:] }
        let valid = text.replacingOccurrences(of: #"\\ud[89ab][0-9a-f]{2}(?!\\ud[c-f])"#, with: #"\\ufffd"#,
                                              options: [.regularExpression, .caseInsensitive])
        return (try? JSONSerialization.jsonObject(with: Data(valid.utf8))) as? [String: Any] ?? [:]
    }
    static var oracle: [String: Any] { json("TestSupport/Data/notifications-settings/expected/notifications.json") }
    static var scenarios: [String: Any] { json("TestSupport/Data/notifications-settings/notification-scenarios.json") }
    /// The app's English strings, read from the repository (the host package has no app bundle).
    static var appStrings: [String: String] {
        NSDictionary(contentsOf: repository.appendingPathComponent("App/Resources/en.lproj/Localizable.strings")) as? [String: String] ?? [:]
    }
    /// Android's value (`%1$s` in Java format) for a string of the oracle.
    static func android(_ key: String) -> String {
        ((oracle["strings"] as? [String: Any])?[key] as? [String: Any])?["value"] as? String ?? "<missing \(key)>"
    }
    static let text = DownloadErrorDelivery.Text(
        retrying: android("download_error_retrying").replacingOccurrences(of: "%1$s", with: "%1$@"),
        notRetrying: android("download_error_not_retrying").replacingOccurrences(of: "%1$s", with: "%1$@"),
        notificationTitle: android("episode_download_failed"), notificationBody: android("download_error_tap_for_details"))

    /// Records what is handed to the system, with its replace-by-identifier rule.
    final class RecordingCenter: SynchronizationNotificationCenter {
        var status: UNAuthorizationStatus
        var posted: [UNNotificationRequest] = []
        var shown: [String: UNNotificationRequest] = [:]
        init(_ status: UNAuthorizationStatus = .authorized) { self.status = status }
        func authorizationStatus() async -> UNAuthorizationStatus { status }
        func post(_ request: UNNotificationRequest) async throws { posted.append(request); shown[request.identifier] = request }
        func removePendingNotificationRequests(withIdentifiers identifiers: [String]) { identifiers.forEach { shown[$0] = nil } }
        func removeDeliveredNotifications(withIdentifiers identifiers: [String]) { identifiers.forEach { shown[$0] = nil } }
    }
    static func status(_ name: String) -> UNAuthorizationStatus {
        switch name {
        case "authorized": .authorized
        case "provisional": .provisional
        case "denied": .denied
        default: .notDetermined
        }
    }

    // MARK: - Wording

    /// Every string shown here is Android's English (value from the oracle, which checked it against strings.xml).
    @Test func appWordingIsAndroidWording() throws {
        let keys = ["notification_pref_fragment", "notification_group_errors", "notification_channel_download_error",
                    "notification_channel_download_error_description", "notification_channel_sync_error",
                    "notification_channel_sync_error_description", "download_error_details", "download_error_retrying",
                    "download_error_not_retrying", "download_error_tap_for_details", "episode_download_failed",
                    "gpodnetsync_error_title", "gpodnetsync_error_descr"]
        try #require(!Self.appStrings.isEmpty && Self.oracle["strings"] != nil)
        for key in keys {
            let expected = Self.android(key).replacingOccurrences(of: "%1$s", with: "%1$@")
            #expect(Self.appStrings[key] == expected, "\(key)")
        }
    }

    // MARK: - Preferences and screen

    /// `settings_screens`: composition, defaults, the sync row's enable rule and the login/logout reset.
    @Test func screenStatesFollowOracle() throws {
        let inputs = try #require(Self.scenarios["settings_screens"] as? [[String: Any]])
        let expected = try #require(Self.oracle["settings_screens"] as? [[String: Any]])
        try #require(inputs.count == 5 && inputs.count == expected.count)
        for (input, output) in zip(inputs, expected) {
            let name = input["name"] as! String
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("M30Prefs-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("notification-preferences.json")
            let store = try NotificationPreferenceStore(file: file)
            let first = UUID()
            // The person's choices are made while the first account is selected.
            let prefs = input["prefs"] as! [String: Bool]
            if let download = prefs["prefShowDownloadReport"] { try store.setDownloadFailed(download) }
            if let sync = prefs["pref_gpodnet_notifications"] { try store.setSynchronizationFailed(sync, account: first) }
            let account: UUID? = switch input["event"] as? String {
            case "logout": nil
            case "login": UUID()
            default: (input["provider_connected"] as! Bool) ? first : nil
            }
            // Saved data, read back independently of the live store.
            let reopened = try NotificationPreferenceStore(file: file).value
            #expect(reopened == store.value, "\(name)")
            #expect(Self.appStrings[NotificationSettingsComposition.titleKey] == output["title"] as? String, "\(name)")
            let category = try #require((output["categories"] as? [[String: Any]])?.first)
            #expect(Self.appStrings[NotificationSettingsComposition.categoryKey] == category["title"] as? String, "\(name)")
            let rows = try #require(category["rows"] as? [[String: Any]])
            #expect(NotificationSettingsComposition.rows.map(\.key) == rows.map { $0["key"] as! String }, "\(name) order")
            for (row, oracle) in zip(NotificationSettingsComposition.rows, rows) {
                #expect(Self.appStrings[row.titleKey] == oracle["title"] as? String, "\(name) \(row.key)")
                #expect(Self.appStrings[row.summaryKey] == oracle["summary"] as? String, "\(name) \(row.key)")
                #expect(NotificationSettingsComposition.isOn(row.key, reopened, synchronizationAccount: account)
                        == oracle["checked"] as? Bool, "\(name) \(row.key) checked")
                #expect(NotificationSettingsComposition.isEnabled(row.key, synchronizationAccount: account)
                        == oracle["enabled"] as? Bool, "\(name) \(row.key) enabled")
            }
        }
    }

    /// Defaults On; the saved file keeps Android's key names; a missing file or key reads as On.
    @Test func defaultsAndSavedKeys() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("M30Keys-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notification-preferences.json")
        let store = try NotificationPreferenceStore(file: file)
        #expect(store.value.downloadFailed && store.value.synchronizationFailedEnabled(account: UUID()))
        let account = UUID()
        try store.setDownloadFailed(false)
        try store.setSynchronizationFailed(false, account: account)
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(saved["prefShowDownloadReport"] as? Bool == false && saved["pref_gpodnet_notifications"] as? Bool == false)
        #expect(!store.value.synchronizationFailedEnabled(account: account))
        try Data("{}".utf8).write(to: file)
        let empty = try NotificationPreferenceStore(file: file).value
        #expect(empty.downloadFailed && empty.synchronizationFailed)
    }

    /// Backup failures in the background: "Synchronization failed" Off drops the notification;
    /// without permission the text still waits for the next activation, whatever the switch (Android's Toast).
    @Test func backupFailureFollowsSynchronizationSwitch() {
        let account = UUID()
        var value = NotificationPreferences()
        #expect(value.backupFailureDelivery(authorized: true, account: account) == .notification)
        #expect(value.backupFailureDelivery(authorized: false, account: account) == .pendingMessage)
        value.synchronizationFailed = false; value.synchronizationAccount = account
        #expect(value.backupFailureDelivery(authorized: true, account: account) == .nothing)
        #expect(value.backupFailureDelivery(authorized: false, account: account) == .pendingMessage)
        // After logout (or with another account) the switch is On again.
        #expect(value.backupFailureDelivery(authorized: true, account: nil) == .notification)
        #expect(value.backupFailureDelivery(authorized: true, account: UUID()) == .notification)
    }

    // MARK: - Download failures through the real download owner

    /// One transfer outcome per attempt, as named in the scenario fixture.
    private final class ScriptedTransfer: MediaTransferring {
        private let outcomes: Mutex<[String]>
        init(_ outcomes: [String]) { self.outcomes = Mutex(outcomes) }
        func download(_ input: MediaDownloadRequest,
                      progress: @escaping @Sendable (MediaDownloadProgress) -> Void) async throws -> MediaDownloadResult {
            let outcome = outcomes.withLock { $0.isEmpty ? "success" : $0.removeFirst() }
            if outcome.hasPrefix("http:") { throw MediaDownloadError.httpStatus(Int(outcome.dropFirst(5))!) }
            switch outcome {
            case "success":
                let body = Data(repeating: 7, count: 1_024)
                try body.write(to: input.destination)
                return MediaDownloadResult(destination: input.destination, size: Int64(body.count), validator: nil)
            case "cancel": throw URLError(.cancelled)
            case "error:ERROR_IO_BLOCKED": throw URLError(.appTransportSecurityRequiresSecureConnection)
            case "error:ERROR_CONNECTION_ERROR": throw URLError(.cannotConnectToHost)
            case "error:ERROR_UNKNOWN_HOST": throw URLError(.cannotFindHost)
            case "error:ERROR_NOT_ENOUGH_SPACE": throw MediaDownloadError.notEnoughSpace(required: 1_000, available: 1)
            default: throw URLError(.unknown)
            }
        }
    }

    private struct Run {
        let foreground: Bool
        let messages: [String]
        let notifications: [[String: Any]]
        let logEntries: Int
        let result: String
    }

    /// Runs the scenario's attempts through `DownloadCoordinator` and its worker/store (retry spacing is skipped
    /// by a clock that moves two minutes per reading) and returns every failure report it published.
    private func reports(title: String?, url: String, outcomes: [String]) async throws -> (reports: [DownloadFailureReport], logs: Int, state: LibraryDownloadJob.State?) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("M30Downloads-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try FeedLibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        do {
            let episode = ParsedEpisode(identifier: "m30", title: title, media: ParsedMedia(url: url, size: 1_024, durationMilliseconds: 30_000))
            let feed = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "M30 podcast", episodes: [episode]),
                source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
            let network = DownloadNetworkMonitor(startMonitoring: false)
            network.update(.init(connected: true, metered: false, cellular: false))
            let ticks = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
            let coordinator = DownloadCoordinator(store: store, directory: folder.appendingPathComponent("media"),
                transfer: ScriptedTransfer(outcomes), network: network,
                clock: { ticks.withLock { $0 += 120; return $0 } })
            var collected: [DownloadFailureReport] = []
            let events = coordinator.events()
            let listener = Task { @MainActor in
                for await event in events { if case .attemptFailed(let report) = event { collected.append(report) } }
            }
            _ = try await coordinator.request(episodeID: feed.episodes[0].id)
            let failures = outcomes.filter { $0.hasPrefix("http:") || $0.hasPrefix("error:") }.count
            let deadline = ContinuousClock.now + .seconds(30)
            var job: LibraryDownloadJob?
            while ContinuousClock.now < deadline {
                job = try await store.downloadJobs(activeOnly: false).first
                if collected.count >= failures, let job, !job.state.isActive || outcomes.last == "cancel" { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            await coordinator.stop()
            listener.cancel()
            let logs = try await store.downloadLog().count
            try await store.close()
            return (collected, logs, job?.state)
        } catch { try? await store.close(); throw error }
    }

    /// Every download scenario of the oracle: the message of each attempt, the notification of the last one
    /// (for each "Download failed" × authorization case), the Download log entries and the end state.
    @Test func downloadScenariosFollowOracle() async throws {
        let inputs = try #require(Self.scenarios["download_scenarios"] as? [[String: Any]])
        let outputs = try #require(Self.oracle["download"] as? [[String: Any]])
        try #require(inputs.count == 31 && outputs.count == inputs.count)
        var replayed = 0
        for (input, output) in zip(inputs, outputs) {
            let name = input["name"] as! String
            let runs = (output["ios"] as! [[String: Any]]).map { run in
                Run(foreground: run["foreground"] as! Bool, messages: (run["messages"] as! [[String: Any]]).map { $0["text"] as! String },
                    notifications: run["notification_requests"] as! [[String: Any]], logEntries: run["log_entries"] as! Int,
                    result: run["result"] as! String)
            }
            let outcomes = (input["runs"] as! [[String: Any]]).map { $0["outcome"] as! String }
            let title = input["title"] as? String, url = input["download_url"] as! String
            var failures: [DownloadFailureReport]
            if outcomes.contains("throw") {
                // Android's `Downloader.call()` throwing has no iOS counterpart (every transfer error maps to
                // a download failure); its delivery is checked with the report such a failure produces.
                failures = [DownloadFailureReport(jobID: 1, episodeID: 1, title: title ?? url, failure: .io(nil), retrying: false)]
            } else {
                let result = try await reports(title: title, url: url, outcomes: outcomes)
                failures = result.reports
                replayed += 1
                #expect(result.logs == runs.map(\.logEntries).reduce(0, +), "\(name) Download log entries")
                switch runs.last?.result {
                case "failure": #expect(result.state == .failed, "\(name)")
                case "success" where outcomes.last == "success": #expect(result.state == .completed, "\(name)")
                default: break
                }
            }
            // One report per failed attempt, retried exactly when the oracle says the attempt is retried.
            let failedRuns = runs.filter { $0.result != "success" }
            #expect(failures.map(\.retrying) == failedRuns.map { $0.result == "retry" }, "\(name) attempts")
            #expect(failures.allSatisfy { $0.title == (title ?? url) }, "\(name) request title")
            for cell in output["ios_delivery"] as! [[String: Any]] {
                let label = "\(name) switch \(cell["toggle_on"]!) \(cell["authorization"]!)"
                let center = RecordingCenter(Self.status(cell["authorization"] as! String))
                var shown: [String] = []
                var foreground = false
                let delivery = DownloadErrorDelivery(center: center, text: Self.text, enabled: { cell["toggle_on"] as! Bool },
                                                     foreground: { if foreground { shown.append($0) }; return foreground })
                for (report, run) in zip(failures, failedRuns) {
                    foreground = run.foreground
                    let before = shown.count
                    await delivery.deliver(report)
                    #expect(Array(shown[before...]) == run.messages, "\(label) messages")
                }
                let requested = failedRuns.contains { !$0.notifications.isEmpty }
                #expect(!center.posted.isEmpty == (cell["notification_delivered"] as! Bool), "\(label) notification")
                if !center.posted.isEmpty {
                    #expect(requested, "\(label)")
                    let expected = try #require(failedRuns.last { !$0.notifications.isEmpty }?.notifications.first)
                    #expect(center.posted.allSatisfy { $0.content.title == expected["title"] as? String
                        && $0.content.body == expected["text"] as? String }, "\(label) text")
                    // One fixed identity: the system shows one notification however many failures there were.
                    #expect(center.shown.count == 1 && center.shown[DownloadErrorDelivery.identifier] != nil, "\(label)")
                }
            }
        }
        #expect(replayed == 29)
    }

    /// Android's limits, cut only between whole characters: never a broken emoji or a stripped accent.
    @Test func shortTitleKeepsWholeCharacters() {
        #expect(DownloadErrorDelivery.shortTitle("Twenty characters!!!") == "Twenty characters!!!")
        #expect(DownloadErrorDelivery.shortTitle("Twenty-one characters") == "Twenty-one characte…")
        #expect(DownloadErrorDelivery.shortTitle("Weekly news round 🎧 part 2") == "Weekly news round …")
        let decomposed = "Episodes about cafe\u{301}s and more"
        #expect(DownloadErrorDelivery.shortTitle(decomposed) == "Episodes about caf…")
        for title in ["👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦 family", "ééééééééééééééééééééééé", "a🎧🎧🎧🎧🎧🎧🎧🎧🎧🎧🎧"] {
            let short = DownloadErrorDelivery.shortTitle(title)
            #expect(short.hasSuffix("…") && short.utf16.count <= 20 && title.hasPrefix(String(short.dropLast())), "\(title)")
        }
    }

    /// The notification the app hands over, and what a tap on it opens.
    @Test func notificationRequestAndTapRoute() {
        let request = DownloadErrorDelivery.request(text: Self.text)
        #expect(request.content.title == "Episode download failed" && request.content.body == "Tap to view details.")
        #expect(request.identifier == DownloadErrorDelivery.identifier && request.trigger == nil)
        #expect(request.content.sound != nil && request.content.interruptionLevel == .active)
        #expect(DownloadErrorDelivery.opensDownloadLog(identifier: request.identifier, category: request.content.categoryIdentifier))
        #expect(!DownloadErrorDelivery.opensDownloadLog(identifier: NativeSynchronizationNotifications.errorIdentifier,
                                                        category: NativeSynchronizationNotifications.category))
        #expect(!NativeSynchronizationNotifications.opensApplication(identifier: request.identifier, category: request.content.categoryIdentifier))
    }

    /// The last 416 is logged, so the notification's "Tap to view details." opens a log that shows the episode.
    @Test func finalRangeFailureIsLogged() async throws {
        let result = try await reports(title: "Range episode", url: "https://example.test/range.mp3",
                                       outcomes: ["http:416", "http:416", "http:416"])
        #expect(result.reports.map(\.retrying) == [true, true, false])
        #expect(result.logs == 1 && result.state == .failed)
    }

    // MARK: - Synchronization failures and the switch

    /// `sync` scenarios with the iOS rule (Android 8+ channel semantics): the in-app message is
    /// always shown; the notification needs the switch On and permission.
    @Test func synchronizationSwitchGatesOnlyTheNotification() async throws {
        let inputs = try #require(Self.scenarios["sync_scenarios"] as? [[String: Any]])
        let outputs = try #require(Self.oracle["sync"] as? [[String: Any]])
        try #require(inputs.count == 18 && outputs.count == inputs.count)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("M30Sync-\(UUID()).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) } }
        let store = try FeedLibraryStore(url: file)
        let account = UUID()
        try await store.selectSynchronizationAccount(account)
        let epoch = try await store.synchronizationState().epoch
        do {
            for (input, output) in zip(inputs, outputs) {
                let ios = output["ios"] as! [String: Any]
                for cell in ios["delivery"] as! [[String: Any]] {
                    let label = "\(input["name"]!) switch \(cell["toggle_on"]!) \(cell["authorization"]!)"
                    let center = RecordingCenter(Self.status(cell["authorization"] as! String))
                    var shown: [String] = []
                    let foreground = input["foreground"] as! Bool
                    let delivery = SynchronizationDelivery(store: store, publisher: NativeSynchronizationNotifications(center: center),
                        text: .init(errorTitle: Self.android("gpodnetsync_error_title"), errorPrefix: Self.android("gpodnetsync_error_descr")),
                        foreground: { if foreground { shown.append($0) }; return foreground },
                        notificationsEnabled: { $0 == account && cell["toggle_on"] as! Bool || $0 != account },
                        episodesChanged: { _ in })
                    try await delivery.handle(.reportError(message: input["message"] as? String ?? ""), epoch: epoch)
                    let message = (ios["message"] as? String).map { $0.trimmingCharacters(in: .whitespaces) }
                    #expect(shown.map { $0.trimmingCharacters(in: .whitespaces) } == (message.map { [$0] } ?? []), "\(label) message")
                    #expect(!center.posted.isEmpty == (cell["notification_delivered"] as! Bool), "\(label) notification")
                }
            }
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
}
