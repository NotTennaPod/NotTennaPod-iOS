import Foundation

/// Input the wire contract (contract-v1) rejects. `code` names the reason, as the Python reference does.
public struct ContractError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Code: String, Sendable {
        case invalidJSON = "invalid_json"
        case invalidValue = "invalid_value"
        case invalidUUID = "invalid_uuid"
        case invalidID = "invalid_id"
        case invalidKind = "invalid_kind"
        case invalidQueueKey = "invalid_queue_key"
        case invalidRange = "invalid_range"
        case keyTooLong = "key_too_long"
        case invalidNode = "invalid_node"
        case duplicate
        case dependencyMissing = "dependency_missing"
        case cycle
        case invalidBase64 = "invalid_base64"
        case invalidCursor = "invalid_cursor"
        case invalidPart = "invalid_part"
    }

    public var code: Code
    public var message: String
    /// The missing node IDs of a `dependency_missing` error, sorted bytewise.
    public var missing: [String]

    public init(_ code: Code, _ message: String, missing: [String] = []) {
        self.code = code
        self.message = message
        self.missing = missing
    }

    public var description: String { "\(code.rawValue): \(message)" }
}

/// A protocol JSON value (PROTOCOL §3.1). Numbers are integers within ±(2^53−1); there are no floats.
/// Strings compare by their exact code points, never by Unicode canonical equivalence.
public indirect enum ContractJSON: Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case string(String)
    case array([ContractJSON])
    case object(ContractObject)

    public static let maximumSafeInteger: Int64 = 9_007_199_254_740_991
    /// Nesting limit of decoded JSON: the outermost array or object is level 1.
    public static let maximumDepth = 64

    public var isNull: Bool { if case .null = self { true } else { false } }
    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var integerValue: Int64? { if case .integer(let value) = self { value } else { nil } }
    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var arrayValue: [ContractJSON]? { if case .array(let value) = self { value } else { nil } }
    public var objectValue: ContractObject? { if case .object(let value) = self { value } else { nil } }

    /// The member `name` of an object; nil for a missing member or a value that is not an object.
    public subscript(name: String) -> ContractJSON? { objectValue?[name] }
}

extension ContractJSON: Equatable {
    public static func == (lhs: ContractJSON, rhs: ContractJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case (.bool(let a), .bool(let b)): a == b
        case (.integer(let a), .integer(let b)): a == b
        case (.string(let a), .string(let b)): a.utf8.elementsEqual(b.utf8)
        case (.array(let a), .array(let b)): a.count == b.count && zip(a, b).allSatisfy { $0 == $1 }
        case (.object(let a), .object(let b)): a == b
        default: false
        }
    }
}

/// Literals for building values; JSON null is written `.null`, so `nil` keeps meaning an absent member.
extension ContractJSON: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: ContractJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, ContractJSON)...) {
        self = .object(ContractObject(literal: elements))
    }
}

/// A JSON object whose members are kept in JCS order (UTF-16 code units of the names) with unique names.
public struct ContractObject: Sendable, Equatable {
    public struct Member: Sendable, Equatable {
        public let name: String
        public var value: ContractJSON

        public static func == (lhs: Member, rhs: Member) -> Bool {
            lhs.name.utf8.elementsEqual(rhs.name.utf8) && lhs.value == rhs.value
        }
    }

    public private(set) var members: [Member] = []

    public init() {}

    /// Rejects two members with the same name.
    public init(members: some Sequence<(String, ContractJSON)>) throws {
        var list = members.map { Member(name: $0.0, value: $0.1) }
        list.sort { Self.precedes($0.name, $1.name) }
        for index in list.indices.dropFirst() where Self.same(list[index - 1].name, list[index].name) {
            throw ContractError(.invalidJSON, "duplicate member name \"\(list[index].name)\"")
        }
        self.members = list
    }

    init(literal elements: [(String, ContractJSON)]) {
        do { try self.init(members: elements) } catch { preconditionFailure("duplicate member in an object literal") }
    }

    public var count: Int { members.count }
    public var isEmpty: Bool { members.isEmpty }
    public var names: [String] { members.map(\.name) }

    public subscript(name: String) -> ContractJSON? {
        get {
            let index = insertionIndex(of: name)
            return index < members.count && Self.same(members[index].name, name) ? members[index].value : nil
        }
        set {
            let index = insertionIndex(of: name)
            let present = index < members.count && Self.same(members[index].name, name)
            switch (present, newValue) {
            case (true, .some(let value)): members[index].value = value
            case (true, nil): members.remove(at: index)
            case (false, .some(let value)): members.insert(Member(name: name, value: value), at: index)
            case (false, nil): break
            }
        }
    }

    public func contains(_ name: String) -> Bool { self[name] != nil }

    private func insertionIndex(of name: String) -> Int {
        var low = 0
        var high = members.count
        while low < high {
            let middle = (low + high) / 2
            if Self.precedes(members[middle].name, name) { low = middle + 1 } else { high = middle }
        }
        return low
    }

    static func precedes(_ lhs: String, _ rhs: String) -> Bool { lhs.utf16.lexicographicallyPrecedes(rhs.utf16) }
    static func same(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
}

extension ContractObject: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, ContractJSON)...) { self.init(literal: elements) }
}

// MARK: - Strict decoding (PROTOCOL §3.1)

extension ContractJSON {
    /// Decodes protocol JSON strictly: valid UTF-8 without a byte-order mark, integers only (no fraction,
    /// exponent, `-0` or leading zeros) within ±(2^53−1), no duplicate member names, no lone surrogate
    /// escapes, no unescaped control characters, no trailing data, at most 64 levels of nesting.
    public static func decode(_ data: some Sequence<UInt8>) throws -> ContractJSON {
        let bytes = Array(data)
        SQLWorkMeter.shared.noteDecoded(bytes: bytes.count)
        guard ContractUTF8.isValid(bytes) else { throw ContractError(.invalidJSON, "invalid UTF-8") }
        return try bytes.withUnsafeBufferPointer { buffer in
            var parser = StrictJSONParser(bytes: buffer)
            parser.skipWhitespace()
            let value = try parser.value(depth: 0)
            parser.skipWhitespace()
            guard parser.index == buffer.count else {
                throw ContractError(.invalidJSON, "trailing data at offset \(parser.index)")
            }
            return value
        }
    }

    /// Decodes text, which is always valid Unicode, as its UTF-8 bytes.
    public static func decode(_ text: String) throws -> ContractJSON { try decode(Array(text.utf8)) }
}

private struct StrictJSONParser {
    let bytes: UnsafeBufferPointer<UInt8>
    var index = 0

    init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

    private func failure(_ message: String) -> ContractError { ContractError(.invalidJSON, message) }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private func starts(with literal: StaticString) -> Bool {
        let count = literal.utf8CodeUnitCount
        guard index + count <= bytes.count else { return false }
        return literal.withUTF8Buffer { expected in
            (0..<count).allSatisfy { bytes[index + $0] == expected[$0] }
        }
    }

    mutating func value(depth: Int) throws -> ContractJSON {
        guard index < bytes.count else { throw failure("unexpected end of input") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try object(depth: depth + 1)
        case UInt8(ascii: "["): return try array(depth: depth + 1)
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t") where starts(with: "true"): index += 4; return .bool(true)
        case UInt8(ascii: "f") where starts(with: "false"): index += 5; return .bool(false)
        case UInt8(ascii: "n") where starts(with: "null"): index += 4; return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .integer(try integer())
        default: throw failure("unexpected character at offset \(index)")
        }
    }

    private mutating func object(depth: Int) throws -> ContractJSON {
        guard depth <= ContractJSON.maximumDepth else { throw failure("nesting deeper than \(ContractJSON.maximumDepth) levels") }
        index += 1
        var members: [(String, ContractJSON)] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(ContractObject())
        }
        while true {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw failure("expected a member name at offset \(index)") }
            let name = try string()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw failure("expected ':' at offset \(index)") }
            index += 1
            skipWhitespace()
            members.append((name, try value(depth: depth)))
            skipWhitespace()
            guard index < bytes.count else { throw failure("unterminated object") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                skipWhitespace()
                continue
            }
            guard bytes[index] == UInt8(ascii: "}") else { throw failure("expected ',' or '}' at offset \(index)") }
            index += 1
            return .object(try ContractObject(members: members))
        }
    }

    private mutating func array(depth: Int) throws -> ContractJSON {
        guard depth <= ContractJSON.maximumDepth else { throw failure("nesting deeper than \(ContractJSON.maximumDepth) levels") }
        index += 1
        var elements: [ContractJSON] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(elements)
        }
        while true {
            elements.append(try value(depth: depth))
            skipWhitespace()
            guard index < bytes.count else { throw failure("unterminated array") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                skipWhitespace()
                continue
            }
            guard bytes[index] == UInt8(ascii: "]") else { throw failure("expected ',' or ']' at offset \(index)") }
            index += 1
            return .array(elements)
        }
    }

    /// The string starting at the opening quote. The bytes are valid UTF-8, so every byte of a
    /// multi-byte sequence is at least 0x80 and never mistaken for a quote, backslash or control.
    private mutating func string() throws -> String {
        index += 1
        var output: [UInt8] = []
        var runStart = index
        while true {
            guard index < bytes.count else { throw failure("unterminated string") }
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                if output.isEmpty {
                    let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[runStart..<index]), as: UTF8.self)
                    index += 1
                    return text
                }
                output.append(contentsOf: bytes[runStart..<index])
                index += 1
                return String(decoding: output, as: UTF8.self)
            }
            if byte < 0x20 { throw failure("unescaped control character in a string at offset \(index)") }
            guard byte == UInt8(ascii: "\\") else { index += 1; continue }
            output.append(contentsOf: bytes[runStart..<index])
            guard index + 1 < bytes.count else { throw failure("unterminated escape") }
            let escape = bytes[index + 1]
            index += 2
            switch escape {
            case UInt8(ascii: "\""): output.append(0x22)
            case UInt8(ascii: "\\"): output.append(0x5C)
            case UInt8(ascii: "/"): output.append(0x2F)
            case UInt8(ascii: "b"): output.append(0x08)
            case UInt8(ascii: "f"): output.append(0x0C)
            case UInt8(ascii: "n"): output.append(0x0A)
            case UInt8(ascii: "r"): output.append(0x0D)
            case UInt8(ascii: "t"): output.append(0x09)
            case UInt8(ascii: "u"):
                guard let unit = hex4(at: index) else { throw failure("invalid \\u escape") }
                index += 4
                var scalar: UInt32 = unit
                if (0xD800...0xDBFF).contains(unit) {
                    guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u"),
                          let low = hex4(at: index + 2), (0xDC00...0xDFFF).contains(low) else {
                        throw failure("lone surrogate escape")
                    }
                    index += 6
                    scalar = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                } else if (0xDC00...0xDFFF).contains(unit) {
                    throw failure("lone surrogate escape")
                }
                output.append(contentsOf: UTF8.encode(Unicode.Scalar(scalar)!)!)
            default: throw failure("invalid escape at offset \(index - 1)")
            }
            runStart = index
        }
    }

    private func hex4(at position: Int) -> UInt32? {
        guard position + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for offset in 0..<4 {
            guard let digit = ContractHex.digit(bytes[position + offset], uppercase: true) else { return nil }
            value = value << 4 | UInt32(digit)
        }
        return value
    }

    private mutating func integer() throws -> Int64 {
        let start = index
        let negative = bytes[index] == UInt8(ascii: "-")
        if negative { index += 1 }
        let digitsStart = index
        guard index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) else {
            throw failure("invalid number at offset \(start)")
        }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else {
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count, [UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E")].contains(bytes[index]) {
            throw failure("not an integer at offset \(start)")
        }
        let count = index - digitsStart
        if negative, count == 1, bytes[digitsStart] == UInt8(ascii: "0") { throw failure("-0") }
        guard count <= 16 else { throw failure("integer outside ±(2^53−1)") }
        var magnitude: Int64 = 0
        for position in digitsStart..<index { magnitude = magnitude * 10 + Int64(bytes[position] - UInt8(ascii: "0")) }
        guard magnitude <= ContractJSON.maximumSafeInteger else { throw failure("integer outside ±(2^53−1)") }
        return negative ? -magnitude : magnitude
    }
}

// MARK: - Canonical serialization (RFC 8785, integer values only)

extension ContractJSON {
    /// `UTF-8(JCS(value))`: members sorted by the UTF-16 code units of their names, no whitespace,
    /// minimal string escapes, integers in plain decimal. An integer outside ±(2^53−1) is rejected.
    public func canonicalBytes() throws -> [UInt8] {
        var output: [UInt8] = []
        try appendCanonical(to: &output)
        return output
    }

    public func canonicalData() throws -> Data { Data(try canonicalBytes()) }

    public func canonicalString() throws -> String { String(decoding: try canonicalBytes(), as: UTF8.self) }

    private func appendCanonical(to output: inout [UInt8]) throws {
        switch self {
        case .null: output.append(contentsOf: "null".utf8)
        case .bool(let value): output.append(contentsOf: (value ? "true" : "false").utf8)
        case .integer(let value):
            guard value >= -Self.maximumSafeInteger, value <= Self.maximumSafeInteger else {
                throw ContractError(.invalidValue, "integer outside ±(2^53−1)")
            }
            output.append(contentsOf: String(value).utf8)
        case .string(let value): Self.appendCanonical(string: value, to: &output)
        case .array(let elements):
            output.append(UInt8(ascii: "["))
            for (position, element) in elements.enumerated() {
                if position > 0 { output.append(UInt8(ascii: ",")) }
                try element.appendCanonical(to: &output)
            }
            output.append(UInt8(ascii: "]"))
        case .object(let object):
            output.append(UInt8(ascii: "{"))
            for (position, member) in object.members.enumerated() {
                if position > 0 { output.append(UInt8(ascii: ",")) }
                Self.appendCanonical(string: member.name, to: &output)
                output.append(UInt8(ascii: ":"))
                try member.value.appendCanonical(to: &output)
            }
            output.append(UInt8(ascii: "}"))
        }
    }

    private static func appendCanonical(string: String, to output: inout [UInt8]) {
        output.append(UInt8(ascii: "\""))
        for byte in string.utf8 {
            switch byte {
            case 0x22: output.append(contentsOf: [0x5C, 0x22])
            case 0x5C: output.append(contentsOf: [0x5C, 0x5C])
            case 0x08: output.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 0x0C: output.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 0x0A: output.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0D: output.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x09: output.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0..<0x20:
                output.append(contentsOf: "\\u00".utf8)
                output.append(ContractHex.lowercase[Int(byte >> 4)])
                output.append(ContractHex.lowercase[Int(byte & 0x0F)])
            default: output.append(byte)
            }
        }
        output.append(UInt8(ascii: "\""))
    }
}

// MARK: - Byte helpers

enum ContractUTF8 {
    /// Well-formed UTF-8 (Unicode table 3-7): no overlong forms, no surrogates, nothing above U+10FFFF.
    static func isValid(_ bytes: [UInt8]) -> Bool {
        var index = 0
        let count = bytes.count
        func continuation(_ offset: Int, _ range: ClosedRange<UInt8> = 0x80...0xBF) -> Bool {
            index + offset < count && range.contains(bytes[index + offset])
        }
        while index < count {
            let lead = bytes[index]
            switch lead {
            case 0x00...0x7F: index += 1
            case 0xC2...0xDF:
                guard continuation(1) else { return false }
                index += 2
            case 0xE0:
                guard continuation(1, 0xA0...0xBF), continuation(2) else { return false }
                index += 3
            case 0xE1...0xEC, 0xEE...0xEF:
                guard continuation(1), continuation(2) else { return false }
                index += 3
            case 0xED:
                guard continuation(1, 0x80...0x9F), continuation(2) else { return false }
                index += 3
            case 0xF0:
                guard continuation(1, 0x90...0xBF), continuation(2), continuation(3) else { return false }
                index += 4
            case 0xF1...0xF3:
                guard continuation(1), continuation(2), continuation(3) else { return false }
                index += 4
            case 0xF4:
                guard continuation(1, 0x80...0x8F), continuation(2), continuation(3) else { return false }
                index += 4
            default: return false
            }
        }
        return true
    }
}

/// Lowercase hex, the contract's form for bytes.
public enum ContractHex {
    static let lowercase = Array("0123456789abcdef".utf8)

    public static func encode(_ bytes: some Sequence<UInt8>) -> String {
        var output: [UInt8] = []
        for byte in bytes {
            output.append(lowercase[Int(byte >> 4)])
            output.append(lowercase[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Lowercase hex of whole bytes only; nil for anything else.
    public static func decode(_ text: String) -> [UInt8]? {
        let digits = Array(text.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = digit(digits[index], uppercase: false), let low = digit(digits[index + 1], uppercase: false) else { return nil }
            output.append(high << 4 | low)
            index += 2
        }
        return output
    }

    /// True for exactly `count` lowercase hex characters.
    static func isLowercase(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { digit($0, uppercase: false) != nil }
    }

    static func digit(_ byte: UInt8, uppercase: Bool) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F") where uppercase: byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
