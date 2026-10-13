import Foundation
import CoreFoundation

public enum SynchronizationError: Error, Equatable, Sendable {
    case invalidHost, notLoggedIn, authentication, httpStatus(Int), invalidResponse, invalidAction, unsupportedOperation
}

public struct SynchronizationEpisodeAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case new, download, play, delete }
    public var podcast: String
    public var episode: String
    public var guid: String?
    public var action: Kind
    public var timestamp: Date?
    public var started: Int32
    public var position: Int32
    public var total: Int32

    public init(podcast: String, episode: String, guid: String? = nil, action: Kind,
                timestamp: Date?, started: Int32 = -1, position: Int32 = -1, total: Int32 = -1) {
        self.podcast = podcast; self.episode = episode; self.guid = guid; self.action = action
        self.timestamp = timestamp
        self.started = action == .play ? started : -1
        self.position = action == .play ? position : -1
        self.total = action == .play ? total : -1
    }

    // Network representation is separate from Codable's lossless local record.
    // Source skips actions missing mandatory fields, while optional play fields
    // are admitted together only when started >= 0, position > 0 and total > 0.
    static func read(_ object: [String: Any]) -> Self? {
        guard let podcast = object["podcast"] as? String, !podcast.isEmpty,
              let episode = object["episode"] as? String, !episode.isEmpty,
              let raw = object["action"] as? String,
              let action = Kind(rawValue: raw.lowercased(with: Locale(identifier: "en_US"))) else { return nil }
        let guid = (object["guid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let timestamp = (object["timestamp"] as? String).flatMap { dateFormatter().date(from: String($0.prefix(19))) }
        var result = Self(podcast: podcast, episode: episode, guid: guid, action: action, timestamp: timestamp)
        let started = optionalInteger(object["started"]), position = optionalInteger(object["position"]), total = optionalInteger(object["total"])
        if action == .play, started >= 0, position > 0, total > 0 {
            result.started = started; result.position = position; result.total = total
        }
        return result
    }

    func wireObject(device: String?) throws -> [String: Any] {
        guard !podcast.isEmpty, !episode.isEmpty, let timestamp, timestamp.timeIntervalSince1970.isFinite else {
            throw SynchronizationError.invalidAction
        }
        var object: [String: Any] = ["podcast": podcast, "episode": episode, "action": action.rawValue,
            "timestamp": Self.dateFormatter().string(from: timestamp)]
        if let guid { object["guid"] = guid }
        if let device { object["device"] = device }
        if action == .play {
            object["started"] = started; object["position"] = position; object["total"] = total
        }
        return object
    }

    private static func optionalInteger(_ value: Any?) -> Int32 {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.int32Value }
        if let string = value as? String, let number = Double(string), number.isFinite {
            return number >= Double(Int32.max) ? Int32.max : number <= Double(Int32.min) ? Int32.min : Int32(number)
        }
        return -1
    }
    private static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.isLenient = true
        return formatter
    }
}

public struct SynchronizationSubscriptionChanges: Equatable, Sendable {
    public var added: [String]
    public var removed: [String]
    public var timestamp: Int64
    public init(added: [String], removed: [String], timestamp: Int64) {
        self.added = added; self.removed = removed; self.timestamp = timestamp
    }
}

public struct SynchronizationEpisodeChanges: Equatable, Sendable {
    public var actions: [SynchronizationEpisodeAction]
    public var timestamp: Int64
    public init(actions: [SynchronizationEpisodeAction], timestamp: Int64) {
        self.actions = actions; self.timestamp = timestamp
    }
}

public struct SynchronizationUploadResult: Equatable, Sendable {
    public var timestamp: Int64
    public var updatedURLs: [String: String] = [:]
    public init(timestamp: Int64, updatedURLs: [String: String] = [:]) {
        self.timestamp = timestamp; self.updatedURLs = updatedURLs
    }
}

public struct SynchronizationDevice: Codable, Equatable, Sendable {
    public var id: String
    public var caption: String
    public var type: String
    public var subscriptions: Int
    public init(id: String, caption: String, type: String, subscriptions: Int) {
        self.id = id; self.caption = caption; self.type = type; self.subscriptions = subscriptions
    }
}

public protocol SynchronizationProvider: Sendable {
    func login() async throws
    func subscriptionChanges(since: Int64) async throws -> SynchronizationSubscriptionChanges
    func uploadSubscriptions(added: [String], removed: [String]) async throws -> SynchronizationUploadResult
    func episodeChanges(since: Int64) async throws -> SynchronizationEpisodeChanges
    func uploadEpisodeActions(_ actions: [SynchronizationEpisodeAction]) async throws -> SynchronizationUploadResult?
    func logout() async throws
}

public struct SynchronizationRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public var notBefore: Date
    public let network: DownloadNetworkConstraint
    public var attempts: Int
    /// Source announces scheduling only when no service is active at admission.
    /// Optional so older saved requests decode without inventing a new event.
    public let announcesStart: Bool?
    public init(notBefore: Date, allowMobile: Bool, announcesStart: Bool = true) {
        id = UUID(); self.notBefore = notBefore; network = allowMobile ? .connected : .unmetered; attempts = 0
        self.announcesStart = announcesStart
    }
}

public struct SynchronizationState: Codable, Equatable, Sendable {
    public init() {}
    /// Opaque identity binds cursors/outbox to the separately held account credentials.
    public var accountID: UUID?
    public var account: SynchronizationAccount?
    public var lastHost: String?
    public var credentialCleanup: [UUID]?
    public var epoch = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    public var subscriptionTimestamp: Int64 = 0
    public var episodeTimestamp: Int64 = 0
    public var lastAttempt: Date?
    public var lastAttemptSuccessful = false
    public var allowMobile = false
    public var request: SynchronizationRequest?
}

public struct SynchronizationQueuedChange: Codable, Equatable, Sendable {
    public enum Value: Codable, Equatable, Sendable {
        case added(String), removed(String), episode(SynchronizationEpisodeAction)
        var phase: SynchronizationPhase {
            if case .episode = self { .episodes } else { .subscriptions }
        }
    }
    public let id: Int64
    public let value: Value
}

public enum SynchronizationPhase: String, Sendable { case subscriptions, episodes }

public enum SynchronizationActionPolicy {
    private struct Key: Hashable {
        let podcast, episode: [UInt16]
        init(_ action: SynchronizationEpisodeAction) {
            podcast = Array(action.podcast.utf16); episode = Array(action.episode.utf16)
        }
    }
    /// Source considers all local kinds, but only remote PLAY affects the library.
    /// Equal remote timestamps overwrite earlier remote entries and local ties.
    public static func remoteOverridingLocal(_ remote: [SynchronizationEpisodeAction],
                                            local: [SynchronizationEpisodeAction]) -> [SynchronizationEpisodeAction] {
        var latest: [Key: SynchronizationEpisodeAction] = [:]
        for action in local {
            let key = Key(action)
            if let previous = latest[key]?.timestamp {
                // Original Date.before(null) crashes for an undated later entry.
                // Retain the known newest date instead of losing the whole sync.
                if let date = action.timestamp, date > previous { latest[key] = action }
            } else { latest[key] = action }
        }
        func overrides(_ first: SynchronizationEpisodeAction, _ second: SynchronizationEpisodeAction?) -> Bool {
            guard let date = second?.timestamp else { return false }
            return first.timestamp.map { date > $0 } ?? true
        }
        var selected: [Key: SynchronizationEpisodeAction] = [:], order: [Key] = []
        for action in remote where action.action == .play {
            let key = Key(action)
            guard !overrides(action, latest[key]), !overrides(action, selected[key]) else { continue }
            if selected[key] == nil { order.append(key) }
            selected[key] = action
        }
        return order.compactMap { selected[$0] }
    }

    public static func validGUID(_ value: String?) -> String? {
        guard let value, !JavaString.trim(value).isEmpty, value != "null" else { return nil }
        return value
    }
}
