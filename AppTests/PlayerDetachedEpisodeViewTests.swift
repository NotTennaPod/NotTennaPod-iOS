import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// The player of an episode kept after the server removed its podcast (PROTOCOL §6.8): the episode is cut loose from the
/// account and no list shows its podcast, while the mini and full player still show its title, its podcast's name and the
/// podcast's artwork, offer no podcast or episode action, and keep their place through widths and right-to-left.
@MainActor @Suite(.serialized)
struct PlayerDetachedEpisodeViewTests {
    private func player(in view: UIView) -> PlayerView? {
        (view as? PlayerView) ?? view.subviews.lazy.compactMap { player(in: $0) }.first
    }
    private func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }
    private func find(_ id: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == id { return view }
        return view.subviews.lazy.compactMap { find(id, in: $0) }.first
    }
    private func wait(_ details: @autoclosure () -> String = "", _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "\(details())")
    }

    /// A server library whose podcast the server removed while the player held its first episode (41 s in).
    private nonisolated static func detached(_ root: URL, image: String) async throws -> (store: FeedLibraryStore, feed: LibraryFeed, episode: LibraryEpisode) {
        let url = root.appendingPathComponent("library.sqlite")
        let id = { ContractIdentity.randomUUID() }
        let namespace = id()
        let provisioning = try FeedLibraryStore(url: url)
        try await provisioning.initializeServerLibrary(ServerLibraryIdentity(libraryID: id(), serverURL: "http://127.0.0.1:1", serverID: nil,
                                                                             accountID: id(), namespace: namespace, username: "alice", installID: id(),
                                                                             deviceMarker: nil))
        try await provisioning.close()
        let store = try FeedLibraryStore(url: url)
        let source = "https://example.invalid/removed-feed"
        let feed = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Removed podcast", imageURL: image, episodes: (1...2).map { index in
            ParsedEpisode(identifier: "held-\(index)", title: "Held episode \(index)", publicationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400),
                          media: ParsedMedia(url: "https://example.invalid/held-\(index).mp3", size: 1_000, durationMilliseconds: 600_000))
        }), source: source, responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil))
        let episode = try #require(feed.episodes.first { $0.details.identifier == "held-1" })
        // The registration resolves (the podcast is the account's), and the server has every pending fact.
        let op = try #require(try await store.withDatabaseForTesting { try $0.rows("SELECT op_id FROM ntp_registrations WHERE feed_id = ?", [.integer(feed.id)]).first?.first?.text })
        let podcast = try ContractIdentity.podcastID(namespace: namespace, creatingOpID: op)
        let generation = try ContractIdentity.generationID(namespace: namespace, podcastID: podcast, creatingOpID: op)
        try await store.resolveRegistration(opID: op, .init(podcastID: podcast, generationID: generation, mode: "created", decisionID: nil))
        let log = id()
        try await store.withDatabaseForTesting { database in
            try database.transaction {
                try database.execute("DELETE FROM ntp_overlays")
                try database.execute("DELETE FROM ntp_outbox")
                try database.execute("UPDATE ntp_library SET cursor = ?, log_id = ?, epoch = 1, seq = 0, digest = ? WHERE id = 1",
                                     [.text(try SyncCursor(logID: log, epoch: 1, seq: 0, digest: String(repeating: "0", count: 64)).encoded),
                                      .text(log), .text(String(repeating: "0", count: 64))])
            }
        }
        _ = try await store.beginPlayback(episodeID: episode.id, positionMilliseconds: 41_000)
        let cursor = try SyncCursor(logID: log, epoch: 1, seq: 1, digest: ContractIdentity.sha256Hex(Array("\(log)1".utf8)))
        _ = try await store.applyServerUnit(ServerUnitInput(commit: ServerCommit(epoch: 1, seq: 1, records: [
            ServerRecord(entity: "podcast", id: podcast, fieldGroup: "subscription", value: ["state": "removed", "generation_id": .string(generation)])
        ]), cursor: cursor, watermark: nil, now: 1_760_000_000_000), history: nil, maxWork: nil)
        return (store, feed, episode)
    }

    @Test(arguments: [false, true])
    func theDetachedEpisodesPlayerShowsItsTitlePodcastAndArtwork(rtl: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlayerDetached-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = "https://example.invalid/removed-cover-\(UUID()).png"
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.pngData())
        let previous = EpisodeArtworkView.remoteLoader
        defer { EpisodeArtworkView.remoteLoader = previous }
        EpisodeArtworkView.remoteLoader = { url in (png, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
        let (store, feed, episode) = try await Self.detached(root, image: image)
        do {
            #expect(try await store.feed(id: feed.id) == nil, "no list shows the removed podcast")
            #expect(try await store.feeds().isEmpty)
            let playback = PlaybackCoordinator(store: store, engine: AVPlayerPlaybackEngine(muted: true))
            try await playback.restore()
            #expect(playback.episode?.id == episode.id, "the player holds the episode")
            let preferences = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
            var value = preferences.value; value.defaultPage = NavigationDestination.subscriptions.rawValue
            try preferences.update(value)
            let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: playback,
                timeDisplayPreferences: try TimeDisplayPreferenceStore(file: root.appendingPathComponent("time.json")),
                navigationPreferences: preferences, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
            try await withViewTestWindow { host, window in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                controller.view.frame = host.view.bounds
                controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                await controller.reloadLibrary()?.value
                #expect(find("subscriptionFeed-\(feed.id)", in: controller.view) == nil, "Subscriptions does not show it")
                let player = try #require(player(in: controller.view))
                player.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                @MainActor func texts() -> [String] { views(UILabel.self, in: player).filter { !$0.isHidden }.compactMap { $0.text } }
                try await wait("mini player: \(texts())") { texts().contains("Held episode 1") && texts().contains("Removed podcast") }
                let mini = try #require(find("miniPlayerArtwork", in: player) as? EpisodeArtworkView)
                try await wait("mini artwork: \(mini.displayedSource ?? "none")") { mini.displayedSource == image }
                player.setExpanded(true, animated: false)
                for width in [host.view.bounds.width, min(host.view.bounds.width, 402), min(host.view.bounds.width, 340)] {
                    controller.view.frame.size.width = width
                    controller.view.setNeedsLayout(); controller.view.layoutIfNeeded(); player.layoutIfNeeded()
                    let cover = try #require(find("playerCoverArtwork", in: player) as? EpisodeArtworkView)
                    try await wait("cover: \(cover.displayedSource ?? "none")") { cover.displayedSource == image }
                    let frame = cover.convert(cover.bounds, to: window)
                    #expect(window.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "the cover at width \(width): \(frame)")
                    let podcastLine = try #require(views(UILabel.self, in: player).first { !$0.isHidden && $0.text?.hasPrefix("Removed podcast\u{00a0}・") == true },
                                                   "the full player's podcast line: \(texts())")
                    #expect(window.bounds.contains(podcastLine.convert(podcastLine.bounds, to: window)))
                }
                // No podcast or episode action reaches a podcast no list shows.
                #expect(find("playerShare", in: player).map(\.isHidden) ?? true)
            }
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
}
