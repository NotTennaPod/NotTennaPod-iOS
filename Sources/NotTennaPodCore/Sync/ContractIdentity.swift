import CryptoKit
import Foundation

/// Identity primitives of the wire contract (PROTOCOL §3.2, §15.2): UUIDs, the `L()` field encoding,
/// podcast, generation and episode IDs, and GUID trimming.
public enum ContractIdentity {
    /// The episode identity kinds `K` of PROTOCOL §3.3.
    public enum EpisodeKind: String, CaseIterable, Sendable {
        case rssGUID = "rss-guid"
        case atomID = "atom-id"
        case rssGUIDEnclosure = "rss-guid+enclosure"
        case enclosure
    }

    /// A lowercase hyphenated 36-character UUID; uppercase, braces and other forms are rejected.
    public static func isUUID(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                guard byte == UInt8(ascii: "-") else { return false }
            } else if ContractHex.digit(byte, uppercase: false) == nil {
                return false
            }
        }
        return true
    }

    /// A random UUID in the contract's form.
    public static func randomUUID() -> String { UUID().uuidString.lowercased() }

    public static func isPodcastID(_ text: String) -> Bool { hasHashForm(text, prefix: "p1:") }
    public static func isGenerationID(_ text: String) -> Bool { hasHashForm(text, prefix: "g1:") }

    /// `e1:` and 64 lowercase hex characters, or `e0:` and a UUID (an item without GUID and enclosure).
    public static func isEpisodeID(_ text: String) -> Bool {
        if hasHashForm(text, prefix: "e1:") { return true }
        return text.hasPrefix("e0:") && isUUID(String(text.dropFirst(3)))
    }

    private static func hasHashForm(_ text: String, prefix: String) -> Bool {
        text.hasPrefix(prefix) && ContractHex.isLowercase(String(text.dropFirst(prefix.count)), count: 64)
    }

    /// `L(f1, …, fk)`: each field's UTF-8 bytes preceded by their length as a 4-byte big-endian integer.
    /// Unicode is never normalized.
    public static func lengthPrefixed(_ fields: [String]) -> [UInt8] {
        var output: [UInt8] = []
        for field in fields {
            let bytes = Array(field.utf8)
            precondition(bytes.count <= Int(UInt32.max), "an identity field longer than 2^32−1 bytes")
            let length = UInt32(bytes.count)
            output.append(contentsOf: [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
            output.append(contentsOf: bytes)
        }
        return output
    }

    /// `P = "p1:" + hex(SHA-256(L("podcast-v1", A, creating_op_id)))`.
    public static func podcastID(namespace: String, creatingOpID: String) throws -> String {
        try requireUUID(namespace, "namespace")
        try requireUUID(creatingOpID, "op_id")
        return "p1:" + sha256Hex(lengthPrefixed(["podcast-v1", namespace, creatingOpID]))
    }

    /// `G = "g1:" + hex(SHA-256(L("generation-v1", A, P, creating_op_id)))`.
    public static func generationID(namespace: String, podcastID: String, creatingOpID: String) throws -> String {
        try requireUUID(namespace, "namespace")
        guard isPodcastID(podcastID) else { throw ContractError(.invalidID, "not a podcast ID: \(podcastID)") }
        try requireUUID(creatingOpID, "op_id")
        return "g1:" + sha256Hex(lengthPrefixed(["generation-v1", namespace, podcastID, creatingOpID]))
    }

    /// `E = "e1:" + hex(SHA-256(L("episode-v1", A, P, K, V)))`, with `V` taken as given.
    public static func episodeID(namespace: String, podcastID: String, kind: EpisodeKind, value: String) throws -> String {
        try requireUUID(namespace, "namespace")
        guard isPodcastID(podcastID) else { throw ContractError(.invalidID, "not a podcast ID: \(podcastID)") }
        return "e1:" + sha256Hex(lengthPrefixed(["episode-v1", namespace, podcastID, kind.rawValue, value]))
    }

    /// The same, for a kind given as its wire name; an unknown kind is rejected.
    public static func episodeID(namespace: String, podcastID: String, kind: String, value: String) throws -> String {
        guard let known = EpisodeKind(rawValue: kind) else { throw ContractError(.invalidKind, "unknown episode identity kind \(kind)") }
        return try episodeID(namespace: namespace, podcastID: podcastID, kind: known, value: value)
    }

    /// `V` for `rss-guid+enclosure`: the GUID, U+001F, the normalized enclosure URL.
    public static func guidEnclosureValue(guid: String, normalizedEnclosure: String) -> String {
        guid + "\u{1F}" + normalizedEnclosure
    }

    /// AntennaPod's `GuidValidator` after Java's `String.trim()`: code points up to U+0020 are removed at
    /// both ends; the GUID is absent when the result is empty or exactly `null`.
    public static func trimmedGUID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = JavaString.trim(raw)
        return trimmed.isEmpty || trimmed == "null" ? nil : trimmed
    }

    static func requireUUID(_ text: String, _ name: String) throws {
        guard isUUID(text) else { throw ContractError(.invalidUUID, "\(name) is not a lowercase hyphenated UUID: \(text)") }
    }

    static func sha256Hex(_ bytes: [UInt8]) -> String { ContractHex.encode(SHA256.hash(data: bytes)) }
}
