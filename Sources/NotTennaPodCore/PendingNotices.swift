import Foundation
import Synchronization

/// What became of work the system ended (an interrupted database import or export), kept durably until a
/// person has actually seen it: `pending-notices.json` in the root folder, one entry per attempt. Recovery records an
/// outcome here before it resolves its own record (by the attempt's identity, so recording twice is harmless); a
/// background launch, a failed graph start or a notice waiting behind another never removes it; only its visible
/// presentation in the foreground does (`acknowledge`).
public struct PendingNotice: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// The interrupted database import had been published: it was completed.
        case importCompleted
        /// The database import never reached its commit: rolled back, the library unchanged.
        case importRolledBack
        /// An export's location never reached the app.
        case exportLocationUnknown
        /// The export to the named document may be incomplete.
        case exportMayBeIncomplete
    }
    public var id: UUID
    public var kind: Kind
    /// The document's name, for `exportMayBeIncomplete`.
    public var name: String?

    public init(id: UUID, kind: Kind, name: String? = nil) {
        self.id = id; self.kind = kind; self.name = name
    }
}

public final class PendingNotices: Sendable {
    public static let fileName = "pending-notices.json"
    public let file: URL
    private let lock = Mutex(())

    /// The notices not yet seen, and the attempts whose notice was seen while their own record is not resolved yet: so
    /// recording such an attempt again (its record could not say it was recorded) never shows it a second time.
    private struct Contents: Codable {
        var pending: [PendingNotice] = []
        var acknowledged: [UUID] = []
    }

    public init(root: URL) {
        file = root.appendingPathComponent(Self.fileName)
    }

    /// The notices not yet seen, oldest first. Throws when the file cannot be read now.
    public func all() throws -> [PendingNotice] {
        try lock.withLock { _ in try read().pending }
    }

    /// Records `notice` (once per attempt; never again once seen). Throws when it cannot be saved: the caller keeps its
    /// own record then.
    public func add(_ notice: PendingNotice) throws {
        try lock.withLock { _ in
            var contents = try read()
            guard !contents.pending.contains(where: { $0.id == notice.id }), !contents.acknowledged.contains(notice.id) else { return }
            contents.pending.append(notice)
            try write(contents)
        }
    }

    /// The notice was presented where the person sees it.
    public func acknowledge(_ id: UUID) throws {
        try lock.withLock { _ in
            var contents = try read()
            guard contents.pending.contains(where: { $0.id == id }) else { return }
            contents.pending.removeAll { $0.id == id }
            contents.acknowledged.append(id)
            try write(contents)
        }
    }

    /// The attempt's own record is gone: nothing can record it again, so its acknowledgement need not be kept.
    public func resolved(_ id: UUID) throws {
        try lock.withLock { _ in
            var contents = try read()
            guard contents.acknowledged.contains(id) else { return }
            contents.acknowledged.removeAll { $0 == id }
            try write(contents)
        }
    }

    private func read() throws -> Contents {
        guard let data = try SavedState.contents(of: file) else { return Contents() }
        // Written atomically, so never partial; damaged content holds nothing that can still be shown.
        return (try? JSONDecoder().decode(Contents.self, from: data)) ?? Contents()
    }

    private func write(_ contents: Contents) throws {
        if contents.pending.isEmpty && contents.acknowledged.isEmpty {
            if try SavedState.isPresent(file) { try FileManager.default.removeItem(at: file) }
            return
        }
        try JSONEncoder().encode(contents).write(to: file, options: .atomic)
    }
}
