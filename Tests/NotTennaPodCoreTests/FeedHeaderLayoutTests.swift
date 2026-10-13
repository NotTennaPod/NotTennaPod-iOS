import Foundation
import Testing
@testable import NotTennaPodCore

struct FeedHeaderLayoutTests {
    /// Same place and size as a person sees it: every edge within one point.
    private func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }
    private func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 1 }

    @Test func wideWindowResourceInsetSurvivesANarrowerContentPane() {
        let narrowWindow = FeedHeaderLayout(width: 700, titleHeight: 30, authorHeight: 20, configurationWidth: 999)
        let wideWindow = FeedHeaderLayout(width: 700, titleHeight: 30, authorHeight: 20, configurationWidth: 1000)
        #expect(close(narrowWindow.hero.minX, 0) && close(narrowWindow.cover.minX, 16))
        #expect(close(wideWindow.hero.minX, 56) && close(wideWindow.hero.width, 588) && close(wideWindow.cover.minX, 72))
        #expect(close(wideWindow.info.minX, 200) && close(wideWindow.title.minX, 212))
        #expect(close(narrowWindow.height, wideWindow.height))
    }

    @Test func independentlyCapturedAndroidHeaderMatchesAllAvailableBoundsWithinTwoPixels() throws {
        struct Capture: Decodable {
            let density: CGFloat
            let widthPixels, heightPixels: CGFloat
            let frames: [String: [CGFloat]]
        }
        let url = try #require(Bundle.module.url(forResource: "feed-header-capture", withExtension: "json", subdirectory: "Fixtures"))
        let capture = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: url))
        let density = capture.density
        let title = try #require(capture.frames["title"]), author = try #require(capture.frames["author"])
        let layout = FeedHeaderLayout(width: capture.widthPixels / density, titleHeight: title[3] / density,
                                      authorHeight: author[3] / density, scale: density)
        let actual = ["cover":layout.cover, "actionStrip":layout.actionStrip, "info":layout.info,
                      "filter":layout.filter, "settings":layout.settings, "title":layout.title, "author":layout.author]
        // Same composition as the Android capture: every edge within 2 device pixels (under 1 pt).
        for (key, rectangle) in actual {
            let pixels = [rectangle.minX, rectangle.minY, rectangle.width, rectangle.height].map { $0 * density }
            let expected = try #require(capture.frames[key])
            #expect(zip(pixels, expected).allSatisfy { abs($0 - $1) <= 2 }, "Original captured bounds for \(key): \(pixels) vs \(expected)")
        }
        #expect(abs(layout.height * density - capture.heightPixels) <= 2)
    }

    @Test func allStatusCombinationsPreserveOriginalOrderAndInsets() {
        for mask in 0..<8 {
            let failure = mask & 1 != 0, filtered = mask & 2 != 0, disabled = mask & 4 != 0
            for width in [320, 402, 834, 999, 1000, 1366] as [CGFloat] {
                let inset: CGFloat = width >= 1000 ? 56 : 0
                let layout = FeedHeaderLayout(width: width, titleHeight: 30, authorHeight: 20,
                    failureTextHeight: failure ? 40 : nil, filteredTextHeight: filtered ? 20 : nil,
                    updatesDisabledTextHeight: disabled ? 20 : nil)
                #expect(close(layout.cover, CGRect(x: inset + 16, y: 8, width: 124, height: 124)))
                #expect(close(layout.info, CGRect(x: inset + 144, y: 108, width: 48, height: 48)))
                #expect(close(layout.title.maxY, layout.author.minY) && close(layout.author.maxY, 92))
                // Status rows appear only when needed, in Android's order (failure, filtered, updates
                // disabled), each below the previous one without overlapping, and the header grows to fit.
                var y: CGFloat = 156
                if failure {
                    #expect(close(layout.failure, CGRect(x: inset + 16, y: y + 8, width: width - 2 * inset - 32, height: 56)))
                    y += 72
                } else { #expect(layout.failure == .zero) }
                if filtered { #expect(close(layout.filtered.minY, y) && close(layout.filtered.height, 24)); y += 24 }
                else { #expect(layout.filtered == .zero) }
                if disabled { #expect(close(layout.updatesDisabled.minY, y) && close(layout.updatesDisabled.height, 24)); y += 24 }
                else { #expect(layout.updatesDisabled == .zero) }
                #expect(close(layout.height, y))
            }
        }
    }

    @Test func directionMirrorsAnchorsWithoutChangingVerticalComposition() {
        for width in [320, 402, 834, 1000] as [CGFloat] {
            for scale in [1, 2, 2.625, 3] as [CGFloat] {
                let left = FeedHeaderLayout(width: width, titleHeight: 32, authorHeight: 19, scale: scale)
                let right = FeedHeaderLayout(width: width, titleHeight: 32, authorHeight: 19, scale: scale, rightToLeft: true)
                for (a, b) in zip([left.cover, left.title, left.author, left.info, left.filter, left.settings],
                                  [right.cover, right.title, right.author, right.info, right.filter, right.settings]) {
                    #expect(abs(a.minX + b.maxX - width) < 0.5) // Mirrored within half a point.
                    #expect(a.minY == b.minY && a.size == b.size)
                }
                #expect(left.height == right.height)
            }
        }
    }

    @Test func freshHeaderVisibilityPreservesSubscriptionAndStatusVariants() {
        // Fresh-view expectations from FeedItemlistFragment.refreshHeaderView.
        // This does not model its 24-hour preview refresh side effect or stale views.
        let expectedButtons: [FeedSubscriptionState: [Bool]] = [
            .subscribed: [true, true, true, false, false],
            .notSubscribed: [false, false, false, true, false],
            .archived: [true, false, false, false, true]
        ]
        for state in FeedSubscriptionState.allCases {
            for mask in 0..<16 {
                let failed = mask & 1 != 0, keep = mask & 2 != 0, filter = mask & 4 != 0, interacted = mask & 8 != 0
                let value = FeedHeaderPresentation(state: state, failed: failed, keepUpdated: keep,
                                                   hasFilter: filter, hasInteracted: interacted)
                #expect([value.info, value.filter, value.settings, value.subscribe, value.restore] == expectedButtons[state])
                #expect(value.failure == failed)
                switch state {
                case .subscribed:
                    #expect(value.updatesDisabled == !keep && value.filtered == filter)
                    #expect(!value.description && !value.subscriptionNotice)
                case .archived:
                    #expect(value.updatesDisabled && value.filtered == filter)
                    #expect(!value.description && !value.subscriptionNotice)
                case .notSubscribed:
                    #expect(!value.updatesDisabled && !value.filtered && value.description)
                    #expect(value.subscriptionNotice == interacted)
                }
            }
        }
    }
}
