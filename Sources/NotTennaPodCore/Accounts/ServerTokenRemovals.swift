import CryptoKit
import Foundation

/// Token removals the logout cut-off could not finish (PROTOCOL §15.4), kept across launches in
/// `pending-token-removals.json`. Each names the installation's Keychain item and a SHA-256 digest of the token it
/// held, never the token itself. A retry removes the item's token only while it still holds that same token, so a
/// later login's token is never deleted or overwritten.
struct ServerTokenRemovals {
    struct Removal: Codable, Equatable, Sendable {
        var library: String
        var install: String
        /// SHA-256 of the token, lowercase hex.
        var token: String
    }

    static let fileName = "pending-token-removals.json"
    let url: URL

    init(root: URL) { url = root.appendingPathComponent(Self.fileName) }

    static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The recorded removals; none when the file is missing or damaged. A file that cannot be read now (before the first
    /// unlock) is thrown, never taken for none.
    func read() throws -> [Removal] {
        guard let data = try SavedState.contents(of: url) else { return [] }
        return (try? JSONDecoder().decode([Removal].self, from: data)) ?? []
    }

    /// Writes `removals` atomically; an empty list removes the file.
    func write(_ removals: [Removal]) throws {
        if removals.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try JSONEncoder().encode(removals).write(to: url, options: .atomic)
    }
}
