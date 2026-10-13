import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor
struct FeedInformationBodyViewTests {
    private func info(_ subscription: FeedSubscriptionState = .subscribed, funded: Bool = true,
                      description: String = "A podcast about science.\nA second paragraph with more detail.") throws -> FeedInformation {
        var metadata = ParsedFeed(format: .rss, description: description)
        metadata.funding = funded ? [.init(url: "https://example.com/support", content: "Support this podcast")] : []
        var feed = LibraryFeed(id: 1, source: "https://example.com/feed", metadata: metadata, episodes: [])
        feed.subscriptionState = subscription
        return try FeedInformation(feed: feed, websiteCallable: false, supportLabel: "Support this podcast")
    }
    private func element<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if view.accessibilityIdentifier == id { return view as? T }
        for child in view.subviews { if let found = element(id, in: child, as: type) { return found } }
        return nil
    }
    private func layout(_ view: UIView, width: CGFloat) {
        view.frame = CGRect(origin: .zero, size: view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)))
        view.setNeedsLayout(); view.layoutIfNeeded()
        for child in view.subviews { child.setNeedsLayout(); child.layoutIfNeeded() }
    }

    @Test func sourceSectionOrderInsetsIconsAndVisibilityAcrossWidthsAndDirections() throws {
        for width: CGFloat in [320, 400, 834, 1000] {
            for rtl in [false, true] {
                for state in 0...2 {
                    let view = FeedInformationBodyView(feedID: 1, information: try info(state == 2 ? .notSubscribed : .subscribed, funded: state == 0), sourceURL: "https://example.com/feed") { _, _, _ in nil }
                    view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                    view.windowWidth = width
                    layout(view, width: width)
                    let stats: UILabel = try #require(element("statisticsHeadingLabel", in: view))
                    let all: UIButton = try #require(element("statisticsButton", in: view))
                    let cards: UIControl = try #require(element("statisticsFragmentContainer", in: view))
                    let support: UILabel = try #require(element("supportHeadingLabel", in: view))
                    let funding: FeedInformationTextView = try #require(element("supportUrl", in: view))
                    let heading: UILabel = try #require(element("descriptionHeadingLabel", in: view))
                    let description: FeedInformationTextView = try #require(element("descriptionLabel", in: view))
                    let urlHeading: UILabel = try #require(element("urlHeadingLabel", in: view))
                    let url: UIControl = try #require(element("urlLabel", in: view))
                    let inset: CGFloat = width >= 1000 ? 64 : 8
                    #expect(stats.isHidden == (state == 2) && cards.isHidden == stats.isHidden && all.isHidden == stats.isHidden)
                    #expect(support.isHidden == (state != 0) && funding.isHidden == support.isHidden)
                    #expect(stats.text == "Statistics" && all.title(for: .normal) == "All podcasts »")
                    #expect(support.text == "Support" && heading.text == "Description" && urlHeading.text == "URL")
                    // Wide windows (≥1000 pt) use the source's large side inset; others the narrow one (±1 pt).
                    #expect(abs(heading.frame.minX - (inset + 8)) < 1 && abs(description.frame.minX - (inset + 8)) < 1)
                    #expect(abs(description.frame.maxX - (width - inset - 8)) < 1)
                    // Sections stack in source order without overlapping: [stats] [support] description, URL.
                    @MainActor func below(_ lower: UIView, _ upper: UIView, within gap: CGFloat = 24) -> Bool {
                        lower.frame.minY >= upper.frame.maxY - 0.5 && lower.frame.minY - upper.frame.maxY <= gap
                    }
                    #expect(below(description, heading))
                    #expect(below(urlHeading, description))
                    #expect(below(url, urlHeading) && abs(view.bounds.height - url.frame.maxY) <= 16)
                    if state == 2 { #expect(heading.frame.minY > 0 && heading.frame.minY <= 24) }
                    else {
                        #expect(all.frame.minY > 0 && all.frame.minY <= 24)
                        #expect(below(cards, all))
                        #expect(abs(cards.frame.minX - inset) < 1 && abs(cards.frame.maxX - (width - inset)) < 1)
                        #expect(rtl ? all.frame.maxX <= stats.frame.minX : stats.frame.maxX <= all.frame.minX)
                        #expect(below(heading, state == 0 ? funding : cards))
                    }
                    if state == 0 {
                        #expect(below(support, cards))
                        #expect(below(funding, support))
                    }
                    #expect(description.isSelectable && !description.isEditable && !description.isScrollEnabled && description.links.isEmpty)
                    #expect(!funding.isSelectable && !funding.isEditable && !funding.isScrollEnabled && funding.textContainer.maximumNumberOfLines == 8)
                    #expect(description.textContainerInset == .zero && description.textContainer.lineFragmentPadding == 0)
                    #expect(stats.font.fontName == "Roboto-Medium" && stats.font.pointSize == 16)
                    #expect(funding.font?.fontName == "Roboto-Regular" && funding.font?.pointSize == 14)
                    let icon = try #require(url.subviews.compactMap { $0 as? UIImageView }.first)
                    let label = try #require(url.subviews.compactMap { $0 as? UILabel }.first)
                    #expect(icon.image != nil && icon.bounds.width > 0 && icon.bounds.height > 0)
                    #expect(label.numberOfLines == 4)
                    // The copy icon trails the URL text in either direction.
                    #expect(rtl ? label.frame.minX >= icon.frame.maxX - 0.5 : icon.frame.minX >= label.frame.maxX - 0.5)
                    #expect(rtl ? abs(url.frame.maxX - (width - inset)) < 1 : abs(url.frame.minX - inset) < 1)
                }
            }
        }
    }

    @Test func independentActionsCopyCurrentURLAndResizeDoesNotReloadStatistics() async throws {
        let reads = InformationReadCounter()
        let view = FeedInformationBodyView(feedID: 1, information: try info(), sourceURL: "https://example.com/feed") { _, _, _ in await reads.read(); return nil }
        var actions: [FeedInformationBodyView.Action] = [], copies: [String] = []
        view.onAction = { actions.append($0) }; view.copyURL = { copies.append($0) }
        await view.loadStatistics()?.value
        for width: CGFloat in [320, 1000, 400] { layout(view, width: width) }
        #expect(await reads.count == 1)
        try #require(element("statisticsButton", in: view, as: UIButton.self)).sendActions(for: .touchUpInside)
        try #require(element("statisticsFragmentContainer", in: view, as: UIControl.self)).sendActions(for: .touchUpInside)
        let funding = try #require(element("supportUrl", in: view, as: FeedInformationTextView.self))
        funding.openLink?(funding.links[0].url)
        let url = try #require(element("urlLabel", in: view, as: UIControl.self))
        url.sendActions(for: .touchUpInside)
        view.update(information: try info(.notSubscribed), sourceURL: "https://new.example/feed")
        url.sendActions(for: .touchUpInside)
        #expect(view.loadStatistics() == nil)
        #expect(actions == [.allPodcasts, .detailedStatistics, .fundingURL("https://example.com/support")])
        #expect(copies == ["https://example.com/feed", "https://new.example/feed"])
        #expect(url.accessibilityLabel == "https://new.example/feed")
        #expect(await reads.count == 1)
    }

    @Test func fundingLinkGeometryExcludesWhitespaceAndDescriptionKeepsNativeSelection() throws {
        let text = "First https://example.com/long/path and https://second.example.com/end"
        let view = FeedInformationTextView(kind: .funding)
        view.update(text)
        for rtl in [false, true] {
            view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            layout(view, width: 160)
            #expect(view.links.count == 2 && !view.isSelectable)
            var visibleLinks = Set<String>()
            for link in view.links {
                for index in link.range.location..<NSMaxRange(link.range) {
                    let start = try #require(view.position(from: view.beginningOfDocument, offset: index))
                    let end = try #require(view.position(from: start, offset: 1))
                    let range = try #require(view.textRange(from: start, to: end))
                    let rect = view.firstRect(for: range)
                    let point = CGPoint(x: rect.midX, y: rect.midY)
                    if rect.width > 0 && view.bounds.contains(point) {
                        #expect(view.link(at: point)?.url == link.url)
                        if view.link(at: point)?.url == link.url { visibleLinks.insert(link.url) }
                    }
                }
            }
            #expect(visibleLinks == Set(view.links.map(\.url)))
            #expect(view.link(at: CGPoint(x: -1, y: 10)) == nil)
            #expect(view.link(at: CGPoint(x: 161, y: 10)) == nil)
            // RTL alignment can place a URL at the right edge. Derive a point
            // from the known non-link prefix instead of assuming edge whitespace.
            let plainStart = try #require(view.position(from: view.beginningOfDocument, offset: 0))
            let plainEnd = try #require(view.position(from: plainStart, offset: 1))
            let plainRange = try #require(view.textRange(from: plainStart, to: plainEnd))
            let plainRect = view.firstRect(for: plainRange)
            #expect(view.link(at: CGPoint(x: plainRect.midX, y: plainRect.midY)) == nil)
            let oldFrame = view.frame
            view.frame.size.height += 40; view.layoutIfNeeded()
            #expect(view.link(at: CGPoint(x: 80, y: oldFrame.height + 20)) == nil)
            view.frame = oldFrame; view.layoutIfNeeded()
        }
        view.update("Text before links\n" + String(repeating: "ordinary text\n", count: 10) + "https://hidden.example.com")
        layout(view, width: 160)
        for y in stride(from: CGFloat(1), to: view.bounds.height, by: 5) {
            for x in stride(from: CGFloat(1), to: CGFloat(160), by: 5) { #expect(view.link(at: CGPoint(x: x, y: y)) == nil) }
        }
        let description = FeedInformationTextView(kind: .description)
        description.update(text); layout(description, width: 160)
        #expect(description.isSelectable && description.links.isEmpty && description.dataDetectorTypes.isEmpty)
        description.selectedRange = NSRange(location: 0, length: 5)
        #expect(description.selectedRange == NSRange(location: 0, length: 5))
        #expect(description.attributedText.attribute(.link, at: 10, effectiveRange: nil) == nil)
    }

    @Test func unicodeLinksKeepUTF16HitTargetsAcrossWrappingAndUpdates() throws {
        let view = FeedInformationTextView(kind: .funding)
        for text in ["😀 https://éxample.fr/é😀 and https://example.org/next",
                     "مساعدة https://مثال.مصر/path ونص",
                     "First https://example.com/a%20b then https://例え.com/path"] {
            view.update(text)
            for width: CGFloat in [140, 320] {
                for rtl in [false, true] {
                    view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                    layout(view, width: width)
                    var found = Set<String>()
                    for y in stride(from: CGFloat(1), to: view.bounds.height, by: 2) {
                        for x in stride(from: CGFloat(1), to: width, by: 2) {
                            if let hit = view.link(at: CGPoint(x: x, y: y)) { found.insert(hit.url) }
                        }
                    }
                    #expect(found == Set(view.links.map(\.url)), "width=\(width), rtl=\(rtl), text=\(text)")
                    #expect(view.accessibilityCustomActions?.map(\.name) == view.links.map { (text as NSString).substring(with: $0.range) })
                }
            }
        }
        view.update("no more links"); layout(view, width: 320)
        #expect(view.links.isEmpty && view.accessibilityCustomActions?.isEmpty == true)
    }

    @Test func largerTextAndWindowQualificationKeepCompositionAndReflow() async throws {
        let view = FeedInformationBodyView(feedID: 1, information: try info(description: String(repeating: "Long paragraph with details. ", count: 15)), sourceURL: String(repeating: "https://example.com/long/path/", count: 15)) { _, _, _ in nil }
        layout(view, width: 400)
        let height = view.bounds.height
        view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        view.updateTraitsIfNeeded(); await Task.yield(); layout(view, width: 400)
        #expect(view.bounds.height > height)
        let description = try #require(element("descriptionLabel", in: view, as: FeedInformationTextView.self))
        #expect((description.font?.pointSize ?? 0) > 14, "traits=\(description.traitCollection.preferredContentSizeCategory.rawValue), attributes=\(String(describing: description.attributedText.attribute(.font, at: 0, effectiveRange: nil)))")
        let url = try #require(element("urlLabel", in: view, as: UIControl.self))
        #expect(url.frame.minY > description.frame.maxY && url.frame.maxX <= 392)
        view.traitOverrides.preferredContentSizeCategory = .large
        view.updateTraitsIfNeeded(); await Task.yield(); layout(view, width: 400)
        #expect(abs(view.bounds.height - height) < 1, "Returning to default text size restores the layout")
        view.windowWidth = 1000; layout(view, width: 400)
        #expect(abs(description.frame.minX - 72) < 1 && abs(description.frame.maxX - 328) < 1, "Wide-window inset applies")
    }
}

private actor InformationReadCounter {
    private(set) var count = 0
    func read() { count += 1 }
}
