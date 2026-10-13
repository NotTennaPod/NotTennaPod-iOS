import UIKit
import Testing

/// Records UIKit-delivered lifecycle events; tests never synthesize them.
@MainActor final class ViewTestWindowHost: UIViewController {
    private(set) var appeared = false
    private(set) var appearanceCount = 0
    private(set) var disappearanceCount = 0
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        appearanceCount += 1
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        appeared = false
        disappearanceCount += 1
    }
}

/// Runs mounted-view checks only after the real root appearance completes.
/// Teardown also completes before another fixture replaces the key window.
@MainActor func withViewTestWindow(_ body: @MainActor (ViewTestWindowHost, UIWindow) async throws -> Void) async throws {
    // A freshly launched test host can enter the test before its scene activates.
    // Await UIKit's real activation; an inactive scene is not a valid test window host.
    // Simulator cold launches have repeatedly activated after the old three-
    // second setup deadline. This awaits readiness, not an application timing
    // requirement; lifecycle assertions and their deadlines below are unchanged.
    let activationDeadline = ContinuousClock.now + .seconds(10)
    while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
          ContinuousClock.now < activationDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive })
    let previous = scene.keyWindow, orientation = scene.effectiveGeometry.interfaceOrientation
    let window = UIWindow(windowScene: scene), host = ViewTestWindowHost()
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.view.layoutIfNeeded()
    func waitForAppearance(_ visible: Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while host.appeared != visible && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(host.appeared == visible, "UIKit must complete the test-window appearance transition")
    }
    var failure: (any Error)?
    do {
        try await waitForAppearance(true)
        try await body(host, window)
    } catch { failure = error }
    window.endEditing(true)
    window.rootViewController = nil
    window.isHidden = true
    do { try await waitForAppearance(false) }
    catch {
        if failure == nil { failure = error } else { Issue.record(error) }
    }
    await restoreInterfaceOrientation(orientation, of: scene)
    previous?.makeKey()
    if let failure { throw failure }
}

/// The scene is shared by every mounted-view suite. A test, or app code it drives (the video screen requests
/// landscape), can leave it rotated; later suites would then lay out in landscape safe areas and heights.
/// Restore the entry orientation so any such leak stays inside the test that caused it.
@MainActor private func restoreInterfaceOrientation(_ orientation: UIInterfaceOrientation, of scene: UIWindowScene) async {
    guard orientation != .unknown, scene.effectiveGeometry.interfaceOrientation != orientation else { return }
    print("View test window: restoring orientation \(orientation.rawValue) from \(scene.effectiveGeometry.interfaceOrientation.rawValue)")
    var refusal: String?
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: UIInterfaceOrientationMask(rawValue: 1 << orientation.rawValue))) {
        refusal = String(describing: $0)
    }
    let deadline = ContinuousClock.now + .seconds(6)
    while refusal == nil, scene.effectiveGeometry.interfaceOrientation != orientation, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    if scene.effectiveGeometry.interfaceOrientation != orientation && !windowingRefusesRotation(refusal) {
        Issue.record("The test window could not restore orientation \(orientation.rawValue): \(refusal ?? "timed out")")
    }
}

/// iPad's default windowing mode refuses programmatic rotation (UISceneErrorDomain 101). Tests that resize
/// through rotation then check the same outcome at the current size; the UI journeys rotate the real device.
func windowingRefusesRotation(_ error: String?) -> Bool { error?.contains("UISceneErrorDomain Code=101") == true }

/// Tears down a window a test mounted a screen in directly (rather than through `withViewTestWindow`).
/// Hiding is not enough: a hidden window can stay in the shared scene's window list after the test
/// (three did after LibraryReloadViewTests), and the application walks that list to reload every
/// `LibraryViewController` root after a feed refresh (`AppDelegate.libraryControllers`). A leftover
/// root whose test loader never completes then keeps a later suite's real refresh active forever.
/// Detaching the root keeps the test's screen out of the application's graph.
@MainActor func closeTestWindow(_ window: UIWindow, restoringKey previous: UIWindow?) {
    window.rootViewController?.dismiss(animated: false)
    window.endEditing(true)
    window.rootViewController = nil
    window.isHidden = true
    previous?.makeKey()
}
