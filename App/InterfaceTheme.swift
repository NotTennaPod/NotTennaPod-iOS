import UIKit
import NotTennaPodCore

/// Full black (`Theme.AntennaPod.TrueBlack`): a window trait that `Appearance` colours read
/// together with the dark interface style. Changing it redraws dynamic colours like a light/dark change does.
struct FullBlackThemeTrait: UITraitDefinition {
    static let defaultValue = false
    static let affectsColorAppearance = true
    static let name = "AntennaPodFullBlack"
    static let identifier = "org.nottennapod.app.fullBlack"
}

/// Applies Settings → User interface → Theme and Full black to windows. Android recreates its
/// activity; here every window of every scene takes the new traits at once, so every screen, sheet and dialog
/// (they inherit the window's traits) is drawn in the new theme.
@MainActor enum InterfaceTheme {
    static let changed = Notification.Name("AntennaPodInterfacePreferencesChanged")

    static func style(for theme: ThemePreference) -> UIUserInterfaceStyle {
        switch theme { case .system: .unspecified; case .light: .light; case .dark: .dark }
    }

    static func apply(_ preferences: InterfacePreferences, to window: UIWindow) {
        window.overrideUserInterfaceStyle = style(for: preferences.theme)
        window.traitOverrides[FullBlackThemeTrait.self] = preferences.blackTheme
    }

    /// Every connected scene's windows, then every main screen re-renders (text, icons and cached colours).
    static func applyEverywhere(_ preferences: InterfacePreferences) {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                apply(preferences, to: window)
                // Screens re-rendered right after a change must already read the new traits. (Not at scene start:
                // forcing it there would load the root screen before the scene has finished installing it.)
                window.updateTraitsIfNeeded()
            }
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
