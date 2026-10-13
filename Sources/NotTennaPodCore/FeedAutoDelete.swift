import Foundation

/// FeedPreferences.AutoDeleteAction in the pinned release.
public enum FeedAutoDelete: Int, Codable, CaseIterable, Sendable {
    case global = 0, always = 1, never = 2

    public var titleKey: String {
        switch self {
        case .global: "global_default"
        case .always: "feed_auto_download_always"
        case .never: "feed_auto_download_never"
        }
    }

    public func enabled(global: Bool, local: Bool, isLocalFeed: Bool) -> Bool {
        switch self {
        case .global: global && (!isLocalFeed || local)
        case .always: true
        case .never: false
        }
    }
}

/// The original active player retains the feed attached to its loaded media.
/// Global preferences are read again when playback ends.
public struct PlaybackDeletionPolicy: Equatable, Sendable {
    public var choice: FeedAutoDelete
    public var isLocalFeed: Bool
    public init(choice: FeedAutoDelete = .global, isLocalFeed: Bool = false) {
        self.choice = choice; self.isLocalFeed = isLocalFeed
    }
}
