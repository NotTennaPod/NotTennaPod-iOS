import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite
struct MediaDownloadRangeTests {
    private func destination() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadRange-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("episode")
    }

    @Test func invalidResumeMetadataCannotMutateExistingBytes() async throws {
        let cases: [(String?, String)] = [
            (nil, "def"), ("invalid", "def"), ("bytes 5-7/8", "xyz"), ("bytes 1-3/8", "xyz"),
            ("bytes 3-5/5", "def"), ("bytes 3-2/6", "def"), ("bytes 3-5/6", "defg"),
            ("bytes 3-5/6", "de"), ("bytes 3-9223372036854775807/*", "def"),
            ("items 3-5/6", "def"), ("bytes +3-5/6", "def")
        ]
        for (range, body) in cases {
            let server = try await LoopbackHTTPServer.start { _ in
                .init(status: 206, headers: range.map { ["Content-Range": $0] } ?? [:], body: Data(body.utf8))
            }
            defer { server.stop() }
            let file = try destination()
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let prefix = Data("abc".utf8)
            try prefix.write(to: file)
            await #expect(throws: MediaDownloadError.invalidRange) {
                try await MediaDownloadTransfer().download(.init(source: server.url.absoluteString, destination: file, representation: .init(resource: server.url, entityTag: "\"v1\"")))
            }
            #expect(try Data(contentsOf: file) == prefix, "Rejected range: \(range ?? "missing")")
            #expect(server.requests.map { $0.headers["range"] } == ["bytes=3-"])
        }
    }

    @Test(arguments: [false, true])
    func shorterValidRangesContinueUntilTheWholeRepresentationArrives(omitLaterTotal: Bool) async throws {
        let server = try await LoopbackHTTPServer.start { request in
            switch request.headers["range"] {
            case "bytes=3-": .init(status: 206, headers: ["ETag": "\"v1\"", "Content-Range": "bytes 3-4/8"], body: Data("de".utf8))
            case "bytes=5-": .init(status: 206, headers: ["ETag": "\"v1\"", "Content-Range": omitLaterTotal ? "bytes 5-7/*" : "bytes 5-7/8"], body: Data("fgh".utf8))
            default: .init(status: 400, body: Data())
            }
        }
        defer { server.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("abc".utf8).write(to: file)
        let progress = Mutex<[MediaDownloadProgress]>([])
        let result = try await MediaDownloadTransfer().download(.init(source: server.url.absoluteString, destination: file, representation: .init(resource: server.url, entityTag: "\"v1\"")),
            progress: { value in progress.withLock { $0.append(value) } })
        #expect(try Data(contentsOf: file) == Data("abcdefgh".utf8))
        #expect(result.size == 8)
        #expect(server.requests.map { $0.headers["range"] } == ["bytes=3-", "bytes=5-"])
        #expect(progress.withLock { $0.first == .init(received: 3, expected: 8) && $0.last == .init(received: 8, expected: 8) })
    }

    @Test func unknownTotalResumeRestartsWithAFullResponseInsteadOfGuessingCompletion() async throws {
        let server = try await LoopbackHTTPServer.start { request in
            if request.headers["range"] != nil {
                return .init(status: 206, headers: ["ETag": "\"v1\"", "Content-Range": "bytes 3-5/*"], body: Data("def".utf8))
            }
            return .init(body: Data("abcdefghi".utf8))
        }
        defer { server.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("abc".utf8).write(to: file)
        let result = try await MediaDownloadTransfer().download(.init(source: server.url.absoluteString, destination: file, representation: .init(resource: server.url, entityTag: "\"v1\"")))
        #expect(result.size == 9)
        #expect(try Data(contentsOf: file) == Data("abcdefghi".utf8))
        #expect(server.requests.map { $0.headers["range"] } == ["bytes=3-", nil])
        let full = try #require(server.requests.last)
        #expect(full.headers["if-range"] == nil && full.headers["if-none-match"] == nil && full.headers["if-modified-since"] == nil)
    }

    @Test func verifiedByteProgressDoesNotConsumeTheRedirectRetryLimit() async throws {
        let bytes = Data((0..<30).map(UInt8.init))
        let server = try await LoopbackHTTPServer.start { request in
            guard let range = request.headers["range"], let start = Int(range.dropFirst(6).dropLast()), bytes.indices.contains(start) else {
                return .init(status: 400, body: Data())
            }
            return .init(status: 206, headers: ["ETag": "\"v1\"", "Content-Range": "bytes \(start)-\(start)/30"], body: bytes[start...start])
        }
        defer { server.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try bytes.prefix(1).write(to: file)
        let result = try await MediaDownloadTransfer(availableCapacity: { _ in 29 }).download(.init(source: server.url.absoluteString, destination: file, representation: .init(resource: server.url, entityTag: "\"v1\"")))
        #expect(result.size == 30 && server.requests.count == 29)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func changedTotalBetweenPartialResponsesCannotBeCommittedAsComplete() async throws {
        let server = try await LoopbackHTTPServer.start { request in
            if request.headers["range"] == "bytes=3-" {
                return .init(status: 206, headers: ["ETag": "\"v1\"", "Content-Range": "bytes 3-4/8"], body: Data("de".utf8))
            }
            return .init(status: 206, headers: ["ETag": "\"v1\"", "Content-Range": "bytes 5-7/9"], body: Data("BAD".utf8))
        }
        defer { server.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("abc".utf8).write(to: file)
        await #expect(throws: MediaDownloadError.invalidRange) {
            try await MediaDownloadTransfer().download(.init(source: server.url.absoluteString, destination: file, representation: .init(resource: server.url, entityTag: "\"v1\"")))
        }
        #expect(try Data(contentsOf: file) == Data("abcde".utf8))
        #expect(server.requests.count == 2)
    }

    @Test func ignoredRangeResetsProgressAndCapacityToReplacementLength() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(body: Data("new".utf8)) }
        defer { server.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("old partial bytes".utf8).write(to: file)
        let progress = Mutex<[MediaDownloadProgress]>([])
        let result = try await MediaDownloadTransfer(availableCapacity: { _ in 3 }).download(
            .init(source: server.url.absoluteString, destination: file, representation: .init(resource: server.url, entityTag: "\"v1\"")), progress: { value in progress.withLock { $0.append(value) } })
        #expect(result.size == 3)
        #expect(try Data(contentsOf: file) == Data("new".utf8))
        #expect(progress.withLock { $0.first == .init(received: 0, expected: 3) && $0.last == .init(received: 3, expected: 3) })
    }

    @Test(arguments: [false, true])
    func chunkedPartialBodyMustMatchItsDeclaredRange(overlong: Bool) async throws {
        let encoded = overlong ? "4\r\ndefg\r\n0\r\n\r\n" : "2\r\nde\r\n0\r\n\r\n"
        let server = try await LoopbackHTTPServer.start { _ in
            .init(status: 206, headers: ["ETag": "\"v1\"", "Content-Range": "bytes 3-5/6", "Transfer-Encoding": "chunked"], body: Data(encoded.utf8))
        }
        defer { server.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("abc".utf8).write(to: file)
        await #expect(throws: MediaDownloadError.wrongSize(expected: 6, received: overlong ? 7 : 5)) {
            try await MediaDownloadTransfer().download(.init(source: server.url.absoluteString, destination: file, representation: .init(resource: server.url, entityTag: "\"v1\"")))
        }
        let remaining = try Data(contentsOf: file)
        #expect(remaining.starts(with: Data("abc".utf8)) && remaining.count <= 6)
        if !overlong { #expect(remaining == Data("abcde".utf8)) }
    }
}
