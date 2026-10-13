import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct NativeRelayBodyTests {
    private func configuration(timeout: TimeInterval = 8) -> URLSessionConfiguration {
        let value = URLSessionConfiguration.ephemeral
        value.urlCache = nil; value.httpCookieStorage = nil; value.urlCredentialStorage = nil
        value.timeoutIntervalForRequest = timeout; value.timeoutIntervalForResource = .greatestFiniteMagnitude
        return value
    }
    private func open(_ url: URL, timeout: TimeInterval = 8) async throws -> NativeRelayBody {
        try await NativeRelayBody.open(request: URLRequest(url: url), configuration: configuration(timeout: timeout),
            delegate: RelaySessionDelegate(proxy: PodcastProxy()))
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(predicate())
    }
    nonisolated private func chunk(_ bytes: Data) -> Data {
        Data("\(String(bytes.count, radix: 16))\r\n".utf8) + bytes + Data("\r\n".utf8)
    }
    private func read(_ body: NativeRelayBody, count: Int) async throws -> Data {
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            Issue.record("Available response bytes were held instead of delivered")
            body.cancel()
        }
        defer { watchdog.cancel() }
        var result = Data()
        while result.count < count { result.append(try #require(try await body.next())) }
        #expect(result.count == count)
        return result
    }

    @Test(arguments: [false, true])
    func smallChunksAreAvailableBeforeLaterBytesAndEOF(knownLength: Bool) async throws {
        let parts = [Data([13]), Data(repeating: 42, count: 63), Data(repeating: 201, count: 4095)]
        let size = parts.reduce(0) { $0 + $1.count }
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: knownLength ? ["Content-Type": "audio/mpeg", "Content-Length": String(size)] : ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"],
                body: knownLength ? parts[0] : chunk(parts[0]), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let body = try await open(server.url)
        defer { body.cancel() }
        #expect(body.response.expectedContentLength == (knownLength ? Int64(size) : -1))
        // Bytes already received are delivered at once, before later bytes or EOF.
        #expect(try await read(body, count: parts[0].count) == parts[0])
        for part in parts.dropFirst() {
            try await server.appendResponseBody(knownLength ? part : chunk(part))
            #expect(try await read(body, count: part.count) == part)
        }
        if !knownLength { try await server.appendResponseBody(Data("0\r\n\r\n".utf8), isFinal: true) }
        #expect(try await body.next() == nil)
    }

    @Test func pausedStreamDoesNotBlockAnotherRequestAndBothDeliverEveryByte() async throws {
        let bytes = Data((0..<(3 * 1024 * 1024)).map { UInt8($0 % 251) })
        let server = try await LoopbackHTTPServer.start { _ in .init(body: bytes) }
        defer { server.stop() }
        let first = try await open(server.url)
        defer { first.cancel() }
        try await wait { first.snapshot.bufferedBytes > 0 }
        // First request remains unread while this request drains completely.
        let second = try await open(server.url)
        defer { second.cancel() }
        var received = Data()
        while let part = try await second.next() { received.append(part) }
        #expect(received == bytes)
        var firstBytes = Data()
        while let part = try await first.next() { firstBytes.append(part) }
        #expect(firstBytes == bytes)
    }

    @Test(arguments: [false, true])
    func repeatedCompleteBodiesPreserveEveryByteAndEOF(knownLength: Bool) async throws {
        let payload = Data((0..<119600).map { UInt8($0 % 251) })
        let server = try await LoopbackHTTPServer.start { _ in
            knownLength ? .init(headers: ["Content-Type": "audio/mpeg"], body: payload)
                : .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"],
                    body: chunk(payload) + Data("0\r\n\r\n".utf8))
        }
        defer { server.stop() }
        let relay = try await NativeStreamingRelay.start(url: server.url, playlist: false, proxy: PodcastProxy())
        defer { relay.cancel() }
        for _ in 0..<24 {
            let body = try await open(relay.url)
            defer { body.cancel() }
            #expect(try await read(body, count: payload.count) == payload)
            #expect(try await body.next() == nil)
            try await wait { relay.snapshot.activeRequests == 0 }
        }
        #expect(server.requests.count == 24)
    }

    @Test(arguments: [false, true])
    func cancellingWhileWaitingForHeadersOrBodyEndsPromptly(beforeHeaders: Bool) async throws {
        let server = try await LoopbackHTTPServer.start { _ in
            beforeHeaders ? nil : .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "2000"], body: Data([7]), keepConnectionOpen: true)
        }
        defer { server.stop() }
        if beforeHeaders {
            let opening = Task { try await open(server.url) }
            try await wait { server.requests.count == 1 }
            opening.cancel()
            await #expect(throws: (any Error).self) { _ = try await opening.value }
        } else {
            let body = try await open(server.url)
            #expect(try await read(body, count: 1) == Data([7]))
            let reading = Task { try await body.next() }
            try await wait { body.snapshot.waitingConsumer }
            reading.cancel()
            await #expect(throws: (any Error).self) { _ = try await reading.value }
        }
    }

    @Test func consumerSuspensionExcludesIdleTimeoutAndResumedIdleStillFails() async throws {
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "2000"], body: Data([7]), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let body = try await open(server.url, timeout: 1)
        defer { body.cancel() }
        #expect(try await read(body, count: 1) == Data([7]))
        #expect(body.snapshot.consumerPaused)
        // This elapsed wait tests the owned read deadline while the consumer is
        // paused; it is not synchronization for an arbitrary callback.
        try await Task.sleep(for: .milliseconds(1300))
        #expect(!body.snapshot.completed && body.snapshot.consumerPaused)
        let resumed = ContinuousClock.now
        do {
            _ = try await body.next()
            Issue.record("An idle resumed request must fail, not report EOF")
        } catch { #expect((error as? URLError)?.code == .timedOut) }
        #expect(resumed.duration(to: .now) >= .milliseconds(800))
    }

    @Test func truncatedKnownBodyDeliversAvailableBytesThenOriginalFailure() async throws {
        let bytes = Data([1, 2, 3, 4, 5])
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "2000"], body: bytes, keepConnectionOpen: true)
        }
        defer { server.stop() }
        let body = try await open(server.url)
        defer { body.cancel() }
        // The bytes arrive first and the connection closes afterwards, as in a real truncated download. When the
        // close travels in the same segment as the last few bytes, URLSession itself may drop them before any
        // delegate call, which is not the relay's behaviour under test.
        var received = Data()
        while received.count < bytes.count, let part = try await body.next() { received.append(part) }
        #expect(received == bytes)
        try await server.appendResponseBody(Data(), isFinal: true)
        do {
            while let part = try await body.next() { received.append(part) }
            Issue.record("Truncated declared body must not become successful EOF")
        } catch { #expect((error as? URLError)?.code == .networkConnectionLost, "\(error)") }
        #expect(received == bytes && body.snapshot.completed)
    }

    @Test(arguments: [false, true], [false, true])
    func relayForwardsOneByteAndPartialBlocksWithCapturedCredentials(proxyEnabled: Bool, knownLength: Bool) async throws {
        let parts = [Data([3]), Data(repeating: 43, count: 37), Data(repeating: 203, count: 4095)]
        let payload = parts.reduce(Data(), +)
        let credentials = FeedCredentials(username: "source", password: "captured")
        let proxyAuth = "Basic " + Data("proxy:captured".utf8).base64EncodedString()
        let server = try await LoopbackHTTPServer.start { request in
            if proxyEnabled, request.headers["proxy-authorization"] != proxyAuth {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"chunks\""])
            }
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            return .init(headers: knownLength ? ["Content-Type": "audio/mpeg", "Content-Length": String(payload.count)] : ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"],
                body: knownLength ? parts[0] : chunk(parts[0]), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!,
            username: "proxy", password: "captured") : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://chunk-relay.invalid/audio")! : server.url
        let failures = Mutex(0)
        let relay = try await NativeStreamingRelay.start(url: url, playlist: false, proxy: proxy, credentials: credentials,
            onFailure: { _ in failures.withLock { $0 += 1 } })
        defer { relay.cancel() }
        let body = try await open(relay.url)
        defer { body.cancel() }
        #expect(try await read(body, count: 1) == parts[0])
        let connection = try #require(server.requests.lastIndex { !proxyEnabled || $0.headers["proxy-authorization"] == proxyAuth })
        for part in parts.dropFirst() {
            try await server.appendResponseBody(knownLength ? part : chunk(part), toConnectionAt: connection)
            #expect(try await read(body, count: part.count) == part)
        }
        if !knownLength { try await server.appendResponseBody(Data("0\r\n\r\n".utf8), toConnectionAt: connection, isFinal: true) }
        #expect(try await body.next() == nil)
        try await wait { relay.snapshot.activeRequests == 0 }
        #expect(failures.withLock { $0 == 0 })
    }
}
