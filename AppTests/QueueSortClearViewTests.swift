import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Mounted Queue screen and Playback settings: the overflow menu (unlocked, locked, Keep sorted), the Sort
/// sheet with Keep sorted, drag disabled while sorted, Clear queue and the Enqueue settings rows.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct QueueSortClearViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if view.accessibilityIdentifier == id, let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(id, in: $0, as: type) }.first
    }
    private func wait(_ condition: @MainActor () async throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while try await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await condition(), sourceLocation: sourceLocation)
    }

    struct Fixture {
        let root: URL, store: FeedLibraryStore, queue: QueueInteractionPreferenceStore, downloads: DownloadPreferenceStore
        let ids: [String: Int64]
    }
    /// One feed. E1 30 min, E2 10 min, E3 20 min, E4 40 min are queued in that order; E5 (5 min) is not.
    private func withFixture(_ body: @MainActor (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("M23View-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let minutes: [String: Int32] = ["E1": 30, "E2": 10, "E3": 20, "E4": 40, "E5": 5]
        let episodes = minutes.keys.sorted().enumerated().map { index, title in
            ParsedEpisode(identifier: title, title: title, publicationDate: base.addingTimeInterval(Double(index) * 3600),
                          media: .init(url: "https://example.test/\(title).mp3", size: 1, durationMilliseconds: minutes[title]! * 60_000))
        }
        let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Sorted", episodes: episodes), source: "https://example.test/feed",
            responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        let ids = Dictionary(uniqueKeysWithValues: feed.episodes.map { ($0.details.title!, $0.id) })
        _ = try await store.enqueue(["E1", "E2", "E3", "E4"].map { ids[$0]! })
        let queue = try QueueInteractionPreferenceStore(file: root.appendingPathComponent("queue.json"))
        let downloads = try DownloadPreferenceStore(file: root.appendingPathComponent("downloads.json"))
        do { try await body(Fixture(root: root, store: store, queue: queue, downloads: downloads, ids: ids)) }
        catch { store.setQueueInsertionSettings(.init()); try? await store.close(); throw error }
        try await store.close()
    }
    private func withScreen(_ destination: NavigationDestination, _ fixture: Fixture, rtl: Bool = false,
                            _ body: @MainActor (LibraryViewController, @MainActor (String, UIView?) throws -> Void, @MainActor () -> [String]) async throws -> Void) async throws {
        let navigation = try NavigationPreferenceStore(file: fixture.root.appendingPathComponent("navigation-\(UUID()).json"))
        var value = navigation.value; value.defaultPage = destination.rawValue; try navigation.update(value)
        let controller = LibraryViewController(library: fixture.store, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil,
            downloadPreferences: fixture.downloads, queueInteractionPreferences: fixture.queue)
        let titles = Dictionary(uniqueKeysWithValues: fixture.ids.map { ($0.value, $0.key) })
        try await withViewTestWindow { host, window in
            // Presentations take the window's layout direction, as with a right-to-left system language.
            if rtl { window.traitOverrides.layoutDirection = .rightToLeft; controller.view.semanticContentAttribute = .forceRightToLeft }
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            controller.view.frame = host.view.bounds
            await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
            let tap: @MainActor (String, UIView?) throws -> Void = { id, view in
                controller.view.layoutIfNeeded()
                let control: UIControl = try #require(self.find(id, in: view ?? controller.view), "Missing \(id)")
                #expect(control.isEnabled, "\(id) enabled")
                control.sendActions(for: .touchUpInside)
                controller.view.layoutIfNeeded()
            }
            let order: @MainActor () -> [String] = {
                controller.view.layoutIfNeeded()
                return fixture.ids.values.compactMap { id -> (CGFloat, String)? in
                    guard let row = self.find("episode-\(id)", in: controller.view, as: UIButton.self) else { return nil }
                    return (row.convert(row.bounds, to: controller.view).minY, titles[id]!)
                }.sorted { $0.0 < $1.0 }.map(\.1)
            }
            try await body(controller, tap, order)
        }
    }
    private func menuOrder(_ view: UIView) -> [String] {
        ["queueSort", "queueClear", "queueRefresh", "queueLock"].compactMap { id in
            find(id, in: view, as: UIButton.self).map { (id, $0.convert($0.bounds, to: view).minY) }
        }.sorted { $0.1 < $1.1 }.map(\.0)
    }
    private func closeMenu(_ controller: LibraryViewController) {
        find("queueMenu", in: controller.view, as: UIControl.self)?.sendActions(for: .touchUpInside)
    }
    private func presentedSheet(_ controller: LibraryViewController) async throws -> QueueSortController {
        try await wait { (controller.presentedViewController as? QueueSortController)?.isBeingPresented == false }
        let sheet = try #require(controller.presentedViewController as? QueueSortController)
        sheet.view.layoutIfNeeded()
        return sheet
    }
    private func dragHandleShown(_ id: Int64, _ controller: LibraryViewController) throws -> Bool {
        let button = try #require(find("episode-\(id)", in: controller.view, as: UIButton.self))
        let row = try #require(button.superview as? EpisodeRowView)
        let handle = try #require(Mirror(reflecting: row).children.first { $0.label == "drag" }?.value as? UIImageView)
        return !handle.isHidden && row.acceptsQueueDrag(at: CGPoint(x: handle.frame.midX, y: handle.frame.midY), policy: controller.queuePolicy)
    }

    @Test func menuSortSheetKeepSortedHidesLockAndDisablesDragUntilTurnedOff() async throws {
        try await withFixture { fixture in
            try fixture.queue.update(.init(locked: true, showLockWarning: false))
            try await withScreen(.queue, fixture) { controller, tap, order in
                #expect(order() == ["E1", "E2", "E3", "E4"])
                try tap("queueMore", nil)
                #expect(menuOrder(controller.view) == ["queueSort", "queueClear", "queueRefresh", "queueLock"], "Locked: Lock shown, checked")
                #expect(find("queueSort", in: controller.view, as: UIButton.self)?.title(for: .normal) == "Sort")
                #expect(find("queueClear", in: controller.view, as: UIButton.self)?.title(for: .normal) == "Clear queue")
                #expect(find("queueLock", in: controller.view, as: UIButton.self)?.accessibilityTraits.contains(.selected) == true)
                try tap("queueSort", nil)
                let sheet = try await presentedSheet(controller)
                // Opened with Keep sorted off: no active row; the checkbox is unchecked and disabled.
                let rows = QueueSortRow.allCases.map { find("queueSort-\($0.rawValue)", in: sheet.view, as: UIButton.self) }
                #expect(rows.map { $0?.title(for: .normal) } == ["Episode title", "Podcast title", "Duration", "Date", "Random", "Smart shuffle"])
                #expect(rows.allSatisfy { $0?.accessibilityTraits.contains(.selected) == false })
                let frames = rows.compactMap { $0?.convert($0!.bounds, to: sheet.view) }
                for pair in stride(from: 0, to: 6, by: 2) {
                    #expect(abs(frames[pair].minY - frames[pair + 1].minY) < 1 && frames[pair].maxX <= frames[pair + 1].minX, "Two columns, row-major")
                    if pair > 0 { #expect(frames[pair].minY >= frames[pair - 1].maxY) }
                }
                let keep = sheet.keepSorted
                #expect(keep.accessibilityLabel == "Keep sorted" && !keep.checked && !keep.isEnabled && keep.accessibilityTraits.contains(.notEnabled))
                let keepFrame = keep.convert(keep.bounds, to: sheet.view)
                #expect(keepFrame.minY >= frames[5].maxY && keepFrame.minX <= frames[0].minX + 1 && keepFrame.maxX >= frames[5].maxX - 1, "Full width under the grid")
                #expect(sheet.view.bounds.contains(keepFrame))

                // Duration: shortest first, re-sorted at once; the order is saved even with Keep sorted off.
                try tap("queueSort-duration", sheet.view)
                #expect(rows[2]?.title(for: .normal) == "Duration\u{a0}▲" && rows[2]?.accessibilityTraits.contains(.selected) == true)
                #expect(keep.isEnabled && !keep.checked)
                #expect(fixture.queue.value.keepSortedOrderName == "DURATION_SHORT_LONG" && !fixture.queue.value.keepSorted)
                try await wait { order() == ["E2", "E3", "E1", "E4"] }
                // Keep sorted on: Lock disappears and dragging stops at once, while the sheet is open.
                try tap("queueKeepSorted", sheet.view)
                #expect(keep.checked && keep.accessibilityValue == "On" && fixture.queue.value.keepSorted)
                #expect(!(try dragHandleShown(fixture.ids["E1"]!, controller)))
                // Random turns Keep sorted off and disables it; Duration again restores it.
                try tap("queueSort-random", sheet.view)
                #expect(rows[4]?.title(for: .normal) == "Random" && !keep.checked && !keep.isEnabled && !fixture.queue.value.keepSorted)
                #expect(fixture.queue.value.keepSortedOrderName == "RANDOM")
                try await wait { Set(order()) == ["E1", "E2", "E3", "E4"] }
                try tap("queueSort-duration", sheet.view)
                #expect(keep.checked && keep.isEnabled && fixture.queue.value.keepSorted)
                try await wait { order() == ["E2", "E3", "E1", "E4"] }
                // Tapping the active row flips it.
                try tap("queueSort-duration", sheet.view)
                #expect(rows[2]?.title(for: .normal) == "Duration\u{a0}▼" && fixture.queue.value.keepSortedOrderName == "DURATION_LONG_SHORT")
                try await wait { order() == ["E4", "E1", "E3", "E2"] }
                try tap("queueSort-duration", sheet.view)
                try await wait { order() == ["E2", "E3", "E1", "E4"] }
                sheet.dismiss(animated: false); try await wait { controller.presentedViewController == nil }

                // Keep sorted menu: no Lock; no drag handles; no Move to top/bottom.
                try tap("queueMore", nil)
                #expect(menuOrder(controller.view) == ["queueSort", "queueClear", "queueRefresh"])
                closeMenu(controller)
                for id in fixture.ids.values where id != fixture.ids["E5"] { #expect(!(try dragHandleShown(id, controller))) }
                #expect(!controller.queuePolicy.allowsDrag)
                let row = try #require(find("episode-\(fixture.ids["E3"]!)", in: controller.view, as: UIButton.self)?.superview as? EpisodeRowView)
                row.contextMenu?(row, .init(x: 0.5, y: 0.5))
                try await wait { controller.presentedViewController?.isBeingPresented == false }
                let menu = try #require(controller.presentedViewController)
                #expect(find("queue-top", in: menu.view, as: UIControl.self) == nil && find("queue-bottom", in: menu.view, as: UIControl.self) == nil)
                menu.dismiss(animated: false); try await wait { controller.presentedViewController == nil }

                // An addition is sorted in: E5 (5 min) goes first.
                _ = try await fixture.store.enqueueUsingSettings([fixture.ids["E5"]!])
                await controller.reloadLibrary()?.value
                #expect(order() == ["E5", "E2", "E3", "E1", "E4"])

                // Keep sorted off: Lock returns with its earlier (locked) state; dragging stays off because locked.
                try tap("queueMore", nil); try tap("queueSort", nil)
                let reopened = try await presentedSheet(controller)
                #expect(reopened.keepSorted.checked && reopened.keepSorted.isEnabled)
                #expect(find("queueSort-duration", in: reopened.view, as: UIButton.self)?.title(for: .normal) == "Duration\u{a0}▲")
                try tap("queueKeepSorted", reopened.view)
                #expect(!fixture.queue.value.keepSorted && fixture.queue.value.locked)
                reopened.dismiss(animated: false); try await wait { controller.presentedViewController == nil }
                try tap("queueMore", nil)
                #expect(menuOrder(controller.view) == ["queueSort", "queueClear", "queueRefresh", "queueLock"])
                try tap("queueLock", nil)
                #expect(!fixture.queue.value.locked)
                try await wait { try dragHandleShown(fixture.ids["E1"]!, controller) }
                // Additions now follow Enqueue location (Back) instead of the sort.
                #expect(fixture.store.queueInsertionSettings.keepSortedOrder == nil)
            }
            // Keep sorted and its order survive a reopened store.
            let stored = try QueueInteractionPreferenceStore(file: fixture.root.appendingPathComponent("queue.json")).value
            #expect(stored.keepSortedOrderName == "DURATION_SHORT_LONG" && !stored.keepSorted)
        }
    }

    @Test func clearQueueAsksThenRemovesEveryEpisodeAndNoListShowsItQueued() async throws {
        try await withFixture { fixture in
            try await withScreen(.queue, fixture) { controller, tap, order in
                try tap("queueMore", nil); try tap("queueClear", nil)
                try await wait { controller.presentedViewController is SourceMessageController && controller.presentedViewController?.isBeingPresented == false }
                let prompt = try #require(controller.presentedViewController)
                #expect(find("sourceMessageTitle", in: prompt.view, as: UILabel.self)?.text == "Clear queue")
                #expect(find("queueClearConfirm", in: prompt.view, as: UIButton.self)?.title(for: .normal) == "Confirm")
                #expect(find("queueClearCancel", in: prompt.view, as: UIButton.self)?.title(for: .normal) == "Cancel")
                func texts(_ view: UIView) -> [String] {
                    let own: [String] = (view as? UILabel)?.text.map { [$0] } ?? []
                    return own + view.subviews.flatMap(texts)
                }
                #expect(texts(prompt.view).contains("Please confirm that you want to remove ALL episodes from the queue."))
                try tap("queueClearCancel", prompt.view)
                try await wait { controller.presentedViewController == nil }
                #expect(order() == ["E1", "E2", "E3", "E4"])
                #expect(try await fixture.store.queue().count == 4)

                try tap("queueMore", nil); try tap("queueClear", nil)
                try await wait { controller.presentedViewController is SourceMessageController && controller.presentedViewController?.isBeingPresented == false }
                try tap("queueClearConfirm", controller.presentedViewController!.view)
                try await wait { controller.presentedViewController == nil && order().isEmpty }
                #expect(try await fixture.store.queue().isEmpty)
                #expect(find("queueInformation", in: controller.view, as: UILabel.self)?.text == "0 episodes • 0\u{a0}minutes left")
                // Clear on an empty queue still asks, then does nothing.
                try tap("queueMore", nil); try tap("queueClear", nil)
                try await wait { controller.presentedViewController is SourceMessageController && controller.presentedViewController?.isBeingPresented == false }
                try tap("queueClearConfirm", controller.presentedViewController!.view)
                try await wait { controller.presentedViewController == nil }
                #expect(fixture.queue.value == .init(), "Clear changes neither Lock nor Keep sorted")

                // The feed's episode list shows no stale "In the queue" indicator.
                controller.push(.feed(try #require(try await fixture.store.feeds().first?.id)))
                try await wait { self.find("episode-\(fixture.ids["E1"]!)", in: controller.view, as: UIButton.self) != nil }
                for id in fixture.ids.values {
                    let row = try #require(find("episode-\(id)", in: controller.view, as: UIButton.self))
                    #expect(row.accessibilityValue?.contains("In the queue") == false, "\(row.accessibilityValue ?? "")")
                }
            }
        }
    }

    @Test func queueSortSheetAndMenuMirrorInRightToLeft() async throws {
        try await withFixture { fixture in
            try await withScreen(.queue, fixture, rtl: true) { controller, tap, _ in
                try tap("queueMore", nil)
                #expect(menuOrder(controller.view) == ["queueSort", "queueClear", "queueRefresh", "queueLock"])
                try tap("queueSort", nil)
                let sheet = try await presentedSheet(controller)
                #expect(sheet.view.effectiveUserInterfaceLayoutDirection == .rightToLeft)
                let title = try #require(find("queueSort-episodeTitle", in: sheet.view, as: UIButton.self))
                let feedTitle = try #require(find("queueSort-feedTitle", in: sheet.view, as: UIButton.self))
                #expect(title.frame.minX > feedTitle.frame.maxX - 1, "The first column is on the right")
                let keep = sheet.keepSorted
                #expect(sheet.view.bounds.contains(keep.convert(keep.bounds, to: sheet.view)))
                try tap("queueSort-date", sheet.view)
                try tap("queueKeepSorted", sheet.view)
                #expect(keep.checked && fixture.queue.value.keepSorted && fixture.queue.value.keepSortedOrderName == "DATE_OLD_NEW")
            }
        }
    }

    @Test func playbackSettingsEditEnqueueLocationAndEnqueueDownloaded() async throws {
        try await withFixture { fixture in
            try await withScreen(.queue, fixture) { controller, tap, _ in
                controller.push(.settings(.playback))
                controller.view.layoutIfNeeded()
                let location = try #require(find("prefEnqueueLocation", in: controller.view, as: UIControl.self))
                let downloaded = try #require(find("prefEnqueueDownloaded", in: controller.view, as: UIControl.self))
                let follow = try #require(find("prefFollowQueue", in: controller.view, as: UIControl.self))
                #expect(location.accessibilityLabel == "Enqueue location" && location.accessibilityHint == "Add episodes to: Back")
                #expect(location.frame.maxY <= downloaded.frame.minY + 0.5 && downloaded.frame.maxY <= follow.frame.minY + 0.5,
                        "Queue category order: Enqueue location, Enqueue downloaded, Continuous playback")
                #expect(downloaded.accessibilityLabel == "Enqueue downloaded" && downloaded.accessibilityHint == "Add downloaded episodes to the queue")
                #expect(downloaded.accessibilityValue == "On")

                try tap("prefEnqueueLocation", nil)
                try await wait { controller.presentedViewController is SourceSingleChoiceController && controller.presentedViewController?.isBeingPresented == false }
                let dialog = try #require(controller.presentedViewController)
                dialog.view.layoutIfNeeded()
                let choices = ["BACK", "FRONT", "AFTER_CURRENTLY_PLAYING", "RANDOM"].compactMap { find("prefEnqueueLocation-\($0)", in: dialog.view, as: UIControl.self) }
                #expect(choices.map(\.accessibilityLabel) == ["Back", "Front", "After current episode", "Random"])
                #expect(zip(choices, choices.dropFirst()).allSatisfy { $0.frame.minY < $1.frame.minY })
                // Cancel keeps the value.
                try tap("prefEnqueueLocationCancel", dialog.view)
                try await wait { controller.presentedViewController == nil }
                #expect(fixture.downloads.value.enqueueLocation == .back)
                try tap("prefEnqueueLocation", nil)
                try await wait { controller.presentedViewController is SourceSingleChoiceController && controller.presentedViewController?.isBeingPresented == false }
                try tap("prefEnqueueLocation-FRONT", controller.presentedViewController!.view)
                try await wait { controller.presentedViewController == nil }
                #expect(fixture.downloads.value.enqueueLocation == .front)
                #expect(fixture.store.queueInsertionSettings.location == .front)
                try await wait { self.find("prefEnqueueLocation", in: controller.view, as: UIControl.self)?.accessibilityHint == "Add episodes to: Front" }

                try tap("prefEnqueueDownloaded", nil)
                #expect(!fixture.downloads.value.enqueue)
                #expect(find("prefEnqueueDownloaded", in: controller.view, as: UIControl.self)?.accessibilityValue == "Off")
                // A user add now goes to the front.
                _ = try await fixture.store.enqueueUsingSettings([fixture.ids["E5"]!])
                #expect(try await fixture.store.queue().first?.id == fixture.ids["E5"])
            }
            let reopened = try DownloadPreferenceStore(file: fixture.root.appendingPathComponent("downloads.json"))
            #expect(reopened.value.enqueueLocation == .front && !reopened.value.enqueue)
            fixture.store.setQueueInsertionSettings(.init())
        }
    }
}
