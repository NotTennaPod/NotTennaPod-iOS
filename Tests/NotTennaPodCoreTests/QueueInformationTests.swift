import Foundation
import Testing
@testable import NotTennaPodCore

struct QueueInformationTests {
    @Test func matchesUnchangedAndroidMethodsAcrossAllSliderRatesAndBoundaryQueues() throws {
        struct Item: Decodable { let position: Int32; let duration: Int32; let speedBits: UInt32 }
        struct Sample: Decodable {
            let items: [Item?]; let enabled: Bool; let actionMode: Bool
            let remaining: Int64; let text: String; let visible: Bool
        }
        struct Fixture: Decodable { let referenceCommit: String; let cases: [Sample] }
        let url = try #require(Bundle.module.url(forResource: "queue-information-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.referenceCommit == "f8c641887e4677237b01b6e942ff8fe20fc8beec")
        #expect(fixture.cases.count == 2146)
        for sample in fixture.cases {
            var speeds = PlaybackSpeedPreferences()
            let items = sample.items.enumerated().map { index, item in
                let id = Int64(index + 1)
                speeds.feeds[id] = item.map { Float(bitPattern: $0.speedBits) }
                return QueueInformation.Item(episodeID: id, feedID: id, position: item?.position ?? 0, duration: item?.duration)
            }
            let info = QueueInformation(items: items, speeds: speeds, respectsSpeed: sample.enabled, selecting: sample.actionMode)
            #expect(info.remainingMilliseconds == sample.remaining)
            #expect(info.isVisible == sample.visible)
            let duration = info.durationText { key, count in
                let unit = key == "time_hours_quantified" ? "hour" : "minute"
                return "\(count) \(unit)\(count == 1 ? "" : "s")"
            }
            #expect("\(info.count) episode\(info.count == 1 ? "" : "s") • \(duration) left" == sample.text)
        }
    }

    @Test func resolvesTemporaryFeedAndGlobalSpeedsPerQueuedMediaAndCountsMissingMedia() {
        var speeds = PlaybackSpeedPreferences()
        speeds.global = 2; speeds.feeds[10] = 3
        speeds.currentEpisodeID = 1; speeds.temporary = 4
        let items: [QueueInformation.Item] = [
            .init(episodeID: 1, feedID: 10, position: 0, duration: 120_000),
            .init(episodeID: 2, feedID: 10, position: 0, duration: 120_000),
            .init(episodeID: 3, feedID: 20, position: 0, duration: 120_000),
            .init(episodeID: 4, feedID: 20, position: 0, duration: nil)
        ]
        let info = QueueInformation(items: items, speeds: speeds, respectsSpeed: true)
        #expect(info.count == 4 && info.remainingMilliseconds == 130_000)
        #expect(QueueInformation(items: items, speeds: speeds, respectsSpeed: false).remainingMilliseconds == 360_000)
        speeds.currentEpisodeID = nil
        #expect(QueueInformation(items: items, speeds: speeds, respectsSpeed: true).remainingMilliseconds == 140_000)
    }
}
