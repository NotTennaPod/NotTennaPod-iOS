import Foundation
import Testing
@testable import NotTennaPodCore

struct VorbisDescriptionReaderTests {
    private struct Oracle: Decodable {
        struct Case: Decodable { let name, data: String; let expected, error: String? }
        struct Real: Decodable { let name, sha256: String; let expected: String? }
        struct Defect: Decodable { let name, data, intended: String; let expected, error: String? }
        let referenceCommit: String
        let cases: [Case]
        let realFiles: [Real]
        let defects: [Defect]
    }
    private func oracle() throws -> Oracle {
        let url = try #require(Bundle.module.url(forResource: "vorbis-descriptions-oracle", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
    }
    private func fixture(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VorbisDescription-\(UUID()).ogg")
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
    private func integer(_ value: Int) -> [UInt8] { [0, 8, 16, 24].map { UInt8((value >> $0) & 255) } }
    private func page(_ data: [UInt8]) -> [UInt8] {
        let segments = [UInt8](repeating: 255, count: data.count / 255) + [UInt8(data.count % 255)]
        // Structural fixture: the reader, like the source, does not validate CRC.
        return Array("OggS".utf8) + [UInt8](repeating: 0, count: 22) + [UInt8(segments.count)] + segments + data
    }
    private func stream(_ body: [UInt8]) -> Data {
        var bytes: [UInt8] = []
        for offset in stride(from: 0, to: body.count, by: 60_000) { bytes += page(Array(body[offset..<min(offset + 60_000, body.count)])) }
        return Data(bytes)
    }
    private func comments(_ fields: [[UInt8]], vendor: [UInt8] = []) -> [UInt8] {
        Array("OpusTags".utf8) + integer(vendor.count) + vendor + integer(fields.count)
            + fields.flatMap { integer($0.count) + $0 }
    }

    @Test func unchangedSourceCorpusMatchesFieldSelectionAndPageSpanning() throws {
        let original = try oracle()
        #expect(original.referenceCommit == "f8c641887e4677237b01b6e942ff8fe20fc8beec")
        #expect(original.cases.count == 316)
        try fixture { url in
            for item in original.cases {
                #expect(item.error == nil)
                try #require(Data(base64Encoded: item.data)).write(to: url)
                let actual = try VorbisDescriptionReader.read(url: url)
                #expect(actual.map { Array($0.utf16) } == item.expected.map { Array($0.utf16) }, "\(item.name)")
            }
        }
    }

    @Test func actualUpstreamOggAndOpusFilesUseID3FallbackAndYieldSummary() throws {
        for item in try oracle().realFiles {
            let url = try #require(Bundle.module.url(forResource: item.name, withExtension: nil, subdirectory: "Fixtures/VorbisDescriptions"))
            #expect(item.expected == "Summary")
            #expect(try VorbisDescriptionReader.read(url: url) == item.expected)
            #expect(try LocalMediaDescriptionReader.read(url: url) == item.expected)
        }
    }

    @Test func invalidKeyAndEmptyPageDoNotReproduceOriginalReaderFailures() throws {
        let defects = try oracle().defects
        #expect(defects.map(\.expected) == [nil, nil])
        #expect(defects[0].error == "NullPointerException")
        try fixture { url in
            for item in defects {
                try #require(Data(base64Encoded: item.data)).write(to: url)
                #expect(try VorbisDescriptionReader.read(url: url) == item.intended)
            }
        }
    }

    @Test func truncatedLaterVectorsRetainValidDescriptionAndOversizeIsRejected() throws {
        try fixture { url in
            let first = Array("comment=Kept".utf8)
            let partial = Array("OpusTags".utf8) + integer(0) + integer(2) + integer(first.count) + first + integer(100) + [65]
            try stream(partial).write(to: url)
            #expect(try VorbisDescriptionReader.read(url: url) == "Kept")
            let oversized = Array("OpusTags".utf8) + integer(0) + integer(1) + integer(20 * 1024 * 1024 + 1)
            try stream(oversized).write(to: url)
            #expect(throws: VorbisDescriptionReader.Failure.oversizedComment) { try VorbisDescriptionReader.read(url: url) }
            #expect(try LocalMediaDescriptionReader.read(url: url) == nil)
            try Data("Not a tagged media file".utf8).write(to: url)
            #expect(try LocalMediaDescriptionReader.read(url: url) == nil)
        }
    }

    @Test func vendorValidationHandlesUnicodeAndRejectsOverlongSurrogatesAndTruncation() throws {
        try fixture { url in
            for valid in [Array("é😀".utf8), [UInt8](repeating: 65, count: 200_000)] {
                try stream(comments([Array("comment=Kept".utf8)], vendor: valid)).write(to: url)
                #expect(try VorbisDescriptionReader.read(url: url) == "Kept")
            }
            for invalid: [UInt8] in [[0xc0, 0x80], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80], [0xe2, 0x82], [0x80]] {
                try stream(comments([Array("comment=Hidden".utf8)], vendor: invalid)).write(to: url)
                #expect(throws: VorbisDescriptionReader.Failure.invalidText) { try VorbisDescriptionReader.read(url: url) }
                #expect(try LocalMediaDescriptionReader.read(url: url) == nil)
            }
        }
    }

    @Test func cancellationDuringIgnoredVectorIsNotSwallowedByFallbackReader() throws {
        try fixture { url in
            let unused = Array("METADATA_BLOCK_PICTURE=".utf8) + [UInt8](repeating: 65, count: 1_000_000)
            try stream(comments([unused, Array("comment=Later".utf8)])).write(to: url)
            var checks = 0
            #expect(throws: CancellationError.self) {
                try LocalMediaDescriptionReader.read(url: url) {
                    checks += 1
                    if checks == 20 { throw CancellationError() }
                }
            }
            #expect(checks == 20)
            #expect(try LocalMediaDescriptionReader.read(url: url) == "Later")
        }
    }

    @Test func coordinatedRealMetadataDescriptionReachesPersistentLocalEpisodes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VorbisLibrary-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: false)
        for item in try oracle().realFiles {
            let source = try #require(Bundle.module.url(forResource: item.name, withExtension: nil, subdirectory: "Fixtures/VorbisDescriptions"))
            try FileManager.default.copyItem(at: source, to: media.appendingPathComponent(item.name))
        }
        let bookmark = try LocalFolderDocuments.makeBookmark(directory: media)
        let docs = LocalFolderDocuments(bookmark: bookmark)
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        _ = try await store.registerLocalFolder(title: "Fixture", directoryIdentity: "fixture:folder", bookmark: bookmark)
        let service = LocalFeedRefreshService(store: store, open: { _ in
            try await docs.scanInput { url, check in
                LocalFileMetadata(description: try LocalMediaDescriptionReader.read(url: url, checkCancellation: check))
            }
        })
        _ = try await service.refresh(feedID: 1, description: "Local", author: "Local folder")
        let episodes = try #require(try await store.feed(id: 1)?.episodes)
        #expect(episodes.count == 3)
        #expect(episodes.allSatisfy { $0.details.description == "Summary" })
        try await store.close()
        let reopened = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        #expect(try await reopened.feed(id: 1)?.episodes == episodes)
        try await reopened.close()
    }
}
