import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor
struct FeedStatisticsCardsViewTests {
    private typealias Card = FeedStatisticsCardsView.Card
    private typealias Content = FeedStatisticsCardsView.Content
    private var contents: [Card: Content] {
        [.playbackTime: .init(value: "1.0 hours", subtitle: "played"),
         .episodesStarted: .init(value: "1 episode", subtitle: "started"),
         .spaceDownloaded: .init(value: "1.0 kB", subtitle: "space taken"),
         .durationTotal: .init(value: "10.0 hours", subtitle: "total"),
         .episodesTotal: .init(value: "12 episodes", subtitle: "total"),
         .episodesDownloaded: .init(value: "2 episodes", subtitle: "downloaded"),
         .expectedNextEpisode: .init(value: "Any day now", subtitle: "next episode (estimate)"),
         .episodeSchedule: .init(value: "weekly, Monday", subtitle: "release schedule")]
    }
    private func element<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if view.accessibilityIdentifier == id { return view as? T }
        for child in view.subviews { if let result = element(id, in: child, as: type) { return result } }
        return nil
    }
    private func layout(_ view: FeedStatisticsCardsView, width: CGFloat) {
        view.frame = CGRect(origin: .zero, size: view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)))
        view.setNeedsLayout(); view.layoutIfNeeded()
    }

    @Test func realSnapshotFormatsEverySourceCardAndRefreshesDisabledState() throws {
        let now = Date(timeIntervalSince1970: 1_735_819_200)
        var played = EpisodeUserState()
        played.playState = .played; played.downloadDate = now
        var feed = LibraryFeed(id: 1, source: "https://example.test/feed", metadata: ParsedFeed(format: .rss, title: "Podcast"), episodes: [
            LibraryEpisode(id: 1, details: ParsedEpisode(publicationDate: now.addingTimeInterval(-86_400),
                media: ParsedMedia(url: "fixture://one", size: 1000, durationMilliseconds: 3_600_000)), userState: played),
            LibraryEpisode(id: 2, details: ParsedEpisode(publicationDate: now,
                media: ParsedMedia(url: "fixture://two", size: 0, durationMilliseconds: 3_600_000)))])
        let formatter = StatisticsTextFormatter(locale: Locale(identifier: "en-US"), timeZone: TimeZone(secondsFromGMT: 0)!, now: now)
        let snapshot = try #require(try FeedStatisticsSnapshot(feed: feed, now: now, timeZone: formatter.timeZone))
        let texts = FeedStatisticsCardsView.contents(snapshot: snapshot, formatter: formatter)
        let expected: [Card: Content] = [
            .playbackTime: .init(value: "1.0 hours", subtitle: "played"),
            .episodesStarted: .init(value: "1 episode", subtitle: "started"),
            .spaceDownloaded: .init(value: "1.0 kB", subtitle: "space taken"),
            .durationTotal: .init(value: "2.0 hours", subtitle: "total"),
            .episodesTotal: .init(value: "2 episodes", subtitle: "total"),
            .episodesDownloaded: .init(value: "1 episode", subtitle: "downloaded"),
            .expectedNextEpisode: .init(value: "Jan 3", subtitle: "next episode (estimate)"),
            .episodeSchedule: .init(value: "daily", subtitle: "release schedule")]
        #expect(texts == expected)
        let view = FeedStatisticsCardsView(detailed: true)
        view.update(snapshot: snapshot, formatter: formatter); layout(view, width: 402)
        for (id, expected) in expected {
            let card = try #require(element("statistics.\(id.rawValue)", in: view, as: UIView.self))
            #expect(element("statisticsValue", in: card, as: UILabel.self)?.text == expected.value)
            #expect(element("statisticsSubtitle", in: card, as: UILabel.self)?.text == expected.subtitle)
        }
        feed.keepUpdated = false
        let disabled = try #require(try FeedStatisticsSnapshot(feed: feed, now: now, timeZone: formatter.timeZone))
        view.update(snapshot: disabled, formatter: formatter); layout(view, width: 402)
        for id: Card in [.expectedNextEpisode, .episodeSchedule] {
            let card = try #require(element("statistics.\(id.rawValue)", in: view, as: UIView.self))
            #expect(element("statisticsValue", in: card, as: UILabel.self)?.text == Appearance.text("updates_disabled_label"))
        }
        #expect(Appearance.quantity("num_episodes", count: 4_294_967_298) == "4294967298 episodes")
        #expect(Appearance.quantity("num_episodes", count: 1000) == "1000 episodes")
        #expect(Appearance.quantity("num_episodes", count: 0) == "0 episodes")
    }

    @Test func sourceRowsMarginsPaddingTypographyAndReadingOrder() throws {
        for detailed in [false, true] {
            let view = FeedStatisticsCardsView(detailed: detailed, contents: contents)
            let rows: [[Card]] = detailed
                ? [[.playbackTime, .episodesStarted, .spaceDownloaded], [.durationTotal, .episodesTotal, .episodesDownloaded], [.expectedNextEpisode, .episodeSchedule]]
                : [[.playbackTime, .episodesStarted, .spaceDownloaded], [.expectedNextEpisode, .episodeSchedule]]
            #expect(view.subviews.count == (detailed ? 8 : 5))
            for width: CGFloat in [240, 320, 402, 834] {
                for rtl in [false, true] {
                    view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                    layout(view, width: width)
                    var previousBottom: CGFloat = 0
                    for row in rows {
                        let slot = width / CGFloat(row.count)
                        var rowHeight: CGFloat?, rowTop: CGFloat?, previousCard: UIView?
                        for (index, id) in row.enumerated() {
                            let card = try #require(element("statistics.\(id.rawValue)", in: view, as: UIView.self))
                            let value: UILabel = try #require(element("statisticsValue", in: card))
                            let subtitle: UILabel = try #require(element("statisticsSubtitle", in: card))
                            // Cards share a row in source order (mirrored in RTL), equally sized, inside the view.
                            #expect(abs(card.frame.width - (slot - 8)) < 1)
                            #expect(card.frame.minX >= -0.5 && card.frame.maxX <= width + 0.5)
                            if let previousCard {
                                #expect(rtl ? card.frame.maxX <= previousCard.frame.minX + 0.5 : card.frame.minX >= previousCard.frame.maxX - 0.5)
                            }
                            previousCard = card
                            if let rowTop { #expect(abs(card.frame.minY - rowTop) < 0.5) } else {
                                rowTop = card.frame.minY
                                #expect(card.frame.minY >= previousBottom - 0.5, "Rows stack without overlapping")
                            }
                            if let rowHeight { #expect(abs(card.frame.height - rowHeight) < 0.5) } else { rowHeight = card.frame.height }
                            // Value above subtitle, both padded inside the card and not clipped.
                            #expect(value.frame.minX > 0 && value.frame.minY > 0 && value.frame.maxX < card.bounds.width)
                            #expect(abs(subtitle.frame.minX - value.frame.minX) < 0.5 && subtitle.frame.minY >= value.frame.maxY - 0.5)
                            #expect(subtitle.frame.maxY <= card.bounds.height + 0.5)
                            #expect(value.text == contents[id]?.value && subtitle.text == contents[id]?.subtitle)
                            #expect(value.font.fontName == "Roboto-Medium" && value.font.pointSize == 14)
                            #expect(subtitle.font.fontName == "Roboto-Regular" && subtitle.font.pointSize == 12)
                            #expect(value.numberOfLines == 0 && subtitle.numberOfLines == 0)
                            let paragraph = try #require(value.attributedText?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
                            #expect(paragraph.alignment == (rtl ? .right : .left))
                            #expect(!card.isAccessibilityElement && card.accessibilityElements?.count == 2)
                        }
                        previousBottom = (rowTop ?? 0) + (rowHeight ?? 0)
                    }
                    #expect(view.bounds.height >= previousBottom - 0.5 && view.bounds.height - previousBottom <= 16, "View fits its cards")
                    #expect(view.accessibilityElements?.compactMap { ($0 as? UIView)?.accessibilityIdentifier } == rows.flatMap { $0 }.map { "statistics.\($0.rawValue)" })
                }
            }
        }
    }

    @Test func loadingAndLongUpdatesRetainCardsAndReflowWithoutClipping() throws {
        let view = FeedStatisticsCardsView(detailed: true)
        layout(view, width: 320)
        let card = try #require(element("statistics.playbackTime", in: view, as: UIView.self))
        let label: UILabel = try #require(element("statisticsValue", in: card))
        #expect(label.text == "…")
        let originalHeight = view.bounds.height
        var long = contents
        long[.playbackTime] = Content(value: String(repeating: "12345 hours ", count: 12), subtitle: "played")
        view.update(long); layout(view, width: 320)
        #expect(element("statistics.playbackTime", in: view, as: UIView.self) === card)
        #expect(view.bounds.height > originalHeight)
        let wrappedHeight = view.bounds.height
        layout(view, width: 834)
        #expect(view.bounds.height < wrappedHeight)
        view.update([:]); layout(view, width: 320)
        #expect(view.bounds.height == originalHeight && label.text == "…")
        for width: CGFloat in [0, 12, 23] {
            layout(view, width: width)
            #expect(view.bounds.height.isFinite)
            for child in view.subviews { #expect(child.frame.width >= 0 && child.frame.minX >= 0 && child.frame.maxX <= width + 0.001) }
        }
    }

    @Test func detailedDialogInsetsAndTerminalActions() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { host.dismiss(animated: false); window.isHidden = true; previous?.makeKey() }
        for action in ["statisticsOK", "statisticsOpenPodcast", "escape"] {
            var opened = 0
            let dialog = FeedStatisticsDialog.make(title: "Podcast title", contents: contents) {
                #expect(host.presentedViewController == nil)
                opened += 1
            }
            host.present(dialog, animated: false); dialog.view.layoutIfNeeded()
            let heading: UILabel = try #require(element("sourceMessageTitle", in: dialog.view))
            #expect(heading.text == "Podcast title")
            let body = try #require(element("statisticsDialogBody", in: dialog.view, as: UIView.self))
            body.layoutIfNeeded()
            let cards = try #require(body.subviews.first as? FeedStatisticsCardsView)
            cards.layoutIfNeeded()
            #expect(cards.detailed && cards.subviews.count == 8)
            // Cards are inset evenly inside the dialog body.
            let left = cards.frame.minX, right = body.bounds.width - cards.frame.maxX
            #expect(left > 0 && abs(left - right) < 1 && cards.frame.minY > 0 && cards.frame.maxY < body.bounds.height)
            let open: UIButton = try #require(element("statisticsOpenPodcast", in: dialog.view))
            let ok: UIButton = try #require(element("statisticsOK", in: dialog.view))
            #expect(open.title(for: .normal) == "Open podcast" && ok.title(for: .normal) == "OK")
            #expect(open.frame.maxX < ok.frame.minX)
            if action == "escape" { #expect(dialog.accessibilityPerformEscape()) }
            else { try #require(element(action, in: dialog.view, as: UIButton.self)).sendActions(for: .touchUpInside) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while host.presentedViewController != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(host.presentedViewController == nil && opened == (action == "statisticsOpenPodcast" ? 1 : 0))
        }
    }

    @Test func largerTextReflowsWithoutMovingCardsToDifferentRows() async throws {
        let view = FeedStatisticsCardsView(detailed: true, contents: contents)
        layout(view, width: 402)
        let originalHeight = view.bounds.height
        view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        view.updateTraitsIfNeeded()
        await Task.yield()
        layout(view, width: 402)
        let first = try #require(element("statistics.playbackTime", in: view, as: UIView.self))
        let value: UILabel = try #require(element("statisticsValue", in: first))
        let subtitle: UILabel = try #require(element("statisticsSubtitle", in: first))
        #expect(value.font.pointSize > 14 && subtitle.font.pointSize > 12)
        #expect(view.bounds.height > originalHeight)
        let lastInRow = try #require(element("statistics.spaceDownloaded", in: view, as: UIView.self))
        let nextRow = try #require(element("statistics.durationTotal", in: view, as: UIView.self))
        #expect(abs(first.frame.minY - lastInRow.frame.minY) < 0.5 && abs(first.frame.height - lastInRow.frame.height) < 0.5, "Row stays together")
        #expect(nextRow.frame.minY >= first.frame.maxY - 0.5 && nextRow.frame.minY - first.frame.maxY <= 16, "Next row follows below")
        #expect(subtitle.frame.maxY <= first.bounds.height + 0.5, "Enlarged text is not clipped")
        view.traitOverrides.preferredContentSizeCategory = .large
        view.updateTraitsIfNeeded()
        await Task.yield()
        layout(view, width: 402)
        #expect(view.bounds.height == originalHeight && value.font.pointSize == 14)
    }
}
