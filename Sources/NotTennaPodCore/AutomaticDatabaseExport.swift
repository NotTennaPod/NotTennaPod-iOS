import Foundation
import Synchronization

/// Source `AutomaticDatabaseExportWorker` (storage/importexport/…/AutomaticDatabaseExportWorker.java):
/// every 3 days write `NotTennaPodBackup-yyyy-MM-dd.db` (the Android database backup) into the chosen
/// folder, then keep only the 5 most recently modified matching backups.
public enum AutomaticDatabaseExport {
    /// `PeriodicWorkRequest.Builder(…, 3, TimeUnit.DAYS)`.
    public static let interval: TimeInterval = 3 * 24 * 60 * 60
    /// Worker `:92–98`: keep the 5 newest, including the new backup.
    public static let kept = 5

    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        case openFolder, createFile, deleteSome
        case incompleteWrite(expected: Int64, actual: Int64)
        case other(String)
        /// A rename found a file of that name: the next free name is tried (never shown).
        case nameTaken

        /// Source exception texts (hard-coded English on Android as well).
        public var errorDescription: String? {
            switch self {
            case .openFolder: "Unable to open export folder"
            case .createFile: "Unable to create export file"
            case .deleteSome: "Unable to delete some database backup files"
            case .incompleteWrite(let expected, let actual):
                "Unable to write entire database. Expected to write \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)), but wrote \(ByteCountFormatter.string(fromByteCount: max(0, actual), countStyle: .file))."
            case .other(let message): message
            case .nameTaken: "Unable to create export file"
            }
        }
    }

    /// `String.format("NotTennaPodBackup-%s.db", SimpleDateFormat("yyyy-MM-dd", Locale.US))` at run time.
    public static func filename(at date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd"
        return "NotTennaPodBackup-\(formatter.string(from: date)).db"
    }

    /// Worker `:84–90` pattern, whole name, case-sensitive, ASCII digits only.
    public static func isBackupName(_ name: String) -> Bool {
        let units = Array(name.utf8), prefix = Array("NotTennaPodBackup-".utf8), suffix = Array(".db".utf8)
        guard units.count == prefix.count + 10 + suffix.count, units.starts(with: prefix), units.suffix(3).elementsEqual(suffix) else { return false }
        let date = units[prefix.count..<(prefix.count + 10)]
        return date.enumerated().allSatisfy { index, unit in
            index == 4 || index == 7 ? unit == UInt8(ascii: "-") : (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(unit)
        }
    }

    /// Never overwrite; the stock Android local provider's ` (n)` naming for a collision.
    public static func uniqueName(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let stem = String(name.dropLast(3))
        var index = 1
        while existing.contains("\(stem) (\(index)).db") { index += 1 }
        return "\(stem) (\(index)).db"
    }

    /// The next backup is due 3 days after the last run (successful or failed).
    /// A last run in the future (clock moved back) counts from now.
    public static func nextDue(lastRun: Date?, now: Date) -> Date {
        guard let lastRun else { return now }
        return min(lastRun, now).addingTimeInterval(interval)
    }
    public static func isDue(lastRun: Date?, now: Date) -> Bool { now >= nextDue(lastRun: lastRun, now: now) }

    /// One run (worker `export`, `:71–102`), safe against an end at any point: folder check; an earlier
    /// attempt's incomplete file (its process ended, or its write was cancelled) is removed; the complete backup is
    /// written under an incomplete name and verified, then takes its unique dated name (never replacing a file); then
    /// retention over the verified complete backups by modification date. Cancellation is checked before every side
    /// effect, and cancels the folder's coordination where it can: a write already running finishes but is never
    /// published. A failed or cancelled run leaves no new backup; retention runs only after a published one.
    @discardableResult
    public static func run(folder: any AutomaticBackupFolder, now: Date, timeZone: TimeZone, attempt: UUID = UUID(),
                           payload: @Sendable () async throws -> Data) async throws -> String {
        let existing: [AutomaticBackupFolderItem]
        do { existing = try await coordinated(folder) { try folder.list() } }
        catch let error as CancellationError { throw error } catch { throw Failure.openFolder }
        for item in existing where isIncompleteName(item.name) {
            try await coordinated(folder) { try? folder.remove(item.name) }
        }
        try Task.checkCancellation()
        let data: Data
        do { data = try await payload() } catch let error as CancellationError { throw error }
        catch { throw Failure.other((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
        try Task.checkCancellation()
        let staged = incompleteName(attempt)
        try await coordinated(folder) { try folder.create(staged, data: data) }
        let name: String
        do {
            name = try await publish(staged, folder: folder, preferred: filename(at: now, timeZone: timeZone),
                                     existing: Set(existing.map(\.name)))
        } catch {
            // Never published: the incomplete file goes now, or with the next run.
            try? folder.remove(staged)
            throw error
        }
        try Task.checkCancellation()
        let listed: [AutomaticBackupFolderItem]
        do { listed = try await coordinated(folder) { try folder.list() } }
        catch let error as CancellationError { throw error } catch { throw Failure.deleteSome }
        // Only verified complete backups count toward the five kept; pruning starts after the fifth verified survivor.
        // A backup-named file whose content is not on this device (kept only in iCloud: never downloaded to judge it), or
        // that cannot be read, is kept, never counted and never removed; one that is not a whole database (an earlier
        // build ended mid-write) is never counted and goes only once it is older than the fifth verified backup, as on
        // Android. Files of any other name are never touched.
        let backups = listed.filter { $0.isRegularFile && isBackupName($0.name) }.sorted {
            let left = $0.modified ?? Date(timeIntervalSince1970: 0), right = $1.modified ?? Date(timeIntervalSince1970: 0)
            return left == right ? $0.name > $1.name : left > right
        }
        var verified = 0, removals: [AutomaticBackupFolderItem] = []
        for item in backups {
            let verdict: Bool?
            do { verdict = try await coordinated(folder) { try folder.isComplete(item.name) } }
            catch let error as CancellationError { throw error } catch { verdict = nil }
            switch verdict {
            case true?: if verified < kept { verified += 1 } else { removals.append(item) }
            case false?: if verified >= kept { removals.append(item) }
            case nil: break
            }
        }
        var failed = false
        for item in removals {
            try Task.checkCancellation()
            do { try await coordinated(folder) { try folder.remove(item.name) } }
            catch let error as CancellationError { throw error } catch { failed = true }
        }
        if failed { throw Failure.deleteSome }
        return name
    }

    /// The verified file takes the first free dated name (` (n)` on a collision), never replacing a file that appeared
    /// meanwhile; cancellation is checked just before.
    private static func publish(_ staged: String, folder: any AutomaticBackupFolder, preferred: String,
                                existing: Set<String>) async throws -> String {
        var taken = existing
        for _ in 0..<5 {
            try Task.checkCancellation()
            let name = uniqueName(preferred, existing: taken)
            do {
                try await coordinated(folder) { try folder.rename(staged, to: name) }
                return name
            } catch Failure.nameTaken {
                taken.insert(name)
                if let listed = try? await coordinated(folder, { try folder.list() }) { taken.formUnion(listed.map(\.name)) }
            } catch let error as CancellationError {
                throw error
            } catch {
                // The provider refused: reported as the source's creation failure.
                throw Failure.createFile
            }
        }
        throw Failure.createFile
    }

    /// A folder operation with the run's cancellation connected to the folder's coordination.
    private static func coordinated<T>(_ folder: any AutomaticBackupFolder, _ body: () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler { try body() } onCancel: { folder.cancel() }
    }

    /// The name a run writes its backup under until it is verified: visible (no provider has to accept a hidden name),
    /// never a backup name (no `.db`, so retention and Android's pattern never take it), unique per attempt.
    static func incompleteName(_ attempt: UUID) -> String { "NotTennaPodBackup-\(attempt.uuidString).incomplete" }
    /// This app's incomplete files: the visible name, and the hidden one earlier builds used (`.NotTennaPodBackup-…`).
    static func isIncompleteName(_ name: String) -> Bool {
        let suffix = ".incomplete"
        for prefix in ["NotTennaPodBackup-", ".NotTennaPodBackup-"] where name.hasPrefix(prefix) && name.hasSuffix(suffix) {
            if UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))) != nil { return true }
        }
        return false
    }

    /// Whether a file's first 100 bytes and size describe a whole SQLite database: its header's page count (when
    /// valid) times its page size, else whole pages. An empty or truncated file is not a complete backup.
    public static func isCompleteDatabase(header: Data, size: Int64) -> Bool {
        let bytes = [UInt8](header.prefix(100))
        guard bytes.count == 100, bytes.prefix(16).elementsEqual(Array("SQLite format 3\0".utf8)) else { return false }
        func integer(_ offset: Int, _ count: Int) -> Int64 { bytes[offset..<(offset + count)].reduce(0) { $0 << 8 | Int64($1) } }
        let raw = integer(16, 2), pageSize = raw == 1 ? 65_536 : raw
        guard pageSize >= 512, pageSize & (pageSize - 1) == 0, size >= pageSize else { return false }
        let pages = integer(28, 4)
        if pages > 0, integer(92, 4) == integer(24, 4) { return size == pages * pageSize }
        return size % pageSize == 0
    }
}

public struct AutomaticBackupFolderItem: Equatable, Sendable {
    public var name: String
    public var isRegularFile: Bool
    public var modified: Date?
    public init(name: String, isRegularFile: Bool, modified: Date?) {
        self.name = name; self.isRegularFile = isRegularFile; self.modified = modified
    }
}

/// The chosen backup folder (source `DocumentFile` tree).
public protocol AutomaticBackupFolder: Sendable {
    /// Direct children. Throws when the folder cannot be opened or written.
    func list() throws -> [AutomaticBackupFolderItem]
    /// Creates `name`, never overwriting. On return the file is complete and verified, or absent with an error.
    func create(_ name: String, data: Data) throws
    /// `name` takes `newName`, never replacing a file: `Failure.nameTaken` when one has that name.
    func rename(_ name: String, to newName: String) throws
    func remove(_ name: String) throws
    /// Whether `name` holds a whole database; nil when its content is not on this device (reading it would download it).
    func isComplete(_ name: String) throws -> Bool?
    /// The run was cancelled: coordination still waiting stops and nothing new starts; an accessor already running
    /// finishes, and the run never publishes what it wrote.
    func cancel()
}

extension AutomaticBackupFolder {
    public func cancel() {}
}

/// A user-picked folder kept through a bookmark (as local folders are); every operation is coordinated, and the
/// coordination is cancelled with the run (`cancel`): one still waiting stops, and none starts afterwards.
public final class SecurityScopedBackupFolder: AutomaticBackupFolder {
    private let bookmark: Data
    private let refreshed: @Sendable (Data) -> Void
    private final class Coordinator: @unchecked Sendable {
        // `NSFileCoordinator.cancel()` may be called from any thread.
        let value = NSFileCoordinator(filePresenter: nil)
    }
    private let state = Mutex<(cancelled: Bool, active: [ObjectIdentifier: Coordinator])>((false, [:]))
    /// Writes and verification go in pieces, so a cancelled write stops between them.
    static let piece = 1 << 20

    public init(bookmark: Data, refreshed: @escaping @Sendable (Data) -> Void = { _ in }) {
        self.bookmark = bookmark; self.refreshed = refreshed
    }

    private var isCancelled: Bool { state.withLock { $0.cancelled } }

    public func cancel() {
        let active = state.withLock { state -> [Coordinator] in
            state.cancelled = true
            return Array(state.active.values)
        }
        for coordinator in active { coordinator.value.cancel() }
    }

    private func access<T>(_ body: (URL) throws -> T) throws -> T {
        guard !isCancelled else { throw CancellationError() }
        var stale = false
        let folder: URL
        do {
            folder = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutImplicitStartAccessing],
                             relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch { throw AutomaticDatabaseExport.Failure.openFolder }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: folder.path) else { throw AutomaticDatabaseExport.Failure.openFolder }
        if stale, let fresh = try? LocalFolderDocuments.makeBookmark(directory: folder) { refreshed(fresh) }
        return try body(folder)
    }

    /// One coordination, registered for `cancel`. `perform` runs it and returns the accessor's result (nil when the
    /// accessor never ran).
    private func coordinated<T>(_ perform: (NSFileCoordinator, inout NSError?) -> Result<T, any Error>?) throws -> T {
        let coordinator = Coordinator(), key = ObjectIdentifier(coordinator)
        let registered = state.withLock { state -> Bool in
            guard !state.cancelled else { return false }
            state.active[key] = coordinator
            return true
        }
        guard registered else { throw CancellationError() }
        defer { _ = state.withLock { $0.active.removeValue(forKey: key) } }
        var coordinationError: NSError?
        let result = perform(coordinator.value, &coordinationError)
        if let coordinationError { throw isCancelled ? CancellationError() : coordinationError }
        guard let result else { throw isCancelled ? CancellationError() : AutomaticDatabaseExport.Failure.openFolder }
        return try result.get()
    }

    /// An accessor's work, unless the run was cancelled while the accessor waited.
    private func accessing<T>(_ body: () throws -> T) -> Result<T, any Error> {
        isCancelled ? .failure(CancellationError()) : Result { try body() }
    }

    private func coordinate<T>(_ url: URL, writing: Bool, options: NSFileCoordinator.WritingOptions = [],
                               _ body: (URL) throws -> T) throws -> T {
        try coordinated { coordinator, error in
            var result: Result<T, any Error>?
            if writing {
                coordinator.coordinate(writingItemAt: url, options: options, error: &error) { target in result = accessing { try body(target) } }
            } else {
                coordinator.coordinate(readingItemAt: url, options: [], error: &error) { target in result = accessing { try body(target) } }
            }
            return result
        }
    }

    public func list() throws -> [AutomaticBackupFolderItem] {
        try access { folder in
            try coordinate(folder, writing: false) { directory in
                try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])
                    .map { file in
                        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                        return .init(name: file.lastPathComponent, isRegularFile: values?.isRegularFile == true, modified: values?.contentModificationDate)
                    }
            }
        }
    }

    public func create(_ name: String, data: Data) throws {
        try access { folder in
            try coordinate(folder.appendingPathComponent(name), writing: true) { file in
                // Exclusive creation: an existing file is never truncated (FileManager.createFile would).
                guard (try? Data().write(to: file, options: .withoutOverwriting)) != nil,
                      let handle = try? FileHandle(forWritingTo: file) else { throw AutomaticDatabaseExport.Failure.createFile }
                do {
                    var offset = 0
                    while offset < data.count {
                        guard !isCancelled else { throw CancellationError() }
                        let end = min(offset + Self.piece, data.count)
                        try handle.write(contentsOf: data[offset..<end])
                        offset = end
                    }
                    try handle.synchronize(); try handle.close()
                    try verify(file, data)
                } catch {
                    try? handle.close(); try? FileManager.default.removeItem(at: file)  // No partial file.
                    throw error
                }
            }
        }
    }

    /// The written file holds exactly `data`: its size, then its bytes read back.
    private func verify(_ file: URL, _ data: Data) throws {
        let written = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard written == Int64(data.count) else {
            throw AutomaticDatabaseExport.Failure.incompleteWrite(expected: Int64(data.count), actual: written)
        }
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        var offset = 0
        while offset < data.count {
            guard !isCancelled else { throw CancellationError() }
            guard let piece = try reader.read(upToCount: Self.piece), !piece.isEmpty,
                  piece == data[offset..<(offset + piece.count)] else { throw AutomaticDatabaseExport.Failure.createFile }
            offset += piece.count
        }
    }

    public func rename(_ name: String, to newName: String) throws {
        try access { folder in
            let source = folder.appendingPathComponent(name), destination = folder.appendingPathComponent(newName)
            try coordinated { coordinator, error in
                var result: Result<Void, any Error>?
                coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination, options: .forReplacing,
                                       error: &error) { from, to in
                    result = accessing {
                        // Exclusive: a file that has that name is never replaced.
                        guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else {
                            if errno == EEXIST { throw AutomaticDatabaseExport.Failure.nameTaken }
                            throw AutomaticDatabaseExport.Failure.createFile
                        }
                        coordinator.item(at: from, didMoveTo: to)
                    }
                }
                return result
            }
        }
    }

    public func remove(_ name: String) throws {
        try access { folder in
            try coordinate(folder.appendingPathComponent(name), writing: true, options: .forDeleting) { try FileManager.default.removeItem(at: $0) }
        }
    }

    public func isComplete(_ name: String) throws -> Bool? {
        try access { folder in
            let file = folder.appendingPathComponent(name)
            // Content kept only in the cloud: reading it would download it, so it is not judged.
            let values = try? file.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus == .notDownloaded { return nil }
            return try coordinate(file, writing: false) { file in
                let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
                let reader = try FileHandle(forReadingFrom: file)
                defer { try? reader.close() }
                return AutomaticDatabaseExport.isCompleteDatabase(header: try reader.read(upToCount: 100) ?? Data(), size: size)
            }
        }
    }
}

/// Source `prefAutomaticExportFolder` (enabled ⇔ a folder is stored), plus the durable schedule and a
/// pending error for a report that could not be shown. Outside the library, so it
/// survives a database import like Android's SharedPreferences.
public struct AutomaticDatabaseExportPreferences: Codable, Equatable, Sendable {
    public var bookmark: Data?
    public var lastRun: Date?
    public var pendingError: String?
    public var isEnabled: Bool { bookmark != nil }
    public init(bookmark: Data? = nil, lastRun: Date? = nil, pendingError: String? = nil) {
        self.bookmark = bookmark; self.lastRun = lastRun; self.pendingError = pendingError
    }
}

@MainActor public final class AutomaticDatabaseExportPreferenceStore {
    public private(set) var value: AutomaticDatabaseExportPreferences
    private let file: URL
    public init(file: URL) throws {
        self.file = file
        // Damaged content starts from the defaults, as always. A file that cannot be read now (before the first unlock)
        // is thrown, never taken for "no backup folder": defaulting would lose the folder's bookmark at the next save.
        value = try SavedState.contents(of: file)
            .map { (try? JSONDecoder().decode(AutomaticDatabaseExportPreferences.self, from: $0)) ?? .init() } ?? .init()
    }
    public func update(_ change: (inout AutomaticDatabaseExportPreferences) -> Void) throws {
        var next = value; change(&next)
        guard next != value else { return }
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        value = next
    }
}

extension AndroidDatabaseBackup {
    /// The manual and automatic export payload: one consistent library read, then the download log,
    /// stored credentials and speed preferences; a unique temporary file, never a shared path.
    public static func data(library: FeedLibraryStore, speeds: PlaybackSpeedPreferences,
                            credentials: @Sendable (Int64) async throws -> FeedCredentials?) async throws -> Data {
        // One read transaction: feeds, queue, download log and statistics units (PROTOCOL §11.5).
        let contents = try await library.exportContents()
        var stored: [Int64: FeedCredentials] = [:]
        for feed in contents.feeds { if let value = try await credentials(feed.id) { stored[feed.id] = value } }
        return try data(for: LibraryExportSource(contents: contents, speeds: speeds, credentials: stored).backup)
    }
}
