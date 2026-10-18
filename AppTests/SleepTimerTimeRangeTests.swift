import UIKit
import Testing
@testable import NotTennaPod

@MainActor @Suite(.serialized)
struct SleepTimerTimeRangeTests {
    private func find(_ id: String, in view: UIView) -> UIButton? {
        if view.accessibilityIdentifier == id { return view as? UIButton }
        return view.subviews.lazy.compactMap { find(id, in: $0) }.first
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
    @Test func sourceClockInputWrapsFloorsAndKeepsLongArcAtCoincidentHandles() {
        let dial = SleepTimerTimeRangeDial(from: 22, to: 6)
        dial.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        #expect(dial.point(hour: 0) == CGPoint(x: 200, y: 40))
        #expect(abs(dial.point(hour: 6).x - 360) < 0.001)
        #expect(abs(dial.point(hour: 12).y - 360) < 0.001)
        #expect(abs(dial.point(hour: 18).x - 40) < 0.001)
        #expect(!dial.beginDrag(at: dial.point(hour: 12)))
        dial.moveDrag(to: dial.point(hour: 10.4)); #expect(dial.from == 22 && dial.to == 6)
        // Source accepts the angle even away from the painted handle's radius.
        #expect(dial.beginDrag(at: dial.point(hour: 22.2, radius: 60)))
        #expect(dial.from == 22)
        dial.moveDrag(to: dial.point(hour: 23.7)); #expect(dial.from == 23)
        dial.moveDrag(to: dial.point(hour: 0.2)); #expect(dial.from == 0)
        dial.cancelTracking(with: nil)
        dial.moveDrag(to: dial.point(hour: 5.5)); #expect(dial.from == 0)
        for (destination, expectedFrom, expectedTo) in [(2.2, 2, 0), (20.2, 0, 20)] {
            let equal = SleepTimerTimeRangeDial(from: 0, to: 0); equal.frame = dial.frame
            #expect(equal.beginDrag(at: equal.point(hour: 23.5)))
            equal.moveDrag(to: equal.point(hour: destination))
            #expect(equal.from == expectedFrom && equal.to == expectedTo)
            equal.endDrag()
        }
    }

    @Test(arguments: [false, true])
    func mountedSquareDialRetainsInputAcrossSafeAreaAndSizeChanges(rtl: Bool) async throws {
        let controller = SleepTimerTimeRangeController(from: 22, to: 6) { _, _ in }
        try await withViewTestWindow { host, window in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            let dial = controller.dial
            let endpoints = try #require(dial.accessibilityElements as? [UIAccessibilityElement])
            #expect(endpoints.count == 2 && endpoints.allSatisfy { $0.accessibilityTraits.contains(.adjustable) })
            endpoints[0].accessibilityIncrement(); endpoints[0].accessibilityIncrement()
            endpoints[1].accessibilityDecrement()
            #expect(controller.from == 0 && controller.to == 5)
            for width in [min(host.view.bounds.width, 402), min(host.view.bounds.width, 340)] {
                controller.view.frame = CGRect(x: 0, y: 0, width: width, height: host.view.bounds.height)
                for insets in [UIEdgeInsets(top: 0, left: 31, bottom: 0, right: 7), .init(top: 0, left: 7, bottom: 0, right: 31)] {
                    controller.additionalSafeAreaInsets = insets
                    controller.view.setNeedsLayout(); controller.view.layoutIfNeeded(); dial.layoutIfNeeded()
                    #expect(dial.bounds.width == dial.bounds.height)
                    #expect(controller.from == 0 && controller.to == 5)
                    let safe = controller.view.safeAreaLayoutGuide.layoutFrame
                    let frame = dial.convert(dial.bounds, to: controller.view)
                    #expect(frame.minX >= safe.minX && frame.maxX <= safe.maxX)
                    let center = dial.convert(dial.point(hour: 0), to: window)
                    #expect(window.hitTest(center, with: nil) === dial)
                    #expect(abs(dial.point(hour: 6).x - dial.bounds.width * 0.9) < 0.001)
                    let ok = try #require(find("sleepTimerTimeRangeOK", in: controller.view))
                    #expect(window.bounds.contains(ok.convert(ok.bounds, to: window)))
                }
            }
        }
    }

    @Test(arguments: ["ok", "escape", "outside", "owner"])
    func everyDismissalSavesEditedRangeExactlyOnce(route: String) async throws {
        var saved: [(Int, Int)] = []
        let controller = SleepTimerTimeRangeController(from: 22, to: 6) { saved.append(($0, $1)) }
        try await withViewTestWindow { host, _ in
            host.present(controller, animated: false)
            try await wait { controller.viewIfLoaded?.window != nil && !controller.isBeingPresented }
            controller.view.layoutIfNeeded()
            let dial = controller.dial
            #expect(dial.beginDrag(at: dial.point(hour: 22.2)))
            dial.moveDrag(to: dial.point(hour: 21.5)); dial.endDrag()
            switch route {
            case "ok": try #require(find("sleepTimerTimeRangeOK", in: controller.view)).sendActions(for: .touchUpInside)
            case "escape": #expect(controller.accessibilityPerformEscape())
            case "outside": controller.perform(NSSelectorFromString("outside:"), with: TimeRangeOutsideTap())
            default: host.dismiss(animated: false)
            }
            try await wait { host.presentedViewController == nil && saved.count == 1 }
            #expect(saved[0].0 == 21 && saved[0].1 == 6)
            // UIKit can deliver more than one dismissal callback; delivery remains idempotent.
            controller.dismiss(animated: false)
            #expect(saved.count == 1)
        }
    }

    /// Touch moves arrive every frame: within the same hour nothing repaints or reports a change.
    @Test func dragWithinAnHourDoesNotRepaint() {
        let dial = SleepTimerTimeRangeDial(from: 22, to: 6)
        dial.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        var changes = 0
        dial.addAction(UIAction { _ in changes += 1 }, for: .valueChanged)
        dial.layer.displayIfNeeded()
        #expect(dial.beginDrag(at: dial.point(hour: 22.1)))
        dial.moveDrag(to: dial.point(hour: 22.4)); dial.moveDrag(to: dial.point(hour: 22.9))
        #expect(!dial.layer.needsDisplay() && changes == 0 && dial.from == 22)
        dial.moveDrag(to: dial.point(hour: 23.2))
        #expect(dial.layer.needsDisplay() && changes == 1 && dial.from == 23)
        dial.endDrag()
    }
}

@MainActor private final class TimeRangeOutsideTap: UITapGestureRecognizer {
    override func location(in view: UIView?) -> CGPoint { CGPoint(x: 1, y: 1) }
}
