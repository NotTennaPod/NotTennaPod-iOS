import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor
struct SubscriptionStatisticsLoaderTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var formatter: StatisticsTextFormatter {
        .init(locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!, now: now)
    }
    private func feeds(title: String = "Alpha") -> [LibraryFeed] {
        func episode(_ id: Int64, last: Int64, played: Int64, marked: Bool = false) -> LibraryEpisode {
            var state = EpisodeUserState()
            state.lastPlayedTimeMilliseconds = last
            state.playedDurationMilliseconds = played
            state.playState = marked ? .played : .unplayed
            return LibraryEpisode(id: id, details: ParsedEpisode(media: ParsedMedia(url: "fixture://\(id)",
                size: 10, durationMilliseconds: 60_000)), userState: state)
        }
        var alpha = LibraryFeed(id: 1, source: "fixture://alpha",
            metadata: .init(format: .rss, title: title, imageURL: "fixture://alpha-image"), episodes: [
                episode(1, last: 99, played: 10_500), episode(2, last: 100, played: 20_750),
                episode(3, last: 0, played: 0, marked: true)])
        alpha.customTitle = "Custom \(title)"
        alpha.episodeFilterValues = ["played"] // Display filtering must not remove the other rows.
        var beta = LibraryFeed(id: 2, source: "fixture://beta",
            metadata: .init(format: .rss, title: "Beta", imageURL: "fixture://beta-image"), episodes: [
                episode(4, last: 199, played: 30_750), episode(5, last: 200, played: 40_000),
                episode(6, last: 150, played: 10_000, marked: true)])
        beta.subscriptionState = .archived
        let empty = LibraryFeed(id: 3, source: "fixture://empty", metadata: .init(format: .rss), episodes: [])
        var excluded = alpha; excluded.id = 4; excluded.subscriptionState = .notSubscribed
        return [beta, empty, excluded, alpha]
    }
    private func waitFor(_ count: Int, in gate: SubscriptionReadGate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await gate.count < count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(await gate.count == count)
    }
    private func loaded(_ loader: SubscriptionStatisticsLoader) throws -> SubscriptionStatisticsSnapshot {
        guard case .loaded(let snapshot) = loader.state else {
            Issue.record("Expected loaded state: \(loader.state)")
            throw SubscriptionReadGate.Failure.denied
        }
        return snapshot
    }

    @Test func oneReadSuppliesIndependentTotalsOrderMetadataAndCapturedContext() async throws {
        let gate = SubscriptionReadGate(), loader = SubscriptionStatisticsLoader { try await gate.read() }
        var preferences = StatisticsPeriodPreferences(timeFrom: 100, timeTo: 200)
        let captured = SubscriptionStatisticsRequest(preferences: preferences, formatter: formatter)
        let task = loader.load(preferences: preferences, formatter: formatter)
        try await waitFor(1, in: gate)
        preferences.includeMarkedAsPlayed = true; preferences.timeTo = .max
        await gate.resolve(0, with: .success(feeds()))
        await task.value
        let result = try loaded(loader)
        #expect(result.request == captured)
        #expect(result.rows.map { $0.statistics.feedID } == [2, 1])
        #expect(result.rows.map { $0.statistics.playedSeconds } == [40, 20])
        #expect(result.rows.map(\.title) == ["Beta", "Custom Alpha"])
        #expect(result.rows.map(\.imageURL) == ["fixture://beta-image", "fixture://alpha-image"])
        #expect(result.statistics.feeds.map(\.totalSeconds) == [180, 180])
        #expect(result.statistics.feeds.map(\.episodes) == [3, 3])
        #expect(result.statistics.oldestPlaybackMilliseconds == 99)
        #expect(loader.lastSnapshot == result)
        #expect(await gate.count == 1)
        #expect(await gate.allReadsOffMainThread)
    }

    @Test func defaultMarkedEmptyAndEqualDurationRowsPreserveExistingAggregateSemantics() async throws {
        let fixture = feeds()
        let loader = SubscriptionStatisticsLoader { fixture }
        await loader.load(preferences: .init(), formatter: formatter).value
        #expect(try loaded(loader).rows.map { $0.statistics.playedSeconds } == [80, 31])
        await loader.load(preferences: .init(includeMarkedAsPlayed: true), formatter: formatter).value
        #expect(try loaded(loader).rows.map { $0.statistics.feedID } == [1, 2])
        #expect(try loaded(loader).rows.map { $0.statistics.playedSeconds } == [91, 80])
        // Reversed bounds select no playback but keep eligible rows in ID order.
        await loader.load(preferences: .init(timeFrom: 200, timeTo: 100), formatter: formatter).value
        #expect(try loaded(loader).rows.map { $0.statistics.feedID } == [1, 2])
        #expect(try loaded(loader).rows.map { $0.statistics.playedSeconds } == [0, 0])
        loader.replaceLibrary { [] }
        await loader.load(preferences: .init(), formatter: formatter).value
        let empty = try loaded(loader)
        #expect(empty.rows.isEmpty && empty.statistics.feeds.isEmpty)
        #expect(empty.statistics.oldestPlaybackMilliseconds == 1_800_000_000_000)
    }

    @Test func latestSameLibraryRequestWinsOverDelayedSuccessAndFailure() async throws {
        let gate = SubscriptionReadGate(), loader = SubscriptionStatisticsLoader { try await gate.read() }
        var events: [SubscriptionStatisticsLoader.State] = []
        loader.onChange = { events.append($0) }
        let first = loader.load(preferences: .init(), formatter: formatter); try await waitFor(1, in: gate)
        let second = loader.load(preferences: .init(includeMarkedAsPlayed: true), formatter: formatter)
        try await waitFor(2, in: gate)
        let latestFormatter = StatisticsTextFormatter(locale: Locale(identifier: "ja_JP"),
            timeZone: TimeZone(identifier: "Asia/Tokyo")!, now: now.addingTimeInterval(600))
        let latest = loader.load(preferences: .init(timeFrom: 100, timeTo: 200), formatter: latestFormatter)
        try await waitFor(3, in: gate)
        await gate.resolve(2, with: .success(feeds(title: "Latest"))); await latest.value
        let accepted = try loaded(loader)
        #expect(accepted.request.formatter == latestFormatter)
        #expect(accepted.rows.map(\.title) == ["Beta", "Custom Latest"])
        #expect(accepted.rows.map { $0.statistics.playedSeconds } == [40, 20])
        await gate.resolve(1, with: .failure(SubscriptionReadGate.Failure.denied)); await second.value
        await gate.resolve(0, with: .success(feeds(title: "Stale"))); await first.value
        #expect(loader.state == .loaded(accepted) && loader.lastSnapshot == accepted)
        #expect(events.last == .loaded(accepted))
    }

    @Test func readAndCalculationFailuresPreserveLastSuccessAndRetryUsesNewSnapshot() async throws {
        let gate = SubscriptionReadGate(), loader = SubscriptionStatisticsLoader { try await gate.read() }
        let initial = loader.load(preferences: .init(), formatter: formatter); try await waitFor(1, in: gate)
        await gate.resolve(0, with: .success(feeds())); await initial.value
        let accepted = try loaded(loader)
        let request = SubscriptionStatisticsRequest(preferences: .init(timeFrom: 100, timeTo: 200), formatter: formatter)
        let failed = loader.load(preferences: request.preferences, formatter: formatter); try await waitFor(2, in: gate)
        #expect(loader.lastSnapshot == accepted)
        await gate.resolve(1, with: .failure(SubscriptionReadGate.Failure.denied)); await failed.value
        #expect(loader.state == .failed(request, message: "denied") && loader.lastSnapshot == accepted)
        let invalidFormatter = StatisticsTextFormatter(locale: formatter.locale, timeZone: formatter.timeZone,
            now: Date(timeIntervalSince1970: .infinity))
        let invalid = loader.load(preferences: .init(), formatter: invalidFormatter); try await waitFor(3, in: gate)
        await gate.resolve(2, with: .success(feeds())); await invalid.value
        #expect(loader.state == .failed(.init(preferences: .init(), formatter: invalidFormatter), message: "invalidDate"))
        #expect(loader.lastSnapshot == accepted)
        let retry = loader.load(preferences: request.preferences, formatter: formatter); try await waitFor(4, in: gate)
        await gate.resolve(3, with: .success(feeds(title: "Recovered"))); await retry.value
        #expect(try loaded(loader).rows.map(\.title) == ["Beta", "Custom Recovered"])
        #expect(try loaded(loader).rows.map { $0.statistics.playedSeconds } == [40, 20])
    }

    @Test func replacingLibraryDiscardsPriorSnapshotAndBothKindsOfLateCompletion() async throws {
        let oldGate = SubscriptionReadGate(), newGate = SubscriptionReadGate()
        let loader = SubscriptionStatisticsLoader { try await oldGate.read() }
        let initial = loader.load(preferences: .init(), formatter: formatter); try await waitFor(1, in: oldGate)
        await oldGate.resolve(0, with: .success(feeds())); await initial.value
        let oldSuccess = loader.load(preferences: .init(), formatter: formatter); try await waitFor(2, in: oldGate)
        let oldError = loader.load(preferences: .init(), formatter: formatter); try await waitFor(3, in: oldGate)
        loader.replaceLibrary { try await newGate.read() }
        #expect(loader.lastSnapshot == nil && loader.state == .idle)
        let current = loader.load(preferences: .init(), formatter: formatter); try await waitFor(1, in: newGate)
        // New identity reuses IDs; stale metadata must not leak just because IDs match.
        var replacement = feeds(title: "Other library"); replacement.removeAll { $0.id != 1 }
        await newGate.resolve(0, with: .success(replacement)); await current.value
        let accepted = try loaded(loader)
        #expect(accepted.rows.map(\.title) == ["Custom Other library"])
        #expect(accepted.rows.map { $0.statistics.playedSeconds } == [31])
        await oldGate.resolve(1, with: .success(feeds())); await oldSuccess.value
        await oldGate.resolve(2, with: .failure(SubscriptionReadGate.Failure.denied)); await oldError.value
        #expect(loader.state == .loaded(accepted) && loader.lastSnapshot == accepted)
    }

    @Test func realStoreReadsCompleteUnfilteredMetadataAndClosedLibraryFailureKeepsPriorValue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SubscriptionLoader-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let source = "https://fixture.invalid/alpha"
        let parsed = ParsedFeed(format: .rss, title: "Stored", imageURL: "fixture://stored-cover", episodes: [
            ParsedEpisode(identifier: "1", media: ParsedMedia(url: "fixture://media", size: 10, durationMilliseconds: 60_000))])
        let feed = try await store.insert(FetchedFeed(feed: parsed, source: source,
            responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil))
        let episode = try #require(feed.episodes.first)
        try await store.updateEpisode(id: episode.id) {
            $0.userState.lastPlayedTimeMilliseconds = 100; $0.userState.playedDurationMilliseconds = 20_750
        }
        try await store.updatePreferences(feedID: feed.id) { $0.customTitle = "Stored custom"; $0.subscriptionState = .archived }
        try await store.setEpisodeFilter(feedID: feed.id, filter: .init(values: ["played"]))
        let loader = SubscriptionStatisticsLoader(store: store)
        await loader.load(preferences: .init(timeFrom: 100, timeTo: 200), formatter: formatter).value
        let accepted = try loaded(loader)
        #expect(accepted.rows.map(\.title) == ["Stored custom"])
        #expect(accepted.rows.map(\.imageURL) == ["fixture://stored-cover"])
        #expect(accepted.rows.map { $0.statistics.playedSeconds } == [20])
        #expect(accepted.rows.map { $0.statistics.episodes } == [1])
        try await store.close()
        await loader.load(preferences: .init(), formatter: formatter).value
        guard case .failed = loader.state else { Issue.record("Closed database must fail"); return }
        #expect(loader.lastSnapshot == accepted)
        let emptyStore = try FeedLibraryStore(url: directory.appendingPathComponent("other.sqlite"))
        loader.replaceLibrary(store: emptyStore)
        #expect(loader.lastSnapshot == nil)
        await loader.load(preferences: .init(), formatter: formatter).value
        #expect(try loaded(loader).rows.isEmpty)
        try await emptyStore.close()
    }
}

/// Deliberately ignores cancellation until the test supplies a completion, as
/// a database or provider operation may do. No wall-clock ordering oracle.
private actor SubscriptionReadGate {
    enum Failure: Error { case denied }
    private var pending: [Int: CheckedContinuation<[LibraryFeed], any Error>] = [:]
    private(set) var count = 0
    private(set) var cancelledCompletions = 0
    private(set) var allReadsOffMainThread = true
    private func offMainThread() -> Bool { !Thread.isMainThread }
    func read() async throws -> [LibraryFeed] {
        let index = count; count += 1
        allReadsOffMainThread = allReadsOffMainThread && offMainThread()
        defer { if Task.isCancelled { cancelledCompletions += 1 } }
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func resolve(_ index: Int, with result: Result<[LibraryFeed], any Error>) {
        pending.removeValue(forKey: index)?.resume(with: result)
    }
}
