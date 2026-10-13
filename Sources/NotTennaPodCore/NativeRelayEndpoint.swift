import Foundation
import Network

/// Bind and advertise the same concrete interface address. The application must
/// resolve a receiver-reachable interface before creating a remote media lease.
public struct NativeRelayEndpoint: Sendable, Equatable {
    public static let loopback = NativeRelayEndpoint(address: "127.0.0.1", receiver: false)
    let address: String
    let receiver: Bool

    private init(address: String, receiver: Bool) {
        self.address = address; self.receiver = receiver
    }

    public static func receiver(address: String) throws -> Self {
        if let ipv4 = IPv4Address(address) {
            let bytes = Array(ipv4.rawValue)
            guard bytes[0] != 0, bytes[0] < 224 else { throw URLError(.badURL) }
        } else if let ipv6 = IPv6Address(address) {
            let bytes = Array(ipv6.rawValue)
            guard bytes.contains(where: { $0 != 0 }), bytes[0] != 0xff else { throw URLError(.badURL) }
        } else { throw URLError(.badURL) }
        return .init(address: address, receiver: true)
    }

    func url(port: UInt16, path: String) throws -> URL {
        let host = address.contains(":") ? "[\(address)]" : address
        guard let url = URL(string: "http://\(host):\(port)/\(path)") else { throw URLError(.badURL) }
        return url
    }
}
