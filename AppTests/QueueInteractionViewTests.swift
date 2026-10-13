import UIKit
import UIKit.UIGestureRecognizerSubclass
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct QueueInteractionViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let value = view as? T { return value }
        return view.subviews.lazy.compactMap { find(id, in: $0) as T? }.first
    }
    private func tap(_ id: String, in view: UIView) throws {
        let control: UIControl = try #require(find(id, in: view)); control.sendActions(for: .touchUpInside)
    }
    private func wait(_ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while try await !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await predicate())
    }
    private func fixture(_ body: @MainActor (LibraryViewController, FeedLibraryStore, QueueInteractionPreferenceStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QueueView-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        do {
            _ = try await store.insert(.init(feed: .init(format: .rss, title: "Queue", episodes: (1...4).map {
                .init(identifier: "\($0)", title: "Episode \($0)", media: .init(url: "https://example.invalid/\($0).mp3", size: 123456, durationMilliseconds: 120_000))
            }), source: "https://example.invalid/feed", responseURL: URL(string: "https://example.invalid/feed")!, validator: nil, permanentRedirectURL: nil))
            _ = try await store.enqueue([1,2,3,4])
            let navigation = try NavigationPreferenceStore(file: directory.appendingPathComponent("navigation.json"))
            var value = navigation.value; value.defaultPage = NavigationDestination.queue.rawValue; try navigation.update(value)
            let preferences = try QueueInteractionPreferenceStore(file: directory.appendingPathComponent("queue.json"))
            let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
                timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil,
                mobileNetworkPreferences: nil, usage: nil, queueInteractionPreferences: preferences)
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                controller.view.frame = host.view.bounds
                defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
                try await body(controller,store,preferences,directory)
            }
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
    private func row(_ id: Int64, in controller: LibraryViewController) throws -> EpisodeRowView {
        let button: UIButton = try #require(find("episode-\(id)", in: controller.view))
        return try #require(button.superview as? EpisodeRowView)
    }
    @Test func cancelDoesNotPersistSuppressionAndConfirmSurvivesReopen() async throws {
        try await fixture { controller,store,preferences,directory in
            controller.toggleQueueLock()
            try await wait { controller.presentedViewController?.isBeingPresented == false }
            let first = try #require(controller.presentedViewController)
            first.view.layoutIfNeeded()
            let body: QueueLockWarningBody = try #require(find("queueLockWarning",in:first.view))
            body.layoutIfNeeded()
            let warning = try #require(body.subviews.compactMap { $0 as? UILabel }.first)
            #expect(abs(warning.frame.minX - 24) <= 1); #expect(abs(warning.frame.minY - 16) <= 1)
            #expect(abs(warning.frame.maxX - (body.bounds.width-24)) <= 1)
            try tap("queueLockSuppress",in:first.view); try tap("queueLockCancel",in:first.view)
            try await wait { controller.presentedViewController == nil }
            #expect(preferences.value == .init()); #expect(try await store.queue().map(\.id) == [1,2,3,4])
            controller.toggleQueueLock(); try await wait { controller.presentedViewController?.isBeingPresented == false }
            let second = try #require(controller.presentedViewController)
            let checkbox: SpeedCheckbox = try #require(find("queueLockSuppress",in:second.view)); #expect(!checkbox.checked)
            try tap("queueLockSuppress",in:second.view); try tap("queueLockConfirm",in:second.view)
            try await wait { preferences.value.locked }
            #expect(try QueueInteractionPreferenceStore(file: directory.appendingPathComponent("queue.json")).value == .init(locked:true,showLockWarning:false))
            controller.toggleQueueLock(); #expect(!preferences.value.locked); controller.toggleQueueLock(); #expect(preferences.value.locked)
            #expect(controller.presentedViewController == nil)
        }
    }
    @Test func lockedContextMovesAndPreservesRowBinding() async throws {
        try await fixture { controller,store,preferences,_ in
            try preferences.update(.init(locked:true,showLockWarning:false)); await controller.reloadLibrary()?.value
            let before = try row(2,in:controller)
            before.contextMenu?(before,.init(x:0.5,y:0.5))
            try await wait { controller.presentedViewController?.isBeingPresented == false }
            let menu = try #require(controller.presentedViewController)
            try tap("queue-top",in:menu.view)
            try await wait { try await store.queue().map(\.id) == [2,1,3,4] }
            #expect(preferences.value.locked)
        }
    }
    @Test func selectedInformationKeepsFrameAndBulkMovementPreservesRelativeOrder() async throws {
        try await fixture { controller,store,_,_ in
            let info: UILabel = try #require(find("queueInformation",in:controller.view)), frame = info.frame
            controller.startFeedSelection(2); try tap("episode-4",in:controller.view)
            #expect(info.isHidden); #expect(info.frame == frame)
            let top: UIButton = try #require(find("queueBulk-top",in:controller.view)); top.sendActions(for:.touchUpInside)
            try await wait { try await store.queue().map(\.id) == [2,4,1,3] }
            #expect(!info.isHidden)
        }
    }
    @Test func resizeBetweenMoveSubmissionAndCompletionSettlesVisibleAndStoredOrder() async throws {
        try await fixture { controller,store,_,_ in
            controller.startFeedSelection(2); try tap("episode-4",in:controller.view)
            let top: UIButton = try #require(find("queueBulk-top",in:controller.view))
            top.sendActions(for: .touchUpInside)
            // The action has submitted its asynchronous store work, but has not
            // yielded this MainActor turn. A real layout invalidation can run here.
            controller.additionalSafeAreaInsets.right += 40
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            let deadline = ContinuousClock.now + .seconds(6)
            var stored: [Int64] = [], displayed: [Int64] = []
            repeat {
                stored = try await store.queue().map(\.id)
                displayed = try [Int64(1),2,3,4].map { (id: $0, y: try row($0,in:controller).frame.minY) }
                    .sorted { $0.y < $1.y }.map(\.id)
                if stored == [2,4,1,3] && displayed == [2,4,1,3] { break }
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            #expect(stored == [2,4,1,3])
            #expect(displayed == [2,4,1,3])
        }
    }
    @Test func lockedSelectionHidesBulkActionsAndRetainsContextAlternative() async throws {
        try await fixture { controller,_,preferences,_ in
            try preferences.update(.init(locked:true,showLockWarning:false)); await controller.reloadLibrary()?.value
            controller.startFeedSelection(2); try tap("episode-4",in:controller.view)
            #expect((find("queueBulk-top",in:controller.view) as UIButton?) == nil)
            #expect((find("queueBulk-bottom",in:controller.view) as UIButton?) == nil)
            let info: UILabel = try #require(find("queueInformation",in:controller.view)); #expect(info.isHidden)
            try tap("endEpisodeSelection",in:controller.view); #expect(!info.isHidden)
        }
    }
    @Test func queueRowsUseContainerTextSizeAndDirectionBeforeMeasurement() async throws {
        try await fixture { controller,_,_,_ in
            let initialRow = try row(1,in:controller)
            let initial = initialRow.frame.height
            let initialTitle = try #require(initialRow.subviews.compactMap { $0 as? UILabel }.first { $0.attributedText?.string == "Episode 1" })
            let initialParagraph = try #require(initialTitle.attributedText?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            #expect(initialParagraph.alignment == .left)
            controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            controller.view.semanticContentAttribute = .forceRightToLeft
            await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
            let changed = try row(1,in:controller)
            #expect(changed.frame.height > initial)
            #expect(changed.effectiveUserInterfaceLayoutDirection == .rightToLeft)
            // Pinned feeditemlist_item.xml title declares textAlignment="viewStart".
            // An English title must follow RTL view-start rather than natural LTR text.
            let title = try #require(changed.subviews.compactMap { $0 as? UILabel }.first { $0.attributedText?.string == "Episode 1" })
            let paragraph = try #require(title.attributedText?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            #expect(paragraph.alignment == .right)
            #expect(title.attributedText?.string == "Episode 1")
            #expect(changed.acceptsQueueDrag(at: .init(x:changed.bounds.width-36,y:changed.bounds.midY),policy:.init()))
            #expect(!changed.acceptsQueueDrag(at: .init(x:changed.bounds.width-70,y:changed.bounds.midY),policy:.init()))
            // UIKit presentations inherit the window environment, not this child
            // controller's local row-layout override.
            controller.view.window?.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            controller.toggleQueueLock()
            try await wait { controller.presentedViewController?.isBeingPresented == false }
            let dialog = try #require(controller.presentedViewController)
            dialog.view.layoutIfNeeded()
            let body: QueueLockWarningBody = try #require(find("queueLockWarning",in:dialog.view))
            body.layoutIfNeeded()
            let warning = try #require(body.subviews.compactMap { $0 as? UILabel }.first)
            #expect(warning.traitCollection.preferredContentSizeCategory == .accessibilityExtraExtraExtraLarge)
            #expect(warning.font.pointSize > Appearance.font(14,compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize)
            for id in ["queueLockCancel", "queueLockConfirm", "queueLockSuppress"] {
                let control: UIControl = try #require(find(id,in:dialog.view))
                #expect(!control.isHidden && control.isEnabled)
                #expect(dialog.view.bounds.contains(control.convert(control.bounds,to:dialog.view)))
            }
        }
    }

    /// Real OS scene resize complements the separately delivered Duo RTL pointer journey.
    @Test func queueRTLRetainsOrderAndReachabilityAcrossDeliveredSceneResize() async throws {
        try await fixture { controller, store, _, _ in
            controller.view.semanticContentAttribute = .forceRightToLeft
            let captured = try await store.queue().map(QueueEpisodeIdentity.init)
            _ = try await store.performQueueMove(.boundary([3], .top), expected: captured)
            await controller.reloadLibrary()?.value
            let before = try await store.snapshot()
            let window = try #require(controller.view.window), scene = try #require(window.windowScene)
            let scroll: UIScrollView = try #require(find("libraryContent", in: controller.view))
            let oldMask = controller.view.autoresizingMask
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            defer { controller.view.autoresizingMask = oldMask }
            window.layoutIfNeeded(); controller.view.layoutIfNeeded()
            let originalScene = scene.effectiveGeometry.coordinateSpace.bounds.size
            let originalContent = scroll.bounds.size
            // Rotate away from whatever orientation an earlier test left, and restore it afterwards.
            let orientation = scene.effectiveGeometry.interfaceOrientation
            let wasPortrait = orientation.isPortrait
            let restore: UIInterfaceOrientationMask = switch orientation {
                case .portraitUpsideDown: .portraitUpsideDown
                case .landscapeLeft: .landscapeLeft
                case .landscapeRight: .landscapeRight
                default: .portrait
            }
            var requestError: (any Error)?, failure: (any Error)?
            do {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: wasPortrait ? .landscapeLeft : .portrait)) { requestError = $0 }
                try await wait {
                    let bounds = scene.effectiveGeometry.coordinateSpace.bounds
                    return requestError != nil || ((bounds.width > bounds.height) == wasPortrait && scroll.bounds.size != originalContent)
                }
                // iPad's default windowing mode does not allow programmatic rotation (UISceneErrorDomain 101);
                // the order and reachability checks below still run at the current size, and the UI journey
                // QueueGestureTests.test09RTLLeadingHalfAndRotation rotates the real device.
                let rotated = requestError == nil
                if let requestError { try #require((requestError as NSError).code == 101, "\(requestError)") }
                window.layoutIfNeeded(); controller.view.layoutIfNeeded()
                if rotated { #expect((window.bounds.width > window.bounds.height) == wasPortrait) }
                #expect(window.bounds.contains(scroll.convert(scroll.bounds, to: window)))
                let displayed = try [Int64(1),2,3,4].map { (id: $0, y: try row($0, in: controller).frame.minY) }.sorted { $0.y < $1.y }.map(\.id)
                #expect(displayed == [3,1,2,4])
                #expect(try await store.queue().map(\.id) == [3,1,2,4])
                #expect(try await store.snapshot() == before)
                let first = try row(3, in: controller)
                let title = try #require(first.subviews.compactMap { $0 as? UILabel }.first { $0.attributedText?.string == "Episode 3" })
                let paragraph = try #require(title.attributedText?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
                #expect(paragraph.alignment == .right)
                let button: UIButton = try #require(find("episode-3", in: controller.view))
                func reachable() -> Bool {
                    let center = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: window)
                    let hit = window.hitTest(center, with: nil)
                    return window.bounds.contains(center) && (hit === button || hit?.isDescendant(of: button) == true)
                }
                try await wait { reachable() }
                #expect(reachable())
                let evidence = "sceneBefore=\(originalScene); sceneAfter=\(scene.effectiveGeometry.coordinateSpace.bounds.size); window=\(window.bounds); contentBefore=\(originalContent); contentAfter=\(scroll.bounds.size); safeArea=\(controller.view.safeAreaInsets); order=\(displayed); firstRowHit=\(reachable())"
                print("M10 actual scene resize: \(evidence)")
                Attachment.record(Data(evidence.utf8), named: "queue-rtl-actual-scene-geometry.txt")
                let format = UIGraphicsImageRendererFormat(); format.scale = window.traitCollection.displayScale
                let rendered = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    #expect(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                Attachment.record(try #require(rendered.pngData()), named: "queue-rtl-actual-landscape-window.png")
            } catch { failure = error }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: restore)) { print("M10 scene restore error: \($0)") }
            try await wait { scene.effectiveGeometry.coordinateSpace.bounds.size == originalScene && scroll.bounds.size == originalContent }
            print("M10 scene restored: scene=\(scene.effectiveGeometry.coordinateSpace.bounds.size); content=\(scroll.bounds.size)")
            #expect(try await store.snapshot() == before)
            if let failure { throw failure }
        }
    }

    /// Synthetic recognizer phase, not a delivered additional-finger acceptance test.
    /// UIKit target/action cancellation must restore the actual mounted controller state.
    @Test func rejectedAdditionalTouchNotifiesControllerAndRestoresPreview() async throws {
        try await fixture { controller,store,_,_ in
            let source = try row(3,in:controller), original = source.frame
            let scroll: UIScrollView = try #require(find("libraryContent",in:controller.view))
            let gesture = try #require(source.gestureRecognizers?.compactMap { $0 as? QueueRowDrag }.first)
            gesture.state = .began
            try await wait { !scroll.isScrollEnabled }
            source.frame.origin.y += 80
            gesture.touchesBegan([],with:UIEvent())
            try await wait { scroll.isScrollEnabled && source.frame == original }
            #expect(try await store.queue().map(\.id) == [1,2,3,4])
            gesture.touchesMoved([],with:UIEvent()); gesture.touchesEnded([],with:UIEvent())
            #expect(scroll.isScrollEnabled); #expect(source.frame == original)
            #expect(try await store.queue().map(\.id) == [1,2,3,4])
        }
    }

}
