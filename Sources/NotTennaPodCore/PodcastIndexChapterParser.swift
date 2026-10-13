import Foundation

public enum PodcastIndexChapterParser {
    public static func parse(_ text: String) -> [ParsedChapter]? {
        let data = Data((text.first == "\u{FEFF}" ? String(text.dropFirst()) : text).utf8)
        // Foundation validates syntax and nesting before the ordered projection.
        // Keep object insertion order when a publisher supplies object metadata:
        // JSONObject.optString exposes that order in the displayed title/link.
        guard (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil else { return nil }
        // The ordered reader recurses per nesting level; 400 levels (JSONSerialization accepts 512) overflowed a
        // 512 KB thread stack and ended the app. Real chapter files nest three levels.
        guard nestingDepth(data) <= 64 else { return nil }
        var reader = OrderedChapterJSON(bytes: Array(data))
        guard case .object(let root) = reader.read(),
              case .array(let values) = root.first(where: { $0.0 == "chapters" })?.1 else { return nil }
        var chapters: [ParsedChapter] = []
        for value in values {
            guard case .object(let fields) = value else { return nil }
            func field(_ name: String) -> OrderedChapterJSON.Value? { fields.first { $0.0 == name }?.1 }
            chapters.append(.init(startMilliseconds: Int64(field("startTime")?.intValue ?? 0) * 1000,
                                  title: field("title")?.stringValue ?? "",
                                  link: field("url")?.stringValue ?? "",
                                  imageURL: field("img")?.stringValue ?? ""))
        }
        return chapters
    }

    private static func nestingDepth(_ data: Data) -> Int {
        var depth = 0, deepest = 0, inString = false, escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { inString = false }
                continue
            }
            switch byte {
            case 34: inString = true
            case 91, 123: depth += 1; deepest = max(deepest, depth)
            case 93, 125: depth -= 1
            default: break
            }
        }
        return deepest
    }
}

/// An order-preserving projection of already validated JSON. Scalar decoding
/// stays with Foundation; this is private to the chapter format's coercions.
private struct OrderedChapterJSON {
    indirect enum Value {
        case object([(String, Value)]), array([Value]), string(String), number(String), bool(Bool), null

        var intValue: Int32 {
            switch self {
            case .number(let raw):
                if let integer = Int64(raw) { return Int32(truncatingIfNeeded: integer) }
                return Self.narrow(Double(raw))
            case .string(let raw): return Self.narrow(Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
            default: return 0
            }
        }
        private static func narrow(_ value: Double?) -> Int32 {
            guard let value, !value.isNaN else { return 0 }
            if value >= Double(Int32.max) { return .max }
            if value <= Double(Int32.min) { return .min }
            return Int32(value)
        }
        var stringValue: String {
            switch self {
            case .string(let text): return text
            case .null: return "null"
            case .bool(let value): return value ? "true" : "false"
            case .number(let raw):
                if let integer = Int64(raw) { return String(integer) }
                return Self.doubleString(Double(raw) ?? 0)
            case .array, .object: return json
            }
        }
        private static func doubleString(_ number: Double) -> String {
            // Java Double.toString uses scientific notation outside [1e-3,1e7).
            let value = String(number)
            if let e = value.firstIndex(of: "e") {
                var mantissa = String(value[..<e])
                if !mantissa.contains(".") { mantissa += ".0" }
                return mantissa + "E" + String(Int(value[value.index(after: e)...]) ?? 0)
            }
            if abs(number) >= 1e7 || (number != 0 && abs(number) < 1e-3) {
                var digits = value.replacingOccurrences(of: ".", with: "")
                let negative = digits.hasPrefix("-"); if negative { digits.removeFirst() }
                let dot = value.firstIndex(of: ".").map { value.distance(from: value.startIndex, to: $0) } ?? value.count
                var exponent = dot - (negative ? 1 : 0) - 1
                while digits.first == "0" { digits.removeFirst(); exponent -= 1 }
                while digits.last == "0" { digits.removeLast() }
                let first = digits.removeFirst()
                return (negative ? "-" : "") + String(first) + "." + (digits.isEmpty ? "0" : digits) + "E" + String(exponent)
            }
            return value
        }
        var json: String {
            switch self {
            case .string(let text): return Self.quote(text)
            case .object(let fields): return "{" + fields.map { Self.quote($0.0) + ":" + $0.1.json }.joined(separator: ",") + "}"
            case .array(let values): return "[" + values.map(\.json).joined(separator: ",") + "]"
            case .number:
                let value = stringValue
                return value.hasSuffix(".0") ? String(value.dropLast(2)) : value
            default: return stringValue
            }
        }
        private static func quote(_ text: String) -> String {
            let data = try! JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
        }
    }

    let bytes: [UInt8]
    var offset = 0
    mutating func read() -> Value {
        whitespace()
        switch bytes[offset] {
        case 123: // Object; duplicate names replace values without moving their key.
            offset += 1; whitespace(); var fields: [(String, Value)] = []
            // Positions by name: a hostile object with 100,000 keys searched the list for every key.
            var positions: [String: Int] = [:]
            while bytes[offset] != 125 {
                let key = string(); whitespace(); offset += 1
                let value = read()
                if let index = positions[key] { fields[index].1 = value }
                else { positions[key] = fields.count; fields.append((key, value)) }
                whitespace(); if bytes[offset] == 44 { offset += 1; whitespace() } else { break }
            }
            offset += 1; return .object(fields)
        case 91:
            offset += 1; whitespace(); var values: [Value] = []
            while bytes[offset] != 93 {
                values.append(read()); whitespace()
                if bytes[offset] == 44 { offset += 1; whitespace() } else { break }
            }
            offset += 1; return .array(values)
        case 34: return .string(string())
        default:
            let start = offset
            scan: while offset < bytes.count {
                switch bytes[offset] { case 9, 10, 13, 32, 44, 93, 125: break scan; default: offset += 1 }
            }
            let token = String(decoding: bytes[start..<offset], as: UTF8.self)
            switch token { case "true": return .bool(true); case "false": return .bool(false); case "null": return .null; default: return .number(token) }
        }
    }
    private mutating func whitespace() {
        while offset < bytes.count, bytes[offset] == 9 || bytes[offset] == 10 || bytes[offset] == 13 || bytes[offset] == 32 { offset += 1 }
    }
    private mutating func string() -> String {
        let start = offset; offset += 1
        var escaped = false
        while bytes[offset] != 34 {
            if bytes[offset] == 92 { offset += 1; escaped = true }
            offset += 1
        }
        offset += 1
        // Validated JSON: a string without escapes is its UTF-8 bytes.
        guard escaped else { return String(decoding: bytes[(start + 1)..<(offset - 1)], as: UTF8.self) }
        return try! JSONSerialization.jsonObject(with: Data(bytes[start..<offset]), options: .fragmentsAllowed) as! String
    }
}
