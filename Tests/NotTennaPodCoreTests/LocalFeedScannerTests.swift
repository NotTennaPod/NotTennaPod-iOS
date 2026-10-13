import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

struct LocalFeedScannerTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private func file(_ name: String, identity: String? = nil, size: Int64 = 123) -> LocalFeedFile {
        LocalFeedFile(name: name, identity: identity ?? "document:" + name, providerMIMEType: "audio/mpeg", mediaMIMEType: "audio/mpeg", size: size, modified: date)
    }
    private func feed(_ files: [LocalFeedFile]) -> LibraryFeed {
        LibraryFeed(id: 1, source: "antennapod_local:fixture", metadata: ParsedFeed(format: .rss, title: "Local folder"),
            episodes: files.enumerated().map { index, file in
                var episode = LibraryEpisode(id: Int64(index + 1), details: ParsedEpisode(identifier: "saved-\(index)", title: "Cached \(file.name)", description: "Saved notes",
                    link: file.name, publicationDate: date, media: ParsedMedia(url: file.identity, size: file.size, mimeType: file.providerMIMEType, durationMilliseconds: 30_000)))
                episode.userState.isFavorite = true; episode.userState.positionMilliseconds = 12_345
                episode.userState.playState = .played; episode.userState.autoDownloadEnabled = false
                return episode
            })
    }
    private func merge(_ snapshot: ParsedFeed, into saved: LibraryFeed) -> FeedRefreshResult {
        var options = FeedRefreshOptions(now: date); options.isLocalFeed = true; options.removeUnlistedItems = true
        var next: Int64 = 100
        return FeedRefreshMerger.merge(snapshot, into: saved, options: options) { next += 1; return next }
    }
    private func scan(_ files: [LocalFeedFile], saved: LibraryFeed,
                      metadata: @Sendable (LocalFeedFile) async throws -> LocalFileMetadata) async throws -> ParsedFeed {
        try await LocalFeedScanner.scan(files: files, saved: saved, folderIdentity: "fixture:folder",
            description: "Local description", author: "Local folder", newIdentifier: { "new-fixture-id" }, readMetadata: metadata)
    }

    @Test func sourceArtworkMatchingAndMediaOracles() throws {
        struct Oracle: Decodable {
            struct Artwork: Decodable { struct File: Decodable { let name: String; let mime: String? }; let files: [File]; let expected: String }
            struct Matching: Decodable { struct Episode: Decodable { let link: String; let media: Bool }; let query: String; let episodes: [Episode]; let expected: Int }
            struct Media: Decodable { let mime: String?; let expected: String }
            struct Defect: Decodable { let linkAfterMetadataReuse: String; let survivesCurrentFilenameFilter: Bool }
            let referenceCommit: String; let artwork: [Artwork]; let matching: [Matching]; let media: [Media]; let renameDefect: Defect
        }
        let url = try #require(Bundle.module.url(forResource: "local-feed-scan-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        #expect(oracle.referenceCommit == "f8c641887e4677237b01b6e942ff8fe20fc8beec")
        #expect(oracle.artwork.count == 609 && oracle.matching.count == 870 && oracle.media.count == 19)
        for row in oracle.artwork {
            let files = row.files.enumerated().map { index, item in
                LocalFeedFile(name: item.name, identity: "document:\(index)", providerMIMEType: item.mime, mediaMIMEType: nil, size: 0, modified: date)
            }
            #expect(LocalFeedScanner.artwork(files: files, folderIdentity: "fixture:folder") == row.expected)
        }
        for row in oracle.matching {
            let episodes = row.episodes.enumerated().map { index, item in
                LibraryEpisode(id: Int64(index), details: ParsedEpisode(link: item.link, media: item.media ? ParsedMedia(size: 0) : nil))
            }
            #expect((LocalFeedScanner.matchingEpisode(filename: row.query, episodes: episodes) ?? -1) == row.expected)
        }
        for row in oracle.media { #expect(LocalFeedScanner.isMedia(row.mime) == (row.expected != "UNKNOWN")) }
        // Preserve the original-method defect observation; prevention is tested separately.
        #expect(oracle.renameDefect.linkAfterMetadataReuse == "old.mp3")
        #expect(!oracle.renameDefect.survivesCurrentFilenameFilter)
    }

    @Test func unchangedIdentityAndSizeReuseMetadataAndListeningStateDespiteModifiedDate() async throws {
        var document = file("episode.mp3")
        let saved = feed([document])
        document.modified = date.addingTimeInterval(900)
        let snapshot = try await scan([document], saved: saved) { _ in
            Issue.record("Unchanged identity and size must not rescan metadata")
            return LocalFileMetadata()
        }
        let result = merge(snapshot, into: saved)
        #expect(result.feed.episodes == saved.episodes)
        #expect(result.feed.metadata.description == "Local description")
        #expect(result.feed.metadata.author == "Local folder")
        #expect(result.feed.metadata.imageURL == "antennapod_generative_cover:fixture:folder")
    }

    @Test(arguments: [1, 2, 3]) func changedDocumentRescansMetadataWithoutReplacingIDHistoryOrMeasuredDuration(change: Int) async throws {
        var document = file("episode.mp3")
        let saved = feed([document])
        if change & 1 != 0 { document.size += 1 }
        if change & 2 != 0 { document.identity = "document:reconnected" }
        let calls = Mutex<[String]>([])
        let publication = date.addingTimeInterval(123)
        let snapshot = try await scan([document], saved: saved) { file in
            calls.withLock { $0.append(file.name) }
            return LocalFileMetadata(title: "New metadata title", publicationDate: publication, durationMilliseconds: 90_000, description: "New notes")
        }
        let result = merge(snapshot, into: saved)
        let episode = try #require(result.feed.episodes.first)
        #expect(calls.withLock { $0 } == ["episode.mp3"])
        #expect(episode.id == saved.episodes[0].id && episode.details.identifier == "saved-0")
        #expect(episode.userState == saved.episodes[0].userState)
        #expect(episode.details.title == "New metadata title" && episode.details.description == "New notes")
        #expect(episode.details.publicationDate == publication)
        #expect(episode.details.media?.size == document.size && episode.details.media?.durationMilliseconds == 30_000)
        #expect(episode.details.media?.url == document.identity)
    }

    @Test func completeScanRemovesMissingFilesAndAddsFilenameFallbacks() async throws {
        let saved = feed([file("removed.mp3"), file("keep.mp3")])
        let snapshot = try await scan([file("keep.mp3"), file("new.recording.mp3")], saved: saved) { _ in
            LocalFileMetadata(title: "", durationMilliseconds: 45_000)
        }
        let result = merge(snapshot, into: saved)
        #expect(result.removedEpisodes.map(\.id) == [1])
        #expect(result.feed.episodes.first { $0.id == 2 }?.userState == saved.episodes[1].userState)
        let added = try #require(result.feed.episodes.first { $0.id == 101 })
        #expect(added.details.title == "new.recording" && added.details.link == "new.recording.mp3")
        #expect(added.details.media?.durationMilliseconds == 45_000)
        let empty = try await scan([], saved: saved) { _ in throw MetadataFailure() }
        #expect(merge(empty, into: saved).removedEpisodes.count == 2)
    }

    @Test func renameRetainsCurrentFilenameWhenReusingMetadataAndCreatesNewEpisodeIdentity() async throws {
        let saved = feed([file("old.mp3", identity: "document:stable-id")])
        let snapshot = try await scan([file("renamed.mp3", identity: "document:stable-id")], saved: saved) { _ in
            Issue.record("Same document identity/size should reuse metadata even after rename")
            return LocalFileMetadata()
        }
        let result = merge(snapshot, into: saved)
        let episode = try #require(result.feed.episodes.first)
        #expect(result.feed.episodes.count == 1 && result.removedEpisodes.map(\.id) == [1])
        #expect(episode.details.link == "renamed.mp3" && episode.details.title == "Cached old.mp3")
        #expect(episode.id == 101 && episode.details.identifier == "new-fixture-id")
        #expect(episode.userState.positionMilliseconds == 0 && !episode.userState.isFavorite)
    }

    @Test func filenamesUseJavaExactEqualityRatherThanUnicodeCanonicalEquality() async throws {
        let saved = feed([file("café.mp3")])
        let snapshot = try await scan([file("cafe\u{301}.mp3")], saved: saved) { _ in LocalFileMetadata() }
        let result = merge(snapshot, into: saved)
        #expect(result.removedEpisodes.map(\.id) == [1])
        #expect(result.feed.episodes.first?.id == 101)
        #expect(result.feed.episodes.first?.details.link?.utf16.elementsEqual("cafe\u{301}.mp3".utf16) == true)
    }

    @Test func resolvedMIMEControlsSelectionButProviderMIMEIsRetained() async throws {
        var included = file("file.bin"); included.providerMIMEType = "application/octet-stream"
        included.mediaMIMEType = "audio/mpeg"
        var excluded = file("unknown.bin"); excluded.mediaMIMEType = "application/octet-stream"
        var cover = file("folder.jpg"); cover.providerMIMEType = "text/plain"; cover.mediaMIMEType = "text/plain"
        let snapshot = try await scan([excluded, included, cover], saved: feed([])) { file in
            #expect(file.name == "file.bin")
            return LocalFileMetadata()
        }
        #expect(snapshot.episodes.count == 1)
        #expect(snapshot.episodes.first?.media?.mimeType == "application/octet-stream")
        #expect(snapshot.imageURL == cover.identity)
    }

    private func file(_ name: String, size: Int64 = 123, availability: LocalDocumentAvailability) -> LocalFeedFile {
        var result = file(name, size: size); result.availability = availability; return result
    }

    @Test func onlyAPositivelyNotDownloadedFileSkipsItsMetadataRead() async throws {
        let states: [LocalDocumentAvailability] = [.current, .downloadedStale, .unknown, .notDownloaded]
        let saved = feed(states.map { file("\($0).mp3") })
        // A changed size makes every local file read again, as today.
        let files = states.map { file("\($0).mp3", size: 456, availability: $0) }
        let calls = Mutex<[String]>([])
        let snapshot = try await scan(files, saved: saved) { file in
            calls.withLock { $0.append(file.name) }
            return LocalFileMetadata(title: "Read " + file.name, durationMilliseconds: 90_000)
        }
        let result = merge(snapshot, into: saved)
        #expect(calls.withLock { $0 } == ["current.mp3", "downloadedStale.mp3", "unknown.mp3"])
        #expect(result.removedEpisodes.isEmpty)
        for (index, state) in states.enumerated() {
            let episode = try #require(result.feed.episodes.first { $0.id == saved.episodes[index].id })
            #expect(episode.userState == saved.episodes[index].userState)
            if state == .notDownloaded {
                #expect(episode == saved.episodes[index], "Reading an evicted file would download it")
            } else {
                #expect(episode.details.title == "Read \(state).mp3" && episode.details.media?.size == 456)
            }
        }
    }

    @Test func presentFilesKeepTheirEpisodesWhateverTheirTypeAndOnlyMissingFilesAreRemoved() async throws {
        let saved = feed([file("evicted.mp3"), file("untyped.mp3"), file("gone.mp3")])
        var evicted = file("evicted.mp3", availability: .notDownloaded)
        evicted.providerMIMEType = nil; evicted.mediaMIMEType = nil
        var untyped = file("untyped.mp3", size: 999)
        untyped.providerMIMEType = nil; untyped.mediaMIMEType = nil
        let snapshot = try await scan([evicted, untyped], saved: saved) { file in
            Issue.record("No metadata read for \(file.name)")
            return LocalFileMetadata()
        }
        let result = merge(snapshot, into: saved)
        #expect(result.removedEpisodes.map(\.id) == [3])
        #expect(result.feed.episodes.map(\.id).sorted() == [1, 2])
        #expect(result.feed.episodes.allSatisfy { episode in saved.episodes.contains(episode) })
    }

    @Test(arguments: [false, true])
    func newCloudOnlyFileAppearsUnderItsFileNameAndIsReadOnceDownloaded(changedIdentity: Bool) async throws {
        let calls = Mutex(0)
        let read: @Sendable (LocalFeedFile) async throws -> LocalFileMetadata = { _ in
            calls.withLock { $0 += 1 }
            return LocalFileMetadata(title: "Tagged title", publicationDate: Date(timeIntervalSince1970: 1_600_000_000),
                durationMilliseconds: 61_000, description: "Tagged notes", embeddedArtwork: Data([1]))
        }
        let cloud = file("new.recording.mp3", size: 4_242, availability: .notDownloaded)
        var saved = feed([])
        var result = merge(try await scan([cloud], saved: saved, metadata: read), into: saved)
        let added = try #require(result.feed.episodes.first)
        #expect(calls.withLock { $0 } == 0)
        #expect(added.details.title == "new.recording" && added.details.link == "new.recording.mp3")
        #expect(added.details.publicationDate == date)
        #expect(added.details.media == ParsedMedia(url: cloud.identity, size: 4_242, mimeType: "audio/mpeg",
            durationMilliseconds: 0, hasEmbeddedPicture: false, metadataPending: true))
        saved = result.feed
        saved.episodes[0].userState.positionMilliseconds = 5_000; saved.episodes[0].userState.isFavorite = true

        // Still in the cloud: nothing is read and nothing changes.
        result = merge(try await scan([cloud], saved: saved, metadata: read), into: saved)
        #expect(calls.withLock { $0 } == 0 && result.feed.episodes == saved.episodes)

        // Downloaded, with the same size, under the same or a new provider identity.
        var downloaded = cloud; downloaded.availability = .current
        if changedIdentity { downloaded.identity = "document:materialised" }
        result = merge(try await scan([downloaded], saved: saved, metadata: read), into: saved)
        let filled = try #require(result.feed.episodes.first)
        #expect(calls.withLock { $0 } == 1)
        #expect(filled.id == added.id && filled.details.identifier == added.details.identifier)
        #expect(filled.userState == saved.episodes[0].userState)
        #expect(filled.details.title == "Tagged title" && filled.details.description == "Tagged notes")
        #expect(filled.details.publicationDate == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(filled.details.media == ParsedMedia(url: downloaded.identity, size: 4_242, mimeType: "audio/mpeg",
            durationMilliseconds: 61_000, hasEmbeddedPicture: true, metadataPending: nil))

        // Read once: later scans reuse it, and a later eviction keeps it.
        saved = result.feed
        result = merge(try await scan([downloaded], saved: saved, metadata: read), into: saved)
        var evicted = downloaded; evicted.availability = .notDownloaded
        result = merge(try await scan([evicted], saved: result.feed, metadata: read), into: result.feed)
        #expect(calls.withLock { $0 } == 1 && result.feed.episodes == saved.episodes)
    }

    @Test func aFailedReadKeepsMetadataPendingUntilALaterScanReadsTheUnchangedFile() async throws {
        let cloud = file("tagged.mp3", size: 4_242, availability: .notDownloaded)
        let pending = merge(try await scan([cloud], saved: feed([])) { _ in LocalFileMetadata() }, into: feed([])).feed
        var downloaded = cloud; downloaded.availability = .current
        let failed = merge(try await scan([downloaded], saved: pending) { _ in throw CocoaError(.fileReadNoPermission) }, into: pending)
        // Unchanged and still pending: no error text, no artwork fact, no lost work.
        #expect(failed.feed.episodes == pending.episodes && failed.removedEpisodes.isEmpty)
        let calls = Mutex(0)
        let recovered = merge(try await scan([downloaded], saved: failed.feed) { _ in
            calls.withLock { $0 += 1 }
            return LocalFileMetadata(title: "Tagged title", description: "Tagged notes", embeddedArtwork: Data([1]))
        }, into: failed.feed)
        let episode = try #require(recovered.feed.episodes.first)
        #expect(calls.withLock { $0 } == 1 && episode.id == pending.episodes[0].id)
        #expect(episode.details.title == "Tagged title" && episode.details.description == "Tagged notes")
        #expect(episode.details.media?.hasEmbeddedPicture == true && episode.details.media?.metadataPending == nil)
        // A file first seen on the device keeps today's rule: one read, its error shown.
        let local = merge(try await scan([file("broken.mp3")], saved: feed([])) { _ in throw MetadataFailure() }, into: feed([]))
        #expect(local.feed.episodes.first?.details.description == "Fixture metadata failure")
        #expect(local.feed.episodes.first?.details.media?.metadataPending == nil)
    }

    @Test func everyListedNameIsPresentEvenWhenItIsNotAFile() async throws {
        let saved = feed([file("a.mp3"), file("gone.mp3")])
        let snapshot = try await LocalFeedScanner.scan(files: [], presentNames: ["a.mp3"], saved: saved, folderIdentity: "fixture:folder",
            description: "", author: "") { _ in Issue.record("Nothing to read"); return LocalFileMetadata() }
        let result = merge(snapshot, into: saved)
        #expect(result.removedEpisodes.map(\.id) == [2] && result.feed.episodes == [saved.episodes[0]])
    }

    @Test func metadataPendingSurvivesStoredJSONAndIsAbsentForOtherEpisodes() throws {
        let pending = ParsedMedia(url: "document:a", size: 1, metadataPending: true)
        let decoded = try JSONDecoder().decode(ParsedMedia.self, from: JSONEncoder().encode(pending))
        #expect(decoded == pending)
        let plain = try JSONEncoder().encode(ParsedMedia(url: "document:a", size: 1))
        #expect(!String(decoding: plain, as: UTF8.self).contains("metadataPending"))
    }

    private struct MetadataFailure: LocalizedError { var errorDescription: String? { "Fixture metadata failure" } }
    @Test func metadataFailureKeepsEpisodeWithMessageAndCancellationDoesNotReturnPartialSnapshot() async throws {
        let snapshot = try await scan([file("broken.mp3")], saved: feed([])) { _ in throw MetadataFailure() }
        #expect(snapshot.episodes.count == 1 && snapshot.episodes[0].description == "Fixture metadata failure")
        await #expect(throws: CancellationError.self) {
            try await scan([file("one.mp3"), file("two.mp3")], saved: feed([])) { file in
                if file.name == "two.mp3" { throw CancellationError() }
                return LocalFileMetadata()
            }
        }
    }
    @Test func taskCancelledDuringMetadataReadCannotReturnAPartialFeed() async throws {
        let calls = Mutex(0)
        let task = Task {
            try await scan([file("one.mp3"), file("two.mp3")], saved: feed([])) { _ in
                calls.withLock { $0 += 1 }
                withUnsafeCurrentTask { $0?.cancel() }
                return LocalFileMetadata(title: "Late metadata")
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(calls.withLock { $0 } >= 1)
    }

}
