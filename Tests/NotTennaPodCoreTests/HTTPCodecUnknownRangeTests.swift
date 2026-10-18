import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized)
struct HTTPCodecUnknownRangeTests {
    private enum Failure: Error { case deadline }
    private func chunk(_ data: Data, end: Bool = false) -> Data {
        Data("\(String(data.count, radix: 16))\r\n".utf8) + data + Data("\r\n\(end ? "0\r\n\r\n" : "")".utf8)
    }
    private func read(_ input: any MediaByteInput, at offset: Int64, count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result {
                    var data = Data()
                    while data.count < count {
                        let part = try input.read(at: offset + Int64(data.count), maximumCount: count - data.count)
                        if part.isEmpty { break }
                        data.append(part)
                    }
                    return data
                })
            }
        }
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func timeline(_ input: any MediaByteInput) async throws -> MatroskaTimeline {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result {
                    try MatroskaTimeline.read(bytes: { try input.read(at: $0, maximumCount: $1) },
                        checkCancellation: { try input.checkFailure() })
                })
            }
        }
    }

    @Test(arguments: [false, true], [16, 4096])
    func WebMCuesLoadBeforeInitialEOFWithOrWithoutReportedTotal(reportedTotal: Bool, responseLimit: Int) async throws {
        let data = try Data(contentsOf: #require(Bundle.module.url(forResource: "tone-opus.webm", withExtension: nil,
            subdirectory: "Fixtures/StreamingFormats")))
        let prefix = chunk(Data(data.prefix(data.count * 3 / 4)))
        let server = try await LoopbackHTTPServer.start { request in
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                let end = min(data.count, offset + responseLimit)
                return .init(status: 206, headers: ["Content-Range": "bytes \(offset)-\(end - 1)/\(reportedTotal ? String(data.count) : "*")"],
                    body: Data(data[offset..<end]))
            }
            return .init(headers: ["Transfer-Encoding": "chunked"], body: prefix, keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            Issue.record("Declared WebM cue read stalled on unknown initial HTTP length")
            input.cancel()
        }
        defer { watchdog.cancel() }
        input.prepareForSeek()
        let value = try await timeline(input)
        // The stream is seekable and shows its duration before the download finishes.
        #expect(value.isSeekable && abs((value.durationMicroseconds ?? 0) - 8_008_000) <= 50_000)
        #expect(input.initialDeclaredLength == nil && !input.snapshot().completed)
        #expect(input.declaredLength == (reportedTotal ? Int64(data.count) : nil))
        #expect(input.length == (reportedTotal ? Int64(data.count) : nil))
    }

    @Test func cancellingHeldCueLeasePreservesOriginalInputAndCache() async throws {
        let data = try Data(contentsOf: #require(Bundle.module.url(forResource: "tone-opus.webm", withExtension: nil,
            subdirectory: "Fixtures/StreamingFormats")))
        let prefix = chunk(Data(data.prefix(data.count * 3 / 4)))
        let server = try await LoopbackHTTPServer.start { request in
            if request.headers["range"] != nil { return nil }
            return .init(headers: ["Transfer-Encoding": "chunked"], body: prefix, keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let lease = input.makeReadLease()
        lease.prepareForSeek()
        let opening = Task { try await timeline(lease) }
        defer { lease.cancel(); opening.cancel() }
        try await wait { server.requests.contains { $0.headers["range"] == "bytes=86250-" } && input.snapshot().waitingReaders > 0 }
        lease.cancel()
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(!input.snapshot().cancelled && input.sourceFailure?.error == nil && input.snapshot().waitingReaders == 0)
        #expect(try await read(input, at: 0, count: 1024) == data.prefix(1024))
        input.cancel()
        #expect(input.snapshot().activeTransfers == 0 && !FileManager.default.fileExists(atPath: input.cacheURL.path))
    }

    @Test(arguments: ["offset", "total", "length", "identity", "overlap"])
    func invalidUnknownLengthRangeFailsBeforeItCanSupplyRequestedBytes(mode: String) async throws {
        let data = Data(repeating: 42, count: 16384)
        let prefix = chunk(Data(data.prefix(1024)))
        let server = try await LoopbackHTTPServer.start { request in
            if request.headers["range"] != nil {
                if mode == "overlap" { return .init(headers: ["ETag": "\"stable\""], body: Data(repeating: 43, count: data.count)) }
                var headers = ["ETag": mode == "identity" ? "\"changed\"" : "\"stable\"",
                    "Content-Range": "bytes \(mode == "offset" ? 12289 : 12288)-16383/\(mode == "total" ? "100" : "*")"]
                if mode == "length" { headers["Content-Length"] = "4095" }
                return .init(status: 206, headers: headers, body: data.suffix(4096))
            }
            return .init(headers: ["Transfer-Encoding": "chunked", "ETag": "\"stable\""], body: prefix, keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            Issue.record("Invalid unknown-length range did not fail")
            input.cancel()
        }
        defer { watchdog.cancel() }
        #expect(try await read(input, at: 0, count: 1024) == data.prefix(1024))
        input.prepareForSeek()
        do { _ = try await read(input, at: 12288, count: 1); Issue.record("Invalid range supplied a byte") }
        catch {
            if mode == "identity" || mode == "overlap" { #expect((error as? URLError)?.code == .resourceUnavailable) }
            else { #expect((error as? MediaDownloadError) == .invalidRange) }
        }
        #expect(input.sourceFailure?.error != nil && input.snapshot().activeTransfers == 0 && server.requests.count == 2)
        #expect(!FileManager.default.fileExists(atPath: input.cacheURL.path))
    }

    @Test(arguments: ["partial-known", "partial-unknown", "full-known", "full-unknown"], [false, true])
    func unknownInitialLengthAllowsValidatedRangeAndPreservesCoverage(style: String, validator: Bool) async throws {
        let data = Data((0..<16384).map { UInt8(truncatingIfNeeded: $0 * 17) })
        let prefix = chunk(Data(data.prefix(1024)))
        let server = try await LoopbackHTTPServer.start { request in
            var headers = validator ? ["ETag": "\"stable\""] : [:]
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                if style.hasPrefix("partial") {
                    headers["Content-Range"] = "bytes \(offset)-\(data.count - 1)/\(style == "partial-known" ? String(data.count) : "*")"
                    return .init(status: 206, headers: headers, body: Data(data.suffix(from: offset)))
                }
                if style == "full-unknown" {
                    headers["Transfer-Encoding"] = "chunked"
                    let body = Data("\(String(data.count, radix: 16))\r\n".utf8) + data + Data("\r\n0\r\n\r\n".utf8)
                    return .init(headers: headers, body: body)
                }
                return .init(headers: headers, body: data)
            }
            headers["Transfer-Encoding"] = "chunked"
            return .init(headers: headers, body: prefix, keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            Issue.record("Unknown-length range did not complete")
            input.cancel()
        }
        defer { watchdog.cancel() }
        #expect(try await read(input, at: 0, count: 1024) == data.prefix(1024))
        #expect(input.length == nil && input.declaredLength == nil)
        input.prepareForSeek()
        #expect(input.supportsRandomAccess)
        #expect(try await read(input, at: 12288, count: 4096) == data.suffix(4096))
        let range = try #require(server.requests.first { $0.headers["range"] != nil })
        // A changed file on the server must not be spliced into the cached start.
        #expect(range.headers["if-range"] == (validator ? "\"stable\"" : nil))
        if style.hasPrefix("partial") {
            try await wait { input.snapshot().activeTransfers == 1 }
            #expect(!input.snapshot().completed)
            #expect(input.length == (style == "partial-known" ? 16384 : nil))
            try await server.appendResponseBody(chunk(Data(data.suffix(from: 1024)), end: true), toConnectionAt: 0)
        }
        try await wait { input.snapshot().completed }
        #expect(input.length == 16384 && input.initialDeclaredLength == nil && input.snapshot().activeTransfers == 0)
        // Later response headers resolve cache eligibility; EOF alone does not.
        #expect(input.declaredLength == (style.hasSuffix("-known") ? 16384 : nil))
        #expect(try await read(input, at: 0, count: 16384) == data)
        #expect(try await read(input, at: 16384, count: 1).isEmpty)
    }
}
