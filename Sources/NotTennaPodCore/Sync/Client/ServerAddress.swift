import Foundation

/// A NotTennaPod server's address as the person enters it on the Synchronization page (PROTOCOL §15.4). The same rules
/// as the gpodder.net address: HTTPS unless the address names `http://` (or port 80 without a scheme), no credentials,
/// query or fragment. The normalized form is what the library registry stores as `server_url`, so a kept library is
/// found again whatever the person types.
public struct ServerAddress: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// `scheme://host[:port][/path]`, lowercase scheme and host, no default port and no trailing slash.
    public let string: String
    public let isPlainHTTP: Bool
    /// The host as shown to the person, without brackets around an IPv6 address.
    public let host: String

    public init?(entered: String) {
        let text = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let explicitScheme = text.contains("://")
        guard var components = URLComponents(string: explicitScheme ? text : "https://" + text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true,
              components.rangeOfPort == nil || components.port != nil else { return nil }
        components.scheme = scheme
        if !explicitScheme, components.port == 80 { components.scheme = "http" }
        if let encoded = components.percentEncodedHost { components.percentEncodedHost = encoded.lowercased() }
        if (components.scheme == "https" && components.port == 443) || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path
        guard let value = components.string, URL(string: value) != nil else { return nil }
        string = value
        isPlainHTTP = components.scheme == "http"
        self.host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    /// A stored `server_url` (already normalized).
    public init?(stored: String) { self.init(entered: stored) }

    public var description: String { string }

    /// The URL of an API path such as `v1/info`.
    public func endpoint(_ path: String) -> URL { URL(string: string + "/" + path)! }

    /// A Tailscale address: its IPv4 range 100.64.0.0/10, its IPv6 range fd7a:115c:a1e0::/48, or a MagicDNS name
    /// under `.ts.net`. Tailscale encrypts the connection itself, so plain HTTP there carries no warning.
    public var isTailscale: Bool {
        if host.hasSuffix(".ts.net") { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let value = UInt32(bigEndian: v4.s_addr)
            return value & 0xFFC0_0000 == 0x6440_0000
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            return Array(bytes.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
        }
        return false
    }

    /// Android's "Password and data are not encrypted!" warning: plain HTTP outside Tailscale.
    public var showsEncryptionWarning: Bool { isPlainHTTP && !isTailscale }
}
