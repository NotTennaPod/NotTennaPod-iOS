import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

#if DEBUG

/// The DEBUG hooks the app's hub bridge installs (`ServerDebugHooks`, PROTOCOL §16): the observer
/// hears a recorded fact only after its transaction committed, and every playback save with its durability; the
/// action clock offset moves the fact's `client_time` and nothing the rows keep. The hooks are process-wide, so this
/// suite restores them before it ends.
@Suite(.serialized) struct ServerDebugHooksTests {
    final class Heard: Sendable {
        let exports = Mutex<[ServerDebugHooks.Export]>([])
        let saves = Mutex<[ServerDebugHooks.Save]>([])
        var observer: ServerDebugHooks.Observer {
            .init(crashPoint: { _ in }, saved: { save in self.saves.withLock { $0.append(save) } },
                  exported: { exports in self.exports.withLock { $0 += exports } })
        }
    }

    @Test func exportsAndSavesAreHeardAndTheActionClockMovesOnlyClientTime() async throws {
        let fixture = try await ServerLibraryFixture()
        let heard = Heard()
        ServerDebugHooks.install(heard.observer)
        ServerDebugHooks.setActionClockOffset(milliseconds: 3 * 86_400_000)
        do {
            let (feed, _, _) = try await fixture.subscribeRegistered()
            let episode = try #require(feed.episodes.first).id
            let before = Int64(Date().timeIntervalSince1970 * 1_000)
            try await fixture.store.setFavorite(episodeID: episode, favorite: true)
            let favorite = try #require(try fixture.outbox().first { $0.type == "favorite.set" })
            let reported = heard.exports.withLock { $0 }.first { $0.type == "favorite.set" }
            #expect(reported?.opID == favorite.opID)
            #expect(reported?.installSeq == favorite.installSeq)
            let clientTime = try #require(favorite.json["client_time"]?.integerValue)
            #expect(clientTime >= before + 3 * 86_400_000, "the fact carries the moved action clock")
            #expect(clientTime < before + 3 * 86_400_000 + 600_000)

            let session = try await fixture.store.beginPlayback(episodeID: episode)
            _ = try await fixture.store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 5_000, durationMilliseconds: 600_000, status: .playing))
            _ = try await fixture.store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 7_000, durationMilliseconds: 600_000, status: .paused),
                                                       synchronize: true)
            let saves = heard.saves.withLock { $0 }
            #expect(saves.map(\.positionMilliseconds) == [5_000, 7_000])
            #expect(saves.map(\.durable) == [false, true])
            #expect(saves.allSatisfy { $0.serverLibrary && $0.episodeID == episode })
            let played = try await fixture.store.loadEpisode(episode)?.userState.lastPlayedTimeMilliseconds ?? 0
            #expect(played < before + 600_000, "the row keeps the real clock")
        } catch {
            ServerDebugHooks.install(nil); ServerDebugHooks.setActionClockOffset(milliseconds: 0)
            await fixture.close()
            throw error
        }
        ServerDebugHooks.install(nil); ServerDebugHooks.setActionClockOffset(milliseconds: 0)
        await fixture.close()
    }

    @Test func aRolledBackRecordingIsNeverHeard() async throws {
        let fixture = try await ServerLibraryFixture()
        let heard = Heard()
        ServerDebugHooks.install(heard.observer)
        defer { ServerDebugHooks.install(nil) }
        let (feed, _, _) = try await fixture.subscribeRegistered()
        let episode = try #require(feed.episodes.first).id
        heard.exports.withLock { $0.removeAll() }
        await fixture.store.injectRecorderFailure(after: 1)
        await #expect(throws: (any Error).self) { try await fixture.store.setFavorite(episodeID: episode, favorite: true) }
        #expect(heard.exports.withLock { $0 }.isEmpty)
        await fixture.close()
    }
}
#endif
