import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor
struct LocalFolderEntryViewTests {
    private func element<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if let value = view as? T, value.accessibilityIdentifier == id { return value }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: type) }.first
    }

    @Test func sourceEntryWordingIconAndActionSurviveWidthAndDirectionChanges() throws {
        var invoked = 0
        let button = AddPodcastEntryButton(title: "Add local folder", image: "ic_folder", identifier: "addLocalFolder") { invoked += 1 }
        let label = try #require(button.subviews.compactMap { $0 as? UILabel }.first)
        let icon = try #require(button.subviews.compactMap { $0 as? UIImageView }.first)
        #expect(label.text == "Add local folder" && button.accessibilityLabel == label.text)
        #expect(icon.image != nil)
        #expect(label.font.fontName == "Roboto-Regular" && label.font.pointSize == 14)
        for width in [240, 402, 834] as [CGFloat] {
            for rtl in [false, true] {
                button.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                button.frame = CGRect(origin: .zero, size: button.sizeThatFits(CGSize(width: width, height: 1000)))
                button.setNeedsLayout(); button.layoutIfNeeded()
                // A comfortably tappable row; icon and full wording visible, side by side, not overlapping.
                #expect(abs(button.bounds.height - 48) <= 1)
                #expect(button.bounds.contains(icon.frame) && button.bounds.contains(label.frame))
                #expect(!icon.frame.intersects(label.frame))
                #expect(label.intrinsicContentSize.width <= label.frame.width + 0.5)
                #expect(abs(label.frame.midY - icon.frame.midY) <= 1)
                // The icon leads the wording in both directions.
                if rtl { #expect(icon.frame.minX > label.frame.maxX - 0.5 && label.textAlignment == .right) }
                else { #expect(icon.frame.maxX < label.frame.minX + 0.5 && label.textAlignment == .left) }
                button.sendActions(for: .touchUpInside)
            }
        }
        #expect(invoked == 6)
    }

    @Test func pickerCancelsWithoutSelectionAndRejectsOldOrDuplicateCallbacks() {
        let delegate = LocalFolderPicker()
        var selected: [URL] = []
        let first = delegate.makeController { selected.append($0) }
        #expect(first.allowsMultipleSelection == false)
        #expect(first.delegate === delegate)
        delegate.documentPickerWasCancelled(first)
        let url = URL(filePath: "/fixture/folder")
        delegate.documentPicker(first, didPickDocumentsAt: [url])
        #expect(selected.isEmpty)
        let old = delegate.makeController { selected.append($0) }
        let current = delegate.makeController { selected.append($0) }
        delegate.documentPicker(old, didPickDocumentsAt: [url])
        delegate.documentPickerWasCancelled(old)
        #expect(selected.isEmpty)
        delegate.documentPicker(current, didPickDocumentsAt: [url])
        delegate.documentPicker(current, didPickDocumentsAt: [url])
        #expect(selected == [url])
        let empty = delegate.makeController { selected.append($0) }
        delegate.documentPicker(empty, didPickDocumentsAt: [])
        #expect(selected == [url])
    }

    @Test func appEntryRegistersRealFolderOpensFeedAndBackReturnsToAddPodcast() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalFolderEntryView-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Test local podcast")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let library = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let preferences = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
        var value = preferences.value
        value.defaultPage = NavigationDestination.addPodcast.rawValue
        try preferences.update(value)
        let controller = LibraryViewController(library: library, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: preferences, speedPreferences: nil,
            mobileNetworkPreferences: nil, usage: nil)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while element("addLocalFolder", in: controller.view, as: UIControl.self) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let rss = try #require(element("addRSS", in: controller.view, as: UIControl.self))
        let folder = try #require(element("addLocalFolder", in: controller.view, as: UIControl.self))
        #expect(folder.frame.minY >= rss.frame.maxY - 0.5) // listed directly after "Add podcast by RSS address"
        await controller.addLocalFolder(directory)
        let feed = try #require(try await library.feeds().first)
        #expect(feed.title == "Test local podcast" && feed.episodeSortOrderCode == 3)
        #expect(try await library.localFolder(feedID: feed.id) != nil)
        let back = try #require(element("toolbarBack", in: controller.view, as: UIButton.self))
        // Returning from the feed does not cancel the separately owned refresh.
        back.sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
        #expect(element("addLocalFolder", in: controller.view, as: UIControl.self) != nil)
        let completionDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await library.logs(feedID: feed.id).isEmpty, ContinuousClock.now < completionDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await library.logs(feedID: feed.id).first?.kind == .success)
        #expect(try await library.feed(id: feed.id)?.metadata.author == "Local folder")
        try await library.close()
    }
}
