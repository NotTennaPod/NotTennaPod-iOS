import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite
struct MediaDownloadIdentityTests {
    private func destination() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadIdentity-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("episode")
    }

    @Test func unvalidatedPrefixCannotBeCombinedWithANewServerFile() async throws {
        let server = try await LoopbackHTTPServer.start { request in
            if request.headers["range"] != nil {
                return .init(status: 206, headers: ["Content-Range": "bytes 3-5/6", "ETag": "\"v2\""], body: Data("XYZ".utf8))
            }
            return .init(headers: ["ETag": "\"v2\""], body: Data("UVWXYZ".utf8))
        }
        defer { server.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("abc".utf8).write(to: file)
        _ = try await MediaDownloadTransfer().download(.init(source: server.url.absoluteString, destination: file))
        #expect(try Data(contentsOf: file) == Data("UVWXYZ".utf8))
        #expect(server.requests.map { $0.headers["range"] } == [nil])
        #expect(server.requests.allSatisfy { $0.headers["if-none-match"] == nil && $0.headers["if-range"] == nil })
    }

    @Test(arguments: ["\"v2\"", "W/\"v1\"", "missing"])
    func incompatiblePartialIdentityFallsBackWithoutAppending(tag: String) async throws {
        let observedPrefixes = Mutex<[Data]>([])
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("abc".utf8).write(to: file)
        let server = try await LoopbackHTTPServer.start { request in
            if request.headers["range"] != nil {
                var headers = ["Content-Range": "bytes 3-5/6"]
                if tag != "missing" { headers["ETag"] = tag }
                return .init(status: 206, headers: headers, body: Data("BAD".utf8))
            }
            if let bytes = try? Data(contentsOf: file) { observedPrefixes.withLock { $0.append(bytes) } }
            return .init(headers: ["ETag": "\"v2\""], body: Data("UVWXYZ".utf8))
        }
        defer { server.stop() }
        let result = try await MediaDownloadTransfer().download(.init(source: server.url.absoluteString, destination: file,
            representation: .init(resource: server.url, entityTag: "\"v1\"", total: 6)))
        #expect(try Data(contentsOf: file) == Data("UVWXYZ".utf8))
        #expect(result.representation == .init(resource: server.url, entityTag: "\"v2\"", total: 6))
        #expect(observedPrefixes.withLock { $0 } == [Data("abc".utf8)])
        #expect(server.requests.map { $0.headers["range"] } == ["bytes=3-", nil])
        #expect(server.requests.map { $0.headers["if-range"] } == ["\"v1\"", nil])
        #expect(server.requests.allSatisfy { $0.headers["if-none-match"] == nil && $0.headers["if-modified-since"] == nil })
    }

    @Test(arguments: ["W/\"v1\"", "unquoted", "\"a\"b\"", "\"line\nbreak\"", "Fri, 11 Sep 2026 00:00:00 GMT"])
    func weakOrInvalidSavedValidatorNeverAuthorizesCombiningBytes(tag: String) async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(body: Data("new".utf8)) }
        defer { server.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("old".utf8).write(to: file)
        _ = try await MediaDownloadTransfer().download(.init(source: server.url.absoluteString, destination: file,
            representation: .init(resource: server.url, entityTag: tag)))
        #expect(server.requests.first?.headers["range"] == nil)
        #expect(server.requests.first?.headers["if-range"] == nil)
        #expect(try Data(contentsOf: file) == Data("new".utf8))
    }

    @Test(arguments: [false, true])
    func redirectIdentityBelongsToTheActualResource(sameResource: Bool) async throws {
        let server = try await LoopbackHTTPServer.start { request in
            if request.path == "/feed" {
                return .init(status: 302, headers: ["Location": sameResource ? "/old" : "/new"], body: Data())
            }
            if request.headers["range"] != nil {
                return .init(status: 206, headers: ["Content-Range": "bytes 3-5/6", "ETag": "\"same-tag\""], body: Data("def".utf8))
            }
            return .init(headers: ["ETag": "\"same-tag\""], body: Data("UVWXYZ".utf8))
        }
        defer { server.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("abc".utf8).write(to: file)
        let resource = server.url.deletingLastPathComponent().appendingPathComponent("old")
        _ = try await MediaDownloadTransfer().download(.init(source: server.url.absoluteString, destination: file,
            representation: .init(resource: resource, entityTag: "\"same-tag\"", total: 6)))
        #expect(try Data(contentsOf: file) == Data((sameResource ? "abcdef" : "UVWXYZ").utf8))
        #expect(server.requests.map { $0.headers["range"] } == [nil, sameResource ? "bytes=3-" : nil])
        #expect(server.requests.first?.headers["if-range"] == nil)
    }

    @Test func failedAcceptanceCannotLabelOrReceiveReplacementBytes() async throws {
        struct PersistenceFailure: Error {}
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["ETag": "\"v2\""], body: Data("UVWXYZ".utf8))
        }
        defer { server.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("abc".utf8).write(to: file)
        let progress = Mutex<[MediaDownloadProgress]>([])
        await #expect(throws: PersistenceFailure.self) {
            try await MediaDownloadTransfer().download(.init(source: server.url.absoluteString, destination: file,
                representation: .init(resource: server.url, entityTag: "\"v1\"", total: 6),
                acceptRepresentation: { identity in
                    #expect(identity == .init(resource: server.url, entityTag: "\"v2\"", total: 6))
                    #expect(try Data(contentsOf: file).isEmpty)
                    throw PersistenceFailure()
                }), progress: { value in progress.withLock { $0.append(value) } })
        }
        #expect(try Data(contentsOf: file).isEmpty)
        #expect(progress.withLock { $0.isEmpty })
    }

    private actor AcceptanceGate {
        private var continuation: CheckedContinuation<Void, Never>?
        var entered: Bool { continuation != nil }
        func hold() async { await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }

    @Test func cancellationWaitsForAcceptanceAndCannotDeliverLateBytes() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(headers: ["ETag": "\"v1\""], body: Data("audio".utf8)) }
        defer { server.stop() }
        let file = try destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let gate = AcceptanceGate()
        let returned = Mutex(false)
        let progress = Mutex<[MediaDownloadProgress]>([])
        let task = Task {
            defer { returned.withLock { $0 = true } }
            return try await MediaDownloadTransfer().download(.init(source: server.url.absoluteString, destination: file,
                acceptRepresentation: { _ in await gate.hold() }), progress: { value in progress.withLock { $0.append(value) } })
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await gate.entered) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let entered = await gate.entered
        try #require(entered)
        task.cancel()
        #expect(!returned.withLock { $0 })
        #expect(try Data(contentsOf: file).isEmpty)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: file).isEmpty)
        #expect(progress.withLock { $0.isEmpty })
    }

}
