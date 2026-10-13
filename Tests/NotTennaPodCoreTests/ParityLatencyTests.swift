import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// How promptly a parse answers its cancellation: the longest time between two questions
/// (from the start to the first included; the last decides the answer), the time from its first true answer to
/// the return (teardown and unwinding included), and how late it returns after a deadline armed just after a chosen
/// question. Bounds are far above what these inputs take now in a debug build on a loaded machine, and far below what
/// the same inputs took before.
struct ParityLatencyTests {
    struct Run {
        var seconds = 0.0
        var gap = 0.0  // the longest time between two questions, from the start to the first included
        var gapAfter = 0  // the question that gap follows (0: the start)
        var tail = 0.0  // from the last question, when the answer is decided, to the return
        var checks = 0
        var afterTrue: Double?  // from the first true answer to the return
        var lateness: Double?  // from the armed deadline to the return
        var outcome = ""
    }

    /// The clock's seconds.
    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    /// Parses doc on a default secondary thread, as a refresh can, timing every question. cancelAt answers true from
    /// that question on; armAt arms a deadline armDelay after that question. With expandOnly, only the document's
    /// entities are expanded (the parse's first pass).
    static func run(_ doc: [UInt8], cancelAt: Int? = nil, armAt: Int? = nil, armDelay: Double = 0.001,
                    expandOnly: Bool = false) -> Run {
        final class Box: @unchecked Sendable {
            var run = Run()
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let data = Data(doc)
        let thread = Thread {
            var run = Run()
            let start = now()
            var last = start
            var firstTrue: Double?
            var deadline: Double?
            let isCancelled: () -> Bool = {
                let t = now()
                if t - last > run.gap {
                    run.gap = t - last
                    run.gapAfter = run.checks
                }
                last = t
                run.checks += 1
                if run.checks == armAt { deadline = t + armDelay }
                let cancelled = (cancelAt.map { run.checks >= $0 } ?? false) || (deadline.map { t >= $0 } ?? false)
                if cancelled && firstTrue == nil { firstTrue = t }
                return cancelled
            }
            do {
                if expandOnly {
                    let expanded = try ParitySAX.expandDocument(doc, cancellation: ParityCancellation(isCancelled: isCancelled))
                    run.outcome = "expanded \(expanded.count)"
                } else {
                    let feed = try ParityFeedParser.parse(data, source: "https://example.com/feed.xml", now: ParityFeedParserTests.now,
                                                          isCancelled: isCancelled)
                    run.outcome = "feed \(feed.title ?? "")"
                }
            } catch is CancellationError {
                run.outcome = "cancelled"
            } catch let error as ParityParseError {
                run.outcome = error.label
            } catch {
                run.outcome = "\(error)"
            }
            let end = now()
            run.tail = end - last
            run.seconds = end - start
            run.afterTrue = firstTrue.map { end - $0 }
            run.lateness = deadline.map { end - $0 }
            box.run = run
            done.signal()
        }
        thread.start()
        done.wait()
        return box.run
    }

    static func describe(_ r: Run) -> String {
        String(format: "%@: %.3f s, %d questions, longest gap %.1f ms after question %d, tail %.1f ms, after true %@, late %@", r.outcome,
               r.seconds, r.checks, r.gap * 1000, r.gapAfter, r.tail * 1000, r.afterTrue.map { String(format: "%.1f ms", $0 * 1000) } ?? "-",
               r.lateness.map { String(format: "%.1f ms", $0 * 1000) } ?? "-")
    }

    /// The parse's latency at its longest gap: uncancelled, cancelled at the question that gap follows (the time from
    /// that true answer to the return), and with a deadline armed just after it.
    /// warm runs the parse once first: a first parse in the process can spend a long time releasing memory it was the
    /// first to touch, which no question can shorten.
    static func atLongestGap(_ name: String, _ doc: [UInt8], cancel: Bool = true, arm: Bool = true,
                             warm: Bool = false, expandOnly: Bool = false) -> (plain: Run, cancelled: Run?, armed: Run?) {
        if warm { _ = run(doc, expandOnly: expandOnly) }
        let plain = run(doc, expandOnly: expandOnly)
        let at = max(1, plain.gapAfter)
        let cancelled = cancel ? run(doc, cancelAt: at, expandOnly: expandOnly) : nil
        let armed = arm ? run(doc, armAt: at, expandOnly: expandOnly) : nil
        print("parity latency \(name) (\(doc.count) bytes): plain \(describe(plain))"
              + (cancelled.map { "; cancelled at \(at): " + describe($0) } ?? "") + (armed.map { "; armed after \(at): " + describe($0) } ?? ""))
        return (plain, cancelled, armed)
    }

    static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    // MARK: Element names

    /// A name of colons kept one index for every colon before it was refused (64 MiB peaked at 1.5 GB, six times Go's
    /// reader); one index is kept now, and the scan stops at the second colon.
    @Test func colonNamesKeepOneIndex() {
        let doc = Self.bytes("<rss version=\"2.0\"><channel><title>t</title><" + String(repeating: ":", count: 8 << 20) + "/></channel></rss>")
        var outcome = ""
        let run = ParityParseMeasurementTests.measure {
            outcome = Self.run(doc).outcome
        }
        print("parity latency colon name: peak heap \(run.peakBytes) bytes for \(doc.count)")
        #expect(outcome == "parser_exception")
        #expect(run.peakBytes < 12 * doc.count, "peak heap \(run.peakBytes) bytes for a \(doc.count)-byte feed")
    }

    /// A long name with one colon is scanned whole, and its steps are counted: no long time between questions.
    @Test func colonScansAreCounted() {
        let doc = Self.bytes("<rss version=\"2.0\"><channel><title>t</title><a:" + String(repeating: "b", count: 24 << 20)
            + "/></channel></rss>")
        let (plain, _, armed) = Self.atLongestGap("one colon", doc, cancel: false)
        #expect(plain.outcome == "parser_exception" && armed?.outcome == "cancelled")
        #expect((armed?.lateness ?? 1) < 0.15, "a deadline armed after the question before the longest gap")
    }

    // MARK: Teardown after cancellation

    /// A website tag's attributes were kept, never read: a tag of millions took seconds to release, after the
    /// cancellation's true answer too. They are read past now.
    @Test func websiteTagAttributesAreNotKept() {
        let doc = Self.bytes("<html><head><link" + (0..<1_000_000).map { " a\($0)=v" }.joined() + "><title>T</title></head></html>")
        let (plain, cancelled, _) = Self.atLongestGap("website attributes", doc, arm: false)
        #expect(plain.outcome == "unsupported_type_html" && cancelled?.outcome == "cancelled")
        #expect((cancelled?.afterTrue ?? 1) < 0.05, "from the true answer at the longest gap to the return")
    }

    /// TagSoup kept every unknown element type it defined, and every element of a chain, as objects: millions took
    /// seconds to release after the cancellation's true answer. They are numbered in contiguous storage now. The
    /// parse is cancelled at its middle and at its longest gap.
    @Test func htmlElementsReleaseAtOnce() {
        for (name, title, text) in [("unknown elements", (0..<500_000).map { "<zz\($0)/>" }.joined(), ""),
                                    ("a chain", String(repeating: "<b>", count: 2_000_000) + "T", "T")] {
            let doc = Self.bytes("<rss version=\"2.0\"><channel><title><![CDATA[" + title + "]]></title></channel></rss>")
            let (plain, atGap, _) = Self.atLongestGap(name, doc, arm: false)
            let middle = Self.run(doc, cancelAt: plain.checks / 2)
            print("parity latency \(name), cancelled at its middle: \(Self.describe(middle))")
            #expect(plain.outcome == "feed " + text && atGap?.outcome == "cancelled" && middle.outcome == "cancelled", "\(name)")
            #expect((atGap?.afterTrue ?? 1) < 0.025 && (middle.afterTrue ?? 1) < 0.025, "\(name): from the true answer to the return")
        }
    }

    /// An HTML declaration of millions of words: TagSoup's split kept every word (2.9 GB of heap
    /// for 64 MiB), released for 150 ms, after the true answer too. Only the five words it reads
    /// are kept now.
    @Test func htmlDeclarationWordsAreNotKept() {
        let doc = Self.bytes("<rss version=\"2.0\"><channel><title><![CDATA[<!DOCTYPE " + String(repeating: "x ", count: 4_000_000)
                             + ">T]]></title></channel></rss>")
        var outcome = ""
        let measured = ParityParseMeasurementTests.measure { outcome = Self.run(doc).outcome }
        let (_, atGap, _) = Self.atLongestGap("an HTML declaration", doc, arm: false)
        print("parity latency an HTML declaration: peak heap \(measured.peakBytes) bytes for \(doc.count)")
        #expect(outcome == "feed T" && atGap?.outcome == "cancelled")
        // The text's own copies (UTF-8, UTF-16, the scanner's buffer) take 12 to 15 times its size in a debug build;
        // with the words it took 48 times.
        #expect(measured.peakBytes < 20 * doc.count, "peak heap \(measured.peakBytes) bytes for a \(doc.count)-byte feed")
        #expect((atGap?.afterTrue ?? 1) < 0.025, "from the true answer at the longest gap to the return")
    }

    /// A start tag of many namespace declarations or attributes: the parse's namespace bindings and the tag's
    /// attributes and their uniqueness sets were objects, millions of them released for seconds after the true answer
    /// (1.65 s for 57 MB of declarations). They are numbers in contiguous storage now.
    @Test func xmlTagsReleaseAtOnce() {
        let rss = "<rss version=\"2.0\"><channel><title>T</title>"
        for (name, tag) in [("namespace declarations", "<x" + (0..<400_000).map { " xmlns:p\($0)=\"u\($0)\"" }.joined() + "/>"),
                            ("attributes", "<x" + (0..<600_000).map { " a\($0)=\"\"" }.joined() + "/>")] {
            let doc = Self.bytes(rss + tag + "</channel></rss>")
            let (plain, atGap, _) = Self.atLongestGap(name, doc, arm: false)
            let middle = Self.run(doc, cancelAt: plain.checks / 2)
            print("parity latency \(name), cancelled at its middle: \(Self.describe(middle))")
            #expect(plain.outcome == "feed T" && atGap?.outcome == "cancelled" && middle.outcome == "cancelled", "\(name)")
            #expect((atGap?.afterTrue ?? 1) < 0.025 && (middle.afterTrue ?? 1) < 0.025, "\(name): from the true answer to the return")
        }
    }

    /// A prolog of many entity declarations: the declared names, values and replacement texts were dictionary entries
    /// of objects, millions of them released for about a second after the true answer. They
    /// are numbered in contiguous storage now. Uses still expand.
    @Test func entityTablesReleaseAtOnce() {
        let declarations = (0..<300_000).map { "<!ENTITY e\($0) \"x&#65;\">" }.joined()
        let doc = Self.bytes("<!DOCTYPE rss [" + declarations + "]><rss version=\"2.0\"><channel><title>T&e0;&e299999;</title>"
                             + "</channel></rss>")
        let (plain, atGap, _) = Self.atLongestGap("entity declarations", doc, arm: false)
        let middle = Self.run(doc, cancelAt: plain.checks / 2)
        print("parity latency entity declarations, cancelled at its middle: \(Self.describe(middle))")
        #expect(plain.outcome == "feed TxAxA" && atGap?.outcome == "cancelled" && middle.outcome == "cancelled")
        #expect((atGap?.afterTrue ?? 1) < 0.025 && (middle.afterTrue ?? 1) < 0.025, "from the true answer to the return")
    }

    // MARK: Long names

    /// One legal name as long as the document (an unused entity's, an attribute's) was hashed in single unchecked
    /// passes, as dictionary and set keys and in the entity filter's polynomial loops: a deadline went unanswered for
    /// up to a second. Names are hashed and compared in counted steps now, their hashes kept, and the
    /// polynomial loops ask inside. The yardstick is the same document with a value as long in place of the name, which
    /// no pass hashes: its longest gap is the parse's ordinary one. A deadline armed just after the question before
    /// the longest gap is answered within as long.
    @Test func longNamesAreHashedInCountedSteps() {
        let rss = "<rss version=\"2.0\"><channel><title>T</title>"
        let entity = 8 << 20
        let attribute = 24 << 20
        for (name, doc, yardstick) in [
            ("an entity name", "<!DOCTYPE rss [<!ENTITY " + String(repeating: "e", count: entity) + " \"x\">]>" + rss + "</channel></rss>",
             "<!DOCTYPE rss [<!ENTITY e \"" + String(repeating: "e", count: entity) + "\">]>" + rss + "</channel></rss>"),
            ("an attribute name", rss + "<x " + String(repeating: "a", count: attribute) + "=\"x\"/></channel></rss>",
             rss + "<x a=\"" + String(repeating: "a", count: attribute) + "\"/></channel></rss>")
        ] {
            let (plain, _, armed) = Self.atLongestGap(name, Self.bytes(doc), cancel: false, warm: true)
            _ = Self.run(Self.bytes(yardstick))
            let ordinary = Self.run(Self.bytes(yardstick))
            print("parity latency \(name), the yardstick: \(Self.describe(ordinary))")
            let bound = 3 * ordinary.gap + 0.05
            #expect(plain.outcome == "feed T" && ordinary.outcome == "feed T", "\(name)")
            #expect(plain.gap < bound, "\(name): the longest gap")
            if armed?.outcome == "cancelled" {
                #expect((armed?.lateness ?? 1) < bound, "\(name): a deadline armed after the question before the longest gap")
            }
        }
    }

    /// A reference inside a replacement text, its name as long as the document: the predefined-entity check copied
    /// the name and hashed it in one unchecked pass (a 64 MiB name kept a deadline waiting 200 ms), before the
    /// counted lookup. A name longer than four bytes is no predefined entity's, and is not read now. Undefined (a
    /// parser exception) and declared (the same name twice); the entities' first pass alone, where the reference is
    /// read. The yardstick has the same long run as a replacement text with no reference, and its longest gap is the
    /// pass's ordinary one. A deadline armed just after the question before the longest gap is answered within as
    /// long.
    @Test func longReferencesInReplacementTextsAreCounted() throws {
        let n = 16 << 20
        let rss = "<rss version=\"2.0\"><channel><title>T&e;</title></channel></rss>"
        let long = String(repeating: "a", count: n)
        for (name, doc, declared, yardstick) in [
            ("an undefined reference", "<!DOCTYPE rss [<!ENTITY e \"&" + long + ";\">]>" + rss, false,
             "<!DOCTYPE rss [<!ENTITY e \"" + long + "\">]>" + rss),
            ("a declared reference", "<!DOCTYPE rss [<!ENTITY " + long + " \"x\"><!ENTITY e \"&" + long + ";\">]>" + rss, true,
             "<!DOCTYPE rss [<!ENTITY a \"" + long + "\"><!ENTITY e \"" + long + "\">]>" + rss)
        ] {
            // The declared reference's "&e;" becomes "x".
            let outcome = declared ? "expanded \(doc.utf8.count - 2)" : "parser_exception"
            let (plain, _, armed) = Self.atLongestGap(name, Self.bytes(doc), cancel: false, expandOnly: true)
            let ordinary = Self.run(Self.bytes(yardstick), expandOnly: true)
            print("parity latency \(name), the yardstick: \(Self.describe(ordinary))")
            let bound = 3 * ordinary.gap + 0.05
            #expect(plain.outcome == outcome, "\(name)")
            #expect(plain.gap < bound, "\(name): the longest gap")
            // The pass may end before the deadline, with no question after it.
            if armed?.outcome == "cancelled" {
                #expect((armed?.lateness ?? 1) < bound, "\(name): a deadline armed after the question before the longest gap")
            } else {
                #expect(armed?.outcome == outcome, "\(name)")
            }
        }
        // The whole parse answers as before: the declared reference expands, the undefined one is malformed.
        let short = String(repeating: "a", count: 100)
        let declared = try ParityFeedParser.parse(Data(("<!DOCTYPE rss [<!ENTITY " + short + " \"x\"><!ENTITY e \"&" + short + ";&amp;\">]>"
            + rss).utf8), source: "https://example.com/feed.xml", now: ParityFeedParserTests.now)
        #expect(declared.title == "Tx&")
        #expect(throws: ParityParseError.self) {
            _ = try ParityFeedParser.parse(Data(("<!DOCTYPE rss [<!ENTITY e \"&" + short + ";\">]>" + rss).utf8),
                                           source: "https://example.com/feed.xml", now: ParityFeedParserTests.now)
        }
    }
}
