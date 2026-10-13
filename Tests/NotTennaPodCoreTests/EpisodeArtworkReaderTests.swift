import CryptoKit
import Foundation
import Testing
@testable import NotTennaPodCore

struct EpisodeArtworkReaderTests {
    private struct FileTransfer: MediaTransferring {
        let file: URL
        func download(_ input: MediaDownloadRequest,
                      progress: @escaping @Sendable (MediaDownloadProgress) -> Void) async throws -> MediaDownloadResult {
            let bytes = try Data(contentsOf: file)
            try bytes.write(to: input.destination)
            return .init(destination: input.destination, size: Int64(bytes.count), validator: nil)
        }
    }
    private actor Gate {
        private var continuation: CheckedContinuation<Data?, Never>?
        var started: Bool { continuation != nil }
        func read() async -> Data? { await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(returning: Data([7])); continuation = nil }
    }
    private func withDownload(_ body: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadedArtwork-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let feedURL = URL(string: "https://example.invalid/feed")!
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, imageURL: "fixture:feed",
            episodes: [ParsedEpisode(identifier: "one", media: ParsedMedia(url: "https://example.invalid/one.ogg", size: 1, hasEmbeddedPicture: false))]),
            source: feedURL.absoluteString, responseURL: feedURL, validator: nil, permanentRedirectURL: nil))
        let job = try #require(try await store.requestDownload(episodeID: 1, directory: root))
        let file = try #require(Bundle.module.url(forResource: "auphonic.ogg", withExtension: nil, subdirectory: "Fixtures/VorbisDescriptions"))
        let network = DownloadNetworkMonitor(startMonitoring: false)
        network.update(.init(connected: true, metered: false, cellular: false))
        let worker = MediaDownloadWorker(store: store, transfer: FileTransfer(file: file), network: network, duration: { _ in 10_000 })
        #expect(try await worker.run(id: job.id) == .completed)
        do { try await body(store, url); try await store.close() }
        catch { try? await store.close(); throw error }
    }

    @Test func completedDownloadInspectsArtworkAndLegacyLookupPersistsAcrossReopen() async throws {
        try await withDownload { store, url in
            #expect(try await store.episode(id: 1)?.details.media?.hasEmbeddedPicture == true)
            try await store.updateEpisode(id: 1) { $0.details.media?.hasEmbeddedPicture = nil; $0.userState.isFavorite = true }
            let episode = try #require(try await store.episode(id: 1))
            let reader = EpisodeArtworkReader(store: store)
            let picture = try #require(try await reader.read(episode: episode))
            #expect(SHA256.hash(data: picture).map { String(format: "%02x", $0) }.joined()
                == "efece7e0b38d8f9eadaeb3482b71a581e099ddf9febe614aed0fe5d5043e8634")
            #expect(try await store.episode(id: 1)?.details.media?.hasEmbeddedPicture == true)
            #expect(try await store.episode(id: 1)?.userState.isFavorite == true)
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.episode(id: 1)?.details.media?.hasEmbeddedPicture == true)
            try await reopened.close()
            try await store.requestMediaDeletion(episodeID: 1)
            #expect(try await store.episode(id: 1)?.details.media?.hasEmbeddedPicture == false)
            #expect(try await reader.read(episode: episode) == nil)
        }
    }

    @Test(arguments: ["delete", "replace", "cancel"])
    func delayedDownloadedImageCannotCommitAfterItsFileChanges(change: String) async throws {
        try await withDownload { store, _ in
            try await store.updateEpisode(id: 1) { $0.details.media?.hasEmbeddedPicture = nil }
            let episode = try #require(try await store.episode(id: 1))
            let gate = Gate()
            let reader = EpisodeArtworkReader(store: store, readDownloaded: { _ in await gate.read() })
            let pending = Task { try await reader.read(episode: episode) }
            for _ in 0..<1000 {
                if await gate.started { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(await gate.started)
            if change == "delete" { try await store.requestMediaDeletion(episodeID: 1) }
            else if change == "replace" { try await store.updateEpisode(id: 1) { $0.userState.downloadDate = .distantFuture } }
            else { pending.cancel() }
            await gate.release()
            if change == "cancel" { await #expect(throws: CancellationError.self) { try await pending.value } }
            else { #expect(try await pending.value == nil) }
            #expect(try await store.episode(id: 1)?.details.media?.hasEmbeddedPicture == (change == "delete" ? false : nil))
        }
    }

    @Test func missingDownloadedFileRecordsAbsentArtworkWithoutUndoingListeningState() async throws {
        try await withDownload { store, _ in
            try await store.updateEpisode(id: 1) { $0.details.media?.hasEmbeddedPicture = nil; $0.userState.positionMilliseconds = 900 }
            let episode = try #require(try await store.episode(id: 1))
            try FileManager.default.removeItem(atPath: #require(episode.userState.localFileURL))
            #expect(try await EpisodeArtworkReader(store: store).read(episode: episode) == nil)
            #expect(try await store.episode(id: 1)?.details.media?.hasEmbeddedPicture == false)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 900)
        }
    }

    @Test func failedReloadDoesNotEraseKnownPictureAndIdentityUsesLiteralStrings() async throws {
        try await withDownload { store, _ in
            let episode = try #require(try await store.episode(id: 1))
            let reader = EpisodeArtworkReader(store: store, readDownloaded: { _ in throw CocoaError(.fileReadNoPermission) })
            #expect(try await reader.read(episode: episode) == nil)
            #expect(try await store.episode(id: 1)?.details.media?.hasEmbeddedPicture == true)
            var composed = episode, decomposed = episode
            composed.details.media?.url = "https://example/caf\u{e9}"
            decomposed.details.media?.url = "https://example/cafe\u{301}"
            #expect(DownloadedArtworkReference(composed) != DownloadedArtworkReference(decomposed))
        }
    }

    @Test func cancelledCompletionArtworkCannotPublishDownloadedState() async throws {
        try await withDownload { store, url in
            try await store.requestMediaDeletion(episodeID: 1)
            let job = try #require(try await store.requestDownload(episodeID: 1, directory: url.deletingLastPathComponent()))
            let file = try #require(Bundle.module.url(forResource: "auphonic.ogg", withExtension: nil, subdirectory: "Fixtures/VorbisDescriptions"))
            let gate = Gate()
            let network = DownloadNetworkMonitor(startMonitoring: false)
            network.update(.init(connected: true, metered: false, cellular: false))
            let worker = MediaDownloadWorker(store: store, transfer: FileTransfer(file: file), network: network,
                duration: { _ in 10_000 }, artwork: { _ in await gate.read() != nil })
            let pending = Task { try await worker.run(id: job.id) }
            for _ in 0..<1000 {
                if await gate.started { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            try #require(await gate.started)
            pending.cancel(); await gate.release()
            #expect(try await pending.value == .interrupted)
            #expect(try await store.episode(id: 1)?.userState.isDownloaded == false)
            #expect(try await store.episode(id: 1)?.details.media?.hasEmbeddedPicture == false)
            #expect(try await store.downloadJob(id: job.id)?.state == .waiting)
        }
    }

    @Test func originalLazyLookupOracleExplainsDeferredSourceSelection() throws {
        struct Oracle: Decodable {
            struct Case: Decodable {
                let known: Bool?; let downloadDate: Int; let path: String?
                let picture, failure, expected, second: Bool; let reads: Int
            }
            let cases: [Case]
        }
        let url = try #require(Bundle.module.url(forResource: "lazy-artwork-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let rows = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url)).cases
        #expect(rows.count == 108)
        let feed = LibraryFeed(id: 1, source: "https://example/feed", metadata: ParsedFeed(format: .rss, imageURL: "fixture:feed"), episodes: [])
        for row in rows {
            var episode = LibraryEpisode(id: 1, details: ParsedEpisode(media: ParsedMedia(size: 1, hasEmbeddedPicture: row.known)))
            episode.userState.localFileURL = row.path; episode.userState.isDownloaded = row.downloadDate > 0
            let inspect = row.known == nil && row.downloadDate > 0 && row.path != nil
            #expect(row.reads == (inspect ? 1 : 0))
            #expect(row.expected == row.second)
            #expect(row.expected == (row.known ?? (inspect && row.picture && !row.failure)))
            let source = EpisodeArtworkSelection.source(episode: episode, feed: feed)
            #expect(source == ((row.known == true || inspect) ? "metadata-retriever:" + (row.path ?? "null") : "fixture:feed"))
        }
    }
}
