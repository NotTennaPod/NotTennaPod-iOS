import Foundation
import Testing
@testable import NotTennaPodCore

/// The shared contract vectors (NotTennaPod-Server `contract/vectors`, copied into
/// `TestSupport/Contract/vectors` by `Tools/sync-contract-vectors.sh`). Each suite runs every case the way
/// the server's `check_vectors.py` checks it: a case either has an expected result or must be rejected.
struct ContractVectorTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized
    static let directory = root.appendingPathComponent("TestSupport/Contract/vectors")

    static func cases(_ suite: String) throws -> [ContractJSON] {
        let data = try Data(contentsOf: directory.appendingPathComponent("\(suite).json"))
        let file = try ContractJSON.decode(data)
        try #require(file["suite"]?.stringValue == suite)
        return try #require(file["cases"]?.arrayValue)
    }

    /// Runs every case; `check` returns nil when the case passes, otherwise what went wrong.
    private func run(_ suite: String, _ check: (ContractJSON) throws -> String?) throws {
        let cases = try Self.cases(suite)
        var failures: [String] = []
        for (index, vector) in cases.enumerated() {
            let problem: String?
            do { problem = try check(vector) } catch { problem = "malformed case or crash: \(error)" }
            if let problem { failures.append("case \(index): \(problem)\n  \(String(describing: try? vector.canonicalString()).prefix(400))") }
        }
        print("contract vectors: suite=\(suite) cases=\(cases.count) failures=\(failures.count)")
        #expect(!cases.isEmpty)
        #expect(failures.isEmpty, "\(suite): \(failures.count) of \(cases.count) cases fail\n\(failures.prefix(5).joined(separator: "\n"))")
    }

    /// A case with `"error": true` (or an error code) must be rejected; otherwise `compute` must succeed
    /// and equal the expected value.
    private func expect<T>(_ vector: ContractJSON, _ compute: () throws -> T, equals expected: () throws -> T,
                           by same: (T, T) -> Bool) throws -> String? {
        if Self.expectsError(vector) {
            do {
                let value = try compute()
                return "expected rejection, got \(value)"
            } catch is ContractError {
                return nil
            } catch {
                return "expected a contract error, got \(error)"
            }
        }
        let value: T
        do { value = try compute() } catch { return "expected \(try expected()), got error \(error)" }
        let wanted = try expected()
        return same(value, wanted) ? nil : "expected \(wanted), got \(value)"
    }

    private func expect(_ vector: ContractJSON, _ compute: () throws -> String, equals expected: () throws -> String) throws -> String? {
        try expect(vector, compute, equals: expected) { $0.utf8.elementsEqual($1.utf8) }
    }

    static func expectsError(_ vector: ContractJSON) -> Bool {
        switch vector["error"] {
        case nil, .null?, .bool(false)?: false
        default: true
        }
    }

    /// A vector case without a member it needs.
    struct MalformedCase: Error, CustomStringConvertible {
        let description: String
    }

    private func need<T>(_ value: T?, _ what: String = "a member") throws -> T {
        guard let value else { throw MalformedCase(description: "missing \(what)") }
        return value
    }

    private func string(_ vector: ContractJSON, _ name: String) throws -> String {
        try need(vector[name]?.stringValue, "string \(name)")
    }

    private func hex(_ vector: ContractJSON, _ name: String) throws -> [UInt8] {
        try need(ContractHex.decode(try string(vector, name)), "lowercase hex \(name)")
    }

    /// A queue key, or nil for JSON null (a sentinel).
    private func key(_ value: ContractJSON?) throws -> QueueKey? {
        let value = try need(value)
        guard !value.isNull else { return nil }
        return try QueueKey(wire: try need(value.stringValue))
    }

    // MARK: Suites

    @Test func canonicalJSON() throws {
        try run("canonical_json") { vector in
            let input: [UInt8] = vector["input_hex"] != nil ? try hex(vector, "input_hex") : Array(try string(vector, "input").utf8)
            return try expect(vector, { try ContractJSON.decode(input).canonicalString() }, equals: { try string(vector, "output") })
        }
    }

    @Test func url() throws {
        try run("url") { vector in
            try expect(vector, { ContractURL.normalize(try string(vector, "input")) }, equals: { try string(vector, "output") })
        }
    }

    @Test func guid() throws {
        try run("guid") { vector in
            let input = vector["input"]?.stringValue
            let output = vector["output"]?.stringValue
            let trimmed = ContractIdentity.trimmedGUID(input)
            let same = trimmed.map { value in output.map { value.utf8.elementsEqual($0.utf8) } ?? false } ?? (output == nil)
            return same ? nil : "expected \(String(describing: output)), got \(String(describing: trimmed))"
        }
    }

    @Test func stripUserinfo() throws {
        try run("strip_userinfo") { vector in
            try expect(vector, { ContractURL.stripUserinfo(try string(vector, "input")) }, equals: { try string(vector, "output") })
        }
    }

    @Test func lengthPrefixed() throws {
        try run("length_prefixed") { vector in
            let fields = try need(vector["fields"]?.arrayValue).map { try need($0.stringValue) }
            return try expect(vector, { ContractHex.encode(ContractIdentity.lengthPrefixed(fields)) }, equals: { try string(vector, "output") })
        }
    }

    @Test func ids() throws {
        try run("ids") { vector in
            let namespace = try string(vector, "namespace")
            let compute: () throws -> String
            switch try string(vector, "kind") {
            case "podcast":
                let op = try string(vector, "op_id")
                compute = { try ContractIdentity.podcastID(namespace: namespace, creatingOpID: op) }
            case "generation":
                let podcast = try string(vector, "podcast_id"), op = try string(vector, "op_id")
                compute = { try ContractIdentity.generationID(namespace: namespace, podcastID: podcast, creatingOpID: op) }
            case "episode":
                let podcast = try string(vector, "podcast_id"), k = try string(vector, "k"), v = try string(vector, "v")
                compute = { try ContractIdentity.episodeID(namespace: namespace, podcastID: podcast, kind: k, value: v) }
            case let kind: return "unknown kind \(kind)"
            }
            return try expect(vector, compute, equals: { try string(vector, "output") })
        }
    }

    @Test func queueParse() throws {
        try run("queue_parse") { vector in
            let input = try string(vector, "input")
            let valid = try need(vector["valid"]?.boolValue)
            guard QueueKey.isValid(input) == valid else { return "expected valid=\(valid)" }
            if valid, try QueueKey(wire: input).wire != input { return "format(parse(x)) != x" }
            return nil
        }
    }

    @Test func queueCompare() throws {
        try run("queue_compare") { vector in
            let compare = { QueueKey.compare(try need(try key(vector["a"])), try need(try key(vector["b"]))) }
            if let problem = try expect(vector, compare, equals: { Int(try need(vector["output"]?.integerValue)) }, by: ==) { return problem }
            guard !Self.expectsError(vector) else { return nil }
            let back = QueueKey.compare(try need(try key(vector["b"])), try need(try key(vector["a"])))
            return back == -Int(try need(vector["output"]?.integerValue)) ? nil : "compare(b, a) is not the negation"
        }
    }

    @Test func queueBetween() throws {
        try run("queue_between") { vector in
            let u = try hex(vector, "u")
            guard u.count == 16 else { return "u is not 16 bytes" }
            let between = { try QueueKey.between(try key(vector["low"]), try key(vector["high"]), positionWriteBytes: u).wire }
            if let problem = try expect(vector, between, equals: { try string(vector, "output") }) { return problem }
            guard !Self.expectsError(vector) else { return nil }
            let output = try QueueKey(wire: try string(vector, "output"))
            if let low = try key(vector["low"]), !(low < output) { return "the output is not above low" }
            if let high = try key(vector["high"]), !(output < high) { return "the output is not below high" }
            return nil
        }
    }

    @Test func causalOrder() throws {
        try run("causal_order") { vector in
            let nodes = try need(vector["nodes"]?.arrayValue).map { node in
                CausalNode(id: try string(node, "id"),
                           dependencies: try need(node["dependencies"]?.arrayValue).map { try need($0.stringValue) },
                           normalizedTime: try need(node["normalized_time"]?.integerValue))
            }
            if let code = vector["error"]?.stringValue {
                do {
                    let order = try CausalOrder.order(nodes)
                    return "expected error \(code), got \(order)"
                } catch let error as ContractError {
                    return error.code.rawValue == code ? nil : "expected error \(code), got \(error)"
                }
            }
            let output = try need(vector["output"]?.arrayValue).map { try need($0.stringValue) }
            return try expect(vector, { try CausalOrder.order(nodes) }, equals: { output }, by: ==)
        }
    }

    @Test func contentHash() throws {
        try run("content_hash") { vector in
            try expect(vector, { try ContractHash.contentHash(try need(vector["fact"])) }, equals: { try string(vector, "output") })
        }
    }

    @Test func digestChain() throws {
        try run("digest_chain") { vector in
            let previous = try hex(vector, "previous")
            let next = { ContractHex.encode(try ContractHash.nextDigest(previous: previous, try need(vector["object"]))) }
            return try expect(vector, next, equals: { try string(vector, "output") })
        }
    }

    @Test func cursor() throws {
        try run("cursor") { vector in
            let encoded = try string(vector, "encoded")
            if Self.expectsError(vector) {
                return (try? SyncCursor(encoded: encoded)).map { "expected rejection, got \($0)" }
            }
            let fields = try need(vector["cursor"])
            let cursor = try SyncCursor(logID: try string(fields, "log_id"), epoch: try need(fields["epoch"]?.integerValue),
                                        seq: try need(fields["seq"]?.integerValue), digest: try string(fields, "digest"))
            guard cursor.json == fields else { return "the cursor's JSON differs from the case's" }
            guard cursor.encoded == encoded else { return "encoded \(cursor.encoded)" }
            return try SyncCursor(encoded: encoded) == cursor ? nil : "decoded a different cursor"
        }
    }

    @Test func parts() throws {
        try run("parts") { vector in
            let parts = try need(vector["parts"]?.arrayValue).map { try need($0.stringValue) }
            let reassemble = { ContractJSON.object(try FactParts.reassemble(parts, contentHash: try string(vector, "content_hash"))) }
            if let problem = try expect(vector, reassemble, equals: { try need(vector["fact"]) }, by: ==) { return problem }
            guard !Self.expectsError(vector) else { return nil }
            // Splitting the fact again reassembles to the same object.
            let fact = try need(vector["fact"])
            let again = try FactParts.reassemble(try FactParts.split(fact, maximumBytes: 37), contentHash: try string(vector, "content_hash"))
            return ContractJSON.object(again) == fact ? nil : "split then reassemble differs"
        }
    }

    @Test func queueSort() throws {
        try run("queue_sort") { vector in
            let items = try need(vector["items"]?.arrayValue).map { item in
                CanonicalQueueSort.Values(podcastID: try string(item, "podcast_id"), title: item["title"]?.stringValue,
                                          podcastTitle: item["podcast_title"]?.stringValue,
                                          publicationTime: item["publication_time"]?.integerValue, duration: item["duration"]?.integerValue)
            }
            let output = try need(vector["output"]?.objectValue)
            guard Set(output.names) == Set(CanonicalQueueSort.Order.allCases.map(\.rawValue)) else {
                return "the output does not cover exactly the keep-sorted orders"
            }
            for order in CanonicalQueueSort.Order.allCases {
                let expected = try need(output[order.rawValue]?.arrayValue).map { Int(try need($0.integerValue)) }
                let actual = CanonicalQueueSort.order(items, by: order)
                if actual != expected { return "\(order.rawValue): expected \(expected), got \(actual)" }
            }
            return nil
        }
    }

    /// The copies are exactly the files the manifest lists (`Tools/sync-contract-vectors.sh --check` also
    /// compares them with a server checkout).
    @Test func copiesMatchTheManifest() throws {
        let manifest = try String(contentsOf: Self.root.appendingPathComponent("TestSupport/Contract/SHA256SUMS"), encoding: .utf8)
        var listed = Set<String>()
        for line in manifest.split(separator: "\n") {
            let hash = String(line.prefix(64))
            let path = String(line.dropFirst(66))
            listed.insert(path)
            let data = try Data(contentsOf: Self.directory.appendingPathComponent(path))
            #expect(ContractIdentity.sha256Hex(Array(data)) == hash, "\(path) differs from the manifest")
        }
        let enumerator = try #require(FileManager.default.enumerator(at: Self.directory, includingPropertiesForKeys: [.isRegularFileKey]))
        var present = Set<String>()
        let prefix = Self.directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        for case let url as URL in enumerator where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            present.insert(String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(prefix.count)))
        }
        #expect(present == listed)
    }
}
