/// MainActivity's ordered back callbacks. System-owned exit remains with the host.
public enum NavigationBackAction: Equatable, Sendable {
    case closeDrawer, collapsePlayer, popChild, openDefault(String), openDrawer, system
}

public enum NavigationBackPolicy {
    public static func action(preferences: NavigationPreferences, rootTag: String, childDepth: Int,
                              playerExpanded: Bool, drawerOpen: Bool, persistentDrawer: Bool,
                              settingsVisible: Bool = false) -> NavigationBackAction {
        // Settings is a separate source Activity; its back does not control the main player.
        if settingsVisible { return childDepth > 0 ? .popChild : .system }
        if drawerOpen && !persistentDrawer { return .closeDrawer }
        if playerExpanded { return .collapsePlayer }
        if childDepth > 0 { return .popChild }
        if preferences.defaultPage != "remember" && preferences.defaultPage != rootTag {
            return .openDefault(preferences.defaultPage)
        }
        if preferences.backButtonOpensDrawer && !preferences.bottomNavigation && !persistentDrawer { return .openDrawer }
        return .system
    }
}
