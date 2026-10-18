#if DEBUG
import UIKit
import SQLite3
import NotTennaPodCore

/// Explicit UUID test libraries only. Production Queue controls handle every delivered pointer.
@MainActor enum QueueGestureFixture {
    private static var diagnostic: QueueObservation?
    static func makeWindow(scene: UIWindowScene) -> UIWindow {
        let args = ProcessInfo.processInfo.arguments
        let isolated = args.firstIndex(of: "-test-library-id").flatMap { index in
            index + 1 < args.count ? UUID(uuidString: args[index + 1]) : nil
        } != nil
        guard isolated, args.contains("-test-queue-gestures"), args.contains("-test-queue-diagnostics") else {
            return UIWindow(windowScene: scene)
        }
        return QueueDiagnosticWindow(windowScene: scene)
    }
    static func observeKeyEvent(_ event: UIEvent, window: UIWindow) {
        guard let diagnostic, diagnostic.controller?.view.window === window,
              let event = event as? UIPressesEvent else { return }
        for press in event.allPresses {
            guard let key = press.key, ["t", "b"].contains(key.charactersIgnoringModifiers.lowercased()) else { continue }
            diagnostic.record("window-key-event", extra: ["keyInput": key.charactersIgnoringModifiers,
                "pressPhase": press.phase.rawValue, "windowIsKey": window.isKeyWindow,
                "sceneActivation": window.windowScene?.activationState.rawValue ?? -1])
        }
    }
    /// Public UIKit observation only; preserves the delivered touch identities and dispatch order.
    static func observeTouchEvent(_ event: UIEvent, window: UIWindow, stage: String) {
        guard ProcessInfo.processInfo.arguments.contains("-test-queue-touch-observation"),
              let diagnostic, diagnostic.controller?.view.window === window,
              event.type == .touches, let touches = event.allTouches else { return }
        let values: [[String: Any]] = touches.map { touch in
            let point = touch.location(in: window)
            return ["identity": String(describing: ObjectIdentifier(touch)),
                    "phase": touch.phase.rawValue, "timestamp": touch.timestamp,
                    "x": point.x, "y": point.y,
                    "view": String(describing: type(of: touch.view)),
                    "viewIdentifier": touch.view?.accessibilityIdentifier ?? ""]
        }
        diagnostic.record("window-touch-" + stage, extra: ["touches": values,
            "eventTimestamp": event.timestamp])
    }
    static func recordControllerEvent(_ event: String, controller: LibraryViewController, input: String? = nil) {
        guard ProcessInfo.processInfo.arguments.contains("-test-queue-diagnostics"),
              diagnostic?.controller === controller else { return }
        diagnostic?.record(event, extra: input.map { ["keyInput": $0] } ?? [:])
    }
    static func prepare(directory: URL, store: FeedLibraryStore, navigation: NavigationPreferenceStore?) async throws {
        let marker = directory.appendingPathComponent("queue-fixture-ready")
        if !FileManager.default.fileExists(atPath: marker.path) {
            guard try await store.snapshot().feeds.isEmpty else { throw CocoaError(.fileWriteFileExists) }
            let source = "https://queue-fixture.invalid/feed"
            let items = (1...16).map { index in
                "<item><guid isPermaLink=\"false\">queue-\(index)</guid><title>Queue item \(String(format: "%02d", index))</title><enclosure url=\"https://queue-fixture.invalid/\(index).mp3\" length=\"123456\" type=\"audio/mpeg\"/><itunes:duration>120</itunes:duration></item>"
            }.joined()
            let xml = "<rss version=\"2.0\" xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><channel><title>Queue gesture fixture</title>\(items)</channel></rss>"
            let result = try await FeedFetcher(transport: Transport(url: URL(string: source)!, body: Data(xml.utf8)))
                .fetch(.init(source: source, generateMissingArtwork: false))
            guard case .updated(let fetched) = result else { throw CocoaError(.fileReadCorruptFile) }
            _ = try await store.insert(fetched)
            _ = try await store.enqueue(Array(1...16).map(Int64.init))
            _ = try await store.beginPlayback(episodeID: 2, positionMilliseconds: 7311)
            if let navigation { var value = navigation.value; value.defaultPage = NavigationDestination.queue.rawValue; try navigation.update(value) }
            try Data("prepared once\n".utf8).write(to: marker, options: .atomic)
        }
        for window in windows {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-test-queue-rtl") {
                window.semanticContentAttribute = .forceRightToLeft
                window.rootViewController?.view.semanticContentAttribute = .forceRightToLeft
            }
            if args.contains("-test-queue-large-text") {
                window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            }
            if let controller = window.rootViewController as? LibraryViewController { await controller.reloadLibrary()?.value }
            if args.contains("-test-queue-diagnostics"), let controller = window.rootViewController as? LibraryViewController {
                let diagnostic = QueueObservation(directory: directory, controller: controller)
                Self.diagnostic = diagnostic
                diagnostic.record("fixture-ready")
                Task { await diagnostic.observe() }
            }
            window.accessibilityIdentifier = "queueFixtureReady"
            if let index = args.firstIndex(of: "-test-queue-interrupt"), index + 1 < args.count,
               let controller = window.rootViewController as? LibraryViewController {
                let observer = QueueGestureInterruption(directory: directory, controller: controller, store: store, mode: args[index + 1])
                Task { await observer.watch() }
            }
        }
    }
    private struct Transport: FeedHTTPTransport {
        let url: URL
        let body: Data
        func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
            guard request.url == url else { throw URLError(.badURL) }
            return .init(url: url, status: 200, headers: ["Content-Type":"application/rss+xml", "Content-Length":String(body.count)], body: body)
        }
    }
    private static var windows: [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    }
}
/// Observation only: every event is forwarded unchanged to normal UIKit dispatch.
@MainActor private final class QueueDiagnosticWindow: UIWindow {
    override func sendEvent(_ event: UIEvent) {
        QueueGestureFixture.observeKeyEvent(event, window: self)
        QueueGestureFixture.observeTouchEvent(event, window: self, stage: "before")
        super.sendEvent(event)
        QueueGestureFixture.observeTouchEvent(event, window: self, stage: "after")
    }
}
/// Controlled external event during a real delivered pointer, reported separately from user navigation.
@MainActor private final class QueueGestureInterruption: NSObject {
    let directory: URL
    weak var controller: LibraryViewController?
    let store: FeedLibraryStore
    let mode: String
    var fired = false
    var attached = Set<ObjectIdentifier>()
    init(directory: URL, controller: LibraryViewController, store: FeedLibraryStore, mode: String) {
        self.directory = directory; self.controller = controller; self.store = store; self.mode = mode
    }
    func watch() async {
        let deadline = ContinuousClock.now + .seconds(30)
        while !fired, ContinuousClock.now < deadline, let controller {
            for gesture in gestures(controller.view) where !attached.contains(ObjectIdentifier(gesture)) {
                attached.insert(ObjectIdentifier(gesture)); gesture.addTarget(self, action: #selector(observed(_:)))
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    private func gestures(_ view: UIView) -> [QueueRowDrag] {
        (view.gestureRecognizers ?? []).compactMap { $0 as? QueueRowDrag } + view.subviews.flatMap(gestures)
    }
    @objc private func observed(_ gesture: QueueRowDrag) {
        guard gesture.state == .began, !fired else { return }; fired = true
        try? Data(mode.utf8).write(to: directory.appendingPathComponent("queue-drag-active"), options: .atomic)
        if mode == "missing" {
            // Another part of the app removes the dragged episode from the queue while it is held.
            Task { [store] in _ = try? await store.removeFromQueue([3], performAutoDownload: false) }
            return
        }
        if mode == "failure" {
            // Saving the move fails: the library database rejects queue changes from now on.
            var db: OpaquePointer?
            if sqlite3_open(directory.appendingPathComponent("library.sqlite").path, &db) == SQLITE_OK {
                sqlite3_exec(db, "CREATE TRIGGER IF NOT EXISTS fixture_reject_queue BEFORE DELETE ON queue BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", nil, nil, nil)
            }
            sqlite3_close(db)
            return
        }
        Task { [self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let controller else { return }
            if mode == "resize" {
                QueueObservation.recordInterruption("before-width-assignment", directory:directory, controller:controller, gesture:gesture)
                // A public safe-area transition changes the actual usable viewport,
                // unlike the former root-frame write that UIKit immediately replaced.
                var insets = controller.additionalSafeAreaInsets
                insets.right += 40
                controller.additionalSafeAreaInsets = insets
                QueueObservation.recordInterruption("after-width-assignment-before-layout", directory:directory, controller:controller, gesture:gesture)
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                QueueObservation.recordInterruption("after-forced-layout", directory:directory, controller:controller, gesture:gesture)
            } else if mode == "refresh" {
                // The screen read again in full (a catch-up's reopen): a reload with no change patches nothing and keeps
                // the drag, as Android's Queue keeps it through a refresh.
                await controller.reloadLibrary(reopen: true)?.value
            }
            else if mode == "navigation" {
                @MainActor func find(_ view: UIView) -> UIControl? {
                    if view.accessibilityIdentifier == "SubscriptionFragment" { return view as? UIControl }
                    return view.subviews.lazy.compactMap(find).first
                }
                find(controller.view)?.sendActions(for: .touchUpInside)
            }
            try? Data(mode.utf8).write(to: directory.appendingPathComponent("queue-interruption-applied"), options: .atomic)
        }
    }
}

/// Test-only observation. Does not dispatch commands, alter focus, reset scrolling, or arbitrate input.
@MainActor private final class QueueObservation: NSObject {
    let directory: URL
    weak var controller: LibraryViewController?
    private var attached = Set<ObjectIdentifier>()
    private var previous: Data?
    private var sequence = 0
    init(directory: URL, controller: LibraryViewController) {
        self.directory = directory; self.controller = controller
    }
    func observe() async {
        let deadline = ContinuousClock.now + .seconds(90)
        while ContinuousClock.now < deadline, let controller, controller.view.window != nil {
            for view in Self.descendants(controller.view) {
                for gesture in view.gestureRecognizers ?? [] where gesture is QueueRowDrag {
                    if attached.insert(ObjectIdentifier(gesture)).inserted {
                        gesture.addTarget(self, action: #selector(phaseChanged(_:)))
                    }
                }
            }
            record("sample", onlyWhenChanged:true)
            try? await Task.sleep(for: .milliseconds(20))
        }
        record("observation-ended")
    }
    @objc private func phaseChanged(_ gesture: QueueRowDrag) {
        record("recognizer-target-action", extra:["observedGesture":Self.gesture(gesture)])
    }
    func record(_ event:String, onlyWhenChanged:Bool = false, extra:[String:Any] = [:]) {
        guard let controller else { return }
        var value = Self.snapshot(controller)
        let state = try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
        if onlyWhenChanged && state == previous { return }; previous = state
        sequence += 1
        value.merge(extra) { _, new in new }
        value["event"] = event; value["sequence"] = sequence
        Self.append(value,to:directory.appendingPathComponent("queue-observations.jsonl"))
    }
    static func recordInterruption(_ event:String,directory:URL,controller:LibraryViewController,gesture:QueueRowDrag) {
        guard ProcessInfo.processInfo.arguments.contains("-test-queue-diagnostics") else { return }
        var value=snapshot(controller);value["event"]=event;value["observedGesture"]=Self.gesture(gesture)
        append(value,to:directory.appendingPathComponent("queue-resize.jsonl"))
    }
    private static func append(_ input:[String:Any],to file:URL) {
        var value=input;value["systemUptime"]=ProcessInfo.processInfo.systemUptime
        value["unixTime"]=Date().timeIntervalSince1970
        guard var data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) else { return }
        data.append(10)
        if !FileManager.default.fileExists(atPath:file.path) { FileManager.default.createFile(atPath:file.path,contents:nil) }
        guard let handle=try? FileHandle(forWritingTo:file) else { return }
        defer { try? handle.close() };try? handle.seekToEnd();try? handle.write(contentsOf:data)
    }
    private static func descendants(_ view:UIView) -> [UIView] { [view]+view.subviews.flatMap(descendants) }
    private static func rect(_ value:CGRect) -> [String:Double] {
        ["x":Double(value.minX),"y":Double(value.minY),"width":Double(value.width),"height":Double(value.height)]
    }
    private static func name(_ value:UIResponder?) -> String {
        guard let value else { return "nil" }
        let identifier=(value as? UIView)?.accessibilityIdentifier ?? ""
        return String(describing:type(of:value)) + (identifier.isEmpty ? "" : "#"+identifier)
    }
    private static func gesture(_ value:UIGestureRecognizer) -> [String:Any] {
        ["name":value.name ?? "", "state":value.state.rawValue,"enabled":value.isEnabled,
         "numberOfTouches":value.numberOfTouches,"view":name(value.view)]
    }
    private static func snapshot(_ controller:LibraryViewController) -> [String:Any] {
        let views=descendants(controller.view)
        let scroll=views.first { $0.accessibilityIdentifier == "libraryContent" } as? UIScrollView
        var result:[String:Any]=["controllerFrame":rect(controller.view.frame),"controllerBounds":rect(controller.view.bounds),
            "controllerSafeArea":rect(controller.view.safeAreaLayoutGuide.layoutFrame),"windowBounds":rect(controller.view.window?.bounds ?? .zero),
            "presentedController":name(controller.presentedViewController),
            "windowIsKey":controller.view.window?.isKeyWindow ?? false,
            "sceneActivation":controller.view.window?.windowScene?.activationState.rawValue ?? -1,
            "controllerCanBecomeFirstResponder":controller.canBecomeFirstResponder,
            "controllerIsFirstResponder":controller.isFirstResponder,
            "windowSceneOrientation":controller.view.window?.windowScene?.effectiveGeometry.interfaceOrientation.rawValue ?? -1]
        if let scroll {
            result["scroll"]=["frame":rect(scroll.frame),"bounds":rect(scroll.bounds),
                "offsetX":scroll.contentOffset.x,"offsetY":scroll.contentOffset.y,
                "contentWidth":scroll.contentSize.width,"contentHeight":scroll.contentSize.height,
                "insetTop":scroll.adjustedContentInset.top,"insetBottom":scroll.adjustedContentInset.bottom,
                "scrollEnabled":scroll.isScrollEnabled,"dragging":scroll.isDragging,"decelerating":scroll.isDecelerating]
        }
        let rows=views.compactMap { $0 as? EpisodeRowView }
        result["rows"]=rows.map { row -> [String:Any] in
            let buttons=descendants(row).compactMap { $0 as? UIButton }
            let id=buttons.compactMap(\.accessibilityIdentifier).first { $0.hasPrefix("episode-") } ?? "unknown"
            return ["id":id,"frame":rect(row.frame),"windowFrame":rect(row.convert(row.bounds,to:row.window)),
                "hidden":row.isHidden,"accessibilityHidden":row.accessibilityElementsHidden,
                "gestures":(row.gestureRecognizers ?? []).filter { $0 is QueueRowDrag }.map(gesture)]
        }
        var candidates:[UIResponder]=views.map { $0 as UIResponder }
        candidates.append(controller)
        if let window=controller.view.window { candidates.append(window) }
        candidates.append(UIApplication.shared)
        let first=candidates.first { $0.isFirstResponder }
        var chain:[String]=[];var current=first
        while let item=current,chain.count<16 { chain.append(name(item));current=item.next }
        result["observedFirstResponder"]=name(first);result["responderChain"]=chain
        var commands:[[String:Any]]=[]
        for command in controller.keyCommands ?? [] {
            guard command.input == "t" || command.input == "b" else { continue }
            var description:[String:Any]=[:]
            description["input"]=command.input ?? ""
            guard let action=command.action else {
                description["selector"]=NSNull();commands.append(description);continue
            }
            description["selector"]=NSStringFromSelector(action)
            description["controllerCanPerform"]=controller.canPerformAction(action,withSender:command)
            let firstTarget=first?.target(forAction:action,withSender:command) as? UIResponder
            let applicationTarget=UIApplication.shared.target(forAction:action,withSender:command) as? UIResponder
            description["firstResponderTarget"]=name(firstTarget)
            description["applicationTarget"]=name(applicationTarget)
            commands.append(description)
        }
        result["queueCommands"]=commands
        return result
    }
}
#endif
