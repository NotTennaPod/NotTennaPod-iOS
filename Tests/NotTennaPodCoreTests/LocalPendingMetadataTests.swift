import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Playback demand for the metadata of an episode first listed while its file was only in the
/// cloud. The folder and files are real; the provider's availability answers are the fixture's.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct LocalPendingMetadataTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private struct Fixture {
        let store: FeedLibraryStore
        let folder: URL
        let provider: LocalAvailabilityFixture
        let refresh: LocalFeedRefreshService
        let episode: LibraryEpisode
    }

    private func fixture(name: String = "tagged.mp3", contents: URL? = nil, _ body: (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalPendingMetadata-\(UUID())", isDirectory: true)
        let folder = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if let contents { try FileManager.default.copyItem(at: contents, to: folder.appendingPathComponent(name)) }
        else { try Data(count: 64).write(to: folder.appendingPathComponent(name)) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        do {
            let feedID = try await store.registerLocalFolder(title: "Folder", directoryIdentity: folder.absoluteString,
                bookmark: LocalFolderDocuments.makeBookmark(directory: folder)).feed.id
            let provider = LocalAvailabilityFixture()
            provider.set(name, .notDownloaded)
            let date = now
            let refresh = LocalFeedRefreshService(store: store, open: { link in
                try await LocalFolderDocuments(bookmark: link.bookmark, availability: provider.source).scanInput { _, _ in
                    LocalFileMetadata(title: "Scanned title")
                }
            }, clock: { date })
            _ = try await refresh.refresh(feedID: feedID, description: "", author: "")
            let id = try #require(try await store.feed(id: feedID)?.episodes.first?.id)
            try await store.updateEpisode(id: id) { $0.userState.isFavorite = true; $0.userState.positionMilliseconds = 3_000 }
            let episode = try #require(try await store.episode(id: id))
            #expect(episode.details.title == URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent)
            #expect(episode.details.media?.metadataPending == true)
            try await body(Fixture(store: store, folder: folder, provider: provider, refresh: refresh, episode: episode))
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

    private final class Gate: Sendable {
        private let enteredState = Mutex(false)
        private let releaseSignal = DispatchSemaphore(value: 0)
        var entered: Bool { enteredState.withLock { $0 } }
        func hold() { enteredState.withLock { $0 = true }; releaseSignal.wait() }
        func release() { releaseSignal.signal() }
    }
    private func wait(_ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try await !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(try await predicate())
    }
    private static let tagged = LocalFileMetadata(title: "Tagged title", publicationDate: Date(timeIntervalSince1970: 1_600_000_000),
        durationMilliseconds: 61_000, description: "Tagged notes", embeddedArtwork: Data([1]))

    /// What playback asked for, the task it started, and how that task ended.
    private final class Demands: Sendable {
        struct Demand: Sendable { let context: LocalPlaybackContext; let identity: LocalPlaybackFileIdentity; let task: Task<Void, Never> }
        private let values = Mutex<[Demand]>([])
        private let outcomes = Mutex<[String]>([])
        var all: [Demand] { values.withLock { $0 } }
        var results: [String] { outcomes.withLock { $0 } }
        func add(_ demand: Demand) { values.withLock { $0.append(demand) } }
        func finish(_ outcome: String) { outcomes.withLock { $0.append(outcome) } }
    }
    private static func describe(_ run: () async throws -> LocalPendingMetadata.Outcome) async -> String {
        do { return "\(try await run())" }
        catch is CancellationError { return "cancelled" }
        catch LocalPlaybackAccess.Failure.changedDocument { return "changedDocument" }
        catch let error as CocoaError { return "cocoa \(error.code.rawValue)" }
        catch { return "\(error)" }
    }
    /// Playback access whose demands run the real fill with `reader`, or are only recorded.
    private func makeAccess(_ f: Fixture, reader: (@Sendable (URL, @Sendable () throws -> Void) throws -> LocalFileMetadata)? = nil)
        -> (LocalPlaybackAccess, Demands) {
        let demands = Demands(), store = f.store
        var environment = LocalPlaybackAccess.Environment()
        environment.demandMetadata = { _, context, identity in
            let task = Task {
                guard let reader else { return }
                demands.finish(await Self.describe {
                    try await LocalPendingMetadata(store: store, readMetadata: reader)
                        .fill(episodeID: context.episodeID, reference: context.reference, playbackIdentity: identity)
                })
            }
            demands.add(.init(context: context, identity: identity, task: task))
            return task
        }
        return (LocalPlaybackAccess(store: f.store, environment: environment), demands)
    }
    private func replace(_ file: URL, with bytes: Data) throws {
        let staged = file.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("staged-\(UUID())")
        try bytes.write(to: staged)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: staged)
    }
    private func rewrite(_ file: URL, with bytes: Data) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.write(contentsOf: bytes)
    }

    @Test func playingACloudFirstEpisodeFillsItsMetadataOnceWithoutAFolderRefresh() async throws {
        try await fixture { f in
            let reads = Mutex<[String]>([])
            let (access, demands) = makeAccess(f) { url, _ in reads.withLock { $0.append(url.lastPathComponent) }; return Self.tagged }
            let logs = try await f.store.logs(feedID: 1)
            let document = try #require(try await access.open(episode: f.episode))
            defer { document.close() }
            #expect(demands.all.isEmpty, "Only confirmed playback asks for metadata")
            for _ in 0..<3 { #expect(try await access.confirm(document)) }
            let demand = try #require(demands.all.first)
            #expect(demands.all.count == 1 && demand.context.episodeID == f.episode.id, "Repeated confirmations join one read")
            await demand.task.value
            #expect(demands.results == ["filled"] && reads.withLock { $0 } == ["tagged.mp3"])
            let filled = try #require(try await f.store.episode(id: f.episode.id))
            #expect(filled.details.title == "Tagged title" && filled.details.description == "Tagged notes")
            #expect(filled.details.publicationDate == Date(timeIntervalSince1970: 1_600_000_000))
            #expect(filled.details.media == ParsedMedia(url: f.episode.details.media?.url, size: 64, mimeType: "audio/mpeg",
                durationMilliseconds: 61_000, hasEmbeddedPicture: true, metadataPending: nil))
            #expect(filled.userState == f.episode.userState && filled.details.identifier == f.episode.details.identifier)
            #expect(try await f.store.logs(feedID: 1) == logs, "No folder refresh ran")
            // The playing document stays valid; an episode whose metadata is known asks for nothing.
            #expect(try await access.confirm(document))
            let again = try #require(try await access.open(episode: filled))
            defer { again.close() }
            #expect(try await access.confirm(again))
            #expect(demands.all.count == 1 && reads.withLock { $0 }.count == 1)
        }
    }

    @Test func theAppsOwnDemandReadsTheDownloadedFileOffThePlayersPath() async throws {
        let source = try #require(Bundle.module.url(forResource: "VorbisDescriptions/auphonic.ogg", withExtension: nil, subdirectory: "Fixtures"))
        try await fixture(name: "auphonic.ogg", contents: source) { f in
            let access = LocalPlaybackAccess(store: f.store)
            let document = try #require(try await access.open(episode: f.episode))
            defer { document.close() }
            #expect(try await access.confirm(document))
            try await wait { try await f.store.episode(id: f.episode.id)?.details.media?.metadataPending == nil }
            let filled = try #require(try await f.store.episode(id: f.episode.id))
            #expect(filled.details.title == "Title" && filled.details.media?.durationMilliseconds == 10_000)
            #expect(filled.details.media?.hasEmbeddedPicture == true && filled.userState == f.episode.userState)
        }
    }

    @Test func aSameSizeReplacementOfThePlayedFileIsNeverFilledIn() async throws {
        try await fixture { f in
            let (access, demands) = makeAccess(f)
            let document = try #require(try await access.open(episode: f.episode))
            #expect(try await access.confirm(document))
            let demand = try #require(demands.all.first)
            // Replaced under the same name and size, with no scan: playback refuses the new file...
            let file = f.folder.appendingPathComponent("tagged.mp3")
            try replace(file, with: Data(repeating: 7, count: 64))
            await #expect(throws: LocalPlaybackAccess.Failure.changedDocument) { try await document.read(at: 0, maximumCount: 64) }
            // ...and so does the metadata read playback asked for, before reading anything.
            let reads = Mutex(0)
            let replacement = LocalPendingMetadata(store: f.store) { _, _ in
                reads.withLock { $0 += 1 }; return LocalFileMetadata(title: "Replacement title", description: "Replacement notes")
            }
            await #expect(throws: LocalPlaybackAccess.Failure.changedDocument) {
                try await replacement.fill(episodeID: demand.context.episodeID, reference: demand.context.reference, playbackIdentity: demand.identity)
            }
            #expect(reads.withLock { $0 } == 0)
            #expect(try await f.store.episode(id: f.episode.id) == f.episode)
            document.close()

            // The work stays pending for the next valid demand: playing the new file reads it.
            let (next, nextDemands) = makeAccess(f) { _, _ in LocalFileMetadata(title: "Replacement title") }
            let reopened = try #require(try await next.open(episode: f.episode))
            defer { reopened.close() }
            #expect(try await next.confirm(reopened))
            await nextDemands.all.first?.task.value
            #expect(nextDemands.results == ["filled"])
            #expect(try await f.store.episode(id: f.episode.id)?.details.title == "Replacement title")
        }
    }

    @Test(arguments: ["replace", "rewrite"])
    func aFileChangedDuringTheReadIsNotFilledIn(change: String) async throws {
        try await fixture { f in
            let gate = Gate()
            let (access, demands) = makeAccess(f) { _, _ in gate.hold(); return Self.tagged }
            let document = try #require(try await access.open(episode: f.episode))
            defer { document.close() }
            #expect(try await access.confirm(document))
            try await wait { gate.entered }
            let file = f.folder.appendingPathComponent("tagged.mp3")
            if change == "replace" { try replace(file, with: Data(repeating: 7, count: 64)) }
            else { try rewrite(file, with: Data(repeating: 9, count: 64)) }
            gate.release()
            await demands.all.first?.task.value
            #expect(demands.results == ["changedDocument"])
            #expect(try await f.store.episode(id: f.episode.id) == f.episode)
        }
    }

    @Test func closingThePlaybackDocumentCancelsItsUnfinishedRead() async throws {
        try await fixture { f in
            let gate = Gate()
            let (access, demands) = makeAccess(f) { _, _ in gate.hold(); return Self.tagged }
            let document = try #require(try await access.open(episode: f.episode))
            #expect(try await access.confirm(document))
            try await wait { gate.entered }
            document.close()
            gate.release()
            await demands.all.first?.task.value
            #expect(demands.results == ["cancelled"])
            #expect(try await f.store.episode(id: f.episode.id) == f.episode)
            // A closed document starts nothing more.
            _ = try await access.confirm(document)
            #expect(demands.all.count == 1)
        }
    }

    @Test(arguments: ["scan", "reconnect"])
    func aFillOvertakenByAScanOrReconnectionIsStale(change: String) async throws {
        try await fixture { f in
            let gate = Gate()
            let (access, demands) = makeAccess(f) { _, _ in gate.hold(); return Self.tagged }
            let document = try #require(try await access.open(episode: f.episode))
            defer { document.close() }
            #expect(try await access.confirm(document))
            try await wait { gate.entered }
            if change == "scan" { _ = try await f.refresh.refresh(feedID: 1, description: "", author: "") }
            else {
                _ = try await f.store.reconnectLocalFolder(feedID: 1, directoryIdentity: f.folder.absoluteString,
                    bookmark: LocalFolderDocuments.makeBookmark(directory: f.folder))
            }
            let before = try await f.store.episode(id: f.episode.id)
            gate.release()
            await demands.all.first?.task.value
            #expect(demands.results == ["stale"])
            #expect(try await f.store.episode(id: f.episode.id) == before)
            #expect(before?.details.media?.metadataPending == true && before?.details.title == "tagged")
        }
    }

    @Test func aFailedFillLeavesTheWorkPendingForTheNextScan() async throws {
        try await fixture { f in
            let (access, demands) = makeAccess(f) { _, _ in throw CocoaError(.fileReadNoPermission) }
            let document = try #require(try await access.open(episode: f.episode))
            defer { document.close() }
            #expect(try await access.confirm(document))
            await demands.all.first?.task.value
            #expect(demands.results == ["cocoa \(CocoaError.fileReadNoPermission.rawValue)"])
            #expect(try await f.store.episode(id: f.episode.id) == f.episode)
            // Downloaded by the playback that asked: the next scan reads it.
            f.provider.set("tagged.mp3", .current)
            _ = try await f.refresh.refresh(feedID: 1, description: "", author: "")
            let scanned = try #require(try await f.store.episode(id: f.episode.id))
            #expect(scanned.details.title == "Scanned title" && scanned.details.media?.metadataPending == nil)
            #expect(scanned.userState == f.episode.userState)
        }
    }
}
