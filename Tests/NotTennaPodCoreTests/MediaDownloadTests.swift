import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.timeLimit(.minutes(1)))
struct MediaDownloadTests {
    private func destination() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("episode.mp3")
    }

    @Test func downloadsBinaryToDiskWithSourceHeadersAndBoundedProgressChunks() async throws {
        let body = Data((0..<100_003).map { UInt8($0 % 251) })
        let server = try await LoopbackHTTPServer.start { _ in .init(headers: ["ETag": "\"v1\""], body: body) }
        defer { server.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let progress = Mutex<[MediaDownloadProgress]>([])
        let result = try await MediaDownloadTransfer(userAgent: "AntennaPod/0.1.0").download(
            .init(source: server.url.absoluteString, destination: file), progress: { value in progress.withLock { $0.append(value) } })
        #expect(try Data(contentsOf: file) == body)
        #expect(result.size == 100_003)
        #expect(result.validator == "\"v1\"")
        #expect(server.requests.count == 1)
        let request = try #require(server.requests.first)
        #expect(request.headers["accept-encoding"] == "identity")
        #expect(request.headers["cache-control"] == "no-cache")
        #expect(request.headers["upgrade-insecure-requests"] == "1")
        #expect(request.headers["user-agent"] == "AntennaPod/0.1.0")
        let values = progress.withLock { $0 }
        #expect(values.first == .init(received: 0, expected: 100_003))
        #expect(values.last == .init(received: 100_003, expected: 100_003))
        #expect(zip(values, values.dropFirst()).allSatisfy { $1.received >= $0.received })
    }

    @Test func resumesFromServerRangeAndRetainsExistingBytes() async throws {
        let server = try await LoopbackHTTPServer.start { _ in
            .init(status: 206, headers: ["Content-Range": "bytes 3-5/6", "Last-Modified": "Fri, 11 Sep 2026 00:00:00 GMT", "ETag": "\"v1\""], body: Data("def".utf8))
        }
        defer { server.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("abc".utf8).write(to: file)
        let result = try await MediaDownloadTransfer().download(.init(source: server.url.absoluteString, destination: file, representation: .init(resource: server.url, entityTag: "\"v1\"", total: 6)))
        #expect(try Data(contentsOf: file) == Data("abcdef".utf8))
        #expect(result.size == 6)
        #expect(result.validator == "\"v1\"")
        #expect(server.requests.first?.headers["range"] == "bytes=3-")
        #expect(server.requests.first?.headers["if-range"] == "\"v1\"")
        #expect(server.requests.first?.headers["if-none-match"] == nil)
    }

    @Test func serverIgnoringRangeReplacesPartialFile() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(body: Data("replacement".utf8)) }
        defer { server.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data(repeating: 88, count: 40).write(to: file)
        let result = try await MediaDownloadTransfer().download(.init(source: server.url.absoluteString, destination: file))
        #expect(try Data(contentsOf: file) == Data("replacement".utf8))
        #expect(result.size == 11)
    }

    @Test func followsRedirectAndRetriesPrivateCredentialsWithoutCachingThem() async throws {
        let server = try await LoopbackHTTPServer.start { request in
            if request.path == "/feed" { return .init(status: 302, headers: ["Location": "/media"], body: Data()) }
            if request.headers["authorization"] == "Basic w6k6wqM=" { return .init(body: Data("audio".utf8)) }
            return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"Test\""], body: Data())
        }
        defer { server.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let transfer = MediaDownloadTransfer()
        _ = try await transfer.download(.init(source: server.url.absoluteString, destination: file,
                                             credentials: .init(username: "é", password: "£")))
        #expect(server.requests.map(\.path) == ["/feed", "/media", "/media", "/media"])
        #expect(server.requests.map { $0.headers["authorization"] } == [nil, nil, "Basic 6Tqj", "Basic w6k6wqM="])
        await #expect(throws: MediaDownloadError.httpStatus(401)) {
            try await transfer.download(.init(source: server.url.absoluteString, destination: file))
        }
        #expect(server.requests.count == 6)
        #expect(try Data(contentsOf: file) == Data("audio".utf8))
    }

    @Test func rejectsSmallTextWithKnownMissingOrChunkedLengthBeforeWriting() async throws {
        let responses: [LoopbackHTTPServer.Response] = [
            .init(headers: ["Content-Type": "text/html"], body: Data("bad".utf8)),
            .init(headers: ["Content-Type": "text/plain"], body: Data("bad".utf8), includeAutomaticContentLength: false),
            .init(headers: ["Content-Type": "text/html", "Transfer-Encoding": "chunked"], body: Data("3\r\nbad\r\n0\r\n\r\n".utf8))
        ]
        for response in responses {
            let server = try await LoopbackHTTPServer.start { _ in response }
            defer { server.stop() }
            let file = try destination()
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            await #expect(throws: MediaDownloadError.fileType) {
                try await MediaDownloadTransfer().download(.init(source: server.url.absoluteString, destination: file))
            }
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func largeContentLengthIsNotMisclassifiedByNarrowIntegerParsing() async throws {
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "text/plain", "Content-Length": "2147483648"],
                  body: Data(repeating: 65, count: 65_536), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let (stream, continuation) = AsyncStream<MediaDownloadProgress>.makeStream()
        let pending = Task {
            defer { continuation.finish() }
            return try await MediaDownloadTransfer(availableCapacity: { _ in .max }).download(
                .init(source: server.url.absoluteString, destination: file), progress: { continuation.yield($0) })
        }
        defer { pending.cancel() }
        var first: MediaDownloadProgress?
        for await value in stream { first = value; break }
        #expect(first == .init(received: 0, expected: 2_147_483_648))
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
    }

    @Test func textGuardUsesCaseSensitivePrefixAndStrict100KiBBoundary() async throws {
        for (type, count) in [("text/plain", 102_400), ("Text/plain", 3), ("audio/mpeg", 3)] {
            let body = Data(repeating: 65, count: count)
            let server = try await LoopbackHTTPServer.start { _ in .init(headers: ["Content-Type": type], body: body) }
            defer { server.stop() }
            let file = try destination()
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let result = try await MediaDownloadTransfer().download(.init(source: server.url.absoluteString, destination: file))
            #expect(result.size == Int64(count))
            #expect(try Data(contentsOf: file) == body)
        }
    }

    @Test func truncationAfterObservedDeliveryRetainsBytesAndReportsWrongSize() async throws {
        let partial = Data(repeating: 65, count: 65_536)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Length": "131072"], body: partial, keepConnectionOpen: true)
        }
        defer { server.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let (stream, continuation) = AsyncStream<MediaDownloadProgress>.makeStream()
        let pending = Task {
            defer { continuation.finish() }
            return try await MediaDownloadTransfer().download(.init(source: server.url.absoluteString, destination: file),
                progress: { continuation.yield($0) })
        }
        defer { pending.cancel() }
        var delivered = false
        for await value in stream {
            if value.received == Int64(partial.count) { delivered = true; break }
        }
        try #require(delivered)
        try await server.appendResponseBody(Data(), isFinal: true)
        await #expect(throws: MediaDownloadError.wrongSize(expected: 131_072, received: 65_536)) { try await pending.value }
        #expect(try Data(contentsOf: file) == partial)
    }

    @Test func malformedWireResponsesFailWithoutInventingDeliveredBytes() async throws {
        // Native URLSession may reject framing before delivering headers or body.
        // The app must fail safely; no domain-specific error or callback order is required.
        for response: LoopbackHTTPServer.Response in [
            .init(headers: ["Content-Length": "100"], body: Data("partial".utf8)),
            .init(headers: ["Transfer-Encoding": "chunked"], body: Data("bad".utf8))
        ] {
            let server = try await LoopbackHTTPServer.start { _ in response }
            defer { server.stop() }
            let file = try destination()
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            await #expect(throws: (any Error).self) {
                try await MediaDownloadTransfer().download(.init(source: server.url.absoluteString, destination: file))
            }
            let received = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : Data()
            // Any bytes delivered before truncation must be an actual response prefix.
            #expect(response.body.starts(with: received))
        }
    }

    @Test func chunkedTransferHasUnknownSizeAndSavesDecodedBytes() async throws {
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Transfer-Encoding": "chunked"], body: Data("3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n".utf8))
        }
        defer { server.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let progress = Mutex<[MediaDownloadProgress]>([])
        let result = try await MediaDownloadTransfer().download(.init(source: server.url.absoluteString, destination: file),
                                                              progress: { value in progress.withLock { $0.append(value) } })
        #expect(result.size == 5)
        #expect(try Data(contentsOf: file) == Data("abcde".utf8))
        #expect(progress.withLock { $0.allSatisfy { $0.expected == nil } })
    }

    @Test func invalidRangeAndHTTPFailuresRetainPartialFileForWorkerDecision() async throws {
        for status in [401, 403, 404, 410, 416, 500, 206] {
            let server = try await LoopbackHTTPServer.start { _ in
                .init(status: status, headers: ["Content-Range": "invalid"], body: Data())
            }
            defer { server.stop() }
            let file = try destination()
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            try Data("partial".utf8).write(to: file)
            await #expect(throws: status == 206 ? MediaDownloadError.invalidRange : .httpStatus(status)) {
                try await MediaDownloadTransfer().download(.init(source: server.url.absoluteString, destination: file))
            }
            #expect(try Data(contentsOf: file) == Data("partial".utf8))
            #expect(server.requests.count == 1)
        }
    }

    @Test func ignoredRangeRecreatesFileBeforeCapacityCheckAsInSource() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(body: Data(repeating: 1, count: 100)) }
        defer { server.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("partial".utf8).write(to: file)
        await #expect(throws: MediaDownloadError.notEnoughSpace(required: 100, available: 99)) {
            try await MediaDownloadTransfer(availableCapacity: { _ in 99 }).download(.init(source: server.url.absoluteString, destination: file))
        }
        #expect(try Data(contentsOf: file).isEmpty)
    }

    @Test func cancellationStopsOutstandingRequestAndDoesNotCreateFile() async throws {
        let server = try await LoopbackHTTPServer.start { _ in nil }
        defer { server.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let task = Task { try await MediaDownloadTransfer().download(.init(source: server.url.absoluteString, destination: file)) }
        defer { task.cancel() }
        for _ in 0..<100 where server.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(server.requests.count == 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func transientImmediateRetryIsBoundedAndRedirectLoopsTerminate() async throws {
        for status in [408, 503, 302] {
            let server = try await LoopbackHTTPServer.start { _ in
                .init(status: status, headers: ["Retry-After": "0", "Location": "/feed"], body: Data())
            }
            defer { server.stop() }
            let file = try destination()
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            await #expect(throws: status == 302 ? MediaDownloadError.tooManyFollowUps : .httpStatus(status)) {
                try await MediaDownloadTransfer().download(.init(source: server.url.absoluteString, destination: file))
            }
            #expect(server.requests.count == (status == 302 ? 21 : 2))
        }
    }

    @Test func cancellingAfterDiskProgressRetainsBytesThatCanResume() async throws {
        let body = Data((0..<2_000_000).map { UInt8($0 % 251) })
        let server = try await LoopbackHTTPServer.start { request in
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                return .init(status: 206, headers: ["ETag": "\"v1\"", "Content-Range": "bytes \(offset)-1999999/2000000"], body: body.subdata(in: offset..<body.count))
            }
            return .init(headers: ["ETag": "\"v1\""], body: body)
        }
        defer { server.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let identity = Mutex<MediaDownloadRepresentation?>(nil)
        let handle = Mutex<(task: Task<MediaDownloadResult, any Error>?, cancelRequested: Bool)>((nil, false))
        let transfer = MediaDownloadTransfer()
        let task = Task {
            try await transfer.download(.init(source: server.url.absoluteString, destination: file, acceptRepresentation: { value in identity.withLock { $0 = value } }), progress: { value in
                if value.received >= 8192 {
                    let task = handle.withLock { state in state.cancelRequested = true; return state.task }
                    task?.cancel()
                }
            })
        }
        let cancelled = handle.withLock { state in state.task = task; return state.cancelRequested }
        if cancelled { task.cancel() }
        defer { task.cancel() }
        await #expect(throws: CancellationError.self) { try await task.value }
        let partial = try Data(contentsOf: file)
        #expect(!partial.isEmpty && partial.count < body.count)
        #expect(partial == body.prefix(partial.count))
        let result = try await transfer.download(.init(source: server.url.absoluteString, destination: file, representation: identity.withLock { $0 }))
        #expect(result.size == 2_000_000)
        #expect(try Data(contentsOf: file) == body)
        #expect(server.requests.count == 2)
        #expect(server.requests.last?.headers["range"] == "bytes=\(partial.count)-")
    }

    @Test func unsolicitedNotModifiedFailsWithoutReplacingPartialFile() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(status: 304, body: Data()) }
        defer { server.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("partial".utf8).write(to: file)
        await #expect(throws: MediaDownloadError.httpStatus(304)) {
            try await MediaDownloadTransfer().download(.init(source: server.url.absoluteString, destination: file))
        }
        #expect(try Data(contentsOf: file) == Data("partial".utf8))
    }

    @Test func authorizationDoesNotLeakAcrossOriginsOnRedirect() async throws {
        let target = try await LoopbackHTTPServer.start { _ in .init(body: Data("audio".utf8)) }
        defer { target.stop() }
        let source = try await LoopbackHTTPServer.start { request in
            if request.headers["authorization"] == nil {
                return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"Source\""], body: Data())
            }
            return .init(status: 302, headers: ["Location": target.url.absoluteString], body: Data())
        }
        defer { source.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        _ = try await MediaDownloadTransfer().download(.init(source: source.url.absoluteString, destination: file,
                                                           credentials: .init(username: "user", password: "pass")))
        #expect(source.requests.map { $0.headers["authorization"] } == [nil, "Basic dXNlcjpwYXNz"])
        #expect(target.requests.count == 1)
        #expect(target.requests.first?.headers["authorization"] == nil)
    }
}
