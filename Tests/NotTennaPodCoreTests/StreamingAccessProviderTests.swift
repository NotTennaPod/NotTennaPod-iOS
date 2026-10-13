import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.timeLimit(.minutes(1))) @MainActor
struct StreamingAccessProviderTests {
    private func withPreferences(_ body: (MobileNetworkPreferenceStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mobile.json")
        try await body(MobileNetworkPreferenceStore(file: file), file)
    }

    private func episode(downloaded: Bool = false, path: String? = nil, url: String = "https://example.invalid/test.mp3") -> LibraryEpisode {
        var state = EpisodeUserState()
        state.isDownloaded = downloaded
        state.localFileURL = path
        return .init(id: 1, details: .init(identifier: "1", media: .init(url: url, size: 0)), userState: state)
    }

    @Test func originalDefaultsAndEveryIndependentPermissionSurviveRelaunch() async throws {
        try await withPreferences { preferences, file in
            #expect(preferences.allowed == ["images"])
            for use in MobileNetworkPreferenceStore.Use.allCases {
                #expect(preferences.allows(use) == (use == .images))
            }
            // Set every subset of the six source choices, in both directions.
            for mask in 0..<64 {
                for (index, use) in MobileNetworkPreferenceStore.Use.allCases.enumerated() {
                    try preferences.setAllowed(use, mask & (1 << index) != 0)
                }
                let expected = Set(MobileNetworkPreferenceStore.Use.allCases.enumerated().compactMap {
                    mask & (1 << $0.offset) != 0 ? $0.element.rawValue : nil
                })
                #expect(preferences.allowed == expected)
                #expect(try MobileNetworkPreferenceStore(file: file).allowed == expected)
            }
        }
    }

    @Test func downloadsFirstEntryInitializesOnlyUnsetMobileChoicesAndConfirmedSetReplacesUnknown() async throws {
        try await withPreferences { preferences, file in
            #expect(!preferences.allows(.sync))
            try preferences.initializeSettingsDefaults()
            #expect(preferences.allowed == ["images", "sync"])
            try preferences.updateAllowed([]); try preferences.initializeSettingsDefaults()
            #expect(preferences.allowed.isEmpty)
            let reopened = try MobileNetworkPreferenceStore(file: file)
            try reopened.initializeSettingsDefaults(); #expect(reopened.allowed.isEmpty)
            try reopened.updateAllowed(["images", "future"])
            try reopened.setAllowed(.streaming, true); #expect(reopened.allowed.contains("future"))
            try reopened.updateAllowed(["streaming", "episode_download"])
            #expect(try MobileNetworkPreferenceStore(file: file).allowed == ["streaming", "episode_download"])
        }
    }

    @Test func restrictedImagesUseCacheWithoutNetworkAndLivePermissionAllowsFetch() async throws {
        try await withPreferences { preferences, _ in
            let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=")!
            let server = try await LoopbackHTTPServer.start { _ in .init(headers: ["Content-Type":"image/png", "Cache-Control":"public, max-age=3600"], body: bytes) }
            defer { server.stop() }
            let cache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 0)
            let configuration = URLSessionConfiguration.ephemeral; configuration.urlCache = cache
            let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
            let network = DownloadNetworkMonitor(startMonitoring: false)
            network.update(.init(connected: true, metered: true, cellular: true))
            let access = MobileImageAccess(preferences: preferences, network: network, session: session)
            try preferences.setAllowed(.images, false)
            await #expect(throws: (any Error).self) { try await access.load(server.url) }
            #expect(server.requests.isEmpty)
            let cached = server.url.appendingPathComponent("cached")
            cache.storeCachedResponse(.init(response: HTTPURLResponse(url: cached, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Cache-Control":"public, max-age=3600"])!, data: bytes), for: URLRequest(url: cached))
            #expect(try await access.load(cached).0 == bytes)
            #expect(server.requests.isEmpty)
            try preferences.setAllowed(.images, true)
            #expect(try await access.load(server.url).0 == bytes)
            #expect(server.requests.count == 1)
            try preferences.setAllowed(.images, false)
            network.update(.init(connected: true, metered: false, cellular: false))
            #expect(try await access.load(server.url.appendingPathComponent("wifi")).0 == bytes)
            #expect(server.requests.count == 2)
        }
    }

    @Test func streamingEditsPreserveUnknownAndOtherStoredPermissions() async throws {
        try await withPreferences { _, file in
            try Data("[\"images\",\"episode_download\",\"future_permission\"]".utf8).write(to: file)
            let preferences = try MobileNetworkPreferenceStore(file: file)
            let original = preferences.allowed
            try preferences.setAllowed(.streaming, true)
            try preferences.setAllowed(.streaming, true)
            #expect(try MobileNetworkPreferenceStore(file: file).allowed == original.union(["streaming"]))
            try preferences.setAllowed(.streaming, false)
            #expect(try MobileNetworkPreferenceStore(file: file).allowed == original)
        }
    }

    @Test func corruptAndFailedWritesDoNotResetOrPublishPreferences() async throws {
        try await withPreferences { preferences, file in
            let invalid = Data("{broken".utf8)
            try invalid.write(to: file)
            #expect(throws: (any Error).self) { try MobileNetworkPreferenceStore(file: file) }
            #expect(try Data(contentsOf: file) == invalid)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try preferences.setAllowed(.streaming, true) }
            #expect(preferences.allowed == ["images"])
        }
    }

    @Test func localAdmissionUsesSavedStateWithoutFileExistenceOrRemoteFallback() throws {
        let missing = "/missing-\(UUID().uuidString).mp3"
        for downloaded in [false, true] {
            for path in [nil, "", missing] as [String?] {
                let item = episode(downloaded: downloaded, path: path)
                #expect(StreamingAccessProvider.needsStreaming(item) == !(downloaded && path != nil))
            }
        }
        let local = episode(downloaded: true, path: missing)
        #expect(try AVPlayerPlaybackEngine.mediaURL(local) == URL(fileURLWithPath: missing))
        #expect(!StreamingAccessProvider.needsStreaming(episode(url: "file:///missing.mp3")))
        // Imported Android content URIs are not native readable files.
        #expect(StreamingAccessProvider.needsStreaming(episode(url: "content://provider/item")))
        #expect(throws: PlaybackSourceError.invalidURL) {
            try AVPlayerPlaybackEngine.mediaURL(episode(url: "content://provider/item"))
        }
    }

    @Test func observedPermissionMatrixMatchesOriginalMeteredOrCellularGuard() async throws {
        try await withPreferences { preferences, _ in
            let monitor = DownloadNetworkMonitor(startMonitoring: false)
            let provider = StreamingAccessProvider(preferences: preferences, network: monitor)
            for connected in [false, true] {
                for metered in [false, true] {
                    for cellular in [false, true] {
                        for allowed in [false, true] {
                            try preferences.setAllowed(.streaming, allowed)
                            monitor.update(.init(connected: connected, metered: metered, cellular: cellular))
                            let result = try await provider.access(for: episode())
                            #expect(result.needsStreaming)
                            #expect(result.streamingAllowed == (allowed || !(metered || cellular)))
                            #expect(!result.isCasting)
                        }
                    }
                }
            }
        }
    }

    @Test func localCastAndPersistentPermissionDoNotWaitForFirstNetworkObservation() async throws {
        try await withPreferences { preferences, _ in
            let monitor = DownloadNetworkMonitor(startMonitoring: false)
            let provider = StreamingAccessProvider(preferences: preferences, network: monitor)
            #expect(try await provider.access(for: episode(downloaded: true, path: "/missing.mp3")).needsStreaming == false)
            #expect(try await provider.access(for: episode(), isCasting: true).isCasting)
            try preferences.setAllowed(.streaming, true)
            #expect(try await provider.access(for: episode()).streamingAllowed)
            #expect(monitor.current == nil && monitor.pendingObservationCount == 0)
        }
    }

    @Test func firstOfflineObservationReturnsWithoutWaitingForConnectivityAndRereadsPreference() async throws {
        try await withPreferences { preferences, _ in
            let monitor = DownloadNetworkMonitor(startMonitoring: false)
            let provider = StreamingAccessProvider(preferences: preferences, network: monitor)
            let item = episode()
            let pending = Task { try await provider.access(for: item) }
            defer { pending.cancel() }
            let deadline = ContinuousClock.now + .seconds(5)
            while monitor.pendingObservationCount == 0 && ContinuousClock.now < deadline { await Task.yield() }
            try #require(monitor.pendingObservationCount == 1)
            try preferences.setAllowed(.streaming, true)
            monitor.update(.init(connected: false, metered: true, cellular: false))
            #expect(try await pending.value.streamingAllowed)
            #expect(monitor.pendingObservationCount == 0 && monitor.pendingWaitCount == 0)
            try preferences.setAllowed(.streaming, false)
            #expect(try await provider.access(for: item).streamingAllowed == false)
            monitor.update(.init(connected: false, metered: false, cellular: false))
            #expect(try await provider.access(for: item).streamingAllowed)
        }
    }
}
