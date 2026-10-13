#if DEBUG
import Foundation
import NotTennaPodCore

/// Explicit controlled persisted state, not a normal-user creation journey:
/// ordinary downloading and playback clear NEW. Only a UUID-isolated test
/// library may request this fixture. Visible list controls perform the action.
struct ListInboxActionFixture: Codable, Sendable {
    let root: URL
    let feedID: Int64
    let targetID: Int64
    let survivorID: Int64

    @MainActor static func prepare(root: URL, store: FeedLibraryStore, preferences: DownloadPreferenceStore) async throws -> Self {
        let manifest = root.appendingPathComponent("fixture.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            let saved = try JSONDecoder().decode(Self.self, from: Data(contentsOf: manifest))
            guard saved.root == root else { throw CocoaError(.fileReadCorruptFile) }
            return saved // Relaunch must not restore files, NEW flags or settings.
        }
        guard !FileManager.default.fileExists(atPath: root.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = waveData()
        let feed = try await store.insert(try await fetchedFeed(mediaSize: bytes.count))
        guard let target = feed.episodes.first(where: { $0.details.identifier == "target" }),
              let survivor = feed.episodes.first(where: { $0.details.identifier == "survivor" }) else { throw CocoaError(.fileReadCorruptFile) }
        _ = try await store.enqueue([target.id, survivor.id])
        try await store.updatePreferences(feedID: feed.id) { $0.autoDelete = .never }
        for (id, name, position) in [(target.id, "target.wav", Int32(90_000)), (survivor.id, "survivor.wav", Int32(12_345))] {
            let file = root.appendingPathComponent(name)
            try bytes.write(to: file, options: .atomic)
            let metadata = try LocalMediaMetadataReader.read(url: file)
            guard metadata.durationMilliseconds == 120_000, metadata.embeddedArtwork == nil else { throw CocoaError(.fileReadCorruptFile) }
            try await store.updateEpisode(id: id) {
                $0.userState.playState = .new; $0.userState.positionMilliseconds = position
                $0.userState.isFavorite = true; $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path
                $0.details.media?.hasEmbeddedPicture = false
            }
        }
        var value = preferences.value
        value.autoDelete = true; value.autoDeleteLocal = false; value.favoriteKeepsEpisode = true
        value.smartMarkAsPlayedSeconds = 30; value.deleteRemovesFromQueue = false
        try preferences.update(value)
        let result = Self(root: root, feedID: feed.id, targetID: target.id, survivorID: survivor.id)
        try JSONEncoder().encode(result).write(to: manifest, options: .atomic)
        return result
    }

    /// Use the public feed boundary; parsed models intentionally do not expose
    /// their memberwise constructors to the app. No network request is made.
    static func fetchedFeed(mediaSize: Int) async throws -> FetchedFeed {
        let source = "https://example.invalid/controlled-list-inbox"
        let xml = """
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
        <title>Controlled inbox cleanup</title>
        <item><guid isPermaLink="false">target</guid><title>Inbox cleanup target</title>
        <enclosure url="\(source)/target.wav" length="\(mediaSize)" type="audio/wav"/><itunes:duration>120</itunes:duration></item>
        <item><guid isPermaLink="false">survivor</guid><title>Inbox cleanup survivor</title>
        <enclosure url="\(source)/survivor.wav" length="\(mediaSize)" type="audio/wav"/><itunes:duration>120</itunes:duration></item>
        </channel></rss>
        """
        let transport = FixtureFeedTransport(url: URL(string: source)!, body: Data(xml.utf8))
        let result = try await FeedFetcher(transport: transport).fetch(.init(source: source, generateMissingArtwork: false))
        guard case .updated(let fetched) = result else { throw CocoaError(.fileReadCorruptFile) }
        return fetched
    }

    private struct FixtureFeedTransport: FeedHTTPTransport {
        let url: URL
        let body: Data
        func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
            guard request.url == url else { throw URLError(.badURL) }
            return FeedHTTPResponse(url: url, status: 200,
                headers: ["Content-Type": "application/rss+xml", "Content-Length": String(body.count)], body: body)
        }
    }

    static func waveData() -> Data {
        let sampleRate: UInt32 = 8_000, frames = sampleRate * 120
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); word(UInt32(36) + frames * 2)
        data.append(contentsOf: "WAVEfmt ".utf8); word(UInt32(16)); word(UInt16(1)); word(UInt16(1))
        word(sampleRate); word(sampleRate * 2); word(UInt16(2)); word(UInt16(16))
        data.append(contentsOf: "data".utf8); word(frames * 2); data.append(Data(count: Int(frames * 2)))
        return data
    }
}
#endif
