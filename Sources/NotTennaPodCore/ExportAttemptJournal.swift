import CryptoKit
import Foundation
import Synchronization
import os

/// A manual export's durable record: written before the Save picker is presented, with its destination unknown;
/// the picked document's name and access (a bookmark) are added before any payload work, and the payload's size and
/// SHA-256 digest before it is published. Resolved (removed) when the picker is cancelled, after a verified
/// publication, or after a failure the person was shown.
public struct ExportAttempt: Codable, Equatable, Sendable {
    public var id: UUID
    /// The suggested file name.
    public var name: String
    public var destinationName: String?
    /// The picked document's access; nil when the provider gave none (the export's outcome then cannot be checked
    /// later, so an interruption is always reported).
    public var destinationBookmark: Data?
    /// The payload's size and digest (hexadecimal SHA-256), recorded before publication.
    public var expectedSize: Int64?
    public var expectedDigest: String?

    /// The digest the record keeps for `data`.
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// The records of manual exports (`Export Attempts/` in the root folder), one file per attempt, written atomically.
public final class ExportAttemptJournal: Sendable {
    public static let folderName = "Export Attempts"
    public let folder: URL
    /// Attempts this process began: a graph start later in the same process never takes them for interrupted ones.
    private static let ownedByThisProcess = Mutex<Set<UUID>>([])
    /// Tests: the process ended (what it was exporting is now an interrupted export).
    static func simulateProcessEnd() { ownedByThisProcess.withLock { $0 = [] } }

    private let makeBookmark: @Sendable (URL) throws -> Data

    public init(root: URL, makeBookmark: @escaping @Sendable (URL) throws -> Data = {
        try $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }) {
        folder = root.appendingPathComponent(Self.folderName, isDirectory: true)
        self.makeBookmark = makeBookmark
    }

    private func file(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }

    private func write(_ attempt: ExportAttempt) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(attempt).write(to: file(attempt.id), options: .atomic)
    }

    private func read(_ id: UUID) throws -> ExportAttempt {
        try JSONDecoder().decode(ExportAttempt.self, from: Data(contentsOf: file(id)))
    }

    /// Before the picker is presented: the attempt, its destination unknown.
    public func begin(name: String) throws -> UUID {
        let attempt = ExportAttempt(id: UUID(), name: name)
        Self.ownedByThisProcess.withLock { _ = $0.insert(attempt.id) }
        try write(attempt)
        return attempt.id
    }

    /// The picker returned: the document's name and access, before any payload work. Throws when the record cannot be
    /// saved: the export must not start without it. A provider that gives no bookmark is recorded as such, and an
    /// interruption of that export is then always reported (its result cannot be checked).
    public func chose(_ id: UUID, destination: URL) throws {
        var attempt = try read(id)
        attempt.destinationName = destination.lastPathComponent
        do { attempt.destinationBookmark = try makeBookmark(destination) }
        catch {
            attempt.destinationBookmark = nil
            Logger(subsystem: "org.nottennapod.app", category: "Export").notice("No bookmark for the export's document; an interruption is reported")
        }
        try write(attempt)
    }

    /// The payload is staged and verified: its size and digest, before it is published. Throws when the record cannot
    /// be saved: nothing is published without it.
    public func publishing(_ id: UUID, payload: Data) throws {
        var attempt = try read(id)
        attempt.expectedSize = Int64(payload.count)
        attempt.expectedDigest = ExportAttempt.digest(payload)
        try write(attempt)
    }

    /// Cancelled, published and verified, or its failure shown.
    public func resolve(_ id: UUID) {
        do {
            if try SavedState.isPresent(file(id)) { try FileManager.default.removeItem(at: file(id)) }
            Self.ownedByThisProcess.withLock { _ = $0.remove(id) }
        } catch {
            Logger(subsystem: "org.nottennapod.app", category: "Export").error("Export record kept for the next launch")
        }
    }

    /// At a graph start: the attempts an earlier process never resolved. What became of each is recorded for the person
    /// (`PendingNotices`, until it is actually presented) before its record goes; when that cannot be saved now, the
    /// record stays. One whose picked document holds exactly the payload was published before the process ended, and is
    /// resolved silently.
    public func recover(notices: PendingNotices) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        let owned = Self.ownedByThisProcess.withLock { $0 }
        for name in names.sorted() where name.hasSuffix(".json") {
            guard let id = UUID(uuidString: String(name.dropLast(5))), !owned.contains(id) else { continue }
            let url = file(id)
            guard let data = try? Data(contentsOf: url) else { continue } // Cannot be read now: a later start.
            if let attempt = try? JSONDecoder().decode(ExportAttempt.self, from: data) {
                let notice: PendingNotice? = if let destination = attempt.destinationName {
                    Self.isPublished(attempt) ? nil : PendingNotice(id: id, kind: .exportMayBeIncomplete, name: destination)
                } else {
                    PendingNotice(id: id, kind: .exportLocationUnknown)
                }
                if let notice {
                    do { try notices.add(notice) } catch { continue }
                }
            }
            if (try? FileManager.default.removeItem(at: url)) != nil { try? notices.resolved(id) }
        }
    }

    /// The picked document, reached through its bookmark, holds exactly the payload: its size, then its bytes against
    /// the recorded digest. Anything that cannot be proved (no bookmark or digest, content kept only in the cloud, which
    /// is not downloaded for this, a read that fails) is not published.
    private static func isPublished(_ attempt: ExportAttempt) -> Bool {
        guard let expected = attempt.expectedSize, let digest = attempt.expectedDigest, let bookmark = attempt.destinationBookmark else {
            return false
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return false
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values?.fileSize.map(Int64.init) == expected else { return false }
        if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus == .notDownloaded { return false }
        guard let reader = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? reader.close() }
        var hash = SHA256(), total: Int64 = 0
        while let piece = try? reader.read(upToCount: 1 << 20), !piece.isEmpty {
            hash.update(data: piece); total += Int64(piece.count)
        }
        return total == expected && hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest
    }
}
