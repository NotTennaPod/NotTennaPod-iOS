/// The canonical queue comparators of PROTOCOL §7.6: the sort orders Android 3.12.1's queue sort dialog
/// offers, on canonical values, so every device and the server sort a keep-sorted queue the same way.
/// They never use device custom titles or locale collation.
public enum CanonicalQueueSort {
    /// The keep-sorted orders (every sort-dialog order except random), by their wire names.
    public enum Order: String, CaseIterable, Sendable {
        case episodeTitleAToZ = "episode_title_a_z"
        case episodeTitleZToA = "episode_title_z_a"
        case feedTitleAToZ = "feed_title_a_z"
        case feedTitleZToA = "feed_title_z_a"
        case durationShortToLong = "duration_short_long"
        case durationLongToShort = "duration_long_short"
        case dateOldToNew = "date_old_new"
        case dateNewToOld = "date_new_old"
        case smartShuffleOldToNew = "smart_shuffle_old_new"
        case smartShuffleNewToOld = "smart_shuffle_new_old"
    }

    /// A queue member's canonical sort values. A missing value takes Android's default: title "",
    /// publication time 0, duration 0.
    public struct Values: Sendable, Equatable {
        public var podcastID: String
        public var title: String?
        public var podcastTitle: String?
        public var publicationTime: Int64?
        public var duration: Int64?

        public init(podcastID: String, title: String? = nil, podcastTitle: String? = nil,
                    publicationTime: Int64? = nil, duration: Int64? = nil) {
            self.podcastID = podcastID
            self.title = title
            self.podcastTitle = podcastTitle
            self.publicationTime = publicationTime
            self.duration = duration
        }
    }

    /// The indices of `items` (in current queue order) in sorted order. Every order is stable: equal
    /// values keep their queue order, in descending orders too.
    public static func order(_ items: [Values], by order: Order) -> [Int] {
        switch order {
        case .episodeTitleAToZ, .episodeTitleZToA:
            let keys = items.map { simpleLowercase($0.title ?? "") }
            return stableOrder(items.count, descending: order == .episodeTitleZToA) { keys[$0].lexicographicallyPrecedes(keys[$1]) }
        case .feedTitleAToZ, .feedTitleZToA:
            let keys = items.map { simpleLowercase($0.podcastTitle ?? "") }
            return stableOrder(items.count, descending: order == .feedTitleZToA) { keys[$0].lexicographicallyPrecedes(keys[$1]) }
        case .durationShortToLong, .durationLongToShort:
            let keys = items.map { $0.duration ?? 0 }
            return stableOrder(items.count, descending: order == .durationLongToShort) { keys[$0] < keys[$1] }
        case .dateOldToNew, .dateNewToOld:
            let keys = items.map { $0.publicationTime ?? 0 }
            return stableOrder(items.count, descending: order == .dateNewToOld) { keys[$0] < keys[$1] }
        case .smartShuffleOldToNew, .smartShuffleNewToOld:
            return smartShuffle(items, ascending: order == .smartShuffleOldToNew)
        }
    }

    /// The Unicode simple lowercase mapping of every code point, without locale or context, as code points.
    /// U+0130 maps to "i"; its full mapping would add U+0307.
    static func simpleLowercase(_ text: String) -> [UInt32] {
        text.unicodeScalars.map { scalar in
            if scalar.value == 0x130 { return 0x69 }
            let mapped = scalar.properties.lowercaseMapping.unicodeScalars
            return mapped.count == 1 ? mapped.first!.value : scalar.value
        }
    }

    /// Indices sorted by `precedes`, ties by position; descending reverses the values only.
    private static func stableOrder(_ count: Int, descending: Bool, _ precedes: (Int, Int) -> Bool) -> [Int] {
        Array(0..<count).sorted { a, b in
            if descending ? precedes(b, a) : precedes(a, b) { return true }
            if descending ? precedes(a, b) : precedes(b, a) { return false }
            return a < b
        }
    }

    /// Android's `FeedItemPermutors.smartShuffle` with its double arithmetic. Equally large podcast groups,
    /// which Android leaves in HashMap order, are placed in ascending podcast ID order (bytewise).
    private static func smartShuffle(_ items: [Values], ascending: Bool) -> [Int] {
        var groups: [[UInt8]: [Int]] = [:]
        var groupOrder: [[UInt8]] = []
        for (index, item) in items.enumerated() {
            let key = Array(item.podcastID.utf8)
            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(index)
        }
        let times = items.map { $0.publicationTime ?? 0 }
        var feeds = groupOrder.map { key in
            (key, stableOrderOf(groups[key]!, descending: !ascending) { times[$0] < times[$1] })
        }
        feeds.sort { a, b in
            if a.1.count != b.1.count { return a.1.count > b.1.count }
            return a.0.lexicographicallyPrecedes(b.0)
        }
        var queue = [Int?](repeating: nil, count: items.count)
        var empty = Array(0..<items.count)
        for (_, members) in feeds {
            let spread = Double(empty.count) / Double(members.count + 1)
            var skipped = 0
            var placed = 0
            var remaining: [Int] = []
            var position = 0
            while position < empty.count {
                let slot = empty[position]
                position += 1
                skipped += 1
                if Double(skipped) >= spread * Double(placed + 1) {
                    queue[slot] = members[placed]
                    placed += 1
                    if placed == members.count {
                        remaining.append(contentsOf: empty[position...])
                        break
                    }
                    continue
                }
                remaining.append(slot)
            }
            precondition(placed == members.count, "smart shuffle left items unplaced")
            empty = remaining
        }
        return queue.map { $0! }
    }

    private static func stableOrderOf(_ indices: [Int], descending: Bool, _ precedes: (Int, Int) -> Bool) -> [Int] {
        stableOrder(indices.count, descending: descending) { precedes(indices[$0], indices[$1]) }.map { indices[$0] }
    }
}
