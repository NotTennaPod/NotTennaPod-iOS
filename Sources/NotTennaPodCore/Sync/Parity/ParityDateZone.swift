import Foundation

// Time zones of zone names, from the tzdata rules in ParityDateTables.zoneRules: only the listed transitions (to
// 2037), nothing beyond. A nil zone is GMT.

extension ParityDates {
    /// One zone's rules, decoded.
    final class Zone: Sendable {
        /// Every zone of ParityDateTables.zoneRules by its ID.
        static let byID: [String: Zone] = Dictionary(uniqueKeysWithValues: ParityDateTables.zoneRules.map { id, rule in
            (id, Zone(id: id, offsets: rule.0, isDst: rule.1, transitions: rule.2))
        })

        /// The longest zone name, in code points.
        static let nameMaxRunes = 64

        /// The zone names (ParityDateTables.zoneNames, same order) as the fold keys of their code points.
        static let nameKeys: [[UInt32]] = ParityDateTables.zoneNames.map { name in
            let keys = name.0.unicodeScalars.map { DateCharacters.foldKey($0.value) }
            precondition(!keys.isEmpty && keys.count <= nameMaxRunes, "zone name too long: \(name.0)")
            return keys
        }

        let id: String
        /// The zone's raw offset: that of its latest standard transition, in milliseconds.
        let raw: Int32
        /// Transition times, seconds since the epoch, ascending.
        private let times: [Int64]
        /// The standard offset in force from each transition, ms.
        private let raws: [Int64]
        /// The daylight saving in force from each transition, ms.
        private let dsts: [Int64]
        /// Whether each transition is into a daylight type.
        private let daylight: [Bool]
        /// The offset before the first transition, ms.
        private let earliest: Int64
        /// The latest transition into daylight time and the saving it brought against the latest standard type; nil
        /// without either.
        private let lastSaving: (time: Int64, saving: Int64)?

        /// Decodes a zone: offsets of each local-time type in seconds, '1' for each daylight type, and the transitions
        /// as standard base64 of (zigzag varint seconds since the previous transition, type index) pairs.
        init(id: String, offsets: [Int32], isDst: String, transitions: String) {
            guard let data = Data(base64Encoded: transitions) else { preconditionFailure("bad transitions of zone \(id)") }
            let bytes = Array(data)
            let flags = Array(isDst.utf8)
            func offset(_ type: Int) -> Int64 { Int64(offsets[type]) * 1000 }
            func isDaylight(_ type: Int) -> Bool { flags[type] == UInt8(ascii: "1") }

            var times: [Int64] = []
            var types: [Int] = []
            var at: Int64 = 0
            var i = 0
            while i < bytes.count {
                // A signed varint: LEB128 of the zigzag encoding.
                var ux: UInt64 = 0
                var shift: UInt64 = 0
                while true {
                    precondition(i < bytes.count && shift < 64, "bad transitions of zone \(id)")
                    let b = bytes[i]
                    i += 1
                    ux |= UInt64(b & 0x7F) << shift
                    if b < 0x80 { break }
                    shift += 7
                }
                let delta = Int64(bitPattern: ux >> 1) ^ -Int64(bitPattern: ux & 1)
                precondition(i < bytes.count && Int(bytes[i]) < offsets.count, "bad transitions of zone \(id)")
                at = at &+ delta
                times.append(at)
                types.append(Int(bytes[i]))
                i += 1
            }

            var raw = offset(0)
            var lastStandard: Int?
            for (index, type) in types.enumerated() where !isDaylight(type) {
                raw = offset(type)
                lastStandard = index
            }
            var earliest = raw
            if let type = offsets.indices.first(where: { !isDaylight($0) }) { earliest = offset(type) }

            var raws: [Int64] = []
            var dsts: [Int64] = []
            var daylight: [Bool] = []
            var standard = earliest
            var lastDaylight: Int?
            for (index, type) in types.enumerated() {
                let off = offset(type)
                if isDaylight(type) {
                    raws.append(standard)
                    dsts.append(off - standard)
                    lastDaylight = index
                } else {
                    standard = off
                    raws.append(off)
                    dsts.append(0)
                }
                daylight.append(isDaylight(type))
            }

            self.id = id
            self.raw = Int32(raw)
            self.times = times
            self.raws = raws
            self.dsts = dsts
            self.daylight = daylight
            self.earliest = earliest
            if let lastDaylight, let lastStandard {
                lastSaving = (times[lastDaylight], offset(types[lastDaylight]) - offset(types[lastStandard]))
            } else {
                lastSaving = nil
            }
        }

        /// The index of the last transition at or before the instant u (ms), or -1.
        private func transition(at u: Int64) -> Int {
            let second = DateCalendar.floorDiv(u, 1000)
            var low = 0
            var high = times.count
            while low < high {
                let middle = (low + high) / 2
                if times[middle] > second { high = middle } else { low = middle + 1 }
            }
            return low - 1
        }

        /// The standard offset and the daylight saving of a zone (nil for GMT) in force at the instant u (ms).
        static func offsets(_ zone: Zone?, at u: Int64) -> (raw: Int64, dst: Int64) {
            guard let zone else { return (0, 0) }
            let i = zone.transition(at: u)
            return i < 0 ? (zone.earliest, 0) : (zone.raws[i], zone.dsts[i])
        }

        /// Whether a zone (nil for GMT) is in daylight time at the instant u (ms).
        static func isDaylight(_ zone: Zone?, at u: Int64) -> Bool {
            guard let zone else { return false }
            let i = zone.transition(at: u)
            return i >= 0 && zone.daylight[i]
        }

        /// The zone's daylight saving as of now (ms): that of its latest daylight transition if that is not before
        /// now (rounded up to a second), else 0.
        func savings(now: Int64) -> Int64 {
            guard let lastSaving else { return 0 }
            // Wraps for now within a second of the maximum.
            let second = now > 0 ? (now &+ 999) / 1000 : now / 1000
            return lastSaving.time < second ? 0 : lastSaving.saving
        }
    }
}
