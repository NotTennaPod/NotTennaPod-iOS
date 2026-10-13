import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor
struct FeedStatisticsLoaderTests {
    private let clock = Date(timeIntervalSince1970: 1_735_819_200)
    private func snapshot(_ id: Int64) throws -> FeedStatisticsSnapshot {
        try #require(try FeedStatisticsSnapshot(feed: LibraryFeed(id: id, source: "fixture://\(id)",
            metadata: ParsedFeed(format: .rss, title: "Feed \(id)"),
            episodes: [LibraryEpisode(id: id, details: ParsedEpisode(publicationDate: clock))]),
            now: clock, timeZone: TimeZone(secondsFromGMT: 0)!))
    }
    private func waitFor(_ count: Int, in gate: StatisticsReadGate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await gate.count < count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(await gate.count == count)
    }

    @Test func newerRequestOwnsResultAndFormattingContextWhileOldSuccessAndFailureAreDiscarded() async throws {
        let gate = StatisticsReadGate(), loader = FeedStatisticsLoader { id, now, zone in try await gate.read(id, now, zone) }
        var events: [FeedStatisticsLoader.State] = []
        loader.onChange = { events.append($0) }
        let first = loader.load(feedID: 1); try await waitFor(1, in: gate)
        let second = loader.load(feedID: 2); try await waitFor(2, in: gate)
        let formatter = StatisticsTextFormatter(locale: Locale(identifier: "ja-JP"), timeZone: TimeZone(identifier: "Asia/Tokyo")!, now: clock)
        let latest = loader.load(feedID: 1, formatter: formatter); try await waitFor(3, in: gate)
        #expect(await gate.requests.last == .init(id: 1, now: clock, zone: formatter.timeZone))
        let result = try snapshot(1)
        await gate.resolve(2, with: .success(result)); await latest.value
        #expect(loader.state == .loaded(result, formatter))
        await gate.resolve(1, with: .failure(StatisticsReadGate.Failure.denied)); await second.value
        await gate.resolve(0, with: .success(try snapshot(1))); await first.value
        #expect(loader.state == .loaded(result, formatter))
        #expect(events == [.loading(feedID: 1), .loading(feedID: 2), .loading(feedID: 1), .loaded(result, formatter)])
        #expect(await gate.cancelledCompletions == 2)
    }

    @Test func missingCurrentErrorsAndMismatchedFeedNeverPublishWrongStatistics() async throws {
        let gate = StatisticsReadGate(), loader = FeedStatisticsLoader { id, now, zone in try await gate.read(id, now, zone) }
        let missing = loader.load(feedID: 1); try await waitFor(1, in: gate)
        await gate.resolve(0, with: .success(nil)); await missing.value
        #expect(loader.state == .unavailable(feedID: 1))
        let failed = loader.load(feedID: 1); try await waitFor(2, in: gate)
        await gate.resolve(1, with: .failure(StatisticsReadGate.Failure.denied)); await failed.value
        #expect(loader.state == .failed(feedID: 1, message: "denied"))
        let mismatched = loader.load(feedID: 1); try await waitFor(3, in: gate)
        await gate.resolve(2, with: .success(try snapshot(2))); await mismatched.value
        #expect(loader.state == .failed(feedID: 1, message: "Statistics snapshot belongs to a different feed"))
    }
}

private actor StatisticsReadGate {
    enum Failure: Error { case denied }
    struct Request: Equatable, Sendable { let id: Int64; let now: Date; let zone: TimeZone }
    private(set) var requests: [Request] = []
    private var pending: [Int: CheckedContinuation<FeedStatisticsSnapshot?, any Error>] = [:]
    private(set) var cancelledCompletions = 0
    var count: Int { requests.count }
    func read(_ id: Int64, _ now: Date, _ zone: TimeZone) async throws -> FeedStatisticsSnapshot? {
        let index = requests.count
        requests.append(Request(id: id, now: now, zone: zone))
        defer { if Task.isCancelled { cancelledCompletions += 1 } }
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func resolve(_ index: Int, with result: Result<FeedStatisticsSnapshot?, any Error>) {
        pending.removeValue(forKey: index)?.resume(with: result)
    }
}
