import Foundation
import Synchronization

/// RFC 9110 origin boundary. A redirect/challenge does not grant its destination
/// access to credentials supplied for the original request.
enum HTTPOrigin {
    static func matches(_ first: URL, _ second: URL) -> Bool {
        guard let scheme = first.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = first.host?.lowercased(), !host.isEmpty,
              second.scheme?.lowercased() == scheme, second.host?.lowercased() == host else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        return (first.port ?? defaultPort) == (second.port ?? defaultPort)
    }
}
