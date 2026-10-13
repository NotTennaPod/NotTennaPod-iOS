import Foundation
import Network

/// Application proxy choice. DIRECT retains system proxy selection, as the
/// source leaves OkHttp's default ProxySelector installed in this mode.
public struct PodcastProxy: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case direct = "DIRECT", http = "HTTP", socks = "SOCKS" }
    public var kind: Kind
    public var host: String?
    public var port: Int
    public var username: String?
    public var password: String?

    public init(kind: Kind = .direct, host: String? = nil, port: Int = 0,
                username: String? = nil, password: String? = nil) {
        self.kind = kind; self.host = host; self.port = port
        self.username = username; self.password = password
    }
    public var effectivePort: Int { port > 0 ? port : 8080 }
    public var isConfigured: Bool { kind != .direct && host?.isEmpty == false }

    /// Native HTTP forward-proxy configuration is intentional: Network's
    /// httpCONNECTProxy tunnels plain HTTP too, which does not match OkHttp.
    /// SOCKSv5 uses Network's supported native configuration.
    public func apply(to configuration: URLSessionConfiguration, scheme: String = "http") throws {
        guard isConfigured, let host else { return }
        guard let port = UInt16(exactly: effectivePort), port > 0 else { throw URLError(.badURL) }
        switch kind {
        case .direct: break
        case .http:
            if scheme.lowercased() == "https" {
                var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .init(host), port: .init(rawValue: port)!))
                proxy.allowFailover = false
                if let username, !username.isEmpty, let password { proxy.applyCredential(username: username, password: password) }
                configuration.proxyConfigurations = [proxy]
            } else {
                configuration.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": Int(port),
                    "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": Int(port)]
            }
        case .socks:
            var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: .init(host), port: .init(rawValue: port)!))
            proxy.allowFailover = false
            if let username, !username.isEmpty, let password { proxy.applyCredential(username: username, password: password) }
            configuration.proxyConfigurations = [proxy]
        }
    }

    /// Proxy secrets are never attached to URLRequest headers or offered to an
    /// origin challenge. A failed attempt cannot recurse indefinitely on 407.
    func credential(for challenge: URLAuthenticationChallenge) -> URLCredential? {
        let space = challenge.protectionSpace
        guard kind == .http, isConfigured, space.isProxy(),
              space.host.caseInsensitiveCompare(host ?? "") == .orderedSame,
              space.port == effectivePort,
              space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic,
              challenge.previousFailureCount == 0,
              let username, !username.isEmpty, let password else { return nil }
        return URLCredential(user: username, password: password, persistence: .none)
    }
}
