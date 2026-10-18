import Foundation

/// Elements kept in one strict total order, stored in bounded chunks, so an insert or a removal anywhere moves at most one
/// chunk's elements and a few directory entries, never the whole list (an open list of 100,000 episodes gets a new
/// episode at its top without shifting every member). Ranks are found through the directory of chunk counts.
///
/// The order must be total: two distinct elements never compare equal (the lists break every tie by episode ID), so an
/// element is found again by the order alone.
public struct ChunkedOrderedList<Element> {
    /// What the list did: element moves within and between chunks, elements compared or copied out, directory entries
    /// visited, and comparator calls.
    public struct Metrics: Equatable, Sendable {
        public var elementsMoved = 0
        public var elementsVisited = 0
        public var directoryVisited = 0
        public var comparatorCalls = 0
        public init() {}
    }

    public let capacity: Int
    private let precedes: (Element, Element) -> Bool
    private var chunks: [[Element]] = []
    public private(set) var count = 0
    public var metrics = Metrics()

    /// `sorted` must already be in the order (a list's open sorts it once).
    public init(sorted: [Element], capacity: Int = 256, by precedes: @escaping (Element, Element) -> Bool) {
        precondition(capacity >= 4)
        self.capacity = capacity
        self.precedes = precedes
        let fill = max(1, capacity / 2)
        chunks = stride(from: 0, to: sorted.count, by: fill).map { Array(sorted[$0..<min(sorted.count, $0 + fill)]) }
        count = sorted.count
    }

    public var isEmpty: Bool { count == 0 }

    private mutating func less(_ a: Element, _ b: Element) -> Bool {
        metrics.comparatorCalls += 1
        return precedes(a, b)
    }

    /// The chunk an element belongs in: the first whose last element does not precede it (the last chunk otherwise).
    private mutating func chunkIndex(for element: Element) -> Int {
        var low = 0, high = chunks.count
        while low < high {
            let middle = (low + high) / 2
            metrics.directoryVisited += 1
            if less(chunks[middle][chunks[middle].count - 1], element) { low = middle + 1 } else { high = middle }
        }
        return min(low, max(0, chunks.count - 1))
    }

    private mutating func position(in chunk: Int, of element: Element) -> Int {
        var low = 0, high = chunks[chunk].count
        while low < high {
            let middle = (low + high) / 2
            if less(chunks[chunk][middle], element) { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The members before chunk `chunk`.
    private mutating func ranksBefore(_ chunk: Int) -> Int {
        var total = 0
        for index in 0..<chunk { total += chunks[index].count }
        metrics.directoryVisited += chunk
        return total
    }

    /// Inserts `element` at its place in the order; returns its rank. An element equal to one present is not inserted
    /// again (nil).
    @discardableResult
    public mutating func insert(_ element: Element) -> Int? {
        guard !chunks.isEmpty else {
            chunks = [[element]]; count = 1
            return 0
        }
        let chunk = chunkIndex(for: element)
        let offset = position(in: chunk, of: element)
        if offset < chunks[chunk].count, !less(element, chunks[chunk][offset]) { return nil }
        let rank = ranksBefore(chunk) + offset
        metrics.elementsMoved += chunks[chunk].count - offset
        chunks[chunk].insert(element, at: offset)
        count += 1
        if chunks[chunk].count > capacity { split(chunk) }
        return rank
    }

    /// Removes the element equal to `element` (found by the order); returns its rank before removal, nil when absent.
    @discardableResult
    public mutating func remove(_ element: Element) -> Int? {
        guard let (chunk, offset) = locate(element) else { return nil }
        let rank = ranksBefore(chunk) + offset
        metrics.elementsMoved += chunks[chunk].count - offset - 1
        chunks[chunk].remove(at: offset)
        count -= 1
        if chunks[chunk].isEmpty {
            chunks.remove(at: chunk)
            metrics.directoryVisited += chunks.count - chunk
        } else if chunks[chunk].count < capacity / 4 {
            merge(chunk)
        }
        return rank
    }

    /// The rank of the element equal to `element`, nil when absent.
    public mutating func rank(of element: Element) -> Int? {
        guard let (chunk, offset) = locate(element) else { return nil }
        return ranksBefore(chunk) + offset
    }

    private mutating func locate(_ element: Element) -> (Int, Int)? {
        guard !chunks.isEmpty else { return nil }
        let chunk = chunkIndex(for: element)
        let offset = position(in: chunk, of: element)
        guard offset < chunks[chunk].count, !less(element, chunks[chunk][offset]) else { return nil }
        return (chunk, offset)
    }

    private mutating func split(_ chunk: Int) {
        let half = chunks[chunk].count / 2
        let tail = Array(chunks[chunk][half...])
        metrics.elementsMoved += tail.count
        chunks[chunk].removeSubrange(half...)
        chunks.insert(tail, at: chunk + 1)
        metrics.directoryVisited += chunks.count - chunk
    }

    /// Joins a small chunk with a neighbour when both fit in one.
    private mutating func merge(_ chunk: Int) {
        let neighbour: Int
        if chunk + 1 < chunks.count, chunks[chunk].count + chunks[chunk + 1].count <= capacity { neighbour = chunk + 1 }
        else if chunk > 0, chunks[chunk].count + chunks[chunk - 1].count <= capacity { neighbour = chunk - 1 }
        else { return }
        let (first, second) = (min(chunk, neighbour), max(chunk, neighbour))
        metrics.elementsMoved += chunks[second].count
        chunks[first].append(contentsOf: chunks[second])
        chunks.remove(at: second)
        metrics.directoryVisited += chunks.count - second
    }

    /// The element at `rank`.
    public mutating func element(at rank: Int) -> Element {
        precondition(rank >= 0 && rank < count)
        var remaining = rank
        for index in chunks.indices {
            metrics.directoryVisited += 1
            if remaining < chunks[index].count {
                metrics.elementsVisited += 1
                return chunks[index][remaining]
            }
            remaining -= chunks[index].count
        }
        preconditionFailure()
    }

    /// The elements with ranks in `range` (clamped to the list), in order.
    public mutating func elements(_ range: Range<Int>) -> [Element] {
        let lower = max(0, range.lowerBound), upper = min(count, range.upperBound)
        guard lower < upper else { return [] }
        var result: [Element] = []
        result.reserveCapacity(upper - lower)
        var start = 0
        for chunk in chunks {
            metrics.directoryVisited += 1
            let end = start + chunk.count
            if end > lower {
                let from = max(lower, start) - start, to = min(upper, end) - start
                result.append(contentsOf: chunk[from..<to])
                metrics.elementsVisited += to - from
            }
            start = end
            if start >= upper { break }
        }
        return result
    }

    /// Every element in order (explicit work: select all, a pager over the whole list).
    public var all: [Element] { chunks.flatMap { $0 } }

    /// Tests: the chunk sizes, to check the bounds.
    public var chunkSizes: [Int] { chunks.map(\.count) }

    /// The memory the list holds: every chunk at its capacity, and the directory of chunks at its capacity.
    public var estimatedBytes: Int {
        chunks.reduce(0) { $0 + $1.capacity * MemoryLayout<Element>.stride + 32 } + chunks.capacity * MemoryLayout<[Element]>.stride
    }
}
