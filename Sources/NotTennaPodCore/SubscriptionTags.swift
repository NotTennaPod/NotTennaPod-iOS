import Foundation

/// Tag chips on Subscriptions and Archive (`DBReader.getAllTags`, `SubscriptionTagAdapter`,
/// `SubscriptionFragment.loadSubscriptionsAndTags`).
public enum SubscriptionTagChips {
    public struct Chip: Equatable, Sendable {
        /// `#root` (All), `#untagged` (Untagged) or a real tag title.
        public let tag: String
        /// Unfiltered members of the screen's state, in the feed-list (title) order.
        public let feedIDs: [Int64]
        /// Only real tags have the Rename/Delete long-press menu.
        public var isTag: Bool { !FeedTags.equal(tag, FeedTags.root) && !FeedTags.equal(tag, FeedTags.untagged) }
    }

    /// `getAllTags(state)`: All first, every tag of a feed of this state (except `#root`) in a
    /// stable case-insensitive order over `HashMap` iteration, then Untagged when a feed is untagged.
    public static func chips(_ all: [LibraryFeed], state: FeedSubscriptionState) -> [Chip] {
        let feeds = SubscriptionListQueries.preOrder(all).filter { $0.subscriptionState == state }
        var untagged: [Int64] = []
        var tags = FeedTagOrder.Builder(capacity: 16)
        var members: [[UInt16]: [Int64]] = [:]
        for feed in feeds {
            let feedTags = FeedTagOrder.preferences(feed.tags).values
            if isUntagged(feedTags) { untagged.append(feed.id) }
            for tag in feedTags where !FeedTags.equal(tag, FeedTags.root) {
                tags.insert(tag)
                members[Array(tag.utf16), default: []].append(feed.id)
            }
        }
        var result = tags.values.enumerated().sorted { lhs, rhs in
            let value = SubscriptionListQueries.compareToIgnoreCase(lhs.element, rhs.element)
            return value == 0 ? lhs.offset < rhs.offset : value < 0
        }.map { Chip(tag: $0.element, feedIDs: members[Array($0.element.utf16)] ?? []) }
        result.insert(Chip(tag: FeedTags.root, feedIDs: feeds.map(\.id)), at: 0)
        if !untagged.isEmpty { result.append(Chip(tag: FeedTags.untagged, feedIDs: untagged)) }
        return result
    }

    /// Untagged: the set is empty or exactly `{#root}` (`DBReader:726–727`).
    static func isUntagged(_ tags: [String]) -> Bool {
        tags.isEmpty || (tags.count == 1 && FeedTags.equal(tags[0], FeedTags.root))
    }

    /// The row is shown only when a chip other than All/Untagged exists.
    public static func rowVisible(_ chips: [Chip]) -> Bool { chips.contains(where: \.isTag) }

    /// Real-tag chip text: up to 20 UTF-16 units as is, otherwise the first 19 plus "…". Android's cut
    /// can split a surrogate pair (half an emoji); the cut moves before the pair instead.
    public static func label(_ tag: String) -> String {
        let units = Array(tag.utf16)
        guard units.count > 20 else { return tag }
        let cut = UTF16.isLeadSurrogate(units[18]) ? 18 : 19
        return String(decoding: units[..<cut], as: UTF16.self) + "…"
    }

    /// What the selected chip shows: All is the whole (filtered, ordered) list; another chip is that
    /// tag's members from the same load. A chip without visible feeds falls back to All.
    public static func shown(selected: String, in result: SubscriptionListQueries.Result) -> (tag: String, feeds: [LibraryFeed]) {
        guard !FeedTags.equal(selected, FeedTags.root),
              let folder = result.folders.first(where: { FeedTags.equal($0.title, selected) }) else {
            return (FeedTags.root, result.feeds)
        }
        return (folder.title, folder.feeds)
    }
}

/// Tag rename and delete (`RenameFeedDialog.renameTag`, `TagMenuHandler`, `NavDrawerFragment`).
public enum FeedTagEdit {
    /// `tags.remove(old); tags.add(new)` on the feed's in-memory preference set. Renaming to a tag the
    /// feed already has merges them; a case-only rename is a rename.
    public static func renamed(_ tags: [String], from old: String, to new: String) -> [String] {
        var result = rebuilt(tags) { !FeedTags.equal($0, old) }
        result.insert(new)
        return result.values
    }

    /// `tags.remove(tag)`. An empty result is stored as "" and reads back as `#root` (main list, Untagged).
    public static func deleted(_ tags: [String], _ tag: String) -> [String] {
        rebuilt(tags) { !FeedTags.equal($0, tag) }.values
    }

    /// Defect prevention: Android accepts empty text (blank chips and folders),
    /// `#root` (the tag silently becomes "show in main list") and `#untagged` (a second Untagged chip).
    /// Those are rejected; anything else is used exactly as typed, untrimmed.
    public static func acceptsRename(_ text: String) -> Bool {
        let units = Array(text.utf16)
        guard units.contains(where: { $0 > 32 }) else { return false }
        return !FeedTags.equal(text, FeedTags.root) && !FeedTags.equal(text, FeedTags.untagged)
    }

    /// The feeds a chip/folder rename or delete changes: every feed of that state carrying the tag,
    /// regardless of the subscriptions filter. Subscriptions chips and drawer folders act on subscribed
    /// feeds (Android's drawer limits this to filter-visible feeds, a defect), Archive
    /// chips on archived feeds (copied).
    public static func members(of tag: String, in feeds: [LibraryFeed], state: FeedSubscriptionState) -> [Int64] {
        SubscriptionTagChips.chips(feeds, state: state).first { FeedTags.equal($0.tag, tag) && $0.isTag }?.feedIDs ?? []
    }

    /// Java `HashSet.remove` keeps the table and the other entries' order.
    static func rebuilt(_ tags: [String], keeping: (String) -> Bool) -> FeedTagOrder.Builder {
        let current = FeedTagOrder.preferences(tags)
        var result = FeedTagOrder.Builder(capacity: current.capacity)
        for name in current.values where keeping(name) { result.insert(name) }
        return result
    }
}

/// The stored effect of each tag and bulk edit, shared by the app and the host checks. Every edit is one
/// transaction over the given feeds, applied in list order to each feed's current stored values.
extension FeedLibraryStore {
    /// Tags dialog OK for one or several feeds.
    public func saveTags(_ draft: FeedTags, feedIDs: [Int64]) throws {
        try updatePreferences(feedIDs: feedIDs) { _, preferences in preferences.tags = draft.saved(onto: preferences.tags) }
    }
    /// Rename tag. Invalid text writes nothing.
    public func renameTag(_ old: String, to new: String, feedIDs: [Int64]) throws {
        guard FeedTagEdit.acceptsRename(new), !FeedTags.equal(old, new) else { return }
        try updatePreferences(feedIDs: feedIDs) { _, preferences in
            preferences.tags = FeedTagEdit.renamed(preferences.tags, from: old, to: new)
        }
    }
    /// Delete tag: the tag leaves the feeds; feeds and their other tags stay.
    public func deleteTag(_ tag: String, feedIDs: [Int64]) throws {
        try updatePreferences(feedIDs: feedIDs) { _, preferences in preferences.tags = FeedTagEdit.deleted(preferences.tags, tag) }
    }
    /// Keep updated, Episode notifications, Include in auto downloads, Delete after playing.
    public func applyBulk(_ preference: FeedBulkPreference, feedIDs: [Int64]) throws {
        try updatePreferences(feedIDs: feedIDs) { _, preferences in preference.apply(to: &preferences) }
    }
}
