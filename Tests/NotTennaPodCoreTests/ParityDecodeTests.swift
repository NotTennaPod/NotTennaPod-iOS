import Foundation
import Testing
@testable import NotTennaPodCore

/// How the parity parse turns a feed's bytes into characters: the server's charset resolution (golang.org/x/text's
/// ianaindex, then htmlindex) and its decoders, against the server's own answers (Fixtures/ParityCharsets.txt,
/// written by Tools/parity-tables.sh from the pinned server: every alias name, upper-cased too, and seeded byte
/// strings in each kind of decoder, malformed ones included).
struct ParityDecodeTests {
    static let fixtures = ContractVectorTests.root.appendingPathComponent("Tests/NotTennaPodCoreTests/Fixtures/ParityCharsets.txt")

    /// strconv.Unquote for the strings strconv.Quote writes.
    static func goUnquote(_ quoted: Substring) -> String {
        var scalars = String.UnicodeScalarView()
        var bytes: [UInt8] = []
        let s = Array(quoted.unicodeScalars.dropFirst().dropLast())
        var i = 0
        func flush() {
            scalars.append(contentsOf: String(decoding: bytes, as: UTF8.self).unicodeScalars)
            bytes = []
        }
        func hex(_ n: Int) -> UInt32 {
            let value = UInt32(String(String.UnicodeScalarView(s[(i + 2)..<(i + 2 + n)])), radix: 16)!
            i += 2 + n
            return value
        }
        while i < s.count {
            guard s[i] == "\\" else {
                flush()
                scalars.append(s[i])
                i += 1
                continue
            }
            switch s[i + 1] {
            case "x": bytes.append(UInt8(hex(2)))
            case "u":
                flush()
                scalars.append(Unicode.Scalar(hex(4))!)
            case "U":
                flush()
                scalars.append(Unicode.Scalar(hex(8))!)
            default:
                flush()
                let escapes: [Unicode.Scalar: Unicode.Scalar] = ["t": "\t", "n": "\n", "r": "\r", "a": "\u{07}", "b": "\u{08}",
                                                                 "f": "\u{0C}", "v": "\u{0B}", "\\": "\\", "\"": "\""]
                scalars.append(escapes[s[i + 1]]!)
                i += 2
            }
        }
        flush()
        return String(scalars)
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func bytes(_ hex: Substring) -> [UInt8] {
        let digits = Array(hex.utf8)
        return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(decoding: digits[$0..<($0 + 2)], as: UTF8.self), radix: 16)! }
    }

    @Test func charsetsAndDecodersAnswerAsTheServer() throws {
        let lines = try String(contentsOf: Self.fixtures, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("#") }
        var names = 0
        var decodes = 0
        var failures: [String] = []
        for line in lines {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            switch fields[0] {
            case "charset":
                let name = Self.goUnquote(fields[1])
                let actual = ParityCharset.lookup(name)?.name ?? "!none"
                if actual != fields[2] { failures.append("charset \(fields[1]): \(actual), server \(fields[2])") }
                names += 1
            case "decode":
                // Decoded as a parse decodes, its steps counted.
                let output = try ParityDecode.decodeCharset(Self.bytes(fields[2])[...], name: String(fields[1]),
                                                            work: ParityCancellation { false }).map(Self.hex) ?? "!error"
                if output != fields[3] { failures.append("decode \(fields[1]) \(fields[2]): \(output), server \(fields[3])") }
                decodes += 1
            default:
                Issue.record("unknown fixture line \(line)")
            }
        }
        print("parity charsets: \(names) names, \(decodes) decodes, \(failures.count) differ")
        #expect(names > 2000 && decodes > 3000)
        #expect(failures.isEmpty, "\(failures.count) differ:\n\(failures.prefix(20).joined(separator: "\n"))")
    }

    /// XmlStreamReader's choices: a byte-order mark, the first bytes and the declaration; ISO-8859-1 is the real
    /// Latin-1 here (windows-1252 reaches text through TagSoup's map), and an unknown declared charset makes the
    /// document a website.
    @Test func documentDecoding() throws {
        func decode(_ bytes: [UInt8]) -> String? {
            let text: [UInt8]?? = try? ParityDecode.decodeDocument(bytes, work: ParityCancellation { false })
            return text?.map { String(decoding: $0, as: UTF8.self) }
        }
        #expect(decode(Array("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><a>".utf8) + [0x80, 0xE9]) == "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><a>\u{80}\u{E9}")
        #expect(decode(Array("<?xml version=\"1.0\" encoding=\"windows-1252\"?><a>".utf8) + [0x80]) == "<?xml version=\"1.0\" encoding=\"windows-1252\"?><a>\u{20AC}")
        #expect(decode(Array("<?xml version=\"1.0\" encoding=\"x-unknown-charset\"?><a/>".utf8)) == nil)
        #expect(decode([0xEF, 0xBB, 0xBF] + Array("<a>\u{E9}</a>".utf8)) == "<a>\u{E9}</a>")
        #expect(decode([0xFF, 0xFE, 0x3C, 0x00, 0x61, 0x00, 0x3E, 0x00]) == "<a>")
        #expect(decode([0x3C, 0x61, 0x3E, 0xE2, 0x82, 0x3C]) == "<a>\u{FFFD}<")  // a maximal subpart is one U+FFFD
        // The declaration's end must be within its first 4096 bytes.
        #expect(decode(Array("<?xm".utf8) + [UInt8](repeating: 0x20, count: 5000) + Array(">".utf8)) == nil)
        // Go's leftmost-first match: the last "encoding" after the first "<?xml" that the rest matches.
        #expect(ParityDecode.prologEncoding(Array("<?xml encoding='a' encoding=\"b\" encoding=?>".utf8)).map { Array($0) } == Array("b".utf8))
    }
}
