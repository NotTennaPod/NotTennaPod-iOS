import Foundation
import Testing
@testable import NotTennaPodCore

/// Properties the contract asks of every implementation beyond the fixed vectors.
struct ContractPropertyTests {
    @Test func urlNormalizationIsIdempotent() throws {
        var inputs = try ContractVectorTests.cases("url").compactMap { $0["input"]?.stringValue }
        var generator = SystemRandomNumberGenerator()
        let pieces = ["HTTP", "https", "feed", ":", "//", "/", "@", "[", "]", ":80", ":443", "?", "#", "%4A", "%zz", "É", "a", "B", "1", ".", "-"]
        for _ in 0..<2_000 {
            inputs.append((0..<Int.random(in: 0...10, using: &generator)).map { _ in pieces.randomElement(using: &generator)! }.joined())
        }
        for input in inputs {
            let once = ContractURL.normalize(input)
            #expect(ContractURL.normalize(once) == once, "normalize is not idempotent for \(input)")
        }
    }

    /// A numeric character reference too large for a code point stays as written, however long it is (the
    /// Python reference cannot convert one of more than 4,300 digits). Its `#` then ends an authority.
    @Test func hugeCharacterReferencesStayAsWritten() {
        let reference = "&#" + String(repeating: "1", count: 5_000) + ";"
        #expect(ContractURL.stripUserinfo("https://u\(reference)@h/") == "https://u\(reference)@h/")
        #expect(ContractURL.stripUserinfo("x\(reference)https://u@h/") == "x\(reference)https://h/")
    }

    /// A text is stripped in one pass, so time and memory follow its length. 8 MiB full of URLs,
    /// userinfo and references (the earlier implementation built several arrays of the whole text, about 32 times
    /// its size, and took minutes on 16 MiB of such text).
    @Test func longTextsAreStrippedInOnePass() {
        let unit = "see http://user:pw@host.example/x and //a@b <a href='https://u@h'> &#104;ttp&#58;&#47;/u&#64;h/ &#64; "
        let stripped = "see http://host.example/x and //b <a href='https://h'> &#104;ttp&#58;&#47;/h/ &#64; "
        #expect(ContractURL.stripUserinfo(unit) == stripped)
        let count = 8 * 1_048_576 / unit.utf8.count
        let start = ContinuousClock.now
        #expect(ContractURL.stripUserinfo(String(repeating: unit, count: count)) == String(repeating: stripped, count: count))
        let plain = String(repeating: "a", count: 8 * 1_048_576) + "@"
        #expect(ContractURL.stripUserinfo(plain) == plain)
        #expect(start.duration(to: .now) < .seconds(10))
    }

    @Test func randomInsertionsKeepKeysOrderedAndUnique() throws {
        var keys: [QueueKey] = []
        for _ in 0..<500 {
            let index = Int.random(in: 0...keys.count)
            let low = index > 0 ? keys[index - 1] : nil
            let high = index < keys.count ? keys[index] : nil
            keys.insert(try QueueKey.between(low, high, positionWriteID: UUID()), at: index)
        }
        for (a, b) in zip(keys, keys.dropFirst()) { #expect(a < b) }
        #expect(Set(keys.map(\.wire)).count == keys.count)
        for key in keys { #expect(try QueueKey(wire: key.wire) == key) }
    }

    @Test func canonicalOutputDecodesToTheSameValue() throws {
        for vector in try ContractVectorTests.cases("canonical_json") {
            guard let output = vector["output"]?.stringValue else { continue }
            let value = try ContractJSON.decode(output)
            #expect(try value.canonicalString() == output)
        }
    }

    @Test func causalOrderDoesNotDependOnInputOrder() throws {
        for vector in try ContractVectorTests.cases("causal_order") where vector["output"] != nil {
            let nodes = try #require(vector["nodes"]?.arrayValue).map { node in
                CausalNode(id: try #require(node["id"]?.stringValue),
                           dependencies: try #require(node["dependencies"]?.arrayValue).compactMap(\.stringValue),
                           normalizedTime: try #require(node["normalized_time"]?.integerValue))
            }
            let expected = try CausalOrder.order(nodes)
            for _ in 0..<5 { #expect(try CausalOrder.order(nodes.shuffled()) == expected) }
        }
    }
}
