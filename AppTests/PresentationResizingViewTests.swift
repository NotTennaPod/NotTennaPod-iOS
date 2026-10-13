import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Real UIKit layout with synthetic insets, not a claim about Duo fold poses.
@MainActor
@Suite(.serialized)
struct PresentationResizingViewTests {
    private func element<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let result = view as? T, result.accessibilityIdentifier == id { return result }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: T.self) }.first
    }

    private func mounted(_ controller: UIViewController, rtl: Bool,
                         body: @MainActor () async throws -> Void) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent()
            window.isHidden = true; previous?.makeKey()
        }
        host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
        controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        resize(controller, width: 402, height: 874, left: 0, right: 0)
        try await body()
    }

    private func resize(_ controller: UIViewController, width: CGFloat, height: CGFloat,
                        left: CGFloat, right: CGFloat) {
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: left, bottom: 0, right: right)
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    }

    @Test func speedSheetRetainsControlsRateAndDuplicateNoticeThroughResizing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpeedResize-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let preferences = try PlaybackSpeedPreferenceStore(file: root.appendingPathComponent("speed.json"))
        let playback = PlaybackCoordinator(store: store, engine: AVPlayerPlaybackEngine(muted: true), speedPreferences: preferences)
        try await playback.setSpeed(1.25, alsoGlobal: true)
        for rtl in [false, true] {
            let controller = PlaybackSpeedController(playback: playback, preferences: preferences)
            try await mounted(controller, rtl: rtl) {
                let sheet: UIScrollView = try #require(element("speedDialog", in: controller.view))
                let add: UIControl = try #require(element("speedAddPreset", in: sheet))
                let slider: UIControl = try #require(element("speedSlider", in: sheet))
                let decrease: UIControl = try #require(element("speedDecrease", in: sheet))
                let increase: UIControl = try #require(element("speedIncrease", in: sheet))
                add.sendActions(for: .touchUpInside)
                let notice: UILabel = try #require(element("speedPresetDuplicate", in: controller.view))
                let originalValue = slider.accessibilityValue, originalMessage = notice.text
                #expect(originalValue == PlaybackSpeedDialogState.text(1.25))
                for (width, height) in [(402.0, 874.0), (874, 402), (320, 250), (800, 900)] {
                    for (left, right) in [(0.0, 0.0), (43, 0), (0, 43), (9, 31)] {
                        resize(controller, width: width, height: height, left: left, right: right)
                        let safe = controller.view.safeAreaLayoutGuide.layoutFrame
                        #expect(abs(sheet.frame.minX - safe.minX) <= 1)
                        #expect(abs(sheet.frame.maxX - safe.maxX) <= 1)
                        #expect(abs(sheet.frame.maxY - controller.view.bounds.maxY) <= 0.5)
                        #expect(sheet.frame.minY >= safe.minY - 0.01)
                        #expect(element("speedSlider", in: sheet, as: UIControl.self) === slider)
                        #expect(slider.accessibilityValue == originalValue)
                        #expect(element("speedPresetDuplicate", in: controller.view, as: UILabel.self) === notice)
                        #expect(notice.text == originalMessage)
                        // Duplicate-preset notice stays inside the safe area near the bottom edge.
                        #expect(abs(notice.frame.minX - safe.minX - 16) <= 1)
                        #expect(abs(safe.maxX - notice.frame.maxX - 16) <= 1)
                        #expect(abs(safe.maxY - notice.frame.maxY - 16) <= 1)
                        #expect(notice.bounds.height >= notice.sizeThatFits(CGSize(width: notice.bounds.width, height: .greatestFiniteMagnitude)).height)
                        #expect(abs(decrease.frame.midY - slider.frame.midY) <= 1 && abs(increase.frame.midY - slider.frame.midY) <= 1)
                        if rtl { #expect(increase.frame.maxX <= slider.frame.minX && slider.frame.maxX <= decrease.frame.minX) }
                        else { #expect(decrease.frame.maxX <= slider.frame.minX && slider.frame.maxX <= increase.frame.minX) }
                        if height == 250 { #expect(sheet.contentSize.height > sheet.bounds.height) }
                    }
                }
                // Change only insets: UIKit must invalidate layout itself.
                controller.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 51, bottom: 0, right: 3)
                controller.view.layoutIfNeeded()
                let updatedSafe = controller.view.safeAreaLayoutGuide.layoutFrame
                #expect(abs(sheet.frame.minX - updatedSafe.minX) <= 1)
                #expect(abs(sheet.frame.maxX - updatedSafe.maxX) <= 1)

                // Deliver the actual target action with controlled pan inputs.
                // This verifies geometry/state, not hardware gesture delivery.
                let pan = ResizePan()
                controller.view.addGestureRecognizer(pan)
                pan.state = .began
                controller.perform(NSSelectorFromString("dragSheet:"), with: pan)
                pan.displacement = CGPoint(x: 0, y: 35); pan.state = .changed
                controller.perform(NSSelectorFromString("dragSheet:"), with: pan)
                #expect(abs(sheet.frame.maxY - controller.view.bounds.maxY - 35) <= 1)
                resize(controller, width: 402, height: 650, left: 31, right: 9)
                #expect(abs(sheet.frame.maxY - controller.view.bounds.maxY - 35) <= 1)
                pan.displacement.y = 48
                controller.perform(NSSelectorFromString("dragSheet:"), with: pan)
                #expect(abs(sheet.frame.maxY - controller.view.bounds.maxY - 48) <= 1)
                pan.state = .cancelled
                controller.perform(NSSelectorFromString("dragSheet:"), with: pan)
                #expect(abs(sheet.frame.maxY - controller.view.bounds.maxY) <= 1)
                #expect(element("speedSlider", in: sheet, as: UIControl.self) === slider)
                #expect(playback.speed == 1.25 && playback.phase == .idle)
                #expect(preferences.value.global == 1.25 && preferences.value.presets == [1, 1.25, 1.5])
                let reopened = try PlaybackSpeedPreferenceStore(file: root.appendingPathComponent("speed.json"))
                #expect(reopened.value == preferences.value)
            }
        }
        try await store.close()
    }

    @Test func previewKeepsItsScrollAndSubscriptionActionInsideChangingSafeEdges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewResize-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        do {
            let url = URL(string: "https://example.invalid/feed")!
            let feed = try await store.preparePreview(.init(feed: .init(format: .rss, title: "Resize preview",
                description: String(repeating: "Long description for preview scrolling. ", count: 80),
                episodes: (1...20).map { .init(title: "Episode \($0)") }), source: url.absoluteString,
                responseURL: url, validator: nil, permanentRedirectURL: nil))
            for rtl in [false, true] {
                var subscribed = 0
                let child = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
                    timeDisplayPreferences: nil, navigationPreferences: nil, speedPreferences: nil,
                    mobileNetworkPreferences: nil, usage: nil, previewFeedID: feed.id)
                child.onPreviewSubscribe = { _ in subscribed += 1 }
                let controller = FeedPreviewController(content: child)
                try await mounted(controller, rtl: rtl) {
                    await child.reloadLibrary()?.value
                    controller.view.layoutIfNeeded(); child.view.layoutIfNeeded()
                    let close: UIButton = try #require(element("toolbarBack", in: controller.view))
                    #expect(close.configuration?.image?.pngData() == UIImage(named: "ic_close")?.imageFlippedForRightToLeftLayoutDirection().pngData())
                    #expect(controller.view.accessibilityViewIsModal)
                    let card: UIView = try #require(element("feedPreviewCard", in: controller.view))
                    let scroll: UIScrollView = try #require(element("libraryContent", in: controller.view))
                    scroll.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
                    for width in [402.0, 874, 320, 800] {
                        for (left, right) in [(0.0, 0.0), (43, 0), (0, 43), (9, 31)] {
                            resize(controller, width: width, height: 600, left: left, right: right)
                            child.view.setNeedsLayout(); child.view.layoutIfNeeded()
                            let safe = controller.view.safeAreaLayoutGuide.layoutFrame
                            #expect(abs(card.frame.minX - safe.minX - 16) <= 1)
                            #expect(abs(safe.maxX - card.frame.maxX - 16) <= 1)
                            let button: UIButton = try #require(element("subscribeFeed", in: controller.view))
                            let frame = button.convert(button.bounds, to: controller.view)
                            #expect(frame.minX >= card.frame.minX - 0.5 && frame.maxX <= card.frame.maxX + 0.5)
                            #expect(abs(scroll.contentOffset.y - 120) < 0.5)
                            #expect(subscribed == 0 && button.isEnabled)
                        }
                    }
                    let button: UIButton = try #require(element("subscribeFeed", in: controller.view))
                    button.sendActions(for: .touchUpInside); button.sendActions(for: .touchUpInside)
                    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                    while subscribed == 0, ContinuousClock.now < deadline { await Task.yield() }
                    #expect(subscribed == 1)
                }
            }
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

}

@MainActor
private final class ResizePan: UIPanGestureRecognizer {
    private var phase: UIGestureRecognizer.State = .possible
    var displacement = CGPoint.zero
    override var state: UIGestureRecognizer.State {
        get { phase }
        set { phase = newValue }
    }
    override func translation(in view: UIView?) -> CGPoint { displacement }
    override func velocity(in view: UIView?) -> CGPoint { .zero }
}
