import Foundation

/// A single confirmed period and formatting context, captured before a read.
public struct SubscriptionStatisticsRequest: Equatable, Sendable {
    public let preferences: StatisticsPeriodPreferences
    public let formatter: StatisticsTextFormatter

    public init(preferences: StatisticsPeriodPreferences, formatter: StatisticsTextFormatter) {
        self.preferences = preferences
        self.formatter = formatter
    }
}

/// Aggregate values and visible feed metadata from the same complete library
/// read. No second metadata read can mix a renamed/deleted feed into these rows.
public struct SubscriptionStatisticsSnapshot: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let statistics: FeedStatistics
        public let title: String?
        public let imageURL: String?
    }
    public let request: SubscriptionStatisticsRequest
    public let statistics: LibraryStatistics
    /// Source playback order: descending duration, retaining ascending ID ties.
    public let rows: [Row]

    public init(feeds: [LibraryFeed], units: [Int64: [LibraryStatisticsUnit]] = [:], request: SubscriptionStatisticsRequest) throws {
        let preferences = request.preferences
        let statistics = try LibraryStatistics(feeds: feeds, units: units,
            includeMarkedAsPlayed: preferences.includeMarkedAsPlayed,
            timeFrom: preferences.timeFrom, timeTo: preferences.timeTo, now: request.formatter.now)
        let byID = Dictionary(statistics.feeds.map { ($0.feedID, $0) }, uniquingKeysWith: { _, last in last })
        rows = feeds.compactMap { feed in
            guard let value = byID[feed.id] else { return nil }
            return Row(statistics: value, title: feed.title, imageURL: feed.metadata.imageURL)
        }.sorted {
            $0.statistics.playedSeconds == $1.statistics.playedSeconds
                ? $0.statistics.feedID < $1.statistics.feedID
                : $0.statistics.playedSeconds > $1.statistics.playedSeconds
        }
        self.request = request
        self.statistics = statistics
    }
}

/// One visible subscription-statistics owner's request lifetime. Its input is a
/// complete value snapshot, never independently loaded totals and row titles.
@MainActor
public final class SubscriptionStatisticsLoader {
    public enum State: Equatable, Sendable {
        case idle
        case loading(SubscriptionStatisticsRequest)
        case loaded(SubscriptionStatisticsSnapshot)
        case failed(SubscriptionStatisticsRequest, message: String)
    }
    public typealias Read = @Sendable () async throws -> [LibraryFeed]
    /// The feeds and their statistics units from one read (schema 20).
    public typealias StatisticsRead = @Sendable () async throws -> LibraryStatisticsInput
    public private(set) var state: State = .idle
    /// Retained across a same-library reload/failure. Consumers decide whether
    /// it is visible; this does not prescribe an error/loading presentation.
    public private(set) var lastSnapshot: SubscriptionStatisticsSnapshot?
    public var onChange: ((State) -> Void)?
    private var read: StatisticsRead
    private var generation = UUID()
    private var pending: Task<Void, Never>?

    public init(read: @escaping Read) { self.read = { LibraryStatisticsInput(feeds: try await read()) } }
    public init(readStatistics: @escaping StatisticsRead) { read = readStatistics }
    public convenience init(store: FeedLibraryStore) {
        self.init(readStatistics: { try await store.statisticsLibrary() })
    }
    deinit { pending?.cancel() }

    @discardableResult
    public func load(preferences: StatisticsPeriodPreferences,
                     formatter: StatisticsTextFormatter) -> Task<Void, Never> {
        pending?.cancel()
        let token = UUID(), read = read
        let request = SubscriptionStatisticsRequest(preferences: preferences, formatter: formatter)
        generation = token
        state = .loading(request)
        let task = Task { [weak self] in
            let result: Result<SubscriptionStatisticsSnapshot, any Error>
            do {
                try Task.checkCancellation()
                // Detached ownership keeps synchronous aggregation off MainActor.
                // Cancellation is explicitly forwarded to this unstructured task.
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let input = try await read()
                    try Task.checkCancellation()
                    let snapshot = try SubscriptionStatisticsSnapshot(feeds: input.feeds, units: input.units, request: request)
                    try Task.checkCancellation()
                    return snapshot
                }
                let snapshot = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                result = .success(snapshot)
            } catch { result = .failure(error) }
            guard !Task.isCancelled, let self, generation == token else { return }
            pending = nil
            switch result {
            case .success(let snapshot):
                lastSnapshot = snapshot
                publish(.loaded(snapshot))
            case .failure(let error):
                publish(.failed(request, message: String(describing: error)))
            }
        }
        // A synchronous loading observer can cancel or replace this request.
        pending = task
        onChange?(state)
        return task
    }

    /// Called on navigation away. Even a non-cooperative read cannot publish.
    public func cancel() {
        generation = UUID()
        pending?.cancel(); pending = nil
        lastSnapshot = nil
        publish(.idle)
    }

    /// Library identity changes must discard the old successful presentation as
    /// well as its pending read. The new source is installed before notification.
    public func replaceLibrary(read: @escaping Read) {
        self.read = { LibraryStatisticsInput(feeds: try await read()) }
        cancel()
    }
    public func replaceLibrary(store: FeedLibraryStore) {
        read = { try await store.statisticsLibrary() }
        cancel()
    }

    private func publish(_ value: State) { state = value; onChange?(value) }
}
