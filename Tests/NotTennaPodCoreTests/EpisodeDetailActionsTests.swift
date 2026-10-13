import Foundation
import Testing
@testable import NotTennaPodCore

struct EpisodeDetailActionsTests {
    private struct Oracle: Decodable {
        struct Case: Decodable {
            struct Expected: Decodable {
                let primary, secondary: EpisodeDetailActions.Action
                let primaryVisible, secondaryVisible, indeterminate: Bool
                let progress: Float?
                let primaryLabel, primaryIcon, secondaryLabel, secondaryIcon: String
            }
            let hasMedia, played, local, downloaded, playing, downloading, queued: Bool
            let linkKind, percent: Int
            let expected: Expected
        }
        let referenceCommit: String
        let cases: [Case]
    }

    @Test func bothSlotsMatchOriginalSelectionVisibilityLabelsIconsAndProgress() throws {
        let url = try #require(Bundle.module.url(forResource: "episode-detail-actions-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        #expect(oracle.referenceCommit == "f8c641887e4677237b01b6e942ff8fe20fc8beec")
        #expect(oracle.cases.count == 1536)
        for (index, item) in oracle.cases.enumerated() {
            var episode = LibraryEpisode(id: 1, details: ParsedEpisode(title: "Episode",
                link: item.linkKind == 0 ? nil : item.linkKind == 1 ? "" : "https://example.test",
                media: item.hasMedia ? ParsedMedia(url: "fixture", size: 0, durationMilliseconds: 30000) : nil))
            episode.userState.playState = item.played ? .played : .unplayed
            episode.userState.isDownloaded = item.downloaded
            let initial = episode
            let actual = EpisodeDetailActions(episode: episode, localFeed: item.local, currentlyPlaying: item.playing,
                downloading: item.downloading, queuedDownload: item.queued, downloadPercent: item.percent)
            let expected = item.expected
            #expect(actual.primary.action == expected.primary, "case \(index)")
            #expect(actual.secondary.action == expected.secondary, "case \(index)")
            #expect(actual.primary.visible == expected.primaryVisible, "case \(index)")
            #expect(actual.secondary.visible == expected.secondaryVisible, "case \(index)")
            #expect(actual.downloadProgress == expected.progress, "case \(index)")
            #expect(actual.downloadIndeterminate == expected.indeterminate, "case \(index)")
            #expect(actual.primary.action.labelKey == expected.primaryLabel, "case \(index)")
            #expect(actual.primary.action.icon == expected.primaryIcon, "case \(index)")
            #expect(actual.secondary.action.labelKey == expected.secondaryLabel, "case \(index)")
            #expect(actual.secondary.action.icon == expected.secondaryIcon, "case \(index)")
            #expect(episode == initial)
        }
    }
}
