import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor
struct EpisodeRowAccessibilityViewTests {
    private func row(position: Int32 = 15_000, playing: Bool = true, played: Bool = false,
                     open: @escaping () -> Void = {}) -> EpisodeRowView {
        var state = EpisodeUserState()
        state.playState = played ? .played : .unplayed
        state.isFavorite = true
        state.positionMilliseconds = position
        let episode = LibraryEpisode(id: 2, details: ParsedEpisode(title: "Episode",
            media: ParsedMedia(url: "https://example.invalid/audio", size: 0, durationMilliseconds: 60_000)),
            userState: state)
        let feed = LibraryFeed(id: 1, source: "fixture://feed", metadata: .init(format: .rss, title: "Feed"), episodes: [episode])
        return EpisodeRowView(feed: feed, episode: episode, queued: true, queueScreen: false,
            showRemainingTime: false, activelyPlaying: playing, downloadAction: {}, open: open)
    }

    private func openControl(in view: UIView) throws -> UIButton {
        if let button = view as? UIButton, button.accessibilityIdentifier == "episode-2" { return button }
        for child in view.subviews {
            if let button = try? openControl(in: child) { return button }
        }
        throw MissingRow()
    }
    private struct MissingRow: Error {}

    @Test(arguments: [false, true])
    func livePositionAndTimeModeUpdateSpokenValueWithoutReplacingAction(played: Bool) throws {
        var opens = 0
        let row = row(played: played) { opens += 1 }
        let button = try openControl(in: row)
        let initial = try #require(button.accessibilityValue)
        try #require(initial.hasSuffix("00:00:15. 00:01:00"))
        let prefix = String(initial.dropLast("00:00:15. 00:01:00".count))
        #expect(prefix.contains(Appearance.text("is_favorite_label")))
        #expect(prefix.contains(Appearance.text("in_queue_label")))
        #expect(prefix.contains(Appearance.text("is_played")) == played)
        for (position, remaining, suffix) in [
            (30_000, false, "00:00:30. 00:01:00"),
            (30_000, true, "00:00:30. -00:00:30"),
            (60_000, true, "00:01:00. 00:00:00"),
            (0, false, "00:00:00. 00:01:00")
        ] {
            row.updatePlaybackPosition(position: Int32(position), duration: 60_000, showRemainingTime: remaining)
            #expect(button.accessibilityValue == prefix + suffix)
            #expect(try openControl(in: row) === button)
            #expect(button.accessibilityLabel == "Episode")
        }
        button.sendActions(for: .touchUpInside)
        #expect(opens == 1)
    }

    @Test func hiddenPositionDoesNotLeakIntoSpokenValueDuringLightweightUpdate() throws {
        let row = row(position: 0, playing: false)
        let button = try openControl(in: row)
        let initial = try #require(button.accessibilityValue)
        try #require(initial.hasSuffix("00:01:00"))
        let prefix = String(initial.dropLast("00:01:00".count))
        row.updatePlaybackPosition(position: 20_000, duration: 60_000, showRemainingTime: true)
        #expect(button.accessibilityValue == prefix + "-00:00:40")
        #expect(button.accessibilityValue?.contains("00:00:20") == false)
    }

    /// Android's row background (`bg_episode_list_item.xml`): the playing episode's row is activated
    /// (`colorSecondaryContainer`) while it plays; selection deactivates every row (`EpisodeItemListAdapter` in action
    /// mode) and stays selection. Playback is never spoken as selected.
    @Test func thePlayingRowShowsItsBackgroundOutsideSelectionAndIsNotSpokenAsSelected() throws {
        let row = row(playing: true)
        let button = try openControl(in: row)
        #expect(!row.showsPlayingBackground, "a row the player does not play has no background")
        row.updateDownload(job: nil, progress: nil, playing: true)
        #expect(row.showsPlayingBackground, "the playing episode's row is activated")
        #expect(!button.accessibilityTraits.contains(.selected), "and is not spoken as selected")
        row.setSelected(false, selectionMode: true)
        #expect(!row.showsPlayingBackground, "selection deactivates it")
        row.setSelected(true, selectionMode: true)
        #expect(button.accessibilityTraits.contains(.selected), "a selected row is selected")
        row.setSelected(false, selectionMode: false)
        #expect(row.showsPlayingBackground, "after selection the playing row is activated again")
        row.updateDownload(job: nil, progress: nil, playing: false)
        #expect(!row.showsPlayingBackground, "playback stopped: no background")
    }

    /// The row's ripple: a press shows on touch-down and goes when the press ends.
    @Test func aPressShowsOnTheRow() throws {
        let row = row()
        let button = try openControl(in: row)
        #expect(!row.showsPressedFeedback)
        button.isHighlighted = true
        #expect(row.showsPressedFeedback, "touch-down shows the press")
        button.isHighlighted = false
        #expect(!row.showsPressedFeedback, "the press ends")
    }
}
