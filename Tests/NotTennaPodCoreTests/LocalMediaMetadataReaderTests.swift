import CryptoKit
import Foundation
import Testing
@testable import NotTennaPodCore

struct LocalMediaMetadataReaderTests {
    private struct Oracle: Decodable {
        struct Fixture: Decodable {
            let path, sha256: String
            let title, date, durationMilliseconds, artworkSHA256: String?
            let artworkBytes: Int?
            var name: String { URL(fileURLWithPath: path).lastPathComponent }
            var comments: String? { path.contains("VorbisDescriptions/") ? "Summary" : nil }
        }
        let fixtures: [Fixture]
    }
    private func fixtures() throws -> [Oracle.Fixture] {
        let url = try #require(Bundle.module.url(forResource: "local-metadata-native-oracle", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url)).fixtures
    }
    private func url(_ item: Oracle.Fixture) throws -> URL {
        let suffix = try #require(item.path.range(of: "/Fixtures/"))
        let relative = String(item.path[suffix.upperBound...])
        return try #require(Bundle.module.url(forResource: relative, withExtension: nil, subdirectory: "Fixtures"))
    }
    private func check(_ metadata: LocalFileMetadata, against item: Oracle.Fixture) {
        #expect(metadata.title == item.title)
        // All ten recorded raw dates are absent, bare years, or the source's
        // explicit MP4 sentinel, so scanning must retain file-modified dates.
        #expect(metadata.publicationDate == nil)
        #expect(metadata.durationMilliseconds == item.durationMilliseconds.flatMap(Int32.init))
        #expect(metadata.description == item.comments)
        #expect(metadata.embeddedArtwork?.count == item.artworkBytes)
        if let picture = metadata.embeddedArtwork {
            #expect(SHA256.hash(data: picture).map { String(format: "%02x", $0) }.joined() == item.artworkSHA256)
        }
    }

    @Test func allTenActualMediaFilesMatchIndependentAndroidMetadataAndOriginalComments() throws {
        let fixtures = try fixtures()
        #expect(fixtures.count == 10)
        for item in fixtures {
            let file = try url(item)
            #expect(SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined() == item.sha256)
            check(try LocalMediaMetadataReader.read(url: file), against: item)
        }
    }

    @Test func codecPathMatchesSameMetadataOnPlatformsThatCanNativelyOpenVorbis() throws {
        for item in try fixtures() where ["ogg", "opus", "webm"].contains(URL(fileURLWithPath: item.path).pathExtension) {
            check(try LocalMediaMetadataReader.readUsingCodec(url: url(item)), against: item)
        }
    }

    @Test func durationMappingRoundsAndRejectsInvalidValuesWithoutNegativeOverflow() {
        for seconds: Double? in [nil, .nan, .infinity, -.infinity, -1, Double.greatestFiniteMagnitude,
                                (Double(Int32.max) + 1) / 1000] {
            #expect(LocalMediaMetadataReader.milliseconds(seconds) == nil)
        }
        #expect(LocalMediaMetadataReader.milliseconds(0) == 0)
        #expect(LocalMediaMetadataReader.milliseconds(0.00049) == 0)
        #expect(LocalMediaMetadataReader.milliseconds(0.0005) == 1)
        #expect(LocalMediaMetadataReader.milliseconds(30.040816326530614) == 30_041)
        #expect(LocalMediaMetadataReader.milliseconds(Double(Int32.max) / 1000) == .max)
    }

    @Test func actualMetadataFlowsThroughCoordinatedScanAndPersistsAfterReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MetadataPipeline-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let items = try fixtures()
        for item in items {
            let file = folder.appendingPathComponent(item.name)
            try FileManager.default.copyItem(at: url(item), to: file)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        }
        let bookmark = try LocalFolderDocuments.makeBookmark(directory: folder)
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        _ = try await store.registerLocalFolder(title: "Metadata", directoryIdentity: "fixture:metadata", bookmark: bookmark)
        let service = LocalFeedRefreshService(store: store)
        let outcome = try await service.refresh(feedID: 1, description: "Local", author: "Local folder")
        guard case .updated = outcome else { Issue.record("Actual metadata refresh failed: \(outcome)"); return }
        let episodes = try #require(try await store.feed(id: 1)?.episodes)
        #expect(episodes.count == items.count)
        for item in items {
            let episode = try #require(episodes.first { $0.details.link == item.name })
            #expect(episode.details.title == (item.title ?? (item.name as NSString).deletingPathExtension))
            #expect(episode.details.publicationDate == modified)
            #expect(episode.details.media?.durationMilliseconds == item.durationMilliseconds.flatMap(Int32.init))
            #expect(episode.details.description == item.comments)
            #expect(episode.details.media?.hasEmbeddedPicture == (item.artworkBytes != nil))
        }
        try await store.close()
        let reopened = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        #expect(try await reopened.feed(id: 1)?.episodes == episodes)
        let reader = EpisodeArtworkReader(store: reopened)
        for item in items {
            let id = try #require(episodes.first { $0.details.link == item.name }?.id)
            try await reopened.updateEpisode(id: id) { $0.details.media?.hasEmbeddedPicture = nil }
            let episode = try #require(try await reopened.feed(id: 1)?.episodes.first { $0.details.link == item.name })
            let picture = try await reader.read(episode: episode)
            #expect(picture?.count == item.artworkBytes)
            #expect(picture.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } == item.artworkSHA256)
            #expect(try await reopened.episode(id: id)?.details.media?.hasEmbeddedPicture == (item.artworkBytes != nil))
        }
        try await reopened.close()
    }
}
