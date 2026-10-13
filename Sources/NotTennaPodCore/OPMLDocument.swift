import Foundation

/// The flattened selection rows returned by OPML import. Row order and repeated
/// addresses are significant; subscription identity belongs to the commit owner.
public struct OPMLDocument: Equatable, Codable, Sendable {
    public struct Entry: Equatable, Codable, Sendable {
        public var title: String
        public var xmlURL: String
        public var htmlURL: String?
        public var type: String?

        public init(title: String, xmlURL: String, htmlURL: String? = nil, type: String? = nil) {
            self.title = title
            self.xmlURL = xmlURL
            self.htmlURL = htmlURL
            self.type = type
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }
}

public enum OPMLReadingError: Error, Equatable, Sendable {
    case malformedXML(line: Int, column: Int)
    case unresolvedEntity(String)
}


extension OPMLReadingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedXML(let line, let column): "Malformed XML at line \(line), column \(column)."
        case .unresolvedEntity(let name): "Unresolved entity: &\(name);"
        }
    }
}
