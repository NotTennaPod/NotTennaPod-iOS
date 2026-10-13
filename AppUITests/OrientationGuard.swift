import XCTest

/// The UI test bundle's principal class. Every test leaves the device upright: a test that rotates it restores the
/// orientation in a `defer`, which XCTest skips when a failed assertion stops the test (`continueAfterFailure = false`).
/// A device left in landscape made every later journey (and later view-test runs) run sideways.
@objc(UITestOrientationGuard)
final class UITestOrientationGuard: NSObject, XCTestObservation {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        MainActor.assumeIsolated {
            if XCUIDevice.shared.orientation != .portrait { XCUIDevice.shared.orientation = .portrait }
        }
    }
}
