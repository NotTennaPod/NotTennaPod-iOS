import Foundation
import Testing
@testable import NotTennaPodCore

/// The chunked ordered storage against a plain sorted `Array` over 100,000 random operations at three chunk capacities,
/// and the bound that makes it worth having: an insert or removal at the front of a 100,000-member list moves at most one
/// chunk, not the whole list.
@Suite struct ChunkedOrderedListTests {
    struct Item: Equatable { let key: Int; let id: Int }
    static func precedes(_ a: Item, _ b: Item) -> Bool { a.key != b.key ? a.key < b.key : a.id < b.id }

    @Test(arguments: [4, 16, 256])
    func randomOperationsMatchASortedArray(capacity: Int) {
        var random = LargeAndroidLibrary.Random(state: 0xC4_0000 + UInt64(capacity))
        var reference: [Item] = []
        var list = ChunkedOrderedList<Item>(sorted: [], capacity: capacity, by: Self.precedes)
        var nextID = 0
        for step in 0..<100_000 {
            switch random.int(0...9) {
            case 0...4:
                // Keys collide often: ties are broken by ID.
                let item = Item(key: random.int(0...200), id: nextID); nextID += 1
                let rank = list.insert(item)
                var low = 0, high = reference.count
                while low < high { let middle = (low + high) / 2; if Self.precedes(reference[middle], item) { low = middle + 1 } else { high = middle } }
                let expected = low
                reference.insert(item, at: expected)
                if rank != expected { Issue.record("insert rank at step \(step)"); return }
            case 5...7:
                guard !reference.isEmpty else { continue }
                let index = random.int(0...(reference.count - 1))
                let rank = list.remove(reference[index])
                reference.remove(at: index)
                if rank != index { Issue.record("remove rank at step \(step)"); return }
            case 8:
                // An element not present is neither found nor removed; one present is not inserted twice.
                #expect(list.remove(Item(key: -1, id: -1)) == nil)
                if let present = reference.first { #expect(list.insert(present) == nil) }
            default:
                guard !reference.isEmpty else { continue }
                let lower = random.int(0...(reference.count - 1)), upper = min(reference.count, lower + random.int(0...300))
                #expect(list.elements(lower..<upper) == Array(reference[lower..<upper]))
                let index = random.int(0...(reference.count - 1))
                #expect(list.element(at: index) == reference[index])
                #expect(list.rank(of: reference[index]) == index)
            }
            if step % 5_000 == 0 {
                #expect(list.all == reference)
                #expect(list.chunkSizes.allSatisfy { $0 >= 1 && $0 <= capacity })
            }
            if list.count != reference.count { Issue.record("count at step \(step)"); return }
        }
        #expect(list.all == reference)
    }

    /// A newest-episode insert and a front removal at 10k, 54k and 100k members move at most one chunk (256) of elements
    /// plus a split; the directory work is reported and stays below N/64.
    @Test(arguments: [10_000, 54_000, 100_000])
    func frontChangesMoveOneChunk(size: Int) {
        var list = ChunkedOrderedList<Item>(sorted: (0..<size).map { Item(key: $0, id: $0) }, capacity: 256, by: Self.precedes)
        list.metrics = .init()
        list.insert(Item(key: -1, id: -1))
        #expect(list.metrics.elementsMoved <= 256 + 128, "insert moved \(list.metrics.elementsMoved)")
        #expect(list.metrics.directoryVisited <= size / 64 + 32)
        list.metrics = .init()
        list.remove(Item(key: 0, id: 0))
        #expect(list.metrics.elementsMoved <= 256, "remove moved \(list.metrics.elementsMoved)")
        #expect(list.metrics.directoryVisited <= size / 64 + 32)
        #expect(list.element(at: 0) == Item(key: -1, id: -1) && list.count == size)
    }
}
