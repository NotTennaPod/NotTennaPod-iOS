import Compression
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Pictures on restricted networks (cellular, a hotspot, Low Data Mode) stop at the picture limit, counted on the bytes
/// actually received, whatever the response declares, through the transport the app really uses.
@Suite @MainActor
struct MobileImageLimitTests {
    private static let oversized = 8 * 1024 * 1024

    private func withAccess(proxy: PodcastProxy = .init(),
                            _ body: (MobileImageAccess, DownloadNetworkMonitor) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ImageLimit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = try MobileNetworkPreferenceStore(file: directory.appendingPathComponent("mobile.json"))
        try preferences.setAllowed(.images, true)
        let network = DownloadNetworkMonitor(startMonitoring: false)
        network.update(.init(connected: true, metered: true, cellular: true))
        // As the app builds it: always through the proxy client, which is a direct connection when no proxy is set.
        let environment = ProxyNetworkEnvironment(configuration: proxy)
        let access = MobileImageAccess(preferences: preferences, network: network,
            proxyConfiguration: { environment.newClientConfiguration() }, cache: URLCache(memoryCapacity: 0, diskCapacity: 0))
        try await body(access, network)
    }

    /// Responses larger than the restricted limit in every way a server can send them.
    private static func responses() -> [String: LoopbackHTTPServer.Response] {
        let body = Data(count: oversized)
        let chunked = Data("\(String(body.count, radix: 16))\r\n".utf8) + body + Data("\r\n0\r\n\r\n".utf8)
        return [
            "/declared": .init(headers: ["Content-Type": "image/jpeg"], body: body),
            "/no-length": .init(headers: ["Content-Type": "image/jpeg"], body: body, includeAutomaticContentLength: false),
            "/chunked": .init(headers: ["Content-Type": "image/jpeg", "Transfer-Encoding": "chunked"], body: chunked,
                              includeAutomaticContentLength: false),
            "/gzip": .init(headers: ["Content-Type": "image/jpeg", "Content-Encoding": "gzip"], body: gzip(body)),
            "/claims-huge": .init(headers: ["Content-Type": "image/jpeg", "Content-Length": "104857600"], body: Data(count: 1024)),
            "/claims-small": .init(headers: ["Content-Type": "image/jpeg", "Content-Length": "1000"], body: body),
            "/small": .init(headers: ["Content-Type": "image/jpeg"], body: Data(count: 1024 * 1024)),
            "/missing": .init(status: 404, headers: ["Content-Type": "text/html"], body: Data("missing".utf8)),
        ]
    }

    private func checkLimits(_ access: MobileImageAccess, _ network: DownloadNetworkMonitor, base: URL) async throws {
        for path in ["/declared", "/no-length", "/chunked", "/gzip", "/claims-huge"] {
            let url = base.appendingPathComponent(String(path.dropFirst()))
            let error = await #expect(throws: ArtworkTooLarge.self, "\(path) stops at the restricted limit") { _ = try await access.load(url) }
            #expect(error?.restricted == true)
        }
        // A length smaller than the body: no more than the declared bytes are read.
        let (claimed, _) = try await access.load(base.appendingPathComponent("claims-small"))
        #expect(claimed.count <= 1000)
        // Ordinary pictures and refusals are unaffected.
        #expect(try await access.load(base.appendingPathComponent("small")).0.count == 1024 * 1024)
        #expect((try await access.load(base.appendingPathComponent("missing")).1 as? HTTPURLResponse)?.statusCode == 404)
        // On Wi-Fi the same picture loads.
        network.update(.init(connected: true, metered: false, cellular: false, transport: .wifi))
        for path in ["/declared", "/no-length", "/chunked", "/gzip"] {
            #expect(try await access.load(base.appendingPathComponent(String(path.dropFirst()))).0.count == Self.oversized, "\(path)")
        }
        // A length over the limit for any network stops before the body.
        let huge = await #expect(throws: ArtworkTooLarge.self) { _ = try await access.load(base.appendingPathComponent("claims-huge")) }
        #expect(huge?.restricted == false)
        // Low Data Mode on Wi-Fi counts as restricted.
        network.update(.init(connected: true, metered: false, cellular: false, transport: .wifi, constrained: true))
        await #expect(throws: ArtworkTooLarge.self) { _ = try await access.load(base.appendingPathComponent("no-length")) }
    }

    @Test func directConnectionStopsOversizedPicturesOnRestrictedNetworks() async throws {
        let responses = Self.responses()
        let server = try await LoopbackHTTPServer.start { request in responses[request.path] ?? .init(status: 404) }
        defer { server.stop() }
        try await withAccess { access, network in
            try await checkLimits(access, network, base: server.url.deletingLastPathComponent())
        }
    }

    @Test func configuredProxyStopsOversizedPicturesOnRestrictedNetworks() async throws {
        let responses = Self.responses()
        let proxy = try await LoopbackHTTPServer.start { request in
            responses[URL(string: request.path)?.path ?? ""] ?? .init(status: 404)
        }
        defer { proxy.stop() }
        try await withAccess(proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!)) { access, network in
            try await checkLimits(access, network, base: URL(string: "http://cover-origin.invalid/")!)
        }
        #expect(proxy.requests.allSatisfy { $0.path.hasPrefix("http://cover-origin.invalid/") })
    }

    /// Without a proxy configuration the same bounded client is used.
    @Test func accessWithoutProxyConfigurationStopsOversizedPicturesOnRestrictedNetworks() async throws {
        let responses = Self.responses()
        let server = try await LoopbackHTTPServer.start { request in responses[request.path] ?? .init(status: 404) }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ImageLimit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = try MobileNetworkPreferenceStore(file: directory.appendingPathComponent("mobile.json"))
        let network = DownloadNetworkMonitor(startMonitoring: false)
        network.update(.init(connected: true, metered: true, cellular: true))
        let access = MobileImageAccess(preferences: preferences, network: network, cache: URLCache(memoryCapacity: 0, diskCapacity: 0))
        try await checkLimits(access, network, base: server.url.deletingLastPathComponent())
    }

    /// A picture without a length streamed to the phone: reading stops soon after the limit instead of taking it all.
    @Test func endlessPictureStopsNearTheLimit() async throws {
        let chunk = Data(count: 1024 * 1024)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "image/jpeg"], body: chunk, keepConnectionOpen: true, includeAutomaticContentLength: false)
        }
        defer { server.stop() }
        try await withAccess { access, _ in
            let finished = Mutex(false)
            let load = Task { @MainActor in
                defer { finished.withLock { $0 = true } }
                return try await access.load(server.url.deletingLastPathComponent().appendingPathComponent("endless"))
            }
            let deadline = ContinuousClock.now + .seconds(10)
            while server.requests.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            var sent = 1
            while sent < 40, !finished.withLock({ $0 }) {
                do { try await server.appendResponseBody(chunk, toLatestRequestFor: "/endless", isFinal: false) } catch { break }
                sent += 1
            }
            if !finished.withLock({ $0 }) { try? await server.appendResponseBody(Data(), toLatestRequestFor: "/endless", isFinal: true) }
            let result = await load.result
            #expect(throws: ArtworkTooLarge.self) { _ = try result.get() }
            #expect(sent <= 20, "sent \(sent) MB before the phone stopped reading")
            #expect(server.requests.count == 1)
        }
    }

    /// Deferred pictures are asked for again only on an unrestricted network.
    @Test func waitingForAnUnrestrictedNetworkEndsOnWiFiOnly() async throws {
        try await withAccess { access, network in
            let cellular = try await access.byteLimit()
            #expect(cellular.bytes == MobileImageAccess.restrictedByteLimit && cellular.restricted)
            let finished = Mutex(false)
            let wait = Task { @MainActor in try await access.waitUntilUnrestricted(); finished.withLock { $0 = true } }
            network.update(.init(connected: true, metered: false, cellular: false, transport: .wifi, constrained: true))
            network.update(.init(connected: false, metered: true, cellular: false))
            for _ in 0..<20 { await Task.yield() }
            #expect(!finished.withLock { $0 })
            network.update(.init(connected: true, metered: false, cellular: false, transport: .wifi))
            try await wait.value
            let wifi = try await access.byteLimit()
            #expect(wifi.bytes == MobileImageAccess.byteLimit && !wifi.restricted)
            try await access.waitUntilUnrestricted()
        }
    }

    /// A gzip body (RFC 1952) of `data`, so the bytes on the wire are far fewer than the decoded picture.
    private static func gzip(_ data: Data) -> Data {
        var output = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255])
        let capacity = data.count + 1024
        var deflated = [UInt8](repeating: 0, count: capacity)
        let count = data.withUnsafeBytes { source in
            compression_encode_buffer(&deflated, capacity, source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        output.append(contentsOf: deflated[0..<count])
        let table: [UInt32] = (0..<256).map { index in
            (0..<8).reduce(UInt32(index)) { crc, _ in (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1))) }
        }
        var crc: UInt32 = 0xffff_ffff
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        crc ^= 0xffff_ffff
        for value in [crc, UInt32(truncatingIfNeeded: data.count)] {
            withUnsafeBytes(of: value.littleEndian) { output.append(contentsOf: $0) }
        }
        return output
    }
}
