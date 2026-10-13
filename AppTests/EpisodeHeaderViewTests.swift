import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor
struct EpisodeHeaderViewTests {
    private func feed(title: String? = "Original podcast", image: String? = nil) -> LibraryFeed {
        LibraryFeed(id: 1, source: "https://example.invalid/feed", metadata: ParsedFeed(format: .rss, title: title, imageURL: image), episodes: [])
    }
    private func episode(title: String? = "Original episode") -> LibraryEpisode {
        LibraryEpisode(id: 2, details: ParsedEpisode(title: title, publicationDate: Date(timeIntervalSince1970: 1_700_000_000),
            media: ParsedMedia(url: "https://example.invalid/audio", size: 0, durationMilliseconds: 30_000)))
    }
    private func element<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) throws -> T {
        if let match = view as? T, view.accessibilityIdentifier == id { return match }
        for child in view.subviews {
            if let match = try? element(id, in: child, as: type) { return match }
        }
        throw MissingElement(id: id)
    }
    private struct MissingElement: Error { let id: String }
    private func layout(_ header: EpisodeHeaderView, width: CGFloat = 402) {
        header.frame = CGRect(origin: .zero, size: header.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)))
        header.setNeedsLayout(); header.layoutIfNeeded()
    }

    // ItemFragment.updateAppearance refreshes both titles and the cover on each update.
    @Test func refreshChangesTextAndRelayoutsWithoutReplacingControls() throws {
        let header = EpisodeHeaderView(feed: feed(), episode: episode())
        layout(header)
        let oldHeight = header.bounds.height
        let podcast: UIButton = try element("episodePodcast", in: header)
        let title: UILabel = try element("episodeTitle", in: header)
        let primary: UIButton = try element("episodePrimaryAction", in: header)
        var updated = episode(title: String(repeating: "A substantially longer refreshed episode title ", count: 5))
        updated.details.media?.durationMilliseconds = 92_000
        updated.details.publicationDate = Date(timeIntervalSince1970: 1_750_000_000)
        var updatedFeed = feed(title: "Updated publisher name")
        updatedFeed.customTitle = "My renamed podcast"
        header.update(feed: updatedFeed, episode: updated)
        layout(header)
        #expect(podcast.title(for: .normal) == "My renamed podcast")
        #expect(title.text == updated.details.title)
        #expect(header.bounds.height > oldHeight)
        // Podcast, title, metadata and primary action stay stacked in order after the taller title reflows.
        #expect(title.frame.minY >= podcast.frame.maxY - 0.5)
        let metadata: UIView = try element("episodeMetadata", in: header)
        #expect(metadata.frame.minY >= title.frame.maxY - 0.5)
        #expect(primary.frame.minY >= metadata.frame.maxY - 0.5)
        #expect(title.frame.height >= ceil(title.sizeThatFits(CGSize(width: title.bounds.width, height: .greatestFiniteMagnitude)).height) - 0.5, "Long title is not clipped")
        #expect(try element("episodePrimaryAction", in: header, as: UIButton.self) === primary)
        let duration: UILabel = try element("episodeDuration", in: header)
        #expect(duration.text == "00:01:32")
        let date: UILabel = try element("episodeDate", in: header)
        #expect(date.text == EpisodeRowPresentation.publicationDate(updated.details.publicationDate))
    }

    @Test func refreshClearsAbsentTextDateAndMedia() throws {
        let header = EpisodeHeaderView(feed: feed(), episode: episode())
        var updated = episode(title: nil)
        updated.details.publicationDate = nil; updated.details.media = nil
        header.update(feed: feed(title: nil), episode: updated)
        layout(header)
        #expect(try element("episodeTitle", in: header, as: UILabel.self).text == nil)
        #expect(try element("episodePodcast", in: header, as: UIButton.self).title(for: .normal) == nil)
        let date: UILabel = try element("episodeDate", in: header)
        #expect(date.text?.isEmpty != false)
        #expect(date.accessibilityLabel == nil)
        #expect(try element("episodeDuration", in: header, as: UILabel.self).isHidden)
        #expect(try !element("episodeNoMedia", in: header, as: UILabel.self).isHidden)
    }

    @Test func playbackAndMetadataTicksRetainArtworkAndInteractionTarget() throws {
        let header = EpisodeHeaderView(feed: feed(), episode: episode())
        let cover = try #require(header.subviews.compactMap { $0 as? EpisodeArtworkView }.first)
        let coverButton: UIButton = try element("episodeCover", in: header)
        var opens = 0
        header.openPodcast = { opens += 1 }
        for duration in [0, 30_000, 45_000] as [Int32] {
            var updated = episode(); updated.details.media?.durationMilliseconds = duration
            updated.userState.positionMilliseconds = duration / 2
            header.update(feed: feed(), episode: updated)
            layout(header)
            #expect(header.subviews.compactMap { $0 as? EpisodeArtworkView }.first === cover)
            #expect(try element("episodeCover", in: header, as: UIButton.self) === coverButton)
            #expect(cover.frame == coverButton.frame)
        }
        coverButton.sendActions(for: .touchUpInside)
        #expect(opens == 1)
    }

    @Test func changedCoverInputsReleaseStaleViewsAndKeepCoverButton() throws {
        let header = EpisodeHeaderView(feed: feed(), episode: episode())
        let button: UIButton = try element("episodeCover", in: header)
        // Unsupported URL schemes keep this ownership test independent of networking.
        let variants: [(String?, String?, String?)] = [
            ("fixture:episode-a", nil, "Original podcast"),
            ("fixture:episode-b", nil, "Original podcast"),
            ("fixture:episode-b", "fixture:fallback", "Original podcast"),
            (nil, "fixture:fallback", "Original podcast"),
            (nil, nil, "Renamed podcast"), (nil, nil, nil)
        ]
        for (source, fallback, name) in variants {
            var updated = episode(); updated.details.imageURL = source
            header.update(feed: feed(title: name, image: fallback), episode: updated)
            layout(header)
            // Exactly one cover is shown (no stale artwork stacked underneath), in the cover button's place.
            let covers = header.subviews.compactMap { $0 as? EpisodeArtworkView }
            let replacement = try #require(covers.first)
            #expect(covers.count == 1)
            #expect(replacement.frame == button.frame)
            #expect(replacement.clipsToBounds && replacement.layer.cornerRadius > 0, "Cover keeps rounded corners")
            #expect(try element("episodeCover", in: header, as: UIButton.self) === button)
            #expect(replacement.subviews.compactMap { $0 as? UILabel }.first?.text == name)
        }
    }
    @Test(arguments: [CGFloat(320), 402, 768, 1024], [false, true])
    func subscriptionNoticePreservesWordingPlacementAndPodcastAction(width: CGFloat, textOnly: Bool) throws {
        var currentFeed = feed()
        var item = episode()
        if textOnly { item.details.media = nil }
        let header = EpisodeHeaderView(feed: currentFeed, episode: item)
        layout(header, width: width)
        let baselineHeight = header.bounds.height
        let action: UIButton = try element("episodePrimaryAction", in: header)
        let actionFrame = action.frame
        let notice: UIControl = try element("episodeSubscriptionNotice", in: header)
        #expect(notice.isHidden && notice.frame == .zero)
        var opened = 0
        header.openPodcast = { opened += 1 }
        currentFeed.subscriptionState = .notSubscribed
        header.update(feed: currentFeed, episode: item)
        layout(header, width: width)
        notice.layoutIfNeeded()
        #expect(!notice.isHidden && notice.isAccessibilityElement)
        #expect(notice.accessibilityLabel == "You are not subscribed to this podcast yet. Subscribe for free to access it more easily and keep its playback history.")
        #expect(notice.accessibilityTraits.contains(.button))
        #expect(action.frame == actionFrame)
        #expect(notice.frame.minY > action.frame.maxY && notice.frame.minY - action.frame.maxY < 24, "Notice sits just below the action")
        #expect(abs(notice.frame.midX - width / 2) < 1)
        #expect(notice.frame.width <= width - 32 + 1, "Notice keeps side margins")
        if width <= 402 { #expect(abs(notice.frame.width - (width - 32)) < 1, "On phones the notice spans the content width") }
        let noMedia: UILabel = try element("episodeNoMedia", in: header)
        if textOnly { #expect(noMedia.frame.minY > notice.frame.maxY && noMedia.frame.minY - notice.frame.maxY < 24, "No-media text follows the notice") }
        #expect(noMedia.isHidden == !textOnly)
        #expect(header.bounds.height > baselineHeight)
        let label = try #require(notice.subviews.compactMap { $0 as? UILabel }.first)
        #expect(label.numberOfLines == 0 && label.frame.minX > 0 && label.frame.minY > 0)
        #expect(notice.bounds.contains(label.frame))
        #expect(label.frame.height >= ceil(label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height) - 0.5, "Notice text is not clipped")
        #expect(notice.layer.borderWidth > 0 && notice.layer.cornerRadius > 0, "Outlined, rounded notice")
        let target = header.hitTest(CGPoint(x: notice.frame.midX, y: notice.frame.midY), with: nil)
        #expect(target === notice)
        notice.sendActions(for: .touchUpInside)
        #expect(opened == 1)
        for state in [FeedSubscriptionState.subscribed, .archived] {
            currentFeed.subscriptionState = state
            header.update(feed: currentFeed, episode: item)
            layout(header, width: width)
            #expect(notice.isHidden && notice.frame == .zero)
            #expect(header.bounds.height == baselineHeight)
            #expect(action.frame == actionFrame)
        }
    }

}
