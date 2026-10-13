import Foundation

public enum MediaDownloadFailure: Error, Codable, Equatable, Sendable {
    case http(Int)
    case malformedURL, fileType, invalidRange, tooManyFollowUps
    case connection, unknownHost, certificate, blocked, database
    case io(Int?)
    case wrongSize(expected: Int64, received: Int64)
    case notEnoughSpace(required: Int64, available: Int64)

    public var failsImmediately: Bool {
        if case .http(let status) = self { return [401, 403, 404, 410].contains(status) }
        return self == .blocked
    }

    public var restartsFile: Bool { self == .http(416) }

    public init(_ error: any Error) {
        if let failure = error as? Self { self = failure; return }
        if let error = error as? MediaDownloadError {
            switch error {
            case .malformedURL: self = .malformedURL
            case .httpStatus(let status): self = .http(status)
            case .fileType: self = .fileType
            case .invalidRange: self = .invalidRange
            case .tooManyFollowUps: self = .tooManyFollowUps
            case .notEnoughSpace(let required, let available): self = .notEnoughSpace(required: required, available: available)
            case .wrongSize(let expected, let received): self = .wrongSize(expected: expected, received: received)
            }
        } else if error is FeedLibraryError { self = .database }
        else if let error = error as? URLError {
            switch error.code {
            case .badURL, .unsupportedURL: self = .malformedURL
            case .timedOut, .cannotConnectToHost: self = .connection
            case .cannotFindHost, .dnsLookupFailed: self = .unknownHost
            case .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid: self = .certificate
            case .appTransportSecurityRequiresSecureConnection: self = .blocked
            default: self = .io(error.errorCode)
            }
        } else { self = .io((error as NSError).code) }
    }
}

public struct DownloadAttemptLog: Codable, Equatable, Sendable {
    public let date: Date
    public let attempt: Int
    public let failure: MediaDownloadFailure?
    public var title: String? = nil
    public var detail: String? = nil
}
