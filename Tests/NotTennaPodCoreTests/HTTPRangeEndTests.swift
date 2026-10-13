import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(2))) struct HTTPRangeEndTests {
    private func read(_ input: any MediaByteInput, at offset: Int64, count: Int) async throws -> Data {
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            let state = (input as? HTTPCodecByteInput).map { String(describing: $0.snapshot()) } ?? "read lease"
            FileHandle.standardError.write(Data("Range EOF read deadline: offset=\(offset) count=\(count) \(state)\n".utf8))
            Issue.record("Range EOF fixture read did not finish")
            input.cancel()
        }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(with: Result {
                        var result = Data()
                        while result.count < count {
                            let bytes = try input.read(at: offset + Int64(result.count), maximumCount: count - result.count)
                            if bytes.isEmpty { break }
                            result += bytes
                        }
                        return result
                    })
                }
            }
        } onCancel: { input.cancel() }
    }
    @Test(arguments: [false, true], [false, true])
    func exactEOFPreservesCachedPrefixAndInitialUnknownDeclaration(memory: Bool, proxyEnabled: Bool) async throws {
        let credentials = FeedCredentials(username: "range", password: "eof")
        let prefix = Data("0123456789".utf8)
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == (proxyEnabled ? credentials.authorization(utf8: false) : nil))
            if let range = request.headers["range"] {
                #expect(range == "bytes=100-" && request.headers["if-range"] == "\"stable\"")
                return .init(status: 416, headers: ["Content-Range": "bytes */100"], body: Data("error body is not audio".utf8))
            }
            return .init(headers: ["Content-Type": "application/octet-stream", "ETag": "\"stable\""], body: prefix,
                keepConnectionOpen: true, includeAutomaticContentLength: false)
        }
        defer { server.stop() }
        let relay = proxyEnabled ? try await NativeStreamingRelay.start(url: URL(string: "http://range.invalid/audio")!, playlist: false,
            proxy: PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!), credentials: credentials) : nil
        defer { relay?.cancel() }
        let input = try HTTPCodecByteInput(url: relay?.url ?? server.url, sequentialReadAheadBytes: memory ? 65536 : nil,
            backing: memory ? .memory(capacity: 131072, knownLength: nil) : .disk)
        defer { input.cancel() }
        #expect(try await read(input, at: 0, count: 10) == prefix)
        input.prepareForIndexedSeek(to: 100)
        // Seeking to the exact end is a clean end of stream, not an error, and earlier bytes stay readable.
        #expect(try await read(input, at: 100, count: 16).isEmpty)
        #expect(input.length == 100)
        try input.checkFailure()
        #expect(try await read(input, at: 0, count: 10) == prefix)
        #expect(try await read(input, at: 100, count: 1).isEmpty)
    }

    @Test(arguments: ["before", "beyond", "missing", "malformed", "changed-identity", "changed-length"], [false, true])
    func other416ResponsesCannotBecomeSuccessfulEOF(mode: String, memory: Bool) async throws {
        let server = try await LoopbackHTTPServer.start { request in
            if request.headers["range"] != nil {
                var headers: [String: String] = [:]
                if mode != "missing" {
                    headers["Content-Range"] = mode == "before" ? "bytes */101" : mode == "beyond" ? "bytes */99"
                        : mode == "malformed" ? "bytes */*" : "bytes */100"
                }
                if mode == "changed-identity" { headers["ETag"] = "\"new\"" }
                return .init(status: 416, headers: headers, body: Data("diagnostic".utf8))
            }
            var headers = ["Content-Type": "application/octet-stream", "ETag": "\"stable\""]
            if mode == "changed-length" { headers["Content-Length"] = "1000" }
            return .init(headers: headers, body: Data(repeating: 1, count: 10), keepConnectionOpen: true, includeAutomaticContentLength: false)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url, sequentialReadAheadBytes: memory ? 65536 : nil, backing: memory ? .memory(capacity: 131072, knownLength: nil) : .disk)
        defer { input.cancel() }
        #expect(try await read(input, at: 0, count: 10).count == 10)
        input.prepareForIndexedSeek(to: 100)
        if mode == "changed-identity" || mode == "changed-length" {
            await #expect(throws: URLError(.resourceUnavailable)) { try await read(input, at: 100, count: 1) }
            #expect(input.snapshot().representationRejected)
        } else {
            await #expect(throws: MediaDownloadError.httpStatus(416)) { try await read(input, at: 100, count: 1) }
        }
    }

    @Test(arguments: [Int64(0), 128], [false, true])
    func firstResponseCanDeclareExactEOF(offset: Int64, memory: Bool) async throws {
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["range"] == (offset == 0 ? nil : "bytes=\(offset)-"))
            return .init(status: 416, headers: ["Content-Range": "bytes */\(offset)"], body: Data("not media".utf8))
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url, sequentialReadAheadBytes: memory ? 65536 : nil, backing: memory ? .memory(capacity: 131072, knownLength: nil) : .disk)
        defer { input.cancel() }
        input.prepareForIndexedSeek(to: offset)
        #expect(try await read(input, at: offset, count: 1).isEmpty)
        #expect(input.length == offset)
        try input.checkFailure()
    }
}
