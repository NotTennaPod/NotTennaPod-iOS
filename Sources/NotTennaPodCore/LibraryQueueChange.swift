public struct LibraryQueueChange: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case added(episodeID: Int64, index: Int)
        case removed(episodeID: Int64)
        case moved(episodeID: Int64, index: Int)
        case cleared
        /// The whole queue was permuted (Sort sheet, or Keep sorted after an addition).
        case sorted
    }

    public var events: [Event]
    public var episodeIDs: [Int64]
    public var requestsAutoDownload: Bool
}
