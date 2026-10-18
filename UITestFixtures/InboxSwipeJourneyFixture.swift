#if DEBUG
import Foundation
import UIKit
import NotTennaPodCore

/// A UUID-isolated, media-less NEW fixture for real gesture/filter/Undo journeys.
/// Relaunch never reseeds state or preferences. No networking or cleanup policy.
enum InboxSwipeJourneyFixture {
    @MainActor private static var accessibilityProbe: InboxSwipeAccessibilityProbe?
    @MainActor static func prepare(root: URL, store: FeedLibraryStore, downloads: DownloadPreferenceStore,
                                   filter: AllEpisodesFilterPreferenceStore) async throws {
        let manifest = root.appendingPathComponent("ready.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            try installAccessibilityProbe(root: root, store: store)
            return
        }
        guard !FileManager.default.fileExists(atPath: root.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = "https://example.invalid/inbox-swipe-journey"
        let body = Data("""
        <rss version="2.0"><channel><title>Swipe journey</title>
        <item><guid>swipe-target</guid><title>Swipe journey target</title></item>
        <item><guid>swipe-survivor</guid><title>Swipe journey survivor</title></item>
        </channel></rss>
        """.utf8)
        let response = try await FeedFetcher(transport: Transport(url: URL(string: source)!, body: body))
            .fetch(.init(source: source, generateMissingArtwork: false))
        guard case .updated(let fetched) = response else { throw CocoaError(.fileReadCorruptFile) }
        let feed = try await store.insert(fetched)
        for item in feed.episodes { try await store.updateEpisode(id: item.id) { $0.userState.playState = .new } }
        var settings = downloads.value; settings.autoDelete = false; settings.autoDeleteLocal = false
        try downloads.update(settings)
        // Legacy stored NEW is supported by the source, but deliberately has no picker button.
        try filter.update(.init(values: ["new"]))
        try JSONEncoder().encode(feed.episodes.map(\.id)).write(to: manifest, options: .atomic)
        try installAccessibilityProbe(root: root, store: store)
    }
    @MainActor private static func installAccessibilityProbe(root: URL, store: FeedLibraryStore) throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-test-inbox-swipe-voiceover"),
              let index = arguments.firstIndex(of: "-test-library-id"), index + 1 < arguments.count,
              let id = UUID(uuidString: arguments[index + 1]),
              root.deletingLastPathComponent().lastPathComponent == "UITests-" + id.uuidString else { return }
        accessibilityProbe?.stop()
        accessibilityProbe = try InboxSwipeAccessibilityProbe(root: root, libraryID: id, store: store)
        accessibilityProbe?.start()
    }

    private struct Transport: FeedHTTPTransport {
        let url: URL, body: Data
        func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
            guard request.url == url else { throw URLError(.unsupportedURL) }
            return .init(url: url, status: 200, headers: ["Content-Type": "application/rss+xml"], body: body)
        }
    }
}

/// Controlled setup and read-only observation, never an accessibility input oracle.
/// Only the explicit UUID/DEBUG fixture installs this bounded probe. The real
/// controller/recipient owns the offer, timing, focus handling and Undo operation.
@MainActor private final class InboxSwipeAccessibilityProbe: NSObject {
    private struct Command: Codable {
        let libraryID: UUID
        let nonce: UUID
        let action: String
    }
    private let root: URL, libraryID: UUID, store: FeedLibraryStore
    private var task: Task<Void, Never>?
    private var stopped = false
    private var lastSnapshot = Data()
    private var lastSampleTime: TimeInterval = 0
    private weak var observedOffer: Snackbar?
    private var observedOfferID: UUID?

    init(root: URL, libraryID: UUID, store: FeedLibraryStore) throws {
        self.root = root; self.libraryID = libraryID; self.store = store
        super.init()
        try record("probe-ready")
        NotificationCenter.default.addObserver(self, selector: #selector(focusChanged(_:)),
            name: UIAccessibility.elementFocusedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(announcementFinished(_:)),
            name: UIAccessibility.announcementDidFinishNotification, object: nil)
    }
    func start() {
        task = Task { [weak self] in
            let deadline = ProcessInfo.processInfo.systemUptime + 120
            while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
                guard let self, !stopped else { return }
                do {
                    try await receiveCommand()
                    let state = snapshot()
                    let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
                    let now = ProcessInfo.processInfo.systemUptime
                    if data != lastSnapshot || now - lastSampleTime >= 0.25 {
                        try record("sample", extra: state); lastSnapshot = data; lastSampleTime = now
                    }
                    try await Task.sleep(for: .milliseconds(25))
                } catch is CancellationError { return }
                catch {
                    recordSafely("probe-failure", extra: ["error": String(describing: error)])
                    stop(); return
                }
            }
            self?.recordSafely("probe-ended")
            self?.stop()
        }
    }
    func stop() {
        stopped = true; task?.cancel(); task = nil
        NotificationCenter.default.removeObserver(self)
    }
    private func receiveCommand() async throws {
        let consumedURL = root.appendingPathComponent("voiceover-offer-consumed.json")
        // The offer is created once, as soon as VoiceOver runs: the test enables it after configuring the swipe.
        guard UIAccessibility.isVoiceOverRunning, !FileManager.default.fileExists(atPath: consumedURL.path) else { return }
        let command = Command(libraryID: libraryID, nonce: UUID(), action: "offer")
        // Persist consumption before admitting any action; relaunch cannot replay it.
        try JSONEncoder().encode(command).write(to: consumedURL, options: .atomic)
        let state = try await store.snapshot()
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let targets = state.feeds.filter { $0.source == "https://example.invalid/inbox-swipe-journey" }
            .flatMap(\.episodes).filter { $0.details.identifier == "swipe-target" }
        guard UIAccessibility.isVoiceOverRunning, targets.count == 1,
              let target = targets.first, target.userState.playState == .new,
              let controller = controller(), controller.presentedViewController == nil,
              controller.view.window != nil,
              let configuration = controller.inboxSwipeConfiguration(.left, episodeID: target.id),
              configuration.inboxAction == .removeInbox, configuration.removes else {
            throw NSError(domain: "InboxSwipeAccessibilitySetup", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "VoiceOver, NEW target, mounted route or configured real recipient missing"])
        }
        try record("controlled-recipient-admission", extra: ["nonce": command.nonce.uuidString, "episodeID": target.id])
        controller.performInboxSwipe(.left, episodeID: target.id)
        await controller.lastInboxSwipe?.value
        try record("controlled-recipient-returned", extra: ["nonce": command.nonce.uuidString])
    }
    private func controller() -> LibraryViewController? {
        @MainActor func find(_ node: UIViewController) -> LibraryViewController? {
            if let library = node as? LibraryViewController { return library }
            for child in node.children { if let result = find(child) { return result } }
            if let presented = node.presentedViewController { return find(presented) }
            return nil
        }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { $0.isKeyWindow && !$0.isHidden }
            .compactMap { $0.rootViewController.flatMap(find) }.first
    }
    private func find(_ id: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == id { return view }
        return view.subviews.lazy.compactMap { self.find(id, in: $0) }.first
    }
    private func describe(_ element: Any?) -> [String: Any] {
        guard let element else { return [:] }
        var value: [String: Any] = ["type": String(describing: type(of: element))]
        if let view = element as? UIView {
            value["identifier"] = view.accessibilityIdentifier ?? ""
            value["label"] = view.accessibilityLabel ?? ""
            value["focused"] = view.accessibilityElementIsFocused()
            value["technologies"] = view.accessibilityAssistiveTechnologyFocusedIdentifiers()?.map(\.rawValue).sorted() ?? []
            value["frame"] = NSCoder.string(for: view.convert(view.bounds, to: view.window))
        }
        return value
    }
    private func snapshot() -> [String: Any] {
        var value: [String: Any] = ["focusedElement": describe(UIAccessibility.focusedElement(using: .notificationVoiceOver))]
        if let controller = controller(), let bar = find("inboxSwipeSnackbar", in: controller.view) as? Snackbar {
            if observedOffer !== bar { observedOffer = bar; observedOfferID = UUID() }
            value["offerID"] = observedOfferID!.uuidString
            value["message"] = describe(bar.label)
            value["undo"] = describe(find("inboxSwipeUndo", in: bar))
            value["attached"] = bar.window != nil
            value["alpha"] = Double(bar.alpha)
        }
        return value
    }
    @objc private func focusChanged(_ notification: Notification) {
        recordSafely("focus-notification", extra: [
            "focused": describe(notification.userInfo?[UIAccessibility.focusedElementUserInfoKey]),
            "unfocused": describe(notification.userInfo?[UIAccessibility.unfocusedElementUserInfoKey]),
            "technology": String(describing: notification.userInfo?[UIAccessibility.assistiveTechnologyUserInfoKey] ?? "")])
    }
    @objc private func announcementFinished(_ notification: Notification) {
        recordSafely("announcement-finished", extra: [
            "announcement": notification.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String ?? "",
            "successful": notification.userInfo?[UIAccessibility.announcementWasSuccessfulUserInfoKey] as? Bool ?? false])
    }
    private func record(_ event: String, extra: [String: Any] = [:]) throws {
        var value = snapshot()
        value.merge(extra) { _, new in new }
        value["event"] = event; value["libraryID"] = libraryID.uuidString
        value["uptime"] = ProcessInfo.processInfo.systemUptime
        value["voiceOver"] = UIAccessibility.isVoiceOverRunning
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); data.append(0x0a)
        let file = root.appendingPathComponent("voiceover-observed.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) { try Data().write(to: file, options: .withoutOverwriting) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
    private func recordSafely(_ event: String, extra: [String: Any] = [:]) {
        do { try record(event, extra: extra) }
        catch { print("VOICEOVER_UNDO_PROBE_WRITE_FAILURE \(libraryID.uuidString): \(error)"); stop() }
    }
}
#endif
