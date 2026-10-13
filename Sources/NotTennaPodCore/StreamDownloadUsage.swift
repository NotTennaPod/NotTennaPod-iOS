import Foundation

/// Local on-demand configuration history from UsageStatistics.java. This is
/// separate from playback statistics and is never sent to a service.
public struct StreamDownloadUsage: Codable, Equatable, Sendable {
    public enum Action: Int, Codable, Sendable { case stream = 0, download = 1 }
    public private(set) var movingAverage: Float = 0.5
    public private(set) var streamExecutions: Int32 = 0
    public private(set) var downloadExecutions: Int32 = 0
    public init() {}

    public mutating func log(_ action: Action) {
        switch action {
        case .stream: streamExecutions &+= 1
        case .download: downloadExecutions &+= 1
        }
        // Preserve Java float operations, including 1 - 0.8f rounding.
        let weight: Float = 0.8
        movingAverage = weight * movingAverage + (1 - weight) * Float(action.rawValue)
    }

    public func hasSignificantBias(to action: Action, hidden: Bool) -> Bool {
        !hidden && abs(Float(action.rawValue) - movingAverage) < Float(0.1)
    }

    /// A suggestion replaces this tap's action. Dismissal/choice does not replay it.
    public func suggestion(for action: EpisodeDetailActions.Action, preferences: NavigationPreferences) -> Action? {
        switch action {
        case .stream where !preferences.streamOverDownload && hasSignificantBias(to: .stream, hidden: preferences.streamingSuggestionHidden):
            .stream
        case .download where preferences.streamOverDownload && hasSignificantBias(to: .download, hidden: preferences.streamingSuggestionHidden):
            .download
        default: nil
        }
    }
}

/// Atomic local persistence without publishing navigation changes for every log.
@MainActor public final class StreamDownloadUsageStore {
    public private(set) var value: StreamDownloadUsage
    private let file: URL
    public init(file: URL) throws {
        self.file = file
        value = try SavedState.contents(of: file).map { try JSONDecoder().decode(StreamDownloadUsage.self, from: $0) } ?? .init()
    }

    public func log(_ action: StreamDownloadUsage.Action) throws {
        var next = value
        next.log(action)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        value = next
    }
}
