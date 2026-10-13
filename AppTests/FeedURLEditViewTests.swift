import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor
struct FeedURLEditViewTests {
    private func element<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if view.accessibilityIdentifier == id { return view as? T }
        for child in view.subviews { if let result = element(id, in: child, as: type) { return result } }
        return nil
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await condition()), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await condition())
    }
    private func withHost(_ run: (UIViewController) async throws -> Void) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { host.dismiss(animated: false); window.isHidden = true; previous?.makeKey() }
        try await run(host)
    }
    private func layout(_ view: UIView, width: CGFloat) {
        view.frame = CGRect(origin: .zero, size: view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)))
        view.setNeedsLayout(); view.layoutIfNeeded()
    }

    @Test func originalMultilineInputInsetsSelectionAndGrowth() async throws {
        for width: CGFloat in [280, 360, 560] {
            for rtl in [false, true] {
                for initial in ["", "https://example.com/feed", "https://example.com/long/path?one=1&b=two#section\nsecond line"] {
                    let input = FeedURLEditInputView(value: initial)
                    input.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                    layout(input, width: width)
                    let text = input.textView
                    #expect(input.value == initial && text.selectedRange == NSRange(location: 0, length: 0))
                    #expect(text.isEditable && text.isSelectable && !text.isScrollEnabled)
                    #expect(text.keyboardType == .default && text.returnKeyType == .default)
                    #expect(text.autocapitalizationType == .none && text.autocorrectionType == .no)
                    #expect(text.textContainer.maximumNumberOfLines == 0 && text.textContainer.lineFragmentPadding == 0)
                    // Outlined field with equal side margins, fully inside the dialog body.
                    #expect(text.frame.minX > 0 && abs(text.frame.minX - (width - text.frame.maxX)) < 1)
                    #expect(text.frame.minY > 0 && input.bounds.height > text.frame.maxY && text.bounds.height >= 56)
                    #expect(text.textContainerInset.left > 0 && text.textContainerInset.top > 0, "Text is padded inside the outline")
                    #expect(text.font?.fontName == "Roboto-Regular" && text.font?.pointSize == 16)
                    #expect(text.layer.cornerRadius > 0 && text.layer.borderWidth > 0)
                    let oldHeight = input.bounds.height
                    text.selectedRange = NSRange(location: 0, length: 0)
                    text.insertText("first\nsecond\nthird\nfourth\n")
                    layout(input, width: width)
                    #expect(input.value.hasPrefix("first\nsecond\nthird\nfourth\n") && input.bounds.height > oldHeight)
                    let savedText = input.value, selection = text.selectedRange
                    input.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
                    input.updateTraitsIfNeeded(); await Task.yield(); layout(input, width: width)
                    #expect((text.font?.pointSize ?? 0) > 16 && input.value == savedText && text.selectedRange == selection)
                }
            }
        }
    }

    @Test func prefilledInputThenGuardedWarningPersistsBeforeRefreshAndVisibleUpdate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EditURLViews-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let original = "https://old.example/feed", updated = "  https://new.example/feed?one=1&b=2  "
        let feed = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Original"), source: original,
            responseURL: URL(string: original)!, validator: "old", permanentRedirectURL: nil))
        let recorder = EditURLViewRecorder(), gate = EditURLViewSleepGate()
        let countdown = FeedURLConfirmationCountdown(now: { recorder.now }, sleep: { _ in await gate.sleep() })
        let flow = FeedURLEditFlow(original: original, save: { old, new in
            #expect(old == original && new == updated)
            try await store.updateFeedDownloadURL(original: old, updated: new)
            await recorder.record("saved")
        }, requestForcedRefresh: { recorder.record("refresh") }, didUpdateURL: { value in
            #expect(value == updated); recorder.record("visible")
        }, failed: { error in Issue.record(error) }, makeCountdown: { countdown })
        try await withHost { host in
            let input = try #require(flow.show(from: host))
            try await waitUntil { host.presentedViewController === input && !input.isBeingPresented }
            let field: UITextView = try #require(element("editFeedURLInput", in: input.view))
            #expect(field.text == original && field.selectedRange.location == 0)
            field.text = updated
            try #require(element("editFeedURLNext", in: input.view, as: UIButton.self)).sendActions(for: .touchUpInside)
            try await waitUntil { host.presentedViewController is FeedURLConfirmationController }
            let warning = try #require(host.presentedViewController as? FeedURLConfirmationController)
            try await waitUntil { await gate.count == 1 }
            let title: UILabel = try #require(element("sourceMessageTitle", in: warning.view))
            let message: UILabel = try #require(element("sourceMessage", in: warning.view))
            #expect(title.text == "Edit feed URL" && message.text == Appearance.text("edit_url_confirmation_msg"))
            let confirm: UIButton = try #require(element("editFeedURLConfirm", in: warning.view))
            #expect(!confirm.isEnabled && confirm.title(for: .normal) == "OK (16)")
            confirm.sendActions(for: .touchUpInside)
            #expect(recorder.events.isEmpty && host.presentedViewController === warning)
            #expect(try await store.feed(id: feed.id)?.source == original)
            recorder.now = .milliseconds(14999); await gate.resumeNext()
            try await waitUntil { await gate.count == 2 }
            #expect(!confirm.isEnabled && confirm.title(for: .normal) == "OK (1)")
            recorder.now = .seconds(15); await gate.resumeNext()
            try await waitUntil { confirm.isEnabled }
            #expect(confirm.title(for: .normal) == "OK")
            confirm.sendActions(for: .touchUpInside); confirm.sendActions(for: .touchUpInside)
            try await waitUntil { recorder.events.count == 3 && host.presentedViewController == nil }
            #expect(recorder.events == ["saved", "refresh", "visible"])
            #expect(flow.original == updated && !flow.isSaving)
            #expect(try await store.feed(id: feed.id)?.source == updated)
        }
        try await store.close()
    }

    @Test func multilineEditingKeepsCaretVisibleInDialogAndFailureDoesNotPublishSuccess() async throws {
        let state = EditURLViewRecorder(), gate = EditURLViewSleepGate()
        let countdown = FeedURLConfirmationCountdown(now: { state.now }, sleep: { _ in await gate.sleep() })
        let flow = FeedURLEditFlow(original: "https://original.example/feed", save: { _, _ in
            throw NSError(domain: "fixture-storage", code: 1)
        }, requestForcedRefresh: { Issue.record("Failed save must not refresh") },
           didUpdateURL: { _ in Issue.record("Failed save must not update the URL") },
           failed: { _ in state.record("failed") }, makeCountdown: { countdown })
        try await withHost { host in
            let input = try #require(flow.show(from: host))
            try await waitUntil { !input.isBeingPresented }
            let field: UITextView = try #require(element("editFeedURLInput", in: input.view))
            #expect(field.becomeFirstResponder())
            field.insertText(String(repeating: "long field value\n", count: 40))
            input.view.setNeedsLayout(); input.view.layoutIfNeeded()
            input.revealTextPosition(field)
            var ancestor = field.superview
            while ancestor != nil && !(ancestor is UIScrollView) { ancestor = ancestor?.superview }
            let scroller = try #require(ancestor as? UIScrollView)
            let selection = try #require(field.selectedTextRange)
            let caret = field.convert(field.caretRect(for: selection.end), to: scroller)
            #expect(caret.minY >= scroller.bounds.minY - 1 && caret.maxY <= scroller.bounds.maxY + 1)
            #expect(field.layer.borderWidth > 1, "Focused outline is emphasised")
            field.resignFirstResponder()
            try #require(element("editFeedURLNext", in: input.view, as: UIButton.self)).sendActions(for: .touchUpInside)
            try await waitUntil { host.presentedViewController is FeedURLConfirmationController }
            let warning = try #require(host.presentedViewController as? FeedURLConfirmationController)
            try await waitUntil { await gate.count == 1 }
            state.now = .seconds(20); await gate.resumeNext()
            let confirm: UIButton = try #require(element("editFeedURLConfirm", in: warning.view))
            try await waitUntil { confirm.isEnabled }
            confirm.sendActions(for: .touchUpInside)
            try await waitUntil { state.events == ["failed"] && host.presentedViewController == nil }
            #expect(!flow.isSaving && flow.original == "https://original.example/feed")
        }
    }

    @Test func cancelAndEscapeNeverCommitAndStopCountdownWakeups() async throws {
        for action in ["inputCancel", "warningCancel", "escape", "externalDismiss"] {
            let state = EditURLViewRecorder(), gate = EditURLViewSleepGate()
            let countdown = FeedURLConfirmationCountdown(now: { state.now }, sleep: { _ in await gate.sleep() })
            let flow = FeedURLEditFlow(original: "https://example.com/feed", save: { _, _ in Issue.record("Cancelled edit must not write") },
                requestForcedRefresh: { Issue.record("Cancelled edit must not refresh") }, didUpdateURL: { _ in Issue.record("Cancelled edit must not change visible URL") },
                failed: { Issue.record($0) }, makeCountdown: { countdown })
            try await withHost { host in
                let input = try #require(flow.show(from: host))
                try await waitUntil { !input.isBeingPresented }
                if action == "inputCancel" {
                    try #require(element("editFeedURLCancel", in: input.view, as: UIButton.self)).sendActions(for: .touchUpInside)
                } else {
                    try #require(element("editFeedURLNext", in: input.view, as: UIButton.self)).sendActions(for: .touchUpInside)
                    try await waitUntil { host.presentedViewController is FeedURLConfirmationController }
                    let warning = try #require(host.presentedViewController as? FeedURLConfirmationController)
                    try await waitUntil { await gate.count == 1 && !warning.isBeingPresented }
                    if action == "warningCancel" { try #require(element("editFeedURLCancel", in: warning.view, as: UIButton.self)).sendActions(for: .touchUpInside) }
                    else if action == "escape" { #expect(warning.accessibilityPerformEscape()) }
                    else { host.dismiss(animated: false) }
                }
                try await waitUntil { host.presentedViewController == nil }
                #expect(countdown.state == .idle)
                state.now = .seconds(100); await gate.resumeNext(); await Task.yield()
                #expect(countdown.state == .idle && !flow.isSaving)
            }
        }
    }
}

@MainActor private final class EditURLViewRecorder {
    var now: Duration = .zero
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}
private actor EditURLViewSleepGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var count = 0
    func sleep() async { count += 1; await withCheckedContinuation { continuations.append($0) } }
    func resumeNext() { if !continuations.isEmpty { continuations.removeFirst().resume() } }
}
