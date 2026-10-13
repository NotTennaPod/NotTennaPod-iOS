import Foundation

/// SingleFeedSortDialog choices and FeedItemSortQuery's SQLite BINARY ordering.
public enum FeedEpisodeSortOrder: Int, Codable, CaseIterable, Sendable {
    case dateOldest = 1, dateNewest = 2, titleAscending = 3, titleDescending = 4
    case durationShortest = 5, durationLongest = 6, filenameAscending = 7, filenameDescending = 8
    case sizeSmallest = 9, sizeLargest = 10
    case global = 11

    public enum Field: String, CaseIterable, Sendable {
        case title, duration, date, size, filename, global
        public var titleKey: String {
            switch self {
            case .title: "episode_title"
            case .duration: "duration"
            case .date: "date"
            case .size: "size"
            case .filename: "filename"
            case .global: "global_default"
            }
        }
        public static func choices(local: Bool, includesGlobal: Bool = true) -> [Self] {
            [.title, .duration, .date] + (local ? [.filename] : []) + (includesGlobal ? [.global] : [])
        }
    }
    public var field: Field {
        switch self {
        case .dateOldest, .dateNewest: .date
        case .titleAscending, .titleDescending: .title
        case .durationShortest, .durationLongest: .duration
        case .sizeSmallest, .sizeLargest: .size
        case .filenameAscending, .filenameDescending: .filename
        case .global: .global
        }
    }
    public var ascending: Bool { [.dateOldest, .titleAscending, .durationShortest, .filenameAscending, .sizeSmallest].contains(self) }
    public func selecting(_ field: Field) -> Self {
        switch field {
        case .title: self == .titleAscending ? .titleDescending : .titleAscending
        case .duration: self == .durationShortest ? .durationLongest : .durationShortest
        case .date: self == .dateNewest ? .dateOldest : .dateNewest
        case .size: self == .sizeLargest ? .sizeSmallest : .sizeLargest
        case .filename: self == .filenameAscending ? .filenameDescending : .filenameAscending
        case .global: .global
        }
    }
    public func sorted(_ episodes: [LibraryEpisode], global: Self = .dateNewest) -> [LibraryEpisode] {
        let order = self == .global ? (global == .global ? .dateNewest : global) : self
        func compare<T: Comparable>(_ a: T?, _ b: T?) -> Int {
            switch (a, b) {
            case (nil, nil): 0
            case (nil, _): -1
            case (_, nil): 1
            case let (a?, b?): a == b ? 0 : (a < b ? -1 : 1)
            }
        }
        func binary(_ a: String?, _ b: String?) -> Int {
            guard let a, let b else { return a == nil ? (b == nil ? 0 : -1) : 1 }
            if a.utf8.elementsEqual(b.utf8) { return 0 }
            return a.utf8.lexicographicallyPrecedes(b.utf8) ? -1 : 1
        }
        return episodes.sorted { a, b in
            let comparison: Int
            switch order.field {
            case .title: comparison = binary(a.details.title, b.details.title)
            case .filename: comparison = binary(a.details.link, b.details.link)
            case .duration: comparison = compare(a.details.media?.durationMilliseconds, b.details.media?.durationMilliseconds)
            case .size: comparison = compare(a.details.media?.size, b.details.media?.size)
            case .date: comparison = compare(a.details.publicationDate, b.details.publicationDate)
            case .global: comparison = 0
            }
            // SQLite's source row scan retains ID order when the sort key ties.
            if comparison == 0 { return a.id < b.id }
            return order.ascending ? comparison < 0 : comparison > 0
        }
    }
}
