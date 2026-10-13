import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Source `AutomaticDatabaseExportWorker` naming, due rule, retention and failure handling, with
/// an injected folder and clock. Expectations are from the pinned worker.
@Suite(.serialized) struct AutomaticDatabaseExportTests {
    final class MemoryFolder: AutomaticBackupFolder, Sendable {
        struct State { var files: [String: (data: Data, modified: Date, regular: Bool)] = [:]; var failList = false
                       var failCreate = false; var failRemove: Set<String> = []; var clock = Date(timeIntervalSince1970: 2_000_000_000)
                       /// Backup-named files whose content is not a whole database, and files whose content is not on this device.
                       var incomplete: Set<String> = []; var unknown: Set<String> = []; var unreadable: Set<String> = []
                       /// The provider refuses renames; a file of this name appears just before the next rename to it.
                       var refuseRename = false; var appearsOnRename: String?
                       /// The run cancelled its coordination: nothing new starts (an accessor running finishes).
                       var cancelled = false; var operations: [String] = [] }
        let state = Mutex(State())
        /// A provider stall inside the create accessor, which ignores cancellation (`NSFileCoordinator` cannot stop it).
        let createStall = Mutex<DispatchSemaphore?>(nil), createEntered = Mutex(false)
        private func live(_ value: State) throws { if value.cancelled { throw CancellationError() } }
        func list() throws -> [AutomaticBackupFolderItem] {
            try state.withLock { value in
                try live(value)
                if value.failList { throw CocoaError(.fileReadNoPermission) }
                return value.files.map { .init(name: $0.key, isRegularFile: $0.value.regular, modified: $0.value.modified) }
            }
        }
        func create(_ name: String, data: Data) throws {
            try state.withLock { value in try live(value) }
            if let stall = createStall.withLock({ $0 }) { createEntered.withLock { $0 = true }; stall.wait() }
            try state.withLock { value in
                value.operations.append("create \(name)")
                if value.failCreate || value.files[name] != nil { throw AutomaticDatabaseExport.Failure.createFile }
                value.files[name] = (data, value.clock, true)
            }
        }
        func rename(_ name: String, to newName: String) throws {
            try state.withLock { value in
                try live(value)
                value.operations.append("rename \(name) \(newName)")
                if value.refuseRename { throw CocoaError(.fileWriteNoPermission) }
                if value.appearsOnRename == newName { value.files[newName] = (Data("someone else's".utf8), value.clock, true); value.appearsOnRename = nil }
                guard value.files[newName] == nil else { throw AutomaticDatabaseExport.Failure.nameTaken }
                guard let file = value.files.removeValue(forKey: name) else { throw CocoaError(.fileNoSuchFile) }
                value.files[newName] = file
            }
        }
        func remove(_ name: String) throws {
            try state.withLock { value in
                try live(value)
                value.operations.append("remove \(name)")
                if value.failRemove.contains(name) { throw CocoaError(.fileWriteNoPermission) }
                value.files[name] = nil
            }
        }
        func isComplete(_ name: String) throws -> Bool? {
            try state.withLock { value in
                try live(value)
                if value.unreadable.contains(name) { throw CocoaError(.fileReadNoPermission) }
                return value.unknown.contains(name) ? nil : !value.incomplete.contains(name)
            }
        }
        func cancel() { state.withLock { $0.cancelled = true } }
        func seed(_ name: String, daysAgo: Double, regular: Bool = true) {
            state.withLock { $0.files[name] = (Data("old".utf8), $0.clock.addingTimeInterval(-daysAgo * 86_400), regular) }
        }
        var names: Set<String> { state.withLock { Set($0.files.keys) } }
        func data(_ name: String) -> Data? { state.withLock { $0.files[name]?.data } }
    }
    let gmt = TimeZone(identifier: "GMT")!
    let now = Date(timeIntervalSince1970: 2_000_000_000)  // 2033-05-18 03:33:20 GMT

    @Test func filenameUsesTheLocalDateAtRunTimeWithASCIIDigits() {
        #expect(AutomaticDatabaseExport.filename(at: now, timeZone: gmt) == "NotTennaPodBackup-2033-05-18.db")
        #expect(AutomaticDatabaseExport.filename(at: now, timeZone: TimeZone(identifier: "Pacific/Kiritimati")!) == "NotTennaPodBackup-2033-05-18.db")
        #expect(AutomaticDatabaseExport.filename(at: now, timeZone: TimeZone(identifier: "America/Adak")!) == "NotTennaPodBackup-2033-05-17.db")
    }

    @Test func backupNamePatternIsTheSourceRegex() {
        for name in ["NotTennaPodBackup-2026-01-01.db", "NotTennaPodBackup-0000-99-99.db"] { #expect(AutomaticDatabaseExport.isBackupName(name), "\(name)") }
        for name in ["NotTennaPodBackup-2026-1-01.db", "NotTennaPodBackup-2026-01-01 (1).db", "nottennapodbackup-2026-01-01.db",
                     "NotTennaPodBackup-2026-01-01.db.txt", "NotTennaPodBackup-٢٠٢٦-01-01.db", "NotTennaPodBackup-2026_01-01.db", "notes.txt"] {
            #expect(!AutomaticDatabaseExport.isBackupName(name), "\(name)")
        }
    }

    @Test func dueEveryThreeDaysAfterTheLastRun() {
        #expect(AutomaticDatabaseExport.isDue(lastRun: nil, now: now))
        #expect(!AutomaticDatabaseExport.isDue(lastRun: now, now: now.addingTimeInterval(259_199)))
        #expect(AutomaticDatabaseExport.isDue(lastRun: now, now: now.addingTimeInterval(259_200)))
        #expect(AutomaticDatabaseExport.nextDue(lastRun: now.addingTimeInterval(86_400 * 30), now: now) == now.addingTimeInterval(259_200),
                "A future last run (clock moved back) counts from now")
    }

    @Test func collisionNeverOverwrites() {
        let base = "NotTennaPodBackup-2033-05-18.db"
        #expect(AutomaticDatabaseExport.uniqueName(base, existing: []) == base)
        #expect(AutomaticDatabaseExport.uniqueName(base, existing: [base]) == "NotTennaPodBackup-2033-05-18 (1).db")
        #expect(AutomaticDatabaseExport.uniqueName(base, existing: [base, "NotTennaPodBackup-2033-05-18 (1).db"]) == "NotTennaPodBackup-2033-05-18 (2).db")
    }

    @Test func retentionKeepsTheFiveNewestMatchingRegularFilesByModificationDate() async throws {
        let folder = MemoryFolder()
        // Names' dates deliberately disagree with modification order: the key is the modification date.
        for (index, name) in ["2020-01-07", "2020-01-06", "2020-01-05", "2020-01-04", "2020-01-03", "2020-01-02", "2020-01-01"].enumerated() {
            folder.seed("NotTennaPodBackup-\(name).db", daysAgo: Double(7 - index))
        }
        let unrelated = ["NotTennaPodBackup-2026-1-01.db", "NotTennaPodBackup-2026-01-01 (1).db", "nottennapodbackup-2026-01-01.db",
                         "NotTennaPodBackup-2026-01-01.db.txt", "notes.txt"]
        for name in unrelated { folder.seed(name, daysAgo: 100) }
        folder.seed("NotTennaPodBackup-2019-01-01.db", daysAgo: 200, regular: false)  // a directory with a matching name
        let name = try await AutomaticDatabaseExport.run(folder: folder, now: now, timeZone: gmt) { Data("backup".utf8) }
        #expect(name == "NotTennaPodBackup-2033-05-18.db")
        let kept = folder.names.filter { AutomaticDatabaseExport.isBackupName($0) }
        #expect(kept == [name, "NotTennaPodBackup-2020-01-01.db", "NotTennaPodBackup-2020-01-02.db", "NotTennaPodBackup-2020-01-03.db",
                         "NotTennaPodBackup-2020-01-04.db", "NotTennaPodBackup-2019-01-01.db"], "5 newest files + the untouched directory")
        #expect(Set(unrelated).isSubset(of: folder.names))
    }

    @Test func deleteFailureKeepsTheNewBackupAndReportsAfterDeletingTheRest() async throws {
        let folder = MemoryFolder()
        for day in 1...7 { folder.seed("NotTennaPodBackup-2020-01-0\(day).db", daysAgo: Double(day)) }
        folder.state.withLock { $0.failRemove = ["NotTennaPodBackup-2020-01-06.db"] }
        await #expect(throws: AutomaticDatabaseExport.Failure.deleteSome) {
            try await AutomaticDatabaseExport.run(folder: folder, now: now, timeZone: gmt) { Data("backup".utf8) }
        }
        #expect(folder.names.contains("NotTennaPodBackup-2033-05-18.db"))
        #expect(folder.names.contains("NotTennaPodBackup-2020-01-06.db") && !folder.names.contains("NotTennaPodBackup-2020-01-05.db")
                && !folder.names.contains("NotTennaPodBackup-2020-01-07.db"))
        #expect(AutomaticDatabaseExport.Failure.deleteSome.errorDescription == "Unable to delete some database backup files")
    }

    @Test func failuresUseSourceMessagesAndSkipRetention() async throws {
        let folder = MemoryFolder()
        for day in 1...7 { folder.seed("NotTennaPodBackup-2020-01-0\(day).db", daysAgo: Double(day)) }
        folder.state.withLock { $0.failList = true }
        await #expect(throws: AutomaticDatabaseExport.Failure.openFolder) {
            try await AutomaticDatabaseExport.run(folder: folder, now: now, timeZone: gmt) { Data() }
        }
        folder.state.withLock { $0.failList = false; $0.failCreate = true }
        await #expect(throws: AutomaticDatabaseExport.Failure.createFile) {
            try await AutomaticDatabaseExport.run(folder: folder, now: now, timeZone: gmt) { Data() }
        }
        folder.state.withLock { $0.failCreate = false }
        await #expect(throws: AutomaticDatabaseExport.Failure.other("Database version mismatch. Expected: 3110000, found: 1")) {
            try await AutomaticDatabaseExport.run(folder: folder, now: now, timeZone: gmt) {
                throw AndroidDatabaseBackup.Failure.verification("Database version mismatch. Expected: 3110000, found: 1")
            }
        }
        #expect(folder.names.count == 7, "No retention and no new file after any failure")
        #expect(AutomaticDatabaseExport.Failure.openFolder.errorDescription == "Unable to open export folder")
        #expect(AutomaticDatabaseExport.Failure.createFile.errorDescription == "Unable to create export file")
    }

    /// The real folder implementation against the file system: bookmark, create (never overwriting),
    /// list with modification dates, remove, and a missing folder.
    @Test func securityScopedFolderOnDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M18-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = SecurityScopedBackupFolder(bookmark: try LocalFolderDocuments.makeBookmark(directory: directory))
        try folder.create("NotTennaPodBackup-2033-05-18.db", data: Data("one".utf8))
        #expect(throws: AutomaticDatabaseExport.Failure.createFile) { try folder.create("NotTennaPodBackup-2033-05-18.db", data: Data("two".utf8)) }
        #expect(try Data(contentsOf: directory.appendingPathComponent("NotTennaPodBackup-2033-05-18.db")) == Data("one".utf8))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let items = try folder.list()
        #expect(items.first { $0.name == "NotTennaPodBackup-2033-05-18.db" }?.isRegularFile == true)
        #expect(items.first { $0.name == "sub" }?.isRegularFile == false)
        #expect(items.allSatisfy { $0.modified != nil })
        try folder.remove("NotTennaPodBackup-2033-05-18.db")
        #expect(try folder.list().map(\.name) == ["sub"])
        try FileManager.default.removeItem(at: directory)
        #expect(throws: AutomaticDatabaseExport.Failure.openFolder) { _ = try folder.list() }
    }

    @Test func realBackupPayloadIsTheAndroidFormat() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M18P-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try AndroidDatabaseRestore.read(AndroidDatabaseRestoreTests.fixtures.appendingPathComponent("emulator-parity-library.db"), staging: directory.appendingPathComponent("s"))
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try await store.installRestoredLibrary(library, carrying: try await store.restoreCarryOver())
        let data = try await AndroidDatabaseBackup.data(library: store, speeds: .init()) { _ in nil }
        let file = directory.appendingPathComponent("out.db"); try data.write(to: file)
        let db = try BackupSQLite(url: file, create: false); defer { try? db.close() }
        #expect(try db.integer("PRAGMA user_version") == 3_110_000)
        #expect(try db.integer("SELECT count(*) FROM Feeds") == 16 && db.integer("SELECT count(*) FROM Queue") == 9)
        try await store.close()
    }

    // MARK: - A run that may end at any point

    private func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate() && ContinuousClock.now < deadline { await Task.yield() }
        try #require(predicate())
    }

    @Test func theBackupIsWrittenUnderAnIncompleteNameVerifiedThenPublishedUnderItsName() async throws {
        let folder = MemoryFolder()
        let attempt = UUID()
        let name = try await AutomaticDatabaseExport.run(folder: folder, now: now, timeZone: gmt, attempt: attempt) { Data("backup".utf8) }
        let staged = AutomaticDatabaseExport.incompleteName(attempt)
        #expect(name == "NotTennaPodBackup-2033-05-18.db")
        #expect(folder.state.withLock { $0.operations } == ["create \(staged)", "rename \(staged) \(name)"])
        #expect(folder.names == [name] && folder.data(name) == Data("backup".utf8))
        #expect(staged == "NotTennaPodBackup-\(attempt.uuidString).incomplete" && !AutomaticDatabaseExport.isBackupName(staged),
                "A visible name a provider accepts, never a backup name")
    }

    @Test func aKilledRunsIncompleteFileGoesWithTheNextRunAndUnrelatedFilesStay() async throws {
        let folder = MemoryFolder()
        // Killed while writing: its incomplete file stayed. Killed after publishing: its backup is complete and counts.
        let leftover = AutomaticDatabaseExport.incompleteName(UUID())
        folder.seed(leftover, daysAgo: 1)
        // An earlier build's hidden incomplete file is this app's too.
        let hidden = ".NotTennaPodBackup-\(UUID().uuidString).incomplete"
        folder.seed(hidden, daysAgo: 2)
        for day in 1...5 { folder.seed("NotTennaPodBackup-2020-01-0\(day).db", daysAgo: Double(day)) }
        let unrelated = [".NotTennaPodBackup-notes.incomplete", "NotTennaPodBackup-notes.incomplete", "notes.txt",
                         ".NotTennaPodBackup-\(UUID().uuidString).incomplete.icloud"]
        for item in unrelated { folder.seed(item, daysAgo: 30) }
        let name = try await AutomaticDatabaseExport.run(folder: folder, now: now, timeZone: gmt) { Data("backup".utf8) }
        #expect(!folder.names.contains(leftover) && !folder.names.contains(hidden))
        #expect(Set(unrelated).isSubset(of: folder.names), "Only this app's incomplete files are removed")
        #expect(Set(folder.names.filter(AutomaticDatabaseExport.isBackupName)) == [name, "NotTennaPodBackup-2020-01-01.db",
                "NotTennaPodBackup-2020-01-02.db", "NotTennaPodBackup-2020-01-03.db", "NotTennaPodBackup-2020-01-04.db"])
    }

    @Test func retentionKeepsFiveVerifiedBackupsAndNeverCountsAnIncompleteOrUnknownOne() async throws {
        let folder = MemoryFolder()
        // Newest first. Files that are not whole databases, or whose content is only in the cloud, never count.
        let names = (1...10).map { "NotTennaPodBackup-2020-02-\(String(format: "%02d", $0)).db" }
        for (index, name) in names.enumerated() { folder.seed(name, daysAgo: Double(index + 1)) }
        folder.state.withLock {
            $0.incomplete = [names[1], names[6], names[9]]
            $0.unknown = [names[2], names[8]]
        }
        let others = ["AntennaPodBackup-2020-02-01.db", ".NotTennaPodBackup-2020-02-03.db.icloud", "notes.txt"]
        for item in others { folder.seed(item, daysAgo: 100) }
        let name = try await AutomaticDatabaseExport.run(folder: folder, now: now, timeZone: gmt) { Data("backup".utf8) }
        // Verified: the new one, 0, 3, 4, 5 (five survivors); then 7 is verified and older: it goes, as do the incomplete
        // 6 and 9 behind the fifth; the unknown 2 and 8 and the newer incomplete 1 stay; other names are untouched.
        #expect(folder.names == Set([name, names[0], names[1], names[2], names[3], names[4], names[5], names[8]] + others))
    }

    @Test func unknownContentNeverCountsSoOlderVerifiedBackupsSurvive() async throws {
        let folder = MemoryFolder()
        // Four newer backups whose content is only in the cloud (or an earlier partial), then four verified ones.
        let names = (1...8).map { "NotTennaPodBackup-2020-03-0\($0).db" }
        for (index, name) in names.enumerated() { folder.seed(name, daysAgo: Double(index + 1)) }
        folder.state.withLock { $0.unknown = Set(names.prefix(4)) }
        let others = ["AntennaPodBackup-2020-03-01.db", ".NotTennaPodBackup-2020-03-02.db.icloud", "notes.txt"]
        for item in others { folder.seed(item, daysAgo: 100) }
        let name = try await AutomaticDatabaseExport.run(folder: folder, now: now, timeZone: gmt) { Data("backup".utf8) }
        #expect(folder.names == Set([name] + names + others), "Only five verified exist: nothing is removed")
    }

    /// A backup that cannot be read (now, or ever) is kept, never counted and never removed; verified backups beyond the
    /// fifth verified survivor are still pruned, so one unreadable file never makes the folder grow without bound.
    @Test func anUnreadableBackupIsKeptUncountedAndNeverStopsPruning() async throws {
        let folder = MemoryFolder()
        let names = (1...8).map { "NotTennaPodBackup-2020-04-0\($0).db" }
        for (index, name) in names.enumerated() { folder.seed(name, daysAgo: Double(index + 1)) }
        folder.state.withLock { $0.unreadable = [names[0], names[6]]; $0.incomplete = [names[7]] }
        folder.seed(".NotTennaPodBackup-2020-04-01.db.icloud", daysAgo: 100)
        var day = 0.0
        for _ in 0..<10 {
            let name = try await AutomaticDatabaseExport.run(folder: folder, now: now.addingTimeInterval(day * 86_400), timeZone: gmt) {
                Data("backup".utf8)
            }
            day += 3
            #expect(folder.names.contains(name))
            let verified = folder.names.filter { AutomaticDatabaseExport.isBackupName($0) && ![names[0], names[6], names[7]].contains($0) }
            #expect(verified.count == 5, "Five verified backups after every run: \(verified.sorted())")
        }
        #expect(folder.names.isSuperset(of: [names[0], names[6], ".NotTennaPodBackup-2020-04-01.db.icloud"]),
                "The unreadable files and the placeholder are never removed")
        #expect(!folder.names.contains(names[7]), "An incomplete one older than the fifth verified backup goes, as before")
    }

    @Test func cancellationInsideAnAccessorNeverPublishesAndTheNextRunCleansUp() async throws {
        let folder = MemoryFolder()
        for day in 1...3 { folder.seed("NotTennaPodBackup-2020-01-0\(day).db", daysAgo: Double(day)) }
        let before = folder.names
        let stall = DispatchSemaphore(value: 0)
        folder.createStall.withLock { $0 = stall }
        let run = Task { try await AutomaticDatabaseExport.run(folder: folder, now: now, timeZone: gmt) { Data("backup".utf8) } }
        try await until { folder.createEntered.withLock { $0 } }
        run.cancel()
        try await until { folder.state.withLock { $0.cancelled } }
        // The accessor was already running: it finishes its write.
        stall.signal()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(!folder.names.contains("NotTennaPodBackup-2033-05-18.db"), "Never published")
        let leftovers = Set(folder.names.filter(AutomaticDatabaseExport.isIncompleteName))
        #expect(leftovers.count == 1 && folder.names.subtracting(leftovers) == before, "Existing backups untouched")
        folder.createStall.withLock { $0 = nil }
        folder.state.withLock { $0.cancelled = false }
        let name = try await AutomaticDatabaseExport.run(folder: folder, now: now, timeZone: gmt) { Data("backup".utf8) }
        #expect(folder.names == before.union([name]), "The next run removes the leftover and publishes")
    }

    @Test func expirationWhileWaitingForTheLibraryGateStopsHoldingNothing() async throws {
        let folder = MemoryFolder(), gate = LibraryGate()
        folder.seed("NotTennaPodBackup-2020-01-01.db", daysAgo: 1)
        await gate.acquireExclusive() // a Keep at logout moving libraries
        let run = Task {
            try await AutomaticDatabaseExport.run(folder: folder, now: now, timeZone: gmt) {
                try await gate.acquireSharedUnlessCancelled()
                defer { gate.releaseShared() }
                return Data("backup".utf8)
            }
        }
        try await until { gate.hasWaiters }
        run.cancel()
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(!gate.hasWaiters)
        gate.releaseExclusive()
        #expect(!gate.isHeld && folder.names == ["NotTennaPodBackup-2020-01-01.db"])
    }

    @Test func aProviderRefusalPublishesNothingAndASameNameCollisionNeverOverwrites() async throws {
        let folder = MemoryFolder()
        folder.seed("NotTennaPodBackup-2020-01-01.db", daysAgo: 1)
        folder.state.withLock { $0.refuseRename = true }
        await #expect(throws: AutomaticDatabaseExport.Failure.createFile) {
            try await AutomaticDatabaseExport.run(folder: folder, now: now, timeZone: gmt) { Data("backup".utf8) }
        }
        #expect(folder.names == ["NotTennaPodBackup-2020-01-01.db"], "Its incomplete file is removed; nothing else changes")
        // A file of the backup's name appears while it is written (another device, the person): it is never replaced.
        folder.state.withLock { $0.refuseRename = false; $0.appearsOnRename = "NotTennaPodBackup-2033-05-18.db" }
        let name = try await AutomaticDatabaseExport.run(folder: folder, now: now, timeZone: gmt) { Data("backup".utf8) }
        #expect(name == "NotTennaPodBackup-2033-05-18 (1).db")
        #expect(folder.data("NotTennaPodBackup-2033-05-18.db") == Data("someone else's".utf8) && folder.data(name) == Data("backup".utf8))
    }

    @Test func aWholeDatabaseIsRecognisedAndAnEmptyOrTruncatedOneIsNot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("K5c-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try AndroidDatabaseRestore.read(AndroidDatabaseRestoreTests.fixtures.appendingPathComponent("emulator-parity-library.db"),
                                                      staging: directory.appendingPathComponent("s"))
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try await store.installRestoredLibrary(library, carrying: try await store.restoreCarryOver())
        let data = try await AndroidDatabaseBackup.data(library: store, speeds: .init()) { _ in nil }
        try await store.close()
        #expect(AutomaticDatabaseExport.isCompleteDatabase(header: data.prefix(100), size: Int64(data.count)))
        #expect(!AutomaticDatabaseExport.isCompleteDatabase(header: data.prefix(100), size: Int64(data.count / 2)))
        #expect(!AutomaticDatabaseExport.isCompleteDatabase(header: Data(), size: 0))
        #expect(!AutomaticDatabaseExport.isCompleteDatabase(header: Data(repeating: 7, count: 100), size: 4096))

        // The real folder: a verified write, an exclusive rename, the completeness check, and cancellation.
        let backups = directory.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let folder = SecurityScopedBackupFolder(bookmark: try LocalFolderDocuments.makeBookmark(directory: backups))
        let staged = AutomaticDatabaseExport.incompleteName(UUID())
        try folder.create(staged, data: data)
        #expect(try folder.isComplete(staged) == true)
        try Data("theirs".utf8).write(to: backups.appendingPathComponent("NotTennaPodBackup-2033-05-18.db"))
        #expect(throws: AutomaticDatabaseExport.Failure.nameTaken) { try folder.rename(staged, to: "NotTennaPodBackup-2033-05-18.db") }
        #expect(try Data(contentsOf: backups.appendingPathComponent("NotTennaPodBackup-2033-05-18.db")) == Data("theirs".utf8))
        try folder.rename(staged, to: "NotTennaPodBackup-2033-05-18 (1).db")
        #expect(try Data(contentsOf: backups.appendingPathComponent("NotTennaPodBackup-2033-05-18 (1).db")) == data)
        try data.prefix(data.count / 2).write(to: backups.appendingPathComponent("NotTennaPodBackup-2020-01-01.db"))
        #expect(try folder.isComplete("NotTennaPodBackup-2020-01-01.db") == false)
        #expect(try folder.isComplete("NotTennaPodBackup-2033-05-18.db") == false)
        folder.cancel()
        #expect(throws: CancellationError.self) { _ = try folder.list() }
        #expect(throws: CancellationError.self) { try folder.create(AutomaticDatabaseExport.incompleteName(UUID()), data: data) }
    }

    @MainActor @Test func preferencesPersistAndEnabledMeansAFolder() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("M18-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = try AutomaticDatabaseExportPreferenceStore(file: file)
        #expect(!store.value.isEnabled)
        try store.update { $0.bookmark = Data([1]); $0.lastRun = now; $0.pendingError = "x" }
        let reopened = try AutomaticDatabaseExportPreferenceStore(file: file)
        #expect(reopened.value == .init(bookmark: Data([1]), lastRun: now, pendingError: "x") && reopened.value.isEnabled)
        try Data("{".utf8).write(to: file)
        #expect(try AutomaticDatabaseExportPreferenceStore(file: file).value == .init(), "Unreadable file reads as disabled")
    }
}
