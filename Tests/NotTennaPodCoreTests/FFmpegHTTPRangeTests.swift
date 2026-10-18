import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized)
struct FFmpegHTTPRangeTests {
    private static let names = ["tone-vorbis.ogg", "tone-opus.ogg", "tone-opus.webm"]
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
    }

    struct Configuration: Sendable, CustomStringConvertible {
        let validator: String
        let response: String
        var description: String { "\(validator)/\(response)" }
    }
    private static let configurations = ["strong", "absent", "weak"].flatMap { validator in
        ["partial", "ignored", "ignored-chunked"].map { Configuration(validator: validator, response: $0) }
    }

    @Test(arguments: names, configurations)
    func seekPastAvailablePrefixUsesHTTPRangesAndPlaysTheRequestedAudio(name: String, configuration: Configuration) async throws {
        let url = try fixture(name), data = try Data(contentsOf: url)
        let prefix = Data(data.prefix(data.count * 3 / 4))
        var identity: [String: String] = [:]
        if configuration.validator == "strong" { identity["ETag"] = "\"v1\"" }
        if configuration.validator == "weak" { identity["ETag"] = "W/\"v1\"" }
        let responseIdentity = identity
        let server = try await LoopbackHTTPServer.start { request in
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                var headers = responseIdentity
                if configuration.response == "partial" {
                    headers["Content-Range"] = "bytes \(offset)-\(data.count - 1)/\(data.count)"
                    return .init(status: 206, headers: headers, body: data.dropFirst(offset))
                }
                if configuration.response == "ignored-chunked" {
                    headers["Transfer-Encoding"] = "chunked"
                    return .init(headers: headers,
                        body: Data("\(String(data.count, radix: 16))\r\n".utf8) + data + Data("\r\n0\r\n\r\n".utf8))
                }
                return .init(headers: headers, body: data)
            }
            var headers = responseIdentity
            headers["Content-Length"] = String(data.count)
            return .init(headers: headers, body: prefix, keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let watchdog = Task { try await Task.sleep(for: .seconds(8)); input.cancel() }
        defer { watchdog.cancel() }
        let remote = try await FFmpegAudioReader.open(input: input, maximumFrames: 127, timing: .media3)
        #expect(try await remote.next() != nil)
        #expect(!input.snapshot().completed)
        #expect(server.requests.count == 1 && server.requests[0].headers["range"] == nil)
        let target = CMTime(value: 7, timescale: 1)
        let local = try FFmpegAudioReader(url: url, maximumFrames: 127, timing: .media3)
        try await local.seek(to: target)
        do {
            try await remote.seek(to: target)
            var expected = AudibleAudio(), actual = AudibleAudio()
            for _ in 0..<5 {
                actual.add(try #require(try await remote.next())); expected.add(try #require(try await local.next()))
            }
            FFmpegBufferedSeekReferenceTests.expectSameAudible(actual, expected, "\(name) \(configuration) seek to 7 s")
            #expect(abs((actual.starts.first ?? 0) - 7_000_000) <= 250_000 && actual.peak > 1000)
            #expect(server.requests.contains { $0.headers["range"] != nil })
            #expect(server.requests.filter { $0.headers["range"] != nil }.allSatisfy {
                $0.headers["if-range"] == (configuration.validator == "strong" ? "\"v1\"" : nil)
            })
        } catch {
            print("Incomplete seek \(name): \(input.snapshot()), ranges=\(server.requests.compactMap { $0.headers["range"] })")
            await local.cancel(); await remote.cancel(); throw error
        }
        await local.cancel(); await remote.cancel()
        #expect(!FileManager.default.fileExists(atPath: input.cacheURL.path))
        #expect(input.snapshot().activeTransfers == 0 && input.snapshot().waitingReaders == 0)
    }

    @Test(arguments: ["offset", "total", "length", "etag", "missing-full-etag", "overlap", "forbidden"])
    func invalidRangeResponsesPreserveCauseAndRetireAllWork(mode: String) async throws {
        let data = try Data(contentsOf: fixture("tone-opus.webm"))
        let server = try await LoopbackHTTPServer.start { request in
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                var headers = ["ETag": "\"v1\""]
                if mode == "forbidden" { return .init(status: 403, body: Data()) }
                if mode == "missing-full-etag" { return .init(body: data) }
                if mode == "length" {
                    headers["Content-Length"] = String(data.count - 1)
                    return .init(headers: headers, body: data.dropLast())
                }
                if mode == "overlap" {
                    var changed = data; changed[0] ^= 1
                    return .init(headers: headers, body: changed)
                }
                if mode == "etag" { headers["ETag"] = "\"v2\"" }
                headers["Content-Range"] = "bytes \(offset + (mode == "offset" ? 1 : 0))-\(data.count - 1)/\(data.count + (mode == "total" ? 1 : 0))"
                return .init(status: 206, headers: headers, body: data.dropFirst(offset))
            }
            return .init(headers: ["Content-Length": String(data.count), "ETag": "\"v1\""],
                body: data.prefix(data.count * 3 / 4), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let watchdog = Task { try await Task.sleep(for: .seconds(8)); input.cancel() }
        defer { watchdog.cancel() }
        let reader = try await FFmpegAudioReader.open(input: input, timing: .media3)
        do { try await reader.seek(to: CMTime(value: 7, timescale: 1)); Issue.record("Invalid range was accepted") }
        catch {
            switch mode {
            case "offset", "total": #expect((error as? MediaDownloadError) == .invalidRange)
            case "forbidden": #expect((error as? MediaDownloadError) == .httpStatus(403))
            default: #expect((error as? URLError)?.code == .resourceUnavailable)
            }
        }
        let state = input.snapshot()
        #expect(state.cancelled && state.failure != nil && state.activeTransfers == 0 && state.waitingReaders == 0)
        #expect(state.cleanupFailure == nil && !FileManager.default.fileExists(atPath: input.cacheURL.path))
        #expect(await reader.status == .failed)
        await reader.cancel()
    }

    @Test(arguments: [false, true])
    func cancellingAnOutstandingRangeWakesDecoderAndFencesLateNetworkFailure(cancelTask: Bool) async throws {
        let data = try Data(contentsOf: fixture("tone-opus.webm"))
        let server = try await LoopbackHTTPServer.start { request in
            if request.headers["range"] != nil { return nil }
            return .init(headers: ["Content-Length": String(data.count)],
                body: data.prefix(data.count * 3 / 4), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let reader = try await FFmpegAudioReader.open(input: input, timing: .media3)
        let seek = Task { try await reader.seek(to: CMTime(value: 7, timescale: 1)) }
        let watchdog = Task { try await Task.sleep(for: .seconds(8)); input.cancel() }
        defer { watchdog.cancel() }
        while !server.requests.contains(where: { $0.headers["range"] != nil }) && !input.snapshot().cancelled {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!input.snapshot().cancelled && input.snapshot().activeTransfers > 0)
        if cancelTask { seek.cancel() } else { await reader.cancel() }
        await #expect(throws: CancellationError.self) { try await seek.value }
        let state = input.snapshot()
        server.stop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(state.cancelled && state.waitingReaders == 0 && state.activeTransfers == 0)
        #expect(input.snapshot().received == state.received && input.snapshot().failure == nil)
        #expect(!FileManager.default.fileExists(atPath: input.cacheURL.path))
        #expect(await reader.status == .cancelled)
    }


    @Test func sparseRangeReadsNeverExposeUnwrittenHolesOrRequireAFullBody() async throws {
        let data = Data((0..<200_000).map { UInt8($0 % 251) })
        let prefix = Data(data.prefix(32_768))
        let server = try await LoopbackHTTPServer.start { request in
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                let end = min(offset + 8192, data.count)
                return .init(status: 206, headers: ["Content-Range": "bytes \(offset)-\(end - 1)/\(data.count)"],
                    body: data[offset..<end])
            }
            return .init(headers: ["Content-Length": String(data.count)], body: prefix, keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        defer { input.cancel() }
        let watchdog = Task { try await Task.sleep(for: .seconds(8)); input.cancel() }
        defer { watchdog.cancel() }
        func read(_ offset: Int64) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue(label: "AntennaPodTests.CodecByteRead").async {
                    do { continuation.resume(returning: try input.read(at: offset, maximumCount: 1024)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }
        #expect(try await read(0) == data.prefix(1024))
        input.prepareForSeek()
        #expect(try await read(150_003) == data[150_003..<151_027])
        #expect(try await read(90_007) == data[90_007..<91_031])
        while input.snapshot().received < 32_768 + 2 * 8192 && !input.snapshot().cancelled {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Seeking ahead reads the right bytes without downloading the whole file first.
        let state = input.snapshot()
        #expect(!state.cancelled && !state.completed && state.length == Int64(data.count))
        #expect(try await read(0) == data.prefix(1024))
        #expect(try await read(200_000).isEmpty)
        input.cancel()
        #expect(input.snapshot().activeTransfers == 0 && !FileManager.default.fileExists(atPath: input.cacheURL.path))
    }

}
