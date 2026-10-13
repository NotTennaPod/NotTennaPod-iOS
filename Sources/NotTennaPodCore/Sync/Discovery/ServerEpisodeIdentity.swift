import Foundation

/// An item's identity evidence as a refresh observed it (PROTOCOL §3.3, §9.7): its trimmed GUID, its enclosure
/// URL, its own publication time (nil when the item has none) and its title, every string without URL userinfo.
public struct ServerItemEvidence: Equatable, Sendable {
    public var guid: String?
    public var enclosureURL: String?
    public var publicationTime: Int64?
    public var title: String?
    /// An Atom feed's GUIDs are `atom-id`s.
    public var atom: Bool

    public init(guid: String?, enclosureURL: String?, publicationTime: Int64?, title: String?, atom: Bool) {
        self.guid = ContractIdentity.trimmedGUID(guid.map(ContractURL.stripUserinfo))
        self.enclosureURL = enclosureURL.flatMap { $0.isEmpty ? nil : ContractURL.stripUserinfo($0) }
        self.publicationTime = publicationTime
        self.title = title.map(ContractURL.stripUserinfo)
        self.atom = atom
    }

    var normalizedEnclosure: String? { enclosureURL.map(ContractURL.normalize) }
    var guidKind: String { atom ? ContractIdentity.EpisodeKind.atomID.rawValue : ContractIdentity.EpisodeKind.rssGUID.rawValue }
    /// Neither GUID nor enclosure: nothing to play, an `e0:` episode of its own (PROTOCOL §3.3 rule 5).
    var isUnidentifiable: Bool { guid == nil && enclosureURL == nil }

    /// The plain derivation (PROTOCOL §3.3 rules 2 and 4): the GUID, else the normalized enclosure.
    var plainKey: ServerEpisodeKey? {
        if let guid { return ServerEpisodeKey(kind: guidKind, value: guid) }
        if let enclosure = normalizedEnclosure { return ServerEpisodeKey(kind: ContractIdentity.EpisodeKind.enclosure.rawValue, value: enclosure) }
        return nil
    }

    /// Rule 3's identity for a reused GUID: GUID, U+001F, the normalized enclosure.
    var guidEnclosureKey: ServerEpisodeKey? {
        guard let guid, let enclosure = normalizedEnclosure else { return nil }
        return ServerEpisodeKey(kind: ContractIdentity.EpisodeKind.rssGUIDEnclosure.rawValue,
                                value: ContractIdentity.guidEnclosureValue(guid: guid, normalizedEnclosure: enclosure))
    }

    /// The occurrence evidence an `EpisodeRef` carries (PROTOCOL §7.2): `k` and `v` of the derivation used, and what was
    /// observed.
    func occurrence(_ key: ServerEpisodeKey?) -> ContractObject {
        var object: ContractObject = ["k": .string(key?.kind ?? "none"), "v": .string(key?.value ?? "")]
        if let guid { object["guid"] = .string(guid) }
        if let enclosureURL { object["enclosure_url"] = .string(enclosureURL) }
        if let title { object["title"] = .string(title) }
        if let publicationTime { object["publication_time"] = .integer(publicationTime) }
        return object
    }
}

/// The kind and value an episode ID derives from (`k`, `v`; PROTOCOL §3.3). `none` with an empty value for an `e0:` episode.
public struct ServerEpisodeKey: Hashable, Sendable {
    public var kind: String
    public var value: String
    public init(kind: String, value: String) { self.kind = kind; self.value = value }

    static let none = ServerEpisodeKey(kind: "none", value: "")
    var isNone: Bool { kind == "none" }
}

/// A podcast's `identity_rules` record (PROTOCOL §9.7): the releases of its disputed GUIDs, its disputed
/// enclosures and the lookup aliases that differ from plain derivation. No record means no rules.
struct ServerIdentityRules: Sendable {
    struct Release: Sendable {
        var episodeID: String
        var publicationTime: Int64?
        /// Normalized enclosure URLs.
        var enclosures: [String]
    }

    var disputedGUIDs: [String: [Release]] = [:]
    var disputedEnclosures: Set<String> = []
    /// `(guid | enclosure, value)` → episode.
    var aliases: [ServerEpisodeKey: String] = [:]

    init() {}

    init(_ record: ContractJSON?) {
        guard let record else { return }
        for entry in record["disputed_guids"]?.arrayValue ?? [] {
            guard let guid = entry["guid"]?.stringValue else { continue }
            disputedGUIDs[guid] = (entry["releases"]?.arrayValue ?? []).compactMap { release in
                guard let id = release["episode_id"]?.stringValue else { return nil }
                return Release(episodeID: id, publicationTime: release["publication_time"]?.integerValue,
                               enclosures: (release["enclosures"]?.arrayValue ?? []).compactMap(\.stringValue))
            }
        }
        disputedEnclosures = Set((record["disputed_enclosures"]?.arrayValue ?? []).compactMap(\.stringValue))
        for alias in record["aliases"]?.arrayValue ?? [] {
            guard let kind = alias["kind"]?.stringValue, let value = alias["value"]?.stringValue,
                  let episode = alias["episode_id"]?.stringValue else { continue }
            aliases[ServerEpisodeKey(kind: kind, value: value)] = episode
        }
    }

    var isEmpty: Bool { disputedGUIDs.isEmpty && disputedEnclosures.isEmpty && aliases.isEmpty }

    /// Whether the rules say anything about an item (an alias or a dispute of its GUID, an alias of its enclosure
    /// without one): otherwise its episode is its plain derivation.
    func concern(_ item: ServerItemEvidence) -> Bool {
        if let guid = item.guid { return disputedGUIDs[guid] != nil || aliases[ServerEpisodeKey(kind: "guid", value: guid)] != nil }
        guard let enclosure = item.normalizedEnclosure else { return false }
        return aliases[ServerEpisodeKey(kind: "enclosure", value: enclosure)] != nil
    }
}

/// Episode identity in a server library (PROTOCOL §9.7, §3.3 rules 1–5, PROTOCOL §9.7): the device's
/// derivation with its podcast's published rules, as the shared reference's devices derive it.
enum ServerEpisodeIdentity {
    /// "Within 7 days" (PROTOCOL §3.3, §9.7): one release.
    static let releaseWindow: Int64 = 7 * 86_400_000

    /// An item's episode under a registered podcast: a disputed GUID's release (the release within 7 days of its date,
    /// the nearest; without a date, the release listing its enclosure if exactly one does), else `rss-guid+enclosure` for
    /// a dated item with an enclosure near no release; an undisputed GUID's lookup alias or its plain ID; without a GUID
    /// the enclosure's lookup alias (unless disputed) or its plain ID. Nil without GUID and enclosure (rule 5). The key
    /// is the derivation the occurrence names (`k`, `v`).
    static func derive(_ item: ServerItemEvidence, rules: ServerIdentityRules, namespace: String,
                       podcast: String) throws -> (episodeID: String, key: ServerEpisodeKey)? {
        if let guid = item.guid {
            let plain = ServerEpisodeKey(kind: item.guidKind, value: guid)
            if let releases = rules.disputedGUIDs[guid] {
                if let release = release(of: item, in: releases) { return (release, plain) }
                if item.publicationTime != nil, let key = item.guidEnclosureKey {
                    return (try id(key, namespace: namespace, podcast: podcast), key)
                }
                return (try id(plain, namespace: namespace, podcast: podcast), plain)
            }
            if let alias = rules.aliases[ServerEpisodeKey(kind: "guid", value: guid)] { return (alias, plain) }
            return (try id(plain, namespace: namespace, podcast: podcast), plain)
        }
        guard let enclosure = item.normalizedEnclosure else { return nil }
        let plain = ServerEpisodeKey(kind: ContractIdentity.EpisodeKind.enclosure.rawValue, value: enclosure)
        if !rules.disputedEnclosures.contains(enclosure), let alias = rules.aliases[ServerEpisodeKey(kind: "enclosure", value: enclosure)] {
            return (alias, plain)
        }
        return (try id(plain, namespace: namespace, podcast: podcast), plain)
    }

    /// The release a disputed GUID's item belongs to (PROTOCOL §9.7): a dated item to the release whose date lies within 7
    /// days of its own (the nearest; ties to the earlier release, then the smaller episode ID); an undated one to the
    /// release listing its enclosure if exactly one does. Nil otherwise.
    static func release(of item: ServerItemEvidence, in releases: [ServerIdentityRules.Release]) -> String? {
        if let date = item.publicationTime {
            let near = releases.filter { release in
                guard let time = release.publicationTime else { return false }
                return abs(date - time) <= releaseWindow
            }
            return near.min { a, b in
                let da = abs(date - a.publicationTime!), db = abs(date - b.publicationTime!)
                if da != db { return da < db }
                if a.publicationTime! != b.publicationTime! { return a.publicationTime! < b.publicationTime! }
                return a.episodeID.utf8.lexicographicallyPrecedes(b.episodeID.utf8)
            }?.episodeID
        }
        guard let enclosure = item.normalizedEnclosure else { return nil }
        let listing = releases.filter { $0.enclosures.contains(enclosure) }
        return listing.count == 1 ? listing[0].episodeID : nil
    }

    static func id(_ key: ServerEpisodeKey, namespace: String, podcast: String) throws -> String {
        try ContractIdentity.episodeID(namespace: namespace, podcastID: podcast, kind: key.kind, value: key.value)
    }

    /// One local episode's identity evidence, for the phone's own reused-GUID rule and matching.
    struct LocalItem: Sendable, Equatable {
        var localID: Int64
        var key: ServerEpisodeKey
        var guid: String?
        /// Normalized.
        var enclosure: String?
        var publicationTime: Int64?
    }

    /// A reused GUID seen first on the phone (PROTOCOL §9.7, §3.3): among this podcast's local episodes with the
    /// item's GUID, a dated item belongs to the one whose observed date lies within 7 days of its own (the nearest); an
    /// undated one to the one with its enclosure if exactly one has it. A dated item with an enclosure near none of
    /// them, where one of them has another enclosure and a date more than 7 days from the item's, is a new occurrence:
    /// it takes `rss-guid+enclosure` (the episode already holding that identity, if one does), so downloads and state
    /// are never overwritten before the server knows. Otherwise nil: the plain derivation stands.
    /// `locals`: the podcast's local episodes with the item's GUID (or more; others are ignored).
    static func localOccurrence(of item: ServerItemEvidence, among locals: [LocalItem]) -> LocalOccurrence? {
        guard let guid = item.guid else { return nil }
        let same = locals.filter { $0.guid == guid && !$0.key.isNone }
        guard !same.isEmpty else { return nil }
        let enclosure = item.normalizedEnclosure
        if let date = item.publicationTime {
            let near = same.filter { local in local.publicationTime.map { abs(date - $0) <= releaseWindow } ?? false }
            if let best = near.min(by: { a, b in
                let da = abs(date - a.publicationTime!), db = abs(date - b.publicationTime!)
                return da != db ? da < db : a.localID < b.localID
            }) { return .existing(best.localID) }
            guard let enclosure, let key = item.guidEnclosureKey else { return nil }
            let disputes = same.contains { local in
                guard let other = local.enclosure, other != enclosure, let time = local.publicationTime else { return false }
                return abs(date - time) > releaseWindow
            }
            guard disputes else { return nil }
            if let holder = same.first(where: { $0.key == key }) {
                // A holder more than 7 days away is another release of rotating enclosures: the server gives this one
                // a persisted ID of its own.
                if holder.publicationTime != nil { return .provisional(key, release: date) }
                return .existing(holder.localID)
            }
            return .reused(key)
        }
        guard let enclosure else { return nil }
        let listing = same.filter { $0.enclosure == enclosure }
        return listing.count == 1 ? .existing(listing[0].localID) : nil
    }

    enum LocalOccurrence: Equatable {
        /// The item is this local episode's occurrence.
        case existing(Int64)
        /// The item is a new occurrence of a reused GUID, with this identity.
        case reused(ServerEpisodeKey)
        /// The item is a release of rotating enclosures whose `rss-guid+enclosure` an earlier release already has
        ///: its own episode, named by that identity and its occurrence evidence until the server's
        /// persisted occurrence mapping gives it an ID (an `e0:`), never mapped here before. `release` (its date)
        /// tells it from the earlier one.
        case provisional(ServerEpisodeKey, release: Int64)

        /// The identity the first-item rule compares (one per release).
        func identity(_ key: ServerEpisodeKey) -> String? {
            guard case .provisional(let key, let release) = self else { return nil }
            return "provisional\u{0}\(key.value)\u{0}\(release)"
        }
    }

    /// A fetch's items of reused GUIDs the server has not disputed yet, resolved with all of the
    /// fetch's evidence before the first-item rule, independent of item order. A GUID none of the podcast's local
    /// episodes has is partitioned into releases as the server's dispute does (PROTOCOL §9.7, `S/internal/ops/identity.go`
    /// `detect`): dated occurrences with an enclosure in (date, enclosure) order, the first the original release, a later
    /// one a release of its own when it is more than 7 days from every release so far and another enclosure is more than
    /// 7 days from it; each item belongs to the nearest release within 7 days (undated: the one listing its enclosure if
    /// exactly one does, else the original). The original keeps the plain identity; a later release is
    /// `rss-guid+enclosure` of its first enclosure. A GUID local episodes have is resolved item by item, oldest first,
    /// against them and the fetch's earlier new occurrences (`localOccurrence`). Items absent from the result take
    /// their plain derivation.
    static func batchOccurrences(_ items: [(index: Int, evidence: ServerItemEvidence)], locals: [LocalItem],
                                 disputed: (String) -> Bool) -> [Int: LocalOccurrence] {
        var byGUID: [String: [(index: Int, evidence: ServerItemEvidence)]] = [:]
        for item in items { if let guid = item.evidence.guid, !disputed(guid) { byGUID[guid, default: []].append(item) } }
        var localsByGUID: [String: [LocalItem]] = [:]
        for local in locals where !local.key.isNone { if let guid = local.guid { localsByGUID[guid, default: []].append(local) } }
        var result: [Int: LocalOccurrence] = [:]
        func order(_ a: ServerItemEvidence, _ b: ServerItemEvidence) -> Bool {
            switch (a.publicationTime, b.publicationTime) {
            case (let x?, let y?) where x != y: return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return (a.normalizedEnclosure ?? "").utf8.lexicographicallyPrecedes((b.normalizedEnclosure ?? "").utf8)
            }
        }
        for (guid, group) in byGUID {
            if let existing = localsByGUID[guid] {
                var virtuals: [LocalItem] = []
                var virtualOccurrence: [Int64: LocalOccurrence] = [:]
                for item in group.sorted(by: { order($0.evidence, $1.evidence) }) {
                    let found = localOccurrence(of: item.evidence, among: existing + virtuals)
                    switch found {
                    case .existing(let id) where id < 0:
                        result[item.index] = virtualOccurrence[id]
                    case .existing(let id): result[item.index] = .existing(id)
                    case .reused(let key), .provisional(let key, _):
                        result[item.index] = found
                        let id = -Int64(virtuals.count + 1)
                        virtualOccurrence[id] = found
                        virtuals.append(LocalItem(localID: id, key: key, guid: guid, enclosure: item.evidence.normalizedEnclosure,
                                                  publicationTime: item.evidence.publicationTime))
                    case nil: break
                    }
                }
                continue
            }
            guard group.count > 1 else { continue }
            let dated = group.filter { $0.evidence.publicationTime != nil && $0.evidence.normalizedEnclosure != nil }
                .sorted { order($0.evidence, $1.evidence) }
            func disputes(_ x: ServerItemEvidence) -> Bool {
                dated.contains { y in
                    y.evidence.normalizedEnclosure != x.normalizedEnclosure && abs(x.publicationTime! - y.evidence.publicationTime!) > releaseWindow
                }
            }
            guard dated.contains(where: { disputes($0.evidence) }) else { continue }
            var releases: [(time: Int64, enclosures: [String], original: Bool)] = []
            var makers = Set<Int>()
            for (position, item) in dated.enumerated() {
                let time = item.evidence.publicationTime!
                let near = releases.contains { abs(time - $0.time) <= releaseWindow }
                if position == 0 || (!near && disputes(item.evidence)) {
                    releases.append((time, [item.evidence.normalizedEnclosure!], position == 0))
                    makers.insert(item.index)
                }
            }
            func nearest(_ time: Int64) -> Int? {
                releases.indices.filter { abs(time - releases[$0].time) <= releaseWindow }.min { a, b in
                    let da = abs(time - releases[a].time), db = abs(time - releases[b].time)
                    return da != db ? da < db : releases[a].time < releases[b].time
                }
            }
            for item in dated where !makers.contains(item.index) {
                if let best = nearest(item.evidence.publicationTime!), !releases[best].enclosures.contains(item.evidence.normalizedEnclosure!) {
                    releases[best].enclosures.append(item.evidence.normalizedEnclosure!)
                }
            }
            // A later release whose `rss-guid+enclosure` an earlier one has (rotating enclosures) is provisional.
            var used = Set<ServerEpisodeKey>()
            let occurrences = releases.map { release -> LocalOccurrence? in
                guard !release.original else { return nil }
                let key = ServerEpisodeKey(kind: ContractIdentity.EpisodeKind.rssGUIDEnclosure.rawValue,
                                           value: ContractIdentity.guidEnclosureValue(guid: guid, normalizedEnclosure: release.enclosures[0]))
                return used.insert(key).inserted ? .reused(key) : .provisional(key, release: release.time)
            }
            for item in group {
                var release: Int?
                if let time = item.evidence.publicationTime { release = nearest(time) }
                else if let enclosure = item.evidence.normalizedEnclosure {
                    let listing = releases.indices.filter { releases[$0].enclosures.contains(enclosure) }
                    if listing.count == 1 { release = listing[0] }
                }
                if let release, let occurrence = occurrences[release] { result[item.index] = occurrence }
            }
        }
        return result
    }

    /// Whether a local episode with `rss-guid+enclosure` `key` is a provisional release (rotating
    /// enclosures): another of the feed's episodes has the same identity with a date more than 7
    /// days before its own.
    /// The earliest holds the identity; a provisional one is never mapped to it.
    static func isProvisional(_ item: LocalItem, among locals: [LocalItem]) -> Bool {
        guard item.key.kind == ContractIdentity.EpisodeKind.rssGUIDEnclosure.rawValue, let time = item.publicationTime else { return false }
        return locals.contains { $0.localID != item.localID && $0.key == item.key && ($0.publicationTime.map { time - $0 > releaseWindow } ?? false) }
    }

    /// Probable GUID changes in one fetch (PROTOCOL §9.5, §9.7): items whose GUID occurs once in the fetch and
    /// whose episode is new to this phone's replica, matched one to one, across the whole fetch, with episodes of the
    /// replica no item of the fetch resolves to, by identical non-empty title and the same publication time to the
    /// second. Returns the matched items' indices. They are observed but neither proposed nor filed, so a hosting move
    /// does not put old episodes back into the Inbox while the server's merge is pending.
    static func probableGUIDChanges(items: [(guid: String?, title: String?, publicationTime: Int64?, isNew: Bool)],
                                    vanished: [(title: String?, publicationTime: Int64?)]) -> Set<Int> {
        guard !vanished.isEmpty else { return [] }
        var shared: [String: Int] = [:]
        for item in items { if let guid = item.guid { shared[guid, default: 0] += 1 } }
        func same(_ a: (title: String?, publicationTime: Int64?), _ b: (title: String?, publicationTime: Int64?)) -> Bool {
            guard let ta = a.title, !ta.isEmpty, let tb = b.title, ta.utf8.elementsEqual(tb.utf8),
                  let pa = a.publicationTime, let pb = b.publicationTime else { return false }
            return floorDivide(pa, 1_000) == floorDivide(pb, 1_000)
        }
        let news = items.indices.filter { index in
            guard let guid = items[index].guid else { return false }
            return shared[guid] == 1 && items[index].isNew
        }
        var byNew: [Int: [Int]] = [:], byOld: [Int: [Int]] = [:]
        for index in news {
            for (old, candidate) in vanished.enumerated() where same((items[index].title, items[index].publicationTime), candidate) {
                byNew[index, default: []].append(old)
                byOld[old, default: []].append(index)
            }
        }
        return Set(news.filter { index in
            guard let olds = byNew[index], olds.count == 1 else { return false }
            return byOld[olds[0]]?.count == 1
        })
    }

    private static func floorDivide(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }
}
