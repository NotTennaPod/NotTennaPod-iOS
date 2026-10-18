import Foundation

/// What every graph start does before any library opens (PROTOCOL §15.4): the schema-20 migration of every
/// library on the device, then an unfinished Keep at logout finished as far as it can be, then the library to open,
/// which is a converted library where its markers show it while its Keep is not published.
public enum LibraryGraphStart {
    /// The migration of every library on the device that is not at the current schema (21): each through a
    /// migrating connection of its own, under the exclusive library gate, without starting its graph. A failure rolls
    /// back and is retried at the next graph start; meanwhile that library stays at its schema, and one below 20 is
    /// offered to no export. Schema 21 creates the derived tables empty; a library's rows are filled when it next opens. When the gate is busy (an export still collecting at a runtime restart) nothing waits: the migration
    /// runs at the next graph start. Returns the libraries that could not be migrated.
    @discardableResult
    public static func migrateLibraries(root: URL, gate: LibraryGate) -> [URL] {
        var databases = [root.appendingPathComponent(LibraryLocation.databaseName)]
        databases += ((try? LibraryLocation.all(root: root)) ?? []).filter { $0.reference != .standalone }.map(\.database)
        databases += ((try? PreviousLibraryLocation.all(root: root)) ?? []).map(\.database)
        let pending = databases.filter { database in
            !LibraryLocation.isAbsent(database) && ((try? LibraryDatabaseInspection.schemaVersion(of: database)) ?? 0) < 21
        }
        guard !pending.isEmpty else { return [] }
        guard gate.tryAcquireExclusive() else { return pending }
        defer { gate.releaseExclusive() }
        var failed: [URL] = []
        for database in pending {
            do { try LibrarySQLite(url: database).close() } catch { failed.append(database) }
        }
        return failed
    }

    /// An unfinished Keep at logout, finished as far as it can be before anything opens (PROTOCOL §15.4 "Recovery comes
    /// first"): at a launch, or at a runtime restart that follows one. Returns the Keep's outcome, nil without one.
    /// Throws when what it must read cannot be read or inspected now (before the first unlock, a locked database):
    /// the start waits for it. Only a damaged registry counts as no Keep, as before.
    public static func finishKeep(_ keep: LibraryKeep, gate: LibraryGate) throws -> (manifest: LibraryKeepManifest, outcome: LibraryKeep.Outcome)? {
        do { guard try keep.unfinished() != nil else { return nil } }
        catch where SavedState.isCorrupt(error) { return nil }
        guard gate.tryAcquireExclusive() else { return nil }
        defer { gate.releaseExclusive() }
        return keep.runUnfinished()
    }

    /// Local copy detection (PROTOCOL §6.10) for every server library on the device that may sync again, before any opens and
    /// after an unfinished Keep's recovery (a `keeping` library never syncs again; its Keep finishes locally instead).
    /// A copy forks every author and takes a new installation in one transaction of its own database. Under the
    /// exclusive library gate; a busy gate, an unreadable registry or library, or a Keychain that cannot be read yet
    /// (before the first unlock) leave it to the exchange, which detects the open library before it sends anything.
    /// Returns the libraries found to be copies.
    @discardableResult
    public static func detectCopies(root: URL, secrets: any ServerSecretStore, gate: LibraryGate) -> [String] {
        guard let registry = try? LibraryRegistryFile(root: root).read() else { return [] }
        let candidates = registry.libraries.filter { [.active, .ready, .inactive].contains($0.state) }
        guard !candidates.isEmpty, gate.tryAcquireExclusive() else { return [] }
        defer { gate.releaseExclusive() }
        return candidates.compactMap { entry in
            let location = LibraryLocation(root: root, reference: .server(entry.id))
            guard case .forked? = try? ServerCopyDetection.detect(location, libraryID: entry.id, secrets: secrets) else { return nil }
            return entry.id
        }
    }

    /// The library to open, given the registry's choice: a committed Keep that could not publish opens its converted
    /// library where it is; a database the Keep archived is never opened as the active library. A
    /// manifest, database or marker that cannot be read or inspected now is thrown, never taken for "no Keep";
    /// only damaged content is skipped, as before.
    public static func converted(_ keep: LibraryKeep) throws -> LibraryLocation? {
        let keeps: [LibraryKeepManifest]
        do { keeps = try keep.unfinishedKeeps() }
        catch where SavedState.isCorrupt(error) { return nil }
        for manifest in keeps {
            do { if let location = try keep.convertedLibrary(manifest) { return location } }
            catch where LibraryKeep.isNotALibrary(error) { continue }
        }
        return nil
    }

    /// The library a graph start opens and, when it is not the one recorded, why.
    public struct Opening: Sendable {
        public enum Fallback: Sendable { case registryDamaged, folderMissing, databaseMissing }
        public var location: LibraryLocation
        public var fallback: Fallback?
        /// The server library the registry chose and whose folder or database is confirmed missing, when the
        /// standalone library opens instead (`MissingLibraryNotice`).
        public var missing: LibraryReference?
    }

    /// The library a graph start opens (PROTOCOL §15.4): a converted library whose Keep has not published, else the registry's
    /// choice with a recorded switch applied; the standalone library only when the registry is absent or damaged, or
    /// the chosen server library's folder or database is confirmed missing (its database is never created here: a
    /// Keep may have moved it). Anything that cannot be read now is thrown, so the start waits instead of opening
    /// another library or an empty one.
    public static func openingLibrary(root: URL, keep: LibraryKeep) throws -> Opening {
        if let converted = try converted(keep) { return Opening(location: converted) }
        let standalone = LibraryLocation(root: root, reference: .standalone)
        var opening = Opening(location: standalone)
        do { opening.location = LibraryLocation(root: root, reference: try LibraryRegistryFile(root: root).openingLibrary()) }
        catch where SavedState.isCorrupt(error) { opening.fallback = .registryDamaged }
        guard opening.location.reference != .standalone else { return opening }
        let chosen = opening.location.reference
        if !(try opening.location.folderIsPresent()) { return Opening(location: standalone, fallback: .folderMissing, missing: chosen) }
        // An interrupted database import's backup still counts: `LibraryReplacement.recoverInterrupted` returns it, or
        // the start waits until it can.
        let database = opening.location.database, backup = URL(fileURLWithPath: database.path + ".pre-restore")
        if !(try SavedState.isPresent(database)), !(try SavedState.isPresent(backup)) {
            return Opening(location: standalone, fallback: .databaseMissing, missing: chosen)
        }
        return opening
    }

    /// The library a database import replaces, decided while the import holds the library gate exclusively with the
    /// graph stopped. A converted library whose Keep has not published is published first: its database is the only
    /// evidence that the Keep committed, and replacing it would leave the Keep to follow the registry to an empty
    /// library. Then the library is checked again by identity where it is now. Throws when the Keep still cannot
    /// publish, or the library is no longer the one the import began on; nothing is replaced then. Returns the
    /// location to replace and the Keep's outcome when one ran.
    public static func importTarget(current: LibraryLocation, identity: String,
                                    keep: LibraryKeep) throws -> (location: LibraryLocation, keep: LibraryKeep.Outcome?) {
        var location = current, outcome: LibraryKeep.Outcome?
        if current.converted != nil, let manifest = try keep.unfinishedKeeps().first(where: { (try? keep.convertedLibrary($0)) != nil }) {
            let result = keep.run(manifest)
            outcome = result
            switch result {
            case .finished, .cleanupPending: location = LibraryLocation(root: current.root, reference: .standalone)
            case .notPublished(let failure), .notCommitted(let failure): throw LibraryImportBlocked(keep: failure)
            }
        }
        guard !LibraryLocation.isAbsent(location.database),
              (try? LibraryDatabaseInspection.identity(of: location.database))?.identity == identity else { throw FeedLibraryError.closed }
        return (location, outcome)
    }

    /// The registry names the root folder's library by identity (PROTOCOL §15.4), so a library's folder is found without opening
    /// a database. Written only where a registry exists (never in standalone use), when it changed (a database import
    /// replaced the library, or the first graph start after schema 20).
    public static func recordStandaloneIdentity(root: URL) {
        let file = LibraryRegistryFile(root: root)
        guard file.exists, let identity = try? LibraryDatabaseInspection.identity(of: root.appendingPathComponent(LibraryLocation.databaseName)),
              identity.keepRole != .archived else { return }
        _ = try? file.update { registry in
            if registry.keeping == nil, registry.conversions.isEmpty { registry.standaloneIdentity = identity.identity }
        }
    }
}

/// The one-off message that the server library the registry chose could not be found on this device, so this device's
/// library opened instead (`LibraryGraphStart.Opening.missing`: its folder or database is confirmed missing). It is due
/// once a graph start that opened that way succeeded, and the first screen that can show it takes it, once. Later
/// starts that fall back for the same library (a restart after a database import, a switch or a Keep) and scenes
/// connecting again find nothing due; a start that opens anything else ends the occurrence. A damaged registry is not
/// this case, and a library that cannot be read now (before the first unlock) never falls back: that start waits and
/// decides nothing. Kept for the process only, so nothing is saved; a later launch that falls back says it again.
public struct MissingLibraryNotice: Sendable {
    /// The missing library of the current occurrence.
    private var occurrence: LibraryReference?
    public private(set) var isDue = false

    public init() {}

    /// A graph start succeeded and opened `opening`.
    public mutating func started(_ opening: LibraryGraphStart.Opening) {
        guard let missing = opening.missing else { occurrence = nil; isDue = false; return }
        guard missing != occurrence else { return }
        occurrence = missing
        isDue = true
    }

    /// Whether a screen shows the message now: true once per occurrence.
    public mutating func take() -> Bool {
        defer { isDue = false }
        return isDue
    }
}

/// A database import that waits for a Keep at logout to publish: shown with the
/// existing import error; a full disk with the system's own wording.
public struct LibraryImportBlocked: Error, Equatable, LocalizedError {
    public var keep: KeepFailure
    public var errorDescription: String? {
        keep == .storage ? CocoaError(.fileWriteOutOfSpace).localizedDescription : nil
    }
}

/// The order of a Keep at logout run while the app is in use (PROTOCOL §15.4): the library gate exclusively, then
/// the activation rule again while holding it and, in the same synchronous step, the graph's command admission
/// retired, as an ordinary switch does, so nothing admitted after the check can be stopped by the Keep. Only then
/// the waits (the account-policy writes, the graph's stop with the downloads detached), the Keep's phases, the gate
/// released and the graph started again, whatever the outcome.
@MainActor public struct LibraryKeepRuntime {
    public var gate: LibraryGate
    /// The activation rule holds, in the foreground, and a Keep is pending.
    public var mayRun: @MainActor () -> Bool
    /// Closes the graph's command admission; synchronous.
    public var retire: @MainActor () -> Void
    /// Lets what the graph must finish settle, then stops it.
    public var stop: @MainActor () async -> Void
    /// The Keep's phases.
    public var keep: @MainActor () -> Void
    public var restart: @MainActor () -> Void

    public init(gate: LibraryGate, mayRun: @escaping @MainActor () -> Bool, retire: @escaping @MainActor () -> Void,
                stop: @escaping @MainActor () async -> Void, keep: @escaping @MainActor () -> Void, restart: @escaping @MainActor () -> Void) {
        self.gate = gate; self.mayRun = mayRun; self.retire = retire; self.stop = stop; self.keep = keep; self.restart = restart
    }

    /// Returns whether the Keep ran.
    @discardableResult public func run() async -> Bool {
        await gate.acquireExclusive()
        guard mayRun() else { gate.releaseExclusive(); return false }
        retire()
        await stop()
        keep()
        gate.releaseExclusive()
        restart()
        return true
    }
}
