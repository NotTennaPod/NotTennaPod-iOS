import UIKit
import NotTennaPodCore

@MainActor final class PlaybackIntervalController: SourceSingleChoiceController {
    init(direction: PlaybackIntervalDirection, preferences: PlaybackIntervalPreferenceStore) {
        super.init(title: Appearance.text(direction.titleKey), identifier: direction.preferenceKey,
            choices: PlaybackIntervalPreferences.choices.map { seconds in
                (String(seconds), "\(seconds.formatted(.number.grouping(.never))) \(Appearance.text("time_seconds"))")
            }, selectedIndex: preferences.value.selectedIndex(for: direction)) { index in
                var value = preferences.value
                value.select(index, for: direction)
                try preferences.update(value)
            }
    }
    required init?(coder: NSCoder) { fatalError() }
}
