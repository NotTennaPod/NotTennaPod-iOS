import Foundation

/// The Android `SortOrder` values the Queue sort sheet offers, stored by enum name
/// like `prefQueueKeepSortedOrder`.
public enum QueueSortOrder: String, CaseIterable, Codable, Sendable {
    case dateOldNew = "DATE_OLD_NEW"
    case dateNewOld = "DATE_NEW_OLD"
    case episodeTitleAZ = "EPISODE_TITLE_A_Z"
    case episodeTitleZA = "EPISODE_TITLE_Z_A"
    case durationShortLong = "DURATION_SHORT_LONG"
    case durationLongShort = "DURATION_LONG_SHORT"
    case feedTitleAZ = "FEED_TITLE_A_Z"
    case feedTitleZA = "FEED_TITLE_Z_A"
    case random = "RANDOM"
    case smartShuffleOldNew = "SMART_SHUFFLE_OLD_NEW"
    case smartShuffleNewOld = "SMART_SHUFFLE_NEW_OLD"

    /// `SortOrder.parseWithDefault`: a missing or unknown stored name reads as `DATE_NEW_OLD`.
    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .dateNewOld
    }

    /// `SortOrder.code` (`SortOrder.java:15–31`).
    public var code: Int {
        switch self {
        case .dateOldNew: 1
        case .dateNewOld: 2
        case .episodeTitleAZ: 3
        case .episodeTitleZA: 4
        case .durationShortLong: 5
        case .durationLongShort: 6
        case .feedTitleAZ: 101
        case .feedTitleZA: 102
        case .random: 103
        case .smartShuffleOldNew: 104
        case .smartShuffleNewOld: 105
        }
    }
}

/// The values `FeedItemPermutors` reads from a queued episode, with its null-safe defaults applied:
/// no title → "", no feed title → "", no date → epoch 0, no media → duration 0.
public struct QueueSortItem: Equatable, Sendable {
    public var id: Int64
    public var feedID: Int64
    public var title: String?
    public var feedTitle: String?
    public var publicationMilliseconds: Int64
    public var durationMilliseconds: Int32

    public init(id: Int64, feedID: Int64, title: String?, feedTitle: String?,
                publicationMilliseconds: Int64, durationMilliseconds: Int32) {
        self.id = id; self.feedID = feedID; self.title = title; self.feedTitle = feedTitle
        self.publicationMilliseconds = publicationMilliseconds; self.durationMilliseconds = durationMilliseconds
    }
}

/// `FeedItemPermutors.getPermutor(order).reorder(queue)` (`FeedItemPermutors.java:31–204`).
public enum QueueSorter {
    public static func sorted(_ items: [QueueSortItem], by order: QueueSortOrder, locale: Locale,
                              shuffle: (inout [QueueSortItem]) -> Void = { $0.shuffle() }) -> [QueueSortItem] {
        switch order {
        case .random:
            var result = items; shuffle(&result); return result
        case .smartShuffleOldNew: return smartShuffle(items, ascending: true)
        case .smartShuffleNewOld: return smartShuffle(items, ascending: false)
        case .episodeTitleAZ, .episodeTitleZA:
            return stable(items, descending: order == .episodeTitleZA) { text($0.title, locale) }
        case .feedTitleAZ, .feedTitleZA:
            return stable(items, descending: order == .feedTitleZA) { text($0.feedTitle, locale) }
        case .durationShortLong, .durationLongShort:
            return stable(items, descending: order == .durationLongShort) { $0.durationMilliseconds }
        case .dateOldNew, .dateNewOld:
            return stable(items, descending: order == .dateNewOld) { $0.publicationMilliseconds }
        }
    }

    /// `String.toLowerCase(Locale.getDefault())` compared with `String.compareTo`: UTF-16 code units,
    /// not collation (accented letters sort after "z"; Turkish lower-cases I to dotless ı).
    struct UTF16Key: Comparable {
        let units: [UInt16]
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.units.lexicographicallyPrecedes(rhs.units) }
    }
    static func text(_ value: String?, _ locale: Locale) -> UTF16Key {
        UTF16Key(units: Array((value ?? "").lowercased(with: locale).utf16))
    }

    /// `Collections.sort`: stable. The descending comparators are `f2.compareTo(f1)`, so equal keys keep
    /// their current queue order in both directions.
    private static func stable<Key: Comparable>(_ items: [QueueSortItem], descending: Bool,
                                                key: (QueueSortItem) -> Key) -> [QueueSortItem] {
        items.enumerated().map { (index: $0.offset, item: $0.element, key: key($0.element)) }
            .sorted { lhs, rhs in
                if lhs.key != rhs.key { return descending ? rhs.key < lhs.key : lhs.key < rhs.key }
                return lhs.index < rhs.index
            }.map(\.item)
    }

    /// `FeedItemPermutors.smartShuffle` (`:154–204`).
    static func smartShuffle(_ items: [QueueSortItem], ascending: Bool) -> [QueueSortItem] {
        var groups: [Int64: [QueueSortItem]] = [:]
        for item in items { groups[item.feedID, default: []].append(item) }
        // HashMap iteration order, then each group by date (stable), then a stable sort by size descending.
        let feeds = hashMapIterationOrder(items.map(\.feedID)).map { feedID in
            stable(groups[feedID] ?? [], descending: !ascending) { $0.publicationMilliseconds }
        }.enumerated().sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
            .map(\.element)
        var result = [QueueSortItem?](repeating: nil, count: items.count)
        var emptySlots = Array(items.indices)
        for feedItems in feeds {
            let spread = Double(emptySlots.count) / Double(feedItems.count + 1)
            var skipped = 0, placed = 0, remaining: [Int] = []
            var index = 0
            while index < emptySlots.count {
                let slot = emptySlots[index]; index += 1
                skipped += 1
                if Double(skipped) >= spread * Double(placed + 1) {
                    result[slot] = feedItems[placed]
                    placed += 1
                    if placed == feedItems.count { remaining.append(contentsOf: emptySlots[index...]); break }
                } else {
                    remaining.append(slot)
                }
            }
            emptySlots = remaining
        }
        return result.compactMap { $0 }
    }

    /// Iteration order of a `java.util.HashMap<Long, …>` filled with `keys` (first occurrence counts):
    /// bucket index ascending, insertion order within a bucket. The table starts at 16, doubles when the
    /// size exceeds 0.75 × capacity, and also doubles when a ninth key lands in one bucket while the
    /// capacity is below 64 (`treeifyBin` resizes instead). A treeified bin (≥ 9 colliding keys at
    /// capacity ≥ 64) keeps insertion order here.
    static func hashMapIterationOrder(_ keys: [Int64]) -> [Int64] {
        func hash(_ key: Int64) -> UInt32 {
            let value = UInt64(bitPattern: key)
            let h = UInt32(truncatingIfNeeded: value ^ (value >> 32))
            return h ^ (h >> 16)
        }
        var inserted: [Int64] = [], seen = Set<Int64>(), capacity: UInt32 = 16
        for key in keys where !seen.contains(key) {
            let bucket = hash(key) & (capacity - 1)
            let existing = inserted.count(where: { hash($0) & (capacity - 1) == bucket })
            inserted.append(key); seen.insert(key)
            if existing >= 8 && capacity < 64 { capacity *= 2 }
            if Double(inserted.count) > Double(capacity) * 0.75 { capacity *= 2 }
        }
        return inserted.enumerated().sorted {
            let lhs = hash($0.element) & (capacity - 1), rhs = hash($1.element) & (capacity - 1)
            return lhs != rhs ? lhs < rhs : $0.offset < $1.offset
        }.map(\.element)
    }
}

/// How new queue entries are placed: Enqueue location (`prefEnqueueLocation`) and Keep sorted
/// (`prefQueueKeepSorted` + `prefQueueKeepSortedOrder`). The library applies them in `addQueueItem`'s way.
public struct QueueInsertionSettings: Equatable, Sendable {
    public var location: EnqueueLocation
    /// Non-nil while Keep sorted is on.
    public var keepSortedOrder: QueueSortOrder?
    /// `Locale.getDefault()` for the title comparators.
    public var locale: Locale

    public init(location: EnqueueLocation = .back, keepSortedOrder: QueueSortOrder? = nil, locale: Locale = .current) {
        self.location = location; self.keepSortedOrder = keepSortedOrder; self.locale = locale
    }
}

/// The six Queue sort-sheet rows in grid order (`ItemSortDialog.populateList` without File name and
/// Size; Date and Smart shuffle ascending-default, `QueueFragment.java:596–605`).
public enum QueueSortRow: String, CaseIterable, Sendable {
    case episodeTitle, feedTitle, duration, date, random, smartShuffle

    public var titleKey: String {
        switch self {
        case .episodeTitle: "episode_title"
        case .feedTitle: "feed_title"
        case .duration: "duration"
        case .date: "date"
        case .random: "random"
        case .smartShuffle: "smart_shuffle"
        }
    }
    public var ascending: QueueSortOrder {
        switch self {
        case .episodeTitle: .episodeTitleAZ
        case .feedTitle: .feedTitleAZ
        case .duration: .durationShortLong
        case .date: .dateOldNew
        case .random: .random
        case .smartShuffle: .smartShuffleOldNew
        }
    }
    public var descending: QueueSortOrder {
        switch self {
        case .episodeTitle: .episodeTitleZA
        case .feedTitle: .feedTitleZA
        case .duration: .durationLongShort
        case .date: .dateNewOld
        case .random: .random
        case .smartShuffle: .smartShuffleNewOld
        }
    }
    public func isActive(_ order: QueueSortOrder?) -> Bool { order == ascending || order == descending }
    /// The ▲/▼ arrow of the active row; nil when inactive and for Random (one order, no arrow).
    public func arrowAscending(_ order: QueueSortOrder?) -> Bool? {
        guard isActive(order), ascending != descending else { return nil }
        return order == ascending
    }
    /// `ItemSortDialog.onAddItem`: the active row flips (Random stays Random and shuffles again);
    /// an inactive row selects its ascending-default order.
    public func tapped(from order: QueueSortOrder?) -> QueueSortOrder {
        guard isActive(order) else { return ascending }
        return order == ascending ? descending : ascending
    }
}

/// `QueueFragment.QueueSortDialog` state (`QueueFragment.java:579–626`).
public struct QueueSortSheetState: Equatable, Sendable {
    /// The active row's order; nil when the sheet opened with Keep sorted off and nothing was tapped yet.
    public private(set) var order: QueueSortOrder?
    public private(set) var keepSorted: Bool
    public private(set) var keepSortedEnabled: Bool
    private var turnedOffKeepSortedForRandom = false

    public init(keepSorted: Bool, storedOrder: QueueSortOrder) {
        order = keepSorted ? storedOrder : nil
        self.keepSorted = keepSorted
        keepSortedEnabled = keepSorted   // "Disable until something gets selected"
    }

    public mutating func tap(_ row: QueueSortRow) {
        order = row.tapped(from: order)
        selectionChanged()
    }

    public mutating func setKeepSorted(_ value: Bool) {
        guard keepSortedEnabled, order != nil else { return }
        keepSorted = value
        selectionChanged()
    }

    private mutating func selectionChanged() {
        if order == .random {
            turnedOffKeepSortedForRandom = turnedOffKeepSortedForRandom || keepSorted
            keepSorted = false
            keepSortedEnabled = false
        } else {
            if turnedOffKeepSortedForRandom { keepSorted = true; turnedOffKeepSortedForRandom = false }
            keepSortedEnabled = true
        }
    }
}
