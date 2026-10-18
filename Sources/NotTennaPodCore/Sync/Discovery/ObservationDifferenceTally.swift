import Foundation

/// Why this phone's observations differ from the canonical records it holds (the first-refresh
/// diagnosis): each attempted comparison of a record with its canonical record, and each field that differs, by field
/// name only. No title, address or value is kept, so its line can go into the shareable synchronization log.
struct ObservationDifferenceTally: Equatable, Sendable {
    /// Comparisons attempted with a canonical record, and how many found a difference. Counted when compared: before the
    /// size limit decides what is sent and before the transaction commits (a rolled-back one counts too).
    private(set) var items = 0, differ = 0
    /// Field name → records it differed in. `missing`: no canonical record. `media.url.query`: the enclosure address
    /// differs only after its `?`.
    private(set) var fields: [String: Int] = [:]

    /// The episode record fields (`ServerCatalogRecords.item`) and the media members a difference is named by;
    /// anything else is `other`.
    static let names: Set<String> = [
        "title", "description", "link", "pub_date", "image_url", "payment_link", "media", "chapters", "chapter_url",
        "transcript_url", "transcript_type", "social_interact_url",
    ]
    static let mediaNames: [String: String] = ["size": "media.size", "duration": "media.duration", "mime_type": "media.mime"]

    var isEmpty: Bool { items == 0 }

    /// `fields`: the parse's record fields; `canonical`: the canonical record's (`ServerCatalogRecords.fields(ofCanonical:)`).
    mutating func note(_ fields: ContractJSON, canonical: ContractJSON?) {
        items += 1
        guard canonical != fields else { return }
        differ += 1
        guard case .object(let parsed) = fields, case .object(let stored)? = canonical else {
            self.fields["missing", default: 0] += 1
            return
        }
        var names = Set<String>()
        for key in Set(parsed.names).union(stored.names) where (parsed[key] ?? .null) != (stored[key] ?? .null) {
            guard key == "media", case .object(let a)? = parsed[key], case .object(let b)? = stored[key] else {
                names.insert(Self.names.contains(key) ? key : "other")
                continue
            }
            for member in Set(a.names).union(b.names) where (a[member] ?? .null) != (b[member] ?? .null) {
                if member == "url" {
                    let left = a[member]?.stringValue, right = b[member]?.stringValue
                    func base(_ url: String?) -> Substring? { url?.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first }
                    let queryOnly = left != nil && right != nil && base(left) == base(right)
                    names.insert(queryOnly ? "media.url.query" : "media.url")
                } else {
                    names.insert(Self.mediaNames[member] ?? "media.other")
                }
            }
        }
        for name in names { self.fields[name, default: 0] += 1 }
    }

    /// `items=N differ=M fields=name:count,…` (names sorted).
    var line: String {
        let list = fields.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        return "items=\(items) differ=\(differ) fields=\(list.isEmpty ? "none" : list)"
    }
}
