import Foundation

/// `SearchPreferenceFragment`'s search history: titles of opened results, newest first, at most five; a title
/// already present is not added again (and not moved). Stored beside the library, like Android's own
/// "preferenceSearch" preferences file, which no backup includes.
@MainActor public final class SettingsSearchHistoryStore {
    public static let limit = 5
    public private(set) var terms: [String]
    private let file: URL?

    private struct Stored: Codable { var terms: [String] }

    /// A history kept in memory only.
    public init() { file = nil; terms = [] }

    /// A nil file keeps the history in memory only. A missing or damaged file starts empty, as always; one that cannot
    /// be read now (before the first unlock) is thrown, so an empty history never replaces it at the next search.
    public init(file: URL?) throws {
        self.file = file
        if let file, let data = try SavedState.contents(of: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            terms = Array(stored.terms.prefix(Self.limit))
        } else {
            terms = []
        }
    }

    /// `SearchPreferenceFragment.addHistoryEntry`.
    public func add(_ term: String) throws {
        guard !terms.contains(term) else { return }
        var updated = terms
        if updated.count >= Self.limit { updated.removeLast() }
        updated.insert(term, at: 0)
        try save(updated)
    }

    /// The "Clear history" menu item.
    public func clear() throws { try save([]) }

    private func save(_ updated: [String]) throws {
        if let file { try JSONEncoder().encode(Stored(terms: updated)).write(to: file, options: .atomic) }
        terms = updated
    }
}
