import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor
struct FeedAppBarViewTests {
    private func solid(_ color: UIColor) -> CGImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { renderer in
            color.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.cgImage!
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let data = try #require(image.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        return (0..<4).map { bytes[y * image.bytesPerRow + x * 4 + $0] }
    }
    @Test func backgroundDarkensArtworkMoreForListThanInformation() throws {
        let source = solid(UIColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        let list = try #require(FeedBackgroundRenderer.render(source, width: 20, height: 10, tint: 102))
        let info = try #require(FeedBackgroundRenderer.render(source, width: 20, height: 10, tint: 130))
        let listPixel = try pixel(list, x: 5, y: 5), infoPixel = try pixel(info, x: 5, y: 5)
        // Both are visibly dimmed, opaque versions of the artwork colour; the list header is darker.
        for value in [listPixel, infoPixel] {
            #expect(value[0] < 200 && value[0] > 60 && value[0] > value[1] && value[1] > value[2] && value[3] == 255)
        }
        #expect(Int(infoPixel[0]) > Int(listPixel[0]) + 10)
        #expect(list.width == 20 && list.height == 10)
        #expect(FeedBackgroundRenderer.render(source, width: 0, height: 20, tint: 130) == nil)
    }
    @Test func generativeBackgroundLoadsAndClearsWhenArtworkChanges() async throws {
        let feed = LibraryFeed(id: 1, source: "https://example.org/feed", metadata: ParsedFeed(format: .rss,
            title: "Artwork", imageURL: "antennapod_generative_cover:https://example.org/feed"), episodes: [])
        let header = SubscribedFeedHeaderView(feed: feed)
        let appBar = FeedAppBarView(header: header, information: false)
        appBar.frame = CGRect(x: 0, y: 0, width: 200, height: 212)
        appBar.setNeedsLayout(); appBar.layoutIfNeeded()
        let image = try #require(appBar.subviews.compactMap { $0 as? UIImageView }.first)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while image.image == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(image.image != nil)
        // Cancel a resize render and remove the source while it is in flight.
        appBar.frame.size.width = 500; appBar.setNeedsLayout(); appBar.layoutIfNeeded()
        let withoutArtwork = LibraryFeed(id: feed.id, source: feed.source,
            metadata: ParsedFeed(format: .rss, title: "Artwork"), episodes: [])
        header.update(feed: withoutArtwork, hasFilter: false, keepUpdated: true)
        #expect(image.image == nil)
        await appBar.waitForArtwork()
        #expect(image.image == nil)
    }

    @Test func redrawnBarShowsTheFinishedBackgroundAtOnce() async throws {
        // A cover already on screen (in the shared cover cache), as on a podcast page being redrawn.
        let source = "https://example.invalid/blur-\(UUID()).png"
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        ArtworkImageCache.store(UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40), format: format).image { renderer in
            UIColor.orange.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }, source: source, maxPixels: 400)
        let feed = LibraryFeed(id: 7, source: "https://example.org/blur", metadata: ParsedFeed(format: .rss,
            title: "Blur", imageURL: source), episodes: [])
        func bar() -> (FeedAppBarView, UIImageView?) {
            let appBar = FeedAppBarView(header: SubscribedFeedHeaderView(feed: feed), information: false)
            appBar.frame = CGRect(x: 0, y: 0, width: 300, height: 212)
            appBar.setNeedsLayout(); appBar.layoutIfNeeded()
            return (appBar, appBar.subviews.compactMap { $0 as? UIImageView }.first)
        }
        let (first, firstImage) = bar()
        let shown = try #require(firstImage)
        await first.waitForArtwork()
        let blurred = try #require(shown.image)
        // The next redraw shows the same finished background immediately, never the dark placeholder.
        let (_, secondImage) = bar()
        #expect(secondImage?.image === blurred)
    }

    @Test func backgroundKeepsTopArtworkOpaque() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { renderer in
            UIColor.red.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            UIColor.blue.setFill(); renderer.fill(CGRect(x: 0, y: 32, width: 64, height: 32))
        }
        let result = try #require(FeedBackgroundRenderer.render(image.cgImage!, width: 64, height: 32, tint: 102))
        // The header shows the top of the artwork (red), not its lower half (blue), fully opaque.
        for y in [0, 20] {
            let value = try pixel(result, x: 30, y: y)
            #expect(value[0] > 60 && value[2] < 20 && value[3] == 255)
        }
    }
}
