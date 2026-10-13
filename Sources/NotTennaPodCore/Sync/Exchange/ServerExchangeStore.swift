import Foundation

/// Why a server library's exchange is paused (`ntp_library.pause_reason`, PROTOCOL §6.4). Each is
/// shown on the Synchronization page; local use never waits.
public enum ServerPauseReason: String, Sendable, CaseIterable {
    /// `version_unsupported`, for one change or for a whole request (PROTOCOL §10): pushing waits until the server or the
    /// app is updated; pulls continue. Which side needs updating is derived (`ServerExchangeState.appNeedsUpdate`).
    case versionUnsupported = "version_unsupported"
    /// 401 or 403: everything waits for "Sign in again".
    case signIn = "sign_in"
    /// `409 lineage_mismatch`: the server was restored; recovery takes over.
    case lineageMismatch = "lineage_mismatch"
    /// `409 lineage_unknown`: the server no longer has this library's history (PROTOCOL §6.11).
    case lineageUnknown = "lineage_unknown"
    /// `installation_conflict`, or an `installation_superseded` this library did not cause: another library uses this
    /// transport (PROTOCOL §6.10); the installation transition handles it.
    case transportConflict = "transport_conflict"
    /// A `dependency_missing` naming a node this library holds: the server lost it (recovery, PROTOCOL §6.4).
    case dependencyLost = "dependency_lost"

    /// Whether pulls continue while paused.
    public var pullsContinue: Bool { self == .versionUnsupported || self == .transportConflict }
}

/// A request a server refused with `version_unsupported` (PROTOCOL §10: "pause the affected direction"): until an explicit
/// retry (Synchronize now, Force full synchronization, signing in again) or an update, only that work waits, and the
/// rest goes on. A refused change pauses pushing (`push`), as a refused push request does. `recovery` is a recovery's
/// requests after a server restore (its snapshot, inventory, uploads and finish, PROTOCOL §6.11); `installation` the successor
/// installation a transition asks for (PROTOCOL §6.10).
public enum ServerRefusedRequest: String, Sendable, CaseIterable {
    case push, pull, snapshot, secret, recovery, installation
}

/// The exchange's view of a server library (`ntp_library`).
struct ServerExchangeState: Sendable, Equatable {
    var libraryID: String
    var accountID: String
    var namespace: String
    var installID: String
    var cursor: SyncCursor?
    var acked: Int64
    var nextInstallSeq: Int64
    var pause: ServerPauseReason?
    var bounds: ServerBounds
    /// `ntp_library.protocol_version`: the newest protocol version the server reported when it last refused a whole
    /// request of this app's with `version_unsupported` (426); nil after a refused change, or once sync resumed.
    var refusingProtocol: Int? = nil
    /// `ntp_library.version_refusals`: what the server refused with `version_unsupported`; pushing alone when the pause
    /// says so without naming anything (an earlier pause, or one set directly).
    var refusedRequests: Set<ServerRefusedRequest> = []

    /// Whether `request` may be sent: everything but what a `version_unsupported` pause refused.
    func permits(_ request: ServerRefusedRequest) -> Bool { pause != .versionUnsupported || !refusedRequests.contains(request) }

    /// Paused by `version_unsupported` because this app, not the server, needs updating (PROTOCOL §15.5): a whole request refused
    /// by a server that speaks this app's protocol versions or newer ones. A refused change (an operation the server
    /// does not know) and a server whose newest version is older than this app's oldest name the server.
    var appNeedsUpdate: Bool {
        guard pause == .versionUnsupported, let refusingProtocol else { return false }
        return refusingProtocol >= ServerClient.protocolVersions.lowerBound
    }
}

/// The advertised transport bounds (`GET /v1/info`, PROTOCOL §6.4), with the server's defaults.
struct ServerBounds: Sendable, Equatable {
    var maxRequestBytes = 4 << 20
    var maxOperations = 500
    var maxUnframedFactBytes = 256 << 10
    var maxPartBytes = 256 << 10
    var maxPartCount = 64
    /// Entries per recovery inventory request (PROTOCOL §6.11).
    var recoveryInventory = 2_000

    init() {}

    init(_ json: ContractJSON?) {
        guard let json else { return }
        func value(_ name: String, _ fallback: Int) -> Int { json[name]?.integerValue.map { Int(clamping: $0) }.flatMap { $0 > 0 ? $0 : nil } ?? fallback }
        maxRequestBytes = value("max_request_bytes", maxRequestBytes)
        maxOperations = value("max_operations", maxOperations)
        maxUnframedFactBytes = value("max_unframed_fact_bytes", maxUnframedFactBytes)
        maxPartBytes = value("max_part_bytes", maxPartBytes)
        maxPartCount = value("max_part_count", maxPartCount)
        recoveryInventory = value("recovery_inventory", recoveryInventory)
    }
}

/// A framed outbox entry's transport framing (PROTOCOL §6.4, §6.10): its transaction ID, chosen once and stored
/// with the entry before the first part is sent, and the parts the server has stored.
struct ServerFraming: Codable, Equatable, Sendable {
    var transactionID: String
    var present: [Int]

    private enum CodingKeys: String, CodingKey { case transactionID = "transaction_id", present }
}

/// One unacknowledged outbox entry.
struct ServerOutboxEntry: Sendable {
    var installSeq: Int64
    var opID: String
    var type: String
    var bytes: [UInt8]
    var contentHash: String
    var secretIDs: [String]
    var framing: ServerFraming?
    var waiting: [String]?

    var fact: ContractJSON { (try? ContractJSON.decode(bytes)) ?? .null }
}

/// What one push answered, as the store records it.
struct ServerPushRecord: Sendable {
    var receipts: [(installSeq: Int64, receipt: ContractJSON)] = []
    /// Slots consumed without a receipt (`op_id_conflict`).
    var consumedWithoutReceipt: [Int64] = []
    var partsPresent: [(installSeq: Int64, present: [Int])] = []
    /// `invalid_part`: the stored part list is discarded and the parts of the same transaction resent.
    var resetParts: [Int64] = []
    var waiting: (installSeq: Int64, missing: [String])?
    /// The response's head lineage (`{log_id, epoch}`), stored with each receipt.
    var lineage: ContractJSON?
    var watermark: Int64?
    /// `gap`: the server's watermark is below this library's acknowledgement.
    var gap = false
}

extension FeedLibraryStore {
    func serverExchangeState() throws -> ServerExchangeState {
        guard serverContext != nil else { throw ServerRecordingError.notAServerLibrary }
        guard let row = try database.rows("SELECT library_id, account_id, namespace, install_id, cursor, acked_install_seq, next_install_seq, pause_reason, bounds, protocol_version, version_refusals FROM ntp_library WHERE id = 1").first,
              case .text(let library) = row[0], case .text(let account) = row[1], case .text(let namespace) = row[2],
              case .text(let install) = row[3], let acked = row[5].integer, let next = row[6].integer else {
            throw ServerRecordingError.corruptState("ntp_library")
        }
        var cursor: SyncCursor?
        if case .text(let encoded) = row[4] { cursor = try SyncCursor(encoded: encoded) }
        var pause: ServerPauseReason?
        if case .text(let reason) = row[7] { pause = ServerPauseReason(rawValue: reason) }
        let bounds = try row[8].data.map { try ContractJSON.decode($0) }
        return ServerExchangeState(libraryID: library, accountID: account, namespace: namespace, installID: install, cursor: cursor,
                                   acked: acked, nextInstallSeq: next, pause: pause, bounds: ServerBounds(bounds),
                                   refusingProtocol: row[9].integer.map { Int(clamping: $0) },
                                   refusedRequests: pause == .versionUnsupported ? Self.refusedRequests(row[10].text) : [])
    }

    /// The advertised bounds (`GET /v1/info`), stored for the pusher.
    func setServerBounds(_ bounds: ContractJSON?) throws {
        try database.transaction {
            try database.execute("UPDATE ntp_library SET bounds = ? WHERE id = 1", [try bounds.map { .blob(try $0.canonicalData()) } ?? .null])
        }
    }

    /// The tiny durable transaction before every push (PROTOCOL §15.2): in WAL mode its commit syncs every earlier commit, so
    /// no fact is sent before it is durable.
    func serverDurabilityBarrier() throws {
        try syncTransactions(ServerTransactionKind.bookkeeping) { try database.transaction(durable: true) {
            try database.execute("UPDATE ntp_library SET durability_counter = durability_counter + 1 WHERE id = 1")
        } }
    }

    /// Unacknowledged outbox entries after `acked`, in slot order.
    func serverOutbox(after acked: Int64, limit: Int) throws -> [ServerOutboxEntry] {
        try database.rows("SELECT install_seq, op_id, type, fact, content_hash, secret_ids, framing, waiting FROM ntp_outbox WHERE install_seq > ? ORDER BY install_seq LIMIT ?",
                          [.integer(acked), .integer(Int64(limit))]).map { row in
            guard let seq = row[0].integer, case .text(let op) = row[1], case .text(let type) = row[2], let fact = row[3].data,
                  case .text(let hash) = row[4] else { throw ServerRecordingError.corruptState("ntp_outbox") }
            var secrets: [String] = []
            if case .text(let text) = row[5] { secrets = (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? [] }
            let framing = try row[6].data.map { try JSONDecoder().decode(ServerFraming.self, from: $0) }
            let waiting = try row[7].data.map { try JSONDecoder().decode([String].self, from: $0) }
            return ServerOutboxEntry(installSeq: seq, opID: op, type: type, bytes: [UInt8](fact), contentHash: hash,
                                     secretIDs: secrets, framing: framing, waiting: waiting)
        }
    }

    /// Unsent changes: outbox entries without a receipt, drafts, and facts parked behind changes another device may
    /// restore (PROTOCOL §15.5 "changes not yet synchronized").
    public func serverUnsentChanges() throws -> Int {
        guard serverContext != nil else { return 0 }
        return Int(try database.scalar("SELECT (SELECT count(*) FROM ntp_outbox WHERE receipt IS NULL) + (SELECT count(*) FROM ntp_drafts) + (SELECT count(*) FROM ntp_retained WHERE CAST(lineage AS TEXT) LIKE '%\"parked\"%')"))
    }

    /// Persists a framed entry's framing before any part of it is sent (PROTOCOL §6.10: never reframed). Returns the stored
    /// framing: an existing one is kept.
    func serverFraming(installSeq: Int64, opID: String) throws -> ServerFraming {
        try database.transaction {
            guard let row = try database.rows("SELECT framing, op_id FROM ntp_outbox WHERE install_seq = ?", [.integer(installSeq)]).first,
                  case .text(opID) = row[1] else { throw ServerRecordingError.corruptState("no outbox entry \(installSeq)") }
            if let data = row[0].data { return try JSONDecoder().decode(ServerFraming.self, from: data) }
            let framing = ServerFraming(transactionID: ContractIdentity.randomUUID(), present: [])
            try database.execute("UPDATE ntp_outbox SET framing = ? WHERE install_seq = ?", [.blob(try JSONEncoder().encode(framing)), .integer(installSeq)])
            return framing
        }
    }

    /// Records a push's results in one durable transaction (PROTOCOL §6.4): receipts with their lineage, parts stored,
    /// waiting entries, and `acked_install_seq` over the contiguous acknowledged prefix.
    func recordServerPush(_ push: ServerPushRecord) throws {
        try syncTransactions(ServerTransactionKind.bookkeeping) { try recordServerPushLabelled(push) }
    }

    private func recordServerPushLabelled(_ push: ServerPushRecord) throws {
        try database.transaction {
            let lineage = try push.lineage.map { LibrarySQLValue.blob(try $0.canonicalData()) } ?? .null
            for (seq, receipt) in push.receipts {
                try database.execute("UPDATE ntp_outbox SET receipt = ?, receipt_lineage = ?, waiting = NULL WHERE install_seq = ? AND op_id = ?",
                                     [.blob(try receipt.canonicalData()), lineage, .integer(seq), .text(receipt["op_id"]?.stringValue ?? "")])
            }
            for seq in push.consumedWithoutReceipt {
                try database.execute("UPDATE ntp_outbox SET receipt = ?, receipt_lineage = ?, waiting = NULL WHERE install_seq = ?",
                                     [.blob(try ContractJSON.object(["op_id_conflict": true]).canonicalData()), lineage, .integer(seq)])
            }
            for (seq, present) in push.partsPresent {
                guard let row = try database.rows("SELECT framing FROM ntp_outbox WHERE install_seq = ?", [.integer(seq)]).first,
                      let data = row[0].data else { continue }
                var framing = try JSONDecoder().decode(ServerFraming.self, from: data)
                framing.present = present.sorted()
                try database.execute("UPDATE ntp_outbox SET framing = ? WHERE install_seq = ?", [.blob(try JSONEncoder().encode(framing)), .integer(seq)])
            }
            for seq in push.resetParts {
                guard let row = try database.rows("SELECT framing FROM ntp_outbox WHERE install_seq = ?", [.integer(seq)]).first,
                      let data = row[0].data else { continue }
                var framing = try JSONDecoder().decode(ServerFraming.self, from: data)
                framing.present = []
                try database.execute("UPDATE ntp_outbox SET framing = ? WHERE install_seq = ?", [.blob(try JSONEncoder().encode(framing)), .integer(seq)])
            }
            if let waiting = push.waiting {
                try database.execute("UPDATE ntp_outbox SET waiting = ? WHERE install_seq = ?",
                                     [.blob(try JSONEncoder().encode(waiting.missing)), .integer(waiting.installSeq)])
            }
            if push.gap, let watermark = push.watermark {
                try database.execute("UPDATE ntp_library SET acked_install_seq = min(acked_install_seq, ?) WHERE id = 1", [.integer(watermark)])
            } else {
                try advanceAcknowledgement(watermark: push.watermark)
            }
        }
    }

    /// `acked_install_seq` over the contiguous prefix of consumed slots: every entry up to it has a receipt or was
    /// retired; never above the server's watermark.
    func advanceAcknowledgement(watermark: Int64?) throws {
        let next = try database.scalar("SELECT next_install_seq FROM ntp_library WHERE id = 1")
        let firstUnreceipted = try database.rows("SELECT min(install_seq) FROM ntp_outbox WHERE receipt IS NULL").first?.first?.integer
        var prefix = (firstUnreceipted ?? next) - 1
        if let watermark { prefix = min(prefix, watermark) }
        try database.execute("UPDATE ntp_library SET acked_install_seq = max(acked_install_seq, ?) WHERE id = 1", [.integer(prefix)])
    }

    /// `refusedProtocol`: with `version_unsupported` for a whole request, the newest protocol version the server
    /// reported (which side needs updating, PROTOCOL §15.5); every other pause, and resuming, clear it, and what was refused.
    func setServerPause(_ reason: ServerPauseReason?, refusedProtocol: Int? = nil) throws {
        try syncTransactions(ServerTransactionKind.bookkeeping) { try database.transaction {
            try database.execute("UPDATE ntp_library SET pause_reason = ?, protocol_version = ?, version_refusals = NULL WHERE id = 1",
                                 [reason.map { .text($0.rawValue) } ?? .null,
                                  reason == .versionUnsupported ? refusedProtocol.map { .integer(Int64($0)) } ?? .null : .null])
        } }
    }

    /// The server refused `request` with `version_unsupported` (a refused change: `push`): sync pauses that work only,
    /// beside what it refused before in the same pause. `refusedProtocol` as for `setServerPause`; the newest decides.
    func refuseServerRequest(_ request: ServerRefusedRequest, refusedProtocol: Int?) throws {
        try database.transaction {
            let state = try serverExchangeState()
            let refused = (state.pause == .versionUnsupported ? state.refusedRequests : []).union([request])
            try database.execute("UPDATE ntp_library SET pause_reason = ?, protocol_version = ?, version_refusals = ? WHERE id = 1",
                                 [.text(ServerPauseReason.versionUnsupported.rawValue), refusedProtocol.map { .integer(Int64($0)) } ?? .null,
                                  .text(ServerRefusedRequest.allCases.filter(refused.contains).map(\.rawValue).joined(separator: ","))])
        }
    }

    static func refusedRequests(_ text: String?) -> Set<ServerRefusedRequest> {
        let named = Set((text ?? "").split(separator: ",").compactMap { ServerRefusedRequest(rawValue: String($0)) })
        return named.isEmpty ? [.push] : named
    }

    /// The local credential and approved origins of a wire secret this library holds (PROTOCOL §15.4).
    func serverSecretCredential(_ secretID: String) throws -> (credentialID: UUID, approvedOrigins: [String])? {
        guard let row = try database.rows("SELECT credential_id, approved_origins FROM ntp_secrets WHERE secret_id = ?", [.text(secretID)]).first,
              case .text(let text) = row[0], let id = UUID(uuidString: text) else { return nil }
        var origins: [String] = []
        if case .text(let list) = row[1] { origins = (try? JSONDecoder().decode([String].self, from: Data(list.utf8))) ?? [] }
        return (id, origins)
    }

    /// Whether this library holds a node (a fact or decision it knows, PROTOCOL §6.4 `dependency_missing`).
    func serverKnowsNode(_ id: String) throws -> Bool {
        try database.scalar("SELECT (SELECT count(*) FROM ntp_nodes WHERE node_id = ? AND kind != 'draft') + (SELECT count(*) FROM ntp_retained WHERE op_id = ?)",
                            [.text(id), .text(id)]) > 0
    }

    // MARK: - Wake hints (PROTOCOL §6.4: push soon after a local action)

    /// Yields after every committed local action that recorded facts. Hints carry nothing; the scheduler reads.
    public func serverOutboxChanges() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            serverOutboxListeners[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeServerOutboxListener(id) } }
        }
    }

    private func removeServerOutboxListener(_ id: UUID) { serverOutboxListeners[id] = nil }

    func noteServerOutboxChanged() { for listener in serverOutboxListeners.values { listener.yield(()) } }

    // MARK: - Sync log reports from the store (PROTOCOL §15.5)

    /// A sync log line from the store (a refused write, owed facts recorded late); the newest 50 are kept until the
    /// next exchange logs them.
    func noteServerDiagnostic(_ kind: String, _ detail: String) {
        serverDiagnostics.append((kind, detail))
        if serverDiagnostics.count > 50 { serverDiagnostics.removeFirst(serverDiagnostics.count - 50) }
    }

    func takeServerDiagnostics() -> [(kind: String, detail: String)] {
        defer { serverDiagnostics.removeAll() }
        return serverDiagnostics
    }

    /// The installation whose token the exchange sends (PROTOCOL §15.4).
    public func serverInstallationID() throws -> String? { try serverContext == nil ? nil : serverExchangeState().installID }
}
