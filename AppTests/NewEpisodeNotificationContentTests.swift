import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor struct NewEpisodeNotificationContentTests {
    @Test func sourcePluralWordingUsesTotalAndPreservesPodcastTitle() {
        let text = NewEpisodeNotificationContent.text
        #expect(text.title(1) == "New episode")
        #expect(text.title(2) == "New episodes")
        #expect(text.message(1, "Show %2$@") == "Show %2$@ has a new episode")
        #expect(text.message(27, "A & B") == "A & B has 27 new episodes")
        #expect(text.summary == "Your subscriptions have new episodes.")
    }
    /// The picture reduced to a 32×32 grid of RGB values (row-major, top row first).
    private func grid(_ image: UIImage) throws -> [[Int]] {
        let cg = try #require(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let context = try #require(CGContext(data: &bytes, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        return (0..<(32 * 32)).map { index in bytes[(index * 4)..<(index * 4 + 3)].map(Int.init) }
    }

    /// A podcast without artwork gets its generated cover in the notification: a square picture
    /// with a visible pattern, not a blank or missing image.
    @Test func generatedCoverNotificationArtworkIsAVisiblePattern() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let data = try #require(try await NewEpisodeNotificationContent.artwork(.init(feedID: 1, title: "Show",
            imageURL: "antennapod_generative_cover:https://example.org/feed", count: 1), store: store))
        let image = try #require(UIImage(data: data))
        #expect(image.size.width == image.size.height && image.size.width >= 128)
        let colors = Set(try grid(image).map { $0.map { $0 / 32 } })
        #expect(colors.count > 1, "a pattern, not a blank square")
        try await store.close()
    }

    /// A wide podcast image is centre-cropped to a square (Android's 128 dp centre crop), not squashed or letterboxed.
    @Test func wideCoverIsCentreCroppedToASquare() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        // Red | green | blue thirds: the square centre crop is all green.
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let wide = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 100), format: format).pngData { context in
            for (index, color) in [UIColor.red, .green, .blue].enumerated() {
                color.setFill(); context.fill(CGRect(x: index * 100, y: 0, width: 100, height: 100))
            }
        }
        let previous = EpisodeArtworkView.remoteLoader
        EpisodeArtworkView.remoteLoader = { url in (wide, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
        defer { EpisodeArtworkView.remoteLoader = previous }
        let data = try #require(try await NewEpisodeNotificationContent.artwork(.init(feedID: 1, title: "Show",
            imageURL: "https://example.org/wide.png", count: 1), store: store))
        let image = try #require(UIImage(data: data))
        #expect(image.size.width == image.size.height)
        let pixels = try grid(image)
        for index in [32 * 16 + 1, 32 * 16 + 16, 32 * 16 + 30, 1 * 32 + 16, 30 * 32 + 16] {
            let rgb = pixels[index]
            #expect(rgb[1] > 200 && rgb[0] < 60 && rgb[2] < 60, "cell \(index) is \(rgb), expected green")
        }
        try await store.close()
    }
}
