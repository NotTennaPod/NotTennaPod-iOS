import Foundation

/// Reads a one-shot import file. Does not validate addresses, deduplicate rows,
/// subscribe, or fetch feeds. XML well-formedness is mandatory as an explicit
/// safeguard; valid-document source semantics remain separate.
public struct OPMLReader: Sendable {
    public init() {}

    public func read(_ data: Data) throws -> OPMLDocument {
        // The source activity uses the default Commons IO BOMInputStream (UTF-8
        // BOM only) and then an InputStreamReader fixed to UTF-8. Decode before
        // XML parsing so an encoding declaration cannot reinterpret the bytes.
        let bytes = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        var text = String(decoding: bytes, as: UTF8.self)
        if let expression = try? NSRegularExpression(
            pattern: #"\A(<\?xml(?=\s)[^?]*?\sencoding\s*=\s*)(["'])[^"']*\2"#) {
            text = expression.stringByReplacingMatches(in: text,
                range: NSRange(text.startIndex..., in: text), withTemplate: "$1$2UTF-8$2")
        }
        let prepared = try OPMLLexicalInput.prepare(text)
        let handler = OPMLXMLHandler(attributeNames: prepared.attributeNames)
        let parser = XMLParser(data: Data(prepared.text.utf8))
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = handler
        guard parser.parse(), parser.parserError == nil else {
            throw OPMLReadingError.malformedXML(line: parser.lineNumber, column: parser.columnNumber)
        }
        return OPMLDocument(entries: handler.entries)
    }
}

private final class OPMLXMLHandler: NSObject, XMLParserDelegate {
    var entries: [OPMLDocument.Entry] = []
    private var hasEnteredOPML = false
    private let attributeNames: [[String]]
    private var startTagIndex = 0
    private var currentAttributeNames: [String] = []

    init(attributeNames: [[String]]) { self.attributeNames = attributeNames }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        currentAttributeNames = startTagIndex < attributeNames.count ? attributeNames[startTagIndex] : []
        startTagIndex += 1
        // The source reader keeps this flag set until END_DOCUMENT, including
        // well-formed wrapper content after a closing OPML element.
        if elementName == "opml" { hasEnteredOPML = true }
        guard hasEnteredOPML, elementName == "outline",
              let address = attribute("xmlUrl", in: attributes), !address.isEmpty else { return }
        let suppliedTitle = attribute("title", in: attributes).flatMap { $0.isEmpty ? nil : $0 }
            ?? attribute("text", in: attributes).flatMap { $0.isEmpty ? nil : $0 }
        entries.append(.init(title: suppliedTitle ?? address, xmlURL: address,
                             htmlURL: attribute("htmlUrl", in: attributes), type: attribute("type", in: attributes)))
    }

    private func attribute(_ name: String, in attributes: [String: String]) -> String? {
        // Android KXmlParser.getAttributeValue(null, name) scans source
        // attributes in reverse order, ignoring namespace URI. A dictionary's
        // iteration order cannot preserve that last-source-attribute rule.
        currentAttributeNames.reversed().first {
            $0 != "xmlns" && !$0.hasPrefix("xmlns:") && $0.split(separator: ":").last.map(String.init) == name
        }.flatMap { attributes[$0] }
    }
}

/// Preserve the source parser's literal attribute TAB without replacing XML
/// validation. Comments, CDATA, declarations and text are copied verbatim.
private enum OPMLLexicalInput {
    struct Prepared {
        let text: String
        let attributeNames: [[String]]
    }
    static func prepare(_ text: String) throws -> Prepared {
        let input = Array(text); var output = ""; var i = 0
        var attributeNames: [[String]] = []
        // Match a complete quoted value so apparent names inside values cannot
        // become attributes. XMLParser still validates every name and value.
        let attribute = try NSRegularExpression(pattern: #"\s([^\s=<>/'"]+)\s*=\s*(?:"[^"]*"|'[^']*')"#)
        func starts(_ value: String) -> Bool { input[i...].starts(with: Array(value)) }
        func copyThrough(_ end: String) {
            while i < input.count {
                if starts(end) { output += end; i += end.count; return }
                output.append(input[i]); i += 1
            }
        }
        while i < input.count {
            if starts("<!--") { output += "<!--"; i += 4; copyThrough("-->"); continue }
            if starts("<![CDATA[") { output += "<![CDATA["; i += 9; copyThrough("]]>"); continue }
            if starts("<?") { output += "<?"; i += 2; copyThrough("?>"); continue }
            if starts("<!DOCTYPE") {
                var quote: Character?; var brackets = 0
                repeat {
                    let c = input[i]; output.append(c); i += 1
                    if let q = quote { if c == q { quote = nil } }
                    else if c == "\"" || c == "'" { quote = c }
                    else if c == "[" { brackets += 1 }
                    else if c == "]" { brackets -= 1 }
                    else if c == ">" && brackets == 0 { break }
                } while i < input.count
                continue
            }
            if input[i] == "<" {
                let tagStart = i
                let isStartTag = i + 1 < input.count && input[i + 1] != "/" && input[i + 1] != "!"
                var quote: Character?
                repeat {
                    let c = input[i]
                    if c == "&" { try checkReference(input, at: i) }
                    if let q = quote {
                        if c == q { quote = nil }
                        output += c == "\t" ? "&#9;" : String(c)
                    } else {
                        output.append(c)
                        if c == "\"" || c == "'" { quote = c }
                        else if c == ">" { i += 1; break }
                    }
                    i += 1
                } while i < input.count
                if isStartTag {
                    let tag = String(input[tagStart..<i])
                    attributeNames.append(attribute.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)).compactMap {
                        Range($0.range(at: 1), in: tag).map { String(tag[$0]) }
                    })
                }
            } else {
                if input[i] == "&" { try checkReference(input, at: i) }
                output.append(input[i]); i += 1
            }
        }
        return Prepared(text: output, attributeNames: attributeNames)
    }
    private static func checkReference(_ text: [Character], at i: Int) throws {
        guard let end = text[(i + 1)...].firstIndex(of: ";") else { return } // XMLParser diagnoses malformed syntax.
        let name = String(text[(i + 1)..<end])
        guard name.hasPrefix("#") || ["amp", "lt", "gt", "quot", "apos"].contains(name) else {
            // Original Android reader does not resolve named DTD entities. Do not
            // fetch external resources or silently expand an internal declaration.
            throw OPMLReadingError.unresolvedEntity(name)
        }
    }
}
