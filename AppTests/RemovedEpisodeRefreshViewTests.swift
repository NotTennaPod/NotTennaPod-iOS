import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Run alone with the scheme's UUID-isolated, muted test host. This deliberately
/// uses the application's selected service graph and scene, not replacement
/// refresh/deletion/playback owners assembled in the test.
@MainActor @Suite(.serialized)
struct RemovedEpisodeRefreshViewTests {
    private func element<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if let found = view as? T, found.accessibilityIdentifier == id { return found }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: T.self) }.first
    }
    private func tap(_ id: String, in controller: UIViewController) throws {
        let control: UIControl = try #require(element(id, in: controller.view))
        control.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
    }
    private func wait(_ condition: @MainActor () async throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let end = ContinuousClock.now + .seconds(20)
        while try await !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await condition(), sourceLocation: sourceLocation)
    }

    @Test func selectedApplicationRefreshRetiresPausedMediaAcknowledgesAndPreservesMovedDocument() async throws {
        let arguments = ProcessInfo.processInfo.arguments
        let index = try #require(arguments.firstIndex(of: "-test-library-id"))
        try #require(index + 1 < arguments.count)
        let identifier = try #require(UUID(uuidString: arguments[index + 1]))
        try #require(arguments.contains("-test-muted-playback"))
        let app = try #require(UIApplication.shared.delegate as? AppDelegate)
        try #require(app.startupError == nil)
        let store = try #require(app.library), playback = try #require(app.playback)
        let refresh = try #require(app.manualRefresh), deletion = try #require(app.feedDeletion)
        try #require(playback.episode == nil, "Use an isolated host with no selected media")
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("UITests-" + identifier.uuidString)
        let root = directory.appendingPathComponent("removal-component-" + UUID().uuidString)
        let fixture = try await RemovedEpisodeRefreshFixture.prepare(root: root, store: store)
        do {
            try await wait {
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows).contains { $0.rootViewController is LibraryViewController && !$0.isHidden }
            }
            let controller = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).filter { !$0.isHidden }
                .compactMap { $0.rootViewController as? LibraryViewController }.first)
            await controller.openNotification(.feed(fixture.feedID))
            controller.view.layoutIfNeeded()
            try #require(element("episode-\(fixture.removedID)", in: controller.view, as: UIControl.self) != nil)
            try #require(element("episode-\(fixture.survivorID)", in: controller.view, as: UIControl.self) != nil)
            try tap("episode-\(fixture.removedID)", in: controller)
            try tap("episodePrimaryAction", in: controller)
            try await wait { playback.episode?.id == fixture.removedID && playback.phase == .playing }
            try tap("miniPlayerPlay", in: controller)
            try await wait { playback.phase == .paused }
            #expect(app.playbackRoutes?.reading != nil)
            #expect(try await store.playbackSelectionEpisodeID() == fixture.removedID)
            #expect(try await store.queue().filter { [fixture.removedID, fixture.survivorID].contains($0.id) }
                .map(\.id) == [fixture.removedID, fixture.survivorID])
            let bytes = try Data(contentsOf: fixture.original)
            try fixture.moveTarget()
            // Moving the provider document itself does not remove library state.
            #expect(try await store.episode(id: fixture.removedID) != nil)
            #expect(playback.episode?.id == fixture.removedID && playback.phase == .paused)
            try tap("toolbarBack", in: controller)
            try tap("feedListMore", in: controller)
            try tap("refreshFeed", in: controller)
            try await wait { try await store.episode(id: fixture.removedID) == nil && playback.episode == nil }
            // Bounded: an unbounded wait turned a stuck refresh into a 120 s suite timeout with no cause shown.
            try? await wait { if case .active = refresh.state { false } else { true } }
            if case .active = refresh.state { Issue.record("Manual refresh still active: \(refresh.state)") }
            #expect(refresh.state == .idle)
            #expect(playback.phase == .idle && playback.sample == nil && !playback.wantsPlayback)
            #expect(app.playbackRoutes?.reading == nil)
            #expect(try await store.playbackSelectionEpisodeID() == nil)
            #expect(try await store.playbackSession() == nil)
            #expect(try await store.feed(id: fixture.feedID)?.episodes.map(\.id) == [fixture.survivorID])
            #expect(try await store.queue().filter { [fixture.removedID, fixture.survivorID].contains($0.id) }
                .map(\.id) == [fixture.survivorID])
            #expect(try await store.pendingEffects().allSatisfy {
                if case .removeEpisodes = $0.effect.kind { return $0.effect.feedID != fixture.feedID }
                return true
            })
            try await wait { self.element("episode-\(fixture.removedID)", in: controller.view, as: UIControl.self) == nil }
            #expect(element("episode-\(fixture.survivorID)", in: controller.view, as: UIControl.self) != nil)
            #expect(try Data(contentsOf: fixture.retained) == bytes)
            #expect(!FileManager.default.fileExists(atPath: fixture.original.path))
            #expect(try Data(contentsOf: fixture.survivor) == bytes)

            let reopened = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
            #expect(try await reopened.episode(id: fixture.removedID) == nil)
            #expect(try await reopened.playbackSelectionEpisodeID() == nil)
            #expect(try await reopened.queue().contains { $0.id == fixture.survivorID })
            #expect(try await reopened.pendingEffects().allSatisfy {
                if case .removeEpisodes = $0.effect.kind { return $0.effect.feedID != fixture.feedID }
                return true
            })
            try await reopened.close()
            // Reopening fixture metadata must never recreate removed media.
            let same = try await RemovedEpisodeRefreshFixture.prepare(root: root, store: store)
            #expect(same.removedID == fixture.removedID)
            #expect(!FileManager.default.fileExists(atPath: fixture.original.path))
            #expect(try await store.episode(id: fixture.removedID) == nil)
            try tap("episode-\(fixture.survivorID)", in: controller)
            try tap("episodePrimaryAction", in: controller)
            try await wait { playback.episode?.id == fixture.survivorID && playback.phase == .playing }
            try tap("miniPlayerPlay", in: controller)
            try await wait { playback.phase == .paused }
            #expect(try await store.playbackSelectionEpisodeID() == fixture.survivorID)
            #expect(try Data(contentsOf: fixture.retained) == bytes)
        } catch {
            try? await deletion.delete(feedID: fixture.feedID).value
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        try await deletion.delete(feedID: fixture.feedID).value
        try FileManager.default.removeItem(at: root)
    }
}
