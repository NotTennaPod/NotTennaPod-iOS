import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Download-log retention, the attempt budget and background transfer assembly, against the
/// independent oracle (built from the Android 3.12.1 source:
/// `PodDBAdapter.clearOldDownloadLog`, `DatabaseMaintenanceWorker`, `EpisodeDownloadWorker`, WorkManager
/// 2.10.3). Expected values come from `TestSupport/Data/background-work/expected/background-work.json`.
@Suite(.serialized) struct BackgroundWorkTests {
    static let evidence = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../TestSupport/Data").standardized
    static func json(_ path: String) throws -> [String: Any] {
        // The oracle records Android's surrogate-splitting title truncation as a lone `\ud83c` escape,
        // which Foundation rejects; it is not used here (messages are not part of these checks).
        let text = try String(contentsOf: evidence.appendingPathComponent(path), encoding: .utf8)
            .replacingOccurrences(of: #"\\ud[89ab][0-9a-f]{2}(?!\\ud[c-f])"#, with: #"\\ufffd"#, options: [.regularExpression, .caseInsensitive])
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }
    static var cases: [String: Any] { try! json("background-work/background-cases.json") }
    static var expected: [String: Any] { try! json("background-work/expected/background-work.json") }

    private func temp() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundWork-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }

    /// A library with one feed per title, each with one episode, for native log rows.
    private func library(_ directory: URL, feeds: [String]) async throws -> (FeedLibraryStore, [String: Int64]) {
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        var ids: [String: Int64] = [:]
        for (index, title) in feeds.enumerated() {
            let source = "https://example.test/feed-\(index)"
            let feed = ParsedFeed(format: .rss, title: title, episodes: [
                ParsedEpisode(identifier: "e\(index)", title: title, media: .init(url: "https://example.test/media-\(index)", size: 100))])
            ids[title] = try await store.insert(.init(feed: feed, source: source, responseURL: URL(string: source)!,
                                                      validator: nil, permanentRedirectURL: nil)).id
        }
        return (store, ids)
    }

    /// A media attempt log row at `milliseconds` (a failed attempt, as the source writes one per attempt).
    private func mediaRow(_ store: FeedLibraryStore, episodeID: Int64, directory: URL, at milliseconds: Int64,
                          success: Bool) async throws {
        let job = try #require(try await store.requestDownload(episodeID: episodeID, directory: directory, now: date(milliseconds)))
        _ = try #require(try await store.beginDownloadAttempt(id: job.id, now: date(milliseconds)))
        if success {
            try Data("media".utf8).write(to: job.destination)
            #expect(try await store.attachDownloadFile(id: job.id, attempt: 1))
            #expect(try await store.completeDownload(id: job.id, attempt: 1, now: date(milliseconds)))
        } else {
            _ = try #require(try await store.recordDownloadFailure(id: job.id, attempt: 1, failure: .http(404), now: date(milliseconds)))
        }
    }

    // MARK: - Retention

    @Test func androidBackupLogKeepsSourceBoundariesNullDatesAndOrderAndExportsNullBack() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        // A real Android 3.12.1 backup whose DownloadLog is replaced by the oracle's boundary rows.
        let backup = directory.appendingPathComponent("boundary.db")
        try FileManager.default.copyItem(at: Self.evidence.appendingPathComponent("database-restore/android-3.12.1/first-journey-downloaded.db"),
                                         to: backup)
        let rows = (Self.cases["download_log"] as! [String: Any])["rows"] as! [[String: Any]]
        let sqlite = try BackupSQLite(url: backup, create: false, writable: true)
        try sqlite.execute("DELETE FROM DownloadLog")
        for row in rows {
            let completion: BackupSQLite.Value = (row["completion_date"] as? NSNumber).map { .integer($0.int64Value) } ?? .null
            try sqlite.execute("INSERT INTO DownloadLog (id,feedfile,feedfile_type,reason,successful,completion_date,reason_detailed,title) VALUES (?,?,?,?,?,?,?,?)", [
                .integer((row["id"] as! NSNumber).int64Value), .integer((row["feedfile"] as! NSNumber).int64Value),
                .integer((row["feedfile_type"] as! NSNumber).int64Value), .integer((row["reason"] as! NSNumber).int64Value),
                .integer((row["successful"] as! NSNumber).int64Value), completion,
                .text(row["reason_detailed"] as? String), .text(row["title"] as? String)])
        }
        try sqlite.close()
        let restored = try AndroidDatabaseRestore.read(backup, staging: directory.appendingPathComponent("staging"))
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try await store.installRestoredLibrary(restored, carrying: try await store.restoreCarryOver())
        let oracle = Self.expected["download_log"] as! [String: Any]
        let titles = Dictionary(uniqueKeysWithValues: rows.map { (($0["id"] as! NSNumber).intValue, $0["title"] as! String) })
        let deleted = try await store.pruneDownloadLog(beforeMilliseconds: (oracle["cutoff_ms"] as! NSNumber).int64Value)
        #expect(deleted == (oracle["deleted"] as! [Int]).count)
        let log = try await store.downloadLog()
        #expect(Set(log.compactMap(\.title)) == Set((oracle["kept"] as! [Int]).map { titles[$0]! }))
        // Display order: newest first, the tie in either order, the NULL date last.
        let groups = (oracle["visible"] as! [[Int]]).map { Set($0.map { titles[$0]! }) }
        var remaining = log.compactMap(\.title)
        for group in groups {
            #expect(Set(remaining.prefix(group.count)) == group)
            remaining.removeFirst(group.count)
        }
        // A NULL source date stays NULL when exported again.
        let export = directory.appendingPathComponent("export.db")
        let snapshot = try await store.snapshot()
        try AndroidDatabaseBackup.write(.init(feeds: snapshot.feeds, queue: [], downloadLog: log), to: export)
        let exported = try BackupSQLite(url: export, create: false)
        let nulls = try exported.rows("SELECT title FROM DownloadLog WHERE completion_date IS NULL")
        #expect(nulls.count == 1)
        if case .text(let title)? = nulls.first?.first { #expect(title == "NULL completion_date") }
        try exported.close()
        try await store.close()
    }

    @Test func nativeFeedAndMediaHistoryUseTheSameCutoffAndKeepTransferJobs() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let rows = ((Self.cases["download_log"] as! [String: Any])["rows"] as! [[String: Any]]).filter { $0["completion_date"] is NSNumber }
        let (store, ids) = try await library(directory, feeds: rows.map { $0["title"] as! String } + ["Waiting job"])
        for row in rows {
            let title = row["title"] as! String, at = (row["completion_date"] as! NSNumber).int64Value
            let feedID = try #require(ids[title])
            if (row["feedfile_type"] as! NSNumber).intValue == 0 {
                try await store.recordFailure(.httpStatus(503), feedID: feedID, date: date(at))
            } else {
                let episode = try #require(try await store.feed(id: feedID)?.episodes.first?.id)
                try await mediaRow(store, episodeID: episode, directory: directory, at: at, success: (row["successful"] as! NSNumber).intValue == 1)
            }
        }
        // A retrying job whose only log row is old: pruning removes the row, never the job or its retry.
        let waitingEpisode = try #require(try await store.feed(id: ids["Waiting job"]!)?.episodes.first?.id)
        let waiting = try #require(try await store.requestDownload(episodeID: waitingEpisode, directory: directory, now: date(0)))
        _ = try await store.beginDownloadAttempt(id: waiting.id, now: date(1_000))
        let retrying = try #require(try await store.recordDownloadFailure(id: waiting.id, attempt: 1, failure: .connection, now: date(1_000)))
        let oracle = Self.expected["download_log"] as! [String: Any]
        try await store.pruneDownloadLog(beforeMilliseconds: (oracle["cutoff_ms"] as! NSNumber).int64Value)
        let titles = Dictionary(uniqueKeysWithValues: rows.map { (($0["id"] as! NSNumber).intValue, $0["title"] as! String) })
        let kept = Set((oracle["kept"] as! [Int]).compactMap { titles[$0] })
        #expect(Set(try await store.downloadLog().compactMap(\.title)) == kept)
        var expectedJob = retrying; expectedJob.logs = []
        #expect(try await store.downloadJob(id: waiting.id) == expectedJob)
        try await store.close()
    }

    @Test func pruningBeforeTheTwoHundredCapShowsTheNewestTwoHundred() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let cap = Self.cases["download_log_cap"] as! [String: Any]
        let rows = cap["rows"] as! [[String: Any]]
        let (store, ids) = try await library(directory, feeds: ["Podcast"])
        var idByDate: [Int64: Int] = [:]
        for row in rows {
            let at = (row["completion_date"] as! NSNumber).int64Value
            idByDate[at] = (row["id"] as! NSNumber).intValue
            try await store.recordFailure(.httpStatus(503), feedID: ids["Podcast"]!, date: date(at))
        }
        let oracle = Self.expected["download_log_cap"] as! [String: Any]
        try await store.pruneDownloadLog(beforeMilliseconds: (oracle["cutoff_ms"] as! NSNumber).int64Value)
        let remaining = Set(try await store.logs(feedID: ids["Podcast"]!).map { idByDate[DatabaseMaintenance.milliseconds($0.date)]! })
        #expect(remaining == Set(oracle["kept"] as! [Int]))
        let shown = try await store.downloadLog().map { idByDate[DatabaseMaintenance.milliseconds($0.date)]! }
        #expect(shown.count == 200)
        #expect(Set(shown) == Set((oracle["kept"] as! [Int]).sorted { a, b in
            let da = rows.first { ($0["id"] as! NSNumber).intValue == a }!["completion_date"] as! NSNumber
            let db = rows.first { ($0["id"] as! NSNumber).intValue == b }!["completion_date"] as! NSNumber
            return da.int64Value > db.int64Value
        }.prefix(200)))
        try await store.close()
    }

    @Test func maintenanceDueRuleMatchesOracle() throws {
        let cases = Self.cases["maintenance_due"] as! [[String: Any]]
        let expected = Self.expected["maintenance_due"] as! [[String: Any]]
        for (input, output) in zip(cases, expected) {
            let due = DatabaseMaintenanceSchedule.isDue(lastRunMilliseconds: (input["last_run_ms"] as? NSNumber)?.int64Value,
                                                        nowMilliseconds: (input["now_ms"] as! NSNumber).int64Value)
            #expect(due == (output["due"] as! Bool), "\(input["name"]!)")
        }
    }

    /// Sixteen days of 12-hourly entries viewed daily. When the app is opened at Android's run times,
    /// the durable 3-day schedule deletes exactly what Android deletes, so every daily view matches.
    @Test func maintenanceCadenceReproducesAndroidTimeline() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let timeline = Self.cases["log_timeline"] as! [String: Any]
        let rows = timeline["rows"] as! [[String: Any]]
        let oracle = Self.expected["log_timeline"] as! [String: Any]
        let (store, ids) = try await library(directory, feeds: ["Podcast"])
        let now = Mutex<Int64>(0)
        let maintenance = DatabaseMaintenance(store: store, file: directory.appendingPathComponent("database-maintenance.json"),
                                              clock: { Date(timeIntervalSince1970: Double(now.withLock { $0 }) / 1000) })
        let runs = (oracle["android_runs"] as! [NSNumber]).map(\.int64Value)
        let views = oracle["views"] as! [[String: Any]]
        let events = (runs.map { ($0, false) } + views.map { (($0["t"] as! NSNumber).int64Value, true) }).sorted { $0.0 < $1.0 }
        var inserted = 0
        var ranAt: [Int64] = []
        for (time, isView) in events {
            // Entries become visible at their completion date.
            while inserted < rows.count, (rows[inserted]["completion_date"] as! NSNumber).int64Value <= time {
                try await store.recordFailure(.httpStatus(503), feedID: ids["Podcast"]!,
                                              date: date((rows[inserted]["completion_date"] as! NSNumber).int64Value))
                inserted += 1
            }
            now.withLock { $0 = time }
            if try await maintenance.runIfDue() != nil { ranAt.append(time) }
            guard isView else { continue }
            let view = views.first { ($0["t"] as! NSNumber).int64Value == time }!
            let log = try await store.downloadLog()
            #expect(log.count == (view["visible_count"] as! NSNumber).intValue, "day \(view["day"]!)")
            let oldest = try #require(log.last).date
            #expect(Int((Double(time) / 1000 - oldest.timeIntervalSince1970) / 3600) == (view["oldest_age_h"] as! NSNumber).intValue,
                    "day \(view["day"]!)")
        }
        #expect(ranAt == runs)
        // The schedule is durable: a relaunch within the period does not run again.
        let relaunched = DatabaseMaintenance(store: store, file: directory.appendingPathComponent("database-maintenance.json"),
                                             clock: { Date(timeIntervalSince1970: Double(runs.last! + 1_000) / 1000) })
        #expect(try await relaunched.runIfDue() == nil)
        #expect(await relaunched.lastRun == date(runs.last!))
        try await store.close()
    }

    // MARK: - Attempts (stops do not consume attempts)

    private func failure(_ reason: String) -> MediaDownloadFailure {
        switch reason {
        case "ERROR_IO_WRONG_SIZE": .wrongSize(expected: 100, received: 50)
        case "ERROR_CONNECTION_ERROR": .connection
        case "ERROR_HTTP_DATA_ERROR": .http(500)
        case "ERROR_UNKNOWN_HOST": .unknownHost
        case "ERROR_NOT_FOUND": .http(404)
        case "ERROR_UNAUTHORIZED": .http(401)
        case "ERROR_NOT_ENOUGH_SPACE": .notEnoughSpace(required: 100, available: 1)
        default: .io(nil)
        }
    }

    @Test func attemptSequencesFollowRecommendedOracle() async throws {
        let cases = Self.cases["attempts"] as! [[String: Any]]
        let expected = Self.expected["attempts"] as! [[String: Any]]
        for (input, output) in zip(cases, expected) {
            let name = input["name"] as! String
            // A malformed Content-Range makes Android's worker throw with a null reason (no log row,
            // failed at once). iOS reports it as an ordinary retryable range failure instead.
            if name.hasPrefix("malformed Content-Range") { continue }
            let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
            let (store, ids) = try await library(directory, feeds: [input["title"] as! String])
            let episode = try #require(try await store.feed(id: ids[input["title"] as! String]!)?.episodes.first?.id)
            let job = try #require(try await store.requestDownload(episodeID: episode, directory: directory, now: date(0)))
            var clock: Int64 = 1_000
            for (run, result) in zip(input["runs"] as! [[String: Any]], output["ios_recommended"] as! [[String: Any]]) {
                let label = "\(name) run \(result["run_attempt_count"]!) \(run["outcome"]!)"
                let current = try #require(try await store.downloadJob(id: job.id))
                if let retry = current.retryAt { clock = max(clock, DatabaseMaintenance.milliseconds(retry)) }
                if current.fileResetRequired == true { _ = try await store.acknowledgeDownloadFileReset(id: job.id, attempt: current.attempts) }
                let started = try #require(try await store.beginDownloadAttempt(id: job.id, now: date(clock)), "\(label)")
                #expect(started.countedAttempts - 1 == (result["run_attempt_count"] as! NSNumber).intValue, "\(label)")
                let logsBefore = try await store.downloadLog().count
                switch run["outcome"] as! String {
                case "success":
                    try Data("media".utf8).write(to: started.destination)
                    #expect(try await store.attachDownloadFile(id: job.id, attempt: started.attempts))
                    #expect(try await store.completeDownload(id: job.id, attempt: started.attempts, now: date(clock)))
                case "stopped":
                    #expect(try await store.interruptDownload(id: job.id, attempt: started.attempts, now: date(clock)))
                case "http_416":
                    _ = try await store.recordDownloadFailure(id: job.id, attempt: started.attempts, failure: .http(416), now: date(clock))
                default:
                    _ = try await store.recordDownloadFailure(id: job.id, attempt: started.attempts,
                                                              failure: failure(run["reason"] as! String), now: date(clock))
                }
                let after = try #require(try await store.downloadJob(id: job.id))
                let log = try await store.downloadLog()
                // Defect prevention (supersedes this oracle row): the last 416 is logged,
                // so the "Tap to view details." it produces opens a log that shows the episode.
                let finalRangeFailure = run["outcome"] as! String == "http_416" && result["next"] as! String == "done:failed"
                #expect((log.count > logsBefore) == (result["log_row"] is String || finalRangeFailure), "\(label) log row")
                #expect((after.fileResetRequired == true) == (result["file"] as! String == "deleted"), "\(label) file")
                let next = result["next"] as! String
                if next.hasPrefix("retry-after-ms:") {
                    #expect(after.state == .waiting, "\(label)")
                    #expect(after.retryAt == date(clock + Int64(next.dropFirst("retry-after-ms:".count))!), "\(label) delay")
                } else if next == "rerun-when-constraints-met" {
                    #expect(after.state == .waiting && after.retryAt == nil, "\(label)")
                } else if next == "done:failed" {
                    #expect(after.state == .failed, "\(label)")
                } else if next == "done:success" {
                    #expect(after.state == .completed, "\(label)")
                }
                clock += 1_000
            }
            try await store.close()
        }
    }

    // MARK: - Background transfer assembly

    private struct Transfer {
        let directory: URL
        let destination: URL
        let files: BackgroundMediaDownloads.Files
        init(_ directory: URL) throws {
            self.directory = directory
            destination = directory.appendingPathComponent("episode-1-download-1.media")
            files = .init(destination: destination)
            try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        }
        func finish(record: BackgroundMediaDownloads.TaskRecord, status: Int, url: String = "https://example.test/a.mp3",
                    headers: [String: String], body: Data) throws {
            try files.write(record)
            try body.write(to: files.body)
            try files.write(.init(status: status, url: URL(string: url), headers: headers))
        }
        var record0: BackgroundMediaDownloads.TaskRecord { .init(destination: files.key, base: 0) }
    }

    private final class Acceptance: Sendable {
        let identities = Mutex<[MediaDownloadRepresentation?]>([])
        let sizes = Mutex<[Int64]>([])
    }

    private func assemble(_ transfer: Transfer, acceptance: Acceptance = .init()) async throws -> BackgroundMediaDownloads.Assembly {
        let destination = transfer.destination
        return try await BackgroundMediaDownloads.assemble(files: transfer.files, input: .init(
            source: "https://example.test/a.mp3", destination: destination, acceptRepresentation: { identity in
                acceptance.identities.withLock { $0.append(identity) }
                acceptance.sizes.withLock { $0.append(BackgroundMediaDownloads.size(of: destination)) }
            }), capacity: { _ in .max })
    }

    @Test func fullResponseReplacesStaleBytesOnlyAfterIdentityIsSavedAgainstEmptyFile() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let transfer = try Transfer(directory)
        try Data("stale-old-representation".utf8).write(to: transfer.destination)
        let body = Data((0..<5_000).map { UInt8($0 % 251) })
        try transfer.finish(record: transfer.record0, status: 200, headers: ["Content-Length": "5000", "ETag": "\"v2\""], body: body)
        let acceptance = Acceptance()
        let bodyFile = try FileManager.default.attributesOfItem(atPath: transfer.files.body.path)[.systemFileNumber] as? Int
        guard case .finished(let result) = try await assemble(transfer, acceptance: acceptance) else {
            Issue.record("not finished"); return
        }
        #expect(try Data(contentsOf: transfer.destination) == body && result.size == 5_000)
        let published = try FileManager.default.attributesOfItem(atPath: transfer.destination.path)[.systemFileNumber] as? Int
        #expect(bodyFile != nil && published == bodyFile, "the finished body is moved into place, not copied byte by byte")
        #expect(acceptance.identities.withLock { $0 } == [MediaDownloadRepresentation(resource: URL(string: "https://example.test/a.mp3")!, entityTag: "\"v2\"", total: 5_000)])
        #expect(acceptance.sizes.withLock { $0 } == [0], "old bytes never carry the new identity")
        #expect(transfer.files.finishedResponse() == nil && transfer.files.taskRecord() == nil)
    }

    @Test func rangeContinuationAppendsOnlyMatchingIdentity() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let transfer = try Transfer(directory)
        let full = Data((0..<10_000).map { UInt8($0 % 253) })
        try full.prefix(4_000).write(to: transfer.destination)
        let record = BackgroundMediaDownloads.TaskRecord(destination: transfer.files.key, base: 4_000,
            resource: URL(string: "https://example.test/a.mp3"), entityTag: "\"v1\"", total: 10_000)
        try transfer.finish(record: record, status: 206, headers: ["Content-Range": "bytes 4000-9999/10000", "ETag": "\"v1\""],
                            body: full.suffix(6_000))
        guard case .finished(let result) = try await assemble(transfer) else { Issue.record("not finished"); return }
        #expect(try Data(contentsOf: transfer.destination) == full && result.representation?.total == 10_000)
    }

    @Test func rangeWithChangedIdentityRestartsWithoutTouchingThePrefix() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let transfer = try Transfer(directory)
        let prefix = Data(repeating: 7, count: 4_000)
        try prefix.write(to: transfer.destination)
        let record = BackgroundMediaDownloads.TaskRecord(destination: transfer.files.key, base: 4_000,
            resource: URL(string: "https://example.test/a.mp3"), entityTag: "\"v1\"", total: 10_000)
        try transfer.finish(record: record, status: 206, headers: ["Content-Range": "bytes 4000-9999/10000", "ETag": "\"v2\""],
                            body: Data(repeating: 9, count: 6_000))
        guard case .restartFull = try await assemble(transfer) else { Issue.record("mixed representations accepted"); return }
        #expect(try Data(contentsOf: transfer.destination) == prefix)
    }

    @Test func shortBodyFailsAndErrorStatusesAndSmallTextAreNotPublished() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let transfer = try Transfer(directory)
        try Data().write(to: transfer.destination)
        try transfer.finish(record: transfer.record0, status: 200, headers: ["Content-Length": "5000"], body: Data(count: 3_000))
        await #expect(throws: MediaDownloadError.wrongSize(expected: 5_000, received: 3_000)) { try await assemble(transfer) }
        #expect(BackgroundMediaDownloads.size(of: transfer.destination) == 0)
        try transfer.finish(record: transfer.record0, status: 404, headers: [:], body: Data("missing".utf8))
        await #expect(throws: MediaDownloadError.httpStatus(404)) { try await assemble(transfer) }
        try transfer.finish(record: transfer.record0, status: 200, headers: ["Content-Type": "text/html", "Content-Length": "9"],
                            body: Data("<html/>ab".utf8))
        await #expect(throws: MediaDownloadError.fileType) { try await assemble(transfer) }
        #expect(BackgroundMediaDownloads.size(of: transfer.destination) == 0)
    }

    @Test func firstPartialRangeIsMovedIntoPlaceAndLaterPartsAppend() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let transfer = try Transfer(directory)
        let full = Data((0..<6_000).map { UInt8($0 % 241) })
        try Data("stale".utf8).write(to: transfer.destination)
        try transfer.finish(record: transfer.record0, status: 206, headers: ["Content-Range": "bytes 0-1999/6000", "ETag": "\"v1\""],
                            body: full.prefix(2_000))
        let acceptance = Acceptance()
        guard case .continueFrom(let identity) = try await assemble(transfer, acceptance: acceptance) else { Issue.record("not continued"); return }
        #expect(acceptance.sizes.withLock { $0 } == [0], "old bytes never carry the new identity")
        #expect(try Data(contentsOf: transfer.destination) == full.prefix(2_000) && identity.total == 6_000)
        let record = BackgroundMediaDownloads.TaskRecord(destination: transfer.files.key, base: 2_000,
            resource: identity.resource, entityTag: identity.entityTag, total: 6_000)
        try transfer.finish(record: record, status: 206, headers: ["Content-Range": "bytes 2000-5999/6000", "ETag": "\"v1\""],
                            body: full.suffix(4_000))
        guard case .finished(let result) = try await assemble(transfer) else { Issue.record("not finished"); return }
        #expect(try Data(contentsOf: transfer.destination) == full && result.size == 6_000)
        #expect(transfer.files.finishedResponse() == nil)
    }

    @Test func partialAnswerToOpenRangeContinuesFromVerifiedBytes() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let transfer = try Transfer(directory)
        try Data(repeating: 1, count: 1_000).write(to: transfer.destination)
        let record = BackgroundMediaDownloads.TaskRecord(destination: transfer.files.key, base: 1_000,
            resource: URL(string: "https://example.test/a.mp3"), entityTag: "\"v1\"", total: 5_000)
        try transfer.finish(record: record, status: 206, headers: ["Content-Range": "bytes 1000-2999/5000", "ETag": "\"v1\""],
                            body: Data(repeating: 2, count: 2_000))
        guard case .continueFrom(let identity) = try await assemble(transfer) else { Issue.record("not continued"); return }
        #expect(identity.total == 5_000 && BackgroundMediaDownloads.size(of: transfer.destination) == 3_000)
    }

    // MARK: - Engine choice and background time

    @Test func backgroundSessionOnlyForRequestsItReproduces() {
        let plain = MediaDownloadRequest(source: "https://example.test/a.mp3", destination: URL(fileURLWithPath: "/tmp/a"))
        #expect(MediaDownloadRouter.usesBackgroundSession(plain, proxyConfigured: false))
        #expect(!MediaDownloadRouter.usesBackgroundSession(plain, proxyConfigured: true), "every download uses the configured proxy")
        var login = plain; login.credentials = FeedCredentials(username: "user", password: "secret")
        #expect(!MediaDownloadRouter.usesBackgroundSession(login, proxyConfigured: false))
        let userInfo = MediaDownloadRequest(source: "https://user:secret@example.test/a.mp3", destination: URL(fileURLWithPath: "/tmp/a"))
        #expect(!MediaDownloadRouter.usesBackgroundSession(userInfo, proxyConfigured: false))
        var empty = plain; empty.credentials = FeedCredentials(username: "", password: "")
        #expect(MediaDownloadRouter.usesBackgroundSession(empty, proxyConfigured: false))
    }

    // MARK: - Orphaned background transfers

    /// A background-session task as the system lists it after a launch.
    private final class ListedTask: ReconciledTransfer {
        let taskIdentifier: Int
        let taskDescription: String?
        let state: URLSessionTask.State
        private(set) var cancelled = false
        init(_ id: Int, _ description: String?, state: URLSessionTask.State = .running) {
            taskIdentifier = id; taskDescription = description; self.state = state
        }
        convenience init(_ id: Int, destination: URL, state: URLSessionTask.State = .running) {
            let key = BackgroundMediaDownloads.Files(destination: destination).key
            self.init(id, BackgroundMediaDownloads.describe(.init(destination: key, base: 0)), state: state)
        }
        func cancel() { cancelled = true }
    }

    /// Transfers left by an earlier run, a finished download or another library are cancelled; the task
    /// of a download that is still active is kept for its job to adopt.
    @Test func reconcileCancelsTransfersOfNoCurrentDownloadAndKeepsActiveOnes() async throws {
        let directory = try temp()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, _) = try await library(directory, feeds: ["Running", "Finished"])
        let media = directory.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let running = try #require(try await store.requestDownload(episodeID: 1, directory: media))
        try await mediaRow(store, episodeID: 2, directory: media, at: 1_000, success: true)
        let finished = try #require(try await store.downloadJobs(activeOnly: false).first { $0.episodeID == 2 })
        let kept = ListedTask(1, destination: running.destination)
        let keptWaiting = ListedTask(2, destination: running.destination, state: .suspended)
        let ofFinished = ListedTask(3, destination: finished.destination)
        let otherLibrary = ListedTask(4, destination: URL(fileURLWithPath: "/private/var/UITests-other/media/episode-1-download-1.media"))
        let unreadable = ListedTask(5, "not a transfer record")
        let undescribed = ListedTask(6, nil)
        let alreadyEnded = ListedTask(7, destination: finished.destination, state: .completed)
        let ending = ListedTask(8, destination: finished.destination, state: .canceling)
        let tasks = [kept, keptWaiting, ofFinished, otherLibrary, unreadable, undescribed, alreadyEnded, ending]
        let downloads = BackgroundMediaDownloads(identifier: "org.nottennapod.app.tests.\(UUID().uuidString)")
        let cancelled = try await downloads.reconcile(tasks) { try await store.downloadJobs(activeOnly: true).map(\.destination) }
        #expect(cancelled == 4)
        let cancelledIDs = tasks.filter { $0.cancelled }.map { $0.taskIdentifier }
        #expect(cancelledIDs == [3, 4, 5, 6])
        #expect(!kept.cancelled && !keptWaiting.cancelled, "the active download's transfer stays for the background resume")
        try await store.close()
    }

    /// After a database import the replaced library's downloads no longer exist (the restored library
    /// has no download jobs): every earlier transfer goes, so none can hold a connection.
    @Test func reconcileAfterLibraryReplacementCancelsEveryEarlierTransfer() async throws {
        let directory = try temp()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["before", "restored"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        }
        let (before, _) = try await library(directory.appendingPathComponent("before", isDirectory: true), feeds: ["A", "B"])
        let media = directory.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        var tasks: [ListedTask] = []
        for id: Int64 in [1, 2] {
            let job = try #require(try await before.requestDownload(episodeID: id, directory: media))
            tasks.append(ListedTask(Int(id), destination: job.destination))
        }
        try await before.close()
        let (restored, _) = try await library(directory.appendingPathComponent("restored", isDirectory: true), feeds: ["A", "B"])
        let downloads = BackgroundMediaDownloads(identifier: "org.nottennapod.app.tests.\(UUID().uuidString)")
        let cancelled = try await downloads.reconcile(tasks) { try await restored.downloadJobs().map(\.destination) }
        #expect(cancelled == 2)
        let allCancelled = tasks.allSatisfy { $0.cancelled }
        #expect(allCancelled)
        // A new download in the restored library is kept by the next reconciliation.
        let fresh = try #require(try await restored.requestDownload(episodeID: 1, directory: media))
        let next = ListedTask(9, destination: fresh.destination)
        let again = try await downloads.reconcile([next]) { try await restored.downloadJobs().map(\.destination) }
        #expect(again == 0)
        #expect(!next.cancelled)
        try await restored.close()
    }

    /// When the library cannot be read nothing is cancelled (the app retries at the next activation).
    @Test func reconcileCancelsNothingWhenTheLibraryCannotBeRead() async throws {
        let task = ListedTask(1, destination: URL(fileURLWithPath: "/tmp/media/episode-1-download-1.media"))
        let downloads = BackgroundMediaDownloads(identifier: "org.nottennapod.app.tests.\(UUID().uuidString)")
        await #expect(throws: FeedLibraryError.self) {
            try await downloads.reconcile([task]) { throw FeedLibraryError.closed }
        }
        #expect(!task.cancelled)
    }

    private final class HeldTransfer: MediaTransferring {
        let started = Mutex(0)
        func download(_ input: MediaDownloadRequest,
                      progress: @escaping @Sendable (MediaDownloadProgress) -> Void) async throws -> MediaDownloadResult {
            started.withLock { $0 += 1 }
            try await Task.sleep(for: .seconds(600))
            return .init(destination: input.destination, size: 0, validator: nil)
        }
    }

    @Test func endOfBackgroundTimeInterruptsForegroundTransfersUntilActiveAgain() async throws {
        let held = HeldTransfer()
        let router = MediaDownloadRouter(foreground: held, background: nil, userAgent: "AntennaPod/test", proxyConfigured: { true })
        let request = MediaDownloadRequest(source: "https://example.test/a.mp3", destination: URL(fileURLWithPath: "/tmp/a"))
        let first = Task { try await router.download(request) { _ in } }
        while held.started.withLock({ $0 }) == 0 { await Task.yield() }
        router.pauseForegroundTransfers()
        await #expect(throws: DownloadNetworkInterruption.self) { try await first.value }
        let second = Task { try await router.download(request) { _ in } }
        try await Task.sleep(for: .milliseconds(200))
        #expect(held.started.withLock { $0 } == 1, "no new foreground transfer while paused")
        router.resumeForegroundTransfers()
        while held.started.withLock({ $0 }) == 1 { await Task.yield() }
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
    }
}
