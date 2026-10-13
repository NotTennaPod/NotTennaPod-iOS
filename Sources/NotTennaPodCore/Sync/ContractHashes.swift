import CryptoKit
import Foundation

/// Hashes, MACs and the digest chain of the wire contract (PROTOCOL §6.1).
public enum ContractHash {
    /// `d(0)`: 32 zero bytes.
    public static let zeroDigest = [UInt8](repeating: 0, count: 32)

    /// The fact content hash, `hex(SHA-256(UTF-8(JCS(fact))))`, over the object as received. It does not
    /// validate the fact.
    public static func contentHash(_ fact: ContractJSON) throws -> String {
        ContractIdentity.sha256Hex(try fact.canonicalBytes())
    }

    /// One link of the digest chain, used for commits and snapshot items alike:
    /// `d = SHA-256(previous ‖ UTF-8(JCS(object)))`.
    public static func nextDigest(previous: [UInt8], _ object: ContractJSON) throws -> [UInt8] {
        guard previous.count == 32 else { throw ContractError(.invalidValue, "the previous digest must be 32 bytes") }
        var hash = SHA256()
        hash.update(data: previous)
        hash.update(data: try object.canonicalBytes())
        return Array(hash.finalize())
    }

    /// The digest after a run of objects, starting from `start`.
    public static func chainDigest(_ objects: [ContractJSON], start: [UInt8] = zeroDigest) throws -> [UInt8] {
        try objects.reduce(start) { try nextDigest(previous: $0, $1) }
    }
}

/// Strict base64url (RFC 4648 §5) without padding, as cursors, parts and page tokens use it.
public enum ContractBase64URL {
    public static func encode(_ bytes: some Sequence<UInt8>) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Rejects padding, characters outside the alphabet, an impossible length and non-zero unused trailing bits.
    public static func decode(_ text: String) throws -> [UInt8] {
        let characters = Array(text.utf8)
        guard characters.allSatisfy({ isAlphabet($0) }) else {
            throw ContractError(.invalidBase64, "not unpadded base64url")
        }
        guard characters.count % 4 != 1 else { throw ContractError(.invalidBase64, "impossible base64 length") }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - characters.count % 4) % 4)
        guard let data = Data(base64Encoded: standard) else { throw ContractError(.invalidBase64, "not base64url") }
        let bytes = [UInt8](data)
        guard encode(bytes) == text else { throw ContractError(.invalidBase64, "non-canonical base64url (trailing bits)") }
        return bytes
    }

    private static func isAlphabet(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "_"): true
        default: false
        }
    }
}

/// A change-log cursor (PROTOCOL §6.1): base64url of `UTF-8(JCS({log_id, epoch, seq, digest}))`. Clients
/// treat it as opaque for equality, but decode it to name the cursor of each verified commit.
public struct SyncCursor: Equatable, Hashable, Sendable {
    public let logID: String
    public let epoch: Int64
    public let seq: Int64
    /// The commit digest at `seq`, 64 lowercase hex characters.
    public let digest: String

    public init(logID: String, epoch: Int64, seq: Int64, digest: String) throws {
        guard ContractIdentity.isUUID(logID) else { throw ContractError(.invalidCursor, "log_id is not a UUID") }
        for (name, value) in [("epoch", epoch), ("seq", seq)] where value < 0 || value > ContractJSON.maximumSafeInteger {
            throw ContractError(.invalidCursor, "\(name) is not a non-negative integer")
        }
        guard ContractHex.isLowercase(digest, count: 64) else {
            throw ContractError(.invalidCursor, "digest is not 64 lowercase hex characters")
        }
        self.logID = logID
        self.epoch = epoch
        self.seq = seq
        self.digest = digest
    }

    /// Decodes the wire form; anything but the exact canonical bytes of these four members is rejected.
    public init(encoded: String) throws {
        let raw: [UInt8]
        let value: ContractJSON
        do {
            raw = try ContractBase64URL.decode(encoded)
            value = try ContractJSON.decode(raw)
        } catch let error as ContractError {
            throw ContractError(.invalidCursor, error.message)
        }
        guard let object = value.objectValue, object.names.sorted() == ["digest", "epoch", "log_id", "seq"],
              let logID = object["log_id"]?.stringValue, let epoch = object["epoch"]?.integerValue,
              let seq = object["seq"]?.integerValue, let digest = object["digest"]?.stringValue else {
            throw ContractError(.invalidCursor, "a cursor is exactly {log_id, epoch, seq, digest}")
        }
        try self.init(logID: logID, epoch: epoch, seq: seq, digest: digest)
        guard try json.canonicalBytes() == raw else { throw ContractError(.invalidCursor, "cursor JSON is not canonical") }
    }

    public var json: ContractJSON {
        ["log_id": .string(logID), "epoch": .integer(epoch), "seq": .integer(seq), "digest": .string(digest)]
    }

    public var encoded: String {
        // The members are validated, so the canonical form always exists.
        ContractBase64URL.encode((try? json.canonicalBytes()) ?? [])
    }
}

/// Framing of a fact larger than the operation bound (PROTOCOL §6.4): base64url slices of its canonical
/// bytes, in index order.
public enum FactParts {
    /// The canonical bytes of `fact` in non-empty slices of at most `maximumBytes` bytes, as base64url.
    public static func split(_ fact: ContractJSON, maximumBytes: Int) throws -> [String] {
        precondition(maximumBytes > 0, "a part holds at least one byte")
        let bytes = try fact.canonicalBytes()
        return stride(from: 0, to: bytes.count, by: maximumBytes).map {
            ContractBase64URL.encode(bytes[$0..<min(bytes.count, $0 + maximumBytes)])
        }
    }

    /// Reassembles parts: each a non-empty base64url slice, together exactly the canonical JSON of an object
    /// whose content hash is `contentHash`. Validating the fact itself is a separate step.
    public static func reassemble(_ parts: [String], contentHash: String) throws -> ContractObject {
        guard ContractHex.isLowercase(contentHash, count: 64) else {
            throw ContractError(.invalidPart, "content_hash is not 64 lowercase hex characters")
        }
        guard !parts.isEmpty else { throw ContractError(.invalidPart, "no parts") }
        var bytes: [UInt8] = []
        let value: ContractJSON
        do {
            for part in parts {
                let slice = try ContractBase64URL.decode(part)
                guard !slice.isEmpty else { throw ContractError(.invalidPart, "an empty part") }
                bytes.append(contentsOf: slice)
            }
            value = try ContractJSON.decode(bytes)
        } catch let error as ContractError {
            throw ContractError(.invalidPart, error.message)
        }
        guard let object = value.objectValue else { throw ContractError(.invalidPart, "the reassembled JSON is not an object") }
        guard try value.canonicalBytes() == bytes else { throw ContractError(.invalidPart, "the reassembled bytes are not canonical JSON") }
        guard ContractIdentity.sha256Hex(bytes) == contentHash else { throw ContractError(.invalidPart, "content hash mismatch") }
        return object
    }
}
