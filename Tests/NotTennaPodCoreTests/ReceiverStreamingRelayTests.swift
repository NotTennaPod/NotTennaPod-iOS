import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct ReceiverStreamingRelayTests {
    @Test func endpointRequiresConcreteAddressAndFormatsIPv6() throws {
        for invalid in ["", "0.0.0.0", "::", "255.255.255.255", "224.0.0.1", "ff02::1", "receiver.invalid", "127.0.0.1/path"] {
            #expect(throws: (any Error).self) { try NativeRelayEndpoint.receiver(address: invalid) }
        }
        let ipv6 = try NativeRelayEndpoint.receiver(address: "::1")
        #expect(try ipv6.url(port: 1234, path: "token/media").absoluteString == "http://[::1]:1234/token/media")
    }

    @Test(arguments: ["127.0.0.1", "::1"]) func receiverPreflightRangesHeadAndErrorsUseCapturedProxy(address: String) async throws {
        let login = FeedCredentials(username: "publisher", password: "fixture")
        let proxy = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == login.authorization(utf8: false))
            #expect(request.headers["cookie"] == nil)
            #expect(request.headers["origin"] == nil)
            #expect(request.headers["user-agent"] == "AntennaPod/receiver-test")
            if request.headers["range"] == "bytes=2-4" {
                return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "Content-Range": "bytes 2-4/10", "Accept-Ranges": "bytes"], body: Data("234".utf8))
            }
            if request.headers["range"] == "bytes=100-" {
                return .init(status: 416, headers: ["Content-Range": "bytes */10"])
            }
            return .init(headers: ["Content-Type": "audio/mpeg", "Accept-Ranges": "bytes"], body: Data("0123456789".utf8))
        }
        defer { proxy.stop() }
        let relay = try await NativeStreamingRelay.start(url: URL(string: "http://publisher.invalid/audio?token=original")!, playlist: false,
            proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!), credentials: login,
            endpoint: .receiver(address: address), userAgent: "AntennaPod/receiver-test")
        defer { relay.cancel() }
        #expect(relay.owns(relay.url))
        #expect(!relay.owns(URL(string: "http://publisher.invalid/audio?token=original")!))
        var request = URLRequest(url: relay.url)
        request.httpMethod = "OPTIONS"
        request.setValue("https://receiver.invalid", forHTTPHeaderField: "Origin")
        request.setValue("GET", forHTTPHeaderField: "Access-Control-Request-Method")
        request.setValue("range", forHTTPHeaderField: "Access-Control-Request-Headers")
        let (empty, preflight) = try await URLSession.shared.data(for: request)
        let options = try #require(preflight as? HTTPURLResponse)
        #expect(options.statusCode == 204 && empty.isEmpty)
        #expect(options.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
        #expect(options.value(forHTTPHeaderField: "Access-Control-Allow-Methods") == "GET, HEAD, OPTIONS")
        #expect(options.value(forHTTPHeaderField: "Access-Control-Allow-Headers")?.contains("Range") == true)
        #expect(proxy.requests.isEmpty)
        request.httpMethod = "GET"
        request.setValue("bytes=2-4", forHTTPHeaderField: "Range")
        request.setValue("Bearer foreign", forHTTPHeaderField: "Authorization")
        request.setValue("foreign=cookie", forHTTPHeaderField: "Cookie")
        let (body, partial) = try await URLSession.shared.data(for: request)
        let response = try #require(partial as? HTTPURLResponse)
        #expect(body == Data("234".utf8) && response.statusCode == 206)
        #expect(response.value(forHTTPHeaderField: "Content-Range") == "bytes 2-4/10")
        #expect(response.value(forHTTPHeaderField: "Access-Control-Expose-Headers")?.contains("Content-Range") == true)
        request.httpMethod = "HEAD"; request.setValue(nil, forHTTPHeaderField: "Range")
        let (headBody, head) = try await URLSession.shared.data(for: request)
        #expect(headBody.isEmpty)
        #expect((head as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") == "10")
        request.httpMethod = "GET"; request.setValue("bytes=100-", forHTTPHeaderField: "Range")
        let (_, invalidRange) = try await URLSession.shared.data(for: request)
        #expect((invalidRange as? HTTPURLResponse)?.statusCode == 416)
        #expect((invalidRange as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
        #expect(proxy.requests.count == 3)
        #expect(proxy.requests.allSatisfy { $0.path == "http://publisher.invalid/audio?token=original" })
        relay.cancel()
        #expect(!relay.owns(relay.url))
        await #expect(throws: (any Error).self) { _ = try await URLSession.shared.data(from: relay.url) }
    }

    @Test func receiverHLSRedirectKeysAndQueryRemainAuthorized() async throws {
        let login = FeedCredentials(username: "publisher", password: "fixture")
        let proxy = try await LoopbackHTTPServer.start { request in
            let url = URL(string: request.path)!
            #expect(request.headers["authorization"] == (url.host == "publisher.invalid" ? login.authorization(utf8: false) : nil))
            if url.host == "publisher.invalid" { return .init(status: 302, headers: ["Location": "http://cdn.invalid/path/index.m3u8?token=original"]) }
            if url.path.hasSuffix(".m3u8") {
                return .init(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:2,\npart.ts\n".utf8))
            }
            return .init(body: Data(url.lastPathComponent.utf8))
        }
        defer { proxy.stop() }
        let failures = Mutex<[String]>([])
        let relay = try await NativeStreamingRelay.start(url: URL(string: "http://publisher.invalid/start")!, playlist: true,
            proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!), credentials: login,
            endpoint: .receiver(address: "127.0.0.1"), onFailure: { error in failures.withLock { $0.append(error.localizedDescription) } })
        defer { relay.cancel() }
        let (index, response) = try await URLSession.shared.data(from: relay.url)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
        let lines = String(decoding: index, as: UTF8.self).components(separatedBy: "\n")
        let keyLine = try #require(lines.first { $0.hasPrefix("#EXT-X-KEY:") })
        let keyText = try #require(keyLine.split(separator: "\"").dropFirst().first)
        let key = try #require(URL(string: String(keyText)))
        let segmentText = try #require(lines.first { $0.hasPrefix("http://") })
        let segment = try #require(URL(string: segmentText))
        for url in [key, segment] {
            #expect(url.host == relay.url.host && url.port == relay.url.port)
            let (_, response) = try await URLSession.shared.data(from: url)
            #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
        }
        let before = proxy.requests.count
        var changed = URLComponents(url: relay.url, resolvingAgainstBaseURL: false)!
        changed.queryItems = [.init(name: "token", value: "forged")]
        await #expect(throws: (any Error).self) { _ = try await URLSession.shared.data(from: changed.url!) }
        var foreign = URLComponents(url: relay.url, resolvingAgainstBaseURL: false)!
        foreign.path = "/foreign/" + relay.url.lastPathComponent
        var preflight = URLRequest(url: foreign.url!); preflight.httpMethod = "OPTIONS"
        await #expect(throws: (any Error).self) { _ = try await URLSession.shared.data(for: preflight) }
        #expect(proxy.requests.count == before)
        changed.queryItems = [.init(name: "_HLS_msn", value: "24"), .init(name: "_HLS_part", value: "2")]
        _ = try await URLSession.shared.data(from: changed.url!)
        #expect(proxy.requests.contains { $0.path == "http://publisher.invalid/start?_HLS_msn=24&_HLS_part=2" })
        #expect(failures.withLock { $0.isEmpty })
    }

    @Test(arguments: [false, true]) func receiverLeaseCancellationRetiresUpstream(beforeHeaders: Bool) async throws {
        let disconnected = Mutex(0)
        let proxy = try await LoopbackHTTPServer.start(onClientDisconnect: { disconnected.withLock { $0 += 1 } }) { _ in
            beforeHeaders ? nil : .init(headers: ["Content-Length": "2000"], body: Data([7]), keepConnectionOpen: true)
        }
        defer { proxy.stop() }
        let relay = try await NativeStreamingRelay.start(url: URL(string: "http://source.invalid/media")!, playlist: false,
            proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!), endpoint: .receiver(address: "127.0.0.1"))
        defer { relay.cancel() }
        let loading = Task { try await URLSession.shared.data(from: relay.url) }
        defer { loading.cancel() }
        let deadline = ContinuousClock.now + .seconds(3)
        while proxy.requests.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(proxy.requests.count == 1)
        relay.cancel()
        await #expect(throws: (any Error).self) { _ = try await loading.value }
        while disconnected.withLock({ $0 == 0 }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(disconnected.withLock { $0 > 0 })
        #expect(!relay.owns(relay.url))
    }

    @Test func loopbackDefaultRetainsLocalResponseContract() async throws {
        let proxy = try await LoopbackHTTPServer.start { _ in .init(body: Data("media".utf8)) }
        defer { proxy.stop() }
        let relay = try await NativeStreamingRelay.start(url: URL(string: "http://source.invalid/media")!, playlist: false,
            proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!))
        defer { relay.cancel() }
        #expect(relay.url.host == "127.0.0.1")
        let (body, response) = try await URLSession.shared.data(from: relay.url)
        #expect(body == Data("media".utf8))
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == nil)
    }
}
