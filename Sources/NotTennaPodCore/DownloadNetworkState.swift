import Foundation

public enum DownloadNetworkConstraint: String, Codable, Equatable, Sendable {
    case connected, unmetered

    public init(ignoreConstraints: Bool, allowMobile: Bool) {
        self = ignoreConstraints || allowMobile ? .connected : .unmetered
    }

    public func permits(_ network: DownloadNetworkState) -> Bool {
        network.connected && (self == .connected || !network.metered)
    }
}

public struct DownloadNetworkState: Equatable, Sendable {
    public let connected: Bool
    public let metered: Bool
    public let cellular: Bool
    public let vpnOverWiFi: Bool
    public enum Transport: Sendable { case wifi, ethernet, other }
    public let transport: Transport
    public var automaticDownloadConnection: AutomaticDownloadPolicy.Connection {
        guard connected else { return .unavailable }
        switch transport {
        case .wifi: return .wifi(metered: metered)
        case .ethernet: return .ethernet
        case .other: return .other(restricted: restricted)
        }
    }

    public init(connected: Bool, metered: Bool, cellular: Bool, vpnOverWiFi: Bool = false, transport: Transport = .other) {
        self.connected = connected
        self.metered = metered
        self.cellular = cellular
        self.vpnOverWiFi = vpnOverWiFi
        self.transport = transport
    }

    public var restricted: Bool { metered || cellular }
}
