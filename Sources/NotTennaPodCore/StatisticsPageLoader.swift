import Foundation

/// One Statistics page's read (Years or Downloads): the complete library is read off the main
/// actor and turned into the page's snapshot. A newer load, a cancel or a library change
/// supersedes a pending read, which then cannot publish.
@MainActor
public final class StatisticsPageLoader<Snapshot: Equatable & Sendable> {
    public enum State: Equatable, Sendable {
        case idle, loading
        case loaded(Snapshot)
        case failed(message: String)
    }
    public typealias Read = @Sendable () async throws -> [LibraryFeed]
    public private(set) var state: State = .idle
    public var onChange: ((State) -> Void)?
    private let produce: @Sendable () async throws -> Snapshot
    private var generation = UUID()
    private var pending: Task<Void, Never>?

    public init(read: @escaping Read, make: @escaping @Sendable ([LibraryFeed]) -> Snapshot) {
        produce = { make(try await read()) }
    }

    /// A page that counts statistics units (schema 20): the feeds and their units from one read.
    public init(readStatistics: @escaping @Sendable () async throws -> LibraryStatisticsInput,
                make: @escaping @Sendable (LibraryStatisticsInput) -> Snapshot) {
        produce = { make(try await readStatistics()) }
    }
    deinit { pending?.cancel() }

    /// A reload keeps showing the previous snapshot until the new one is ready.
    @discardableResult
    public func load() -> Task<Void, Never> {
        pending?.cancel()
        let token = UUID(), produce = produce
        generation = token
        if case .loaded = state {} else { state = .loading }
        let task = Task { [weak self] in
            let result: Result<Snapshot, any Error>
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let snapshot = try await produce()
                    try Task.checkCancellation()
                    return snapshot
                }
                result = .success(try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() })
            } catch { result = .failure(error) }
            guard !Task.isCancelled, let self, generation == token else { return }
            pending = nil
            switch result {
            case .success(let snapshot): publish(.loaded(snapshot))
            case .failure(let error): publish(.failed(message: String(describing: error)))
            }
        }
        pending = task
        return task
    }

    public func cancel() {
        generation = UUID()
        pending?.cancel(); pending = nil
        if state != .idle { publish(.idle) }
    }

    private func publish(_ value: State) { state = value; onChange?(value) }
}
