import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.timeLimit(.minutes(1))) @MainActor
struct EpisodeChapterPresentationTests {
    private let chapters = [ParsedChapter(startMilliseconds: 1_000, title: "One"),
                            ParsedChapter(startMilliseconds: 20_000, title: "Two"),
                            ParsedChapter(startMilliseconds: 40_000, title: "Three")]
    private actor Loads {
        var calls: [(Int64, Bool)] = []
        var pending: [Int: CheckedContinuation<[ParsedChapter], any Error>] = [:]
        var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
        func read(_ episode: LibraryEpisode, _ force: Bool) async throws -> [ParsedChapter] {
            let index = calls.count; calls.append((episode.id, force))
            return try await withCheckedThrowingContinuation { continuation in
                pending[index] = continuation
                let ready = waiters.filter { $0.0 <= index }
                waiters.removeAll { $0.0 <= index }
                for (_, waiter) in ready { waiter.resume() }
            }
        }
        func started(_ index: Int) async {
            if calls.count <= index { await withCheckedContinuation { waiters.append((index, $0)) } }
        }
        func finish(_ index: Int, _ chapters: [ParsedChapter]) { pending.removeValue(forKey: index)?.resume(returning: chapters) }
        func fail(_ index: Int) { pending.removeValue(forKey: index)?.resume(throwing: URLError(.timedOut)) }
    }
    private func withStore(_ body: (FeedLibraryStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChapterPresentation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let feed = URL(string: "https://example.invalid/feed")!
        var episode = ParsedEpisode(identifier: "one", title: "One",
            media: .init(url: "https://example.invalid/one.mp3", size: 12, durationMilliseconds: 60_000))
        episode.chapters = chapters; episode.chapterURL = "https://example.invalid/chapters.json"
        var second = episode; second.identifier = "two"; second.title = "Two"
        second.chapters = nil; second.chapterURL = nil
        _ = try await store.insert(.init(feed: .init(format: .rss, episodes: [episode, second]), source: feed.absoluteString,
            responseURL: feed, validator: nil, permanentRedirectURL: nil))
        do { try await body(store); try await store.close() }
        catch { try? await store.close(); throw error }
    }

    @Test func successfulReloadSignalsFocusResetButTicksFailuresAndRetiredLoadsDoNot() async throws {
        try await withStore { store in
            let gate = Loads(), owner = EpisodeChapterPresentation(surface:.dialog,store:store) { try await gate.read($0,$1) }
            var reloads = 0
            owner.onReloaded = {
                #expect(!owner.isLoading && owner.chapters == chapters)
                reloads += 1
            }
            defer { owner.onReloaded = nil; owner.stop() }
            owner.reload(episodeID:1); await gate.started(0)
            #expect(reloads == 0)
            await gate.finish(0,chapters); await owner.awaitLoading()
            #expect(reloads == 1)
            owner.updatePosition(25_000)
            #expect(reloads == 1 && owner.selectedIndex == 1)
            owner.reload(episodeID:1); await gate.started(1)
            await gate.finish(1,chapters); await owner.awaitLoading()
            #expect(reloads == 2)
            owner.reload(episodeID:1); await gate.started(2)
            await gate.fail(2); await owner.awaitLoading()
            #expect(reloads == 2)
            owner.reload(episodeID:1); await gate.started(3)
            let retired = owner.request
            owner.stop(); await gate.finish(3,chapters); await retired?.value
            #expect(reloads == 2)
        }
    }

    @Test func storedFlagShowsCoverControlWithoutPretendingXMLIsAlreadyLoaded() async throws {
        try await withStore { store in
            let gate = Loads(), owner = EpisodeChapterPresentation(surface: .cover, store: store) { try await gate.read($0, $1) }
            owner.reload(episodeID: 1); await gate.started(0)
            #expect(owner.hasChapters && owner.chapters == nil && owner.isLoading && owner.nextVisible)
            #expect(owner.currentChapter == nil && owner.previousTarget(position: 0, speed: 1) == nil)
            await gate.finish(0, []); await owner.awaitLoading()
            #expect(!owner.hasChapters && owner.chapters == [] && !owner.isLoading)
            owner.reload(episodeID: 2); await gate.started(1)
            #expect(!owner.hasChapters && owner.chapters == nil)
            await gate.finish(1, chapters); await owner.awaitLoading()
            #expect(owner.hasChapters && owner.chapters == chapters)
        }
    }

    @Test func independentSurfacesKeepLoadedListsUntilTheirOwnReload() async throws {
        try await withStore { store in
            let gate = Loads()
            let cover = EpisodeChapterPresentation(surface: .cover, store: store) { try await gate.read($0, $1) }
            let seek = EpisodeChapterPresentation(surface: .seekbar, store: store) { try await gate.read($0, $1) }
            let dialog = EpisodeChapterPresentation(surface: .dialog, store: store) { try await gate.read($0, $1) }
            for (index, owner) in [cover, seek, dialog].enumerated() {
                owner.reload(episodeID: 1); await gate.started(index)
                await gate.finish(index, chapters); await owner.awaitLoading()
            }
            dialog.reload(episodeID: 1, forceRefresh: true); await gate.started(3)
            #expect(dialog.chapters == chapters && dialog.isLoading && dialog.showsProgress)
            let refreshed = [ParsedChapter(startMilliseconds: 0, title: "Changed")]
            await gate.finish(3, refreshed); await dialog.awaitLoading()
            #expect(dialog.chapters == refreshed && !dialog.showsProgress && cover.chapters == chapters && seek.chapters == chapters)
            let calls = await gate.calls
            #expect(calls.map(\.1) == [false, false, false, true])
            cover.reload(episodeID: 1); await gate.started(4)
            #expect(cover.chapters == nil && cover.hasChapters)
            await gate.finish(4, refreshed); await cover.awaitLoading()
            #expect(cover.chapters == refreshed && seek.chapters == chapters)
            dialog.reload(episodeID: 2); await gate.started(5)
            // Status reload retains the old adapter until the new media arrives.
            // Its captured episode ID lets PlaybackCoordinator reject old actions.
            #expect(dialog.episode?.id == 1 && dialog.chapters == refreshed && !dialog.showsProgress)
            await gate.finish(5, chapters); await dialog.awaitLoading()
            #expect(dialog.episode?.id == 2 && dialog.chapters == chapters)
        }
    }

    @Test(arguments: [EpisodeChapterPresentation.Surface.cover, .seekbar, .dialog])
    func selectionTicksDoNotReloadAndBeforeFirstUsesSurfacePolicy(surface: EpisodeChapterPresentation.Surface) async throws {
        try await withStore { store in
            let gate = Loads(), owner = EpisodeChapterPresentation(surface: surface, store: store) { try await gate.read($0, $1) }
            owner.reload(episodeID: 1); await gate.started(0)
            await gate.finish(0, chapters); await owner.awaitLoading()
            #expect(owner.selectedIndex == -1)
            owner.updatePosition(20_000)
            #expect(owner.selectedIndex == 1)
            owner.updatePosition(0)
            #expect(owner.selectedIndex == (surface == .seekbar ? -1 : 1) && owner.positionMilliseconds == 0)
            #expect(await gate.calls.count == 1)
        }
    }

    @Test func coverTargetsRetainStrictSpeedThresholdAndStoredDurationClamp() async throws {
        try await withStore { store in
            let owner = EpisodeChapterPresentation(surface: .cover, store: store) { _, _ in chapters }
            owner.reload(episodeID: 1); await owner.awaitLoading()
            owner.updatePosition(20_000)
            #expect(owner.previousTarget(position: 35_000, speed: 1.5) == 20_000)
            #expect(owner.previousTarget(position: 34_999, speed: 1.5) == 1_000)
            #expect(owner.selectedIndex == 0 && owner.previousTarget(position: 0, speed: 1) == 0)
            #expect(owner.nextTarget() == 20_000 && owner.nextTarget() == 40_000)
            #expect(!owner.canSeekNext && !owner.nextVisible && owner.nextTarget() == nil)
            try await store.updateEpisode(id: 1) { $0.userState.positionMilliseconds = 70_000 }
            owner.reload(episodeID: 1); await owner.awaitLoading()
            #expect(owner.selectedIndex == 2)
            // Cover uses its loaded media position when refreshing the index.
            #expect(owner.previousTarget(position: 40_000, speed: 1) == 40_000)
            #expect(owner.selectedIndex == 2)
        }
    }

    @Test func stopAndReplacementRejectLateCompletionsAndMissingSelectionClears() async throws {
        try await withStore { store in
            let gate = Loads(), owner = EpisodeChapterPresentation(surface: .dialog, store: store) { try await gate.read($0, $1) }
            var changes = 0, empties = 0
            owner.onChange = { changes += 1 }; owner.onEmpty = { empties += 1 }
            owner.reload(episodeID: 1); await gate.started(0)
            let original = owner.request
            owner.reload(episodeID: 2); await gate.started(1)
            await gate.finish(1, chapters); await owner.awaitLoading()
            let count = changes
            await gate.finish(0, [])
            await original?.value
            #expect(owner.episode?.id == 2 && owner.chapters == chapters && empties == 0)
            owner.reload(episodeID: 2); await gate.started(2)
            let interrupted = owner.request
            owner.stop(); let stopped = changes
            await gate.finish(2, [])
            await interrupted?.value
            #expect(changes == stopped && changes >= count && !owner.isLoading && empties == 0)
            owner.reload(episodeID: nil)
            #expect(owner.episode == nil && owner.chapters == nil && owner.selectedIndex == -1)
            owner.reload(episodeID: 999); await owner.awaitLoading()
            #expect(owner.episode == nil && !owner.isLoading && empties == 0)
        }
    }

    @Test func emptyDismissalAndInterruptedRetryRemainDistinct() async throws {
        try await withStore { store in
            let gate = Loads(), owner = EpisodeChapterPresentation(surface: .dialog, store: store) { try await gate.read($0, $1) }
            var empties = 0, failures = 0
            owner.onEmpty = { empties += 1 }; owner.onFailure = { _ in failures += 1 }
            owner.reload(episodeID: 1); await gate.started(0)
            await gate.fail(0); await owner.awaitLoading()
            #expect(owner.chapters == nil && empties == 0 && failures == 1)
            owner.reload(episodeID: 1); await gate.started(1)
            await gate.finish(1, chapters); await owner.awaitLoading()
            #expect(owner.canRefresh && owner.rowTarget(at: 1) == 20_000 && owner.rowProgressPosition == 20_000)
            owner.updatePosition(25_000)
            #expect(owner.rowTarget(at: 1) == 20_000 && owner.rowProgressPosition == 25_000)
            #expect(owner.rowTarget(at: -1) == nil && owner.rowTarget(at: 3) == nil)
            owner.reload(episodeID: 1, forceRefresh: true); await gate.started(2)
            await gate.fail(2); await owner.awaitLoading()
            #expect(owner.chapters == nil && owner.canRefresh && owner.selectedIndex == -1 && empties == 0)
            owner.reload(episodeID: 1, forceRefresh: true); await gate.started(3)
            await gate.finish(3, []); await owner.awaitLoading()
            #expect(owner.chapters == [] && empties == 1 && failures == 2)
        }
    }

    @Test func seekbarProjectsLoadedAndTickPositionsButDialogStartsRowAtChapterBoundary() async throws {
        try await withStore { store in
            try await store.updateEpisode(id: 1) { $0.userState.positionMilliseconds = 25_000 }
            let seek = EpisodeChapterPresentation(surface: .seekbar, store: store, displayPosition: { $0 / 2 }) { _, _ in chapters }
            seek.reload(episodeID: 1); await seek.awaitLoading()
            #expect(seek.positionMilliseconds == 12_500 && seek.selectedIndex == 0)
            seek.updatePosition(40_000)
            #expect(seek.positionMilliseconds == 20_000 && seek.selectedIndex == 1)
            let gate = Loads(), dialog = EpisodeChapterPresentation(surface: .dialog, store: store) { try await gate.read($0, $1) }
            #expect(dialog.showsProgress)
            dialog.reload(episodeID: 1); await gate.started(0)
            await gate.finish(0, chapters); await dialog.awaitLoading()
            #expect(dialog.selectedIndex == 1 && dialog.highlightedIndex == 1 && dialog.rowProgressPosition == 20_000)
            dialog.updatePosition(25_000)
            #expect(dialog.rowProgressPosition == 25_000)
            dialog.reload(episodeID: 1); await gate.started(1)
            #expect(dialog.isLoading && !dialog.showsProgress)
            let later = [ParsedChapter(startMilliseconds: 30_000, title: "Later"), ParsedChapter(startMilliseconds: 40_000, title: "Last")]
            await gate.finish(1, later); await dialog.awaitLoading()
            // Source resets focusedChapter, but setMedia retains adapter state.
            #expect(dialog.selectedIndex == -1 && dialog.highlightedIndex == 1 && dialog.rowProgressPosition == 25_000)
        }
    }
}
