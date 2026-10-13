import Foundation

/// How Android 3.12.1 turns a downloaded feed file into characters. `FeedHandler.parseFeed` and
/// `TypeGetter.createReader` both read through commons-io `XmlStreamReader` (2.5, lenient), which picks the
/// encoding from the byte-order mark, the first bytes and the XML declaration, and decodes with
/// `InputStreamReader` (malformed bytes become U+FFFD). Decoding here the same way gives the parser
/// Android's characters: a feed with a stray invalid byte still opens, and an unreadable declared encoding
/// fails like Android instead of as a parser error.
enum AndroidXMLStreamDecoding {
    struct Failure: Error, Equatable { let message: String }

    private static let byteOrderMarks: [(bytes: [UInt8], encoding: String)] = [
        // BOMInputStream tries the longest marks first.
        ([0x00, 0x00, 0xFE, 0xFF], "UTF-32BE"), ([0xFF, 0xFE, 0x00, 0x00], "UTF-32LE"),
        ([0xEF, 0xBB, 0xBF], "UTF-8"), ([0xFE, 0xFF], "UTF-16BE"), ([0xFF, 0xFE], "UTF-16LE"),
    ]
    private static let guesses: [(bytes: [UInt8], encoding: String)] = [
        ([0x3C, 0x3F, 0x78, 0x6D], "UTF-8"), ([0x00, 0x3C, 0x00, 0x3F], "UTF-16BE"), ([0x3C, 0x00, 0x3F, 0x00], "UTF-16LE"),
        ([0x00, 0x00, 0x00, 0x3C, 0x00, 0x00, 0x00, 0x3F, 0x00, 0x00, 0x00, 0x78, 0x00, 0x00, 0x00, 0x6D], "UTF-32BE"),
        ([0x3C, 0x00, 0x00, 0x00, 0x3F, 0x00, 0x00, 0x00, 0x78, 0x00, 0x00, 0x00, 0x6D, 0x00, 0x00, 0x00], "UTF-32LE"),
        ([0x4C, 0x6F, 0xA7, 0x94], "CP1047"),
    ]

    /// The document's characters as `XmlStreamReader` delivers them, or the failure that makes Android's
    /// reader unusable (an encoding it cannot decode, an XML declaration without its closing `>`).
    static func decode(_ data: Data) throws -> String {
        let bom = byteOrderMarks.first { data.starts(with: $0.bytes) }
        let body = data.dropFirst(bom?.bytes.count ?? 0)
        let guess = guesses.first { body.starts(with: $0.bytes) }?.encoding
        let declared = try declaredEncoding(body, guess: guess)
        let encoding: String
        switch bom?.encoding {
        case nil:
            if guess == nil || declared == nil { encoding = "UTF-8" }
            else if declared == "UTF-16", guess == "UTF-16BE" || guess == "UTF-16LE" { encoding = guess! }
            else { encoding = declared! }
        case "UTF-8":
            // A conflicting guess or declaration throws XmlStreamReaderException; lenient detection then
            // falls back to the declared encoding (or UTF-8).
            if (guess != nil && guess != "UTF-8") || (declared != nil && declared != "UTF-8") { encoding = declared ?? "UTF-8" }
            else { encoding = "UTF-8" }
        case let mark? where mark.hasPrefix("UTF-16"):
            if (guess != nil && guess != mark) || (declared != nil && declared != "UTF-16" && declared != mark) {
                encoding = declared ?? "UTF-8"
            } else { encoding = mark }
        default:
            encoding = declared ?? "UTF-8"
        }
        return try decode(body, javaCharset: encoding)
    }

    /// `XmlStreamReader.getXmlProlog`: the declaration up to the first `>` (read with the guessed encoding
    /// within 4096 bytes), its `encoding` attribute upper-cased.
    private static func declaredEncoding(_ body: Data, guess: String?) throws -> String? {
        guard let guess else { return nil }
        guard let text = try? decode(body.prefix(4096), javaCharset: guess), let end = text.firstIndex(of: ">") else {
            throw Failure(message: body.count < 4096 ? "Unexpected end of XML stream"
                          : "XML prolog or ROOT element not found on first 4096 bytes")
        }
        let prolog = text[...end].replacingOccurrences(of: "\r\n", with: "").replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        let pattern = #"<\?xml.*encoding[\s]*=[\s]*((?:".[^"]*")|(?:'.[^']*'))"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: prolog, range: NSRange(prolog.startIndex..., in: prolog)),
              let range = Range(match.range(at: 1), in: prolog) else { return nil }
        return String(prolog[range].dropFirst().dropLast()).uppercased()
    }

    /// `InputStreamReader` decoding: malformed input becomes U+FFFD; an unknown charset name fails.
    private static func decode(_ bytes: Data, javaCharset name: String) throws -> String {
        switch name.uppercased() {
        case "UTF-8", "UTF8": return String(decoding: bytes, as: UTF8.self)
        case "UTF-16BE", "UTF-16LE", "UTF-16":
            // Java's "UTF-16" honours a leading mark and otherwise reads big-endian.
            var little = name.uppercased() == "UTF-16LE"
            var units = bytes
            if name.uppercased() == "UTF-16", units.count >= 2 {
                if units.starts(with: [0xFF, 0xFE]) { little = true; units = units.dropFirst(2) }
                else if units.starts(with: [0xFE, 0xFF]) { units = units.dropFirst(2) }
            }
            var code: [UInt16] = []
            code.reserveCapacity(units.count / 2)
            var index = units.startIndex
            while index + 1 < units.endIndex {
                let first = UInt16(units[index]), second = UInt16(units[index + 1])
                code.append(little ? first | second << 8 : first << 8 | second)
                index += 2
            }
            var text = String(decoding: code, as: UTF16.self)
            if index < units.endIndex { text.unicodeScalars.append("\u{FFFD}") }
            return text
        default:
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else { throw Failure(message: name) }
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
            if let text = String(data: bytes, encoding: encoding) { return text }
            // A byte the charset leaves undefined: decode byte by byte, replacing what cannot be read.
            var text = ""
            for byte in bytes { text += String(data: Data([byte]), encoding: encoding) ?? "\u{FFFD}" }
            return text
        }
    }

    /// The characters as a UTF-8 document for Apple's XML parser: the declaration's encoding is rewritten so
    /// the parser reads the characters Android read instead of decoding the bytes again.
    static func utf8Document(_ text: String) -> Data {
        var text = text
        if text.hasPrefix("<?xml"), let end = text.firstIndex(of: ">"),
           let expression = try? NSRegularExpression(pattern: #"\A(<\?xml(?=\s)[^?]*?\sencoding\s*=\s*)(["'])[^"']*\2"#) {
            let declaration = String(text[...end])
            let rewritten = expression.stringByReplacingMatches(in: declaration,
                range: NSRange(declaration.startIndex..., in: declaration), withTemplate: "$1$2UTF-8$2")
            text.replaceSubrange(...end, with: rewritten)
        }
        return Data(text.utf8)
    }
}

/// Two constructs make Apple's XML parser (libxml2) work far longer than the document is long.
/// Android's parser (Expat) refuses the first and handles the second in linear time; real feeds never come
/// near either limit, so such a document is reported as a broken feed instead of stalling a refresh.
/// - Entities declared in the document that expand to more than 100 times its size once that exceeds 8 MiB
///   (Expat's billion-laughs protection defaults; a "quadratic blow-up" took libxml2 over ten seconds).
/// - More than 10,000 attributes on one element (libxml2's duplicate check is quadratic: 100,000 took ten
///   seconds).
enum XMLHostileStructureGuard {
    static let maximumAttributes = 10_000
    static let amplificationActivationBytes: Int64 = 8 << 20
    static let maximumAmplification: Int64 = 100

    /// Throws `FeedParsingError.limitExceeded` describing the first limit the document passes.
    static func check(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var scan = Scan(bytes: bytes)
            try scan.run()
            let total = scan.expandedReferenceBytes()
            if total > amplificationActivationBytes,
               Double(bytes.count) + Double(total) > Double(maximumAmplification) * Double(max(1, bytes.count)) {
                throw FeedParsingError.limitExceeded("Limit on input amplification factor (from DTD and entities) breached")
            }
        }
    }

    private struct Scan {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0
        /// Declared general entities: replacement bytes and the references inside them.
        var entities: [[UInt8]: (length: Int64, references: [[UInt8]])] = [:]
        /// References to declared entities in the document's content and attribute values.
        var references: [[UInt8]: Int64] = [:]

        init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

        /// The index of the next `byte` at or after `position`, or the end (memchr: text is skipped fast).
        private func next(_ byte: UInt8, from position: Int) -> Int {
            guard position < bytes.count, let base = bytes.baseAddress,
                  let found = memchr(base + position, Int32(byte), bytes.count - position) else { return bytes.count }
            return found.assumingMemoryBound(to: UInt8.self) - UnsafeMutablePointer(mutating: base)
        }

        private func starts(_ literal: StaticString, at position: Int) -> Bool {
            let count = literal.utf8CodeUnitCount
            guard position + count <= bytes.count else { return false }
            return literal.withUTF8Buffer { prefix in
                for offset in 0..<count where bytes[position + offset] != prefix[offset] { return false }
                return true
            }
        }
        private func find(_ literal: StaticString, from position: Int) -> Int {
            let first = literal.withUTF8Buffer { $0[0] }
            var cursor = next(first, from: position)
            while cursor < bytes.count, !starts(literal, at: cursor) { cursor = next(first, from: cursor + 1) }
            return min(bytes.count, cursor + literal.utf8CodeUnitCount)
        }
        private static func isNameByte(_ byte: UInt8) -> Bool {
            byte >= 0x80 || (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x5F || byte == 0x3A || byte == 0x2D || byte == 0x2E
        }
        private func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }

        /// `&name;` at `position` (not a character reference): the name and the index after `;`.
        private func reference(at position: Int) -> ([UInt8], Int)? {
            var cursor = position + 1
            guard cursor < bytes.count, bytes[cursor] != 0x23 else { return nil }
            while cursor < bytes.count, cursor - position <= 256, Self.isNameByte(bytes[cursor]) { cursor += 1 }
            guard cursor < bytes.count, bytes[cursor] == 0x3B, cursor > position + 1 else { return nil }
            return (Array(bytes[(position + 1)..<cursor]), cursor + 1)
        }
        private mutating func count(referencesIn range: Range<Int>) {
            guard !entities.isEmpty else { return }
            var cursor = next(0x26, from: range.lowerBound)
            while cursor < range.upperBound {
                if let (name, after) = reference(at: cursor), after <= range.upperBound {
                    if entities[name] != nil { references[name, default: 0] += 1 }
                    cursor = next(0x26, from: after)
                } else { cursor = next(0x26, from: cursor + 1) }
            }
        }

        mutating func run() throws {
            var textStart = 0
            while index < bytes.count {
                guard bytes[index] == 0x3C else { index = next(0x3C, from: index); continue }
                count(referencesIn: textStart..<index)
                if starts("<!--", at: index) { index = find("-->", from: index + 4) }
                else if starts("<![CDATA[", at: index) { index = find("]]>", from: index + 9) }
                else if starts("<?", at: index) { index = find("?>", from: index + 2) }
                else if starts("<!DOCTYPE", at: index) { doctype() }
                else if starts("<!", at: index) || starts("</", at: index) { skipTag() }
                else { try startTag() }
                // Markup that runs to the end of the document leaves `index` past it.
                index = min(index, bytes.count)
                textStart = index
            }
            count(referencesIn: textStart..<bytes.count)
        }

        /// A start tag: attributes are the `=` signs outside quoted values; values may hold references.
        private mutating func startTag() throws {
            var attributes = 0
            index += 1
            while index < bytes.count, bytes[index] != 0x3E {
                let byte = bytes[index]
                if byte == 0x22 || byte == 0x27 {
                    let start = index + 1
                    index = next(byte, from: start)
                    count(referencesIn: start..<min(index, bytes.count))
                } else if byte == 0x3D {
                    attributes += 1
                    if attributes > maximumAttributes {
                        throw FeedParsingError.limitExceeded("More than \(maximumAttributes) attributes on one element")
                    }
                }
                index += 1
            }
            index += 1
        }

        private mutating func skipTag() {
            index += 1
            var quote: UInt8?
            while index < bytes.count {
                let byte = bytes[index]
                if let open = quote { if byte == open { quote = nil } }
                else if byte == 0x22 || byte == 0x27 { quote = byte }
                else if byte == 0x3E { break }
                index += 1
            }
            index += 1
        }

        /// `<!DOCTYPE name ... [ internal subset ]>`: records `<!ENTITY name "value">` general entities.
        private mutating func doctype() {
            index += 9
            var quote: UInt8?
            while index < bytes.count {
                let byte = bytes[index]
                if let open = quote { if byte == open { quote = nil }; index += 1; continue }
                if byte == 0x22 || byte == 0x27 { quote = byte; index += 1; continue }
                if byte == 0x3E { index += 1; return }
                if byte == 0x5B { index += 1; internalSubset(); continue }
                index += 1
            }
        }

        private mutating func internalSubset() {
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x5D { index += 1; return }
                if starts("<!--", at: index) { index = find("-->", from: index + 4) }
                else if starts("<?", at: index) { index = find("?>", from: index + 2) }
                else if starts("<!ENTITY", at: index) { entity() }
                else if byte == 0x3C { skipTag() }
                else { index += 1 }
            }
        }

        private mutating func entity() {
            index += 8
            while index < bytes.count, isSpace(bytes[index]) { index += 1 }
            let parameter = index < bytes.count && bytes[index] == 0x25
            if parameter { index += 1; while index < bytes.count, isSpace(bytes[index]) { index += 1 } }
            let nameStart = index
            while index < bytes.count, Self.isNameByte(bytes[index]) { index += 1 }
            let name = Array(bytes[nameStart..<index])
            while index < bytes.count, isSpace(bytes[index]) { index += 1 }
            if !parameter, !name.isEmpty, index < bytes.count, bytes[index] == 0x22 || bytes[index] == 0x27 {
                let quote = bytes[index]
                let start = index + 1
                index = start
                while index < bytes.count, bytes[index] != quote { index += 1 }
                var inner: [[UInt8]] = []
                var cursor = start
                while cursor < index {
                    if bytes[cursor] == 0x26, let (reference, next) = reference(at: cursor), next <= index {
                        inner.append(reference); cursor = next
                    } else { cursor += 1 }
                }
                if entities[name] == nil { entities[name] = (Int64(index - start), inner) }
            }
            skipTag()
        }

        /// Characters the declared references expand to, saturating; a reference cycle counts as unbounded.
        /// Iterative, so a long chain of declarations cannot exhaust the stack.
        func expandedReferenceBytes() -> Int64 {
            func add(_ a: Int64, _ b: Int64) -> Int64 { let (sum, overflow) = a.addingReportingOverflow(b); return overflow ? .max : sum }
            var sizes: [[UInt8]: Int64] = [:]
            var visiting: Set<[UInt8]> = []
            func size(_ root: [UInt8]) -> Int64 {
                var stack: [([UInt8], Int)] = [(root, 0)]
                while let (name, next) = stack.last {
                    if sizes[name] != nil { stack.removeLast(); continue }
                    guard let entity = entities[name] else { sizes[name] = 0; stack.removeLast(); continue }
                    if next == 0 { visiting.insert(name) }
                    if next < entity.references.count {
                        stack[stack.count - 1].1 = next + 1
                        let child = entity.references[next]
                        if visiting.contains(child), sizes[child] == nil { sizes[name] = .max; visiting.remove(name); stack.removeLast(); continue }
                        stack.append((child, 0))
                        continue
                    }
                    if sizes[name] == nil { sizes[name] = entity.references.reduce(entity.length) { add($0, sizes[$1] ?? .max) } }
                    visiting.remove(name)
                    stack.removeLast()
                }
                return sizes[root] ?? 0
            }
            var total: Int64 = 0
            for (name, count) in references {
                let (product, overflow) = size(name).multipliedReportingOverflow(by: count)
                let (sum, sumOverflow) = total.addingReportingOverflow(overflow ? .max : product)
                total = sumOverflow ? .max : sum
            }
            return total
        }
    }
}
