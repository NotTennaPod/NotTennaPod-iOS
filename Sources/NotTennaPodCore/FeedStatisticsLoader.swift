import Foundation

/// Owns the statistics read for one visible component. A later request or
/// released view must never receive an earlier snapshot or error callback.
@MainActor
public final class FeedStatisticsLoader {
    public enum State: Equatable, Sendable {
        case idle
        case loading(feedID: Int64)
        case loaded(FeedStatisticsSnapshot, StatisticsTextFormatter)
        case unavailable(feedID: Int64)
        case failed(feedID: Int64, message: String)
    }
    public typealias Read = @Sendable (Int64, Date, TimeZone) async throws -> FeedStatisticsSnapshot?
    public private(set) var state: State = .idle
    public var onChange: ((State) -> Void)?
    private let read: Read
    private var request = UUID()
    private var pending: Task<Void, Never>?

    public init(read: @escaping Read) { self.read = read }
    public convenience init(store: FeedLibraryStore) {
        self.init { id, now, zone in try await store.statisticsSnapshot(feedID: id, now: now, timeZone: zone) }
    }
    deinit { pending?.cancel() }

    @discardableResult
    public func load(feedID: Int64, formatter: StatisticsTextFormatter = .init()) -> Task<Void, Never> {
        pending?.cancel()
        let token = UUID(), read = read
        request = token
        state = .loading(feedID: feedID)
        let task = Task { [weak self] in
            let result: Result<FeedStatisticsSnapshot?, any Error>
            do {
                try Task.checkCancellation()
                let snapshot = try await read(feedID, formatter.now, formatter.timeZone)
                try Task.checkCancellation()
                result = .success(snapshot)
            } catch { result = .failure(error) }
            guard !Task.isCancelled, let self, request == token else { return }
            pending = nil
            switch result {
            case .success(let snapshot?):
                guard snapshot.feedID == feedID else {
                    publish(.failed(feedID: feedID, message: "Statistics snapshot belongs to a different feed"))
                    return
                }
                publish(.loaded(snapshot, formatter))
            case .success(nil): publish(.unavailable(feedID: feedID))
            case .failure(let error): publish(.failed(feedID: feedID, message: String(describing: error)))
            }
        }
        // Store ownership before notifying: a callback may replace/cancel this
        // request synchronously. Nothing after notification may overwrite it.
        pending = task
        onChange?(state)
        return task
    }

    public func cancel() {
        request = UUID(); pending?.cancel(); pending = nil
        publish(.idle)
    }
    private func publish(_ value: State) { state = value; onChange?(value) }
}
