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
    /// The pages' bytes as downloaded (decoded).
    public internal(set) var bytes: Int64 = 0
    /// Its records with a value: the base staging it writes.
    public internal(set) var records = 0

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
/// spooled page by page (`ServerSnapshotSpool`, resumed after an interruption) until `has_more` is false, then the
/// manifest's item count and `snapshot_digest` checked over the whole (reassembled) items. `view_expired` restarts from
/// the beginning, discarding what was staged.
public struct ServerAttachSnapshotDownload: Sendable {
    public let client: ServerClient
    public let token: String
    public let installID: String
    /// `staging/attach/` of the new library.
    public let folder: URL
    /// Checked before each page request (`ServerBulkNetworkWait` when the download may not use the network now); each
    /// page asks the system not to use mobile data or Low Data Mode unless the mobile-data preference allows sync.
    public var network: (any ServerSyncNetworkGate)?
    /// The bulk disk policy: admission before the first page, then a check before every page.
    public var disk: ServerBulkDiskPolicy?

    public init(client: ServerClient, token: String, installID: String, folder: URL) {
        self.client = client; self.token = token; self.installID = installID; self.folder = folder
    }

    /// `progress` receives the number of items received so far.
    public func run(progress: @Sendable (Int) async -> Void = { _ in }) async throws -> ServerAttachSnapshot {
        let client = client, token = token, installID = installID, folder = folder, disk = disk, network = network
        var spool = ServerSnapshotSpool(folder: folder, identity: .init(mode: "attach", installID: installID), fetch: { page in
            try await client.snapshotPage(token: token, installID: installID, page: page, allowsMobile: await network?.allowsMobile() ?? true)
        }, restarts: { error, resumed in
            let failure = error as? ServerClientError
            return failure == .viewExpired || (resumed && failure == .server(status: 400, code: "invalid_request"))
        })
        spool.beforeRequest = {
            if let wait = await network?.bulkWaitReason() { throw ServerBulkNetworkWait(reason: wait) }
        }
        disk?.guarding(&spool, estimate: ServerSnapshotEstimate.read(folder.deletingLastPathComponent())?.bytes)
        let snapshot = try await spool.run(progress: progress)
        ServerSnapshotEstimate.record(snapshot, in: folder.deletingLastPathComponent())
        return snapshot
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}

/// A whole-library download waits for a network it may use (PROTOCOL §15.5): nothing was requested.
public struct ServerBulkNetworkWait: Error, Equatable, Sendable {
    public var reason: ServerNetworkWait
}

/// The size of the last snapshot downloaded into a library (`staging/last-snapshot.json`): the base of the next
/// download's estimate (Force full synchronization's confirmation, the disk admission), scaled by the items now.
struct ServerSnapshotEstimate: Codable, Equatable, Sendable {
    var bytes: Int64
    var items: Int

    static func read(_ staging: URL) -> ServerSnapshotEstimate? {
        guard let data = try? Data(contentsOf: staging.appendingPathComponent("last-snapshot.json")) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func record(_ snapshot: ServerAttachSnapshot, in staging: URL) {
        guard snapshot.bytes > 0, snapshot.itemCount > 0,
              let data = try? JSONEncoder().encode(ServerSnapshotEstimate(bytes: snapshot.bytes, items: snapshot.itemCount)) else { return }
        try? data.write(to: staging.appendingPathComponent("last-snapshot.json"), options: .atomic)
    }

    /// The estimate for a library now holding `items` snapshot items (nil: no earlier download).
    func scaled(to items: Int) -> Int64 {
        guard self.items > 0, items > 0 else { return bytes }
        return Int64((Double(bytes) * Double(items) / Double(self.items)).rounded())
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
    /// The bulk disk policy: the library's archive, base and projection writes are made under its write budget, so they
    /// never use the space the app keeps for its own writes (nil: unlimited).
    public var disk: ServerBulkDiskPolicy?

    public init(location: LibraryLocation, libraryID: String, installID: String, token: String, client: ServerClient,
                disk: ServerBulkDiskPolicy? = nil) {
        self.location = location; self.libraryID = libraryID; self.installID = installID; self.token = token; self.client = client
        self.disk = disk
    }
}

public enum ServerAttachmentError: Error, Equatable, Sendable {
    /// The applier could not project the account's library yet; the library stays attaching and retries.
    case projectionUnavailable
}

