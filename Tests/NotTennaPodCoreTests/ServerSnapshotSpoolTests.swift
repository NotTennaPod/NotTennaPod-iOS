import Foundation
import Testing
@testable import NotTennaPodCore

/// The resumable snapshot spool (PROTOCOL §6.4) every whole-library download uses (attach, Force full synchronization,
/// a recovery's snapshot): a verified page is never downloaded twice while the server's view lives; a complete spool
/// is reused without the network; a damaged spool is cut back or deleted, never trusted; the disk check stops before a
/// page is written.
@Suite(.serialized) struct ServerSnapshotSpoolTests {
    /// A server's snapshot view, paged: each page `{head, has_more, next, install_watermark, items}`, the last with its
    /// manifest (item count and digest chain).
    final class View: @unchecked Sendable {
        let head: String
        let pages: [ContractJSON]
        private let lock = NSLock()
        private var log: [String?] = []
        private var served: [Int64] = []
        /// Fails the request for this page index (0-based) once.
        var failAt: Int?
        /// Answers `view_expired` to every token request.
        var expired = false

        init(items: [ContractJSON], perPage: Int, head: String? = nil) throws {
            let cursor = try head ?? SyncCursor(logID: ContractIdentity.randomUUID(), epoch: 1, seq: 42, digest: String(repeating: "a", count: 64)).encoded
            self.head = cursor
            var digest = ContractHash.zeroDigest
            for item in items { digest = try ContractHash.nextDigest(previous: digest, item) }
            let chunks = stride(from: 0, to: items.count, by: perPage).map { Array(items[$0..<min(items.count, $0 + perPage)]) }
            pages = chunks.enumerated().map { index, chunk in
                var page: ContractObject = ["head": .string(cursor), "has_more": .bool(index < chunks.count - 1), "install_watermark": 0,
                                            "items": .array(chunk)]
                if index < chunks.count - 1 { page["next"] = .string("token-\(index + 1)") }
                else { page["manifest"] = ["item_count": .integer(Int64(items.count)), "snapshot_digest": .string(ServerAttachSnapshotDownload.hex(digest))] }
                return .object(page)
            }
        }

        struct Failed: Error {}
        struct Expired: Error {}

        func fetch(_ token: String?) throws -> ContractJSON {
            let index = token.map { Int($0.dropFirst("token-".count))! } ?? 0
            try lock.withLock {
                log.append(token)
                if token != nil, expired { throw Expired() }
                if failAt == index { failAt = nil; throw Failed() }
            }
            let page = pages[index]
            lock.withLock { served.append(Int64(try! page.canonicalData().count)) }
            return page
        }

        var requests: [String?] { lock.withLock { log } }
        var bytesServed: Int64 { lock.withLock { served.reduce(0, +) } }
        func reset() { lock.withLock { log = []; served = [] } }
    }

    static func items(_ count: Int, padding: Int = 64) -> [ContractJSON] {
        (0..<count).map { index in
            ["record": ["entity": "episode", "id": .string("e1:\(index)"), "field_group": "state",
                        "value": ["note": .string(String(repeating: "x", count: padding))]]]
        }
    }

    static func spool(_ folder: URL, _ view: View, identity: ServerSnapshotIdentity = .init(mode: "upgrade", installID: "install-1"),
                      beforeWrite: @escaping @Sendable (Int64, Int64) throws -> Void = { _, _ in }) -> ServerSnapshotSpool {
        var spool = ServerSnapshotSpool(folder: folder, identity: identity, fetch: { try view.fetch($0) },
                                        restarts: { error, _ in error is View.Expired })
        spool.beforeWrite = beforeWrite
        return spool
    }

    static func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("Spool-\(UUID())/full") }

    @Test func anInterruptedDownloadContinuesFromItsNextPage() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let view = try View(items: Self.items(60), perPage: 10)
        view.failAt = 3
        await #expect(throws: View.Failed.self) { try await Self.spool(folder, view).run() }
        #expect(view.requests == [nil, "token-1", "token-2", "token-3"])
        let manifest = try #require(ServerSnapshotSpool.manifest(in: folder))
        #expect(manifest.pages.count == 3 && !manifest.complete && manifest.targetHead == view.head)
        view.reset()
        let snapshot = try await Self.spool(folder, view).run()
        #expect(view.requests == ["token-3", "token-4", "token-5"], "pages 4–6 only: nothing received is asked again")
        #expect(snapshot.itemCount == 60 && snapshot.head == view.head)
        // A resumed spool is the same snapshot as an uninterrupted one.
        let fresh = Self.folder()
        defer { try? FileManager.default.removeItem(at: fresh.deletingLastPathComponent()) }
        let whole = try await Self.spool(fresh, view).run()
        #expect(try Self.items(of: snapshot) == Self.items(of: whole))
    }

    @Test func aCompleteSpoolIsReusedWithoutTheNetworkAndVerifiedAgain() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let view = try View(items: Self.items(25), perPage: 10)
        _ = try await Self.spool(folder, view).run()
        view.reset()
        let again = try await Self.spool(folder, view).run()
        #expect(view.requests.isEmpty, "a complete, verified spool needs no server view")
        #expect(again.itemCount == 25)
        // A complete spool whose content no longer verifies (its last page replaced, hashes made to match) is deleted at
        // once, never trusted, and the next run downloads it fresh.
        var manifest = try #require(ServerSnapshotSpool.manifest(in: folder))
        var last = try ContractJSON.decode(Data(contentsOf: folder.appendingPathComponent(manifest.pages[2].file))).objectValue!
        last["items"] = .array(Array(Self.items(4)))
        let data = try ContractJSON.object(last).canonicalData()
        try data.write(to: folder.appendingPathComponent(manifest.pages[2].file))
        manifest.pages[2].sha256 = ContractIdentity.sha256Hex(Array(data))
        try ServerSnapshotSpool.save(manifest, in: folder)
        await #expect(throws: ServerSnapshotError.verificationFailed) { try await Self.spool(folder, view).run() }
        #expect(!FileManager.default.fileExists(atPath: folder.path), "deleted at once, not verified in a loop")
        #expect(view.requests.isEmpty)
        let fresh = try await Self.spool(folder, view).run()
        #expect(fresh.itemCount == 25 && view.requests == [nil, "token-1", "token-2"])
    }

    @Test func damagedPagesAreCutBackAndOrphansDeleted() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let view = try View(items: Self.items(60), perPage: 10)
        view.failAt = 5
        await #expect(throws: View.Failed.self) { try await Self.spool(folder, view).run() }
        // An interrupted write of page 6 left its file without a manifest entry; page 3 was altered on disk.
        try Data("{}".utf8).write(to: folder.appendingPathComponent("page-000006.json"))
        try Data("{\"truncated\":".utf8).write(to: folder.appendingPathComponent(".page-000006.json.tmp"))
        let third = folder.appendingPathComponent("page-000003.json")
        let original = try Data(contentsOf: third)
        try original.prefix(original.count / 2).write(to: third)
        view.reset()
        let snapshot = try await Self.spool(folder, view).run()
        #expect(view.requests == ["token-2", "token-3", "token-4", "token-5"], "from the page before the damaged one")
        #expect(snapshot.itemCount == 60)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(names == Set((1...6).map { String(format: "page-%06d.json", $0) } + ["manifest.json"]))
        // A manifest naming a page that is gone.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("page-000002.json"))
        view.reset()
        _ = try await Self.spool(folder, view).run()
        #expect(view.requests == ["token-1", "token-2", "token-3", "token-4", "token-5"])
    }

    @Test func anotherRequestOrAnExpiredViewStartsAgain() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let view = try View(items: Self.items(40), perPage: 10)
        view.failAt = 2
        await #expect(throws: View.Failed.self) { try await Self.spool(folder, view).run() }
        view.reset()
        // Another installation's (or lineage's, or field groups') spool is never continued.
        _ = try await Self.spool(folder, view, identity: .init(mode: "upgrade", installID: "install-2")).run()
        #expect(view.requests.first == .some(nil), "a new first page")
        // The view expired while the download waited: started again from its first page.
        view.failAt = 2
        try? FileManager.default.removeItem(at: folder)
        await #expect(throws: View.Failed.self) { try await Self.spool(folder, view).run() }
        view.reset()
        view.expired = true
        await #expect(throws: ServerClientError.viewExpired) { try await Self.spool(folder, view).run() }
        #expect(view.requests.first == "token-2" && view.requests.filter { $0 == nil }.count == 2,
                "the saved token first, then two fresh attempts, each refused at its second page")
        view.expired = false
        view.reset()
        _ = try await Self.spool(folder, view).run()
        #expect(view.requests == [nil, "token-1", "token-2", "token-3"])
    }

    @Test func tooLittleSpaceStopsBeforeAPageIsWrittenAndContinuesLater() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let view = try View(items: Self.items(50), perPage: 10)
        let free = FreeSpace(1 << 40)
        let policy = ServerBulkDiskPolicy(available: { _ in free.value })
        let check: @Sendable (Int64, Int64) throws -> Void = { page, spooled in
            if spooled == 0 { try policy.admit(estimate: nil, spooled: 0, at: folder) }
            try policy.check(page + Int64(policy.expansion * Double(spooled + page)), at: folder)
        }
        // Not enough for a first download of unknown size: nothing is written.
        free.value = policy.reserve + (1 << 30)
        await #expect(throws: ServerInsufficientSpace.self) { try await Self.spool(folder, view, beforeWrite: check).run() }
        #expect(ServerSnapshotSpool.manifest(in: folder)?.pages.isEmpty == true)
        // Space runs out after three pages (another app wrote meanwhile): the three stay, nothing past the reserve.
        free.value = 1 << 40
        let spooledLimit = SpaceAfter(pages: 3, free: free, reserve: policy.reserve)
        await #expect(throws: ServerInsufficientSpace.self) {
            try await Self.spool(folder, view, beforeWrite: { page, spooled in spooledLimit.note(); try check(page, spooled) }).run()
        }
        #expect(ServerSnapshotSpool.manifest(in: folder)?.pages.count == 3)
        free.value = 1 << 40
        view.reset()
        let snapshot = try await Self.spool(folder, view, beforeWrite: check).run()
        #expect(snapshot.itemCount == 50 && view.requests == ["token-3", "token-4"], "it continues where it stopped")
    }

    /// The synthetic power-user library (70 podcasts, 26,271 episodes): a download interrupted at 80 % re-downloads at
    /// most the page in flight, not what it had received.
    @Test func aPowerUsersInterruptedDownloadReDownloadsNothingItReceived() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        var items: [ContractJSON] = []
        for podcast in 0..<70 {
            items.append(["record": ["entity": "podcast", "id": .string("p1:\(podcast)"), "field_group": "subscription", "value": ["state": "subscribed"]]])
        }
        // About 1 kB per episode here (the deployed library's ~11 kB scale the bytes, not the shape).
        for episode in 0..<26_271 {
            items.append(["record": ["entity": "episode", "id": .string("e1:\(episode)"), "field_group": "identity",
                                     "value": ["podcast_id": .string("p1:\(episode % 70)"), "note": .string(String(repeating: "y", count: 900))]]])
        }
        let view = try View(items: items, perPage: 1_000)
        let total = try view.pages.reduce(Int64(0)) { $0 + Int64(try $1.canonicalData().count) }
        let cut = view.pages.count * 4 / 5
        view.failAt = cut
        await #expect(throws: View.Failed.self) { try await Self.spool(folder, view).run() }
        let received = view.bytesServed
        view.reset()
        let snapshot = try await Self.spool(folder, view).run()
        let again = view.bytesServed
        let reDownloaded = again - (total - received)
        print("spool measurement: pages \(view.pages.count), total \(total) bytes, received before the interruption \(received), downloaded after it \(again), re-downloaded \(reDownloaded)")
        #expect(snapshot.itemCount == items.count && snapshot.podcastCount == 70)
        #expect(reDownloaded == 0, "nothing received before the interruption is downloaded again")
        #expect(again == total - received)
    }

    /// The network rule of whole-library downloads: on mobile data, or Wi-Fi in Low Data Mode, only when the
    /// "Synchronization" mobile-data preference allows it; ordinary sync keeps running on Low Data Wi-Fi. Each page asks
    /// the system again (mobile data and Low Data refused unless allowed), so a network change mid-download refuses the
    /// next page; a recovery's one-item opening is not bulk.
    @Test func wholeLibraryDownloadsFollowTheMobileDataPreferenceAndLowDataMode() async throws {
        let lowData = DownloadNetworkState(connected: true, metered: false, cellular: false, transport: .wifi, constrained: true)
        let cellular = DownloadNetworkState(connected: true, metered: true, cellular: true)
        let wifi = DownloadNetworkState(connected: true, metered: false, cellular: false, transport: .wifi)
        #expect(DownloadNetworkSyncGate.bulkWaitReason(lowData, allowMobile: false) == .mobileDataOff)
        #expect(DownloadNetworkSyncGate.waitReason(lowData, allowMobile: false) == nil, "ordinary sync runs on Low Data Wi-Fi")
        #expect(DownloadNetworkSyncGate.bulkWaitReason(cellular, allowMobile: false) == .mobileDataOff)
        #expect(DownloadNetworkSyncGate.bulkWaitReason(cellular, allowMobile: true) == nil)
        #expect(DownloadNetworkSyncGate.bulkWaitReason(lowData, allowMobile: true) == nil)
        #expect(DownloadNetworkSyncGate.bulkWaitReason(wifi, allowMobile: false) == nil)

        let monitor = DownloadNetworkMonitor(startMonitoring: false)
        let sent = SentRequests()
        let gate = DownloadNetworkSyncGate(monitor: monitor, allowMobile: { false })
        let transport = HTTPServerExchangeTransport(base: URL(string: "http://127.0.0.1:9")!, transport: sent, network: gate, token: { "token" })
        let page: ContractJSON = ["mode": "upgrade", "install_id": "i", "acked_install_seq": 0]
        monitor.update(lowData)
        await #expect(throws: ServerExchangeError.networkNotPermitted) { try await transport.send("POST", "v1/snapshot", body: page) }
        #expect(sent.requests.isEmpty, "nothing asked")
        _ = try? await transport.send("POST", "v1/pull", body: ["cursor": "c"])
        #expect(sent.requests.count == 1, "ordinary sync still runs")
        _ = try? await transport.send("POST", "v1/snapshot", body: ["mode": "recovery", "limit": 1])
        #expect(sent.requests.count == 2, "a recovery's one-item opening is not bulk")
        monitor.update(wifi)
        _ = try? await transport.send("POST", "v1/snapshot", body: page)
        let request = try #require(sent.requests.last)
        #expect(sent.requests.count == 3 && !request.allowsExpensiveNetworkAccess && !request.allowsConstrainedNetworkAccess,
                "the system refuses mobile data and Low Data for the page")
    }

    final class SentRequests: SynchronizationHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { log } }
        func send(_ request: URLRequest) async throws -> SynchronizationHTTPResponse {
            lock.withLock { log.append(request) }
            return SynchronizationHTTPResponse(status: 200, body: Data("{}".utf8))
        }
    }

    /// What staging needs per spooled byte on the synthetic power-user library (records only, the staging's whole
    /// input): measured, and within the per-page factor.
    @Test func stagingNeedsLessThanThePerPageFactor() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        var items: [ContractJSON] = []
        for podcast in 0..<70 {
            items.append(["record": ["entity": "podcast", "id": .string("p1:\(podcast)"), "field_group": "subscription", "value": ["state": "subscribed"]]])
        }
        for episode in 0..<26_271 {
            let id = ContractJSON.string("e1:" + String(format: "%064x", episode))
            items.append(["record": ["entity": "episode", "id": id, "field_group": "identity", "provenance": [],
                                     "value": ["podcast_id": .string("p1:\(episode % 70)"), "occurrence": ["k": "guid", "v": .string("guid-\(episode)")]]]])
            items.append(["record": ["entity": "episode", "id": id, "field_group": "state", "provenance": [],
                                     "value": ["played": .bool(episode % 3 == 0), "position": .integer(Int64(episode * 1_000)),
                                               "note": .string(String(repeating: "z", count: 300))]]])
        }
        let view = try View(items: items, perPage: 1_000)
        let snapshot = try await Self.spool(folder, view).run()
        let file = folder.deletingLastPathComponent().appendingPathComponent("full-1.sqlite")
        let staged = try ServerFullReprojection.stageBase(snapshot, into: file)
        let size = ["", "-wal", "-journal"].reduce(Int64(0)) { total, suffix in
            total + ((try? FileManager.default.attributesOfItem(atPath: file.path + suffix)[.size] as? Int64) ?? 0)
        }
        let factor = Double(size) / Double(snapshot.bytes)
        print("staging measurement: \(staged.records) records, spooled \(snapshot.bytes) bytes, staged \(size) bytes, factor \(String(format: "%.2f", factor))")
        #expect(factor < ServerBulkDiskPolicy().expansion)
    }

    final class FreeSpace: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: Int64
        init(_ bytes: Int64) { self.bytes = bytes }
        var value: Int64 {
            get { lock.withLock { bytes } }
            set { lock.withLock { bytes = newValue } }
        }
    }

    /// Free space that falls below the reserve once `pages` pages were written.
    final class SpaceAfter: @unchecked Sendable {
        let pages: Int, free: FreeSpace, reserve: Int64
        private let lock = NSLock()
        private var seen = 0
        init(pages: Int, free: FreeSpace, reserve: Int64) { self.pages = pages; self.free = free; self.reserve = reserve }
        func note() {
            lock.withLock {
                seen += 1
                if seen > pages { free.value = reserve + 1_000 }
            }
        }
    }

    static func items(of snapshot: ServerAttachSnapshot) throws -> [ContractJSON] {
        var items: [ContractJSON] = []
        try snapshot.forEachItem { items.append($0) }
        return items
    }
}
