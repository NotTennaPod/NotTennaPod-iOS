import Foundation

/// Rewrite network references, keeping HLS tags and native selection/timing semantics.
struct HLSRelayPlaylist {
    enum Failure: Error { case invalidText, unresolvedVariable, contentSteering }
    static func rewrite(_ data: Data, base: URL, inherited: [String: String] = [:],
                        map: (URL, Bool, [String: String]) throws -> URL) throws -> Data {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else { throw Failure.invalidText }
        var variables: [String: String] = [:]
        var nextIsPlaylist = false
        let expression = try NSRegularExpression(pattern: #"(?:^|,)([A-Z0-9-]*URI)="([^"]*)""#)
        func expanded(_ text: String) throws -> String {
            var result = text
            for _ in 0..<32 {
                guard let start = result.range(of: "{$"), let end = result[start.upperBound...].firstIndex(of: "}") else { return result }
                let name = String(result[start.upperBound..<end])
                guard let value = variables[name] else { throw Failure.unresolvedVariable }
                result.replaceSubrange(start.lowerBound...end, with: value)
            }
            throw Failure.unresolvedVariable
        }
        func mapped(_ text: String, playlist: Bool) throws -> String {
            let value = try expanded(text)
            guard let url = URL(string: value, relativeTo: base)?.absoluteURL else { throw URLError(.badURL) }
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return value }
            return try map(url, playlist, variables).absoluteString
        }
        let lines = try text.components(separatedBy: "\n").map { original -> String in
            let line = original.hasSuffix("\r") ? String(original.dropLast()) : original
            if line.hasPrefix("#EXT-X-DEFINE:") {
                let attributes = attributes(String(line.dropFirst("#EXT-X-DEFINE:".count)))
                if let name = attributes["NAME"], let value = attributes["VALUE"] { variables[name] = try expanded(value) }
                if let name = attributes["IMPORT"] {
                    guard let value = inherited[name] else { throw Failure.unresolvedVariable }
                    variables[name] = value
                }
                if let name = attributes["QUERYPARAM"] {
                    guard let value = URLComponents(url: base, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == name })?.value,
                          !value.contains("\""), !value.contains("\n"), !value.contains("\r") else { throw Failure.unresolvedVariable }
                    variables[name] = value
                    // Native playback sees an opaque local URL, so preserve the original
                    // query-derived variable as an explicit definition for its parser.
                    return "#EXT-X-DEFINE:NAME=\"\(name)\",VALUE=\"\(value)\""
                }
                return line
            }
            // Content steering can synthesize remote hosts from JSON, outside playlist URI rewriting.
            // Keep this explicit capability gap until those generated routes are mediated too.
            if line.hasPrefix("#EXT-X-CONTENT-STEERING:") { throw Failure.contentSteering }
            if !line.isEmpty, !line.hasPrefix("#") {
                defer { nextIsPlaylist = false }
                return try mapped(line, playlist: nextIsPlaylist)
            }
            if line.hasPrefix("#EXT-X-STREAM-INF:") { nextIsPlaylist = true }
            guard let colon = line.firstIndex(of: ":") else { return line }
            let tag = String(line[..<colon]), attributesStart = line.index(after: colon)
            var attributesText = String(line[attributesStart...])
            let isPlaylist = ["#EXT-X-MEDIA", "#EXT-X-I-FRAME-STREAM-INF", "#EXT-X-RENDITION-REPORT", "#EXT-X-IMAGE-STREAM-INF"].contains(tag)
            for match in expression.matches(in: attributesText, range: NSRange(attributesText.startIndex..., in: attributesText)).reversed() {
                guard let range = Range(match.range(at: 2), in: attributesText) else { continue }
                let replacement = try mapped(String(attributesText[range]), playlist: isPlaylist)
                attributesText.replaceSubrange(range, with: replacement)
            }
            return tag + ":" + attributesText
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
    private static func attributes(_ text: String) -> [String: String] {
        var quoted = false, fields: [String] = [], current = ""
        for character in text {
            if character == "\"" { quoted.toggle() }
            if character == ",", !quoted { fields.append(current); current = "" } else { current.append(character) }
        }
        fields.append(current)
        return fields.reduce(into: [:]) { result, field in
            guard let equals = field.firstIndex(of: "=") else { return }
            let key = String(field[..<equals]); var value = String(field[field.index(after: equals)...])
            if value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            result[key] = value
        }
    }
}
