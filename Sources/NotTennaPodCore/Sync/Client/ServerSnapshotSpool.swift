import Foundation

/// What a spooled snapshot was asked for (PROTOCOL §6.4): a spool is resumed or reused only for exactly the same request.
/// The library folder already fixes the server and the account.
struct ServerSnapshotIdentity: Codable, Equatable, Sendable {
    /// `attach`, `upgrade` (Force full synchronization) or `recovery`.
    var mode: String
    var installID: String
    var recoveryID: String?
    /// The request cursor's lineage (`upgrade`, `recovery`).
    var logID: String?
    var epoch: Int64?
    /// Nil: every field group.
    var fieldGroups: [String]?

    enum CodingKeys: String, CodingKey {
        case mode, installID = "install_id", recoveryID = "recovery_id", logID = "log_id", epoch, fieldGroups = "field_groups"
    }
}

/// A spool's `manifest.json`: written after each page (atomically, after the page itself), so a stopped download
/// continues from the last page it lists.
struct ServerSnapshotManifest: Codable, Equatable, Sendable {
    struct Page: Codable, Equatable, Sendable {
        var file: String
        var sha256: String
        var items: Int
        var bytes: Int64
        /// The token of the page after this one; nil on the last page.
        var next: String?
    }

    var version = 1
    var identity: ServerSnapshotIdentity
    /// The view's head, from its first page: what a Force full synchronization publishes (its fence).
    var targetHead: String?
    var pages: [Page] = []
    /// The last page (`has_more: false`) is listed. Never trusted on its own: the spool is verified before any use.
    var complete = false
    /// When a page last arrived (milliseconds since 1970).
    var lastActivity: Int64 = 0
    /// The snapshot's records with a value, once verified: the base it stages (whether it may be staged while audio
    /// plays is decided by it, before anything is verified or staged again).
    var records: Int?

    var bytes: Int64 { pages.reduce(0) { $0 + $1.bytes } }

    enum CodingKeys: String, CodingKey {
        case version, identity, targetHead = "target_head", pages, complete, lastActivity = "last_activity", records
    }
}

/// Bulk sync work stopped because it would eat into the space the app keeps for its own writes (PROTOCOL §6.4 local
/// policy): the verified pages stay, and it continues once space was freed.
public struct ServerInsufficientSpace: Error, Equatable, Sendable {
    /// Bytes more free space needed.
    public var shortfall: Int64
}

/// Free space and the reserve bulk sync work never uses (Force full synchronization, attach and recovery snapshots):
/// checkpoints, downloads and the library's own writes keep `reserve`.
public struct ServerBulkDiskPolicy: Sendable {
    /// Bytes free on `url`'s volume for important use; nil when unknown (then nothing is refused).
    public var available: @Sendable (URL) -> Int64?
    public var reserve: Int64 = 1 << 30
    /// Kept besides the reserve at every armed write gate (SQLite's own bookkeeping).
    public var margin: Int64 = 64 << 20
    /// Start without a size estimate (a first attachment or recovery): this much free beyond the reserve.
    public var unknownAdmission: Int64 = 2 << 30
    /// The staging and build need per spooled byte, checked before every page so a download that could never be
    /// staged stops early. Only an estimate: staging alone measured 1.27 on a synthetic 26,271-episode library (the
    /// build's images were not measured); the write gate, not this factor, keeps the reserve.
    public var expansion = 1.6

    public init(available: @escaping @Sendable (URL) -> Int64? = ServerBulkDiskPolicy.volumeAvailable) { self.available = available }

    public static let volumeAvailable: @Sendable (URL) -> Int64? = { url in
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        guard let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }

    /// Throws `ServerInsufficientSpace` unless `need` more bytes leave the reserve free.
    public func check(_ need: Int64, at url: URL) throws {
        guard let free = available(url) else { return }
        let required = reserve + max(0, need)
        if free < required { throw ServerInsufficientSpace(shortfall: required - free) }
    }

    /// Admission before a download starts: with an estimate, room for 2.5 times it (what is spooled already counts as
    /// used); without one, `unknownAdmission`.
    public func admit(estimate: Int64?, spooled: Int64, at url: URL) throws {
        let need = estimate.map { Int64(Double($0) * 2.5) - spooled } ?? unknownAdmission
        try check(need, at: url)
    }

    /// Sets `spool`'s admission (with `estimate`, nil: unknown) and its check before every page: the page, and the
    /// staging and build the spooled bytes will need, leave the reserve free.
    func guarding(_ spool: inout ServerSnapshotSpool, estimate: Int64?) {
        let policy = self, folder = spool.folder
        spool.admission = { spooled in try policy.admit(estimate: estimate, spooled: spooled, at: folder) }
        spool.beforeWrite = { page, spooled in try policy.check(page + Int64(policy.expansion * Double(spooled + page)), at: folder) }
    }

    /// What the write gate may let bulk SQLite work add now: free space less the reserve and the margin.
    public func budget(at url: URL) -> Int64? {
        guard let free = available(url) else { return nil }
        return max(0, free - reserve - margin)
    }
}

/// A snapshot of any mode (PROTOCOL §6.4) spooled page by page into `folder` and verified before use: the last page's
/// item count and `snapshot_digest` over the whole (reassembled) items. First attachment (PROTOCOL §15.4), Force full
/// synchronization (PROTOCOL §6.14) and a recovery's full snapshot (PROTOCOL §6.11) use it.
///
/// Resumable: each page is written (synced, renamed) before the manifest lists it, and a spool for the same request
/// continues from its last listed page's token, which the server honours as long as its view lives (`view_expired`
/// decides: no age rule). A complete spool needs no view; it is verified again at every reopen before use. A page the
/// manifest does not list (an interrupted write) is deleted; a listed page that is missing or altered truncates the
/// spool there. A spool that fails verification is deleted at once (the caller backs off), never verified in a loop.
struct ServerSnapshotSpool: Sendable {
    let folder: URL
    let identity: ServerSnapshotIdentity
    /// One page: the request's first page (nil) or the page a token names.
    let fetch: @Sendable (String?) async throws -> ContractJSON
    /// Whether a failure means the view is gone: start again from the first page. `resumed`: the token came from the
    /// manifest of an earlier run (a token the server no longer accepts, `invalid_request`, starts again too).
    let restarts: @Sendable (_ error: any Error, _ resumed: Bool) -> Bool
    var clock: @Sendable () -> Date = { Date() }
    /// Before each page request (and never for a complete spool): the network may refuse bulk work now.
    var beforeRequest: @Sendable () async throws -> Void = {}
    /// Before a download starts or continues (never for a complete spool), with what is spooled already: throws
    /// `ServerInsufficientSpace` when it may not start.
    var admission: @Sendable (_ spooled: Int64) throws -> Void = { _ in }
    /// Before each page is written, with its size and what is spooled already: throws `ServerInsufficientSpace`.
    var beforeWrite: @Sendable (_ page: Int64, _ spooled: Int64) throws -> Void = { _, _ in }
    /// Once the first page named the view's head.
    var onTarget: @Sendable (String) async -> Void = { _ in }

    static let manifestName = "manifest.json"

    /// The verified snapshot: reused when complete, else continued (or started) and verified. `progress` receives
    /// the number of items received so far.
    func run(progress: @Sendable (Int) async -> Void = { _ in }) async throws -> ServerAttachSnapshot {
        for _ in 0..<3 {
            do { return try await attempt(progress: progress) }
            catch is Restart { Self.remove(folder) }
        }
        throw ServerClientError.viewExpired
    }

    private struct Restart: Error {}

    /// The manifest of a spool whose identity matches, its pages checked; nil when there is none (anything else in the
    /// folder is removed). What failed the check is removed and the manifest truncated before it.
    func reopen() throws -> ServerSnapshotManifest? {
        guard let manifest = Self.manifest(in: folder) else { Self.remove(folder); return nil }
        guard manifest.identity == identity else { Self.remove(folder); return nil }
        var kept = manifest
        for (index, page) in manifest.pages.enumerated() {
            let url = folder.appendingPathComponent(page.file)
            guard let data = try? Data(contentsOf: url), ContractIdentity.sha256Hex(Array(data)) == page.sha256 else {
                kept.pages = Array(manifest.pages.prefix(index))
                kept.complete = false
                break
            }
        }
        if kept.pages.isEmpty { kept.targetHead = nil }
        let listed = Set(kept.pages.map(\.file) + [Self.manifestName])
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !listed.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        if kept != manifest { try Self.save(kept, in: folder) }
        return kept
    }

    private func attempt(progress: @Sendable (Int) async -> Void) async throws -> ServerAttachSnapshot {
        var manifest = try reopen() ?? ServerSnapshotManifest(identity: identity)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if manifest.pages.isEmpty { try Self.save(manifest, in: folder) }
        var received = manifest.pages.reduce(0) { $0 + $1.items }
        if !manifest.complete {
            try admission(manifest.bytes)
            var token = manifest.pages.last?.next
            let resumedFrom = token
            if let head = manifest.targetHead { await onTarget(head) }
            repeat {
                try Task.checkCancellation()
                try await beforeRequest()
                let page: ContractJSON
                do { page = try await fetch(token) }
                catch where restarts(error, token != nil && token == resumedFrom) { throw Restart() }
                try Task.checkCancellation()
                guard let head = page["head"]?.stringValue, (try? SyncCursor(encoded: head)) != nil else {
                    throw ServerSnapshotError.invalidSnapshot("a page without its head")
                }
                // Every page is of the same view: a page of another one starts again.
                if let target = manifest.targetHead, target != head { throw Restart() }
                let data = try page.canonicalData()
                try beforeWrite(Int64(data.count), manifest.bytes)
                let more = page["has_more"]?.boolValue == true
                var next: String?
                if more {
                    guard let value = page["next"]?.stringValue, !value.isEmpty else {
                        throw ServerSnapshotError.invalidSnapshot("a page without a next token")
                    }
                    next = value
                }
                let name = String(format: "page-%06d.json", manifest.pages.count + 1)
                try Self.durableWrite(data, to: folder.appendingPathComponent(name))
                let items = page["items"]?.arrayValue?.count ?? 0
                manifest.pages.append(.init(file: name, sha256: ContractIdentity.sha256Hex(Array(data)), items: items, bytes: Int64(data.count), next: next))
                let first = manifest.targetHead == nil
                manifest.targetHead = head
                manifest.complete = !more
                manifest.lastActivity = Int64(clock().timeIntervalSince1970 * 1_000)
                try Self.save(manifest, in: folder)
                if first { await onTarget(head) }
                received += items
                await progress(received)
                token = next
            } while !manifest.complete
        } else {
            await progress(received)
        }
        do {
            let snapshot = try Self.verify(manifest, in: folder)
            if manifest.records != snapshot.records {
                manifest.records = snapshot.records
                try? Self.save(manifest, in: folder)
            }
            return snapshot
        } catch {
            // Deleted at once: the same invalid spool is never verified again; the caller backs off.
            Self.remove(folder)
            throw error
        }
    }

    /// The spool's snapshot, checked against the last page's manifest (item count and digest chain over every
    /// reassembled item).
    static func verify(_ manifest: ServerSnapshotManifest, in folder: URL) throws -> ServerAttachSnapshot {
        guard manifest.complete, let lastPage = manifest.pages.last, lastPage.next == nil else { throw ServerSnapshotError.verificationFailed }
        let pages = manifest.pages.map { folder.appendingPathComponent($0.file) }
        let last = try ContractJSON.decode(Data(contentsOf: pages[pages.count - 1]))
        guard let head = last["head"]?.stringValue, (try? SyncCursor(encoded: head)) != nil,
              let summary = last["manifest"], let expectedCount = summary["item_count"]?.integerValue,
              let expectedDigest = summary["snapshot_digest"]?.stringValue else {
            throw ServerSnapshotError.invalidSnapshot("the last page has no head or manifest")
        }
        let unverified = ServerAttachSnapshot(head: head, installWatermark: last["install_watermark"]?.integerValue ?? 0,
                                              itemCount: 0, podcastCount: 0, pages: pages)
        var digest = ContractHash.zeroDigest, count: Int64 = 0, records = 0
        var live = Set<String>()
        do {
            try unverified.forEachItem { item in
                digest = try ContractHash.nextDigest(previous: digest, item)
                count += 1
                if let value = item["record"]?["value"], value != .null { records += 1 }
                if let record = item["record"], record["entity"]?.stringValue == "podcast",
                   record["field_group"]?.stringValue == "subscription", let id = record["id"]?.stringValue {
                    if let state = record["value"]?["state"]?.stringValue, state != "removed" { live.insert(id) }
                }
            }
        } catch is ServerSnapshotError { throw ServerSnapshotError.verificationFailed }
        guard count == expectedCount, ServerAttachSnapshotDownload.hex(digest) == expectedDigest else { throw ServerSnapshotError.verificationFailed }
        var snapshot = ServerAttachSnapshot(head: head, installWatermark: unverified.installWatermark, itemCount: Int(count),
                                            podcastCount: live.count, pages: pages)
        snapshot.bytes = manifest.bytes
        snapshot.records = records
        return snapshot
    }

    // MARK: - Files

    static func manifest(in folder: URL) -> ServerSnapshotManifest? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(manifestName)) else { return nil }
        return try? JSONDecoder().decode(ServerSnapshotManifest.self, from: data)
    }

    static func save(_ manifest: ServerSnapshotManifest, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try durableWrite(try encoder.encode(manifest), to: folder.appendingPathComponent(manifestName))
    }

    static func remove(_ folder: URL) { try? FileManager.default.removeItem(at: folder) }

    /// Written to a temporary file, synced, renamed over `url`, and the folder synced: after a crash `url` is either
    /// the old file or the whole new one.
    static func durableWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try? FileManager.default.removeItem(at: temporary)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            // The disk filled up (another app wrote meanwhile): the spool stays as it was.
            let failure = error as NSError
            if failure.code == NSFileWriteOutOfSpaceError || (failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOSPC)) {
                throw ServerInsufficientSpace(shortfall: Int64(data.count))
            }
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY)
        if directory >= 0 { fsync(directory); close(directory) }
    }
}
