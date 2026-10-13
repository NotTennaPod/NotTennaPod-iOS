import Foundation

public struct TimeDisplayPreferences: Codable, Equatable, Sendable {
    public var showRemainingTime: Bool
    public var timeRespectsSpeed: Bool

    public init(showRemainingTime: Bool = false, timeRespectsSpeed: Bool = false) {
        self.showRemainingTime = showRemainingTime
        self.timeRespectsSpeed = timeRespectsSpeed
    }

    private enum CodingKeys: String, CodingKey { case showRemainingTime, timeRespectsSpeed }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showRemainingTime = try values.decodeIfPresent(Bool.self, forKey: .showRemainingTime) ?? false
        timeRespectsSpeed = try values.decodeIfPresent(Bool.self, forKey: .timeRespectsSpeed) ?? false
    }
}

@MainActor
public final class TimeDisplayPreferenceStore {
    public private(set) var value: TimeDisplayPreferences
    private let file: URL

    public init(file: URL) throws {
        self.file = file
        value = try SavedState.contents(of: file).map { try JSONDecoder().decode(TimeDisplayPreferences.self, from: $0) }
            ?? TimeDisplayPreferences()
    }

    public func update(_ value: TimeDisplayPreferences) throws {
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        self.value = value
    }

    public func toggleRemainingTime() throws {
        var updated = value
        updated.showRemainingTime.toggle()
        try update(updated)
    }
}
