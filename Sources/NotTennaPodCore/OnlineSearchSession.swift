import Foundation

@MainActor public final class OnlineSearchSession {
    public enum State: Equatable, Sendable {
        case idle, loading, results([PodcastSearchResult]), failure(String)
    }
    public let provider: PodcastSearchProvider
    public private(set) var submittedQuery = ""
    public private(set) var state: State = .idle
    public var onChange: (() -> Void)?
    private let read: @Sendable (String, PodcastSearchProvider) async throws -> [PodcastSearchResult]
    private var task: Task<Void, Never>?
    private var generation = UUID()
    public init(provider: PodcastSearchProvider = .combined,
                read: @escaping @Sendable (String, PodcastSearchProvider) async throws -> [PodcastSearchResult] = { query, provider in
                    try await PodcastSearchClient().search(query, provider: provider)
                }) { self.provider = provider; self.read = read }
    deinit { task?.cancel() }
    public func submit(_ query: String) {
        cancel(); submittedQuery = query; state = .loading; onChange?()
        let generation = generation, read = read, provider = provider
        task = Task { [weak self] in
            do {
                let results = try await read(query, provider)
                try Task.checkCancellation()
                guard let self, self.generation == generation else { return }
                state = .results(results); task = nil; onChange?()
            } catch {
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                state = .failure(error.localizedDescription); task = nil; onChange?()
            }
        }
    }
    public func retry() { submit(submittedQuery) }
    public func cancel() { generation = UUID(); task?.cancel(); task = nil }
}
