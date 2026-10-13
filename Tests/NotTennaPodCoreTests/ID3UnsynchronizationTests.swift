import Foundation
import Testing
@testable import NotTennaPodCore

struct ID3UnsynchronizationTests {
    private func integer(_ n: Int, safe: Bool = false) -> [UInt8] {
        let shift = safe ? 7 : 8, mask = safe ? 127 : 255
        return [3, 2, 1, 0].map { UInt8((n >> ($0 * shift)) & mask) }
    }
    private func frame(_ id: String, payload: [UInt8], flags: [UInt8] = [0, 0]) -> [UInt8] {
        Array(id.utf8) + integer(payload.count) + flags + payload
    }
    private func comment(_ bytes: [UInt8]) -> [UInt8] {
        frame("COMM", payload: [0, 101, 110, 103, 0] + bytes)
    }
    /// Independent encoder: escape FF before 00/E0...FF and at the tag's end.
    private func encode(_ bytes: [UInt8]) -> [UInt8] {
        var encoded: [UInt8] = []
        for (index, byte) in bytes.enumerated() {
            encoded.append(byte)
            if byte == 0xff && (index + 1 == bytes.count || bytes[index + 1] == 0 || bytes[index + 1] >= 0xe0) {
                encoded.append(0)
            }
        }
        return encoded
    }
    private func tag(_ body: [UInt8], extended: Bool = false, escaped: Bool = true) -> Data {
        let payload = escaped ? encode(body) : body
        return Data([73, 68, 51, 3, 0, (escaped ? 0x80 : 0) | (extended ? 0x40 : 0)] + integer(payload.count, safe: true) + payload)
    }
    private func fixture(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ID3Unsync-\(UUID()).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    @Test func escapedTagPreservesCommentThatOriginalReaderTruncates() throws {
        struct Oracle: Decodable {
            struct Example: Decodable { let data, originalResult, intendedComment: String }
            let unsynchronization: Example
        }
        let url = try #require(Bundle.module.url(forResource: "id3-comments-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let original = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url)).unsynchronization
        #expect(original.originalResult == "Vw78=", "Preserve original reader's truncated ÿ result")
        try fixture { url in
            try #require(Data(base64Encoded: original.data)).write(to: url)
            #expect(try ID3CommentReader.read(url: url) == original.intendedComment)
        }
    }

    @Test func everyEscapedBytePairAcrossChunkBoundaryMatchesUnescapedTag() throws {
        try fixture { url in
            // Payload begins at physical offset25. Place FF at the end of a16KiB
            // refill and immediately around it. The escape rule only distinguishes
            // a following 00, E0...FF or any other byte, so cover each class and its
            // edges instead of all 256 values (same coverage, a tenth of the time).
            let boundaryOffset = 16_384 - 10 - 5 - 1 // Frame header + COMM prefix.
            for offset in [boundaryOffset - 1, boundaryOffset, boundaryOffset + 1] {
                for next: UInt8 in [0x00, 0x01, 0x41, 0xDF, 0xE0, 0xF0, 0xFE, 0xFF] {
                    let text = [UInt8](repeating: 65, count: offset) + [0xff, next, 66, 0]
                    let body = comment(text)
                    try tag(body, escaped: false).write(to: url)
                    let expected = try ID3CommentReader.read(url: url)
                    try tag(body).write(to: url)
                    let actual = try ID3CommentReader.read(url: url)
                    #expect(actual?.utf16.elementsEqual(expected?.utf16 ?? "".utf16) == true,
                        "offset=\(offset), followingByte=\(next)")
                }
            }
        }
    }

    @Test func escapedFrameLengthsAndSkippedPayloadKeepFollowingFramesAligned() throws {
        try fixture { url in
            for count in [255, 511, 65_535] {
                let artwork = frame("APIC", payload: [UInt8](repeating: 0xff, count: count))
                let body = artwork + comment([0xff, 0xe0, 0]) + frame("TXXX", payload: [0] + Array("comment".utf8) + [0] + Array("Final".utf8))
                try tag(body).write(to: url)
                #expect(try ID3CommentReader.read(url: url) == "Final", "decoded size=\(count)")
            }
        }
    }

    @Test func extendedHeaderGroupingAndTerminalEscapeAreHandledOnce() throws {
        try fixture { url in
            let extended = integer(6) + [0, 0, 0, 0, 0, 0]
            let grouped = frame("COMM", payload: [0xff, 0, 101, 110, 103, 0, 0xff], flags: [0, 0x20])
            try tag(extended + grouped, extended: true).write(to: url)
            #expect(try ID3CommentReader.read(url: url) == "ÿ")
            // The audio begins with bytes that would look like escaped tag text.
            try (tag(comment([0xff])) + Data([0, 0xe0, 0xff, 0])).write(to: url)
            #expect(try ID3CommentReader.read(url: url) == "ÿ")
        }
    }

    @Test func incompleteDecodedFramesFailAndLargeSkippedFramesRemainCancellable() throws {
        try fixture { url in
            let oversized = Array("COMM".utf8) + integer(4) + [0, 0, 0xff, 0, 0xff]
            try tag(oversized).write(to: url)
            #expect(throws: ID3CommentReader.Failure.truncated) { try ID3CommentReader.read(url: url) }
            let body = frame("APIC", payload: [UInt8](repeating: 0xff, count: 1_000_000)) + comment(Array("After".utf8))
            try tag(body).write(to: url)
            var checks = 0
            #expect(throws: CancellationError.self) {
                try ID3CommentReader.read(url: url) {
                    checks += 1
                    if checks == 15 { throw CancellationError() }
                }
            }
            #expect(try ID3CommentReader.read(url: url) == "After")
        }
    }
}
