import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.timeLimit(.minutes(1))) struct FeedAuthenticationTests {
    private let credentials = FeedCredentials(username: "fixture-user", password: "fixture-password")
    private var fetched: FetchedFeed {
        .init(feed: .init(format: .rss, title: "Private feed", episodes: []), source: "https://example.test/private.xml",
              responseURL: URL(string: "https://example.test/private.xml")!, validator: nil, permanentRedirectURL: nil)
    }
    private func fixture(isolation: isolated (any Actor)? = #isolation, _ body: (FeedLibraryStore, URL, FeedTestVault, FeedAuthentication) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FeedAuth-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library.sqlite"), store = try FeedLibraryStore(url: file)
        let vault = FeedTestVault(), auth = FeedAuthentication(store: store, vault: vault)
        do { try await body(store, file, vault, auth); try await store.close() }
        catch { try? await store.close(); throw error }
    }

    @Test func authenticatedPreviewSubscribeAndReopenKeepSecretOutsideLibrary() async throws {
        try await fixture { store, file, vault, auth in
            let preview = try await auth.preparePreview(fetched, credentials: credentials)
            #expect(preview.subscriptionState == .notSubscribed && !preview.keepUpdated)
            #expect(try await auth.credentials(feedID: preview.id) == credentials)
            #expect(try await store.pendingEffects().isEmpty)
            #expect(try await store.subscribePreview(feedID: preview.id))
            let reopened = try FeedLibraryStore(url: file)
            #expect(try await FeedAuthentication(store: reopened, vault: vault).credentials(feedID: preview.id) == credentials)
            #expect(try await reopened.feed(id: preview.id)?.subscriptionState == .subscribed)
            try await reopened.close()
            for candidate in [file, URL(filePath: file.path + "-wal"), URL(filePath: file.path + "-shm")] {
                if let data = try? Data(contentsOf: candidate) {
                    #expect(data.range(of: Data(credentials.username!.utf8)) == nil)
                    #expect(data.range(of: Data(credentials.password!.utf8)) == nil)
                }
            }
            #expect(vault.values.count == 1)
            #expect(try await store.feedCredentialCleanup().isEmpty)
        }
    }

    @Test func failedSecretWriteDoesNotCreatePreviewOrReplaceExistingCredential() async throws {
        try await fixture { store, _, vault, auth in
            vault.failInsert = true
            await #expect(throws: SynchronizationCredentialError.keychain(-1)) { try await auth.preparePreview(fetched, credentials: credentials) }
            #expect(try await store.feeds().isEmpty)
            vault.failInsert = false
            let feed = try await auth.preparePreview(fetched, credentials: credentials)
            vault.failInsert = true
            await #expect(throws: SynchronizationCredentialError.keychain(-1)) {
                try await auth.save(.init(username: "replacement", password: "new"), feedID: feed.id)
            }
            #expect(try await auth.credentials(feedID: feed.id) == credentials)
            #expect(vault.values.count == 1)
            #expect(try await store.feedCredentialCleanup().isEmpty)
        }
    }

    @Test func replacementAndFeedDeletionRetainCleanupAcrossFailureAndReopen() async throws {
        try await fixture { store, file, vault, auth in
            let feed = try await auth.preparePreview(fetched, credentials: credentials)
            vault.failRemove = true
            let replacement = FeedCredentials(username: "", password: "")
            try await auth.save(replacement, feedID: feed.id)
            #expect(try await auth.credentials(feedID: feed.id) == replacement)
            #expect(vault.values.count == 2)
            #expect(try await store.requestFeedDeletion(feedID: feed.id))
            #expect(try await auth.credentials(feedID: feed.id) == nil)
            #expect(try await store.feedCredentialCleanup().count == 2)
            let reopened = try FeedLibraryStore(url: file), recovery = FeedAuthentication(store: reopened, vault: vault)
            await #expect(throws: SynchronizationCredentialError.keychain(-2)) { try await recovery.recoverCredentialCleanup() }
            vault.failRemove = false
            try await recovery.recoverCredentialCleanup()
            #expect(vault.values.isEmpty)
            #expect(try await reopened.feedCredentialCleanup().isEmpty)
            try await reopened.close()
        }
    }

    @Test func interruptedStagingAndMissingFeedCannotLeaveSelectedOrLeakedSecret() async throws {
        try await fixture { store, _, vault, auth in
            for written in [false, true] {
                let id = UUID(); try await store.stageFeedCredential(id)
                if written { try vault.insert("interrupted-fixture", id: id) }
            }
            try await auth.recoverCredentialCleanup()
            #expect(vault.values.isEmpty)
            #expect(try await store.feedCredentialCleanup().isEmpty)
            await #expect(throws: FeedLibraryError.missingFeed(99)) { try await auth.save(credentials, feedID: 99) }
            #expect(vault.values.isEmpty)
            #expect(try await store.feedCredentialCleanup().isEmpty)
        }
    }

    @Test func concurrentEditsLeaveOneCompleteCredentialPair() async throws {
        try await fixture { store, _, vault, auth in
            let feed = try await auth.preparePreview(fetched, credentials: credentials)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<10 {
                    group.addTask { try await auth.save(.init(username: "user-\(index)", password: "secret-\(index)"), feedID: feed.id) }
                }
                try await group.waitForAll()
            }
            let selected = try #require(try await auth.credentials(feedID: feed.id))
            #expect(selected.username?.dropFirst(5) == selected.password?.dropFirst(7))
            #expect(vault.values.count == 1)
            #expect(try await store.feedCredentialCleanup().isEmpty)
        }
    }

    @MainActor @Test func rejectedLoginPersistsDetailsAndCorrectedLoginRecoversWithoutLosingLibraryState() async throws {
        let login = credentials, bad = FeedCredentials(username: "fixture-user", password: "rejected")
        let server = try await LoopbackHTTPServer.start { request in
            guard request.headers["authorization"] == login.authorization(utf8: true) else {
                return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"fixture\", charset=\"UTF-8\""], body: Data())
            }
            return .init(body: Data("<rss><channel><title>Recovered podcast</title><item><guid>retained</guid><title>Retained episode</title></item></channel></rss>".utf8))
        }
        defer { server.stop() }
        try await fixture { store, file, vault, auth in
            let feed = try await auth.preparePreview(.init(feed: .init(format: .rss, title: "Private", episodes: [.init(identifier: "retained", title: "Retained episode")]), source: server.url.absoluteString, responseURL: server.url, validator: "v1", permanentRedirectURL: nil), credentials: bad)
            _ = try await store.subscribePreview(feedID: feed.id)
            try await store.updatePreferences(feedID: feed.id) { $0.keepUpdated = false }
            let episodeID = feed.episodes[0].id
            try await store.updateEpisode(id: episodeID) { $0.userState.isFavorite = true; $0.userState.positionMilliseconds = 4321 }
            let network = DownloadNetworkMonitor(startMonitoring: false)
            network.update(.init(connected: true, metered: false, cellular: false))
            let before = try #require(try await store.feed(id: feed.id))
            @MainActor func refresh(_ store: FeedLibraryStore, _ auth: FeedAuthentication) async throws {
                let worker = FeedRefreshWorker(store: store, remote: FeedRefreshService(store: store), local: LocalFeedRefreshService(store: store), localDescription: "Local", localAuthor: "Local", network: network, credentials: { try await auth.credentials(feedID: $0) }, options: { _ in .init() }, effects: AuthenticationRefreshEffects())
                let owner = ManualFeedRefreshCoordinator(store: store, worker: worker)
                _ = try await owner.runOnce(feedID: feed.id).value
                try await owner.waitUntilIdle()
                #expect(try await store.manualRefreshRequest() == nil)
            }
            try await refresh(store, auth)
            let failed = try #require(try await store.feed(id: feed.id))
            #expect(failed.lastUpdateFailed && !failed.keepUpdated && failed.episodes == before.episodes)
            #expect(failed.metadata == before.metadata && failed.validator == before.validator)
            let reopened = try FeedLibraryStore(url: file), restored = FeedAuthentication(store: reopened, vault: vault)
            do {
                let log = try #require(try await reopened.logs(feedID: feed.id).first)
                #expect(log.kind == .failure(.unauthorized) && log.detail == "401")
                let details = FeedLogDetails(log: log, feed: failed, text: { $0 })
                #expect(details.technical == "401" && details.fileURL == server.url.absoluteString)
                #expect(try await restored.credentials(feedID: feed.id) == bad)
                try await restored.save(login, feedID: feed.id)
                try await refresh(reopened, restored)
                let recovered = try #require(try await reopened.feed(id: feed.id))
                #expect(!recovered.lastUpdateFailed && !recovered.keepUpdated && recovered.subscriptionState == .subscribed)
                #expect(recovered.title == "Recovered podcast" && recovered.episodes.count == 1)
                #expect(recovered.episodes[0].id == episodeID && recovered.episodes[0].userState.isFavorite && recovered.episodes[0].userState.positionMilliseconds == 4321)
                let history = try await reopened.logs(feedID: feed.id)
                #expect(history.first?.kind == .success)
                #expect(history.contains { $0.kind == .failure(.unauthorized) && $0.detail == "401" })
                try await reopened.close()
            } catch { try? await reopened.close(); throw error }
        }
    }

    @MainActor @Test func reopenedCredentialsReachRealRefreshAndDownloadRequests() async throws {
        let login = credentials, content = Data("authenticated-media-fixture".utf8)
        let server = try await LoopbackHTTPServer.start { request in
            guard request.headers["authorization"] == login.authorization(utf8: true) else {
                return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"fixture\", charset=\"UTF-8\""], body: Data())
            }
            if request.path.hasPrefix("/audio") { return .init(body: content) }
            return .init(body: Data("<rss><channel><title>Authenticated refresh</title></channel></rss>".utf8))
        }
        defer { server.stop() }
        try await fixture { store, file, vault, auth in
            let item = ParsedEpisode(identifier: "private", title: "Private episode", media: .init(url: server.url.deletingLastPathComponent().appendingPathComponent("audio").absoluteString, size: Int64(content.count)))
            let feed = try await auth.preparePreview(.init(feed: .init(format: .rss, title: "Private", episodes: [item]),
                source: server.url.absoluteString, responseURL: server.url, validator: nil, permanentRedirectURL: nil), credentials: login)
            _ = try await store.subscribePreview(feedID: feed.id)
            let reopened = try FeedLibraryStore(url: file), restored = FeedAuthentication(store: reopened, vault: vault)
            let network = DownloadNetworkMonitor(startMonitoring: false)
            network.update(.init(connected: true, metered: false, cellular: false))
            let worker = FeedRefreshWorker(store: reopened, remote: FeedRefreshService(store: reopened),
                local: LocalFeedRefreshService(store: reopened), localDescription: "Local", localAuthor: "Local", network: network,
                credentials: { try await restored.credentials(feedID: $0) }, options: { _ in .init() }, effects: AuthenticationRefreshEffects())
            let request = FeedRefreshRequest(feedID: feed.id, enqueuedAt: Date())
            try await reopened.enqueueManualRefresh(request)
            try await worker.run(request)
            #expect(try await reopened.feed(id: feed.id)?.title == "Authenticated refresh")
            #expect(try await reopened.manualRefreshRequest() == nil)
            let downloads = DownloadCoordinator(store: reopened, directory: file.deletingLastPathComponent().appendingPathComponent("media"),
                network: network, credentials: { episodeID in
                    try await restored.credentials(feedID: reopened.feedID(forEpisode: episodeID))
                })
            do {
                _ = try await downloads.request(episodeID: feed.episodes[0].id)
                let deadline = ContinuousClock.now + .seconds(5)
                while try await reopened.episode(id: feed.episodes[0].id)?.userState.isDownloaded != true, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                let saved = try #require(try await reopened.episode(id: feed.episodes[0].id)?.userState.localFileURL)
                #expect(try Data(contentsOf: URL(filePath: saved)) == content)
                #expect(server.requests.filter { $0.path == "/feed" && $0.headers["authorization"] != nil }.count == 1)
                #expect(server.requests.filter { $0.path == "/audio" && $0.headers["authorization"] != nil }.count == 1)
                await downloads.stop(); try await reopened.close()
            } catch { await downloads.stop(); try? await reopened.close(); throw error }
        }
    }
}

private struct AuthenticationRefreshEffects: FeedRefreshEffects {
    func handle(_ event: FeedRefreshWorker.Event, request: FeedRefreshRequest) async throws { }
}

private final class FeedTestVault: SynchronizationCredentialStore, Sendable {
    private struct State { var values: [UUID: String] = [:]; var failInsert = false; var failRemove = false }
    private let state = Mutex(State())
    var values: [UUID: String] { state.withLock { $0.values } }
    var failInsert: Bool { get { state.withLock { $0.failInsert } } set { state.withLock { $0.failInsert = newValue } } }
    var failRemove: Bool { get { state.withLock { $0.failRemove } } set { state.withLock { $0.failRemove = newValue } } }
    func insert(_ password: String, id: UUID) throws {
        try state.withLock { if $0.failInsert { throw SynchronizationCredentialError.keychain(-1) }; $0.values[id] = password }
    }
    func password(id: UUID) throws -> String {
        try state.withLock { guard let value = $0.values[id] else { throw SynchronizationCredentialError.missing }; return value }
    }
    func remove(id: UUID) throws {
        try state.withLock { if $0.failRemove { throw SynchronizationCredentialError.keychain(-2) }; $0.values[id] = nil }
    }
}
