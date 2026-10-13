import Foundation

/// A verified attach snapshot (PROTOCOL §15.4, §6.4), spooled page by page into the new
/// library's `staging/attach/` folder so a large account never has to fit in memory. Its items are read back in
/// snapshot order with framed items reassembled.
public struct ServerAttachSnapshot: Sendable {
    /// The view's head cursor: the cursor the library continues from once the snapshot is applied.
    public let head: String
    public let installWatermark: Int64
    public let itemCount: Int
    /// Podcasts the account holds (a `podcast` `subscription` record whose state is not `removed`).
    public let podcastCount: Int
    let pages: [URL]

    /// An account with no podcast: first attachment asks before going on (PROTOCOL §15.5, "Attachment, empty account").
    public var isEmptyAccount: Bool { podcastCount == 0 }

    /// Every item of the snapshot in order: `{accepted}`, `{decision}` and `{record}` objects.
    public func forEachItem(_ body: (ContractJSON) throws -> Void) throws {
        // A framed item: its parts in order, consecutive (PROTOCOL §6.4).
        var parts: (index: Int64, count: Int64, next: Int64, bytes: [UInt8])?
        for page in pages {
            let decoded = try ContractJSON.decode(Data(contentsOf: page))
            for item in decoded["items"]?.arrayValue ?? [] {
                guard let part = item["item_part"] else {
                    guard parts == nil else { throw ServerSnapshotError.invalidSnapshot("an unfinished framed item") }
                    try body(item); continue
                }
                guard let index = part["index"]?.integerValue, let partIndex = part["part_index"]?.integerValue,
                      let count = part["part_count"]?.integerValue, count >= 1, let data = part["data"]?.stringValue else {
                    throw ServerSnapshotError.invalidSnapshot("a malformed item part")
                }
                let bytes = try ContractBase64URL.decode(data)
                if partIndex == 0, parts == nil {
                    parts = (index, count, 1, bytes)
                } else if var current = parts, current.index == index, current.count == count, current.next == partIndex {
                    current.bytes += bytes; current.next += 1
                    parts = current
                } else { throw ServerSnapshotError.invalidSnapshot("an item part out of order") }
                if let current = parts, current.next == current.count {
                    parts = nil
                    try body(try ContractJSON.decode(current.bytes))
                }
            }
        }
        guard parts == nil else { throw ServerSnapshotError.invalidSnapshot("an unfinished framed item") }
    }
}

public enum ServerSnapshotError: Error, Equatable, Sendable {
    case invalidSnapshot(String)
    /// The manifest's item count or digest does not match the items (PROTOCOL §15.4).
    case verificationFailed
}

/// Downloads an attach snapshot (PROTOCOL §15.4): `POST /v1/snapshot {mode: attach, install_id, acked_install_seq: 0}`,
/// pages spooled until `has_more` is false, then the manifest's item count and `snapshot_digest` checked over the
/// whole (reassembled) items. `view_expired` restarts from the beginning, discarding what was staged.
public struct ServerAttachSnapshotDownload: Sendable {
    public let client: ServerClient
    public let token: String
    public let installID: String
    /// `staging/attach/` of the new library.
    public let folder: URL

    public init(client: ServerClient, token: String, installID: String, folder: URL) {
        self.client = client; self.token = token; self.installID = installID; self.folder = folder
    }

    /// `progress` receives the number of items received so far.
    public func run(progress: @Sendable (Int) async -> Void = { _ in }) async throws -> ServerAttachSnapshot {
        let client = client, token = token, installID = installID
        return try await ServerSnapshotDownload(folder: folder, fetch: { page in
            try await client.snapshotPage(token: token, installID: installID, page: page)
        }, isViewExpired: { ($0 as? ServerClientError) == .viewExpired }).run(progress: progress)
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}

/// A snapshot of any mode (PROTOCOL §6.4), spooled page by page into `folder` and verified: the manifest's item
/// count and `snapshot_digest` over the whole (reassembled) items. `view_expired` restarts from the beginning,
/// discarding what was staged. First attachment (PROTOCOL §15.4) and Force full synchronization (PROTOCOL §6.14) use it.
struct ServerSnapshotDownload: Sendable {
    let folder: URL
    /// One page: the request's first page (nil) or the page a token names.
    let fetch: @Sendable (String?) async throws -> ContractJSON
    let isViewExpired: @Sendable (any Error) -> Bool

    func run(progress: @Sendable (Int) async -> Void = { _ in }) async throws -> ServerAttachSnapshot {
        for round in 0..<3 {
            do { return try await attempt(progress: progress) }
            catch where isViewExpired(error) && round < 2 { continue }
        }
        throw ServerClientError.viewExpired
    }

    private func attempt(progress: @Sendable (Int) async -> Void) async throws -> ServerAttachSnapshot {
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var pages: [URL] = [], received = 0, page: String?
        var last: ContractJSON
        repeat {
            try Task.checkCancellation()
            last = try await fetch(page)
            let url = folder.appendingPathComponent(String(format: "page-%06d.json", pages.count + 1))
            try last.canonicalData().write(to: url, options: .atomic)
            pages.append(url)
            received += last["items"]?.arrayValue?.count ?? 0
            await progress(received)
            if last["has_more"]?.boolValue == true {
                guard let next = last["next"]?.stringValue, !next.isEmpty else {
                    throw ServerSnapshotError.invalidSnapshot("a page without a next token")
                }
                page = next
            } else { page = nil }
        } while page != nil
        guard let head = last["head"]?.stringValue, (try? SyncCursor(encoded: head)) != nil,
              let manifest = last["manifest"], let expectedCount = manifest["item_count"]?.integerValue,
              let expectedDigest = manifest["snapshot_digest"]?.stringValue else {
            throw ServerSnapshotError.invalidSnapshot("the last page has no head or manifest")
        }
        let snapshot = ServerAttachSnapshot(head: head, installWatermark: last["install_watermark"]?.integerValue ?? 0,
                                            itemCount: 0, podcastCount: 0, pages: pages)
        var digest = ContractHash.zeroDigest, count: Int64 = 0
        var live = Set<String>()
        try snapshot.forEachItem { item in
            digest = try ContractHash.nextDigest(previous: digest, item)
            count += 1
            if let record = item["record"], record["entity"]?.stringValue == "podcast",
               record["field_group"]?.stringValue == "subscription", let id = record["id"]?.stringValue {
                if let state = record["value"]?["state"]?.stringValue, state != "removed" { live.insert(id) }
            }
        }
        guard count == expectedCount, ServerAttachSnapshotDownload.hex(digest) == expectedDigest else { throw ServerSnapshotError.verificationFailed }
        return ServerAttachSnapshot(head: head, installWatermark: snapshot.installWatermark, itemCount: Int(count),
                                    podcastCount: live.count, pages: pages)
    }
}

/// Builds a new server library from its verified attach snapshot (PROTOCOL §15.4–7: archive, nodes, records to rows in
/// one transaction, the cursor, secrets, download reuse and catch-up by pulls). The exchange implements it; the
/// library is not live yet, so it needs no unit discipline.
///
/// Contract: `apply` is called with the library provisioned (schema 19, its `ntp_library` row) and its store closed.
/// It is idempotent and throws on failure; the library then stays `attaching` (a crash too), and the next attempt
/// downloads the snapshot again and calls it again on the same library. The account service owns the registry state
/// and the switch.
public protocol ServerAttachSnapshotApplier: Sendable {
    func apply(_ snapshot: ServerAttachSnapshot, to library: ServerAttachmentTarget) async throws
}

/// The library an attachment builds.
public struct ServerAttachmentTarget: Sendable {
    public let location: LibraryLocation
    public let libraryID: String
    public let installID: String
    public let token: String
    public let client: ServerClient

    public init(location: LibraryLocation, libraryID: String, installID: String, token: String, client: ServerClient) {
        self.location = location; self.libraryID = libraryID; self.installID = installID; self.token = token; self.client = client
    }
}

public enum ServerAttachmentError: Error, Equatable, Sendable {
    /// The applier could not project the account's library yet; the library stays attaching and retries.
    case projectionUnavailable
}

