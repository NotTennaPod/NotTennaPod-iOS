import Foundation

/// Presentation compatibility for the pinned release's UTF-16 string sets.
/// This is an insertion-only builder: tag editing itself remains an array draft.
/// It deliberately has no general map API, object identity ordering or deletion.
enum FeedTagOrder {
    static func preferences(_ stored: [String]) -> Builder {
        // FeedPreferencesCursor maps an empty persisted tag string to #root.
        let parsed = Builder(collection: stored.isEmpty ? [FeedTags.root] : stored)
        var preferences = Builder(capacity: 16)
        for name in parsed.values { preferences.insert(name) }
        return preferences
    }

    struct Builder {
        private struct Node {
            let name: String, units: [UInt16], hash: UInt32
            var parent: Int?, left: Int?, right: Int?
            var red = true
        }
        private struct Bucket {
            var order: [Int] = []
            var root: Int?
        }
        private var nodes: [Node] = []
        private var buckets: [Bucket]
        private var seen = Set<[UInt16]>()
        var capacity: Int { buckets.count }
        var values: [String] { buckets.flatMap { $0.order.map { nodes[$0].name } } }

        init(capacity: Int) {
            var size = 16
            while size < capacity { size *= 2 }
            buckets = Array(repeating: Bucket(), count: size)
        }
        init(collection: [String]) {
            // HashSet's collection constructor reserves for at least 12 entries.
            self.init(capacity: (max(collection.count, 12) * 4 + 2) / 3)
            for name in collection { insert(name) }
        }
        mutating func insert(_ name: String) {
            let units = Array(name.utf16)
            guard seen.insert(units).inserted else { return }
            let raw = units.reduce(UInt32(0)) { ($0 &* 31) &+ UInt32($1) }
            let hash = raw ^ (raw >> 16)
            let id = nodes.count
            nodes.append(Node(name: name, units: units, hash: hash))
            let index = Int(hash) & (capacity - 1)
            if buckets[index].root != nil {
                insertTree(id, bucket: index, linkAfterParent: true)
                moveRootToFront(index)
            } else {
                buckets[index].order.append(id)
                if buckets[index].order.count >= 9 {
                    if capacity < 64 { grow() } else { treeify(index) }
                }
            }
            if nodes.count > capacity * 3 / 4 { grow() }
        }

        private mutating func grow() {
            let old = buckets, oldCapacity = old.count
            buckets = Array(repeating: Bucket(), count: oldCapacity * 2)
            for (index, bucket) in old.enumerated() where !bucket.order.isEmpty {
                let low = bucket.order.filter { Int(nodes[$0].hash) & oldCapacity == 0 }
                let high = bucket.order.filter { Int(nodes[$0].hash) & oldCapacity != 0 }
                buckets[index].order = low
                buckets[index + oldCapacity].order = high
                guard bucket.root != nil else { continue }
                for (destination, group, other) in [(index, low, high), (index + oldCapacity, high, low)] where group.count > 6 {
                    if other.isEmpty { buckets[destination].root = bucket.root }
                    else { treeify(destination) }
                }
            }
        }

        private func precedes(_ lhs: Int, _ rhs: Int) -> Bool {
            let a = nodes[lhs], b = nodes[rhs]
            if a.hash != b.hash { return Int32(bitPattern: a.hash) < Int32(bitPattern: b.hash) }
            return a.units.lexicographicallyPrecedes(b.units)
        }
        private mutating func treeify(_ bucket: Int) {
            let order = buckets[bucket].order
            buckets[bucket].root = nil
            for id in order {
                nodes[id].parent = nil; nodes[id].left = nil; nodes[id].right = nil; nodes[id].red = true
                insertTree(id, bucket: bucket, linkAfterParent: false)
            }
            moveRootToFront(bucket)
        }
        private mutating func moveRootToFront(_ bucket: Int) {
            guard let root = buckets[bucket].root,
                  let offset = buckets[bucket].order.firstIndex(of: root), offset != 0 else { return }
            buckets[bucket].order.remove(at: offset)
            buckets[bucket].order.insert(root, at: 0)
        }
        private mutating func insertTree(_ id: Int, bucket: Int, linkAfterParent: Bool) {
            guard var cursor = buckets[bucket].root else {
                buckets[bucket].root = id; nodes[id].red = false
                return
            }
            while true {
                let left = precedes(id, cursor)
                if let next = left ? nodes[cursor].left : nodes[cursor].right { cursor = next; continue }
                nodes[id].parent = cursor
                if left { nodes[cursor].left = id } else { nodes[cursor].right = id }
                if linkAfterParent, let offset = buckets[bucket].order.firstIndex(of: cursor) {
                    buckets[bucket].order.insert(id, at: offset + 1)
                }
                balance(id, bucket: bucket)
                return
            }
        }
        private func isRed(_ id: Int?) -> Bool { id.map { nodes[$0].red } ?? false }
        private mutating func rotateLeft(_ id: Int, bucket: Int) {
            guard let pivot = nodes[id].right else { return }
            let parent = nodes[id].parent, middle = nodes[pivot].left
            nodes[id].right = middle
            if let middle { nodes[middle].parent = id }
            nodes[pivot].parent = parent
            if let parent {
                if nodes[parent].left == id { nodes[parent].left = pivot } else { nodes[parent].right = pivot }
            } else { buckets[bucket].root = pivot }
            nodes[pivot].left = id; nodes[id].parent = pivot
        }
        private mutating func rotateRight(_ id: Int, bucket: Int) {
            guard let pivot = nodes[id].left else { return }
            let parent = nodes[id].parent, middle = nodes[pivot].right
            nodes[id].left = middle
            if let middle { nodes[middle].parent = id }
            nodes[pivot].parent = parent
            if let parent {
                if nodes[parent].right == id { nodes[parent].right = pivot } else { nodes[parent].left = pivot }
            } else { buckets[bucket].root = pivot }
            nodes[pivot].right = id; nodes[id].parent = pivot
        }
        private mutating func balance(_ inserted: Int, bucket: Int) {
            var id = inserted
            while let parent = nodes[id].parent, nodes[parent].red,
                  let grandparent = nodes[parent].parent {
                if nodes[grandparent].left == parent {
                    let uncle = nodes[grandparent].right
                    if isRed(uncle) {
                        nodes[parent].red = false; nodes[uncle!].red = false
                        nodes[grandparent].red = true; id = grandparent
                    } else {
                        if nodes[parent].right == id { id = parent; rotateLeft(id, bucket: bucket) }
                        let p = nodes[id].parent!, g = nodes[p].parent!
                        nodes[p].red = false; nodes[g].red = true; rotateRight(g, bucket: bucket)
                    }
                } else {
                    let uncle = nodes[grandparent].left
                    if isRed(uncle) {
                        nodes[parent].red = false; nodes[uncle!].red = false
                        nodes[grandparent].red = true; id = grandparent
                    } else {
                        if nodes[parent].left == id { id = parent; rotateRight(id, bucket: bucket) }
                        let p = nodes[id].parent!, g = nodes[p].parent!
                        nodes[p].red = false; nodes[g].red = true; rotateLeft(g, bucket: bucket)
                    }
                }
            }
            if let root = buckets[bucket].root { nodes[root].red = false }
        }
    }
}
