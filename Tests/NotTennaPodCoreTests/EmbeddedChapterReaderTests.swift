import CryptoKit
import Foundation
import ImageIO
import Synchronization
import Testing
@testable import NotTennaPodCore

private final class ChapterTestInput: MediaByteInput {
    let data: Data
    let supportsRandomAccess = true
    var length: Int64? { Int64(data.count) }
    struct State { var cancelled = false; var checks = 0; var reads: [(offset: Int64, count: Int)] = [] }
    let state = Mutex(State())
    let cancelAfterChecks: Int?
    init(_ data: Data, cancelAfterChecks: Int? = nil) { self.data = data; self.cancelAfterChecks = cancelAfterChecks }
    func prepareForSeek() {}
    func cancel() { state.withLock { $0.cancelled = true } }
    func checkFailure() throws {
        try state.withLock { state in
            state.checks += 1
            if state.cancelled || cancelAfterChecks.map({ state.checks > $0 }) == true { throw CancellationError() }
        }
    }
    func read(at offset: Int64, maximumCount: Int) throws -> Data {
        try checkFailure()
        guard offset >= 0, offset <= data.count, maximumCount > 0, maximumCount <= 65_536 else { throw URLError(.badServerResponse) }
        let end = min(Int(offset) + maximumCount, data.count)
        state.withLock { $0.reads.append((offset, end - Int(offset))) }
        return data.subdata(in: Int(offset)..<end)
    }
}

struct EmbeddedChapterReaderTests {
    private struct Oracle: Decodable {
        struct Case: Decodable {
            let file: String
            let loaded: [ParsedChapter]?
            let rawError: String?
        }
        let referenceCommit: String
        let complete: Bool
        let cases: [Case]
    }
    private func url(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/EmbeddedChapters"))
    }
    private func oracle() throws -> Oracle {
        let result = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url("oracle.json")))
        #expect(result.complete && result.referenceCommit == "f8c641887e4677237b01b6e942ff8fe20fc8beec")
        #expect(result.cases.count == 50)
        return result
    }
    @Test func originalMetadataOrderingTitlesLinksAndImageReferences() throws {
        for item in try oracle().cases where !item.file.contains("id-collision") {
            #expect(try EmbeddedChapterReader.read(url: url(item.file)) == item.loaded, "original media case \(item.file)")
        }
    }
    @Test func distinctThreeDigitVorbisIDsDoNotDiscardValidChapters() throws {
        let cases = try oracle().cases.filter { $0.file.contains("id-collision") }
        #expect(cases.count == 2)
        for item in cases {
            // Confirm the retained source defect rather than rewriting its oracle.
            #expect(item.loaded == nil && item.rawError?.contains("duplicate ID (chapter100") == true)
            let result = try #require(try EmbeddedChapterReader.read(url: url(item.file)))
            #expect(result == [.init(startMilliseconds: 1000, title: "0", chapterID: "0"),
                               .init(startMilliseconds: 2000, title: "1", chapterID: "100")])
        }
    }
    @Test func originalEmbeddedArtworkBytesAndDecodableImages() throws {
        struct Report: Decodable {
            struct Entry: Decodable {
                struct Chapter: Decodable { let imageURL: String?; let artworkSHA256: String? }
                let file: String; let loaded: [Chapter]?
            }
            let cases: [Entry]
        }
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: url("oracle.json")))
        var checked = 0
        for item in report.cases {
            for chapter in item.loaded ?? [] {
                guard let expected = chapter.artworkSHA256 else { continue }
                let reference = try #require(chapter.imageURL.flatMap(EmbeddedChapterImage.init(url:)))
                let data = try reference.read(url: url(item.file))
                #expect(data.count == reference.length)
                #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == expected)
                let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
                #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
                checked += 1
            }
        }
        #expect(checked == 11)
    }
    @Test func largePicturesStayOutOfMetadataReads() throws {
        let data = try Data(contentsOf: url("original-ultraschall5.mp3"))
        let input = ChapterTestInput(data)
        #expect(try EmbeddedChapterReader.read(input: input)?.count == 3)
        let reads = input.state.withLock { $0.reads }
        #expect(reads.allSatisfy { $0.count <= 65_536 })
        #expect(reads.reduce(0) { $0 + $1.count } < data.count / 4)
    }
    @Test func cancellationDuringBufferedParsingRemainsRetryable() throws {
        let data = try Data(contentsOf: url("original-auphonic.mp3"))
        let input = ChapterTestInput(data, cancelAfterChecks: 30)
        #expect(throws: CancellationError.self) { try EmbeddedChapterReader.read(input: input) }
        #expect(try EmbeddedChapterReader.read(input: ChapterTestInput(data))?.count == 4)
    }
    @Test func providerCancellationProbeRunsThroughoutFileAndImageReads() throws {
        let file = try url("original-auphonic.mp3"), checks = Mutex(0)
        #expect(throws: CancellationError.self) {
            try EmbeddedChapterReader.read(url: file, checkCancellation: {
                let count = checks.withLock { $0 += 1; return $0 }
                if count > 30 { throw CancellationError() }
            })
        }
        let reference = try #require(EmbeddedChapterImage(url: "embedded-image://16073/2750569"))
        let large = try url("original-ultraschall5.mp3"), imageChecks = Mutex(0)
        #expect(throws: CancellationError.self) {
            try reference.read(url: large, checkCancellation: {
                let count = imageChecks.withLock { $0 += 1; return $0 }
                if count > 10 { throw CancellationError() }
            })
        }
    }
    @Test func embeddedImageURLsAndOutOfBoundsRangesCannotReadOutsideResource() throws {
        for address in ["embedded-image://-1/3", "embedded-image://0/-1", "embedded-image://0/1/2",
                        "embedded-image://0/1?extra", "embedded-image://9223372036854775807/1", "https://example.test/1/2"] {
            #expect(EmbeddedChapterImage(url: address) == nil)
        }
        let reference = try #require(EmbeddedChapterImage(url: "embedded-image://10/20"))
        #expect(throws: (any Error).self) { try reference.read(input: ChapterTestInput(Data(repeating: 0, count: 20))) }
    }
}
