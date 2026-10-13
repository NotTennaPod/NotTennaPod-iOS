import Foundation
import SwiftSoup

enum FeedValueParsing {
    static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\u{b}\u{c}"))
    }

    static func integer(_ value: String?) -> Int64? {
        guard let value, !value.isEmpty else { return nil }
        var units = Array(value.utf16)
        var normalized = ""
        if units.first == 43 || units.first == 45 {
            normalized = units.removeFirst() == 45 ? "-" : "+"
        }
        guard !units.isEmpty else { return nil }
        for unit in units {
            guard let scalar = Unicode.Scalar(unit), scalar.properties.numericType == .decimal,
                  let number = scalar.properties.numericValue else { return nil }
            normalized += String(Int(number))
        }
        return Int64(normalized)
    }

    static func saturatedMultiply(_ value: Int64, by factor: Int64) -> Int64 {
        let result = value.multipliedReportingOverflow(by: factor)
        return result.overflow ? (value < 0 ? .min : .max) : result.partialValue
    }

    static func javaLong(_ value: Float) -> Int64 {
        if value.isNaN { return 0 }
        if value >= Float(Int64.max) { return .max }
        if value <= Float(Int64.min) { return .min }
        return Int64(value)
    }

    static func components(_ value: String) -> [String] {
        var parts = value.components(separatedBy: ":")
        if !value.isEmpty {
            while parts.last == "" { parts.removeLast() }
        }
        return parts
    }

    static func duration(_ value: String) -> Int64? {
        let parts = components(JavaString.trim(value))
        guard (1...3).contains(parts.count), let seconds = parts.last else { return nil }
        var result: Int64
        if seconds.contains(".") {
            var raw = JavaString.trim(seconds)
            if ["f", "F", "d", "D"].contains(raw.last.map(String.init) ?? "") { raw.removeLast() }
            guard let number = Float(raw) else { return nil }
            result = saturatedMultiply(javaLong(number), by: 1_000)
                &+ javaLong(number.truncatingRemainder(dividingBy: 1) * 1_000)
        } else {
            guard let number = integer(seconds) else { return nil }
            result = saturatedMultiply(number, by: 1_000)
        }
        if parts.count >= 2 {
            guard let minutes = integer(parts[parts.count - 2]) else { return nil }
            result = result &+ saturatedMultiply(minutes, by: 60_000)
        }
        if parts.count == 3 {
            guard let hours = integer(parts[0]) else { return nil }
            result = result &+ saturatedMultiply(hours, by: 3_600_000)
        }
        return result
    }

    static func chapterTime(_ value: String) -> Int64? {
        let parts = components(value)
        var result: Int64 = 0
        var index = 0
        if parts.count == 3 {
            guard let hours = integer(parts[0]), Int32(exactly: hours) != nil else { return nil }
            result = hours * 3_600_000
            index = 1
        }
        if parts.count >= 2 {
            guard let minutes = integer(parts[index]), Int32(exactly: minutes) != nil,
                  let seconds = Float(JavaString.trim(parts[index + 1])) else { return nil }
            result = result &+ minutes * 60_000 &+ javaLong(seconds * 1_000)
        }
        return result
    }

    static func htmlText(_ value: String, compact: Bool) throws -> String {
        // Text without markup or references is one text node: its result is the whitespace rule below, without
        // the HTML parser (a feed of 100,000 episodes spent most of its parse there).
        if !value.unicodeScalars.contains(where: { $0 == "<" || $0 == "&" || $0 == "\r" || $0 == "\0" }) {
            var output = String.UnicodeScalarView()
            for scalar in value.unicodeScalars {
                if scalar == " " || scalar == "\n" {
                    if let last = output.last, last != " ", last != "\n" { output.append(" ") }
                } else { output.append(scalar) }
            }
            return String(output)
        }
        guard !HTMLNesting.exceeds(value) else { return HTMLNesting.plainText(value, compact: compact) }
        let document = try SwiftSoup.parseBodyFragment(value)
        var output = ""
        let blocks: Set<String> = ["p", "ul", "li", "div", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6"]
        func boundary() {
            guard !output.isEmpty else { return }
            let existing = output.reversed().prefix(while: { $0 == "\n" }).count
            output += String(repeating: "\n", count: max(0, (compact ? 1 : 2) - existing))
        }
        // Depth-first in document order with an explicit stack (recursion overflowed the stack
        // on markup nested hundreds of thousands deep).
        guard let body = document.body() else { return output }
        var pending: [(node: Node, leaving: Bool)] = [(body, false)]
        while let (node, leaving) = pending.popLast() {
            if let text = node as? TextNode {
                for scalar in text.getWholeText().unicodeScalars {
                    if scalar == " " || scalar == "\n" {
                        if let last = output.unicodeScalars.last, last != " ", last != "\n" { output += " " }
                    } else {
                        output.unicodeScalars.append(scalar)
                    }
                }
                continue
            }
            let tag = (node as? Element)?.tagName() ?? ""
            if leaving {
                if tag == "br" { output += "\n" }
                if blocks.contains(tag) { boundary() }
                continue
            }
            if blocks.contains(tag) { boundary() }
            if tag == "img" { output += "\u{fffc}" }
            pending.append((node, true))
            pending.append(contentsOf: node.getChildNodes().reversed().map { ($0, false) })
        }
        return output
    }
}
