import UIKit
import NotTennaPodCore

// Theme, Full black and Use episode cover.
extension LibraryViewController {
    /// Rows outside a podcast's own episode list follow "Use episode cover".
    var usesEpisodeCover: Bool { interfacePreferences?.value.useEpisodeCover ?? true }

    func observeInterfacePreferences() {
        NotificationCenter.default.removeObserver(self, name: InterfaceTheme.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(interfacePreferencesChanged), name: InterfaceTheme.changed, object: nil)
        playerView?.useEpisodeCover = usesEpisodeCover
    }

    /// After a saved User interface change (`InterfaceTheme.applyEverywhere`) every main screen redraws in the
    /// new theme and cover choice at once; Android recreates its activity (`UserInterfacePreferencesFragment.java:45–51`).
    @objc func interfacePreferencesChanged() {
        guard isViewLoaded else { return }
        playerView?.useEpisodeCover = usesEpisodeCover
        drawerSignature = nil
        updatePlayer()
        render()
    }
}
