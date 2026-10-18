import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Mounted Home components: source `home_section.xml` header, `horizontal_itemlist_item.xml` card,
/// horizontal strips (RTL-mirrored) and the Configure dialog's reorder semantics.
@MainActor @Suite(.serialized)
struct HomeSectionsViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if let match = view as? T, view.accessibilityIdentifier == id { return match }
        return view.subviews.lazy.compactMap { find(id, in: $0, as: type) }.first
    }
    private func feed(_ id: Int64 = 1) -> LibraryFeed {
        var parsed = ParsedFeed(format: .rss); parsed.title = "Feed \(id)"
        return LibraryFeed(id: id, source: "https://home.test/\(id)", metadata: parsed, episodes: [])
    }
    private func episode(_ id: Int64, position: Int32 = 0) -> LibraryEpisode {
        var details = ParsedEpisode(); details.title = "Episode \(id) with a title that wraps onto a second line"
        details.publicationDate = Date(timeIntervalSince1970: 1_790_000_000)
        details.media = ParsedMedia(url: "https://home.test/\(id).mp3", size: 1, mimeType: "audio/mpeg", durationMilliseconds: 60_000)
        var state = EpisodeUserState(); state.positionMilliseconds = position
        return LibraryEpisode(id: id, details: details, userState: state)
    }

    @Test(arguments: [false, true]) func headerPlacesTitleStartAndMoreEnd(rightToLeft: Bool) throws {
        var tapped = 0
        let header = HomeSectionHeader(section: .inbox, moreTitle: "Inbox", badge: "99+", onShuffle: nil, onMore: { tapped += 1 })
        header.semanticContentAttribute = rightToLeft ? .forceRightToLeft : .forceLeftToRight
        header.frame = CGRect(x: 0, y: 0, width: 402, height: HomeSectionHeader.height); header.layoutIfNeeded()
        let title: UILabel = try #require(find("homeSectionTitle-InboxSection", in: header))
        let more: UIButton = try #require(find("homeMore-InboxSection", in: header))
        let badge: UILabel = try #require(find("homeInboxBadge", in: header))
        #expect(title.text == "See what's new" && badge.text == "99+")
        // Title (then badge) at the leading edge, More at the trailing edge, mirrored in RTL.
        if rightToLeft {
            #expect(title.frame.maxX < 402 && title.frame.maxX > 402 - 32 && more.frame.minX > 0 && more.frame.minX < 24)
            #expect(badge.frame.maxX <= title.frame.minX + 0.5 && more.frame.maxX <= badge.frame.minX + 0.5)
        } else {
            #expect(title.frame.minX > 0 && title.frame.minX < 32 && more.frame.maxX < 402 && more.frame.maxX > 402 - 24)
            #expect(badge.frame.minX >= title.frame.maxX - 0.5 && more.frame.minX >= badge.frame.maxX - 0.5)
        }
        #expect(more.frame.width <= 402 * 0.4 + 0.5 && title.frame.width <= 402 * 0.6 + 0.5)
        #expect(title.accessibilityTraits.contains(.header))
        more.sendActions(for: .touchUpInside); #expect(tapped == 1)
    }

    @Test func surpriseHeaderHasShuffle() throws {
        var shuffled = 0
        let header = HomeSectionHeader(section: .surprise, moreTitle: "Episodes", badge: nil, onShuffle: { shuffled += 1 }, onMore: {})
        header.frame = CGRect(x: 0, y: 0, width: 402, height: HomeSectionHeader.height); header.layoutIfNeeded()
        let shuffle: UIButton = try #require(find("homeShuffle", in: header))
        #expect(shuffle.accessibilityLabel == "Shuffle suggestions")
        shuffle.sendActions(for: .touchUpInside); #expect(shuffled == 1)
    }

    @Test func cardShowsActionInCornerAndOpens() throws {
        var opened = 0, acted = 0
        let card = HomeEpisodeCard(feed: feed(), episode: episode(7, position: 30_000), library: nil, playing: false,
                                   action: { acted += 1 }, open: { opened += 1 })
        card.actionButton.update(episode: episode(7, position: 30_000), job: nil, progress: nil)
        card.frame = CGRect(x: 0, y: 0, width: HomeEpisodeCard.width, height: HomeEpisodeCard.height); card.layoutIfNeeded()
        #expect(card.layer.cornerRadius > 0, "Rounded card")
        // Action button in the cover's bottom-trailing corner, a full touch target, inside the card.
        let button = card.actionButton.frame
        #expect(button.width >= 44 && button.height >= 44 && card.bounds.contains(button))
        #expect(button.midX > card.bounds.midX && button.maxY > card.bounds.width / 2 && button.maxY <= card.bounds.width + 0.5)
        #expect(card.actionButton.cardStyle && card.actionButton.accessibilityLabel == "Download")
        card.actionButton.sendActions(for: .touchUpInside); #expect(acted == 1)
        card.sendActions(for: .touchUpInside); #expect(opened == 1)
        #expect(card.accessibilityIdentifier == "homeEpisode-7")
    }

    @Test(arguments: [false, true]) func stripsStartAtLeadingInsetAndMirror(rightToLeft: Bool) {
        let covers = (1...4).map { HomeFeedCover(feed: feed($0), open: {}) }
        let strip = HomeStrip(items: covers, pitch: HomeFeedCover.pitch, itemSize: CGSize(width: 96, height: 96), identifier: "strip")
        strip.semanticContentAttribute = rightToLeft ? .forceRightToLeft : .forceLeftToRight
        strip.frame = CGRect(x: 0, y: 0, width: 402, height: 112); strip.layoutIfNeeded()
        // First item starts at the leading inset; order mirrors in RTL; equal, non-overlapping items all scrollable into view.
        let xs = covers.map(\.frame.minX)
        if rightToLeft {
            let inset = strip.contentSize.width - covers[0].frame.maxX
            #expect(inset > 0 && inset < 24 && xs == xs.sorted(by: >))
        } else { #expect(covers[0].frame.minX > 0 && covers[0].frame.minX < 24 && xs == xs.sorted()) }
        #expect(covers.allSatisfy { abs($0.frame.width - covers[0].frame.width) < 0.5 && $0.frame.width >= 88 })
        #expect(zip(covers.sorted { $0.frame.minX < $1.frame.minX }, covers.sorted { $0.frame.minX < $1.frame.minX }.dropFirst()).allSatisfy { $0.frame.maxX <= $1.frame.minX + 0.5 })
        #expect(covers.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= strip.contentSize.width + 0.5 })
    }

    @Test func configureListHidesAcrossTheHiddenHeaderAndNeverAboveShown() throws {
        let list = HomeConfigurationList(shown: HomeSection.allCases, hidden: [])
        list.frame = CGRect(origin: .zero, size: list.sizeThatFits(CGSize(width: 360, height: 1000))); list.layoutIfNeeded()
        func move(_ section: HomeSection, _ name: String) -> Bool {
            let row = find("homeConfigure-\(section.rawValue)", in: list) as UIView?
            guard let action = row?.accessibilityCustomActions?.first(where: { $0.name == name }) else { return false }
            return action.actionHandler?(action) ?? false
        }
        #expect(!move(.queue, "Move up"), "Nothing moves above Shown")
        #expect(move(.downloads, "Move down"), "Downloads crosses the Hidden header")
        #expect(list.shownSections == [.queue, .inbox, .surprise, .classics] && list.hiddenSections == [.downloads])
        #expect((find("homeConfigure-DownloadsSection", in: list) as UIView?)?.accessibilityValue == "Hidden")
        #expect(HomeSectionPreferences.confirmed(shown: list.shownSections, hidden: list.hiddenSections).sections == [.queue, .inbox, .surprise, .classics])
        #expect(move(.downloads, "Move up") && list.hiddenSections.isEmpty)
    }
}
