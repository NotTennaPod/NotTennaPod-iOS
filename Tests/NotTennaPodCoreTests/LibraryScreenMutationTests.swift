import Foundation
import Testing
@testable import NotTennaPodCore

#if DEBUG
/// Each mutation of the incremental screen model, switched on by its test-only fault, is caught by its deterministic
/// witness (the witness records an issue: a semantic mismatch, not a crash).
@Suite(.serialized) struct LibraryScreenMutationTests {
    func caught(_ fault: ScreenModelFault, _ witness: () async throws -> Void) async {
        screenModelFaults = [fault]
        defer { screenModelFaults = [] }
        await withKnownIssue("\(fault) is caught") { try await witness() }
    }

    @MainActor func caught(_ fault: LibraryScreenUpdater.Fault, _ witness: (LibraryScreenUpdaterTests) async throws -> Void) async {
        var tests = LibraryScreenUpdaterTests()
        tests.faults = [fault]
        await withKnownIssue("\(fault) is caught") { try await witness(tests) }
    }

    @Test func listOrderMutationsAreCaught() async {
        let tests = EpisodeListIndexTests()
        await caught(.tieByEpisodeOnly) { tests.episodesTieByPodcastThenEpisode() }
        await caught(.nullsLast) { tests.missingValuesSortAsSQLiteNull() }
        await caught(.removeByNewKey) { tests.aRekeyedMemberLeavesItsOldPlace() }
        await caught(.equalKeyAfter) { tests.anEqualKeyInsertsOnItsIDSide() }
    }

    /// Counters kept from the counts table, not from the window: a count that is not kept differs from the full read.
    @Test func countsNotKeptAreCaught() async {
        await caught(.countsNotKept) {
            let world = try await LibraryScreenModelEquivalenceTests.World.make(server: false, seed: 5, feeds: 3, episodesPerFeed: 20)
            // A played mark changes its podcast's counts (played, unplayed).
            let target = try #require(world.mirror.feeds.first?.episodes.first { $0.userState.playState != .played }).id
            try await world.store.markEpisodePlayed(episodeID: target, played: true)
            try await world.patch()
            try await world.check("counts")
            #expect(world.problems.isEmpty, "\(world.problems)")
            await world.close()
        }
    }

    /// A podcast the server removed while the player holds one of its episodes (held-detach) and subscribed again enters
    /// the lists in a feed of its own; patched as a header change only, it would be missing.
    @Test func aFeedResetIgnoredIsCaught() async {
        await caught(.feedResetIgnored) {
            let world = try await LibraryScreenModelEquivalenceTests.World.make(server: true, seed: 9, feeds: 2, episodesPerFeed: 10)
            try await world.step(.heldRemoval)
            try await world.patch()
            // Subscribed again: the reopened podcast enters the lists with its episodes, which only a reset reads.
            try await world.step(.reAdd)
            try await world.patch()
            try await world.check("subscribed again")
            #expect(world.problems.isEmpty, "\(world.problems)")
            await world.close()
        }
    }

    @MainActor @Test func updaterMutationsAreCaught() async {
        await caught(.applyMixedReads) { try await $0.aReadAheadOfDeliveryIsReadAgain() }
        await caught(.dropDuringOpen) { try await $0.setsBeforeTheOpenAreCoveredAndLaterOnesPatched() }
        await caught(.settleEarly) { try await $0.settleWaitsForTheReceipt() }
        await caught(.paceLocal) { try await $0.syncSetsArePacedAndLocalSetsAreNot() }
    }
}
#endif
