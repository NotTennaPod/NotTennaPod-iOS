import Foundation
import CoreGraphics
import Testing
@testable import NotTennaPodCore

struct EpisodeRowTests {
    private let locale = Locale(identifier: "en_US")
    private func episode(position: Int32 = 0, duration: Int32 = 30_000) -> LibraryEpisode {
        var result = LibraryEpisode(id: 1, details: ParsedEpisode(title: "Episode", media: ParsedMedia(url: "https://example.test/a.mp3", size: 120_017, durationMilliseconds: duration)))
        result.userState.positionMilliseconds = position
        return result
    }

    @Test func referenceQueueMetadataAndDuration() {
        let row = EpisodeRowPresentation(episode: episode(), inQueue: true, queueScreen: true, locale: locale)
        #expect(row.duration == "00:00:30")
        #expect(row.position == nil && row.progressPercent == nil && row.indicators.isEmpty)
        #expect(row.action == .download && row.opacity == 1)
        #expect(EpisodeRowPresentation.fileSize(120_017, locale: locale) == "120 kB")
        let date = Date(timeIntervalSince1970: 1_789_128_000)
        #expect(EpisodeRowPresentation.publicationDate(date, now: date, locale: locale, timeZone: .gmt) == "Sep 11")
    }

    @Test func actionPriorityFollowsSourceEvenWhenSignalsOverlap() {
        var item = episode()
        item.userState.isDownloaded = true
        #expect(EpisodeRowPresentation(episode: item, currentlyPlaying: true, localFeed: true, downloading: true, streamOverDownload: true).action == .pause)
        #expect(EpisodeRowPresentation(episode: item, localFeed: true, downloading: true, streamOverDownload: true).action == .playLocal)
        #expect(EpisodeRowPresentation(episode: item, downloading: true, streamOverDownload: true).action == .play)
        item.userState.isDownloaded = false
        #expect(EpisodeRowPresentation(episode: item, downloading: true, streamOverDownload: true).action == .cancelDownload)
        #expect(EpisodeRowPresentation(episode: item, streamOverDownload: true).action == .stream)
        item.details.media = nil
        for state in EpisodePlayState.allCases {
            item.userState.playState = state
            let row = EpisodeRowPresentation(episode: item, currentlyPlaying: true, downloading: true)
            #expect(row.action == .markPlayed && row.actionVisible == (state != .played))
            #expect(!row.activated && row.duration == nil && row.position == nil)
        }
    }

    @Test func playedOpacityAndOrderedStatusIndicators() {
        for state in EpisodePlayState.allCases {
            for favorite in [false, true] {
                for queued in [false, true] {
                    for queueScreen in [false, true] {
                        var item = episode()
                        item.userState.playState = state
                        item.userState.isFavorite = favorite
                        item.details.media?.mimeType = "video/mp4"
                        let row = EpisodeRowPresentation(episode: item, inQueue: queued, queueScreen: queueScreen)
                        var expected: [EpisodeRowPresentation.Indicator] = []
                        if state == .new { expected.append(.inbox) }
                        expected.append(.video)
                        if favorite { expected.append(.favorite) }
                        if queued && !queueScreen { expected.append(.queue) }
                        #expect(row.indicators == expected)
                        #expect(row.opacity == (state == .played ? 0.5 : 1))
                    }
                }
            }
        }
    }

    @Test func positionAndRemainingTimeIncludePlayedAndOverrunEpisodes() {
        var item = episode(position: 3_883, duration: 30_040)
        item.userState.playState = .played
        let row = EpisodeRowPresentation(episode: item, showRemainingTime: true, locale: locale)
        #expect(row.position == "00:00:03" && row.duration == "-00:00:26" && row.progressPercent == 12)
        let overrun = EpisodeRowPresentation(episode: episode(position: 40_000), showRemainingTime: true, locale: locale)
        #expect(overrun.duration == "00:00:00" && overrun.progressPercent == 100)
        #expect(EpisodeRowPresentation(episode: episode(position: 1, duration: 0)).duration == nil)
        #expect(EpisodeRowPresentation(episode: episode(position: 1, duration: 0)).progressPercent == 100)
        #expect(EpisodeRowPresentation(episode: episode(duration: 0), activelyPlaying: true).progressPercent == 0)
        #expect(EpisodeRowPresentation(episode: episode(position: -1), activelyPlaying: true).progressPercent == 0)
        #expect(EpisodeRowPresentation(episode: episode(), currentlyPlaying: true).position == nil)
        #expect(EpisodeRowPresentation(episode: episode(), activelyPlaying: true, locale: locale).position == "00:00:00")
    }

    @Test func downloadProgressHasMinimumVisibleStrokeAndSeparateQueuedState() {
        for percent in [-1, 0, 1, 40, 100] {
            let row = EpisodeRowPresentation(episode: episode(), downloading: true, queuedDownload: true, downloadPercent: percent)
            #expect(row.downloadProgress == max(Float(percent) * 0.01, 0.01))
            #expect(row.downloadIndeterminate)
        }
        var item = episode()
        item.userState.isDownloaded = true
        #expect(EpisodeRowPresentation(episode: item).downloadProgress == 1)
        #expect(!EpisodeRowPresentation(episode: item, queuedDownload: true).downloadIndeterminate)
    }

    @Test func timeAndFileSizeBoundaries() {
        let times: [(Int32, String)] = [(.min,"00:00:00"), (-1,"00:00:00"), (0,"00:00:00"), (999,"00:00:00"), (1_000,"00:00:01"), (3_600_000,"01:00:00"), (.max,"596:31:23")]
        for (value, expected) in times { #expect(EpisodeRowPresentation.time(value, locale: locale) == expected) }
        let sizes: [(Int64, String)] = [(-1,""), (0,""), (1,"1 B"), (900,"900 B"), (901,"0.90 kB"), (1_000,"1.0 kB"), (9_999,"10.0 kB"), (10_000,"10 kB"), (900_000,"900 kB"), (900_001,"0.90 MB")]
        for (value, expected) in sizes { #expect(EpisodeRowPresentation.fileSize(value, locale: locale) == expected) }
    }

    @Test func dateYearBoundaryUsesCalendarYearAndTimeZoneRatherThanElapsedYear() {
        let date = Date(timeIntervalSince1970: 1_767_225_599)
        let now = date.addingTimeInterval(1)
        #expect(EpisodeRowPresentation.publicationDate(date, now: now, locale: locale, timeZone: .gmt) == "Dec 31, 2025")
        #expect(EpisodeRowPresentation.publicationDate(date, now: now, locale: locale, timeZone: TimeZone(secondsFromGMT: -28_800)!) == "Dec 31")
        #expect(EpisodeRowPresentation.publicationDate(nil) == "")
    }

    @Test func layoutMatchesIndependentAndroidQueueAndFeedBounds() {
        let scale = 2.625
        for queue in [false, true] {
            let layout = EpisodeRowLayout(width: 1080 / scale, titleHeight: 110 / scale, metadataHeight: 39 / scale,
                                          progressHeight: 39 / scale, draggable: queue, scale: scale)
            // Same row composition as the Android capture, within one point.
            #expect(abs(layout.height * scale - 256) <= scale)
            #expect(abs(layout.cover.minX * scale - (queue ? 74 : 43)) <= scale)
            #expect(abs(layout.cover.width * scale - 147) <= scale)
            #expect(abs(layout.text.minX * scale - (queue ? 263 : 232)) <= scale)
            #expect(abs(layout.text.minY * scale - 34) <= scale)
            #expect(abs(layout.text.maxX * scale - 901) <= scale)
            #expect(abs(layout.action.minX * scale - 922) <= scale)
        }
    }

    @Test func layoutMirrorsRegionsAndExpandsWithText() {
        for width in [320.0, 402, 768, 1024] {
            for titleHeight in [20.0, 40, 80] {
                let ltr = EpisodeRowLayout(width: width, titleHeight: titleHeight, metadataHeight: 16, progressHeight: 16, draggable: true)
                let rtl = EpisodeRowLayout(width: width, titleHeight: titleHeight, metadataHeight: 16, progressHeight: 16, draggable: true, rightToLeft: true)
                #expect(abs(ltr.height - rtl.height) <= 0.5)
                #expect(abs(ltr.text.maxX + rtl.text.minX - CGFloat(width)) <= 0.5)
                #expect(abs(ltr.cover.maxX + rtl.cover.minX - CGFloat(width)) <= 0.5)
                #expect(abs(ltr.action.maxX + rtl.action.minX - CGFloat(width)) <= 0.5)
                #expect(ltr.cover.maxX <= ltr.text.minX && ltr.text.maxX <= ltr.action.minX)
            }
        }
    }

    @Test func generatedCoverMatchesUnchangedJavaDrawingOperations() throws {
        struct Case: Decodable { var model: String; var width: Int; var height: Int; var lines: [[Int64]] }
        struct Fixture: Decodable { var cases: [Case] }
        let url = try #require(Bundle.module.url(forResource: "cover-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.cases.count == 42)
        // The placeholder cover for a podcast without artwork shows the same
        // stripes and colours as Android (geometry within half a pixel).
        func float(_ bits: Int64) -> Float { Float(bitPattern: UInt32(bitPattern: Int32(truncatingIfNeeded: bits))) }
        for test in fixture.cases {
            let actual = GenerativeCoverPattern(model: test.model, width: test.width, height: test.height).lines
            #expect(actual.count == test.lines.count, "\(test.model): lines \(actual.count)/\(test.lines.count)")
            for (line, expected) in zip(actual, test.lines) {
                let geometry = [line.x1, line.y1, line.x2, line.y2, line.width]
                #expect(zip(geometry, expected.prefix(5)).allSatisfy { abs($0 - float($1)) <= 0.5 }, "\(test.model): \(geometry)")
                #expect(Int64(line.color) == expected[5] && Int64(line.tint) == expected[6], "\(test.model): colour")
            }
        }
    }
}
