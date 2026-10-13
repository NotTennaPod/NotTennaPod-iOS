import Foundation
import Testing
@testable import NotTennaPodCore

/// The parse's limits at their exact edges and its depth on a default secondary thread.
/// Every expectation is a fixed number worked out from the server's rules (sax.go: text and attribute values 64 MiB,
/// entity text 16 MiB, Expat's activation at 8 MiB and amplification 100, entity depth 64, element depth 256), never
/// read from this port's constants: a limit one off fails here.
struct ParityLimitTests {
    typealias Parse = ParityFeedParserTests

    /// "accepted" when the document parses with its title, the parse error's label otherwise.
    static func outcome(_ doc: String) -> String {
        do {
            let feed = try Parse.parse(doc)
            return feed.title == "T" ? "accepted" : "title \(String(describing: feed.title))"
        } catch let error as ParityParseError {
            return error.label
        } catch {
            return "\(error)"
        }
    }

    // MARK: Text and attribute values: 64 MiB (67,108,864 bytes) counted

    /// The decoded text and attribute values inside the document element are counted in UTF-8 bytes: the version
    /// attribute (3), the title (1) and 33,554,430 "é" (67,108,860) are exactly 67,108,864, the most there may be.
    @Test func textUpToSixtyFourMebibytes() {
        let head = "<rss version=\"2.0\"><channel><title>T</title><x>"
        let tail = "</x></channel></rss>"
        let text = String(repeating: "\u{E9}", count: 33_554_430)
        #expect(Self.outcome(head + text + tail) == "accepted")
        #expect(Self.outcome(head + text + "x" + tail) == "parser_exception")
    }

    /// Attribute values and text count together; namespace declarations and white space outside the document
    /// element do not count.
    @Test func attributesAndTextUpToSixtyFourMebibytes() {
        let head = "\n <rss version=\"2.0\" xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><channel><title>T</title><x a=\""
        let value = String(repeating: "a", count: 33_554_432)
        let text = String(repeating: "\u{E9}", count: 16_777_214)  // 33,554,428 bytes: with 3 + 1, 67,108,864
        #expect(Self.outcome(head + value + "\">" + text + "</x></channel></rss>\n") == "accepted")
        #expect(Self.outcome(head + value + "\">" + text + "x</x></channel></rss>\n") == "parser_exception")
    }

    // MARK: Entity text: 16 MiB (16,777,216 bytes) charged

    /// Every use is charged its expanded length, and every expansion built along the way once: c ("&e;", e being
    /// 4,096 x's) used 4,093 times charges 4,093 × 4,096 + 4,096 (c built) + 4,096 (e built) = 16,773,120, and z
    /// ("x") used m times charges m + 1. With m = 4,095 that is 16,777,216, the most there may be. A 200,000-byte
    /// comment before the uses keeps them under Expat's amplification limit.
    @Test func entityTextUpToSixteenMebibytes() {
        func doc(_ m: Int) -> String {
            "<!DOCTYPE rss [<!ENTITY e \"" + String(repeating: "x", count: 4096) + "\"><!ENTITY c \"&e;\"><!ENTITY z \"x\">]>"
                + "<rss version=\"2.0\"><channel><title>T</title><!--" + String(repeating: "p", count: 200_000) + "--><x>"
                + String(repeating: "&c;", count: 4093) + String(repeating: "&z;", count: m) + "</x></channel></rss>"
        }
        #expect(Self.outcome(doc(4095)) == "accepted")
        #expect(Self.outcome(doc(4096)) == "parser_exception")
    }

    // MARK: Expat's amplification: 100 times the input, from 8 MiB (8,388,608 bytes)

    /// a is 1,024 x's, b 1,024 uses of a (1,048,576 bytes), t 26,392 y's. After &t; and eight &b; the expansions
    /// are 26,392 + 8 × 1,048,576 = 8,415,000 bytes; with the input read so far at D = 85,000 bytes the total is
    /// 8,500,000, exactly 100 times D, which may be; at D = 84,999 it is more than 100 times.
    @Test func amplificationUpToOneHundredTimes() {
        let prolog = "<!DOCTYPE rss [<!ENTITY a \"" + String(repeating: "x", count: 1024) + "\"><!ENTITY b \""
            + String(repeating: "&a;", count: 1024) + "\"><!ENTITY t \"" + String(repeating: "y", count: 26_392) + "\">]>"
        func doc(direct: Int) -> String {
            let head = prolog + "<rss version=\"2.0\"><channel><title>T</title><x>&t;<!--"
            let uses = "-->" + String(repeating: "&b;", count: 8)
            let pad = direct - head.utf8.count - uses.utf8.count
            let doc = head + String(repeating: "p", count: pad) + uses
            #expect(doc.utf8.count == direct)
            return doc + "</x></channel></rss>"
        }
        #expect(Self.outcome(doc(direct: 85_000)) == "accepted")
        #expect(Self.outcome(doc(direct: 84_999)) == "parser_exception")
    }

    /// Below 8,388,608 bytes of input and expansions together, any amplification may be: seven &b; and a thousand
    /// &a; expand to 7 × 1,048,576 + 1,000 × 1,024 = 8,364,032 bytes, with the input read so far at D = 24,575 bytes
    /// a total of 8,388,607 (accepted, though more than 300 times D); at D = 24,576 the total reaches 8,388,608.
    @Test func amplificationFromEightMebibytes() {
        let prolog = "<!DOCTYPE rss [<!ENTITY a \"" + String(repeating: "x", count: 1024) + "\"><!ENTITY b \""
            + String(repeating: "&a;", count: 1024) + "\">]>"
        func doc(direct: Int) -> String {
            let head = prolog + "<rss version=\"2.0\"><channel><title>T</title><x><!--"
            let uses = "-->" + String(repeating: "&b;", count: 7) + String(repeating: "&a;", count: 1000)
            let pad = direct - head.utf8.count - uses.utf8.count
            let doc = head + String(repeating: "p", count: pad) + uses
            #expect(doc.utf8.count == direct)
            return doc + "</x></channel></rss>"
        }
        #expect(Self.outcome(doc(direct: 24_575)) == "accepted")
        #expect(Self.outcome(doc(direct: 24_576)) == "parser_exception")
    }

    // MARK: Depth on a default secondary thread (512 KiB of stack)

    /// Runs body on a Foundation thread with the default secondary-thread stack, as a refresh's parse can run.
    static func onDefaultThread(_ body: @escaping @Sendable () -> [String]) async -> (stack: Int, results: [String]) {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                let stack = Thread.current.stackSize
                continuation.resume(returning: (stack, body()))
            }
            thread.start()
        }
    }

    /// Entity references nest 64 deep (e0 at depth 64 under e64), elements 256 deep; TagSoup's element chains of
    /// 200,000 are released, after a conversion, when it throws and when its formatting elements are restarted; a
    /// date's weekday retries are a loop. All on a default secondary thread's stack, where recursion as deep as the
    /// input would overflow.
    @Test func depthOnADefaultSecondaryThread() async {
        let (stack, results) = await Self.onDefaultThread {
            func entities(_ depth: Int) -> String {
                var prolog = "<!DOCTYPE rss [<!ENTITY e0 \"x\">"
                for i in 1...depth { prolog += "<!ENTITY e\(i) \"&e\(i - 1);\">" }
                return prolog + "]><rss version=\"2.0\"><channel><title>T</title><x>&e\(depth);</x></channel></rss>"
            }
            func elements(_ depth: Int) -> String {
                let nested = depth - 2  // rss and channel
                return "<rss version=\"2.0\"><channel><title>T</title>" + String(repeating: "<x>", count: nested)
                    + String(repeating: "</x>", count: nested) + "</channel></rss>"
            }
            func html(_ s: String) -> String {
                do {
                    return try ParityHTMLText.text(s, compact: true, cancellation: ParityCancellation { false })
                        .utf16.count.description
                } catch let error as ParityParseError {
                    return error.label
                } catch {
                    return "\(error)"
                }
            }
            let bold = String(repeating: "<b>", count: 200_000)
            let date = (try? ParityDates.parse(String(repeating: "a, ", count: 1000) + "Sat, 09 Oct 2021 10:00:00 +0000",
                                               now: Parse.now)).flatMap { $0 }
            return [Self.outcome(entities(64)), Self.outcome(entities(65)), Self.outcome(elements(256)), Self.outcome(elements(257)),
                    html(bold + "x"), html(bold + "<font color=\"-\">x"), html(bold + "<p>x"), date.map(String.init) ?? "nil"]
        }
        #expect(stack == 512 << 10, "the thread's stack is \(stack) bytes, not the default 512 KiB")
        // The text of the restarted case is "x" and the paragraph's newline.
        #expect(results == ["accepted", "parser_exception", "accepted", "parser_exception", "1", "parser_exception", "2",
                            "1633773600000"])
    }
}
