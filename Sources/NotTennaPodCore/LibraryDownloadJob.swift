import Foundation

public struct LibraryDownloadJob: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case waiting, transferring, completed, cancelled, failed

        public var isActive: Bool { self == .waiting || self == .transferring }
    }

    public let id: Int64
    /// Changes only when a server merge moves an active download to the survivor (PROTOCOL §9.7).
    public internal(set) var episodeID: Int64
    public let source: String
    public let destination: URL
    public let enqueuedByDownload: Bool
    public let createdAt: Date
    public var state: State
    public var attempts: Int
    public var updatedAt: Date
    public var retryAt: Date?
    public var fileResetRequired: Bool?
    public var logs: [DownloadAttemptLog]?
    public var representation: MediaDownloadRepresentation?
    public var networkConstraint: DownloadNetworkConstraint?
    /// Attempts that were stopped (network constraint lost, app stopped or relaunched) instead of
    /// ending in a result. `attempts` stays the fencing identity; only the other attempts count toward
    /// the three-attempt budget and the 30 s / 60 s retry delays. Android lets every stop consume an
    /// attempt, so two Wi-Fi losses and one transient error delete the partial file; not copied.
    public var interruptions: Int?

    /// Attempts that ended in a result (failure, 416 or success).
    public var countedAttempts: Int { attempts - (interruptions ?? 0) }
}
