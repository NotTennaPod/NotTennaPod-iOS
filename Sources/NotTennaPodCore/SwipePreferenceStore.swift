import Foundation

public enum InboxSwipePreferenceError: Error, Equatable, Sendable {
    case unknownScreen(String)
    case actionNotAllowed(screen: SwipeScreen, action: SwipeAction)
}

/// No entry means the first gesture opens configuration; confirmed defaults remain a distinct state.
public struct SwipePreferences: Codable, Equatable, Sendable {
    private var screens: [String: SwipeConfiguration] = [:]
    public init() {}
    public func configuration(for screen: SwipeScreen) -> SwipeConfiguration? { screens[screen.rawValue] }

    public mutating func set(_ configuration: SwipeConfiguration, for screen: SwipeScreen) throws {
        try Self.validate(configuration, screen: screen)
        screens[screen.rawValue] = configuration
    }
    private static func validate(_ configuration: SwipeConfiguration, screen: SwipeScreen) throws {
        for action in [configuration.left, configuration.right] where !screen.actions.contains(action) {
            throw InboxSwipePreferenceError.actionNotAllowed(screen: screen, action: action)
        }
    }
    private enum CodingKeys: String, CodingKey { case screens }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        screens = try values.decode([String: SwipeConfiguration].self, forKey: .screens)
        for (key, configuration) in screens {
            guard let screen = SwipeScreen(rawValue: key) else { throw InboxSwipePreferenceError.unknownScreen(key) }
            try Self.validate(configuration, screen: screen)
        }
    }
}

@MainActor public final class SwipePreferenceStore {
    public private(set) var value: SwipePreferences
    private let file: URL

    public init(file: URL) throws {
        self.file = file
        value = try SavedState.contents(of: file).map { try JSONDecoder().decode(SwipePreferences.self, from: $0) } ?? .init()
    }
    public func draft(for screen: SwipeScreen) -> SwipeDraft {
        .init(screen: screen, configuration: value.configuration(for: screen) ?? screen.defaultConfiguration)
    }
    /// Validate and atomically replace durable bytes before publishing any in-memory change.
    public func confirm(_ draft: SwipeDraft) throws {
        var updated = value
        try updated.set(draft.configuration, for: draft.screen)
        try JSONEncoder().encode(updated).write(to: file, options: .atomic)
        value = updated
    }

    public enum Gesture: Equatable, Sendable {
        case disabled
        case configure
        case action(SwipeAction)
    }
    public func gesture(on screen: SwipeScreen, direction: EpisodeSwipeDirection) -> Gesture {
        guard let configuration = value.configuration(for: screen) else { return .configure }
        return configuration.enabled ? .action(configuration.action(direction)) : .disabled
    }
}
