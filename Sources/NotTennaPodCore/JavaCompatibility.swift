import Foundation

/// java.lang.String primitives that decide visible order.
public enum JavaString {
    /// `String.hashCode()` over UTF-16 code units, as a signed 32-bit value.
    public static func hashCode(_ value: String) -> Int32 {
        var hash: Int32 = 0
        for unit in value.utf16 { hash = hash &* 31 &+ Int32(unit) }
        return hash
    }
    /// `String.trim()`: removes code units <= U+0020 at both ends only (not other Unicode whitespace).
    public static func trim(_ value: String) -> String {
        let scalars = value.unicodeScalars
        let start = scalars.firstIndex { $0.value > 0x20 } ?? scalars.endIndex
        let end = scalars.lastIndex { $0.value > 0x20 }.map { scalars.index(after: $0) } ?? start
        return String(scalars[start..<end])
    }
    /// `String.compareTo` (UTF-16 code-unit order, not collation), as used by `Collections.sort`.
    public static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
    }
}

/// android.text.TextUtils primitives.
enum TextUtils {
    /// `TextUtils.split(value, ",")`: "" has no fields; otherwise every field counts, empty ones too.
    static func split(_ value: String) -> [String] { value.isEmpty ? [] : value.components(separatedBy: ",") }
}

/// Iteration order of a `java.util.HashMap<String, V>` (JDK 8+): buckets by the spread hash,
/// insertion order within a bucket, doubling at 75% load with order-preserving splits.
/// Tree bins (9+ keys in one bucket of a table of 64 or more) are not modelled; they need
/// about a hundred colliding feed URLs and keep list order here.
struct JavaHashMapOrder {
    private var table: [[(hash: UInt32, key: String)]] = []
    private var size = 0
    private var threshold = 0

    private static func spread(_ key: String) -> UInt32 {
        let hash = UInt32(bitPattern: JavaString.hashCode(key))
        return hash ^ (hash >> 16)
    }
    /// Adds `key` if absent. An existing key keeps its position, like `HashMap.put`.
    mutating func put(_ key: String) {
        if table.isEmpty { resize() }
        let hash = Self.spread(key)
        let index = Int(hash & UInt32(table.count - 1))
        if table[index].contains(where: { $0.hash == hash && $0.key == key }) { return }
        table[index].append((hash, key))
        if table[index].count >= 9 && table.count < 64 { resize() }
        size += 1
        if size > threshold { resize() }
    }
    private mutating func resize() {
        let old = table
        let capacity = old.isEmpty ? 16 : old.count * 2
        var new = Array(repeating: [(hash: UInt32, key: String)](), count: capacity)
        for (index, bin) in old.enumerated() {
            for node in bin {
                new[node.hash & UInt32(old.count) == 0 ? index : index + old.count].append(node)
            }
        }
        table = new
        threshold = capacity * 3 / 4
    }
    var keys: [String] { table.flatMap { $0.map(\.key) } }
}
