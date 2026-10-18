import Foundation

public enum DownloadNetworkConstraint: String, Codable, Equatable, Sendable {
    case connected, unmetered

    public init(ignoreConstraints: Bool, allowMobile: Bool) {
        self = ignoreConstraints || allowMobile ? .connected : .unmetered
    }

    /// UNMETERED is WorkManager's NET_CAPABILITY_NOT_METERED: on iOS neither an expensive network (cellular, a
    /// hotspot) nor one in Low Data Mode, as the background session's requests refuse both.
    public func permits(_ network: DownloadNetworkState) -> Bool {
        network.connected && (self == .connected || (!network.metered && !network.constrained))
    }
}

public struct DownloadNetworkState: Equatable, Sendable {
    public let connected: Bool
    public let metered: Bool
    public let cellular: Bool
    public let vpnOverWiFi: Bool
    /// Low Data Mode (`NWPath.isConstrained`): Android's metered network for what the Mobile updates settings govern
    /// (pictures, refresh, streaming, downloads, automatic downloads). Ordinary server sync ignores it.
    public let constrained: Bool
    public enum Transport: Sendable { case wifi, ethernet, other }
    public let transport: Transport
    public var automaticDownloadConnection: AutomaticDownloadPolicy.Connection {
        guard connected else { return .unavailable }
        switch transport {
        case .wifi: return .wifi(metered: metered || constrained)
        case .ethernet: return .ethernet
        case .other: return .other(restricted: restricted)
        }
    }

    public init(connected: Bool, metered: Bool, cellular: Bool, vpnOverWiFi: Bool = false, transport: Transport = .other,
                constrained: Bool = false) {
        self.connected = connected
        self.metered = metered
        self.cellular = cellular
        self.vpnOverWiFi = vpnOverWiFi
        self.transport = transport
        self.constrained = constrained
    }

    public var restricted: Bool { metered || cellular || constrained }
}
