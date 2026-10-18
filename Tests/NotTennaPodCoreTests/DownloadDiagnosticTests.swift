import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

private struct DiagnosticTransport: FeedHTTPTransport {
    let error: URLError
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse { throw error }
}
private struct DiagnosticMediaTransfer: MediaTransferring {
    let error: URLError
    func download(_ input: MediaDownloadRequest, progress: @escaping @Sendable (MediaDownloadProgress) -> Void) async throws -> MediaDownloadResult { throw error }
}

@MainActor @Suite
struct DownloadDiagnosticTests {
    private func fixture(_ body: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadDiagnostic-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        _ = try await store.insert(.init(feed: .init(format: .rss, title: "Diagnostic podcast", episodes: [
            .init(identifier: "one", title: "Diagnostic episode", media: .init(url: "https://example.test/media", size: 100))]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        do { try await body(store, root); try await store.close() } catch { try? await store.close(); throw error }
    }
    @Test func networkFeedDiagnosticSurvivesCategoryMappingPersistenceAndClipboard() async throws {
        try await fixture { store, root in
            let message = "The host could not be resolved. DNS lookup failed."
            let error = URLError(.cannotFindHost, userInfo: [NSLocalizedDescriptionKey: message])
            let fetcher = FeedFetcher(transport: DiagnosticTransport(error: error))
            #expect(try await FeedRefreshService(store: store, fetcher: fetcher).refresh(feedID: 1) == .failed(.unknownHost))
            let reopened = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
            let log = try #require(try await reopened.logs(feedID: 1).first)
            #expect(log.kind == .failure(.unknownHost) && log.detail == message)
            let detail = FeedLogDetails(log: log, feed: try await reopened.feed(id: 1), text: { $0 })
            #expect(detail.technical == message && detail.clipboard.contains(message))
            try await reopened.close()
            await #expect(throws: FeedFetchError.unknownHost) { try await fetcher.fetch(.init(source: "https://example.test/feed")) }
        }
    }
    @Test func mediaWorkerRetainsNativeDiagnosticThroughAllRetriesAndReopen() async throws {
        try await fixture { store, root in
            let message = "The certificate chain could not be verified."
            let error = URLError(.serverCertificateUntrusted, userInfo: [NSLocalizedDescriptionKey: message])
            let time = Mutex(Date(timeIntervalSince1970: 100))
            let network = DownloadNetworkMonitor(startMonitoring: false)
            network.update(.init(connected: true, metered: false, cellular: false))
            let worker = MediaDownloadWorker(store: store, transfer: DiagnosticMediaTransfer(error: error),
                clock: { time.withLock { $0 } }, wait: { interval in time.withLock { $0.addTimeInterval(interval) } }, network: network)
            let job = try #require(try await store.requestDownload(episodeID: 1, directory: root, now: time.withLock { $0 }))
            #expect(try await worker.run(id: job.id) == .failed(.certificate))
            let reopened = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
            let entries = try await reopened.downloadLog()
            #expect(entries.count == 3)
            for entry in entries {
                let details = FeedLogDetails(entry: entry, feed: try await reopened.feed(id: 1), episode: try await reopened.episode(id: 1), text: { $0 })
                #expect(details.technical == message && details.statusKey == "download_error_certificate")
                #expect(details.clipboard.contains(message))
            }
            #expect(try await reopened.downloadJob(id: job.id)?.state == .failed)
            try await reopened.close()
        }
    }
    @Test func sourceSizeDiagnosticAndAbsentDetailsHaveDistinctPersistedMeanings() async throws {
        try await fixture { store, root in
            try await store.recordFailure(.wrongSize(expected: 1000, received: 22), feedID: 1, date: Date())
            #expect(try await store.logs(feedID: 1).first?.detail == "Download completed but size: 22 does not equal expected size 1000")
            let job = try #require(try await store.requestDownload(episodeID: 1, directory: root))
            _ = try await store.beginDownloadAttempt(id: job.id)
            _ = try await store.recordDownloadFailure(id: job.id, attempt: 1, failure: .wrongSize(expected: 1000, received: 22))
            let entry = try #require(try await store.downloadLog().first)
            let details = FeedLogDetails(entry: entry, feed: nil, episode: nil, text: { $0 })
            #expect(details.technical == "Download completed but size: 22 does not equal expected size 1000")
            let old = try JSONDecoder().decode(DownloadAttemptLog.self, from: Data("{\"date\":0,\"attempt\":1,\"failure\":{\"fileType\":{}}}".utf8))
            #expect(old.detail == nil && old.title == nil)
            #expect(DownloadDiagnostic.media(.fileType) == nil)
            #expect(DownloadDiagnostic.media(.notEnoughSpace(required: 10, available: 1)) == nil)
        }
    }
    @Test func cancellationDoesNotBecomeAnErrorDiagnostic() async throws {
        try await fixture { store, _ in
            let fetcher = FeedFetcher(transport: DiagnosticTransport(error: URLError(.cancelled)))
            await #expect(throws: CancellationError.self) { try await FeedRefreshService(store: store, fetcher: fetcher).refresh(feedID: 1) }
            let logs = try await store.downloadLog()
            #expect(logs.isEmpty)
        }
    }
}
