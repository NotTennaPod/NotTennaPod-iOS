import Foundation

/// Immediate selection with serialized persistence, retained after dismissal.
@MainActor public final class FeedSortEditor {
    public private(set) var selection: FeedEpisodeSortOrder
    public let fields: [FeedEpisodeSortOrder.Field]
    public var onChange: (() -> Void)?
    public var onSaved: (() -> Void)?
    public var onFailure: ((any Error) -> Void)?
    private var committed: FeedEpisodeSortOrder
    private let save: @MainActor (FeedEpisodeSortOrder) async throws -> Void
    private var tail: Task<Void, Never>?
    private var revision = 0

    public init(selection: FeedEpisodeSortOrder, local: Bool, includesGlobal: Bool = true,
                fields: [FeedEpisodeSortOrder.Field]? = nil,
                save: @escaping @MainActor (FeedEpisodeSortOrder) async throws -> Void) {
        self.selection = selection; committed = selection; self.save = save
        self.fields = fields ?? FeedEpisodeSortOrder.Field.choices(local: local, includesGlobal: includesGlobal)
    }
    public convenience init(feed: LibraryFeed, store: FeedLibraryStore) {
        self.init(selection: feed.episodeSortOrderCode.flatMap(FeedEpisodeSortOrder.init(rawValue:)) ?? .global,
                  local: feed.source.isLocalFeedSource, save: {
            try await store.setFeedEpisodeSortOrder(feedID: feed.id, order: $0)
        })
    }
    @discardableResult public func select(_ field: FeedEpisodeSortOrder.Field) -> Task<Void, Never>? {
        guard fields.contains(field), !(field == .global && selection == .global) else { return nil }
        selection = selection.selecting(field)
        revision += 1
        let value = selection, revision = revision, previous = tail
        let task = Task {
            await previous?.value
            do {
                try await save(value); committed = value; onSaved?()
            } catch {
                if self.revision == revision { selection = committed; onChange?() }
                onFailure?(error)
            }
        }
        tail = task; onChange?()
        return task
    }
}
