import Foundation
import Testing
@testable import NotTennaPodCore

/// Further closures in a retained switch's reconciliation (`FeedLibraryStore.rebase`): a touch on
/// something its plan writes or maps is never dropped for lacking a live mapping, and nothing else defers. The library
/// is `ServerLocalPlaybackTests.library()` (podcast P on feed F, episodes one and two, both queued); the switch is a
/// shadow of a commit moving episode one's position, which writes one's row on F without projecting P or changing
/// anything structurally. These closures are defensive: the product's own local actions that reach their preconditions
/// (a podcast setting, a refresh, a feed deletion) also write the feed and are deferred earlier. Where a precondition
/// cannot be reached otherwise (a podcast overlay changing alone, a mapping gone with no logged write), the test makes
/// it with SQL on the store's connection, which the local-change log records like any write (the mapping tables are
/// not logged).
@Suite(.serialized) struct ServerRebaseDependencyTests {
    typealias Retained = ServerRetainedPublicationTests
    typealias Local = ServerLocalPlaybackTests

    static func position(_ ms: Int64) -> ServerRecord {
        ServerRecord(entity: "episode", id: Local.one, fieldGroup: "position", value: ["generation_id": .string(Local.generation), "position": .integer(ms)])
    }

    /// The shadow of episode one's new position (40 s) and its input; F is the feed it holds.
    static func shadow(_ fixture: ServerLibraryFixture, one: Int64) async throws -> (shadow: ServerShadowBuild, input: ServerUnitInput, feed: Int64) {
        let input = try await Retained.nextInput(fixture, [Self.position(40_000)])
        let shadow = try await Retained.build(fixture, input)
        let feed = try #require(try await fixture.store.feedID(forEpisode: one))
        let scope = shadow.revisions.scope
        #expect(scope.rows.contains(one) && scope.feeds.contains(feed), "it writes one's row on F: \(scope)")
        #expect(!scope.everything && !scope.podcasts.contains(Local.podcast) && scope.structuralFeeds.isEmpty && scope.structural.isEmpty,
                "nothing structural, P not projected: \(scope)")
        return (shadow, input, feed)
    }

    /// Whether the switch is deferred within the publication budget (nothing written then).
    static func deferredWithinTheBudget(_ fixture: ServerLibraryFixture, _ shadow: ServerShadowBuild, _ input: ServerUnitInput) async -> Bool {
        do {
            let result = try await fixture.store.publishServerShadow(shadow, input: input, history: nil, workLimit: 1_000)
            #expect(!result.wholeAtPause)
            return false
        } catch ServerApplyError.deferred {
            return true
        } catch {
            Issue.record("\(error)")
            return false
        }
    }

    static func position(_ store: FeedLibraryStore, _ id: Int64) async throws -> Int32? {
        try await store.episode(id: id)?.userState.positionMilliseconds
    }

    // MARK: - :210-215, a podcast overlay

    /// A podcast-level overlay of P changes alone (P is not projected; its live feed F is). The switch is deferred,
    /// nothing written; the whole publication then applies the commit and keeps the overlay.
    @Test func aPodcastOverlayOnTheHeldFeedsPodcastDefersTheSwitch() async throws {
        let (fixture, _, one, _) = try await Local.library()
        let store = fixture.store
        let (shadow, input, _) = try await Self.shadow(fixture, one: one)
        let before = try await Self.position(store, one)
        let op = ContractIdentity.randomUUID()
        try await store.executeForTesting("INSERT INTO ntp_overlays(op_id, entity, id, property, kind, value, clock) VALUES (?, 'podcast', ?, 'keep_updated', 'register', ?, 1)",
                                          [.text(op), .text(Local.podcast), .blob(Data(try ContractJSON.bool(false).canonicalBytes()))])
        #expect(await Self.deferredWithinTheBudget(fixture, shadow, input), "deferred within the budget")
        #expect(try await Self.position(store, one) == before, "nothing written while deferred")
        let whole = try await store.publishServerShadow(shadow, input: input, history: nil)
        #expect(whole.published && whole.wholeAtPause, "\(whole)")
        #expect(try await Self.position(store, one) == 40_000, "the commit applies")
        #expect(try fixture.rows("SELECT count(*) FROM ntp_overlays WHERE op_id = '\(op)' AND entity = 'podcast'") == [["1"]], "the change is kept")
        await fixture.close()
    }

    // MARK: - :275, an unmapped episode on a feed nothing maps live

    /// Episode two has no wire mapping (a local item) on F; after the build F's live mapping is gone (no logged write)
    /// and two changes. The switch writes rows on F: it is deferred.
    @Test func anUnmappedEpisodeOnAHeldFeedWithoutALiveMappingDefersTheSwitch() async throws {
        let (fixture, _, one, two) = try await Local.library()
        let store = fixture.store
        try await store.executeForTesting("UPDATE ntp_episodes SET local_id = NULL WHERE local_id = ?", [.integer(two)])
        let (shadow, input, feed) = try await Self.shadow(fixture, one: one)
        #expect(!shadow.revisions.scope.rows.contains(two), "it does not write two")
        try await store.executeForTesting("DELETE FROM ntp_podcasts WHERE feed_id = ?", [.integer(feed)])
        try await store.projectForTesting(two) { $0.userState.positionMilliseconds = 77_000 }
        #expect(await Self.deferredWithinTheBudget(fixture, shadow, input), "deferred within the budget")
        #expect(try await Self.position(store, two) == 77_000)
        await fixture.close()
    }

    // MARK: - :267-273, an episode gone since the build

    /// The switch writes episode one's row; after the build that row is deleted and its mapping cleared. The switch is
    /// deferred, and the whole publication does not bring the deleted row back (the server's episode is projected from
    /// the intact rows: a row of its own, never the stale image under the deleted row's ID).
    @Test func anEpisodeTheSwitchWritesDeletedSinceItsBuildDefersIt() async throws {
        let (fixture, _, one, _) = try await Local.library()
        let store = fixture.store
        let (shadow, input, _) = try await Self.shadow(fixture, one: one)
        try await store.executeForTesting("DELETE FROM queue WHERE episode_id = ?", [.integer(one)])
        try await store.executeForTesting("DELETE FROM episodes WHERE id = ?", [.integer(one)])
        try await store.executeForTesting("UPDATE ntp_episodes SET local_id = NULL WHERE local_id = ?", [.integer(one)])
        #expect(await Self.deferredWithinTheBudget(fixture, shadow, input), "deferred within the budget")
        #expect(try await store.episode(id: one) == nil, "nothing written while deferred")
        let whole = try await store.publishServerShadow(shadow, input: input, history: nil)
        #expect(whole.published && whole.wholeAtPause, "\(whole)")
        #expect(try await store.episode(id: one) == nil, "the deleted row is not brought back")
        await fixture.close()
    }

    /// A local-folder episode the switch does not write changes after the build: no dependency, so the switch is not
    /// deferred and the change is kept.
    @Test func aLocalFolderEpisodeTheSwitchDoesNotWriteDoesNotDeferIt() async throws {
        let (fixture, _, one, _) = try await Local.library()
        let store = fixture.store
        let folder = try await store.registerLocalFolder(title: "Folder", directoryIdentity: "folder-1", bookmark: Data([1]))
        let scan = ParsedFeed(format: .rss, title: "Folder", episodes: [
            ParsedEpisode(identifier: "l.mp3", title: "L", publicationDate: ServerLibraryFixture.now, media: ParsedMedia(url: "l.mp3", size: 10))])
        _ = try await store.applyLocalFolderScan(scan, context: folder)
        let local = try #require(try await store.feed(id: folder.feed.id)?.episodes.first?.id)
        let (shadow, input, _) = try await Self.shadow(fixture, one: one)
        try await store.setFavorite(episodeID: local, favorite: true)
        #expect(await !Self.deferredWithinTheBudget(fixture, shadow, input), "published within the budget")
        #expect(try await Self.position(store, one) == 40_000)
        #expect(try await store.episode(id: local)?.userState.isFavorite == true)
        await fixture.close()
    }

    // MARK: - Over-deferral guard

    /// Ordinary local actions after the build on a podcast whose feed the switch does not hold (a favorite, a download
    /// started, a queue edit), and a favorite on the row it writes: the switch is published within the budget, not
    /// deferred, re-projecting that row; every change is kept.
    @Test func ordinaryActionsOnAnotherPodcastStillRebaseWithoutDeferring() async throws {
        let (fixture, _, one, _) = try await Local.library()
        let store = fixture.store
        let other = try await fixture.subscribeRegistered(ServerDiscoveryTests.fetched(ServerDiscoveryTests.base, source: "https://example.test/other.xml"))
        let ids = other.feed.episodes.map(\.id).sorted()
        let (shadow, input, feed) = try await Self.shadow(fixture, one: one)
        #expect(other.feed.id != feed && !shadow.revisions.scope.feeds.contains(other.feed.id))
        try await store.setFavorite(episodeID: ids[0], favorite: true)
        let directory = fixture.directory.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try await store.requestDownload(episodeID: ids[1], directory: directory, enqueue: false)
        _ = try await store.enqueue([ids[2]])
        try await store.setFavorite(episodeID: one, favorite: true)
        let result = try await store.publishServerShadow(shadow, input: input, history: nil, workLimit: 1_000)
        #expect(result.published && !result.wholeAtPause && result.rebased == 1, "\(result)")
        let shown = try #require(try await store.episode(id: one))
        #expect(shown.userState.positionMilliseconds == 40_000 && shown.userState.isFavorite, "\(shown.userState)")
        #expect(try await store.episode(id: ids[0])?.userState.isFavorite == true)
        #expect(try await store.downloadJobs().contains { $0.episodeID == ids[1] })
        #expect(try await store.queue().map(\.id).contains(ids[2]))
        await fixture.close()
    }
}
