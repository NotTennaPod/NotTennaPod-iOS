import CryptoKit
import Foundation

struct NativeRelayResource: Codable, Equatable, Sendable {
    let url: URL
    let playlist: Bool
    let variables: [String: String]
}

/// Stateless, playback-scoped routes. Live playlist history does not accumulate in
/// memory and old native requests remain valid after a playlist window advances.
/// The MAC authenticates the payload; it does not encrypt the original media URL.
struct NativeRelayRoute: Sendable {
    private let key = SymmetricKey(size: .bits256)

    func encode(_ resource: NativeRelayResource) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(resource)
        let signature = Data(HMAC<SHA256>.authenticationCode(for: payload, using: key))
        return base64(payload) + "." + base64(signature) + (resource.playlist ? ".m3u8" : ".media")
    }

    func decode(_ route: String) throws -> NativeRelayResource {
        let parts = route.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = data(parts[0]), let signature = data(parts[1]),
              HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: payload, using: key) else {
            throw URLError(.badURL)
        }
        let resource = try JSONDecoder().decode(NativeRelayResource.self, from: payload)
        guard parts[2] == (resource.playlist ? "m3u8" : "media") else { throw URLError(.badURL) }
        return resource
    }

    private func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func data(_ text: Substring) -> Data? {
        var value = String(text).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: value)
    }
}
