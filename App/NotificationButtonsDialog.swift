import UIKit
import NotTennaPodCore

/// Settings → User interface → "Set notification buttons" (UserInterfacePreferencesFragment.java:122–191).
/// A multi-choice dialog titled "Set notification buttons" with Cancel and Confirm; ticking only edits the
/// draft, Confirm saves it, Cancel/outside tap/back keep the saved choice.
///
/// Adaptation: only Skip episode and Playback speed are offered, in Android's
/// order; Android's "exactly two" rule (and its error) is not applied because with two offered buttons it
/// would allow no change at all, so any selection, including none, is saved.
enum NotificationButtonsDialog {
    static let identifier = "prefFullNotificationButtons"

    @MainActor static func make(store: NotificationButtonPreferenceStore,
                                onSaved: (@MainActor () -> Void)? = nil) -> SourceSingleChoiceController {
        let offered = NotificationButton.offered
        let selected = Set(offered.indices.filter { store.value.shows(offered[$0]) })
        return SourceSingleChoiceController(title: Appearance.text("pref_full_notification_buttons_title"),
            identifier: identifier, choices: offered.map { (String($0.rawValue), Appearance.text($0.titleKey)) },
            selectedIndex: nil, selectedIndices: selected, onConfirm: { indices in
                try store.select(indices)
                onSaved?()
            }, confirmTitle: Appearance.text("confirm_label"), onSelect: { _ in })
    }
}
