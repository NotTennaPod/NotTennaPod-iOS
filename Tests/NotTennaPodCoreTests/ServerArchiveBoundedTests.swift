import Foundation
import Testing
@testable import NotTennaPodCore

/// A pull is archived in bounded transactions: a large commit's body goes in parts, each in its own
/// transaction, and the commit becomes pending only once all of them are written.
@Suite struct ServerArchiveBoundedTests {
    static let log = ContractIdentity.randomUUID()

    /// A commit of `count` records whose values do not compress well (as a catalog's revisions and URLs).
    static func commit(seq: Int64, count: Int) throws -> (commit: ServerCommit, body: ContractJSON, cursor: SyncCursor) {
        let records: [ContractJSON] = (0..<count).map { _ in
            ["entity": "episode", "id": .string("e1:" + ContractIdentity.sha256Hex(Array(ContractIdentity.randomUUID().utf8))),
             "field_group": "metadata", "value": ["revision": .string(ContractIdentity.randomUUID()),
                                                  "url": .string("https://example.test/\(ContractIdentity.randomUUID()).mp3")],
             "provenance": []]
        }
        let body: ContractJSON = ["epoch": 1, "seq": .integer(seq), "accepted": [], "decisions": [], "slots": [], "records": .array(records)]
        let cursor = try SyncCursor(logID: log, epoch: 1, seq: seq, digest: String(repeating: "a", count: 64))
        return (try ServerCommit(body), body, cursor)
    }

    static func archive() throws -> (ServerArchive, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ServerArchive-\(UUID())")
        return (try ServerArchive(url: folder.appendingPathComponent("sync.sqlite")), folder)
    }

    @Test func aLargeCommitIsArchivedInBoundedPartsAndReadBackWhole() throws {
        let (archive, folder) = try Self.archive()
        defer { try? archive.close(); try? FileManager.default.removeItem(at: folder) }
        let large = try Self.commit(seq: 1, count: 6_000), small = try Self.commit(seq: 2, count: 3)
        try archive.archiveBounded(large.commit, body: large.body, cursor: large.cursor, now: 0)
        try archive.archiveBounded(small.commit, body: small.body, cursor: small.cursor, now: 0)
        let parts = try archive.database.rows("SELECT length(data) FROM pending_commit_parts WHERE seq = 1").compactMap { $0[0].integer }
        #expect(parts.count > 1 && parts.allSatisfy { $0 <= Int64(ServerArchive.transactionBytes) }, "\(parts)")
        #expect(try archive.database.scalar("SELECT count(*) FROM pending_commit_parts WHERE seq = 2") == 0, "a small body stays whole")
        let first = try #require(try archive.nextPendingCommit(after: 0))
        #expect(first.cursor == large.cursor && first.commit.records == large.commit.records)
        // A pull stopped halfway archives the same commit again: the result is the same.
        try archive.archiveBounded(large.commit, body: large.body, cursor: large.cursor, now: 0)
        #expect(try archive.nextPendingCommit(after: 0)?.commit.records == large.commit.records)
        #expect(try archive.pendingCommits(after: 0).map(\.cursor.seq) == [1, 2])
        try archive.dropPendingCommits(through: 1, logID: Self.log)
        #expect(try archive.database.scalar("SELECT count(*) FROM pending_commit_parts") == 0)
        #expect(try archive.nextPendingCommit(after: 0)?.cursor.seq == 2)
    }

    /// Parts written before a stop, without the commit's own row, are not a pending commit.
    @Test func aCommitWhoseBodyIsUnfinishedIsNotPending() throws {
        let (archive, folder) = try Self.archive()
        defer { try? archive.close(); try? FileManager.default.removeItem(at: folder) }
        try archive.database.transaction {
            try archive.database.execute("INSERT INTO pending_commit_parts(seq, idx, data) VALUES (1, 0, x'00')")
        }
        #expect(try archive.nextPendingCommit(after: 0) == nil)
        let large = try Self.commit(seq: 1, count: 6_000)
        try archive.archiveBounded(large.commit, body: large.body, cursor: large.cursor, now: 0)
        #expect(try archive.nextPendingCommit(after: 0)?.commit.records == large.commit.records, "archived again over the stale part")
    }
}
