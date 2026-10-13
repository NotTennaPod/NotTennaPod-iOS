import Foundation
import Security
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Starting while data is still locked. Saved state that cannot be read now (a permission or data-protection
/// error, a folder that cannot be examined, a locked Keychain) is never replaced by defaults, set aside, or taken for
/// "no registry"; the start waits and is tried again in the same process once the state can be read.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct LibraryStartupTests {
    private let serverID = "0b5a3c1e-7c43-4a5e-9d1f-2b9a0e7f6c11"

    private final class Root {
        let url: URL
        private var denied: [URL] = []
        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryStartup-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        /// Unreadable (a file) or not examinable (a folder), as before the first unlock or after a permission error.
        func deny(_ item: URL) throws {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: item.path)
            denied.append(item)
        }
        /// Protected data became available again.
        func allow() throws {
            for item in denied.reversed() {
                var directory: ObjCBool = false
                FileManager.default.fileExists(atPath: item.path, isDirectory: &directory)
                try FileManager.default.setAttributes([.posixPermissions: directory.boolValue ? 0o755 : 0o644], ofItemAtPath: item.path)
            }
            denied = []
        }
        func entries() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() }
        deinit {
            try? allow()
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// A Keychain that refuses with errSecInteractionNotAllowed while locked, as AfterFirstUnlock items do before the
    /// first unlock.
    private final class LockableProxyKeychain: ProxyPreferencePersistence, Sendable {
        let locked = Mutex(true)
        let stored: PodcastProxy?
        init(stored: PodcastProxy?) { self.stored = stored }
        func load() throws -> PodcastProxy? {
            if locked.withLock({ $0 }) { throw SynchronizationCredentialError.keychain(errSecInteractionNotAllowed) }
            return stored
        }
        func save(_ configuration: PodcastProxy) throws {}
    }

    /// What the start finds: whether it fails, and whether protected data is available.
    @MainActor private final class Conditions {
        var failing = true
        var available = false
        var builds = 0
        var log: [String] = []
    }

    private func server(_ id: String) -> LibraryRegistry.ServerLibrary {
        .init(id: id, serverURL: "https://sync.example.test", serverID: "server-1", accountID: "6f1c2d3e-4b5a-4c6d-8e7f-9a0b1c2d3e4f",
              username: "alice", state: .active, createdAt: 1_700_000_000_000)
    }

    /// Whether `body` throws an error that means saved state cannot be reached now.
    private func unavailable<T>(_ body: () throws -> T) -> Bool {
        do { _ = try body(); return false } catch { return SavedState.isUnavailable(error) }
    }

    /// The task's result; cancelling the test (its time limit) cancels the task, so a regression fails, never hangs.
    private func result<T: Sendable>(of task: Task<T, any Error>) async throws -> T {
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func wait(until condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "condition not reached")
            await Task.yield()
        }
    }

    // MARK: - Classification

    @Test func onlyConfirmedAbsenceMeansNothingIsThere() throws {
        let root = try Root()
        let missing = root.url.appendingPathComponent("missing.json")
        #expect(try SavedState.contents(of: missing) == nil)
        #expect(try !SavedState.isPresent(missing))
        let folder = root.url.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let inside = folder.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: inside)
        try root.deny(folder)
        // A folder that cannot be examined is not "no file": `fileExists` says false here, which is why it is not used.
        #expect(!FileManager.default.fileExists(atPath: inside.path))
        #expect(unavailable { try SavedState.contents(of: inside) })
        #expect(unavailable { try SavedState.isPresent(inside) })
        #expect(!SavedState.isAbsent(inside))
    }

    @Test func accessErrorsAreUnavailableAndDecodingErrorsAreCorrupt() throws {
        let protection = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue,
                                 userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        #expect(SavedState.isUnavailable(protection) && !SavedState.isCorrupt(protection))
        #expect(SavedState.isUnavailable(POSIXError(.EACCES)) && SavedState.isUnavailable(POSIXError(.EIO)))
        #expect(SavedState.isUnavailable(SynchronizationCredentialError.keychain(errSecInteractionNotAllowed)))
        #expect(SavedState.isUnavailable(ServerSecretStoreError.keychain(errSecInteractionNotAllowed)))
        #expect(!SavedState.isUnavailable(SynchronizationCredentialError.keychain(errSecItemNotFound)))
        #expect(SavedState.isUnavailable(FeedLibraryError.sqlite(code: 14, message: "unable to open database file")))
        #expect(!SavedState.isUnavailable(CocoaError(.fileReadNoSuchFile)) && !SavedState.isUnavailable(POSIXError(.ENOSPC)))
        let damaged = #expect(throws: DecodingError.self) { try JSONDecoder().decode(SleepTimerPreferences.self, from: Data("{".utf8)) }
        #expect(damaged.map(SavedState.isCorrupt) == true && damaged.map(SavedState.isUnavailable) == false)
        #expect(SavedState.isCorrupt(PlaybackSpeedError.invalidSpeed) && SavedState.isCorrupt(LibraryRegistryError.unsupportedVersion(2)))
    }

    // MARK: - Settings, registry, folders, backup preferences, Keychain

    @Test func settingsThatCannotBeReadAreNeitherSetAsideNorDefaulted() throws {
        let root = try Root()
        let file = root.url.appendingPathComponent("sleep-timer.json")
        var saved = SleepTimerPreferences(); saved.lastMinutes = "45"; saved.vibrate = true
        try JSONEncoder().encode(saved).write(to: file)
        let bytes = try Data(contentsOf: file)
        try root.deny(file)
        var reported = 0
        #expect(unavailable {
            _ = try UnreadableSettingsFile.open(file, { try SleepTimerPreferenceStore(file: $0) }) { _ in reported += 1 }
        })
        #expect(reported == 0)
        #expect(try root.entries() == ["sleep-timer.json"], "nothing set aside, no default file written")
        try root.allow()
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try UnreadableSettingsFile.open(file, { try SleepTimerPreferenceStore(file: $0) }) { _ in reported += 1 }.value == saved)
        #expect(reported == 0)
    }

    @Test func settingsInAFolderThatCannotBeExaminedAreNotTakenForMissing() throws {
        let root = try Root()
        let folder = root.url.appendingPathComponent("settings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("interface-preferences.json")
        var saved = InterfacePreferences(); saved.useEpisodeCover.toggle()
        try JSONEncoder().encode(saved).write(to: file)
        try root.deny(folder)
        for open in [{ _ = try InterfacePreferenceStore(file: file) }, { _ = try NavigationPreferenceStore(file: file) },
                     { _ = try DownloadPreferenceStore(file: file) }, { _ = try HomeSectionPreferenceStore(file: file) },
                     { _ = try MobileNetworkPreferenceStore(file: file) }] as [@MainActor () throws -> Void] {
            #expect(unavailable { try open() })
        }
        try root.allow()
        #expect(try InterfacePreferenceStore(file: file).value == saved)
    }

    @Test func registryThatCannotBeReadDoesNotOpenTheStandaloneLibrary() throws {
        let root = try Root()
        let file = LibraryRegistryFile(root: root.url)
        var registry = LibraryRegistry()
        registry.libraries = [server(serverID)]
        registry.active = .server(serverID)
        try file.write(registry)
        try root.deny(file.url)
        #expect(unavailable { try file.openingLibrary() })
        #expect(unavailable { try file.read() })
        try root.allow()
        // Its parent folder cannot be examined: not "no registry" either.
        let parent = try Root()
        let inner = parent.url.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try LibraryRegistryFile(root: inner).write(registry)
        try parent.deny(inner)
        #expect(unavailable { try LibraryRegistryFile(root: inner).openingLibrary() })
        try parent.allow()
        #expect(try LibraryRegistryFile(root: inner).openingLibrary() == .server(serverID))
        #expect(try file.openingLibrary() == .server(serverID))
    }

    @Test func libraryFolderThatCannotBeExaminedIsNotTakenForMissing() throws {
        let root = try Root()
        let location = LibraryLocation(root: root.url, reference: .server(serverID))
        #expect(try !location.folderIsPresent())
        try location.prepare()
        #expect(try location.folderIsPresent())
        try root.deny(LibraryLocation.serverLibraries(root: root.url))
        #expect(unavailable { try location.folderIsPresent() })
        try root.allow()
        #expect(try location.folderIsPresent())
    }

    @Test func backupPreferencesThatCannotBeReadKeepTheirFolder() throws {
        let root = try Root()
        let file = root.url.appendingPathComponent("automatic-database-export.json")
        let saved = AutomaticDatabaseExportPreferences(bookmark: Data("bookmark".utf8), lastRun: Date(timeIntervalSince1970: 1_700_000_000))
        try JSONEncoder().encode(saved).write(to: file)
        try root.deny(file)
        #expect(unavailable { try AutomaticDatabaseExportPreferenceStore(file: file) })
        try root.allow()
        #expect(try AutomaticDatabaseExportPreferenceStore(file: file).value == saved)
        // Damaged content still starts from the defaults, as before.
        try Data("{".utf8).write(to: file)
        #expect(try AutomaticDatabaseExportPreferenceStore(file: file).value == AutomaticDatabaseExportPreferences())
    }

    // MARK: - The startup owner

    /// A start in the order the app uses: the registry, the library folder, the proxy's Keychain item, a settings file
    /// and the backup preferences. Each in turn cannot be read (no protected data): the start waits each time and
    /// nothing is renamed, defaulted or given up for the standalone library; then protected data becomes available in
    /// the same process and every saved value is there.
    @Test func startWaitsWhileLockedAndStartsOnAvailabilityWithEverySavedValueIntact() async throws {
        let root = try Root()
        var registry = LibraryRegistry()
        registry.libraries = [server(serverID)]; registry.active = .server(serverID)
        try LibraryRegistryFile(root: root.url).write(registry)
        try LibraryLocation(root: root.url, reference: .server(serverID)).prepare()
        var sleep = SleepTimerPreferences(); sleep.lastMinutes = "45"
        try JSONEncoder().encode(sleep).write(to: root.url.appendingPathComponent("sleep-timer.json"))
        let backup = AutomaticDatabaseExportPreferences(bookmark: Data("folder".utf8))
        try JSONEncoder().encode(backup).write(to: root.url.appendingPathComponent("automatic-database-export.json"))
        let proxy = PodcastProxy(kind: .http, host: "proxy.example.test", port: 8080)
        let keychain = LockableProxyKeychain(stored: proxy)
        for name in ["libraries.json", "sleep-timer.json", "automatic-database-export.json"] {
            try root.deny(root.url.appendingPathComponent(name))
        }
        let conditions = Conditions()
        var opened: (LibraryReference, PodcastProxy, SleepTimerPreferences, AutomaticDatabaseExportPreferences)?
        var resolved: [(LibraryStartup.State, LibraryStartup.State)] = []
        let startup = LibraryStartup(.init(build: {
            let reference = try LibraryRegistryFile(root: root.url).openingLibrary()
            guard try LibraryLocation(root: root.url, reference: reference).folderIsPresent() else { throw CocoaError(.fileNoSuchFile) }
            let proxyStore = try ProxyPreferenceStore(persistence: keychain)
            let sleepStore = try UnreadableSettingsFile.open(root.url.appendingPathComponent("sleep-timer.json"),
                                                            { try SleepTimerPreferenceStore(file: $0) }) { _ in Issue.record("set aside") }
            let backupStore = try UnreadableSettingsFile.open(root.url.appendingPathComponent("automatic-database-export.json"),
                { try AutomaticDatabaseExportPreferenceStore(file: $0) }) { _ in Issue.record("set aside") }
            opened = (reference, proxyStore.value, sleepStore.value, backupStore.value)
        }, retire: {}, discard: {}, protectedDataAvailable: { conditions.available }, resolved: { resolved.append(($0, $1)) }))
        startup.start()
        #expect(startup.state == .waitingForUnlock && opened == nil)
        #expect(SavedState.isUnavailable(try #require(startup.failure)))
        let entries = ["Server Libraries", "automatic-database-export.json", "libraries.json", "sleep-timer.json"]
        let denied = ["sleep-timer.json", "automatic-database-export.json"]
        // One by one: the registry readable but the Keychain locked; the Keychain open but the settings file
        // unreadable; the settings readable but the backup preferences unreadable. Each time a wait, nothing changed.
        for step in 0..<3 {
            try root.allow()
            if step >= 1 { keychain.locked.withLock { $0 = false } }
            for name in denied.dropFirst(max(0, step - 1)) where step >= 1 { try root.deny(root.url.appendingPathComponent(name)) }
            startup.retry()
            try await wait { startup.state != .starting }
            #expect(startup.state == .waitingForUnlock && opened == nil, "step \(step)")
            #expect(SavedState.isUnavailable(try #require(startup.failure)), "step \(step)")
            #expect(try root.entries() == entries, "step \(step): nothing set aside or written")
        }
        try root.allow()
        conditions.available = true
        startup.retry()
        try await wait { startup.state == .started }
        let values = try #require(opened)
        #expect(values.0 == .server(serverID), "the recorded library, never the standalone library")
        #expect(values.1 == proxy && values.2 == sleep && values.3 == backup)
        #expect(resolved.map(\.0) == [.waitingForUnlock, .waitingForUnlock, .waitingForUnlock, .waitingForUnlock, .started])
        #expect(resolved.last?.1 == .waitingForUnlock && startup.failure == nil)
    }

    @Test func repeatedActivationAndAvailabilityStartOnce() async throws {
        let conditions = Conditions()
        let startup = LibraryStartup(.init(build: {
            conditions.builds += 1
            if conditions.failing { throw POSIXError(.EPERM) }
        }, retire: {}, discard: { await Task.yield() }, protectedDataAvailable: { false }, resolved: { _, _ in }))
        startup.start()
        #expect(conditions.builds == 1 && startup.state == .waitingForUnlock)
        conditions.failing = false
        for _ in 0..<5 { startup.retry() }
        #expect(startup.state == .starting)
        try await wait { startup.state == .started }
        for _ in 0..<5 { startup.retry() }
        await Task.yield()
        #expect(conditions.builds == 2 && startup.state == .started)
    }

    /// What a failed attempt built is retired before anything else runs, discarded before the next attempt, and never
    /// published; attempts never overlap.
    @Test func partialGraphIsRetiredAtOnceAndDiscardedBeforeTheNextAttempt() async throws {
        var events: [String] = []
        var owners: [String] = []
        var building = false
        let conditions = Conditions()
        let discardGate = AsyncStream<Void>.makeStream()
        let startup = LibraryStartup(.init(build: {
            #expect(!building); building = true; defer { building = false }
            events.append("build")
            owners = ["store", "player"]
            if conditions.failing { throw POSIXError(.EIO) }
            owners.append("downloads")
        }, retire: {
            events.append("retire")
        }, discard: {
            for await _ in discardGate.stream { break }
            owners = []
            events.append("discarded")
        }, protectedDataAvailable: { true }, resolved: { state, _ in events.append("resolved \(state)") }))
        startup.start()
        #expect(events == ["build", "retire", "resolved failed"])
        conditions.failing = false
        startup.retry(); startup.start() // an activation and a restart while the discard runs share one attempt
        await Task.yield()
        #expect(events.count == 3 && startup.state == .starting && startup.presented == .failed)
        discardGate.continuation.yield()
        try await wait { startup.state == .started }
        #expect(events == ["build", "retire", "resolved failed", "discarded", "build", "resolved started"])
        #expect(owners == ["store", "player", "downloads"])
    }

    @Test func workThatArrivedWhileWaitingRunsOnceAfterTheStartSucceeds() async throws {
        let conditions = Conditions()
        let startup = LibraryStartup(.init(build: { if conditions.failing { throw POSIXError(.EPERM) } }, retire: {}, discard: {},
                                           protectedDataAvailable: { conditions.available }, resolved: { _, _ in }))
        startup.start()
        var ran: [String] = []
        startup.whenStarted { ran.append("link") }
        startup.whenStarted { ran.append("shortcut") }
        startup.retry()
        try await wait { startup.state == .waitingForUnlock }
        #expect(ran.isEmpty, "nothing runs while it still waits")
        conditions.failing = false; conditions.available = true
        startup.retry()
        try await wait { startup.state == .started }
        #expect(ran == ["link", "shortcut"])
        startup.whenStarted { ran.append("notification") }
        startup.retry()
        await Task.yield()
        #expect(ran == ["link", "shortcut", "notification"])
    }

    /// Wait → a failure once protected data is available (a normal, shown error, not an endless wait) →
    /// success at the next activation. Work that arrived meanwhile never goes to the failed start's error screen; it
    /// runs once, after the successful start.
    @Test func queuedWorkSurvivesAFailureAfterUnlockAndRunsOnceAfterSuccess() async throws {
        let conditions = Conditions()
        var resolved: [LibraryStartup.State] = []
        let startup = LibraryStartup(.init(build: { if conditions.failing { throw FeedLibraryError.corruptRecord } }, retire: {},
                                           discard: {}, protectedDataAvailable: { conditions.available },
                                           resolved: { state, _ in resolved.append(state) }))
        var ran: [LibraryStartup.State] = []
        startup.start()
        startup.whenStarted { ran.append(startup.state) }
        #expect(startup.state == .waitingForUnlock && !startup.isStarted)
        conditions.available = true
        startup.retry()
        try await wait { startup.state == .failed }
        #expect(startup.failure as? FeedLibraryError == .corruptRecord)
        #expect(ran.isEmpty, "nothing reaches the error screen of a failed start")
        conditions.failing = false
        startup.sceneActivated()
        try await wait { startup.state == .started }
        #expect(ran == [.started] && resolved == [.waitingForUnlock, .failed, .started])
    }

    /// Work that arrives while a failed attempt is still being discarded is held outside that teardown:
    /// the attempt that follows fails again (with protected data available) and gets none of it; the next successful
    /// start runs it once.
    @Test func workArrivingWhileADiscardIsSuspendedRunsOnceAfterSuccess() async throws {
        let conditions = Conditions()
        conditions.available = true
        let gate = AsyncStream<Void>.makeStream()
        let startup = LibraryStartup(.init(build: { if conditions.failing { throw POSIXError(.EIO) } }, retire: {}, discard: {
            for await _ in gate.stream { break }
        }, protectedDataAvailable: { conditions.available }, resolved: { _, _ in }))
        startup.start()
        startup.retry()
        await Task.yield()
        var ran = 0
        startup.whenStarted { ran += 1 }
        #expect(startup.state == .starting && ran == 0)
        gate.continuation.yield()
        try await wait { startup.state == .failed }
        #expect(ran == 0, "the failed start's error screen gets nothing")
        conditions.failing = false
        startup.sceneActivated()
        gate.continuation.yield()
        try await wait { startup.state == .started }
        #expect(ran == 1)
        startup.retry(); startup.sceneActivated()
        await Task.yield()
        #expect(ran == 1)
    }

    /// Once started, protected data becoming available or a scene becoming active resumes work parked for
    /// access (once per event), and never starts the graph again; before that, they retry the start.
    @Test func onceStartedAvailabilityAndActivationResumeParkedWork() async throws {
        let conditions = Conditions()
        var resumed = 0
        let startup = LibraryStartup(.init(build: {
            conditions.builds += 1
            if conditions.failing { throw POSIXError(.EPERM) }
        }, retire: {}, discard: {}, protectedDataAvailable: { conditions.available }, resolved: { _, _ in },
           resumeParked: { resumed += 1 }))
        startup.start()
        conditions.failing = false
        startup.protectedDataBecameAvailable()
        try await wait { startup.state == .started }
        #expect(resumed == 0 && conditions.builds == 2)
        startup.protectedDataBecameAvailable()
        startup.sceneActivated()
        #expect(resumed == 2 && conditions.builds == 2, "the started graph is not rebuilt")
    }

    // MARK: - Widget and Control Center commands: one ordered dispatcher

    /// A deadline that already passed is refused at once, with no other startup event.
    @Test func elapsedWidgetDeadlineFinishesWithoutAnotherStartupEvent() async throws {
        let startup = LibraryStartup(.init(build: { throw POSIXError(.EPERM) }, retire: {}, discard: {},
                                           protectedDataAvailable: { false }, resolved: { _, _ in }))
        startup.start()
        await #expect(throws: SavedStateUnavailable.self) {
            try await startup.runCommand(before: .now - .milliseconds(1)) { Issue.record("an expired command ran") }
        }
    }

    /// The wait ends at its deadline though nothing else happens: no availability, no activation, no cancellation.
    @Test func widgetWaitEndsAtItsDeadlineWithoutAnyStartupEvent() async throws {
        let startup = LibraryStartup(.init(build: { throw POSIXError(.EPERM) }, retire: {}, discard: {},
                                           protectedDataAvailable: { false }, resolved: { _, _ in }))
        startup.start()
        await #expect(throws: SavedStateUnavailable.self) {
            try await startup.runCommand(before: .now + .milliseconds(50)) { Issue.record("an expired command ran") }
        }
        #expect(startup.state == .waitingForUnlock)
    }

    /// Expiry racing a successful start or a cancellation: every command is settled exactly once (a second resumption
    /// of a continuation would trap) and runs only within its deadline. In every other round the short waits must end by
    /// themselves before anything else happens.
    @Test func expiryRacingStartAndCancellationReleasesEachWaiterOnce() async throws {
        for round in 0..<10 {
            let conditions = Conditions()
            let startup = LibraryStartup(.init(build: { if conditions.failing { throw POSIXError(.EPERM) } }, retire: {},
                                               discard: {}, protectedDataAvailable: { conditions.available }, resolved: { _, _ in }))
            startup.start()
            let short = (0..<4).map { _ in Task { try await startup.runCommand(before: .now + .milliseconds(1)) {} } }
            let long = (0..<4).map { _ in Task { try await startup.runCommand(before: .now + .seconds(60)) {} } }
            await Task.yield()
            long[0].cancel()
            if round.isMultiple(of: 2) {
                for task in short { await #expect(throws: SavedStateUnavailable.self) { try await result(of: task) } }
            }
            conditions.failing = false; conditions.available = true
            startup.retry()
            for task in short {
                do { try await result(of: task) } catch { #expect(error is SavedStateUnavailable) }
            }
            await #expect(throws: CancellationError.self) { try await result(of: long[0]) }
            for task in long.dropFirst() { try await result(of: task) }
            #expect(startup.state == .started)
        }
    }

    /// Commands admitted while the start waits, from tasks of different priorities, run in the order
    /// they were admitted (a Play then a Pause stay so), whatever order their tasks resume in.
    @Test func commandsRunInAdmissionOrderWhateverTheirPriority() async throws {
        let conditions = Conditions()
        let startup = LibraryStartup(.init(build: { if conditions.failing { throw POSIXError(.EPERM) } }, retire: {}, discard: {},
                                           protectedDataAvailable: { conditions.available }, resolved: { _, _ in }))
        startup.start()
        var tasks: [Task<Void, any Error>] = []
        let priorities: [TaskPriority] = [.background, .high, .utility, .userInitiated, .low, .high]
        for (index, priority) in priorities.enumerated() {
            // Callers from anywhere (detached tasks resume on the shared executor, where priority decides who runs first).
            tasks.append(Task.detached(priority: priority) {
                try await startup.runCommand(before: .now + .seconds(60)) { conditions.log.append("\(index)") }
            })
            try await wait { startup.admittedCommands == index + 1 }
        }
        conditions.failing = false; conditions.available = true
        startup.retry()
        for task in tasks { try await result(of: task) }
        #expect(conditions.log == priorities.indices.map { "\($0)" })
    }

    /// A command arriving once the graph started, while the earlier ones still run, runs after them.
    @Test func commandsArrivingWhileThePendingOnesRunFollowThem() async throws {
        let conditions = Conditions()
        let startup = LibraryStartup(.init(build: { if conditions.failing { throw POSIXError(.EPERM) } }, retire: {}, discard: {},
                                           protectedDataAvailable: { conditions.available }, resolved: { _, _ in }))
        startup.start()
        let gate = AsyncStream<Void>.makeStream()
        let first = Task { @MainActor in
            try await startup.runCommand(before: .now + .seconds(60)) {
                conditions.log.append("play")
                for await _ in gate.stream { break }
            }
        }
        try await wait { startup.admittedCommands == 1 }
        let second = Task { @MainActor in try await startup.runCommand(before: .now + .seconds(60)) { conditions.log.append("pause") } }
        try await wait { startup.admittedCommands == 2 }
        conditions.failing = false; conditions.available = true
        startup.retry()
        try await wait { conditions.log == ["play"] }
        let live = Task { @MainActor in try await startup.runCommand(before: .now + .seconds(60)) { conditions.log.append("play again") } }
        try await wait { startup.admittedCommands == 2 }
        #expect(conditions.log == ["play"], "nothing overtakes the running command")
        gate.continuation.yield()
        for task in [first, second, live] { try await result(of: task) }
        #expect(conditions.log == ["play", "pause", "play again"])
    }

    /// A command whose task is cancelled while the start succeeds (inside the build, before it returns)
    /// never runs; the others do, in order.
    @Test func commandCancelledAsTheStartSucceedsNeverRuns() async throws {
        let conditions = Conditions()
        var cancelDuringBuild: Task<Void, any Error>?
        let startup = LibraryStartup(.init(build: {
            if conditions.failing { throw POSIXError(.EPERM) }
            cancelDuringBuild?.cancel()
        }, retire: {}, discard: {}, protectedDataAvailable: { conditions.available }, resolved: { _, _ in }))
        startup.start()
        let play = Task { @MainActor in try await startup.runCommand(before: .now + .seconds(60)) { conditions.log.append("play") } }
        try await wait { startup.admittedCommands == 1 }
        let pause = Task { @MainActor in try await startup.runCommand(before: .now + .seconds(60)) { conditions.log.append("pause") } }
        try await wait { startup.admittedCommands == 2 }
        cancelDuringBuild = play
        conditions.failing = false; conditions.available = true
        startup.retry()
        await #expect(throws: CancellationError.self) { try await result(of: play) }
        try await result(of: pause)
        #expect(conditions.log == ["pause"])
    }

    /// A start that fails with a shown error keeps a waiting command until its deadline: a success at the next
    /// activation within it still runs it once.
    @Test func widgetCommandWaitingThroughAFailedStartRunsAfterTheNextSuccess() async throws {
        let conditions = Conditions()
        let startup = LibraryStartup(.init(build: { if conditions.failing { throw POSIXError(.EIO) } }, retire: {}, discard: {},
                                           protectedDataAvailable: { conditions.available }, resolved: { _, _ in }))
        startup.start()
        let waiting = Task { try await startup.runCommand(before: .now + .seconds(60)) { conditions.log.append("ran") } }
        try await wait { startup.admittedCommands == 1 }
        conditions.available = true
        startup.protectedDataBecameAvailable()
        try await wait { startup.state == .failed }
        #expect(conditions.log.isEmpty)
        conditions.failing = false
        startup.sceneActivated()
        try await result(of: waiting)
        #expect(startup.state == .started && conditions.log == ["ran"])
    }
}
