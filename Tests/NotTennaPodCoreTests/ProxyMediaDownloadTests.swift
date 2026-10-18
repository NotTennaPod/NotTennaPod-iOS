import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite struct ProxyMediaDownloadTests {
    private func file() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProxyMedia-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("audio.media")
    }
    @Test func authenticatedProxyResumesRealFileWithoutMixingOriginCredentials() async throws {
        let source = URL(string: "http://media-origin.invalid/audio")!
        let proxyAuth = "Basic " + Data("proxy-user:proxy-secret".utf8).base64EncodedString()
        let originAuth = "Basic " + Data("feed-user:feed-secret".utf8).base64EncodedString()
        let proxy = try await LoopbackHTTPServer.start { request in
            guard request.headers["proxy-authorization"] == proxyAuth else {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"proxy\""])
            }
            guard request.headers["authorization"] == originAuth else {
                return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"feed\""])
            }
            return .init(status: 206, headers: ["ETag": "\"same\"", "Content-Range": "bytes 3-5/6"], body: Data("def".utf8))
        }
        defer { proxy.stop() }
        let destination = try file(); defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        try Data("abc".utf8).write(to: destination)
        let configuration = PodcastProxy(kind: .http, host: "127.0.0.1", port: proxy.url.port!, username: "proxy-user", password: "proxy-secret")
        let client = ProxyNetworkEnvironment.Client(configuration: configuration)
        let transfer = MediaDownloadTransfer(proxyClient: { client })
        let result = try await transfer.download(.init(source: source.absoluteString, destination: destination,
            credentials: .init(username: "feed-user", password: "feed-secret"),
            representation: .init(resource: source, entityTag: "\"same\"", total: 6)))
        #expect(result.size == 6)
        #expect(try Data(contentsOf: destination) == Data("abcdef".utf8))
        #expect(proxy.requests.first?.headers["proxy-authorization"] == nil)
        #expect(proxy.requests.allSatisfy { $0.path == source.absoluteString && $0.headers["range"] == "bytes=3-" && $0.headers["if-range"] == "\"same\"" })
        #expect(proxy.requests.last?.headers["authorization"] == originAuth)
        #expect(proxy.requests.last?.headers["proxy-authorization"] == proxyAuth)
    }
    @Test func activeRedirectChainKeepsItsClientAndNextDownloadUsesReplacementWithoutOldSecret() async throws {
        let environment = ProxyNetworkEnvironment(configuration: .init())
        let second = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["proxy-authorization"] == nil)
            return .init(body: Data("replacement".utf8))
        }
        let next = PodcastProxy(kind: .http, host: "127.0.0.1", port: second.url.port!)
        let first = try await LoopbackHTTPServer.start { request in
            guard request.headers["proxy-authorization"] != nil else {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"first\""])
            }
            if request.path == "http://second-origin.invalid/audio" { return .init(body: Data("original-client".utf8)) }
            environment.update(next, reinitializeShared: true)
            return .init(status: 302, headers: ["Location": "http://second-origin.invalid/audio"])
        }
        defer { first.stop(); second.stop() }
        environment.update(.init(kind: .http, host: "127.0.0.1", port: first.url.port!, username: "old", password: "old-secret"), reinitializeShared: true)
        let transfer = MediaDownloadTransfer(proxyClient: { environment.sharedClient() })
        let destination = try file(); defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        _ = try await transfer.download(.init(source: "http://first-origin.invalid/audio", destination: destination))
        #expect(try Data(contentsOf: destination) == Data("original-client".utf8))
        #expect(first.requests.count == 3 && second.requests.isEmpty)
        _ = try await transfer.download(.init(source: "http://first-origin.invalid/audio", destination: destination))
        #expect(try Data(contentsOf: destination) == Data("replacement".utf8))
        #expect(first.requests.count == 3 && second.requests.count == 1)
    }
    @Test func confirmingUnchangedProxyReplacesClientCookiesForFutureDownloads() async throws {
        let proxy = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Set-Cookie": "downloadsession=previous; Path=/"], body: Data("media".utf8))
        }
        defer { proxy.stop() }
        let configuration = PodcastProxy(kind: .http, host: "127.0.0.1", port: proxy.url.port!)
        let environment = ProxyNetworkEnvironment(configuration: configuration)
        let transfer = MediaDownloadTransfer(proxyClient: { environment.sharedClient() })
        let destination = try file(); defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let request = MediaDownloadRequest(source: "http://media-origin.invalid/audio", destination: destination)
        _ = try await transfer.download(request)
        _ = try await transfer.download(request)
        environment.update(configuration, reinitializeShared: true)
        _ = try await transfer.download(request)
        #expect(proxy.requests.count == 3)
        #expect(proxy.requests[0].headers["cookie"] == nil)
        #expect(proxy.requests[1].headers["cookie"]?.contains("downloadsession=previous") == true)
        #expect(proxy.requests[2].headers["cookie"] == nil)
    }
    @Test func rejectedProxyLeavesExistingFileUntouchedAndDoesNotLoop() async throws {
        let proxy = try await LoopbackHTTPServer.start { _ in .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"reject\""]) }
        defer { proxy.stop() }
        let configuration = PodcastProxy(kind: .http, host: "127.0.0.1", port: proxy.url.port!, username: "bad", password: "bad")
        let destination = try file(); defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        try Data("preserved".utf8).write(to: destination)
        let client = ProxyNetworkEnvironment.Client(configuration: configuration)
        await #expect(throws: (any Error).self) {
            try await MediaDownloadTransfer(proxyClient: { client }).download(.init(source: "http://media-origin.invalid/audio", destination: destination))
        }
        #expect(try Data(contentsOf: destination) == Data("preserved".utf8))
        #expect(proxy.requests.count <= 2 && !proxy.requests.isEmpty)
    }
}
