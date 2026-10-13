// Names (prefixes, namespace URIs, entity names) numbered by value in contiguous storage, and the hashing and
// comparing of names that can be as long as the document: both run in steps of the cancellation interval, each
// counted, so that one long name is never a long pass without a question.

/// Byte strings numbered by value, kept one after another, with an open-addressing index of them. Releasing a table of
/// millions is a few deallocations.
struct ParityNames {
    private var bytes: [UInt8] = []
    private var ends: [Int] = []
    private var hashes: [Int] = []
    private var slots = [Int32](repeating: -1, count: 16)

    var count: Int { ends.count }

    /// Name i, its bytes. (Held while the table grows, it would make the next addition copy the table.)
    func name(_ i: Int) -> ArraySlice<UInt8> { bytes[(i == 0 ? 0 : ends[i - 1])..<ends[i]] }

    /// A name's hash, its bytes fed in steps of the cancellation interval, each counted.
    static func hash(_ s: ArraySlice<UInt8>, _ work: ParityCancellation) throws -> Int {
        var hasher = Hasher()
        try s.withUnsafeBytes { raw in
            var start = 0
            repeat {
                let end = min(raw.count, start + ParityCancellation.interval)
                try work.tick(end - start)
                hasher.combine(bytes: UnsafeRawBufferPointer(rebasing: raw[start..<end]))
                start = end
            } while start < raw.count
        }
        return hasher.finalize()
    }

    /// Byte equality, compared in steps of the cancellation interval, each counted.
    static func equal(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>, _ work: ParityCancellation) throws -> Bool {
        guard a.count == b.count else { return false }
        var i = 0
        while i < a.count {
            let n = min(a.count - i, ParityCancellation.interval)
            try work.tick(n)
            if !a[(a.startIndex + i)..<(a.startIndex + i + n)].elementsEqual(b[(b.startIndex + i)..<(b.startIndex + i + n)]) {
                return false
            }
            i += n
        }
        return true
    }

    /// The number of a name, if it has one.
    func find(_ s: ArraySlice<UInt8>, _ work: ParityCancellation) throws -> Int? {
        try find(s, hash: Self.hash(s, work), work)
    }

    func find(_ s: ArraySlice<UInt8>, hash: Int, _ work: ParityCancellation) throws -> Int? {
        let mask = slots.count - 1
        var k = hash & mask
        while slots[k] >= 0 {
            let i = Int(slots[k])
            if hashes[i] == hash, try Self.equal(name(i), s, work) { return i }
            k = (k + 1) & mask
        }
        return nil
    }

    /// The number of a name, given one if it has none (the next number).
    mutating func intern(_ s: ArraySlice<UInt8>, _ work: ParityCancellation) throws -> Int {
        let h = try Self.hash(s, work)
        if let i = try find(s, hash: h, work) { return i }
        let i = count
        if bytes.isEmpty {
            // The first name of a whole array takes its storage, not a copy: one name as long as the document is kept
            // once.
            bytes = Array(s)
        } else {
            bytes.append(contentsOf: s)
        }
        ends.append(bytes.count)
        hashes.append(h)
        if 2 * count > slots.count {
            // Growing places every name again, a pass as long as the table: its steps are counted.
            slots = [Int32](repeating: -1, count: 2 * slots.count)
            for j in 0..<count {
                try work.tick()
                place(j)
            }
        } else {
            place(i)
        }
        return i
    }

    private mutating func place(_ i: Int) {
        let mask = slots.count - 1
        var k = hashes[i] & mask
        while slots[k] >= 0 { k = (k + 1) & mask }
        slots[k] = Int32(i)
    }
}
