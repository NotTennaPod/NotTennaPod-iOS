import UIKit
import Testing
import XCTest
import ObjectiveC
@testable import NotTennaPod

@MainActor final class ChooserTestDiscovery: CastDeviceDiscovery {
    var devices: [CastDiscoveredDevice] = []
    var onChange: (() -> Void)?
    var starts = 0, stops = 0
    var selections: [String] = []
    var acceptsSelection = true
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func select(id: String) -> Bool { selections.append(id); return acceptsSelection }
    func send(_ devices: [CastDiscoveredDevice]) { self.devices = devices; onChange?() }
}
@MainActor final class ChooserTestClock: CastChooserClock {
    var now: TimeInterval = 0
    var jobs: [UUID: (TimeInterval, @MainActor () -> Void)] = [:]
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> CastChooserCancellation {
        let id = UUID(); jobs[id] = (now + delay, action)
        return CastChooserCancellation { [weak self] in self?.jobs[id] = nil }
    }
    func advance(_ seconds: TimeInterval) {
        let end = now + seconds
        while let next = jobs.min(by: { $0.value.0 < $1.value.0 }), next.value.0 <= end {
            now = next.value.0; jobs[next.key] = nil; next.value.1()
        }
        now = end
    }
}

@MainActor @Suite(.serialized) struct CastDeviceChooserTests {
    @Test func exactEmptyTimingStopsDiscoveryAndReopeningRestarts() {
        let discovery = ChooserTestDiscovery(), clock = ChooserTestClock()
        let chooser = CastDeviceChooser(discovery: discovery, clock: clock)
        chooser.start(); chooser.start()
        #expect(discovery.starts == 1 && chooser.phase == .searching)
        clock.advance(4.999); #expect(chooser.phase == .searching)
        clock.advance(0.001); #expect(chooser.phase == .wifiHint)
        clock.advance(14.999); #expect(chooser.phase == .wifiHint)
        clock.advance(0.001); #expect(chooser.phase == .noDevices && discovery.stops == 1)
        discovery.send([.init(id: "late", name: "Late")]); clock.advance(10)
        #expect(chooser.devices.isEmpty && chooser.phase == .noDevices)
        chooser.start(); #expect(chooser.devices.map(\.id) == ["late"] && discovery.starts == 2)
        chooser.stop(); #expect(clock.jobs.isEmpty && discovery.stops == 2)
    }
    @Test func coalescesChangesWithoutStarvingListAndRestartsHintAfterRemoval() {
        let discovery = ChooserTestDiscovery(), clock = ChooserTestClock()
        let chooser = CastDeviceChooser(discovery: discovery, clock: clock)
        chooser.start(); clock.advance(0.1)
        discovery.send([.init(id: "a", name: "A")]); clock.advance(0.1)
        discovery.send([.init(id: "b", name: "B")]); clock.advance(0.099)
        #expect(chooser.devices.isEmpty)
        clock.advance(0.002); #expect(chooser.devices.map(\.id) == ["b"])
        clock.advance(21); #expect(chooser.phase == .routes)
        discovery.send([]); clock.advance(4.999); #expect(chooser.phase == .searching)
        clock.advance(0.002); #expect(chooser.phase == .wifiHint)
        chooser.stop()
    }
    @Test func namesUseStableCaseInsensitiveLexicalOrder() {
        let discovery = ChooserTestDiscovery(), clock = ChooserTestClock()
        discovery.devices = ["z", "speaker2", "Speaker10", "a", "A", "ı", "I", "İ", "i", "ß", "SS", "σ", "ς"].enumerated().map { .init(id: String($0.offset), name: $0.element) }
        let chooser = CastDeviceChooser(discovery: discovery, clock: clock)
        chooser.start()
        #expect(chooser.devices.map(\.name) == ["a", "A", "ı", "I", "İ", "i", "Speaker10", "speaker2", "SS", "z", "ß", "σ", "ς"])
        chooser.stop()
    }
    @Test func selectionWaitsForSessionAndFailureAllowsRetry() {
        let discovery = ChooserTestDiscovery(), clock = ChooserTestClock()
        discovery.devices = [.init(id: "living", name: "Living room")]
        let chooser = CastDeviceChooser(discovery: discovery, clock: clock)
        var completed = 0; chooser.onSelected = { completed += 1 }
        chooser.start(); chooser.select(id: "missing")
        #expect(discovery.selections.isEmpty)
        discovery.acceptsSelection = false; chooser.select(id: "living")
        #expect(chooser.selecting.isEmpty && completed == 0 && chooser.isActive)
        discovery.acceptsSelection = true; chooser.select(id: "living")
        #expect(chooser.selecting == ["living"] && completed == 0)
        chooser.selectionFailed(id: "living"); #expect(chooser.selecting.isEmpty)
        chooser.select(id: "living"); chooser.routeSelected(); chooser.routeSelected()
        #expect(completed == 1 && discovery.stops == 1)
    }
    @Test func dismissalCancelsPendingUpdatesAndTimers() {
        let discovery = ChooserTestDiscovery(), clock = ChooserTestClock()
        let chooser = CastDeviceChooser(discovery: discovery, clock: clock)
        chooser.start(); discovery.send([.init(id: "a", name: "A")])
        chooser.stop(); clock.advance(50)
        #expect(chooser.devices.isEmpty && clock.jobs.isEmpty && discovery.onChange == nil)
        chooser.routeSelected(); chooser.select(id: "a"); #expect(discovery.selections.isEmpty)
    }
    @Test func sdkDiscoveryDelegateUsesActualSelectors() {
        for name in ["didUpdateDeviceList", "didHaveDiscoveredDeviceWhenStartingDiscovery"] {
            #expect(class_getInstanceMethod(GoogleCastDeviceDiscovery.self, NSSelectorFromString(name)) != nil)
        }
    }
    func element<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) throws -> T {
        func find(_ view: UIView) -> T? {
            if view.accessibilityIdentifier == id { return view as? T }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        return try #require(find(view))
    }
    func mount(_ dialog: CastDeviceChooserController, host: UIViewController, size: CGSize) {
        host.addChild(dialog); host.view.addSubview(dialog.view); dialog.didMove(toParent: host)
        dialog.view.frame = CGRect(origin: .zero, size: size)
        dialog.view.traitOverrides.preferredContentSizeCategory = .large
        dialog.chooser.start(); dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
    }
    @Test func emptyStatesPreserveSourceCompositionAndHelpAction() async throws {
        try await withViewTestWindow { host, _ in
            let discovery = ChooserTestDiscovery(), clock = ChooserTestClock()
            let chooser = CastDeviceChooser(discovery: discovery, clock: clock)
            var urls: [URL] = []
            let dialog = CastDeviceChooserController(chooser: chooser, tabletDescription: false, openHelp: { urls.append($0) })
            mount(dialog, host: host, size: CGSize(width: 412, height: 800))
            let panel = try element("castChooserPanel", in: dialog.view)
            let title: UILabel = try element("castChooserTitle", in: dialog.view)
            #expect(abs(panel.frame.width - 320) < 2, "Source phone dialog width")
            #expect(title.frame.minX > 0 && title.frame.minY > 0 && panel.bounds.contains(title.frame))
            #expect(title.text == "Cast to")
            clock.advance(5); dialog.view.layoutIfNeeded()
            let hint: UILabel = try element("castChooserHint", in: dialog.view)
            let wifi = try element("castChooserWiFi", in: dialog.view)
            let help: UIButton = try element("castChooserHelp", in: dialog.view)
            let ok: UIButton = try element("castChooserOK", in: dialog.view)
            #expect(wifi.frame.maxX <= hint.frame.minX && wifi.frame.width > 0, "Wi-Fi icon precedes the hint text")
            #expect(hint.frame.minY >= title.frame.maxY)
            #expect(help.isHidden && ok.isHidden && hint.text?.hasSuffix("this phone") == true)
            #expect(help.frame.minY >= hint.frame.maxY, "Help link sits below the hint")
            let reserved = help.frame
            clock.advance(15); dialog.view.layoutIfNeeded()
            #expect(abs(help.frame.minY - reserved.minY) < 1, "Space for Help is reserved, so nothing jumps when it appears")
            #expect(!help.isHidden && !ok.isHidden && ok.title(for: .normal) == "OK")
            #expect(title.text == "No devices available")
            #expect(ok.frame.midX > panel.bounds.midX && ok.frame.maxX <= panel.bounds.width, "OK sits at the trailing edge")
            help.sendActions(for: .touchUpInside)
            #expect(urls.map(\.absoluteString) == ["https://support.google.com/chromecast/?p=trouble-finding-devices"])
            #expect(!chooser.isActive)
        }
    }
    @Test func tabletFractionsUseLocalConfigurationAndRetainSelectionAcrossResize() async throws {
        try await withViewTestWindow { host, _ in
            let discovery = ChooserTestDiscovery(), clock = ChooserTestClock()
            discovery.devices = [.init(id: "a", name: "Bedroom")]
            let chooser = CastDeviceChooser(discovery: discovery, clock: clock)
            let dialog = CastDeviceChooserController(chooser: chooser, tabletDescription: true, openHelp: { _ in })
            mount(dialog, host: host, size: CGSize(width: 834, height: 1194))
            chooser.select(id: "a")
            let panel = try element("castChooserPanel", in: dialog.view)
            for (w, h, fraction): (CGFloat, CGFloat, CGFloat) in [(834,1194,0.7),(1194,834,0.5),(600,900,0.9),(900,600,0.6),(720,720,0.5)] {
                dialog.view.frame.size = CGSize(width: w, height: h); dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                #expect(abs(panel.frame.width - min(w * fraction, w - dialog.view.safeAreaInsets.left - dialog.view.safeAreaInsets.right - 48)) < 1)
                #expect(chooser.selecting == ["a"] && discovery.starts == 1)
            }
            chooser.stop()
        }
    }
    @Test func asymmetricInsetsRTLAndCollapsedGeometryPreserveState() async throws {
        try await withViewTestWindow { host, _ in
            let discovery = ChooserTestDiscovery(), clock = ChooserTestClock()
            let chooser = CastDeviceChooser(discovery: discovery, clock: clock)
            let dialog = CastDeviceChooserController(chooser: chooser, tabletDescription: false, openHelp: { _ in })
            mount(dialog, host: host, size: CGSize(width: 500, height: 700))
            clock.advance(5)
            let panel = try element("castChooserPanel", in: dialog.view)
            for insets in [UIEdgeInsets(top: 11, left: 84, bottom: 21, right: 0), UIEdgeInsets(top: 17, left: 0, bottom: 3, right: 84)] {
                for rtl in [false, true] {
                    dialog.additionalSafeAreaInsets = insets
                    dialog.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                    dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                    let safe = dialog.view.bounds.inset(by: dialog.view.safeAreaInsets)
                    #expect(safe.contains(panel.frame))
                    #expect(abs(panel.frame.midX - safe.midX) < 1)
                    let hint: UILabel = try element("castChooserHint", in: dialog.view)
                    let wifi = try element("castChooserWiFi", in: dialog.view)
                    #expect(rtl ? wifi.frame.minX >= hint.frame.maxX : wifi.frame.maxX <= hint.frame.minX, "Icon leads the hint in both directions")
                    #expect(CGRect(origin: .zero, size: panel.frame.size).insetBy(dx: -1, dy: -1).contains(hint.frame))
                    #expect(chooser.phase == .wifiHint && discovery.starts == 1)
                }
            }
            dialog.view.frame.size = CGSize(width: 50, height: 40); dialog.view.layoutIfNeeded()
            #expect(panel.isHidden)
            dialog.view.frame.size = CGSize(width: 500, height: 700); dialog.view.layoutIfNeeded()
            #expect(!panel.isHidden && chooser.phase == .wifiHint)
            chooser.stop()
        }
    }
    @Test func longDeviceListScrollsWithinPanelAndSelectsLastRoute() async throws {
        try await withViewTestWindow { host, _ in
            let discovery = ChooserTestDiscovery(), clock = ChooserTestClock()
            discovery.devices = (0..<40).map { .init(id: String($0), name: String(format: "Room %02d", $0)) }
            let chooser = CastDeviceChooser(discovery: discovery, clock: clock)
            let dialog = CastDeviceChooserController(chooser: chooser, tabletDescription: false, openHelp: { _ in })
            mount(dialog, host: host, size: CGSize(width: 350, height: 320))
            let list: UIScrollView = try element("castChooserDevices", in: dialog.view)
            let title: UILabel = try element("castChooserTitle", in: dialog.view)
            let panel = try element("castChooserPanel", in: dialog.view)
            #expect(list.isScrollEnabled && list.clipsToBounds)
            let anchor = title.convert(title.bounds, to: dialog.view)
            let last: UIControl = try element("castDevice.39", in: dialog.view)
            list.scrollRectToVisible(last.frame, animated: false)
            #expect(list.bounds.contains(last.frame))
            #expect(panel.bounds.contains(last.convert(last.bounds, to: panel)))
            last.sendActions(for: .touchUpInside)
            #expect(discovery.selections == ["39"] && chooser.selecting == ["39"])
            #expect(title.convert(title.bounds, to: dialog.view) == anchor)
            dialog.view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
            #expect(title.font.pointSize > 20 && chooser.selecting == ["39"])
            chooser.stop()
        }
    }
    @Test func narrowHintCanScrollToHelpAndLocalRouteFontChangesRemeasure() async throws {
        try await withViewTestWindow { host, _ in
            let discovery = ChooserTestDiscovery(), clock = ChooserTestClock()
            let chooser = CastDeviceChooser(discovery: discovery, clock: clock)
            var opened = false
            let dialog = CastDeviceChooserController(chooser: chooser, tabletDescription: false, openHelp: { _ in opened = true })
            mount(dialog, host: host, size: CGSize(width: 180, height: 300))
            clock.advance(20); dialog.view.layoutIfNeeded()
            let scroll: UIScrollView = try element("castChooserContent", in: dialog.view)
            let help: UIButton = try element("castChooserHelp", in: dialog.view)
            #expect(scroll.contentSize.width > scroll.bounds.width && scroll.clipsToBounds)
            #expect(help.titleLabel?.numberOfLines == 0 && help.bounds.height > 20)
            scroll.scrollRectToVisible(help.frame, animated: false)
            #expect(scroll.bounds.contains(help.frame))
            help.sendActions(for: .touchUpInside); #expect(opened)
            discovery.devices = [.init(id: "a", name: "Speaker")]
            chooser.start()
            dialog.view.frame.size = CGSize(width: 400, height: 600)
            dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
            let row: UIControl = try element("castDevice.a", in: dialog.view)
            let label: UILabel = try element("castDeviceName", in: row)
            let oldHeight = row.frame.height
            label.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            let deadline = ContinuousClock.now + .seconds(3)
            while row.frame.height <= oldHeight && ContinuousClock.now < deadline { await Task.yield() }
            #expect(label.font.pointSize > 16 && row.frame.height > oldHeight)
            chooser.stop()
        }
    }

}
