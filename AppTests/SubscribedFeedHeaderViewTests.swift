import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor
struct SubscribedFeedHeaderViewTests {
    private func feed(id: Int64 = 1, title: String = "Podcast", image: String? = nil) -> LibraryFeed {
        LibraryFeed(id: id, source: "https://example.invalid/feed", metadata: ParsedFeed(format: .rss, title: title,
            author: "Author", imageURL: image), episodes: [])
    }
    private func element<T: UIView>(_ id: String, in header: UIView, as type: T.Type = T.self) throws -> T {
        try #require(header.subviews.first { $0.accessibilityIdentifier == id } as? T)
    }
    /// Frames within a point: sub-point differences are not visible.
    private func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }
    private func layout(_ header: UIView, width: CGFloat = 402) {
        header.frame = CGRect(origin: .zero, size: header.sizeThatFits(CGSize(width: width, height: 1000)))
        header.setNeedsLayout(); header.layoutIfNeeded()
    }

    @Test func restorePillClearsEmptyGeometryAndRecoversAfterResize() throws {
        var model = feed(); model.subscriptionState = .archived
        let header = SubscribedFeedHeaderView(feed: model)
        let button: UIButton = try element("restoreFeed", in: header)
        let fill = try #require(button.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        for size in [CGSize.zero, CGSize(width: 97, height: 48), CGSize(width: 97, height: 8),
                     CGSize(width: 0, height: 48), CGSize(width: 97, height: 48)] {
            button.bounds = CGRect(origin: .zero, size: size)
            button.setNeedsLayout(); button.layoutIfNeeded()
            if size.width == 0 || size.height <= 8 {
                #expect(fill.path == nil)
            } else {
                let path = try #require(fill.path)
                // Pill spans the button width with a small vertical inset (within half a point).
                let box = path.boundingBoxOfPath
                #expect(abs(box.minX) <= 0.5 && abs(box.minY - 4) <= 0.5)
                #expect(abs(box.width - 97) <= 0.5 && abs(box.height - 40) <= 0.5)
                #expect(path.contains(CGPoint(x: 48, y: 24)))
                #expect(!path.contains(CGPoint(x: 1, y: 5)))
            }
        }
        layout(header)
        var actions: [SubscribedFeedHeaderView.Action] = []
        header.onAction = { actions.append($0) }
        button.sendActions(for: .touchUpInside)
        #expect(actions == [.restore])
        #expect(!button.isHidden && button.bounds.height == 48)
    }

    @Test func originalControlsTypographyActionsAndStatusPlacement() throws {
        var model = feed(); model.lastUpdateFailed = true
        let header = SubscribedFeedHeaderView(feed: model, hasFilter: true, keepUpdated: false)
        var actions: [SubscribedFeedHeaderView.Action] = []
        header.onAction = { actions.append($0) }
        layout(header)
        let title: UILabel = try element("feedTitle", in: header)
        let author: UILabel = try element("feedAuthor", in: header)
        #expect(title.font.fontName == "Roboto-Light" && title.font.pointSize == 22)
        #expect(author.font.fontName == "Roboto-Regular" && author.font.pointSize == 14)
        #expect(title.numberOfLines == 2 && author.numberOfLines == 2)
        #expect(title.textColor == .white && author.textColor == .white)
        let cover: UIButton = try element("feedCover", in: header)
        #expect(near(cover.frame, CGRect(x: 16, y: 8, width: 124, height: 124)))
        #expect(!cover.isAccessibilityElement)
        for (index, id) in ["feedInformation", "feedFilter", "feedSettings"].enumerated() {
            let button: UIButton = try element(id, in: header)
            #expect(button.image(for: .normal) != nil)
            #expect(near(button.frame, CGRect(x: 144 + CGFloat(index) * 48, y: 108, width: 48, height: 48)))
            button.sendActions(for: .touchUpInside)
        }
        cover.sendActions(for: .touchUpInside)
        let failure: UIControl = try element("feedRefreshFailure", in: header)
        let filtered: UIControl = try element("feedFiltered", in: header)
        let disabled: UIControl = try element("feedUpdatesDisabled", in: header)
        #expect(abs(failure.frame.minY - 164) <= 1 && abs(failure.frame.minX - 16) <= 1 && abs(failure.frame.width - 370) <= 1)
        #expect(abs(filtered.frame.minY - (failure.frame.maxY + 8)) <= 1)
        #expect(disabled.frame.minY >= filtered.frame.maxY - 0.5 && abs(disabled.frame.maxY - header.bounds.height) <= 1)
        #expect(failure.layer.cornerRadius == 8 && failure.layer.borderWidth == 2)
        #expect(disabled.isUserInteractionEnabled == false)
        failure.sendActions(for: .touchUpInside); filtered.sendActions(for: .touchUpInside)
        #expect(actions == [.information, .filter, .settings, .information, .failure, .filter])
        let copyTitle = try #require(title.accessibilityCustomActions?.first)
        let copyAuthor = try #require(author.accessibilityCustomActions?.first)
        #expect(copyTitle.actionHandler?(copyTitle) == true)
        #expect(copyAuthor.actionHandler?(copyAuthor) == true)
        #expect(actions.suffix(2) == [.copyTitle("Podcast"), .copyAuthor("Author")])
    }

    @Test func refreshRetainsControlsAndReflowsStatusWithoutMovingActionStrip() throws {
        let header = SubscribedFeedHeaderView(feed: feed())
        layout(header)
        let info: UIButton = try element("feedInformation", in: header)
        let oldInfo = info.frame
        var changed = feed(title: String(repeating: "Long title ", count: 20)); changed.lastUpdateFailed = true
        header.update(feed: changed, hasFilter: true, keepUpdated: false); layout(header)
        #expect(try element("feedInformation", in: header, as: UIButton.self) === info && near(info.frame, oldInfo))
        let title: UILabel = try element("feedTitle", in: header)
        let author: UILabel = try element("feedAuthor", in: header)
        #expect(title.text == changed.title && title.numberOfLines == 2)
        #expect(title.frame.maxY <= author.frame.minY + 0.5)
        #expect(abs(author.frame.maxY - (info.frame.minY - 16)) <= 1)
        header.update(feed: feed(), hasFilter: false, keepUpdated: true); layout(header)
        #expect(abs(header.bounds.height - 156) <= 1)
        for id in ["feedRefreshFailure", "feedFiltered", "feedUpdatesDisabled"] {
            #expect(try element(id, in: header, as: UIControl.self).isHidden)
        }
        for width in [320, 834, 1000] as [CGFloat] {
            header.semanticContentAttribute = .forceRightToLeft; layout(header, width: width)
            let inset: CGFloat = width >= 1000 ? 56 : 0
            #expect(abs(info.frame.maxX - (width - inset - 144)) <= 1)
            let cover: UIButton = try element("feedCover", in: header)
            #expect(abs(cover.frame.maxX - (width - inset - 16)) <= 1)
            #expect(title.textAlignment == .right && abs(info.frame.minY - 108) <= 1)
        }
    }

    @Test func missingAuthorKeepsItsLineAboveThePreviewSubscribeStrip() throws {
        var model = LibraryFeed(id: 1, source: "https://example.invalid/feed",
            metadata: ParsedFeed(format: .rss, title: "Podcast"), episodes: [])
        model.subscriptionState = .notSubscribed
        let header = SubscribedFeedHeaderView(feed: model)
        layout(header)
        let author: UILabel = try element("feedAuthor", in: header)
        let title: UILabel = try element("feedTitle", in: header)
        #expect(author.frame.height >= author.font.lineHeight - 0.5)
        #expect(title.frame.maxY <= author.frame.minY + 0.5)
        #expect(abs(author.frame.maxY - 84) <= 1)
    }

    @Test func changingArtworkOwnerOrLiteralImageReplacesOnlyTheArtwork() throws {
        let header = SubscribedFeedHeaderView(feed: feed())
        let cover: UIButton = try element("feedCover", in: header)
        var image: UIView = try element("feedArtwork", in: header)
        for model in [feed(image: ""), feed(id: 2, image: ""), feed(id: 2, image: "antennapod_generative_cover:changed")] {
            header.update(feed: model, hasFilter: false, keepUpdated: true)
            let next: UIView = try element("feedArtwork", in: header)
            #expect(next !== image)
            #expect(try element("feedCover", in: header, as: UIButton.self) === cover)
            image = next
        }
    }

    @Test func windowResizeChangesResourceInsetsWhilePaneWidthStaysFixed() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1100, height: 800)
        let header = SubscribedFeedHeaderView(feed: feed())
        window.addSubview(header)
        defer { header.removeFromSuperview() }
        layout(header, width: 700)
        let cover: UIButton = try element("feedCover", in: header)
        let info: UIButton = try element("feedInformation", in: header)
        #expect(abs(cover.frame.minX - 72) <= 1 && abs(info.frame.minX - 200) <= 1)
        window.frame.size.width = 900
        layout(header, width: 700)
        #expect(abs(cover.frame.minX - 16) <= 1 && abs(info.frame.minX - 144) <= 1)
        #expect(header.bounds.width == 700 && abs(header.bounds.height - 156) <= 1)
    }
}
