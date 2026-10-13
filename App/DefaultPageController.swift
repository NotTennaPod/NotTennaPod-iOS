import UIKit
import NotTennaPodCore

/// MaterialListPreference commits a tapped option and dismisses; Cancel is inert.
@MainActor final class DefaultPageController: SourceSingleChoiceController {
    init(preferences: NavigationPreferenceStore) {
        super.init(title: Appearance.text("pref_default_page"), identifier: "defaultPage",
            choices: NavigationPreferences.defaultPageChoices.map { tag in
                (tag, NavigationDestination(rawValue: tag).map(Appearance.title) ?? Appearance.text("remember_last_page"))
            }, selectedIndex: preferences.value.selectedDefaultPageIndex) { index in
                var value = preferences.value
                guard value.selectDefaultPage(at: index) else { return }
                try preferences.update(value)
            }
    }
    required init?(coder: NSCoder) { fatalError() }
}
