import UIKit
import UniformTypeIdentifiers
import Testing
import Synchronization
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct OPMLImportViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if let match = view as? T, view.accessibilityIdentifier == id { return match }
        return view.subviews.lazy.compactMap { find(id, in: $0, as: type) }.first
    }
    private func wait(_ stage: String = "view ready", _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate(), Comment(rawValue: stage))
    }
    @Test(arguments: [false, true])
    func selectionCompositionAndResizePreserveDraft(rightToLeft: Bool) async throws {
        var commits = 0
        let xml = "<opml>" + (0..<24).map { "<outline title='Podcast \($0) — retained Unicode &amp; readable long title' xmlUrl='raw-\($0)'/>" }.joined() + "</opml>"
        let session = OPMLImportSession(read: { _ in Data(xml.utf8) }, commit: { _ in 0 }, refresh: { commits += 1 })
        let controller = OPMLImportController(session: session)
        try await withViewTestWindow { host, window in
            host.addChild(controller); host.view.addSubview(controller.view)
            controller.view.frame = host.view.bounds; controller.didMove(toParent: host)
            defer { session.close(); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            try await wait { controller.view.window === window }
            controller.view.semanticContentAttribute = rightToLeft ? .forceRightToLeft : .forceLeftToRight
            controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            await session.load(URL(fileURLWithPath: "/fixture"))?.value
            let first: UIControl = try #require(find("opmlRow-0", in: controller.view))
            let second: UIControl = try #require(find("opmlRow-1", in: controller.view))
            let last: UIControl = try #require(find("opmlRow-23", in: controller.view))
            let list = try #require(first.superview as? UIScrollView)
            let cancel: UIButton = try #require(find("opmlCancel", in: controller.view))
            let confirm: UIButton = try #require(find("opmlConfirm", in: controller.view))
            #expect(session.selected.isEmpty && confirm.isEnabled)
            #expect(first.accessibilityLabel == "Podcast 0 — retained Unicode & readable long title")
            #expect(second.accessibilityLabel == "Podcast 1 — retained Unicode & readable long title")
            second.sendActions(for: .touchUpInside); #expect(session.selected == [1])
            #expect(second.accessibilityTraits.contains(.selected))
            for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390), CGSize(width: 1024, height: 768)] {
                controller.view.frame = CGRect(origin: .zero, size: size)
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                #expect(controller.view.bounds.size == size)
                #expect(controller.view.effectiveUserInterfaceLayoutDirection == (rightToLeft ? .rightToLeft : .leftToRight))
                #expect(first.frame.maxY <= second.frame.minY)
                if rightToLeft { #expect(confirm.frame.maxX < cancel.frame.minX) }
                else { #expect(cancel.frame.maxX < confirm.frame.minX) }
                let safe = controller.view.safeAreaLayoutGuide.layoutFrame
                #expect(safe.contains(cancel.frame) && safe.contains(confirm.frame))
                #expect(list.frame.maxY <= confirm.frame.minY)
                #expect(list.contentSize.height > list.bounds.height)
                list.scrollRectToVisible(last.frame, animated: false)
                #expect(list.bounds.contains(last.frame), "Last selectable row must be completely reachable")
                #expect(session.selected == [1])
            }
            cancel.sendActions(for: .touchUpInside)
            #expect(!session.isPresented && commits == 0)
        }
    }
    @Test func selectedDraftSurvivesDeliveredSceneResize() async throws {
        let counts = Mutex((reads: 0, commits: 0, refreshes: 0))
        let xml = "<opml><outline title='First' xmlUrl='raw-first'/><outline title='Selected second' xmlUrl='raw-second'/><outline title='Last' xmlUrl='raw-last'/></opml>"
        let session = OPMLImportSession(read: { _ in counts.withLock { $0.reads += 1 }; return Data(xml.utf8) },
                                        commit: { _ in counts.withLock { $0.commits += 1 }; return 0 }, refresh: { counts.withLock { $0.refreshes += 1 } })
        let controller = OPMLImportController(session: session)
        try await withViewTestWindow { host, window in
            host.addChild(controller); host.view.addSubview(controller.view)
            controller.view.frame = host.view.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            controller.didMove(toParent: host)
            defer { session.close(); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            try await wait { controller.view.window === window }
            await session.load(URL(fileURLWithPath: "/scene-fixture"))?.value
            let selected: UIControl = try #require(find("opmlRow-1", in: controller.view))
            let cancel: UIButton = try #require(find("opmlCancel", in: controller.view))
            let confirm: UIButton = try #require(find("opmlConfirm", in: controller.view))
            let list = try #require(selected.superview as? UIScrollView)
            selected.sendActions(for: .touchUpInside)
            window.layoutIfNeeded(); controller.view.layoutIfNeeded()
            let scene = try #require(window.windowScene)
            let originalScene = scene.effectiveGeometry.coordinateSpace.bounds.size
            let originalContent = list.bounds.size, originalView = controller.view.bounds.size
            let orientation = scene.effectiveGeometry.interfaceOrientation
            let restore: UIInterfaceOrientationMask
            switch orientation {
            case .portrait: restore = .portrait
            case .portraitUpsideDown: restore = .portraitUpsideDown
            case .landscapeLeft: restore = .landscapeLeft
            case .landscapeRight: restore = .landscapeRight
            default: throw CocoaError(.coderInvalidValue)
            }
            @MainActor func reachable(_ control: UIControl) -> Bool {
                let center = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: window)
                let hit = window.hitTest(center, with: nil)
                return window.bounds.contains(center) && (hit === control || hit?.isDescendant(of: control) == true)
            }
            @MainActor func verifyDraft() {
                let (reads, commits, refreshes) = counts.withLock { $0 }
                #expect(session.state == .selecting && session.isPresented)
                #expect(session.selected == [1] && selected.accessibilityTraits.contains(.selected))
                #expect(session.document.entries.map(\.xmlURL) == ["raw-first", "raw-second", "raw-last"])
                #expect(reads == 1 && commits == 0 && refreshes == 0)
                #expect(reachable(selected) && reachable(cancel) && reachable(confirm))
                let safe = controller.view.safeAreaLayoutGuide.layoutFrame
                #expect(safe.contains(cancel.frame) && safe.contains(confirm.frame))
                #expect(list.frame.maxY <= confirm.frame.minY && cancel.frame.maxX < confirm.frame.minX)
                #expect(window.bounds.contains(controller.view.convert(controller.view.bounds, to: window)))
            }
            var requestError: String?, failure: (any Error)?
            do {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation.isPortrait ? .landscapeLeft : .portrait)) {
                    requestError = String(describing: $0)
                }
                try await wait("OS delivered changed scene and content geometry") {
                    requestError != nil || (scene.effectiveGeometry.coordinateSpace.bounds.size != originalScene &&
                        list.bounds.size != originalContent && controller.view.bounds.size != originalView)
                }
                try #require(requestError == nil || windowingRefusesRotation(requestError), "\(requestError ?? "")")
                window.layoutIfNeeded(); controller.view.layoutIfNeeded()
                try await wait("Resized selection and actions are reachable") { reachable(selected) && reachable(cancel) && reachable(confirm) }
                verifyDraft()
                let (reads, commits, refreshes) = counts.withLock { $0 }
                let evidence = "sceneBefore=\(originalScene); sceneAfter=\(scene.effectiveGeometry.coordinateSpace.bounds.size); contentBefore=\(originalContent); contentAfter=\(list.bounds.size); window=\(window.bounds); safeArea=\(controller.view.safeAreaInsets); selected=\(session.selected); reads=\(reads); commits=\(commits); refreshes=\(refreshes)"
                print("M11 actual scene resize: \(evidence)")
                Attachment.record(Data(evidence.utf8), named: "opml-actual-scene-geometry.txt")
                let rendered = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    #expect(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                Attachment.record(try #require(rendered.pngData()), named: "opml-actual-resized-window.png")
            } catch { failure = error }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: restore)) { print("M11 scene restore error: \($0)") }
            try await wait("Original scene and content geometry restored") {
                scene.effectiveGeometry.coordinateSpace.bounds.size == originalScene && list.bounds.size == originalContent && controller.view.bounds.size == originalView
            }
            try await wait { reachable(selected) && reachable(cancel) && reachable(confirm) }
            verifyDraft()
            print("M11 scene restored: scene=\(scene.effectiveGeometry.coordinateSpace.bounds.size); content=\(list.bounds.size); selected=\(session.selected)")
            if let failure { throw failure }
        }
    }
    @Test func coldPendingOpenWarmReplacementAndStalePickerCallback() async throws {
        let host = ViewTestWindowHost(); host.loadViewIfNeeded()
        var sessions: [OPMLImportSession] = []
        let flow = OPMLImportFlow(host: host, makeSession: {
            let session = OPMLImportSession(read: { url in Data("<opml><outline xmlUrl='\(url.lastPathComponent)'/></opml>".utf8) }, commit: { _ in 0 }, refresh: {})
            sessions.append(session); return session
        }, finished: {}, notice: { _ in })
        flow.open(URL(fileURLWithPath: "/cold")); #expect(sessions.isEmpty)
        try await withViewTestWindow { parent, window in
        parent.addChild(host); parent.view.addSubview(host.view); host.view.frame = parent.view.bounds; host.didMove(toParent: parent)
        defer { sessions.forEach { $0.close() }; host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent() }
        try await wait("mounted child appearance") { host.appeared && host.view.window === window }
        flow.presentPendingDocument()
        try await wait("cold pending selection") { sessions.first?.state == .selecting }
        #expect(sessions[0].document.entries.map(\.xmlURL) == ["cold"])
        flow.open(URL(fileURLWithPath: "/warm"))
        try await wait("warm replacement selection") { sessions.count == 2 && sessions[1].state == .selecting }
        #expect(!sessions[0].isPresented)
        #expect(sessions[1].document.entries.map(\.xmlURL) == ["warm"])
        let stale = UIDocumentPickerViewController(forOpeningContentTypes: [.data])
        flow.documentPicker(stale, didPickDocumentsAt: [URL(fileURLWithPath: "/stale")])
        #expect(sessions.count == 2)
        host.dismiss(animated: false)
        try await wait { host.presentedViewController == nil }
        }
    }
    /// Source `preferences_import_export.xml` puts the Database category above OPML.
    /// Also OPML export above OPML import, each row running its own action.
    @Test func databaseCategoryPrecedesOPMLWhenBackupIsAvailable() throws {
        var backups = 0, imports = 0, exports = 0
        #expect(find("databaseExport", in: BackupRestoreView(importAction: {}, exportAction: {}), as: UIButton.self) == nil)
        let shell = BackupRestoreView(importAction: { imports += 1 }, exportAction: { exports += 1 }, databaseExportAction: { backups += 1 })
        shell.frame = CGRect(origin: .zero, size: shell.sizeThatFits(CGSize(width: 390, height: 844))); shell.layoutIfNeeded()
        let labels = shell.subviews.compactMap { $0 as? UILabel }.map(\.text)
        #expect(labels == ["Database", "OPML"])
        let database: UIButton = try #require(find("databaseExport", in: shell)), opml: UIButton = try #require(find("opmlExport", in: shell))
        #expect(database.accessibilityLabel == "Database export")
        #expect(database.accessibilityHint == "Transfer subscriptions, listened episodes and queue to NotTennaPod on another device")
        #expect(database.frame.maxY <= opml.frame.minY)
        let opmlImport: UIButton = try #require(find("opmlImportPreference", in: shell))
        #expect(opml.frame.maxY <= opmlImport.frame.minY)
        #expect(shell.bounds.height >= opmlImport.frame.maxY)
        database.sendActions(for: .touchUpInside); opml.sendActions(for: .touchUpInside); opmlImport.sendActions(for: .touchUpInside)
        #expect(backups == 1 && exports == 1 && imports == 1)
    }
}
