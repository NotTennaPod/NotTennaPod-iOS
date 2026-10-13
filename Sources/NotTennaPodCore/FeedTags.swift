import Foundation

/// TagSettingsDialog edits a draft; only OK changes stored preferences.
public struct FeedTags: Equatable, Sendable {
    public static let root = "#root"
    public static let untagged = "#untagged"
    public private(set) var displayed: [String]
    public var includeRoot: Bool
    private var preferencesCapacity: Int
    /// The tags common to every edited feed when the dialog opened; OK removes exactly these from each
    /// feed before adding the draft, so tags only some feeds have stay untouched.
    public let common: [String]
    /// More than one feed: the dialog shows the common-tags information line.
    public let isMultiple: Bool

    public init(tags: [String]) {
        self.init(preferences: FeedTagOrder.preferences(tags))
    }
    private init(preferences: FeedTagOrder.Builder) {
        let common = FeedTagOrder.Builder(collection: preferences.values).values
        displayed = common.filter { !Self.equal($0, Self.root) }
        includeRoot = common.contains { Self.equal($0, Self.root) }
        preferencesCapacity = preferences.capacity
        self.common = common; isMultiple = false
    }
    /// TagSettingsDialog for several feeds, in list order: a copy of the first feed's set, retaining
    /// only tags every other feed has. There is no partial marker; the chips follow the first feed's order.
    public init(selection: [[String]]) {
        let first = FeedTagOrder.preferences(selection.first ?? [])
        var common = FeedTagOrder.Builder(collection: first.values).values
        for tags in selection.dropFirst() {
            let other = Set(FeedTagOrder.preferences(tags).values.map { Array($0.utf16) })
            common.removeAll { !other.contains(Array($0.utf16)) }
        }
        displayed = common.filter { !Self.equal($0, Self.root) }
        includeRoot = common.contains { Self.equal($0, Self.root) }
        preferencesCapacity = first.capacity
        self.common = common; isMultiple = selection.count > 1
    }
    /// One edited feed's new tags: remove every common tag, then add the draft (and `#root` when checked).
    /// A `#root` only some feeds had was not common, so it stays even when the box is unchecked.
    public func saved(onto tags: [String]) -> [String] {
        var result = FeedTagEdit.rebuilt(tags) { name in !common.contains { Self.equal($0, name) } }
        for name in displayed + (includeRoot ? [Self.root] : []) { result.insert(name) }
        return result.values
    }
    /// Java trim removes code units <= U+0020, not all Unicode whitespace.
    @discardableResult public mutating func add(_ input: String) -> Bool {
        let name = JavaString.trim(input)
        guard !name.isEmpty, !Self.equal(name, Self.untagged),
              !displayed.contains(where: { Self.equal($0, name) }) else { return false }
        displayed.append(name)
        return true
    }
    public mutating func remove(at index: Int) {
        guard displayed.indices.contains(index) else { return }
        displayed.remove(at: index)
    }
    private var savedPreferences: FeedTagOrder.Builder {
        // A single-feed edit removes every old common tag before adding the
        // draft. The source preference set retains its allocated capacity.
        var result = FeedTagOrder.Builder(capacity: preferencesCapacity)
        for name in displayed + (includeRoot ? [Self.root] : []) { result.insert(name) }
        return result
    }
    public var saved: [String] { savedPreferences.values }
    /// Reopening within the same settings screen retains the preference object.
    /// A fresh screen/library load instead uses init(tags:) above.
    public func reopeningSaved() -> Self { Self(preferences: savedPreferences) }
    // Java tags are exact UTF-16 strings. Swift String equality also folds
    // canonically equivalent spellings, which would merge distinct source tags.
    public static func equal(_ lhs: String, _ rhs: String) -> Bool { lhs.utf16.elementsEqual(rhs.utf16) }
    static func unique(_ tags: [String]) -> [String] {
        var seen = Set<[UInt16]>()
        return tags.filter { seen.insert(Array($0.utf16)).inserted }
    }
    public static func suggestions(in feeds: [LibraryFeed]) -> [String] {
        unique(feeds.filter { $0.subscriptionState == .subscribed }.flatMap(\.tags))
            .filter { !equal($0, root) && !equal($0, untagged) }
            .sorted { $0.lowercased().utf16.lexicographicallyPrecedes($1.lowercased().utf16) }
    }
}
