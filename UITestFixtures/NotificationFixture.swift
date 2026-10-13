#if DEBUG
import Foundation
import UserNotifications
import NotTennaPodCore

/// Notifications journey support, only for a UUID-isolated test library launched with `-test-notification-recorder`.
///
/// Notification permission is a system setting the tests may not depend on or change, so the download-failure
/// delivery posts to this recording center instead of the system: it answers "authorized" and writes each
/// request the app hands over to `notification-requests.json`, and each delivery decision to
/// `download-error-outcomes.json`, in the test library. The journey reads both files directly.
///
/// A tap on the recorded notification is simulated by the journey writing its request identifier to
/// `notification-response` in the test library before launching (cold) or activating (warm) the app; the
/// app then takes the same route as a system notification response.
@MainActor final class NotificationRecorder: SynchronizationNotificationCenter {
    static let requestsFile = "notification-requests.json"
    static let outcomesFile = "download-error-outcomes.json"
    static let responseFile = "notification-response"
    private let directory: URL

    private init(directory: URL) { self.directory = directory }

    static func make(directory: URL, arguments: [String] = ProcessInfo.processInfo.arguments) -> NotificationRecorder? {
        guard directory.lastPathComponent.hasPrefix("UITests-"), arguments.contains("-test-notification-recorder") else { return nil }
        return NotificationRecorder(directory: directory)
    }

    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func post(_ request: UNNotificationRequest) async throws {
        append(["identifier": request.identifier, "category": request.content.categoryIdentifier,
                "title": request.content.title, "body": request.content.body,
                "sound": request.content.sound != nil, "active": request.content.interruptionLevel == .active],
               to: Self.requestsFile)
    }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}

    func record(_ outcome: DownloadErrorDelivery.Outcome, report: DownloadFailureReport) {
        let kind: String, message: String?
        switch outcome {
        case .message(let text): kind = "message"; message = text
        case .notification: kind = "notification"; message = nil
        case .nothing: kind = "nothing"; message = nil
        }
        var entry: [String: Any] = ["outcome": kind, "title": report.title, "retrying": report.retrying]
        if let message { entry["message"] = message }
        append(entry, to: Self.outcomesFile)
    }

    private func append(_ entry: [String: Any], to name: String) {
        let file = directory.appendingPathComponent(name)
        var entries = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        entries.append(entry)
        if let data = try? JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Reads and removes a simulated notification tap (test libraries only).
    static func takeSimulatedTap(directory: URL?) -> String? {
        guard let directory, directory.lastPathComponent.hasPrefix("UITests-") else { return nil }
        let file = directory.appendingPathComponent(responseFile)
        guard let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.removeItem(at: file)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
