import Foundation
import Testing
@testable import NotTennaPodCore

struct PlaybackSpeedTests {
    @Test func displayConversionMatchesUnchangedJavaAcrossEverySliderSpeedAndBoundaries() throws {
        struct Sample: Decodable { let time: Int32; let speedBits: UInt32; let enabled: Bool; let converted: Int32 }
        struct Fixture: Decodable { let referenceCommit: String; let cases: [Sample] }
        let url = try #require(Bundle.module.url(forResource: "speed-time-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.referenceCommit == "f8c641887e4677237b01b6e942ff8fe20fc8beec")
        #expect(fixture.cases.count == 1_848)
        for sample in fixture.cases {
            #expect(PlaybackSpeed.displayTime(sample.time, speed: Float(bitPattern: sample.speedBits),
                                             respectsSpeed: sample.enabled) == sample.converted)
        }
    }

    @Test func temporaryAndFeedPrecedenceDependsOnMediaIdentity() {
        for global: Float in [0.5, 1, 1.5, 4] {
            for feed: Float in [-1, 0.75, 2] {
                for temporary: Float in [-1, 1.25, 3] {
                    #expect(PlaybackSpeed.resolve(global: global, feed: feed, temporary: temporary,
                        isCurrent: true) == (temporary != -1 ? temporary : (feed != -1 ? feed : global)))
                    #expect(PlaybackSpeed.resolve(global: global, feed: feed, temporary: temporary,
                        isCurrent: false) == (feed != -1 ? feed : global))
                    #expect(PlaybackSpeed.resolve(global: global, feed: feed, temporary: temporary,
                        isCurrent: true, isFeedMedia: false) == global)
                }
            }
        }
    }

    @Test func sliderHasSeventyOneStepsAndClampsOnlyItsControlBounds() {
        #expect(PlaybackSpeed.sliderSpeed(progress: .min) == 0.5)
        #expect(PlaybackSpeed.sliderSpeed(progress: .max) == 4)
        for progress in 0...70 {
            let speed = PlaybackSpeed.sliderSpeed(progress: progress)
            #expect(PlaybackSpeed.sliderProgress(speed: speed) == progress)
        }
        #expect(PlaybackSpeed.sliderProgress(speed: 0.524) == 0)
        #expect(PlaybackSpeed.sliderProgress(speed: 0.526) == 1)
        #expect(PlaybackSpeed.sliderProgress(speed: .infinity) == 70)
        #expect(PlaybackSpeed.sliderProgress(speed: -.infinity) == 0)
        #expect(PlaybackSpeed.sliderProgress(speed: .nan) == 0)
    }

    @Test func queueUsesEachRateAndPreservesNegativeAndJavaOverflowContributions() {
        let queue: [(position: Int32, duration: Int32, speed: Float)] = [(10_000, 40_000, 1.5), (0, 30_000, 0.5), (40_000, 30_000, 2)]
        #expect(PlaybackSpeed.queueTimeLeft(queue, respectsSpeed: false) == 50_000)
        #expect(PlaybackSpeed.queueTimeLeft(queue, respectsSpeed: true) == 75_000)
        #expect(PlaybackSpeed.queueTimeLeft([], respectsSpeed: true) == 0)
        #expect(PlaybackSpeed.queueTimeLeft([(.min, .max, 1)], respectsSpeed: false) == -1)
        #expect(PlaybackSpeed.queueTimeLeft([(0, 16_777_217, 1)], respectsSpeed: false) == 16_777_216)
        #expect(PlaybackSpeed.queueTimeLeft([(0, .max, 1)], respectsSpeed: false) == 2_147_483_648)
    }

    @Test func playerConvertsTheRawRemainderRatherThanSubtractingRoundedDisplays() throws {
        let locale = Locale(identifier: "en_US")
        let ordinary = try #require(PlayerTimePresentation(position: 3_883, duration: 30_040, showRemainingTime: true,
            speed: 2, timeRespectsSpeed: false, locale: locale))
        let adjusted = try #require(PlayerTimePresentation(position: 3_883, duration: 30_040, showRemainingTime: true,
            speed: 2, timeRespectsSpeed: true, locale: locale))
        #expect(ordinary.position == "00:00:03" && ordinary.length == "-00:00:26")
        #expect(adjusted.position == "00:00:01" && adjusted.length == "-00:00:13")
        #expect(adjusted.lengthMilliseconds == 13_078)
        #expect(PlaybackSpeed.displayTime(30_040, speed: 2, respectsSpeed: true)
            - PlaybackSpeed.displayTime(3_883, speed: 2, respectsSpeed: true) == 13_079)
        #expect(PlayerTimePresentation(position: -1, duration: 30_040, showRemainingTime: true,
            speed: 2, timeRespectsSpeed: true) == nil)
    }
}
