import Foundation
import Testing
@testable import NotTennaPodCore

@Suite struct ProxyRecipientTests {
    @Test func proxySynchronizationRetainsLoginCookieAndIsolatesAnotherAccountSession() async throws {
        let proxyAuth = "Basic " + Data("proxy:secret".utf8).base64EncodedString()
        let proxy = try await LoopbackHTTPServer.start { request in
            guard request.headers["proxy-authorization"] == proxyAuth else {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"proxy\""])
            }
            if request.path.contains("login.json") {
                return .init(headers: ["Set-Cookie": "sessionid=owned-account; Path=/; HttpOnly"])
            }
            if request.path.contains("/other") {
                #expect(request.headers["cookie"] == nil)
                return .init()
            }
            guard request.headers["cookie"]?.contains("sessionid=owned-account") == true else { return .init(status: 401) }
            return .init(body: Data(#"{"add":[],"remove":[],"timestamp":7}"#.utf8))
        }
        defer { proxy.stop() }
        let configuration = PodcastProxy(kind: .http, host: "127.0.0.1", port: proxy.url.port!, username: "proxy", password: "secret")
        let transport = try ProxySynchronizationTransport(proxy: configuration)
        let client = try SynchronizationHTTPClient(backend: .gpodder, host: "http://sync-origin.invalid", username: "account", password: "account-password", device: "fixture", transport: transport)
        try await client.login()
        let changes = try await client.subscriptionChanges(since: 0)
        #expect(changes.timestamp == 7)
        let other = try ProxySynchronizationTransport(proxy: configuration)
        let response = try await other.send(URLRequest(url: URL(string: "http://sync-origin.invalid/other")!))
        #expect(response.status == 200)
        let login = try #require(proxy.requests.first { $0.path.contains("login.json") && $0.headers["proxy-authorization"] != nil })
        #expect(login.method == "POST" && login.headers["authorization"] == "Basic " + Data("account:account-password".utf8).base64EncodedString())
        #expect(proxy.requests.filter { $0.path.contains("subscriptions") }.allSatisfy { $0.headers["authorization"] == nil })
    }
    @MainActor @Test func artworkProxyKeepsItsOwnClientAndRestrictedImagesNeverOpenNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyImage-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = try MobileNetworkPreferenceStore(file: root.appendingPathComponent("mobile.json"))
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=")!
        let first = try await LoopbackHTTPServer.start { _ in .init(headers: ["Content-Type": "image/png"], body: image) }
        let second = try await LoopbackHTTPServer.start { _ in .init(headers: ["Content-Type": "image/png"], body: image) }
        defer { first.stop(); second.stop() }
        let environment = ProxyNetworkEnvironment(configuration: .init(kind: .http, host: "127.0.0.1", port: first.url.port!))
        let network = DownloadNetworkMonitor(startMonitoring: false)
        network.update(.init(connected: true, metered: true, cellular: true))
        let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 0)
        let access = MobileImageAccess(preferences: preferences, network: network,
            proxyConfiguration: { environment.newClientConfiguration() }, cache: cache)
        try preferences.setAllowed(.images, false)
        let url = URL(string: "http://cover-origin.invalid/image.png")!
        await #expect(throws: (any Error).self) { try await access.load(url) }
        #expect(first.requests.isEmpty)
        let cached = url.appendingPathComponent("cached")
        cache.storeCachedResponse(.init(response: HTTPURLResponse(url: cached, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Cache-Control": "public, max-age=3600"])!, data: image), for: URLRequest(url: cached))
        #expect(try await access.load(cached).0 == image)
        #expect(first.requests.isEmpty)
        try preferences.setAllowed(.images, true)
        #expect(try await access.load(url).0 == image)
        environment.update(.init(kind: .http, host: "127.0.0.1", port: second.url.port!), reinitializeShared: true)
        #expect(try await access.load(url.appendingPathComponent("second")).0 == image)
        #expect(first.requests.count == 2 && second.requests.isEmpty)
        let newlyConstructed = MobileImageAccess(preferences: preferences, network: network,
            proxyConfiguration: { environment.newClientConfiguration() }, cache: cache)
        #expect(try await newlyConstructed.load(url.appendingPathComponent("fresh")).0 == image)
        #expect(second.requests.count == 1)
    }
    @Test func redirectTransportNeverRestoresOriginSecretOnReturnHopOrAcceptsRedirectUserinfo() async throws {
        let proxy = try await LoopbackHTTPServer.start { request in
            switch request.path {
            case "http://origin.invalid/start": return .init(status: 302, headers: ["Location": "http://untrusted:password@other.invalid/next"])
            case "http://other.invalid/next": return .init(status: 302, headers: ["Location": "http://origin.invalid/end"])
            default: return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"origin\""])
            }
        }
        defer { proxy.stop() }
        let transport = RedirectingProxyTransport(transport: try URLSessionFeedTransport(proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!)))
        var request = URLRequest(url: URL(string: "http://origin.invalid/start")!)
        request.setValue("Basic owned-account", forHTTPHeaderField: "Authorization")
        let response = try await transport.send(request)
        #expect(response.status == 401 && proxy.requests.count == 3)
        #expect(proxy.requests.map { $0.headers["authorization"] } == ["Basic owned-account", nil, nil])
        #expect(proxy.requests.allSatisfy { !$0.path.contains("untrusted") && !$0.path.contains("password") })
    }
    @Test func postRedirectsPreserveOrDiscardBodyAccordingToStatusWithoutLosingSameOriginAuthorization() async throws {
        for status in [302, 303, 307, 308] {
            let proxy = try await LoopbackHTTPServer.start { request in
                if request.path.hasSuffix("/start") { return .init(status: status, headers: ["Location": "/end"]) }
                return .init()
            }
            defer { proxy.stop() }
            let transport = RedirectingProxyTransport(transport: try URLSessionFeedTransport(proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!)))
            var request = URLRequest(url: URL(string: "http://origin.invalid/start")!)
            request.httpMethod = "POST"; request.httpBody = Data("payload".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Basic owned-account", forHTTPHeaderField: "Authorization")
            _ = try await transport.send(request)
            let final = try #require(proxy.requests.last)
            #expect(proxy.requests.count == 2 && final.headers["authorization"] == "Basic owned-account")
            if status == 307 || status == 308 { #expect(final.method == "POST" && final.body == Data("payload".utf8)) }
            else { #expect(final.method == "GET" && final.body.isEmpty && final.headers["content-type"] == nil) }
        }
    }
}
