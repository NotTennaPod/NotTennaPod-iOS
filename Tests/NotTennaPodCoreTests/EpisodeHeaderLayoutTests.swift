import Foundation
import Testing
@testable import NotTennaPodCore

struct EpisodeHeaderLayoutTests {
    /// Same frame as the Android capture within one point (`scale` pixels).
    private func near(_ actual: [Int], _ expected: [Int], scale: Double) -> Bool {
        actual.count == expected.count && zip(actual, expected).allSatisfy { abs(Double($0 - $1)) <= scale }
    }
    private func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.5) -> Bool { abs(a - b) <= tolerance }
    private func near(_ a: CGRect, _ b: CGRect) -> Bool {
        near(a.minX, b.minX) && near(a.minY, b.minY) && near(a.width, b.width) && near(a.height, b.height)
    }

    @Test func recordedAndroidHeaderFrames() {
        let scale = 2.625
        let layout = EpisodeHeaderLayout(width: 1080 / scale, podcastHeight: 51 / scale,
            titleHeight: 57 / scale, metadataHeight: 51 / scale, scale: scale)
        func pixels(_ rect: CGRect) -> [Int] {
            [rect.minX, rect.minY + 242 / scale, rect.maxX, rect.maxY + 242 / scale].map { Int(($0 * scale).rounded()) }
        }
        #expect(near(pixels(layout.cover), [42, 248, 189, 395], scale: scale))
        #expect(near(pixels(layout.podcast), [231, 242, 1038, 293], scale: scale))
        #expect(near(pixels(layout.title), [231, 293, 1038, 350], scale: scale))
        #expect(near(pixels(layout.metadata), [231, 350, 1038, 401], scale: scale))
        #expect(near(pixels(layout.primary), [42, 401, 540, 528], scale: scale))
        #expect(near(pixels(layout.secondary), [540, 401, 1038, 528], scale: scale))
        #expect(abs(layout.height * scale - 289) <= scale)
    }

    @Test(arguments: [320.0, 402, 768, 1024], [1.0, 2, 2.625, 3])
    func adaptiveCompositionAndMirroring(width: Double, scale: Double) {
        let ltr = EpisodeHeaderLayout(width: width, podcastHeight: 40, titleHeight: 100, metadataHeight: 20, scale: scale)
        let rtl = EpisodeHeaderLayout(width: width, podcastHeight: 40, titleHeight: 100, metadataHeight: 20, scale: scale, rightToLeft: true)
        // Text beside the cover, buttons side by side below the metadata,
        // divider below the buttons; RTL mirrors the same composition.
        #expect(ltr.podcast.minX > ltr.cover.maxX)
        #expect(near(ltr.primary.maxX, ltr.secondary.minX))
        #expect(near(ltr.primary.minY, ltr.metadata.maxY))
        #expect(near(ltr.divider.minY, ltr.primary.maxY))
        #expect(near(ltr.height, rtl.height))
        for (left, right) in [(ltr.cover,rtl.cover), (ltr.title,rtl.title), (ltr.primary,rtl.primary), (ltr.secondary,rtl.secondary)] {
            #expect(near(left.minX, width - right.maxX, 1))
            #expect(near(left.width, right.width) && near(left.height, right.height))
        }
    }

    @Test func shortMetadataCentersCoverAndKeepsActionSlots() {
        let layout = EpisodeHeaderLayout(width: 402, podcastHeight: 10, titleHeight: 10, metadataHeight: 10, scale: 3)
        #expect(near(layout.cover.minY, 0))
        #expect(near(layout.primary.minY, 56))
        #expect(near(layout.primary.width, layout.secondary.width))
    }
    @Test func sourceNoticeMarginsAndOrderingAtAndroidDensity() {
        let scale = 2.625
        // XML-derived frames with supplied text/notice measurements, not runtime captures.
        let layout = EpisodeHeaderLayout(width: 1080 / scale, podcastHeight: 51 / scale,
            titleHeight: 57 / scale, metadataHeight: 51 / scale, scale: scale,
            subscriptionNoticeSize: CGSize(width: 900 / scale, height: 180 / scale), noMediaHeight: 36 / scale)
        func pixels(_ rect: CGRect) -> [Int] {
            [rect.minX, rect.minY, rect.maxX, rect.maxY].map { Int(($0 * scale).rounded()) }
        }
        #expect(near(pixels(layout.subscriptionNotice), [90, 307, 990, 487], scale: scale))
        #expect(near(pixels(layout.noMedia), [42, 508, 1038, 544], scale: scale))
        #expect(near(pixels(layout.divider), [42, 544, 1038, 547], scale: scale))
        #expect(abs(layout.height * scale - 547) <= scale)
    }

    @Test(arguments: [320.0, 402, 768, 1024], [1.0, 2, 2.625, 3])
    func noticesKeepActionAnchorsAndCollapseWithoutExtraMargins(width: Double, scale: Double) {
        let base = EpisodeHeaderLayout(width: width, podcastHeight: 20, titleHeight: 50, metadataHeight: 20, scale: scale)
        for notice in [CGSize.zero, CGSize(width: 250, height: 80)] {
            for noMedia in [0.0, 24] {
                let layout = EpisodeHeaderLayout(width: width, podcastHeight: 20, titleHeight: 50,
                    metadataHeight: 20, scale: scale, subscriptionNoticeSize: notice, noMediaHeight: noMedia)
                let rtl = EpisodeHeaderLayout(width: width, podcastHeight: 20, titleHeight: 50,
                    metadataHeight: 20, scale: scale, rightToLeft: true, subscriptionNoticeSize: notice, noMediaHeight: noMedia)
                #expect(near(layout.primary, base.primary) && near(layout.secondary, base.secondary))
                #expect(near(layout.cover, base.cover) && near(layout.title, base.title))
                #expect(near(layout.noMedia, rtl.noMedia) && near(layout.subscriptionNotice, rtl.subscriptionNotice))
                #expect(near(layout.noMedia.maxY, layout.divider.minY))
                if notice == .zero {
                    #expect(near(layout.subscriptionNotice, .zero))
                    #expect(near(layout.noMedia.minY, base.divider.minY))
                } else {
                    let margin = (8 * scale).rounded() / scale
                    #expect(near(layout.subscriptionNotice.minY - base.divider.minY, margin))
                    #expect(near(layout.noMedia.minY - layout.subscriptionNotice.maxY, margin))
                    #expect(near(layout.subscriptionNotice.midX, width / 2))
                }
                if notice == .zero && noMedia == 0 { #expect(near(layout.height, base.height)) }
            }
        }
    }

}
