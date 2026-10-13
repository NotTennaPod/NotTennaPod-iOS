import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

struct ID3CommentReaderTests {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ID3-\(UUID()).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
    private func size(_ n: Int, safe: Bool) -> [UInt8] {
        safe ? [UInt8((n >> 21) & 127), UInt8((n >> 14) & 127), UInt8((n >> 7) & 127), UInt8(n & 127)]
             : [UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]
    }
    private func frame(_ id: String, payload: [UInt8], version: Int = 3, flags: UInt8 = 0) -> [UInt8] {
        Array(id.utf8) + size(payload.count, safe: version == 4) + [0, flags] + payload
    }
    private func tag(_ body: [UInt8], version: Int = 3, flags: UInt8 = 0) -> Data {
        Data([73, 68, 51, UInt8(version), 0, flags] + size(body.count, safe: true) + body)
    }
    private var comment: [UInt8] { frame("COMM", payload: [0, 101, 110, 103, 0] + Array("Comment".utf8) + [0]) }

    private struct Oracle: Decodable {
        struct Case: Decodable { let name, data: String; let error, expected: String? }
        struct Extended: Decodable { let data, originalResult, intendedComment: String }
        let referenceCommit: String
        let cases: [Case]
        let extendedHeader: Extended
    }
    private func oracle() throws -> Oracle {
        let url = try #require(Bundle.module.url(forResource: "id3-comments-oracle", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
    }

    @Test func unchangedOriginalReadersAgreeOnByteLevelCommentCorpus() throws {
        let oracle = try oracle()
        #expect(oracle.referenceCommit == "f8c641887e4677237b01b6e942ff8fe20fc8beec")
        #expect(oracle.cases.count == 622)
        try fixture { url in
            for item in oracle.cases {
                try #require(Data(base64Encoded: item.data)).write(to: url)
                if item.error != nil {
                    #expect(throws: (any Error).self, "\(item.name)") { try ID3CommentReader.read(url: url) }
                } else {
                    let actual = try ID3CommentReader.read(url: url)
                    #expect(actual.map { Array($0.utf16) } == item.expected.map { Array($0.utf16) }, "\(item.name)")
                }
            }
        }
    }

    @Test func validExtendedHeaderRetainsCommentInsteadOfOriginalSkipDefect() throws {
        let original = try oracle().extendedHeader
        #expect(original.originalResult == "N", "Retain the unchanged Java defect evidence")
        try fixture { url in
            try #require(Data(base64Encoded: original.data)).write(to: url)
            #expect(try ID3CommentReader.read(url: url) == original.intendedComment)
            let extendedV4: [UInt8] = [0, 0, 0, 6, 1, 0]
            try tag(extendedV4 + frame("COMM", payload: [0, 101, 110, 103, 0, 118, 52, 0], version: 4), version: 4, flags: 0x40).write(to: url)
            #expect(try ID3CommentReader.read(url: url) == "v4")
        }
    }

    @Test func everyTruncatedPrefixAndOversizeFrameIsRejectedWithoutPartialComment() throws {
        try fixture { url in
            let complete = tag(comment)
            for length in 0..<complete.count {
                try complete.prefix(length).write(to: url)
                #expect(throws: (any Error).self) { try ID3CommentReader.read(url: url) }
            }
            let malformed = Array("COMM".utf8) + [255, 255, 255, 255, 0, 0]
            try tag(comment + malformed).write(to: url)
            #expect(throws: ID3CommentReader.Failure.truncated) { try ID3CommentReader.read(url: url) }
            var invalidSize = complete; invalidSize[6] = 128
            try invalidSize.write(to: url)
            #expect(throws: ID3CommentReader.Failure.invalidSize) { try ID3CommentReader.read(url: url) }
        }
    }

    @Test func sparseArtworkAndMediaAreSkippedInsteadOfLoaded() throws {
        try fixture { url in
            let artworkSize = 100 * 1024 * 1024
            let tagSize = 10 + artworkSize + comment.count
            let header = [73, 68, 51, 3, 0, 0] + size(tagSize, safe: true)
            try Data(header + Array("APIC".utf8) + size(artworkSize, safe: false) + [0, 0]).write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seek(toOffset: UInt64(20 + artworkSize)); try handle.write(contentsOf: Data(comment))
            try handle.truncate(atOffset: 4 * 1024 * 1024 * 1024); try handle.close()
            #expect(try ID3CommentReader.read(url: url) == "Comment")
        }
    }

    @Test func cancellationInsideLargeTextReadDiscardsPartialResultAndClosesFile() throws {
        try fixture { url in
            let text = [UInt8](repeating: 65, count: 100_000)
            try tag(frame("COMM", payload: [0, 101, 110, 103, 0] + text + [0])).write(to: url)
            var checks = 0
            #expect(throws: CancellationError.self) {
                try ID3CommentReader.read(url: url) {
                    checks += 1
                    if checks == 5 { throw CancellationError() }
                }
            }
            #expect(try ID3CommentReader.read(url: url)?.count == 100_000)
        }
    }

    @Test func v4UnsynchronizationGroupingAndDataLengthPrefixesAreDecoded() throws {
        try fixture { url in
            // Group byte + synchsafe data length + Latin-1 COMM. FF00 is an inserted zero.
            let text: [UInt8] = [0, 101, 110, 103, 0, 0xff, 0, 0xe0, 0]
            let prefix: [UInt8] = [5, 0, 0, 0, 8]
            try tag(frame("COMM", payload: prefix + text, version: 4, flags: 0x43), version: 4).write(to: url)
            #expect(try ID3CommentReader.read(url: url) == "ÿà")
        }
    }

    @Test func unsupportedEncodingsAreExplicitAndPaddingDoesNotConsumeMedia() throws {
        try fixture { url in
            try tag(comment, version: 2).write(to: url)
            #expect(throws: ID3CommentReader.Failure.unsupportedVersion) { try ID3CommentReader.read(url: url) }
            try tag(comment, flags: 0x80).write(to: url)
            #expect(try ID3CommentReader.read(url: url) == "Comment")
            try tag(frame("COMM", payload: [0, 101, 110, 103, 0], flags: 0x80)).write(to: url)
            #expect(throws: ID3CommentReader.Failure.unsupportedFrameEncoding) { try ID3CommentReader.read(url: url) }
            try (tag(comment + [0, 0, 0]) + Data("This is media, not another frame".utf8)).write(to: url)
            #expect(try ID3CommentReader.read(url: url) == "Comment")
        }
    }
}
