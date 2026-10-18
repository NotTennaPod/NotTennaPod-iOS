import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Remote transcript misses ask the admission ("Cover images", or an unrestricted network) and are bounded; local and
/// cached transcripts never ask. Every request is a real request at a loopback fixture.
extension TranscriptLoaderTests {
    private static let mib = 1024 * 1024

    /// A transcript whose text pads the document to about `bytes`.
    static func document(_ word: String, bytes: Int = 0) -> Data {
        Data("{\"segments\":[{\"startTime\":0,\"endTime\":5,\"body\":\"\(word)\(String(repeating: " ", count: max(0, bytes - 80)))\"}]}".utf8)
    }

    /// Serves `body()` at /transcript.json, counting requests.
    final class Server: Sendable {
        private final class Script: Sendable {
            let response = Mutex(LoopbackHTTPServer.Response(body: TranscriptLoaderTests.document("A")))
        }
        let server: LoopbackHTTPServer
        private let script: Script
        init() async throws {
            let script = Script()
            self.script = script
            server = try await LoopbackHTTPServer.start { _ in script.response.withLock { $0 } }
        }
        var url: URL { server.url.deletingLastPathComponent().appendingPathComponent("transcript.json") }
        var count: Int { server.requests.count }
        func serve(_ body: Data, headers: [String: String] = [:], declaresLength: Bool = true) {
            script.response.withLock { $0 = .init(headers: headers, body: body, includeAutomaticContentLength: declaresLength) }
        }
        deinit { server.stop() }
    }

    @MainActor private func loader(_ fixture: AuxiliaryNetworkFixture, cache: URLCache? = nil) -> TranscriptLoader {
        TranscriptLoader(transport: URLSessionFeedTransport(), cache: cache ?? URLCache(memoryCapacity: 40_000_000, diskCapacity: 0),
                         userAgent: "test", admission: fixture.admission)
    }

    /// Cover images off on cellular or Low Data: a cold miss makes no request and waits for its permission.
    @Test(arguments: ["cellular", "lowData"]) @MainActor
    func coldMissOnRestrictedNetworkWithCoverImagesOffMakesNoRequest(network: String) async throws {
        let server = try await Server()
        let fixture = try AuxiliaryNetworkFixture(allowed: [], state: network == "cellular" ? AuxiliaryNetworkFixture.cellular : AuxiliaryNetworkFixture.lowData)
        let load = try await loader(fixture).loadTranscript(.init(format: .json, url: server.url.absoluteString))
        #expect(load == TranscriptLoad(transcript: nil, refreshPending: false, deferred: .permitted(.smallMetadata)))
        #expect(server.count == 0)
        // Control: with Cover images on, the same miss is fetched.
        try fixture.allow(["images"])
        #expect(try await loader(fixture).loadTranscript(.init(format: .json, url: server.url.absoluteString)).transcript?.segments.first?.words == "A")
        #expect(server.count == 1)
    }

    /// The sidecar and a cached response show without asking, whatever the network and options.
    @Test @MainActor func sidecarAndCacheHitsMakeNoRequest() async throws {
        let server = try await Server()
        let fixture = try AuxiliaryNetworkFixture(allowed: [], state: AuxiliaryNetworkFixture.wifi)
        let loader = loader(fixture), descriptor = FeedTranscript(format: .json, url: server.url.absoluteString)
        #expect(try await loader.loadTranscript(descriptor).transcript != nil)
        #expect(server.count == 1)
        fixture.network.update(AuxiliaryNetworkFixture.cellular)
        #expect(try await loader.loadTranscript(descriptor) == TranscriptLoad(transcript: try TranscriptParser.parse(String(decoding: Self.document("A"), as: UTF8.self), format: .json)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sidecar-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appendingPathComponent("episode.mp3")
        try Self.document("Local").write(to: URL(fileURLWithPath: media.path + ".transcript"))
        let other = FeedTranscript(format: .json, url: server.url.appendingPathExtension("other").absoluteString)
        #expect(try await loader.loadTranscript(other, localMediaPath: media.path).transcript?.segments.first?.words == "Local")
        #expect(server.count == 1)
    }

    /// The default options (Cover images on) fetch a transcript on cellular, as before.
    @Test @MainActor func defaultSettingsLoadOnCellular() async throws {
        let server = try await Server()
        let fixture = try AuxiliaryNetworkFixture(allowed: ["images"], state: AuxiliaryNetworkFixture.cellular)
        #expect(try await loader(fixture).loadTranscript(.init(format: .json, url: server.url.absoluteString)).transcript?.segments.first?.words == "A")
        #expect(server.count == 1)
    }

    /// Over the budget, with the length declared, undeclared, or hidden by gzip: on a restricted network (5 MiB) a
    /// 6 MiB transcript waits for an unrestricted network; on Wi-Fi (20 MiB) a 21 MiB one is refused for the session.
    /// Neither is cached; one request per attempt.
    @Test(arguments: ["declared", "undeclared", "gzip"]) @MainActor
    func oversizedTranscriptsAreNotCachedAndWaitOrAreRefused(framing: String) async throws {
        let server = try await Server()
        func serve(_ bytes: Int) throws {
            let body = Self.document("Big", bytes: bytes)
            switch framing {
            case "gzip": server.serve(try TestGzip.encode(body), headers: ["Content-Encoding": "gzip"])
            case "undeclared": server.serve(body, declaresLength: false)
            default: server.serve(body)
            }
        }
        let cache = URLCache(memoryCapacity: 40_000_000, diskCapacity: 0)
        let fixture = try AuxiliaryNetworkFixture(allowed: ["images"], state: AuxiliaryNetworkFixture.cellular)
        let loader = loader(fixture, cache: cache), descriptor = FeedTranscript(format: .json, url: server.url.absoluteString)
        try serve(6 * Self.mib)
        #expect(try await loader.loadTranscript(descriptor) == TranscriptLoad(transcript: nil, deferred: .unrestricted))
        #expect(server.count == 1 && cache.cachedResponse(for: URLRequest(url: server.url)) == nil)
        // Under the unrestricted budget it loads (control).
        fixture.network.update(AuxiliaryNetworkFixture.wifi)
        #expect(try await loader.loadTranscript(descriptor).transcript?.segments.first?.words.hasPrefix("Big") == true)
        #expect(server.count == 2)
        try serve(21 * Self.mib)
        await #expect(throws: FeedBodyLimitExceeded.self) { try await loader.loadTranscript(descriptor, forceRefresh: true) }
        #expect(server.count == 3)
        await #expect(throws: FeedBodyLimitExceeded.self) { try await loader.loadTranscript(descriptor, forceRefresh: true) }
        #expect(server.count == 3, "refused for the session")
    }

    /// Over the restricted budget the transcript waits for an unrestricted network: one request; then none while the
    /// network stays restricted, whatever the options; then exactly one on Wi-Fi.
    @Test @MainActor func restrictedOverCapWaitsForUnrestrictedNotPermission() async throws {
        let server = try await Server()
        server.serve(Self.document("Big", bytes: 6 * Self.mib))
        let fixture = try AuxiliaryNetworkFixture(allowed: ["images"], state: AuxiliaryNetworkFixture.cellular)
        let loader = loader(fixture), descriptor = FeedTranscript(format: .json, url: server.url.absoluteString)
        #expect(try await loader.loadTranscript(descriptor).deferred == .unrestricted)
        #expect(server.count == 1)
        for options: Set<String> in [["images"], ["images", "streaming"], ["images", "streaming", "feed_refresh"]] {
            try fixture.allow(options)
            #expect(try await loader.loadTranscript(descriptor).deferred == .unrestricted)
            #expect(try await loader.loadTranscript(descriptor, forceRefresh: true) == TranscriptLoad(transcript: nil, refreshPending: true, deferred: .unrestricted))
        }
        fixture.network.update(AuxiliaryNetworkFixture.lowData)
        #expect(try await loader.loadTranscript(descriptor).deferred == .unrestricted)
        #expect(server.count == 1)
        fixture.network.update(AuxiliaryNetworkFixture.wifi)
        #expect(try await loader.loadTranscript(descriptor).transcript != nil)
        #expect(server.count == 2)
    }

    /// A Refresh while denied keeps showing the sidecar or cached transcript "A", makes no request and keeps its
    /// intent; once permitted, exactly one request replaces it with the publisher's "B".
    @Test(arguments: ["sidecar", "cache"]) @MainActor func deniedForcedRefreshKeepsIntent(source: String) async throws {
        let server = try await Server()
        let fixture = try AuxiliaryNetworkFixture(allowed: ["images"], state: AuxiliaryNetworkFixture.wifi)
        let loader = loader(fixture), descriptor = FeedTranscript(format: .json, url: server.url.absoluteString)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sidecar-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appendingPathComponent("episode.mp3")
        var path: String?
        if source == "sidecar" {
            try Self.document("A").write(to: URL(fileURLWithPath: media.path + ".transcript")); path = media.path
        } else {
            #expect(try await loader.loadTranscript(descriptor).transcript?.segments.first?.words == "A")
        }
        let before = server.count
        server.serve(Self.document("B"))
        try fixture.allow([])
        fixture.network.update(AuxiliaryNetworkFixture.cellular)
        let denied = try await loader.loadTranscript(descriptor, localMediaPath: path, forceRefresh: true)
        #expect(denied.transcript?.segments.first?.words == "A" && denied.refreshPending && denied.deferred == .permitted(.smallMetadata))
        #expect(server.count == before)
        try fixture.allow(["images"])
        try await fixture.admission.wait(until: try #require(denied.deferred))
        let refreshed = try await loader.loadTranscript(descriptor, localMediaPath: path, forceRefresh: denied.refreshPending)
        #expect(refreshed == TranscriptLoad(transcript: try TranscriptParser.parse(String(decoding: Self.document("B"), as: UTF8.self), format: .json)))
        #expect(server.count == before + 1)
    }

    /// A transcript admitted only because the network was unrestricted stops when a metered network appears, even one
    /// gone again: the result waits for its permission, nothing is cached, and the next load fetches it once.
    @Test @MainActor func transientMeteredRevisionDefersAPathLockedTranscript() async throws {
        let disconnected = Mutex(false)
        let hold = Mutex(true)
        let body = Self.document("A")
        let server = try await LoopbackHTTPServer.start(onClientDisconnect: { disconnected.withLock { $0 = true } }) { _ in
            hold.withLock { $0 } ? nil : .init(body: body)
        }
        defer { server.stop() }
        let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 0)
        let fixture = try AuxiliaryNetworkFixture(allowed: [], state: AuxiliaryNetworkFixture.wifi)
        let loader = loader(fixture, cache: cache), descriptor = FeedTranscript(format: .json, url: server.url.absoluteString)
        let load = Task { try await loader.loadTranscript(descriptor) }
        try await fixture.until { server.requests.count == 1 }
        fixture.network.update(AuxiliaryNetworkFixture.cellular)
        fixture.network.update(AuxiliaryNetworkFixture.wifi)
        #expect(try await load.value == TranscriptLoad(transcript: nil, deferred: .permitted(.smallMetadata)))
        try await fixture.until { disconnected.withLock { $0 } }
        #expect(cache.cachedResponse(for: URLRequest(url: server.url)) == nil)
        hold.withLock { $0 = false }
        #expect(try await loader.loadTranscript(descriptor).transcript?.segments.first?.words == "A")
        #expect(server.requests.count == 2)
    }

    /// A sidecar over the restricted budget parks its URL for the transcript screen too: on the same network the screen
    /// makes no request and waits for an unrestricted one, where it loads.
    @Test @MainActor func sidecarOverBudgetParksTheURLForTheScreen() async throws {
        let server = try await Server()
        server.serve(Self.document("Big", bytes: 6 * Self.mib), declaresLength: false)
        let fixture = try AuxiliaryNetworkFixture(allowed: ["images"], state: AuxiliaryNetworkFixture.cellular)
        let loader = loader(fixture), descriptor = FeedTranscript(format: .json, url: server.url.absoluteString)
        let media = FileManager.default.temporaryDirectory.appendingPathComponent("Sidecar-\(UUID()).mp3")
        try Data([1]).write(to: media)
        defer { try? FileManager.default.removeItem(at: media); try? FileManager.default.removeItem(atPath: media.path + ".transcript") }
        await #expect(throws: FeedBodyLimitExceeded.self) {
            try await loader.storeSidecar(descriptor, media: media, constraint: .connected, network: fixture.network)
        }
        #expect(server.count == 1)
        #expect(try await loader.loadTranscript(descriptor) == TranscriptLoad(transcript: nil, deferred: .unrestricted))
        #expect(server.count == 1)
        fixture.network.update(AuxiliaryNetworkFixture.wifi)
        #expect(try await loader.loadTranscript(descriptor).transcript != nil)
        #expect(server.count == 2)
    }

    /// A URL refused this session by the screen (over the unrestricted budget) is not fetched again for a sidecar.
    /// A loader with no such history fetches it (control).
    @Test @MainActor func refusedURLIsNotFetchedAgainForASidecar() async throws {
        let server = try await Server()
        server.serve(Self.document("Big", bytes: 21 * Self.mib))
        let fixture = try AuxiliaryNetworkFixture(allowed: ["images"], state: AuxiliaryNetworkFixture.wifi)
        let loader = loader(fixture), descriptor = FeedTranscript(format: .json, url: server.url.absoluteString)
        let media = FileManager.default.temporaryDirectory.appendingPathComponent("Sidecar-\(UUID()).mp3")
        try Data([1]).write(to: media)
        defer { try? FileManager.default.removeItem(at: media); try? FileManager.default.removeItem(atPath: media.path + ".transcript") }
        await #expect(throws: FeedBodyLimitExceeded.self) { try await loader.loadTranscript(descriptor) }
        #expect(server.count == 1)
        await #expect(throws: FeedBodyLimitExceeded.self) {
            try await loader.storeSidecar(descriptor, media: media, constraint: .unmetered, network: fixture.network)
        }
        #expect(server.count == 1)
        await #expect(throws: FeedBodyLimitExceeded.self) {
            try await self.loader(fixture).storeSidecar(descriptor, media: media, constraint: .unmetered, network: fixture.network)
        }
        #expect(server.count == 2)
    }
}
