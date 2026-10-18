import Foundation

/// One instance per source surface. Cover, seekbar and dialog reload independent
/// media snapshots; only their transport/cache is shared.
@MainActor public final class EpisodeChapterPresentation {
    public enum Surface: Sendable { case cover, seekbar, dialog }
    public private(set) var episode: LibraryEpisode?
    public private(set) var chapters: [ParsedChapter]?
    public private(set) var selectedIndex = -1
    /// INVISIBLE at the final chapter; retain the slot and the prior visibility
    /// when no chapter is selected, as the source cover does.
    public private(set) var nextVisible = true
    public private(set) var positionMilliseconds: Int64 = 0
    public private(set) var isLoading = false
    public private(set) var showsProgress: Bool
    /// Dialog adapter state is distinct from its reset-on-reload focus index.
    public private(set) var highlightedIndex = -1
    public private(set) var rowProgressPosition: Int64 = 0
    public var onChange: (() -> Void)?
    /// A fresh media load resets dialog focus even when chapter values are unchanged.
    public var onReloaded: (() -> Void)?
    public var onEmpty: (() -> Void)?
    public var onFailure: ((any Error) -> Void)?

    private let surface: Surface
    private let store: FeedLibraryStore
    private let load: @Sendable (LibraryEpisode, Bool) async throws -> EpisodeChapterLoad
    private let wait: @Sendable (AuxiliaryNetworkAdmission.Wake) async throws -> Void
    private let displayPosition: (Int64) -> Int64
    private(set) var request: Task<Void, Never>?
    /// One task per load with deferred parts: it reloads once when any of their conditions holds.
    private(set) var wake: Task<Void, Never>?
    /// A Refresh asked for and not yet done (a part of it had to wait): play/pause reloads of the same episode keep
    /// refreshing until it is.
    private(set) var pendingRefreshEpisodeID: Int64?
    private var token = UUID()

    public convenience init(surface: Surface, store: FeedLibraryStore, access: EpisodeChapterAccess,
                            displayPosition: @escaping (Int64) -> Int64 = { $0 }) {
        let admission = access.admission
        self.init(surface: surface, store: store, displayPosition: displayPosition,
                  loadDeferring: { try await access.loadDeferring(episode: $0, forceRefresh: $1) },
                  wait: { try await admission.wait(until: $0) })
    }

    convenience init(surface: Surface, store: FeedLibraryStore, displayPosition: @escaping (Int64) -> Int64 = { $0 },
         load: @escaping @Sendable (LibraryEpisode, Bool) async throws -> [ParsedChapter]) {
        self.init(surface: surface, store: store, displayPosition: displayPosition,
                  loadDeferring: { .init(chapters: try await load($0, $1)) }, wait: { _ in })
    }

    init(surface: Surface, store: FeedLibraryStore, displayPosition: @escaping (Int64) -> Int64 = { $0 },
         loadDeferring: @escaping @Sendable (LibraryEpisode, Bool) async throws -> EpisodeChapterLoad,
         wait: @escaping @Sendable (AuxiliaryNetworkAdmission.Wake) async throws -> Void) {
        self.surface = surface; self.store = store; self.load = loadDeferring; self.wait = wait
        self.displayPosition = displayPosition; showsProgress = surface == .dialog
    }

    deinit { request?.cancel(); wake?.cancel() }

    public var hasChapters: Bool {
        chapters.map { !$0.isEmpty } ?? (episode?.details.chapters?.isEmpty == false)
    }
    public var canRefresh: Bool { episode?.details.chapterURL?.isEmpty == false }
    public var currentChapter: ParsedChapter? {
        guard let chapters, chapters.indices.contains(selectedIndex) else { return nil }
        return chapters[selectedIndex]
    }
    public var canSeekNext: Bool {
        guard let chapters else { return false }
        return selectedIndex >= 0 && selectedIndex < chapters.count - 1
    }

    /// Call on surface start and player-status change, not on position ticks.
    /// Refresh reads a fresh database snapshot, including updated chapter URLs.
    public func reload(episodeID: Int64?, forceRefresh asked: Bool = false) {
        request?.cancel(); wake?.cancel(); wake = nil
        token = UUID()
        let captured = token
        if pendingRefreshEpisodeID != episodeID { pendingRefreshEpisodeID = nil }
        if asked, let episodeID { pendingRefreshEpisodeID = episodeID }
        let forceRefresh = pendingRefreshEpisodeID != nil
        if episodeID == nil {
            episode = nil; chapters = nil; selectedIndex = -1; positionMilliseconds = 0
        }
        guard let episodeID else { isLoading = false; onChange?(); return }
        isLoading = true
        if surface == .dialog, asked { showsProgress = true }
        onChange?()
        let store = store, load = load
        request = Task { [weak self] in
            var loadingEpisode: LibraryEpisode?
            do {
                guard var fresh = try await store.episode(id: episodeID) else {
                    guard let self, token == captured else { return }
                    episode = nil; chapters = nil; selectedIndex = -1; isLoading = false
                    onChange?()
                    return
                }
                try Task.checkCancellation()
                guard self?.token == captured else { return }
                // Cover/seekbar first display metadata with an unloaded list.
                // A refreshing dialog retains its rows beneath the spinner.
                if let self, surface != .dialog {
                    episode = fresh; chapters = nil; selectedIndex = -1
                    positionMilliseconds = positionForSurface(Int64(fresh.userState.positionMilliseconds))
                    onChange?()
                }
                if self?.surface != .dialog {
                    // The source's second load reads the database again. Do
                    // not reuse a position snapshot from the metadata pass.
                    guard let reloaded = try await store.episode(id: episodeID) else { throw CancellationError() }
                    fresh = reloaded
                }
                try Task.checkCancellation()
                guard self?.token == captured else { return }
                loadingEpisode = fresh
                let loaded = try await load(fresh, forceRefresh)
                let result = loaded.chapters
                try Task.checkCancellation()
                guard let self, token == captured else { return }
                // Parts that had to wait show as soon as their condition holds: the available list is published now.
                if !loaded.deferred.isEmpty { armWake(loaded.deferred, episodeID: episodeID, forceRefresh: forceRefresh) }
                else if forceRefresh { pendingRefreshEpisodeID = nil }
                episode = fresh; chapters = result; selectedIndex = -1; isLoading = false
                positionMilliseconds = positionForSurface(Int64(fresh.userState.positionMilliseconds))
                select(at: positionMilliseconds)
                if surface == .dialog { showsProgress = false }
                onReloaded?()
                onChange?()
                // "No chapters" only when every source has answered: a part waiting for the network may still bring some.
                if surface == .dialog, result.isEmpty, loaded.deferred.isEmpty { onEmpty?() }
            } catch {
                guard let self, token == captured else { return }
                isLoading = false
                // Interrupted reads are never published as a completed empty
                // list; a subsequent start/status/Refresh can retry.
                if let loadingEpisode, error is CancellationError ||
                    (error as? URLError).map({ [.cancelled, .timedOut].contains($0.code) }) == true {
                    episode = loadingEpisode; chapters = nil; selectedIndex = -1
                    positionMilliseconds = positionForSurface(Int64(loadingEpisode.userState.positionMilliseconds))
                    if surface == .dialog { showsProgress = false }
                }
                onChange?()
                if !(error is CancellationError) { onFailure?(error) }
            }
        }
    }

    public func stop() {
        token = UUID(); request?.cancel(); request = nil
        wake?.cancel(); wake = nil
        isLoading = false
    }

    /// `wait` subscribes before it checks, so a permission that returned before this was armed is seen at once.
    private func armWake(_ conditions: Set<AuxiliaryNetworkAdmission.Wake>, episodeID: Int64, forceRefresh: Bool) {
        wake?.cancel()
        let wait = wait, captured = token
        wake = Task { [weak self] in
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for condition in conditions { group.addTask { try await wait(condition) } }
                    defer { group.cancelAll() }
                    try await group.next()
                }
            } catch { return }
            guard !Task.isCancelled, let self, token == captured else { return }
            reload(episodeID: episodeID, forceRefresh: forceRefresh)
        }
    }

    private func positionForSurface(_ raw: Int64) -> Int64 {
        surface == .seekbar ? displayPosition(raw) : raw
    }

    /// Receive media time; the seekbar uses its supplied TimeSpeedConverter
    /// projection consistently for both initial selection and later ticks.
    public func updatePosition(_ position: Int64) {
        positionMilliseconds = positionForSurface(position)
        select(at: positionMilliseconds)
        if surface == .dialog, let chapters, chapters.indices.contains(highlightedIndex) {
            rowProgressPosition = position
        }
        onChange?()
    }

    private func select(at position: Int64) {
        let index = ChapterPlaybackRules.currentIndex(in: chapters, positionMilliseconds: position)
        // Only cover/dialog retain the prior selection before the first
        // boundary. AudioPlayerFragment assigns -1 on every such update.
        guard index >= 0 else {
            if surface == .seekbar { selectedIndex = -1 }
            return
        }
        guard index != selectedIndex else { return }
        select(index: index)
    }

    private func select(index: Int) {
        guard let chapters, chapters.indices.contains(index) else { return }
        if surface == .cover, let episode,
           episode.userState.positionMilliseconds > (episode.details.media?.durationMilliseconds ?? 0) {
            selectedIndex = chapters.count - 1
        } else { selectedIndex = index }
        if surface == .cover { nextVisible = selectedIndex < chapters.count - 1 }
        if surface == .dialog {
            highlightedIndex = index
            rowProgressPosition = chapters[index].startMilliseconds
        }
    }

    /// Return a captured target for PlaybackCoordinator.seekChapter. The caller
    /// passes this presentation's episode ID, never a newly selected episode.
    public func previousTarget(position: Int64, speed: Float) -> Int64? {
        guard let current = currentChapter else { return nil }
        if selectedIndex == 0 { return 0 }
        if Float(position) - 10_000 * speed < Float(current.startMilliseconds) {
            select(index: selectedIndex - 1)
            onChange?()
            return currentChapter?.startMilliseconds
        }
        return current.startMilliseconds
    }

    public func nextTarget() -> Int64? {
        guard canSeekNext else { return nil }
        select(index: selectedIndex + 1)
        onChange?()
        return currentChapter?.startMilliseconds
    }

    public func rowTarget(at index: Int) -> Int64? {
        guard let chapters, chapters.indices.contains(index) else { return nil }
        if selectedIndex != index {
            select(index: index)
            onChange?()
        }
        return chapters[index].startMilliseconds
    }

    func awaitLoading() async { await request?.value }
}
