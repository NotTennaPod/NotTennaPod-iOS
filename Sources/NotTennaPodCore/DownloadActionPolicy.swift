import Foundation

public struct DownloadActionPolicy: Equatable, Sendable {
    public enum Choice: Int, Equatable, Sendable { case none, now, later }
    public enum Decision: Equatable, Sendable {
        case ignored
        case request(ignoreConstraints: Bool, showMobileNotice: Bool)
        case confirmation(showVPNAdvice: Bool)
    }

    public private(set) var bypassChoice: Choice = .none
    public private(set) var bypassTimeSeconds: Int64 = 0

    public init() {}

    public func decision(hasMedia: Bool, downloaded: Bool, downloading: Bool, allowMobile: Bool,
                         restrictedNetwork: Bool, vpnOverWiFi: Bool, nowMilliseconds: Int64) -> Decision {
        guard hasMedia, !downloaded, !downloading else { return .ignored }
        let elapsed = (nowMilliseconds / 1000) &- bypassTimeSeconds
        let bypass = elapsed < 300
        if allowMobile || !restrictedNetwork || bypass {
            return .request(ignoreConstraints: bypassChoice == .now, showMobileNotice: bypass && bypassChoice == .now)
        }
        return .confirmation(showVPNAdvice: restrictedNetwork && vpnOverWiFi)
    }

    public mutating func confirm(_ choice: Choice, nowMilliseconds: Int64) -> Decision {
        guard choice != .none else { return .ignored }
        bypassChoice = choice
        bypassTimeSeconds = nowMilliseconds / 1000
        return .request(ignoreConstraints: choice == .now, showMobileNotice: false)
    }
}
