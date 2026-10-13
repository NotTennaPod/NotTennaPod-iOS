public enum EnqueueLocation: String, CaseIterable, Codable, Sendable {
    case back = "BACK"
    case front = "FRONT"
    case afterCurrentlyPlaying = "AFTER_CURRENTLY_PLAYING"
    case random = "RANDOM"

    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .back
    }

    /// `enqueue_location_options`, in the order of `enqueue_location_values` (`arrays.xml:186–199`).
    public var titleKey: String {
        switch self {
        case .back: "enqueue_location_back"
        case .front: "enqueue_location_front"
        case .afterCurrentlyPlaying: "enqueue_location_after_current"
        case .random: "enqueue_location_random"
        }
    }
}

public struct QueueMedia: Equatable, Sendable {
    public var downloadURL: String?

    public init(downloadURL: String?) {
        self.downloadURL = downloadURL
    }
}

public struct QueueEntry: Equatable, Sendable {
    public let episodeID: Int64
    public var media: QueueMedia?

    public init(episodeID: Int64, media: QueueMedia?) {
        self.episodeID = episodeID
        self.media = media
    }
}

public enum PlayingItem: Equatable, Sendable {
    case episode(Int64)
    case external
}

public enum QueuePlacement {
    public static func insertionIndex(
        location: EnqueueLocation,
        queue: [QueueEntry],
        playing: PlayingItem?,
        isDownloading: (String?) -> Bool,
        randomIndex: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }
    ) -> Int {
        let start: Int
        switch location {
        case .back:
            return queue.count
        case .front:
            start = 0
        case .afterCurrentlyPlaying:
            if case let .episode(id) = playing {
                start = queue.firstIndex { $0.episodeID == id }.map { $0 + 1 } ?? 0
            } else {
                start = 0
            }
        case .random:
            let range = 0...queue.count
            let index = randomIndex(range)
            precondition(range.contains(index))
            return index
        }
        return queue.indices.dropFirst(start).first { index in
            guard let media = queue[index].media else { return true }
            return !isDownloading(media.downloadURL)
        } ?? queue.count
    }
}
