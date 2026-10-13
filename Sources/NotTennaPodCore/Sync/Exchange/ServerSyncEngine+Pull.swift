import Foundation

/// Why a pull view was discarded (PROTOCOL §6.6).
enum ServerPullError: Error, Equatable, Sendable {
    /// A commit does not chain from the cursor to the head (PROTOCOL §6.4), or a part is malformed.
    case verificationFailed(String)
}

/// How far a pull got. What a recovery does after its catch-up needs a view of the server's head.
enum ServerPullReach: Equatable, Sendable {
    /// The server answered a verified view up to its head, and every commit of it is archived.
    case head
    /// Commits archived earlier are applied first; the server was not asked.
    case pendingFirst
    /// The server was not asked, or nothing verified: a pause, a pull the server refused, a view discarded twice.
    case blocked
}

/// Pulling (PROTOCOL §6.6): `POST /v1/pull` pages spooled to `staging/pull/` until `has_more` is false, every
/// commit verified against the digest chain from the cursor to the head, then archived in `sync.sqlite` in one
/// transaction. Nothing live changes here; the applier then applies the archived commits one unit at a time.
extension ServerSyncEngine {
    @discardableResult
    func pull(_ report: inout ServerExchangeReport) async throws -> ServerPullReach {
        for attempt in 0..<2 {
            do {
                let (count, reach) = try await pullView()
                report.pulledCommits += count
                return reach
            } catch let error as ServerPullError {
                // A view that fails verification is discarded and pulled again (PROTOCOL §6.6). Its reason is this app's own words,
                // with the server's numbers only.
                log("pull", "discarded: \(error)")
                if attempt == 1 { backoff(&report) }
            }
        }
        return .blocked
    }

    /// Pulls one view and archives it. Returns the number of commits archived, and how far it got.
    private func pullView() async throws -> (Int, ServerPullReach) {
        let state = try await store.serverExchangeState()
        if let pause = state.pause, !pause.pullsContinue { return (0, .blocked) }
        // A pull the server refused waits for an explicit retry or an update.
        guard state.permits(.pull), let cursor = state.cursor else { return (0, .blocked) }
        // Commits archived but not applied apply first, from the archive (PROTOCOL §6.6).
        guard try archive.pendingCommitCount(after: cursor.seq) == 0 else { return (0, .pendingFirst) }
        let spool = staging.appendingPathComponent("pull", isDirectory: true)
        try? FileManager.default.removeItem(at: spool)
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: spool) }
        var pages: [URL] = []
        var page: String?
        var head: SyncCursor?
        var watermark: Int64?
        repeat {
            try Task.checkCancellation()
            var body: ContractObject = ["cursor": .string(cursor.encoded), "install_id": .string(state.installID),
                                        "acked_install_seq": .integer(state.acked)]
            if let page { body["page"] = .string(page) }
            let answer = try await ServerRequestRefused.mapping(.pull) { try await transport.pull(.object(body)) }
            let url = spool.appendingPathComponent(String(format: "page-%06d.json", pages.count + 1))
            try answer.canonicalData().write(to: url, options: .atomic)
            pages.append(url)
            guard let encoded = answer["head"]?.stringValue, let decoded = try? SyncCursor(encoded: encoded) else {
                throw ServerPullError.verificationFailed("a page without a head")
            }
            if let head, head != decoded { throw ServerPullError.verificationFailed("pages of different heads") }
            head = decoded
            watermark = answer["install_watermark"]?.integerValue
            if answer["has_more"]?.boolValue == true {
                guard let next = answer["next"]?.stringValue, !next.isEmpty else { throw ServerPullError.verificationFailed("no next page") }
                page = next
            } else { page = nil }
        } while page != nil
        try crash("pull.spooled")
        guard let head else { return (0, .blocked) }
        guard head.logID == cursor.logID else { throw ServerExchangeError.server(status: 409, code: "lineage_mismatch", retryAfter: nil) }
        // Pass 1: the digest chain from the cursor to the head, over the strictly decoded commits.
        var digest = ContractHex.decode(cursor.digest) ?? []
        var seq = cursor.seq
        try forEachCommit(pages) { json in
            guard let commitSeq = json["seq"]?.integerValue, commitSeq == seq + 1 else {
                throw ServerPullError.verificationFailed("commit \(json["seq"]?.integerValue ?? -1) after \(seq)")
            }
            digest = try ContractHash.nextDigest(previous: digest, json)
            seq = commitSeq
        }
        guard seq == head.seq, ContractHex.encode(digest) == head.digest else {
            throw ServerPullError.verificationFailed("the chain ends at \(seq), not the head \(head.seq)")
        }
        guard seq > cursor.seq else { return (0, .head) }
        // Pass 2: archive every commit of the verified view, in order, in bounded transactions (a
        // playback save never waits behind a long archive write).
        var count = 0
        let now = now()
        digest = ContractHex.decode(cursor.digest) ?? []
        try forEachCommit(pages) { json in
            try Task.checkCancellation()
            digest = try ContractHash.nextDigest(previous: digest, json)
            let commit = try ServerCommit(json)
            try archive.archiveBounded(commit, body: json, cursor: try SyncCursor(logID: head.logID, epoch: commit.epoch, seq: commit.seq,
                                                                                  digest: ContractHex.encode(digest)), now: now)
            count += 1
        }
        pullWatermark = watermark
        try crash("pull.archived")
        log("pull", "\(count) commits to \(head.seq)")
        return (count, .head)
    }

    /// The commits of spooled pages in order, a commit larger than a page reassembled from its parts.
    private func forEachCommit(_ pages: [URL], _ body: (ContractJSON) throws -> Void) throws {
        var parts: (seq: Int64, count: Int64, next: Int64, bytes: [UInt8])?
        for page in pages {
            let decoded = try ContractJSON.decode(Data(contentsOf: page))
            for item in decoded["items"]?.arrayValue ?? [] {
                if let commit = item["commit"] {
                    guard parts == nil else { throw ServerPullError.verificationFailed("an unfinished framed commit") }
                    try body(commit)
                    continue
                }
                guard let part = item["commit_part"], let seq = part["seq"]?.integerValue, let index = part["part_index"]?.integerValue,
                      let count = part["part_count"]?.integerValue, count >= 1, let data = part["data"]?.stringValue else {
                    throw ServerPullError.verificationFailed("a malformed item")
                }
                let bytes = try ContractBase64URL.decode(data)
                if index == 0, parts == nil { parts = (seq, count, 1, bytes) }
                else if var current = parts, current.seq == seq, current.count == count, current.next == index {
                    current.bytes += bytes; current.next += 1
                    parts = current
                } else { throw ServerPullError.verificationFailed("a commit part out of order") }
                if let current = parts, current.next == current.count {
                    parts = nil
                    try body(try ContractJSON.decode(current.bytes))
                }
            }
        }
        guard parts == nil else { throw ServerPullError.verificationFailed("an unfinished framed commit") }
    }
}
