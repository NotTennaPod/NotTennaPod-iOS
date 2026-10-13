/// A causal node (PROTOCOL §6.1): a fact or a server decision, its dependencies and normalized time.
public struct CausalNode: Sendable, Equatable {
    public var id: String
    public var dependencies: [String]
    public var normalizedTime: Int64

    public init(id: String, dependencies: [String], normalizedTime: Int64) {
        self.id = id
        self.dependencies = dependencies
        self.normalizedTime = normalizedTime
    }
}

/// Causal order and time normalization (PROTOCOL §6.9).
public enum CausalOrder {
    /// The topological order of a set of nodes closed under dependencies: Kahn's algorithm, always emitting
    /// the ready node with the smallest `(normalized time, ID bytewise)`. Errors, the first that applies:
    /// `duplicate` node ID, `dependency_missing` (with the missing IDs), `cycle`. A dependency listed twice
    /// counts once.
    public static func order(_ nodes: [CausalNode]) throws -> [String] {
        var index: [[UInt8]: Int] = [:]
        let keys = nodes.map { Array($0.id.utf8) }
        for (position, node) in nodes.enumerated() {
            try checkTime(node.normalizedTime, "normalized_time")
            guard index.updateValue(position, forKey: keys[position]) == nil else {
                throw ContractError(.duplicate, "node \(node.id) appears more than once")
            }
        }
        var missing = Set<[UInt8]>()
        for node in nodes {
            for dependency in node.dependencies where index[Array(dependency.utf8)] == nil { missing.insert(Array(dependency.utf8)) }
        }
        if !missing.isEmpty {
            let sorted = missing.sorted { $0.lexicographicallyPrecedes($1) }.map { String(decoding: $0, as: UTF8.self) }
            throw ContractError(.dependencyMissing, "missing \(sorted)", missing: sorted)
        }
        var waiting = [Int](repeating: 0, count: nodes.count)
        var children = [[Int]](repeating: [], count: nodes.count)
        var ready = ReadyHeap(times: nodes.map(\.normalizedTime), keys: keys)
        for (position, node) in nodes.enumerated() {
            let unique = Set(node.dependencies.map { index[Array($0.utf8)]! })
            waiting[position] = unique.count
            for parent in unique { children[parent].append(position) }
            if unique.isEmpty { ready.push(position) }
        }
        var output: [String] = []
        output.reserveCapacity(nodes.count)
        while let next = ready.pop() {
            output.append(nodes[next].id)
            for child in children[next] {
                waiting[child] -= 1
                if waiting[child] == 0 { ready.push(child) }
            }
        }
        guard output.count == nodes.count else { throw ContractError(.cycle, "dependency cycle") }
        return output
    }

    private static func checkTime(_ value: Int64, _ name: String) throws {
        guard value >= -ContractJSON.maximumSafeInteger, value <= ContractJSON.maximumSafeInteger else {
            throw ContractError(.invalidValue, "\(name) outside ±(2^53−1)")
        }
    }
}

/// A binary min-heap of node positions by `(time, key bytewise)`.
private struct ReadyHeap {
    let times: [Int64]
    let keys: [[UInt8]]
    private var heap: [Int] = []

    init(times: [Int64], keys: [[UInt8]]) {
        self.times = times
        self.keys = keys
    }

    private func precedes(_ a: Int, _ b: Int) -> Bool {
        if times[a] != times[b] { return times[a] < times[b] }
        return keys[a].lexicographicallyPrecedes(keys[b])
    }

    mutating func push(_ node: Int) {
        heap.append(node)
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard precedes(heap[child], heap[parent]) else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Int? {
        guard let first = heap.first else { return nil }
        let last = heap.removeLast()
        if !heap.isEmpty {
            heap[0] = last
            var parent = 0
            while true {
                let left = 2 * parent + 1
                let right = left + 1
                var smallest = parent
                if left < heap.count, precedes(heap[left], heap[smallest]) { smallest = left }
                if right < heap.count, precedes(heap[right], heap[smallest]) { smallest = right }
                guard smallest != parent else { break }
                heap.swapAt(parent, smallest)
                parent = smallest
            }
        }
        return first
    }
}
