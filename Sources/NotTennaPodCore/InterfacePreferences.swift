import Foundation

/// Settings → User interface → Theme (`prefTheme`). The raw values are Android's stored strings:
/// `UserPreferences.setTheme` writes "0" (Light), "1" (Dark) or "system"; `getTheme` reads anything else as system.
public enum ThemePreference: String, CaseIterable, Sendable {
    case system
    case light = "0"
    case dark = "1"

    public init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .system }
}

/// `ThemeSwitcher.readThemeValue`: the theme the screens are drawn in.
public enum ResolvedTheme: String, Sendable {
    case light = "LIGHT", dark = "DARK", black = "BLACK"
}

/// The User interface preferences: Theme, Full black and Use episode cover (Android keys `prefTheme`,
/// `prefThemeBlack`, `prefEpisodeCover`). Kept outside the library database, like SharedPreferences,
/// so a database import leaves them unchanged.
public struct InterfacePreferences: Codable, Equatable, Sendable {
    public var theme: ThemePreference
    public var blackTheme: Bool
    public var useEpisodeCover: Bool

    public init(theme: ThemePreference = .system, blackTheme: Bool = false, useEpisodeCover: Bool = true) {
        self.theme = theme; self.blackTheme = blackTheme; self.useEpisodeCover = useEpisodeCover
    }

    /// Full black only applies while the dark theme is in effect (`TS:53–55`).
    public func resolvedTheme(systemIsDark: Bool) -> ResolvedTheme {
        let dark = switch theme { case .system: systemIsDark; case .light: false; case .dark: true }
        return dark ? (blackTheme ? .black : .dark) : .light
    }

    private enum CodingKeys: String, CodingKey {
        case theme = "prefTheme", blackTheme = "prefThemeBlack", useEpisodeCover = "prefEpisodeCover"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        theme = ThemePreference(stored: try values.decodeIfPresent(String.self, forKey: .theme))
        blackTheme = try values.decodeIfPresent(Bool.self, forKey: .blackTheme) ?? false
        useEpisodeCover = try values.decodeIfPresent(Bool.self, forKey: .useEpisodeCover) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(theme.rawValue, forKey: .theme)
        try values.encode(blackTheme, forKey: .blackTheme)
        try values.encode(useEpisodeCover, forKey: .useEpisodeCover)
    }
}

/// Saved beside the library as `interface-preferences.json`. Atomic writes publish only saved state; an unreadable
/// file reports an error rather than being replaced with defaults (the app's preference-store convention).
@MainActor
public final class InterfacePreferenceStore {
    public private(set) var value: InterfacePreferences
    private let file: URL

    public init(file: URL) throws {
        self.file = file
        value = try SavedState.contents(of: file).map { try JSONDecoder().decode(InterfacePreferences.self, from: $0) }
            ?? InterfacePreferences()
    }

    public func update(_ value: InterfacePreferences) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: file, options: .atomic)
        self.value = value
    }
}
