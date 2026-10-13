import Foundation

/// A document read belongs to a presentation; a confirmed job belongs to itself.
/// Closing a screen invalidates reads/UI delivery without cancelling accepted writes.
@MainActor public final class OPMLImportSession {
    public enum State: Equatable, Sendable {
        case loading, selecting, committing, completed, closed
        case readFailed(String), commitFailed(String)
    }
    public private(set) var state: State = .loading
    public private(set) var document = OPMLDocument(entries: [])
    public private(set) var selected: Set<Int> = []
    public private(set) var committedFeedIDs: [Int64] = []
    public var onChange: (() -> Void)?
    public private(set) var isPresented = true
    private let read: @Sendable (URL) async throws -> Data
    private let commit: @Sendable (OPMLDocument.Entry) async throws -> Int64
    private let refresh: @MainActor () async throws -> Void
    private var generation = UUID()
    private var reading: Task<Void, Never>?
    private var confirmed: [OPMLDocument.Entry]?
    private var job: Task<Void, Never>?
    private var nextIndex = 0

    public init(read: @escaping @Sendable (URL) async throws -> Data,
                commit: @escaping @Sendable (OPMLDocument.Entry) async throws -> Int64,
                refresh: @escaping @MainActor () async throws -> Void) {
        self.read = read; self.commit = commit; self.refresh = refresh
    }
    public convenience init(store: FeedLibraryStore,
                            read: @escaping @Sendable (URL) async throws -> Data,
                            refresh: @escaping @MainActor () async throws -> Void) {
        self.init(read: read, commit: { try await store.importOPMLEntry($0).id }, refresh: refresh)
    }
    deinit { reading?.cancel() }

    @discardableResult public func load(_ url: URL) -> Task<Void, Never>? {
        guard isPresented, confirmed == nil else { return nil }
        generation = UUID(); let token = generation
        reading?.cancel(); state = .loading; selected = []; document = .init(entries: []); publish()
        let read = read
        let task = Task { [weak self] in
            do {
                let bytes = try await read(url)
                try Task.checkCancellation()
                let parsed = try await Task.detached { try OPMLReader().read(bytes) }.value
                guard let self, self.isPresented, self.generation == token else { return }
                self.document = parsed; self.state = .selecting; self.publish()
            } catch {
                guard let self, self.isPresented, self.generation == token else { return }
                self.state = .readFailed(error.localizedDescription); self.publish()
            }
        }
        reading = task; return task
    }
    public func toggle(_ index: Int) {
        guard state == .selecting, document.entries.indices.contains(index) else { return }
        if !selected.insert(index).inserted { selected.remove(index) }; publish()
    }
    public func selectAll(_ all: Bool) {
        guard state == .selecting else { return }
        selected = all ? Set(document.entries.indices) : []; publish()
    }
    /// Capture once in row order. A retry resumes the failed entry/refresh phase,
    /// retaining the already committed prefix and its exact effect identities.
    @discardableResult public func confirm() -> Task<Void, Never>? {
        guard isPresented else { return nil }
        switch state { case .selecting, .commitFailed: break; default: return nil }
        if confirmed == nil { confirmed = document.entries.enumerated().compactMap { selected.contains($0.offset) ? $0.element : nil } }
        state = .committing; publish()
        let task = Task { [self] in
            do {
                let entries = confirmed ?? []
                while nextIndex < entries.count {
                    let id = try await commit(entries[nextIndex])
                    committedFeedIDs.append(id); nextIndex += 1
                }
                try await refresh() // global runOnce, also for an empty selection
                state = .completed
            } catch { state = .commitFailed(error.localizedDescription) }
            job = nil; publish()
        }
        job = task; return task
    }
    public func close() {
        isPresented = false; generation = UUID(); reading?.cancel(); reading = nil
        if confirmed == nil { state = .closed }
        onChange = nil // committed work may finish; it cannot reopen this screen
    }
    private func publish() { if isPresented { onChange?() } }
}
