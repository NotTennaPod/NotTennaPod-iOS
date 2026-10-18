#if DEBUG
import Foundation
import CryptoKit
import NotTennaPodCore

/// Opt-in UUID isolation survives a real Files-driven cold launch. The runner
/// must remove this one marker during cleanup; unrelated explicit test libraries
/// never consume it. No fixture is enabled in Release.
@MainActor enum OPMLJourneyFixture {
    private struct Configuration: Codable { let library: UUID; let mode: String }
    private static var marker: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("opml-journey-active.json")
    }
    static func arguments(_ supplied: [String]) -> [String] {
        guard let marker else { return supplied }
        if supplied.contains("-test-opml-journey-clear") { try? FileManager.default.removeItem(at: marker); return supplied }
        if let index = supplied.firstIndex(of: "-test-library-id"), index + 1 < supplied.count {
            guard let id = UUID(uuidString: supplied[index + 1]),
                  let modeIndex = supplied.firstIndex(of: "-test-opml-journey-mode"), modeIndex + 1 < supplied.count,
                  ["ordinary", "hold-until-close", "fail-second-once", "refresh-lifecycle", "remove-source"].contains(supplied[modeIndex + 1]) else { return supplied }
            try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(Configuration(library: id, mode: supplied[modeIndex + 1])).write(to: marker, options: .atomic)
            return supplied
        }
        guard let bytes = try? Data(contentsOf: marker), let configuration = try? JSONDecoder().decode(Configuration.self, from: bytes) else { return supplied }
        return supplied + ["-test-library-id", configuration.library.uuidString, "-test-opml-journey-mode", configuration.mode, "-test-muted-playback"]
    }
    static func session(store: FeedLibraryStore, refresh: @escaping @MainActor () async throws -> Void) -> OPMLImportSession? {
        let args = arguments(ProcessInfo.processInfo.arguments)
        guard let modeIndex = args.firstIndex(of: "-test-opml-journey-mode"), modeIndex + 1 < args.count,
              let idIndex = args.firstIndex(of: "-test-library-id"), idIndex + 1 < args.count,
              let id = UUID(uuidString: args[idIndex + 1]), let marker else { return nil }
        let gate = CommitGate(mode: args[modeIndex + 1], journal: marker.deletingLastPathComponent()
            .appendingPathComponent("UITests-" + id.uuidString).appendingPathComponent("opml-journey-events.json"))
        let session = OPMLImportSession(read: { url in
            if gate.mode == "refresh-lifecycle" { try await gate.prepareRetainedLibrary(store: store, library: id) }
            let bytes = try await OPMLDocumentReader().read(url)
            if gate.mode == "remove-source" {
                // The import must work from what was read, even once the picked file is gone.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try FileManager.default.removeItem(at: url)
            }
            await gate.record("read-snapshot")
            await gate.record("read-sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            return bytes
        }, commit: { entry in
            try await gate.beforeCommit()
            let result = try await store.importOPMLEntry(entry)
            await gate.record("committed:\(result.id)")
            return result.id
        }, refresh: { try await refresh(); gate.record("refresh-enqueued") })
        gate.session = session
        return session
    }
    private struct SeedTransport: FeedHTTPTransport {
        let body: Data
        func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
            guard let url = request.url else { throw URLError(.badURL) }
            return .init(url: url, status: 200, headers: ["Content-Type": "application/rss+xml"], body: body)
        }
    }
    @MainActor private final class CommitGate {
        weak var session: OPMLImportSession?
        let mode: String, journal: URL
        var attempts = 0, events: [String] = []
        init(mode: String, journal: URL) { self.mode = mode; self.journal = journal }
        func record(_ value: String) {
            events.append(value)
            try? JSONEncoder().encode(events).write(to: journal, options: .atomic)
        }
        func prepareRetainedLibrary(store: FeedLibraryStore, library: UUID) async throws {
            // Seed through public store operations before selection, only in this explicit mode.
            // The independent observer captures this pre-import state before confirmation.
            guard try await store.feeds().isEmpty else { return }
            let base = "http://127.0.0.1:18771/" + library.uuidString
            for (name, state) in [("global", FeedSubscriptionState.subscribed),
                                  ("archived", .archived), ("preview", .notSubscribed)] {
                let source = base + "/" + name + ".xml"
                let xml = """
                <rss version="2.0"><channel><title>Before \(name)</title>
                <item><guid isPermaLink="false">retained-\(name)</guid><title>Retained \(name)</title>
                <enclosure url="\(base)/\(name).mp3" length="4" type="audio/mpeg"/></item></channel></rss>
                """
                let result = try await FeedFetcher(transport: SeedTransport(body: Data(xml.utf8)))
                    .fetch(.init(source: source, generateMissingArtwork: false))
                guard case .updated(let fetched) = result else { throw CocoaError(.fileReadCorruptFile) }
                let feed = try await store.insert(fetched, subscriptionState: state)
                try await store.updatePreferences(feedID: feed.id) {
                    $0.customTitle = "Custom " + name; $0.skip = .init(introSeconds: 12, endingSeconds: 7)
                }
                let file = journal.deletingLastPathComponent().appendingPathComponent("retained-" + name + ".mp3")
                try Data([1, 3, 5, 7]).write(to: file)
                try await store.updateEpisode(id: feed.episodes[0].id) {
                    $0.userState.isFavorite = true; $0.userState.positionMilliseconds = 12000
                    $0.userState.localFileURL = file.absoluteString; $0.userState.isDownloaded = true
                }
                if name == "global" { _ = try await store.enqueue([feed.episodes[0].id]) }
            }
            record("retained-library-ready")
        }
        func beforeCommit() async throws {
            attempts += 1; record("attempt:\(attempts)")
            if mode == "fail-second-once", attempts == 2 {
                record("injected-write-error"); throw CocoaError(.fileWriteUnknown)
            }
            if mode == "hold-until-close", attempts == 1 {
                record("waiting-for-close")
                let deadline = ContinuousClock.now + .seconds(20)
                while session?.isPresented == true, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard session?.isPresented == false else { throw CocoaError(.userCancelled) }
                record("closed-before-write")
            }
        }
    }
}
#endif
