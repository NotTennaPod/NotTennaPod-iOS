import Foundation

public struct PlaybackPreferences: Equatable, Sendable {
    public var skip = FeedSkipPreferences()
    public var end = PlaybackEndPreferences()
    public var enqueueLocation: EnqueueLocation = .back
    public var followQueue = true
    public var speed: Float = 1
    public var skipSilence = false

    public init() {}
}

/// Supplied by the owner from source selection, network preferences/path and route state.
public struct PlaybackStreamingAccess: Equatable, Sendable {
    public var needsStreaming: Bool
    public var streamingAllowed: Bool
    public var isCasting: Bool
    public init(needsStreaming: Bool, streamingAllowed: Bool, isCasting: Bool = false) {
        self.needsStreaming = needsStreaming
        self.streamingAllowed = streamingAllowed
        self.isCasting = isCasting
    }
}
